import Darwin
import Foundation

/// One audio file in the music library, as the duplicate check knows it.
public struct LibraryFile: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date
    /// nil when the file couldn't be read, or is online-only and wasn't read.
    public var tags: AudioTags?
    /// A cloud placeholder (Dropbox, iCloud): its bytes aren't on this Mac,
    /// so reading it would download it (decision 4, item 3.8).
    public var onlineOnly: Bool

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// The saved library index: rebuilt incrementally, so a launch re-reads
/// only new or changed files (decision 4, item 3.7; the Electron app
/// re-read every file on every launch).
public struct LibraryIndexSnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var rootPath: String
    public var scannedAt: Date
    public var files: [LibraryFile]

    public var onlineOnlyCount: Int { files.filter(\.onlineOnly).count }
    public var unreadOnlineOnlyCount: Int { files.filter { $0.onlineOnly && $0.tags == nil }.count }
}

public struct LibraryScanOptions: Sendable {
    /// Read the tags of online-only files too (downloads them). Off until the
    /// person agrees, after being told how many files and roughly how much.
    public var readOnlineOnlyFiles = false
    public var concurrency = 8
    public init() {}
}

public enum LibraryScanner {
    /// The file types the library check reads. Today's eight, plus AIFF,
    /// which the Electron app skipped (decision 4, item 3.8).
    public static let audioExtensions: Set<String> = ["flac", "m4a", "mp3", "wav", "aac", "ogg", "opus", "alac", "aif", "aiff"]

    public struct Found: Sendable { public let url: URL; public let size: Int64; public let modified: Date; public let onlineOnly: Bool }

    /// Walks the folder. Skips hidden files (which includes the "._"
    /// AppleDouble copies that exFAT and network drives create), package
    /// contents and symbolic links, as decided in item 3.8.
    public static func walk(_ root: URL, isOnlineOnly: (URL) -> Bool = LibraryScanner.isDataless) throws -> [Found] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }   // an unreadable subfolder is skipped, not fatal
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        var found: [Found] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            found.append(Found(url: url, size: Int64(values.fileSize ?? 0),
                               modified: values.contentModificationDate ?? .distantPast,
                               onlineOnly: isOnlineOnly(url)))
        }
        return found.sorted { $0.url.path < $1.url.path }   // deterministic order, so "which file" never varies
    }

    /// True for a File Provider placeholder whose data isn't on disk
    /// (SF_DATALESS). Checking it doesn't download anything.
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0
    }

    /// Builds a fresh snapshot, reusing every entry of `previous` whose size
    /// and modification date are unchanged. Progress is reported about every
    /// 25 files and once at the end, as in the Electron app.
    public static func scan(root: URL, previous: LibraryIndexSnapshot?, options: LibraryScanOptions = LibraryScanOptions(),
                            reader: TagReading = TagReader(),
                            isOnlineOnly: @escaping @Sendable (URL) -> Bool = LibraryScanner.isDataless,
                            progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> LibraryIndexSnapshot {
        let found = try walk(root, isOnlineOnly: isOnlineOnly)
        let total = found.count
        progress(0, total)
        var known: [String: LibraryFile] = [:]
        if let previous, previous.rootPath == root.path {
            for file in previous.files { known[file.path] = file }
        }

        var results = [LibraryFile?](repeating: nil, count: total)
        var done = 0
        var lastReported = 0
        try await withThrowingTaskGroup(of: (Int, LibraryFile).self) { group in
            var next = 0
            func addTask() {
                guard next < total else { return }
                let index = next, item = found[next]
                next += 1
                let reuse = known[item.url.path].flatMap { old -> LibraryFile? in
                    guard old.size == item.size, old.modified == item.modified else { return nil }
                    // An online-only file read earlier keeps its tags; one that
                    // wasn't read is read now if the person has since agreed.
                    if old.tags == nil, item.onlineOnly, options.readOnlineOnlyFiles { return nil }
                    return LibraryFile(path: old.path, size: old.size, modified: old.modified, tags: old.tags, onlineOnly: item.onlineOnly)
                }
                group.addTask {
                    try Task.checkCancellation()
                    if let reuse { return (index, reuse) }
                    var tags: AudioTags?
                    if !item.onlineOnly || options.readOnlineOnlyFiles {
                        tags = await reader.readTags(at: item.url)
                    }
                    return (index, LibraryFile(path: item.url.path, size: item.size, modified: item.modified,
                                               tags: tags, onlineOnly: item.onlineOnly))
                }
            }
            for _ in 0..<max(1, options.concurrency) { addTask() }
            while let (index, file) = try await group.next() {
                results[index] = file
                done += 1
                if done - lastReported >= 25 || done == total {
                    lastReported = done
                    progress(done, total)
                }
                addTask()
            }
        }
        return LibraryIndexSnapshot(rootPath: root.path, scannedAt: Date(), files: results.compactMap { $0 })
    }
}

/// Owns the library index for the app: one scan at a time, and the newest
/// request always wins — changing or clearing the folder mid-scan can never
/// leave the old folder's results in place (decision 4, item 3.15).
public actor LibraryIndexService {
    public enum Status: Equatable, Sendable {
        case off
        case scanning(done: Int, total: Int)
        case ready(fileCount: Int)
        /// The folder isn't reachable; the last saved index is still used.
        case unavailable(lastScanned: Date?)
        case failed(String)
    }

    public private(set) var snapshot: LibraryIndexSnapshot? {
        didSet { matcherIndex = snapshot?.matcherIndex() }
    }
    /// Built once per snapshot, so checking a 500-row import doesn't
    /// normalise the whole library 500 times.
    public private(set) var matcherIndex: LibraryMatcher.Index?
    public private(set) var status: Status = .off
    private var generation = 0
    private var currentTask: Task<Void, Never>?
    private let store: JSONFileStore<LibraryIndexSnapshot>
    private let reader: TagReading
    private let isOnlineOnly: @Sendable (URL) -> Bool
    private var onChange: (@Sendable (Status) -> Void)?

    public init(cacheFile: URL, reader: TagReading = TagReader(),
                isOnlineOnly: @escaping @Sendable (URL) -> Bool = LibraryScanner.isDataless) {
        self.store = JSONFileStore(file: cacheFile)
        self.reader = reader
        self.isOnlineOnly = isOnlineOnly
        if case .loaded(let saved) = store.load() {
            snapshot = saved
            matcherIndex = saved.matcherIndex()   // didSet doesn't run in init
        }
    }

    /// The library check for one track: nil when the check is off, no index
    /// exists yet, or nothing matches.
    public func match(_ query: LibraryMatcher.Query) -> LibraryMatcher.Match? {
        matcherIndex?.match(query)
    }

    public func setOnChange(_ handler: @escaping @Sendable (Status) -> Void) { onChange = handler }

    /// Starts (or restarts) a scan of `folder`; nil turns the check off.
    public func scan(_ folder: URL?, options: LibraryScanOptions = LibraryScanOptions()) {
        generation += 1
        let mine = generation
        currentTask?.cancel()
        guard let folder else {
            snapshot = nil
            set(.off)
            return
        }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            // Keep the last index for the same folder rather than an empty one:
            // an empty index would let every owned song download again.
            if snapshot?.rootPath != folder.path { snapshot = nil }
            set(.unavailable(lastScanned: snapshot?.scannedAt))
            return
        }
        let previous = snapshot
        let reader = self.reader, isOnlineOnly = self.isOnlineOnly
        set(.scanning(done: 0, total: 0))
        currentTask = Task {
            do {
                let result = try await LibraryScanner.scan(root: folder, previous: previous, options: options, reader: reader,
                                                           isOnlineOnly: isOnlineOnly) { done, total in
                    Task { await self.progress(done, total, generation: mine) }
                }
                self.finish(result, generation: mine)
            } catch is CancellationError {
                // A newer request took over.
            } catch {
                self.fail(error, generation: mine)
            }
        }
    }

    /// Waits for the scan in flight, if any (for tests and for "Download
    /// holds rows until the library check is done", decision 4, item 4.20).
    public func waitForScan() async { await currentTask?.value }

    private func progress(_ done: Int, _ total: Int, generation: Int) {
        guard generation == self.generation, case .scanning = status else { return }
        set(.scanning(done: done, total: total))
    }

    private func finish(_ result: LibraryIndexSnapshot, generation: Int) {
        guard generation == self.generation else { return }
        snapshot = result
        try? store.save(result)
        set(.ready(fileCount: result.files.count))
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        set(.failed("The music library couldn't be read (\(error.localizedDescription)). Check the folder, then press Refresh."))
    }

    private func set(_ new: Status) {
        status = new
        onChange?(new)
    }
}
