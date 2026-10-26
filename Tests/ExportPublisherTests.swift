import XCTest
@testable import AudayBridgeCore

final class ExportPublisherTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func snapshot(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("days"), withIntermediateDirectories: true)
        try Data(name.utf8).write(to: url.appendingPathComponent("index.md"))
        try Data((name + "正文").utf8).write(to: url.appendingPathComponent("days/2026-10-26.md"))
        let manifest: [String: Any] = ["recordCount": 1, "dayCount": 1, "files": [["path": "days/2026-10-26.md", "records": 1]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.appendingPathComponent("manifest.json"))
        return url
    }
    func testUpdatesManagedSnapshotPreservingInboxesAndPrivateModes() throws {
        let first = try snapshot("first"), second = try snapshot("second")
        let export = root.appendingPathComponent("export")
        try ExportPublisher.publish(snapshot: first, to: export, status: ["syncedAt": "first"])
        for name in ["requests", "results"] {
            try FileManager.default.createDirectory(at: export.appendingPathComponent(name), withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: export.appendingPathComponent(name + "/preserved"))
        }
        try ExportPublisher.publish(snapshot: second, to: export, status: ["syncedAt": "second"])
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("index.md")), "second")
        for name in ["requests", "results"] {
            XCTAssertEqual(try String(contentsOf: export.appendingPathComponent(name + "/preserved")), "keep")
        }
        for (path, mode) in [("", 0o700), ("days", 0o700), ("days/2026-10-26.md", 0o600), ("index.md", 0o600), ("manifest.json", 0o600), ("muse-status.json", 0o600)] {
            let permissions = try FileManager.default.attributesOfItem(atPath: export.appendingPathComponent(path).path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(permissions.intValue & 0o777, mode)
        }
    }
    func testMidPublishFailureRestoresCompletePreviousSnapshot() throws {
        let first = try snapshot("first"), second = try snapshot("second")
        let export = root.appendingPathComponent("export")
        try ExportPublisher.publish(snapshot: first, to: export, status: ["syncedAt": "first"])
        let oldStatus = try Data(contentsOf: export.appendingPathComponent("muse-status.json"))
        struct Injected: Error {}
        XCTAssertThrowsError(try ExportPublisher.publish(snapshot: second, to: export, status: ["syncedAt": "second"], beforeCommit: {
            XCTAssertFalse(FileManager.default.fileExists(atPath: export.appendingPathComponent("muse-status.json").path))
            throw Injected()
        }))
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("index.md")), "first")
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("days/2026-10-26.md")), "first正文")
        XCTAssertEqual(try Data(contentsOf: export.appendingPathComponent("muse-status.json")), oldStatus)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: export.path).contains { $0.hasPrefix(".publish-") })
    }
    func testRejectsInvalidManifestBeforeChangingOldExport() throws {
        let first = try snapshot("first"), second = try snapshot("second")
        let export = root.appendingPathComponent("export")
        try ExportPublisher.publish(snapshot: first, to: export, status: ["syncedAt": "first"])
        try FileManager.default.removeItem(at: second.appendingPathComponent("days/2026-10-26.md"))
        XCTAssertThrowsError(try ExportPublisher.publish(snapshot: second, to: export, status: [:]))
        XCTAssertEqual(try String(contentsOf: export.appendingPathComponent("index.md")), "first")
    }
    func testRejectsSymlinkDestinationOrMember() throws {
        let source = try snapshot("source")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let export = root.appendingPathComponent("export")
        try FileManager.default.createSymbolicLink(at: export, withDestinationURL: outside)
        XCTAssertThrowsError(try ExportPublisher.publish(snapshot: source, to: export, status: [:]))
        try FileManager.default.removeItem(at: export)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: export.appendingPathComponent("results"), withDestinationURL: outside)
        XCTAssertThrowsError(try ExportPublisher.publish(snapshot: source, to: export, status: [:]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
