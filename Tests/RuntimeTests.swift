import XCTest
@testable import AudayBridgeCore

final class RuntimeTests: XCTestCase {
    private func withScript(_ body: String, perform: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("bootstrap with spaces.sh")
        try body.write(to: script, atomically: true, encoding: .utf8)
        try await perform(script)
    }

    @MainActor func testSeparatePipesLastJSONAndPrivacy() async throws {
        try await withScript("""
        i=0; while [ "$i" -lt 5000 ]; do echo 'PRIVATE-TRANSCRIPT-SECRET' >&2; i=$((i+1)); done
        echo '[Auday] Downloading audio: 25/100 bytes (25%)' >&2
        echo '[Auday] Downloading audio: PRIVATE-TRANSCRIPT-SECRET' >&2
        echo 'unstructured startup output'
        echo '{"records":[],"syncedAt":"2026-10-26"}'
        """) { script in
            let runner = CommandRunner()
            let result = try await runner.run([], bootstrap: script)
            XCTAssertEqual(result["syncedAt"] as? String, "2026-10-26")
            XCTAssertNotNil(result["records"] as? [Any])
            XCTAssertFalse(runner.logs.joined().contains("SECRET"))
            XCTAssertFalse(runner.busy)
        }
    }

    @MainActor func testMalformedJSONAndToolFailureAreSanitized() async throws {
        try await withScript("""
        case "$1" in
        bad) echo 'PRIVATE-SECRET';;
        failed) echo '{"ok":false,"error":"connection_closed"}'; exit 1;;
        private) echo '{"ok":false,"error":"PRIVATE/SECRET"}';;
        esac
        """) { script in
            let runner = CommandRunner()
            for (argument, code) in [("bad", "invalid_result"), ("failed", "connection_closed"), ("private", "invalid_result")] {
                do {
                    _ = try await runner.run([argument], bootstrap: script)
                    XCTFail("Expected failure")
                } catch let error as BridgeError {
                    XCTAssertEqual(error.code, code)
                    XCTAssertFalse(error.localizedDescription.contains("SECRET"))
                }
            }
        }
    }

    @MainActor func testConcurrentOperationRejectedAndGroupCancelled() async throws {
        try await withScript("sleep 60 & wait\n") { script in
            let runner = CommandRunner()
            let task = Task { try await runner.run([], bootstrap: script) }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(runner.busy)
            do {
                _ = try await runner.run([], bootstrap: script)
                XCTFail("Concurrent operation should fail")
            } catch let error as BridgeError { XCTAssertEqual(error.code, "busy") }
            runner.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancelled operation should fail")
            } catch let error as BridgeError { XCTAssertEqual(error.code, "cancelled") }
            XCTAssertFalse(runner.busy)
        }
    }

    func testProgressAllowsOnlyKnownStagesAndNumericCounts() {
        XCTAssertEqual(SafeProgress.parse("[Auday] Downloading audio: 25/100 bytes (25%)")?.fraction, 0.25)
        XCTAssertNil(SafeProgress.parse("[Auday] private text SECRET"))
        XCTAssertFalse(SafeProgress.parse("[Auday] Downloading audio: SECRET")!.label.contains("SECRET"))
        XCTAssertNil(SafeProgress.parse("[Auday] Downloading audio: 101/100 bytes (101%)")?.fraction)
    }
}
