import Foundation
import CryptoKit

/// Installs the reviewed 0.6.0 snapshot, independently of git and git-lfs.
enum SkillInstaller {
    static let version = "0.6.0"
    static let revision = "20245721d7b60b8ac91cd68d2600c76b67348249"
    static let archiveSHA256 = "4274d430902983b1170ae5e860a6817f320151d25cb99237e386db507f82e63e"

    static func validate(at root: URL) throws {
        let fm = FileManager.default
        for relative in ["scripts/bootstrap.sh", "scripts/auday.py", "SKILL.md", "VERSION"] {
            let file = root.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard fm.isReadableFile(atPath: file.path), values.isRegularFile == true,
                  values.isSymbolicLink != true else { throw InstallError.incomplete }
        }
        let installedVersion = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard installedVersion == version else { throw InstallError.version }
    }

    static func install(at destination: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // Never replace a user-modified or unknown runtime implicitly.
            try validate(at: destination)
            return
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let work = parent.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let source = URL(string: "https://codeload.github.com/666ghj/auday-skill/zip/\(revision)")!
        let (download, response) = try await URLSession.shared.download(from: source)
        defer { try? fm.removeItem(at: download) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw InstallError.download
        }
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == archiveSHA256 else { throw InstallError.hash }
        let archive = work.appendingPathComponent("skill.zip")
        try fm.moveItem(at: download, to: archive)
        let unpack = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        // Hash-verified, fixed upstream archive; no shell interpolation.
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, unpack.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw InstallError.unpack }
        }.value
        try Task.checkCancellation()
        let root = unpack.appendingPathComponent("auday-skill-\(revision)", isDirectory: true)
        try validate(at: root)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // A same-filesystem rename publishes only the fully verified package.
        try fm.moveItem(at: root, to: destination)
    }

    enum InstallError: LocalizedError {
        case incomplete, version, download, hash, unpack
        var errorDescription: String? {
            switch self {
            case .incomplete: return "Auday 包不完整，缺少必要文件。请移开损坏的包后重试。"
            case .version: return "Auday 包版本不符合已核对的 0.6.0，请使用应用管理的安装位置。"
            case .download: return "无法下载官方 Auday 包，请检查网络后重试。"
            case .hash: return "Auday 下载包的 SHA-256 不匹配，已拒绝安装。"
            case .unpack: return "Auday 包解压失败，请重试。"
            }
        }
    }
}
