import Foundation

/// What a Spotify embed page gives an add.
struct SpotifyPageContent: Sendable {
    /// The album or playlist's name; empty for a single track, whose summary
    /// says "the link".
    var name: String
    var tracks: [SpotifyTrack]
    var cap: SpotifyCapNotice?
}

extension TrackResolver {
    /// Reads a Spotify track, album or playlist from its public embed page:
    /// no Spotify sign-in, no cookies (product rule; tidal-and-spotify-
    /// networking.md E). Retried like every other request (D4 1.4), but not
    /// paced with TIDAL.
    func spotifyPage(_ link: ParsedInput.SpotifyLink) async throws -> SpotifyPageContent {
        let kind: SpotifyEmbed.Kind = switch link.content {
        case .track: .track
        case .album: .album
        case .playlist: .playlist
        }
        guard let url = SpotifyEmbed.url(kind: kind, id: link.id) else {
            throw ResolveFailure(kind: .spotifyRefused, message: ResolveMessages.spotifyRefused(link.content))
        }
        let data = try await spotifyGet(url, content: link.content)
        let html = String(decoding: data, as: UTF8.self)
        do {
            switch link.content {
            case .track:
                let track = try SpotifyEmbed.parseTrack(html: html, requestedID: link.id)
                return SpotifyPageContent(name: "", tracks: Self.titled([track]), cap: nil)
            case .album:
                let album = try SpotifyEmbed.parseAlbum(html: html, requestedID: link.id)
                return SpotifyPageContent(name: album.title, tracks: Self.titled(album.tracks), cap: nil)
            case .playlist:
                let playlist = try SpotifyEmbed.parsePlaylist(html: html, requestedID: link.id)
                var cap: SpotifyCapNotice?
                if playlist.reachedEmbedLimit {
                    let listed = SpotifyEmbed.playlistTrackLimit
                    let total = Self.playlistLength(in: html)
                    if let message = ResolveMessages.spotifyCap(playlistName: playlist.title, listed: listed, total: total) {
                        cap = SpotifyCapNotice(playlistName: playlist.title, listed: listed, total: total, message: message)
                    }
                }
                return SpotifyPageContent(name: playlist.title, tracks: Self.titled(playlist.tracks), cap: cap)
            }
        } catch {
            let message = error.errorDescription ?? ResolveMessages.spotifyBusy
            throw ResolveFailure(kind: .unreadable, message: message)
        }
    }

    /// Entries without a title (unplayable or removed items) can't be
    /// matched or shown.
    private static func titled(_ tracks: [SpotifyTrack]) -> [SpotifyTrack] {
        tracks.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The playlist's real length, if Spotify's page carries one (D4 4.4).
    /// Whether it does, and under which name, needs the D4 4.4 live check:
    /// these are the names Spotify's own data uses elsewhere. Nil keeps the
    /// honest wording that doesn't claim a count.
    static func playlistLength(in html: String) -> Int? {
        guard let entity = try? SpotifyEmbed.entity(in: html) else { return nil }
        func whole(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double == double.rounded(), double < 1e9 else { return nil }
            return Int(double)
        }
        for key in ["trackCount", "totalTracks"] {
            if let count = whole(entity[key]) { return count }
        }
        if let tracks = entity["tracks"] as? [String: Any], let count = whole(tracks["total"]) { return count }
        return nil
    }

    private func spotifyGet(_ url: URL, content: ParsedInput.Content) async throws -> Data {
        do {
            let response = try await web.send(
                HTTPRequest(method: .get, url: url, headers: SpotifyEmbed.requestHeaders, expectedBody: .webPage)
            )
            return try response.requireOK(expecting: .webPage)
        } catch {
            throw Self.spotifyFailure(error, content: content)
        }
    }

    private static func spotifyFailure(_ error: any Error, content: ParsedInput.Content) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        switch error as? RequestError {
        case .offline:
            return ResolveFailure(kind: .offline, message: ResolveMessages.noInternet)
        case .busy, .server:
            return ResolveFailure(kind: .busy, message: ResolveMessages.spotifyBusy)
        case .notFound, .forbidden, .unauthorized:
            return ResolveFailure(kind: .spotifyRefused, message: ResolveMessages.spotifyRefused(content))
        case .unexpectedStatus, .decoding, .none:
            return ResolveFailure(kind: .unreadable,
                                  message: SpotifyEmbedError.unexpectedShape.errorDescription ?? ResolveMessages.spotifyBusy)
        }
    }

    /// A spotify.link short link, opened to see where it forwards (D4 4.3
    /// option A): one request to Spotify's public link service, no sign-in.
    /// Redirects are never followed by the client; the forward is read from
    /// the answer and accepted only when it leads to open.spotify.com, so a
    /// short link can't send the app anywhere else. A web page instead of a
    /// plain forward gets option B's message.
    func followShortLink(_ url: URL) async throws -> ParsedInput.SpotifyLink {
        var current = url
        for _ in 0..<3 {
            let response: HTTPResponse
            do {
                response = try await web.send(
                    HTTPRequest(method: .get, url: current, headers: SpotifyEmbed.requestHeaders, expectedBody: .webPage)
                )
            } catch {
                throw Self.spotifyFailure(error, content: .track)
            }
            guard (300...399).contains(response.status) else {
                if response.status == 200 {
                    throw ResolveFailure(kind: .shortLink, message: ResolveMessages.shortLinkPage)
                }
                do { _ = try response.requireOK(expecting: .webPage) } catch {
                    throw Self.spotifyFailure(error, content: .track)
                }
                throw ResolveFailure(kind: .shortLink, message: ResolveMessages.shortLinkPage)
            }
            guard let location = response.header("Location"),
                  let next = URL(string: location, relativeTo: current)?.absoluteURL,
                  next.scheme?.lowercased() == "https",
                  let host = next.host?.lowercased() else {
                throw ResolveFailure(kind: .shortLink, message: ResolveMessages.shortLinkElsewhere)
            }
            if InputParser.spotifyShortLinkHosts.contains(host) {
                current = next
                continue
            }
            guard host == "open.spotify.com", case let .spotify(link) = InputParser.parse(next.absoluteString) else {
                throw ResolveFailure(kind: .shortLink, message: ResolveMessages.shortLinkElsewhere)
            }
            return link
        }
        throw ResolveFailure(kind: .shortLink, message: ResolveMessages.shortLinkElsewhere)
    }
}
