import Foundation
import Testing
@testable import RobogearsCore

// What a queue row keeps about its downloads (decision 4, items 2.9, 2.10,
// 2.17): the request a batch copies from it, its outcome across a restart,
// and old saved queues still loading.

@Suite("Queue row downloads")
struct QueueRowDownloadTests {
    private static let folder = URL(fileURLWithPath: "/Volumes/Test SSD/TIDAL", isDirectory: true)

    private static func row(state: QueueItem.DownloadState = .waiting, lastOutcome: TrackDownloadOutcome? = nil) -> QueueItem {
        QueueItem(tidalID: 77_646_169, title: "Blue Lantern", version: "Radio Edit", artist: "Placeholder Artist",
                  album: "Glass Orchard", durationSeconds: 245, isrc: "QZFZ22012345", hiRes: true, source: .spotify,
                  state: state, losslessOnTIDAL: true, lastOutcome: lastOutcome)
    }

    @Test func aDownloadRequestCopiesTheRowAndUsesTheBatchFolder() throws {
        let row = Self.row()
        let request = try #require(row.downloadRequest(folder: Self.folder))
        #expect(request == TrackDownloadRequest(rowID: row.id, tidalID: 77_646_169, title: "Blue Lantern", version: "Radio Edit",
                                                artist: "Placeholder Artist", album: "Glass Orchard", durationSeconds: 245,
                                                isrc: "QZFZ22012345", expectsHiRes: true, losslessOnTIDAL: true,
                                                folder: Self.folder, replaceExisting: false))
        #expect(row.downloadRequest(folder: Self.folder, replaceExisting: true)?.replaceExisting == true)
    }

    @Test func aRowWithoutATIDALTrackHasNothingToDownload() {
        let row = QueueItem(tidalID: nil, title: "Not On TIDAL", artist: "Placeholder Artist", source: .importList, match: .notOnTIDAL)
        #expect(row.downloadRequest(folder: Self.folder) == nil)
        #expect(DownloadBatch.Track(row: row, folder: Self.folder) == nil)
    }

    @Test func aBatchTrackRemembersHowTheRowLookedBefore() throws {
        let reason = "Failed: TIDAL is busy. Try again in a few minutes."
        let track = try #require(DownloadBatch.Track(row: Self.row(state: .failed(reason: reason)), folder: Self.folder))
        #expect(track.stateBefore == .failed(reason: reason))
        #expect(DownloadBatch.putBack(track) == DownloadBatch.RowUpdate(rowID: track.rowID, state: .failed(reason: reason),
                                                                        message: reason))
        let waiting = try #require(DownloadBatch.Track(row: Self.row(), folder: Self.folder))
        #expect(DownloadBatch.putBack(waiting) == DownloadBatch.RowUpdate(rowID: waiting.rowID, state: .waiting))
    }

    @Test func aQueueSavedBeforeDownloadOutcomesExistedStillLoads() throws {
        // Encode a row, then strip the two newer fields, as an older build wrote it.
        let row = Self.row(state: .failed(reason: "Failed: Not available in your country"))
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        object["losslessOnTIDAL"] = nil
        object["lastOutcome"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let loaded = try JSONDecoder().decode(QueueItem.self, from: old)
        #expect(loaded.losslessOnTIDAL == nil)
        #expect(loaded.lastOutcome == nil)
        #expect(loaded.state == .failed(reason: "Failed: Not available in your country"))
        #expect(loaded.title == "Blue Lantern")
    }

    @Test func aRowsOutcomeSurvivesASaveAndReload() throws {
        let outcomes: [TrackDownloadOutcome] = [
            .saved(fileName: "Intro (Second Example).flac", quality: .flac(bitDepth: 24, sampleRate: 96_000),
                   notes: [.savedUnderAnotherName(takenName: "Intro.flac"), .belowHiRes, .savedNextToAAC(aacName: "Intro.m4a")]),
            .saved(fileName: "Paper Harbour.m4a", quality: .aac, notes: [.savedAsAAC, .withoutCoverArt, .limitedTags]),
            .alreadyInFolder(fileName: "Blue Lantern.flac"),
            .existingLooksDamaged(fileName: "Blue Lantern.flac"),
            .nameTakenByUnreadableFile(fileName: "Intro.flac"),
        ]
        for outcome in outcomes {
            let row = Self.row(state: DownloadBatch.rowState(for: outcome), lastOutcome: outcome)
            let reloaded = try JSONDecoder().decode(QueueItem.self, from: JSONEncoder().encode(row.persisted))
            #expect(reloaded == row)
        }
    }

    @Test func inFlightStatesAreSavedAsWaitingAndFailuresKeepTheirReason() {
        #expect(Self.row(state: .queued).persisted.state == .waiting)
        #expect(Self.row(state: .downloading(percent: 60)).persisted.state == .waiting)
        let reason = "Failed: the file is 3:12 but TIDAL lists 4:05. Retry to download it again."
        #expect(Self.row(state: .failed(reason: reason)).persisted.state == .failed(reason: reason))
    }

    @Test func theRowsDownloadLineComesFromItsOutcome() {
        let outcome = TrackDownloadOutcome.saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 24, sampleRate: 96_000), notes: [])
        #expect(Self.row(state: .done(quality: "24-bit / 96 kHz"), lastOutcome: outcome).downloadMessage
                == "Saved Blue Lantern.flac, 24-bit / 96 kHz")
        #expect(Self.row(state: .done(quality: "16-bit / 44.1 kHz")).downloadMessage == "Saved, 16-bit / 44.1 kHz")
        #expect(Self.row(state: .failed(reason: "Failed: TIDAL is busy. Try again in a few minutes.")).downloadMessage
                == "Failed: TIDAL is busy. Try again in a few minutes.")
        #expect(Self.row(state: .queued).downloadMessage == nil)
        #expect(Self.row(state: .downloading(percent: 4)).downloadMessage == nil)
        #expect(Self.row().downloadMessage == nil)
    }

    @Test func progressOnlyMovesARowThatIsDownloading() {
        var queue = [Self.row(state: .downloading(percent: 0)), Self.row(state: .failed(reason: "Failed: x"))]
        queue.apply(.rowProgress(rowID: queue[0].id, percent: 42))
        queue.apply(.rowProgress(rowID: queue[1].id, percent: 42))
        queue.apply(.rowProgress(rowID: UUID(), percent: 42))
        #expect(queue[0].state == .downloading(percent: 42))
        #expect(queue[1].state == .failed(reason: "Failed: x"))
    }
}

@Suite("Keep-awake and network monitor")
struct BatchSystemServiceTests {
    @Test func theKeepAwakeHoldsOneAssertionAndReleasesIt() {
        let preventer = SystemSleepPreventer()
        preventer.preventSleep(reason: "robogears Downloader test")
        #expect(preventer.isPreventingSleep)
        preventer.preventSleep(reason: "robogears Downloader test")
        preventer.allowSleep()
        #expect(!preventer.isPreventingSleep)
        preventer.allowSleep()
        #expect(!preventer.isPreventingSleep)
    }

    @Test func waitingForTheNetworkEndsAtOnceWhenTheWaitIsCancelled() async {
        let monitor = SystemNetworkMonitor()
        let wait = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await monitor.waitUntilOnline()
        }
        await #expect(throws: CancellationError.self) { try await wait.value }
    }
}
