import AppKit
import SwiftUI

/// The entry point: runs a debug instrument when asked to (snapshots, or
/// the model checks in debug builds; never shown to the person), otherwise
/// runs the app.
@main
enum AppMain {
    @MainActor
    static func main() {
        #if DEBUG
        if SelfChecks.requested(CommandLine.arguments) {
            SelfChecks.run()
            return
        }
        #endif
        if let directory = SnapshotHarness.requestedDirectory(CommandLine.arguments) {
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
            AboutWindow(model: model)
                .windowMinimizeBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

/// Quit confirmation during a batch, last-window behaviour and the Dock menu.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps downloading (4.9); the Dock shows progress.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        let updating = model.update?.isQuittingForUpdate == true
        if let batch = model.batch, !model.quitConfirmed, !updating {
            model.alert = .quitDuringBatch(remaining: max(0, batch.total - batch.finished))
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "robogears Downloader" }?
                .makeKeyAndOrderFront(nil)
            return .terminateCancel
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
        if model.batch != nil {
            menu.addItem(ActionMenuItem("Stop Downloads") { model.stopDownloads() })
        } else {
            let item = ActionMenuItem(model.downloadButtonTitle) { model.downloadAll() }
            item.isEnabled = model.canDownload
            menu.addItem(item)
        }
        let open = ActionMenuItem("Open Download Folder") { model.openDownloadFolder() }
        open.isEnabled = model.settings.downloadFolder != nil
        menu.addItem(open)
        menu.autoenablesItems = false
        return menu
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
    }
}
