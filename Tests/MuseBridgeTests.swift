import XCTest
@testable import AudayBridgeCore

final class MuseBridgeTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func record(_ id: String, day: String = "2026-10-26", text: String = "完整正文") -> Record {
        Record(raw: ["id": id, "kind": "transcript", "text": text,
                     "start": day + "T09:00:00+08:00", "end": day + "T10:00:00+08:00",
                     "timeZone": "Asia/Shanghai", "status": "confirmed"])
    }

    func testOnlyExplicitSendCreatesRequestAndFiltersDay() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        XCTAssertEqual(try bridge.requests().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("requests").path))
        let path = try bridge.createRequest(records: [record("today"), record("yesterday", day: "2026-10-25")],
                                            date: "2026-10-26", instruction: "", derivatives: ["yesterday": "PRIVATE", "today": "衍生文本"])
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("request.json"))) as! [String: Any]
        XCTAssertEqual(manifest["recordIds"] as? [String], ["today"])
        XCTAssertEqual(manifest["instruction"] as? String, FileMuseBridge.defaultInstruction)
        let content = try String(contentsOf: path.appendingPathComponent("content.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("完整正文"))
        XCTAssertTrue(content.contains("衍生文本"))
        XCTAssertTrue(content.contains("Asia/Shanghai"))
        XCTAssertFalse(content.contains("yesterday"))
        XCTAssertFalse(content.contains("PRIVATE"))
        XCTAssertEqual(try bridge.requests().first?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("results").path))
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent("content.md").path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
    }

    func testDoneRequiresMatchingIDTimestampAndFullResult() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        let request = try bridge.createRequest(records: [record("source")], date: "2026-10-26", instruction: "用户要求")
        let id = request.lastPathComponent
        let result = directory.appendingPathComponent("results/" + id, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let body = String(repeating: "日报完整内容\n", count: 2000)
        try body.write(to: result.appendingPathComponent("result.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try bridge.requests().first?.state, .pending)
        func done(_ idValue: String, _ timestamp: String) throws {
            try JSONSerialization.data(withJSONObject: ["requestId": idValue, "finishedAt": timestamp])
                .write(to: result.appendingPathComponent("done.json"))
        }
        try done("../wrong", "2026-10-26T12:30:00+08:00")
        XCTAssertEqual(try bridge.requests().first?.state, .invalid)
        try done(id, "invalid")
        XCTAssertEqual(try bridge.requests().first?.state, .invalid)
        try done(id, "2026-10-26T12:30:00+08:00")
        XCTAssertEqual(try bridge.requests().first?.state, .completed)
        XCTAssertEqual(try bridge.requests().first?.result, body)
    }

    func testSymlinkResultsRejectedAndRequestsNotOverwritten() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        let first = try bridge.createRequest(records: [record("one")], date: "2026-10-26", instruction: "")
        let second = try bridge.createRequest(records: [record("two")], date: "2026-10-26", instruction: "")
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        let elsewhere = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("results"), withDestinationURL: elsewhere)
        XCTAssertEqual(try bridge.requests().map(\.state), [.invalid, .invalid])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testRejectsSymlinkRequestDirectoryAndInvalidOrEmptyDates() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        XCTAssertThrowsError(try bridge.createRequest(records: [record("a")], date: "2026-02-30", instruction: ""))
        XCTAssertThrowsError(try bridge.createRequest(records: [record("a")], date: "2026-10-25", instruction: ""))
        let elsewhere = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("requests"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try bridge.createRequest(records: [record("a")], date: "2026-10-26", instruction: ""))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testSourceStateAndChronologicalOrderAcrossTimeZonesArePreserved() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        let earlier = Record(raw: ["id": "earlier", "kind": "memory", "text": "EARLIER_BODY",
                                   "start": "2026-10-26T12:00:00+08:00", "timeZone": "Asia/Shanghai",
                                   "state": "candidate", "status": "automatically saved"])
        let later = Record(raw: ["id": "later", "kind": "transcript", "text": "LATER_BODY",
                                 "start": "2026-10-26T05:00:00Z", "timeZone": "UTC", "state": "confirmed"])
        let path = try bridge.createRequest(records: [later, earlier], date: "2026-10-26", instruction: "")
        let content = try String(contentsOf: path.appendingPathComponent("content.md"), encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(content.range(of: "EARLIER_BODY")?.lowerBound),
                          try XCTUnwrap(content.range(of: "LATER_BODY")?.lowerBound))
        XCTAssertTrue(content.contains(#""state":"candidate""#))
        XCTAssertTrue(content.contains(#""status":"automatically saved""#))
        XCTAssertTrue(content.contains("2026-10-26T12:00:00+08:00"))
        XCTAssertTrue(content.contains("2026-10-26T05:00:00Z"))
    }

    func testOneMalformedOrLinkedManifestDoesNotHideValidHistory() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        let valid = try bridge.createRequest(records: [record("valid")], date: "2026-10-26", instruction: "")
        let malformed = try bridge.createRequest(records: [record("bad")], date: "2026-10-26", instruction: "")
        try Data("{ broken".utf8).write(to: malformed.appendingPathComponent("request.json"))
        let linked = try bridge.createRequest(records: [record("linked")], date: "2026-10-26", instruction: "")
        let manifest = linked.appendingPathComponent("request.json")
        try FileManager.default.removeItem(at: manifest)
        // A valid manifest behind a symlink must still be rejected, not read.
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: valid.appendingPathComponent("request.json"))
        let history = try bridge.requests()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.first(where: { $0.id == valid.lastPathComponent })?.state, .pending)
        XCTAssertEqual(history.first(where: { $0.id == malformed.lastPathComponent })?.state, .invalid)
        XCTAssertEqual(history.first(where: { $0.id == linked.lastPathComponent })?.state, .invalid)
        XCTAssertNil(history.first(where: { $0.id == linked.lastPathComponent })?.result)
    }

    func testAudioAssetsHaveSeparateIdentityAndFullProvenance() throws {
        let bridge = FileMuseBridge(exportURL: directory)
        let asset: [String: Any] = ["id": "asset-1", "start": "2026-10-26T09:00:00+08:00",
                                    "timeZone": "Asia/Shanghai", "scope": "text-and-audio-read-only",
                                    "timeline": [["recordedStart": "2026-10-26T09:00:00+08:00", "offset": 0]],
                                    "sha256": "synthetic-hash", "contentRevision": "revision-1"]
        let audio = try XCTUnwrap(AudioCatalog.records(assets: [asset], textRecords: [], date: "2026-10-26").first)
        let path = try bridge.createRequest(records: [record("text-record"), audio], date: "2026-10-26",
                                            instruction: "", derivatives: [audio.id: "转录全文"])
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: path.appendingPathComponent("request.json"))) as! [String: Any]
        XCTAssertEqual(manifest["recordIds"] as? [String], ["text-record"])
        XCTAssertEqual(manifest["audioAssetIds"] as? [String], ["asset-1"])
        let content = try String(contentsOf: path.appendingPathComponent("content.md"), encoding: .utf8)
        XCTAssertTrue(content.contains(#""sourceType":"audio_asset""#))
        XCTAssertTrue(content.contains(#""sourceType":"record""#))
        XCTAssertTrue(content.contains(#""asset":{"contentRevision":"revision-1""#))
        XCTAssertTrue(content.contains(#""recordedStart":"2026-10-26T09:00:00+08:00""#))
        XCTAssertTrue(content.contains(#""scope":"text-and-audio-read-only""#))
        XCTAssertTrue(content.contains("转录全文"))
    }
}
