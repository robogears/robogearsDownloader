import Foundation

/// Turns links, pasted lines and tracklists into queue rows, and runs the
/// searches and Match Again of the queue (D4 area 4, 1.4, 1.7, 1.11).
///
/// The Electron resolver (tidal-and-spotify-networking.md §F) matched with
/// eight workers, never retried, turned every failed lookup into "not
/// found", kept Spotify's names on rows, and could only be cancelled between
/// tracks. Here:
///
/// - every TIDAL call goes through the shared `TIDALPace`, and a busy TIDAL
///   gives "Couldn't check: TIDAL was busy" rows, never "not found" (1.4);
/// - rows show and are checked as the TIDAL track that will download, with
///   the source's own words as a second line when they differ (4.14–4.16);
/// - rows stream out in source order as they are made, and `ResolveJob.stop()`
///   stops requests in flight at once while keeping what is finished (4.9,
///   1.11);
/// - no connection or no sign-in stops the add with a failure that keeps the
///   source for Try Again (1.7, 1.1).
///
/// One add at a time is the app's rule (4.18); the resolver itself doesn't
/// enforce it.
public struct TrackResolver: Sendable {
    public let tidal: TIDALAPI
    public let pace: TIDALPace
    /// For Spotify's embed pages and short links. Not paced with TIDAL: a
    /// Spotify refusal must never pause TIDAL lookups.
    public let web: HTTPClient
    public let library: any LibraryMarking
    /// Songs matched at once within one add, as the Electron app did; the
    /// pace bounds the whole app.
    public var matchWindow = 8
    /// Links of a pasted list read at once: "a few at a time", so Spotify and
    /// TIDAL don't start refusing them (D4 4.13).
    public var linkWindow = 4

    /// `tidal`'s client must have been made with `pacing: pace`, the same
    /// pace downloads and previews use: the slots come from `pace.run`, but
    /// the shared 429 pause only reaches requests whose client reports to
    /// that pace (D4 1.4). `web` is a separate client with no pacing.
    public init(tidal: TIDALAPI, pace: TIDALPace, web: HTTPClient, library: any LibraryMarking = NoLibrary()) {
        assert((tidal.client.pacing as? TIDALPace) === pace,
               "TrackResolver: make the TIDAL client with HTTPClient(pacing: pace) so one 429 pauses every caller")
        self.tidal = tidal
        self.pace = pace
        self.web = web
        self.library = library
    }

    // MARK: - Adding

    /// Starts adding `source`. `queue` is what the queue holds now, so rows
    /// already there are skipped and counted.
    public func add(_ source: ResolveSource, queue: QueueContents = .empty) -> ResolveJob {
        let (stream, continuation) = AsyncStream.makeStream(of: ResolveEvent.self)
        let resolver = self
        let emit: @Sendable (ResolveEvent) -> Void = { continuation.yield($0) }
        let work = Task {
            let session = AddSession(queue: queue, library: resolver.library, emit: emit)
            let last = await resolver.perform(source, session)
            continuation.yield(last)
            continuation.finish()
        }
        continuation.onTermination = { _ in work.cancel() }
        return ResolveJob(events: stream, stop: { work.cancel() })
    }

    /// Runs one add to its end and returns the last event.
    private func perform(_ source: ResolveSource, _ session: AddSession) async -> ResolveEvent {
        do {
            switch source {
            case let .link(text):
                try await addLink(InputParser.parse(text), session)
            case let .line(text):
                try await addTracklist(TracklistParser.parse(text), name: nil, session)
            case let .tracklist(text, name):
                try await addTracklist(TracklistParser.parse(text), name: name, session)
            case let .tracklistFile(data, name):
                let decoded = TracklistTextDecoder.decode(data)
                if decoded.looksBinary {
                    throw ResolveFailure(kind: .notText, message: ResolveMessages.notText(name))
                }
                try await addTracklist(TracklistParser.parse(decoded.text), name: name, session)
            }
            if Task.isCancelled { session.markStopped() }
            return .finished(session.summary)
        } catch var failure as ResolveFailure {
            if failure.kind == .signInNeeded {
                failure.message = ResolveMessages.signInNeeded(session.summary.sourceName)
            }
            if failure.isRetryable { failure.retry = source }
            if session.summary.added > 0 || session.summary.alreadyInQueue > 0 { failure.summary = session.summary }
            return .failed(failure)
        } catch where error is CancellationError || Task.isCancelled {
            // Stopped by Cancel; whatever finished has been sent.
            session.markStopped()
            return .finished(session.summary)
        } catch {
            session.emit(.log("The add stopped on an unexpected error: \(error)"))
            return .failed(ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable,
                                          summary: session.summary.added > 0 ? session.summary : nil))
        }
    }

    // MARK: Links

    /// A single link: TIDAL lists arrive page by page, Spotify tracks are
    /// matched as they come.
    private func addLink(_ parsed: ParsedInput, _ session: AddSession) async throws {
        session.summary.sourceName = "link"
        switch parsed {
        case .empty, .search:
            throw ResolveFailure(kind: .notALink, message: ResolveMessages.notALink)
        case let .unsupported(link):
            throw ResolveFailure(kind: .unsupportedLink, message: ResolveMessages.unsupported(link))
        case let .tidal(.track(id)):
            session.summary.total = 1
            let row = try await tidalTrackRow(id: id)
            await session.deliver([row], processed: 1)
        case let .tidal(list):
            let summaryName = try await loadTIDALList(list) { rows, loaded, total in
                session.summary.total = total
                await session.deliver(rows, processed: loaded - session.summary.processed)
                if let total, total > TIDALAPI.pageSize {
                    session.emit(.progress(.loading(done: loaded, total: total)))
                }
            } named: { name in
                session.summary.sourceName = name
            }
            session.summary.videosSkipped += summaryName.videosSkipped
        case let .spotify(link):
            try await addSpotify(link, session)
        case let .spotifyShortLink(url):
            try await addSpotify(followShortLink(url), session)
        }
    }

    private func addSpotify(_ link: ParsedInput.SpotifyLink, _ session: AddSession) async throws {
        let page = try await spotifyPage(link)
        if !page.name.isEmpty { session.summary.sourceName = page.name }
        if let cap = page.cap { session.emit(.capped(cap)) }
        try await runInOrder(page.tracks.map { .match(WantedTrack(spotify: $0)) }, session)
    }

    /// A TIDAL track link: one lookup, TIDAL's own data on the row.
    private func tidalTrackRow(id: Int) async throws -> NewRow {
        let data = try await linkCall(.track) { try await $0.track(id: id) }
        guard let decoded = try? JSONDecoder().decode(TIDALTrack.self, from: data),
              let track = TIDALQueueTrack(decoded) else {
            throw ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable)
        }
        return .tidal(track, source: .tidal)
    }

    /// Reads a TIDAL album or playlist: its name (D4 4.2: summaries name the
    /// source), then every page in order, handing each page's rows on as it
    /// arrives so a 1,250-track playlist shows "Loading 300 of 1,250
    /// tracks…" (D4 4.21) and stops between pages when cancelled. Videos are
    /// skipped, as in the Electron app.
    private func loadTIDALList(
        _ link: ParsedInput.TidalLink,
        page onPage: ([NewRow], _ loaded: Int, _ total: Int?) async -> Void,
        named: (String) -> Void
    ) async throws -> (videosSkipped: Int, loaded: Int) {
        let content = link.content
        let info = try await linkCall(content) { api in
            switch link {
            case let .album(id): try await api.album(id: id)
            case let .playlist(uuid): try await api.playlist(id: uuid)
            case let .track(id): try await api.track(id: id)
            }
        }
        if let name = Self.listName(info, content: content), !name.isEmpty { named(name) }

        var offset = 0, pages = 0, loaded = 0, videos = 0
        while true {
            try Task.checkCancellation()
            let pageOffset = offset
            let data = try await linkCall(content) { api in
                switch link {
                case let .album(id): try await api.albumItemsPage(id: id, offset: pageOffset)
                case let .playlist(uuid): try await api.playlistItemsPage(id: uuid, offset: pageOffset)
                case let .track(id): try await api.track(id: id)
                }
            }
            guard let page = try? JSONDecoder().decode(TIDALPage<TIDALPageItem>.self, from: data) else {
                throw ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable)
            }
            videos += page.items.filter { ($0.type?.lowercased().contains("video") ?? false) || ($0.track?.isVideo ?? false) }.count
            loaded += page.items.count
            let rows = page.musicTracks.compactMap(TIDALQueueTrack.init).map { NewRow.tidal($0, source: .tidal) }
            await onPage(rows, loaded, page.totalNumberOfItems)
            pages += 1
            if page.items.count < TIDALAPI.pageSize { break }
            if let total = page.totalNumberOfItems, loaded >= total { break }
            guard pages < TIDALAPI.maxPages else {
                throw ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable)
            }
            offset += TIDALAPI.pageSize
        }
        return (videos, loaded)
    }

    private static func listName(_ data: Data, content: ParsedInput.Content) -> String? {
        switch content {
        case .album: (try? JSONDecoder().decode(TIDALAlbum.self, from: data))?.title
        case .playlist: (try? JSONDecoder().decode(TIDALPlaylist.self, from: data))?.title
        case .track: nil
        }
    }

    /// One TIDAL call for a link, through the pace, with failures in words
    /// for the whole link.
    private func linkCall(
        _ content: ParsedInput.Content, _ call: @escaping @Sendable (TIDALAPI) async throws -> Data
    ) async throws -> Data {
        let tidal = self.tidal
        do {
            return try await pace.run(.matching) { try await call(tidal) }
        } catch {
            try Self.rethrowIfStopping(error)
            switch error as? RequestError {
            case .busy, .server:
                throw ResolveFailure(kind: .busy, message: ResolveMessages.tidalBusy)
            case .notFound, .forbidden:
                throw ResolveFailure(kind: .notAvailable, message: ResolveMessages.tidalNotAvailable(content))
            case .unauthorized, .unexpectedStatus:
                throw ResolveFailure(kind: .refusedByTIDAL, message: ResolveMessages.tidalRefused(content))
            case .decoding, .offline, .none:
                throw ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable)
            }
        }
    }

    // MARK: Tracklists

    private func addTracklist(_ parsed: ParsedTracklist, name: String?, _ session: AddSession) async throws {
        session.summary.sourceName = Self.sourceName(of: parsed, fileName: name)
        session.summary.unit = parsed.links.isEmpty ? .lines : .tracks
        if case let .table(columns) = parsed.format { session.summary.columns = columns }
        guard !parsed.isEmpty else {
            throw ResolveFailure(kind: .empty, message: ResolveMessages.emptyTracklist(name))
        }
        // A single link line is added like a link typed into the field.
        if parsed.items.count == 1, case let .link(link)? = parsed.items.first {
            try await addLink(link, session)
            return
        }

        // Links inside the list are read first, a few at a time and in
        // order (D4 4.13), then everything is matched as one list. A link
        // still loading when Cancel comes adds nothing; the ones already
        // read keep their rows.
        let linkIndices = parsed.items.indices.filter { if case .link = parsed.items[$0] { true } else { false } }
        var expansions: [Int: Expansion] = [:]
        if !linkIndices.isEmpty {
            session.emit(.progress(.loading(done: 0, total: linkIndices.count)))
            let resolver = self
            let results = try await ordered(linkIndices.count, window: linkWindow, onFinished: { done in
                session.emit(.progress(.loading(done: done, total: linkIndices.count)))
            }) { position in
                guard case let .link(link) = parsed.items[linkIndices[position]] else { return Expansion() }
                return try await resolver.expand(link)
            }
            for (position, expansion) in results.enumerated() {
                if let expansion { expansions[linkIndices[position]] = expansion }
            }
        }

        var work: [WorkItem] = []
        for (index, item) in parsed.items.enumerated() {
            switch item {
            case let .track(entry):
                work.append(.match(WantedTrack(entry: entry)))
            case .link:
                guard let expansion = expansions[index] else { continue }
                if let skipped = expansion.skipped { session.summary.skippedLinks.append(skipped) }
                if let cap = expansion.cap { session.emit(.capped(cap)) }
                session.summary.videosSkipped += expansion.videosSkipped
                work.append(contentsOf: expansion.work)
            }
        }
        try await runInOrder(work, session)
    }

    /// "Exportify CSV" for Exportify's columns, else the file's name, else
    /// "pasted text" (D4 4.2).
    static func sourceName(of parsed: ParsedTracklist, fileName: String?) -> String {
        if case let .table(columns) = parsed.format,
           columns.title.caseInsensitiveCompare("Track Name") == .orderedSame,
           let artist = columns.artist?.lowercased(), artist.hasPrefix("artist name") {
            return "Exportify CSV"
        }
        if let fileName, !fileName.isEmpty { return fileName }
        return "pasted text"
    }

    /// What one link of a pasted list adds.
    struct Expansion: Sendable {
        var work: [WorkItem] = []
        var skipped: SkippedLink?
        var cap: SpotifyCapNotice?
        var videosSkipped = 0
    }

    /// Reads one link of a list. A link that can't be added is skipped with
    /// its reason; only a lost connection or sign-in stops the whole list.
    private func expand(_ parsed: ParsedInput) async throws -> Expansion {
        do {
            switch parsed {
            case .empty, .search:
                return Expansion()
            case let .unsupported(link):
                return Expansion(skipped: SkippedLink(link: link.link, reason: ResolveMessages.unsupported(link)))
            case let .tidal(.track(id)):
                return Expansion(work: [.ready([try await tidalTrackRow(id: id)])])
            case let .tidal(list):
                var rows: [NewRow] = []
                let result = try await loadTIDALList(list) { page, _, _ in rows += page } named: { _ in }
                return Expansion(work: rows.map { .ready([$0]) }, videosSkipped: result.videosSkipped)
            case let .spotify(link):
                let page = try await spotifyPage(link)
                return Expansion(work: page.tracks.map { .match(WantedTrack(spotify: $0)) }, cap: page.cap)
            case let .spotifyShortLink(url):
                let page = try await spotifyPage(followShortLink(url))
                return Expansion(work: page.tracks.map { .match(WantedTrack(spotify: $0)) }, cap: page.cap)
            }
        } catch let failure as ResolveFailure where !failure.stopsAList {
            return Expansion(skipped: SkippedLink(link: Self.linkText(parsed), reason: failure.message))
        }
    }

    private static func linkText(_ parsed: ParsedInput) -> String {
        switch parsed {
        case let .tidal(.track(id)): "https://tidal.com/track/\(id)"
        case let .tidal(.album(id)): "https://tidal.com/album/\(id)"
        case let .tidal(.playlist(uuid)): "https://tidal.com/playlist/\(uuid)"
        case let .spotify(link): "https://open.spotify.com/\(link.content.rawValue)/\(link.id)"
        case let .spotifyShortLink(url): url.absoluteString
        case let .unsupported(link): link.link
        case let .search(query, _): query
        case .empty: ""
        }
    }

    // MARK: Matching many songs in order

    /// One step of an add: rows already known (a TIDAL list), or a song to
    /// match.
    enum WorkItem: Sendable {
        case ready([NewRow])
        case match(WantedTrack)
    }

    private enum StepResult: Sendable {
        case rows([NewRow])
        /// Cancelled before it finished.
        case unfinished
        /// Ends the add (no connection, no sign-in).
        case halt(ResolveFailure)
    }

    /// Runs every match with at most `matchWindow` at once and hands rows to
    /// the session in source order as the finished stretch grows, so the
    /// queue keeps the list's order and Cancel keeps what is done (D4 4.9).
    /// "Matching N / M" counts each finished match (D4 4.21).
    ///
    /// Rows already read from a link (a TIDAL album or playlist inside a
    /// pasted list) need no request: they are finished from the start, so
    /// they never wait for a matching place and Cancel never drops them.
    private func runInOrder(_ work: [WorkItem], _ session: AddSession) async throws {
        let total = work.count
        session.summary.total = session.summary.processed + total
        var results: [StepResult?] = work.map { item in
            if case let .ready(rows) = item { return .rows(rows) }
            return nil
        }
        let toMatch: [(index: Int, wanted: WantedTrack)] = work.enumerated().compactMap { index, item in
            if case let .match(wanted) = item { return (index, wanted) }
            return nil
        }
        if !toMatch.isEmpty { session.emit(.progress(.matching(done: 0, total: toMatch.count))) }

        var flushed = 0
        func flushFinished() async {
            while flushed < total, let ready = results[flushed] {
                if case let .rows(rows) = ready { await session.deliver(rows, processed: 1) }
                flushed += 1
            }
        }
        await flushFinished()

        let resolver = self
        let log: @Sendable (String) -> Void = { [emit = session.emit] in emit(.log($0)) }
        var matched = 0
        var halt: ResolveFailure?
        await withTaskGroup(of: (Int, StepResult).self) { group in
            var next = 0
            func launchNext() {
                let (index, wanted) = toMatch[next]
                next += 1
                group.addTask { (index, await resolver.matchStep(wanted, log: log)) }
            }
            while next < toMatch.count, next < max(matchWindow, 1), !Task.isCancelled { launchNext() }
            while let (index, result) = await group.next() {
                results[index] = result
                if case let .halt(failure) = result, halt == nil {
                    halt = failure
                    group.cancelAll()
                }
                if case .rows = result {
                    matched += 1
                    session.emit(.progress(.matching(done: matched, total: toMatch.count)))
                }
                if halt == nil, !Task.isCancelled, next < toMatch.count { launchNext() }
                await flushFinished()
            }
        }
        // Stopped or halted: what finished after a gap still joins the queue,
        // in order, rather than being thrown away.
        while flushed < total {
            if case let .rows(rows)? = results[flushed] { await session.deliver(rows, processed: 1) }
            flushed += 1
        }
        if let halt { throw halt }
    }

    private func matchStep(_ wanted: WantedTrack, log: @Sendable (String) -> Void) async -> StepResult {
        do {
            return .rows([try await matchRow(wanted, priority: .matching, log: log)])
        } catch let failure as ResolveFailure {
            return .halt(failure)
        } catch {
            return .unfinished
        }
    }

    /// Runs `count` jobs, at most `window` at once, returning their results
    /// in order. A job stopped by Cancel leaves a gap (nil) and nothing new
    /// starts once the add is cancelled, so what finished before Cancel is
    /// kept (D4 4.9). Any other error stops the rest and is thrown.
    private func ordered<T: Sendable>(
        _ count: Int, window: Int, onFinished: (Int) -> Void,
        _ job: @escaping @Sendable (Int) async throws -> T
    ) async throws -> [T?] {
        try await withThrowingTaskGroup(of: (Int, T?).self) { group in
            var results = [T?](repeating: nil, count: count)
            var next = 0, done = 0
            func launchNext() {
                let index = next
                next += 1
                group.addTask {
                    do {
                        return (index, try await job(index))
                    } catch is CancellationError {
                        return (index, nil)
                    }
                }
            }
            while next < count, next < max(window, 1), !Task.isCancelled { launchNext() }
            while let (index, value) = try await group.next() {
                results[index] = value
                if value != nil {
                    done += 1
                    onFinished(done)
                }
                if !Task.isCancelled, next < count { launchNext() }
            }
            return results
        }
    }
}

extension ResolveFailure {
    /// Failures that end a whole pasted list rather than skipping one link.
    var stopsAList: Bool {
        switch kind {
        case .offline, .signInNeeded, .signInInvalid, .signInUnreadable: true
        default: false
        }
    }
}

/// The state of one add, used only by the task running it.
final class AddSession {
    let queue: QueueContents
    let library: any LibraryMarking
    let emit: @Sendable (ResolveEvent) -> Void
    var summary = ResolveSummary(sourceName: "")
    private var seen = Set<Int64>()

    init(queue: QueueContents, library: any LibraryMarking, emit: @escaping @Sendable (ResolveEvent) -> Void) {
        self.queue = queue
        self.library = library
        self.emit = emit
    }

    /// Sends rows to the queue: skips what the queue already holds and a
    /// second row for the same TIDAL track, then puts the library mark on
    /// each (D4 4.20: "Checking library…" while the index isn't ready).
    func deliver(_ rows: [NewRow], processed: Int) async {
        summary.processed += processed
        var out: [QueueItem] = []
        for row in rows {
            var item = row.item
            if queue.contains(item) {
                summary.alreadyInQueue += 1
                continue
            }
            if let id = item.tidalID, !seen.insert(id).inserted {
                summary.sameTIDALTrack += 1
                continue
            }
            let mark = await library.mark(for: row.libraryQuery)
            LibraryMarks.apply(mark, to: &item)
            switch item.match {
            case .matched: summary.found += 1
            case .differentArtist:
                summary.found += 1
                summary.differentArtist += 1
            case .notOnTIDAL: summary.notOnTIDAL += 1
            case .couldNotCheck: summary.couldNotCheck += 1
            }
            out.append(item)
        }
        summary.added += out.count
        if !out.isEmpty { emit(.rows(out)) }
    }

    func markStopped() {
        if let total = summary.total, summary.processed >= total { return }
        summary.stopped = true
    }
}
