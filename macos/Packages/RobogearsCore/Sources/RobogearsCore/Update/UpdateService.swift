import Foundation
import Observation

/// The updater's state machine, observed directly by SwiftUI (recipe §6):
/// idle → checking → result; available → downloading → verifying →
/// readyToInstall → applying. Every failure lands in a state the UI can
/// recover from.
@MainActor
@Observable
public final class UpdateService {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case noReleases
        case rateLimited(retryAfterSeconds: Int?)
        case offline
        case available
        case downloading(percent: Int)
        case verifying
        case readyToInstall
        case applying
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var available: AvailableUpdate?
    /// Set when the app quits to install; quit confirmations must let it through.
    public private(set) var isQuittingForUpdate = false

    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let runningBundle: URL
    @ObservationIgnored private let isDebugBuild: Bool
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private let isWritable: @Sendable (String) -> Bool

    public init(configuration: UpdaterConfiguration, currentVersion: String, runningBundle: URL,
                isDebugBuild: Bool, session: URLSession = .shared,
                isWritable: @escaping @Sendable (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }) {
        self.checker = UpdateChecker(configuration: configuration, session: session)
        self.currentVersion = currentVersion
        self.runningBundle = runningBundle
        self.isDebugBuild = isDebugBuild
        self.isWritable = isWritable
        UpdateInstaller.sweepStaleStaging(in: FileManager.default.temporaryDirectory, appName: configuration.appName)
    }

    private var configuration: UpdaterConfiguration { checker.configuration }

    public var installDestination: URL {
        UpdateInstaller.installDestination(runningBundle: runningBundle, appName: configuration.appName, isWritable: isWritable)
    }

    /// False in debug builds or when the app's folder can't be changed: the
    /// UI then offers the release page instead of installing.
    public var canSelfInstall: Bool {
        UpdateInstaller.canSelfInstall(isDebugBuild: isDebugBuild, destination: installDestination, isWritable: isWritable)
    }

    /// Launch and periodic checks are silent: only a newer release changes
    /// what the person sees. A manual check (silent: false) also reports
    /// "up to date", offline and errors.
    public func check(silent: Bool) async {
        switch phase {
        case .checking, .downloading, .verifying, .readyToInstall, .applying: return
        default: break
        }
        let before = phase
        phase = .checking
        let result = await checker.check(currentVersion: currentVersion)
        lastCheck = Date()
        switch result {
        case .available(let update):
            available = update
            phase = .available
        case .upToDate:
            phase = silent ? (before == .available ? .available : .idle) : .upToDate
        case .noReleases:
            phase = silent ? .idle : .noReleases
        case .rateLimited(let seconds):
            phase = silent ? .idle : .rateLimited(retryAfterSeconds: seconds)
        case .offline:
            phase = silent ? .idle : .offline
        case .failed(let message):
            phase = silent ? .idle : .failed(message)
        }
    }

    /// Re-checks after a wake from sleep when the last check is over 12 hours old.
    public func recheckIfStale(now: Date = Date()) async {
        if let lastCheck, now.timeIntervalSince(lastCheck) < 12 * 3600 { return }
        await check(silent: true)
    }

    /// Download, verify and stage; stops at readyToInstall.
    public func downloadAndStage() async {
        guard let update = available, phase == .available || isRetryable else { return }
        guard canSelfInstall, let assetURL = update.assetURL else { return }
        do {
            let temp = FileManager.default.temporaryDirectory
            try UpdateInstaller.checkFreeSpace(assetSize: update.assetSize, in: temp)
            guard isWritable(installDestination.deletingLastPathComponent().path) else {
                throw UpdateInstallError.destinationNotWritable(installDestination.deletingLastPathComponent().path)
            }
            phase = .downloading(percent: 0)
            let zip = temp.appendingPathComponent("\(configuration.appName)-update-\(UUID().uuidString).zip")
            let downloader = UpdateDownloader(destination: zip, advertisedSize: update.assetSize,
                                              overridesAllowed: configuration.overridesAllowed) { [weak self] percent in
                Task { @MainActor in
                    if case .downloading = self?.phase { self?.phase = .downloading(percent: percent) }
                }
            }
            let file = try await downloader.download(from: assetURL)
            phase = .verifying
            let expected = await fetchSidecar(update.sha256URL)
            try UpdateInstaller.verify(file: file, expectedSHA256: expected)
            let app = try await Task.detached { [configuration] in
                try UpdateInstaller.unpackAndValidate(zip: file, expectedVersion: update.version,
                                                      appName: configuration.appName,
                                                      bundleIdentifier: configuration.bundleIdentifier,
                                                      stagingRoot: temp)
            }.value
            stagedApp = app
            phase = .readyToInstall
        } catch let error as UpdateInstallError {
            phase = .failed(error.message)
        } catch {
            phase = .failed(UpdateInstallError.download(error.localizedDescription).message)
        }
    }

    private var isRetryable: Bool { if case .failed = phase { return available != nil } else { return false } }

    /// Starts the relauncher and asks the caller to quit. If the staged copy
    /// has vanished (temporary folders get purged), it offers the download
    /// again instead of hanging on "Updating…".
    public func installStagedUpdate(terminate: @MainActor () -> Void) {
        guard phase == .readyToInstall, let update = available else { return }
        guard let staged = stagedApp, FileManager.default.fileExists(atPath: staged.path) else {
            stagedApp = nil
            phase = .available
            return
        }
        do {
            phase = .applying
            try UpdateInstaller.launchRelauncher(appName: configuration.appName, stagedApp: staged,
                                                 target: installDestination,
                                                 fromVersion: currentVersion, toVersion: update.version)
            isQuittingForUpdate = true
            terminate()
        } catch let error as UpdateInstallError {
            phase = error == .stageMissing ? .available : .failed(error.message)
        } catch {
            phase = .failed(UpdateInstallError.tool(error.localizedDescription).message)
        }
    }

    /// A sidecar that is missing or unreadable falls back to TLS alone.
    private func fetchSidecar(_ url: URL?) async -> String? {
        guard let url, UpdateAssets.isAllowedDownloadURL(url, overridesAllowed: configuration.overridesAllowed),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UpdateAssets.parseSidecar(String(decoding: data, as: UTF8.self))
    }
}
