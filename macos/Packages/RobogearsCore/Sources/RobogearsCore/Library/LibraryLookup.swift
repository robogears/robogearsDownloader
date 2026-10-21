import Foundation

// Joins the scanner's saved index to the matcher: the scanner knows files and
// their tags, the matcher knows how to compare them with an incoming track.

extension LibraryFile {
    /// The matcher's view of this file. An online-only file that wasn't read
    /// still matches by its file name, which never gives more than "similar"
    /// (the v0.1.24 rule), so an unread cloud file can't hide a download.
    public var matcherEntry: LibraryMatcher.Entry {
        LibraryMatcher.Entry(path: path, tagTitle: tags?.title, tagArtists: tags?.artists ?? [],
                             tagDurationSeconds: tags?.durationSeconds, tagISRC: tags?.isrc)
    }
}

extension LibraryIndexSnapshot {
    /// A matcher index over every file, in the snapshot's path order.
    public func matcherIndex() -> LibraryMatcher.Index {
        LibraryMatcher.Index(entries: files.map(\.matcherEntry))
    }
}

extension QueueItem.LibraryMatch {
    /// The queue's record of a library match (product rule 4: exact rows start
    /// left out, similar rows stay in with a warning).
    public init(_ match: LibraryMatcher.Match) {
        self.init(kind: match.kind == .exact ? .exact : .similar, path: match.path, libraryTitle: match.libraryTitle)
    }
}
