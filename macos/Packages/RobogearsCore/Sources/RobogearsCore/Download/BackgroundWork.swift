// Long file work (writing a 150 MB FLAC or the AAC file, decoding it for the
// length check) that Cancel must not wait for.
//
// Decision 4, item 2.4: "Cancel stops the current track at once, download
// and tagging". The FLAC writer and Apple's decoder can't be interrupted
// halfway, and the length check decodes a whole Hi-Res track (seconds;
// docs/spikes/audio-and-tagging.md, part a). So they run on a background
// queue, and a cancelled download returns at once; the work finishes on
// its own and `afterAbandon` then cleans up whatever it left.
import Foundation
import Synchronization

enum BackgroundWork {
    /// Runs `work` off Swift's cooperative threads and returns its result.
    /// If the calling task is cancelled first, throws `CancellationError`
    /// straight away, lets `work` finish, then runs `afterAbandon`.
    static func run<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T,
        afterAbandon: @escaping @Sendable () -> Void = {}
    ) async throws -> T {
        let slot = Slot<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard slot.install(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try work() }
                    if slot.finish(with: result) { afterAbandon() }
                }
            }
        } onCancel: {
            slot.abandon()
        }
    }

    /// The same promise for async work that may not stop when cancelled,
    /// such as the AAC writer, which another part of the app provides and
    /// whose contract can't make it stop halfway. The work runs in a task of
    /// its own that is cancelled too, so it stops early if it can; either
    /// way the caller gets `CancellationError` at once, and `afterAbandon`
    /// runs once the work has really ended.
    static func run<T: Sendable>(
        async work: @escaping @Sendable () async throws -> T,
        afterAbandon: @escaping @Sendable () -> Void = {}
    ) async throws -> T {
        let slot = Slot<T>()
        let worker = Worker()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard slot.install(continuation) else { return }
                worker.start {
                    let result: Result<T, any Error>
                    do {
                        result = .success(try await work())
                    } catch {
                        result = .failure(error)
                    }
                    if slot.finish(with: result) { afterAbandon() }
                }
            }
        } onCancel: {
            slot.abandon()
            worker.cancel()
        }
    }

    /// The task running async work, cancelled with its caller even when
    /// the cancellation arrives before the task exists.
    private final class Worker: Sendable {
        private let state = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

        func start(_ body: @escaping @Sendable () async -> Void) {
            let task = Task { await body() }
            let cancelledFirst = state.withLock { state -> Bool in
                state.task = task
                return state.cancelled
            }
            if cancelledFirst { task.cancel() }
        }

        func cancel() {
            let task = state.withLock { state -> Task<Void, Never>? in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    /// One waiter, resumed once: by the work's result or by cancellation.
    private final class Slot<T: Sendable>: Sendable {
        private enum State {
            case idle
            case waiting(CheckedContinuation<T, any Error>)
            case abandoned
            case done
        }

        private let state = Mutex(State.idle)

        /// False when the task was cancelled before the work started; the
        /// continuation has been resumed with `CancellationError` then.
        func install(_ continuation: CheckedContinuation<T, any Error>) -> Bool {
            let cancelledEarly = state.withLock { state -> Bool in
                if case .abandoned = state { return true }
                state = .waiting(continuation)
                return false
            }
            if cancelledEarly { continuation.resume(throwing: CancellationError()) }
            return !cancelledEarly
        }

        func abandon() {
            let waiter = state.withLock { state -> CheckedContinuation<T, any Error>? in
                switch state {
                case .idle:
                    state = .abandoned
                    return nil
                case let .waiting(continuation):
                    state = .abandoned
                    return continuation
                case .abandoned, .done:
                    return nil
                }
            }
            waiter?.resume(throwing: CancellationError())
        }

        /// Hands the result to the waiter. True when nobody was waiting any
        /// more (the task was cancelled), so the caller cleans up instead.
        func finish(with result: Result<T, any Error>) -> Bool {
            let (waiter, wasAbandoned) = state.withLock { state -> (CheckedContinuation<T, any Error>?, Bool) in
                switch state {
                case let .waiting(continuation):
                    state = .done
                    return (continuation, false)
                case .abandoned:
                    return (nil, true)
                case .idle, .done:
                    state = .done
                    return (nil, false)
                }
            }
            waiter?.resume(with: result)
            return wasAbandoned
        }
    }
}
