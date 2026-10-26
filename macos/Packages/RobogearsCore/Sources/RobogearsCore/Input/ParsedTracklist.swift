// The result of reading a CSV, a Music export or a pasted list.

import Foundation

public struct ParsedTracklist: Sendable, Hashable {
    /// How the text was read, so the import summary can show it ("Columns:
    /// Track Name → title, Artist Name(s) → artist") and a wrong pick is
    /// visible at once (G4-5 skeptic).
    public let format: Format
    /// Tracks and links in the order they appear.
    public let items: [Item]

    public init(format: Format, items: [Item]) {
        self.format = format
        self.items = items
    }

    /// The song lines, in order.
    public var entries: [Entry] {
        items.compactMap { if case .track(let entry) = $0 { entry } else { nil } }
    }

    /// The link lines, in order. A list of links is added as links rather
    /// than searched as song names (G4-14).
    public var links: [ParsedInput] {
        items.compactMap { if case .link(let link) = $0 { link } else { nil } }
    }

    public var isEmpty: Bool { items.isEmpty }
}

extension ParsedTracklist {
    public enum Item: Sendable, Hashable {
        case track(Entry)
        /// A line holding a link: supported or not, it is never searched.
        case link(ParsedInput)
    }

    /// One way of reading a line as a title and an artist.
    public struct Reading: Sendable, Hashable {
        public let title: String
        /// Empty when the line names no artist.
        public let artist: String

        public init(title: String, artist: String) {
            self.title = title
            self.artist = artist
        }
    }

    /// One song to look up on TIDAL.
    public struct Entry: Sendable, Hashable {
        /// The possible readings, best guess first, never empty. A CSV with a
        /// header has exactly one. A pasted "A - B" line has both orders, so
        /// the matcher can score each against the same search results and
        /// keep the best; ties go to the earlier reading (G4-6 and its
        /// skeptic: every spaced separator, both orders, Title - Artist
        /// first).
        public let readings: [Reading]
        /// What to search TIDAL for: one search per line, using all its words.
        public let searchText: String
        /// The recording's ISRC when the file has one, for an exact lookup
        /// before any search (G4-5).
        public let isrc: String?
        /// Length in seconds when the file has a duration column, to help
        /// rank candidates (G4-5).
        public let duration: TimeInterval?

        /// Nil when `readings` is empty: an entry always has a best guess, and
        /// app code building one gets a nil to handle rather than a crash.
        public init?(readings: [Reading], searchText: String, isrc: String? = nil, duration: TimeInterval? = nil) {
            guard !readings.isEmpty else { return nil }
            self.readings = readings
            self.searchText = searchText
            self.isrc = isrc
            self.duration = duration
        }

        /// The best-guess title.
        public var title: String { readings[0].title }
        /// The best-guess artist.
        public var artist: String { readings[0].artist }
    }

    public enum Delimiter: String, Sendable, Hashable, CaseIterable {
        case comma = ","
        case semicolon = ";"
        case tab = "\t"

        var scalar: Unicode.Scalar {
            switch self {
            case .comma: ","
            case .semicolon: ";"
            case .tab: "\t"
            }
        }
    }

    /// The columns chosen from a header row, by their header text as written.
    public struct Columns: Sendable, Hashable {
        public let delimiter: Delimiter
        public let title: String
        public let artist: String?
        public let isrc: String?
        public let duration: String?

        public init(delimiter: Delimiter, title: String, artist: String?, isrc: String?, duration: String?) {
            self.delimiter = delimiter
            self.title = title
            self.artist = artist
            self.isrc = isrc
            self.duration = duration
        }
    }

    public enum Format: Sendable, Hashable {
        /// A table with a recognised header row.
        case table(Columns)
        /// Lines of 2–4 fields with no header ("Title, Artist", or rows copied
        /// from a web table).
        case headerlessColumns(Delimiter)
        /// One song per line, split at spaced separators.
        case plainText
    }
}
