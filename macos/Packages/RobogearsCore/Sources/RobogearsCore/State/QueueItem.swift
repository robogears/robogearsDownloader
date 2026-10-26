import Foundation

/// One row of the review queue.
public struct QueueItem: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case tidal, spotify, importList, search }

    /// What a library check found (decision 4, area 3).
    public struct LibraryMatch: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case exact, similar }
        public var kind: Kind
        public var path: String
        public var libraryTitle: String
        public init(kind: Kind, path: String, libraryTitle: String) {
            self.kind = kind; self.path = path; self.libraryTitle = libraryTitle
        }
    }

    /// Whether the TIDAL match exists and can be trusted.
    public enum Match: Codable, Equatable, Sendable {
        case matched
        /// TIDAL searched and nothing fitted.
        case notOnTIDAL
        /// The lookup itself failed (busy, offline): Match Again can fix it.
        case couldNotCheck(reason: String)
        /// The title matched but TIDAL credits another artist; left out until + Add.
        case differentArtist(tidalArtist: String)
    }

    /// Where the row is in downloading. Only `waiting` and `failed` survive a
    /// restart: a crash mid-batch brings unfinished rows back as waiting.
    public enum DownloadState: Codable, Equatable, Sendable {
        case waiting
        /// In a running batch, not started yet.
        case queued
        case downloading(percent: Int)
        case done(quality: String)
        case skipped(reason: String)
        /// Kept across restarts with its reason (decision 4, item 2.9).
        case failed(reason: String)
    }

    public let id: UUID
    public var tidalID: Int64?
    public var title: String
    public var version: String?
    public var artist: String
    public var album: String?
    public var durationSeconds: Int?
    public var isrc: String?
    public var hiRes: Bool
    public var explicit: Bool
    public var source: Source
    /// The text the person brought (Spotify or a CSV), shown as a quiet second
    /// line when it differs from what TIDAL will save (decision 4, item 4.14).
    public var originalTitle: String?
    public var originalArtist: String?
    /// The length the source gave (Spotify's, or a CSV's duration column) for
    /// a row matched to a TIDAL track, shown with the second line so a big
    /// gap from TIDAL's length hints at a different version (decision 4,
    /// item 4.14). Nil for TIDAL's own rows, for rows not found (their
    /// `durationSeconds` is already the source's), and in older saved queues.
    public var originalDurationSeconds: Int?
    public var match: Match
    public var libraryMatch: LibraryMatch?
    /// Exact library matches start left out; the person can + Add them.
    public var included: Bool
    public var state: DownloadState
    /// Whether TIDAL's track details list a lossless version: false shows the
    /// AAC badge before downloading (decision 4, item 2.10). Nil when unknown,
    /// and in queues saved before the field existed.
    public var losslessOnTIDAL: Bool?
    /// What the row's latest download did, beside `state`'s words: the file
    /// it concerns, so the row can offer Show in Finder, Replace (2.3),
    /// Save As… (2.6) or Move the old .m4a to Trash (2.10). Nil until a batch
    /// finishes the row, and again once the row goes back to waiting.
    public var lastOutcome: TrackDownloadOutcome?
    /// True while the row waits for the library index to finish (D4 4.20):
    /// it shows "Checking library…", and Download All holds it until the
    /// mark is filled in, so no row is ever sent unchecked (rule 4). Nil
    /// (or false) once checked. Optional so queues saved before this field
    /// existed load unchanged.
    public var libraryCheckPending: Bool?

    /// Whether the row still waits for its library check (D4 4.20).
    public var isLibraryCheckPending: Bool { libraryCheckPending == true }

    public init(id: UUID = UUID(), tidalID: Int64?, title: String, version: String? = nil, artist: String,
                album: String? = nil, durationSeconds: Int? = nil, isrc: String? = nil, hiRes: Bool = false,
                explicit: Bool = false, source: Source, originalTitle: String? = nil, originalArtist: String? = nil,
                match: Match = .matched, libraryMatch: LibraryMatch? = nil, included: Bool? = nil,
                state: DownloadState = .waiting, losslessOnTIDAL: Bool? = nil, lastOutcome: TrackDownloadOutcome? = nil) {
        self.id = id
        self.tidalID = tidalID
        self.title = title
        self.version = version
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.isrc = isrc
        self.hiRes = hiRes
        self.explicit = explicit
        self.source = source
        self.originalTitle = originalTitle
        self.originalArtist = originalArtist
        self.match = match
        self.libraryMatch = libraryMatch
        // Library review happens in the queue (product rule 4): an exact match
        // starts greyed out; a similar one stays included with a warning.
        self.included = included ?? (libraryMatch?.kind != .exact)
        self.state = state
        self.losslessOnTIDAL = losslessOnTIDAL
        self.lastOutcome = lastOutcome
    }

    /// Rows that Download All sends: matched, included, not already done,
    /// and library-checked; a row still waiting for its check is held so
    /// nothing goes out unchecked (D4 4.20, rule 4).
    public var isDownloadable: Bool {
        guard tidalID != nil, case .matched = match, included, !isLibraryCheckPending else { return false }
        switch state {
        case .waiting, .failed: return true
        default: return false
        }
    }

    /// The form a row takes on disk: in-flight states fall back to waiting so
    /// a crash or quit never strands a row as "downloading" or loses it.
    public var persisted: QueueItem {
        var copy = self
        switch state {
        case .queued, .downloading: copy.state = .waiting
        default: break
        }
        return copy
    }

    /// What a download of this row asks for, copied now so later edits to
    /// the row can't change a download in flight. Nil without a TIDAL track.
    /// `folder` is the batch's folder, kept to the end of the batch (2.17).
    public func downloadRequest(folder: URL, replaceExisting: Bool = false) -> TrackDownloadRequest? {
        guard let tidalID else { return nil }
        return TrackDownloadRequest(rowID: id, tidalID: tidalID, title: title, version: version, artist: artist,
                                    album: album, durationSeconds: durationSeconds, isrc: isrc, expectsHiRes: hiRes,
                                    losslessOnTIDAL: losslessOnTIDAL, folder: folder, replaceExisting: replaceExisting)
    }

    /// The row's download line in plain words (2.9): "Saved Blue Lantern.flac,
    /// 24-bit / 96 kHz", "Already in your download folder", a failure's
    /// reason. Nil while the row waits or downloads; the UI labels those.
    public var downloadMessage: String? {
        switch state {
        case .waiting, .queued, .downloading:
            return nil
        case .done(let quality):
            if let lastOutcome { return DownloadBatch.message(for: lastOutcome) }
            return "Saved, \(quality)"
        case .skipped(let reason), .failed(let reason):
            return reason
        }
    }
}
