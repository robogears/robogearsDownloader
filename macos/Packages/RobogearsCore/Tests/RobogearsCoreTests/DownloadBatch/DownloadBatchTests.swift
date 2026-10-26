import Foundation
import Synchronization
import Testing
@testable import RobogearsCore

// The batch runner behind Download All, Retry, Retry All and Retry Selected
// (decision 4, area 2 and items 1.6, 1.7, 1.10). Every download here is a
// scripted stand-in: nothing touches the network, TIDAL or a real folder.

private typealias Notice = DownloadBatch.StopNotice
private typealias Counter = DownloadBatch.Counter

private let busyLine = "Failed: TIDAL is busy. Try again in a few minutes."
private let previewLine = "Failed: TIDAL sent only a preview. Check that your TIDAL subscription is active, then Retry."

private func isFailed(_ state: QueueItem.DownloadState?) -> Bool {
    if case .failed = state { return true }
    return false
}

private func isDone(_ state: QueueItem.DownloadState?) -> Bool {
    if case .done = state { return true }
    return false
}

/// Starts the batch and waits until its last event has arrived.
private func runToEnd(_ batch: DownloadBatch, _ log: BatchEventLog) async -> DownloadBatch.Summary {
    let summary = await batch.run()
    await batchEventually { log.summary != nil }
    return summary
}

@Suite("Download batch runner")
struct DownloadBatchTests {
    // MARK: - The run

    @Test func tracksDownloadOneAtATimeInQueueOrder() async {
        let rows = BatchFixtures.rows(4)
        let downloader = BatchScriptedDownloader(Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, [BatchScriptedDownloader.Step.saveAfter(.milliseconds(20))])
        }))
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let summary = await batch.run()
        #expect(downloader.calledRows == rows.map(\.id))
        #expect(downloader.mostAtOnce == 1)
        #expect(summary.counts.downloaded == 4)
        #expect(summary.ending == .finished)
    }

    @Test func theStartChimePlaysOnlyOnceTheBatchHasReallyStarted() async {
        let rows = BatchFixtures.rows(2)
        let sounds = BatchRecordingSounds()
        let batch = BatchFixtures.batch(rows, downloader: BatchScriptedDownloader(), sounds: sounds)
        let log = BatchEventLog.listen(to: batch)
        #expect(sounds.all.isEmpty)
        await batch.start()
        #expect(sounds.all.first == .downloadChime)
        await batchEventually { log.summary != nil }
        #expect(sounds.all == [.downloadChime, .successPing])
        #expect(log.all.first == .started(rowIDs: rows.map(\.id), folder: BatchFixtures.folder))
    }

    @Test func everyRowInTheBatchShowsAsWaitingBeforeTheFirstDownloadStarts() async {
        let rows = BatchFixtures.rows(3)
        let batch = BatchFixtures.batch(rows, downloader: BatchScriptedDownloader())
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        let updates = log.rowUpdates
        let firstDownload = updates.firstIndex { if case .downloading = $0.state { true } else { false } }
        #expect(firstDownload == 3)
        #expect(updates.prefix(3).map(\.state) == [.queued, .queued, .queued])
        #expect(updates.prefix(3).map(\.rowID) == rows.map(\.id))
    }

    @Test func startingTwiceRunsTheBatchOnce() async {
        let rows = BatchFixtures.rows(2)
        let downloader = BatchScriptedDownloader()
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        await batch.start()
        await batch.start()
        _ = await batch.run()
        #expect(downloader.calledRows == rows.map(\.id))
    }

    @Test func aRowListedTwiceDownloadsOnce() async {
        let rows = BatchFixtures.rows(2)
        let downloader = BatchScriptedDownloader()
        let tracks = BatchFixtures.tracks([rows[0], rows[0], rows[1]])
        let batch = DownloadBatch(tracks: tracks, folder: BatchFixtures.folder, downloader: downloader,
                                  network: BatchStandInNetwork(), keepAwake: BatchRecordingKeepAwake(),
                                  clock: BatchGateClock())
        _ = await batch.run()
        #expect(batch.rowIDs == rows.map(\.id))
        #expect(downloader.calledRows == rows.map(\.id))
    }

    @Test func anEmptyBatchEndsAtOnceWithoutASoundOrKeepingTheMacAwake() async {
        let sounds = BatchRecordingSounds()
        let keepAwake = BatchRecordingKeepAwake()
        let batch = BatchFixtures.batch([], downloader: BatchScriptedDownloader(), keepAwake: keepAwake, sounds: sounds)
        let summary = await batch.run()
        #expect(summary.text == "Nothing downloaded.")
        #expect(sounds.all.isEmpty)
        #expect(keepAwake.history.isEmpty)
    }

    @Test func aSubscriberAfterTheEndGetsAStreamThatEndsAtOnce() async {
        let batch = BatchFixtures.batch(BatchFixtures.rows(1), downloader: BatchScriptedDownloader())
        _ = await batch.run()
        var count = 0
        for await _ in batch.events() { count += 1 }
        #expect(count == 0)
    }

    // MARK: - 2.22 counter, 4.12 rows added later

    @Test func retrySelectedCountsOnlyTheRowBeingRetried() async {
        let queue = (1...5).map { BatchFixtures.row("Song \($0)", state: .failed(reason: busyLine)) }
        let batch = BatchFixtures.batch([queue[2]], kind: .retry, downloader: BatchScriptedDownloader())
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        #expect(log.counters.first == Counter(finished: 0, total: 1))
        #expect(log.counters.last == Counter(finished: 1, total: 1))
        #expect(log.counters.allSatisfy { $0.total == 1 })
        #expect(log.counters.last?.text == "1 of 1")
    }

    @Test func theCounterCountsFinishedTracksWhateverTheirResult() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([
            rows[1].id: [.fail(.notAvailable(reason: "Not available in your country"))],
            rows[2].id: [.save(.alreadyInFolder(fileName: "Song 3.flac"))],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        #expect(log.counters.map(\.finished) == [0, 1, 2, 3])
        #expect(await batch.counter == Counter(finished: 3, total: 3))
    }

    @Test func rowsAddedToTheQueueDuringABatchWaitForTheNextDownloadAll() async {
        var queue = BatchFixtures.rows(3)
        let gate = BatchGate()
        let downloader = BatchScriptedDownloader([queue[0].id: [.saveWhenOpened(gate)]])
        let batch = BatchFixtures.batch(queue, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { downloader.active == queue[0].id }
        // Rows pasted mid-batch go into the queue, not into the batch (4.12).
        queue += BatchFixtures.rows(2, prefix: "Pasted")
        gate.set(open: true)
        await batchEventually { log.summary != nil }
        #expect(downloader.calledRows == queue.prefix(3).map(\.id))
        #expect(log.counters.allSatisfy { $0.total == 3 })
        queue.apply(log.all)
        #expect(queue.suffix(2).allSatisfy { $0.state == .waiting && $0.isDownloadable })
    }

    // MARK: - Progress and row lines

    @Test func progressIsReportedOncePerWholePercent() async {
        let rows = BatchFixtures.rows(1)
        let downloader = BatchScriptedDownloader([rows[0].id: [.save(nil, progress: [0.001, 0.004, 0.25, 0.251, 0.5, 0.999, 1.0])]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        #expect(log.progress(for: rows[0].id) == [25, 50, 99, 100])
        let lastProgress = log.all.lastIndex { if case .rowProgress = $0 { true } else { false } }
        let done = log.all.lastIndex { if case let .row(update) = $0, isDone(update.state) { true } else { false } }
        #expect(lastProgress! < done!)
    }

    @Test func aLateProgressReportFromAFinishedTrackNeverReachesTheQueue() async {
        let rows = BatchFixtures.rows(2)
        let downloader = BatchScriptedDownloader([rows[0].id: [.saveKeepingProgress], rows[1].id: [.hang()]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { downloader.active == rows[1].id }
        downloader.keptProgress(for: rows[0].id)?(0.7)
        await batch.cancel()
        await batchEventually { log.summary != nil }
        #expect(log.progress(for: rows[0].id).isEmpty)
        #expect(log.progress(for: rows[1].id).isEmpty)
    }

    @Test func aSavedRowCarriesItsOutcomeAndPlainLine() async {
        let rows = [BatchFixtures.row("Blue Lantern", hiRes: true)]
        let outcome = BatchFixtures.saved("Blue Lantern.flac")
        let downloader = BatchScriptedDownloader([rows[0].id: [.save(outcome)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        let last = log.updates(for: rows[0].id).last
        #expect(last?.state == .done(quality: "24-bit / 96 kHz"))
        #expect(last?.outcome == outcome)
        #expect(last?.message == "Saved Blue Lantern.flac, 24-bit / 96 kHz")
        #expect(downloader.calls.first?.expectsHiRes == true)
    }

    @Test func aDamagedExistingFileLeavesTheRowWithItsLineAndFileName() async {
        let rows = BatchFixtures.rows(1)
        let downloader = BatchScriptedDownloader([rows[0].id: [.save(.existingLooksDamaged(fileName: "Song 1.flac"))]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        var queue = rows
        queue.apply(log.all)
        #expect(queue[0].state == .skipped(reason: "Song 1.flac in your download folder looks damaged"))
        #expect(queue[0].lastOutcome == .existingLooksDamaged(fileName: "Song 1.flac"))
        #expect(queue[0].downloadMessage == "Song 1.flac in your download folder looks damaged")
    }

    @Test func aWriteFailureShowsAPlainLineAndKeepsItsDetailForTheLogOnly() async {
        let rows = BatchFixtures.rows(1)
        let detail = "The volume “Test SSD” returned error 5"
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.writeFailed(detail: detail))]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        let last = log.updates(for: rows[0].id).last
        #expect(last?.state == .failed(reason: "Failed: the file couldn't be saved. Retry to try again."))
        #expect(last?.error == .writeFailed(detail: detail))
        #expect(last?.message?.contains("error 5") == false)
    }

    @Test func eventsAppliedToTheQueueLeaveEachRowInItsFinalState() async {
        var queue = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([
            queue[1].id: [.fail(.notAvailable(reason: "Not available in your country"))],
            queue[2].id: [.save(.alreadyInFolder(fileName: "Song 3.flac"))],
        ])
        let batch = BatchFixtures.batch(queue, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        queue.apply(log.all)
        #expect(queue[0].state == .done(quality: "16-bit / 44.1 kHz"))
        #expect(queue[0].downloadMessage == "Saved Song 1.flac, 16-bit / 44.1 kHz")
        #expect(queue[1].state == .failed(reason: "Failed: Not available in your country"))
        #expect(queue[2].state == .skipped(reason: "Already in your download folder"))
        // Only the real failure is kept as failed across a restart (2.9).
        #expect(queue.map(\.persisted).map(\.state) == queue.map(\.state))
    }

    // MARK: - 2.17 the batch's folder

    @Test func theBatchKeepsTheFolderItStartedWith() async {
        let rows = BatchFixtures.rows(2)
        let elsewhere = URL(fileURLWithPath: "/Volumes/Other/New Folder", isDirectory: true)
        let downloader = BatchScriptedDownloader()
        let tracks = rows.compactMap { DownloadBatch.Track(row: $0, folder: elsewhere) }
        let batch = DownloadBatch(tracks: tracks, folder: BatchFixtures.folder, downloader: downloader,
                                  network: BatchStandInNetwork(), keepAwake: BatchRecordingKeepAwake(),
                                  clock: BatchGateClock())
        let summary = await batch.run()
        #expect(downloader.calls.allSatisfy { $0.folder == BatchFixtures.folder })
        #expect(batch.folder == BatchFixtures.folder)
        #expect(summary.folder == BatchFixtures.folder)
        #expect(batch.inProgressFolderNote
                == "Downloads in progress are saved to “TIDAL”. The new folder is used from the next batch.")
    }

    // MARK: - 2.1, 1.6 stopping once

    @Test func aSignInRejectionOnTheFirstTrackStopsOnceAndPutsEveryRowBackToWaiting() async {
        let rows = BatchFixtures.rows(10)
        let sounds = BatchRecordingSounds()
        let keepAwake = BatchRecordingKeepAwake()
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.signInRejected)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, keepAwake: keepAwake, sounds: sounds)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(downloader.calledRows == [rows[0].id])
        #expect(summary.ending == .stopped(Notice(reason: .signInRejected, unfinished: 10)))
        #expect(log.stopNotices.count == 1)
        #expect(log.stopNotices.first?.fix == .signIn)
        #expect(summary.text == "Downloads stopped: your TIDAL sign-in is no longer valid. 10 tracks are still in your queue.")
        for row in rows { #expect(log.finalStates[row.id] == .waiting) }
        #expect(!log.rowUpdates.contains { isFailed($0.state) })
        #expect(sounds.all == [.downloadChime, .finishedWithProblems])
        #expect(!keepAwake.isHeld)
    }

    @Test func aSignInRejectionAtTrack12KeepsTheSavedRowsAndReturnsTheRest() async {
        let rows = BatchFixtures.rows(300)
        let downloader = BatchScriptedDownloader([rows[11].id: [.fail(.signInRejected)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(downloader.calls.count == 12)
        #expect(summary.counts.downloaded == 11)
        #expect(summary.counts.unfinished == 289)
        #expect(log.stopNotices == [Notice(reason: .signInRejected, unfinished: 289)])
        #expect(summary.text == "Downloads stopped: your TIDAL sign-in is no longer valid. 289 tracks are still in your queue.")
        #expect(rows.prefix(11).allSatisfy { isDone(log.finalStates[$0.id]) })
        #expect(rows.suffix(289).allSatisfy { log.finalStates[$0.id] == .waiting })
        #expect(summary.returnedRows.map(\.rowID) == rows.suffix(289).map(\.id))
    }

    @Test func rowsBeingRetriedReturnToTheirEarlierFailureWhenTheBatchStops() async {
        let reasons = [busyLine, "Failed: Not available in your country", "Failed: the download stopped early. Retry to download it again."]
        var queue = reasons.enumerated().map { BatchFixtures.row("Song \($0.offset)", state: .failed(reason: $0.element)) }
        let damagedLine = "Damaged.flac in your download folder looks damaged"
        let damaged = BatchFixtures.row("Damaged", state: .skipped(reason: damagedLine),
                                        lastOutcome: .existingLooksDamaged(fileName: "Damaged.flac"))
        queue.append(damaged)
        let tracks = queue.prefix(3).compactMap { DownloadBatch.Track(row: $0, folder: BatchFixtures.folder) }
            + [DownloadBatch.Track(row: damaged, folder: BatchFixtures.folder, replaceExisting: true)!]
        let downloader = BatchScriptedDownloader([queue[0].id: [.fail(.signInRejected)]])
        let batch = DownloadBatch(tracks: tracks, folder: BatchFixtures.folder, kind: .retry, downloader: downloader,
                                  network: BatchStandInNetwork(), keepAwake: BatchRecordingKeepAwake(),
                                  clock: BatchGateClock())
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        let before = queue
        queue.apply(log.all)
        #expect(queue == before)
        #expect(queue[3].lastOutcome == .existingLooksDamaged(fileName: "Damaged.flac"))
    }

    @Test func aReplaceRequestAsksTheDownloaderToReplaceTheDamagedFile() async {
        let row = BatchFixtures.row("Damaged", state: .skipped(reason: "Damaged.flac in your download folder looks damaged"),
                                    lastOutcome: .existingLooksDamaged(fileName: "Damaged.flac"))
        let downloader = BatchScriptedDownloader()
        let batch = DownloadBatch(tracks: [DownloadBatch.Track(row: row, folder: BatchFixtures.folder, replaceExisting: true)!],
                                  folder: BatchFixtures.folder, kind: .retry, downloader: downloader,
                                  network: BatchStandInNetwork(), keepAwake: BatchRecordingKeepAwake(), clock: BatchGateClock())
        _ = await batch.run()
        #expect(downloader.calls.first?.replaceExisting == true)
    }

    @Test func anUnavailableFolderMidBatchStopsOnceWithChooseFolder() async {
        let rows = BatchFixtures.rows(5)
        let message = "The download folder “TIDAL” on Test SSD isn't available. Connect the drive or choose another folder."
        let downloader = BatchScriptedDownloader([rows[2].id: [.fail(.folderUnavailable(message: message))]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(log.stopNotices.count == 1)
        #expect(log.stopNotices.first?.fix == .chooseFolder)
        #expect(summary.text == "Downloads stopped: the download folder “TIDAL” on Test SSD isn't available. Connect the drive or choose another folder. 3 tracks are still in your queue.")
        #expect(rows.prefix(2).allSatisfy { isDone(log.finalStates[$0.id]) })
        #expect(rows.suffix(3).allSatisfy { log.finalStates[$0.id] == .waiting })
    }

    @Test func aFullDiskStopsOnceAndSaysHowMuchMoreIsNeeded() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.diskFull(bytesNeeded: 330_000_000))]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(summary.text == "Downloads stopped: the disk with your download folder is full (about 330 MB more needed). 3 tracks are still in your queue. Free up space, then choose Download All.")
        #expect(downloader.calls.count == 1)
    }

    @Test func anInactiveSubscriptionStopsTheBatchOnce() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([rows[1].id: [.fail(.subscriptionInactive)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(summary.ending == .stopped(Notice(reason: .subscriptionInactive, unfinished: 2)))
        #expect(log.finalStates[rows[1].id] == .waiting)
    }

    // MARK: - 2.1, 1.4 TIDAL failing several tracks in a row

    @Test func threeBusyFailuresInARowWhileOnlineStopTheBatch() async {
        let rows = BatchFixtures.rows(6)
        let downloader = BatchScriptedDownloader([
            rows[0].id: [.fail(.busy)], rows[1].id: [.fail(.busy)], rows[2].id: [.fail(.busy)],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(downloader.calls.count == 3)
        #expect(log.stopNotices == [Notice(reason: .tidalFailing(tracksInARow: 3), unfinished: 3)])
        #expect(rows.prefix(3).allSatisfy { log.finalStates[$0.id] == .failed(reason: busyLine) })
        #expect(rows.suffix(3).allSatisfy { log.finalStates[$0.id] == .waiting })
        #expect(summary.counts.failed == 3)
        #expect(summary.sound == .finishedWithProblems)
    }

    @Test func coverAndAlbumLookupsOutlastingTheirRetriesCountAsTIDALFailing() async {
        let rows = BatchFixtures.rows(4)
        let downloader = BatchScriptedDownloader([
            rows[0].id: [.fail(.coverUnavailable)], rows[1].id: [.fail(.albumDetailsUnavailable)], rows[2].id: [.fail(.busy)],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        #expect(log.stopNotices.first?.reason == .tidalFailing(tracksInARow: 3))
    }

    @Test func aSavedTrackBreaksUpARunOfBusyFailures() async {
        let rows = BatchFixtures.rows(6)
        let downloader = BatchScriptedDownloader([
            rows[0].id: [.fail(.busy)], rows[1].id: [.fail(.busy)],
            rows[3].id: [.fail(.busy)], rows[4].id: [.fail(.busy)],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(summary.ending == .finished)
        #expect(summary.counts.failed == 4)
        #expect(downloader.calls.count == 6)
    }

    @Test func aTrackOtherThanBusyBreaksUpARunOfBusyFailures() async {
        let rows = BatchFixtures.rows(5)
        let downloader = BatchScriptedDownloader([
            rows[0].id: [.fail(.busy)], rows[1].id: [.fail(.busy)],
            rows[2].id: [.fail(.notAvailable(reason: "Not available in your country"))],
            rows[3].id: [.fail(.busy)], rows[4].id: [.fail(.busy)],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let summary = await batch.run()
        #expect(summary.ending == .finished)
        #expect(summary.counts.failed == 5)
    }

    @Test func aTrackAlreadyInTheFolderDoesNotHideARunOfBusyFailures() async {
        let rows = BatchFixtures.rows(5)
        let downloader = BatchScriptedDownloader([
            rows[0].id: [.fail(.busy)],
            rows[1].id: [.save(.alreadyInFolder(fileName: "Song 2.flac"))],
            rows[2].id: [.fail(.busy)], rows[3].id: [.fail(.busy)],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        #expect(log.stopNotices.first?.reason == .tidalFailing(tracksInARow: 3))
        #expect(log.finalStates[rows[4].id] == .waiting)
    }

    @Test func busyFailuresOnTheLastTracksEndTheBatchWithASummaryNotANotice() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader(Dictionary(uniqueKeysWithValues: rows.map { ($0.id, [BatchScriptedDownloader.Step.fail(.busy)]) }))
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(log.stopNotices.isEmpty)
        #expect(summary.text == "Nothing downloaded: 3 failed. Most common reason: TIDAL is busy. Try again in a few minutes.")
    }

    // MARK: - 2.23, 1.10 preview clips

    @Test func aPreviewOnTheFirstTrackStopsTheBatchAsASubscriptionProblem() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.previewOnly)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(summary.ending == .stopped(Notice(reason: .previewsOnly, unfinished: 3)))
        #expect(downloader.calls.count == 1)
        #expect(rows.allSatisfy { log.finalStates[$0.id] == .waiting })
    }

    @Test func aPreviewAfterASavedTrackFailsOnlyItsRow() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([rows[1].id: [.fail(.previewOnly)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(summary.ending == .finished)
        #expect(log.finalStates[rows[1].id] == .failed(reason: previewLine))
        #expect(isDone(log.finalStates[rows[2].id]))
        #expect(summary.sound == .finishedWithProblems)
    }

    @Test func rowsAlreadyInTheFolderAtTheStartDoNotHideAPreviewOnTheFirstStream() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([
            rows[0].id: [.save(.alreadyInFolder(fileName: "Song 1.flac"))],
            rows[1].id: [.fail(.previewOnly)],
        ])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        let summary = await runToEnd(batch, log)
        #expect(summary.ending == .stopped(Notice(reason: .previewsOnly, unfinished: 2)))
        #expect(log.finalStates[rows[0].id] == .skipped(reason: "Already in your download folder"))
        #expect(log.finalStates[rows[1].id] == .waiting)
    }

    // MARK: - 1.7 offline

    @Test func goingOfflinePausesThenResumesTheSameTrackWithAFreshCall() async {
        let rows = BatchFixtures.rows(3)
        let network = BatchStandInNetwork(online: false)
        let keepAwake = BatchRecordingKeepAwake()
        let sounds = BatchRecordingSounds()
        let downloader = BatchScriptedDownloader([rows[1].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network, keepAwake: keepAwake, sounds: sounds)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { network.waiting == 1 && log.all.contains(.waitingForNetwork) }
        #expect(log.updates(for: rows[1].id).last?.state == .queued)
        #expect(!log.rowUpdates.contains { isFailed($0.state) })
        #expect(!keepAwake.isHeld)
        #expect(await batch.unfinishedCount == 2)
        network.set(online: true)
        await batchEventually { log.summary != nil }
        #expect(downloader.calledRows == [rows[0].id, rows[1].id, rows[1].id, rows[2].id])
        #expect(log.count { $0 == .resumed } == 1)
        #expect(keepAwake.history == [true, false, true, false])
        #expect(log.summary?.everythingWorked == true)
        #expect(sounds.all == [.downloadChime, .successPing])
    }

    @Test func aNetworkErrorFromTheTIDALClientPausesTooInsteadOfFailing() async {
        let rows = BatchFixtures.rows(1)
        let network = BatchStandInNetwork(online: false)
        // The downloader throws the TIDAL client's own error here.
        let raw = RawErrorDownloader(error: RequestError.offline(detail: "no internet connection"))
        let batch = DownloadBatch(tracks: BatchFixtures.tracks(rows), folder: BatchFixtures.folder, downloader: raw,
                                  network: network, keepAwake: BatchRecordingKeepAwake(), clock: BatchGateClock())
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { log.all.contains(.waitingForNetwork) }
        #expect(!log.rowUpdates.contains { isFailed($0.state) })
        network.set(online: true)
        await batchEventually { log.summary != nil }
        #expect(log.summary?.counts.downloaded == 1)
    }

    @Test func aBusyTIDALWhileTheMacIsOfflineIsTheConnectionSoTheBatchPauses() async {
        let rows = BatchFixtures.rows(2)
        let network = BatchStandInNetwork(online: false)
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.busy)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { log.all.contains(.waitingForNetwork) }
        #expect(!log.rowUpdates.contains { isFailed($0.state) })
        network.set(online: true)
        await batchEventually { log.summary != nil }
        // The busy track was tried again once the connection came back.
        #expect(downloader.calledRows == [rows[0].id, rows[0].id, rows[1].id])
        #expect(log.summary?.counts.failed == 0)
        #expect(log.stopNotices.isEmpty)
    }

    @Test func anOfflineErrorWhileTheMacHasAConnectionLooksAgainAfterAGrowingWait() async {
        let rows = BatchFixtures.rows(1)
        let clock = BatchGateClock()
        let keepAwake = BatchRecordingKeepAwake()
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline), .fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, keepAwake: keepAwake, clock: clock)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { clock.sleeping == 1 }
        #expect(clock.sleeps == [.seconds(10)])
        #expect(!keepAwake.isHeld)
        clock.fire()
        await batchEventually { clock.sleeping == 1 && clock.sleeps.count == 2 }
        #expect(clock.sleeps == [.seconds(10), .seconds(20)])
        clock.fire()
        await batchEventually { log.summary != nil }
        #expect(downloader.calls.count == 3)
        #expect(log.count { $0 == .waitingForNetwork } == 2)
        #expect(log.summary?.counts.downloaded == 1)
    }

    @Test func onAMeteredNetworkThePausedBatchAsksBeforeResuming() async {
        let rows = BatchFixtures.rows(2)
        let network = BatchStandInNetwork(online: false, metered: true)
        let keepAwake = BatchRecordingKeepAwake()
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network, keepAwake: keepAwake)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { log.all.contains(.waitingForNetwork) }
        network.set(online: true)
        await batchEventually { log.all.contains(.askToResume) }
        #expect(!log.all.contains(.resumed))
        #expect(!keepAwake.isHeld)
        await batch.resumeOnThisNetwork()
        await batchEventually { log.summary != nil }
        #expect(log.summary?.counts.downloaded == 2)
        #expect(keepAwake.history == [true, false, true, false])
    }

    @Test func cancellingTheMeteredQuestionPutsTheRowsBack() async {
        let rows = BatchFixtures.rows(2)
        let network = BatchStandInNetwork(online: false, metered: true)
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { log.all.contains(.waitingForNetwork) }
        network.set(online: true)
        await batchEventually { log.all.contains(.askToResume) }
        await batch.cancel()
        await batchEventually { log.summary != nil }
        #expect(log.summary?.ending == .cancelled)
        #expect(rows.allSatisfy { log.finalStates[$0.id] == .waiting })
        #expect(downloader.calls.count == 1)
    }

    @Test func withTheQuestionTurnedOffAMeteredNetworkResumesAtOnce() async {
        let rows = BatchFixtures.rows(1)
        let network = BatchStandInNetwork(online: false, metered: true)
        var options = DownloadBatch.Options()
        options.askBeforeResumingOnMeteredNetwork = false
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network, options: options)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { log.all.contains(.waitingForNetwork) }
        network.set(online: true)
        await batchEventually { log.summary != nil }
        #expect(!log.all.contains(.askToResume))
        #expect(log.summary?.counts.downloaded == 1)
    }

    // MARK: - 2.4 Cancel

    @Test func cancelStopsTheTrackAtOnceAndPutsUnfinishedRowsBackWithoutFailingThem() async {
        let rows = BatchFixtures.rows(5)
        let sounds = BatchRecordingSounds()
        let keepAwake = BatchRecordingKeepAwake()
        let downloader = BatchScriptedDownloader([rows[1].id: [.hang(progress: [0.6])]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, keepAwake: keepAwake, sounds: sounds)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { log.progress(for: rows[1].id) == [60] }
        let clock = ContinuousClock()
        let pressed = clock.now
        await batch.cancel()
        await batchEventually { log.summary != nil }
        #expect(clock.now - pressed < .seconds(1))
        let summary = log.summary
        #expect(summary?.ending == .cancelled)
        #expect(summary?.text == "Cancelled: 1 downloaded, 4 still in your queue.")
        #expect(downloader.cleanedUp == [rows[1].id])
        #expect(downloader.calledRows == [rows[0].id, rows[1].id])
        #expect(isDone(log.finalStates[rows[0].id]))
        #expect(rows.dropFirst().allSatisfy { log.finalStates[$0.id] == .waiting })
        #expect(!log.rowUpdates.contains { isFailed($0.state) })
        #expect(sounds.all == [.downloadChime, .cancelChime])
        #expect(!keepAwake.isHeld)
    }

    @Test func cancelWhileWaitingForTheNetworkEndsThePause() async {
        let rows = BatchFixtures.rows(3)
        let network = BatchStandInNetwork(online: false)
        let sounds = BatchRecordingSounds()
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network, sounds: sounds)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { network.waiting == 1 }
        await batch.cancel()
        await batchEventually { log.summary != nil }
        #expect(network.waiting == 0)
        #expect(log.summary?.ending == .cancelled)
        #expect(rows.allSatisfy { log.finalStates[$0.id] == .waiting })
        #expect(sounds.all == [.downloadChime, .cancelChime])
    }

    @Test func aTrackThatIgnoresCancelCannotHoldTheBatchPastItsTimeLimit() async {
        let rows = BatchFixtures.rows(2)
        let clock = BatchGateClock()
        let stuck = BatchGate(honoursCancel: false)
        let downloader = BatchScriptedDownloader([rows[0].id: [.stuck(stuck)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, clock: clock)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { downloader.active == rows[0].id }
        await batch.cancel()
        await batchEventually { clock.sleeping == 1 }
        #expect(clock.sleeps == [.seconds(1)])
        #expect(log.summary == nil)
        clock.fire()
        await batchEventually { log.summary != nil }
        #expect(log.summary?.ending == .cancelled)
        #expect(rows.allSatisfy { log.finalStates[$0.id] == .waiting })
        #expect(await batch.unfinishedCount == 0)
        // The track gives up later; nothing more reaches the queue.
        let eventsAtEnd = log.all.count
        stuck.set(open: true)
        await batchEventually { downloader.cleanedUp == [rows[0].id] }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(log.all.count == eventsAtEnd)
        #expect(downloader.calls.count == 1)
    }

    @Test func aTrackSavedJustBeforeCancelReachedItStaysDone() async {
        let rows = BatchFixtures.rows(2)
        let downloader = BatchScriptedDownloader([rows[0].id: [.saveDespiteCancel]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { downloader.active == rows[0].id }
        await batch.cancel()
        await batchEventually { log.summary != nil }
        #expect(isDone(log.finalStates[rows[0].id]))
        #expect(log.finalStates[rows[1].id] == .waiting)
        #expect(log.summary?.counts.downloaded == 1)
    }

    @Test func cancelBeforeTheBatchStartsPlaysNothing() async {
        let sounds = BatchRecordingSounds()
        let downloader = BatchScriptedDownloader()
        let batch = BatchFixtures.batch(BatchFixtures.rows(2), downloader: downloader, sounds: sounds)
        await batch.cancel()
        let summary = await batch.run()
        #expect(summary.ending == .cancelled)
        #expect(sounds.all.isEmpty)
        #expect(downloader.calls.isEmpty)
    }

    // MARK: - 2.13 removing rows

    @Test func removingAWaitingRowTakesItOutOfTheBatchAndShrinksTheCounter() async {
        let rows = BatchFixtures.rows(4)
        let gate = BatchGate()
        let downloader = BatchScriptedDownloader([rows[0].id: [.saveWhenOpened(gate)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { downloader.active == rows[0].id }
        await batch.remove(rows[2].id)
        #expect(await batch.counter == Counter(finished: 0, total: 3))
        gate.set(open: true)
        await batchEventually { log.summary != nil }
        #expect(downloader.calledRows == [rows[0].id, rows[1].id, rows[3].id])
        #expect(log.all.contains(.rowRemoved(rows[2].id)))
        #expect(log.counters.last == Counter(finished: 3, total: 3))
        #expect(log.summary?.counts.downloaded == 3)
        #expect(log.summary?.everythingWorked == true)
    }

    @Test func removingTheDownloadingRowStopsItAndTheBatchMovesOn() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader([rows[1].id: [.hang()]])
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { downloader.active == rows[1].id }
        await batch.remove(rows[1].id)
        await batchEventually { log.summary != nil }
        #expect(downloader.cleanedUp == [rows[1].id])
        #expect(downloader.calledRows == rows.map(\.id))
        #expect(!log.updates(for: rows[1].id).contains { isFailed($0.state) })
        #expect(log.counters.last == Counter(finished: 2, total: 2))
        #expect(log.summary?.ending == .finished)
        #expect(log.summary?.counts.downloaded == 2)
    }

    @Test func removingThePausedRowWithNothingAfterItEndsTheWait() async {
        let rows = BatchFixtures.rows(1)
        let network = BatchStandInNetwork(online: false)
        let keepAwake = BatchRecordingKeepAwake()
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network, keepAwake: keepAwake)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        await batchEventually { network.waiting == 1 }
        await batch.remove(rows[0].id)
        await batchEventually { log.summary != nil }
        #expect(network.waiting == 0)
        #expect(log.summary?.text == "Nothing downloaded.")
        #expect(downloader.calls.count == 1)
        #expect(!keepAwake.isHeld)
    }

    @Test func aRowRemovedBeforeTheStartIsNeverShownAsWaiting() async {
        let rows = BatchFixtures.rows(3)
        let downloader = BatchScriptedDownloader()
        let batch = BatchFixtures.batch(rows, downloader: downloader)
        let log = BatchEventLog.listen(to: batch)
        await batch.remove(rows[1].id)
        _ = await runToEnd(batch, log)
        #expect(log.updates(for: rows[1].id).isEmpty)
        #expect(log.all.contains(.started(rowIDs: [rows[0].id, rows[2].id], folder: BatchFixtures.folder)))
        #expect(downloader.calledRows == [rows[0].id, rows[2].id])
        #expect(log.counters.allSatisfy { $0.total == 2 })
    }

    @Test func removingAFinishedRowChangesNothing() async {
        let rows = BatchFixtures.rows(2)
        let batch = BatchFixtures.batch(rows, downloader: BatchScriptedDownloader())
        let log = BatchEventLog.listen(to: batch)
        _ = await runToEnd(batch, log)
        await batch.remove(rows[0].id)
        #expect(!log.all.contains(.rowRemoved(rows[0].id)))
    }

    // MARK: - 2.5 Quit

    @Test func quittingWaitsForTheTrackToCleanUpAndReturnsEveryRowsFinalState() async {
        let rows = BatchFixtures.rows(5)
        let sounds = BatchRecordingSounds()
        let keepAwake = BatchRecordingKeepAwake()
        let downloader = BatchScriptedDownloader([rows[1].id: [.hang()]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, keepAwake: keepAwake, sounds: sounds)
        await batch.start()
        await batchEventually { downloader.active == rows[1].id }
        #expect(await batch.unfinishedCount == 4)
        #expect(DownloadBatch.quitQuestion(unfinished: await batch.unfinishedCount)?.title
                == "Quit while 4 tracks are still downloading?")
        let summary = await batch.stopForQuit()
        // The temporary file is gone before Quit returns.
        #expect(downloader.cleanedUp == [rows[1].id])
        #expect(summary.ending == .quit)
        #expect(summary.returnedRows.map(\.rowID) == rows.dropFirst().map(\.id))
        #expect(summary.returnedRows.allSatisfy { $0.state == .waiting })
        #expect(sounds.all == [.downloadChime])
        #expect(!keepAwake.isHeld)
        #expect(await batch.unfinishedCount == 0)
        // A queue that missed the events still catches up from the summary.
        var queue = rows
        queue.apply(.finished(summary))
        #expect(queue.dropFirst().allSatisfy { $0.state == .waiting })
    }

    @Test func quittingWhileWaitingForTheNetworkEndsThePause() async {
        let rows = BatchFixtures.rows(2)
        let network = BatchStandInNetwork(online: false)
        let downloader = BatchScriptedDownloader([rows[0].id: [.fail(.offline)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network)
        await batch.start()
        await batchEventually { network.waiting == 1 }
        let summary = await batch.stopForQuit()
        #expect(summary.ending == .quit)
        #expect(network.waiting == 0)
        #expect(summary.returnedRows.map(\.rowID) == rows.map(\.id))
    }

    @Test func quittingNeverWaitsLongerThanItsTimeLimit() async {
        let rows = BatchFixtures.rows(2)
        let clock = BatchGateClock()
        let stuck = BatchGate(honoursCancel: false)
        let downloader = BatchScriptedDownloader([rows[0].id: [.stuck(stuck)]])
        let batch = BatchFixtures.batch(rows, downloader: downloader, clock: clock)
        await batch.start()
        await batchEventually { downloader.active == rows[0].id }
        let quitting = Task { await batch.stopForQuit() }
        await batchEventually { clock.sleeping == 1 }
        #expect(clock.sleeps == [.seconds(5)])
        clock.fire()
        let summary = await quitting.value
        #expect(summary.ending == .quit)
        #expect(summary.returnedRows.map(\.rowID) == rows.map(\.id))
        stuck.set(open: true)
        await batchEventually { downloader.cleanedUp == [rows[0].id] }
    }

    @Test func quittingBeforeTheBatchStartsReturnsAtOnceWithoutASound() async {
        let sounds = BatchRecordingSounds()
        let keepAwake = BatchRecordingKeepAwake()
        let rows = BatchFixtures.rows(2)
        let batch = BatchFixtures.batch(rows, downloader: BatchScriptedDownloader(), keepAwake: keepAwake, sounds: sounds)
        let summary = await batch.stopForQuit()
        #expect(summary.ending == .quit)
        #expect(sounds.all.isEmpty)
        #expect(keepAwake.history.isEmpty)
        #expect(await batch.stopForQuit() == summary)
    }

    // MARK: - 2.12 keep-awake

    enum Ending: String, CaseIterable, Sendable {
        case finished, stopped, cancelled, quit, removedWhilePaused
    }

    @Test(arguments: Ending.allCases)
    func theKeepAwakeIsReleasedInEveryEnding(_ ending: Ending) async {
        let rows = BatchFixtures.rows(3)
        let keepAwake = BatchRecordingKeepAwake()
        let network = BatchStandInNetwork(online: ending != .removedWhilePaused)
        var script: [UUID: [BatchScriptedDownloader.Step]] = [:]
        switch ending {
        case .finished: break
        case .stopped: script[rows[1].id] = [.fail(.signInRejected)]
        case .cancelled, .quit: script[rows[1].id] = [.hang()]
        case .removedWhilePaused: script[rows[2].id] = [.fail(.offline)]
        }
        let downloader = BatchScriptedDownloader(script)
        let batch = BatchFixtures.batch(rows, downloader: downloader, network: network, keepAwake: keepAwake)
        let log = BatchEventLog.listen(to: batch)
        await batch.start()
        switch ending {
        case .finished, .stopped:
            break
        case .cancelled:
            await batchEventually { downloader.active == rows[1].id }
            await batch.cancel()
        case .quit:
            await batchEventually { downloader.active == rows[1].id }
            _ = await batch.stopForQuit()
        case .removedWhilePaused:
            await batchEventually { network.waiting == 1 }
            #expect(!keepAwake.isHeld)
            await batch.remove(rows[2].id)
        }
        await batchEventually { log.summary != nil }
        #expect(!keepAwake.isHeld)
        #expect(keepAwake.history.first == true)
        #expect(keepAwake.history.last == false)
        #expect(Set(keepAwake.reasons) == ["robogears Downloader is downloading tracks"])
    }

    // MARK: - Errors that aren't download errors

    @Test func errorsFromOtherLayersAreReadAsTheirNearestKind() {
        #expect(DownloadBatch.trackError(from: RequestError.offline(detail: "no internet connection")) == .offline)
        #expect(DownloadBatch.trackError(from: RequestError.busy(retryAfter: nil)) == .busy)
        #expect(DownloadBatch.trackError(from: RequestError.server(status: 503)) == .busy)
        #expect(DownloadBatch.trackError(from: RequestError.unauthorized(subStatus: 11003)) == .signInRejected)
        #expect(DownloadBatch.trackError(from: RequestError.forbidden(subStatus: 4005)) == .notAvailable(reason: "TIDAL refused this stream"))
        #expect(DownloadBatch.trackError(from: RequestError.notFound(subStatus: nil)) == .notAvailable(reason: "TIDAL refused this stream"))
        #expect(DownloadBatch.trackError(from: TokenError.signInInvalid) == .signInRejected)
        #expect(DownloadBatch.trackError(from: TokenError.notSignedIn) == .signInRejected)
        #expect(DownloadBatch.trackError(from: URLError(.notConnectedToInternet)) == .offline)
        #expect(DownloadBatch.trackError(from: TrackDownloadError.previewOnly) == .previewOnly)
    }

    @Test func anUnknownErrorNeverCarriesItsTextIntoTheLog() {
        let secret = BatchOtherError(description: "GET https://audio.example/track.flac?token=SIGNED-SECRET failed")
        let mapped = DownloadBatch.trackError(from: secret)
        #expect(mapped == .writeFailed(detail: "Unexpected error (BatchOtherError)"))
        #expect(!"\(mapped)".contains("SIGNED-SECRET"))
    }

    @Test func aSignInRejectionFromTheTokenKeeperStopsTheBatchToo() async {
        let rows = BatchFixtures.rows(3)
        let raw = RawErrorDownloader(error: TokenError.signInInvalid)
        let batch = DownloadBatch(tracks: BatchFixtures.tracks(rows), folder: BatchFixtures.folder, downloader: raw,
                                  network: BatchStandInNetwork(), keepAwake: BatchRecordingKeepAwake(), clock: BatchGateClock())
        let summary = await batch.run()
        #expect(summary.ending == .stopped(Notice(reason: .signInRejected, unfinished: 3)))
    }
}

/// Throws one error once, then saves: for errors that come from the TIDAL
/// client or the token keeper rather than the track pipeline.
private final class RawErrorDownloader: TrackDownloading {
    private let error: any Error
    private let calls = Mutex(0)

    init(error: any Error) {
        self.error = error
    }

    func download(_ request: TrackDownloadRequest,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> TrackDownloadOutcome {
        let call = calls.withLock { count -> Int in
            count += 1
            return count
        }
        if call == 1 { throw error }
        return BatchScriptedDownloader.defaultOutcome(for: request)
    }
}
