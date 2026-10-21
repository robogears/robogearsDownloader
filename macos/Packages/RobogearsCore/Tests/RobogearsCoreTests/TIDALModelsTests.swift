import Foundation
import Testing
@testable import RobogearsCore

/// Reads a synthetic fixture from Fixtures/tidal.
private func tidalFixture(_ file: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures/tidal"),
        "missing fixture \(file)"
    )
    return try Data(contentsOf: url)
}

private func decode<T: Decodable>(_ type: T.Type, fromFixture file: String) throws -> T {
    try JSONDecoder().decode(type, from: tidalFixture(file))
}

private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

@Suite struct TIDALTrackModelTests {
    @Test func fullTrackReplyDecodesEveryFieldTheAppReads() throws {
        let track = try decode(TIDALTrack.self, fromFixture: "track.json")
        #expect(track.id == 900_000_101)
        #expect(track.title == "Blue Lantern")
        #expect(track.version == "Extended Mix")
        #expect(track.duration == 245)
        #expect(track.trackNumber == 3)
        #expect(track.volumeNumber == 1)
        #expect(track.isrc == "ZZX001100003")
        #expect(track.copyright == "2011 Placeholder Records")
        #expect(track.explicit == true)
        #expect(track.audioQuality == "LOSSLESS")
        #expect(track.audioModes == ["STEREO"])
        #expect(track.streamStartDate == "2011-05-02T00:00:00.000+0000")
        #expect(track.allowStreaming == true)
        #expect(track.streamReady == true)
        #expect(track.artist?.name == "Placeholder Artist")
        #expect(track.artists?.map(\.name) == ["Placeholder Artist", "Second Example"])
        #expect(track.album?.id == 800_000_100)
        #expect(track.album?.title == "Harbour Lights")
        #expect(track.album?.cover == "1a2b3c4d-0000-4000-8000-00000000abcd")
        #expect(track.album?.releaseDate == "2011-05-02")
    }

    @Test func hiResComesFromTheMediaMetadataTag() throws {
        let track = try decode(TIDALTrack.self, fromFixture: "track.json")
        #expect(track.isHiRes)
        let plain = TIDALTrack(id: 1, mediaMetadata: TIDALMediaMetadata(tags: ["LOSSLESS"]))
        #expect(!plain.isHiRes)
        #expect(!TIDALTrack(id: 2).isHiRes)
    }

    @Test func oneOddFieldDoesNotSinkTheWholeTrack() throws {
        // id as a string, duration and track number as decimals, a Bool sent
        // as text, tags as a string instead of a list, junk inside artists and
        // an album that isn't an object: everything readable still arrives.
        let track = try decode(TIDALTrack.self, fromFixture: "track-odd-shapes.json")
        #expect(track.id == 900_000_102)
        #expect(track.title == "Paper Harbour")
        #expect(track.duration == 200)
        #expect(track.trackNumber == 1)
        #expect(track.volumeNumber == nil)
        #expect(track.explicit == nil)
        #expect(track.version == nil)
        #expect(track.mediaMetadata?.tags == nil)
        #expect(track.artists?.count == 2)
        #expect(track.artists?.first?.name == "Third Placeholder")
        #expect(track.artists?.last?.id == 7_000_004)
        #expect(track.album == nil)
    }

    @Test func artistNamesFallBackToTheMainArtistWhenTheListIsEmpty() throws {
        let page = try decode(TIDALPage<TIDALPageItem>.self, fromFixture: "playlist-items.json")
        let paper = try #require(page.musicTracks.first { $0.id == 900_000_303 })
        #expect(paper.artistNames == ["Third Placeholder"])
    }

    @Test func blankArtistNamesAreDroppedLikeJavaScriptJoinDid() {
        let track = TIDALTrack(id: 1, artists: [
            TIDALArtist(name: "Placeholder Artist"), TIDALArtist(name: ""), TIDALArtist(name: nil),
        ])
        #expect(track.artistNames == ["Placeholder Artist"])
    }

    @Test func trackRoundTripsThroughCodable() throws {
        let track = try decode(TIDALTrack.self, fromFixture: "track.json")
        let again = try JSONDecoder().decode(TIDALTrack.self, from: JSONEncoder().encode(track))
        #expect(again == track)
    }
}

@Suite struct TIDALAlbumAndPlaylistModelTests {
    @Test func albumReplyDecodesReleaseDateCopyrightAndArtist() throws {
        let album = try decode(TIDALAlbum.self, fromFixture: "album.json")
        #expect(album.id == 800_000_100)
        #expect(album.title == "Harbour Lights")
        #expect(album.releaseDate == "2011-05-02")
        #expect(album.copyright == "(P) 2011 Placeholder Records")
        #expect(album.artist?.name == "Placeholder Artist")
        #expect(album.numberOfTracks == 11)
        #expect(album.version == nil)
        #expect(album.mediaMetadata?.tags?.contains("HIRES_LOSSLESS") == true)
    }

    @Test func coverURLTurnsEveryDashIntoASlash() throws {
        let album = try decode(TIDALAlbum.self, fromFixture: "album.json")
        #expect(album.coverURL()?.absoluteString ==
            "https://resources.tidal.com/images/1a2b3c4d/0000/4000/8000/00000000abcd/1280x1280.jpg")
        #expect(album.coverURL(size: 640)?.absoluteString.hasSuffix("/640x640.jpg") == true)
    }

    @Test func albumWithoutACoverIdHasNoCoverURL() {
        #expect(TIDALAlbum(id: 1).coverURL() == nil)
        #expect(TIDALAlbum(id: 1, cover: "").coverURL() == nil)
    }

    @Test func playlistIdIsAUUIDString() throws {
        let playlist = try decode(TIDALPlaylist.self, fromFixture: "playlist.json")
        #expect(playlist.uuid == "0f1e2d3c-4b5a-4968-8776-655443322110")
        #expect(playlist.title == "Late Ferry")
        #expect(playlist.numberOfTracks == 2)
        #expect(playlist.description == "Synthetic playlist for tests")
    }
}

@Suite struct TIDALPageModelTests {
    @Test func albumPageUnwrapsItemsAndDropsVideosAndIdlessRows() throws {
        let page = try decode(TIDALPage<TIDALPageItem>.self, fromFixture: "album-items.json")
        #expect(page.limit == 100)
        #expect(page.offset == 0)
        #expect(page.totalNumberOfItems == 5)
        // The bare number `42` can't be read and is skipped; the other four arrive.
        #expect(page.items.count == 4)
        #expect(page.musicTracks.map(\.id) == [900_000_201, 900_000_203])
    }

    @Test func wrapperMarkedVideoIsDroppedEvenWhenTheInnerTypeIsNotExactlyVideo() throws {
        // The Electron filter compared the inner `type` with exactly "video",
        // so this "Music Video" inside a `video` wrapper would have been queued.
        let page = try decode(TIDALPage<TIDALPageItem>.self, fromFixture: "album-items.json")
        let video = try #require(page.items.first { $0.track?.id == 900_000_202 })
        #expect(video.type == "video")
        #expect(video.musicTrack == nil)
    }

    @Test func playlistPageAcceptsBareTracksAndDropsTheirVideos() throws {
        let page = try decode(TIDALPage<TIDALPageItem>.self, fromFixture: "playlist-items.json")
        #expect(page.items.count == 3)
        #expect(page.items[1].type == "video")
        #expect(page.musicTracks.map(\.title) == ["Night/Day", "Paper Harbour"])
    }

    @Test func pageWithoutItemsDecodesAsEmpty() throws {
        let page = try decode(TIDALPage<TIDALPageItem>.self, json: #"{"limit":100,"offset":0}"#)
        #expect(page.items.isEmpty)
        let nullItems = try decode(TIDALSearchResult.self, json: #"{"items":null}"#)
        #expect(nullItems.items.isEmpty)
    }

    @Test func searchResultKeepsTIDALsOrder() throws {
        let result = try decode(TIDALSearchResult.self, fromFixture: "search-tracks.json")
        #expect(result.items.map(\.id) == [900_000_101, 900_000_104])
        #expect(result.items.map(\.isHiRes) == [true, false])
    }

    @Test func pageItemRoundTripsInTheWrapperForm() throws {
        let item = TIDALPageItem(type: "track", track: TIDALTrack(id: 5, title: "Blue Lantern"))
        let json = try #require(String(data: JSONEncoder().encode(item), encoding: .utf8))
        #expect(json.contains(#""item""#))
        let again = try JSONDecoder().decode(TIDALPageItem.self, from: Data(json.utf8))
        #expect(again == item)
    }
}

@Suite struct TIDALPlaybackAndSignInModelTests {
    @Test func playbackInfoKeepsTheManifestAndWhatTIDALDelivered() throws {
        let info = try decode(TIDALPlaybackInfo.self, json: """
            {"trackId": 900000101, "assetPresentation": "FULL", "audioMode": "STEREO",
             "audioQuality": "HI_RES_LOSSLESS", "manifestMimeType": "application/dash+xml",
             "manifestHash": "abc", "manifest": "PE1QRC8+", "bitDepth": 24, "sampleRate": 96000}
            """)
        #expect(info.trackId == 900_000_101)
        #expect(info.audioQuality == "HI_RES_LOSSLESS")
        #expect(info.manifestMimeType == "application/dash+xml")
        #expect(info.manifest == "PE1QRC8+")
        #expect(info.bitDepth == 24)
        #expect(info.sampleRate == 96_000)
    }

    @Test func deviceAuthorizationKeepsCodeLifetimeAndInterval() throws {
        let auth = try decode(TIDALDeviceAuthorization.self, fromFixture: "device-authorization.json")
        #expect(auth.deviceCode == "synthetic-device-code-0001")
        #expect(auth.userCode == "ABCDE")
        #expect(auth.expiresIn == 300)
        #expect(auth.pollInterval == 2)
    }

    @Test func schemelessVerificationLinkGetsHTTPS() throws {
        let auth = try decode(TIDALDeviceAuthorization.self, fromFixture: "device-authorization.json")
        #expect(auth.verificationURL?.absoluteString == "https://link.tidal.example.test/ABCDE")
        let withScheme = TIDALDeviceAuthorization(verificationUriComplete: "https://link.example.test/X")
        #expect(withScheme.verificationURL?.absoluteString == "https://link.example.test/X")
        let plainOnly = TIDALDeviceAuthorization(verificationUri: "link.example.test")
        #expect(plainOnly.verificationURL?.absoluteString == "https://link.example.test")
        #expect(TIDALDeviceAuthorization().verificationURL == nil)
    }

    @Test func missingPollIntervalDefaultsToFiveSeconds() {
        #expect(TIDALDeviceAuthorization().pollInterval == 5)
        #expect(TIDALDeviceAuthorization(interval: 0).pollInterval == 5)
    }

    @Test func tokenGrantReadsSnakeCaseFieldsAndTheUserBlock() throws {
        let grant = try decode(TIDALTokenGrant.self, fromFixture: "oauth-grant.json")
        #expect(grant.accessToken == "synthetic-access-value-not-real")
        #expect(grant.refreshToken == "synthetic-refresh-value-not-real")
        #expect(grant.tokenType == "Bearer")
        #expect(grant.expiresIn == 604_800)
        #expect(grant.user?.userId == 12345)
        #expect(grant.user?.countryCode == "NL")
    }

    @Test func printingATokenGrantNeverShowsTheTokens() throws {
        let grant = try decode(TIDALTokenGrant.self, fromFixture: "oauth-grant.json")
        for text in [grant.description, grant.debugDescription, String(describing: grant), "\(grant)"] {
            #expect(!text.contains("synthetic-access-value"))
            #expect(!text.contains("synthetic-refresh-value"))
        }
        #expect(grant.description.contains("<redacted>"))
    }

    @Test func refreshReplyWithoutUserOrLifetimeStillDecodes() throws {
        let grant = try decode(TIDALTokenGrant.self, json: #"{"access_token":"x"}"#)
        #expect(grant.accessToken == "x")
        #expect(grant.expiresIn == nil)
        #expect(grant.user == nil)
    }

    @Test func pendingPollErrorIsReadable() throws {
        let error = try decode(TIDALOAuthError.self, fromFixture: "oauth-pending.json")
        #expect(error.error == "authorization_pending")
        #expect(error.subStatus == 1002)
        #expect(error.status == 400)
    }

    @Test func apiErrorBodyIsTyped() throws {
        let error = try decode(TIDALErrorResponse.self, fromFixture: "api-error.json")
        #expect(error.status == 404)
        #expect(error.subStatus == 2001)
    }

    @Test func userReplyGivesTheCountryCode() throws {
        let user = try decode(TIDALUser.self, json: #"{"id": 12345, "countryCode": "DE"}"#)
        #expect(user.countryCode == "DE")
    }
}

@Suite struct TIDALQueueTrackTests {
    @Test func queueTrackCarriesEveryFieldARowNeeds() throws {
        let track = try decode(TIDALTrack.self, fromFixture: "track.json")
        let row = try #require(TIDALQueueTrack(track))
        #expect(row.tidalId == 900_000_101)
        #expect(row.id == 900_000_101)
        #expect(row.title == "Blue Lantern")
        #expect(row.version == "Extended Mix")
        #expect(row.artists == ["Placeholder Artist", "Second Example"])
        #expect(row.artistLine == "Placeholder Artist, Second Example")
        #expect(row.album == "Harbour Lights")
        #expect(row.duration == 245)
        #expect(row.isrc == "ZZX001100003")
        #expect(row.hiRes)
        #expect(row.explicit)
        #expect(row.audioQuality == "LOSSLESS")
    }

    @Test func trackWithoutAnIdCannotBeQueued() {
        #expect(TIDALQueueTrack(TIDALTrack(title: "No id")) == nil)
    }

    @Test func everyRowSourceGetsHiResFromTheSameTag() throws {
        // G4-10: imported rows never showed Hi-Res in Electron. Search, album
        // and playlist replies all go through the same initialiser now.
        let search = try decode(TIDALSearchResult.self, fromFixture: "search-tracks.json")
        #expect(search.items.compactMap(TIDALQueueTrack.init).map(\.hiRes) == [true, false])
        let album = try decode(TIDALPage<TIDALPageItem>.self, fromFixture: "album-items.json")
        #expect(album.musicTracks.compactMap(TIDALQueueTrack.init).map(\.hiRes) == [false, true])
    }

    @Test func displayTitleAddsTheEditionInParentheses() {
        let row = TIDALQueueTrack(tidalId: 1, title: "Blue Lantern", version: "Extended Mix")
        #expect(row.displayTitle == "Blue Lantern (Extended Mix)")
    }

    @Test func displayTitleDoesNotDoubleAnEditionTheTitleAlreadyHas() {
        let row = TIDALQueueTrack(tidalId: 1, title: "Blue Lantern (Extended Mix)", version: "extended mix")
        #expect(row.displayTitle == "Blue Lantern (Extended Mix)")
        let dashed = TIDALQueueTrack(tidalId: 2, title: "Blue Lantern - 2011 Remaster", version: "2011 Remaster")
        #expect(dashed.displayTitle == "Blue Lantern - 2011 Remaster")
    }

    @Test func blankEditionIsDroppedAndDisplayIsTheBareTitle() {
        let track = TIDALTrack(id: 1, title: "Blue Lantern", version: "   ")
        let row = TIDALQueueTrack(track)
        #expect(row?.version == nil)
        #expect(row?.displayTitle == "Blue Lantern")
    }

    @Test func titleForFileNamesStaysBareWhenTheRowShowsAnEdition() {
        // Rule 3: files are named from TIDAL's title only. `title` must never
        // pick up the edition, even though the row displays it.
        let row = TIDALQueueTrack(TIDALTrack(id: 1, title: "Blue Lantern", version: "Radio Edit"))
        #expect(row?.title == "Blue Lantern")
        #expect(row?.displayTitle == "Blue Lantern (Radio Edit)")
    }

    @Test func losslessOfferIsKnownOnlyWhenTIDALSaysSomething() {
        #expect(TIDALQueueTrack(tidalId: 1, title: "A", audioQuality: "LOSSLESS").offersLossless == true)
        #expect(TIDALQueueTrack(tidalId: 1, title: "A", audioQuality: "HI_RES").offersLossless == true)
        #expect(TIDALQueueTrack(tidalId: 1, title: "A", audioQuality: "HIGH").offersLossless == false)
        #expect(TIDALQueueTrack(tidalId: 1, title: "A", hiRes: true, audioQuality: "HIGH").offersLossless == true)
        #expect(TIDALQueueTrack(tidalId: 1, title: "A").offersLossless == nil)
    }

    @Test func savedQueueTrackRoundTripsAndToleratesMissingFields() throws {
        let row = TIDALQueueTrack(
            tidalId: 7, title: "Paper Harbour", version: "Live", artists: ["Third Placeholder"],
            album: "Crossing", duration: 210, isrc: "ZZX0", hiRes: true, explicit: true, audioQuality: "LOSSLESS"
        )
        let again = try JSONDecoder().decode(TIDALQueueTrack.self, from: JSONEncoder().encode(row))
        #expect(again == row)

        let sparse = try decode(TIDALQueueTrack.self, json: #"{"tidalId": 8}"#)
        #expect(sparse.title == "")
        #expect(sparse.artists.isEmpty)
        #expect(!sparse.hiRes)
        #expect(!sparse.explicit)
    }

    @Test func savedQueueTrackWithoutAnIdIsRejected() {
        #expect(throws: DecodingError.self) {
            try decode(TIDALQueueTrack.self, json: #"{"title": "No id"}"#)
        }
    }

    @Test func losslessTierRuleMatchesTheDownloaderSet() {
        for tier in ["LOSSLESS", "HI_RES_LOSSLESS", "HI_RES", "lossless"] {
            #expect(TIDALAudioQuality.isLosslessTier(tier))
        }
        for tier in ["HIGH", "LOW", "DOLBY_ATMOS", ""] {
            #expect(!TIDALAudioQuality.isLosslessTier(tier))
        }
        #expect(!TIDALAudioQuality.isLosslessTier(nil))
    }
}
