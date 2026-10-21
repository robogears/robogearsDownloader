import Foundation

// MARK: - Request and response

/// One HTTP request, fully described before it is sent, so tests can compare
/// it field by field with the Electron app's request.
public struct HTTPRequest: Sendable, Equatable, CustomStringConvertible {
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method, url: URL, headers: [String: String], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// Method, host and path only. Headers carry Basic and Bearer secrets,
    /// bodies carry refresh tokens and device codes, and CDN queries carry
    /// signed links (reference L10), so none of them is ever printed.
    public var description: String {
        let host = url.host ?? ""
        return "\(method.rawValue) \(url.scheme ?? "https")://\(host)\(url.path)"
            + (body.map { " (body \($0.count) bytes)" } ?? "")
    }
}

/// A complete response. The body is the whole payload, so text decodes as
/// UTF-8 in one piece and a multi-byte character is never split (the
/// Electron app decoded chunk by chunk and could garble it: reference L1).
public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
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
/// Raw response bodies are never carried here: they can hold TIDAL's own
/// text, and the cards keep raw server text out of everything the person
/// reads. `subStatus` is TIDAL's own error number, kept because the TIDAL
/// spike may show it tells "not in your country" from "removed".
public enum RequestError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 429 after the retries ran out, or a `Retry-After` longer than the
    /// policy's limit. `retryAfter` is what TIDAL asked for, if it said.
    case busy(retryAfter: Duration?)
    /// No usable answer: no connection, a timeout, a dropped connection, a
    /// failed secure connection, or a web page where TIDAL data was expected
    /// (a captive portal; G1-9 skeptic note 3).
    case offline(detail: String)
    case notFound(subStatus: Int?)
    case forbidden(subStatus: Int?)
    case unauthorized(subStatus: Int?)
    /// 5xx after the retries ran out.
    case server(status: Int)
    /// Any other status, including a redirect (redirects are not followed).
    case unexpectedStatus(Int, subStatus: Int?)
    /// The answer arrived but wasn't the data expected.
    case decoding(detail: String)

    public var description: String {
        switch self {
        case let .busy(retryAfter):
            return "TIDAL is busy" + (retryAfter.map { " (asked to wait \($0.timeInterval) s)" } ?? "")
        case let .offline(detail): return "Can't reach TIDAL: \(detail)"
        case let .notFound(sub): return "Not found (404\(Self.sub(sub)))"
        case let .forbidden(sub): return "Refused (403\(Self.sub(sub)))"
        case let .unauthorized(sub): return "Not authorised (401\(Self.sub(sub)))"
        case let .server(status): return "TIDAL server error (\(status))"
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
        case .timedOut: return "TIDAL didn't answer in time"
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
    public func requireOK() throws(RequestError) -> Data {
        if let interference = networkInterference { throw interference }
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

    /// Set when something between the Mac and TIDAL answered instead of
    /// TIDAL: a redirect (TIDAL's API and auth hosts never redirect), a 511
    /// "network authentication required", or a web page instead of an error
    /// body. That is a captive portal or a proxy, which is a network
    /// problem, never "not found", "refused" or a parse error (G1-9
    /// skeptic note 3).
    public var networkInterference: RequestError? {
        if (300...399).contains(status) {
            return .offline(detail: "the request was redirected (a network sign-in page may be in the way)")
        }
        if status == 511 || (!looksLikeJSON && isWebPage) {
            return .offline(detail: Self.webPageDetail)
        }
        return nil
    }

    static let webPageDetail = "a web page came back instead of TIDAL data (a network sign-in page may be in the way)"

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

    /// The OAuth `error` code from auth.tidal.com (e.g. "authorization_pending").
    var oauthErrorCode: String? {
        (try? JSONDecoder().decode(TIDALErrorBody.self, from: body))?.error
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

/// The parts of a TIDAL error body this layer reads.
private struct TIDALErrorBody: Decodable {
    let error: String?
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
    /// request that receives nothing for that long; `total` ends one that
    /// trickles on too long. API and JSON calls get both; audio gets only
    /// inactivity, because a 100 MB Hi-Res file on a slow line would hit any
    /// fixed total limit every time.
    public struct Limits: Sendable, Equatable {
        public var inactivity: Duration
        public var total: Duration?

        public init(inactivity: Duration, total: Duration?) {
            self.inactivity = inactivity
            self.total = total
        }

        /// API and JSON calls: 30 s without data (as today) and 60 s in all for
        /// each try (G1-4); retries add their own tries after the backoff.
        public static let api = Limits(inactivity: .seconds(30), total: .seconds(60))
        /// Device sign-in requests: each gives up after 30 s (G1-3).
        public static let signIn = Limits(inactivity: .seconds(30), total: .seconds(30))
        /// Audio files and segments: 60 s without data, as today, no total.
        public static let audio = Limits(inactivity: .seconds(60), total: nil)
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
        // URLSession's resource timeout is a total limit; a week is its default.
        configuration.timeoutIntervalForResource = limits.total?.timeInterval ?? 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// One try, no retry. Transport failures become `RequestError.offline`;
    /// task cancellation stays `CancellationError`, never "offline".
    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await performOnce(request)
        } catch let error as URLError {
            throw RequestError.offline(detail: RequestError.offlineDetail(for: error.code))
        }
    }

    /// Sends with the retry rule. Returns the response for any status that
    /// is TIDAL's answer (2xx, 3xx, 4xx other than 429), so callers decide
    /// what 400 or 404 means for them. Throws `.busy`, `.server` or
    /// `.offline` once retries run out.
    public func send(_ request: HTTPRequest, retry: RetryPolicy = .standard) async throws -> HTTPResponse {
        var retriesSoFar = 0
        while true {
            let failure: RetryPolicy.Failure
            let finalError: RequestError
            do {
                let response = try await performOnce(request)
                guard RetryPolicy.isRetryable(status: response.status) else { return response }
                let retryAfter = response.header("Retry-After")
                    .flatMap { RetryPolicy.parseRetryAfter($0, now: clock.now()) }
                failure = .status(response.status, retryAfter: retryAfter)
                finalError = response.status == 429
                    ? .busy(retryAfter: retryAfter)
                    : response.networkInterference ?? .server(status: response.status)
            } catch let error as URLError {
                failure = .transport(error.code)
                finalError = .offline(detail: RequestError.offlineDetail(for: error.code))
            }
            switch retry.decision(after: failure, retriesSoFar: retriesSoFar) {
            case let .retry(after: wait):
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
    private func performOnce(_ request: HTTPRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = limits.inactivity.timeInterval
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
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
}

/// Redirects are not followed, as in the Electron app. Following one would
/// carry the Bearer or Basic header toward a host nobody checked; a 3xx is
/// returned as the answer and becomes `RequestError.unexpectedStatus`.
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
