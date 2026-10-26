import AppKit
import RobogearsCore

/// What alert buttons do, the first-launch questions, and finding the main
/// window again after it was closed.
extension AppModel {
    func perform(_ action: AlertAction) {
        switch action {
        case .dismiss, .keepOldFiles:
            break
        case .signIn(let pending):
            // The alert is still leaving; the sheet comes up once it's gone.
            afterAlertCloses { $0.sheet = .signIn(resumeAdd: pending) }
        case .quit:
            quitConfirmed = true
            NSApp.terminate(nil)
        case .updateNow:
            updateNowDuringBatch()
        case .updateWhenDownloadsFinish:
            updateWhenDownloadsFinish()
        case .importFirstLines(let text, let name):
            importFirstLines(text, name: name)
        case .resetFolders:
            resetFolders()
        case .moveToApplications:
            moveToApplications()
        case .trashOldFiles:
            trashOldFiles()
        case .showOldFiles:
            let files = OldAppFiles.found(in: AppPaths.supportDirectory())
            if files.isEmpty {
                NSWorkspace.shared.open(AppPaths.supportDirectory())
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        }
    }

    /// Runs `body` once the window has no alert or sheet up (SwiftUI clears
    /// the alert only after its button's action returns).
    func afterAlertCloses(_ body: @escaping @MainActor (AppModel) -> Void) {
        Task { @MainActor [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if self.alert == nil && self.sheet == nil {
                    body(self)
                    return
                }
            }
        }
    }

    // MARK: First launch (4.11)

    /// Asks the next first-launch question, if any, once nothing else is up.
    func presentNextFirstLaunchNotice() {
        guard !firstLaunchQueue.isEmpty else { return }
        afterAlertCloses { model in
            guard model.adding == nil, !model.firstLaunchQueue.isEmpty else { return }
            let next = model.firstLaunchQueue.removeFirst()
            FirstLaunch.markShown(next)
            model.alert = next
        }
    }

    private func moveToApplications() {
        firstLaunchQueue.removeAll()
        do {
            try AppLocation.moveToApplications()
            NSApp.terminate(nil)
        } catch {
            let message = (error as? ServiceError)?.message
                ?? "The app couldn't be moved (\(error.localizedDescription)). Drag it to the Applications folder in Finder instead."
            activity.add(.failed, message)
            afterAlertCloses { $0.alert = .information(title: "robogears Downloader couldn't move itself", message: message) }
        }
    }

    private func trashOldFiles() {
        let files = OldAppFiles.found(in: AppPaths.supportDirectory())
        let result = OldAppFiles.moveToTrash(files)
        if result.failed.isEmpty {
            activity.add(.notice, "Moved \(Formatting.count(result.moved)) files from the previous version to the Trash.")
        } else {
            activity.add(.warning, "Moved \(Formatting.count(result.moved)) files from the previous version to the Trash. These couldn't be moved: \(result.failed.joined(separator: ", ")). You can remove them in Finder.")
        }
    }

    // MARK: Settings › Folders

    /// Reset Folders…: forgets both folders, keeps the TIDAL sign-in.
    func resetFolders() {
        settings.resetFolders()
        saveSettingsNow()
        libraryScanTask?.cancel()
        libraryScanTask = nil
        libraryStatus = .none
        folderProblem = nil
        activity.add(.notice, "Forgot the download and library folders. Your TIDAL sign-in stays.")
    }

    // MARK: The main window

    /// Brings the main window forward, reopening it if it was closed.
    func openMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }

    /// The main window is in front and key (the end of a batch is then seen).
    var isMainWindowKey: Bool {
        if let mainWindowIsKeyOverride { return mainWindowIsKeyOverride }
        guard let mainWindow else { return false }
        return NSApp.isActive && mainWindow.isKeyWindow
    }

    /// The main window is open on screen (closed or minimised windows aren't).
    var isMainWindowVisible: Bool {
        guard let mainWindow else { return false }
        return mainWindow.isVisible && !mainWindow.isMiniaturized
    }
}
