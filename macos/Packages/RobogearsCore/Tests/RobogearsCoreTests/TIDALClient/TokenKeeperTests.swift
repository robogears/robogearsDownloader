import Foundation
import Testing
@testable import RobogearsCore

/// The token keeper (decision G1-5 with the skeptic's notes; G1-2 replace
/// and sign out; G1-8 refused versus offline).
@Suite("Token keeper")
struct TokenKeeperTests {
    let start = TIDALClientFixtures.start

    private func keeper(
        _ server: TIDALMockServer,
        store: TIDALMemoryStore,
        clock: TIDALTestClock = TIDALTestClock()
    ) -> TokenKeeper {
        TokenKeeper(store: store, client: server.makeClient(clock: clock), keys: TIDALClientFixtures.keys)
    }

    /// A stored sign-in whose access token ran out a minute ago.
    private func expired(country: String? = "GB", label: String = "test-renewal") -> TIDALCredential {
        TIDALClientFixtures.credential(country: country, expiresAt: start.addingTimeInterval(-60), label: label)
    }

    // MARK: Signed in or not

    @Test func nothingStoredMeansNotSignedInAndNoNetwork() async throws {
        let server = TIDALMockServer(replies: [])
        let keeper = keeper(server, store: TIDALMemoryStore())
        await #expect(throws: TokenError.notSignedIn) { try await keeper.currentToken() }
        #expect(await keeper.state == .signedOut)
        #expect(server.requests.isEmpty)
    }

    @Test func unreadableStoreIsReportedAndReadAgainWhenTheAppAsks() async throws {
        let store = TIDALMemoryStore(TIDALClientFixtures.credential(), readError: .unreadable(detail: "keychain locked"))
        let keeper = keeper(TIDALMockServer(replies: []), store: store)
        await #expect(throws: TokenError.storeUnreadable(.unreadable(detail: "keychain locked"))) {
            try await keeper.currentToken()
        }
        #expect(await keeper.state == .unreadable(.unreadable(detail: "keychain locked")))
        store.setReadError(nil)
        // Remembered until the app asks again (Settings opening, Try Again).
        await #expect(throws: TokenError.storeUnreadable(.unreadable(detail: "keychain locked"))) {
            try await keeper.currentToken()
        }
        #expect(await keeper.load() == .signedIn(TIDALAccount(userID: 123456789, country: TIDALCountry(code: "GB", isAssumed: false))))
        #expect(try await keeper.currentToken() == "fake-access-1")
    }

    @Test func unreadableStoreIsNotReadAgainOnEveryRequest() async throws {
        // With the Keychain, every read can bring up the macOS prompt again.
        let store = TIDALMemoryStore(readError: .unreadable(detail: "access denied"))
        let keeper = keeper(TIDALMockServer(replies: []), store: store)
        for _ in 0..<3 {
            await #expect(throws: TokenError.self) { try await keeper.currentToken() }
        }
        await #expect(throws: TokenError.self) { try await keeper.country() }
        await #expect(throws: TokenError.self) {
            try await keeper.withAuthorizedRequest { _ in "never sent" }
        }
        #expect(store.reads == 1)
        _ = await keeper.load()
        #expect(store.reads == 2)
    }

    @Test func stateIsNotLoadedUntilLoadedThenShowsTheAccount() async throws {
        let keeper = keeper(TIDALMockServer(replies: []), store: TIDALMemoryStore(TIDALClientFixtures.credential()))
        #expect(await keeper.state == .notLoaded)
        let state = await keeper.load()
        #expect(state == .signedIn(TIDALAccount(userID: 123456789, country: TIDALCountry(code: "GB", isAssumed: false))))
    }

    // MARK: Renewal

    @Test func unexpiredTokenIsUsedWithoutRenewingEvenAfterARelaunch() async throws {
        let server = TIDALMockServer(replies: [])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential()))
        #expect(try await keeper.currentToken() == "fake-access-1")
        #expect(server.requests.isEmpty)
    }

    @Test func expiredTokenRenewsWithTodaysRequest() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")])
        let store = TIDALMemoryStore(expired())
        let token = try await keeper(server, store: store, clock: clock).currentToken()
        #expect(token == "fake-access-2")

        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://auth.tidal.com/v1/oauth2/token")
        #expect(request.bodyText == "client_id=renewal-id&refresh_token=fake-refresh-1&grant_type=refresh_token&scope=r_usr%2Bw_usr%2Bw_sub")
        #expect(request.headers == [
            "User-Agent": "okhttp/5.3.2",
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Content-Type": "application/x-www-form-urlencoded",
            "Content-Length": String(request.body.count),
            "Authorization": "Basic " + Data("renewal-id:abc%2Fdef".utf8).base64EncodedString(),
        ])
        #expect(store.stored?.accessToken == "fake-access-2")
        #expect(store.stored?.expiresAt == clock.now().addingTimeInterval(3600 - 60))
    }

    @Test func tokenCountsAsExpiredFromTheExactExpiryMoment() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")])
        let credential = TIDALClientFixtures.credential(expiresAt: start)
        _ = try await keeper(server, store: TIDALMemoryStore(credential)).currentToken()
        #expect(server.requests.count == 1)
    }

    @Test func callersWaitingAtTheSameTimeShareOneRenewal() async throws {
        let gate = TIDALGate()
        let server = TIDALMockServer { _, _ in
            await gate.wait()
            return .fixture(200, "refresh-renewed.json")
        }
        let keeper = keeper(server, store: TIDALMemoryStore(expired()))
        async let first = keeper.currentToken()
        async let second = keeper.currentToken()
        async let third = keeper.currentToken()
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        let tokens = try await [first, second, third]
        #expect(tokens == ["fake-access-2", "fake-access-2", "fake-access-2"])
        #expect(server.requests.count == 1)
    }

    @Test func cancelledCallerLeavesAPendingRenewalAtOnceWhileOthersStillGetIt() async throws {
        let gate = TIDALGate()
        let server = TIDALMockServer { _, _ in
            await gate.wait()
            return .fixture(200, "refresh-renewed.json")
        }
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(server, store: store)
        let finished = TIDALFlag()
        // The caller that starts the renewal is the one that leaves.
        let leaving = Task {
            defer { finished.set() }
            return try await keeper.currentToken()
        }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let staying = Task { try await keeper.currentToken() }
        leaving.cancel()
        let leftWhileTheRenewalWasPending = try await finished.wait(upTo: .seconds(5))
        await gate.open()
        #expect(leftWhileTheRenewalWasPending)
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(try await staying.value == "fake-access-2")
        #expect(server.requests.count == 1)
        #expect(store.stored?.accessToken == "fake-access-2")
    }

    @Test func callerAlreadyCancelledWhenJoiningARenewalLeavesAtOnce() async throws {
        let gate = TIDALGate()
        let server = TIDALMockServer { _, _ in
            await gate.wait()
            return .fixture(200, "refresh-renewed.json")
        }
        let keeper = keeper(server, store: TIDALMemoryStore(expired()))
        let first = Task { try await keeper.currentToken() }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let finished = TIDALFlag()
        let late = Task {
            defer { finished.set() }
            withUnsafeCurrentTask { $0?.cancel() }
            return try await keeper.currentToken()
        }
        let leftAtOnce = try await finished.wait(upTo: .seconds(5))
        await gate.open()
        #expect(leftAtOnce)
        await #expect(throws: CancellationError.self) { try await late.value }
        #expect(try await first.value == "fake-access-2")
    }

    @Test func rotatedRefreshTokenIsSaved() async throws {
        let store = TIDALMemoryStore(expired())
        _ = try await keeper(TIDALMockServer(replies: [.fixture(200, "refresh-rotated.json")]), store: store).currentToken()
        #expect(store.stored?.refreshToken == "fake-refresh-2")
    }

    @Test func renewalWithoutANewRefreshTokenKeepsTheOldOne() async throws {
        let store = TIDALMemoryStore(expired())
        _ = try await keeper(TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")]), store: store).currentToken()
        #expect(store.stored?.refreshToken == "fake-refresh-1")
    }

    @Test func renewalNeverOverwritesAStoredCountryButFillsAMissingOne() async throws {
        let withCountry = TIDALMemoryStore(expired(country: "GB"))
        _ = try await keeper(TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")]), store: withCountry).currentToken()
        #expect(withCountry.stored?.countryCode == "GB")

        let withoutCountry = TIDALMemoryStore(expired(country: nil))
        _ = try await keeper(TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")]), store: withoutCountry).currentToken()
        #expect(withoutCountry.stored?.countryCode == "DE")
    }

    @Test func refusedRenewalMarksTheSignInInvalidAndRemembersIt() async throws {
        let server = TIDALMockServer(replies: [.fixture(400, "refresh-invalid-grant.json")])
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(server, store: store)
        await #expect(throws: TokenError.signInInvalid) { try await keeper.currentToken() }
        #expect(await keeper.state == .invalid)
        #expect(store.stored?.isRefused == true)
        // Asking again doesn't call TIDAL again.
        await #expect(throws: TokenError.signInInvalid) { try await keeper.currentToken() }
        #expect(server.requests.count == 1)
        // A relaunch remembers it.
        let relaunched = TokenKeeper(store: store, client: server.makeClient(), keys: TIDALClientFixtures.keys)
        #expect(await relaunched.load() == .invalid)
    }

    @Test func unauthorisedRenewalAlsoMeansSignInAgain() async throws {
        let keeper = keeper(TIDALMockServer(replies: [.json(401, "{\"error\":\"invalid_client\"}")]), store: TIDALMemoryStore(expired()))
        await #expect(throws: TokenError.signInInvalid) { try await keeper.currentToken() }
    }

    @Test func offlineRenewalIsRetriedThenReportedOfflineNeverInvalid() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .failure(.notConnectedToInternet) }
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(server, store: store, clock: clock)
        await #expect(throws: RequestError.offline(detail: "no internet connection")) { try await keeper.currentToken() }
        #expect(server.requests.count == 5)
        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
        #expect(store.stored?.isRefused == false)
        if case .signedIn = await keeper.state {} else { Issue.record("an offline renewal must not change the sign-in state") }
    }

    @Test func serverErrorDuringRenewalIsReportedAsSuchNeverInvalid() async throws {
        let server = TIDALMockServer { _, _ in .json(503, "{}") }
        let store = TIDALMemoryStore(expired())
        await #expect(throws: RequestError.server(status: 503)) { try await keeper(server, store: store).currentToken() }
        #expect(store.stored?.isRefused == false)
    }

    @Test func forbiddenRenewalIsReportedButNotTreatedAsARefusedSignIn() async throws {
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(TIDALMockServer(replies: [.fixture(403, "api-forbidden.json")]), store: store)
        await #expect(throws: RequestError.forbidden(subStatus: 4005)) { try await keeper.currentToken() }
        #expect(store.stored?.isRefused == false)
    }

    @Test func busyRenewalIsReportedBusy() async throws {
        let server = TIDALMockServer { _, _ in .json(429, "{}", headers: ["Retry-After": "120"]) }
        let store = TIDALMemoryStore(expired())
        await #expect(throws: RequestError.busy(retryAfter: .seconds(120))) { try await keeper(server, store: store).currentToken() }
        #expect(store.stored?.isRefused == false)
    }

    @Test func portalPageAnsweringTheRenewalIsOfflineNeverInvalid() async throws {
        let portal = TIDALMockReply.response(status: 401, headers: ["Content-Type": "text/html"], body: TIDALClientFixtures.data("captive-portal.html"), chunks: 1)
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(TIDALMockServer(replies: [portal]), store: store)
        await #expect(throws: RequestError.offline(detail: HTTPResponse.webPageDetail)) { try await keeper.currentToken() }
        #expect(store.stored?.isRefused == false)
    }

    @Test func signInFromKeysThisVersionNoLongerHasAsksForAFreshSignIn() async throws {
        let server = TIDALMockServer(replies: [])
        let keeper = keeper(server, store: TIDALMemoryStore(expired(label: "keys-from-an-older-version")))
        await #expect(throws: TokenError.signInInvalid) { try await keeper.currentToken() }
        #expect(server.requests.isEmpty)
        #expect(await keeper.state == .invalid)
    }

    // MARK: 401 handling

    @Test func unauthorisedRequestRenewsOnceAndIsRetriedOnce() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential()))
        let log = TIDALTokenLog()
        let result = try await keeper.withAuthorizedRequest { token in
            log.append(token)
            if token == "fake-access-1" { throw RequestError.unauthorized(subStatus: 11003) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(log.all == ["fake-access-1", "fake-access-2"])
        #expect(server.requests.count == 1)
    }

    @Test func secondUnauthorisedIsReportedNotRetriedAgain() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "refresh-renewed.json")])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential()))
        let log = TIDALTokenLog()
        await #expect(throws: RequestError.unauthorized(subStatus: nil)) {
            try await keeper.withAuthorizedRequest { token -> String in
                log.append(token)
                throw RequestError.unauthorized(subStatus: nil)
            }
        }
        #expect(log.all.count == 2)
        #expect(server.requests.count == 1)
    }

    @Test func otherFailuresAreNotRetriedWithANewToken() async throws {
        let server = TIDALMockServer(replies: [])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential()))
        let log = TIDALTokenLog()
        await #expect(throws: RequestError.notFound(subStatus: 2001)) {
            try await keeper.withAuthorizedRequest { token -> String in
                log.append(token)
                throw RequestError.notFound(subStatus: 2001)
            }
        }
        #expect(log.all.count == 1)
        #expect(server.requests.isEmpty)
    }

    // MARK: Country

    @Test func countryFromTheSignInNeedsNoLookup() async throws {
        let server = TIDALMockServer(replies: [])
        let country = try await keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential())).country()
        #expect(country == TIDALCountry(code: "GB", isAssumed: false))
        #expect(server.requests.isEmpty)
    }

    @Test func missingCountryIsLookedUpOnceAndSaved() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "user-country.json")])
        let store = TIDALMemoryStore(TIDALClientFixtures.credential(country: nil))
        let keeper = keeper(server, store: store)
        #expect(try await keeper.country() == TIDALCountry(code: "NL", isAssumed: false))
        #expect(try await keeper.country() == TIDALCountry(code: "NL", isAssumed: false))
        #expect(server.requests.count == 1)
        let request = try #require(server.requests.first)
        #expect(request.url.absoluteString == "https://api.tidal.com/v1/users/123456789?countryCode=US")
        #expect(request.headers["Authorization"] == "Bearer fake-access-1")
        #expect(request.headers["X-Tidal-Platform"] == "android")
        #expect(store.stored?.countryCode == "NL")
    }

    @Test func countryTIDALWontSayIsAssumedUSForTheSessionAndShownAsAssumed() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "user-without-country.json")])
        let store = TIDALMemoryStore(TIDALClientFixtures.credential(country: nil))
        let keeper = keeper(server, store: store)
        #expect(try await keeper.country() == .assumedUS)
        #expect(try await keeper.country() == .assumedUS)
        #expect(server.requests.count == 1)
        #expect(store.stored?.countryCode == nil)
        #expect(await keeper.state == .signedIn(TIDALAccount(userID: 123456789, country: .assumedUS)))
    }

    @Test func noUserNumberMeansUSAssumedWithoutAPointlessLookup() async throws {
        let server = TIDALMockServer(replies: [])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential(userID: nil, country: nil)))
        #expect(try await keeper.country() == .assumedUS)
        #expect(server.requests.isEmpty)
    }

    @Test func countryLookupRefusedWith404IsAssumedUS() async throws {
        let server = TIDALMockServer(replies: [.fixture(404, "api-not-found.json")])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential(country: nil)))
        #expect(try await keeper.country() == .assumedUS)
    }

    @Test func countryLookupOfflineIsReportedNotGuessedAndTriedAgainLater() async throws {
        let server = TIDALMockServer { _, index in
            index < 5 ? .failure(.notConnectedToInternet) : .fixture(200, "user-country.json")
        }
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential(country: nil)))
        await #expect(throws: RequestError.offline(detail: "no internet connection")) { try await keeper.country() }
        #expect(server.requests.count == 5)
        #expect(try await keeper.country() == TIDALCountry(code: "NL", isAssumed: false))
    }

    @Test func cancelledCallerLeavesAPendingCountryLookupAtOnce() async throws {
        let gate = TIDALGate()
        let server = TIDALMockServer { _, _ in
            await gate.wait()
            return .fixture(200, "user-country.json")
        }
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential(country: nil)))
        let finished = TIDALFlag()
        let leaving = Task {
            defer { finished.set() }
            return try await keeper.country()
        }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        leaving.cancel()
        let leftWhileTheLookupWasPending = try await finished.wait(upTo: .seconds(5))
        await gate.open()
        #expect(leftWhileTheLookupWasPending)
        await #expect(throws: CancellationError.self) { try await leaving.value }
        // The lookup carried on, so the next caller gets its answer.
        #expect(try await keeper.country() == TIDALCountry(code: "NL", isAssumed: false))
        #expect(server.requests.count == 1)
    }

    // MARK: Sign-in and sign-out

    @Test func signingInAgainReplacesTheBrokenSignIn() async throws {
        let store = TIDALMemoryStore(TIDALClientFixtures.credential(access: "old", refused: true))
        let keeper = keeper(TIDALMockServer(replies: []), store: store)
        #expect(await keeper.load() == .invalid)
        var fresh = TIDALClientFixtures.credential(access: "new", refresh: "new-refresh", userID: 42, country: "SE")
        fresh.isRefused = true
        try await keeper.replaceSignIn(with: fresh)
        #expect(try await keeper.currentToken() == "new")
        #expect(store.stored?.accessToken == "new")
        #expect(store.stored?.isRefused == false)
        #expect(await keeper.state == .signedIn(TIDALAccount(userID: 42, country: TIDALCountry(code: "SE", isAssumed: false))))
    }

    @Test func renewalStillRunningWhenANewSignInArrivesCantOverwriteIt() async throws {
        let gate = TIDALGate()
        let server = TIDALMockServer { _, _ in
            await gate.wait()
            return .fixture(200, "refresh-rotated.json")
        }
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(server, store: store)
        let oldCaller = Task { try await keeper.currentToken() }
        while server.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await keeper.replaceSignIn(with: TIDALClientFixtures.credential(access: "new", refresh: "new-refresh"))
        await gate.open()
        // The caller that started under the old sign-in gets its renewal…
        #expect(try await oldCaller.value == "fake-access-2")
        // …but the new sign-in is what stays.
        #expect(try await keeper.currentToken() == "new")
        #expect(store.stored?.refreshToken == "new-refresh")
    }

    @Test func signOutRemovesTheSignInFromThisMac() async throws {
        let store = TIDALMemoryStore(TIDALClientFixtures.credential())
        let keeper = keeper(TIDALMockServer(replies: []), store: store)
        _ = await keeper.load()
        try await keeper.signOut()
        #expect(store.stored == nil)
        #expect(store.deletes == 1)
        #expect(await keeper.state == .signedOut)
        await #expect(throws: TokenError.notSignedIn) { try await keeper.currentToken() }
    }

    @Test func failedSaveKeepsTheSignInForThisSessionAndSaysSo() async throws {
        let store = TIDALMemoryStore()
        store.setWriteError(.unwritable(detail: "keychain refused"))
        let keeper = keeper(TIDALMockServer(replies: []), store: store)
        await #expect(throws: CredentialStoreError.unwritable(detail: "keychain refused")) {
            try await keeper.replaceSignIn(with: TIDALClientFixtures.credential())
        }
        #expect(try await keeper.currentToken() == "fake-access-1")
        #expect(await keeper.saveProblem == .unwritable(detail: "keychain refused"))
    }

    @Test func failedSaveAfterRenewalIsRecordedAndClearedByTheNextGoodSave() async throws {
        let clock = TIDALTestClock()
        let server = TIDALMockServer { _, _ in .fixture(200, "refresh-renewed.json") }
        let store = TIDALMemoryStore(expired())
        let keeper = keeper(server, store: store, clock: clock)
        store.setWriteError(.unwritable(detail: "disk full"))
        #expect(try await keeper.currentToken() == "fake-access-2")
        #expect(await keeper.saveProblem == .unwritable(detail: "disk full"))
        store.setWriteError(nil)
        clock.advance(by: .seconds(7200))
        _ = try await keeper.currentToken()
        #expect(await keeper.saveProblem == nil)
    }

    // MARK: State changes

    @Test func stateChangesFollowTheSignInAsItChanges() async throws {
        let server = TIDALMockServer(replies: [.fixture(400, "refresh-invalid-grant.json")])
        let keeper = keeper(server, store: TIDALMemoryStore(expired()))
        let log = TIDALStateLog(listeningTo: keeper)
        defer { log.stop() }
        let gb = TIDALState.signedIn(TIDALAccount(userID: 123456789, country: TIDALCountry(code: "GB", isAssumed: false)))
        let se = TIDALState.signedIn(TIDALAccount(userID: 42, country: TIDALCountry(code: "SE", isAssumed: false)))
        #expect(try await log.states(count: 1) == [.notLoaded])

        _ = await keeper.load()
        #expect(try await log.states(count: 2) == [.notLoaded, gb])

        // G1-8: a renewal refused mid-batch shows "Sign-in expired" at once.
        await #expect(throws: TokenError.signInInvalid) { try await keeper.currentToken() }
        #expect(try await log.states(count: 3) == [.notLoaded, gb, .invalid])

        try await keeper.replaceSignIn(with: TIDALClientFixtures.credential(userID: 42, country: "SE"))
        #expect(try await log.states(count: 4) == [.notLoaded, gb, .invalid, se])

        try await keeper.signOut()
        #expect(try await log.states(count: 5) == [.notLoaded, gb, .invalid, se, .signedOut])
    }

    @Test func stateChangesShowTheAssumedCountryOnceItIsSettled() async throws {
        let server = TIDALMockServer(replies: [.fixture(200, "user-without-country.json")])
        let keeper = keeper(server, store: TIDALMemoryStore(TIDALClientFixtures.credential(country: nil)))
        _ = await keeper.load()
        let log = TIDALStateLog(listeningTo: keeper)
        defer { log.stop() }
        let unknown = TIDALState.signedIn(TIDALAccount(userID: 123456789, country: nil))
        #expect(try await log.states(count: 1) == [unknown])
        _ = try await keeper.country()
        #expect(try await log.states(count: 2) == [unknown, .signedIn(TIDALAccount(userID: 123456789, country: .assumedUS))])
    }

    @Test func everyListenerHearsEachChange() async throws {
        let keeper = keeper(TIDALMockServer(replies: []), store: TIDALMemoryStore(TIDALClientFixtures.credential()))
        _ = await keeper.load()
        let first = TIDALStateLog(listeningTo: keeper)
        let second = TIDALStateLog(listeningTo: keeper)
        defer { first.stop(); second.stop() }
        _ = try await first.states(count: 1)
        _ = try await second.states(count: 1)
        try await keeper.signOut()
        #expect(try await first.states(count: 2).last == .signedOut)
        #expect(try await second.states(count: 2).last == .signedOut)
    }
}

private typealias TIDALState = TokenKeeper.State
