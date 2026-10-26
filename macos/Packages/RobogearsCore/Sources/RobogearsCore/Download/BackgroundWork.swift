// Long file work (writing a 150 MB FLAC, decoding it for the length check)
// that Cancel must not wait for.
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
