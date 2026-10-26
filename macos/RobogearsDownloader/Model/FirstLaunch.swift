import AppKit
import RobogearsCore

/// The two first-launch questions (DESIGN_DIRECTION 4.11; D4 5.15, 5.11):
/// Move to Applications, then the previous version's files. One after the
/// other, each at most once, and only in release builds: a development build
/// must never offer to move itself or to tidy the files of the Electron app
/// still in use on this Mac.
enum FirstLaunch {
    static let moveOfferedKey = "FirstLaunch.MoveToApplicationsOffered"
    static let oldFilesOfferedKey = "FirstLaunch.OldFilesOffered"
    /// Where the copy that chose Move ran from, so the new copy can put it in
    /// the Trash once it runs from Applications.
    static let movedFromKey = "FirstLaunch.MovedFrom"
    static let appName = "robogears Downloader"

    /// The questions to ask at this launch, in order.
    @MainActor
    static func pendingNotices(defaults: UserDefaults = .standard, bundleURL: URL = Bundle.main.bundleURL,
                               supportDirectory: URL = AppPaths.supportDirectory()) -> [AlertRoute] {
        #if DEBUG
        return []
        #else
        var list: [AlertRoute] = []
        if !defaults.bool(forKey: moveOfferedKey),
           AppLocation.shouldOfferMove(bundleURL: bundleURL, destinationExists: { FileManager.default.fileExists(atPath: $0.path) }) {
            list.append(.moveToApplications)
        }
        // Another copy with our identity still running (the old app during a
        // switch-over) means its files are in use: ask another time.
        let othersRunning = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !defaults.bool(forKey: oldFilesOfferedKey), !othersRunning, OldAppFiles.hasOldApp(in: supportDirectory) {
            list.append(.oldFiles(folder: Formatting.abbreviatedPath(supportDirectory.path)))
        }
        return list
        #endif
    }

    /// Records that a question was shown, so it never comes back.
    static func markShown(_ route: AlertRoute, defaults: UserDefaults = .standard) {
        switch route {
        case .moveToApplications: defaults.set(true, forKey: moveOfferedKey)
        case .oldFiles: defaults.set(true, forKey: oldFilesOfferedKey)
        default: break
        }
    }
}

/// The previous (Electron) version's files in Application Support, found
/// and moved only by exact name (D4 5.11). The Swift app's own files have
/// other names (settings-v2.json, queue-v2.json, update-check.json) and are
/// never touched; update-cache.json is left alone on purpose.
enum OldAppFiles {
    /// The old app's own files: any one of them means the old app ran here.
    static let appFiles = ["settings.json", "queue.json", "token.json"]

    /// Everything the old app and its Electron shell left, by exact name.
    static let names: [String] = appFiles + [
        "pending-tracklist.json", "extension-token.txt", "chrome-extension",
        // Electron and Chromium's own data.
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "ShaderCache", "Local Storage", "Session Storage", "Shared Dictionary",
        "SharedStorage", "SharedStorage-wal", "blob_storage", "Crashpad", "Dictionaries", "IndexedDB",
        "WebStorage", "Service Worker", "Cookies", "Cookies-journal", "Network", "Network Persistent State",
        "Preferences", "TransportSecurity", "Trust Tokens", "Trust Tokens-journal", "DIPS", "DIPS-journal",
        "DIPS-wal", "Local State", "QuotaManager", "QuotaManager-journal", "databases", "VideoDecodeStats",
        "shared_proto_db", "Partitions", "MediaDeviceSalts", "MediaDeviceSalts-journal",
    ]

    /// The old files present in `folder`. The old sign-in counts only when it
    /// has the old app's shape (a JSON array), so a newer file that happens
    /// to share its name is never taken for it.
    static func found(in folder: URL, fileManager fm: FileManager = .default) -> [URL] {
        names.compactMap { name in
            let url = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { return nil }
            if name == "token.json", !isOldSignIn(url) { return nil }
            return url
        }
    }

    static func hasOldApp(in folder: URL) -> Bool {
        found(in: folder).contains { appFiles.contains($0.lastPathComponent) }
    }

    static func isOldSignIn(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [Any]
    }

    /// Moves each old file to the Trash (recoverable). Returns how many moved
    /// and the names that couldn't be moved.
    static func moveToTrash(_ urls: [URL], fileManager fm: FileManager = .default) -> (moved: Int, failed: [String]) {
        var moved = 0
        var failed: [String] = []
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        return (moved, failed)
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
