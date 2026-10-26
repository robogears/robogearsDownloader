import Foundation
import Synchronization

// MARK: - Request and response

/// One HTTP request, fully described before it is sent, so tests can compare
/// it field by field with the Electron app's request.
public struct HTTPRequest: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    /// What a good answer looks like, which decides whether a web page
    /// means "the network is in the way" (G1-9 skeptic note 3).
    public enum ExpectedBody: Sendable, Equatable {
        /// Anything but a web page: JSON from TIDAL's API and auth hosts,
        /// audio from its CDN. A web page instead is a captive portal or a
        /// proxy answering, so it reads as offline.
        case data
        /// A web page by design, such as the Spotify embed page. Only a
        /// redirect or a 511 counts as the network being in the way; a
        /// portal page answering with 200 can't be told apart here, so the
        /// page's own parser has to notice the content it needs is missing.
        case webPage
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var expectedBody: ExpectedBody

    public init(method: Method, url: URL, headers: [String: String], body: Data? = nil, expectedBody: ExpectedBody = .data) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.expectedBody = expectedBody
    }

    /// Method, host and path only. Headers carry Basic and Bearer secrets,
    /// bodies carry refresh tokens and device codes, and CDN queries carry
    /// signed links (reference L10), so none of them is ever printed.
    public var description: String {
        let host = url.host ?? ""
        return "\(method.rawValue) \(url.scheme ?? "https")://\(host)\(url.path)"
            + (body.map { " (body \($0.count) bytes)" } ?? "")
    }

    /// The same three parts, so `dump` can't list the headers, body or query
    /// either.
    public var customMirror: Mirror {
        Mirror(self, children: ["method": method.rawValue, "host": url.host ?? "", "path": url.path])
    }
}

/// A complete response. The body is the whole payload, so text decodes as
/// UTF-8 in one piece and a multi-byte character is never split (the
/// Electron app decoded chunk by chunk and could garble it: reference L1).
public struct HTTPResponse: Sendable, Equatable, CustomReflectable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Status and size only: a sign-in or renewal answer's body holds the
    /// access and refresh tokens, and `dump` would otherwise list its bytes.
    public var customMirror: Mirror {
        Mirror(self, children: ["status": status, "bodyBytes": body.count])
    }

    /// Header lookup ignoring case, as HTTP header names are case-insensitive.
    public func header(_ name: String) -> String? {
        let wanted = name.lowercased()
        return headers.first { $0.key.lowercased() == wanted }?.value
    }

    /// The body decoded as UTF-8 (invalid bytes become U+FFFD).
    public var text: String { String(decoding: body, as: UTF8.self) }
}

// MARK: - Errors

/// Why a request failed, named so the app can say what happened and what to
/// do (G1-4: rows show "TIDAL is busy", "No internet connection",
/// "Removed from TIDAL" instead of a false "not found").
///
/// The same rule serves TIDAL and the Spotify embed page (G1-4), so these
/// words name no service: the caller knows which one it asked and names it
/// ("TIDAL is busy, try again later"), and a Spotify failure can never read
/// as "Can't reach TIDAL".
///
/// Raw response bodies are never carried here: they can hold the server's
/// own text, and the cards keep raw server text out of everything the
/// person reads. `subStatus` is TIDAL's own error number, kept because the
/// TIDAL spike may show it tells "not in your country" from "removed".
public enum RequestError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 429 after the retries ran out, or a `Retry-After` longer than the
    /// policy's limit. `retryAfter` is what the server asked for, if it said.
    case busy(retryAfter: Duration?)
    /// No usable answer: no connection, a timeout, a dropped connection, a
    /// failed secure connection, a redirect, or a web page where data was
    /// expected (a captive portal; G1-9 skeptic note 3).
    case offline(detail: String)
    case notFound(subStatus: Int?)
    case forbidden(subStatus: Int?)
    case unauthorized(subStatus: Int?)
    /// 5xx after the retries ran out.
    case server(status: Int)
    /// Any other status. A redirect is not one of them: redirects are not
    /// followed and read as `offline`, the network being in the way.
    case unexpectedStatus(Int, subStatus: Int?)
    /// The answer arrived but wasn't the data expected.
    case decoding(detail: String)

    public var description: String {
        switch self {
        case let .busy(retryAfter):
            return "The server is busy" + (retryAfter.map { " (asked to wait \($0.timeInterval) s)" } ?? "")
        case let .offline(detail): return "Can't reach the server: \(detail)"
        case let .notFound(sub): return "Not found (404\(Self.sub(sub)))"
        case let .forbidden(sub): return "Refused (403\(Self.sub(sub)))"
        case let .unauthorized(sub): return "Not authorised (401\(Self.sub(sub)))"
        case let .server(status): return "Server error (\(status))"
        case let .unexpectedStatus(status, sub): return "Unexpected answer (\(status)\(Self.sub(sub)))"
        case let .decoding(detail): return "Unreadable answer: \(detail)"
        }
    }

    private static func sub(_ value: Int?) -> String { value.map { ", sub-status \($0)" } ?? "" }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    /// Plain words for a transport failure, for the activity log and rows.
    static func offlineDetail(for code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "the server didn't answer in time"
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return "no internet connection"
        case .networkConnectionLost: return "the connection dropped"
        case .cannotFindHost, .dnsLookupFailed: return "couldn't find the server"
        case .cannotConnectToHost: return "couldn't connect to the server"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
             .clientCertificateRejected, .clientCertificateRequired:
            return "the secure connection failed (a network sign-in page may be in the way)"
        default: return "network error \(code.rawValue)"
        }
    }
}

extension HTTPResponse {
    /// The body when the status is 200, otherwise the matching
    /// `RequestError`. 200 exactly, as every Electron caller checked.
    /// Pass `.webPage` for a page that is HTML by design (the Spotify embed
    /// page), so the page itself isn't read as a captive portal.
    public func requireOK(expecting expected: HTTPRequest.ExpectedBody = .data) throws(RequestError) -> Data {
        if let interference = networkInterference(expecting: expected) { throw interference }
        switch status {
        case 200: return body
        case 401: throw .unauthorized(subStatus: subStatus)
        case 403: throw .forbidden(subStatus: subStatus)
        case 404: throw .notFound(subStatus: subStatus)
        case 429: throw .busy(retryAfter: nil)
        case 500...599: throw .server(status: status)
        default: throw .unexpectedStatus(status, subStatus: subStatus)
        }
    }

    /// The body if it looks like JSON. A web page instead means a captive
    /// portal or a proxy is answering for TIDAL, which is a network problem
    /// and must never become "not found" or a parse error (G1-9 skeptic 3).
    public func requireJSONBody() throws(RequestError) -> Data {
        if looksLikeJSON { return body }
        if isWebPage { throw .offline(detail: Self.webPageDetail) }
        throw .decoding(detail: body.isEmpty ? "empty answer" : "not JSON")
    }

    /// Set when something between the Mac and the server answered instead
    /// of the server: a redirect (TIDAL's hosts never redirect, and
    /// redirects are never followed), a 511 "network authentication
    /// required", or, where data was expected, a web page instead of an
    /// error body. That is a captive portal or a proxy, which is a network
    /// problem, never "not found", "refused" or a parse error (G1-9
    /// skeptic note 3).
    public func networkInterference(expecting expected: HTTPRequest.ExpectedBody = .data) -> RequestError? {
        if (300...399).contains(status) {
            return .offline(detail: "the request was redirected (a network sign-in page may be in the way)")
        }
        if status == 511 || (expected == .data && !looksLikeJSON && isWebPage) {
            return .offline(detail: Self.webPageDetail)
        }
        return nil
    }

    static let webPageDetail = "a web page came back instead of the expected answer (a network sign-in page may be in the way)"

    private var looksLikeJSON: Bool {
        let first = body.first { !Self.isJSONWhitespace($0) }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    private var isWebPage: Bool {
        let first = body.first { !Self.isJSONWhitespace($0) }
        return first == UInt8(ascii: "<") || (header("Content-Type")?.lowercased().contains("text/html") ?? false)
    }

    /// TIDAL's own error number: `subStatus` on api.tidal.com, `sub_status`
    /// on auth.tidal.com. Nil when the body isn't such an error.
    public var subStatus: Int? {
        guard let parsed = try? JSONDecoder().decode(TIDALErrorBody.self, from: body) else { return nil }
        return parsed.subStatus ?? parsed.sub_status
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// The parts of a TIDAL error body this layer reads. Only the sub-status:
/// the OAuth `error` code is read by the sign-in flow on its own, so an
/// `error` field of an unexpected shape can't hide the sub-status.
private struct TIDALErrorBody: Decodable {
    let subStatus: Int?
    let sub_status: Int?
}

// MARK: - Header sets

/// The exact headers each kind of TIDAL call sends today. They differ per
/// call (header table in tidal-sign-in-and-tokens.md), and nothing is known
/// about which ones TIDAL actually needs, so each set is reproduced as is
/// until the TIDAL spike says otherwise (G1-7).
///
/// URLSession still adds its own `Accept-Language` where none is set and
/// honours the Mac's proxy settings; that is the closest a URLSession client
/// can come (G1-7 skeptic note 1). `User-Agent` and `Accept-Encoding` are
/// always set here, which overrides URLSession's own and keeps responses
/// uncompressed as today.
enum TIDALHeaders {
    static let userAgent = "okhttp/5.3.2"
    static let formContentType = "application/x-www-form-urlencoded"

    /// Device authorization (no Authorization header) and device-code poll
    /// (Basic with the sign-in pair). From `tidal_auth_node.js:76-83`.
    static func deviceFlow(bodyLength: Int, basicAuthorization: String? = nil) -> [String: String] {
        var headers = [
            "User-Agent": userAgent,
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Accept-Language": "en-US,en;q=0.9",
            "X-Platform": "android",
            "Content-Type": formContentType,
            "Content-Length": String(bodyLength),
        ]
        if let basicAuthorization { headers["Authorization"] = basicAuthorization }
        return headers
    }

    /// Token refresh: the plain `httpsRequest` defaults plus Basic, with no
    /// platform or language header (`tidal_lib.js:70-81, 129-141`).
    static func tokenRefresh(bodyLength: Int, basicAuthorization: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Content-Type": formContentType,
            "Content-Length": String(bodyLength),
            "Authorization": basicAuthorization,
        ]
    }

    /// Every api.tidal.com call (`tidalGet`, `tidal_lib.js:156-168`).
    static func api(bearer: String) -> [String: String] {
        [
            "User-Agent": userAgent,
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Authorization": "Bearer \(bearer)",
            "X-Tidal-Platform": "android",
        ]
    }
}

// MARK: - Client

/// Sends requests over URLSession with the retry rule, time limits and
/// redirect behaviour the cards ask for.
public final class HTTPClient: Sendable {
    /// Two kinds of time limit (G1-4 skeptic note 2). `inactivity` ends a
    /// try that receives nothing for that long; `total` ends the whole call,
    /// retries and backoff included, so a stalled network (a captive portal,
    /// a dead hotspot: G1-9) gives up after `total` instead of after five
    /// full tries. API and JSON calls get both; audio gets only inactivity,
    /// because a 100 MB Hi-Res file on a slow line would hit any fixed total
    /// limit every time.
    ///
    /// One wait doesn't count against `total`: a 429's `Retry-After`. That
    /// is the server answering at once and asking for a pause, not a stall,
    /// and G1-4 honours it up to 60 s, which a 60 s total that included it
    /// could never do.
    public struct Limits: Sendable, Equatable {
        public var inactivity: Duration
        public var total: Duration?

        public init(inactivity: Duration, total: Duration?) {
            self.inactivity = inactivity
            self.total = total
        }

        /// API and JSON calls: 30 s without data (as today) and about 60 s
        /// for the whole call (G1-4).
        public static let api = Limits(inactivity: .seconds(30), total: .seconds(60))
        /// Device sign-in requests: each gives up after 30 s (G1-3).
        public static let signIn = Limits(inactivity: .seconds(30), total: .seconds(30))
        /// Audio files and segments: 60 s without data, as today, no total.
        public static let audio = Limits(inactivity: .seconds(60), total: nil)

        /// The limits for a try when `timeLeft` remains of the call's total.
        /// A retry is cut to the time left, so it can't run past the end of
        /// the call. The first try always gets these limits unchanged: on the
        /// real clock a few microseconds have passed since the call began,
        /// and a limit cut by that much would give every call a session of
        /// its own and lose connection reuse.
        func forTry(after retriesSoFar: Int, timeLeft: Duration?) -> Limits {
            guard retriesSoFar > 0, let timeLeft, let total else { return self }
            return Limits(inactivity: min(inactivity, timeLeft), total: min(total, timeLeft))
        }
    }

    public let limits: Limits
    public let clock: any NetworkClock
    private let session: URLSession

    /// `sessionConfiguration` is copied; pass one only to change transport
    /// details (tests add a mock protocol). Defaults to an ephemeral session,
    /// so no response or cookie is ever cached on disk.
    public init(
        limits: Limits = .api,
        clock: any NetworkClock = SystemNetworkClock(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.limits = limits
        self.clock = clock
        let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = limits.inactivity.timeInterval
        configuration.timeoutIntervalForResource = limits.total?.timeInterval ?? Self.noTotalLimit
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// URLSession's resource timeout is a total limit; a week is its default.
    private static let noTotalLimit: TimeInterval = 7 * 24 * 3600

    /// One try, no retry. Transport failures become `RequestError.offline`;
    /// task cancellation stays `CancellationError`, never "offline".
    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await performOnce(request, limits: limits)
        } catch let error as URLError {
            throw RequestError.offline(detail: RequestError.offlineDetail(for: error.code))
        }
    }

    /// Sends with the retry rule. Returns the response for any status that
    /// is the server's answer (2xx, 3xx, 4xx other than 429), so callers
    /// decide what 400 or 404 means for them. Throws `.busy`, `.server` or
    /// `.offline` once retries run out or the call's total time limit is
    /// reached.
    ///
    /// The total limit is kept on the injected clock: before each backoff
    /// the call gives up if the wait would reach the end, and each retry's
    /// own limits are cut to the time left. A stalled API call therefore
    /// ends after 60 s (a sign-in step after 30 s) instead of after five
    /// 30 s tries and the backoff between them (review finding on G1-4).
    public func send(_ request: HTTPRequest, retry: RetryPolicy = .standard) async throws -> HTTPResponse {
        var deadline = limits.total.map { clock.now().addingTimeInterval($0.timeInterval) }
        var retriesSoFar = 0
        var lastError: RequestError?
        while true {
            let timeLeft = deadline.map { Duration.seconds(max($0.timeIntervalSince(clock.now()), 0)) }
            // A real sleep can overrun by a hair; never start a try with no time.
            if let timeLeft, timeLeft <= .zero, let lastError { throw lastError }
            let failure: RetryPolicy.Failure
            let finalError: RequestError
            do {
                let response = try await performOnce(request, limits: limits.forTry(after: retriesSoFar, timeLeft: timeLeft))
                guard RetryPolicy.isRetryable(status: response.status) else { return response }
                let retryAfter = response.header("Retry-After")
                    .flatMap { RetryPolicy.parseRetryAfter($0, now: clock.now()) }
                failure = .status(response.status, retryAfter: retryAfter)
                finalError = response.status == 429
                    ? .busy(retryAfter: retryAfter)
                    : response.networkInterference(expecting: request.expectedBody) ?? .server(status: response.status)
            } catch let error as URLError {
                failure = .transport(error.code)
                finalError = .offline(detail: RequestError.offlineDetail(for: error.code))
            }
            lastError = finalError
            switch retry.decision(after: failure, retriesSoFar: retriesSoFar) {
            case let .retry(after: wait):
                if case .status(429, retryAfter: .some(_)) = failure {
                    // The server asked for this pause; it isn't a stall (see Limits).
                    deadline = deadline?.addingTimeInterval(wait.timeInterval)
                }
                if let deadline, clock.now().addingTimeInterval(wait.timeInterval) >= deadline {
                    throw finalError
                }
                try await clock.sleep(for: wait)
                retriesSoFar += 1
            case .giveUp:
                throw finalError
            }
        }
    }

    /// Throws `URLError` for transport failures and `CancellationError` when
    /// the calling task was cancelled (URLSession reports that as
    /// `URLError.cancelled`, which must not read as a network problem).
    private func performOnce(_ request: HTTPRequest, limits tryLimits: Limits) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = tryLimits.inactivity.timeInterval
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        // URLSession sets the total limit per session, not per request, so a
        // retry cut short gets a session of its own (see `Limits.forTry`).
        // Retries are rare, and the connection they would have reused has
        // usually just failed.
        let session = tryLimits == limits ? self.session : Self.session(like: self.session, limits: tryLimits)
        defer { if session !== self.session { session.finishTasksAndInvalidate() } }
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: RefuseRedirects.shared)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String { headers[key] = "\(value)" }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    /// A session configured like `base` (same transport, no cache, no
    /// cookies) with different time limits.
    private static func session(like base: URLSession, limits: Limits) -> URLSession {
        let configuration = base.configuration
        configuration.timeoutIntervalForRequest = limits.inactivity.timeInterval
        configuration.timeoutIntervalForResource = limits.total?.timeInterval ?? noTotalLimit
        return URLSession(configuration: configuration)
    }
}

/// Redirects are not followed, as in the Electron app. Following one would
/// carry the Bearer or Basic header toward a host nobody checked. The 3xx
/// is returned as the answer, and `networkInterference` reads it as
/// offline: TIDAL's hosts never redirect, so something on the network did.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RefuseRedirects()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

// MARK: - Streaming download

extension HTTPClient {
    /// Streams a GET's body straight into a new file at `file` as it
    /// arrives, so a 150 MB Hi-Res track is never held whole in memory
    /// (decision 4, item 2.20; the Electron app buffered DASH tracks whole).
    ///
    /// The same retry rule as `send`: a 429, a 5xx, a timeout or a dropped
    /// connection tries again from the start (the file is emptied first),
    /// and gives up as `busy`, `server` or `offline`. A body that ends
    /// before its `Content-Length` counts as a dropped connection, so a
    /// cut-off transfer is never mistaken for a whole file (reference
    /// download-pipeline.md bug 10). Redirects are refused, as in `send`.
    ///
    /// `file` must not exist yet: it is created exclusively, never
    /// replacing anything. It is removed again unless the answer is a
    /// complete 200, so a failure never leaves a partial file behind.
    ///
    /// Returns the response. For a 200 the body holds only the first bytes
    /// that arrived (up to 512), enough for `networkInterference` to tell a
    /// sign-in page from audio; the rest is in the file. For any other
    /// status the body is the server's answer (up to 64 KiB) and no file is
    /// kept. `progress` gets the bytes received so far in this try and the
    /// `Content-Length`, when the server sent one. Cancelling the task stops
    /// the transfer at once and throws `CancellationError`.
    public func download(
        _ request: HTTPRequest,
        to file: URL,
        retry: RetryPolicy = .standard,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void = { _, _ in }
    ) async throws -> HTTPResponse {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var keepFile = false
        defer {
            try? handle.close()
            if !keepFile { try? FileManager.default.removeItem(at: file) }
        }

        var deadline = limits.total.map { clock.now().addingTimeInterval($0.timeInterval) }
        var retriesSoFar = 0
        var lastError: RequestError?
        while true {
            let timeLeft = deadline.map { Duration.seconds(max($0.timeIntervalSince(clock.now()), 0)) }
            if let timeLeft, timeLeft <= .zero, let lastError { throw lastError }
            try handle.truncate(atOffset: 0)
            let failure: RetryPolicy.Failure
            let finalError: RequestError
            do {
                let attempt = try await streamOnce(
                    request, into: handle, limits: limits.forTry(after: retriesSoFar, timeLeft: timeLeft), progress: progress
                )
                let status = attempt.response.status
                if status == 200 && attempt.isComplete {
                    try handle.synchronize()
                    keepFile = true
                    return attempt.response
                }
                if status == 200 {
                    failure = .transport(.networkConnectionLost)
                    finalError = .offline(detail: RequestError.offlineDetail(for: .networkConnectionLost))
                } else {
                    guard RetryPolicy.isRetryable(status: status) else { return attempt.response }
                    let retryAfter = attempt.response.header("Retry-After")
                        .flatMap { RetryPolicy.parseRetryAfter($0, now: clock.now()) }
                    failure = .status(status, retryAfter: retryAfter)
                    finalError = status == 429
                        ? .busy(retryAfter: retryAfter)
                        : attempt.response.networkInterference(expecting: request.expectedBody) ?? .server(status: status)
                }
            } catch let error as URLError {
                failure = .transport(error.code)
                finalError = .offline(detail: RequestError.offlineDetail(for: error.code))
            }
            lastError = finalError
            switch retry.decision(after: failure, retriesSoFar: retriesSoFar) {
            case let .retry(after: wait):
                if case .status(429, retryAfter: .some(_)) = failure {
                    deadline = deadline?.addingTimeInterval(wait.timeInterval)
                }
                if let deadline, clock.now().addingTimeInterval(wait.timeInterval) >= deadline {
                    throw finalError
                }
                try await clock.sleep(for: wait)
                retriesSoFar += 1
            case .giveUp:
                throw finalError
            }
        }
    }

    /// One try of `download`. Throws `URLError` for transport failures,
    /// `CancellationError` when the calling task was cancelled, and the
    /// file system's error when writing fails (a full disk is not retried).
    private func streamOnce(
        _ request: HTTPRequest,
        into handle: FileHandle,
        limits tryLimits: Limits,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (response: HTTPResponse, isComplete: Bool) {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = tryLimits.inactivity.timeInterval
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        // A session of its own per try: data arrives through a delegate,
        // which URLSession only takes per session. The serial queue keeps
        // the file writes in order.
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = tryLimits.inactivity.timeInterval
        configuration.timeoutIntervalForResource = tryLimits.total?.timeInterval ?? Self.noTotalLimit
        let receiver = StreamingReceiver(handle: handle, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let streamingSession = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        defer { streamingSession.finishTasksAndInvalidate() }
        let task = streamingSession.dataTask(with: urlRequest)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if receiver.begin(continuation) { task.resume() }
            }
        } onCancel: {
            receiver.markCancelled()
            task.cancel()
        }
    }
}

/// Receives one streamed body: writes a 200's bytes to the file as they
/// arrive, keeps any other answer's (short) body for the caller, and
/// resumes the waiting download once the transfer ends. Its callbacks run
/// on a serial queue; the lock covers the state the cancelling task also
/// touches.
private final class StreamingReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Outcome = (response: HTTPResponse, isComplete: Bool)

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var cancelled = false
        var status = 0
        var headers: [String: String] = [:]
        var expected: Int64?
        var received: Int64 = 0
        var kept = Data()
        var writeError: (any Error)?
    }

    /// For a 200, enough of the start to recognise a web page.
    static let sniffBytes = 512
    /// For an error answer: TIDAL's error bodies are small JSON.
    static let errorBodyBytes = 64 * 1024

    private let state = Mutex(State())
    private let handle: FileHandle
    private let progress: @Sendable (Int64, Int64?) -> Void

    init(handle: FileHandle, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.handle = handle
        self.progress = progress
    }

    /// Installs the continuation. False when the caller was cancelled
    /// before the transfer started; the continuation is resumed here then.
    func begin(_ continuation: CheckedContinuation<Outcome, any Error>) -> Bool {
        let alreadyCancelled = state.withLock { state -> Bool in
            if state.cancelled { return true }
            state.continuation = continuation
            return false
        }
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
        return !alreadyCancelled
    }

    func markCancelled() {
        state.withLock { $0.cancelled = true }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key] = "\(value)" }
        }
        let expected = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        state.withLock { state in
            state.status = http.statusCode
            state.headers = headers
            state.expected = expected
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let status = state.withLock { $0.status }
        guard status == 200 else {
            state.withLock { state in
                let room = Self.errorBodyBytes - state.kept.count
                if room > 0 { state.kept.append(data.prefix(room)) }
            }
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            state.withLock { $0.writeError = error }
            dataTask.cancel()
            return
        }
        let (received, expected) = state.withLock { state -> (Int64, Int64?) in
            state.received += Int64(data.count)
            let room = Self.sniffBytes - state.kept.count
            if room > 0 { state.kept.append(data.prefix(room)) }
            return (state.received, state.expected)
        }
        progress(received, expected)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Never followed, as in `send`: the 3xx itself is the answer.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock { state -> (CheckedContinuation<Outcome, any Error>?, Result<Outcome, any Error>) in
            let continuation = state.continuation
            state.continuation = nil
            let result: Result<Outcome, any Error>
            if state.cancelled {
                result = .failure(CancellationError())
            } else if let writeError = state.writeError {
                result = .failure(writeError)
            } else if let error {
                result = .failure((error as? URLError) ?? URLError(.unknown))
            } else {
                let response = HTTPResponse(status: state.status, headers: state.headers, body: state.kept)
                let complete = state.status != 200 || state.expected.map { $0 == state.received } ?? true
                result = .success((response, complete))
            }
            return (continuation, result)
        }
        continuation?.resume(with: result)
    }
}
