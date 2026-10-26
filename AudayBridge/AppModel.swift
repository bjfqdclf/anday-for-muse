import Foundation
import SwiftUI
import AppKit
import CryptoKit

@MainActor
final class AppModel: ObservableObject {
    let runner = CommandRunner()
    @Published private(set) var paths: BridgePaths
    init(paths: BridgePaths = BridgePaths()) { self.paths = paths }
    @Published var working = false
    @Published var message = "首次使用请准备环境。所有记录均为本地缓存。"
    @Published var states = Array(repeating: false, count: 7)
    @Published var updatedAt = "尚未检查"
    @Published var cache: [String: Any] = [:]
    @Published var services: [String] = []
    @Published var records: [Record] = []
    @Published var selected: Record?
    @Published var requests: [MuseRequest] = []
    @Published var query = ""
    @Published var kind = ""
    @Published var dateFilter = ""
    @Published var semantic = false
    @Published var nextOffset: Int?
    @Published var audioPaths: [String: String] = [:]
    @Published var derivatives: [String: String] = [:]
    @Published var retryAvailable = false
    @Published private(set) var resumableRecordCount = 0
    @Published private(set) var resumableBytes: Int64 = 0
    @Published var dailyRecords: [Record] = []
    @Published var dailyDate = ""
    @Published var skippedAudio: Set<String> = []
    @Published var currentAudioID: String?
    @Published var previewReady = false
    @Published var audioModel = UserDefaults.standard.string(forKey: "audioModel") ?? "small"
    @Published var diarize = UserDefaults.standard.object(forKey: "diarize") as? Bool ?? true
    private var operationTask: Task<Void, Never>?
    private var retryUsed = false
    private var cancelled = false
    private var indexedAt: Any = NSNull()
    var allowsAudio: Bool { cache["access"] as? String == "text-and-audio-read-only" }
    var bridge: FileMuseBridge { FileMuseBridge(exportURL: paths.export) }
    var freshness: String { "本地缓存 · 同步：\(cache["syncedAt"] as? String ?? "尚无") · 来源快照：\(cache["sourceSnapshotAt"] as? String ?? "未知")" }

    func perform(_ operation: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; cancelled = false
        operationTask = Task {
            do { try await operation() }
            catch { message = error.localizedDescription }
            await refreshEvidence()
            working = false
            operationTask = nil
        }
    }
    func command(_ args: [String]) async throws -> [String: Any] {
        if cancelled { throw CancellationError() }
        let prefix = args.first == "check" ? ["--home", paths.root.path] : ["--home", paths.root.path, "--profile", paths.profile]
        return try await runner.run(prefix + args, bootstrap: paths.bootstrap)
    }
    func cancel() { cancelled = true; operationTask?.cancel(); runner.cancel(); message = "已取消；将重新检查实际状态。" }
    func switchProfile(_ name: String) {
        guard !working else { return }
        guard name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            message = "Profile 名称仅可包含 1–64 个英文字母、数字、下划线或连字符。"; return
        }
        paths = BridgePaths(root: paths.root, skill: paths.skill, profile: name)
        cache = [:]; records = []; selected = nil; requests = []; dailyRecords = []; previewReady = false
        audioPaths = [:]; derivatives = [:]; states = Array(repeating: false, count: 7)
        retryAvailable = false; indexedAt = NSNull()
        message = "已切换到独立 profile：" + name + "。请单独配对，不会混合不同手机的数据。"
        refresh()
    }
    func prepare() { perform {
        try await SkillInstaller.install(at: self.paths.skill)
        _ = try await self.command(["setup", "--semantic"])
        self.message = "环境准备完成；请发现手机。"
    } }
    func refresh() { perform { } }
    func refreshEvidence() async {
        let fm = FileManager.default
        refreshResumableTransfers()
        states[0] = fm.fileExists(atPath: paths.bootstrap.path) && fm.fileExists(atPath: paths.skill.appendingPathComponent("SKILL.md").path)
        states[1] = false; states[3] = false; states[5] = false
        let model = paths.root.appendingPathComponent("models/embeddinggemma-300M-Q8_0.gguf")
        states[2] = (try? fm.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.int64Value == 333590944 && fm.fileExists(atPath: paths.profileDirectory.appendingPathComponent("semantic-config.json").path)
        // Evidence refresh must run even after cancellation.
        cancelled = false
        if states[0] {
            if let check = try? await command(["check"]) { states[1] = check["ok"] as? Bool == true }
            if let status = try? await command(["status"]) {
                cache = status["cache"] as? [String: Any] ?? [:]
                states[3] = fm.fileExists(atPath: paths.profileDirectory.appendingPathComponent("connection.json").path)
            }
            if states[2], let index = try? await command(["index-status"]) {
                states[5] = index["indexed"] as? Bool == true && index["stale"] as? Bool == false
                indexedAt = index["indexedAt"] ?? index["builtAt"] ?? NSNull()
            }
        }
        states[4] = cache["syncedAt"] is String && cache["recordCount"] is NSNumber
        if let data = try? Data(contentsOf: paths.export.appendingPathComponent("muse-status.json")),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String:Any] {
            states[6] = status["syncedAt"] as? String != nil && status["syncedAt"] as? String == cache["syncedAt"] as? String && fm.fileExists(atPath: paths.export.appendingPathComponent("index.md").path)
        } else { states[6] = false }
        requests = (try? bridge.requests()) ?? []
        updatedAt = Date().formatted(date: .omitted, time: .standard)
    }
    private func refreshResumableTransfers() {
        let directory = paths.profileDirectory.appendingPathComponent("record-staging", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            resumableRecordCount = 0; resumableBytes = 0
            return
        }
        let partials = files.filter { $0.lastPathComponent.hasSuffix(".partial") }
        var bytes: Int64 = 0
        for file in partials {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            bytes += Int64(values.fileSize ?? 0)
        }
        resumableRecordCount = partials.count
        resumableBytes = bytes
    }
    func discover() { perform {
        let result = try await self.command(["discover"])
        self.services = result["services"] as? [String] ?? []
        self.message = self.services.isEmpty ? "未发现手机，请检查同一 Wi-Fi 与手机接入页面。" : "请选择你的手机；发现的名称尚未认证。"
    } }
    func pair(_ service: String) { perform {
        _ = try await self.command(["pair-window", "--service", service])
        self.message = "请在 Auday 本地窗口完成密码输入，完成后点“刷新状态”验证配对。"
    } }
    func sync(retry: Bool = false) { perform {
        if retry { guard self.retryAvailable && !self.retryUsed else { return }; self.retryUsed = true }
        else { self.retryUsed = false }
        self.retryAvailable = false
        let result: [String:Any]
        do {
            result = try await self.command(["sync"])
            guard result["syncedAt"] is String, result["recordCount"] is NSNumber else { throw BridgeError("invalid_result") }
        } catch {
            self.retryAvailable = !self.retryUsed && !self.cancelled
            throw error
        }
        self.cache = result
        do {
            if self.states[2] { let index = try await self.command(["index"]); self.indexedAt = index["builtAt"] ?? NSNull() }
            try await self.exportSnapshot()
            try await self.loadRecords()
            self.message = self.states[2] ? "同步已提交，索引与可读导出已更新。" : "同步已提交并导出；语义环境未就绪，尚未建立索引。"
        } catch {
            self.message = "同步已提交；后续索引或导出未完成：" + error.localizedDescription
        }
    } }
    func index() { perform { let result = try await self.command(["index"]); self.indexedAt = result["builtAt"] ?? NSNull(); self.message = "索引已更新。" } }
    func export() { perform { try await self.exportSnapshot(); self.message = "可读导出与 Muse 状态已更新。" } }
    func exportSnapshot() async throws {
        let fm = FileManager.default
        let snapshots = paths.profileDirectory.appendingPathComponent("exports")
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = snapshots.appendingPathComponent(UUID().uuidString)
        _ = try await command(["export", "--output", destination.path, "--language", "zh-CN"])
        let manifest = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
        let exported = try JSONSerialization.jsonObject(with: manifest) as? [String:Any] ?? [:]
        var status: [String:Any] = ["profile": paths.profile, "exportedAt": ISO8601DateFormatter().string(from: Date()), "libraryBytes": (try? fm.attributesOfItem(atPath: paths.profileDirectory.appendingPathComponent("library.sqlite").path)[.size]) ?? 0, "semanticReady": states[2], "indexedAt": indexedAt]
        for key in ["syncedAt", "sourceSnapshotAt", "sourceSnapshotCurrent", "recordCount", "access"] { status[key] = cache[key] ?? NSNull() }
        status["recordKinds"] = exported["recordKinds"] ?? NSNull()
        try ExportPublisher.publish(snapshot: destination, to: paths.export, status: status)
    }
    func browse(more: Bool = false) { perform { try await self.loadRecords(offset: more ? self.nextOffset ?? 0 : 0) } }
    func loadRecords(offset: Int = 0) async throws {
        if kind == "audio" {
            guard !semantic else { throw BridgeError("audio_semantic", message: "语义检索用于文字记录；请切换关键词浏览录音目录。") }
            records = AudioCatalog.records(assets: try await loadAssets(), textRecords: [], date: dateFilter.isEmpty ? nil : dateFilter)
                .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            nextOffset = nil
            return
        }
        if semantic {
            let status = try await command(["index-status"])
            if status["indexed"] as? Bool != true || status["stale"] as? Bool != false { _ = try await command(["index"]) }
        }
        var args = ["search", query, "--mode", semantic ? "semantic" : "keyword", "--limit", "100"]
        if !kind.isEmpty { args += ["--kind", kind] }
        if !dateFilter.isEmpty { args += ["--date", dateFilter] }
        if !semantic { args += ["--offset", String(offset)] }
        let result = try await command(args)
        let page = (result["records"] as? [[String:Any]] ?? []).map(Record.init(raw:))
        if offset == 0 { records = page } else { records += page }
        nextOffset = result["nextOffset"] as? Int
    }
    func read(_ record: Record) {
        if record.kind == "audio" { selected = record; return }
        perform {
        let result = try await self.command(["read", record.id])
        if let raw = result["record"] as? [String:Any] { self.selected = Record(raw: raw) }
    } }
    func setupAudio() { perform {
        UserDefaults.standard.set(self.audioModel, forKey: "audioModel"); UserDefaults.standard.set(self.diarize, forKey: "diarize")
        var args = ["setup", "--audio", "--model", self.audioModel]
        if !self.diarize { args.append("--no-diarize") }
        _ = try await self.command(args)
        self.message = "本地转录准备与样例验证完成。匿名说话人不代表真实身份。"
    } }
    func loadAssets() async throws -> [[String:Any]] {
        var assets: [[String:Any]] = []; var offset = 0
        repeat {
            let page = try await command(["assets", "--limit", "100", "--offset", String(offset)])
            guard let rows = page["assets"] as? [[String:Any]] else { throw BridgeError("invalid_result") }
            assets += rows
            guard let next = page["nextOffset"] as? Int else { break }; offset = next
        } while true
        return assets
    }
    func fetchAudio(_ record: Record, transcribe: Bool, requiredDate: String? = nil) async throws {
        guard allowsAudio else { throw NSError(domain: "当前仅文本授权，请在手机端开启音频范围后重新同步。", code: 1) }
        let assets = try await loadAssets()
        guard let asset = assets.first(where: { record.audioAssetIDs.contains($0["id"] as? String ?? "") }), let id = asset["id"] as? String else { throw BridgeError("asset_missing", message: "此记录没有可匹配的音频资产，请从录音目录选择条目。") }
        let result = try await command(["audio", id])
        guard let path = result["path"] as? String else { throw NSError(domain: "音频结果缺少路径", code: 1) }
        audioPaths[record.id] = path
        let preparedAsset = result["asset"] as? [String:Any] ?? asset
        if let requiredDate, AudioCatalog.records(assets: [preparedAsset], textRecords: [record], date: requiredDate).isEmpty {
            throw BridgeError("audio_day_scope", message: "录音的完整时间轴不属于所选单日，已排除，避免包含其他日期内容。")
        }
        if transcribe {
            let parent = paths.profileDirectory.appendingPathComponent("derivatives")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let output = parent.appendingPathComponent(UUID().uuidString)
            let metadata = parent.appendingPathComponent(UUID().uuidString + ".json")
            try JSONSerialization.data(withJSONObject: preparedAsset).write(to: metadata)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            var args = ["transcribe", "--audio", path, "--output", output.path, "--language", "auto", "--asset-metadata", metadata.path]
            if !diarize { args.append("--no-diarize") }
            _ = try await command(args)
            let transcript = try String(contentsOf: output.appendingPathComponent("transcript.md"), encoding: .utf8)
            let timeline = try String(contentsOf: output.appendingPathComponent("result.json"), encoding: .utf8)
            derivatives[record.id] = transcript + "\n\n来源与完整时间轴映射（sourceSpans 保留来源片段）：\n\n```json\n" + timeline + "\n```"
            let provenance: [String:Any] = ["recordID": record.id, "assetID": id, "sourceStart": record.start, "sourceTimeZone": record.timeZone, "createdAt": ISO8601DateFormatter().string(from: Date())]
            let provenanceURL = output.appendingPathComponent("bridge-source.json")
            try JSONSerialization.data(withJSONObject: provenance).write(to: provenanceURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: provenanceURL.path)
        }
    }
    func audio(_ record: Record, transcribe: Bool) { perform { try await self.fetchAudio(record, transcribe: transcribe) } }
    func skipCurrentAudio() { if let id = currentAudioID { skippedAudio.insert(id); runner.cancel() } }
    func prepareDay(_ date: String) { perform {
        self.previewReady = false; self.dailyRecords = []; self.dailyDate = date; self.skippedAudio = []
        var offset = 0
        repeat {
            let page = try await self.command(["search", "--date", date, "--limit", "100", "--offset", String(offset)])
            self.dailyRecords += (page["records"] as? [[String:Any]] ?? []).map(Record.init(raw:))
            guard let next = page["nextOffset"] as? Int else { break }; offset = next
        } while true
        // Read complete records before packaging; retrieval excerpts never replace source text.
        var complete: [Record] = []
        for record in self.dailyRecords {
            let result = try await self.command(["read", record.id])
            guard let raw = result["record"] as? [String:Any] else { throw BridgeError("invalid_result") }
            complete.append(Record(raw: raw))
        }
        self.dailyRecords = complete + AudioCatalog.records(assets: try await self.loadAssets(), textRecords: complete, date: date)
        let transcribedAssets = Set(complete.filter { $0.kind == "transcript" && !$0.text.isEmpty }.flatMap(\.audioAssetIDs))
        for audio in self.dailyRecords where audio.kind == "audio" && !(audio.audioAssetID.map { transcribedAssets.contains($0) } ?? false) && self.derivatives[audio.id] == nil {
            self.currentAudioID = audio.id
            do { try await self.fetchAudio(audio, transcribe: true, requiredDate: date) }
            catch {
                if (error as? BridgeError)?.code == "audio_day_scope" {
                    self.skippedAudio.insert(audio.id)
                    self.dailyRecords.removeAll { $0.id == audio.id && $0.kind == "audio" }
                    continue
                }
                if self.cancelled { throw error }
                if !self.skippedAudio.contains(audio.id) { throw error }
            }
        }
        self.currentAudioID = nil; self.previewReady = true
        self.message = "分析包已预览：\(self.dailyRecords.count) 条记录；尚未发送。跳过 \(self.skippedAudio.count) 条录音。"
    } }
    func sendDay(instruction: String) { perform {
        guard self.previewReady, !self.dailyRecords.isEmpty else { return }
        _ = try self.bridge.createRequest(records: self.dailyRecords, date: self.dailyDate, instruction: instruction, derivatives: self.derivatives)
        self.previewReady = false; self.message = "请求已写入文件桥，等待 Muse 处理；这不代表 Muse 已在线连接。"
    } }
    func audioAvailability(_ record: Record) -> String {
        if audioPaths[record.id] != nil { return "录音：已下载并经 Auday 校验" }
        guard let asset = record.raw["asset"] as? [String:Any], let hash = asset["sha256"] as? String,
              hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return "录音：本地尚无已确认下载" }
        let suffixes = ["audio/mp4": ".m4a", "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/x-caf": ".caf", "audio/aac": ".aac"]
        let identityHash = SHA256.hash(data: Data(record.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let suffix = asset["preparation"] as? String == "on-demand" ? "-" + identityHash : ""
        let file = paths.profileDirectory.appendingPathComponent("audio/" + hash + suffix + (suffixes[asset["mime"] as? String ?? ""] ?? ".bin"))
        return FileManager.default.fileExists(atPath: file.path) ? "录音：本地文件已存在，取回时将再次校验" : "录音：尚未下载到本地"
    }
    func openExport() { NSWorkspace.shared.open(paths.export) }
}
