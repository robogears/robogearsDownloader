import Foundation

extension TrackResolver {

    // MARK: - Search (D4 4.11, 4.1)

    /// Up to ten TIDAL results for typed text, each as the row it would
    /// become, with the queue's library marks and whether it's already in
    /// the queue. Plain text always searches, numbers included (D4 4.1); an
    /// unusable link is refused rather than searched (D4 4.2).
    ///
    /// Throws `ResolveFailure` (no connection, busy, signed out: the search
    /// sheet can offer Try Again) or `CancellationError`.
    public func search(_ query: String, queue: QueueContents = .empty) async throws -> SearchResults {
        let trimmed = query.trimmingCharacters(in: InputParser.trimSet)
        guard !trimmed.isEmpty else { return SearchResults(query: trimmed, hits: [], emptyMessage: nil) }
        if case let .unsupported(link) = InputParser.parse(trimmed) {
            throw ResolveFailure(kind: .unsupportedLink, message: ResolveMessages.unsupported(link))
        }
        let tidal = self.tidal
        let data: Data
        do {
            data = try await pace.run(.interactive) {
                try await tidal.searchTracks(query: trimmed, limit: TIDALAPI.defaultSearchLimit)
            }
        } catch {
            try Self.rethrowIfStopping(error)
            switch error as? RequestError {
            case .busy, .server: throw ResolveFailure(kind: .busy, message: ResolveMessages.tidalBusy)
            default: throw ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable)
            }
        }
        let tracks: [TIDALQueueTrack]
        do {
            tracks = try tidalTracks(inSearchReply: data)
        } catch {
            throw ResolveFailure(kind: .unreadable, message: ResolveMessages.tidalUnreadable)
        }
        var seen = Set<Int64>()
        var hits: [SearchHit] = []
        for track in tracks where seen.insert(track.tidalId).inserted {
            let row = NewRow.tidal(track, source: .search)
            var item = row.item
            let mark = await library.mark(for: row.libraryQuery)
            LibraryMarks.apply(mark, to: &item)
            hits.append(SearchHit(item: item, inQueue: queue.tidalIDs.contains(track.tidalId)))
        }
        let empty = hits.isEmpty
            ? ResolveMessages.noResults(trimmed, looksLikeID: InputParser.looksLikeTidalID(trimmed))
            : nil
        return SearchResults(query: trimmed, hits: hits, emptyMessage: empty)
    }

    // MARK: - Fixing a row (D4 4.10, 1.4)

    /// What Search… on a row fills the search sheet with: the words the
    /// person brought, title then artist.
    public func searchQuery(for item: QueueItem) -> String {
        WantedTrack(row: item).searchText
    }

    /// Search… on a "not found" or "couldn't check" row: results to pick
    /// one from. Pass the pick to `replace(_:with:)`.
    public func search(forRow item: QueueItem, queue: QueueContents = .empty) async throws -> SearchResults {
        try await search(searchQuery(for: item), queue: queue)
    }

    /// The row a search pick turns `item` into: same id, so it replaces the
    /// row in place; the person's own words kept as the second line; the
    /// pick's library mark, so an exact library match still arrives greyed
    /// with + Add (rule 4).
    public func replace(_ item: QueueItem, with hit: SearchHit) -> QueueItem {
        var row = hit.item.withID(item.id)
        row.source = item.source
        let wanted = WantedTrack(row: item).readings[0]
        row.originalTitle = nil
        row.originalArtist = nil
        if let tidalID = row.tidalID {
            let track = TIDALQueueTrack(tidalId: tidalID, title: row.title, version: row.version,
                                        artists: [row.artist], album: row.album)
            if NewRow.readsDifferently((wanted.title, wanted.artistLine), from: track) {
                row.originalTitle = wanted.title
                row.originalArtist = wanted.artistLine.isEmpty ? nil : wanted.artistLine
            }
        }
        row.state = .waiting
        return row
    }

    /// Looks a "not found" or "couldn't check" row up again and returns its
    /// replacement under the same id, so it replaces the row in place (D4
    /// 4.10, 1.4's Match Again). Other rows come back unchanged, as does
    /// this one when cancelled. When the lookup can't run (no connection, no
    /// sign-in) the row says so as "Couldn't check: …", never "not found".
    public func matchAgain(_ item: QueueItem, priority: TIDALPace.Priority = .interactive) async -> QueueItem {
        switch item.match {
        case .notOnTIDAL, .couldNotCheck: break
        case .matched, .differentArtist: return item
        }
        do {
            let row = try await matchRow(WantedTrack(row: item), priority: priority, log: { _ in })
            var replacement = row.item.withID(item.id)
            let mark = await library.mark(for: row.libraryQuery)
            LibraryMarks.apply(mark, to: &replacement)
            return replacement
        } catch let failure as ResolveFailure {
            var unchanged = item
            unchanged.match = .couldNotCheck(reason: failure.kind == .offline
                ? ResolveMessages.CouldNotCheck.offline
                : ResolveMessages.CouldNotCheck.signIn)
            return unchanged
        } catch {
            return item
        }
    }

    /// Fills in the library marks of rows added while the library was still
    /// being read (D4 4.20). Call when the index becomes ready.
    public func fillLibraryMarks(_ items: [QueueItem]) async -> [QueueItem] {
        await LibraryMarks.fillPending(items, using: library)
    }
}
