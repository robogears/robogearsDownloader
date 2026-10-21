import Foundation

/// Reads Spotify's public embed pages (`open.spotify.com/embed/<kind>/<id>`).
///
/// No Spotify credentials are used: the page carries its data in a
/// `__NEXT_DATA__` script, and the app reads `props.pageProps.state.data.entity`
/// from it, as the Electron app did (tidal-and-spotify-networking.md E).
/// Playlist pages stop at 100 tracks; `SpotifyPlaylist.reachedEmbedLimit`
/// says when that may have hidden some (G4-4).
public enum SpotifyEmbed {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case track, album, playlist
    }

    /// The most tracks a playlist embed page shows.
    public static let playlistTrackLimit = 100

    /// The desktop Chrome identity the Electron app sent (`SPOTIFY_UA`).
    public static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// The headers the embed request carries: no cookies, no sign-in.
    public static let requestHeaders: [String: String] = [
        "User-Agent": userAgent,
        "Accept": "text/html",
    ]

    /// The embed page for an item. Nil for an empty id.
    public static func url(kind: Kind, id: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard !id.isEmpty, let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://open.spotify.com/embed/\(kind.rawValue)/\(encoded)")
    }

    /// A GET for the embed page with the usual headers and the 30 s timeout.
    public static func request(kind: Kind, id: String) -> URLRequest? {
        guard let url = url(kind: kind, id: id) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    // MARK: - Parsing

    /// A single track page.
    public static func parseTrack(html: String, requestedID: String) throws(SpotifyEmbedError) -> SpotifyTrack {
        let entity = try entity(in: html)
        return SpotifyTrack(
            id: nonEmptyString(entity["id"]) ?? requestedID,
            title: nonEmptyString(entity["name"]) ?? nonEmptyString(entity["title"]) ?? "",
            artists: artists(of: entity),
            durationMilliseconds: milliseconds(entity["duration"]),
            albumTitle: nil
        )
    }

    /// An album page. Tracks with no artist line of their own take the album's artists.
    public static func parseAlbum(html: String, requestedID: String) throws(SpotifyEmbedError) -> SpotifyAlbum {
        let entity = try entity(in: html)
        let albumTitle = nonEmptyString(entity["name"]) ?? nonEmptyString(entity["title"]) ?? ""
        let albumArtists = artists(of: entity)
        let tracks = trackList(of: entity).map { item in
            let own = splitArtists(item["subtitle"] as? String)
            return listedTrack(item, artists: own.isEmpty ? albumArtists : own, albumTitle: albumTitle)
        }
        return SpotifyAlbum(id: requestedID, title: albumTitle, artists: albumArtists, tracks: tracks)
    }

    /// A playlist page. Tracks keep an empty artist list when Spotify gives none.
    public static func parsePlaylist(html: String, requestedID: String) throws(SpotifyEmbedError) -> SpotifyPlaylist {
        let entity = try entity(in: html)
        let listed = (entity["trackList"] as? [Any]) ?? []
        let tracks = trackList(of: entity).map { item in
            listedTrack(item, artists: splitArtists(item["subtitle"] as? String), albumTitle: nil)
        }
        return SpotifyPlaylist(
            id: requestedID,
            title: nonEmptyString(entity["name"]) ?? nonEmptyString(entity["title"]) ?? "",
            description: (entity["description"] as? String) ?? "",
            owner: (entity["subtitle"] as? String) ?? "",
            tracks: tracks,
            // Counted on what Spotify listed, before any unreadable entry is
            // dropped, because the limit is about what the page showed.
            reachedEmbedLimit: listed.count >= playlistTrackLimit
        )
    }

    /// The page bytes are decoded as UTF-8 in one piece, so a character split
    /// across network chunks can't turn into U+FFFD (reference defect L1).
    public static func parseTrack(data: Data, requestedID: String) throws(SpotifyEmbedError) -> SpotifyTrack {
        try parseTrack(html: String(decoding: data, as: UTF8.self), requestedID: requestedID)
    }

    public static func parseAlbum(data: Data, requestedID: String) throws(SpotifyEmbedError) -> SpotifyAlbum {
        try parseAlbum(html: String(decoding: data, as: UTF8.self), requestedID: requestedID)
    }

    public static func parsePlaylist(data: Data, requestedID: String) throws(SpotifyEmbedError) -> SpotifyPlaylist {
        try parsePlaylist(html: String(decoding: data, as: UTF8.self), requestedID: requestedID)
    }

    // MARK: - Pieces

    /// The text of the `<script id="__NEXT_DATA__">` element. The Electron
    /// regex needed `id` to be the first attribute and double-quoted (bug 23);
    /// this accepts any attribute order, either quote and any letter case.
    static func nextDataJSON(in html: String) -> Substring? {
        let pattern = #/<script\b[^>]*?\bid\s*=\s*["']__NEXT_DATA__["'][^>]*>(?<json>.*?)</script\s*>/#
            .dotMatchesNewlines()
            .ignoresCase()
        return html.firstMatch(of: pattern)?.output.json
    }

    /// `props.pageProps.state.data.entity`.
    static func entity(in html: String) throws(SpotifyEmbedError) -> [String: Any] {
        guard let json = nextDataJSON(in: html) else { throw .missingPageData }
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            throw .unreadablePageData
        }
        var node: Any? = root
        for key in ["props", "pageProps", "state", "data", "entity"] {
            node = (node as? [String: Any])?[key]
        }
        guard let entity = node as? [String: Any] else { throw .unexpectedShape }
        return entity
    }

    /// The readable entries of `trackList`, in order. Entries that aren't
    /// objects are skipped; in Electron one such entry failed the whole link.
    private static func trackList(of entity: [String: Any]) -> [[String: Any]] {
        ((entity["trackList"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }

    private static func listedTrack(_ item: [String: Any], artists: [String], albumTitle: String?) -> SpotifyTrack {
        SpotifyTrack(
            id: trackID(fromURI: item["uri"] as? String),
            title: (item["title"] as? String) ?? "",
            artists: artists,
            durationMilliseconds: milliseconds(item["duration"]),
            albumTitle: albumTitle
        )
    }

    /// `artists[].name` when the entity lists any, otherwise its subtitle split
    /// into names (`getSpotifyTrack`, `getSpotifyAlbum`).
    private static func artists(of entity: [String: Any]) -> [String] {
        let named = ((entity["artists"] as? [Any]) ?? [])
            .compactMap { (($0 as? [String: Any])?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return named.isEmpty ? splitArtists(entity["subtitle"] as? String) : named
    }

    /// The track id in a `spotify:track:<id>` URI. Episodes and local files
    /// have none; the id is informational only (`trackUriToId`).
    static func trackID(fromURI uri: String?) -> String? {
        guard let uri else { return nil }
        let pattern = #/spotify:track:(?<id>[a-zA-Z0-9]+)/#
        return uri.firstMatch(of: pattern).map { String($0.output.id) }
    }

    /// Splits an artist line on commas that aren't inside parentheses, so
    /// `A (feat. B, C), D` is two artists. Same as the Electron
    /// `split(/,(?![^(]*\))/)`: a comma stays when a `)` comes before any `(`
    /// after it. Pieces are trimmed and empty ones dropped.
    public static func splitArtists(_ subtitle: String?) -> [String] {
        guard let subtitle, !subtitle.isEmpty else { return [] }
        let scalars = Array(subtitle.unicodeScalars)
        // For each position, the first parenthesis at or after it.
        var nextParenthesis = [Unicode.Scalar?](repeating: nil, count: scalars.count + 1)
        for index in stride(from: scalars.count - 1, through: 0, by: -1) {
            let scalar = scalars[index]
            nextParenthesis[index] = (scalar == "(" || scalar == ")") ? scalar : nextParenthesis[index + 1]
        }
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == ",", nextParenthesis[index + 1] != ")" {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        pieces.append(String(current))
        return pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Spotify's `duration`, assumed to be milliseconds (open question 1).
    private static func milliseconds(_ value: Any?) -> Int? {
        // JSON true/false also arrive as NSNumber; they are not lengths.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < 1e12 else { return nil }
        return Int(double.rounded())
    }
}

/// A track as Spotify's embed page lists it.
public struct SpotifyTrack: Sendable, Hashable {
    /// The Spotify track id; nil for episodes and local files.
    public var id: String?
    public var title: String
    /// Artist names in Spotify's order; may be empty for a playlist entry.
    public var artists: [String]
    public var durationMilliseconds: Int?
    /// Set for tracks read from an album page.
    public var albumTitle: String?

    public init(id: String?, title: String, artists: [String], durationMilliseconds: Int?, albumTitle: String? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.durationMilliseconds = durationMilliseconds
        self.albumTitle = albumTitle
    }

    /// Whole seconds, rounded as `Math.round(ms / 1000)` did. Nil when Spotify
    /// gave no length. The matcher may prefer the exact milliseconds.
    public var duration: Int? {
        durationMilliseconds.map { Int((Double($0) / 1000).rounded()) }
    }

    /// `A, B`, the way Spotify rows always showed their artists.
    public var artistLine: String {
        artists.joined(separator: ", ")
    }
}

public struct SpotifyAlbum: Sendable, Hashable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var tracks: [SpotifyTrack]

    public init(id: String, title: String, artists: [String], tracks: [SpotifyTrack]) {
        self.id = id
        self.title = title
        self.artists = artists
        self.tracks = tracks
    }
}

public struct SpotifyPlaylist: Sendable, Hashable {
    public var id: String
    public var title: String
    public var description: String
    /// The page's subtitle, which names the owner.
    public var owner: String
    public var tracks: [SpotifyTrack]
    /// Spotify showed the 100 tracks its embed page allows, so the playlist
    /// may be longer. It does not mean tracks were dropped: a playlist of
    /// exactly 100 sets it too, and the page doesn't say which (G4-4). The
    /// message should offer the Exportify route, not claim a loss.
    public var reachedEmbedLimit: Bool

    public init(id: String, title: String, description: String, owner: String, tracks: [SpotifyTrack], reachedEmbedLimit: Bool) {
        self.id = id
        self.title = title
        self.description = description
        self.owner = owner
        self.tracks = tracks
        self.reachedEmbedLimit = reachedEmbedLimit
    }
}

/// Why an embed page couldn't be read. Written for the person (G5-16).
public enum SpotifyEmbedError: Error, Sendable, Hashable, LocalizedError {
    /// The page had no `__NEXT_DATA__` script.
    case missingPageData
    /// The script's JSON couldn't be read.
    case unreadablePageData
    /// The JSON had no `props.pageProps.state.data.entity`.
    case unexpectedShape

    public var errorDescription: String? {
        "Spotify's page didn't include the details the app reads; Spotify may have changed it. "
            + "Try again later, or for a playlist, export it with Exportify and drop the CSV here."
    }
}
