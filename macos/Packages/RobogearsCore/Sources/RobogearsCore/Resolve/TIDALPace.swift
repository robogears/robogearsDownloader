import Foundation

/// The seam between `HTTPClient.send` and the shared TIDAL pace (D4 1.4).
///
/// `HTTPClient` calls it around every try, retries included, so a pause that
/// one caller's 429 started also holds the retries and first tries of every
/// other caller. Defined here rather than in the client so the client stays
/// unaware of priorities and slots.
public protocol RequestPacing: Sendable {
    /// Waits while TIDAL has asked every caller to pause. Throws
    /// `RequestError.busy` at once while TIDAL has asked for a pause longer
    /// than the app waits, and `CancellationError` when the caller is
    /// cancelled (D4 1.11: Cancel stops requests that are waiting too).
    func beforeTry() async throws

    /// A try was answered 429. `retryAfter` is TIDAL's `Retry-After` when it
    /// sent one; `pause` is the wait the client chose before its own next try,
    /// nil when it gives up instead.
    func tooManyRequests(retryAfter: Duration?, pause: Duration?) async
}

/// One pace for everything the app asks TIDAL: matching, searches, previews
/// and downloads (D4 1.4 option A, "one shared pace").
///
/// The Electron app had none: the Spotify matcher ran 8 searches at once, the
/// waveform pre-loader 2 more, downloads their own 8 segment workers, and none
/// of them knew when another had been told "too many requests", so they kept
/// tripping TIDAL's limit and turned songs into false "not found" rows
/// (tidal-and-spotify-networking.md bug 3). Here:
///
/// - **Slots.** `run(_:_:)` holds one of a bounded number of slots for a unit
///   of work (normally one TIDAL call with its retries). Eight are shared,
///   the same 8 at a time the Electron app matched with and downloaded
///   segments with, which TIDAL tolerated whenever it wasn't already
///   limiting; how many it really tolerates needs the D4 1.4 live check.
///   One more slot only interactive work can take, so a search you typed or
///   a preview you clicked starts at once even while eight downloads or
///   matches are running ("a preview you click still plays"). Background
///   pre-loading never holds more than 2 (the Electron pre-loader's
///   concurrency), so it can't crowd anything out.
/// - **Priorities.** Waiting work starts in priority order (interactive,
///   matching, downloads, background), first come first served within one.
/// - **One shared 429 pause.** When any request is answered 429, every try
///   of every caller waits as long as TIDAL asked (its `Retry-After`, or the
///   requester's backoff step when it didn't say). A request asking for more
///   than about 60 s means TIDAL is busy: for up to a minute
///   (`Limits.longestBusy`), requests fail at once as busy rather than each
///   asking again; then they are sent again. `status` publishes the wait so
///   the batch bar can show it.
/// - 5xx answers, timeouts and dropped connections keep `RetryPolicy`'s 1, 2,
///   4, 8 s backoff inside `HTTPClient`; "not found" never retries. The pace
///   doesn't change either.
///
/// Never call `run` from inside `run`'s work: the outer slot would be held
/// while the inner one waits, and enough of them would wait forever.
public actor TIDALPace: RequestPacing {
    /// Who is waiting for the answer, most urgent first.
    public enum Priority: Int, Sendable, Comparable, CaseIterable {
        /// Something the person is looking at: a typed search, a preview they
        /// clicked, Match Again on a row.
        case interactive
        /// Links and imports being matched while the adding cover is up.
        case matching
        /// The download batch.
        case download
        /// Waveform pre-loading (D4 5.1).
        case background

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Limits: Sendable, Equatable {
        /// Slots any priority may use.
        public var shared: Int
        /// Further slots only `.interactive` work may use.
        public var interactiveExtra: Int
        /// The most `.background` work running at once.
        public var background: Int
        /// The longest 429 pause the app waits through (RetryPolicy's 60 s);
        /// a longer `Retry-After` reads as "TIDAL is busy".
        public var longestWait: Duration
        /// The longest "TIDAL is busy" lasts before requests are sent again,
        /// whatever `Retry-After` said (it can say a day). One minute, so
        /// "Wait a minute, then click Try Again" is true: Try Again then
        /// really asks TIDAL, and a new 429 starts a new wait.
        public var longestBusy: Duration

        public init(shared: Int, interactiveExtra: Int, background: Int, longestWait: Duration,
                    longestBusy: Duration = .seconds(60)) {
            self.shared = max(shared, 1)
            self.interactiveExtra = max(interactiveExtra, 0)
            self.background = max(background, 1)
            self.longestWait = longestWait
            self.longestBusy = max(longestBusy, .zero)
        }

        public static let standard = Limits(
            shared: 8, interactiveExtra: 1, background: 2,
            longestWait: RetryPolicy.standard.retryAfterLimit
        )
    }

    /// What the batch bar shows about TIDAL's pace.
    public enum Status: Sendable, Equatable {
        case flowing
        /// TIDAL asked everyone to wait until this time (a 429). The bar can
        /// count down to it.
        case waiting(until: Date)
        /// TIDAL asked for a longer pause than the app waits; lookups fail as
        /// "Couldn't check: TIDAL was busy" until this time.
        case busy(until: Date)
    }

    public let limits: Limits
    private let clock: any NetworkClock

    private struct Waiter {
        let ticket: Int
        let priority: Priority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var runningByPriority: [Priority: Int] = [:]
    private var runningTotal = 0
    private var waiters: [Waiter] = []
    private var nextTicket = 0
    private var pausedUntil: Date?
    private var busyUntil: Date?
    public private(set) var status: Status = .flowing
    private var watchers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var statusTimer: Task<Void, Never>?

    public init(limits: Limits = .standard, clock: any NetworkClock = SystemNetworkClock()) {
        self.limits = limits
        self.clock = clock
    }

    /// Work holding a slot right now.
    public var inFlight: Int { runningTotal }
    /// Work waiting for a slot.
    public var queued: Int { waiters.count }

    // MARK: Slots

    /// Runs `work` in a slot of the given priority, waiting for one first.
    /// Cancelling the caller while it waits removes it from the queue at once
    /// (D4 1.11); cancelling it while `work` runs is up to `work`, which for
    /// TIDAL calls stops the request in flight.
    ///
    /// Wrap one TIDAL call at a time, for example
    /// `try await pace.run(.download) { try await api.playbackInfo(…) }`, so a
    /// long list frees its slot between pages and higher priorities can step in.
    nonisolated public func run<T: Sendable>(
        _ priority: Priority,
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(priority)
        do {
            let value = try await work()
            await release(priority)
            return value
        } catch {
            await release(priority)
            throw error
        }
    }

    private func acquire(_ priority: Priority) async throws {
        try Task.checkCancellation()
        // Join the queue behind anyone of the same or higher priority, so
        // work keeps its order; otherwise start when a slot is free.
        if !waiters.contains(where: { $0.priority <= priority }), canStart(priority) {
            start(priority)
            return
        }
        let ticket = nextTicket
        nextTicket += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(ticket: ticket, priority: priority, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(ticket) }
        }
    }

    private func canStart(_ priority: Priority) -> Bool {
        switch priority {
        case .interactive:
            return runningTotal < limits.shared + limits.interactiveExtra
        case .matching, .download:
            return runningTotal < limits.shared
        case .background:
            return runningTotal < limits.shared && runningByPriority[.background, default: 0] < limits.background
        }
    }

    private func start(_ priority: Priority) {
        runningByPriority[priority, default: 0] += 1
        runningTotal += 1
    }

    private func release(_ priority: Priority) {
        runningByPriority[priority, default: 1] -= 1
        runningTotal -= 1
        dispatch()
    }

    /// Starts waiting work while slots allow: the highest priority first, the
    /// earliest arrival within it.
    private func dispatch() {
        while let index = waiters.indices
            .filter({ canStart(waiters[$0].priority) })
            .min(by: { (waiters[$0].priority, waiters[$0].ticket) < (waiters[$1].priority, waiters[$1].ticket) }) {
            let waiter = waiters.remove(at: index)
            start(waiter.priority)
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ ticket: Int) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    // MARK: The shared 429 pause

    public func beforeTry() async throws {
        while true {
            try Task.checkCancellation()
            let now = clock.now()
            if let busyUntil, now < busyUntil {
                throw RequestError.busy(retryAfter: .seconds(busyUntil.timeIntervalSince(now)))
            }
            guard let pausedUntil, now < pausedUntil else { return }
            try await clock.sleep(for: .seconds(pausedUntil.timeIntervalSince(now)))
        }
    }

    public func tooManyRequests(retryAfter: Duration?, pause: Duration?) {
        let now = clock.now()
        if let retryAfter, retryAfter > limits.longestWait {
            let until = now.addingTimeInterval(min(retryAfter, limits.longestBusy).timeInterval)
            busyUntil = max(busyUntil ?? until, until)
        } else {
            // Without a Retry-After, everyone waits as long as the request
            // that was refused does before its own next try.
            let wait = retryAfter ?? pause ?? .seconds(1)
            guard wait > .zero else { return }
            let until = now.addingTimeInterval(wait.timeInterval)
            pausedUntil = max(pausedUntil ?? until, until)
        }
        refreshStatus()
    }

    // MARK: Status

    /// The current status first, then every change, until the caller stops
    /// listening.
    public func statusChanges() -> AsyncStream<Status> {
        let (stream, continuation) = AsyncStream.makeStream(of: Status.self)
        let id = UUID()
        watchers[id] = continuation
        continuation.onTermination = { _ in Task { await self.removeWatcher(id) } }
        continuation.yield(status)
        return stream
    }

    private func removeWatcher(_ id: UUID) {
        watchers[id] = nil
    }

    private func refreshStatus() {
        let now = clock.now()
        let new: Status
        if let busyUntil, now < busyUntil {
            new = .busy(until: busyUntil)
        } else if let pausedUntil, now < pausedUntil {
            new = .waiting(until: pausedUntil)
        } else {
            new = .flowing
        }
        if new != status {
            status = new
            for watcher in watchers.values { watcher.yield(new) }
        }
        // Flip back to flowing (or from busy to a shorter wait) when the
        // current wait ends, so the bar never shows a wait that is over.
        statusTimer?.cancel()
        statusTimer = nil
        let end: Date? = switch new {
        case .flowing: nil
        case let .waiting(until), let .busy(until): until
        }
        if let end {
            let clock = self.clock
            statusTimer = Task {
                try? await clock.sleep(for: .seconds(max(end.timeIntervalSince(clock.now()), 0)))
                guard !Task.isCancelled else { return }
                self.refreshStatus()
            }
        }
    }
}
