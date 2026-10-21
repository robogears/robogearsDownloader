import Foundation
import Testing
@testable import RobogearsCore

/// The API wrappers: today's paths, parameter order and headers
/// (tidal-and-spotify-networking.md, component C), with G1-4's honest errors.
@Suite("TIDAL API")
struct TIDALAPITests {
    private func api(_ server: TIDALMockServer, credential: TIDALCredential = TIDALClientFixtures.credential()) -> TIDALAPI {
        let client = server.makeClient()
        let keeper = TokenKeeper(store: TIDALMemoryStore(credential), client: client, keys: TIDALClientFixtures.keys)
        return TIDALAPI(client: client, keeper: keeper)
    }

    private func page(_ count: Int) -> TIDALMockReply {
        let items = (0..<count).map { "{\"item\":{\"id\":\($0),\"title\":\"Track \($0)\"},\"type\":\"track\"}" }
        return .json(200, "{\"limit\":100,\"items\":[\(items.joined(separator: ","))]}")
    }

    @Test func trackRequestUsesTodaysPathHeadersAndCountry() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "track.json")])
        let body = try await api(server).track(id: 1001)
        #expect(body == TIDALClientFixtures.data("track.json"))
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://api.tidal.com/v1/tracks/1001?countryCode=GB")
        #expect(request.headers == [
            "User-Agent": "okhttp/5.3.2",
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Authorization": "Bearer fake-access-1",
            "X-Tidal-Platform": "android",
        ])
        #expect(request.body.isEmpty)
    }

    @Test func searchEncodesPlusAndKeepsQueryLimitCountryOrder() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{\"items\":[]}")])
        _ = try await api(server).searchTracks(query: "Mumford + Sons Blue Lantern")
        #expect(server.requests.first?.path == "/v1/search/tracks")
        #expect(server.requests.first?.rawQuery == "query=Mumford%20%2B%20Sons%20Blue%20Lantern&limit=10&countryCode=GB")
    }

    @Test func playbackInfoAsksForTheQualityInTodaysParameterOrder() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}"), .json(200, "{}")])
        let api = api(server)
        _ = try await api.playbackInfo(trackID: 1001, quality: .hiResLossless)
        _ = try await api.playbackInfo(trackID: 1001, quality: .lossless)
        #expect(server.requests.map(\.path) == ["/v1/tracks/1001/playbackinfopostpaywall", "/v1/tracks/1001/playbackinfopostpaywall"])
        #expect(server.requests.map(\.rawQuery) == [
            "countryCode=GB&audioquality=HI_RES_LOSSLESS&playbackmode=STREAM&assetpresentation=FULL",
            "countryCode=GB&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL",
        ])
    }

    @Test func albumAndPlaylistInfoUseTheirPaths() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}"), .json(200, "{}")])
        let api = api(server)
        _ = try await api.album(id: 2001)
        _ = try await api.playlist(id: "0c2fb3a1-1e2f-4c8a-9a51-1f3e8d2a7b11")
        #expect(server.requests.map(\.url.absoluteString) == [
            "https://api.tidal.com/v1/albums/2001?countryCode=GB",
            "https://api.tidal.com/v1/playlists/0c2fb3a1-1e2f-4c8a-9a51-1f3e8d2a7b11?countryCode=GB",
        ])
    }

    @Test func playlistIdIsEncodedAsOnePathSegment() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}")])
        _ = try await api(server).playlist(id: "abc great song/../x")
        #expect(server.requests.first?.url.absoluteString == "https://api.tidal.com/v1/playlists/abc%20great%20song%2F..%2Fx?countryCode=GB")
    }

    @Test func userLookupAndIsrcLookupUseTodaysParameters() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}"), .json(200, "{\"items\":[]}")])
        let api = api(server)
        _ = try await api.user(id: 123456789)
        _ = try await api.tracks(isrc: "GBAYE0000001")
        #expect(server.requests.map(\.url.absoluteString) == [
            "https://api.tidal.com/v1/users/123456789?countryCode=US",
            "https://api.tidal.com/v1/tracks?isrc=GBAYE0000001&countryCode=GB",
        ])
    }

    @Test func albumItemsArePagedAHundredAtATimeUntilAShortPage() async throws {
        let server = TIDALMockServer(replies: [page(100), page(100), page(3)])
        let pages = try await api(server).albumItemPages(id: 2001)
        #expect(pages.count == 3)
        #expect(server.requests.map(\.rawQuery) == [
            "countryCode=GB&limit=100&offset=0",
            "countryCode=GB&limit=100&offset=100",
            "countryCode=GB&limit=100&offset=200",
        ])
        #expect(server.requests.allSatisfy { $0.path == "/v1/albums/2001/items" })
    }

    @Test func exactMultipleOfAHundredCostsOneExtraEmptyPageAsToday() async throws {
        let server = TIDALMockServer(replies: [page(100), page(0)])
        let pages = try await api(server).playlistItemPages(id: "0c2fb3a1-1e2f-4c8a-9a51-1f3e8d2a7b11")
        #expect(pages.count == 2)
        #expect(server.requests.last?.path == "/v1/playlists/0c2fb3a1-1e2f-4c8a-9a51-1f3e8d2a7b11/items")
    }

    @Test func pageWithoutItemsEndsPaging() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{\"totalNumberOfItems\":0}")])
        let pages = try await api(server).albumItemPages(id: 2001)
        #expect(pages.count == 1)
    }

    @Test func serverThatIgnoresOffsetCantLoopForever() async throws {
        let server = TIDALMockServer { _, _ in page(100) }
        await #expect(throws: RequestError.decoding(detail: "TIDAL kept sending full pages past 50000 items")) {
            try await api(server).albumItemPages(id: 2001)
        }
        #expect(server.requests.count == TIDALAPI.maxPages)
    }

    @Test func removedTrackIsNotFoundNotAnEmptyResult() async throws {
        let server = TIDALMockServer(replies: [.fixture(404, "api-not-found.json")])
        await #expect(throws: RequestError.notFound(subStatus: 2001)) { try await api(server).track(id: 1) }
    }

    @Test func missingAlbumThrowsInsteadOfSilentlyReturningNothing() async throws {
        let server = TIDALMockServer(replies: [.fixture(404, "api-not-found.json")])
        await #expect(throws: RequestError.notFound(subStatus: 2001)) { try await api(server).album(id: 1) }
    }

    @Test func refusedStreamKeepsTIDALsSubStatus() async throws {
        let server = TIDALMockServer(replies: [.fixture(403, "api-forbidden.json")])
        await #expect(throws: RequestError.forbidden(subStatus: 4005)) {
            try await api(server).playbackInfo(trackID: 1, quality: .hiResLossless)
        }
    }

    @Test func busySearchIsRetriedAndThenSucceeds() async throws {
        let server = TIDALMockServer(replies: [.json(429, "{}", headers: ["Retry-After": "2"]), .json(200, "{\"items\":[]}")])
        let body = try await api(server).searchTracks(query: "Blue Lantern")
        #expect(String(decoding: body, as: UTF8.self) == "{\"items\":[]}")
        #expect(server.requests.count == 2)
    }

    @Test func captivePortalPageIsOfflineNotNotFound() async throws {
        let server = TIDALMockServer(replies: [
            .response(status: 200, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("captive-portal.html"), chunks: 1),
        ])
        await #expect(throws: RequestError.offline(detail: "a web page came back instead of TIDAL data (a network sign-in page may be in the way)")) {
            try await api(server).searchTracks(query: "Blue Lantern")
        }
    }

    @Test func redirectedAPICallIsOfflineNotUnexpected() async throws {
        let server = TIDALMockServer(replies: [.redirect(to: URL(string: "https://portal.example/login")!)])
        await #expect(throws: RequestError.offline(detail: "the request was redirected (a network sign-in page may be in the way)")) {
            try await api(server).track(id: 1001)
        }
    }

    @Test func revokedTokenIsRenewedOnceAndTheCallRetried() async throws {
        let server = TIDALMockServer { request, _ in
            if request.url.host == "auth.tidal.com" { return .fixture(200, "refresh-renewed.json") }
            return request.headers["Authorization"] == "Bearer fake-access-1"
                ? .fixture(401, "api-unauthorized.json")
                : .fixture(200, "track.json")
        }
        let body = try await api(server).track(id: 1001)
        #expect(body == TIDALClientFixtures.data("track.json"))
        #expect(server.requests.map { $0.url.host ?? "" } == ["api.tidal.com", "auth.tidal.com", "api.tidal.com"])
    }

    @Test func signedOutCallIsNotSignedInAndNeverReachesTIDAL() async throws {
        let server = TIDALMockServer(replies: [])
        let client = server.makeClient()
        let api = TIDALAPI(client: client, keeper: TokenKeeper(store: TIDALMemoryStore(), client: client, keys: TIDALClientFixtures.keys))
        await #expect(throws: TokenError.notSignedIn) { try await api.searchTracks(query: "Blue Lantern") }
        #expect(server.requests.isEmpty)
    }

    @Test func assumedCountryIsSentWhenTIDALNeverSaidOne() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{\"items\":[]}")])
        _ = try await api(server, credential: TIDALClientFixtures.credential(userID: nil, country: nil)).searchTracks(query: "x")
        #expect(server.requests.first?.rawQuery == "query=x&limit=10&countryCode=US")
    }
}
