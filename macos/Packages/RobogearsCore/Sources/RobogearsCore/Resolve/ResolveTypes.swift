import Foundation

// The resolver's public vocabulary: what the person brought, what comes back
// while it is matched, and how it ends. The app's window maps these to its
// own types in a few lines (core can't see the app's AddSource / AddEvent).

/// What the person brought to the queue.
public enum ResolveSource: Sendable, Hashable {
    /// A TIDAL or Spotify link typed, pasted or dropped. Words around the
    /// link are ignored (`InputParser`).
    case link(String)
    /// One pasted line naming a song: "Blue Lantern - Placeholder Artist",
    /// "Blue Lantern | Placeholder Artist" or "Blue Lantern, Placeholder
    /// Artist". It is matched and added directly, both orders tried (D4 4.7,
    /// 4.6).
    case line(String)
    /// A pasted list or a tracklist's text, with the file's name when it came
    /// from a file. Links inside it are added as links (D4 4.13).
    case tracklist(text: String, name: String?)
    /// A dropped or opened file's bytes, decoded here whatever the encoding
    /// (D4 4.17) and refused when they aren't text (D4 4.8).
    case tracklistFile(Data, name: String)
}

/// What a paste or a Return in the main field should do, decided before
/// anything is sent (D4 4.1, 4.2, 4.7, 4.13).
public enum AddRoute: Sendable, Hashable {
    case nothing
    /// Hand this to `TrackResolver.add`.
    case add(ResolveSource)
    /// Open search results for this text (or, for a paste, put it in the
    /// search field ready for Return). `looksLikeID` lets "no results" say
    /// "Paste its link instead" (D4 4.1).
    case search(query: String, looksLikeID: Bool)
    /// A link the app can't use, refused with what to do instead (D4 4.2).
    /// Nothing is searched.
    case refuse(String)

    /// ⌘V outside a text field (D4 4.7): several lines import as a list, one
    /// link is added, one line with a separator ("Blue Lantern - Placeholder
    /// Artist", or a comma) is matched and added directly, and one line
    /// without a separator goes to the search field.
    public static func forPaste(_ text: String) -> AddRoute {
        route(text, singleLineWithSeparatorAdds: true)
    }

    /// Return in the main field: a link is added, anything else searches,
    /// numbers included (D4 4.1). A multi-line paste into the field is read
    /// as a list rather than squashed into one line (D4 4.13).
    public static func forField(_ text: String) -> AddRoute {
        route(text, singleLineWithSeparatorAdds: false)
    }

    private static func route(_ text: String, singleLineWithSeparatorAdds: Bool) -> AddRoute {
        let trimmed = text.trimmingCharacters(in: InputParser.trimSet)
        guard !trimmed.isEmpty else { return .nothing }
        let lines = DelimitedText.lines(Substring(trimmed)).filter { !TracklistParser.isBlank($0) }
        if lines.count > 1 { return .add(.tracklist(text: trimmed, name: nil)) }
        switch InputParser.parse(trimmed) {
        case .empty:
            return .nothing
        case .tidal, .spotify, .spotifyShortLink:
            return .add(.link(trimmed))
        case let .unsupported(link):
            return .refuse(ResolveMessages.unsupported(link))
        case let .search(query, looksLikeID):
            if singleLineWithSeparatorAdds, hasSeparator(query) { return .add(.line(query)) }
            return .search(query: query, looksLikeID: looksLikeID)
        }
    }

    /// A spaced dash or bar, a tab, or a comma: the line names a title and an
    /// artist.
    static func hasSeparator(_ line: String) -> Bool {
        PlainTextLine.hasSpacedSeparator(Substring(line)) || line.contains("\t") || line.contains(",")
    }
}

/// What the queue already holds, so an add can skip what's there and its
/// summary can say so ("40 were already in the queue", D4 4.9), and so Try
/// Again after a lost connection doesn't add the same rows twice.
public struct QueueContents: Sendable, Hashable {
    public var tidalIDs: Set<Int64>
    /// Rows without a TIDAL track (not found, couldn't check), by their text.
    var unmatchedKeys: Set<String>

    public init(_ items: [QueueItem]) {
        tidalIDs = Set(items.compactMap(\.tidalID))
        unmatchedKeys = Set(items.filter { $0.tidalID == nil }.map(Self.unmatchedKey))
    }

    public static let empty = QueueContents([])

    func contains(_ row: QueueItem) -> Bool {
        if let id = row.tidalID { return tidalIDs.contains(id) }
        return unmatchedKeys.contains(Self.unmatchedKey(row))
    }

    static func unmatchedKey(_ row: QueueItem) -> String {
        Normalizer.fullKey(row.title) + "|" + Normalizer.fullKey(row.artist)
    }
}

/// How far an add has got.
public enum ResolveProgress: Sendable, Equatable {
    /// "Loading 300 of 1,250 tracks…": a TIDAL album or playlist arriving
    /// page by page, or the links of a pasted list being read. `total` is nil
    /// until known (D4 4.21).
    case loading(done: Int, total: Int?)
    /// "Matching 34 of 100 tracks on TIDAL…": Spotify tracks or tracklist
    /// lines being matched, counted as each finishes (D4 4.21).
    case matching(done: Int, total: Int)
}

/// What an add sends while it runs.
public enum ResolveEvent: Sendable, Equatable {
    case progress(ResolveProgress)
    /// Rows for the queue, in source order, as they are made, so Cancel keeps
    /// what is finished (D4 4.9). Already de-duplicated against the queue and
    /// within the add, with library marks filled in or marked "Checking
    /// library…" (D4 4.20).
    case rows([QueueItem])
    /// Spotify only shared the first 100 tracks of a playlist (D4 4.4): show
    /// the message with Open Exportify.
    case capped(SpotifyCapNotice)
    /// A detail line for the activity log only, such as the server's status
    /// for a failed lookup. Never shown on a row; never a token or link.
    case log(String)
    /// The add ended, completely or stopped by `ResolveJob.stop()`.
    case finished(ResolveSummary)
    /// The add couldn't go on. Rows already sent stay; the failure says what
    /// happened and, when `retry` is set, Try Again runs it again.
    case failed(ResolveFailure)
}

/// One running add. Iterate it for events; it ends with `.finished` or
/// `.failed`.
public struct ResolveJob: AsyncSequence, Sendable {
    public typealias Element = ResolveEvent
    public typealias AsyncIterator = AsyncStream<ResolveEvent>.Iterator

    public let events: AsyncStream<ResolveEvent>
    private let stopper: @Sendable () -> Void

    init(events: AsyncStream<ResolveEvent>, stop: @escaping @Sendable () -> Void) {
        self.events = events
        self.stopper = stop
    }

    public func makeAsyncIterator() -> AsyncStream<ResolveEvent>.Iterator { events.makeAsyncIterator() }

    /// Cancel on the adding cover, Escape or ⌘. (D4 4.9, 4.18): requests in
    /// flight stop at once (D4 1.11), rows already finished are still sent,
    /// then `.finished` with `stopped` set. Ending the iteration instead (by
    /// cancelling the task that reads it) stops everything without a summary.
    public func stop() { stopper() }
}

/// How an add went, for its one summary line (D4 4.2, 4.9).
public struct ResolveSummary: Sendable, Equatable {
    public enum Unit: Sendable, Equatable { case tracks, lines }

    /// "link", the album or playlist's name, "Exportify CSV", a file's name,
    /// or "pasted text" (D4 4.2).
    public var sourceName: String
    /// Whether counts are of tracks (links) or lines (a tracklist).
    public var unit: Unit
    /// Rows sent to the queue.
    public var added = 0
    /// Of those, rows with a TIDAL track (including ones left out for a
    /// different artist).
    public var found = 0
    public var notOnTIDAL = 0
    public var couldNotCheck = 0
    /// Left out with "Different artist on TIDAL" (D4 3.2).
    public var differentArtist = 0
    public var alreadyInQueue = 0
    /// Matched the same TIDAL track as another row of this add.
    public var sameTIDALTrack = 0
    /// Music videos on a TIDAL album or playlist, which aren't added.
    public var videosSkipped = 0
    /// Links in a pasted list that couldn't be added, with why (D4 4.13).
    public var skippedLinks: [SkippedLink] = []
    /// The columns a CSV was read with: "Columns: Track Name → title, Artist
    /// Name(s) → artist" (D4 4.5).
    public var columns: ParsedTracklist.Columns?
    /// Stopped by Cancel before the end.
    public var stopped = false
    /// Tracks or lines handled so far, and how many there were, when known.
    public var processed = 0
    public var total: Int?

    public init(sourceName: String, unit: Unit = .tracks) {
        self.sourceName = sourceName
        self.unit = unit
    }

    /// The sentence for the activity log and the end of the adding cover.
    public var message: String { ResolveMessages.summary(self) }
}

/// A link in a pasted or dropped list that wasn't added.
public struct SkippedLink: Sendable, Equatable {
    public var link: String
    /// Why, in the words a refusal of that link alone would use.
    public var reason: String

    public init(link: String, reason: String) {
        self.link = link
        self.reason = reason
    }
}

/// Spotify only shares the first 100 tracks of a playlist (D4 4.4).
public struct SpotifyCapNotice: Sendable, Equatable {
    public var playlistName: String
    /// Tracks Spotify's page listed.
    public var listed: Int
    /// The playlist's real length, when Spotify's page says it.
    public var total: Int?
    /// D4 4.4's wording, shown with an Open Exportify button.
    public var message: String
}

/// Why an add, a search or a lookup stopped.
public struct ResolveFailure: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// No connection, or something on the network answered instead of
        /// TIDAL or Spotify (D4 1.7).
        case offline
        /// Not signed in to TIDAL (D4 1.1).
        case signInNeeded
        /// TIDAL refused the stored sign-in (D4 1.6).
        case signInInvalid
        /// The stored sign-in couldn't be read.
        case signInUnreadable
        /// TIDAL or Spotify kept answering "too many requests" or a server
        /// error after the retries (D4 1.4).
        case busy
        /// A link the app can't use (D4 4.2).
        case unsupportedLink
        /// The text holds no link at all; it should be searched instead.
        case notALink
        /// TIDAL doesn't offer this track, album or playlist.
        case notAvailable
        /// TIDAL refused to open the link.
        case refusedByTIDAL
        /// Spotify won't share the page (private, deleted or region-blocked).
        case spotifyRefused
        /// Spotify's page or TIDAL's answer didn't carry what the app reads.
        case unreadable
        /// A spotify.link short link that isn't a plain forward to a Spotify
        /// track, album or playlist (D4 4.3).
        case shortLink
        /// A dropped file that isn't text (D4 4.8).
        case notText
        /// A list or file with no songs and no links.
        case empty
    }

    public var kind: Kind
    /// What happened and what to do, ready to show.
    public var message: String
    /// What Try Again runs: the source exactly as the person pasted or
    /// dropped it (D4 1.7). Nil when trying again can't help.
    public var retry: ResolveSource?
    /// What was added before it stopped, when anything was.
    public var summary: ResolveSummary?

    public init(kind: Kind, message: String, retry: ResolveSource? = nil, summary: ResolveSummary? = nil) {
        self.kind = kind
        self.message = message
        self.retry = retry
        self.summary = summary
    }

    /// Whether running the same source again can succeed once the cause has
    /// passed (a connection back, a sign-in, a quieter TIDAL).
    public var isRetryable: Bool {
        switch kind {
        case .offline, .signInNeeded, .signInInvalid, .signInUnreadable, .busy: true
        default: false
        }
    }
}

/// One TIDAL search result, as the row it would become (D4 4.11).
public struct SearchHit: Sendable, Equatable, Identifiable {
    /// The ready row: its library mark is filled in, or it is marked
    /// "Checking library…" (D4 4.20). An exact library match arrives greyed
    /// with + Add, as in the queue (rule 4).
    public var item: QueueItem
    /// Already in the queue: shown "In Queue" and can't be ticked.
    public var inQueue: Bool

    public var id: Int64 { item.tidalID ?? 0 }
}

public struct SearchResults: Sendable, Equatable {
    public var query: String
    /// Up to ten, in TIDAL's order.
    public var hits: [SearchHit]
    /// What to show instead of an empty list (D4 4.11, 4.1).
    public var emptyMessage: String?
}
