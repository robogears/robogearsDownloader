import Foundation
import Synchronization
@testable import RobogearsCore

// Test support for the resolver lane. Every name carries a Resolve prefix so
// it can't collide with helpers other lanes add to the same test target. No
// test here reaches the network: every request goes through the TIDAL lane's
// `TIDALMockURLProtocol`, answered by a per-test `TIDALMockServer`.

// MARK: - Clock

/// Virtual time that only moves when the test says so. A sleep waits until
/// `advance(by:)` passes its wake time, so a test can hold the world inside a
/// 429 pause, look at it, then let it go.
final class ResolveManualClock: NetworkClock {
    private struct Sleeper {
        let id: Int
        let wake: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var nextID = 0
        var cancelled: Set<Int> = []
    }

    private let state: Mutex<State>

    init(now: Date = TIDALClientFixtures.start) {
        state = Mutex(State(now: now))
    }

    func now() -> Date { state.withLock { $0.now } }

    func sleep(for duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            defer { state.nextID += 1 }
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.contains(id) { return .failure(CancellationError()) }
                    let wake = state.now.addingTimeInterval(duration.timeInterval)
                    if wake <= state.now { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, wake: wake, continuation: continuation))
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let index = state.sleepers.firstIndex(where: { $0.id == id }) {
                    return state.sleepers.remove(at: index).continuation
                }
                state.cancelled.insert(id)
                return nil
            }
            waiting?.resume(throwing: CancellationError())
        }
    }

    /// Moves time on and wakes every sleeper whose time has come.
    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.addingTimeInterval(duration.timeInterval)
            let now = state.now
            let due = state.sleepers.filter { $0.wake <= now }
            state.sleepers.removeAll { $0.wake <= now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
}

// MARK: - Waiting for conditions

/// Polls `condition` for up to `limit` of real time.
func resolveEventually(upTo limit: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let end = ContinuousClock.now + limit
    while ContinuousClock.now < end {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Counts work inside a section and remembers the most at once, plus the
/// order names entered in.
final class ResolveConcurrency: Sendable {
    private let state = Mutex<(current: Int, peak: Int, order: [String])>((0, 0, []))

    func enter(_ name: String = "") {
        state.withLock {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
            $0.order.append(name)
        }
    }

    func leave() { state.withLock { $0.current -= 1 } }

    var current: Int { state.withLock { $0.current } }
    var peak: Int { state.withLock { $0.peak } }
    var order: [String] { state.withLock { $0.order } }
}

/// A list a mock handler or a task appends to from any thread.
final class ResolveLog<Element: Sendable>: Sendable {
    private let list = Mutex<[Element]>([])

    func append(_ element: Element) { list.withLock { $0.append(element) } }
    var all: [Element] { list.withLock { $0 } }
    var count: Int { list.withLock { $0.count } }
}
