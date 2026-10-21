// Reads a tracklist (an Exportify CSV, a Music export, a semicolon CSV from
// Excel, rows copied from a web page, or a pasted list) into songs and links.
//
// Reference: renderer-queue-and-flows.md §18 and flow-import-and-preview.md
// §B. Behaviour changes follow decision cards G4-5 (columns by known header
// names; ISRC and duration kept), G4-6 (spaced separators, both orders),
// G4-14 (links in a list stay links), G4-15 (comma, semicolon or tab; CR, LF
// or CRLF) and the skeptic's "header-less lists" card.

import Foundation

public enum TracklistParser {
    /// Parses decoded text. Decode file bytes with `TracklistTextDecoder`
    /// first (and refuse them when `looksBinary`).
    ///
    /// Order of tries: a table whose first non-empty line is a recognised
    /// header; then lines of 2–4 fields with no header; then one song per
    /// line. Songs are de-duplicated case-insensitively on title and artist,
    /// as before.
    public static func parse(_ text: String) -> ParsedTracklist {
        var body = Substring(text)
        if body.unicodeScalars.first == "\u{FEFF}" {
            body = Substring(body.unicodeScalars.dropFirst())
        }
        let lines = DelimitedText.lines(body)
        // The header is the first non-empty line, not the first line: a blank
        // first line used to hide the header (G4-5).
        guard let first = lines.firstIndex(where: { !isBlank($0) }) else {
            return ParsedTracklist(format: .plainText, items: [])
        }
        let fromHeader = Substring(body.unicodeScalars[lines[first].startIndex...])
        if let table = parseTable(fromHeader, headerLine: lines[first]) {
            return table
        }
        return parseLines(lines[first...].filter { !isBlank($0) })
    }

    // MARK: - Table with a header row

    private static func parseTable(_ text: Substring, headerLine: Substring) -> ParsedTracklist? {
        // The delimiter is the one that splits the header into recognised
        // names; with several, the one giving the most columns.
        var best: (delimiter: ParsedTracklist.Delimiter, count: Int)?
        for delimiter in [ParsedTracklist.Delimiter.tab, .semicolon, .comma] {
            let fields = DelimitedText.fields(headerLine, delimiter: delimiter.scalar)
            guard TracklistColumns.looksLikeHeader(fields) else { continue }
            if fields.count > (best?.count ?? 0) { best = (delimiter, fields.count) }
        }
        guard let delimiter = best?.delimiter else { return nil }

        let rows = DelimitedText.rows(text, delimiter: delimiter.scalar)
        guard let header = rows.first else { return nil }
        let dataRows = Array(rows.dropFirst())
        guard let choice = TracklistColumns.choose(header: header, rows: dataRows) else { return nil }

        func cell(_ row: [String], _ index: Int?) -> String {
            guard let index, index < row.count else { return "" }
            return row[index].trimmingCharacters(in: InputParser.trimSet)
        }

        var items: [ParsedTracklist.Item] = []
        var seen = Set<String>()
        for row in dataRows {
            let title = cell(row, choice.title)
            let artist = cell(row, choice.artist)
            let reading = ParsedTracklist.Reading(title: title, artist: artist)
            guard PlainTextLine.isUsable(reading) else { continue }
            guard seen.insert(dedupeKey(reading)).inserted else { continue }
            let entry = ParsedTracklist.Entry(
                readings: [reading],
                searchText: [title, artist].filter { !$0.isEmpty }.joined(separator: " "),
                isrc: choice.isrc.flatMap { TracklistColumns.parseISRC(cell(row, $0)) },
                duration: choice.duration.flatMap { TracklistColumns.parseDuration(cell(row, $0), unit: choice.durationUnit) }
            )
            items.append(.track(entry))
        }

        func name(_ index: Int?) -> String? {
            index.map { header[$0].trimmingCharacters(in: InputParser.trimSet) }
        }
        let columns = ParsedTracklist.Columns(
            delimiter: delimiter,
            title: name(choice.title) ?? "",
            artist: name(choice.artist),
            isrc: name(choice.isrc),
            duration: name(choice.duration)
        )
        return ParsedTracklist(format: .table(columns), items: items)
    }

    // MARK: - Lines without a header

    private static func parseLines(_ lines: [Substring]) -> ParsedTracklist {
        let classified: [(line: Substring, link: ParsedInput?)] = lines.map { line in
            let parsed = InputParser.parse(String(line))
            return (line, parsed.isLink ? parsed : nil)
        }
        let textLines = classified.filter { $0.link == nil }.map(\.line)
        let layout = HeaderlessLayout.detect(textLines)

        var items: [ParsedTracklist.Item] = []
        var seenSongs = Set<String>()
        var seenLinks = Set<ParsedInput>()
        for (line, link) in classified {
            if let link {
                if seenLinks.insert(link).inserted { items.append(.link(link)) }
                continue
            }
            let entry: ParsedTracklist.Entry?
            if let layout, let fields = layout.fields(of: line) {
                entry = layout.entry(fields: fields, line: line)
            } else {
                entry = PlainTextLine.entry(line)
            }
            guard let entry, seenSongs.insert(dedupeKey(entry.readings[0])).inserted else { continue }
            items.append(.track(entry))
        }
        let format: ParsedTracklist.Format = layout.map { .headerlessColumns($0.delimiter) } ?? .plainText
        return ParsedTracklist(format: format, items: items)
    }

    // MARK: - Helpers

    static func isBlank(_ line: Substring) -> Bool {
        line.unicodeScalars.allSatisfy { InputParser.trimSet.contains($0) }
    }

    /// Case-insensitive title and artist, as the Electron parser did.
    static func dedupeKey(_ reading: ParsedTracklist.Reading) -> String {
        "\(reading.title.lowercased())|\(reading.artist.lowercased())"
    }
}

/// Lines of 2–4 fields split by a comma, semicolon or tab with no header:
/// "Blue Lantern, Placeholder Artist", or "1⇥Blue Lantern⇥Placeholder
/// Artist" copied from a web table. The Electron app read the first as a
/// title with no artist and dropped the second (skeptic card "Header-less
/// lists").
struct HeaderlessLayout {
    let delimiter: ParsedTracklist.Delimiter
    let fieldCount: Int
    /// Up to two columns holding words, in file order.
    let textColumns: [Int]
    let durationColumn: Int?
    let skipsNumberColumn: Bool

    /// Most lines (at least 80%) must have the same number of fields. A comma
    /// or semicolon list is left to the plain-text reader when half its lines
    /// already have a spaced separator, so "Ob-La-Di, Ob-La-Da - The Beatles"
    /// keeps its title.
    static func detect(_ lines: [Substring]) -> HeaderlessLayout? {
        guard !lines.isEmpty else { return nil }
        let spaced = lines.filter(PlainTextLine.hasSpacedSeparator).count
        for delimiter in [ParsedTracklist.Delimiter.tab, .semicolon, .comma] {
            if delimiter != .tab, spaced * 2 >= lines.count { continue }
            let split = lines.map { DelimitedText.fields($0, delimiter: delimiter.scalar).map(trim) }
            var histogram: [Int: Int] = [:]
            for fields in split where (2...4).contains(fields.count) { histogram[fields.count, default: 0] += 1 }
            guard let mode = histogram.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }),
                  mode.value * 10 >= lines.count * 8 else { continue }
            let count = mode.key
            let rows = split.filter { $0.count == count }

            let skipsNumberColumn = rows.allSatisfy { isListNumber($0[0]) }
            let candidates = Array((skipsNumberColumn ? 1 : 0)..<count)
            let durationColumn = candidates.first { column in
                rows.allSatisfy { $0[column].contains(":") && TracklistColumns.parseDuration($0[column], unit: .seconds) != nil }
            }
            let textColumns = candidates.filter { column in
                column != durationColumn && !rows.allSatisfy { $0[column].isEmpty || InputParser.isASCIIDigits($0[column]) }
            }
            guard !textColumns.isEmpty else { continue }
            return HeaderlessLayout(
                delimiter: delimiter,
                fieldCount: count,
                textColumns: Array(textColumns.prefix(2)),
                durationColumn: durationColumn,
                skipsNumberColumn: skipsNumberColumn
            )
        }
        return nil
    }

    /// The line's fields when it has this layout's shape; nil sends the line
    /// to the plain-text reader.
    func fields(of line: Substring) -> [String]? {
        let fields = DelimitedText.fields(line, delimiter: delimiter.scalar).map(Self.trim)
        return fields.count == fieldCount ? fields : nil
    }

    /// Both orders, Title - Artist first (G4-6). A comma line also offers the
    /// whole line as a title, so a list of titles such as "Hello, Goodbye"
    /// still matches.
    func entry(fields: [String], line: Substring) -> ParsedTracklist.Entry? {
        let parts = textColumns.map { fields[$0] }.filter { !$0.isEmpty }
        let duration = durationColumn.flatMap { TracklistColumns.parseDuration(fields[$0], unit: .seconds) }
        typealias Reading = ParsedTracklist.Reading
        var readings: [Reading] = []
        switch parts.count {
        case 2:
            readings = [Reading(title: parts[0], artist: parts[1]), Reading(title: parts[1], artist: parts[0])]
            if delimiter == .comma, !skipsNumberColumn {
                readings.append(Reading(title: Self.trim(String(line)), artist: ""))
            }
        case 1:
            // "12⇥Blue Lantern - Placeholder Artist": the one text column is
            // read like a pasted line.
            guard let single = PlainTextLine.entry(Substring(parts[0])) else { return nil }
            return ParsedTracklist.Entry(readings: single.readings, searchText: single.searchText, duration: duration)
        default:
            return nil
        }
        let usable = PlainTextLine.unique(readings).filter(PlainTextLine.isUsable)
        guard !usable.isEmpty else { return nil }
        return ParsedTracklist.Entry(readings: usable, searchText: parts.joined(separator: " "), duration: duration)
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: InputParser.trimSet)
    }

    /// "1", "01", "1." or "1)".
    private static func isListNumber(_ s: String) -> Bool {
        var digits = Substring(s)
        if let last = digits.last, last == "." || last == ")" { digits = digits.dropLast() }
        return InputParser.isASCIIDigits(digits)
    }
}
