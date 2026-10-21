// Choosing columns from a tracklist's header row, and reading duration and
// ISRC values.
//
// The Electron app took the first header containing "name" as the title and
// the first containing "artist" as the artist, so "Artist Name, Track Name"
// searched artists as titles and an "Artist URI(s)" column became the artist
// (renderer-queue-and-flows.md §18; decision card G4-5). Now exact known
// names are tried in priority order before any loose rule, and the loose rule
// never picks a URI, ID, number, count, duration, time, date, disc or year
// column as the title (G4-5 skeptic).

import Foundation

enum TracklistColumns {
    /// Exact header names for the title, best first. Exportify writes "Track
    /// Name"; Music's export writes "Name".
    static let exactTitleNames = [
        "track name", "track title", "title", "song name", "song title", "song", "track", "name",
    ]

    /// Exact header names for the artist, best first; "(s)" is removed before
    /// comparing, so Exportify's "Artist Name(s)" is "artist name".
    static let exactArtistNames = [
        "artist name", "artist names", "artists", "artist", "track artist", "album artist",
    ]

    private static let looseTitleWords: Set<String> = ["title", "song", "name", "track"]
    private static let looseArtistWords: Set<String> = ["artist", "artists"]

    /// Words that rule a column out as the title, even under the loose rule.
    private static let notTitleWords: Set<String> = [
        "artist", "artists", "album", "playlist", "uri", "uris", "url", "urls", "id", "ids",
        "number", "no", "count", "duration", "time", "date", "disc", "year", "isrc", "length",
        "ms", "composer", "genre", "genres", "label",
    ]

    private static let notArtistWords: Set<String> = ["uri", "uris", "url", "urls", "id", "ids"]

    private static let notDurationWords: Set<String> = ["date", "added", "modified", "played", "skipped", "last"]

    /// Lowercased, "(s)" removed, underscores as spaces, whitespace collapsed.
    static func normalizeHeader(_ raw: String) -> String {
        let lowered = raw.lowercased()
            .replacingOccurrences(of: "(s)", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return lowered.split(whereSeparator: { $0.isWhitespace || $0 == "\u{FEFF}" }).joined(separator: " ")
    }

    static func words(_ normalized: String) -> Set<String> {
        Set(normalized.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
    }

    /// Whether a header row names a title or artist column exactly. Only then
    /// is the first line treated as a header, so a pasted song list whose
    /// first line happens to contain "name" isn't swallowed (G4-5).
    static func looksLikeHeader(_ fields: [String]) -> Bool {
        guard fields.count >= 2 else { return false }
        let names = Set(fields.map(normalizeHeader))
        return exactTitleNames.contains(where: names.contains) || exactArtistNames.contains(where: names.contains)
    }

    struct Choice {
        var title: Int
        var artist: Int?
        var isrc: Int?
        var duration: Int?
        var durationUnit: DurationUnit
    }

    /// Picks columns for a header and its data rows; nil when no title
    /// column can be found.
    static func choose(header: [String], rows: [[String]]) -> Choice? {
        let normalized = header.map(normalizeHeader)
        let headerWords = normalized.map(words)

        var titleCandidates: [Int] = []
        for name in exactTitleNames {
            for (index, header) in normalized.enumerated() where header == name && !titleCandidates.contains(index) {
                titleCandidates.append(index)
            }
        }
        for (index, words) in headerWords.enumerated()
        where !titleCandidates.contains(index) && !words.isDisjoint(with: looseTitleWords) && words.isDisjoint(with: notTitleWords) {
            titleCandidates.append(index)
        }
        // "Track" can mean the track number; skip a column whose values are
        // all numbers.
        guard let title = titleCandidates.first(where: { !columnIsNumeric($0, rows: rows) }) else { return nil }

        var artistCandidates: [Int] = []
        for name in exactArtistNames {
            for (index, header) in normalized.enumerated() where header == name && !artistCandidates.contains(index) {
                artistCandidates.append(index)
            }
        }
        for (index, words) in headerWords.enumerated()
        where !artistCandidates.contains(index) && !words.isDisjoint(with: looseArtistWords) && words.isDisjoint(with: notArtistWords) {
            artistCandidates.append(index)
        }
        let artist = artistCandidates.first(where: { $0 != title })

        let isrc = headerWords.firstIndex(where: { $0.contains("isrc") })

        let duration = normalized.indices.first { index in
            let w = headerWords[index]
            let named = w.contains("duration") || w.contains("length") || normalized[index] == "time"
            return named && w.isDisjoint(with: notDurationWords) && index != title && index != artist
        }
        let unit = duration.map { durationUnit(header: normalized[$0], words: headerWords[$0]) } ?? .automatic

        return Choice(title: title, artist: artist, isrc: isrc, duration: duration, durationUnit: unit)
    }

    private static func columnIsNumeric(_ index: Int, rows: [[String]]) -> Bool {
        var sawValue = false
        for row in rows where index < row.count {
            let value = row[index].trimmingCharacters(in: InputParser.trimSet)
            if value.isEmpty { continue }
            sawValue = true
            if !InputParser.isASCIIDigits(value) { return false }
        }
        return sawValue
    }

    // MARK: - Values

    enum DurationUnit: Equatable {
        case milliseconds, seconds, automatic
    }

    /// Exportify's duration is in milliseconds ("Duration (ms)"); Music's
    /// "Time" is in seconds; other tools write m:ss (G4-5 skeptic).
    private static func durationUnit(header: String, words: Set<String>) -> DurationUnit {
        if !words.isDisjoint(with: ["ms", "millisecond", "milliseconds"]) { return .milliseconds }
        if !words.isDisjoint(with: ["s", "sec", "secs", "second", "seconds"]) || header == "time" { return .seconds }
        return .automatic
    }

    /// Seconds from "215000" (ms), "215" (s), "3:35" or "1:02:03". Plain
    /// numbers in a column of unknown unit are milliseconds from 10000 up; no
    /// song is that many seconds long, and no song is under ten seconds.
    static func parseDuration(_ raw: String, unit: DurationUnit) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: InputParser.trimSet)
        guard !value.isEmpty else { return nil }
        if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count) else { return nil }
            var total = 0.0
            for part in parts {
                guard let number = Double(part), number >= 0 else { return nil }
                total = total * 60 + number
            }
            return total > 0 ? total : nil
        }
        guard let number = Double(value), number > 0, number.isFinite else { return nil }
        switch unit {
        case .milliseconds: return number / 1000
        case .seconds: return number
        case .automatic: return number >= 10_000 ? number / 1000 : number
        }
    }

    /// An ISRC is two letters, three letters or digits, then seven digits;
    /// files often write it with hyphens or spaces.
    static func parseISRC(_ raw: String) -> String? {
        let compact = raw.uppercased().filter { $0 != "-" && $0 != " " }
        let bytes = Array(compact.utf8)
        guard bytes.count == 12 else { return nil }
        func isLetter(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        guard bytes[0..<2].allSatisfy(isLetter),
              bytes[2..<5].allSatisfy({ isLetter($0) || isDigit($0) }),
              bytes[5..<12].allSatisfy(isDigit) else { return nil }
        return compact
    }
}
