import Foundation
import IOKit.pwr_mgt
import Synchronization

/// Keeps the Mac from sleeping when idle while a batch downloads (2.12).
/// The display can still sleep, and closing a MacBook's lid still sleeps
/// it. Both calls are safe to repeat.
public protocol SleepPreventing: Sendable {
    func preventSleep(reason: String)
    func allowSleep()
}

/// The real keep-awake: one IOKit power assertion of the kind that stops
/// idle system sleep only. `reason` is what `pmset -g assertions` shows.
public final class SystemSleepPreventer: SleepPreventing {
    private let assertion = Mutex<IOPMAssertionID?>(nil)

    public init() {}

    public func preventSleep(reason: String) {
        assertion.withLock { held in
            guard held == nil else { return }
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            // A refused assertion only means the Mac may sleep; downloads
            // still run, so nothing is reported.
            if result == kIOReturnSuccess { held = id }
        }
    }

    public func allowSleep() {
        assertion.withLock { held in
            guard let id = held else { return }
            IOPMAssertionRelease(id)
            held = nil
        }
    }

    /// Whether an assertion is held now (for tests and diagnostics).
    var isPreventingSleep: Bool { assertion.withLock { $0 != nil } }

    deinit {
        allowSleep()
    }
}
