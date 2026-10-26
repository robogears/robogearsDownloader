// The download folder's side of a download: which name a track takes,
// whether the song is already there, and the final move that never replaces
// a file.
//
// D4 area 2, option A throughout (the owner's choice of 21 Oct 2026), sets
// the behaviour; item numbers below refer to it.
//
// - Names (2.14, 2.6, 2.7): the plain name is "<Title>.flac" from TIDAL's
//   bare title. The Electron app's spellings of the same title count as
//   "already here" too. A name differing only in upper or lower case, or in
//   how accents are stored, counts as taken (`FileNaming.comparisonKey`).
// - Identity (2.6): an existing file is the same recording when it carries
//   the same ISRC, or, when either side has none, the same title (version
//   included, as the title tag carries it, 2.7) and a shared artist. A file
//   whose title and artist can't be read can't be told apart from the song,
//   so the row keeps it and offers Save As…, unless the file is broken in
//   itself (empty or cut off): then it is treated as a damaged copy, with
//   Replace (2.3).
// - The quick check (2.3) runs on any copy that would cause a skip: healthy
//   skips, damaged stays untouched until the person chooses Replace, which
//   moves it to the Trash.
// - A different song holding the plain name (2.6) sends the track to the
//   first free clash name: version, artist, album, then a number.
// - AAC and lossless (2.10): a FLAC of the same recording blocks either
//   kind; an .m4a blocks only another .m4a, or a not-yet-known download when
//   TIDAL has no lossless version. A new FLAC is saved next to an old .m4a.
// - Electron leftovers "….tmp.flac" / "….tmp.m4a" (2.2) are left alone and
//   never count as downloads: no name this app looks for ends that way,
//   except for a title that itself ends in ".tmp", where the file's tags
//   decide like any other file's. Nothing here deletes or moves them; D4
//   2.2 asks for exactly that, so there is no helper for them.
//
// Only `moveIntoPlace`, Replace's move to the Trash,
// `deleteDamagedCopyPermanently` and `removeLeftoverCopies` (the move's own
// hidden copies) write anything. The music library is never touched here:
// the download folder can't be inside it (2.11, checked by Settings and
// before each batch).
import Darwin
import Foundation

/// The decisions and the final move for one download folder. Make one per
/// batch, for the folder the batch started with (2.17); it refuses requests
/// for any other folder. Every decision lists the folder once and reads only
/// the files whose names this track may have. Safe to use from any thread:
/// it keeps no state between calls.
public struct DownloadFolder: DownloadFolderPlanning {
    public let folder: URL
    let tagReader: any TagReading
    let fileOperations: FileOperations
    private let resolvedPath: String
    /// The folder's path, to which names are added as plain text for every
    /// write. `URL.appendingPathComponent` and Foundation's file calls store
    /// "Café" decomposed ("e" plus an accent), while 2.14 keeps names
    /// composed, so the names this type writes never pass through a URL.
    private let folderPath: String

    public init(folder: URL) {
        self.init(folder: folder, tagReader: TagReader(), fileOperations: .system)
    }

    init(folder: URL, tagReader: any TagReading, fileOperations: FileOperations) {
        self.folder = folder
        self.tagReader = tagReader
        self.fileOperations = fileOperations
        resolvedPath = Self.resolvedPath(folder)
        folderPath = folder.path
    }

    /// The path of a name in the folder, spelled exactly as given.
    func path(of name: String) -> String {
        folderPath.hasSuffix("/") ? folderPath + name : folderPath + "/" + name
    }

    // MARK: - DownloadFolderPlanning

    public func decide(for request: TrackDownloadRequest,
                       fileExtension: FileNaming.AudioExtension?) async throws -> FolderDecision {
        try checkFolder(of: request)
        var context = Context(listing: try listing())
        return try await plan(request, want: fileExtension, context: &context, mayTrash: true, mustSave: false)
    }

    /// How many times the move looks for a new name when other files keep
    /// taking the planned one.
    static let maxMoveAttempts = 20

    public func moveIntoPlace(_ temporaryFile: URL, for request: TrackDownloadRequest, plannedName: String,
                              fileExtension: FileNaming.AudioExtension) async throws -> (fileName: String, notes: [SaveNote]) {
        try checkFolder(of: request)
        guard Self.isPlainName(plannedName), plannedName.lowercased().hasSuffix(".\(fileExtension.rawValue)") else {
            throw TrackDownloadError.writeFailed(detail: "“\(plannedName)” isn't a name the download folder can take")
        }
        var name = plannedName
        var notes: [SaveNote] = []
        // When the temporary file is on another disk, a hidden copy is made in
        // the folder first, then renamed like the original would have been.
        var hiddenCopy: String?
        do {
            for _ in 0..<Self.maxMoveAttempts {
                var context = Context(listing: try listing())
                if !context.listing.holders(of: name).isEmpty {
                    // Another file took the name since the decision (2.2):
                    // decide again, keeping this download whatever it finds.
                    guard case let .save(newName, newNotes) = try await plan(
                        request, want: fileExtension, context: &context, mayTrash: false, mustSave: true
                    ) else { throw TrackDownloadError.writeFailed(detail: "no free name") }
                    name = newName
                    notes = newNotes
                }
                switch try attemptMove(hiddenCopy ?? temporaryFile.path, to: path(of: name), source: temporaryFile) {
                case .moved:
                    if hiddenCopy != nil { try? FileManager.default.removeItem(at: temporaryFile) }
                    return (name, Self.notesEarned(byMovingTo: name, plannedName: plannedName, request: request,
                                                   fileExtension: fileExtension, replanNotes: notes))
                case .nameTaken:
                    continue
                case .otherDisk:
                    guard hiddenCopy == nil else { throw TrackDownloadError.writeFailed(detail: "the copy is on another disk") }
                    hiddenCopy = try copyIntoFolder(temporaryFile)
                }
            }
            throw TrackDownloadError.writeFailed(detail: "the name “\(plannedName)” kept being taken")
        } catch {
            if let hiddenCopy { unlink(hiddenCopy) }
            throw error
        }
    }

    /// The notes the move adds to the decision's own. Only the name can be
    /// new: a decision for the plain name had no "saved under another name"
    /// note, so moving elsewhere earns one; a decision for a clash name
    /// already carries it ("another song is already named Intro" still
    /// holds), so nothing is repeated. The decision's other notes (an .m4a
    /// next to it, 2.10) still apply as they were.
    static func notesEarned(byMovingTo name: String, plannedName: String, request: TrackDownloadRequest,
                            fileExtension: FileNaming.AudioExtension, replanNotes: [SaveNote]) -> [SaveNote] {
        guard name != plannedName else { return [] }
        let plain = FileNaming.fileName(title: request.title, extension: fileExtension)
        guard FileNaming.comparisonKey(plannedName) == FileNaming.comparisonKey(plain) else { return [] }
        return replanNotes.filter { if case .savedUnderAnotherName = $0 { true } else { false } }
    }

    // MARK: - Hidden copies from another disk

    /// The hidden copy the move makes when the temporary file is on another
    /// disk: ".robogears-copy-<32 hex digits>.part". Hidden, and never one of
    /// the names a track looks for, so it can't count as a download. Short
    /// whatever the title, so it always fits the 255-byte limit.
    static let hiddenCopyPrefix = ".robogears-copy-"
    static let hiddenCopySuffix = ".part"

    static func hiddenCopyName() -> String {
        hiddenCopyPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + hiddenCopySuffix
    }

    static func isHiddenCopyName(_ name: String) -> Bool {
        guard name.hasPrefix(hiddenCopyPrefix), name.hasSuffix(hiddenCopySuffix) else { return false }
        let id = name.dropFirst(hiddenCopyPrefix.count).dropLast(hiddenCopySuffix.count)
        return id.count == 32 && id.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }

    /// Deletes hidden copies a move left behind when the app stopped in the
    /// middle of one (a crash or a power cut; every failure the app sees
    /// cleans up at once). D4 2.2 deletes the app's own leftovers at the next
    /// launch: call this then, or before a batch, never during one. Only
    /// regular files with exactly the hidden-copy name are touched, so the
    /// person's files and the Electron app's "….tmp.flac" files stay (2.2).
    /// Returns how many were deleted.
    @discardableResult
    public func removeLeftoverCopies() -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where Self.isHiddenCopyName(name) {
            let url = folder.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if unlink(url.path) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: - The queue's badge (2.16)

    /// What the queue shows about a row and the download folder, worked out
    /// without TIDAL (2.16).
    public enum InFolderStatus: Sendable, Equatable {
        /// Nothing here for this row: it would be saved under its plain name.
        case notInFolder
        /// The quiet "In your download folder" badge: the batch skips the
        /// row. A damaged copy gets 2.3's row instead, with Show in Finder
        /// and Replace.
        case inFolder(fileName: String, looksDamaged: Bool)
        /// "A different song is already saved as Intro.flac": the batch will
        /// save this one as `plannedName` (2.6).
        case differentSongHoldsName(fileName: String, plannedName: String)
        /// A file whose title and artist can't be read holds the plain name;
        /// the row offers Save As… (2.6's fallback).
        case nameTakenByUnreadableFile(fileName: String)
    }

    /// The badge for one row: the same decision the batch makes before
    /// asking TIDAL anything, so a badged row really is skipped. Never moves
    /// anything to the Trash, even for a row whose Replace is pending.
    public func inFolderStatus(for request: TrackDownloadRequest) async throws -> InFolderStatus {
        try await inFolderStatuses(for: [request])[request.rowID] ?? .notInFolder
    }

    /// The badges for many rows from one listing of the folder, for the
    /// moment rows are added and before a batch (2.16).
    public func inFolderStatuses(for requests: [TrackDownloadRequest]) async throws -> [UUID: InFolderStatus] {
        for request in requests { try checkFolder(of: request) }
        let shared = try listing()
        var statuses: [UUID: InFolderStatus] = [:]
        for request in requests {
            var context = Context(listing: shared)
            let decision = try await plan(request, want: nil, context: &context, mayTrash: false, mustSave: false)
            statuses[request.rowID] = Self.status(for: decision)
        }
        return statuses
    }

    static func status(for decision: FolderDecision) -> InFolderStatus {
        switch decision {
        case .skip(.alreadyInFolder(let name)): return .inFolder(fileName: name, looksDamaged: false)
        case .skip(.existingLooksDamaged(let name)): return .inFolder(fileName: name, looksDamaged: true)
        case .skip(.nameTakenByUnreadableFile(let name)): return .nameTakenByUnreadableFile(fileName: name)
        case .skip(.saved): return .notInFolder
        case let .save(planned, notes):
            for case let .savedUnderAnotherName(taken) in notes {
                return .differentSongHoldsName(fileName: taken, plannedName: planned)
            }
            return .notInFolder
        }
    }

    // MARK: - Replace without a Trash (2.3)

    /// Deletes a damaged copy for good, after the person answered "Delete"
    /// to "This folder has no Trash. Delete … permanently and download it
    /// again?" (`TrackDownloadError.folderHasNoTrash`). Deletes only when the
    /// file is still there under exactly this name, is one of the names this
    /// track may have, carries this recording and still looks damaged;
    /// otherwise returns false and touches nothing.
    public func deleteDamagedCopyPermanently(named fileName: String, for request: TrackDownloadRequest) async throws -> Bool {
        try checkFolder(of: request)
        var context = Context(listing: try listing())
        guard context.listing.contains(exactly: fileName),
              let lookup = TrackNames(request).allLookups(in: context.listing)
                .first(where: { FileNaming.comparisonKey($0.name) == FileNaming.comparisonKey(fileName) })
        else { return false }
        guard await identity(of: fileName, as: lookup.ext, for: request, context: &context) == .sameRecording else {
            return false
        }
        let url = folder.appendingPathComponent(fileName)
        let verdict = await ExistingFileCheck.check(url, as: lookup.ext, tidalSeconds: request.durationSeconds.map(Double.init))
        guard !verdict.isHealthy else { return false }
        // The name exactly as listed: never a URL, which could spell it
        // differently on a disk that tells composed and decomposed apart.
        guard unlink(path(of: fileName)) == 0 else {
            let code = errno
            throw TrackDownloadError.writeFailed(detail: "Couldn't delete “\(fileName)”: \(String(cString: strerror(code)))")
        }
        return true
    }

    // MARK: - The decision

    /// One decision's working state: the folder's names as listed for it,
    /// and what each existing file turned out to be.
    struct Context {
        var listing: FolderListing
        var identities: [String: FolderIdentity.Verdict] = [:]
    }

    struct Copy: Equatable {
        var name: String
        var ext: FileNaming.AudioExtension
    }

    /// `mayTrash`: Replace may move a damaged copy to the Trash (false for
    /// the badge and the move). `mustSave`: the file is already downloaded
    /// and checked, so nothing skips; every existing file just holds its name.
    func plan(_ request: TrackDownloadRequest, want: FileNaming.AudioExtension?, context: inout Context,
              mayTrash: Bool, mustSave: Bool) async throws -> FolderDecision {
        let names = TrackNames(request)

        // 1. Every copy of this recording under a name this track may have.
        var sameCopies: [Copy] = []
        var looked: Set<String> = []
        for lookup in names.allLookups(in: context.listing) {
            for holder in context.listing.holders(of: lookup.name) where looked.insert(holder).inserted {
                if await identity(of: holder, as: lookup.ext, for: request, context: &context) == .sameRecording {
                    sameCopies.append(Copy(name: holder, ext: lookup.ext))
                }
            }
        }

        // 2. A copy that blocks this download: a FLAC always; an .m4a only
        //    when nothing better is coming (2.10). Healthy skips; damaged
        //    stays, unless the person chose Replace (2.3).
        if !mustSave {
            let blockers = sameCopies.filter { copy in
                switch copy.ext {
                case .flac: true
                case .m4a: want == .m4a || (want == nil && request.losslessOnTIDAL == false)
                }
            }
            if !blockers.isEmpty {
                var damaged: [Copy] = []
                let tidalSeconds = request.durationSeconds.map(Double.init)
                for copy in blockers {
                    let url = folder.appendingPathComponent(copy.name)
                    if await ExistingFileCheck.check(url, as: copy.ext, tidalSeconds: tidalSeconds).isHealthy {
                        return .skip(.alreadyInFolder(fileName: copy.name))
                    }
                    damaged.append(copy)
                }
                guard mayTrash, request.replaceExisting else {
                    return .skip(.existingLooksDamaged(fileName: damaged[0].name))
                }
                for copy in damaged {
                    try moveToTrash(copy.name)
                    context.listing.remove(copy.name)
                }
                sameCopies.removeAll { damaged.contains($0) }
            }
        }

        // 3. The name.
        let target = want ?? (request.losslessOnTIDAL == false ? .m4a : .flac)
        var notes: [SaveNote] = []
        if target == .flac, let aac = sameCopies.first(where: { $0.ext == .m4a }) {
            notes.append(.savedNextToAAC(aacName: aac.name))
        }
        let takenName: String
        switch await stemState(names.plainStem, target, request, &context) {
        case .free:
            return .save(fileName: "\(names.plainStem).\(target.rawValue)", notes: notes)
        case let .taken(holder, unreadable):
            if unreadable, !mustSave { return .skip(.nameTakenByUnreadableFile(fileName: holder)) }
            takenName = holder
        }
        notes.insert(.savedUnderAnotherName(takenName: takenName), at: 0)
        for stem in names.clashStems {
            if case .free = await stemState(stem, target, request, &context) {
                return .save(fileName: "\(stem).\(target.rawValue)", notes: notes)
            }
        }
        for number in 2...FileNaming.maxClashNumber {
            let stem = "\(names.numberedBase) \(number)"
            if case .free = await stemState(stem, target, request, &context) {
                return .save(fileName: "\(stem).\(target.rawValue)", notes: notes)
            }
        }
        throw TrackDownloadError.writeFailed(detail: "every name for “\(request.title)” is taken")
    }

    enum StemState {
        case free
        case taken(by: String, unreadable: Bool)
    }

    /// Names count by their stem: "Intro.m4a" held by a different song also
    /// keeps a FLAC out of "Intro.flac", so one stem never names two songs.
    /// "Intro.flac" next to "Intro.m4a" reads as one song in two qualities,
    /// which is exactly what 2.10 leaves behind and offers to tidy with Move
    /// to Trash, so the person could bin a song they wanted. A stem is free
    /// for this track when nothing holds the target name and anything under
    /// the other extension is this same recording.
    private func stemState(_ stem: String, _ target: FileNaming.AudioExtension, _ request: TrackDownloadRequest,
                           _ context: inout Context) async -> StemState {
        if let holder = context.listing.holders(of: "\(stem).\(target.rawValue)").first {
            let verdict = await identity(of: holder, as: target, for: request, context: &context)
            return .taken(by: holder, unreadable: verdict == .unreadable)
        }
        let other: FileNaming.AudioExtension = target == .flac ? .m4a : .flac
        for holder in context.listing.holders(of: "\(stem).\(other.rawValue)") {
            let verdict = await identity(of: holder, as: other, for: request, context: &context)
            if verdict != .sameRecording { return .taken(by: holder, unreadable: verdict == .unreadable) }
        }
        return .free
    }

    // MARK: - Identity

    /// What an existing file under one of this track's names is. Two cases
    /// go beyond comparing tags:
    /// - Something that isn't a regular file (a folder named "Intro.flac")
    ///   holds the name but is never a copy: it reads as unreadable.
    /// - A file whose tags can't be read and that fails the quick check on
    ///   its own (an empty or cut-off file a crash left, 2.2) is taken as a
    ///   broken copy of this song, so its row says "looks damaged" and offers
    ///   Replace (2.3) instead of Save As…, which would leave the broken file
    ///   blocking the name for good. Replace only moves it to the Trash.
    private func identity(of name: String, as ext: FileNaming.AudioExtension, for request: TrackDownloadRequest,
                          context: inout Context) async -> FolderIdentity.Verdict {
        if let known = context.identities[name] { return known }
        let url = folder.appendingPathComponent(name)
        var verdict = FolderIdentity.Verdict.unreadable
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if let tags = await readTags(url, as: ext) {
                verdict = FolderIdentity.compare(tags, with: request)
            }
            if verdict == .unreadable,
               !(await ExistingFileCheck.check(url, as: ext, tidalSeconds: nil)).isHealthy {
                verdict = .sameRecording
            }
        }
        context.identities[name] = verdict
        return verdict
    }

    /// The tags, read without loading the cover: FLAC with the package's
    /// own reader (it seeks past the picture), .m4a with Apple's.
    private func readTags(_ url: URL, as ext: FileNaming.AudioExtension) async -> AudioTags? {
        switch ext {
        case .flac:
            guard let summary = try? FLACMetadataReader.summary(of: url) else { return nil }
            let comment = summary.vorbisComment
            func values(_ key: String) -> [String] { comment?.values(for: key).filter { !$0.isEmpty } ?? [] }
            return AudioTags(title: values("TITLE").first, artists: values("ARTIST"),
                             durationSeconds: summary.streamInfo.duration, isrc: values("ISRC").first)
        case .m4a:
            return await tagReader.readTags(at: url)
        }
    }

    // MARK: - Writing

    private func moveToTrash(_ name: String) throws {
        let url = folder.appendingPathComponent(name)
        do {
            try fileOperations.trash(url)
        } catch {
            if Self.meansNoTrash(error) { throw TrackDownloadError.folderHasNoTrash(fileName: name) }
            throw TrackDownloadError.writeFailed(detail: "Couldn't move “\(name)” to the Trash: \(error.localizedDescription)")
        }
    }

    /// What macOS answers when a volume has no Trash (some network shares).
    /// Which of these it really sends needs a live check on such a share.
    static func meansNoTrash(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFeatureUnsupportedError { return true }
        if error.domain == NSPOSIXErrorDomain, [ENOTSUP, EOPNOTSUPP].contains(Int32(error.code)) { return true }
        return false
    }

    enum MoveResult {
        case moved
        case nameTaken
        case otherDisk
    }

    /// One attempt at the final move, never over an existing file:
    /// `renamex_np(…, RENAME_EXCL)`. A disk that can't do an exclusive rename
    /// gets the name reserved with an exclusive create and then a plain
    /// rename over that empty placeholder; only a crash in that instant
    /// could leave the empty file behind, which the next decision treats as a
    /// damaged copy (Replace, 2.3). `source` is the temporary file, for the
    /// size a full disk reports.
    private func attemptMove(_ from: String, to destination: String, source: URL) throws -> MoveResult {
        let code = fileOperations.renameExclusive(from, destination)
        switch code {
        case 0:
            return .moved
        case EEXIST, ENOTEMPTY:
            return .nameTaken
        case EXDEV:
            return .otherDisk
        case ENOTSUP, EOPNOTSUPP:
            let placeholder = open(destination, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard placeholder >= 0 else {
                let openError = errno
                if openError == EEXIST { return .nameTaken }
                throw failure(openError, source: source)
            }
            close(placeholder)
            guard rename(from, destination) == 0 else {
                let renameError = errno
                unlink(destination)
                if renameError == EXDEV { return .otherDisk }
                throw failure(renameError, source: source)
            }
            return .moved
        default:
            throw failure(code, source: source)
        }
    }

    /// A hidden copy of a file from another disk, made in the folder with an
    /// exclusive create, so the final step is still a rename within the
    /// folder. A hidden name never counts as a download. Removes its own
    /// partial copy when the copy fails. Returns the copy's path.
    private func copyIntoFolder(_ source: URL) throws -> String {
        for _ in 0..<5 {
            let hidden = path(of: Self.hiddenCopyName())
            let target = open(hidden, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if target < 0 {
                let openError = errno
                if openError == EEXIST { continue }
                throw failure(openError, source: source)
            }
            let input = open(source.path, O_RDONLY)
            guard input >= 0 else {
                let openError = errno
                close(target)
                unlink(hidden)
                throw failure(openError, source: source)
            }
            var copied = fcopyfile(input, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
            var copyError = copied ? 0 : errno
            if copied, fsync(target) != 0 {
                copied = false
                copyError = errno
            }
            close(input)
            if close(target) != 0, copied {
                copied = false
                copyError = errno
            }
            guard copied else {
                unlink(hidden)
                throw failure(copyError, source: source)
            }
            return hidden
        }
        throw TrackDownloadError.writeFailed(detail: "couldn't make a hidden copy in the download folder")
    }

    /// The error for a failed write, in the batch's terms: a full disk and a
    /// folder that can't be reached or written stop the batch (2.19, 2.20).
    private func failure(_ code: Int32, source: URL) -> TrackDownloadError {
        switch code {
        case ENOSPC, EDQUOT:
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity)
                .map(Int64.init) ?? 0
            return .diskFull(bytesNeeded: max(1, size - free))
        case EACCES, EPERM, EROFS:
            return .folderUnavailable(message: Self.cantSaveMessage(folder))
        case ENOENT, ENOTDIR:
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                return unavailable()
            }
            return .writeFailed(detail: "the temporary file is missing")
        default:
            return .writeFailed(detail: String(cString: strerror(code)))
        }
    }

    // MARK: - The folder

    private func listing() throws -> FolderListing {
        do {
            return FolderListing(names: try FileManager.default.contentsOfDirectory(atPath: folder.path))
        } catch {
            throw unavailable()
        }
    }

    /// Why the folder can't be used, in 2.19's words. The batch checks the
    /// remembered folder before each track (with its bookmark and disk name);
    /// this covers the folder vanishing in between. It never creates the
    /// folder (2.19).
    private func unavailable() -> TrackDownloadError {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folderUnavailable(message: Self.cantSaveMessage(folder))
        }
        if let volume = Folders.volumeRoot(of: folder.path), !fm.fileExists(atPath: volume) {
            return .folderUnavailable(message: Self.unavailableMessage(folder))
        }
        return .folderUnavailable(message: Self.missingMessage(folder))
    }

    /// A batch keeps the folder it started with (2.17), so a request for
    /// another folder is a mistake upstream, never a reason to write there.
    private func checkFolder(of request: TrackDownloadRequest) throws {
        guard Self.resolvedPath(request.folder) == resolvedPath else {
            throw TrackDownloadError.writeFailed(detail: "the track is for another download folder")
        }
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A single name inside the folder: no path separators, nothing hidden
    /// or relative, within the 255-byte limit.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/")
            && !name.unicodeScalars.contains("\u{0}") && FileNaming.storedBytes(name) <= FileNaming.maxNameBytes
    }

    // The same words as `Folders.message` for the download folder (2.19).
    static func unavailableMessage(_ folder: URL) -> String {
        "The download folder “\(folder.lastPathComponent)” isn't available. Connect its drive or choose another folder."
    }

    static func missingMessage(_ folder: URL) -> String {
        "The download folder “\(folder.lastPathComponent)” no longer exists. Create it again or choose another folder."
    }

    static func cantSaveMessage(_ folder: URL) -> String {
        "robogears Downloader can't save into the download folder “\(folder.lastPathComponent)”. Check its permissions or choose another folder."
    }
}

// MARK: - File operations

/// The two operations tests replace: the Trash (so no test touches the real
/// one) and the exclusive rename (to act out another disk, a disk without
/// exclusive renames, or a name taken at the last moment).
struct FileOperations: Sendable {
    var trash: @Sendable (URL) throws -> Void
    /// Renames the file at the first path to the second, never over an
    /// existing file. Returns 0, or the errno the rename failed with. Paths
    /// are plain text, so the composed name FileNaming made is the one
    /// stored (a URL would decompose it).
    var renameExclusive: @Sendable (_ from: String, _ to: String) -> Int32

    static let system = FileOperations(
        trash: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
        renameExclusive: { from, to in
            renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
        }
    )
}

// MARK: - The folder's names

/// The folder's file names, grouped by the key under which a disk may treat
/// two names as one (`FileNaming.comparisonKey`).
struct FolderListing: Sendable {
    private(set) var namesByKey: [String: [String]] = [:]

    init(names: [String]) {
        for name in names.sorted() { namesByKey[FileNaming.comparisonKey(name), default: []].append(name) }
    }

    /// Every existing name the given name would clash with.
    func holders(of name: String) -> [String] {
        namesByKey[FileNaming.comparisonKey(name)] ?? []
    }

    func contains(exactly name: String) -> Bool {
        holders(of: name).contains { Array($0.utf8) == Array(name.utf8) }
    }

    mutating func remove(_ name: String) {
        let key = FileNaming.comparisonKey(name)
        namesByKey[key]?.removeAll { $0 == name }
        if namesByKey[key]?.isEmpty == true { namesByKey[key] = nil }
    }
}

/// Every name one track may have in the folder.
struct TrackNames {
    struct Lookup: Equatable {
        var name: String
        var ext: FileNaming.AudioExtension
    }

    let plainStem: String
    let clashStems: [String]
    let numberedBase: String
    /// Today's names and the Electron app's spellings (2.14), then each
    /// clash name (2.6), each in .flac and .m4a.
    let fixedLookups: [Lookup]

    init(_ request: TrackDownloadRequest) {
        plainStem = FileNaming.stem(title: request.title)
        clashStems = FileNaming.clashStems(title: request.title, version: request.version,
                                           artist: request.artist, album: request.album)
        numberedBase = FileNaming.numberedClashBase(title: request.title, version: request.version,
                                                     artist: request.artist, album: request.album)
        var lookups: [Lookup] = []
        for name in FileNaming.existingFileCandidates(title: request.title) {
            for ext in FileNaming.AudioExtension.allCases where name.hasSuffix(".\(ext.rawValue)") {
                lookups.append(Lookup(name: name, ext: ext))
            }
        }
        for stem in clashStems {
            for ext in FileNaming.AudioExtension.allCases { lookups.append(Lookup(name: "\(stem).\(ext.rawValue)", ext: ext)) }
        }
        fixedLookups = lookups
    }

    /// The fixed names, then the numbered clash names present in the folder
    /// in number order, so a song saved as "Intro (Paper Harbour) 3.flac" is
    /// found even if number 2 was deleted since.
    func allLookups(in listing: FolderListing) -> [Lookup] {
        let prefix = FileNaming.comparisonKey("\(numberedBase) ")
        var numbered: [(number: Int, lookup: Lookup)] = []
        for key in listing.namesByKey.keys where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            for ext in FileNaming.AudioExtension.allCases where rest.hasSuffix(".\(ext.rawValue)") {
                let digits = rest.dropLast(ext.rawValue.count + 1)
                guard !digits.isEmpty, digits.first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let number = Int(digits),
                      (2...FileNaming.maxClashNumber).contains(number)
                else { continue }
                numbered.append((number, Lookup(name: "\(numberedBase) \(number).\(ext.rawValue)", ext: ext)))
            }
        }
        numbered.sort { ($0.number, $0.lookup.ext.rawValue) < ($1.number, $1.lookup.ext.rawValue) }
        return fixedLookups + numbered.map(\.lookup)
    }
}

// MARK: - Identity (2.6)

/// Whether an existing file holds the recording a track would save.
enum FolderIdentity {
    enum Verdict: Equatable {
        case sameRecording
        case differentSong
        /// Its title, or with a matching title its artist, can't be read.
        case unreadable
    }

    /// The ISRC decides when both sides carry one: it names one recording,
    /// and every FLAC this app or the Electron app saved has it (2.6, spike
    /// part b). Otherwise the title must agree, version included as the
    /// title tag carries it (2.7), and an artist must be shared, compared as
    /// whole names (D4 3.3). A file with the bare title stands for a named
    /// version only when the lengths agree within 3 seconds, as in the
    /// library check (D4 3.11): the old app wrote bare titles for every
    /// version.
    static func compare(_ tags: AudioTags, with request: TrackDownloadRequest) -> Verdict {
        if let fileCode = MatchRules.recordingCodeKey(tags.isrc), let wanted = MatchRules.recordingCodeKey(request.isrc) {
            return fileCode == wanted ? .sameRecording : .differentSong
        }
        guard let title = tags.title else { return .unreadable }
        let fileTitle = Normalizer.fullKey(title)
        guard !fileTitle.isEmpty else { return .unreadable }
        let shown = Normalizer.fullKey(EditionTitle.make(title: request.title, edition: request.version))
        let bare = Normalizer.fullKey(request.title)
        var titleAgrees = Normalizer.keysAgree(fileTitle, shown)
        if !titleAgrees, shown != bare, Normalizer.keysAgree(fileTitle, bare) {
            titleAgrees = MatchRules.lengthsClose(request.durationSeconds.map(Double.init), tags.durationSeconds)
        }
        guard titleAgrees else { return .differentSong }
        let fileArtists = tags.artists.reduce(into: Set<String>()) { keys, value in
            keys.formUnion(ArtistCredit.text(value).comparisonKeys)
        }
        let wantedArtists = ArtistCredit.text(request.artist).comparisonKeys
        guard !fileArtists.isEmpty, !wantedArtists.isEmpty else { return .unreadable }
        return fileArtists.isDisjoint(with: wantedArtists) ? .differentSong : .sameRecording
    }
}
