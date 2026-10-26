// The core of Download All: one batch of queue rows, downloaded one track
// at a time as the Electron bulk runner did (download-pipeline.md A6),
// through any `TrackDownloading`. It knows nothing about windows: what
// happens goes out as events the app model and the queue store apply.
//
// Decision 4 sets the rules; item numbers below refer to it. In short:
// a shared problem stops the batch once and puts every unfinished row
// back (2.1), being offline pauses and resumes (1.7), Cancel stops at once
// and fails nothing (2.4), Quit stops cleanly (2.5), removing a row takes
// it out of the batch (2.13), the counter counts only this batch (2.22),
// the folder is fixed for the whole run (2.17) and the Mac stays awake
// while tracks run (2.12).
import Foundation
import Synchronization

/// One batch: Download All, a row's Retry, Retry All or Retry Selected.
///
/// An actor rather than an `@Observable` model: the batch outlives any one
/// view (closing the window keeps downloading, 2.5) and its state changes
/// from download tasks off the main thread. The app's main-actor model
/// subscribes to `events()` and redraws from them.
///
/// Use: run `BatchPreflight.check` first; on `.go(folder)`, make a batch
/// with that folder, subscribe to `events()`, then `start()`. The track
/// list is fixed: rows added during a batch wait for the next Download All
/// (4.12).
public actor DownloadBatch {
    public enum Kind: Sendable, Equatable {
        /// Download All. Only a complete one clears greyed library rows (3.6).
        case downloadAll
        /// A row's Retry, Retry All or Retry Selected.
        case retry
    }

    /// One row in the batch: what to download, and how the row looked
    /// before, so a stop or Cancel can put it back as it was (2.1).
    public struct Track: Sendable, Equatable {
        public var request: TrackDownloadRequest
        /// A failed row being retried returns to this failure if the batch
        /// stops before it finishes; a damaged-file row being replaced
        /// returns to its "looks damaged" line. Anything else returns to
        /// waiting.
        public var stateBefore: QueueItem.DownloadState
        public var outcomeBefore: TrackDownloadOutcome?

        public var rowID: UUID { request.rowID }

        public init(request: TrackDownloadRequest, stateBefore: QueueItem.DownloadState = .waiting,
                    outcomeBefore: TrackDownloadOutcome? = nil) {
            self.request = request
            self.stateBefore = stateBefore
            self.outcomeBefore = outcomeBefore
        }

        /// Copies the row as it is now. Nil for a row without a TIDAL track.
        /// `replaceExisting` is Replace on a damaged file (2.3).
        public init?(row: QueueItem, folder: URL, replaceExisting: Bool = false) {
            guard let request = row.downloadRequest(folder: folder, replaceExisting: replaceExisting) else { return nil }
            self.init(request: request, stateBefore: row.state, outcomeBefore: row.lastOutcome)
        }
    }

    /// A row's new state. `apply(to:)` writes it into the queue row.
    public struct RowUpdate: Sendable, Equatable {
        public var rowID: UUID
        public var state: QueueItem.DownloadState
        /// What the download did, when it finished without an error.
        public var outcome: TrackDownloadOutcome?
        /// Why it failed. Its `rowMessage` is the row's line; a
        /// `writeFailed` detail is for the activity log only.
        public var error: TrackDownloadError?
        /// The row's line in plain words (2.9), or nil while it waits or runs.
        public var message: String?

        public init(rowID: UUID, state: QueueItem.DownloadState, outcome: TrackDownloadOutcome? = nil,
                    error: TrackDownloadError? = nil, message: String? = nil) {
            self.rowID = rowID
            self.state = state
            self.outcome = outcome
            self.error = error
            self.message = message
        }

        public func apply(to item: inout QueueItem) {
            item.state = state
            item.lastOutcome = outcome
        }
    }

    /// The batch counter: "37 of 120", counting only this batch (2.22).
    public struct Counter: Sendable, Equatable {
        /// Tracks finished in this batch, whatever their result.
        public var finished: Int
        /// Tracks in this batch, less any removed from it (2.13).
        public var total: Int

        public init(finished: Int, total: Int) {
            self.finished = finished
            self.total = total
        }

        public var text: String { "\(finished) of \(total)" }

        /// For the Dock's progress bar (2.12): finished tracks plus the
        /// share of the one downloading now.
        public func fraction(currentPercent: Int = 0) -> Double {
            guard total > 0 else { return 1 }
            let current = Double(min(100, max(0, currentPercent))) / 100
            return min(1, (Double(finished) + current) / Double(total))
        }
    }

    public enum Event: Sendable, Equatable {
        /// The batch has really started (2.18): this is the moment for the
        /// start chime, which the batch plays through its sound sink. The
        /// rows' `.queued` updates follow ("Waiting" in the queue).
        case started(rowIDs: [UUID], folder: URL)
        /// A row's state changed: queued, downloading, finished, or put back.
        case row(RowUpdate)
        /// A downloading row's percent, once per whole-number change.
        case rowProgress(rowID: UUID, percent: Int)
        /// The row was removed from the queue and has left the batch (2.13).
        case rowRemoved(UUID)
        case counter(Counter)
        /// No internet connection: the batch pauses with "Waiting for an
        /// internet connection…" and the Mac may sleep (1.7, 2.12).
        case waitingForNetwork
        /// The connection is back, on Low Data Mode or a phone hotspot. Ask
        /// "Resume downloads on this network?", then call
        /// `resumeOnThisNetwork()`, or `cancel()` to stop (1.7).
        case askToResume
        case resumed
        /// A shared problem stopped the batch: show this one notice (2.1).
        case stopped(StopNotice)
        /// The last event. Every unfinished row has been put back first.
        case finished(Summary)
    }

    /// Tuning, mostly for tests.
    public struct Options: Sendable {
        /// Ask before resuming on a metered network (1.7's sub-choice, A).
        public var askBeforeResumingOnMeteredNetwork = true
        /// TIDAL failures in a row, while online, that stop the batch (2.1).
        public var tidalFailuresInARowToStop = 3
        /// How long to wait before trying again when the Mac has a connection
        /// but TIDAL can't be reached (a hotel login page), round by round.
        public var unreachableRecheckDelays: [Duration] = [.seconds(10), .seconds(20), .seconds(40), .seconds(60)]
        /// The longest Cancel waits for the current track to stop before the
        /// batch ends anyway, so the button is back within a second (2.4).
        public var cancelTimeLimit: Duration = .seconds(1)
        /// The longest Quit waits for the current track to clean up. Its
        /// temporary file is removed at the next launch if it runs over (2.2).
        public var quitTimeLimit: Duration = .seconds(5)
        /// The keep-awake's reason, shown by `pmset -g assertions`.
        public var keepAwakeReason = "robogears Downloader is downloading tracks"

        public init() {}
    }

    /// The folder this batch saves into, to its end (2.17): for the
    /// summary's Open Folder and Settings' "Downloads in progress are saved
    /// to …" line.
    public nonisolated let folder: URL
    public nonisolated let kind: Kind
    /// The batch's rows, in order.
    public nonisolated let rowIDs: [UUID]

    private let downloader: any TrackDownloading
    private let network: any NetworkMonitoring
    private let keepAwake: any SleepPreventing
    private let sounds: (any BatchSoundPlaying)?
    private let clock: any NetworkClock
    private let options: Options
    private let hub = EventHub()

    private enum Status {
        case pending
        case running
        case finished(Result<TrackDownloadOutcome, TrackDownloadError>)
        /// Removed from the queue. A download that finished saving before
        /// the stop reached it still counts in the summary.
        case removed(savedAnyway: TrackDownloadOutcome?)
        /// Put back in the queue at the end.
        case returned
    }

    private struct Entry {
        var track: Track
        var status: Status
    }

    private enum Halt { case cancel, quit }

    private var entries: [Entry]
    private let positions: [UUID: Int]
    private var runTask: Task<Summary, Never>?
    private var attemptTask: Task<TrackDownloadOutcome, any Error>?
    private var pauseTask: Task<Void, any Error>?
    private var resumeQuestion: CheckedContinuation<Bool, Never>?
    private var halt: Halt?
    private var stopReason: StopNotice.Reason?
    private var isPaused = false
    private var isAwake = false
    private var savedATrack = false
    private var tidalFailuresInARow = 0
    private var finalSummary: Summary?

    /// - Parameters:
    ///   - tracks: the rows, in queue order. Each request's folder is set to
    ///     `folder`; a row listed twice runs once.
    ///   - sounds: where the start chime, cancel chime and ending sound go;
    ///     nil plays nothing (the app can play `Summary.sound` itself).
    public init(tracks: [Track], folder: URL, kind: Kind = .downloadAll,
                downloader: any TrackDownloading,
                network: any NetworkMonitoring = SystemNetworkMonitor(),
                keepAwake: any SleepPreventing = SystemSleepPreventer(),
                sounds: (any BatchSoundPlaying)? = nil,
                clock: any NetworkClock = SystemNetworkClock(),
                options: Options = Options()) {
        var seen = Set<UUID>()
        var entries: [Entry] = []
        for var track in tracks where seen.insert(track.rowID).inserted {
            track.request.folder = folder
            entries.append(Entry(track: track, status: .pending))
        }
        self.entries = entries
        self.positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.track.rowID, $0) })
        self.rowIDs = entries.map(\.track.rowID)
        self.folder = folder
        self.kind = kind
        self.downloader = downloader
        self.network = network
        self.keepAwake = keepAwake
        self.sounds = sounds
        self.clock = clock
        self.options = options
    }

    // MARK: - Public controls

    /// A new stream of everything that happens from now on. Subscribe
    /// before `start()` to see the whole batch. Several subscribers (the
    /// window's model, the queue store) each get every event.
    public nonisolated func events() -> AsyncStream<Event> {
        hub.subscribe()
    }

    /// Starts the batch; returns at once. Plays the start chime now, once
    /// the batch has really started (2.18). Calling it again does nothing.
    public func start() {
        guard runTask == nil, finalSummary == nil else { return }
        guard !entries.isEmpty else {
            _ = finish()
            return
        }
        emit(.started(rowIDs: rowIDs, folder: folder))
        for entry in entries {
            emit(.row(RowUpdate(rowID: entry.track.rowID, state: .queued)))
        }
        emitCounter()
        setAwake(true)
        sounds?.play(.downloadChime)
        runTask = Task { await self.runAll() }
    }

    /// Starts the batch if needed and returns its summary when it ends.
    public func run() async -> Summary {
        start()
        if let runTask { return await runTask.value }
        return finalSummary ?? finish()
    }

    /// Cancel and ⌘. (2.4): stops the current track at once (the track's
    /// own clean-up deletes its temporary file) and puts every unfinished
    /// row back as it was; nothing is newly marked failed. Works while
    /// paused. Plays the cancel chime now; the batch ends as soon as the
    /// track has stopped, and never later than `Options.cancelTimeLimit`.
    public func cancel() {
        guard finalSummary == nil, halt == nil else { return }
        halt = .cancel
        // Not started: nothing to stop, and no sound before an action (2.18).
        guard let runTask else {
            _ = finish()
            return
        }
        sounds?.play(.cancelChime)
        interruptCurrentWork()
        let limit = options.cancelTimeLimit
        let clock = self.clock
        Task {
            if await Self.value(of: runTask, within: limit, clock: clock) == nil {
                self.endNow()
            }
        }
    }

    /// Takes a row out of the batch when it's removed from the queue (2.13).
    /// A waiting row simply won't download; the downloading row is stopped
    /// (its temporary file deleted) and the batch moves on. The counter
    /// shrinks. A finished row is left as it is.
    public func remove(_ rowID: UUID) {
        guard finalSummary == nil, let index = positions[rowID] else { return }
        switch entries[index].status {
        case .pending:
            entries[index].status = .removed(savedAnyway: nil)
        case .running:
            entries[index].status = .removed(savedAnyway: nil)
            attemptTask?.cancel()
            // Waiting for the network for a row that's gone, with nothing
            // after it, would wait for nothing.
            if isPaused, nextPending() == nil {
                pauseTask?.cancel()
                answerResumeQuestion(false)
            }
        case .finished, .removed, .returned:
            return
        }
        emit(.rowRemoved(rowID))
        emitCounter()
    }

    /// The answer to `.askToResume`: carry on over this metered network.
    public func resumeOnThisNetwork() {
        answerResumeQuestion(true)
    }

    /// Tracks not finished yet, the one downloading included: for "Quit
    /// while 12 tracks are still downloading?" (2.5). Zero once it ends.
    public var unfinishedCount: Int {
        entries.reduce(0) { count, entry in
            switch entry.status {
            case .pending, .running: count + 1
            default: count
            }
        }
    }

    /// The counter as it stands.
    public var counter: Counter { makeCounter() }

    /// Quit during a batch (2.5): stops like Cancel but silently, ends any
    /// pause, and returns once the current track has cleaned up and every
    /// row's final state has gone out. The returned summary lists those
    /// rows, so the app can apply them and save the queue before quitting
    /// even if its event handler hasn't run yet. Never waits longer than
    /// `Options.quitTimeLimit`.
    public func stopForQuit() async -> Summary {
        if let finalSummary { return finalSummary }
        if halt == nil { halt = .quit }
        interruptCurrentWork()
        guard let runTask else { return finish() }
        if let summary = await Self.value(of: runTask, within: options.quitTimeLimit, clock: clock) {
            return summary
        }
        return finish()
    }

    /// Ends the batch now, when a stopped track is slow to return. Its
    /// late result is ignored: the row has already gone back (2.4, 2.5).
    private func endNow() {
        _ = finish()
    }

    // MARK: - The run

    private func runAll() async -> Summary {
        while halt == nil, stopReason == nil, finalSummary == nil, let index = nextPending() {
            await runTrack(index)
        }
        return finish()
    }

    private func runTrack(_ index: Int) async {
        let rowID = entries[index].track.rowID
        entries[index].status = .running
        var unreachableRounds = 0
        while halt == nil, isRunning(index) {
            emit(.row(RowUpdate(rowID: rowID, state: .downloading(percent: 0))))
            let result = await attempt(index)
            // Cancel or Quit ran out of patience and ended the batch already.
            guard finalSummary == nil else { return }
            if case .removed = entries[index].status {
                if case let .success(outcome) = result { entries[index].status = .removed(savedAnyway: outcome) }
                return
            }
            let failure: TrackDownloadError
            switch result {
            case let .success(outcome):
                // Saved before a Cancel reached it: it stays done (2.4).
                finishRow(index, .success(outcome))
                return
            case let .failure(error):
                // Cancel or Quit stopped it; it goes back at the end.
                if halt != nil { return }
                failure = Self.trackError(from: error)
            }

            var connected = true
            if failure.pausesBatch || failure.isTIDALFailure {
                connected = await network.currentStatus().isOnline
                guard halt == nil, isRunning(index) else { return }
            }
            // TIDAL "failing" while the Mac has no connection is the
            // connection, not TIDAL: pause instead of failing (1.7, 2.1).
            if failure.pausesBatch || (failure.isTIDALFailure && !connected) {
                guard await pauseForNetwork(index, unreachableRound: connected ? unreachableRounds : nil) else { return }
                if connected { unreachableRounds += 1 }
                continue
            }
            if let reason = Self.stopReason(for: failure) {
                stopReason = reason
                return
            }
            // A preview on the first track TIDAL streams in this batch means
            // the plan, not the track (2.23, 1.10). "First" counts from the
            // first track saved, so rows skipped as already in the folder
            // at the start can't hide it; after a save, a preview fails only
            // its own row.
            if failure == .previewOnly, !savedATrack {
                stopReason = .previewsOnly
                return
            }
            finishRow(index, .failure(failure))
            if false {
                stopReason = .tidalFailing(tracksInARow: tidalFailuresInARow)
            }
            return
        }
    }

    /// One call to the downloader. A fresh call gets a fresh stream link,
    /// which is why a retry after a pause starts here again (1.7).
    private func attempt(_ index: Int) async -> Result<TrackDownloadOutcome, any Error> {
        let request = entries[index].track.request
        let downloader = self.downloader
        let hub = self.hub
        let token = hub.beginProgress(rowID: request.rowID)
        let task = Task<TrackDownloadOutcome, any Error> {
            try await downloader.download(request) { fraction in
                hub.progress(fraction, token: token)
            }
        }
        attemptTask = task
        let result = await task.result
        attemptTask = nil
        hub.endProgress(token)
        return result
    }

    private func finishRow(_ index: Int, _ result: Result<TrackDownloadOutcome, TrackDownloadError>) {
        entries[index].status = .finished(result)
        let rowID = entries[index].track.rowID
        let update: RowUpdate
        switch result {
        case let .success(outcome):
            // Only a save shows TIDAL working: a row skipped as already in
            // the folder never asked TIDAL, so it doesn't break a run of
            // TIDAL failures (2.1, 2.16).
            if case .saved = outcome {
                savedATrack = true
                tidalFailuresInARow = 0
            }
            update = RowUpdate(rowID: rowID, state: Self.rowState(for: outcome), outcome: outcome,
                               message: Self.message(for: outcome))
        case let .failure(error):
            tidalFailuresInARow = error.isTIDALFailure ? tidalFailuresInARow + 1 : 0
            // Only this kind of row is saved as failed across restarts (2.9).
            update = RowUpdate(rowID: rowID, state: .failed(reason: error.rowMessage), error: error,
                               message: error.rowMessage)
        }
        emit(.row(update))
        emitCounter()
    }

    // MARK: - Waiting for the network (1.7)

    /// Pauses until the connection is back, then says whether to try the
    /// same track again. `unreachableRound` is set when the Mac reported a
    /// connection but TIDAL couldn't be reached (a hotel login page): then
    /// nothing will announce the fix, so the batch looks again after a
    /// growing delay.
    private func pauseForNetwork(_ index: Int, unreachableRound: Int?) async -> Bool {
        emit(.row(RowUpdate(rowID: entries[index].track.rowID, state: .queued)))
        tidalFailuresInARow = 0
        isPaused = true
        setAwake(false)
        emit(.waitingForNetwork)

        let network = self.network
        let clock = self.clock
        let delays = options.unreachableRecheckDelays
        let delay = unreachableRound.map { delays.isEmpty ? .seconds(30) : delays[min($0, delays.count - 1)] }
        let wait = Task<Void, any Error> {
            if let delay {
                try await clock.sleep(for: delay)
            } else {
                try await network.waitUntilOnline()
            }
        }
        pauseTask = wait
        var resume = (try? await wait.value) != nil
        pauseTask = nil
        guard finalSummary == nil else { return false }
        if resume, halt == nil, options.askBeforeResumingOnMeteredNetwork,
           await network.currentStatus().isMetered, halt == nil {
            emit(.askToResume)
            resume = await withCheckedContinuation { resumeQuestion = $0 }
        }
        isPaused = false
        guard halt == nil, isRunning(index) || nextPending() != nil else { return false }
        setAwake(true)
        emit(.resumed)
        return resume && isRunning(index)
    }

    private func answerResumeQuestion(_ answer: Bool) {
        let question = resumeQuestion
        resumeQuestion = nil
        question?.resume(returning: answer)
    }

    private func interruptCurrentWork() {
        attemptTask?.cancel()
        pauseTask?.cancel()
        answerResumeQuestion(false)
    }

    // MARK: - The end

    /// Puts every unfinished row back, releases the keep-awake, and sends
    /// the stop notice (if any) and the summary. Runs once.
    private func finish() -> Summary {
        if let finalSummary { return finalSummary }
        var returned: [RowUpdate] = []
        for index in entries.indices {
            switch entries[index].status {
            case .pending, .running:
                let update = Self.putBack(entries[index].track)
                entries[index].status = .returned
                emit(.row(update))
                returned.append(update)
            default:
                break
            }
        }
        setAwake(false)
        let ending: Summary.Ending
        switch (halt, stopReason) {
        case (.cancel, _): ending = .cancelled
        case (.quit, _): ending = .quit
        case let (nil, reason?): ending = .stopped(StopNotice(reason: reason, unfinished: returned.count))
        case (nil, nil): ending = .finished
        }
        let summary = Summary(kind: kind, folder: folder, ending: ending, results: results(),
                              unfinished: returned.count, returnedRows: returned)
        finalSummary = summary
        if case let .stopped(notice) = ending { emit(.stopped(notice)) }
        if let sound = summary.sound { sounds?.play(sound) }
        emit(.finished(summary))
        hub.finish()
        return summary
    }

    /// Unfinished rows go back to waiting with no badge; rows being retried
    /// go back to their earlier failure and reason (2.1, 2.4).
    static func putBack(_ track: Track) -> RowUpdate {
        switch track.stateBefore {
        case let .failed(reason):
            return RowUpdate(rowID: track.rowID, state: .failed(reason: reason), outcome: track.outcomeBefore, message: reason)
        case let .skipped(reason):
            return RowUpdate(rowID: track.rowID, state: .skipped(reason: reason), outcome: track.outcomeBefore, message: reason)
        case .waiting, .queued, .downloading, .done:
            return RowUpdate(rowID: track.rowID, state: .waiting)
        }
    }

    private func results() -> [Result<TrackDownloadOutcome, TrackDownloadError>] {
        entries.compactMap { entry in
            switch entry.status {
            case let .finished(result): result
            case let .removed(saved?): .success(saved)
            default: nil
            }
        }
    }

    // MARK: - Helpers

    private func nextPending() -> Int? {
        entries.firstIndex { if case .pending = $0.status { true } else { false } }
    }

    private func isRunning(_ index: Int) -> Bool {
        if case .running = entries[index].status { return true }
        return false
    }

    private func makeCounter() -> Counter {
        var finished = 0
        var total = 0
        for entry in entries {
            switch entry.status {
            case .finished: finished += 1; total += 1
            case .pending, .running, .returned: total += 1
            case .removed: break
            }
        }
        return Counter(finished: finished, total: total)
    }

    private func emitCounter() {
        emit(.counter(makeCounter()))
    }

    private func emit(_ event: Event) {
        hub.emit(event)
    }

    /// Held while tracks run; released while paused and at every ending.
    private func setAwake(_ awake: Bool) {
        guard awake != isAwake else { return }
        if awake, finalSummary != nil { return }
        isAwake = awake
        if awake {
            keepAwake.preventSleep(reason: options.keepAwakeReason)
        } else {
            keepAwake.allowSleep()
        }
    }

    static func stopReason(for error: TrackDownloadError) -> StopNotice.Reason? {
        switch error {
        case .signInRejected: .signInRejected
        case .subscriptionInactive: .subscriptionInactive
        case let .folderUnavailable(message): .folderUnavailable(message: message)
        case let .diskFull(bytes): .diskFull(bytesNeeded: bytes)
        default: nil
        }
    }

    /// The downloader should throw `TrackDownloadError`; anything else is
    /// read as its nearest kind, so a stray network or sign-in error still
    /// pauses or stops the batch instead of failing every row. Unknown
    /// errors keep only their type name: an error's description can carry
    /// a signed stream link, which must never reach the log.
    static func trackError(from error: any Error) -> TrackDownloadError {
        switch error {
        case let error as TrackDownloadError:
            return error
        case let error as RequestError:
            switch error {
            case .offline: return .offline
            case .busy, .server: return .busy
            // The token keeper has already renewed once and retried (1.8),
            // so a 401 that gets this far is a rejected sign-in (1.6).
            case .unauthorized: return .signInRejected
            // 1.10's honest fallback when TIDAL's refusal isn't recognised.
            case .notFound, .forbidden, .unexpectedStatus: return .notAvailable(reason: "TIDAL refused this stream")
            case .decoding: return .unreadableAudio(detail: error.description)
            }
        case let error as TokenError:
            switch error {
            case .notSignedIn, .signInInvalid: return .signInRejected
            case let .storeUnreadable(storeError): return .writeFailed(detail: storeError.description)
            }
        case let error as URLError where offlineCodes.contains(error.code):
            return .offline
        default:
            return .writeFailed(detail: "Unexpected error (\(type(of: error)))")
        }
    }

    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
    ]

    /// The run's summary, or nil if `limit` passes first.
    private static func value(of task: Task<Summary, Never>, within limit: Duration,
                              clock: any NetworkClock) async -> Summary? {
        let answer = FirstAnswer<Summary?>()
        return await withCheckedContinuation { continuation in
            answer.wait(with: continuation)
            let timer = Task {
                try? await clock.sleep(for: limit)
                answer.give(nil)
            }
            Task {
                let summary = await task.value
                timer.cancel()
                answer.give(summary)
            }
        }
    }
}

extension TrackDownloadError {
    /// TIDAL itself failing: busy past the retries, or temporary errors on
    /// the cover or album lookups outlasting theirs (1.4, 2.15). Several in
    /// a row while the Mac is online stop the batch (2.1).
    var isTIDALFailure: Bool {
        switch self {
        case .busy, .coverUnavailable, .albumDetailsUnavailable: true
        default: false
        }
    }
}

// MARK: - Applying events to the queue

extension Array where Element == QueueItem {
    /// Applies one batch event to the queue: a row's new state and outcome,
    /// or a downloading row's percent. Other events change no row. Rows
    /// already removed from the queue are skipped.
    public mutating func apply(_ event: DownloadBatch.Event) {
        switch event {
        case let .row(update):
            guard let index = firstIndex(where: { $0.id == update.rowID }) else { return }
            update.apply(to: &self[index])
        case let .rowProgress(rowID, percent):
            guard let index = firstIndex(where: { $0.id == rowID }),
                  case .downloading = self[index].state else { return }
            self[index].state = .downloading(percent: percent)
        case let .finished(summary):
            // The returned rows were sent as row events already; applying
            // them again lets a queue that missed events (Quit) catch up.
            for update in summary.returnedRows {
                guard let index = firstIndex(where: { $0.id == update.rowID }) else { continue }
                update.apply(to: &self[index])
            }
        case .started, .rowRemoved, .counter, .waitingForNetwork, .askToResume, .resumed, .stopped:
            return
        }
    }
}

// MARK: - Event delivery

/// Hands events to every subscriber, and lets the downloader's progress
/// callback report straight from its own thread. Progress for an attempt
/// that has ended is dropped under the same lock that orders the events,
/// so a row never shows a percent after its result.
final class EventHub: Sendable {
    private struct State {
        var subscribers: [Int: AsyncStream<DownloadBatch.Event>.Continuation] = [:]
        var nextSubscriber = 0
        var isFinished = false
        var progressToken: Int?
        var progressRow: UUID?
        var lastPercent = 0
        var nextToken = 0
    }

    private let state = Mutex(State())

    func subscribe() -> AsyncStream<DownloadBatch.Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: DownloadBatch.Event.self, bufferingPolicy: .unbounded)
        let id: Int? = state.withLock { s in
            guard !s.isFinished else { return nil }
            let id = s.nextSubscriber
            s.nextSubscriber += 1
            s.subscribers[id] = continuation
            return id
        }
        guard let id else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func emit(_ event: DownloadBatch.Event) {
        state.withLock { s in
            guard !s.isFinished else { return }
            for subscriber in s.subscribers.values { subscriber.yield(event) }
        }
    }

    /// Starts accepting progress for one attempt; the row has just been
    /// shown at 0 %.
    func beginProgress(rowID: UUID) -> Int {
        state.withLock { s in
            s.nextToken += 1
            s.progressToken = s.nextToken
            s.progressRow = rowID
            s.lastPercent = 0
            return s.nextToken
        }
    }

    /// `fraction` 0…1 from the downloader; sent once per whole percent.
    func progress(_ fraction: Double, token: Int) {
        guard fraction.isFinite else { return }
        state.withLock { s in
            guard !s.isFinished, s.progressToken == token, let row = s.progressRow else { return }
            let percent = min(100, max(0, Int((fraction * 100).rounded(.down))))
            guard percent != s.lastPercent else { return }
            s.lastPercent = percent
            for subscriber in s.subscribers.values { subscriber.yield(.rowProgress(rowID: row, percent: percent)) }
        }
    }

    func endProgress(_ token: Int) {
        state.withLock { s in
            if s.progressToken == token {
                s.progressToken = nil
                s.progressRow = nil
            }
        }
    }

    /// Ends every stream. `finish()` runs outside the lock, because it
    /// calls each stream's termination handler, which takes the lock.
    func finish() {
        let subscribers: [AsyncStream<DownloadBatch.Event>.Continuation] = state.withLock { s in
            s.isFinished = true
            s.progressToken = nil
            let all = Array(s.subscribers.values)
            s.subscribers.removeAll()
            return all
        }
        for subscriber in subscribers { subscriber.finish() }
    }
}

/// Resumes a continuation with whichever answer arrives first. `wait(with:)`
/// must be called before anything can answer.
final class FirstAnswer<Value: Sendable>: Sendable {
    private let slot = Mutex<CheckedContinuation<Value, Never>?>(nil)

    func wait(with continuation: CheckedContinuation<Value, Never>) {
        slot.withLock { $0 = continuation }
    }

    func give(_ value: Value) {
        let continuation = slot.withLock { slot -> CheckedContinuation<Value, Never>? in
            defer { slot = nil }
            return slot
        }
        continuation?.resume(returning: value)
    }
}
