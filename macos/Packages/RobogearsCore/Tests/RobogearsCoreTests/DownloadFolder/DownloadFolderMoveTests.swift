import Darwin
import Foundation
import Testing
@testable import RobogearsCore

// The final move (D4 2.2): one step, never over an existing file (a name
// differing only in case counts as taken), a fresh decision when the name
// was taken meanwhile, and nothing half-done left in the download folder.

/// The destinations a stand-in rename was asked for, in order.
final class RenameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [String] = []
    private var sources: [String] = []

    func record(from: String, to: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        sources.append(from)
        destinations.append(to)
        return destinations.count
    }

    var destinationNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return destinations.map { ($0 as NSString).lastPathComponent }
    }

    var sourceNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sources.map { ($0 as NSString).lastPathComponent }
    }
}

@Suite("Moving a download into place")
struct DownloadFolderMoveTests {
    let system = FileOperations.system.renameExclusive

    @Test func aCheckedFileMovesInUnderItsPlannedNameAndLeavesNoTemporaryFile() async throws {
        let folder = try TestFolder()
        let temp = try folder.temporaryDownload(title: "Blue Lantern", isrc: isrc(1))
        let contents = try Data(contentsOf: temp)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        let moved = try await folder.planner().moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac",
                                                             fileExtension: .flac)
        #expect(moved.fileName == "Blue Lantern.flac")
        #expect(moved.notes.isEmpty)
        #expect(try folder.names() == ["Blue Lantern.flac"])
        #expect(try Data(contentsOf: folder.file("Blue Lantern.flac")) == contents)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func theSavedNameKeepsAccentsComposed() async throws {
        // 2.14: "é as one character". A URL would store it decomposed.
        let folder = try TestFolder()
        let temp = try folder.temporaryDownload(title: "Caf\u{E9}")
        let request = folder.request(title: "Caf\u{E9}")
        let moved = try await folder.planner().moveIntoPlace(temp, for: request, plannedName: "Caf\u{E9}.flac",
                                                             fileExtension: .flac)
        #expect(Array(moved.fileName.utf8) == Array("Caf\u{E9}.flac".utf8))
        #expect(try folder.storedNameBytes() == [Array("Caf\u{E9}.flac".utf8)])
    }

    @Test func theMoveNeverReplacesAFileThatTookTheNameMeanwhile() async throws {
        let folder = try TestFolder()
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: "Intro.flac", notes: []))
        // Another song lands under the name while this one downloads.
        let other = try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(1))
        let otherContents = try Data(contentsOf: other)
        let temp = try folder.temporaryDownload(title: "Intro", artist: "Second Example", isrc: isrc(2))
        let moved = try await folder.planner().moveIntoPlace(temp, for: request, plannedName: "Intro.flac",
                                                             fileExtension: .flac)
        #expect(moved.fileName == "Intro (Second Example).flac")
        #expect(moved.notes == [.savedUnderAnotherName(takenName: "Intro.flac")])
        #expect(try Data(contentsOf: other) == otherContents)
        #expect(try folder.names() == ["Intro (Second Example).flac", "Intro.flac"])
    }

    @Test func aNameTakenOnlyInOtherCaseIsNeverEvenTried() async throws {
        // On a case-sensitive drive "Intro.flac" could sit beside "INTRO.flac";
        // the app's own check must stop it, not the disk.
        let folder = try TestFolder()
        try folder.writeFLAC("INTRO.flac", title: "INTRO", artist: "Placeholder Artist", isrc: isrc(1))
        let log = RenameLog()
        let system = self.system
        let planner = folder.planner(rename: { from, to in
            _ = log.record(from: from, to: to)
            return system(from, to)
        })
        let temp = try folder.temporaryDownload(title: "Intro", artist: "Second Example", isrc: isrc(2))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        let moved = try await planner.moveIntoPlace(temp, for: request, plannedName: "Intro.flac", fileExtension: .flac)
        #expect(moved.fileName == "Intro (Second Example).flac")
        #expect(log.destinationNames == ["Intro (Second Example).flac"])
    }

    @Test func aRenameThatLosesARaceAtTheLastMomentPicksTheNextFreeName() async throws {
        let folder = try TestFolder()
        let racer = try folder.temporaryDownload(title: "Blue Lantern", artist: "Placeholder Artist", isrc: isrc(1))
        let racerContents = try Data(contentsOf: racer)
        let log = RenameLog()
        let system = self.system
        let racerPath = racer.path
        let planner = folder.planner(rename: { from, to in
            if log.record(from: from, to: to) == 1 {
                // Another file arrives exactly between the check and the rename.
                _ = system(racerPath, to)
                return EEXIST
            }
            return system(from, to)
        })
        let temp = try folder.temporaryDownload(title: "Blue Lantern", artist: "Second Example", isrc: isrc(2))
        let request = folder.request(title: "Blue Lantern", artist: "Second Example", isrc: isrc(2))
        let moved = try await planner.moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac", fileExtension: .flac)
        #expect(moved.fileName == "Blue Lantern (Second Example).flac")
        #expect(moved.notes == [.savedUnderAnotherName(takenName: "Blue Lantern.flac")])
        #expect(try Data(contentsOf: folder.file("Blue Lantern.flac")) == racerContents)
    }

    @Test func movingOnFromAClashNameDoesntRepeatItsNote() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(1))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        let planned = "Intro (Second Example).flac"
        #expect(try await folder.planner().decide(for: request, fileExtension: .flac)
            == .save(fileName: planned, notes: [.savedUnderAnotherName(takenName: "Intro.flac")]))
        try folder.writeFLAC(planned, title: "Intro", artist: "Third Example", isrc: isrc(3))
        let temp = try folder.temporaryDownload(title: "Intro", artist: "Second Example", isrc: isrc(2))
        let moved = try await folder.planner().moveIntoPlace(temp, for: request, plannedName: planned, fileExtension: .flac)
        #expect(moved.fileName == "Intro (Paper Harbour).flac")
        #expect(moved.notes.isEmpty)
    }

    // MARK: Other disks and disks without exclusive renames

    @Test func aFileOnAnotherDiskIsCopiedInHiddenThenRenamedLeavingNothingBehind() async throws {
        let folder = try TestFolder()
        let log = RenameLog()
        let system = self.system
        let folderPath = folder.url.path
        let planner = folder.planner(rename: { from, to in
            _ = log.record(from: from, to: to)
            return (from as NSString).deletingLastPathComponent == folderPath ? system(from, to) : EXDEV
        })
        let temp = try folder.temporaryDownload(title: "Blue Lantern")
        let contents = try Data(contentsOf: temp)
        let request = folder.request(title: "Blue Lantern")
        let moved = try await planner.moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac", fileExtension: .flac)
        #expect(moved.fileName == "Blue Lantern.flac")
        #expect(try folder.names() == ["Blue Lantern.flac"])
        #expect(try Data(contentsOf: folder.file("Blue Lantern.flac")) == contents)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(log.sourceNames.count == 2)
        #expect(DownloadFolder.isHiddenCopyName(log.sourceNames[1]))
    }

    @Test func aFailedMoveFromAnotherDiskLeavesNothingInTheFolder() async throws {
        let folder = try TestFolder()
        let folderPath = folder.url.path
        let planner = folder.planner(rename: { from, _ in
            (from as NSString).deletingLastPathComponent == folderPath ? EIO : EXDEV
        })
        let temp = try folder.temporaryDownload(title: "Blue Lantern")
        let request = folder.request(title: "Blue Lantern")
        await #expect(throws: TrackDownloadError.self) {
            try await planner.moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac", fileExtension: .flac)
        }
        #expect(try folder.names().isEmpty)
        #expect(FileManager.default.fileExists(atPath: temp.path))

        // A temporary file that vanished: the hidden copy is cleaned up too.
        try FileManager.default.removeItem(at: temp)
        await #expect(throws: TrackDownloadError.writeFailed(detail: "the temporary file is missing")) {
            try await planner.moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac", fileExtension: .flac)
        }
        #expect(try folder.names().isEmpty)
    }

    @Test func aDiskWithoutExclusiveRenamesStillNeverReplacesAFile() async throws {
        let folder = try TestFolder()
        let racer = try folder.temporaryDownload(title: "Blue Lantern", artist: "Placeholder Artist", isrc: isrc(1))
        let racerContents = try Data(contentsOf: racer)
        let log = RenameLog()
        let racerPath = racer.path
        let system = self.system
        let planner = folder.planner(rename: { from, to in
            if log.record(from: from, to: to) == 1 {
                _ = system(racerPath, to) // another file arrives at the last moment
            }
            return ENOTSUP
        })
        let temp = try folder.temporaryDownload(title: "Blue Lantern", artist: "Second Example", isrc: isrc(2))
        let contents = try Data(contentsOf: temp)
        let request = folder.request(title: "Blue Lantern", artist: "Second Example", isrc: isrc(2))
        let moved = try await planner.moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac", fileExtension: .flac)
        #expect(moved.fileName == "Blue Lantern (Second Example).flac")
        #expect(try Data(contentsOf: folder.file("Blue Lantern.flac")) == racerContents)
        #expect(try Data(contentsOf: folder.file("Blue Lantern (Second Example).flac")) == contents)
        #expect(try folder.names() == ["Blue Lantern (Second Example).flac", "Blue Lantern.flac"])
    }

    @Test func aFullDiskStopsTheBatch() async throws {
        let folder = try TestFolder()
        let planner = folder.planner(rename: { _, _ in ENOSPC })
        let temp = try folder.temporaryDownload(title: "Blue Lantern")
        do {
            _ = try await planner.moveIntoPlace(temp, for: folder.request(title: "Blue Lantern"),
                                                plannedName: "Blue Lantern.flac", fileExtension: .flac)
            Issue.record("expected an error")
        } catch let error as TrackDownloadError {
            guard case .diskFull = error else {
                Issue.record("expected a full disk, got \(error)")
                return
            }
            #expect(error.stopsBatch)
        }
        #expect(try folder.names().isEmpty)
    }

    // MARK: Names the move refuses

    @Test func aPlannedNameThatIsntAPlainFileNameIsRefused() async throws {
        let folder = try TestFolder()
        let temp = try folder.temporaryDownload(title: "Blue Lantern")
        let request = folder.request(title: "Blue Lantern")
        for name in ["../Escape.flac", ".Hidden.flac", "Sub/Folder.flac", "Blue Lantern.m4a", ""] {
            await #expect(throws: TrackDownloadError.self, "\(name)") {
                try await folder.planner().moveIntoPlace(temp, for: request, plannedName: name, fileExtension: .flac)
            }
        }
        #expect(try folder.names().isEmpty)
        #expect(FileManager.default.fileExists(atPath: temp.path))
    }

    @Test func aMoveForAnotherFolderIsRefused() async throws {
        let folder = try TestFolder()
        let temp = try folder.temporaryDownload(title: "Blue Lantern")
        var request = folder.request(title: "Blue Lantern")
        request.folder = folder.root
        await #expect(throws: TrackDownloadError.self) {
            try await folder.planner().moveIntoPlace(temp, for: request, plannedName: "Blue Lantern.flac", fileExtension: .flac)
        }
        #expect(FileManager.default.fileExists(atPath: temp.path))
    }

    // MARK: Leftovers from a crash (2.2)

    @Test func theSweepRemovesOnlyTheMovesOwnLeftoverCopies() async throws {
        let folder = try TestFolder()
        let own = DownloadFolder.hiddenCopyName()
        #expect(DownloadFolder.isHiddenCopyName(own))
        let keep = [".Blue Lantern.flac.part", "Blue Lantern.tmp.flac", ".robogears-copy-1234.part",
                    ".robogears-copy-\(String(repeating: "A", count: 32)).part"]
        for name in [own] + keep {
            FileManager.default.createFile(atPath: folder.file(name).path, contents: Data("x".utf8))
        }
        let ownFolder = DownloadFolder.hiddenCopyName()
        try FileManager.default.createDirectory(at: folder.file(ownFolder), withIntermediateDirectories: false)
        #expect(folder.planner().removeLeftoverCopies() == 1)
        #expect(try folder.names() == (keep + [ownFolder]).sorted())
    }
}
