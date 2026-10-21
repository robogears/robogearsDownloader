// Reading one pasted line ("Blue Lantern - Placeholder Artist") as a song.
//
// The Electron parser split at the first hyphen, dash, pipe or tab, spaced or
// not, and always read Title - Artist, so "Anti-Hero - Taylor Swift" became
// "Anti" and DJ-style Artist - Title lists came back not found
// (renderer-queue-and-flows.md §18). Decision card G4-6 with its skeptic's
// change: split only at spaced separators (" - ", " — ", " – ", " | ") or a
// tab; offer every separator position in both orders, Title - Artist first;
// remove leading list numbers; keep one-character titles when an artist is
// given. Leading timestamps in video-description lists are removed too.

import Foundation

enum PlainTextLine {
    typealias Reading = ParsedTracklist.Reading

    private static let spacedSeparators: Set<Character> = ["-", "\u{2014}", "\u{2013}", "|"]

    /// The entry for one line, or nil when nothing usable is left.
    /// `stripsTimestamp` removes a leading "0:00 " first; the caller decides
    /// from the whole list (see `stripTimestamp`).
    static func entry(_ rawLine: Substring, stripsTimestamp: Bool = false) -> ParsedTracklist.Entry? {
        var line = String(rawLine).trimmingCharacters(in: InputParser.trimSet)
        if stripsTimestamp { line = stripTimestamp(line) }
        line = stripListNumber(line)
        guard !line.isEmpty else { return nil }
        let chars = Array(line)

        var splits: [(left: String, right: String)] = []
        var separatorPositions: [Int] = []
        for index in chars.indices where isSeparator(at: index, in: chars) {
            let left = trimmed(chars[..<index])
            let right = trimmed(chars[(index + 1)...])
            guard !left.isEmpty, !right.isEmpty else { continue }
            splits.append((left, right))
            separatorPositions.append(index)
        }

        var readings: [Reading] = []
        let searchText: String
        if splits.isEmpty {
            readings.append(Reading(title: line, artist: ""))
            // "Blue Lantern by Placeholder Artist", only when the line has no
            // other separator, and after the whole line so a title such as
            // "Stand By Me" still wins a tie (G4-6 skeptic, optional part).
            if let by = lastBySplit(line) {
                readings.append(Reading(title: by.left, artist: by.right))
            }
            searchText = line
        } else {
            // Title - Artist: the artist is usually the short last part, so
            // the last separator is tried first ("Blue Lantern - Live at Home
            // - Placeholder Artist").
            for split in splits.reversed() {
                readings.append(Reading(title: split.left, artist: split.right))
            }
            // Artist - Title: the artist is the short first part, and the
            // title may carry " - Radio Edit", so the first separator first.
            for split in splits {
                readings.append(Reading(title: split.right, artist: split.left))
            }
            // A title-only list can still have a dash in a title.
            readings.append(Reading(title: line, artist: ""))
            var words = chars
            for position in separatorPositions { words[position] = " " }
            searchText = collapseSpaces(String(words))
        }

        let usable = unique(readings).filter(isUsable)
        guard !usable.isEmpty else { return nil }
        return ParsedTracklist.Entry(readings: usable, searchText: searchText)
    }

    /// A one-character title ("7") is kept when the line names an artist
    /// (G4-6); on its own it is dropped, as before.
    static func isUsable(_ reading: Reading) -> Bool {
        !reading.title.isEmpty && (reading.title.count >= 2 || !reading.artist.isEmpty)
    }

    static func unique(_ readings: [Reading]) -> [Reading] {
        var seen = Set<Reading>()
        return readings.filter { seen.insert($0).inserted }
    }

    /// Whether the line has a spaced dash or pipe (tabs not counted).
    static func hasSpacedSeparator(_ line: Substring) -> Bool {
        let chars = Array(line)
        return chars.indices.contains { chars[$0] != "\t" && isSeparator(at: $0, in: chars) }
    }

    private static func isSeparator(at index: Int, in chars: [Character]) -> Bool {
        let char = chars[index]
        if char == "\t" { return true }
        guard spacedSeparators.contains(char), index > 0, index + 1 < chars.count else { return false }
        return isSpace(chars[index - 1]) && isSpace(chars[index + 1])
    }

    private static func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\u{00A0}" || c == "\u{3000}"
    }

    private static func trimmed(_ chars: ArraySlice<Character>) -> String {
        String(chars).trimmingCharacters(in: InputParser.trimSet)
    }

    private static func collapseSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Removes "1. ", "01) " or "1<tab>" at the start of a line (G4-6 and its
    /// skeptic). A number followed only by a space ("99 Luftballons") stays.
    static func stripListNumber(_ line: String) -> String {
        var index = line.startIndex
        var digits = 0
        while index < line.endIndex, line[index].isASCII, line[index].isNumber, digits < 5 {
            index = line.index(after: index)
            digits += 1
        }
        guard (1...4).contains(digits), index < line.endIndex else { return line }
        let marker = line[index]
        var rest: Substring
        if marker == "\t" {
            rest = line[line.index(after: index)...]
        } else if marker == "." || marker == ")" {
            let afterMarker = line.index(after: index)
            guard afterMarker < line.endIndex, line[afterMarker] == " " || line[afterMarker] == "\t" else { return line }
            rest = line[afterMarker...]
        } else {
            return line
        }
        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
        return rest.isEmpty ? line : String(rest)
    }

    /// Whether the line starts with a timestamp such as "0:00", "1:02:03",
    /// "[03:41]" or "(03:41)" followed by a space, tab or dash.
    static func startsWithTimestamp(_ line: Substring) -> Bool {
        timestampEnd(in: String(line).trimmingCharacters(in: InputParser.trimSet)) != nil
    }

    /// Removes a leading timestamp and any dash or pipe after it: tracklists
    /// copied from video descriptions start every line with one ("0:00
    /// Placeholder Artist - Blue Lantern"), and G4-6 names those lists as a
    /// main source of Artist - Title lines. Only used when most lines of a
    /// list start with one, because a single line may be a title that starts
    /// with a time ("4:44 - Jay-Z", "10:15 Saturday Night - The Cure").
    static func stripTimestamp(_ line: String) -> String {
        guard let end = timestampEnd(in: line) else { return line }
        var rest = line[end...]
        func dropSpaces() { while let first = rest.first, isSpace(first) { rest = rest.dropFirst() } }
        dropSpaces()
        if let first = rest.first, spacedSeparators.contains(first) {
            rest = rest.dropFirst()
            dropSpaces()
        }
        return rest.isEmpty ? line : String(rest)
    }

    /// Where a leading timestamp ends: one or two digits, a colon and two
    /// digits, optionally ":ss", optionally in brackets, then a space, tab or
    /// dash. Nil when the line doesn't start with one.
    private static func timestampEnd(in line: String) -> String.Index? {
        let chars = Array(line)
        var i = 0
        var closer: Character?
        if let first = chars.first, first == "[" || first == "(" {
            closer = first == "[" ? "]" : ")"
            i = 1
        }
        func digits(max: Int) -> Int {
            var count = 0
            while i < chars.count, count < max, chars[i].isASCII, chars[i].isNumber { i += 1; count += 1 }
            return count
        }
        guard (1...2).contains(digits(max: 2)) else { return nil }
        guard i < chars.count, chars[i] == ":" else { return nil }
        i += 1
        guard digits(max: 2) == 2 else { return nil }
        if i < chars.count, chars[i] == ":" {
            i += 1
            guard digits(max: 2) == 2 else { return nil }
        }
        if let closer {
            guard i < chars.count, chars[i] == closer else { return nil }
            i += 1
        }
        guard i < chars.count, isSpace(chars[i]) || spacedSeparators.contains(chars[i]) else { return nil }
        return line.index(line.startIndex, offsetBy: i)
    }

    private static func lastBySplit(_ line: String) -> (left: String, right: String)? {
        guard let range = line.range(of: " by ", options: [.caseInsensitive, .backwards]) else { return nil }
        let left = line[..<range.lowerBound].trimmingCharacters(in: InputParser.trimSet)
        let right = line[range.upperBound...].trimmingCharacters(in: InputParser.trimSet)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }
}
