import Foundation

/// The checks before any batch starts, the same for Download All, a row's
/// Retry, Retry All and Retry Selected (2.18). In the Electron app only
/// Download All checked anything, and a refused retry stuck on
/// "Downloading…" (renderer-queue-and-flows.md 15c).
public enum BatchPreflight {
    public enum Verdict: Sendable, Equatable {
        /// Start the batch, saving into this folder for its whole run (2.17).
        case go(folder: URL)
        /// Being signed out is the only problem: show the sign-in sheet
        /// (1.1), not the honk. Nothing starts by itself afterwards.
        case signIn
        /// Refused, with the warning honk and a plain message.
        case blocked(Blocked)
    }

    public struct Blocked: Sendable, Equatable {
        public var message: String
        /// The button that fixes it, if one does.
        public var fix: DownloadBatch.Fix?
        /// Always the warning honk: "that action was refused" (2.8 B).
        public var sound: SoundEffect { .warningHonk }

        public init(message: String, fix: DownloadBatch.Fix? = nil) {
            self.message = message
            self.fix = fix
        }
    }

    /// Room the startup disk needs for the queue to be saved after each
    /// track (2.20). A 500-row queue is well under 1 MB; the rest is margin.
    public static let queueSaveReserveBytes: Int64 = 20_000_000

    /// Runs every check, in the order a person would fix them: something to
    /// download, a download folder that is there and outside the library,
    /// room to save the queue, then the TIDAL sign-in.
    ///
    /// - Parameters:
    ///   - trackCount: rows the batch would download.
    ///   - signIn: the token keeper's state. Being offline never reads as
    ///     signed out: the keeper reports from what is stored (1.1).
    ///   - startupDiskFreeBytes: free space where the queue is saved; nil
    ///     when unknown, which doesn't block.
    public static func check(trackCount: Int,
                             downloadFolder: FolderReference?,
                             libraryFolder: FolderReference?,
                             signIn: TokenKeeper.State,
                             startupDiskFreeBytes: Int64?,
                             trashDirectories: [URL] = Folders.defaultTrashDirectories()) -> Verdict {
        guard trackCount > 0 else {
            return .blocked(Blocked(message: "Nothing in the queue can be downloaded."))
        }
        guard let downloadFolder else {
            return .blocked(Blocked(message: "Choose a download folder to start downloading.", fix: .chooseFolder))
        }
        let status = Folders.status(of: downloadFolder, requireWritable: true, trashDirectories: trashDirectories)
        guard case let .available(folder) = status else {
            let message = Folders.message(for: status, reference: downloadFolder, role: "download folder")
                ?? "The download folder isn't available. Choose another folder."
            return .blocked(Blocked(message: message, fix: .chooseFolder))
        }
        // Checked again at every start, since folders can be moved in Finder (2.11).
        if let libraryFolder,
           case let .available(library) = Folders.status(of: libraryFolder, requireWritable: false,
                                                         trashDirectories: trashDirectories),
           Folders.check(downloadFolder: folder, libraryFolder: library) == .insideLibrary {
            return .blocked(Blocked(
                message: "Your download folder “\(downloadFolder.displayName)” is inside your music library. The app never writes to your library, so choose a download folder outside it.",
                fix: .chooseFolder))
        }
        if let free = startupDiskFreeBytes, free < queueSaveReserveBytes {
            return .blocked(Blocked(message: "Your Mac's startup disk is full, so the queue can't be saved during downloads. Free up some space, then try again."))
        }
        switch signIn {
        case .signedIn:
            return .go(folder: folder)
        case .signedOut, .invalid:
            return .signIn
        case let .unreadable(error):
            return .blocked(Blocked(message: error.description))
        case .notLoaded:
            return .blocked(Blocked(message: "Your TIDAL sign-in is still being read. Try again in a moment."))
        }
    }

    /// Free space on the disk holding `url`, by macOS's measure for
    /// important files (it counts space the system can purge). Nil when
    /// it can't be read. Pass the folder the queue is saved in.
    public static func freeBytes(onVolumeOf url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
