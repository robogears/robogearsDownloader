import Foundation

/// What the sign-in sheet shows while TIDAL waits for the person to approve
/// in the browser.
public struct DeviceAuthorization: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    /// The link to open: always `https://` and always a tidal.com host.
    public let verificationURL: URL
    /// TIDAL's short code, shown on its own when TIDAL sends one (G1-3).
    public let userCode: String?
    /// The wait before each poll. Grows by 5 s on `slow_down`.
    public let interval: Duration
    /// When the code stops working: TIDAL's `expiresIn`, or 10 minutes.
    public let expiresAt: Date
    /// Secret to this sign-in; never shown or logged.
    let deviceCode: String

    /// Public so the app can build one for previews of the sign-in sheet
    /// and for view-model tests. The device code is taken but never shown:
    /// `description` and the reflection mirror leave it out.
    public init(verificationURL: URL, userCode: String?, interval: Duration, expiresAt: Date, deviceCode: String) {
        self.verificationURL = verificationURL
        self.userCode = userCode
        self.interval = interval
        self.expiresAt = expiresAt
        self.deviceCode = deviceCode
    }

    public var description: String {
        "DeviceAuthorization(\(verificationURL.host ?? ""), expires \(expiresAt))"
    }

    /// Host and expiry only, so `dump` can't show the device code either.
    public var customMirror: Mirror {
        Mirror(self, children: ["host": verificationURL.host ?? "", "expiresAt": expiresAt])
    }
}

/// Why a sign-in ended without a credential. Each case maps to one plain
/// sentence in the sheet (G1-3 recommended option, with the skeptic's
/// additions).
public enum DeviceSignInError: Error, Sendable, Equatable, CustomStringConvertible {
    /// TIDAL turned down the request itself (step 1, or a poll answered with
    /// something other than an OAuth error). The likely cause is that the
    /// built-in client keys stopped working: "TIDAL didn't accept the
    /// sign-in request. Check for an app update."
    case refused(status: Int)
    /// The link TIDAL sent isn't an https tidal.com address, so it is not
    /// opened or shown.
    case unexpectedVerificationURL
    /// TIDAL's answer lacked a field the flow needs.
    case malformedResponse(detail: String)
    /// "The sign-in code expired. Click Try Again for a new one."
    case expired
    /// "You declined access in the browser."
    case denied
    /// Another OAuth error code from TIDAL.
    case rejected(error: String)
    /// "Can't reach TIDAL. Check your connection and try again." Used when
    /// the network kept failing until the code's time limit, or when the
    /// first request couldn't get through.
    case unreachable(RequestError)

    public var description: String {
        switch self {
        case let .refused(status): return "TIDAL didn't accept the sign-in request (\(status))."
        case .unexpectedVerificationURL: return "TIDAL sent a sign-in link that isn't a tidal.com address."
        case let .malformedResponse(detail): return "TIDAL's sign-in answer was incomplete: \(detail)."
        case .expired: return "The sign-in code expired."
        case .denied: return "Access was declined in the browser."
        case let .rejected(error): return "TIDAL ended the sign-in (\(error))."
        case let .unreachable(error):
            // The shared error names no service; this one knows it was TIDAL.
            if case let .offline(detail) = error { return "Can't reach TIDAL: \(detail)." }
            return "Can't reach TIDAL: \(error)."
        }
    }
}

/// TIDAL's OAuth device-code sign-in (RFC 8628), as `tidal_auth_node.js`
/// runs it, with decision G1-3's changes: a time limit from the code's
/// lifetime, `slow_down` honoured, network blips retried while waiting, a
/// 30 s limit per request, cancellation through Swift task cancellation,
/// and only https tidal.com links accepted.
///
/// Two steps so the sheet can show the link while waiting:
/// `requestAuthorization()`, then `waitForApproval(of:)`. Cancelling the
/// task that runs the second stops polling straight away; closing the sheet
/// or the window should cancel it (G1-3 skeptic note 3).
public struct DeviceSignIn: Sendable {
    /// Sent as one plus-joined token, `r_usr%2Bw_usr%2Bw_sub` on the wire,
    /// exactly as today (reference bug 18; G1-7).
    public static let scope = "r_usr+w_usr+w_sub"
    public static let deviceCodeGrant = "urn:ietf:params:oauth:grant-type:device_code"
    /// Used when TIDAL doesn't say how long the code lives (G1-3).
    public static let defaultLifetime: Duration = .seconds(600)
    /// RFC 8628's default, and today's.
    public static let defaultInterval: Duration = .seconds(5)
    /// RFC 8628: `slow_down` adds 5 s to every later wait.
    public static let slowDownStep: Duration = .seconds(5)

    static let deviceAuthorizationURL = URL(string: "https://auth.tidal.com/v1/oauth2/device_authorization")!
    static let tokenURL = URL(string: "https://auth.tidal.com/v1/oauth2/token")!

    let client: HTTPClient
    let keys: ClientKeySet
    let retry: RetryPolicy

    /// `client` should use `HTTPClient.Limits.signIn` (30 s per request).
    public init(
        client: HTTPClient = HTTPClient(limits: .signIn),
        keys: ClientKeySet = .builtIn,
        retry: RetryPolicy = .standard
    ) {
        self.client = client
        self.keys = keys
        self.retry = retry
    }

    // MARK: Step 1

    /// Asks TIDAL for a device code. Network failures and 5xx get the shared
    /// retry rule; any other non-200 is a refusal.
    public func requestAuthorization() async throws -> DeviceAuthorization {
        let response: HTTPResponse
        do {
            response = try await client.send(Self.deviceAuthorizationRequest(pair: keys.signIn), retry: retry)
        } catch let error as RequestError {
            throw DeviceSignInError.unreachable(error)
        }
        if let interference = response.networkInterference() {
            throw DeviceSignInError.unreachable(interference)
        }
        guard response.status == 200 else {
            throw DeviceSignInError.refused(status: response.status)
        }
        let body: DeviceAuthorizationBody
        do {
            body = try JSONDecoder().decode(DeviceAuthorizationBody.self, from: try response.requireJSONBody())
        } catch let error as RequestError {
            throw Self.signInError(forUnreadableBody: error)
        } catch {
            throw DeviceSignInError.malformedResponse(detail: "not the expected JSON")
        }
        guard let deviceCode = body.deviceCode, !deviceCode.isEmpty else {
            throw DeviceSignInError.malformedResponse(detail: "no device code")
        }
        guard let rawLink = body.verificationUriComplete ?? body.verificationUri else {
            throw DeviceSignInError.malformedResponse(detail: "no sign-in link")
        }
        guard let link = Self.verificationURL(from: rawLink) else {
            throw DeviceSignInError.unexpectedVerificationURL
        }
        let lifetime = body.expiresIn.flatMap(Self.positiveSeconds) ?? Self.defaultLifetime
        let interval = body.interval.flatMap(Self.positiveSeconds) ?? Self.defaultInterval
        return DeviceAuthorization(
            verificationURL: link,
            userCode: body.userCode.flatMap { $0.isEmpty ? nil : $0 },
            interval: interval,
            expiresAt: client.clock.now().addingTimeInterval(lifetime.timeInterval),
            deviceCode: deviceCode
        )
    }

    // MARK: Step 2

    /// Polls until the person approves, declines, or the code runs out.
    ///
    /// Waits first and then polls, as today. A network failure, 429 or 5xx
    /// while waiting doesn't end the sign-in; polling simply carries on
    /// until the time limit, and if the network was what kept failing, the
    /// error says so instead of "expired".
    public func waitForApproval(of authorization: DeviceAuthorization) async throws -> TIDALCredential {
        let request = Self.pollRequest(pair: keys.signIn, deviceCode: authorization.deviceCode)
        var interval = authorization.interval
        var extraWait = Duration.zero
        var lastNetworkFailure: RequestError?

        while true {
            try await client.clock.sleep(for: interval + extraWait)
            extraWait = .zero
            if client.clock.now() >= authorization.expiresAt {
                if let lastNetworkFailure { throw DeviceSignInError.unreachable(lastNetworkFailure) }
                throw DeviceSignInError.expired
            }

            let response: HTTPResponse
            do {
                response = try await client.perform(request)
            } catch let error as RequestError {
                lastNetworkFailure = error
                continue
            }
            if let interference = response.networkInterference() {
                lastNetworkFailure = interference
                continue
            }

            switch response.status {
            case 200:
                return try credential(from: response)
            case 400:
                // A web page was already treated as a blip above, so a
                // 400 that isn't JSON is a real refusal.
                guard let body = try? response.requireJSONBody() else {
                    throw DeviceSignInError.refused(status: 400)
                }
                lastNetworkFailure = nil
                switch (try? JSONDecoder().decode(OAuthErrorBody.self, from: body))?.error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval += Self.slowDownStep
                case "expired_token":
                    throw DeviceSignInError.expired
                case "access_denied":
                    throw DeviceSignInError.denied
                case let other:
                    throw DeviceSignInError.rejected(error: other ?? "unknown")
                }
            case 429:
                let retryAfter = response.header("Retry-After")
                    .flatMap { RetryPolicy.parseRetryAfter($0, now: client.clock.now()) }
                extraWait = min(retryAfter ?? .zero, retry.retryAfterLimit)
                lastNetworkFailure = .busy(retryAfter: retryAfter)
            case 500...599:
                lastNetworkFailure = .server(status: response.status)
            default:
                throw DeviceSignInError.refused(status: response.status)
            }
        }
    }

    /// Builds the stored sign-in from a 200 poll answer.
    /// `expiresAt = now + expires_in − 60 s` (3600 s if TIDAL doesn't say),
    /// and the renewal pair's label instead of its secret (G1-7).
    private func credential(from response: HTTPResponse) throws -> TIDALCredential {
        let token: TIDALTokenResponse
        do {
            token = try JSONDecoder().decode(TIDALTokenResponse.self, from: try response.requireJSONBody())
        } catch let error as RequestError {
            throw Self.signInError(forUnreadableBody: error)
        } catch {
            throw DeviceSignInError.malformedResponse(detail: "not the expected JSON")
        }
        guard let access = token.accessToken, !access.isEmpty,
              let refresh = token.refreshToken, !refresh.isEmpty else {
            throw DeviceSignInError.malformedResponse(detail: "no tokens")
        }
        return TIDALCredential(
            accessToken: access,
            refreshToken: refresh,
            userID: token.userID,
            countryCode: token.countryCode,
            expiresAt: token.expiry(from: client.clock.now()),
            clientPairLabel: keys.renewal.label
        )
    }

    // MARK: Requests

    /// `POST /v1/oauth2/device_authorization`, body
    /// `client_id=<sign-in id>&scope=r_usr%2Bw_usr%2Bw_sub`, no Authorization.
    static func deviceAuthorizationRequest(pair: ClientPair) -> HTTPRequest {
        let body = URIComponent.formBody([
            (name: "client_id", value: pair.clientID),
            (name: "scope", value: scope),
        ])
        return HTTPRequest(
            method: .post,
            url: deviceAuthorizationURL,
            headers: TIDALHeaders.deviceFlow(bodyLength: body.utf8.count),
            body: Data(body.utf8)
        )
    }

    /// `POST /v1/oauth2/token` with the device-code grant and Basic auth from
    /// the sign-in pair, in today's field order.
    static func pollRequest(pair: ClientPair, deviceCode: String) -> HTTPRequest {
        let body = URIComponent.formBody([
            (name: "client_id", value: pair.clientID),
            (name: "device_code", value: deviceCode),
            (name: "grant_type", value: deviceCodeGrant),
            (name: "scope", value: scope),
        ])
        return HTTPRequest(
            method: .post,
            url: tokenURL,
            headers: TIDALHeaders.deviceFlow(bodyLength: body.utf8.count, basicAuthorization: pair.basicAuthorization),
            body: Data(body.utf8)
        )
    }

    // MARK: Link check

    /// The link to open, or nil if it isn't safe to open (G1-3: "The link
    /// opens only if it is an https tidal.com address; https:// is added if
    /// TIDAL leaves it off"). TIDAL has been seen to send `link.tidal.com/…`
    /// without a scheme (unverified for this client; the spike will tell).
    public static func verificationURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), !host.isEmpty,
              host == "tidal.com" || host.hasSuffix(".tidal.com"),
              let url = components.url
        else { return nil }
        return url
    }

    /// A 200 body that couldn't be used: a web page means the network is in
    /// the way; anything else is an incomplete answer from TIDAL.
    private static func signInError(forUnreadableBody error: RequestError) -> DeviceSignInError {
        if case let .decoding(detail) = error { return .malformedResponse(detail: detail) }
        return .unreachable(error)
    }

    /// A positive number of seconds from TIDAL, capped at a day so a huge
    /// `expiresIn` or `interval` (also sent as a numeric string) can't crash
    /// the conversion. Zero, negative and unreadable values mean "not said".
    private static func positiveSeconds(_ value: Double) -> Duration? {
        guard value.isFinite, value > 0 else { return nil }
        return .clamped(seconds: value)
    }
}

// MARK: - Response bodies

private struct DeviceAuthorizationBody: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationUri: String?
    let verificationUriComplete: String?
    let expiresIn: Double?
    let interval: Double?

    private enum CodingKeys: String, CodingKey {
        case deviceCode, userCode, verificationUri, verificationUriComplete, expiresIn, interval
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try container.decodeIfPresent(String.self, forKey: .deviceCode)
        userCode = try container.decodeIfPresent(String.self, forKey: .userCode)
        verificationUri = try container.decodeIfPresent(String.self, forKey: .verificationUri)
        verificationUriComplete = try container.decodeIfPresent(String.self, forKey: .verificationUriComplete)
        expiresIn = container.lenientNumber(forKey: .expiresIn)
        interval = container.lenientNumber(forKey: .interval)
    }
}

private struct OAuthErrorBody: Decodable {
    let error: String?
}

/// A 200 answer from the token endpoint, for both the device-code grant and
/// a refresh. Every field is optional because the Electron code tolerated
/// each one missing; the callers decide what is required.
struct TIDALTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
    let userID: Int?
    let countryCode: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }

    private enum UserKeys: String, CodingKey {
        case userId, countryCode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try? container.decodeIfPresent(String.self, forKey: .accessToken)
        refreshToken = try? container.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresIn = container.lenientNumber(forKey: .expiresIn)
        if let user = try? container.nestedContainer(keyedBy: UserKeys.self, forKey: .user) {
            userID = user.lenientNumber(forKey: .userId).flatMap { Int(exactly: $0) }
            countryCode = (try? user.decodeIfPresent(String.self, forKey: .countryCode)).flatMap { $0 }
        } else {
            userID = nil
            countryCode = nil
        }
    }

    /// `now + expires_in − 60 s`, with 3600 s when TIDAL doesn't say, as
    /// `tidal_auth_node.js:153` and `tidal_lib.js:88` compute it.
    func expiry(from now: Date) -> Date {
        let seconds = expiresIn.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } ?? 3600
        return now.addingTimeInterval(seconds - 60)
    }
}

fileprivate extension KeyedDecodingContainer {
    /// A number sent as a JSON number or as a numeric string; nil otherwise.
    func lenientNumber(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }
}
