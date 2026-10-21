import Foundation
import Security
import Synchronization
@testable import RobogearsCore

// Test support for the TIDAL client lane. Every name carries a TIDAL prefix
// so it can't collide with helpers other lanes add to the same test target.
// No test here reaches the network: every session routes through
// `TIDALMockURLProtocol`, which answers from a per-test `TIDALMockServer`.

// MARK: - Fixtures

enum TIDALClientFixtures {
    static func data(_ name: String) -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/tidal-client"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing fixture \(name)")
        }
        return data
    }

    /// Fake keys with the awkward characters the real ones may hold: a
    /// space and a plus in an id, a literal percent escape in a secret.
    static let keys = ClientKeySet(
        signIn: ClientPair(label: "test-signin", clientID: "signin id+1", clientSecret: "signin-secret"),
        renewal: ClientPair(label: "test-renewal", clientID: "renewal-id", clientSecret: "abc%2Fdef")
    )

    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    static func credential(
        access: String = "fake-access-1",
        refresh: String = "fake-refresh-1",
        userID: Int? = 123456789,
        country: String? = "GB",
        expiresAt: Date = start.addingTimeInterval(3000),
        label: String = "test-renewal",
        refused: Bool = false
    ) -> TIDALCredential {
        TIDALCredential(
            accessToken: access, refreshToken: refresh, userID: userID, countryCode: country,
            expiresAt: expiresAt, clientPairLabel: label, isRefused: refused
        )
    }
}

// MARK: - Mock HTTP

struct TIDALRecordedRequest: Sendable {
    let method: String
    let url: URL
    /// Headers as the client set them, without the mock's routing header.
    let headers: [String: String]
    let body: Data
    let timeoutInterval: TimeInterval

    var bodyText: String { String(decoding: body, as: UTF8.self) }
    var path: String { url.path }
    /// The query exactly as it went on the wire, still percent-encoded.
    var rawQuery: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery }
}

enum TIDALMockReply: Sendable {
    case response(status: Int, headers: [String: String], body: Data, chunks: Int)
    case failure(URLError.Code)
    case redirect(to: URL)
    /// Never answers; only a time limit or cancellation ends the request.
    case hang

    static func json(_ status: Int, _ body: Data, headers: [String: String] = [:], chunks: Int = 1) -> TIDALMockReply {
        var all = ["Content-Type": "application/json"]
        all.merge(headers) { $1 }
        return .response(status: status, headers: all, body: body, chunks: chunks)
    }

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> TIDALMockReply {
        json(status, Data(text.utf8), headers: headers)
    }

    static func fixture(_ status: Int, _ name: String, headers: [String: String] = [:]) -> TIDALMockReply {
        json(status, TIDALClientFixtures.data(name), headers: headers)
    }
}

/// One fake server per test. Requests reach it through a routing header
/// set on the test's session, so tests running in parallel never see each
/// other's traffic.
final class TIDALMockServer: Sendable {
    typealias Handler = @Sendable (TIDALRecordedRequest, Int) async -> TIDALMockReply

    let route = UUID().uuidString
    private let handler: Handler
    private let recorded = Mutex<[TIDALRecordedRequest]>([])

    private static let registry = Mutex<[String: TIDALMockServer]>([:])

    /// Answers with `handler(request, indexOfRequest)`.
    init(handler: @escaping Handler) {
        self.handler = handler
        Self.registry.withLock { $0[route] = self }
    }

    /// Answers with the replies in order; a request past the end gets a 599
    /// so an unexpected extra request fails the test loudly.
    convenience init(replies: [TIDALMockReply]) {
        self.init { _, index in
            index < replies.count ? replies[index] : .json(599, "{\"unscripted\":true}")
        }
    }

    static func lookup(_ route: String) -> TIDALMockServer? {
        registry.withLock { $0[route] }
    }

    var requests: [TIDALRecordedRequest] { recorded.withLock { $0 } }

    func reply(to request: TIDALRecordedRequest) async -> TIDALMockReply {
        let index = recorded.withLock { list -> Int in
            list.append(request)
            return list.count - 1
        }
        return await handler(request, index)
    }

    func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TIDALMockURLProtocol.self]
        configuration.httpAdditionalHeaders = [TIDALMockURLProtocol.routeHeader: route]
        return configuration
    }

    func makeClient(limits: HTTPClient.Limits = .api, clock: any NetworkClock = TIDALTestClock()) -> HTTPClient {
        HTTPClient(limits: limits, clock: clock, sessionConfiguration: sessionConfiguration())
    }
}

final class TIDALMockURLProtocol: URLProtocol, @unchecked Sendable {
    static let routeHeader = "X-TIDAL-Mock-Route"
    private let work = Mutex<Task<Void, Never>?>(nil)

    // Always claim the request: a session with this protocol must never
    // fall through to the real network, even if routing failed.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let route = request.value(forHTTPHeaderField: Self.routeHeader),
              let server = TIDALMockServer.lookup(route) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let recorded = Self.record(request)
        let target = Delivery(target: self)
        let task = Task {
            let reply = await server.reply(to: recorded)
            guard !Task.isCancelled else { return }
            target.target.deliver(reply)
        }
        work.withLock { $0 = task }
    }

    /// URLProtocol instances are driven by URLSession's loader; handing one
    /// to the reply task is the standard mock pattern.
    private struct Delivery: @unchecked Sendable {
        let target: TIDALMockURLProtocol
    }

    override func stopLoading() {
        work.withLock { $0?.cancel() }
    }

    private func deliver(_ reply: TIDALMockReply) {
        guard let url = request.url else { return }
        switch reply {
        case let .response(status, headers, body, chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let pieces = max(chunks, 1)
            let size = max((body.count + pieces - 1) / pieces, 1)
            var offset = 0
            while offset < body.count {
                let end = min(offset + size, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // The client refuses redirects, so the 302 itself is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            break
        }
    }

    private static func record(_ request: URLRequest) -> TIDALRecordedRequest {
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: routeHeader)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        return TIDALRecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: headers,
            body: body,
            timeoutInterval: request.timeoutInterval
        )
    }
}

/// A one-shot gate a mock handler can wait on, so a test can hold a
/// response until several callers are waiting for it.
actor TIDALGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

// MARK: - Clocks

/// Virtual time: sleeping advances the clock instantly and is recorded, so
/// a 15 s backoff or a 10-minute sign-in runs in microseconds.
final class TIDALTestClock: NetworkClock {
    private let state: Mutex<(now: Date, sleeps: [Duration])>

    init(now: Date = TIDALClientFixtures.start) {
        state = Mutex((now: now, sleeps: []))
    }

    func now() -> Date { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.now = $0.now.addingTimeInterval(duration.timeInterval)
            $0.sleeps.append(duration)
        }
        await Task.yield()
        try Task.checkCancellation()
    }

    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.addingTimeInterval(duration.timeInterval) }
    }
}

/// A clock whose sleep really waits (for an hour), and reports when it
/// starts waiting. Used to show that cancelling stops a sign-in mid-wait.
final class TIDALParkedClock: NetworkClock {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    init() {
        (started, signal) = AsyncStream.makeStream(of: Void.self)
    }

    func now() -> Date { TIDALClientFixtures.start }

    func sleep(for duration: Duration) async throws {
        signal.yield()
        try await Task.sleep(for: .seconds(3600))
    }
}

// MARK: - Stores

/// A credential store in memory, with switchable failures.
final class TIDALMemoryStore: CredentialStore {
    private struct State {
        var credential: TIDALCredential?
        var readError: CredentialStoreError?
        var writeError: CredentialStoreError?
        var writes = 0
        var deletes = 0
    }

    private let state: Mutex<State>

    init(_ credential: TIDALCredential? = nil, readError: CredentialStoreError? = nil) {
        state = Mutex(State(credential: credential, readError: readError))
    }

    func read() throws(CredentialStoreError) -> TIDALCredential? {
        let snapshot = state.withLock { $0 }
        if let error = snapshot.readError { throw error }
        return snapshot.credential
    }

    func write(_ credential: TIDALCredential) throws(CredentialStoreError) {
        let error = state.withLock { state -> CredentialStoreError? in
            if let error = state.writeError { return error }
            state.credential = credential
            state.writes += 1
            return nil
        }
        if let error { throw error }
    }

    func delete() throws(CredentialStoreError) {
        state.withLock {
            $0.credential = nil
            $0.deletes += 1
        }
    }

    var stored: TIDALCredential? { state.withLock { $0.credential } }
    var writes: Int { state.withLock { $0.writes } }
    var deletes: Int { state.withLock { $0.deletes } }

    func setReadError(_ error: CredentialStoreError?) { state.withLock { $0.readError = error } }
    func setWriteError(_ error: CredentialStoreError?) { state.withLock { $0.writeError = error } }
}

/// A stand-in for the Security framework: records each query and answers
/// with scripted statuses, so the real login keychain is never touched.
final class TIDALFakeKeychain: KeychainAPI, @unchecked Sendable {
    struct Call {
        let kind: String
        let query: [String: Any]
        let attributes: [String: Any]?
    }

    private let lock = NSLock()
    private var item: Data?
    private var _calls: [Call] = []
    var copyStatusOverride: OSStatus?
    var updateStatusOverride: OSStatus?
    var addStatusOverride: OSStatus?
    var deleteStatusOverride: OSStatus?

    init(item: Data? = nil) {
        self.item = item
    }

    var calls: [Call] { lock.withLock { _calls } }
    var storedData: Data? { lock.withLock { item } }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            _calls.append(Call(kind: "copy", query: query, attributes: nil))
            if let copyStatusOverride { return (copyStatusOverride, nil) }
            return item.map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            _calls.append(Call(kind: "add", query: attributes, attributes: nil))
            if let addStatusOverride { return addStatusOverride }
            item = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            _calls.append(Call(kind: "update", query: query, attributes: attributes))
            if let updateStatusOverride { return updateStatusOverride }
            guard item != nil else { return errSecItemNotFound }
            item = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            _calls.append(Call(kind: "delete", query: query, attributes: nil))
            if let deleteStatusOverride { return deleteStatusOverride }
            guard item != nil else { return errSecItemNotFound }
            item = nil
            return errSecSuccess
        }
    }
}

/// A thread-safe list of the tokens a request body was given.
final class TIDALTokenLog: Sendable {
    private let list = Mutex<[String]>([])

    func append(_ token: String) { list.withLock { $0.append(token) } }
    var all: [String] { list.withLock { $0 } }
}
