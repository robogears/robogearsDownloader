import Foundation

/// One way of reading the song a source names.
struct WantedReading: Sendable, Hashable {
    var title: String
    /// The artist text as the source wrote it, for the row's second line.
    var artistLine: String
    /// The same artists in the shape the matcher compares (D4 3.2).
    var credit: ArtistCredit
}

/// A song to find on TIDAL: a Spotify track, a tracklist line, or a row being
/// matched again. One matcher serves them all (D4 3.2 option A).
struct WantedTrack: Sendable, Hashable {
    /// Best guess first; never empty. A pasted "A - B" line has both orders
    /// (D4 4.6).
    var readings: [WantedReading]
    /// One search per song, with all its words.
    var searchText: String
    /// Looked up on TIDAL before any search when present (D4 4.5, 3.5).
    var isrc: String?
    var durationSeconds: Double?
    /// The album the source names, which picks among releases of one ISRC.
    var album: String?
    var source: QueueItem.Source

    func matcherReadings() -> [TidalMatcher.Wanted] {
        readings.map {
            TidalMatcher.Wanted(title: $0.title, artists: $0.credit, durationSeconds: durationSeconds, isrc: isrc, album: album)
        }
    }

    /// A Spotify track from an embed page. Its artists come as separate
    /// names, which are compared whole.
    init(spotify track: SpotifyTrack) {
        let artistLine = track.artistLine
        readings = [WantedReading(title: track.title, artistLine: artistLine,
                                  credit: track.artists.isEmpty ? .unknown : .names(track.artists))]
        searchText = Self.searchText(track.title, artistLine)
        isrc = nil
        durationSeconds = track.durationMilliseconds.map { Double($0) / 1000 }
        album = track.albumTitle
        source = .spotify
    }

    /// A line of a tracklist, with every reading the parser offered.
    init(entry: ParsedTracklist.Entry) {
        readings = entry.readings.map {
            WantedReading(title: $0.title, artistLine: $0.artist, credit: $0.artist.isEmpty ? .unknown : .text($0.artist))
        }
        searchText = entry.searchText
        isrc = entry.isrc
        durationSeconds = entry.duration
        album = nil
        source = .importList
    }

    /// A "not found" or "couldn't check" row being looked up again (D4 4.10).
    /// The row kept the source's own text; an imported row is tried in both
    /// orders again, since only its best guess was kept.
    init(row: QueueItem) {
        let title = row.originalTitle ?? row.title
        let artist = row.originalArtist ?? row.artist
        var readings = [WantedReading(title: title, artistLine: artist, credit: artist.isEmpty ? .unknown : .text(artist))]
        if row.source == .importList, !artist.isEmpty {
            readings.append(WantedReading(title: artist, artistLine: title, credit: .text(title)))
        }
        self.readings = readings
        searchText = Self.searchText(title, artist)
        isrc = row.isrc
        durationSeconds = (row.originalDurationSeconds ?? row.durationSeconds).map(Double.init)
        album = nil
        source = row.source
    }

    static func searchText(_ title: String, _ artist: String) -> String {
        [title, artist].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension TidalMatcher.Candidate {
    init(_ track: TIDALQueueTrack) {
        self.init(title: track.title, version: track.version, artistNames: track.artists,
                  durationSeconds: track.duration.map(Double.init), isrc: track.isrc, album: track.album)
    }
}

/// The music tracks of a search or ISRC reply, in TIDAL's order: id-less
/// items and videos dropped.
func tidalTracks(inSearchReply data: Data) throws -> [TIDALQueueTrack] {
    let page: TIDALSearchResult
    do {
        page = try JSONDecoder().decode(TIDALSearchResult.self, from: data)
    } catch {
        throw RequestError.decoding(detail: "a search reply wasn't the expected JSON")
    }
    return page.items.filter { !$0.isVideo }.compactMap(TIDALQueueTrack.init)
}

/// The result of one lookup, sorted by what it means for the row.
enum LookupOutcome: Sendable {
    case answer(Data)
    /// TIDAL was busy or failing after the retries: the row says "Couldn't
    /// check", never "not found" (D4 1.4).
    case couldNotCheck(String)
    /// TIDAL answered but refused or garbled this lookup.
    case refused(String)
}

extension TrackResolver {
    /// Finds `wanted` on TIDAL and builds its row: the matched track, a
    /// left-out "Different artist on TIDAL" row, "not on TIDAL", or "couldn't
    /// check". Throws `CancellationError` when stopped and `ResolveFailure`
    /// for what stops the whole add (no connection, no sign-in).
    func matchRow(_ wanted: WantedTrack, priority: TIDALPace.Priority, log: @Sendable (String) -> Void) async throws -> NewRow {
        if let isrc = wanted.isrc, MatchRules.recordingCodeKey(isrc) != nil {
            switch try await lookUp(priority, wanted, log: log, { try await $0.tracks(isrc: isrc) }) {
            case let .answer(data):
                if let row = pick(from: data, for: wanted, sameRecordingOnly: true, log: log) { return row }
            case let .couldNotCheck(reason):
                return .unmatched(wanted, match: .couldNotCheck(reason: reason))
            case .refused:
                // The ISRC lookup has never been tried with this app's
                // sign-in (D4 4.5 live check); a refusal falls back to the
                // search instead of failing the line.
                break
            }
        }
        guard !wanted.searchText.isEmpty else { return .unmatched(wanted, match: .notOnTIDAL) }
        switch try await lookUp(priority, wanted, log: log, { try await $0.searchTracks(query: wanted.searchText) }) {
        case let .answer(data):
            return pick(from: data, for: wanted, sameRecordingOnly: false, log: log)
                ?? .unmatched(wanted, match: .notOnTIDAL)
        case let .couldNotCheck(reason), let .refused(reason):
            return .unmatched(wanted, match: .couldNotCheck(reason: reason))
        }
    }

    /// The matcher's pick among one reply's tracks, as a row.
    private func pick(from data: Data, for wanted: WantedTrack, sameRecordingOnly: Bool, log: @Sendable (String) -> Void) -> NewRow? {
        let tracks: [TIDALQueueTrack]
        do {
            tracks = try tidalTracks(inSearchReply: data)
        } catch {
            log("Couldn't read TIDAL's answer for “\(wanted.readings[0].title)”: \(error)")
            return sameRecordingOnly ? nil : .unmatched(wanted, match: .couldNotCheck(reason: ResolveMessages.CouldNotCheck.unreadable))
        }
        guard let best = TidalMatcher.bestMatch(forReadings: wanted.matcherReadings(), among: tracks.map(TidalMatcher.Candidate.init))
        else { return nil }
        if sameRecordingOnly, best.match.confirmation != .sameRecordingCode { return nil }
        let reading = wanted.readings[best.reading]
        return .tidal(tracks[best.match.index], source: wanted.source,
                      original: (reading.title, reading.artistLine), originalDuration: wanted.durationSeconds,
                      leftOut: best.match.startsLeftOut)
    }

    /// One TIDAL call through the shared pace, with its failure sorted:
    /// busy or failing → "couldn't check"; a refusal or an unreadable answer
    /// → refused; no connection or no sign-in → stops the add.
    func lookUp(
        _ priority: TIDALPace.Priority, _ wanted: WantedTrack, log: @Sendable (String) -> Void,
        _ call: @escaping @Sendable (TIDALAPI) async throws -> Data
    ) async throws -> LookupOutcome {
        let tidal = self.tidal
        do {
            return .answer(try await pace.run(priority) { try await call(tidal) })
        } catch {
            try Self.rethrowIfStopping(error)
            let title = wanted.readings[0].title
            switch error {
            case let request as RequestError:
                log("Couldn't check “\(title)” on TIDAL: \(request)")
                switch request {
                case .busy, .server: return .couldNotCheck(ResolveMessages.CouldNotCheck.busy)
                case .decoding: return .refused(ResolveMessages.CouldNotCheck.unreadable)
                default: return .refused(ResolveMessages.CouldNotCheck.refused)
                }
            default:
                log("Couldn't check “\(title)” on TIDAL: \(error)")
                return .refused(ResolveMessages.CouldNotCheck.refused)
            }
        }
    }

    /// Cancellation, a lost connection and sign-in problems end the whole
    /// add rather than one line: a long import must never turn its tail into
    /// false "not found" rows (D4 4.9, 1.7).
    static func rethrowIfStopping(_ error: any Error) throws {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        if case RequestError.offline = error { throw ResolveFailure(kind: .offline, message: ResolveMessages.noInternet) }
        if let token = error as? TokenError { throw signInFailure(token, sourceName: "this add") }
    }

    static func signInFailure(_ error: TokenError, sourceName: String) -> ResolveFailure {
        switch error {
        case .notSignedIn:
            return ResolveFailure(kind: .signInNeeded, message: ResolveMessages.signInNeeded(sourceName))
        case .signInInvalid:
            return ResolveFailure(kind: .signInInvalid, message: error.description)
        case .storeUnreadable:
            return ResolveFailure(kind: .signInUnreadable, message: error.description)
        }
    }
}
