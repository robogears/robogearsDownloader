import Foundation

// TEMPORARY (see StandIn.swift): the previous version's files.

/// Stands in for RobogearsCore's `LegacyElectronFiles` until the lanes merge.
/// It looks (read-only) for the Electron app's known items by exact name, or
/// reports `sampleItems` when given (the snapshot harness), and it NEVER moves
/// or deletes anything: the Electron app may still be in use on this Mac, and
/// its files are the owner's. The real type moves them to the Trash.
struct StandInOldAppFiles: OldAppFilesProviding {
    /// The names `LegacyElectronFiles` knows, app files first (abridged: the
    /// real list also covers every Electron cache folder).
    static let knownNames = [
        "settings.json", "queue.json", "token.json", "pending-tracklist.json", "extension-token.txt",
        "chrome-extension", "Cache", "Code Cache", "GPUCache", "Cookies", "Local Storage", "Session Storage",
        "IndexedDB", "Preferences", "Local State",
    ]
    static let signInFileName = "token.json"

    /// ~/Library/Application Support/robogears Downloader, where the Electron
    /// app kept its files (`AppPaths.legacyElectronDirectory()` in the core).
    static var electronFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("robogears Downloader", isDirectory: true)
    }

    var folder: URL = Self.electronFolder
    /// Names to report as present instead of looking (snapshots and checks).
    var sampleItems: [String]?

    func presentItems() -> [URL] {
        if let sampleItems { return sampleItems.map { folder.appendingPathComponent($0) } }
        return Self.knownNames.map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var shouldOfferNotice: Bool { !presentItems().isEmpty }

    var hasOldSignIn: Bool { presentItems().contains { $0.lastPathComponent == Self.signInFileName } }

    /// Pretends: reports what the real type would move, moves nothing.
    @discardableResult func moveToTrash() throws -> [URL] { presentItems() }

    /// Pretends: the real type deletes token.json; this one leaves it.
    func deleteOldSignIn() throws {}
}
