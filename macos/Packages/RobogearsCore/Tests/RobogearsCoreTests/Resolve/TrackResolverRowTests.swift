import Foundation
import Synchronization
import Testing
@testable import RobogearsCore

/// Search, Match Again, library marks and the words an add ends with
/// (D4 4.10, 4.11, 4.20, 4.2, 4.9).
@Suite("Resolver: rows, search and library marks")
struct TrackResolverRowTests {
    private static let rowID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!

    private static func exact(_ title: String) -> QueueItem.LibraryMatch {
        .init(kind: .exact, path: "/Music/Library/\(title).flac", libraryTitle: title)
    }

    // MARK: Search (D4 4.11, 4.1)

    @Test func searchResultsCarryTheQueuesLibraryMarksAndInQueue() async throws {
        let library = ResolveFakeLibrary(marks: ["Blue Lantern": Self.exact("Blue Lantern")])
        let harness = ResolveHarness(library: library)
        harness.backend.search("Blue Lantern", [
            ResolveJSON.track(900500001, "Blue Lantern", artists: ["Placeholder Artist"]),
            ResolveJSON.track(900500002, "Blue Lanterns", artists: ["Placeholder Artist"], version: "Radio Edit", explicit: true),
        ])
        let queued = QueueItem(tidalID: 900500002, title: "Blue Lanterns", artist: "Placeholder Artist", source: .search)
        let results = try await harness.resolver.search("  Blue Lantern ", queue: QueueContents([queued]))
        #expect(results.query == "Blue Lantern")
        #expect(results.hits.map(\.id) == [900500001, 900500002])
        // An exact library match arrives greyed with + Add, as in the queue (rule 4).
        #expect(results.hits[0].item.libraryMatch == Self.exact("Blue Lantern"))
        #expect(!results.hits[0].item.included)
        #expect(!results.hits[0].inQueue)
        #expect(results.hits[1].item.libraryMatch == nil)
        #expect(results.hits[1].inQueue)
        #expect(results.hits[1].item.version == "Radio Edit")
        #expect(results.hits[1].item.explicit)
        #expect(results.hits.allSatisfy { $0.item.source == .search })
        #expect(results.emptyMessage == nil)
        #expect(harness.tidalRequests == ["/v1/search/tracks?query=Blue%20Lantern&limit=10&countryCode=GB"])
    }

    @Test func aNumberSearchesAndAnEmptyAnswerPointsAtPastingTheLink() async throws {
        let harness = ResolveHarness()
        let results = try await harness.resolver.search("2041")
        #expect(results.hits.isEmpty)
        #expect(results.emptyMessage == "No TIDAL results for “2041”. Check the spelling or try fewer words. "
            + "Looking for a TIDAL track or playlist by its ID? Paste its link instead.")
        #expect(harness.tidalRequests == ["/v1/search/tracks?query=2041&limit=10&countryCode=GB"])
    }

    @Test func searchRefusesAnUnusableLinkWithoutSearchingIt() async {
        let harness = ResolveHarness()
        await #expect(throws: ResolveFailure(kind: .unsupportedLink,
                                              message: "SoundCloud links aren't supported. Paste a TIDAL or Spotify link, or type the song's name.")) {
            try await harness.resolver.search("https://soundcloud.com/placeholder/blue-lantern")
        }
        #expect(harness.server.requests.isEmpty)
    }

    @Test func searchWithNoConnectionSaysSo() async {
        let harness = ResolveHarness()
        harness.backend.intercept { _, _ in .failure(.notConnectedToInternet) }
        await #expect(throws: ResolveFailure(kind: .offline, message: "No internet connection. Check your connection, then click Try Again.")) {
            try await harness.resolver.search("Blue Lantern")
        }
    }

    @Test func aSignedOutSearchAsksForSignInInWordsAboutSearching() async {
        let harness = ResolveHarness(credential: nil)
        await #expect(throws: ResolveFailure(kind: .signInNeeded, message: "Sign in to TIDAL to search.")) {
            try await harness.resolver.search("Blue Lantern")
        }
        let row = QueueItem(tidalID: nil, title: "Blue Lantern", artist: "Placeholder Artist", source: .importList, match: .notOnTIDAL)
        await #expect(throws: ResolveFailure(kind: .signInNeeded, message: "Sign in to TIDAL to search.")) {
            try await harness.resolver.search(forRow: row)
        }
        #expect(harness.server.requests.isEmpty)
    }

    // MARK: Fixing a row (D4 4.10, 1.4)

    @Test func matchAgainReplacesANotFoundRowInPlace() async {
        let harness = ResolveHarness()
        harness.backend.search("Glass Orchard Northbound Choir", [
            ResolveJSON.track(900400001, "Glass Orchard", artists: ["Northbound Choir"], duration: 233, hiRes: true),
        ])
        let row = QueueItem(id: Self.rowID, tidalID: nil, title: "Glass Orchard", artist: "Northbound Choir",
                            source: .importList, match: .notOnTIDAL)
        let replaced = await harness.resolver.matchAgain(row)
        #expect(replaced.id == Self.rowID)
        #expect(replaced.tidalID == 900400001)
        #expect(replaced.match == .matched)
        #expect(replaced.source == .importList)
        #expect(replaced.hiRes)
        #expect(replaced.durationSeconds == 233)
        #expect(replaced.isDownloadable)
    }

    @Test func matchAgainOnACouldntCheckSpotifyRowKeepsSpotifysWords() async {
        let harness = ResolveHarness()
        harness.backend.search("Paper Harbour Northbound Choir", [
            ResolveJSON.track(900400002, "Paper Harbour", artists: ["Northbound Choir", "Second Guest"]),
        ])
        let row = QueueItem(id: Self.rowID, tidalID: nil, title: "Paper Harbour", artist: "Northbound Choir", durationSeconds: 210,
                            source: .spotify, match: .couldNotCheck(reason: "Couldn't check: TIDAL was busy"))
        let replaced = await harness.resolver.matchAgain(row)
        #expect(replaced.id == Self.rowID)
        #expect(replaced.tidalID == 900400002)
        #expect(replaced.artist == "Northbound Choir, Second Guest")
        #expect(replaced.originalTitle == "Paper Harbour")
        #expect(replaced.originalArtist == "Northbound Choir")
        // Spotify's length stays beside TIDAL's (D4 4.14).
        #expect(replaced.originalDurationSeconds == 210)
    }

    @Test func matchAgainLeavesMatchedRowsAloneAndSaysWhyItCouldntCheck() async {
        let harness = ResolveHarness()
        let matched = QueueItem(id: Self.rowID, tidalID: 900400003, title: "Copper Sky", artist: "Late Ferry Band", source: .tidal)
        #expect(await harness.resolver.matchAgain(matched) == matched)
        #expect(harness.server.requests.isEmpty)

        harness.backend.intercept { _, _ in .failure(.notConnectedToInternet) }
        let missing = QueueItem(id: Self.rowID, tidalID: nil, title: "Copper Sky", artist: "Late Ferry Band",
                                source: .importList, match: .notOnTIDAL)
        let offline = await harness.resolver.matchAgain(missing)
        #expect(offline.id == Self.rowID)
        #expect(offline.match == .couldNotCheck(reason: "Couldn't check: no internet connection"))
    }

    @Test func searchOnARowUsesItsOwnWordsAndThePickReplacesItInPlace() async throws {
        let library = ResolveFakeLibrary(marks: ["Glass Orchard": Self.exact("Glass Orchard")])
        let harness = ResolveHarness(library: library)
        harness.backend.search("Glass Orchard Northbound Choir", [
            ResolveJSON.track(900400004, "Glass Orchard", artists: ["Northbound Choir Ensemble"]),
        ])
        let row = QueueItem(id: Self.rowID, tidalID: nil, title: "Glass Orchard", artist: "Northbound Choir",
                            durationSeconds: 233, source: .spotify, match: .notOnTIDAL)
        #expect(harness.resolver.searchQuery(for: row) == "Glass Orchard Northbound Choir")
        let results = try await harness.resolver.search(forRow: row)
        let pick = try #require(results.hits.first)
        let replaced = harness.resolver.replace(row, with: pick)
        #expect(replaced.id == Self.rowID)
        #expect(replaced.tidalID == 900400004)
        #expect(replaced.source == .spotify)
        #expect(replaced.originalArtist == "Northbound Choir")
        #expect(replaced.originalDurationSeconds == 233)
        // The library check still applies to the pick (rule 4).
        #expect(replaced.libraryMatch?.kind == .exact)
        #expect(!replaced.included)
    }

    /// `withID` rebuilds the row field by field (`id` is a `let`). Every
    /// optional field is set here, so a field added to QueueItem later starts
    /// nil and fails this test until it is set here and copied in `withID`;
    /// otherwise Match Again and Search… would quietly drop it.
    @Test func aRowUnderANewIDKeepsEveryOtherField() {
        var row = QueueItem(
            id: UUID(), tidalID: 900400009, title: "Blue Lantern", version: "Radio Edit", artist: "Placeholder Artist",
            album: "Glass Orchard", durationSeconds: 201, isrc: "ZZRES2600009", hiRes: true, explicit: true,
            source: .spotify, originalTitle: "Blue Lantern - Radio Edit", originalArtist: "Placeholder Artists",
            match: .differentArtist(tidalArtist: "Placeholder Artist"),
            libraryMatch: .init(kind: .similar, path: "/Music/Library/Blue Lantern.flac", libraryTitle: "Blue Lantern"),
            included: false, state: .failed(reason: "TIDAL is busy")
        )
        row.originalDurationSeconds = 245
        row.libraryCheckPending = true
        row.losslessOnTIDAL = true
        row.lastOutcome = .alreadyInFolder(fileName: "Blue Lantern.flac")

        let fields = Array(Mirror(reflecting: row).children)
        let unset = fields.filter { field in
            let value = Mirror(reflecting: field.value)
            return value.displayStyle == .optional && value.children.isEmpty
        }.compactMap(\.label)
        #expect(unset.isEmpty, "Set \(unset) in this test and copy it in QueueItem.withID")

        let copy = row.withID(Self.rowID)
        #expect(copy.id == Self.rowID)
        let copied = Array(Mirror(reflecting: copy).children)
        #expect(copied.count == fields.count)
        for (field, kept) in zip(fields, copied) where field.label != "id" {
            #expect(String(describing: kept.value) == String(describing: field.value), "withID dropped \(field.label ?? "a field")")
        }
    }

    // MARK: Checking library (D4 4.20)

    @Test func rowsAddedBeforeTheLibraryIsReadAreMarkedCheckingAndFilledInLater() async {
        let library = ResolveFakeLibrary(ready: false, marks: ["Blue Lantern": Self.exact("Blue Lantern")])
        let harness = ResolveHarness(library: library)
        harness.backend.setUp {
            $0.tracks[900100001] = ResolveJSON.data(ResolveJSON.track(900100001, "Blue Lantern", artists: ["Placeholder Artist"]))
            $0.tracks[900100002] = ResolveJSON.data(ResolveJSON.track(900100002, "Copper Sky", artists: ["Late Ferry Band"]))
        }
        let first = await harness.run(.link("https://tidal.com/browse/track/900100001")).rows
        let second = await harness.run(.link("https://tidal.com/browse/track/900100002")).rows
        var rows = first + second
        #expect(rows.allSatisfy { $0.isLibraryCheckPending })
        #expect(rows.allSatisfy { $0.libraryMatch == nil && $0.included })

        // Left out by the person while the check ran: that choice stands.
        rows[1].included = false
        let settled = QueueItem(tidalID: 900100003, title: "Paper Harbour", artist: "Northbound Choir", source: .tidal)
        rows.append(settled)

        let stillWaiting = await harness.resolver.fillLibraryMarks(rows)
        #expect(stillWaiting == rows)

        library.setReady(true)
        let filled = await harness.resolver.fillLibraryMarks(rows)
        #expect(filled.map(\.id) == rows.map(\.id))
        #expect(filled[0].libraryMatch == Self.exact("Blue Lantern"))
        #expect(!filled[0].included)
        #expect(!filled[0].isLibraryCheckPending)
        #expect(filled[1].libraryMatch == nil)
        #expect(!filled[1].included)
        #expect(!filled[1].isLibraryCheckPending)
        #expect(filled[2] == settled)
    }

    @Test func theLibraryServiceSaysCheckingWhileItScansAndMarksOnceReady() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resolve-library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([0]).write(to: folder.appendingPathComponent("Blue Lantern.flac"))
        let gate = TIDALGate()
        let reader = ResolveBlockingTagReader(gate: gate, tags: AudioTags(title: "Blue Lantern", artists: ["Placeholder Artist"],
                                                                          durationSeconds: 200))
        let service = LibraryIndexService(cacheFile: folder.appendingPathComponent("index.json"), reader: reader,
                                          isOnlineOnly: { _ in false })
        let query = LibraryMatcher.Query(title: "Blue Lantern", artists: .names(["Placeholder Artist"]), durationSeconds: 200)

        await service.scan(folder)
        #expect(await service.mark(for: query) == .pending)
        await gate.open()
        await service.waitForScan()
        let mark = await service.mark(for: query)
        guard case let .checked(match?) = mark else {
            Issue.record("Expected a library match, got \(mark)")
            return
        }
        #expect(match.kind == .exact)
        #expect(NoLibrary().mark(for: query) == .checked(nil))
    }

    @Test func aLibraryThatCantBeReadOnlyMarksRowsFromASavedIndex() {
        // D4 4.20 and 3.9: an unreadable library with no saved index has
        // checked nothing, so rows wait instead of passing as new.
        #expect(!LibraryMarks.indexIsUsable(status: .unavailable(lastScanned: nil), hasIndex: false))
        #expect(!LibraryMarks.indexIsUsable(status: .failed("refused"), hasIndex: false))
        #expect(LibraryMarks.indexIsUsable(status: .unavailable(lastScanned: Date()), hasIndex: true))
        #expect(LibraryMarks.indexIsUsable(status: .failed("refused"), hasIndex: true))
        #expect(!LibraryMarks.indexIsUsable(status: .scanning(done: 0, total: 0), hasIndex: true))
        #expect(LibraryMarks.indexIsUsable(status: .ready(fileCount: 0), hasIndex: true))
        #expect(LibraryMarks.indexIsUsable(status: .off, hasIndex: false))
    }

    @Test func aMissingLibraryDriveWithNoSavedIndexHoldsRowsAsCheckingAndASavedIndexStillMarks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("resolve-unplugged-\(UUID().uuidString)")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("resolve-index-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: cache)
        }
        let gate = TIDALGate()
        await gate.open()
        let reader = ResolveBlockingTagReader(gate: gate, tags: AudioTags(title: "Blue Lantern", artists: ["Placeholder Artist"],
                                                                          durationSeconds: 200))
        let query = LibraryMatcher.Query(title: "Blue Lantern", artists: .names(["Placeholder Artist"]), durationSeconds: 200)

        // The drive isn't there and nothing was ever read: not "not in library".
        let fresh = LibraryIndexService(cacheFile: cache, reader: reader, isOnlineOnly: { _ in false })
        await fresh.scan(folder)
        guard case .unavailable = await fresh.status else {
            Issue.record("Expected the library to be unavailable, got \(await fresh.status)")
            return
        }
        #expect(await fresh.mark(for: query) == .pending)

        // Read once, then unplugged: the saved index keeps marking (D4 3.9).
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent("Blue Lantern.flac"))
        let service = LibraryIndexService(cacheFile: cache, reader: reader, isOnlineOnly: { _ in false })
        await service.scan(folder)
        await service.waitForScan()
        try FileManager.default.removeItem(at: folder)
        await service.scan(folder)
        guard case .unavailable = await service.status else {
            Issue.record("Expected the library to be unavailable, got \(await service.status)")
            return
        }
        guard case let .checked(match?) = await service.mark(for: query) else {
            Issue.record("Expected the saved index to mark the row")
            return
        }
        #expect(match.kind == .exact)
    }

    @Test func oldSavedQueuesLoadAndTheCheckingMarkIsSaved() throws {
        let old = """
        {"id":"00000000-0000-4000-8000-0000000000AA","tidalID":900100001,"title":"Blue Lantern","artist":"Placeholder Artist",
         "hiRes":false,"explicit":false,"source":"tidal","match":{"matched":{}},"included":true,"state":{"waiting":{}}}
        """
        let decoded = try JSONDecoder().decode(QueueItem.self, from: Data(old.utf8))
        #expect(!decoded.isLibraryCheckPending)
        #expect(decoded.libraryCheckPending == nil)
        #expect(decoded.originalDurationSeconds == nil)

        var pending = decoded
        pending.libraryCheckPending = true
        pending.originalDurationSeconds = 199
        let again = try JSONDecoder().decode(QueueItem.self, from: JSONEncoder().encode(pending))
        #expect(again.isLibraryCheckPending)
        #expect(again.originalDurationSeconds == 199)
    }

    // MARK: Summaries (D4 4.2, 4.9)

    @Test func summariesAddUpAndNameTheSource() {
        var summary = ResolveSummary(sourceName: "Exportify CSV", unit: .lines)
        summary.added = 1_250
        summary.found = 1_200
        summary.notOnTIDAL = 50
        summary.alreadyInQueue = 40
        #expect(summary.message
            == "Added 1,250 tracks from Exportify CSV: 1,200 found on TIDAL, 50 not found. 40 were already in the queue.")

        var stopped = ResolveSummary(sourceName: "Exportify CSV", unit: .lines)
        stopped.stopped = true
        stopped.processed = 120
        stopped.total = 500
        stopped.added = 120
        stopped.found = 112
        stopped.notOnTIDAL = 8
        #expect(stopped.message == "Stopped after 120 of 500. Added 112 tracks, 8 not found. The other 380 lines weren't added.")

        var single = ResolveSummary(sourceName: "link")
        single.alreadyInQueue = 1
        #expect(single.message == "This track is already in the queue.")

        let nothing = ResolveSummary(sourceName: "Glass Orchard")
        #expect(nothing.message == "No tracks were found in Glass Orchard.")
    }

    @Test func aRowStillWaitingForItsLibraryCheckIsHeldFromDownloadAll() {
        var row = QueueItem(tidalID: 900400010, title: "Blue Lantern", artist: "Placeholder Artist", source: .tidal)
        #expect(row.isDownloadable)
        row.libraryCheckPending = true
        #expect(!row.isDownloadable)
        row.libraryCheckPending = nil
        #expect(row.isDownloadable)
    }

    @Test func everyNewTIDALRowSaysWhetherTIDALHasALosslessVersion() {
        let aacOnly = TIDALQueueTrack(tidalId: 900400011, title: "Paper Harbour", artists: ["Another Band"],
                                      audioQuality: "HIGH")
        let lossless = TIDALQueueTrack(tidalId: 900400012, title: "Blue Lantern", artists: ["Placeholder Artist"],
                                       audioQuality: "LOSSLESS")
        let unknown = TIDALQueueTrack(tidalId: 900400013, title: "Copper Sky", artists: ["Placeholder Artist"])
        #expect(NewRow.tidal(aacOnly, source: .importList).item.losslessOnTIDAL == false)
        #expect(NewRow.tidal(lossless, source: .spotify).item.losslessOnTIDAL == true)
        #expect(NewRow.tidal(unknown, source: .tidal).item.losslessOnTIDAL == nil)
    }
}

/// A tag reader that waits for a gate, so a test can look at the library
/// service while its scan is still running.
final class ResolveBlockingTagReader: TagReading {
    let gate: TIDALGate
    let tags: AudioTags

    init(gate: TIDALGate, tags: AudioTags) {
        self.gate = gate
        self.tags = tags
    }

    func readTags(at url: URL) async -> AudioTags? {
        await gate.wait()
        return tags
    }
}
