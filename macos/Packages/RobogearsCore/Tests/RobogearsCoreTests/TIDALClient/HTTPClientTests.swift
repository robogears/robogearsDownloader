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
        #expect(response.networkInterference() == nil)
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
        await #expect(throws: RequestError.offline(detail: "the server didn't answer in time")) {
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
        await #expect(throws: RequestError.offline(detail: "the server didn't answer in time")) {
            try await client.perform(get())
        }
    }

    @Test func webPageInsteadOfJSONCountsAsOfflineNotNotFound() throws {
        let response = HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("captive-portal.html"))
        #expect(throws: RequestError.offline(detail: "a web page came back instead of the expected answer (a network sign-in page may be in the way)")) {
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

    // MARK: Out-of-range numbers (review finding)

    @Test func hugeRetryAfterOnAServerErrorDoesNotCrashTheCall() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .json(503, "{}", headers: ["Retry-After": "1e20"]) }
        await #expect(throws: RequestError.server(status: 503)) {
            try await server.makeClient(clock: clock).send(get())
        }
        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func hugeRetryAfterOnTooManyRequestsFailsAsBusyAtOnce() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(429, "{}", headers: ["Retry-After": "10000000000000000"])])
        await #expect(throws: RequestError.busy(retryAfter: .seconds(86_400))) {
            try await server.makeClient(clock: clock).send(get())
        }
        #expect(clock.sleeps.isEmpty)
    }

    // MARK: Total time limit for the whole call (review finding on G1-4)

    /// A stalled network: every try receives nothing until its inactivity
    /// limit, which the mock plays out on the virtual clock.
    private func stalledServer(_ clock: TIDALTestClock) -> TIDALMockServer {
        TIDALMockServer { request, _ in
            clock.advance(by: .seconds(request.timeoutInterval))
            return .failure(.timedOut)
        }
    }

    @Test func stalledNetworkGivesUpAfterSixtySecondsInAllNotAfterFiveTries() async throws {
        let clock = TIDALTestClock()
        let server = stalledServer(clock)
        await #expect(throws: RequestError.offline(detail: "the server didn't answer in time")) {
            try await server.makeClient(limits: .api, clock: clock).send(get())
        }
        // 30 s, a 1 s wait, then a retry cut to the 29 s that remain.
        #expect(clock.now() == TIDALClientFixtures.start.addingTimeInterval(60))
        #expect(server.requests.map(\.timeoutInterval) == [30, 29])
        #expect(clock.sleeps == [.seconds(1)])
    }

    @Test func tricklingAnswerGivesUpAtTheTotalLimitWithoutAnotherTry() async throws {
        let clock = TIDALTestClock()
        // Data keeps arriving, so only the 60 s total ends the try.
        let server = TIDALMockServer { _, _ in
            clock.advance(by: .seconds(60))
            return .failure(.timedOut)
        }
        await #expect(throws: RequestError.offline(detail: "the server didn't answer in time")) {
            try await server.makeClient(limits: .api, clock: clock).send(get())
        }
        #expect(server.requests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func backoffThatWouldRunPastTheLimitGivesUpInsteadOfWaiting() async throws {
        let clock = TIDALTestClock()
        // Each 503 takes 29.5 s to arrive. The first ends at 29.5 s, the 1 s
        // wait fits, the second ends at exactly 60 s, and the 2 s wait after
        // it would run past the limit.
        let server = TIDALMockServer { _, _ in
            clock.advance(by: .seconds(29.5))
            return .json(503, "{}")
        }
        await #expect(throws: RequestError.server(status: 503)) {
            try await server.makeClient(limits: .api, clock: clock).send(get())
        }
        #expect(server.requests.count == 2)
        #expect(server.requests.map(\.timeoutInterval) == [30, 29.5])
        #expect(clock.sleeps == [.seconds(1)])
        #expect(clock.now() == TIDALClientFixtures.start.addingTimeInterval(60))
    }

    @Test func quickServerErrorsStillGetAllFourRetriesWithinTheLimit() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .json(502, "{}") }
        await #expect(throws: RequestError.server(status: 502)) {
            try await server.makeClient(limits: .api, clock: clock).send(get())
        }
        #expect(server.requests.count == 5)
    }

    @Test func retryAfterOfSixtySecondsIsStillHonouredInsideTheTotalLimit() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(429, "{}", headers: ["Retry-After": "60"]), .json(200, "{}")])
        let response = try await server.makeClient(limits: .api, clock: clock).send(get())
        #expect(response.status == 200)
        #expect(clock.sleeps == [.seconds(60)])
        // The retry still gets its full limits: the asked-for pause isn't a stall.
        #expect(server.requests.map(\.timeoutInterval) == [30, 30])
    }

    @Test func audioHasNoTotalLimitSoEveryRetryIsTried() async throws {
        let clock = TIDALTestClock()
        let server = stalledServer(clock)
        await #expect(throws: RequestError.offline(detail: "the server didn't answer in time")) {
            try await server.makeClient(limits: .audio, clock: clock).send(get())
        }
        #expect(server.requests.count == 5)
        #expect(server.requests.map(\.timeoutInterval) == [60, 60, 60, 60, 60])
    }

    @Test func aLateRetryGetsOnlyTheTimeThatIsLeft() {
        let api = HTTPClient.Limits.api
        #expect(api.forTry(after: 1, timeLeft: .seconds(60)) == api)
        #expect(api.forTry(after: 1, timeLeft: .seconds(45)) == .init(inactivity: .seconds(30), total: .seconds(45)))
        #expect(api.forTry(after: 3, timeLeft: .seconds(12)) == .init(inactivity: .seconds(12), total: .seconds(12)))
        #expect(api.forTry(after: 1, timeLeft: nil) == api)
        #expect(HTTPClient.Limits.audio.forTry(after: 1, timeLeft: .seconds(5)) == .audio)
    }

    @Test func firstTryKeepsTheFullLimitsEvenAfterAFewMicroseconds() {
        // On the real clock a little time always passes before the first
        // try; cutting its limits would give every call its own session.
        let api = HTTPClient.Limits.api
        #expect(api.forTry(after: 0, timeLeft: .seconds(59.9999)) == api)
    }

    // MARK: Pages that are HTML by design (review finding on the Spotify page)

    @Test func expectedWebPageIsNotReadAsACaptivePortal() throws {
        let page = HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>embed</html>".utf8))
        #expect(page.networkInterference(expecting: .webPage) == nil)
        #expect(try page.requireOK(expecting: .webPage) == Data("<html>embed</html>".utf8))
        // The same page where data was expected is still the network in the way.
        #expect(page.networkInterference() == .offline(detail: HTTPResponse.webPageDetail))
    }

    @Test func expectedWebPageStillTreatsARedirectAsTheNetworkInTheWay() {
        let redirect = HTTPResponse(status: 302, headers: ["Location": "https://portal.example/"], body: Data())
        #expect(redirect.networkInterference(expecting: .webPage) == .offline(detail: "the request was redirected (a network sign-in page may be in the way)"))
    }

    @Test func webPageErrorFromAPageServiceIsAServerErrorNotOffline() async throws {
        let server = TIDALMockServer { _, _ in .response(status: 503, headers: ["Content-Type": "text/html"], body: Data("<html>down</html>".utf8), chunks: 1) }
        let request = HTTPRequest(method: .get, url: URL(string: "https://open.spotify.com/embed/playlist/x")!, headers: [:], expectedBody: .webPage)
        await #expect(throws: RequestError.server(status: 503)) {
            try await server.makeClient(clock: TIDALTestClock()).send(request)
        }
    }

    @Test func sharedErrorWordsNameNoService() {
        let errors: [RequestError] = [
            .busy(retryAfter: .seconds(5)), .offline(detail: RequestError.offlineDetail(for: .timedOut)),
            .offline(detail: HTTPResponse.webPageDetail), .server(status: 503),
        ]
        for error in errors {
            #expect(!error.description.contains("TIDAL"), "\(error)")
        }
    }

    @Test func subStatusIsReadEvenWhenTheErrorFieldIsNotText() {
        let response = HTTPResponse(status: 404, headers: [:], body: Data("{\"error\":{\"code\":7},\"subStatus\":2001}".utf8))
        #expect(response.subStatus == 2001)
    }

    // MARK: Secrets

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

    @Test func dumpingARequestNeverShowsHeadersBodyOrQuery() {
        let request = HTTPRequest(
            method: .post,
            url: URL(string: "https://cdn.example/audio.flac?token=signed-secret")!,
            headers: ["Authorization": "Bearer fake-access-1"],
            body: Data("refresh_token=fake-refresh-1".utf8)
        )
        var text = ""
        dump(request, to: &text)
        let leaks = ["signed-secret", "fake-access-1", "fake-refresh-1", "Authorization"].filter { text.contains($0) }
        #expect(leaks.isEmpty, "\(leaks)")
        #expect(text.contains("cdn.example"))
    }

    @Test func dumpingAResponseNeverShowsItsBody() {
        let response = HTTPResponse(status: 200, headers: ["Set-Cookie": "session=secret-cookie"], body: TIDALClientFixtures.data("refresh-rotated.json"))
        var text = ""
        dump(response, to: &text)
        #expect(!text.contains("secret-cookie"))
        // The body's bytes would be listed one per line as numbers.
        #expect(text.split(separator: "\n").count < 6, "\(text)")
    }
}
