import Foundation

/// The Electron app's files, for the first-launch notice (D4 5.11): "This
/// is the new Mac app. Your old queue, folders and TIDAL sign-in weren't
/// carried over." with Show Old Files, Move Old Files to Trash and Delete
/// Old Sign-in. Nothing here runs without the person's click, and only
/// items known by exact name are ever touched; anything else in the folder
/// (the unexplained update-cache.json among them) is left alone.
public struct LegacyElectronFiles: Sendable {
    /// What the Electron app itself wrote (electron-main.js:20–28, 991;
    /// chrome-extension-removal.md: the extension's token and managed folder).
    public static let appItemNames: [String] = [
        "settings.json", "queue.json", "token.json", "pending-tracklist.json",
        "extension-token.txt", "chrome-extension",
    ]
    /// What Electron's browser engine keeps in every app's data folder:
    /// caches, cookies, local storage and the old headless Spotify window's
    /// persistent partition.
    public static let engineItemNames: [String] = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "Cookies", "Cookies-journal", "Local Storage", "Session Storage", "IndexedDB", "WebStorage",
        "Service Worker", "Shared Dictionary", "SharedStorage", "SharedStorage-wal", "blob_storage",
        "Network Persistent State", "Preferences", "TransportSecurity", "Trust Tokens",
        "Trust Tokens-journal", "Crashpad", "Partitions", "Dictionaries", "databases",
        "QuotaManager", "QuotaManager-journal", "Local State",
    ]
    public static let signInFileName = "token.json"

    public let folder: URL
    private let trash: @Sendable (URL) throws -> Void

    /// `trash` moves one item to the Trash; tests pass a stand-in so they
    /// never touch the real Trash.
    public init(folder: URL = AppPaths.legacyElectronDirectory(),
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.folder = folder
        self.trash = trash
    }

    /// The known old items that are actually there, app files first.
    public func presentItems() -> [URL] {
        (Self.appItemNames + Self.engineItemNames)
            .map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Show the notice only when there's something of the old app's to
    /// talk about.
    public var shouldOfferNotice: Bool { !presentItems().isEmpty }

    public var hasOldSignIn: Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.signInFileName).path)
    }

    /// Move Old Files to Trash: every known item, recoverable. Returns what
    /// moved. Stops at the first failure and reports it, so the notice can
    /// say what's left; items already moved stay in the Trash.
    @discardableResult
    public func moveToTrash() throws -> [URL] {
        var moved: [URL] = []
        for item in presentItems() {
            try trash(item)
            moved.append(item)
        }
        return moved
    }

    /// Delete Old Sign-in: removes token.json for good, because in the Trash
    /// it would stay readable until the Trash is emptied. Signing in again
    /// is all it costs. Does nothing when the file isn't there.
    public func deleteOldSignIn() throws {
        let file = folder.appendingPathComponent(Self.signInFileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}
