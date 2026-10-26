import XCTest
@testable import AudayBridgeCore

final class AudioCatalogTests: XCTestCase {
    func testPluralAndSingularAssetReferencesPreserveOrderAndDeduplicate() {
        let record = Record(raw: ["id": "transcript", "audioAssetIDs": ["audio-demo", "second", "audio-demo", ""], "audioAssetID": "second"])
        XCTAssertEqual(record.audioAssetIDs, ["audio-demo", "second"])
        XCTAssertEqual(Record(raw: ["audioAssetID": "single"]).audioAssetIDs, ["single"])
    }

    func testUpstreamTimelineFixtureBuildsAudioRecordWithoutChangingSourceDate() {
        // Shape from upstream tests/make_fixture.py and test_record_transfer.py.
        let asset: [String: Any] = ["id": "audio-demo", "path": "sample.wav", "mime": "audio/wav",
            "durationSeconds": 24, "timeline": [["fileStart": 0, "fileEnd": 24,
                "recordedStart": "2026-01-01T00:05:00+14:00"]]]
        let text = Record(raw: ["id": "transcript-000", "kind": "transcript", "title": "合成项目讨论",
            "audioAssetIDs": ["audio-demo"], "start": "2026-01-01T00:05:00+14:00",
            "end": "2026-01-01T00:05:24+14:00", "timeZone": "Pacific/Kiritimati", "state": "candidate"])
        let records = AudioCatalog.records(assets: [asset], textRecords: [text], date: "2026-01-01")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "audio-demo")
        XCTAssertEqual(records[0].kind, "audio")
        XCTAssertEqual(records[0].audioAssetID, "audio-demo")
        XCTAssertEqual(records[0].start, "2026-01-01T00:05:00+14:00")
        XCTAssertEqual(records[0].status, "candidate")
        XCTAssertEqual(records[0].timeZone, "Pacific/Kiritimati")
        XCTAssertEqual((records[0].raw["asset"] as? [String: Any])?["path"] as? String, "sample.wav")
        XCTAssertTrue(AudioCatalog.records(assets: [asset], textRecords: [text], date: "2025-12-31").isEmpty)
    }

    func testUnknownDatesOnlyAppearInUnfilteredBrowseAndRelatedTextCanDateAsset() {
        let assets: [[String: Any]] = [["id": "unknown"], ["id": "related"]]
        let text = Record(raw: ["id": "t", "audioAssetIDs": ["related"], "start": "2026-10-26T12:00:00+08:00"])
        XCTAssertEqual(AudioCatalog.records(assets: assets, textRecords: [text]).count, 2)
        XCTAssertEqual(AudioCatalog.records(assets: assets, textRecords: [text], date: "2026-10-26").map(\.id), ["related"])
    }

    func testCrossDayTimelineExcludedFromDailyPackageAndMetadataPreserved() {
        let asset: [String: Any] = ["id": "cross", "start": "2026-10-26T23:00:00+08:00", "status": "available",
            "timeline": [["recordedStart": "2026-10-26T23:00:00+08:00"], ["recordedStart": "2026-10-27T01:00:00+08:00"]]]
        XCTAssertEqual(AudioCatalog.records(assets: [asset], textRecords: []).first?.status, "available")
        XCTAssertTrue(AudioCatalog.records(assets: [asset], textRecords: [], date: "2026-10-26").isEmpty)
        XCTAssertTrue(AudioCatalog.records(assets: [asset], textRecords: [], date: "2026-10-27").isEmpty)
    }

    func testSingleSpanCrossingMidnightUsesSourceOffset() {
        let crossing: [String: Any] = ["id": "crossing", "timeline": [
            ["recordedStart": "2026-10-26T23:59:00+14:00", "fileStart": 15, "fileEnd": 135]]]
        let sameDay: [String: Any] = ["id": "same", "timeline": [
            ["recordedStart": "2026-10-26T00:00:00-12:00", "fileStart": 15, "fileEnd": 135]]]
        XCTAssertTrue(AudioCatalog.records(assets: [crossing], textRecords: [], date: "2026-10-26").isEmpty)
        XCTAssertEqual(AudioCatalog.records(assets: [sameDay], textRecords: [], date: "2026-10-26").map(\.id), ["same"])
        XCTAssertEqual(AudioCatalog.records(assets: [crossing], textRecords: []).count, 1)
    }

    func testAssetDurationCrossingMidnightUsesSourceOffset() {
        let crossing: [String: Any] = ["id": "crossing", "start": "2026-10-26T23:59:00.000-12:00", "durationSeconds": 120]
        let sameDay: [String: Any] = ["id": "same", "start": "2026-10-26T00:00:00+14:00", "durationSeconds": 120]
        XCTAssertTrue(AudioCatalog.records(assets: [crossing], textRecords: [], date: "2026-10-26").isEmpty)
        XCTAssertEqual(AudioCatalog.records(assets: [sameDay], textRecords: [], date: "2026-10-26").map(\.id), ["same"])
    }
}
