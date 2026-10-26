import Foundation

/// A row on its way to the queue, with what its library check compares.
struct NewRow: Sendable, Equatable {
    var item: QueueItem
    var libraryQuery: LibraryMatcher.Query

    /// The row for the TIDAL track that will download, from any source
    /// (D4 4.14–4.16): TIDAL's bare title, its edition, every artist, the
    /// album, length, ISRC, explicit flag and Hi-Res flag. The text the
    /// person brought is kept as a quiet second line only when it reads
    /// differently. `leftOut` adds it greyed with "Different artist on
    /// TIDAL" (D4 3.2).
    static func tidal(
        _ track: TIDALQueueTrack, source: QueueItem.Source,
        original: (title: String, artist: String)? = nil, leftOut: Bool = false
    ) -> NewRow {
        var item = QueueItem(
            tidalID: track.tidalId, title: track.title, version: track.version, artist: track.artistLine,
            album: track.album, durationSeconds: track.duration, isrc: track.isrc,
            hiRes: track.hiRes, explicit: track.explicit, source: source
        )
        if let original, readsDifferently(original, from: track) {
            item.originalTitle = original.title
            item.originalArtist = original.artist.isEmpty ? nil : original.artist
        }
        if leftOut {
            item.match = .differentArtist(tidalArtist: track.artistLine)
            item.included = false
        }
        return NewRow(item: item, libraryQuery: LibraryMarks.query(for: track))
    }

    /// A row with no TIDAL track: not on TIDAL, or the lookup failed. It
    /// keeps the source's own text (D4 4.14), and its ISRC and length, so
    /// Match Again can look it up the same way (D4 4.10).
    static func unmatched(_ wanted: WantedTrack, match: QueueItem.Match) -> NewRow {
        let reading = wanted.readings[0]
        let item = QueueItem(
            tidalID: nil, title: reading.title, artist: reading.artistLine,
            durationSeconds: wanted.durationSeconds.map { Int($0.rounded()) }, isrc: wanted.isrc,
            source: wanted.source, match: match
        )
        return NewRow(item: item, libraryQuery: LibraryMarks.query(for: item))
    }

    /// Whether the source's words differ from what TIDAL will save. Case,
    /// accents and punctuation don't count, and Spotify's "Blue Lantern -
    /// 2011 Remaster" reads the same as TIDAL's "Blue Lantern" with the
    /// edition "2011 Remaster".
    static func readsDifferently(_ original: (title: String, artist: String), from track: TIDALQueueTrack) -> Bool {
        let title = Normalizer.fullKey(original.title)
        let sameTitle = Normalizer.keysAgree(title, Normalizer.fullKey(track.displayTitle))
            || Normalizer.keysAgree(title, Normalizer.fullKey(track.title))
        let artist = Normalizer.fullKey(original.artist)
        let sameArtist = artist.isEmpty || Normalizer.keysAgree(artist, Normalizer.fullKey(track.artistLine))
        return !(sameTitle && sameArtist)
    }
}

extension QueueItem {
    /// The same row under another id, so a Match Again or a search pick
    /// replaces a row in place (D4 4.10).
    func withID(_ id: UUID) -> QueueItem {
        var copy = QueueItem(
            id: id, tidalID: tidalID, title: title, version: version, artist: artist, album: album,
            durationSeconds: durationSeconds, isrc: isrc, hiRes: hiRes, explicit: explicit, source: source,
            originalTitle: originalTitle, originalArtist: originalArtist, match: match,
            libraryMatch: libraryMatch, included: included, state: state
        )
        copy.libraryCheckPending = libraryCheckPending
        return copy
    }
}
