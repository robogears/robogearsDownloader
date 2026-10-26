import Foundation
import Testing
@testable import RobogearsCore

// What the download folder decides before anything is saved: skip a healthy
// copy (2.3, 2.6), leave a damaged one for Replace (2.3), give a different
// song with the same title its own name (2.6, 2.7), and the AAC rules (2.10).
// Every file here is made in a temporary folder; the Trash is a stand-in.

@Suite("Download folder decisions")
struct DownloadFolderDecisionTests {
    // MARK: Plain names and same songs

    @Test func anEmptyFolderSavesUnderThePlainTitle() async throws {
        let folder = try TestFolder()
        let decision = try await folder.planner().decide(for: folder.request(title: "Blue Lantern"), fileExtension: .flac)
        #expect(decision == .save(fileName: "Blue Lantern.flac", notes: []))
    }

    @Test func theVersionStaysOutOfThePlainName() async throws {
        let folder = try TestFolder()
        let request = folder.request(title: "Blue Lantern", version: "Radio Edit")
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Blue Lantern.flac", notes: []))
    }

    @Test func aHealthyCopyWithTheSameRecordingCodeIsSkipped() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", isrc: isrc(1))
        let request = folder.request(title: "Intro", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "Intro.flac")))
    }

    @Test func withoutARecordingCodeTheSameTitleAndArtistIsTheSameSong() async throws {
        let folder = try TestFolder()
        // Tagged "Placeholder Artist, Second Example", like the old app's files.
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist, Second Example")
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "Intro.flac")))
    }

    @Test func aDifferentRecordingCodeIsADifferentRecordingEvenWithTheSameTitleAndArtist() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", isrc: isrc(1))
        let request = folder.request(title: "Intro", isrc: isrc(2))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Intro (Placeholder Artist).flac", notes: [.savedUnderAnotherName(takenName: "Intro.flac")]))
    }

    @Test func aShortArtistInsideALongerOneIsNotTheSameArtist() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Oxen Collective")
        let request = folder.request(title: "Intro", artist: "Ox")
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Intro (Ox).flac", notes: [.savedUnderAnotherName(takenName: "Intro.flac")]))
    }

    // MARK: Two songs, one title (2.6, 2.7)

    @Test func aSecondSongCalledIntroIsSavedUnderItsArtist() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(1))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Intro (Second Example).flac", notes: [.savedUnderAnotherName(takenName: "Intro.flac")]))
    }

    @Test func aSecondVersionIsSavedUnderItsVersionFirst() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        let request = folder.request(title: "Blue Lantern", version: "Radio Edit", isrc: isrc(2))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Blue Lantern (Radio Edit).flac",
                     notes: [.savedUnderAnotherName(takenName: "Blue Lantern.flac")]))
    }

    @Test func clashNamesAreTriedInOrderThenNumbered() async throws {
        let folder = try TestFolder()
        let planner = folder.planner()
        let request = folder.request(title: "Intro", version: "Radio Edit", artist: "Second Example", isrc: isrc(9))
        let taken = [Note.taken("Intro.flac")]
        var others = 0
        func addOtherSong(_ name: String) throws {
            others += 1
            try folder.writeFLAC(name, title: "Intro", artist: "Other Artist \(others)", isrc: isrc(others))
        }
        try addOtherSong("Intro.flac")
        #expect(try await planner.decide(for: request, fileExtension: .flac) == .save(fileName: "Intro (Radio Edit).flac", notes: taken))
        try addOtherSong("Intro (Radio Edit).flac")
        #expect(try await planner.decide(for: request, fileExtension: .flac) == .save(fileName: "Intro (Second Example).flac", notes: taken))
        try addOtherSong("Intro (Second Example).flac")
        #expect(try await planner.decide(for: request, fileExtension: .flac) == .save(fileName: "Intro (Paper Harbour).flac", notes: taken))
        try addOtherSong("Intro (Paper Harbour).flac")
        #expect(try await planner.decide(for: request, fileExtension: .flac) == .save(fileName: "Intro (Paper Harbour) 2.flac", notes: taken))
        try addOtherSong("Intro (Paper Harbour) 2.flac")
        #expect(try await planner.decide(for: request, fileExtension: .flac) == .save(fileName: "Intro (Paper Harbour) 3.flac", notes: taken))
    }

    @Test func reQueueingTheSecondIntroFindsItsRenamedFileAndSkipsIt() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(1))
        try folder.writeFLAC("Intro (Second Example).flac", title: "Intro", artist: "Second Example", isrc: isrc(2))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "Intro (Second Example).flac")))
    }

    @Test func aNumberedCopyIsFoundEvenAfterAnEarlierNumberWasDeleted() async throws {
        let folder = try TestFolder()
        for (index, name) in ["Intro.flac", "Intro (Second Example).flac", "Intro (Paper Harbour).flac"].enumerated() {
            try folder.writeFLAC(name, title: "Intro", artist: "Other Artist \(index)", isrc: isrc(index + 1))
        }
        try folder.writeFLAC("Intro (Paper Harbour) 3.flac", title: "Intro", artist: "Second Example", isrc: isrc(9))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(9))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "Intro (Paper Harbour) 3.flac")))
    }

    @Test func theVersionInTheTitleTagTellsTwoVersionsApart() async throws {
        // This app tags a Radio Edit "Blue Lantern (Radio Edit)" (2.7), so the
        // album version is a different song even with no recording codes.
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern (Radio Edit)")
        let request = folder.request(title: "Blue Lantern")
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Blue Lantern (Placeholder Artist).flac",
                     notes: [.savedUnderAnotherName(takenName: "Blue Lantern.flac")]))
    }

    @Test func anOldFileWithTheBareTitleStandsForAVersionOnlyWhenTheLengthsAgree() async throws {
        // The old app tagged every version with the bare title.
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern")
        let sameLength = folder.request(title: "Blue Lantern", version: "Radio Edit", seconds: 1)
        #expect(try await folder.planner().decide(for: sameLength, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "Blue Lantern.flac")))
        let longer = folder.request(title: "Blue Lantern", version: "Extended Mix", seconds: 30)
        #expect(try await folder.planner().decide(for: longer, fileExtension: .flac)
            == .save(fileName: "Blue Lantern (Extended Mix).flac",
                     notes: [.savedUnderAnotherName(takenName: "Blue Lantern.flac")]))
    }

    @Test func twoLongTitlesThatShortenToTheSameNameCountAsAClash() async throws {
        let folder = try TestFolder()
        let start = String(repeating: "a", count: 300)
        let first = folder.request(title: start + "x", isrc: isrc(1))
        guard case let .save(firstName, _) = try await folder.planner().decide(for: first, fileExtension: .flac) else {
            Issue.record("expected a save")
            return
        }
        try folder.writeFLAC(firstName, title: start + "x", isrc: isrc(1))
        let second = folder.request(title: start + "y", artist: "Second Example", isrc: isrc(2))
        let decision = try await folder.planner().decide(for: second, fileExtension: .flac)
        let expectedName = String(repeating: "a", count: FileNaming.maxStemBytes - 17) + " (Second Example).flac"
        #expect(decision == .save(fileName: expectedName, notes: [.savedUnderAnotherName(takenName: firstName)]))
    }

    // MARK: Names a disk may treat as one (2.2, 2.6, 2.14)

    @Test func aNameDifferingOnlyInCaseCountsAsTaken() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("INTRO.flac", title: "INTRO", artist: "Placeholder Artist", isrc: isrc(1))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Intro (Second Example).flac", notes: [.savedUnderAnotherName(takenName: "INTRO.flac")]))
    }

    @Test func theSameSongSavedInOtherCaseIsFound() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("BLUE LANTERN.flac", title: "Blue Lantern", isrc: isrc(1))
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "BLUE LANTERN.flac")))
    }

    @Test func aDecomposedAccentOnDiskIsTheSameName() async throws {
        let folder = try TestFolder()
        // Foundation stores "Café" decomposed; the request's title is composed.
        try folder.writeFLAC("Caf\u{E9}.flac", title: "Caf\u{E9}", isrc: isrc(1))
        #expect(try folder.storedNameBytes() == [Array("Cafe\u{301}.flac".utf8)])
        let same = folder.request(title: "Caf\u{E9}", isrc: isrc(1))
        guard case let .skip(.alreadyInFolder(name)) = try await folder.planner().decide(for: same, fileExtension: .flac) else {
            Issue.record("expected a skip")
            return
        }
        #expect(Array(name.utf8) == Array("Cafe\u{301}.flac".utf8))
        let other = folder.request(title: "Caf\u{E9}", artist: "Second Example", isrc: isrc(2))
        guard case let .save(newName, notes) = try await folder.planner().decide(for: other, fileExtension: .flac) else {
            Issue.record("expected a save")
            return
        }
        // The new name is composed, as 2.14 asks, whatever the disk holds.
        #expect(Array(newName.utf8) == Array("Caf\u{E9} (Second Example).flac".utf8))
        #expect(notes.count == 1)
    }

    @Test func theOldAppsSpellingStillCountsAsAlreadyHere() async throws {
        // "...Ready" was the hidden "...Ready.flac" in the Electron app (2.14).
        let folder = try TestFolder()
        try folder.writeFLAC("...Ready.flac", title: "...Ready", isrc: isrc(1))
        let request = folder.request(title: "...Ready", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "...Ready.flac")))
    }

    @Test func electronLeftoverTmpFilesNeverCountAsDownloadsAndAreLeftAlone() async throws {
        // D4 2.2: "….tmp.flac" raw downloads are left alone and never count.
        let folder = try TestFolder()
        let leftover = try folder.writeFLAC("Blue Lantern.tmp.flac", title: "Blue Lantern", isrc: isrc(1))
        let before = try Data(contentsOf: leftover)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Blue Lantern.flac", notes: []))
        #expect(try Data(contentsOf: leftover) == before)
        #expect(try folder.trashedNames().isEmpty)
    }

    // MARK: Damaged copies (2.3)

    @Test func aCutOffCopyOfTheSameSongIsReportedDamagedAndLeftUntouched() async throws {
        let folder = try TestFolder()
        let url = try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        try folder.cut("Blue Lantern.flac", fraction: 0.6)
        let before = try Data(contentsOf: url)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.existingLooksDamaged(fileName: "Blue Lantern.flac")))
        #expect(try Data(contentsOf: url) == before)
        #expect(try folder.trashedNames().isEmpty)
    }

    @Test func aCopyMuchShorterThanTIDALsLengthLooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        let request = folder.request(title: "Blue Lantern", seconds: 240, isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: nil)
            == .skip(.existingLooksDamaged(fileName: "Blue Lantern.flac")))
    }

    @Test func replaceMovesTheDamagedCopyToTheTrashAndFreesTheName() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        try folder.cut("Blue Lantern.flac", fraction: 0.6)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        #expect(try await folder.planner().decide(for: request, fileExtension: nil)
            == .save(fileName: "Blue Lantern.flac", notes: []))
        #expect(try folder.names().isEmpty)
        #expect(try folder.trashedNames() == ["Blue Lantern.flac"])
    }

    @Test func replaceNeverTouchesAHealthyCopy() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.alreadyInFolder(fileName: "Blue Lantern.flac")))
        #expect(try folder.trashedNames().isEmpty)
    }

    @Test func replaceInAFolderWithoutATrashAsksFirstAndDeletesNothing() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        try folder.cut("Blue Lantern.flac", fraction: 0.6)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        await #expect(throws: TrackDownloadError.folderHasNoTrash(fileName: "Blue Lantern.flac")) {
            try await folder.planner(noTrash: true).decide(for: request, fileExtension: nil)
        }
        #expect(try folder.names() == ["Blue Lantern.flac"])
        #expect(TrackDownloadError.folderHasNoTrash(fileName: "Blue Lantern.flac").rowMessage
            == "This folder has no Trash. Delete “Blue Lantern.flac” permanently and download it again?")
    }

    @Test func deletingPermanentlyTakesOnlyADamagedCopyOfThisSong() async throws {
        let folder = try TestFolder()
        let planner = folder.planner(noTrash: true)
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        // Healthy: kept.
        #expect(try await planner.deleteDamagedCopyPermanently(named: "Blue Lantern.flac", for: request) == false)
        // A different song's damaged file: kept.
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Second Example", isrc: isrc(2))
        try folder.cut("Intro.flac", fraction: 0.6)
        let intro = folder.request(title: "Intro", isrc: isrc(3))
        #expect(try await planner.deleteDamagedCopyPermanently(named: "Intro.flac", for: intro) == false)
        // A file that isn't one of this track's names: kept.
        #expect(try await planner.deleteDamagedCopyPermanently(named: "Intro.flac", for: request) == false)
        // This song's damaged copy: deleted.
        try folder.cut("Blue Lantern.flac", fraction: 0.6)
        #expect(try await planner.deleteDamagedCopyPermanently(named: "Blue Lantern.flac", for: request))
        #expect(try folder.names() == ["Intro.flac"])
    }

    // MARK: Files that can't be identified (2.6's fallback)

    @Test func anUntaggedFileHoldingThePlainNameCantBeToldApart() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: nil, artist: nil)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.nameTakenByUnreadableFile(fileName: "Blue Lantern.flac")))
    }

    @Test func aMatchingTitleWithoutAnArtistCantBeToldApart() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", artist: nil)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.nameTakenByUnreadableFile(fileName: "Blue Lantern.flac")))
    }

    @Test func anEmptyFileAtThePlainNameLooksDamagedRatherThanUnidentified() async throws {
        // A crash can leave a 0-byte file; Replace must be offered for it (2.3).
        let folder = try TestFolder()
        FileManager.default.createFile(atPath: folder.file("Blue Lantern.flac").path, contents: Data())
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.existingLooksDamaged(fileName: "Blue Lantern.flac")))
    }

    @Test func aFolderNamedLikeTheSongHoldsTheNameButIsNeverCalledDamaged() async throws {
        let folder = try TestFolder()
        try FileManager.default.createDirectory(at: folder.file("Blue Lantern.flac"), withIntermediateDirectories: false)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .skip(.nameTakenByUnreadableFile(fileName: "Blue Lantern.flac")))
        #expect(try folder.trashedNames().isEmpty)
    }

    // MARK: AAC and lossless (2.10)

    @Test func anOldM4ADoesntBlockALosslessCopyWhichIsSavedNextToIt() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Paper Harbour.m4a")
        let planner = folder.planner(tags: ["Paper Harbour.m4a": AudioTags(title: "Paper Harbour", artists: ["Placeholder Artist"])])
        let request = folder.request(title: "Paper Harbour", isrc: isrc(1))
        #expect(try await planner.decide(for: request, fileExtension: .flac)
            == .save(fileName: "Paper Harbour.flac", notes: [.savedNextToAAC(aacName: "Paper Harbour.m4a")]))
        #expect(try folder.names() == ["Paper Harbour.m4a"])
    }

    @Test func beforeTIDALAnswersAnM4ABlocksOnlyWhenTIDALHasNoLosslessVersion() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Paper Harbour.m4a")
        let planner = folder.planner(tags: ["Paper Harbour.m4a": AudioTags(title: "Paper Harbour", artists: ["Placeholder Artist"])])
        #expect(try await planner.decide(for: folder.request(title: "Paper Harbour", lossless: false), fileExtension: nil)
            == .skip(.alreadyInFolder(fileName: "Paper Harbour.m4a")))
        for lossless in [true, nil] as [Bool?] {
            #expect(try await planner.decide(for: folder.request(title: "Paper Harbour", lossless: lossless), fileExtension: nil)
                == .save(fileName: "Paper Harbour.flac", notes: [.savedNextToAAC(aacName: "Paper Harbour.m4a")]))
        }
    }

    @Test func anM4AOfTheSameSongBlocksAnotherM4A() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Paper Harbour.m4a")
        let planner = folder.planner(tags: ["Paper Harbour.m4a": AudioTags(title: "Paper Harbour", artists: ["Placeholder Artist"])])
        #expect(try await planner.decide(for: folder.request(title: "Paper Harbour"), fileExtension: .m4a)
            == .skip(.alreadyInFolder(fileName: "Paper Harbour.m4a")))
    }

    @Test func aFLACOfTheSameRecordingBlocksEvenAnAACOnlyDownload() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Paper Harbour.flac", title: "Paper Harbour", isrc: isrc(1))
        let request = folder.request(title: "Paper Harbour", isrc: isrc(1), lossless: false)
        #expect(try await folder.planner().decide(for: request, fileExtension: .m4a)
            == .skip(.alreadyInFolder(fileName: "Paper Harbour.flac")))
        #expect(try await folder.planner().decide(for: request, fileExtension: nil)
            == .skip(.alreadyInFolder(fileName: "Paper Harbour.flac")))
    }

    @Test func anAACOnlyTrackIsSavedAsM4A() async throws {
        let folder = try TestFolder()
        let request = folder.request(title: "Paper Harbour", lossless: false)
        #expect(try await folder.planner().decide(for: request, fileExtension: nil)
            == .save(fileName: "Paper Harbour.m4a", notes: []))
    }

    @Test func aDifferentSongsM4AKeepsAFLACOutOfTheSameStem() async throws {
        // "Intro.flac" next to another song's "Intro.m4a" would look like one
        // song in two qualities, which 2.10 offers to tidy away.
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Intro.m4a")
        let planner = folder.planner(tags: ["Intro.m4a": AudioTags(title: "Intro", artists: ["Placeholder Artist"])])
        let request = folder.request(title: "Intro", artist: "Second Example")
        #expect(try await planner.decide(for: request, fileExtension: .flac)
            == .save(fileName: "Intro (Second Example).flac", notes: [.savedUnderAnotherName(takenName: "Intro.m4a")]))
    }

    // MARK: The folder itself (2.17, 2.19)

    @Test func aRequestForAnotherFolderIsRefused() async throws {
        let folder = try TestFolder()
        var request = folder.request(title: "Blue Lantern")
        request.folder = folder.trashFolder
        await #expect(throws: TrackDownloadError.self) {
            try await folder.planner().decide(for: request, fileExtension: .flac)
        }
    }

    @Test func aDownloadFolderThatNoLongerExistsStopsTheBatchAndIsNeverCreated() async throws {
        let folder = try TestFolder()
        try FileManager.default.removeItem(at: folder.url)
        let request = folder.request(title: "Blue Lantern")
        do {
            _ = try await folder.planner().decide(for: request, fileExtension: .flac)
            Issue.record("expected an error")
        } catch let error as TrackDownloadError {
            #expect(error == .folderUnavailable(message:
                "The download folder “Downloads” no longer exists. Create it again or choose another folder."))
            #expect(error.stopsBatch)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func aFolderReachedThroughALinkWhoseDiskGoesAwayMidBatchStopsTheBatch() async throws {
        // Picked as ".../Link/TIDAL" where Link leads to a drive. Once the
        // drive is gone the link leads nowhere: that is an unavailable folder
        // (2.19), not a track for some other folder.
        let folder = try TestFolder()
        let drive = folder.root.appendingPathComponent("Drive", isDirectory: true)
        let link = folder.root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("TIDAL"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: drive)
        let downloads = link.appendingPathComponent("TIDAL", isDirectory: true)
        let planner = folder.planner(folder: downloads)
        var request = folder.request(title: "Blue Lantern")
        request.folder = downloads
        #expect(try await planner.decide(for: request, fileExtension: .flac) == .save(fileName: "Blue Lantern.flac", notes: []))

        try FileManager.default.removeItem(at: drive)
        do {
            _ = try await planner.decide(for: request, fileExtension: .flac)
            Issue.record("expected an error")
        } catch let error as TrackDownloadError {
            guard case .folderUnavailable = error else {
                Issue.record("expected an unavailable folder, got \(error)")
                return
            }
            #expect(error.stopsBatch)
        }
        #expect(!FileManager.default.fileExists(atPath: drive.path))
    }
}

/// Shorthand for the clash note in the ordering test.
private enum Note {
    static func taken(_ name: String) -> SaveNote { .savedUnderAnotherName(takenName: name) }
}
