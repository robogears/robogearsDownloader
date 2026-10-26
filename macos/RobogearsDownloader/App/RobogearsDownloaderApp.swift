import AppKit
import SwiftUI
import UserNotifications

/// The entry point: runs a debug instrument when asked to (snapshots, or
/// the model checks in debug builds; never shown to the person), otherwise
/// runs the app.
@main
enum AppMain {
    @MainActor
    static func main() {
        // The instruments never touch the person's Application Support
        // folder or preferences: everything they save goes to a temporary
        // folder of their own (StorageLocation).
        #if DEBUG
        if SelfChecks.requested(CommandLine.arguments) {
            StorageLocation.isolateForInstrument()
            SelfChecks.run()
            return
        }
        #endif
        if let directory = SnapshotHarness.requestedDirectory(CommandLine.arguments) {
            StorageLocation.isolateForInstrument()
            SnapshotHarness.run(into: directory)
        } else {
            RobogearsDownloaderApp.main()
        }
    }
}

struct RobogearsDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    var body: some Scene {
        // One main window (Window, not WindowGroup). Closing it keeps
        // downloading; Window › robogears Downloader reopens it.
        Window("robogears Downloader", id: "main") {
            MainWindow(model: model)
        }
        .defaultSize(width: Metrics.windowDefault.width, height: Metrics.windowDefault.height)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsWindow(model: model)
        }

        Window("About robogears Downloader", id: "about") {
            // The title stays for the Window menu and Mission Control; the
            // window itself shows only its content, like other About windows.
            AboutWindow(model: model)
                .toolbar(removing: .title)
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

/// Quit confirmation during a batch, last-window behaviour, reopening, the
/// Dock menu and the end-of-batch notification's buttons.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([AppModel.batchNotificationCategory])
    }

    /// Closing the window keeps downloading (4.9); the Dock shows progress.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with the window closed brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.openMainWindow() }
        return true
    }

    /// ⌘Q, Quit and logging out during a batch ask first, app-modal so the
    /// question shows even with the window closed or a sheet up; Keep
    /// Downloading is the default (Return) and Quit has no key, so Escape
    /// can never quit (4.9, D4 2.5). An update that is quitting to install,
    /// or a Quit already chosen, goes straight through.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let decision = QuitDecision.make(batch: model.batch, quitConfirmed: model.quitConfirmed,
                                         quittingForUpdate: model.update?.isQuittingForUpdate == true)
        if case .ask(let remaining) = decision {
            let content = AlertRoute.quitDuringBatch(remaining: remaining).content
            NSApp.activate()
            let response = content.makeNSAlert().runModal()
            guard content.action(for: response) == .quit else { return .terminateCancel }
            model.quitConfirmed = true
        }
        Task { @MainActor in
            await model.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Control-click on the Dock icon: Download All / Stop Downloads, Open Download Folder.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let model = AppModel.shared
        let menu = NSMenu()
        menu.autoenablesItems = false
        if model.batch != nil {
            menu.addItem(ActionMenuItem("Stop Downloads") { model.stopDownloads() })
        } else {
            let item = ActionMenuItem(model.downloadButtonTitle) { model.downloadAll() }
            item.isEnabled = model.canDownload && !model.isModalUp
            menu.addItem(item)
        }
        let open = ActionMenuItem("Open Download Folder") { model.openDownloadFolder() }
        open.isEnabled = model.settings.downloadFolder != nil
        menu.addItem(open)
        return menu
    }

    // MARK: The end-of-batch notification

    /// Clicking the notification brings the window forward; Show in Finder
    /// opens the download folder (D4 2.12).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let showInFinder = response.actionIdentifier == AppModel.showInFinderActionID
        await MainActor.run {
            let model = AppModel.shared
            if showInFinder { model.openDownloadFolder() } else { model.openMainWindow() }
        }
    }

    /// A batch can end while Settings is in front: the banner still shows.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// An NSMenuItem that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

extension AppModel {
    /// Before quitting: unfinished rows wait (retried rows keep their
    /// failure), the queue and settings are saved, the preview stops.
    func prepareForQuit() async {
        if let batch {
            for id in batch.ids {
                guard let row = row(id), row.inBatch else { continue }
                row.item.state = batch.retriedReasons[id].map { .failed(reason: $0) } ?? .waiting
            }
            await services.downloader.stop()
        }
        stopPreview()
        saveSettingsNow()
        await flushQueue()
        // What's New › Install on Quit: the staged update installs now.
        if update?.isQuittingForUpdate != true { installChosenUpdateAtQuit() }
    }
}
