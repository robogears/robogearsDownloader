import Foundation
import Synchronization
import Testing
@testable import RobogearsCore

// Test support for the batch runner. Every name carries a Batch prefix so it
// can't collide with helpers other lanes add to the same test target. No
// stand-in here touches the network, TIDAL or any real folder.

// MARK: - A gate tests open and close

/// Suspends callers until opened; cancelling a waiting task ends its wait
/// with `CancellationError`, as the real network monitor does.
final class BatchGate: Sendable {
    private struct State {
        var isOpen: Bool
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let state: Mutex<State>
    /// When false, a cancelled waiter keeps waiting (a track that ignores Cancel).
    private let honoursCancel: Bool

    init(open: Bool = false, honoursCancel: Bool = true) {
        state = Mutex(State(isOpen: open))
        self.honoursCancel = honoursCancel
    }

    var waiting: Int { state.withLock { $0.waiters.count } }

    func wait() async throws {
        let id = UUID()
        let honoursCancel = self.honoursCancel
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let answer: Result<Void, any Error>? = state.withLock { s in
                    if s.isOpen { return .success(()) }
                    if honoursCancel, Task.isCancelled { return .failure(CancellationError()) }
                    s.waiters[id] = continuation
                    return nil
                }
                if let answer { continuation.resume(with: answer) }
            }
        } onCancel: {
            guard honoursCancel else { return }
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Opens (and stays open) or closes the gate.
    func set(open: Bool) {
        let ready: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            s.isOpen = open
            guard open else { return [] }
            defer { s.waiters.removeAll() }
            return Array(s.waiters.values)
        }
        for waiter in ready { waiter.resume() }
    }

    /// Lets everyone waiting now through, and stays closed.
    func releaseWaiting() {
        let ready: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            defer { s.waiters.removeAll() }
            return Array(s.waiters.values)
        }
        for waiter in ready { waiter.resume() }
    }
}

// MARK: - Downloader

/// A downloader that follows a script per row, one step per call.
final class BatchScriptedDownloader: TrackDownloading {
    enum Step: Sendable {
        /// Reports these progress fractions, then saves.
        case save(TrackDownloadOutcome? = nil, progress: [Double] = [])
        case fail(TrackDownloadError)
        /// Throws something that isn't a `TrackDownloadError`.
        case throwOther(BatchOtherError)
        /// Reports progress, then downloads until cancelled; then cleans up
        /// its temporary file and throws `CancellationError`.
        case hang(progress: [Double] = [])
        /// Waits for the gate (or a cancel), then saves.
        case saveWhenOpened(BatchGate)
        /// Waits until cancelled, then returns a save anyway: the file was
        /// moved into place just before the stop arrived.
        case saveDespiteCancel
        /// Ignores Cancel until the gate opens; then cleans up and throws.
        case stuck(BatchGate)
    }

    private struct State {
        var scripts: [UUID: [Step]]
        var calls: [TrackDownloadRequest] = []
        var active: UUID?
        var running = 0
        var mostAtOnce = 0
        var cleanedUp: [UUID] = []
    }

    private let state: Mutex<State>

    init(_ scripts: [UUID: [Step]] = [:]) {
        state = Mutex(State(scripts: scripts))
    }

    var calls: [TrackDownloadRequest] { state.withLock { $0.calls } }
    var calledRows: [UUID] { calls.map(\.rowID) }
    var active: UUID? { state.withLock { $0.active } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }
    var cleanedUp: [UUID] { state.withLock { $0.cleanedUp } }

    static func defaultOutcome(for request: TrackDownloadRequest) -> TrackDownloadOutcome {
        .saved(fileName: "\(request.title).flac", quality: .flac(bitDepth: 16, sampleRate: 44_100), notes: [])
    }

    func download(_ request: TrackDownloadRequest,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> TrackDownloadOutcome {
        let step: Step = state.withLock { s in
            s.calls.append(request)
            s.active = request.rowID
            s.running += 1
            s.mostAtOnce = max(s.mostAtOnce, s.running)
            if var steps = s.scripts[request.rowID], !steps.isEmpty {
                let first = steps.removeFirst()
                s.scripts[request.rowID] = steps
                return first
            }
            return .save()
        }
        defer {
            state.withLock { s in
                s.running -= 1
                if s.active == request.rowID { s.active = nil }
            }
        }
        switch step {
        case let .save(outcome, ticks):
            for tick in ticks { progress(tick) }
            return outcome ?? Self.defaultOutcome(for: request)
        case let .fail(error):
            throw error
        case let .throwOther(error):
            throw error
        case let .hang(ticks):
            for tick in ticks { progress(tick) }
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                state.withLock { $0.cleanedUp.append(request.rowID) }
                throw CancellationError()
            }
            return Self.defaultOutcome(for: request)
        case let .saveWhenOpened(gate):
            do {
                try await gate.wait()
            } catch {
                state.withLock { $0.cleanedUp.append(request.rowID) }
                throw error
            }
            return Self.defaultOutcome(for: request)
        case .saveDespiteCancel:
            try? await Task.sleep(for: .seconds(3600))
            return Self.defaultOutcome(for: request)
        case let .stuck(gate):
            try? await gate.wait()
            state.withLock { $0.cleanedUp.append(request.rowID) }
            throw CancellationError()
        }
    }
}

struct BatchOtherError: Error, Sendable, CustomStringConvertible {
    var description: String
}

// MARK: - Network, keep-awake, sounds, clock

/// The "Wi-Fi", switched by the test.
final class BatchStandInNetwork: NetworkMonitoring {
    private let online: BatchGate
    private let metered = Mutex(false)

    init(online: Bool = true, metered: Bool = false) {
        self.online = BatchGate(open: online)
        self.metered.withLock { $0 = metered }
    }

    func currentStatus() async -> NetworkStatus {
        NetworkStatus(isOnline: isOnline, isMetered: metered.withLock { $0 })
    }

    func waitUntilOnline() async throws {
        try await online.wait()
    }

    private let onlineFlag = Mutex(true)
    var isOnline: Bool { onlineFlag.withLock { $0 } }

    func set(online: Bool, metered: Bool? = nil) {
        if let metered { self.metered.withLock { $0 = metered } }
        onlineFlag.withLock { $0 = online }
        self.online.set(open: online)
    }

    /// Tasks waiting for the connection now.
    var waiting: Int { online.waiting }
}

extension BatchStandInNetwork {
    static func offline(metered: Bool = false) -> BatchStandInNetwork {
        let network = BatchStandInNetwork(online: false, metered: metered)
        network.set(online: false)
        return network
    }
}

final class BatchRecordingKeepAwake: SleepPreventing {
    private let state = Mutex<(held: Bool, history: [Bool], reasons: [String])>((false, [], []))

    func preventSleep(reason: String) {
        state.withLock { s in
            s.held = true
            s.history.append(true)
            s.reasons.append(reason)
        }
    }

    func allowSleep() {
        state.withLock { s in
            s.held = false
            s.history.append(false)
        }
    }

    var isHeld: Bool { state.withLock { $0.held } }
    var history: [Bool] { state.withLock { $0.history } }
    var reasons: [String] { state.withLock { $0.reasons } }
}

final class BatchRecordingSounds: BatchSoundPlaying {
    private let played = Mutex<[SoundEffect]>([])
    func play(_ effect: SoundEffect) { played.withLock { $0.append(effect) } }
    var all: [SoundEffect] { played.withLock { $0 } }
}

/// A clock whose sleeps wait until the test lets them through (or the task
/// is cancelled). Left alone, it never fires: a Quit time limit never runs
/// out on its own in these tests.
final class BatchGateClock: NetworkClock {
    private let gate = BatchGate()
    private let requested = Mutex<[Duration]>([])

    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }

    func sleep(for duration: Duration) async throws {
        requested.withLock { $0.append(duration) }
        try await gate.wait()
    }

    /// Every sleep asked for so far.
    var sleeps: [Duration] { requested.withLock { $0 } }
    /// Sleeps waiting now.
    var sleeping: Int { gate.waiting }
    /// Lets the current sleeps end.
    func fire() { gate.releaseWaiting() }
}

// MARK: - Events

/// Collects a batch's events as they arrive.
final class BatchEventLog: Sendable {
    private let events = Mutex<[DownloadBatch.Event]>([])

    static func listen(to batch: DownloadBatch) -> BatchEventLog {
        let log = BatchEventLog()
        let stream = batch.events()
        Task { for await event in stream { log.events.withLock { $0.append(event) } } }
        return log
    }

    var all: [DownloadBatch.Event] { events.withLock { $0 } }

    var rowUpdates: [DownloadBatch.RowUpdate] {
        all.compactMap { if case let .row(update) = $0 { update } else { nil } }
    }

    func updates(for row: UUID) -> [DownloadBatch.RowUpdate] {
        rowUpdates.filter { $0.rowID == row }
    }

    /// Each row's latest state, as the queue would show it.
    var finalStates: [UUID: QueueItem.DownloadState] {
        var states: [UUID: QueueItem.DownloadState] = [:]
        for update in rowUpdates { states[update.rowID] = update.state }
        return states
    }

    func progress(for row: UUID) -> [Int] {
        all.compactMap { if case let .rowProgress(id, percent) = $0, id == row { percent } else { nil } }
    }

    var counters: [DownloadBatch.Counter] {
        all.compactMap { if case let .counter(counter) = $0 { counter } else { nil } }
    }

    var stopNotices: [DownloadBatch.StopNotice] {
        all.compactMap { if case let .stopped(notice) = $0 { notice } else { nil } }
    }

    var summary: DownloadBatch.Summary? {
        all.lazy.compactMap { if case let .finished(summary) = $0 { summary } else { nil } }.first
    }

    func count(_ match: (DownloadBatch.Event) -> Bool) -> Int {
        all.filter(match).count
    }
}

// MARK: - Waiting

/// Polls `condition` until it holds; records an issue after `timeout`.
@discardableResult
func batchEventually(_ timeout: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation,
                     _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    let ok = await condition()
    if !ok { Issue.record("Timed out waiting for a condition", sourceLocation: sourceLocation) }
    return ok
}

// MARK: - Rows

enum BatchFixtures {
    static let folder = URL(fileURLWithPath: "/Volumes/Test SSD/TIDAL", isDirectory: true)

    static func row(_ title: String, artist: String = "Placeholder Artist", hiRes: Bool = false,
                    state: QueueItem.DownloadState = .waiting) -> QueueItem {
        QueueItem(tidalID: Int64(abs(title.hashValue % 1_000_000)) + 1, title: title, artist: artist,
                  hiRes: hiRes, source: .tidal, state: state)
    }

    static func tracks(_ rows: [QueueItem], folder: URL = folder) -> [DownloadBatch.Track] {
        rows.compactMap { DownloadBatch.Track(row: $0, folder: folder) }
    }

    static func rows(_ count: Int, prefix: String = "Song") -> [QueueItem] {
        (1...count).map { row("\(prefix) \($0)") }
    }

    /// A batch with stand-ins; the gate clock never fires unless told to.
    static func batch(_ rows: [QueueItem], kind: DownloadBatch.Kind = .downloadAll,
                      downloader: BatchScriptedDownloader,
                      network: BatchStandInNetwork = BatchStandInNetwork(),
                      keepAwake: BatchRecordingKeepAwake = BatchRecordingKeepAwake(),
                      sounds: BatchRecordingSounds = BatchRecordingSounds(),
                      clock: BatchGateClock = BatchGateClock(),
                      options: DownloadBatch.Options = DownloadBatch.Options()) -> DownloadBatch {
        DownloadBatch(tracks: tracks(rows), folder: folder, kind: kind, downloader: downloader, network: network,
                      keepAwake: keepAwake, sounds: sounds, clock: clock, options: options)
    }

    static func saved(_ name: String, _ quality: SavedQuality = .flac(bitDepth: 24, sampleRate: 96_000),
                      notes: [SaveNote] = []) -> TrackDownloadOutcome {
        .saved(fileName: name, quality: quality, notes: notes)
    }
}
