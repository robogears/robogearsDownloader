import Foundation

/// A folder the person chose (download folder or music library), remembered
/// by a bookmark so a rename or move on the same disk is followed, plus the
/// last path for display when the disk isn't there (decision 4, item 2.19).
public struct FolderReference: Codable, Equatable, Sendable {
    public var bookmark: Data
    public var lastKnownPath: String

    public init(url: URL) throws {
        bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeNameKey], relativeTo: nil)
        lastKnownPath = url.path
    }

    public var displayName: String { URL(fileURLWithPath: lastKnownPath).lastPathComponent }

    /// The disk's name, for messages like "… on Music SSD isn't available".
    public var volumeName: String? {
        let values = URL.resourceValues(forKeys: [.volumeNameKey], fromBookmarkData: bookmark)
        return values?.volumeName
    }
}

public enum FolderStatus: Equatable, Sendable {
    case available(URL)
    /// The disk it lives on isn't connected (or a network share isn't mounted).
    case unavailable(volumeName: String?)
    /// The disk is there but the folder is gone.
    case missing
    /// The folder was moved to the Trash: a bookmark would happily follow it
    /// there, so it counts as gone.
    case inTrash
    /// The folder exists but can't be written (download folder only).
    case notWritable(URL)
}

public enum Folders {
    /// Resolves a remembered folder without ever showing UI or mounting a
    /// disk (an unplugged network share must not trigger a login prompt).
    public static func status(of reference: FolderReference, requireWritable: Bool,
                              trashDirectories: [URL] = defaultTrashDirectories()) -> FolderStatus {
        var stale = false
        let resolved = try? URL(resolvingBookmarkData: reference.bookmark,
                                options: [.withoutUI, .withoutMounting],
                                relativeTo: nil, bookmarkDataIsStale: &stale)
        let fm = FileManager.default
        guard let url = resolved, fm.fileExists(atPath: url.path) else {
            // Bookmark couldn't resolve: decide whether the disk or the folder is missing.
            if let volume = volumeRoot(of: reference.lastKnownPath), !fm.fileExists(atPath: volume) {
                return .unavailable(volumeName: reference.volumeName)
            }
            return .missing
        }
        if isInside(url, anyOf: trashDirectories) { return .inTrash }
        if requireWritable, !fm.isWritableFile(atPath: url.path) { return .notWritable(url) }
        return .available(url)
    }

    /// The person's Trash folders: the home Trash and each mounted volume's.
    public static func defaultTrashDirectories() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let home = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            dirs.append(home)
        }
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            dirs.append(volume.appendingPathComponent(".Trashes", isDirectory: true))
        }
        return dirs
    }

    /// "/Volumes/Music SSD" for paths on an external disk; nil on the startup disk.
    static func volumeRoot(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }

    static func isInside(_ url: URL, anyOf folders: [URL]) -> Bool {
        folders.contains { folder in relationship(of: url, to: folder) != .other }
    }

    public enum Relationship: Equatable, Sendable { case same, inside, other }

    /// Whether `item` is the same folder as `folder` or inside it, by the
    /// file system's own identity rules (links, firmlinks, and each disk's
    /// case sensitivity), not by comparing path text.
    public static func relationship(of item: URL, to folder: URL) -> Relationship {
        var rel: FileManager.URLRelationship = .other
        guard (try? FileManager.default.getRelationship(&rel, ofDirectoryAt: folder, toItemAt: item)) != nil else {
            return .other
        }
        switch rel {
        case .same: return .same
        case .contains: return .inside
        default: return .other
        }
    }

    public enum DownloadFolderProblem: Equatable, Sendable {
        /// The download folder is the library or inside it: refused, because
        /// the app never writes to the library (decision 4, item 2.11).
        case insideLibrary
    }

    /// A library folder inside the download folder is fine (downloads land
    /// at the download folder's top level); the reverse is refused.
    public static func check(downloadFolder: URL, libraryFolder: URL?) -> DownloadFolderProblem? {
        guard let libraryFolder else { return nil }
        return relationship(of: downloadFolder, to: libraryFolder) == .other ? nil : .insideLibrary
    }

    /// The message for each status, in the app's voice: what's wrong and what to do.
    public static func message(for status: FolderStatus, reference: FolderReference, role: String) -> String? {
        let name = "“\(reference.displayName)”"
        switch status {
        case .available:
            return nil
        case .unavailable(let volume):
            if let volume { return "The \(role) \(name) on \(volume) isn't available. Connect the drive or choose another folder." }
            return "The \(role) \(name) isn't available. Connect its drive or choose another folder."
        case .missing:
            return "The \(role) \(name) no longer exists. Create it again or choose another folder."
        case .inTrash:
            return "The \(role) \(name) is in the Trash. Put it back or choose another folder."
        case .notWritable:
            return "robogears Downloader can't save into the \(role) \(name). Check its permissions or choose another folder."
        }
    }
}
