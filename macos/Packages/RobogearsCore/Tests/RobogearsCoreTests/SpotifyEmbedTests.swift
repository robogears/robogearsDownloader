import Foundation
import Testing
@testable import RobogearsCore

/// Reads a synthetic embed page from Fixtures/spotify.
private func spotifyPage(_ file: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures/spotify"),
        "missing fixture \(file)"
    )
    return try Data(contentsOf: url)
}

@Suite struct SpotifyPlaylistEmbedTests {
    @Test func exactlyOneHundredTracksSaysThePlaylistMayBeLonger() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-100.html"), requestedID: "SynPlaylist100")
        #expect(playlist.tracks.count == 100)
        #expect(playlist.reachedEmbedLimit)
        #expect(playlist.title == "Late Ferry")
        #expect(playlist.owner == "Placeholder Owner")
    }

    @Test func ninetyNineTracksIsUnderTheLimit() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-99.html"), requestedID: "SynPlaylist99")
        #expect(playlist.tracks.count == 99)
        #expect(!playlist.reachedEmbedLimit)
    }

    @Test func playlistTracksKeepSpotifysOrderTitlesAndArtists() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-small.html"), requestedID: "SynPlaylistSmall")
        #expect(playlist.id == "SynPlaylistSmall")
        #expect(playlist.description == "Synthetic playlist with odd entries")
        // The null and text entries are skipped; the four real ones arrive in order.
        #expect(playlist.tracks.map(\.title) == [
            "Blue Lantern - 2011 Remaster", "Harbour (feat. A, B)", "夜の灯台", "Café Lumière",
        ])
        #expect(playlist.tracks[0].artists == ["Placeholder Artist", "Second Example"])
        #expect(playlist.tracks[0].artistLine == "Placeholder Artist, Second Example")
        #expect(playlist.tracks[0].id == "SynTrack0001AbCd")
    }

    @Test func commasInsideParenthesesDoNotSplitArtists() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-small.html"), requestedID: "x")
        #expect(playlist.tracks[1].artists == ["Third Placeholder (feat. A, B)", "Fourth Example"])
    }

    @Test func playlistEntryWithoutSubtitleHasNoArtists() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-small.html"), requestedID: "x")
        #expect(playlist.tracks[2].artists.isEmpty)
    }

    @Test func millisecondsBecomeRoundedSeconds() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-small.html"), requestedID: "x")
        #expect(playlist.tracks[0].durationMilliseconds == 245_123)
        #expect(playlist.tracks[0].duration == 245)
        #expect(playlist.tracks[1].duration == 199)   // 199.499 s
        #expect(playlist.tracks[2].duration == 211)   // 210.5 s rounds up, as Math.round did
        #expect(playlist.tracks[3].duration == nil)   // no length given
    }

    @Test func episodeEntriesHaveNoTrackIdButStayInTheList() throws {
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-small.html"), requestedID: "x")
        #expect(playlist.tracks[3].id == nil)
        #expect(playlist.tracks[3].title == "Café Lumière")
    }

    @Test func nonLatinAndAccentedTitlesSurviveDecoding() throws {
        // Decoded from the whole page at once, so multi-byte characters can't
        // be split the way Electron's per-chunk decoding could (L1).
        let playlist = try SpotifyEmbed.parsePlaylist(data: spotifyPage("playlist-small.html"), requestedID: "x")
        #expect(playlist.tracks[2].title.unicodeScalars.count == 4)
        #expect(!playlist.tracks.contains { $0.title.contains("\u{FFFD}") })
    }

    @Test func pageDataScriptIsFoundWhateverTheAttributeOrderOrQuotes() throws {
        // playlist-small.html writes <script type='application/json' ID='__NEXT_DATA__'>,
        // which the Electron regex (id first, double quotes) would have missed.
        let html = String(decoding: try spotifyPage("playlist-small.html"), as: UTF8.self)
        #expect(html.contains("ID='__NEXT_DATA__'"))
        #expect(SpotifyEmbed.nextDataJSON(in: html)?.hasPrefix("{\"props\"") == true)
    }
}

@Suite struct SpotifyAlbumAndTrackEmbedTests {
    @Test func albumTracksWithoutTheirOwnArtistTakeTheAlbumArtists() throws {
        let album = try SpotifyEmbed.parseAlbum(data: spotifyPage("album.html"), requestedID: "SynAlbum0001")
        #expect(album.id == "SynAlbum0001")
        #expect(album.title == "Harbour Lights")
        #expect(album.artists == ["Placeholder Artist"])
        #expect(album.tracks.map(\.title) == ["Harbour Lights", "Blue Lantern", "Night/Day"])
        #expect(album.tracks[1].artists == ["Placeholder Artist"])
        #expect(album.tracks[2].artists == ["Placeholder Artist", "Second Example"])
        #expect(album.tracks.allSatisfy { $0.albumTitle == "Harbour Lights" })
    }

    @Test func albumWithoutAnArtistListReadsTheSubtitle() throws {
        let album = try SpotifyEmbed.parseAlbum(data: spotifyPage("album-subtitle-only.html"), requestedID: "SynAlbum0002")
        #expect(album.artists == ["Third Placeholder", "Fourth Example"])
        #expect(album.tracks.first?.artists == ["Third Placeholder", "Fourth Example"])
    }

    @Test func trackPageReadsNameArtistsAndLength() throws {
        let track = try SpotifyEmbed.parseTrack(data: spotifyPage("track.html"), requestedID: "requested")
        #expect(track.id == "SynTrack0001AbCd")
        #expect(track.title == "Blue Lantern")
        #expect(track.artists == ["Placeholder Artist", "Second Example"])
        #expect(track.duration == 246)
    }

    @Test func trackPageFallsBackToTitleSubtitleAndTheRequestedId() throws {
        let track = try SpotifyEmbed.parseTrack(data: spotifyPage("track-subtitle-only.html"), requestedID: "requested")
        #expect(track.id == "requested")
        #expect(track.title == "Paper Harbour")
        #expect(track.artists == ["Third Placeholder", "Fourth Example"])
        #expect(track.duration == nil)
    }
}

@Suite struct SpotifyEmbedFailureTests {
    @Test func pageWithoutPageDataSaysSo() {
        #expect(throws: SpotifyEmbedError.missingPageData) {
            try SpotifyEmbed.parsePlaylist(data: spotifyPage("no-page-data.html"), requestedID: "x")
        }
    }

    @Test func pageDataWithoutTheEntityIsAnUnexpectedShape() {
        #expect(throws: SpotifyEmbedError.unexpectedShape) {
            try SpotifyEmbed.parseTrack(data: spotifyPage("wrong-shape.html"), requestedID: "x")
        }
    }

    @Test func brokenPageDataIsUnreadable() {
        let html = #"<script id="__NEXT_DATA__" type="application/json">{"props":</script>"#
        #expect(throws: SpotifyEmbedError.unreadablePageData) {
            try SpotifyEmbed.parseAlbum(html: html, requestedID: "x")
        }
    }

    @Test func errorMessagePointsToTheExportifyRoute() {
        let text = SpotifyEmbedError.unexpectedShape.errorDescription ?? ""
        #expect(text.contains("Exportify"))
        #expect(!text.contains("__NEXT_DATA__"))
    }
}

@Suite struct SpotifyEmbedHelperTests {
    @Test func splitArtistsMatchesTheElectronRule() {
        #expect(SpotifyEmbed.splitArtists("A, B") == ["A", "B"])
        #expect(SpotifyEmbed.splitArtists("A (feat. B, C), D") == ["A (feat. B, C)", "D"])
        #expect(SpotifyEmbed.splitArtists(" A ,, B ,") == ["A", "B"])
        #expect(SpotifyEmbed.splitArtists("Solo") == ["Solo"])
        #expect(SpotifyEmbed.splitArtists("") == [])
        #expect(SpotifyEmbed.splitArtists(nil) == [])
        // A comma followed by ")" before any "(" counts as inside parentheses,
        // even without an opening one: the JavaScript lookahead behaves so.
        #expect(SpotifyEmbed.splitArtists("A, B)") == ["A, B)"])
        // After a closed group, commas split again.
        #expect(SpotifyEmbed.splitArtists("A (x), B (y, z), C") == ["A (x)", "B (y, z)", "C"])
    }

    @Test func trackIdComesOnlyFromTrackURIs() {
        #expect(SpotifyEmbed.trackID(fromURI: "spotify:track:4uLU6hMCjMI75M1A2tKUQC") == "4uLU6hMCjMI75M1A2tKUQC")
        #expect(SpotifyEmbed.trackID(fromURI: "spotify:episode:abc") == nil)
        #expect(SpotifyEmbed.trackID(fromURI: "spotify:local:Artist:Album:Title:200") == nil)
        #expect(SpotifyEmbed.trackID(fromURI: nil) == nil)
    }

    @Test func embedURLAndRequestUseThePublicPageWithTheDesktopIdentity() throws {
        #expect(SpotifyEmbed.url(kind: .playlist, id: "SynPlaylist100")?.absoluteString ==
            "https://open.spotify.com/embed/playlist/SynPlaylist100")
        #expect(SpotifyEmbed.url(kind: .track, id: "") == nil)
        #expect(SpotifyEmbed.url(kind: .album, id: "a/b")?.absoluteString ==
            "https://open.spotify.com/embed/album/a%2Fb")
        let request = try #require(SpotifyEmbed.request(kind: .album, id: "SynAlbum0001"))
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/120") == true)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/html")
        // A Cookie header is only added at send time, so checking for it
        // can't fail; turning cookie handling off is what keeps them out.
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 30)
    }
}
