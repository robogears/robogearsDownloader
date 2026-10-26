import Foundation
import Testing
@testable import RobogearsCore

enum ResolveFixtures {
    static func data(_ name: String, folder: String = "resolve") -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/\(folder)"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(folder)/\(name)")
        }
        return data
    }

    static func text(_ name: String, folder: String = "resolve") -> String {
        String(decoding: data(name, folder: folder), as: UTF8.self)
    }
}

/// Links: TIDAL and Spotify tracks, albums and playlists (D4 4.2, 4.3, 4.4,
/// 4.14–4.16, 4.21).
@Suite("Resolver: links")
struct TrackResolverLinkTests {

    // MARK: TIDAL

    @Test func aTIDALTrackLinkMakesOneRowFromTIDALsOwnData() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.tracks[900100001] = ResolveJSON.data(ResolveJSON.track(
                900100001, "Blue Lantern", artists: ["Placeholder Artist", "Second Example"], duration: 245,
                isrc: "ZZRES2600001", version: "Radio Edit", explicit: true, hiRes: true, album: "Glass Orchard"))
        }
        let events = await harness.run(.link("https://tidal.com/browse/track/900100001"))
        let row = events.rows.first
        #expect(events.rows.count == 1)
        #expect(row?.tidalID == 900100001)
        #expect(row?.title == "Blue Lantern")
        #expect(row?.version == "Radio Edit")
        #expect(row?.artist == "Placeholder Artist, Second Example")
        #expect(row?.album == "Glass Orchard")
        #expect(row?.durationSeconds == 245)
        #expect(row?.isrc == "ZZRES2600001")
        #expect(row?.explicit == true)
        #expect(row?.hiRes == true)
        #expect(row?.source == .tidal)
        #expect(row?.match == .matched)
        #expect(row?.originalTitle == nil)
        #expect(harness.tidalRequests == ["/v1/tracks/900100001?countryCode=GB"])
        #expect(events.summary?.message == "Added 1 track from the link.")
    }

    @Test func anAlbumLinkThatNamesATrackAddsJustThatTrack() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.tracks[900100001] = ResolveJSON.data(ResolveJSON.track(900100001, "Blue Lantern", artists: ["Placeholder Artist"]))
        }
        let events = await harness.run(.link("https://listen.tidal.com/album/8100000/track/900100001"))
        #expect(events.rows.map(\.tidalID) == [900100001])
        #expect(harness.tidalRequests == ["/v1/tracks/900100001?countryCode=GB"])
    }

    @Test func aLongTIDALAlbumArrivesPageByPageInOrderWithItsName() async {
        let harness = ResolveHarness()
        let first = (0..<100).map { ResolveJSON.track(900_110_000 + Int64($0), "Track \($0)", artists: ["Placeholder Artist"]) }
        let second = (100..<149).map { ResolveJSON.track(900_110_000 + Int64($0), "Track \($0)", artists: ["Placeholder Artist"]) }
            + [ResolveJSON.track(900_119_999, "Harbour Lights (Video)", artists: ["Placeholder Artist"], type: "video")]
        harness.backend.setUp {
            $0.albums[8100000] = ResolveJSON.data(["id": 8100000, "title": "Harbour Lights"])
            $0.albumPages[8100000] = [
                ResolveJSON.itemsPage(first, offset: 0, total: 150),
                ResolveJSON.itemsPage(second, offset: 100, total: 150),
            ]
        }
        let events = await harness.run(.link("https://tidal.com/album/8100000"))
        #expect(events.rows.map(\.tidalID) == (0..<149).map { 900_110_000 + Int64($0) })
        #expect(harness.tidalRequests == [
            "/v1/albums/8100000?countryCode=GB",
            "/v1/albums/8100000/items?countryCode=GB&limit=100&offset=0",
            "/v1/albums/8100000/items?countryCode=GB&limit=100&offset=100",
        ])
        #expect(events.progress == [.loading(done: 100, total: 150), .loading(done: 150, total: 150)])
        // The first page's rows reach the queue before the second page is asked for.
        let firstRows = events.firstIndex { if case let .rows(rows) = $0 { rows.count == 100 } else { false } }
        let secondRows = events.firstIndex { if case let .rows(rows) = $0 { rows.count == 49 } else { false } }
        #expect(firstRows != nil && secondRows != nil && firstRows! < secondRows!)
        #expect(events.summary?.message == "Added 149 tracks from Harbour Lights. Skipped 1 video.")
    }

    @Test func aTIDALPlaylistSkipsVideosAndNamesThePlaylist() async {
        let harness = ResolveHarness()
        let uuid = "0f1e2d3c-4b5a-4968-8776-655443322110"
        harness.backend.setUp {
            $0.playlists[uuid] = ResolveFixtures.data("playlist.json", folder: "tidal")
            $0.playlistPages[uuid] = [ResolveFixtures.data("playlist-items.json", folder: "tidal")]
        }
        let events = await harness.run(.link("https://tidal.com/browse/playlist/\(uuid)"))
        #expect(events.rows.map(\.tidalID) == [900000301, 900000303])
        #expect(events.rows.first?.hiRes == true)
        #expect(events.rows.last?.artist == "Third Placeholder")
        #expect(events.summary?.sourceName == "Late Ferry")
        #expect(events.summary?.videosSkipped == 1)
    }

    @Test func aTIDALLinkThatIsGoneSaysSoWithoutTryAgain() async {
        let harness = ResolveHarness()
        let events = await harness.run(.link("https://tidal.com/browse/album/8199999"))
        #expect(events.rows.isEmpty)
        #expect(events.failure?.kind == .notAvailable)
        #expect(events.failure?.message == "This TIDAL album isn't available. It may have been removed, or it isn't offered in your country.")
        #expect(events.failure?.retry == nil)
    }

    // MARK: Refusals (D4 4.1, 4.2)

    @Test func linksTheAppCantUseAreRefusedByServiceAndNothingIsSearched() async {
        let harness = ResolveHarness()
        let youTube = await harness.run(.link("https://www.youtube.com/watch?v=SynVideo1"))
        #expect(youTube.failure?.kind == .unsupportedLink)
        #expect(youTube.failure?.message == "YouTube links aren't supported. Paste a TIDAL or Spotify link, or type the song's name.")

        let artist = await harness.run(.link("https://tidal.com/browse/artist/7100000"))
        #expect(artist.failure?.message == "TIDAL artist pages can't be added. Open an album or playlist and copy its link.")

        let mix = await harness.run(.link("https://tidal.com/browse/mix/00a1b2c3d4e5f6"))
        #expect(mix.failure?.message == "TIDAL mixes can't be added. Open an album or playlist and copy its link.")

        #expect(harness.server.requests.isEmpty)
    }

    @Test func plainTextIsNeverOpenedAsATIDALNumber() async {
        let harness = ResolveHarness()
        let events = await harness.run(.link("2041"))
        #expect(events.failure?.kind == .notALink)
        #expect(harness.server.requests.isEmpty)
        #expect(AddRoute.forField("2041") == .search(query: "2041", looksLikeID: true))
    }

    // MARK: Spotify (D4 4.14, 3.2, 4.21)

    @Test func spotifyTracksAreMatchedAndShownAsTheTIDALTrackThatWillDownload() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.webPages["https://open.spotify.com/embed/playlist/SynGlassOrchard"] =
                ResolveFixtures.data("spotify-playlist-glass-orchard.html")
        }
        harness.backend.search("Blue Lantern - 2011 Remaster Placeholder Artist", [
            ResolveJSON.track(900200001, "Blue Lantern", artists: ["Placeholder Artist"], duration: 245, version: "2011 Remaster"),
        ])
        harness.backend.search("Paper Harbour Northbound Choir", [
            ResolveJSON.track(900200002, "Paper Harbour", artists: ["Northbound Choir", "Second Guest"], duration: 210, hiRes: true),
        ])
        harness.backend.search("Intro Northbound Choir", [
            ResolveJSON.track(900200003, "Intro", artists: ["Another Band"], duration: 141),
        ])
        let events = await harness.run(.link("https://open.spotify.com/playlist/SynGlassOrchard?si=abc"))
        let rows = events.rows
        #expect(rows.map(\.tidalID) == [900200001, 900200002, 900200003, nil])
        #expect(rows.allSatisfy { $0.source == .spotify })

        // Same words: no second line.
        #expect(rows[0].title == "Blue Lantern")
        #expect(rows[0].version == "2011 Remaster")
        #expect(rows[0].originalTitle == nil)
        // TIDAL credits another artist too: Spotify's words stay as the second line.
        #expect(rows[1].artist == "Northbound Choir, Second Guest")
        #expect(rows[1].originalTitle == "Paper Harbour")
        #expect(rows[1].originalArtist == "Northbound Choir")
        #expect(rows[1].hiRes)
        // Only another band's "Intro": added, but left out with the reason.
        #expect(rows[2].match == .differentArtist(tidalArtist: "Another Band"))
        #expect(!rows[2].included)
        #expect(rows[2].originalArtist == "Northbound Choir")
        // Not on TIDAL: Spotify's own text.
        #expect(rows[3].match == .notOnTIDAL)
        #expect(rows[3].title == "Copper Sky")
        #expect(rows[3].artist == "Late Ferry Band")
        #expect(rows[3].durationSeconds == 199)

        #expect(events.progress.first == .matching(done: 0, total: 4))
        #expect(events.progress.last == .matching(done: 4, total: 4))
        #expect(events.summary?.message
            == "Added 4 tracks from Glass Orchard: 3 found on TIDAL, 1 not found. 1 is left out: TIDAL credits a different artist.")
        #expect(events.caps.isEmpty)
    }

    @Test func aSpotifyPlaylistAtTheCapSaysSoHonestly() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.webPages["https://open.spotify.com/embed/playlist/SynPlaylist100"] =
                ResolveFixtures.data("playlist-100.html", folder: "spotify")
        }
        let events = await harness.run(.link("https://open.spotify.com/playlist/SynPlaylist100"))
        #expect(events.rows.count == 100)
        let cap = events.caps.first
        #expect(cap?.playlistName == "Late Ferry")
        #expect(cap?.listed == 100)
        #expect(cap?.total == nil)
        #expect(cap?.message == "Spotify only shares the first 100 tracks of a playlist. If Late Ferry is longer, export it with "
            + "Exportify and drop the CSV here. Songs matched to the same TIDAL track aren't added twice.")
    }

    @Test func theCapGivesExactCountsWhenSpotifysPageHasTheLength() async {
        let tracks = (1...100).map { ResolveSpotifyHTML.Track(title: "Placeholder Song \($0)", artists: "Placeholder Artist") }
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.webPages["https://open.spotify.com/embed/playlist/SynLong"] =
                ResolveSpotifyHTML.playlist("SynLong", name: "Late Ferry", tracks: tracks, extra: ["trackCount": 250])
            $0.webPages["https://open.spotify.com/embed/playlist/SynExact"] =
                ResolveSpotifyHTML.playlist("SynExact", name: "Late Ferry", tracks: tracks, extra: ["trackCount": 100])
        }
        let long = await harness.run(.link("https://open.spotify.com/playlist/SynLong"))
        #expect(long.caps.first?.total == 250)
        #expect(long.caps.first?.message
            == "Added the first 100 of 250 tracks. To get the other 150, export the playlist with Exportify and drop the CSV here.")

        let exact = await harness.run(.link("https://open.spotify.com/playlist/SynExact"))
        #expect(exact.caps.isEmpty)
    }

    @Test func aPlaylistUnderTheCapGetsNoWarning() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.webPages["https://open.spotify.com/embed/playlist/SynPlaylist99"] =
                ResolveFixtures.data("playlist-99.html", folder: "spotify")
        }
        let events = await harness.run(.link("https://open.spotify.com/playlist/SynPlaylist99"))
        #expect(events.rows.count == 99)
        #expect(events.caps.isEmpty)
    }

    @Test func aPrivateSpotifyPlaylistSaysHowToGetItIn() async {
        let harness = ResolveHarness()
        let events = await harness.run(.link("https://open.spotify.com/playlist/SynPrivate"))
        #expect(events.failure?.kind == .spotifyRefused)
        #expect(events.failure?.message == "Spotify won't share this playlist. Make it public in Spotify, or export it with Exportify.")
    }

    @Test func twoSpotifyTracksMatchingOneTIDALTrackMakeOneRow() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.webPages["https://open.spotify.com/embed/album/SynTwice"] = ResolveSpotifyHTML.album(
                "SynTwice", name: "Glass Orchard", artists: ["Placeholder Artist"],
                tracks: [.init(title: "Blue Lantern", artists: ""), .init(title: "Blue Lantern - Remastered", artists: "")])
        }
        harness.backend.search("Blue Lantern Placeholder Artist", [
            ResolveJSON.track(900700001, "Blue Lantern", artists: ["Placeholder Artist"]),
        ])
        harness.backend.search("Blue Lantern - Remastered Placeholder Artist", [
            ResolveJSON.track(900700001, "Blue Lantern", artists: ["Placeholder Artist"]),
        ])
        let events = await harness.run(.link("https://open.spotify.com/album/SynTwice"))
        #expect(events.rows.map(\.tidalID) == [900700001])
        #expect(events.summary?.sameTIDALTrack == 1)
        #expect(events.summary?.message == "Added 1 track from Glass Orchard. 1 matched the same TIDAL track as another row.")

        let again = await harness.run(.link("https://open.spotify.com/album/SynTwice"), queue: QueueContents(events.rows))
        #expect(again.rows.isEmpty)
        #expect(again.summary?.message == "All 2 tracks are already in the queue.")
    }

    // MARK: Short links (D4 4.3)

    @Test func aSpotifyShortLinkIsFollowedOnlyToOpenSpotify() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.redirects["https://spotify.link/SynShort1"] = "https://open.spotify.com/track/SynTrack0001AbCd?si=x"
            $0.webPages["https://open.spotify.com/embed/track/SynTrack0001AbCd"] = ResolveFixtures.data("track.html", folder: "spotify")
            $0.redirects["https://spotify.link/SynShort2"] = "https://example.org/landing"
        }
        harness.backend.search("Blue Lantern Placeholder Artist, Second Example", [
            ResolveJSON.track(900800001, "Blue Lantern", artists: ["Placeholder Artist", "Second Example"], duration: 246),
        ])
        let followed = await harness.run(.link("https://spotify.link/SynShort1"))
        #expect(followed.rows.map(\.tidalID) == [900800001])

        let elsewhere = await harness.run(.link("https://spotify.link/SynShort2"))
        #expect(elsewhere.failure?.kind == .shortLink)
        #expect(elsewhere.failure?.message == "This short link doesn't lead to a Spotify track, album or playlist.")
        #expect(!harness.server.requests.contains { $0.url.host == "example.org" })
    }

    @Test func aShortLinkThatOpensAWebPageGetsTheCopyTheLinkMessage() async {
        let harness = ResolveHarness()
        harness.backend.setUp { $0.webPages["https://spotify.link/SynShort3"] = Data("<html>Open in app</html>".utf8) }
        let events = await harness.run(.link("https://spotify.link/SynShort3"))
        #expect(events.failure?.message == "Short links can't be opened here. Open it in your browser, then copy the open.spotify.com link.")
    }
}
