import AppKit
import RobogearsCore

/// What alert buttons do, the first-launch questions, and finding the main
/// window again after it was closed.
extension AppModel {
    func perform(_ action: AlertAction) {
        switch action {
        case .dismiss:
            break
        case .signIn(let pending):
            // The alert is still leaving; the sheet comes up once it's gone.
            // One sign-in at a time, never during a batch (D4 1.2, 1.3).
            afterAlertCloses { model in
                guard model.canChangeSignIn, !model.isSigningIn else {
                    model.activity.add(.warning, model.canChangeSignIn
                                       ? "Finish signing in to TIDAL in Settings, then try again."
                                       : "You can sign in to TIDAL once the downloads finish, then try again.")
                    return
                }
                model.sheet = .signIn(resumeAdd: pending)
            }
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
        }
    }

    /// Runs `body` once the main window has no alert or sheet up, and the
    /// last one has finished leaving (SwiftUI clears the route before its
    /// close animation ends, and a second presentation during it is lost).
    func afterAlertCloses(_ body: @escaping @MainActor (AppModel) -> Void) {
        Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                if self.alert == nil && self.sheet == nil {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard self.alert == nil && self.sheet == nil else { continue }
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
            guard model.adding == nil, model.batch == nil, !model.firstLaunchQueue.isEmpty else { return }
            let next = model.firstLaunchQueue.removeFirst()
            model.markShown(next)
            switch next {
            case .moveToApplications: model.alert = .moveToApplications
            case .oldFiles: model.sheet = .oldFiles
            }
        }
    }

    /// Records that a first-launch question was asked, so it never comes
    /// back: the old-files notice in the settings file (AppSettings.
    /// oldAppNoticeShown, D4 5.11 "explain once"), the move offer as a small value.
    func markShown(_ notice: FirstLaunchNotice) {
        switch notice {
        case .moveToApplications:
            StorageLocation.values.set(true, forKey: FirstLaunch.moveOfferedKey)
        case .oldFiles:
            settings.oldAppNoticeShown = true
            saveSettingsNow()
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

    // MARK: The previous version's files (D4 5.11)

    /// Show Old Files: the old folder in Finder, its known items selected.
    func showOldFiles() {
        let items = services.oldFiles.presentItems()
        if items.isEmpty {
            NSWorkspace.shared.open(services.oldFiles.folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(items)
        }
    }

    /// Move to Trash: only the known old items, recoverable. Returns the
    /// sentence for the notice when something couldn't be moved.
    @discardableResult
    func trashOldFiles() -> String? {
        do {
            let moved = try services.oldFiles.moveToTrash()
            activity.add(.notice, moved.count == 1
                         ? "Moved 1 item from the previous version to the Trash."
                         : "Moved \(Formatting.count(moved.count)) items from the previous version to the Trash.")
            return nil
        } catch {
            let left = services.oldFiles.presentItems().count
            let still = left == 1 ? "1 item is" : "\(Formatting.count(left)) items are"
            let message = "Some of the previous version's files couldn't be moved to the Trash (\(error.localizedDescription)). \(still) still in \(Formatting.abbreviatedPath(services.oldFiles.folder.path)); you can move them in Finder."
            activity.add(.warning, message)
            return message
        }
    }

    /// Delete Old Sign-in: the old token.json, for good. Returns a sentence
    /// for the notice when it failed.
    @discardableResult
    func deleteOldSignIn() -> String? {
        do {
            try services.oldFiles.deleteOldSignIn()
            activity.add(.notice, "Deleted the previous version's TIDAL sign-in.")
            return nil
        } catch {
            let message = "The old sign-in couldn't be deleted (\(error.localizedDescription)). It's token.json in \(Formatting.abbreviatedPath(services.oldFiles.folder.path))."
            activity.add(.warning, message)
            return message
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
        if let window = mainWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindowAction {
            openMainWindowAction()
        } else {
            mainWindow?.makeKeyAndOrderFront(nil)
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

/// What ⌘Q, Quit and logging out do (4.9, D4 2.5): ask only while a batch
/// runs, and never when the app quits to install an update it already asked
/// about, or after the person chose Quit.
enum QuitDecision: Equatable {
    case quit
    case ask(remaining: Int)

    static func make(batch: BatchState?, quitConfirmed: Bool, quittingForUpdate: Bool) -> QuitDecision {
        guard let batch, !quitConfirmed, !quittingForUpdate else { return .quit }
        return .ask(remaining: max(0, batch.total - batch.finished))
    }
}
