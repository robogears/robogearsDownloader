import AppKit
import RobogearsCore

/// What the window shows of an available update: the version, the notes for
/// What's New, and whether this copy can install it itself.
struct UpdateInfo: Equatable, Sendable {
    var version: String
    var notes: String
    var releaseURL: URL?
    /// False in debug builds and when the app's folder can't be changed: the
    /// install buttons then open the release page instead.
    var canSelfInstall: Bool
}

/// The one-line result beside Check Now in Settings › Updates (4.12).
enum UpdateStatusLine: Equatable, Sendable {
    case none
    case checking
    case upToDate
    case available(version: String)
    case offline
    case rateLimited
    case noReleases
    case failed(String)
    case downloading(percent: Int)
    case installing
    case installsOnQuit(version: String)

    var text: String {
        switch self {
        case .none: ""
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .available(let v): "\(v) available"
        case .offline: "No internet connection"
        case .rateLimited: "GitHub is limiting checks; try again in an hour"
        case .noReleases: "No releases yet"
        case .failed(let message): message
        case .downloading(let p): "Downloading \(p)%"
        case .installing: "Installing…"
        case .installsOnQuit(let v): "\(v) installs when you quit"
        }
    }

    var isProblem: Bool {
        switch self {
        case .offline, .rateLimited, .failed: true
        default: false
        }
    }
}

/// The updater in the window (4.8; D4 5.9, 5.12): one engine behind the
/// toolbar control, What's New, the app menu and Settings.
extension AppModel {
    var updateInfo: UpdateInfo? {
        if let updateInfoOverride { return updateInfoOverride }
        guard let update, let available = update.available else { return nil }
        return UpdateInfo(version: available.version, notes: available.notes, releaseURL: available.releaseURL,
                          canSelfInstall: update.canSelfInstall)
    }

    var updateStatusLine: UpdateStatusLine {
        if let updateStatusOverride { return updateStatusOverride }
        guard let update else { return .none }
        switch update.phase {
        case .idle: return update.available.map { .available(version: $0.version) } ?? .none
        case .checking: return .checking
        case .upToDate: return .upToDate
        case .available: return .available(version: update.available?.version ?? "")
        case .offline: return .offline
        case .rateLimited: return .rateLimited
        case .noReleases: return .noReleases
        case .failed(let message): return .failed(message)
        case .downloading(let p): return .downloading(percent: p)
        case .verifying: return .downloading(percent: 100)
        case .readyToInstall:
            return installOnQuit ? .installsOnQuit(version: update.available?.version ?? "") : .installing
        case .applying: return .installing
        }
    }

    /// Check Now has an updater to ask (the snapshot harness pins a status instead).
    var canCheckForUpdates: Bool { update != nil || updateStatusOverride != nil }

    /// Settings › Updates › What's New…, and Help › What's New.
    func showWhatsNew() {
        guard updateInfo != nil else { return }
        openMainWindow()
        guard sheet == nil, alert == nil else { return }
        sheet = .whatsNew
    }

    var isCheckingForUpdates: Bool {
        if case .checking = update?.phase { true } else { false }
    }

    // MARK: Installing

    /// The toolbar control, Install and Relaunch, and Relaunch to Update.
    /// During a batch it asks first (D4 5.12).
    func updateControlClicked() {
        if let batch {
            alert = .updateDuringBatch(remaining: max(0, batch.total - batch.finished))
        } else {
            performUpdate()
        }
    }

    /// Downloads (unless already staged), then installs and relaunches.
    func performUpdate() {
        guard let update, update.available != nil else { return }
        guard update.canSelfInstall else {
            openReleasePage()
            return
        }
        Task {
            await stageUpdate()
            guard update.phase == .readyToInstall else { return }
            await flushQueue()
            update.installStagedUpdate { NSApp.terminate(nil) }
            if case .failed(let message) = update.phase { activity.add(.failed, message) }
        }
    }

    /// Downloads and checks the update without installing it. One at a time:
    /// a second call waits for the first.
    func stageUpdate() async {
        if let stageTask {
            await stageTask.value
            return
        }
        guard let update, update.available != nil, update.phase != .readyToInstall else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let version = update.available?.version {
                self.activity.add(.update, "Downloading robogears Downloader \(version)…")
            }
            await update.downloadAndStage()
            if case .failed(let message) = update.phase {
                self.activity.add(.failed, message)
                self.installOnQuit = false
                self.updateAfterBatch = false
            }
        }
        stageTask = task
        await task.value
        stageTask = nil
    }

    /// What's New › Install on Quit: download now, install at the next quit.
    func chooseInstallOnQuit() {
        guard let info = updateInfo else { return }
        guard info.canSelfInstall else {
            openReleasePage()
            return
        }
        installOnQuit = true
        activity.add(.update, "robogears Downloader \(info.version) installs the next time you quit.")
        Task { await stageUpdate() }
    }

    /// Update When Downloads Finish: download now, relaunch when the batch ends.
    func updateWhenDownloadsFinish() {
        updateAfterBatch = true
        if let info = updateInfo {
            activity.add(.update, "robogears Downloader \(info.version) installs when the downloads finish.")
        }
        Task { await stageUpdate() }
    }

    /// Update Now during a batch: stop the batch; the update installs as it ends.
    func updateNowDuringBatch() {
        updateAfterBatch = true
        stopDownloads()
    }

    /// At quit, after the person chose Install on Quit: starts the relauncher.
    /// Returns whether it did.
    @discardableResult
    func installChosenUpdateAtQuit() -> Bool {
        guard installOnQuit, let update, update.phase == .readyToInstall else { return false }
        update.installStagedUpdate {}
        return update.isQuittingForUpdate
    }

    /// What's New › Skip This Version: the toolbar control stays hidden for
    /// this version (a newer one, or Check for Updates…, shows again).
    func skipThisVersion() {
        guard let info = updateInfo else { return }
        setSkippedVersion(info.version)
        activity.add(.update, "Skipped robogears Downloader \(info.version). Check for Updates… shows it again.")
    }

    func setSkippedVersion(_ version: String?) {
        skippedUpdateVersion = version
        guard persists else { return }
        if let version {
            StorageLocation.values.set(version, forKey: Self.skippedVersionKey)
        } else {
            StorageLocation.values.removeObject(forKey: Self.skippedVersionKey)
        }
    }

    /// What's New's install button, after the sheet has gone: during a batch
    /// it asks first, so the alert must not meet the closing sheet.
    func installFromWhatsNew() {
        sheet = nil
        afterAlertCloses { $0.updateControlClicked() }
    }

    func openReleasePage() {
        let page = updateInfo?.releaseURL ?? URL(string: "https://github.com/robogears/robogearsDownloader/releases/latest")!
        NSWorkspace.shared.open(page)
    }

    // MARK: Checking

    /// Check for Updates… (app menu) and Check Now (Settings). From the menu,
    /// a newer version opens What's New and anything else answers in an
    /// alert; Settings shows the result beside the button instead.
    func checkForUpdates(fromMenu: Bool = false) {
        guard let update else { return }
        Task {
            await update.check(silent: false)
            switch update.phase {
            case .available:
                if let v = update.available?.version {
                    // A check the person asked for shows a skipped version again.
                    if skippedUpdateVersion == v { setSkippedVersion(nil) }
                    activity.add(.update, "robogears Downloader \(v) is available.")
                    announce("robogears Downloader \(v) is available.")
                    if fromMenu, sheet == nil, alert == nil {
                        openMainWindow()
                        sheet = .whatsNew
                    }
                }
            case .upToDate:
                activity.add(.update, "robogears Downloader is up to date.")
                if fromMenu {
                    showCheckResult("You're up to date.", "robogears Downloader \(Self.currentVersion) is the newest version.")
                }
            case .offline:
                activity.add(.warning, "No internet connection. Check for updates again when you're online.")
                if fromMenu { showCheckResult("No internet connection", "Check for updates again when you're online.") }
            case .rateLimited:
                activity.add(.warning, "GitHub is limiting checks; try again in an hour.")
                if fromMenu { showCheckResult("GitHub is limiting checks", "Try again in an hour.") }
            case .noReleases:
                if fromMenu { showCheckResult("No releases yet", "There's nothing to update to.") }
            case .failed(let message):
                activity.add(.failed, message)
                if fromMenu { showCheckResult("Couldn't check for updates", message) }
            default:
                break
            }
        }
    }

    private func showCheckResult(_ title: String, _ message: String) {
        guard sheet == nil, alert == nil else { return }
        openMainWindow()
        alert = .information(title: title, message: message)
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? RobogearsCore.version
    }
}
