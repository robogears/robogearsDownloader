// Where a track lives while it downloads, and the list that makes sure
// nothing is left behind.
//
// Decision 4, item 2.2: each track is downloaded and tagged in macOS's
// temporary folder on the same disk as the download folder, so nothing
// half-done ever appears in the download folder, and the finished file
// moves in with one rename. "The app keeps a list of the temporary files it
// made and deletes them after a failure or cancel, and any leftovers at the
// next launch." The Electron app wrote "<Title>.tmp.flac" into the download
// folder itself and left it there when a download broke
// (download-pipeline.md bug 10).
import Foundation
import Synchronization

public final class TemporaryDownloads: Sendable {
    /// Why a temporary folder couldn't be made.
    public enum Failure: Error, Sendable, Equatable {
        /// macOS gave no temporary folder on the download folder's disk.
        /// Whether some disks refuse (exFAT, network shares) needs a live
        /// check (2.2).
        case noTemporaryFolder(detail: String)
        /// The list of temporary folders couldn't be saved, so a crash
        /// could leave this one behind unnoticed; nothing is downloaded.
        case listNotSaved(detail: String)
    }

    /// Written into every folder the app makes. A leftover is deleted only
    /// when it carries this file, so a damaged or edited list can never
    /// send the clean-up after anything the app didn't make.
    static let markerName = ".robogears-download"

    private let store: JSONFileStore<[String]>
    private let entries: Mutex<[String]>

    /// `registryFile` is where the list is kept (Application Support in
    /// the app, a temporary folder in tests). A list left by an earlier
    /// launch is read, so `sweepLeftovers()` can find its folders.
    public init(registryFile: URL) {
        store = JSONFileStore(file: registryFile, permissions: 0o600)
        switch store.load() {
        case let .loaded(paths): entries = Mutex(paths)
        case .missing, .unreadable: entries = Mutex([])
        }
    }

    /// The temporary folders listed and not yet removed.
    public var registered: [URL] {
        entries.withLock { $0.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    }

    /// A new, empty folder on the same disk as `folder`, listed before it
    /// is used. It is never inside `folder` (rule 2: downloads land flat,
    /// and nothing half-done may look like a download there).
    public func makeFolder(near folder: URL) throws(Failure) -> URL {
        let fm = FileManager.default
        let made: URL
        do {
            made = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        } catch {
            throw .noTemporaryFolder(detail: String(describing: error))
        }
        guard Folders.relationship(of: made, to: folder) == .other else {
            try? fm.removeItem(at: made)
            throw .noTemporaryFolder(detail: "macOS offered a temporary folder inside the download folder")
        }
        do {
            guard fm.createFile(atPath: made.appendingPathComponent(Self.markerName).path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try entries.withLock { list in
                var updated = list
                updated.append(made.path)
                try store.save(updated)
                list = updated
            }
        } catch {
            try? fm.removeItem(at: made)
            throw .listNotSaved(detail: String(describing: error))
        }
        return made
    }

    /// Deletes a folder this registry made, with everything in it, and
    /// takes it off the list once it is gone. If it can't be deleted it
    /// stays listed for the next launch's sweep.
    public func remove(_ folder: URL) {
        let path = folder.path
        guard entries.withLock({ $0.contains(path) }) else { return }
        try? FileManager.default.removeItem(at: folder)
        guard !FileManager.default.fileExists(atPath: path) else { return }
        entries.withLock { list in
            var updated = list
            updated.removeAll { $0 == path }
            // A list that can't be saved still forgets the folder for this
            // launch; the next sweep finds the path gone and drops it.
            try? store.save(updated)
            list = updated
        }
    }

    /// Deletes every listed folder still on disk, for the next launch after
    /// a crash or a forced quit. A listed path that is gone is dropped; one
    /// that exists without the app's marker is dropped without deleting it.
    /// Returns how many folders were deleted. Call it before any download
    /// starts.
    @discardableResult
    public func sweepLeftovers() -> Int {
        let fm = FileManager.default
        return entries.withLock { list in
            var kept: [String] = []
            var deleted = 0
            for path in list {
                guard fm.fileExists(atPath: path) else { continue }
                let marker = (path as NSString).appendingPathComponent(Self.markerName)
                guard fm.fileExists(atPath: marker) else { continue }
                if (try? fm.removeItem(atPath: path)) != nil, !fm.fileExists(atPath: path) {
                    deleted += 1
                } else {
                    kept.append(path)
                }
            }
            if kept != list {
                try? store.save(kept)
                list = kept
            }
            return deleted
        }
    }
}
