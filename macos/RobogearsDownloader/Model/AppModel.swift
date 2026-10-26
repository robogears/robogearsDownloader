import AppKit
import Observation
import RobogearsCore
import SwiftUI

/// The main window's state and every command the window, the menu bar and the
/// Dock menu send. One instance for the app's life. Rows are separate
/// observable objects so a progress tick touches one row only.
@MainActor
@Observable
final class AppModel {
    // MARK: Dependencies

    @ObservationIgnored let services: AppServices
    @ObservationIgnored let player: any PreviewPlaying
    @ObservationIgnored let sounds = SoundPlayer()
    @ObservationIgnored private let settingsStore: SettingsStore?
    @ObservationIgnored let queueStore: QueueStore?
    /// The real updater from RobogearsCore (nil in the snapshot harness).
    let update: UpdateService?
    /// The main window's undo manager (Edit › Undo names each action).
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored let dockProgress = DockProgress()

    // MARK: Settings

    var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    // MARK: Queue

    /// The queue, in order. Replaced only when rows are added, removed or
    /// moved; a row's own changes don't touch this array.
    var rows: [QueueRow] = []
    var selection: Set<UUID> = []
    let activity = ActivityLog()

    // MARK: Routing and transient UI state

    var sheet: SheetRoute?
    var alert: AlertRoute? {
        didSet { if alert == nil, oldValue != nil { presentNextFirstLaunchNotice() } }
    }
    var signInState: SignInState = .signedOut
    /// A sign-in sheet is up (on the main window or Settings): one at a time (D4 1.3).
    var isSigningIn = false
    /// An add in flight: the adding cover is up.
    var adding: AddingState?
    var batch: BatchState?
    /// The notice in the batch slot after a batch (or a Spotify cap notice).
    var summary: BatchSummary?
    var isActivityVisible = true
    var addFieldText = ""
    /// Bumped by ⌘L; the window moves focus to the Add field when it changes.
    var focusAddFieldRequest = 0
    /// Install the update as soon as the running batch ends (4.8).
    var updateAfterBatch = false
    /// What's New › Install on Quit: the staged update installs at the next quit.
    var installOnQuit = false
    /// Set once the person chose Quit in the quit-during-batch alert.
    var quitConfirmed = false
    /// The snapshot harness shows the update control without a network check.
    var updateControlOverride: UpdateControlState?
    /// The snapshot harness shows What's New and Settings › Updates without a check.
    var updateInfoOverride: UpdateInfo?
    var updateStatusOverride: UpdateStatusLine?
    @ObservationIgnored var stageTask: Task<Void, Never>?

    // MARK: Settings window state

    /// The library index, for Settings › Folders ("1,240 files indexed").
    var libraryStatus: LibraryStatus = .none
    @ObservationIgnored var libraryScanTask: Task<Void, Never>?
    /// Bytes in the preview cache (Settings › General); nil until measured.
    var previewCacheBytes: Int64?
    /// Why the last folder choice was refused, shown under the folder in Settings.
    var folderProblem: FolderProblem?
    /// macOS has notifications turned off for the app (Settings › General).
    var notificationsBlocked = false
    /// First-launch questions still to ask, one after the other.
    @ObservationIgnored var firstLaunchQueue: [AlertRoute] = []
    /// Reopens the main window (set by the window; used after it was closed).
    @ObservationIgnored var openMainWindowAction: (@MainActor () -> Void)?
    /// The main window, once it exists (for the quit question and attention).
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// The snapshot harness pins whether the main window is key.
    @ObservationIgnored var mainWindowIsKeyOverride: Bool?

    // MARK: Preview

    var nowPlayingID: UUID?
    var isPreviewPlaying = false
    var previewLoadingID: UUID?
    /// Bumped when the playhead moves without playing (a seek while paused),
    /// so the current row's bars redraw once.
    var previewPositionToken = 0
    @ObservationIgnored var previewGeneration = 0
    @ObservationIgnored var preloadQueue: [UUID] = []
    @ObservationIgnored var preloadInFlight = 0
    /// The snapshot harness pins the playhead instead of reading a player.
    var previewProgressOverride: Double?

    // MARK: Tasks

    @ObservationIgnored var addTask: Task<Void, Never>?
    @ObservationIgnored var batchTask: Task<Void, Never>?
    @ObservationIgnored private var settingsSaveTask: Task<Void, Never>?
    @ObservationIgnored var awakeActivity: NSObjectProtocol?
    @ObservationIgnored private var started = false
    /// Off in the snapshot harness, so rendering never loads anything.
    @ObservationIgnored var preloadingEnabled = true
    /// False in the snapshot harness: nothing is saved there.
    @ObservationIgnored let persists: Bool

    init(services: AppServices, player: any PreviewPlaying, settings: AppSettings,
         settingsStore: SettingsStore?, queueStore: QueueStore?, update: UpdateService?) {
        self.services = services
        self.player = player
        self.settings = settings
        self.settingsStore = settingsStore
        self.queueStore = queueStore
        self.update = update
        self.persists = settingsStore != nil
        sounds.isEnabled = settings.playSoundEffects
        player.volume = settings.previewGain
        player.onFinish = { [weak self] in self?.previewDidFinish() }
    }

    /// The app's model: saved settings and queue, the real updater, and the
    /// stand-in services until the real ones are wired.
    static func live() -> AppModel {
        let support = AppPaths.supportDirectory()
        let store = SettingsStore(file: AppPaths.settingsFile(in: support))
        let (settings, outcome) = store.load()
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let update = UpdateService(
            configuration: .standard(isDebugBuild: isDebug, supportDirectory: support),
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? RobogearsCore.version,
            runningBundle: Bundle.main.bundleURL,
            isDebugBuild: isDebug)
        let model = AppModel(services: StandIn.services(), player: StandInPreviewPlayer(), settings: settings,
                             settingsStore: store, queueStore: QueueStore(file: AppPaths.queueFile(in: support)),
                             update: update)
        if case .unreadable(let kept) = outcome {
            model.activity.add(.warning, "Your settings couldn't be read, so they start fresh. The old file was kept\(kept.map { " at \(Formatting.abbreviatedPath($0))" } ?? "").")
        }
        return model
    }

    static let shared = AppModel.live()

    /// The snapshot harness shows a fixed state: no launch work, no loading.
    func prepareForSnapshot() {
        started = true
        preloadingEnabled = false
    }

    /// Once, when the main window first appears.
    func start() {
        guard !started else { return }
        started = true
        if let moved = AppLocation.trashMovedOriginalIfNeeded() { activity.add(.notice, moved) }
        Task {
            signInState = await services.signIn.currentState()
            await restoreQueue()
            rescanLibrary()
            refreshNotificationPermission()
            // The first-launch questions wait until the window has settled.
            try? await Task.sleep(for: .milliseconds(600))
            firstLaunchQueue = FirstLaunch.pendingNotices()
            presentNextFirstLaunchNotice()
        }
        // The launch check is silent and only in release builds: debug builds
        // never reach GitHub on their own (manual Check for Updates… still does).
        #if !DEBUG
        if settings.checkForUpdatesAutomatically, let update {
            Task { await update.check(silent: true) }
        }
        #endif
    }

    private func restoreQueue() async {
        guard let queueStore else { return }
        switch await queueStore.load() {
        case .loaded(let items):
            appendRows(items.map(QueueRow.init(item:)))
            if !items.isEmpty { activity.add(.notice, "Restored \(Formatting.tracks(items.count)) from your last session.") }
        case .empty:
            break
        case .unreadable(let kept):
            activity.add(.warning, "Your saved queue couldn't be read, so the queue starts empty. The old file was kept\(kept.map { " at \(Formatting.abbreviatedPath($0))" } ?? "").")
        }
    }

    // MARK: Settings

    private func settingsDidChange(from old: AppSettings) {
        sounds.isEnabled = settings.playSoundEffects
        if settings.previewVolume != old.previewVolume { player.volume = settings.previewGain }
        guard persists, settings != old else { return }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.saveSettingsNow()
        }
    }

    func saveSettingsNow() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        guard persists, let settingsStore else { return }
        do {
            try settingsStore.save(settings)
        } catch {
            activity.add(.failed, "Your settings couldn't be saved (\(error.localizedDescription)). Check the startup disk has free space.")
        }
    }

    var isSignedIn: Bool {
        if case .signedIn = signInState { true } else { false }
    }

    // MARK: Aggregates (read by the toolbar and the header)

    /// Rows Download All would send now (checked, included, matched).
    var downloadableCount: Int {
        rows.reduce(0) { $0 + (($1.item.isDownloadable && !$1.isCheckingLibrary) ? 1 : 0) }
    }

    var failedRows: [QueueRow] {
        rows.filter { if case .failed = $0.item.state { true } else { false } }
    }

    /// "Download All", or "Download (47)" when rows are left out or not found.
    var downloadButtonTitle: String {
        let n = downloadableCount
        return n == rows.count || n == 0 ? "Download All" : "Download (\(Formatting.count(n)))"
    }

    var canDownload: Bool { batch == nil && downloadableCount > 0 }

    /// Rows selected, in queue order.
    var selectedRows: [QueueRow] { rows.filter { selection.contains($0.id) } }

    func row(_ id: UUID) -> QueueRow? { rows.first { $0.id == id } }

    /// Retry Selected when a selected row failed; otherwise Retry All Failed (N).
    var retryTitle: String? {
        let failed = failedRows
        guard !failed.isEmpty else { return nil }
        if failed.contains(where: { selection.contains($0.id) }) { return "Retry Selected" }
        return "Retry All Failed (\(Formatting.count(failed.count)))"
    }

    var batchCounterText: String? {
        guard let batch else { return nil }
        let base = "\(Formatting.count(batch.finished)) of \(Formatting.count(batch.total))"
        return batch.waitingForTIDAL ? base + " · waiting for TIDAL…" : base
    }

    /// What the toolbar's update control shows, if anything.
    var updateControl: UpdateControlState? {
        if let updateControlOverride { return updateControlOverride }
        guard let update, let available = update.available else { return nil }
        switch update.phase {
        case .available, .failed, .idle, .upToDate, .checking, .noReleases, .offline, .rateLimited:
            return .available(version: available.version)
        case .downloading(let percent):
            return .downloading(percent: percent)
        case .verifying:
            return .downloading(percent: 100)
        case .readyToInstall:
            // Staged and waiting: for the batch to end (D4 5.12), or for a quit.
            if updateAfterBatch, batch != nil { return .afterDownloads }
            if installOnQuit { return .relaunchToUpdate }
            return .relaunching
        case .applying:
            return .relaunching
        }
    }

    /// Something modal is up: ⌘↩ and paste stay away from it.
    var isModalUp: Bool { sheet != nil || alert != nil }

    /// Announces a sentence to VoiceOver.
    func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// The adding cover's state (4.11).
struct AddingState: Equatable {
    let id = UUID()
    /// Picks the first loading line.
    var seed = Int.random(in: 0..<LoadingLines.all.count)
    var startedAt = Date()
    var done = 0
    var total: Int?
    /// "Matching 34 / 100 tracks on TIDAL…" once a count is known.
    var countText: String? {
        guard let total, total > 0 else { return nil }
        return "Matching \(Formatting.count(done)) / \(Formatting.count(total)) tracks on TIDAL…"
    }
}

/// The running batch (one at a time).
struct BatchState: Equatable {
    var folder: URL
    /// The rows in this batch, in order.
    var ids: [UUID]
    /// Counts only this batch, shrinking when a row is removed (D4 2.22).
    var total: Int
    var finished = 0
    var waitingForTIDAL = false
    /// A complete Download All clears library rows at the end; a retry doesn't (D4 3.6).
    var isDownloadAll: Bool
    /// Rows left out as already in the library when Download All was pressed.
    var libraryRowsAtStart: Set<UUID> = []
    /// Rows being retried go back to their earlier failure if stopped (D4 2.1).
    var retriedReasons: [UUID: String] = [:]
    var downloaded = 0
    var alreadyInFolder = 0
    var failed = 0
    var savedAsAAC = 0
    var stoppedByPerson = false
    var stopCause: BatchStopCause?
}

enum UpdateControlState: Equatable {
    case available(version: String)
    case downloading(percent: Int)
    case relaunching
    /// Downloaded and waiting for the running batch (Update When Downloads Finish).
    case afterDownloads
    /// Downloaded and waiting for a quit (Install on Quit); a click installs now.
    case relaunchToUpdate

    var title: String {
        switch self {
        case .available(let v): "Update to \(v)"
        case .downloading(let p): "Downloading \(p)%"
        case .relaunching: "Relaunching…"
        case .afterDownloads: "Updates After Downloads"
        case .relaunchToUpdate: "Relaunch to Update"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .available, .relaunchToUpdate: true
        case .downloading, .relaunching, .afterDownloads: false
        }
    }

    var help: String {
        switch self {
        case .available: "Download the update and relaunch"
        case .downloading: "Downloading the update"
        case .relaunching: "Installing the update"
        case .afterDownloads: "The update installs when the downloads finish"
        case .relaunchToUpdate: "Install the downloaded update now"
        }
    }
}
