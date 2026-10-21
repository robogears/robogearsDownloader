import Foundation
import Synchronization

/// The account's country, which every TIDAL call carries.
public struct TIDALCountry: Sendable, Equatable {
    public let code: String
    /// True when TIDAL never said and the app is using US. Settings shows
    /// that ("Country: US (assumed)"), because it changes what matches and
    /// what streams (G1-5 skeptic note 3).
    public let isAssumed: Bool

    public init(code: String, isAssumed: Bool) {
        self.code = code
        self.isAssumed = isAssumed
    }

    /// Today's fallback (`tidal_lib.js:108, 118`).
    public static let assumedUS = TIDALCountry(code: "US", isAssumed: true)
}

/// What Settings shows about the sign-in.
public struct TIDALAccount: Sendable, Equatable {
    public let userID: Int?
    /// Nil until it is known or assumed.
    public let country: TIDALCountry?

    /// Public so the app can build one for previews and view-model tests.
    public init(userID: Int?, country: TIDALCountry?) {
        self.userID = userID
        self.country = country
    }
}

/// Why no token could be handed out. Network trouble is never one of these:
/// it arrives as `RequestError` (offline, busy, server), so "offline" never
/// reads as "signed out" or "sign-in expired" (G1-5, G1-8).
public enum TokenError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Nothing is stored. The UI asks the person to sign in (G1-1); the app
    /// never quits over it (reference H1).
    case notSignedIn
    /// TIDAL refused to renew the sign-in, or it came from keys this version
    /// no longer has. Only signing in again helps (G1-8).
    case signInInvalid
    /// The stored sign-in exists but couldn't be read (G1-6 skeptic note 2).
    case storeUnreadable(CredentialStoreError)

    public var description: String {
        switch self {
        case .notSignedIn: return "Not signed in to TIDAL."
        case .signInInvalid: return "Your TIDAL sign-in is no longer valid. Sign in again to keep downloading."
        case let .storeUnreadable(error): return error.description
        }
    }
}

/// The one owner of the TIDAL sign-in (decision G1-5, "One token keeper").
///
/// Every request asks it for the current access token, so a long import
/// picks up a renewed one automatically. It replaces the Electron pattern of
/// each operation (and each child process) loading `token.json`, renewing on
/// its own and overwriting the others' writes (reference bugs 6 and 13).
///
/// - Renews when the clock reaches `expiresAt` (60 s early, as today), with
///   one renewal in flight shared by every caller.
/// - On a 401, renews once and retries the request once; a second 401 is a
///   real error. That also rescues a wrong Mac clock, since expiry is
///   clock-based (G1-5 skeptic note 2).
/// - Saves a rotated refresh token (the Electron app discarded it).
/// - A renewal TIDAL refuses (400 or 401 from the token endpoint) marks the
///   sign-in invalid and remembers it. A renewal that fails for network
///   reasons or a 5xx goes through the shared retry rule and is reported as
///   offline or busy, never as invalid (G1-5 skeptic note 1, G1-8).
/// - Caches the country: from sign-in, else renewal, else `/v1/users/{id}`,
///   else US for this session, reported as assumed.
public actor TokenKeeper {
    public enum State: Sendable, Equatable {
        /// `load()` hasn't run yet.
        case notLoaded
        case signedOut
        case signedIn(TIDALAccount)
        /// "Sign-in expired" in Settings, with Sign In Again (G1-8).
        case invalid
        case unreadable(CredentialStoreError)
    }

    private let store: any CredentialStore
    private let client: HTTPClient
    private let keys: ClientKeySet
    private let retry: RetryPolicy

    private var loaded = false
    private var loadError: CredentialStoreError?
    private var credential: TIDALCredential?
    /// Bumped by every sign-in and sign-out, so a renewal or country lookup
    /// that started before can't write its result over the new sign-in.
    private var generation = 0
    private var renewalTask: Task<TIDALCredential, any Error>?
    private var countryTask: Task<TIDALCountry, any Error>?
    private var assumedCountry: TIDALCountry?
    private var stateListeners: [Int: AsyncStream<State>.Continuation] = [:]
    private var nextListenerID = 0
    private var lastPublishedState: State?

    /// Set when the latest save failed (for example the Keychain refused).
    /// The sign-in still works for this session; Settings can say it won't
    /// survive a relaunch. Cleared by the next successful save.
    public private(set) var saveProblem: CredentialStoreError?

    /// `client` is the API client (`HTTPClient.Limits.api`); its clock is the
    /// keeper's clock too, so one injected clock drives expiry and backoff.
    public init(
        store: any CredentialStore,
        client: HTTPClient,
        keys: ClientKeySet = .builtIn,
        retry: RetryPolicy = .standard
    ) {
        self.store = store
        self.client = client
        self.keys = keys
        self.retry = retry
    }

    // MARK: State

    public var state: State {
        guard loaded else { return .notLoaded }
        if let loadError { return .unreadable(loadError) }
        guard let credential else { return .signedOut }
        if credential.isRefused { return .invalid }
        let country = credential.countryCode.map { TIDALCountry(code: $0, isAssumed: false) } ?? assumedCountry
        return .signedIn(TIDALAccount(userID: credential.userID, country: country))
    }

    /// Every change to `state`, starting with the current one, so Settings
    /// can follow it instead of asking after each operation: "Sign-in
    /// expired" the moment a renewal mid-batch is refused (G1-8), "Country:
    /// US (assumed)" once that is settled (G1-5 skeptic note 3). Each call
    /// returns its own stream; only the newest state is kept for a slow
    /// reader, and ending the iteration stops the updates.
    public func stateChanges() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextListenerID
        nextListenerID += 1
        stateListeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateListener(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeStateListener(_ id: Int) {
        stateListeners[id] = nil
    }

    /// Tells every listener about the current state if it changed. Called at
    /// the end of each step that can change it, never halfway through.
    private func publishState() {
        let current = state
        guard current != lastPublishedState else { return }
        lastPublishedState = current
        for listener in stateListeners.values { listener.yield(current) }
    }

    /// Reads the stored sign-in, and reads it again if the last read
    /// failed: a keychain that was locked may be unlocked now. This is the
    /// only place that retries a failed read; the app calls it when Settings
    /// opens or from Try Again. Signed in or not is a local check, with no
    /// network round trip (G1-1 skeptic note 1).
    @discardableResult
    public func load() -> State {
        if !loaded || loadError != nil { reload() }
        return state
    }

    private func reload() {
        do {
            credential = try store.read()
            loadError = nil
        } catch {
            credential = nil
            loadError = error
        }
        loaded = true
        publishState()
    }

    /// The stored sign-in, read once if nothing has read it yet. A failed
    /// read is remembered, not tried again here: with the Keychain each read
    /// can bring up the macOS password prompt, so an import would show it
    /// once or twice per TIDAL call, each time holding up the keeper while
    /// it waits. Only `load()` reads again (G1-6 skeptic note 2 asks only
    /// that this state never reads as signed out).
    private func requireCredential() throws -> TIDALCredential {
        if !loaded { reload() }
        if let loadError { throw TokenError.storeUnreadable(loadError) }
        guard let credential else { throw TokenError.notSignedIn }
        guard !credential.isRefused else { throw TokenError.signInInvalid }
        return credential
    }

    // MARK: Tokens

    /// The access token to send now, renewed first if the clock says it has
    /// run out.
    public func currentToken() async throws -> String {
        let credential = try requireCredential()
        if client.clock.now() < credential.expiresAt { return credential.accessToken }
        return try await renewed(replacing: credential.accessToken).accessToken
    }

    /// Runs `body` with the current token. If it throws
    /// `RequestError.unauthorized`, renews once and runs it once more with
    /// the new token. A second 401 is thrown as is.
    nonisolated public func withAuthorizedRequest<T: Sendable>(
        _ body: @Sendable (String) async throws -> T
    ) async throws -> T {
        let token = try await currentToken()
        do {
            return try await body(token)
        } catch let error as RequestError where error.isUnauthorized {
            let fresh = try await renewed(replacing: token)
            return try await body(fresh.accessToken)
        }
    }

    /// A credential whose access token is not `staleToken`, renewing only if
    /// nobody else already did. Every caller shares one renewal.
    private func renewed(replacing staleToken: String) async throws -> TIDALCredential {
        let current = try requireCredential()
        if current.accessToken != staleToken && client.clock.now() < current.expiresAt {
            return current
        }
        if let renewalTask { return try await Self.sharedValue(of: renewalTask) }

        let generation = self.generation
        let client = self.client, keys = self.keys, retry = self.retry
        let task = Task<TIDALCredential, any Error> {
            defer { finishRenewal(generation: generation) }
            do {
                let renewal = try await Self.renew(current, client: client, keys: keys, retry: retry)
                return apply(renewal, startedFrom: current, generation: generation)
            } catch is RenewalRefused {
                markRefused(generation: generation)
                throw TokenError.signInInvalid
            }
        }
        renewalTask = task
        return try await Self.sharedValue(of: task)
    }

    private func finishRenewal(generation: Int) {
        if self.generation == generation { renewalTask = nil }
    }

    /// Merges a renewal into the current sign-in (not into the copy the
    /// renewal started from, so a country found meanwhile isn't lost).
    private func apply(_ renewal: Renewal, startedFrom original: TIDALCredential, generation: Int) -> TIDALCredential {
        guard self.generation == generation, var updated = credential else {
            // A new sign-in or a sign-out happened meanwhile. The callers
            // waiting on this renewal started their requests under the old
            // sign-in, so they get its renewed token; nothing is saved.
            return renewal.applied(to: original)
        }
        updated = renewal.applied(to: updated)
        credential = updated
        save(updated)
        publishState()
        return updated
    }

    private func markRefused(generation: Int) {
        guard self.generation == generation, var refused = credential else { return }
        refused.isRefused = true
        credential = refused
        save(refused)
        publishState()
    }

    private func save(_ credential: TIDALCredential) {
        do {
            try store.write(credential)
            saveProblem = nil
        } catch {
            saveProblem = error
        }
    }

    // MARK: Country

    /// The country to send with every API call.
    public func country() async throws -> TIDALCountry {
        let credential = try requireCredential()
        if let code = credential.countryCode, !code.isEmpty {
            return TIDALCountry(code: code, isAssumed: false)
        }
        if let assumedCountry { return assumedCountry }
        guard let userID = credential.userID else {
            // No user number means the lookup can't work (today it asked for
            // /v1/users/undefined on every call: reference bug 13).
            assumedCountry = .assumedUS
            publishState()
            return .assumedUS
        }
        if let countryTask { return try await Self.sharedValue(of: countryTask) }

        let generation = self.generation
        let task = Task<TIDALCountry, any Error> {
            defer { finishCountryLookup(generation: generation) }
            return try await lookUpCountry(userID: userID, generation: generation)
        }
        countryTask = task
        return try await Self.sharedValue(of: task)
    }

    /// Waits for a renewal or country lookup that several callers share,
    /// but lets this caller leave the moment its own task is cancelled, so
    /// Cancel on an import or link stops "within a moment" (G1 missing card)
    /// even while a renewal is stuck on a stalled network. The shared work
    /// carries on for the others: its result is what the next caller needs.
    /// (Awaiting `Task.value` directly ignores the waiter's cancellation.)
    private static func sharedValue<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
        let waiter = SharedResultWaiter<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard waiter.install(continuation) else { return }
                Task { waiter.finish(with: await task.result) }
            }
        } onCancel: {
            waiter.finish(with: .failure(CancellationError()))
        }
    }

    private func finishCountryLookup(generation: Int) {
        if self.generation == generation { countryTask = nil }
    }

    /// `GET /v1/users/{id}?countryCode=US`, as today. A found country is
    /// saved; a definite "no country" (an answer without one, or a 4xx)
    /// means US for this session. Network trouble is thrown instead of
    /// guessing, so an offline moment can't pin the wrong country for the
    /// whole session.
    private func lookUpCountry(userID: Int, generation: Int) async throws -> TIDALCountry {
        let client = self.client, retry = self.retry
        let response = try await withAuthorizedRequest { token in
            let response = try await client.send(
                TIDALAPI.request(path: "/v1/users/\(userID)", parameters: [(name: "countryCode", value: "US")], bearer: token),
                retry: retry
            )
            if response.status == 401 { throw RequestError.unauthorized(subStatus: response.subStatus) }
            return response
        }
        if response.status == 200 {
            let body = try response.requireJSONBody()
            if let code = (try? JSONDecoder().decode(UserCountryBody.self, from: body))?.countryCode, !code.isEmpty {
                if self.generation == generation, var updated = credential {
                    updated.countryCode = code
                    credential = updated
                    save(updated)
                    publishState()
                }
                return TIDALCountry(code: code, isAssumed: false)
            }
        } else if !(400...499).contains(response.status) {
            _ = try response.requireOK()
        }
        if self.generation == generation {
            assumedCountry = .assumedUS
            publishState()
        }
        return .assumedUS
    }

    // MARK: Sign-in and sign-out

    /// Makes `credential` the one stored sign-in, replacing any other, at
    /// once (G1-2: the Electron app appended and kept using the old entry).
    /// The new sign-in is in effect for this session even if saving it
    /// throws; the error says it won't survive a relaunch.
    public func replaceSignIn(with credential: TIDALCredential) throws(CredentialStoreError) {
        generation += 1
        var fresh = credential
        fresh.isRefused = false
        self.credential = fresh
        loaded = true
        loadError = nil
        renewalTask = nil
        countryTask = nil
        assumedCountry = nil
        publishState()
        do {
            try store.write(fresh)
            saveProblem = nil
        } catch {
            saveProblem = error
            throw error
        }
    }

    /// Removes the sign-in from this Mac (G1-2). TIDAL itself isn't told;
    /// whether it has a revoke endpoint is part of the spike.
    public func signOut() throws(CredentialStoreError) {
        generation += 1
        credential = nil
        loaded = true
        loadError = nil
        renewalTask = nil
        countryTask = nil
        assumedCountry = nil
        saveProblem = nil
        publishState()
        try store.delete()
    }

    // MARK: Renewal request

    /// `POST /v1/oauth2/token` with the refresh grant, in today's field
    /// order, Basic auth from the stored pair (`tidal_lib.js:70-81`).
    static func refreshRequest(pair: ClientPair, refreshToken: String) -> HTTPRequest {
        let body = URIComponent.formBody([
            (name: "client_id", value: pair.clientID),
            (name: "refresh_token", value: refreshToken),
            (name: "grant_type", value: "refresh_token"),
            (name: "scope", value: DeviceSignIn.scope),
        ])
        return HTTPRequest(
            method: .post,
            url: DeviceSignIn.tokenURL,
            headers: TIDALHeaders.tokenRefresh(bodyLength: body.utf8.count, basicAuthorization: pair.basicAuthorization),
            body: Data(body.utf8)
        )
    }

    /// One renewal. Network failures, 429 and 5xx are retried by `send` and
    /// then thrown as `RequestError`; a 400 or 401 is TIDAL refusing.
    private static func renew(
        _ credential: TIDALCredential,
        client: HTTPClient,
        keys: ClientKeySet,
        retry: RetryPolicy
    ) async throws -> Renewal {
        guard let pair = keys.pair(labeled: credential.clientPairLabel) else {
            throw RenewalRefused()
        }
        let response = try await client.send(refreshRequest(pair: pair, refreshToken: credential.refreshToken), retry: retry)
        // A portal page must never count as TIDAL refusing: that mark is
        // remembered and would send the person to sign in again for nothing.
        if let interference = response.networkInterference() { throw interference }
        switch response.status {
        case 200:
            let body = try response.requireJSONBody()
            guard let token = try? JSONDecoder().decode(TIDALTokenResponse.self, from: body),
                  let access = token.accessToken, !access.isEmpty else {
                throw RequestError.decoding(detail: "the renewal answer had no access token")
            }
            return Renewal(
                accessToken: access,
                refreshToken: token.refreshToken.flatMap { $0.isEmpty ? nil : $0 },
                expiresAt: token.expiry(from: client.clock.now()),
                countryCode: token.countryCode.flatMap { $0.isEmpty ? nil : $0 }
            )
        case 400, 401:
            throw RenewalRefused()
        default:
            _ = try response.requireOK()
            throw RequestError.unexpectedStatus(response.status, subStatus: response.subStatus)
        }
    }
}

/// What a renewal changes.
private struct Renewal: Sendable {
    let accessToken: String
    /// A rotated refresh token, saved when TIDAL sends one.
    let refreshToken: String?
    let expiresAt: Date
    /// Used only when no country is stored yet; a stored country is never
    /// overwritten, as today.
    let countryCode: String?

    func applied(to base: TIDALCredential) -> TIDALCredential {
        var updated = base
        updated.accessToken = accessToken
        updated.expiresAt = expiresAt
        if let refreshToken { updated.refreshToken = refreshToken }
        if updated.countryCode == nil, let countryCode { updated.countryCode = countryCode }
        return updated
    }
}

private struct RenewalRefused: Error {}

private struct UserCountryBody: Decodable {
    let countryCode: String?
}

/// One caller's wait on a shared task: resumed once, by whichever comes
/// first, the shared result or this caller's cancellation.
private final class SharedResultWaiter<T: Sendable>: Sendable {
    private enum Slot {
        case empty
        case waiting(CheckedContinuation<T, any Error>)
        case settled(Result<T, any Error>)
        case resumed
    }

    private let slot = Mutex<Slot>(.empty)

    /// Stores the continuation, or resumes it at once if the outcome is
    /// already known (the caller was cancelled before it began waiting).
    /// Returns false in that case, so no watcher task is started.
    func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
        let early = slot.withLock { slot -> Result<T, any Error>? in
            guard case let .settled(result) = slot else {
                slot = .waiting(continuation)
                return nil
            }
            slot = .resumed
            return result
        }
        guard let early else { return true }
        continuation.resume(with: early)
        return false
    }

    func finish(with result: Result<T, any Error>) {
        let continuation = slot.withLock { slot -> CheckedContinuation<T, any Error>? in
            switch slot {
            case .empty:
                slot = .settled(result)
                return nil
            case let .waiting(continuation):
                slot = .resumed
                return continuation
            case .settled, .resumed:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}
