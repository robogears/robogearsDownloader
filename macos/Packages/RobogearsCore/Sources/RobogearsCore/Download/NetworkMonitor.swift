import Foundation
import Network
import Synchronization

/// What the batch needs to know about the Mac's connection.
public struct NetworkStatus: Sendable, Equatable {
    /// The Mac has a route to the internet. A hotel login page still counts
    /// as online here; the track download is what finds TIDAL unreachable.
    public var isOnline: Bool
    /// Low Data Mode or a phone hotspot: a paused batch asks before it
    /// resumes there, since a Hi-Res batch can use several GB (1.7).
    public var isMetered: Bool

    public init(isOnline: Bool, isMetered: Bool = false) {
        self.isOnline = isOnline
        self.isMetered = isMetered
    }
}

/// The batch's view of the network, injected so tests can switch the
/// "Wi-Fi" off and on without touching the real network.
public protocol NetworkMonitoring: Sendable {
    func currentStatus() async -> NetworkStatus
    /// Returns once the Mac has a connection, at once if it has one now.
    /// Throws `CancellationError` when the waiting task is cancelled, so
    /// Cancel and Quit end a pause straight away (1.7).
    func waitUntilOnline() async throws
}

/// The real monitor, built on `NWPathMonitor`. It only listens to the
/// system's own reports about network paths; it sends nothing anywhere.
public final class SystemNetworkMonitor: NetworkMonitoring {
    private struct State {
        var status: NetworkStatus?
        var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    }

    private let monitor = NWPathMonitor()
    private let state = Mutex(State())

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(Self.status(of: path))
        }
        monitor.start(queue: DispatchQueue(label: "robogears.download-network-monitor"))
    }

    deinit {
        monitor.cancel()
    }

    public func currentStatus() async -> NetworkStatus {
        status()
    }

    public func waitUntilOnline() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checked under the lock, so a cancel that lands while the
                // waiter is being added can't slip past both checks.
                let answer: Result<Void, any Error>? = state.withLock { s in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if (s.status ?? Self.status(of: monitor.currentPath)).isOnline { return .success(()) }
                    s.waiters[id] = continuation
                    return nil
                }
                if let answer { continuation.resume(with: answer) }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func status() -> NetworkStatus {
        state.withLock { $0.status } ?? Self.status(of: monitor.currentPath)
    }

    private func update(_ status: NetworkStatus) {
        let ready: [CheckedContinuation<Void, any Error>] = state.withLock { s in
            s.status = status
            guard status.isOnline else { return [] }
            let all = Array(s.waiters.values)
            s.waiters.removeAll()
            return all
        }
        for waiter in ready { waiter.resume() }
    }

    private static func status(of path: NWPath) -> NetworkStatus {
        NetworkStatus(isOnline: path.status == .satisfied, isMetered: path.isExpensive || path.isConstrained)
    }
}
