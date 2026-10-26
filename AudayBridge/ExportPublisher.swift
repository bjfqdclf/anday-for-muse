import Foundation

/// Publishes the current readable export while leaving both bridge inboxes alone.
/// Readers must treat muse-status.json as a commit marker and retry if it is absent.
enum ExportPublisher {
    private static let members = ["index.md", "days", "manifest.json"]
    private static let marker = "muse-status.json"

    static func publish(snapshot: URL, to export: URL, status: [String: Any]) throws {
        try publish(snapshot: snapshot, to: export, status: status, beforeCommit: {})
    }

    // The hook is internal so failure recovery can be exercised without unreliable disk-full tests.
    static func publish(snapshot: URL, to export: URL, status: [String: Any], beforeCommit: () throws -> Void) throws {
        let fm = FileManager.default
        let source = snapshot.standardizedFileURL
        let destination = export.standardizedFileURL
        guard source != destination,
              !source.path.hasPrefix(destination.path + "/"),
              !destination.path.hasPrefix(source.path + "/") else { throw PublishError.invalidSnapshot }
        try validateSnapshot(source)
        let statusData = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
        if fm.fileExists(atPath: destination.path) || isSymlink(destination) {
            try validateTree(destination)
            guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw PublishError.unsafePath
            }
        } else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        let work = destination.appendingPathComponent(".publish-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = work.appendingPathComponent("new", isDirectory: true)
        let backup = work.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var keepBackup = false
        defer { if !keepBackup { try? fm.removeItem(at: work) } }
        for name in members {
            try fm.copyItem(at: source.appendingPathComponent(name), to: staged.appendingPathComponent(name))
        }
        try statusData.write(to: staged.appendingPathComponent(marker), options: .atomic)
        try makePrivate(staged)
        var saved: [String] = []
        var installed: [String] = []
        do {
            // Remove the previous marker first, so cooperating readers cannot accept mixed generations.
            for name in [marker] + members {
                let current = destination.appendingPathComponent(name)
                if fm.fileExists(atPath: current.path) {
                    try fm.moveItem(at: current, to: backup.appendingPathComponent(name))
                    saved.append(name)
                }
            }
            for name in members {
                try fm.moveItem(at: staged.appendingPathComponent(name), to: destination.appendingPathComponent(name))
                installed.append(name)
            }
            try beforeCommit()
            // Rename on the same volume is the final, atomic commit marker publication.
            try fm.moveItem(at: staged.appendingPathComponent(marker), to: destination.appendingPathComponent(marker))
        } catch {
            do {
                for name in installed { try fm.removeItem(at: destination.appendingPathComponent(name)) }
                // Restore marker last, after every old payload has been restored.
                for name in saved.filter({ $0 != marker }) + saved.filter({ $0 == marker }) {
                    try fm.moveItem(at: backup.appendingPathComponent(name), to: destination.appendingPathComponent(name))
                }
            } catch {
                keepBackup = true
                throw PublishError.recoveryRequired(work)
            }
            throw error
        }
    }

    private static func validateSnapshot(_ root: URL) throws {
        try validateTree(root)
        let fm = FileManager.default
        for name in ["index.md", "manifest.json"] {
            guard try root.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw PublishError.invalidSnapshot
            }
        }
        let days = root.appendingPathComponent("days")
        guard try days.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any],
              let files = manifest["files"] as? [[String: Any]],
              let recordCount = manifest["recordCount"] as? Int, recordCount >= 0,
              let dayCount = manifest["dayCount"] as? Int, dayCount == files.count else { throw PublishError.invalidSnapshot }
        var seen = Set<String>()
        var total = 0
        for item in files {
            guard let path = item["path"] as? String,
                  path.hasPrefix("days/"), path.hasSuffix(".md"),
                  path.split(separator: "/").count == 2,
                  !path.contains(".."), !path.contains("\\"),
                  let count = item["records"] as? Int, count >= 0,
                  seen.insert(path).inserted,
                  fm.fileExists(atPath: root.appendingPathComponent(path).path),
                  try root.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw PublishError.invalidSnapshot
            }
            total += count
        }
        guard total == recordCount else { throw PublishError.invalidSnapshot }
        let actual = try fm.contentsOfDirectory(at: days, includingPropertiesForKeys: nil)
        guard Set(actual.map { "days/" + $0.lastPathComponent }) == seen else { throw PublishError.invalidSnapshot }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func validateTree(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw PublishError.unsafePath }
        if values.isDirectory == true {
            for member in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try validateTree(member)
            }
        } else if values.isRegularFile != true { throw PublishError.unsafePath }
    }

    private static func makePrivate(_ url: URL) throws {
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
        if isDirectory {
            for member in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try makePrivate(member)
            }
        }
    }

    enum PublishError: LocalizedError {
        case invalidSnapshot, unsafePath, recoveryRequired(URL)
        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: return "可读导出快照不完整或清单不一致，未发布。"
            case .unsafePath: return "导出路径包含符号链接或特殊文件，未发布。"
            case .recoveryRequired(let url): return "导出恢复未完成，原快照备份保留于：\(url.path)"
            }
        }
    }
}
