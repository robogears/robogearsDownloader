import Foundation
import Testing
@testable import RobogearsCore

@Suite("HTTP client")
struct HTTPClientTests {
    let url = URL(string: "https://api.tidal.com/v1/tracks/1001?countryCode=US")!

    private func get(_ headers: [String: String] = ["Accept": "application/json"]) -> HTTPRequest {
        HTTPRequest(method: .get, url: url, headers: headers)
    }

    @Test func sendsExactlyTheHeadersItWasGiven() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}")])
        let client = server.makeClient()
        _ = try await client.send(HTTPRequest(method: .get, url: url, headers: TIDALHeaders.api(bearer: "fake-access-1")))
        #expect(server.requests.first?.headers == [
            "User-Agent": "okhttp/5.3.2",
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Authorization": "Bearer fake-access-1",
            "X-Tidal-Platform": "android",
        ])
    }

    @Test func postBodyArrivesByteForByte() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}")])
        let body = "client_id=a%2Bb&scope=r_usr%2Bw_usr%2Bw_sub"
        _ = try await server.makeClient().send(HTTPRequest(
            method: .post, url: URL(string: "https://auth.tidal.com/v1/oauth2/token")!,
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8)
        ))
        #expect(server.requests.first?.method == "POST")
        #expect(server.requests.first?.bodyText == body)
    }

    @Test func percentEncodedQueryIsNotRewrittenOnTheWay() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}")])
        let query = URIComponent.query([(name: "query", value: "Mumford + Sons (Live) it's"), (name: "limit", value: "10")])
        let request = HTTPRequest(method: .get, url: URL(string: "https://api.tidal.com/v1/search/tracks?" + query)!, headers: [:])
        _ = try await server.makeClient().send(request)
        #expect(server.requests.first?.rawQuery == "query=Mumford%20%2B%20Sons%20(Live)%20it's&limit=10")
    }

    @Test func utf8SplitAcrossNetworkChunksDecodesIntact() async throws {
        let text = "{\"title\":\"Café Étoile 東京 😀\"}"
        let server = TIDALMockServer(replies: [.json(200, Data(text.utf8), chunks: 7)])
        let response = try await server.makeClient().send(get())
        #expect(response.text == text)
    }

    @Test func redirectsAreReturnedNotFollowedAndReadAsTheNetworkInTheWay() async throws {
        let server = TIDALMockServer(replies: [.redirect(to: URL(string: "https://elsewhere.example/x")!)])
        let response = try await server.makeClient().send(get(["Authorization": "Bearer fake-access-1"]))
        #expect(response.status == 302)
        #expect(server.requests.count == 1)
        #expect(throws: RequestError.offline(detail: "the request was redirected (a network sign-in page may be in the way)")) {
            try response.requireOK()
        }
    }

    @Test func networkAuthenticationRequiredIsOfflineAfterRetriesNotAServerError() async throws {
        let server = TIDALMockServer { _, _ in .response(status: 511, headers: ["Content-Type": "text/html"], body: Data("<html></html>".utf8), chunks: 1) }
        await #expect(throws: RequestError.offline(detail: HTTPResponse.webPageDetail)) {
            try await server.makeClient().send(get())
        }
    }

    @Test func jsonErrorBodyLabelledHTMLIsStillTIDALsAnswer() throws {
        let response = HTTPResponse(status: 404, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("api-not-found.json"))
        #expect(response.networkInterference == nil)
        #expect(throws: RequestError.notFound(subStatus: 2001)) { try response.requireOK() }
    }

    @Test func serverErrorIsRetriedAfterOneSecondAndThenSucceeds() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(503, "{}"), .json(200, "{\"ok\":true}")])
        let response = try await server.makeClient(clock: clock).send(get())
        #expect(response.status == 200)
        #expect(server.requests.count == 2)
        #expect(clock.sleeps == [.seconds(1)])
    }

    @Test func persistentServerErrorGivesUpAfterFourRetriesAsServerError() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .json(502, "{}") }
        await #expect(throws: RequestError.server(status: 502)) {
            try await server.makeClient(clock: clock).send(get())
        }
        #expect(server.requests.count == 5)
        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func tooManyRequestsHonoursRetryAfter() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(429, "{}", headers: ["Retry-After": "12"]), .json(200, "{}")])
        _ = try await server.makeClient(clock: clock).send(get())
        #expect(clock.sleeps == [.seconds(12)])
    }

    @Test func retryAfterOverTheLimitFailsAsBusyWithoutWaiting() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(429, "{}", headers: ["Retry-After": "300"])])
        await #expect(throws: RequestError.busy(retryAfter: .seconds(300))) {
            try await server.makeClient(clock: clock).send(get())
        }
        #expect(clock.sleeps.isEmpty)
        #expect(server.requests.count == 1)
    }

    @Test func notFoundIsReturnedOnceWithoutRetry() async throws {
        let server = TIDALMockServer { _, _ in .fixture(404, "api-not-found.json") }
        let response = try await server.makeClient().send(get())
        #expect(server.requests.count == 1)
        #expect(throws: RequestError.notFound(subStatus: 2001)) { try response.requireOK() }
    }

    @Test func forbiddenKeepsTIDALsSubStatus() async throws {
        let server = TIDALMockServer(replies: [.fixture(403, "api-forbidden.json")])
        let response = try await server.makeClient().send(get())
        #expect(throws: RequestError.forbidden(subStatus: 4005)) { try response.requireOK() }
    }

    @Test func droppedConnectionIsRetriedThenReportedOffline() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .failure(.networkConnectionLost) }
        await #expect(throws: RequestError.offline(detail: "the connection dropped")) {
            try await server.makeClient(clock: clock).send(get())
        }
        #expect(server.requests.count == 5)
    }

    @Test func shortWifiBlipIsAbsorbedByRetries() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.failure(.notConnectedToInternet), .failure(.notConnectedToInternet), .json(200, "{}")])
        let response = try await server.makeClient(clock: clock).send(get())
        #expect(response.status == 200)
        #expect(clock.sleeps == [.seconds(1), .seconds(2)])
    }

    @Test func performTriesOnceAndNamesTheTransportProblem() async throws {
        let server = TIDALMockServer { _, _ in .failure(.timedOut) }
        await #expect(throws: RequestError.offline(detail: "TIDAL didn't answer in time")) {
            try await server.makeClient().perform(get())
        }
        #expect(server.requests.count == 1)
    }

    @Test func cancellingTheTaskIsCancellationNotOffline() async throws {
        let server = TIDALMockServer { _, _ in .hang }
        let client = server.makeClient()
        let task = Task { try await client.send(HTTPRequest(method: .get, url: url, headers: [:])) }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.count == 1)
    }

    @Test func cancelledBeforeSendingNeverReachesTheNetwork() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{}")])
        let client = server.makeClient()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(HTTPRequest(method: .get, url: url, headers: [:]))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test func inactivityLimitIsSetOnEveryRequest() async throws {
        let server = TIDALMockServer { _, _ in .json(200, "{}") }
        _ = try await server.makeClient(limits: .api).send(get())
        _ = try await server.makeClient(limits: .audio).send(get())
        #expect(server.requests.map(\.timeoutInterval) == [30, 60])
    }

    @Test func totalTimeLimitEndsAStalledRequest() async throws {
        // Real time, kept short: the total limit is URLSession's own timer.
        let server = TIDALMockServer { _, _ in .hang }
        let client = server.makeClient(limits: .init(inactivity: .seconds(30), total: .milliseconds(300)), clock: TIDALTestClock())
        await #expect(throws: RequestError.offline(detail: "TIDAL didn't answer in time")) {
            try await client.perform(get())
        }
    }

    @Test func webPageInsteadOfJSONCountsAsOfflineNotNotFound() throws {
        let response = HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("captive-portal.html"))
        #expect(throws: RequestError.offline(detail: "a web page came back instead of TIDAL data (a network sign-in page may be in the way)")) {
            try response.requireJSONBody()
        }
    }

    @Test func emptyOrNonJSONBodyIsADecodingError() throws {
        #expect(throws: RequestError.decoding(detail: "empty answer")) {
            try HTTPResponse(status: 200, headers: [:], body: Data()).requireJSONBody()
        }
        #expect(throws: RequestError.decoding(detail: "not JSON")) {
            try HTTPResponse(status: 200, headers: [:], body: Data("ok".utf8)).requireJSONBody()
        }
    }

    @Test func requestDescriptionNeverShowsHeadersBodyOrQuery() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://cdn.example/audio.flac?token=signed-secret")!,
            headers: ["Authorization": "Bearer fake-access-1"],
            body: Data("refresh_token=fake-refresh-1".utf8)
        )
        let text = request.description
        let leaks = ["signed-secret", "fake-access-1", "fake-refresh-1"].contains { text.contains($0) }
        #expect(!leaks)
        #expect(text == "POST https://cdn.example/audio.flac (body 28 bytes)")
    }
}
