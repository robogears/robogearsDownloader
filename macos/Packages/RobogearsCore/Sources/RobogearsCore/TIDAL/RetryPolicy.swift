import Foundation

// MARK: - Clock

/// The two things the network layer needs from time: the wall clock (token
/// expiry is wall-clock, as `Date.now()` was in the Electron app) and a
/// cancellable wait (backoff, sign-in polling).
///
/// It is injected so tests run the 1-2-4-8 s backoff, a 60 s Retry-After or a
/// 10-minute sign-in deadline in microseconds instead of waiting for real.
public protocol NetworkClock: Sendable {
    func now() -> Date
    /// Waits for `duration`. Throws `CancellationError` when the task is
    /// cancelled, so Cancel in the sign-in sheet stops polling at once.
    func sleep(for duration: Duration) async throws
}

/// The real clock: `Date()` and `Task.sleep`.
public struct SystemNetworkClock: NetworkClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for `Date` arithmetic and URLSession.
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// The longest wait any number from a server is read as: one day.
    /// Retry-After, `expiresIn` and `interval` all arrive as text a server,
    /// proxy or captive portal controls.
    static let longestServerWait: Duration = .seconds(86_400)

    /// `seconds` from a server as a duration between zero and `limit`.
    /// Converting the number straight to whole milliseconds stops the
    /// program once it passes about 9.2e15 s, so a single header such as
    /// `Retry-After: 1e20` could end the app mid-batch (review finding on
    /// the TIDAL client). Not-a-number and negative values read as zero.
    static func clamped(seconds: Double, to limit: Duration = .longestServerWait) -> Duration {
        guard seconds.isFinite, seconds > 0 else { return .zero }
        guard seconds < limit.timeInterval else { return limit }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

// MARK: - Retry policy

/// When a failed request is tried again, and how long to wait first.
///
/// Decision G1-4 (recommended option, with the skeptic's corrections): the
/// Electron app never retried an API call, so a five-second TIDAL hiccup
/// turned songs into "not found". The rule now is:
/// - 429 ("too many requests"): wait as long as TIDAL's `Retry-After` says,
///   capped at 60 s. A longer request fails at once as busy instead of
///   holding silently.
/// - 5xx, timeouts and dropped connections: wait 1, 2, 4, then 8 s. Four
///   retries after the first try, 15 s of waiting in all, which is what lets
///   short Wi-Fi blips pass unnoticed (G1-9: "Blips shorter than about 15 s
///   are absorbed by the normal retries").
/// - 404 and 403 (and every other 4xx) are answers, not hiccups: never retried.
/// A 429 without `Retry-After` uses the same 1-2-4-8 s steps.
public struct RetryPolicy: Sendable, Equatable {
    /// The wait before each retry. Its count is the number of retries.
    public var delays: [Duration]
    /// The longest `Retry-After` the app will honour before giving up as busy.
    public var retryAfterLimit: Duration

    public init(delays: [Duration], retryAfterLimit: Duration) {
        self.delays = delays
        self.retryAfterLimit = retryAfterLimit
    }

    /// The shared rule for every TIDAL and Spotify-page request (G1-4).
    public static let standard = RetryPolicy(
        delays: [.seconds(1), .seconds(2), .seconds(4), .seconds(8)],
        retryAfterLimit: .seconds(60)
    )

    /// One try only. Used where the caller runs its own loop (sign-in polling).
    public static let never = RetryPolicy(delays: [], retryAfterLimit: .zero)

    public var maxRetries: Int { delays.count }

    /// What went wrong on one try, as far as retrying is concerned.
    public enum Failure: Sendable, Equatable {
        /// An HTTP status the server sent. `retryAfter` is the parsed header.
        case status(Int, retryAfter: Duration?)
        /// No usable answer: a timeout, a dropped connection, no network.
        case transport(URLError.Code)
    }

    public enum Decision: Sendable, Equatable {
        case retry(after: Duration)
        case giveUp
    }

    /// Whether to try again after `retriesSoFar` retries have already been
    /// used. Pure, so the whole rule is tested without a network.
    public func decision(after failure: Failure, retriesSoFar: Int) -> Decision {
        guard retriesSoFar < delays.count else { return .giveUp }
        let backoff = delays[retriesSoFar]
        switch failure {
        case let .status(code, retryAfter):
            if code == 429 {
                guard let retryAfter else { return .retry(after: backoff) }
                return retryAfter > retryAfterLimit ? .giveUp : .retry(after: max(retryAfter, .zero))
            }
            return Self.isRetryable(status: code) ? .retry(after: backoff) : .giveUp
        case let .transport(code):
            return Self.isRetryable(code) ? .retry(after: backoff) : .giveUp
        }
    }

    /// 429 and every 5xx. Everything else is TIDAL's actual answer.
    public static func isRetryable(status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// Timeouts, dropped connections and "no network right now". Certificate
    /// and TLS failures are not retried: on a captive portal they won't clear
    /// within 15 s, and they are reported as offline straight away.
    public static func isRetryable(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive,
             .badServerResponse, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    /// Parses a `Retry-After` header: either whole seconds ("30") or an
    /// HTTP date ("Wed, 21 Oct 2026 22:00:00 GMT"), measured from `now`.
    /// Returns nil for anything unreadable, so the normal backoff applies.
    /// Anything over a day reads as a day, which is past `retryAfterLimit`
    /// and so fails as busy instead of crashing on the conversion.
    public static func parseRetryAfter(_ value: String, now: Date) -> Duration? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed), seconds.isFinite {
            return .clamped(seconds: seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return .clamped(seconds: date.timeIntervalSince(now))
    }
}
