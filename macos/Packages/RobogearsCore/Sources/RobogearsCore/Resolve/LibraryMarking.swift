import Foundation

/// The library verdict for a new row (product rule 4, D4 area 3).
public enum LibraryMark: Sendable, Equatable {
    /// The library index isn't ready yet (a scan is running, or the library
    /// can't be read and no index was saved): the row is added at once,
    /// marked "Checking library…", and filled in later (D4 4.20).
    case pending
    /// Checked: nil when nothing in the library matches, or when there is no
    /// library to check.
    case checked(QueueItem.LibraryMatch?)
}

/// Where the resolver gets library marks. Injected, so rows can be marked
/// without the resolver owning the scanner; never writes to the library.
public protocol LibraryMarking: Sendable {
    func mark(for query: LibraryMatcher.Query) async -> LibraryMark
}

extension LibraryIndexService: LibraryMarking {
    /// Pending while the index can't be trusted (`LibraryMarks.indexIsUsable`);
    /// otherwise the current index decides, and no folder means no mark.
    public func mark(for query: LibraryMatcher.Query) -> LibraryMark {
        guard LibraryMarks.indexIsUsable(status: status, hasIndex: matcherIndex != nil) else { return .pending }
        return .checked(match(query).map(QueueItem.LibraryMatch.init))
    }
}

/// No library folder chosen: nothing is ever marked.
public struct NoLibrary: LibraryMarking {
    public init() {}
    public func mark(for query: LibraryMatcher.Query) -> LibraryMark { .checked(nil) }
}

public enum LibraryMarks {
    /// Whether the library service's index can mark a new row now.
    ///
    /// - A scan is running (the launch scan, a Refresh or a new folder): no,
    ///   so no row is checked against a half-read index (D4 4.20).
    /// - A folder is chosen but can't be read (a missing drive, refused
    ///   access, a failed scan): only with a saved index, whose marks stand
    ///   (D4 3.9). With none, nothing has been checked, so the row waits as
    ///   "Checking library…" and Download All holds it, rather than passing as
    ///   "not in your library" and downloading a song you own (rule 4; D4 3.8:
    ///   "a missing drive … so every row looks new").
    /// - No folder, or a finished scan: yes.
    static func indexIsUsable(status: LibraryIndexService.Status, hasIndex: Bool) -> Bool {
        switch status {
        case .scanning: false
        case .unavailable, .failed: hasIndex
        case .off, .ready: true
        }
    }

    /// What the library check compares for a TIDAL track: what will be saved,
    /// with TIDAL's artist list kept whole (D4 4.14, 3.3).
    static func query(for track: TIDALQueueTrack) -> LibraryMatcher.Query {
        LibraryMatcher.Query(
            title: track.title, edition: track.version,
            artists: track.artists.isEmpty ? .unknown : .names(track.artists),
            durationSeconds: track.duration.map(Double.init), isrc: track.isrc
        )
    }

    /// What the library check compares for a row that is already built. The
    /// artist list was joined into one line, so it is read as free text.
    static func query(for row: QueueItem) -> LibraryMatcher.Query {
        LibraryMatcher.Query(
            title: row.title, edition: row.version,
            artists: row.artist.isEmpty ? .unknown : .text(row.artist),
            durationSeconds: row.durationSeconds.map(Double.init), isrc: row.isrc
        )
    }

    /// Puts a mark on a row. An exact library match leaves the row out until
    /// + Add (rule 4); any other mark keeps the row's own choice, so a Leave
    /// Out made while the library was still being checked stands (D4 3.9).
    static func apply(_ mark: LibraryMark, to row: inout QueueItem) {
        switch mark {
        case .pending:
            row.libraryMatch = nil
            row.libraryCheckPending = true
        case let .checked(match):
            row.libraryMatch = match
            row.libraryCheckPending = nil
            if match?.kind == .exact { row.included = false }
        }
    }

    /// Fills in the rows marked "Checking library…" once the index is ready
    /// (D4 4.20). Other rows come back untouched; rows whose index still
    /// isn't ready stay pending. Ids and order are kept.
    public static func fillPending(_ items: [QueueItem], using library: any LibraryMarking) async -> [QueueItem] {
        var result = items
        for index in result.indices where result[index].isLibraryCheckPending {
            let mark = await library.mark(for: query(for: result[index]))
            if case .checked = mark { apply(mark, to: &result[index]) }
        }
        return result
    }
}
