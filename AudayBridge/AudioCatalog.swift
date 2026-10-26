import Foundation

extension Record {
    /// Both forms occur in Auday source records; keep order and remove duplicates.
    var audioAssetIDs: [String] {
        let values = (raw["audioAssetIDs"] as? [String] ?? []) + (audioAssetID.map { [$0] } ?? [])
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

enum AudioCatalog {
    /// Audio is an asset catalogue, not a `search --kind audio` record kind.
    /// Never infer a source date from the Mac's current timezone or filesystem times.
    static func records(assets: [[String: Any]], textRecords: [Record], date: String? = nil) -> [Record] {
        var seen = Set<String>()
        return assets.compactMap { asset in
            guard let id = asset["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { return nil }
            let related = textRecords.filter { $0.audioAssetIDs.contains(id) }.sorted { $0.start < $1.start }
            let timeline = asset["timeline"] as? [[String: Any]] ?? []
            let recordedStarts = timeline.compactMap { nonempty($0["recordedStart"]) }
            let assetStart = nonempty(asset["start"])
            let start = assetStart ?? recordedStarts.first ?? related.compactMap { nonempty($0.raw["start"]) }.first
            if let date, !date.isEmpty {
                guard let start, sourceDate(start) == date else { return nil }
                // An entire cross-day asset must not leak into a single-day analysis package.
                let knownAssetTimes = [assetStart, nonempty(asset["end"])].compactMap { $0 } + recordedStarts
                guard knownAssetTimes.allSatisfy({ sourceDate($0) == date }) else { return nil }
                for span in timeline {
                    if let recordedStart = nonempty(span["recordedStart"]),
                       let fileStart = (span["fileStart"] as? NSNumber)?.doubleValue,
                       let fileEnd = (span["fileEnd"] as? NSNumber)?.doubleValue {
                        guard endDate(start: recordedStart, duration: fileEnd - fileStart) == date else { return nil }
                    }
                }
                if let assetStart, let duration = (asset["durationSeconds"] ?? asset["duration"]) as? NSNumber {
                    guard endDate(start: assetStart, duration: duration.doubleValue) == date else { return nil }
                }
            }
            var raw = asset
            raw["id"] = id
            raw["kind"] = "audio"
            raw["audioAssetID"] = id
            raw["asset"] = asset
            raw["title"] = nonempty(asset["title"]) ?? related.first?.title ?? "录音"
            if let start { raw["start"] = start }
            for field in ["end", "timeZone", "status", "state"] where raw[field] == nil {
                if let value = related.first?.raw[field] { raw[field] = value }
            }
            if raw["sourceIDs"] == nil { raw["sourceIDs"] = related.map(\.id) }
            return Record(raw: raw)
        }
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
    private static func sourceDate(_ timestamp: String) -> String? {
        guard timestamp.range(of: #"^\d{4}-\d{2}-\d{2}(?:T|$)"#, options: .regularExpression) != nil else { return nil }
        return String(timestamp.prefix(10))
    }

    /// Compare an interval's end in the exact numeric offset supplied by its source.
    /// The host timezone and its daylight-saving rules never participate.
    private static func endDate(start: String, duration: Double) -> String? {
        guard duration.isFinite, duration >= 0 else { return nil }
        let offset: Int
        if start.hasSuffix("Z") {
            offset = 0
        } else {
            guard let range = start.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) else { return nil }
            let suffix = String(start[range])
            let components = suffix.dropFirst().split(separator: ":")
            guard let hours = Int(components[0]), let minutes = Int(components[1]), hours <= 23, minutes < 60 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (suffix.hasPrefix("-") ? -1 : 1)
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = parser.date(from: start)
        parser.formatOptions = [.withInternetDateTime]
        guard let beginning = parsed ?? parser.date(from: start), let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: beginning.addingTimeInterval(duration))
    }
}
