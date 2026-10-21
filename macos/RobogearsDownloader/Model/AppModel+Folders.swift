import AppKit
import RobogearsCore

/// Folders, Finder and sign-in commands.
extension AppModel {
    static let exportifyURL = URL(string: "https://exportify.net")!
    static let helpURL = URL(string: "https://github.com/robogears/robogearsDownloader#readme")!

    // MARK: Folders

    /// Choose Folder… (empty state, summary notice, Settings).
    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDownloadFolder(url)
    }

    func setDownloadFolder(_ url: URL) {
        // The download folder can't be the library or inside it (D4 2.11).
        if let library = settings.libraryFolder,
           case .available(let libraryURL) = Folders.status(of: library, requireWritable: false),
           Folders.check(downloadFolder: url, libraryFolder: libraryURL) == .insideLibrary {
            refuse("The download folder can't be inside your music library. Choose another folder.")
            return
        }
        do {
            settings.downloadFolder = try FolderReference(url: url)
            saveSettingsNow()
            if summary?.outcome == .noFolder { summary = nil }
            let suffix = batch != nil ? " The running batch keeps saving to its folder; the change applies from the next batch." : ""
            activity.add(.notice, "Downloads go to \(Formatting.abbreviatedPath(url.path)).\(suffix)")
            checkDownloadFolder(for: rows)
        } catch {
            refuse("That folder can't be remembered (\(error.localizedDescription)). Choose another folder.")
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Music Library Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            settings.libraryFolder = try FolderReference(url: url)
            saveSettingsNow()
            activity.add(.library, "Music library set to \(Formatting.abbreviatedPath(url.path)). It's only ever read.")
            checkLibrary(for: rows)
        } catch {
            refuse("That folder can't be remembered (\(error.localizedDescription)). Choose another folder.")
        }
    }

    func clearLibraryFolder() {
        settings.libraryFolder = nil
        saveSettingsNow()
    }

    /// The folder the running batch saves to, else the chosen one (D4 2.17).
    var downloadFolderURL: URL? {
        if let batch { return batch.folder }
        guard let reference = settings.downloadFolder,
              case .available(let url) = Folders.status(of: reference, requireWritable: false) else { return nil }
        return url
    }

    var downloadFolderDisplayPath: String? {
        settings.downloadFolder.map { Formatting.abbreviatedPath($0.lastKnownPath) }
    }

    /// File › Open Download Folder (⇧⌘O), Open Folder in the notice.
    func openDownloadFolder() {
        if let url = downloadFolderURL {
            NSWorkspace.shared.open(url)
        } else if let reference = settings.downloadFolder {
            let status = Folders.status(of: reference, requireWritable: false)
            refuse(Folders.message(for: status, reference: reference, role: "download folder") ?? "The download folder isn't available.")
        } else {
            chooseDownloadFolder()
        }
    }

    // MARK: Finder

    func showInFinder(_ ids: [UUID]) {
        var urls: [URL] = []
        for id in ids {
            guard let row = row(id) else { continue }
            if let file = row.savedFile, FileManager.default.fileExists(atPath: file.path) {
                urls.append(file)
            } else if let folder = downloadFolderURL {
                let guess = folder.appendingPathComponent("\(row.item.title).flac")
                urls.append(FileManager.default.fileExists(atPath: guess.path) ? guess : folder)
            }
        }
        guard !urls.isEmpty else {
            refuse("The file isn't there any more. It may have been moved or the drive disconnected.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(Array(Set(urls)))
    }

    func showLibraryFiles(_ ids: [UUID]) {
        let urls = ids.compactMap { row($0)?.item.libraryMatch?.path }.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            refuse("The library file isn't available. Check the library drive is connected.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func openExportify() { NSWorkspace.shared.open(Self.exportifyURL) }
    func openHelp() { NSWorkspace.shared.open(Self.helpURL) }

    // MARK: Sign-in

    func showSignIn() {
        guard batch == nil, sheet == nil else { return }
        sheet = .signIn(resumeAdd: nil)
    }

    /// The sign-in sheet reports success here.
    func signInSucceeded(country: String?, resume: PendingAdd?) {
        signInState = .signedIn(country: country)
        activity.add(.notice, "Signed in to TIDAL.")
        announce("Signed in to TIDAL.")
        if let resume {
            // Let the sheet close first; then the add carries on (nothing downloads by itself).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                self.continueAfterSignIn(resume)
            }
        }
    }

    func signOut() {
        guard batch == nil else { return }
        Task {
            await services.signIn.signOut()
            signInState = .signedOut
            activity.add(.notice, "Signed out of TIDAL.")
        }
    }

    var canChangeSignIn: Bool { batch == nil }
}
