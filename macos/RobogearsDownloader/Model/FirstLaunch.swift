import AppKit
import RobogearsCore

/// One of the two first-launch questions (DESIGN_DIRECTION 4.11).
enum FirstLaunchNotice: Equatable, Sendable {
    /// "Move robogears Downloader to Applications?" (an alert; D4 5.15).
    case moveToApplications
    /// The previous version's files (a small sheet: it carries D4 5.11's
    /// three actions plus Keep, one more than an alert holds).
    case oldFiles
}

/// The two first-launch questions (DESIGN_DIRECTION 4.11; D4 5.15, 5.11):
/// Move to Applications, then the previous version's files. One after the
/// other, each at most once, and only in release builds: a development build
/// must never offer to move itself or to tidy the files of the Electron app
/// still in use on this Mac.
enum FirstLaunch {
    static let moveOfferedKey = "FirstLaunch.MoveToApplicationsOffered"
    /// TODO(core integration): RobogearsCore's `AppSettings.oldAppNoticeShown`
    /// replaces this key once the lanes merge.
    static let oldFilesOfferedKey = "FirstLaunch.OldFilesOffered"
    /// Where the copy that chose Move ran from, so the new copy can put it in
    /// the Trash once it runs from Applications.
    static let movedFromKey = "FirstLaunch.MovedFrom"
    static let appName = "robogears Downloader"

    /// The rule, without the Mac: Move first, then the old files; each only
    /// once; the old files wait while the old app is still running (its
    /// files are in use).
    static func notices(moveOffered: Bool, outsideApplications: Bool, oldFilesShown: Bool,
                        oldFilesPresent: Bool, oldAppRunning: Bool) -> [FirstLaunchNotice] {
        var list: [FirstLaunchNotice] = []
        if !moveOffered, outsideApplications { list.append(.moveToApplications) }
        if !oldFilesShown, oldFilesPresent, !oldAppRunning { list.append(.oldFiles) }
        return list
    }

    /// The questions to ask at this launch, in order.
    @MainActor
    static func pendingNotices(oldFiles: any OldAppFilesProviding, defaults: UserDefaults = .standard,
                               bundleURL: URL = Bundle.main.bundleURL) -> [FirstLaunchNotice] {
        #if DEBUG
        return []
        #else
        // Another copy with our identity still running (the old app during a
        // switch-over) means its files are in use: ask another time.
        let othersRunning = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return notices(
            moveOffered: defaults.bool(forKey: moveOfferedKey),
            outsideApplications: AppLocation.shouldOfferMove(bundleURL: bundleURL,
                                                             destinationExists: { FileManager.default.fileExists(atPath: $0.path) }),
            oldFilesShown: defaults.bool(forKey: oldFilesOfferedKey),
            oldFilesPresent: oldFiles.shouldOfferNotice,
            oldAppRunning: othersRunning)
        #endif
    }

    /// Records that a question was shown, so it never comes back.
    static func markShown(_ notice: FirstLaunchNotice, defaults: UserDefaults = .standard) {
        switch notice {
        case .moveToApplications: defaults.set(true, forKey: moveOfferedKey)
        case .oldFiles: defaults.set(true, forKey: oldFilesOfferedKey)
        }
    }
}

/// Where the app runs from, and Move to Applications (D4 5.15).
enum AppLocation {
    /// /Applications or ~/Applications (or a folder inside either).
    static func isInApplications(_ bundleURL: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let roots = ["/Applications/", home.appendingPathComponent("Applications").path + "/"]
        return roots.contains { path.hasPrefix($0) }
    }

    /// The copy to install: /Applications, or ~/Applications without admin rights.
    static func destination(isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) },
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if isWritable("/Applications") {
            return URL(fileURLWithPath: "/Applications/\(FirstLaunch.appName).app")
        }
        return home.appendingPathComponent("Applications/\(FirstLaunch.appName).app")
    }

    /// Offer the move only from outside Applications, and only when no copy is
    /// there already (the move never replaces another copy of the app).
    static func shouldOfferMove(bundleURL: URL, destination: URL = destination(),
                                destinationExists: (URL) -> Bool) -> Bool {
        !isInApplications(bundleURL) && !destinationExists(destination)
    }

    static func isTranslocated(_ bundleURL: URL) -> Bool {
        bundleURL.path.contains("/AppTranslocation/")
    }

    /// Copies this app into Applications with the updater's relauncher, which
    /// waits for this process to quit, installs the copy, clears the download
    /// quarantine and opens it. The copy that was opened is put in the Trash
    /// by the new copy once it runs (not when it was opened from a disk image
    /// or Downloads through App Translocation, whose real place isn't known).
    @MainActor
    static func moveToApplications(running bundleURL: URL = Bundle.main.bundleURL) throws {
        let target = destination()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(FirstLaunch.appName)-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("\(FirstLaunch.appName).app")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [bundleURL.path, staged.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw ServiceError("The app couldn't be copied into Applications. Drag it there in Finder instead.")
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? RobogearsCore.version
        try UpdateInstaller.launchRelauncher(appName: FirstLaunch.appName, stagedApp: staged, target: target,
                                             fromVersion: version, toVersion: version)
        if !isTranslocated(bundleURL) {
            UserDefaults.standard.set(bundleURL.path, forKey: FirstLaunch.movedFromKey)
        }
    }

    /// At launch from Applications after a Move: the copy that was opened
    /// goes to the Trash, but only if it is still there, isn't this copy, and
    /// carries this app's identifier. Returns a sentence for the log.
    @MainActor
    static func trashMovedOriginalIfNeeded(running bundleURL: URL = Bundle.main.bundleURL,
                                           defaults: UserDefaults = .standard) -> String? {
        guard let path = defaults.string(forKey: FirstLaunch.movedFromKey) else { return nil }
        guard isInApplications(bundleURL) else { return nil }
        defaults.removeObject(forKey: FirstLaunch.movedFromKey)
        let original = URL(fileURLWithPath: path)
        guard original.standardizedFileURL != bundleURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: original.path),
              Bundle(url: original)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return nil }
        do {
            try FileManager.default.trashItem(at: original, resultingItemURL: nil)
            return "Moved to Applications. The copy in \(Formatting.abbreviatedPath(original.deletingLastPathComponent().path)) is in the Trash."
        } catch {
            return "Moved to Applications. The copy in \(Formatting.abbreviatedPath(original.deletingLastPathComponent().path)) couldn't be moved to the Trash; you can delete it in Finder."
        }
    }
}
