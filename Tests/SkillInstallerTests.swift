import XCTest
@testable import AudayBridgeCore

final class SkillInstallerTests: XCTestCase {
    func testValidationRequiresCompletePinnedVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try SkillInstaller.validate(at: root))
        for file in ["scripts/bootstrap.sh", "scripts/auday.py", "SKILL.md"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(file))
        }
        try Data("0.7.0\n".utf8).write(to: root.appendingPathComponent("VERSION"))
        XCTAssertThrowsError(try SkillInstaller.validate(at: root))
        try Data("0.6.0\n".utf8).write(to: root.appendingPathComponent("VERSION"))
        XCTAssertNoThrow(try SkillInstaller.validate(at: root))
    }

    func testValidationRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("scripts/bootstrap.sh"), withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try SkillInstaller.validate(at: root))
    }
}
