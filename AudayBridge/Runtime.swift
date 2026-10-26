import Foundation
import Combine
import Darwin

/// Runs the official bootstrap in a private process group. Raw output never enters UI logs.
@MainActor
final class CommandRunner: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var logs: [String] = []
    @Published private(set) var progress: Double?
    private var processID: pid_t?
    private var wasCancelled = false

    func cancel() {
        guard let pid = processID else { return }
        wasCancelled = true
        kill(-pid, SIGTERM)
        // Keep the busy gate until both pipes and waitpid have finished.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self?.processID == pid, self?.wasCancelled == true else { return }
            if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
        }
    }

    func run(_ arguments: [String], bootstrap: URL) async throws -> [String: Any] {
        guard !busy else { throw BridgeError("busy") }
        busy = true
        progress = nil
        wasCancelled = false
        defer { busy = false; processID = nil; progress = nil }
        let result: (Data, Int32) = try await withCheckedThrowingContinuation { continuation in
            let output = Pipe(), errors = Pipe()
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_setpgroup(&attributes, 0)
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
            let argv = (["/bin/sh", bootstrap.path] + arguments).map { strdup($0) } + [nil]
            let environment = ProcessInfo.processInfo.environment.merging(["AUDAY_PROGRESS": "1"]) { _, new in new }
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
            var pid: pid_t = 0
            let spawned = argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    posix_spawn(&pid, "/bin/sh", &actions, &attributes, args.baseAddress!, env.baseAddress!)
                }
            }
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            guard spawned == 0 else {
                continuation.resume(throwing: BridgeError("launch_failed", message: "无法启动 Auday 工具，请检查运行包与系统环境。"))
                return
            }
            processID = pid
            let state = ProcessOutput()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                state.setOutput(output.fileHandleForReading.readDataToEndOfFile())
                try? output.fileHandleForReading.close()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var pending = Data()
                while true {
                    let data = errors.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        if let safe = SafeProgress.parse(line) {
                            Task { @MainActor in self?.append(safe) }
                        }
                    }
                    // Untrusted stderr may contain arbitrary diagnostics without line breaks.
                    if pending.count > 16_384 { pending.removeAll(keepingCapacity: true) }
                }
                if let safe = SafeProgress.parse(String(decoding: pending, as: UTF8.self)) {
                    Task { @MainActor in self?.append(safe) }
                }
                try? errors.fileHandleForReading.close()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                state.setStatus(status)
                group.leave()
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume(returning: state.result())
            }
        }
        if wasCancelled { throw BridgeError("cancelled") }
        guard let line = String(data: result.0, encoding: .utf8)?.split(separator: "\n").last,
              let data = String(line).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], !json.isEmpty else {
            throw BridgeError("invalid_result")
        }
        if json["ok"] as? Bool == false || json["error"] != nil {
            let rawCode = json["error"] as? String ?? "invalid_result"
            // Error payloads can contain paths or text: retain only a fixed identifier internally.
            let candidate = rawCode.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "invalid_result"
            let code = candidate.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,79}$"#, options: .regularExpression) != nil ? candidate : "invalid_result"
            throw BridgeError(code)
        }
        guard result.1 == 0 else { throw BridgeError("invalid_result") }
        // Official search/read/status/sync successes often have no `ok`; callers verify command-specific fields.
        return json
    }

    private func append(_ entry: SafeProgress) {
        logs.append(entry.label)
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
        progress = entry.fraction
    }
}

private final class ProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var status: Int32 = 0
    func setOutput(_ data: Data) { lock.lock(); defer { lock.unlock() }; output = data }
    func setStatus(_ value: Int32) { lock.lock(); defer { lock.unlock() }; status = value }
    func result() -> (Data, Int32) { lock.lock(); defer { lock.unlock() }; return (output, status) }
}

struct SafeProgress {
    let label: String
    let fraction: Double?
    static func parse(_ line: String) -> SafeProgress? {
        guard line.hasPrefix("[Auday] ") else { return nil }
        let body = String(line.dropFirst(8))
        let parts = body.components(separatedBy: ": ")
        guard let translated = stages[parts[0]] else { return nil }
        guard parts.count > 1 else { return SafeProgress(label: translated, fraction: nil) }
        let pattern = #"^(\d+)/(\d+) (bytes|records|assets|results)(?: \(\d+%\))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: parts[1], range: NSRange(parts[1].startIndex..., in: parts[1])),
              match.range.length == parts[1].utf16.count,
              let a = Range(match.range(at: 1), in: parts[1]), let b = Range(match.range(at: 2), in: parts[1]),
              let completed = Double(parts[1][a]), let total = Double(parts[1][b]), completed <= total else {
            return SafeProgress(label: translated, fraction: nil)
        }
        return SafeProgress(label: translated + " · " + parts[1], fraction: total > 0 ? completed / total : nil)
    }
    private static let stages: [String: String] = [
        "Checking phone status": "检查手机状态", "Preparing text snapshot on phone": "手机准备快照",
        "Text snapshot ready": "快照已准备", "Downloading text records": "下载文本记录",
        "Receiving text records": "接收文本记录", "Receiving audio catalog": "接收音频目录",
        "Downloading audio catalogue": "下载音频目录", "Downloading large text record": "下载大型记录",
        "Verifying large text record": "校验大型记录", "Large text record verified": "大型记录校验完成",
        "Validating synchronized snapshot": "校验同步快照", "Saving local library": "保存本地资料库",
        "Synchronization complete": "同步已完成", "Snapshot unchanged; reusing cached records": "快照未变化，复用缓存",
        "Waiting for another operation on this local library": "等待资料库操作结束",
        "Searching cached text": "检索本地缓存", "Keyword search complete": "关键词检索完成",
        "Preparing local semantic search": "准备本地语义搜索", "Downloading semantic model": "下载语义模型",
        "Downloading semantic runtime": "下载语义运行时", "Downloading llama runtime": "下载语义运行时", "Downloading uv runtime": "下载私有工具",
        "Downloading python runtime": "下载私有 Python", "Downloading local component": "下载本地组件",
        "Preparing private Python runtime": "准备私有 Python", "Using verified local component": "使用已校验组件",
        "Verifying downloaded component": "校验下载组件", "Connection interrupted; resuming download": "恢复组件下载",
        "Verifying meaning-based retrieval": "验证语义检索", "Semantic search setup verified": "语义环境验证完成",
        "Verifying local semantic model": "校验本地语义模型", "Loading local semantic model": "加载语义模型",
        "Indexing text": "建立文本索引", "Semantic index ready": "语义索引已建立",
        "Understanding your search": "处理语义查询", "Searching by meaning": "执行语义检索",
        "Semantic search complete": "语义检索完成", "Exporting readable text": "导出可读文本",
        "Readable export complete": "可读导出完成", "Preparing requested audio on phone": "手机准备录音",
        "Requested audio ready": "录音已准备", "Using verified cached audio": "使用已校验录音缓存",
        "Downloading audio": "下载录音", "Verifying downloaded audio": "校验录音", "Audio saved and verified": "录音保存并校验完成",
        "Downloading pinned Whisper.cpp source": "下载转录运行时源码", "Preparing local audio analysis": "准备本地音频分析",
        "Downloading selected transcription model": "下载所选转录模型",
        "Downloading speaker segmentation model": "下载说话人分段模型", "Downloading speaker embedding model": "下载说话人特征模型",
        "Preparing 16 kHz mono audio": "准备转录音频", "Audio preparation complete": "音频准备完成",
        "Transcribing audio with Whisper.cpp": "本地转录", "Transcription complete": "转录完成",
        "Identifying anonymous speaker turns": "区分匿名说话人", "Speaker diarization complete": "匿名说话人区分完成",
        "Saving local analysis results": "保存衍生分析", "Local audio analysis complete": "本地音频分析完成",
        "Verifying transcription with public sample audio": "使用公开样本验证转录", "Local audio setup verified": "本地音频环境已验证"
    ]
}
