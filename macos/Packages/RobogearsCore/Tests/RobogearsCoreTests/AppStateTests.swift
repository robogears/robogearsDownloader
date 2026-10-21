import Foundation
import Testing
@testable import RobogearsCore

private func tempDir(_ label: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("appstate-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func row(_ title: String, state: QueueItem.DownloadState = .waiting, library: QueueItem.LibraryMatch? = nil) -> QueueItem {
    QueueItem(tidalID: Int64(abs(title.hashValue % 1_000_000)), title: title, artist: "Placeholder Artist",
              source: .tidal, libraryMatch: library, state: state)
}

// MARK: - Atomic JSON store

@Test func aDamagedFileIsKeptAsideNotOverwritten() throws {
    let dir = tempDir("damaged")
    let file = dir.appendingPathComponent("settings-v2.json")
    try Data("{ not json".utf8).write(to: file)
    let store = JSONFileStore<AppSettings>(file: file)
    guard case .unreadable(let kept?) = store.load() else { Issue.record("expected unreadable"); return }
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(try String(contentsOf: kept, encoding: .utf8) == "{ not json")
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func privateFilesAreSavedWithOwnerOnlyPermissions() throws {
    let file = tempDir("perm").appendingPathComponent("secret.json")
    try JSONFileStore<AppSettings>(file: file, permissions: 0o600).save(AppSettings())
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@Test func savingLeavesNoTemporaryFilesBehind() throws {
    let dir = tempDir("tmp")
    let store = JSONFileStore<AppSettings>(file: dir.appendingPathComponent("settings-v2.json"))
    try store.save(AppSettings())
    try store.save(AppSettings())
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == ["settings-v2.json"])
}

// MARK: - Settings

@Test func settingsStartBlankWithTheVolumeAtHalf() {
    let s = AppSettings()
    #expect(s.downloadFolder == nil)
    #expect(s.libraryFolder == nil)
    #expect(s.previewVolume == 0.5)
    #expect(s.previewGain == 0.25)
    #expect(s.playSoundEffects)
    #expect(!s.notifyWhenDownloadsFinish)
}

@Test func theVolumeComesBackAsTheSliderPositionNotItsSquare() throws {
    let file = tempDir("vol").appendingPathComponent("settings-v2.json")
    var s = AppSettings()
    s.previewVolume = 0.5
    try SettingsStore(file: file).save(s)
    #expect(SettingsStore(file: file).load().settings.previewVolume == 0.5)
}

@Test func resetFoldersKeepsTheVolumeAndSwitches() throws {
    var s = AppSettings()
    s.downloadFolder = try FolderReference(url: tempDir("reset"))
    s.previewVolume = 0.8
    s.playSoundEffects = false
    s.resetFolders()
    #expect(s.downloadFolder == nil)
    #expect(s.previewVolume == 0.8)
    #expect(!s.playSoundEffects)
}

@Test func settingsWithMissingKeysStillLoad() throws {
    let file = tempDir("partial").appendingPathComponent("settings-v2.json")
    try Data(#"{"previewVolume":0.3}"#.utf8).write(to: file)
    let s = SettingsStore(file: file).load().settings
    #expect(s.previewVolume == 0.3)
    #expect(s.playSoundEffects)
}

// MARK: - Queue

@Test func exactLibraryMatchesStartLeftOutAndSimilarOnesIncluded() {
    let exact = row("Blue Lantern", library: .init(kind: .exact, path: "/L/Blue Lantern.flac", libraryTitle: "Blue Lantern"))
    let similar = row("Paper Harbour", library: .init(kind: .similar, path: "/L/Paper Harbour (Live).flac", libraryTitle: "Paper Harbour (Live)"))
    #expect(!exact.included)
    #expect(similar.included)
    #expect(row("Copper Sky").included)
}

@Test func unfinishedRowsComeBackWaitingAndFailedRowsKeepTheirReason() async throws {
    let file = tempDir("queue").appendingPathComponent("queue-v2.json")
    let store = QueueStore(file: file, debounce: .milliseconds(1))
    let items = [
        row("Waiting Song"),
        row("Queued Song", state: .queued),
        row("Half Song", state: .downloading(percent: 60)),
        row("Broken Song", state: .failed(reason: "TIDAL is busy, try again later")),
    ]
    await store.save(items)
    await store.flush()
    guard case .loaded(let back) = await QueueStore(file: file).load() else { Issue.record("expected loaded"); return }
    #expect(back.map(\.title) == items.map(\.title))
    #expect(back[1].state == .waiting)
    #expect(back[2].state == .waiting)
    #expect(back[3].state == .failed(reason: "TIDAL is busy, try again later"))
}

@Test func quickChangesAreWrittenOnceAfterTheDebounce() async throws {
    let file = tempDir("debounce").appendingPathComponent("queue-v2.json")
    let store = QueueStore(file: file, debounce: .milliseconds(200))
    await store.save([row("One")])
    await store.save([row("One"), row("Two")])
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try await Task.sleep(for: .milliseconds(600))
    guard case .loaded(let back) = await QueueStore(file: file).load() else { Issue.record("expected loaded"); return }
    #expect(back.map(\.title) == ["One", "Two"])
}

@Test func onlyIncludedMatchedRowsAreDownloadable() {
    var leftOut = row("Left Out", library: .init(kind: .exact, path: "/L/x.flac", libraryTitle: "x"))
    #expect(!leftOut.isDownloadable)
    leftOut.included = true
    #expect(leftOut.isDownloadable)
    var missing = row("Missing")
    missing.match = .notOnTIDAL
    #expect(!missing.isDownloadable)
    #expect(row("Done", state: .done(quality: "24-bit / 96 kHz")).isDownloadable == false)
    #expect(row("Retry Me", state: .failed(reason: "x")).isDownloadable)
}

// MARK: - Folders

@Test func aDownloadFolderInsideTheLibraryIsRefused() throws {
    let library = tempDir("lib")
    let inside = library.appendingPathComponent("New Downloads")
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    #expect(Folders.check(downloadFolder: inside, libraryFolder: library) == .insideLibrary)
    #expect(Folders.check(downloadFolder: library, libraryFolder: library) == .insideLibrary)
}

@Test func aLibraryInsideTheDownloadFolderIsFine() throws {
    let downloads = tempDir("dl")
    let library = downloads.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    #expect(Folders.check(downloadFolder: downloads, libraryFolder: library) == nil)
    #expect(Folders.check(downloadFolder: downloads, libraryFolder: nil) == nil)
}

@Test func aRenamedFolderIsFollowed() throws {
    let parent = tempDir("rename")
    let original = parent.appendingPathComponent("TIDAL")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    let reference = try FolderReference(url: original)
    let renamed = parent.appendingPathComponent("TIDAL 2026")
    try FileManager.default.moveItem(at: original, to: renamed)
    guard case .available(let url) = Folders.status(of: reference, requireWritable: true, trashDirectories: []) else {
        Issue.record("expected the folder to be followed"); return
    }
    #expect(url.lastPathComponent == "TIDAL 2026")
}

@Test func aFolderMovedToTheTrashCountsAsGone() throws {
    let parent = tempDir("trash")
    let fakeTrash = parent.appendingPathComponent("Trash")
    let folder = parent.appendingPathComponent("Downloads")
    try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let reference = try FolderReference(url: folder)
    try FileManager.default.moveItem(at: folder, to: fakeTrash.appendingPathComponent("Downloads"))
    #expect(Folders.status(of: reference, requireWritable: true, trashDirectories: [fakeTrash]) == .inTrash)
}

@Test func aDeletedFolderIsMissing() throws {
    let folder = tempDir("deleted")
    let reference = try FolderReference(url: folder)
    try FileManager.default.removeItem(at: folder)
    #expect(Folders.status(of: reference, requireWritable: true, trashDirectories: []) == .missing)
}

@Test func aFolderOnAnUnpluggedDiskIsUnavailable() throws {
    // A bookmark that can't resolve, remembered under /Volumes/<disk>.
    var reference = try FolderReference(url: tempDir("gone"))
    try FileManager.default.removeItem(atPath: reference.lastKnownPath)
    reference.lastKnownPath = "/Volumes/Music SSD Not Mounted/TIDAL"
    if case .unavailable = Folders.status(of: reference, requireWritable: true, trashDirectories: []) {} else {
        Issue.record("expected unavailable")
    }
}

@Test func folderMessagesSayWhatToDo() throws {
    let reference = try FolderReference(url: tempDir("msg"))
    let message = Folders.message(for: .unavailable(volumeName: "Music SSD"), reference: reference, role: "download folder")
    #expect(message?.contains("isn't available. Connect the drive or choose another folder.") == true)
    #expect(Folders.message(for: .inTrash, reference: reference, role: "download folder")?.contains("is in the Trash") == true)
}
