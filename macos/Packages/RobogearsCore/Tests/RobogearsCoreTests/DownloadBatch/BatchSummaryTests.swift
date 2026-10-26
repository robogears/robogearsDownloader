import Foundation
import Testing
@testable import RobogearsCore

// The words and sounds a batch ends with (decision 4, items 2.1, 2.5, 2.8,
// 2.9, 2.12, 2.17): all pure functions, so no download runs here.

private typealias Summary = DownloadBatch.Summary
private typealias Notice = DownloadBatch.StopNotice

private let folder = BatchFixtures.folder

private func saved(_ name: String = "Blue Lantern.flac", _ quality: SavedQuality = .flac(bitDepth: 24, sampleRate: 96_000),
                   notes: [SaveNote] = []) -> Result<TrackDownloadOutcome, TrackDownloadError> {
    .success(.saved(fileName: name, quality: quality, notes: notes))
}

private let already: Result<TrackDownloadOutcome, TrackDownloadError> = .success(.alreadyInFolder(fileName: "Paper Harbour.flac"))

private func failed(_ error: TrackDownloadError) -> Result<TrackDownloadOutcome, TrackDownloadError> {
    .failure(error)
}

private func summary(_ results: [Result<TrackDownloadOutcome, TrackDownloadError>],
                     ending: Summary.Ending = .finished, unfinished: Int = 0) -> Summary {
    Summary(kind: .downloadAll, folder: folder, ending: ending, results: results, unfinished: unfinished)
}

@Suite("Batch summary and endings")
struct BatchSummaryTests {
    // MARK: 2.8 endings

    @Test func everythingWorkingPlaysTheSuccessPingAndSaysDone() {
        let s = summary(Array(repeating: saved(), count: 12) + [already, already])
        #expect(s.text == "Done: 12 downloaded, 2 already in your folder.")
        #expect(s.sound == .successPing)
        #expect(s.everythingWorked)
        #expect(s.isComplete)
        #expect(s.notificationText == "Downloaded 12 tracks.")
    }

    @Test func aFailedTrackSwapsThePingForTheQuieterSoundAndCountsTheFailure() {
        let s = summary(Array(repeating: saved(), count: 12) + [already, already, failed(.busy)])
        #expect(s.text == "12 downloaded, 2 already in your folder, 1 failed.")
        #expect(s.sound == .finishedWithProblems)
        #expect(!s.everythingWorked)
        #expect(s.notificationText == "Downloaded 12 tracks. 1 failed.")
    }

    @Test func nothingDownloadedSaysSoWithTheMostCommonReason() {
        let s = summary(Array(repeating: failed(.busy), count: 10)
                        + Array(repeating: failed(.notAvailable(reason: "Not available in your country")), count: 5))
        #expect(s.text == "Nothing downloaded: 15 failed. Most common reason: TIDAL is busy. Try again in a few minutes.")
        #expect(s.sound == .finishedWithProblems)
        #expect(s.mostCommonFailure == "TIDAL is busy. Try again in a few minutes.")
        #expect(s.notificationText == "Nothing downloaded: 15 failed.")
    }

    @Test func aReasonWithoutAFullStopGetsOneInTheSummary() {
        let s = summary([failed(.notAvailable(reason: "Not available in your country"))])
        #expect(s.text == "Nothing downloaded: 1 failed. Most common reason: Not available in your country.")
    }

    @Test func tiedReasonsNameTheOneSeenFirst() {
        let s = summary([failed(.coverUnavailable), failed(.busy), failed(.busy), failed(.coverUnavailable)])
        #expect(s.mostCommonFailure == "TIDAL didn't send the cover art. Retry to try again.")
    }

    @Test func onlyTracksAlreadyInTheFolderStillCountAsDone() {
        let s = summary([already, already])
        #expect(s.text == "Done: 2 already in your folder.")
        #expect(s.sound == .successPing)
        #expect(s.notificationText == "All 2 tracks were already in your download folder.")
        #expect(summary([already]).notificationText == "The track was already in your download folder.")
    }

    @Test func aBatchWhoseRowsAllLeftEndsQuietlyWithNothingDownloaded() {
        let s = summary([])
        #expect(s.text == "Nothing downloaded.")
        #expect(s.sound == nil)
        #expect(s.notificationText == nil)
    }

    @Test func aStoppedBatchPlaysTheQuietSoundBesideItsNotice() {
        let notice = Notice(reason: .signInRejected, unfinished: 288)
        let s = summary(Array(repeating: saved(), count: 11) + [failed(.busy)], ending: .stopped(notice), unfinished: 288)
        #expect(s.sound == .finishedWithProblems)
        #expect(s.text == notice.text)
        #expect(s.notificationText == notice.text)
        #expect(!s.isComplete)
    }

    @Test func aCancelledBatchHasNoEndingSoundBecauseTheCancelChimeAlreadyPlayed() {
        let s = summary([saved(), saved(), saved()], ending: .cancelled, unfinished: 37)
        #expect(s.sound == nil)
        #expect(s.text == "Cancelled: 3 downloaded, 37 still in your queue.")
        #expect(s.notificationText == nil)
        #expect(!s.isComplete)
    }

    @Test func quittingHasNoSoundAndNoNotification() {
        let s = summary([saved()], ending: .quit, unfinished: 12)
        #expect(s.sound == nil)
        #expect(s.notificationText == nil)
        #expect(!s.isComplete)
    }

    @Test func oneDownloadedTrackIsSingularInTheNotification() {
        #expect(summary([saved()]).notificationText == "Downloaded 1 track.")
        #expect(summary([saved(), failed(.busy), failed(.busy)]).notificationText == "Downloaded 1 track. 2 failed.")
    }

    @Test func existingFilesThatNeedAChoiceAreNotASuccess() {
        let damaged: Result<TrackDownloadOutcome, TrackDownloadError> = .success(.existingLooksDamaged(fileName: "Blue Lantern.flac"))
        let untagged: Result<TrackDownloadOutcome, TrackDownloadError> = .success(.nameTakenByUnreadableFile(fileName: "Intro.flac"))
        let one = summary([damaged])
        #expect(one.text == "Nothing downloaded: 1 looks damaged in your folder.")
        #expect(one.sound == .finishedWithProblems)
        #expect(one.notificationText == "1 track needs your attention.")
        let more = summary([saved(), damaged, damaged, untagged])
        #expect(more.text == "1 downloaded, 2 look damaged in your folder, 1 not saved: name already taken.")
        #expect(more.notificationText == "Downloaded 1 track. 3 tracks need your attention.")
        #expect(more.counts.needsAttention == 3)
    }

    // MARK: 2.8 notes on saved files

    @Test func theSummaryCountsWhatSavedFilesCarry() {
        let s = summary([
            saved("Paper Harbour.m4a", .aac, notes: [.savedAsAAC]),
            saved("Intro (Second Example).flac", notes: [.savedUnderAnotherName(takenName: "Intro.flac")]),
            saved(notes: [.withoutCoverArt]),
            saved(notes: [.limitedTags]),
            saved("Copper Sky.flac", .flac(bitDepth: 16, sampleRate: 44_100), notes: [.belowHiRes]),
            saved("Paper Harbour.flac", notes: [.savedNextToAAC(aacName: "Paper Harbour.m4a")]),
        ])
        #expect(s.counts.savedAsAAC == 1)
        #expect(s.counts.savedUnderAnotherName == 1)
        #expect(s.counts.withoutCoverArt == 1)
        #expect(s.counts.limitedTags == 1)
        #expect(s.counts.belowHiRes == 1)
        #expect(s.counts.savedNextToAAC == 1)
        #expect(s.text == "Done: 6 downloaded. 1 saved as AAC, 1 saved under another name, 1 without cover art, 1 with limited tags, 1 below Hi-Res.")
    }

    @Test func anAACFileCountsOnceEvenWhenItsQualityAndNoteBothSaySo() {
        let s = summary([saved("Paper Harbour.m4a", .aac, notes: [.savedAsAAC, .savedAsAAC]), saved("Copper Sky.m4a", .aac)])
        #expect(s.counts.savedAsAAC == 2)
        #expect(s.text == "Done: 2 downloaded. 2 saved as AAC.")
    }

    @Test func notesAreListedAfterFailuresToo() {
        let s = summary([saved(notes: [.withoutCoverArt]), failed(.busy)])
        #expect(s.text == "1 downloaded, 1 failed. 1 without cover art.")
    }

    // MARK: 2.1 stop notice

    @Test func theSignInNoticeSaysHowManyTracksAreStillInTheQueueAndOffersSignIn() {
        let notice = Notice(reason: .signInRejected, unfinished: 288)
        #expect(notice.text == "Downloads stopped: your TIDAL sign-in is no longer valid. 288 tracks are still in your queue.")
        #expect(notice.fix == .signIn)
        #expect(Notice(reason: .signInRejected, unfinished: 1).text
                == "Downloads stopped: your TIDAL sign-in is no longer valid. 1 track is still in your queue.")
    }

    @Test func eachStoppingProblemHasItsOwnNotice() {
        #expect(Notice(reason: .subscriptionInactive, unfinished: 40).text
                == "Downloads stopped: your TIDAL subscription isn't active. Downloads need a TIDAL plan with lossless streaming. 40 tracks are still in your queue.")
        #expect(Notice(reason: .previewsOnly, unfinished: 40).text
                == "Downloads stopped: TIDAL sent only a preview instead of the full track. 40 tracks are still in your queue. Check that your TIDAL subscription is active, then choose Download All.")
        #expect(Notice(reason: .diskFull(bytesNeeded: 329_500_000), unfinished: 40).text
                == "Downloads stopped: the disk with your download folder is full (about 330 MB more needed). 40 tracks are still in your queue. Free up space, then choose Download All.")
        #expect(Notice(reason: .tidalFailing(tracksInARow: 3), unfinished: 40).text
                == "Downloads stopped: TIDAL couldn't send 3 tracks in a row. 40 tracks are still in your queue. Try Download All again in a few minutes.")
        let folderNotice = Notice(reason: .folderUnavailable(message: "The download folder “TIDAL” on Music SSD isn't available. Connect the drive or choose another folder."),
                                  unfinished: 40)
        #expect(folderNotice.text
                == "Downloads stopped: the download folder “TIDAL” on Music SSD isn't available. Connect the drive or choose another folder. 40 tracks are still in your queue.")
        #expect(folderNotice.fix == .chooseFolder)
        #expect(Notice(reason: .diskFull(bytesNeeded: 1), unfinished: 0).fix == nil)
    }

    @Test func aNoticeWithNothingLeftDoesNotCountZeroTracks() {
        #expect(Notice(reason: .signInRejected, unfinished: 0).text == "Downloads stopped: your TIDAL sign-in is no longer valid.")
    }

    // MARK: 2.9 row lines

    @Test func aSavedRowNamesItsFileAndQuality() {
        let outcome = TrackDownloadOutcome.saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 24, sampleRate: 96_000), notes: [])
        #expect(DownloadBatch.message(for: outcome) == "Saved Blue Lantern.flac, 24-bit / 96 kHz")
        #expect(DownloadBatch.rowState(for: outcome) == .done(quality: "24-bit / 96 kHz"))
        let cd = TrackDownloadOutcome.saved(fileName: "Copper Sky.flac", quality: .flac(bitDepth: 16, sampleRate: 44_100), notes: [])
        #expect(DownloadBatch.message(for: cd) == "Saved Copper Sky.flac, 16-bit / 44.1 kHz")
    }

    @Test func aSecondSongCalledIntroSaysWhichNameItGotAndWhy() {
        let outcome = TrackDownloadOutcome.saved(fileName: "Intro (Second Example).flac", quality: .flac(bitDepth: 16, sampleRate: 44_100),
                                                 notes: [.savedUnderAnotherName(takenName: "Intro.flac")])
        #expect(DownloadBatch.message(for: outcome) == "Saved as Intro (Second Example).flac — another song is already named Intro")
    }

    @Test func anAACRowSaysTIDALHasNoLosslessVersion() {
        let outcome = TrackDownloadOutcome.saved(fileName: "Paper Harbour.m4a", quality: .aac, notes: [.savedAsAAC])
        #expect(DownloadBatch.message(for: outcome) == "Saved as AAC (.m4a): TIDAL has no lossless version")
        #expect(DownloadBatch.rowState(for: outcome) == .done(quality: "AAC"))
        let clash = TrackDownloadOutcome.saved(fileName: "Intro (Second Example).m4a", quality: .aac,
                                               notes: [.savedAsAAC, .savedUnderAnotherName(takenName: "Intro.m4a")])
        #expect(DownloadBatch.message(for: clash)
                == "Saved as Intro (Second Example).m4a — another song is already named Intro. AAC (.m4a): TIDAL has no lossless version")
    }

    @Test func notesOnASavedRowFollowAsShortSentences() {
        let outcome = TrackDownloadOutcome.saved(fileName: "Paper Harbour.flac", quality: .flac(bitDepth: 16, sampleRate: 44_100),
                                                 notes: [.withoutCoverArt, .limitedTags, .belowHiRes,
                                                         .savedNextToAAC(aacName: "Paper Harbour.m4a")])
        #expect(DownloadBatch.message(for: outcome)
                == "Saved Paper Harbour.flac, 16-bit / 44.1 kHz. Without cover art: TIDAL has none for this album. With limited tags: TIDAL has no details for this album. Below Hi-Res: TIDAL had only 16-bit / 44.1 kHz. The older Paper Harbour.m4a is still in your download folder")
    }

    @Test func rowsThatDidNotDownloadSayWhyAndAreSkippedNotDone() {
        let cases: [(TrackDownloadOutcome, String)] = [
            (.alreadyInFolder(fileName: "Blue Lantern.flac"), "Already in your download folder"),
            (.existingLooksDamaged(fileName: "Blue Lantern.flac"), "Blue Lantern.flac in your download folder looks damaged"),
            (.nameTakenByUnreadableFile(fileName: "Intro.flac"), "Not downloaded: Intro.flac already exists and can't be identified"),
        ]
        for (outcome, line) in cases {
            #expect(DownloadBatch.message(for: outcome) == line)
            #expect(DownloadBatch.rowState(for: outcome) == .skipped(reason: line))
        }
    }

    @Test func theClashSentenceNamesTheSongNotItsExtension() {
        #expect(DownloadBatch.titlePart(of: "Intro.flac") == "Intro")
        #expect(DownloadBatch.titlePart(of: "Intro.M4A") == "Intro")
        #expect(DownloadBatch.titlePart(of: "Intro") == "Intro")
        #expect(DownloadBatch.titlePart(of: ".flac") == ".flac")
    }

    // MARK: 2.5, 2.17, 2.22 other words

    @Test func theQuitQuestionCountsTracksAndOnlyAppearsWhenSomethingWouldStop() {
        #expect(DownloadBatch.quitQuestion(unfinished: 0) == nil)
        let one = DownloadBatch.quitQuestion(unfinished: 1)
        #expect(one?.title == "Quit while 1 track is still downloading?")
        #expect(one?.message == "The track in progress is discarded. It stays in your queue for next time.")
        let twelve = DownloadBatch.quitQuestion(unfinished: 12)
        #expect(twelve?.title == "Quit while 12 tracks are still downloading?")
        #expect(twelve?.message == "The track in progress is discarded. The others stay in your queue for next time.")
    }

    @Test func settingsSaysWhichFolderTheRunningBatchUses() {
        #expect(DownloadBatch.inProgressFolderNote(folderName: "TIDAL")
                == "Downloads in progress are saved to “TIDAL”. The new folder is used from the next batch.")
    }

    @Test func theCounterReadsThisBatchOnlyAndFeedsTheDockBar() {
        let counter = DownloadBatch.Counter(finished: 37, total: 120)
        #expect(counter.text == "37 of 120")
        #expect(abs(counter.fraction(currentPercent: 50) - 37.5 / 120) < 1e-9)
        #expect(DownloadBatch.Counter(finished: 1, total: 1).fraction(currentPercent: 80) == 1)
        #expect(DownloadBatch.Counter(finished: 0, total: 0).fraction() == 1)
        #expect(DownloadBatch.Counter(finished: 0, total: 4).fraction(currentPercent: 400) == 0.25)
    }
}
