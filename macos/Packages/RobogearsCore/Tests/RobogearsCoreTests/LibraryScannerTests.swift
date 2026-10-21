import Foundation
import Testing
@testable import RobogearsCore

private func fixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/library/\(name)")
}

/// Copies fixtures into `dir`. A leading "._" or "." in the target name makes
/// a copy of blue-lantern.flac under that name (hidden files aren't bundled).
private func copyFixtures(_ names: [String], into dir: URL) throws {
    for name in names {
        let source = name.hasPrefix(".") ? fixture("blue-lantern.flac") : fixture(name)
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))
    }
}

private func tempLibrary(_ label: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tag reading

@Test func flacTagsAndLengthAreRead() async throws {
    let tags = try #require(await TagReader().readTags(at: fixture("blue-lantern.flac")))
    #expect(tags.title == "Blue Lantern")
    #expect(tags.artists == ["Placeholder Artist"])
    #expect(tags.isrc == "QZXYZ2600001")
    #expect(abs((tags.durationSeconds ?? 0) - 1.0) < 0.01)
}

@Test func oggVorbisTagsAndLengthAreRead() async throws {
    let tags = try #require(await TagReader().readTags(at: fixture("paper-harbour.ogg")))
    #expect(tags.title == "Paper Harbour")
    #expect(tags.artists == ["Another Band"])
    #expect(tags.isrc == "QZXYZ2600002")
    #expect(abs((tags.durationSeconds ?? 0) - 1.0) < 0.05)
}

@Test func opusTagsAndLengthAreRead() async throws {
    let tags = try #require(await TagReader().readTags(at: fixture("copper-sky.opus")))
    #expect(tags.title == "Copper Sky")
    #expect(tags.artists == ["Placeholder Artist"])
    #expect(abs((tags.durationSeconds ?? 0) - 1.0) < 0.05)
}

@Test func mp3TagsIncludingTheISRCAreRead() async throws {
    let tags = try #require(await TagReader().readTags(at: fixture("late-ferry.mp3")))
    #expect(tags.title == "Late Ferry")
    #expect(tags.artists == ["Example Trio"])
    #expect(tags.isrc == "QZXYZ2600004")
    // MP3 frames carry encoder delay and padding, so a 1 s file reads a little
    // longer; the library check only cares about differences over 10 s.
    #expect(abs((tags.durationSeconds ?? 0) - 1.0) < 0.3)
}

@Test func m4aTagsAreRead() async throws {
    let tags = try #require(await TagReader().readTags(at: fixture("seven-lanterns.m4a")))
    #expect(tags.title == "Seven Lanterns")
    #expect(tags.artists == ["Example Trio"])
}

@Test func repeatedArtistCommentsAreAllKeptAndKeysIgnoreCase() {
    func entry(_ s: String) -> Data {
        var d = Data()
        var n = UInt32(s.utf8.count).littleEndian
        d.append(Data(bytes: &n, count: 4)); d.append(Data(s.utf8)); return d
    }
    var block = Data()
    var vendorLength = UInt32(4).littleEndian
    block.append(Data(bytes: &vendorLength, count: 4)); block.append(Data("test".utf8))
    var count = UInt32(4).littleEndian
    block.append(Data(bytes: &count, count: 4))
    for s in ["title=Blue Lantern", "ARTIST=Placeholder Artist", "Artist=Second Guest", "ISRC="] { block.append(entry(s)) }
    let tags = VorbisComments.tags(from: VorbisComments.parse(block), durationSeconds: nil)
    #expect(tags.title == "Blue Lantern")
    #expect(tags.artists == ["Placeholder Artist", "Second Guest"])
    #expect(tags.isrc == nil)   // an empty value counts as missing
}

@Test func aTruncatedCommentBlockDoesNotCrash() {
    #expect(VorbisComments.parse(Data([0xFF, 0xFF, 0xFF, 0x7F])).isEmpty)
    #expect(VorbisComments.parse(Data()).isEmpty)
}

@Test func aFileThatIsNotAudioReturnsNoTags() async throws {
    let dir = tempLibrary("notaudio")
    let fake = dir.appendingPathComponent("not-really.flac")
    try Data("hello".utf8).write(to: fake)
    #expect(await TagReader().readTags(at: fake) == nil)
}

// MARK: - Walking and scanning

@Test func hiddenAppleDoubleAndNonAudioFilesAreSkipped() throws {
    let dir = tempLibrary("walk")
    try copyFixtures(["blue-lantern.flac", "._blue-lantern.flac", ".hidden-copy.flac", "late-ferry.mp3"], into: dir)
    try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
    let sub = dir.appendingPathComponent("Sub Folder")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try copyFixtures(["copper-sky.opus"], into: sub)
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.flac"), withDestinationURL: dir.appendingPathComponent("blue-lantern.flac"))
    let names = try LibraryScanner.walk(dir, isOnlineOnly: { _ in false }).map { $0.url.lastPathComponent }
    #expect(names.sorted() == ["blue-lantern.flac", "copper-sky.opus", "late-ferry.mp3"])
}

@Test func aScanReadsEveryFileAndReportsFinalProgress() async throws {
    let dir = tempLibrary("scan")
    try copyFixtures(["blue-lantern.flac", "paper-harbour.ogg", "late-ferry.mp3"], into: dir)
    let ticks = ProgressLog()
    let snapshot = try await LibraryScanner.scan(root: dir, previous: nil, isOnlineOnly: { _ in false }) { done, total in ticks.add(done, total) }
    #expect(snapshot.files.count == 3)
    #expect(snapshot.files.allSatisfy { $0.tags?.title != nil })
    #expect(ticks.last?.0 == 3 && ticks.last?.1 == 3)
}

@Test func onlineOnlyFilesAreNotReadUntilAllowed() async throws {
    let dir = tempLibrary("cloud")
    try copyFixtures(["blue-lantern.flac", "late-ferry.mp3"], into: dir)
    let counter = CountingReader()
    let cloud: @Sendable (URL) -> Bool = { $0.lastPathComponent == "late-ferry.mp3" }
    let first = try await LibraryScanner.scan(root: dir, previous: nil, reader: counter, isOnlineOnly: cloud)
    #expect(counter.count == 1)
    #expect(first.unreadOnlineOnlyCount == 1)
    var allow = LibraryScanOptions()
    allow.readOnlineOnlyFiles = true
    let second = try await LibraryScanner.scan(root: dir, previous: first, options: allow, reader: counter, isOnlineOnly: cloud)
    #expect(counter.count == 2)   // only the online-only file is read now
    #expect(second.unreadOnlineOnlyCount == 0)
}

@Test func aRescanReadsOnlyNewOrChangedFiles() async throws {
    let dir = tempLibrary("incremental")
    try copyFixtures(["blue-lantern.flac", "late-ferry.mp3"], into: dir)
    let counter = CountingReader()
    let first = try await LibraryScanner.scan(root: dir, previous: nil, reader: counter, isOnlineOnly: { _ in false })
    #expect(counter.count == 2)
    try copyFixtures(["copper-sky.opus"], into: dir)
    let again = try await LibraryScanner.scan(root: dir, previous: first, reader: counter, isOnlineOnly: { _ in false })
    #expect(counter.count == 3)
    #expect(again.files.count == 3)
    try FileManager.default.removeItem(at: dir.appendingPathComponent("late-ferry.mp3"))
    let afterDelete = try await LibraryScanner.scan(root: dir, previous: again, reader: counter, isOnlineOnly: { _ in false })
    #expect(counter.count == 3)
    #expect(afterDelete.files.map(\.fileName).sorted() == ["blue-lantern.flac", "copper-sky.opus"])
}

// MARK: - The index service

@Test func theIndexIsSavedAndReloaded() async throws {
    let dir = tempLibrary("persist")
    try copyFixtures(["blue-lantern.flac"], into: dir)
    let cache = tempLibrary("cache").appendingPathComponent("library-index.json")
    let service = LibraryIndexService(cacheFile: cache, isOnlineOnly: { _ in false })
    await service.scan(dir)
    await service.waitForScan()
    #expect(await service.status == .ready(fileCount: 1))
    let reloaded = LibraryIndexService(cacheFile: cache, isOnlineOnly: { _ in false })
    #expect(await reloaded.snapshot?.files.first?.tags?.title == "Blue Lantern")
}

@Test func anUnreachableLibraryKeepsTheLastIndex() async throws {
    let dir = tempLibrary("unplug")
    try copyFixtures(["blue-lantern.flac"], into: dir)
    let cache = tempLibrary("cache2").appendingPathComponent("library-index.json")
    let service = LibraryIndexService(cacheFile: cache, isOnlineOnly: { _ in false })
    await service.scan(dir)
    await service.waitForScan()
    try FileManager.default.removeItem(at: dir)   // as if the drive were unplugged
    await service.scan(dir)
    guard case .unavailable(let last?) = await service.status else { Issue.record("expected unavailable with a date"); return }
    #expect(last <= Date())
    #expect(await service.snapshot?.files.count == 1)   // never an empty index that would re-download everything
}

@Test func theNewestScanRequestWins() async throws {
    let slow = tempLibrary("slow")
    try copyFixtures(["blue-lantern.flac", "late-ferry.mp3", "paper-harbour.ogg"], into: slow)
    let fast = tempLibrary("fast")
    try copyFixtures(["copper-sky.opus"], into: fast)
    let cache = tempLibrary("cache3").appendingPathComponent("library-index.json")
    let service = LibraryIndexService(cacheFile: cache, reader: SlowReader(), isOnlineOnly: { _ in false })
    await service.scan(slow)
    await service.scan(fast)          // the folder changed mid-scan
    await service.waitForScan()
    try await Task.sleep(for: .milliseconds(300))   // let a cancelled slow scan finish trying
    #expect(await service.snapshot?.rootPath == fast.path)
    #expect(await service.status == .ready(fileCount: 1))
}

@Test func clearingTheFolderTurnsTheCheckOff() async throws {
    let cache = tempLibrary("cache4").appendingPathComponent("library-index.json")
    let service = LibraryIndexService(cacheFile: cache, isOnlineOnly: { _ in false })
    await service.scan(nil)
    #expect(await service.status == .off)
    #expect(await service.snapshot == nil)
}

// MARK: - Helpers

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [(Int, Int)] = []
    func add(_ done: Int, _ total: Int) { lock.withLock { ticks.append((done, total)) } }
    var last: (Int, Int)? { lock.withLock { ticks.last } }
}

private final class CountingReader: TagReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func readTags(at url: URL) async -> AudioTags? {
        lock.withLock { reads += 1 }
        return AudioTags(title: url.deletingPathExtension().lastPathComponent)
    }
}

private struct SlowReader: TagReading {
    func readTags(at url: URL) async -> AudioTags? {
        try? await Task.sleep(for: .milliseconds(150))
        return AudioTags(title: url.lastPathComponent)
    }
}
