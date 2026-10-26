// The tags a downloaded track is saved with, built in one place so the
// download, the download folder's same-song check (2.6) and anything later
// that compares tags all agree on what a track's title and artist tags say.
import Foundation

public enum TrackTagging {
    /// The tags for a track, filled the way the Electron app filled FFmpeg's
    /// `-metadata` keys (download-pipeline.md B11), with one change from
    /// decision 4, item 2.7: the title tag carries TIDAL's version.
    ///
    /// - title: TIDAL's title plus " (version)", unless the title already
    ///   names the version (see `titleTag`).
    /// - artist: every TIDAL artist, joined with ", "; the single `artist`
    ///   when the list is empty.
    /// - album: the track's album title, else the album details' title.
    /// - album artist: the album details' artist, else the track's album
    ///   artist, else the track's first artist (`||` order in B11).
    /// - track and disc: TIDAL's `trackNumber` and `volumeNumber`.
    /// - year: the first four characters of the release date, from the album
    ///   details, else the track's album, else the track's stream start date.
    /// - copyright: the album details', else the track's.
    /// - ISRC: the track's.
    ///
    /// `album` is nil when TIDAL had no album details (2.15, "Saved with
    /// limited tags"); the track's own fields fill in then.
    public static func tags(for track: TIDALTrack, album: TIDALAlbum?) -> FLACTags {
        let releaseDate = firstNonEmpty(album?.releaseDate, track.album?.releaseDate, track.streamStartDate)
        let artists = track.artistNames
        return FLACTags(
            title: titleTag(title: track.title, version: track.version),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", "),
            album: firstNonEmpty(track.album?.title, album?.title),
            albumArtist: firstNonEmpty(album?.artist?.name, track.album?.artist?.name, track.artists?.first?.name),
            trackNumber: track.trackNumber,
            discNumber: track.volumeNumber,
            year: releaseDate.map { String($0.prefix(4)) },
            copyright: firstNonEmpty(album?.copyright, track.copyright),
            isrc: firstNonEmpty(track.isrc)
        )
    }

    /// What a saved file's title, artist and ISRC tags read for the song a
    /// queue row describes, before anything is downloaded. The download
    /// folder's same-song check (2.6) compares an existing file with this;
    /// it matches what `tags(for:album:)` writes as long as the row's
    /// artist line is TIDAL's artists joined with ", ", as every row source
    /// builds it (`TIDALQueueTrack.artistLine`).
    public static func identity(of request: TrackDownloadRequest) -> FLACTags {
        FLACTags(
            title: titleTag(title: request.title, version: request.version),
            artist: firstNonEmpty(request.artist),
            album: firstNonEmpty(request.album),
            isrc: firstNonEmpty(request.isrc)
        )
    }

    /// The title tag: "Blue Lantern (Radio Edit)", never doubled when the
    /// title already holds the version as whole words, ignoring case and
    /// accents (2.7). The same rule as the queue's display title
    /// (`TIDALQueueTrack.displayTitle`), so the row and the file agree. Nil
    /// when there is neither a title nor a version.
    public static func titleTag(title: String?, version: String?) -> String? {
        let title = title ?? ""
        let version = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else { return title.isEmpty ? nil : title }
        if TIDALQueueTrack.containsPhrase(version, in: title) { return title }
        return title.isEmpty ? version : "\(title) (\(version))"
    }

    /// JavaScript's `a || b || c` over strings: the first that isn't empty.
    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { !($0?.isEmpty ?? true) } ?? nil
    }
}
