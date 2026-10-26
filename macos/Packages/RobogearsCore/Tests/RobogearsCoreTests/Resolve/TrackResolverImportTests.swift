import Foundation
import Testing
@testable import RobogearsCore

/// Tracklists and pasted lines, and how a long add behaves: the shared pace,
/// Cancel, a busy TIDAL and a lost connection (D4 4.5–4.9, 4.13, 1.4, 1.7,
/// 1.11).
@Suite("Resolver: imports")
struct TrackResolverImportTests {

    private static func lines(_ count: Int) -> String {
        (1...count).map { "Song \($0) - Placeholder Artist" }.joined(separator: "\n")
    }

    private static func songNumber(_ request: TIDALRecordedRequest) -> Int? {
        guard request.url.path == "/v1/search/tracks",
              let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "query" })?.value,
              query.hasPrefix("Song ") else { return nil }
        return Int(query.dropFirst(5).prefix { $0.isNumber })
    }

    private static func songReply(_ number: Int) -> TIDALMockReply {
        .json(200, ResolveJSON.results([ResolveJSON.track(Int64(901_000_000 + number), "Song \(number)", artists: ["Placeholder Artist"])]))
    }

    // MARK: Lines (D4 4.6, 4.7)

    @Test func aPastedLineIsMatchedInEitherOrderAndAddedDirectly() async {
        #expect(AddRoute.forPaste("Placeholder Artist - Blue Lantern") == .add(.line("Placeholder Artist - Blue Lantern")))
        #expect(AddRoute.forPaste("Blue Lantern, Placeholder Artist") == .add(.line("Blue Lantern, Placeholder Artist")))
        #expect(AddRoute.forPaste("Blue Lantern") == .search(query: "Blue Lantern", looksLikeID: false))
        // In the field, the same line searches: the hint promises a search (D4 4.1).
        #expect(AddRoute.forField("Placeholder Artist - Blue Lantern")
            == .search(query: "Placeholder Artist - Blue Lantern", looksLikeID: false))

        let harness = ResolveHarness()
        harness.backend.search("Placeholder Artist Blue Lantern", [
            ResolveJSON.track(900900001, "Blue Lantern", artists: ["Placeholder Artist"], hiRes: true),
        ])
        let events = await harness.run(.line("Placeholder Artist - Blue Lantern"))
        let row = events.rows.first
        #expect(events.rows.count == 1)
        #expect(row?.tidalID == 900900001)
        #expect(row?.source == .importList)
        #expect(row?.hiRes == true)
        #expect(row?.originalTitle == nil)
        #expect(events.summary?.sourceName == "pasted text")

        // A comma works as the separator too (D4 4.7: "now also for a comma").
        harness.backend.search("Copper Sky Late Ferry Band", [
            ResolveJSON.track(900900002, "Copper Sky", artists: ["Late Ferry Band"]),
        ])
        let comma = await harness.run(.line("Copper Sky, Late Ferry Band"))
        #expect(comma.rows.map(\.tidalID) == [900900002])
        #expect(comma.rows.first?.match == .matched)
    }

    @Test func pastingLinksAndUnusableLinksIsRoutedBeforeAnythingIsSent() {
        #expect(AddRoute.forPaste("https://tidal.com/browse/track/900100001") == .add(.link("https://tidal.com/browse/track/900100001")))
        #expect(AddRoute.forPaste("https://music.apple.com/us/album/x/1") == .refuse(
            "Apple Music links aren't supported. Paste a TIDAL or Spotify link, or type the song's name."))
        #expect(AddRoute.forPaste("  \n ") == .nothing)
        let list = "Blue Lantern - Placeholder Artist\nhttps://tidal.com/browse/track/900100001"
        #expect(AddRoute.forPaste(list) == .add(.tracklist(text: list, name: nil)))
        #expect(AddRoute.forField(list) == .add(.tracklist(text: list, name: nil)))
    }

    // MARK: Lists with links (D4 4.13)

    @Test func linksInsideAPastedListAreAddedAsLinksInTheListsOrder() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.tracks[900600001] = ResolveJSON.data(ResolveJSON.track(900600001, "Copper Sky", artists: ["Late Ferry Band"]))
        }
        harness.backend.search("Blue Lantern Placeholder Artist", [
            ResolveJSON.track(900600002, "Blue Lantern", artists: ["Placeholder Artist"]),
        ])
        harness.backend.search("Northbound Choir Paper Harbour", [
            ResolveJSON.track(900600003, "Paper Harbour", artists: ["Northbound Choir"]),
        ])
        let events = await harness.run(.tracklist(text: ResolveFixtures.text("pasted-mixed.txt"), name: nil))
        #expect(events.rows.map(\.tidalID) == [900600002, 900600001, 900600003])
        // The two links are counted as links while they are read, then the
        // two song lines as tracks being matched (D4 4.21).
        #expect(events.progress.first == .readingLinks(done: 0, total: 2))
        #expect(events.progress.contains(.readingLinks(done: 2, total: 2)))
        #expect(!events.progress.contains { if case .loading = $0 { true } else { false } })
        #expect(events.progress.last == .matching(done: 2, total: 2))
        #expect(events.rows.map(\.source) == [.importList, .tidal, .importList])
        #expect(!harness.searchQueries.contains { $0.contains("http") })
        let summary = events.summary
        #expect(summary?.skippedLinks == [SkippedLink(
            link: "https://www.youtube.com/watch?v=SynVideo1",
            reason: "YouTube links aren't supported. Paste a TIDAL or Spotify link, or type the song's name.")])
        #expect(summary?.message == "Added 3 tracks from pasted text. Skipped 1 link the app can't add: "
            + "YouTube links aren't supported. Paste a TIDAL or Spotify link, or type the song's name.")
    }

    // MARK: CSVs (D4 4.5, 4.17)

    @Test func anISRCIsLookedUpBeforeAnySearch() async {
        let harness = ResolveHarness()
        harness.backend.setUp {
            $0.isrcs["ZZRES2600001"] = ResolveJSON.results([
                ResolveJSON.track(900300001, "Blue Lantern", artists: ["Placeholder Artist"], duration: 245, isrc: "ZZRES2600001"),
            ])
        }
        harness.backend.search("Paper Harbour Northbound Choir", [
            ResolveJSON.track(900300002, "Paper Harbour", artists: ["Northbound Choir"], duration: 210),
        ])
        let events = await harness.run(.tracklistFile(ResolveFixtures.data("exportify-isrc.csv"), name: "glass-orchard.csv"))
        #expect(events.rows.map(\.tidalID) == [900300001, 900300002])
        #expect(harness.tidalRequests.contains("/v1/tracks?isrc=ZZRES2600001&countryCode=GB"))
        #expect(harness.searchQueries == ["Paper Harbour Northbound Choir"])
        #expect(events.summary?.sourceName == "Exportify CSV")
        #expect(events.summary?.columns?.title == "Track Name")
        #expect(events.summary?.message == "Added 2 tracks from Exportify CSV. "
            + "Columns: Track Name → title, Artist Name(s) → artist, ISRC → recording code, Duration (ms) → length.")
        // The CSV's own lengths stay with the rows, beside TIDAL's (D4 4.14).
        #expect(events.rows.map(\.originalDurationSeconds) == [245, 210])
    }

    @Test func aRefusedISRCLookupFallsBackToTheSearch() async {
        let harness = ResolveHarness()
        harness.backend.intercept { request, _ in
            request.url.path == "/v1/tracks" ? .json(400, "{\"status\":400,\"subStatus\":1002}") : nil
        }
        harness.backend.search("Blue Lantern Placeholder Artist", [
            ResolveJSON.track(900300001, "Blue Lantern", artists: ["Placeholder Artist"], duration: 245),
        ])
        let events = await harness.run(.tracklistFile(ResolveFixtures.data("exportify-isrc.csv"), name: "glass-orchard.csv"))
        #expect(events.rows.first?.tidalID == 900300001)
        #expect(harness.searchQueries.contains("Blue Lantern Placeholder Artist"))
    }

    @Test func aFileThatIsntTextIsRefusedAndAnEmptyListSaysWhatItNeeds() async {
        let harness = ResolveHarness()
        var binary = Data("ID3".utf8)
        binary.append(contentsOf: [0, 0, 0, 1, 2, 3, 0, 0, 0xFF, 0xFB])
        let audio = await harness.run(.tracklistFile(binary, name: "Blue Lantern.mp3"))
        #expect(audio.failure?.kind == .notText)
        #expect(audio.failure?.message == "Blue Lantern.mp3 isn't a text tracklist. Drop a CSV or text tracklist, or a TIDAL or Spotify link.")

        let empty = await harness.run(.tracklist(text: "\n  \n", name: "notes.txt"))
        #expect(empty.failure?.kind == .empty)
        #expect(harness.server.requests.isEmpty)
    }

    @Test func aUTF16FileFromMusicIsReadAndNamedByItsFile() async {
        let harness = ResolveHarness()
        harness.backend.search("Blue Lantern Placeholder Artist", [
            ResolveJSON.track(900300001, "Blue Lantern", artists: ["Placeholder Artist"]),
        ])
        var bytes = Data([0xFF, 0xFE])
        bytes.append("Blue Lantern - Placeholder Artist\r\n".data(using: .utf16LittleEndian)!)
        let events = await harness.run(.tracklistFile(bytes, name: "my-list.txt"))
        #expect(events.rows.map(\.tidalID) == [900300001])
        #expect(events.summary?.sourceName == "my-list.txt")
    }

    // MARK: A busy TIDAL (D4 1.4)

    @Test func aBusyTIDALGivesCouldntCheckRowsNeverNotFound() async {
        let harness = ResolveHarness()
        harness.backend.intercept { request, _ in
            request.url.path == "/v1/search/tracks" ? .json(429, "{}", headers: ["Retry-After": "120"]) : nil
        }
        let events = await harness.run(.tracklist(text: Self.lines(2), name: nil))
        #expect(events.rows.count == 2)
        #expect(events.rows.allSatisfy { $0.match == .couldNotCheck(reason: "Couldn't check: TIDAL was busy") })
        #expect(events.summary?.notOnTIDAL == 0)
        #expect(events.summary?.message == "Added 2 tracks from pasted text: 0 found on TIDAL, 2 couldn't be checked.")
        #expect(events.logs.allSatisfy { !$0.contains("Bearer") && !$0.contains("fake-access") })
    }

    @Test func serverErrorsAfterTheRetriesAlsoGiveCouldntCheck() async {
        let harness = ResolveHarness()
        harness.backend.intercept { request, _ in
            request.url.path == "/v1/search/tracks" ? .json(503, "{}") : nil
        }
        let events = await harness.run(.line("Blue Lantern - Placeholder Artist"))
        #expect(events.rows.first?.match == .couldNotCheck(reason: "Couldn't check: TIDAL was busy"))
        // The first try and the four 1-2-4-8 s retries.
        #expect(harness.searchQueries.count == 5)
    }

    // MARK: The shared pace (D4 1.4)

    @Test func twoImportsShareEightRequestsInFlight() async {
        let harness = ResolveHarness()
        let gate = TIDALGate()
        let inFlight = ResolveConcurrency()
        harness.backend.intercept { request, _ in
            guard request.url.path == "/v1/search/tracks" else { return nil }
            inFlight.enter()
            await gate.wait()
            inFlight.leave()
            return nil
        }
        async let first = harness.run(.tracklist(text: Self.lines(10), name: nil))
        async let second = harness.run(.tracklist(text: Self.lines(10).replacingOccurrences(of: "Song", with: "Tune"), name: nil))
        #expect(await resolveEventually { inFlight.current == 8 })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(inFlight.current == 8)
        await gate.open()
        let (a, b) = await (first, second)
        #expect(a.rows.count == 10 && b.rows.count == 10)
        #expect(inFlight.peak == 8)
    }

    @Test func one429PausesTheWholeImportForItsRetryAfterThenEveryLineMatches() async throws {
        let clock = ResolveManualClock()
        let harness = ResolveHarness(clock: clock)
        let allSent = TIDALGate()
        let gate = TIDALGate()
        let arrivals = ResolveLog<(index: Int, at: Date)>()
        harness.backend.intercept { request, index in
            guard let number = Self.songNumber(request) else { return nil }
            arrivals.append((index, clock.now()))
            if index == 0 {
                await allSent.wait()
                return .json(429, "{}", headers: ["Retry-After": "5"])
            }
            await gate.wait()
            return Self.songReply(number)
        }
        let job = Task { await harness.run(.tracklist(text: Self.lines(10), name: nil)) }
        let start = TIDALClientFixtures.start
        // Eight lines on the wire, then TIDAL refuses the first.
        #expect(await resolveEventually { harness.server.requests.count == 8 })
        await allSent.open()
        #expect(await resolveEventually { await harness.pace.status == .waiting(until: start.addingTimeInterval(5)) })

        // The seven searches already under way finish; the two lines left and
        // the refused line's retry wait out TIDAL's pause.
        await gate.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.server.requests.count == 8)

        clock.advance(by: .seconds(5))
        let events = await job.value
        #expect(harness.server.requests.count == 11)
        #expect(arrivals.all.filter { $0.index >= 8 }.allSatisfy { $0.at >= start.addingTimeInterval(5) })
        #expect(events.rows.count == 10)
        #expect(events.rows.allSatisfy { $0.match == .matched })
    }

    @Test func aTypedSearchOvertakesAnImportWaitingForTheSameSlot() async throws {
        let harness = ResolveHarness(paceLimits: .init(shared: 1, interactiveExtra: 0, background: 1, longestWait: .seconds(60)))
        let gate = TIDALGate()
        harness.backend.intercept { request, index in
            if index == 0 { await gate.wait() }
            return nil
        }
        let job = Task { await harness.run(.tracklist(text: Self.lines(4), name: nil)) }
        #expect(await resolveEventually {
            let queued = await harness.pace.queued
            return queued == 3 && harness.server.requests.count == 1
        })
        let search = Task { try await harness.resolver.search("Glass Orchard") }
        #expect(await resolveEventually { await harness.pace.queued == 4 })
        await gate.open()
        _ = try await search.value
        _ = await job.value
        // Whichever line held the one slot went first; the search came next.
        #expect(harness.searchQueries.dropFirst().first == "Glass Orchard")
        #expect(harness.searchQueries.count == 5)
    }

    // MARK: Cancel (D4 4.9, 1.11)

    @Test(.timeLimit(.minutes(1))) func cancelKeepsFinishedRowsAndStopsTheRequestsInFlight() async {
        let harness = ResolveHarness()
        let cancelled = ResolveLog<Int>()
        harness.backend.intercept { request, _ in
            guard let number = Self.songNumber(request) else { return nil }
            if number <= 3 { return Self.songReply(number) }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.append(number)
            }
            return .hang
        }
        let job = harness.resolver.add(.tracklist(text: Self.lines(10), name: nil))
        var events: [ResolveEvent] = []
        var stopped = false
        let begun = ContinuousClock.now
        for await event in job {
            events.append(event)
            if !stopped, events.rows.count == 3 {
                stopped = true
                // Lines 4-10 took the freed places and are all on the wire.
                _ = await resolveEventually { harness.server.requests.count == 10 }
                job.stop()
            }
        }
        #expect(ContinuousClock.now - begun < .seconds(5))
        #expect(events.rows.map(\.tidalID) == [901_000_001, 901_000_002, 901_000_003])
        let summary = events.summary
        #expect(summary?.stopped == true)
        #expect(summary?.processed == 3)
        #expect(summary?.total == 10)
        #expect(summary?.message == "Stopped after 3 of 10. Added 3 tracks. The other 7 lines weren't added.")
        // Each request under way was stopped, not left to time out.
        #expect(await resolveEventually { cancelled.count == 7 })
        #expect(Set(cancelled.all) == Set(4...10))
        #expect(harness.server.requests.count == 10)
    }

    /// D4 4.9 A: "Stopped after 120 of 500. Added 112 tracks, 8 not found."
    /// The parts add up to the lines processed.
    @Test(.timeLimit(.minutes(1))) func aStoppedImportsSummaryAddsUpToTheLinesProcessed() async {
        let harness = ResolveHarness()
        harness.backend.intercept { request, _ in
            switch Self.songNumber(request) {
            case 1: Self.songReply(1)
            case 2: .json(200, ResolveJSON.results([]))   // not on TIDAL
            case 3: .json(503, "{}")                      // busy after the retries
            case .some: .hang
            case nil: nil
            }
        }
        let job = harness.resolver.add(.tracklist(text: Self.lines(5), name: nil))
        var events: [ResolveEvent] = []
        var stopped = false
        for await event in job {
            events.append(event)
            if !stopped, events.rows.count == 3 {
                stopped = true
                job.stop()
            }
        }
        #expect(events.rows.map(\.match) == [.matched, .notOnTIDAL, .couldNotCheck(reason: "Couldn't check: TIDAL was busy")])
        let summary = events.summary
        #expect(summary?.added == 3)
        #expect(summary?.found == 1)
        #expect(summary?.message
            == "Stopped after 3 of 5. Added 1 track, 1 not found, 1 couldn't be checked. The other 2 lines weren't added.")
    }

    @Test(.timeLimit(.minutes(1))) func cancelWhileAListsLinksLoadKeepsTheLinksAlreadyRead() async {
        let harness = ResolveHarness()
        let album = (0..<3).map { ResolveJSON.track(900_120_000 + Int64($0), "Track \($0)", artists: ["Placeholder Artist"]) }
        harness.backend.setUp {
            $0.albums[8100001] = ResolveJSON.data(["id": 8100001, "title": "Harbour Lights"])
            $0.albumPages[8100001] = [ResolveJSON.itemsPage(album, offset: 0, total: 3)]
        }
        // The second album never answers; only Cancel ends its request.
        harness.backend.intercept { request, _ in
            request.url.path.hasPrefix("/v1/albums/8100002") ? .hang : nil
        }
        let text = "https://tidal.com/browse/album/8100001\nhttps://tidal.com/browse/album/8100002\nSong 1 - Placeholder Artist"
        let job = harness.resolver.add(.tracklist(text: text, name: nil))
        var events: [ResolveEvent] = []
        var stopped = false
        let begun = ContinuousClock.now
        for await event in job {
            events.append(event)
            if !stopped, case .progress(.readingLinks(done: 1, total: 2)) = event {
                stopped = true
                job.stop()
            }
        }
        #expect(ContinuousClock.now - begun < .seconds(5))
        // The album already read stays; the one still loading and the line
        // behind it are dropped, and nothing more is sent.
        #expect(events.rows.map(\.tidalID) == (0..<3).map { 900_120_000 + Int64($0) })
        #expect(events.summary?.stopped == true)
        #expect(events.summary?.message == "Stopped after 3 of 4. Added 3 tracks. The other 1 track wasn't added.")
        #expect(harness.searchQueries.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func cancelDuringMatchingKeepsTracksAlreadyReadFromALink() async {
        let harness = ResolveHarness()
        // One match at a time, so the album's rows sit behind the line.
        var resolver = harness.resolver
        resolver.matchWindow = 1
        let album = (0..<2).map { ResolveJSON.track(900_130_000 + Int64($0), "Track \($0)", artists: ["Placeholder Artist"]) }
        harness.backend.setUp {
            $0.albums[8100003] = ResolveJSON.data(["id": 8100003, "title": "Harbour Lights"])
            $0.albumPages[8100003] = [ResolveJSON.itemsPage(album, offset: 0, total: 2)]
        }
        harness.backend.intercept { request, _ in Self.songNumber(request) != nil ? .hang : nil }
        let job = resolver.add(.tracklist(text: "Song 1 - Placeholder Artist\nhttps://tidal.com/browse/album/8100003", name: nil))
        var events: [ResolveEvent] = []
        var stopped = false
        for await event in job {
            events.append(event)
            if !stopped, case .progress(.matching(done: 0, total: 1)) = event {
                stopped = true
                _ = await resolveEventually { harness.searchQueries.count == 1 }
                job.stop()
            }
        }
        // The line still being matched is dropped; the album's tracks were
        // already read, so they join the queue in the list's order.
        #expect(events.rows.map(\.tidalID) == [900_130_000, 900_130_001])
        #expect(events.summary?.stopped == true)
        #expect(events.summary?.message == "Stopped after 2 of 3. Added 2 tracks. The other 1 track wasn't added.")
    }

    // MARK: Offline and signed out (D4 1.7, 1.1)

    @Test func anImportWithNoConnectionStopsAndKeepsWhatWasPastedForTryAgain() async {
        let harness = ResolveHarness()
        harness.backend.intercept { _, _ in .failure(.notConnectedToInternet) }
        let source = ResolveSource.tracklist(text: Self.lines(3), name: nil)
        let events = await harness.run(source)
        #expect(events.rows.isEmpty)
        let failure = events.failure
        #expect(failure?.kind == .offline)
        #expect(failure?.message == "No internet connection. Check your connection, then click Try Again.")
        #expect(failure?.retry == source)
        #expect(failure?.isRetryable == true)
    }

    @Test func aLinkLookupWithNoConnectionKeepsTheLinkForTryAgain() async {
        let harness = ResolveHarness()
        harness.backend.intercept { _, _ in .failure(.notConnectedToInternet) }
        let source = ResolveSource.link("https://tidal.com/browse/album/8100000")
        let events = await harness.run(source)
        #expect(events.failure?.kind == .offline)
        #expect(events.failure?.retry == source)
    }

    @Test func signedOutAddsAskForSignInAndKeepTheSource() async {
        let harness = ResolveHarness(credential: nil)
        let source = ResolveSource.tracklist(text: Self.lines(2), name: nil)
        let events = await harness.run(source)
        #expect(events.failure?.kind == .signInNeeded)
        #expect(events.failure?.message == "Sign in to TIDAL to add tracks from pasted text.")
        #expect(events.failure?.retry == source)
        #expect(harness.server.requests.isEmpty)
    }
}
