import XCTest
@testable import AudayBridgeCore

@MainActor
final class AppModelTests: XCTestCase {
    private var root: URL!
    private var paths: BridgePaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill = root.appendingPathComponent("skill")
        try FileManager.default.createDirectory(at: skill.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
        paths = BridgePaths(root: root.appendingPathComponent("data"), skill: skill)
        try FileManager.default.createDirectory(at: paths.profileDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 40000).write(to: paths.profileDirectory.appendingPathComponent("library.sqlite"))
        try Data("{}".utf8).write(to: paths.profileDirectory.appendingPathComponent("connection.json"))
        let fixture = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = #"""
        fixture=FIXTURE
        printf '%s\n' "$*" >> "$fixture/calls"
        while [ "$#" -gt 0 ]; do
            case "$1" in --home|--profile) shift 2 ;; *) break ;; esac
        done
        command="$1"
        shift
        case "$command" in
          check) printf '%s\n' '{"ok":true}' ;;
          status) printf '%s\n' '{"cache":{"syncedAt":"2026-10-26T10:00:00+08:00","sourceSnapshotAt":"2026-10-26T09:59:00+08:00","sourceSnapshotCurrent":true,"recordCount":1,"access":"text-only-read-only"}}' ;;
          sync)
            if [ -f "$fixture/fail-sync" ]; then
              printf '%s\n' '{"ok":false,"error":"connection_closed"}'
              exit 1
            fi
            printf '%s\n' '{"syncedAt":"2026-10-26T10:00:00+08:00","sourceSnapshotAt":"2026-10-26T09:59:00+08:00","sourceSnapshotCurrent":true,"recordCount":1,"access":"text-only-read-only"}' ;;
          index) printf '%s\n' '{"builtAt":"2026-10-26T10:01:00+08:00","indexed":true,"recordCount":1}' ;;
          index-status) printf '%s\n' '{"builtAt":"2026-10-26T10:01:00+08:00","indexed":true,"stale":false}' ;;
          export)
            while [ "$#" -gt 0 ]; do
              case "$1" in --output) output="$2"; shift 2 ;; *) shift ;; esac
            done
            mkdir -p "$output/days"
            printf '%s\n' '# Index' > "$output/index.md"
            printf '%s\n' '完整缓存正文' > "$output/days/2026-10-26.md"
            printf '%s\n' '{"syncedAt":"2026-10-26T10:00:00+08:00","recordCount":1,"dayCount":1,"recordKinds":{"transcript":1},"files":[{"path":"days/2026-10-26.md","records":1}]}' > "$output/manifest.json"
            printf '%s\n' '{"ok":true,"recordCount":1}' ;;
          search) printf '%s\n' '{"records":[{"id":"day-record","kind":"transcript","start":"2026-10-26T09:00:00+08:00","text":"检索结果"}],"nextOffset":null}' ;;
          read) printf '%s\n' '{"record":{"id":"day-record","kind":"transcript","start":"2026-10-26T09:00:00+08:00","text":"完整原文，与检索摘要不同","status":"confirmed"}}' ;;
          assets) printf '%s\n' '{"assets":[],"nextOffset":null}' ;;
          *) printf '%s\n' '{"ok":false,"error":"unexpected_test_command"}'; exit 1 ;;
        esac
        """#.replacingOccurrences(of: "FIXTURE", with: fixture)
        try Data(script.utf8).write(to: paths.bootstrap)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func awaitIdle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.working { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        model.cancel()
        XCTFail("Fixture operation did not finish")
    }
    private func calls() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
    private func prepareSemanticEvidence() throws {
        let model = paths.root.appendingPathComponent("models/embeddinggemma-300M-Q8_0.gguf")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: model.path, contents: Data())
        let handle = try FileHandle(forWritingTo: model)
        try handle.truncate(atOffset: 333590944)
        try handle.close()
        try Data("{}".utf8).write(to: paths.profileDirectory.appendingPathComponent("semantic-config.json"))
    }

    func testCheckOmitsUnsupportedProfileOption() async throws {
        let model = AppModel(paths: paths)
        _ = try await model.command(["check"])
        let call = try XCTUnwrap(calls().first)
        XCTAssertTrue(call.contains("--home " + paths.root.path))
        XCTAssertTrue(call.hasSuffix(" check"))
        XCTAssertFalse(call.contains("--profile"))
        _ = try await model.command(["status"])
        XCTAssertTrue(try XCTUnwrap(calls().last).contains("--profile default status"))
    }

    func testSyncBuildsIndexPublishesSnapshotAndPreservesBuiltAt() async throws {
        try prepareSemanticEvidence()
        let model = AppModel(paths: paths)
        model.states[2] = true
        model.sync()
        try await awaitIdle(model)
        let statusData = try Data(contentsOf: paths.export.appendingPathComponent("muse-status.json"))
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: statusData) as? [String: Any])
        XCTAssertEqual(status["syncedAt"] as? String, "2026-10-26T10:00:00+08:00")
        XCTAssertEqual(status["indexedAt"] as? String, "2026-10-26T10:01:00+08:00")
        XCTAssertEqual(status["recordCount"] as? Int, 1)
        XCTAssertEqual(status["semanticReady"] as? Bool, true)
        XCTAssertTrue(model.states[4]); XCTAssertTrue(model.states[5]); XCTAssertTrue(model.states[6])
        let commands = try calls()
        let sync = try XCTUnwrap(commands.firstIndex { $0.hasSuffix(" sync") })
        let index = try XCTUnwrap(commands.firstIndex { $0.hasSuffix(" index") })
        let export = try XCTUnwrap(commands.firstIndex { $0.contains(" export --output ") })
        XCTAssertLessThan(sync, index); XCTAssertLessThan(index, export)
        XCTAssertEqual(try String(contentsOf: paths.export.appendingPathComponent("days/2026-10-26.md")), "完整缓存正文\n")
    }

    func testConnectionFailureOffersOnlyOneExplicitRetry() async throws {
        try Data().write(to: root.appendingPathComponent("fail-sync"))
        let model = AppModel(paths: paths)
        model.sync(); try await awaitIdle(model)
        XCTAssertTrue(model.retryAvailable)
        XCTAssertTrue(model.message.contains("本批未提交"))
        model.sync(retry: true); try await awaitIdle(model)
        XCTAssertFalse(model.retryAvailable)
        model.sync(retry: true); try await awaitIdle(model)
        XCTAssertEqual(try calls().filter { $0.hasSuffix(" sync") }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.export.appendingPathComponent("muse-status.json").path))
    }


    func testDailyPreviewReadsFullRecordsWithoutSendingRequest() async throws {
        let model = AppModel(paths: paths)
        model.prepareDay("2026-10-26")
        try await awaitIdle(model)
        XCTAssertTrue(model.previewReady)
        XCTAssertEqual(model.dailyRecords.count, 1)
        XCTAssertEqual(model.dailyRecords.first?.text, "完整原文，与检索摘要不同")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.export.appendingPathComponent("requests").path))
        XCTAssertTrue(try model.bridge.requests().isEmpty)
    }
}
