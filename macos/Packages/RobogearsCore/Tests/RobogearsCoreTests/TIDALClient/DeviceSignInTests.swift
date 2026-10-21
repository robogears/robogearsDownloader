import Foundation
import Testing
@testable import RobogearsCore

/// Device-code sign-in: today's requests (tidal-sign-in-and-tokens.md,
/// component 8) plus decision G1-3's time limit, slow_down, retries while
/// waiting, link check and cancellation.
@Suite("Device sign-in")
struct DeviceSignInTests {
    let keys = TIDALClientFixtures.keys

    private func signIn(_ server: TIDALMockServer, clock: TIDALTestClock = TIDALTestClock()) -> DeviceSignIn {
        DeviceSignIn(client: server.makeClient(limits: .signIn, clock: clock), keys: keys)
    }

    private func authorization(
        interval: Duration = .seconds(2),
        lifetime: TimeInterval = 300,
        clock: TIDALTestClock
    ) -> DeviceAuthorization {
        DeviceAuthorization(
            verificationURL: URL(string: "https://link.tidal.com/ABCDE")!,
            userCode: "ABCDE",
            interval: interval,
            expiresAt: clock.now().addingTimeInterval(lifetime),
            deviceCode: "fake-device-code-0001"
        )
    }

    // MARK: Step 1

    @Test func deviceCodeRequestMatchesTodayByteForByte() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "device-authorization.json")])
        _ = try await signIn(server).requestAuthorization()
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://auth.tidal.com/v1/oauth2/device_authorization")
        #expect(request.bodyText == "client_id=signin%20id%2B1&scope=r_usr%2Bw_usr%2Bw_sub")
        #expect(request.headers == [
            "User-Agent": "okhttp/5.3.2",
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Accept-Language": "en-US,en;q=0.9",
            "X-Platform": "android",
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": "53",
        ])
        #expect(request.body.count == 53)
        #expect(request.headers["Authorization"] == nil)
        #expect(request.timeoutInterval == 30)
    }

    @Test func schemelessLinkGetsHttpsAndTheShortCodeIsShown() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(200, "device-authorization.json")])
        let auth = try await signIn(server, clock: clock).requestAuthorization()
        #expect(auth.verificationURL.absoluteString == "https://link.tidal.com/ABCDE")
        #expect(auth.userCode == "ABCDE")
        #expect(auth.interval == .seconds(2))
        #expect(auth.expiresAt == clock.now().addingTimeInterval(300))
    }

    @Test func missingLifetimeAndIntervalDefaultToTenMinutesAndFiveSeconds() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(200, "{\"deviceCode\":\"d\",\"verificationUriComplete\":\"https://link.tidal.com/X\"}")])
        let auth = try await signIn(server, clock: clock).requestAuthorization()
        #expect(auth.expiresAt == clock.now().addingTimeInterval(600))
        #expect(auth.interval == .seconds(5))
        #expect(auth.userCode == nil)
    }

    @Test func linksOutsideTIDALAreRefused() {
        let refused = [
            "https://evil.example/tidal.com",
            "https://tidal.com.evil.example/x",
            "https://eviltidal.com/x",
            "http://link.tidal.com/ABCDE",
            "https://tidal.com@evil.example/x",
            "https://user:pass@link.tidal.com/x",
            "https://link.tidal.com:8443/x",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "",
        ]
        for link in refused {
            #expect(DeviceSignIn.verificationURL(from: link) == nil, "\(link)")
        }
    }

    @Test func tidalHostsAndSubdomainsAreAccepted() {
        #expect(DeviceSignIn.verificationURL(from: "link.tidal.com/ABCDE")?.absoluteString == "https://link.tidal.com/ABCDE")
        #expect(DeviceSignIn.verificationURL(from: "https://tidal.com/device")?.absoluteString == "https://tidal.com/device")
        #expect(DeviceSignIn.verificationURL(from: "HTTPS://Link.TIDAL.com/ABCDE") != nil)
        #expect(DeviceSignIn.verificationURL(from: " https://listen.tidal.com/x \n") != nil)
    }

    @Test func linkOutsideTIDALEndsTheSignInWithoutOpeningIt() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{\"deviceCode\":\"d\",\"verificationUriComplete\":\"https://evil.example/login\"}")])
        await #expect(throws: DeviceSignInError.unexpectedVerificationURL) {
            try await signIn(server).requestAuthorization()
        }
    }

    @Test func refusedDeviceCodeRequestSaysTIDALDidntAccept() async throws {
        let server = TIDALMockServer(replies: [.fixture(400, "poll-invalid-client.json")])
        await #expect(throws: DeviceSignInError.refused(status: 400)) {
            try await signIn(server).requestAuthorization()
        }
    }

    @Test func missingDeviceCodeIsAnIncompleteAnswer() async throws {
        let server = TIDALMockServer(replies: [.json(200, "{\"verificationUriComplete\":\"link.tidal.com/X\"}")])
        await #expect(throws: DeviceSignInError.malformedResponse(detail: "no device code")) {
            try await signIn(server).requestAuthorization()
        }
    }

    @Test func noNetworkForTheFirstRequestSaysCantReachTIDAL() async throws {
        let server = TIDALMockServer { _, _ in .failure(.notConnectedToInternet) }
        await #expect(throws: DeviceSignInError.unreachable(.offline(detail: "no internet connection"))) {
            try await signIn(server).requestAuthorization()
        }
    }

    // MARK: Step 2

    @Test func pollWaitsFirstThenSendsTodaysRequest() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(200, "device-approved.json")])
        _ = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(clock.sleeps == [.seconds(2)])
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://auth.tidal.com/v1/oauth2/token")
        #expect(request.bodyText == "client_id=signin%20id%2B1&device_code=fake-device-code-0001"
            + "&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&scope=r_usr%2Bw_usr%2Bw_sub")
        #expect(request.headers["Authorization"] == "Basic " + Data("signin id+1:signin-secret".utf8).base64EncodedString())
        #expect(request.headers["X-Platform"] == "android")
        #expect(request.headers["Accept-Language"] == "en-US,en;q=0.9")
    }

    @Test func approvalBuildsTheCredentialWithTheRenewalPairLabel() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(200, "device-approved.json")])
        let credential = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(credential.accessToken == "fake-access-1")
        #expect(credential.refreshToken == "fake-refresh-1")
        #expect(credential.userID == 123456789)
        #expect(credential.countryCode == "GB")
        // now + expires_in (604800 s) − 60 s, measured after the 2 s wait.
        #expect(credential.expiresAt == clock.now().addingTimeInterval(604800 - 60))
        #expect(credential.clientPairLabel == "test-renewal")
        #expect(!credential.isRefused)
    }

    @Test func answerWithoutLifetimeOrUserAssumesOneHourAndNoCountry() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(200, "device-approved-minimal.json")])
        let credential = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(credential.expiresAt == clock.now().addingTimeInterval(3600 - 60))
        #expect(credential.userID == nil)
        #expect(credential.countryCode == nil)
    }

    @Test func pendingKeepsPollingAtTheSameInterval() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [
            .fixture(400, "poll-authorization-pending.json"),
            .fixture(400, "poll-authorization-pending.json"),
            .fixture(200, "device-approved.json"),
        ])
        _ = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(clock.sleeps == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(server.requests.count == 3)
    }

    @Test func slowDownAddsFiveSecondsToEveryLaterWait() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [
            .fixture(400, "poll-slow-down.json"),
            .fixture(400, "poll-authorization-pending.json"),
            .fixture(400, "poll-slow-down.json"),
            .fixture(200, "device-approved.json"),
        ])
        _ = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(clock.sleeps == [.seconds(2), .seconds(7), .seconds(7), .seconds(12)])
    }

    @Test func expiredCodeSaysExpired() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(400, "poll-code-expired.json")])
        await #expect(throws: DeviceSignInError.expired) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
    }

    @Test func declinedInTheBrowserSaysDenied() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(400, "poll-access-denied.json")])
        await #expect(throws: DeviceSignInError.denied) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
    }

    @Test func anyOtherOAuthErrorEndsTheSignInWithItsCode() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(400, "poll-invalid-client.json")])
        await #expect(throws: DeviceSignInError.rejected(error: "invalid_client")) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
    }

    @Test func pollingStopsAtTheCodesTimeLimit() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .fixture(400, "poll-authorization-pending.json") }
        await #expect(throws: DeviceSignInError.expired) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(interval: .seconds(5), lifetime: 60, clock: clock))
        }
        // Polls at 5, 10 … 55 s; at 60 s the code is dead, so no 12th poll.
        #expect(server.requests.count == 11)
        #expect(clock.now() == TIDALClientFixtures.start.addingTimeInterval(60))
    }

    @Test func tenMinuteDefaultLimitEndsAnAbandonedSignIn() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, index in
            index == 0
                ? .json(200, "{\"deviceCode\":\"d\",\"verificationUriComplete\":\"link.tidal.com/X\",\"interval\":5}")
                : .fixture(400, "poll-authorization-pending.json")
        }
        let flow = signIn(server, clock: clock)
        let auth = try await flow.requestAuthorization()
        await #expect(throws: DeviceSignInError.expired) { try await flow.waitForApproval(of: auth) }
        #expect(clock.now() == TIDALClientFixtures.start.addingTimeInterval(600))
        #expect(server.requests.count == 1 + 119)
    }

    @Test func networkBlipWhileWaitingKeepsPolling() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [
            .failure(.networkConnectionLost),
            .json(503, "{}"),
            .json(429, "{}", headers: ["Retry-After": "3"]),
            .fixture(200, "device-approved.json"),
        ])
        let credential = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(credential.accessToken == "fake-access-1")
        // The 429's Retry-After is added to the next wait.
        #expect(clock.sleeps == [.seconds(2), .seconds(2), .seconds(2), .seconds(5)])
    }

    @Test func networkDownUntilTheLimitSaysCantReachInsteadOfExpired() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .failure(.notConnectedToInternet) }
        await #expect(throws: DeviceSignInError.unreachable(.offline(detail: "no internet connection"))) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(lifetime: 20, clock: clock))
        }
    }

    @Test func pollAnsweredWithAnUnexpectedStatusIsARefusal() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(401, "{}")])
        await #expect(throws: DeviceSignInError.refused(status: 401)) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
    }

    @Test func approvalWithoutTokensIsAnIncompleteAnswer() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.json(200, "{\"user\":{\"userId\":1}}")])
        await #expect(throws: DeviceSignInError.malformedResponse(detail: "no tokens")) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
    }

    @Test func approvalThatIsntJSONIsAnIncompleteAnswerNotNoNetwork() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.response(status: 200, headers: ["Content-Type": "text/plain"], body: Data("OK".utf8), chunks: 1)])
        await #expect(throws: DeviceSignInError.malformedResponse(detail: "not JSON")) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
    }

    @Test func captivePortalPageWhileWaitingIsABlip() async throws {
        let clock = TIDALTestClock()
        let portal = TIDALMockReply.response(status: 400, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("captive-portal.html"), chunks: 1)
        let server = TIDALMockServer(replies: [portal, .fixture(200, "device-approved.json")])
        let credential = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(credential.accessToken == "fake-access-1")
    }

    @Test func plainTextRefusalWhileWaitingEndsTheSignIn() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .response(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad Request".utf8), chunks: 1) }
        await #expect(throws: DeviceSignInError.refused(status: 400)) {
            try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        }
        #expect(server.requests.count == 1)
    }

    @Test func captivePortalOnTheFirstRequestSaysCantReachTIDAL() async throws {
        let server = TIDALMockServer(replies: [.response(status: 200, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("captive-portal.html"), chunks: 1)])
        var unreachable = false
        do { _ = try await signIn(server).requestAuthorization() } catch let error as DeviceSignInError {
            if case .unreachable(.offline) = error { unreachable = true }
        }
        #expect(unreachable)
    }

    @Test func redirectedFirstRequestSaysCantReachNotRefused() async throws {
        let server = TIDALMockServer(replies: [.redirect(to: URL(string: "https://portal.example/login")!)])
        await #expect(throws: DeviceSignInError.unreachable(.offline(detail: "the request was redirected (a network sign-in page may be in the way)"))) {
            try await signIn(server).requestAuthorization()
        }
    }

    @Test func redirectWhileWaitingIsABlip() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.redirect(to: URL(string: "https://portal.example/login")!), .fixture(200, "device-approved.json")])
        let credential = try await signIn(server, clock: clock).waitForApproval(of: authorization(clock: clock))
        #expect(credential.accessToken == "fake-access-1")
    }

    @Test func cancellingStopsPollingStraightAway() async throws {
        let clock = TIDALParkedClock()
        let server = TIDALMockServer { _, _ in .fixture(400, "poll-authorization-pending.json") }
        let flow = DeviceSignIn(client: server.makeClient(limits: .signIn, clock: clock), keys: keys)
        let auth = DeviceAuthorization(
            verificationURL: URL(string: "https://link.tidal.com/X")!, userCode: nil,
            interval: .seconds(5), expiresAt: TIDALClientFixtures.start.addingTimeInterval(600), deviceCode: "d"
        )
        let task = Task { try await flow.waitForApproval(of: auth) }
        var waits = clock.started.makeAsyncIterator()
        _ = await waits.next()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test func authorizationDescriptionHidesTheDeviceCode() {
        let clock = TIDALTestClock()
        let text = String(describing: authorization(clock: clock))
        let leaks = text.contains("fake-device-code-0001")
        #expect(!leaks)
    }
}
