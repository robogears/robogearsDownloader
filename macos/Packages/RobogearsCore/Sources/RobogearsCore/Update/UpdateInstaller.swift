import Foundation

/// Download → verify → stage → swap for the self-updater (recipe §6–§8).
public enum UpdateInstallError: Error, Equatable, Sendable {
    case notEnoughSpace(neededMB: Int)
    case destinationNotWritable(String)
    case download(String)
    case checksumMismatch
    case badPackage(String)
    case stageMissing
    case tool(String)

    /// What the person reads: what went wrong and what to do.
    public var message: String {
        switch self {
        case .notEnoughSpace(let mb):
            return "There isn't enough free space for the update (about \(mb) MB needed). Free up some space, then try again."
        case .destinationNotWritable(let folder):
            return "robogears Downloader can't update itself because it can't change \(folder). Download the new version from the release page and drag it to Applications."
        case .download(let detail):
            return "The update didn't download (\(detail)). Try again."
        case .checksumMismatch:
            return "The downloaded update was damaged, so it wasn't installed. Try again."
        case .badPackage(let detail):
            return "The downloaded update isn't usable: \(detail) Try again later."
        case .stageMissing:
            return "The downloaded update was removed before it could be installed. Download it again."
        case .tool(let detail):
            return "The update couldn't be prepared (\(detail)). Try again."
        }
    }
}

public enum UpdateInstaller {
    // MARK: Destination and permission to self-install

    /// Where the new app goes. A quarantined copy opened from Downloads runs
    /// from a read-only App Translocation path, so it installs to
    /// /Applications instead (falling back to ~/Applications without admin).
    public static func installDestination(runningBundle: URL, appName: String,
                                          isWritable: (String) -> Bool,
                                          home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let translocated = runningBundle.path.contains("/AppTranslocation/")
        if !translocated, isWritable(runningBundle.deletingLastPathComponent().path) {
            return runningBundle
        }
        if isWritable("/Applications") {
            return URL(fileURLWithPath: "/Applications/\(appName).app")
        }
        return home.appendingPathComponent("Applications/\(appName).app")
    }

    /// Debug builds never self-install; the UI then opens the release page.
    public static func canSelfInstall(isDebugBuild: Bool, destination: URL, isWritable: (String) -> Bool) -> Bool {
        !isDebugBuild && isWritable(destination.deletingLastPathComponent().path)
    }

    // MARK: Preflight

    /// The flow can hold the download, the unpacked copy and the backup at
    /// once: about 2.5× the asset (recipe §6).
    public static func checkFreeSpace(assetSize: Int64, in directory: URL) throws {
        let needed = Int64(Double(max(assetSize, 50_000_000)) * 2.5)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free < needed {
            throw UpdateInstallError.notEnoughSpace(neededMB: Int(needed / 1_000_000))
        }
    }

    // MARK: Integrity

    /// Compares the download with its sidecar digest. Same-channel digests prove
    /// the file isn't corrupt or cut short; they can't prove who made it.
    public static func verify(file: URL, expectedSHA256: String?) throws {
        guard let expected = expectedSHA256 else { return }
        let actual = try UpdateAssets.sha256(of: file)
        guard actual == expected.lowercased() else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateInstallError.checksumMismatch
        }
    }

    // MARK: Stage

    /// Unpacks the zip with ditto (keeps the code seal intact) and checks the
    /// bundle is this app, not older than promised, and internally consistent.
    public static func unpackAndValidate(zip: URL, expectedVersion: String, appName: String,
                                         bundleIdentifier: String, stagingRoot: URL) throws -> URL {
        let fm = FileManager.default
        let dir = stagingRoot.appendingPathComponent("\(appName)-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? fm.removeItem(at: dir) } }

        try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        try? fm.removeItem(at: zip)

        let apps = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.lastPathComponent == "\(appName).app" }) else {
            throw UpdateInstallError.badPackage("it doesn't contain \(appName).")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleIdentifier"] as? String) == bundleIdentifier else {
            throw UpdateInstallError.badPackage("it is a different app.")
        }
        if let version = info?["CFBundleShortVersionString"] as? String,
           UpdateVersion.isNewer(expectedVersion, than: version) {
            throw UpdateInstallError.badPackage("it is older than the release it came from.")
        }
        // Integrity only for an ad-hoc app: catches a mangled extraction, not
        // a forged bundle. The relauncher re-signs ad hoc after the swap.
        try runTool("/usr/bin/codesign", ["--verify", "--deep", app.path])
        success = true
        return app
    }

    /// Deletes staging folders and scripts this app left in the temporary
    /// folder more than a day ago (a crash or quit mid-update).
    public static func sweepStaleStaging(in directory: URL, appName: String, olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items where item.lastPathComponent.hasPrefix("\(appName)-update-")
            || item.lastPathComponent.hasPrefix("\(appName)-relaunch-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: item) }
        }
    }

    // MARK: Swap

    /// The shared relauncher (recipe §7; identical in logic to the Electron
    /// one). argv: <old-pid> <staged-app> <target-app> — paths are never
    /// pasted into the script text. It waits for this app to exit (and
    /// reopens it if it never does), backs up, moves the new app in, re-signs
    /// ad hoc and verifies, and rolls back on any failure so the person is
    /// never left without an app.
    public static func relauncherScript(appName: String) -> String {
        """
        #!/bin/bash
        # \(appName) self-update relauncher. argv: <old-pid> <staged-app> <target-app>
        if [ "$1" != "--daemonized" ]; then
          nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 &
          disown
          exit 0
        fi
        shift
        PID="$1"; NEW_APP="$2"; TARGET="$3"
        LOGDIR="$HOME/Library/Logs/\(appName)"; mkdir -p "$LOGDIR"
        exec >>"$LOGDIR/update-$(date +%s).log" 2>&1
        set -x
        trap "" HUP TERM
        BACKUP="${TARGET}.bak"
        for i in $(seq 1 30); do ps -p "$PID" >/dev/null 2>&1 || break; sleep 1; done
        if ps -p "$PID" >/dev/null 2>&1; then
          echo "ERROR: old app never exited; aborting"
          open "$TARGET"; rm -f "$0"; exit 1
        fi
        xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true
        mkdir -p "$(dirname "$TARGET")"
        if [ -d "$TARGET" ]; then
          rm -rf "$BACKUP" 2>/dev/null
          if ! mv "$TARGET" "$BACKUP"; then
            echo "ERROR: backup failed; aborting"; open "$TARGET"; rm -f "$0"; exit 1
          fi
        fi
        if ! mv "$NEW_APP" "$TARGET"; then
          echo "ERROR: move-in failed, rolling back"
          [ -d "$BACKUP" ] && [ ! -d "$TARGET" ] && mv "$BACKUP" "$TARGET"
          [ -d "$TARGET" ] && open "$TARGET"
          rm -f "$0"; exit 1
        fi
        if codesign --force --deep --sign - "$TARGET" && codesign --verify --deep --strict "$TARGET"; then
          rm -rf "$BACKUP" 2>/dev/null
          open "$TARGET"
        else
          echo "ERROR: re-sign/verify failed, restoring backup"
          rm -rf "$TARGET" 2>/dev/null
          [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET"
          [ -d "$TARGET" ] && open "$TARGET"
        fi
        rm -f "$0"

        """
    }

    /// Writes the relauncher, records an attempt line (the only trace if the
    /// swap goes wrong after this process is gone), and starts it detached.
    /// The caller quits the app right after.
    public static func launchRelauncher(appName: String, stagedApp: URL, target: URL,
                                        fromVersion: String, toVersion: String,
                                        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                                        logsDirectory: URL? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagedApp.path) else { throw UpdateInstallError.stageMissing }
        let script = temporaryDirectory.appendingPathComponent("\(appName)-relaunch-\(UUID().uuidString).sh")
        try relauncherScript(appName: appName).write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let logs = logsDirectory ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(appName)")
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let line = "\(ISO8601DateFormatter().string(from: Date())) update \(fromVersion) -> \(toVersion) staged=\(stagedApp.path) target=\(target.path)\n"
        appendLine(line, to: logs.appendingPathComponent("attempts.log"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), stagedApp.path, target.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static func appendLine(_ line: String, to file: URL) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    /// Runs a system tool and throws with its output when it fails.
    static func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateInstallError.tool("\(URL(fileURLWithPath: path).lastPathComponent) failed: \(text.prefix(200))")
        }
    }
}
