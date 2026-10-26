import AppKit
import UserNotifications

/// "Notify When Downloads Finish" (off by default; D4 2.12, DESIGN_DIRECTION
/// 4.11). The app asks macOS for permission only when the person turns the
/// switch on, never at launch, and posts one notification per batch when the
/// window isn't key. The text is the summary sentence: no links, no account.
extension AppModel {
    /// Reads whether macOS lets the app notify (Settings › General shows a
    /// note when it doesn't). Never asks.
    func refreshNotificationPermission() {
        guard persists else { return }
        Task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            notificationsBlocked = status == .denied
        }
    }

    /// Settings › General: System Settings › Notifications, where only the
    /// person can turn them on.
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Called when the switch turns on: the system asks once; a refusal shows
    /// in Settings instead of failing silently.
    func requestNotificationPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsBlocked = !granted
            if !granted {
                activity.add(.warning, "macOS isn't letting robogears Downloader show notifications. Turn them on in System Settings › Notifications.")
            }
        }
    }

    /// One notification for the end of a batch, only when the person asked for them.
    func postBatchNotification(_ notice: BatchSummary) {
        guard persists, settings.notifyWhenDownloadsFinish else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.notificationTitle(for: notice.outcome)
        content.body = notice.sentence
        content.categoryIdentifier = Self.batchCategoryID
        let request = UNNotificationRequest(identifier: "batch-\(notice.id.uuidString)", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            try? await center.add(request)
        }
    }

    nonisolated static let batchCategoryID = "batch-finished"
    nonisolated static let showInFinderActionID = "show-in-finder"

    /// The notification's one button (D4 2.12: "with Show in Finder").
    static var batchNotificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: batchCategoryID,
                               actions: [UNNotificationAction(identifier: showInFinderActionID, title: "Show in Finder")],
                               intentIdentifiers: [])
    }

    static func notificationTitle(for outcome: BatchSummary.Outcome) -> String {
        switch outcome {
        case .allGood: "Downloads Done"
        case .someFailed: "Downloads Finished with Problems"
        case .stoppedByPerson, .stoppedByCause: "Downloads Stopped"
        case .noFolder, .spotifyCap: "robogears Downloader"
        }
    }
}
