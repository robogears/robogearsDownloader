import Foundation
import Testing
@testable import RobogearsCore

/// The one shared pace every TIDAL caller goes through (D4 1.4 option A).
@Suite("TIDAL pace")
struct TIDALPaceTests {
    private static let start = TIDALClientFixtures.start

    // MARK: Slots

    @Test func neverRunsMoreThanEightOrdinaryRequestsAtOnce() async throws {
        let pace = TIDALPace()
        let gate = TIDALGate()
        let counter = ResolveConcurrency()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await pace.run(.matching) {
                        counter.enter()
                        await gate.wait()
                        counter.leave()
                    }
                }
            }
            #expect(await resolveEventually { counter.current == 8 })
            try await Task.sleep(for: .milliseconds(50))
            #expect(counter.current == 8)
            #expect(await pace.queued == 12)
            await gate.open()
            try await group.waitForAll()
        }
        #expect(counter.peak == 8)
        #expect(await pace.inFlight == 0)
    }

    @Test func aClickedPreviewStartsWhileEightDownloadsHoldEveryOrdinarySlot() async throws {
        let pace = TIDALPace()
        let gate = TIDALGate()
        let downloads = ResolveConcurrency()
        let matching = ResolveConcurrency()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await pace.run(.download) { downloads.enter(); await gate.wait() } }
            }
            #expect(await resolveEventually { downloads.current == 8 })
            group.addTask { try await pace.run(.matching) { matching.enter() } }
            #expect(await resolveEventually { await pace.queued == 1 })

            // The extra slot: the click runs now, with every ordinary slot held.
            let answer = try await pace.run(.interactive) { "preview" }
            #expect(answer == "preview")
            #expect(matching.current == 0)

            await gate.open()
            try await group.waitForAll()
        }
        #expect(matching.peak == 1)
    }

    @Test func waitingWorkStartsInPriorityOrderThenArrivalOrder() async throws {
        let pace = TIDALPace(limits: .init(shared: 1, interactiveExtra: 0, background: 1, longestWait: .seconds(60)))
        let gate = TIDALGate()
        let started = ResolveConcurrency()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await pace.run(.download) { await gate.wait() } }
            #expect(await resolveEventually { await pace.inFlight == 1 })
            let arrivals: [(String, TIDALPace.Priority)] = [
                ("background", .background), ("download", .download), ("matching 1", .matching),
                ("search", .interactive), ("matching 2", .matching),
            ]
            for (index, (name, priority)) in arrivals.enumerated() {
                group.addTask { try await pace.run(priority) { started.enter(name) } }
                #expect(await resolveEventually { await pace.queued == index + 1 })
            }
            await gate.open()
            try await group.waitForAll()
        }
        #expect(started.order == ["search", "matching 1", "matching 2", "download", "background"])
    }

    @Test func anInteractiveSearchOvertakesQueuedMatching() async throws {
        // No extra slot here, so only the queue order can let the search
        // through first.
        let pace = TIDALPace(limits: .init(shared: 2, interactiveExtra: 0, background: 1, longestWait: .seconds(60)))
        let gate = TIDALGate()
        let started = ResolveConcurrency()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 { group.addTask { try await pace.run(.matching) { await gate.wait() } } }
            #expect(await resolveEventually { await pace.inFlight == 2 })
            for line in 1...5 {
                group.addTask { try await pace.run(.matching) { started.enter("line \(line)") } }
            }
            #expect(await resolveEventually { await pace.queued == 5 })
            group.addTask { try await pace.run(.interactive) { started.enter("search") } }
            #expect(await resolveEventually { await pace.queued == 6 })
            await gate.open()
            try await group.waitForAll()
        }
        #expect(started.order.first == "search")
        #expect(started.order.count == 6)
    }

    @Test func backgroundPreloadingNeverHoldsMoreThanTwoSlots() async throws {
        let pace = TIDALPace()
        let gate = TIDALGate()
        let preloads = ResolveConcurrency()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { try await pace.run(.background) { preloads.enter(); await gate.wait(); preloads.leave() } }
            }
            #expect(await resolveEventually { preloads.current == 2 })
            // Matching isn't held back by the waiting pre-loads.
            let matched = try await pace.run(.matching) { true }
            #expect(matched)
            try await Task.sleep(for: .milliseconds(30))
            #expect(preloads.current == 2)
            await gate.open()
            try await group.waitForAll()
        }
        #expect(preloads.peak == 2)
    }

    @Test func cancellingQueuedWorkLeavesTheQueueAtOnceAndNeverRunsIt() async throws {
        let pace = TIDALPace(limits: .init(shared: 1, interactiveExtra: 0, background: 1, longestWait: .seconds(60)))
        let gate = TIDALGate()
        let ran = TIDALFlag()
        let holder = Task { try await pace.run(.matching) { await gate.wait() } }
        #expect(await resolveEventually { await pace.inFlight == 1 })
        let queued = Task { try await pace.run(.matching) { ran.set() } }
        #expect(await resolveEventually { await pace.queued == 1 })
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(await pace.queued == 0)
        await gate.open()
        try await holder.value
        #expect(!ran.isSet)
        #expect(await pace.inFlight == 0)
    }

    @Test func aFailingRequestStillFreesItsSlot() async throws {
        let pace = TIDALPace(limits: .init(shared: 1, interactiveExtra: 0, background: 1, longestWait: .seconds(60)))
        await #expect(throws: RequestError.notFound(subStatus: nil)) {
            try await pace.run(.matching) { () async throws -> Int in throw RequestError.notFound(subStatus: nil) }
        }
        #expect(await pace.inFlight == 0)
        #expect(try await pace.run(.matching) { 1 } == 1)
    }

    // MARK: The shared 429 pause

    @Test func a429HoldsEveryTryUntilTheRetryAfterEnds() async throws {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        await pace.tooManyRequests(retryAfter: .seconds(5), pause: .seconds(5))
        #expect(await pace.status == .waiting(until: Self.start.addingTimeInterval(5)))

        let passed = TIDALFlag()
        let waiting = Task { try await pace.beforeTry(); passed.set() }
        // The status timer and the waiting try both sleep on the clock.
        #expect(await resolveEventually { clock.sleeperCount == 2 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(!passed.isSet)

        clock.advance(by: .seconds(4))
        try await Task.sleep(for: .milliseconds(30))
        #expect(!passed.isSet)

        clock.advance(by: .seconds(1))
        #expect(try await passed.wait(upTo: .seconds(5)))
        try await waiting.value
        #expect(await resolveEventually { await pace.status == .flowing })
    }

    @Test func a429WithoutRetryAfterPausesEveryoneForTheRequestersBackoffStep() async {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        await pace.tooManyRequests(retryAfter: nil, pause: .seconds(2))
        #expect(await pace.status == .waiting(until: Self.start.addingTimeInterval(2)))
    }

    @Test func aLaterShorter429NeverShortensTheWait() async {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        await pace.tooManyRequests(retryAfter: .seconds(30), pause: .seconds(30))
        await pace.tooManyRequests(retryAfter: .seconds(2), pause: .seconds(2))
        #expect(await pace.status == .waiting(until: Self.start.addingTimeInterval(30)))
    }

    @Test func aRetryAfterOverSixtySecondsFailsLookupsAtOnceAsBusy() async throws {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        await pace.tooManyRequests(retryAfter: .seconds(120), pause: nil)
        #expect(await pace.status == .busy(until: Self.start.addingTimeInterval(120)))
        await #expect(throws: RequestError.busy(retryAfter: .seconds(120))) { try await pace.beforeTry() }

        clock.advance(by: .seconds(120))
        try await pace.beforeTry()
        #expect(await resolveEventually { await pace.status == .flowing })
    }

    @Test func statusChangesPublishTheWaitForTheBatchBar() async throws {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        let seen = ResolveLog<TIDALPace.Status>()
        let listener = Task {
            for await status in await pace.statusChanges() { seen.append(status) }
        }
        #expect(await resolveEventually { seen.count == 1 })
        await pace.tooManyRequests(retryAfter: .seconds(10), pause: .seconds(10))
        #expect(await resolveEventually { seen.count == 2 })
        #expect(await resolveEventually { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(10))
        #expect(await resolveEventually { seen.count == 3 })
        listener.cancel()
        #expect(seen.all == [.flowing, .waiting(until: Self.start.addingTimeInterval(10)), .flowing])
    }

    @Test func cancellingATryThatWaitsOutAPauseStopsItAtOnce() async throws {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        await pace.tooManyRequests(retryAfter: .seconds(50), pause: .seconds(50))
        let waiting = Task { try await pace.beforeTry() }
        #expect(await resolveEventually { clock.sleeperCount == 2 })
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }
}

/// The pace attached to a real `HTTPClient`, answered by the mock server.
@Suite("TIDAL pace with the HTTP client")
struct TIDALPaceHTTPTests {
    private static let start = TIDALClientFixtures.start

    private static func search(_ n: Int) -> HTTPRequest {
        HTTPRequest(method: .get, url: URL(string: "https://api.tidal.com/v1/search/tracks?query=line\(n)")!, headers: [:])
    }

    @Test func one429HoldsEveryOtherCallerUntilItsRetryAfter() async throws {
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        let arrivals = ResolveLog<Date>()
        let server = TIDALMockServer { _, index in
            arrivals.append(clock.now())
            return index == 0
                ? .json(429, "{}", headers: ["Retry-After": "5"])
                : .json(200, "{\"items\":[]}")
        }
        let client = HTTPClient(clock: clock, sessionConfiguration: server.sessionConfiguration(), pacing: pace)

        try await withThrowingTaskGroup(of: Int.self) { group in
            group.addTask { try await pace.run(.matching) { try await client.send(Self.search(0)).status } }
            #expect(await resolveEventually { await pace.status == .waiting(until: Self.start.addingTimeInterval(5)) })

            // Eight more matches while TIDAL's pause runs: none may reach it.
            for n in 1...8 {
                group.addTask { try await pace.run(.matching) { try await client.send(Self.search(n)).status } }
            }
            #expect(await resolveEventually {
                let inFlight = await pace.inFlight, queued = await pace.queued
                return inFlight == 8 && queued == 1
            })
            try await Task.sleep(for: .milliseconds(100))
            #expect(server.requests.count == 1)

            clock.advance(by: .seconds(5))
            var statuses: [Int] = []
            for try await status in group { statuses.append(status) }
            #expect(statuses == Array(repeating: 200, count: 9))
        }
        // The refused request's retry plus the eight others, all after the pause.
        #expect(arrivals.count == 10)
        #expect(arrivals.all.dropFirst().allSatisfy { $0 >= Self.start.addingTimeInterval(5) })
        #expect(await resolveEventually { await pace.status == .flowing })
    }

    @Test func serverErrorsKeepTheOneTwoFourEightBackoffWithThePaceAttached() async throws {
        let clock = TIDALTestClock()
        let pace = TIDALPace(clock: clock)
        let server = TIDALMockServer(replies: Array(repeating: .json(503, "{}"), count: 4) + [.json(200, "{}")])
        let client = HTTPClient(clock: clock, sessionConfiguration: server.sessionConfiguration(), pacing: pace)
        let response = try await pace.run(.matching) { try await client.send(Self.search(1)) }
        #expect(response.status == 200)
        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
        #expect(await pace.status == .flowing)
    }

    @Test func notFoundIsNeverRetriedWithThePaceAttached() async throws {
        let pace = TIDALPace(clock: TIDALTestClock())
        let server = TIDALMockServer(replies: [.json(404, "{}"), .json(200, "{}")])
        let client = HTTPClient(clock: TIDALTestClock(), sessionConfiguration: server.sessionConfiguration(), pacing: pace)
        let response = try await pace.run(.matching) { try await client.send(Self.search(1)) }
        #expect(response.status == 404)
        #expect(server.requests.count == 1)
    }

    @Test func waitingOutAnotherCallersPauseDoesntUseUpTheTimeLimit() async throws {
        // A 50 s pause, then a slow first answer: without the deadline moving
        // with the pause, this call would give up as offline at 60 s.
        let clock = ResolveManualClock()
        let pace = TIDALPace(clock: clock)
        await pace.tooManyRequests(retryAfter: .seconds(50), pause: .seconds(50))
        let server = TIDALMockServer { _, index in
            if index == 0 {
                clock.advance(by: .seconds(15))
                return .failure(.timedOut)
            }
            return .json(200, "{}")
        }
        let client = HTTPClient(clock: clock, sessionConfiguration: server.sessionConfiguration(), pacing: pace)
        let call = Task { try await client.send(Self.search(1)).status }
        #expect(await resolveEventually { clock.sleeperCount == 2 })
        clock.advance(by: .seconds(50))
        // The retry after the timeout waits 1 s on the clock.
        #expect(await resolveEventually { clock.sleeperCount >= 1 && server.requests.count == 1 })
        clock.advance(by: .seconds(1))
        #expect(try await call.value == 200)
    }
}
