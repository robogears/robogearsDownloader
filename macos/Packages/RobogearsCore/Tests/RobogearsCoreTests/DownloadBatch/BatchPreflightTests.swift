import Foundation
import Testing
@testable import RobogearsCore

// The checks every way of starting downloads shares (decision 4, items 2.11,
// 2.18, 2.19, 2.20). Folders are made in a temporary folder per test; the
// owner's folders are never looked at.

private let signedIn = TokenKeeper.State.signedIn(TIDALAccount(userID: 1, country: TIDALCountry(code: "GB", isAssumed: false)))
private let plentyOfRoom: Int64 = 50_000_000_000

/// A temporary folder with a "TIDAL" download folder and a "Music" library inside.
private struct PreflightFolders {
    let root: URL
    let download: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-preflight-\(UUID().uuidString)", isDirectory: true)
        download = root.appendingPathComponent("TIDAL", isDirectory: true)
        library = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func check(trackCount: Int = 3, download: FolderReference?, library: FolderReference? = nil,
                   signIn: TokenKeeper.State = signedIn, free: Int64? = plentyOfRoom,
                   trash: [URL] = []) -> BatchPreflight.Verdict {
    BatchPreflight.check(trackCount: trackCount, downloadFolder: download, libraryFolder: library,
                         signIn: signIn, startupDiskFreeBytes: free, trashDirectories: trash)
}

private func blockedMessage(_ verdict: BatchPreflight.Verdict) -> String? {
    if case let .blocked(blocked) = verdict { return blocked.message }
    return nil
}

@Suite("Batch preflight")
struct BatchPreflightTests {
    @Test func everythingInPlaceGoesWithTheResolvedFolder() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let verdict = check(download: try FolderReference(url: folders.download), library: try FolderReference(url: folders.library))
        guard case let .go(folder) = verdict else {
            Issue.record("Expected go, got \(verdict)")
            return
        }
        #expect(folder.standardizedFileURL.resolvingSymlinksInPath().path
                == folders.download.standardizedFileURL.resolvingSymlinksInPath().path)
        // The batch plays the start chime itself, once it has started.
        #expect(verdict.sound == nil)
    }

    @Test func noDownloadFolderIsRefusedWithTheHonkAndChooseFolder() {
        let verdict = check(download: nil)
        guard case let .blocked(blocked) = verdict else {
            Issue.record("Expected blocked, got \(verdict)")
            return
        }
        #expect(blocked.message == "Choose a download folder to start downloading.")
        #expect(blocked.fix == .chooseFolder)
        #expect(verdict.sound == .warningHonk)
    }

    @Test func aDownloadFolderThatNoLongerExistsIsRefusedAndNeverCreated() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let reference = try FolderReference(url: folders.download)
        try FileManager.default.removeItem(at: folders.download)
        let verdict = check(download: reference)
        #expect(blockedMessage(verdict) == "The download folder “TIDAL” no longer exists. Create it again or choose another folder.")
        // Create Folder is offered beside Choose Folder…; only that click creates it (2.19).
        if case let .blocked(blocked) = verdict { #expect(blocked.fix == .createFolder) }
        #expect(!FileManager.default.fileExists(atPath: folders.download.path))
    }

    @Test func aDownloadFolderInTheTrashIsRefused() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let verdict = check(download: try FolderReference(url: folders.download), trash: [folders.root])
        #expect(blockedMessage(verdict) == "The download folder “TIDAL” is in the Trash. Put it back or choose another folder.")
        if case let .blocked(blocked) = verdict { #expect(blocked.fix == .chooseFolder) }
    }

    @Test func aDownloadFolderInsideTheLibraryIsRefusedBecauseTheLibraryIsReadOnly() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let inside = folders.library.appendingPathComponent("New", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let verdict = check(download: try FolderReference(url: inside), library: try FolderReference(url: folders.library))
        #expect(blockedMessage(verdict)
                == "Your download folder “New” is inside your music library. The app never writes to your library, so choose a download folder outside it.")
        if case let .blocked(blocked) = verdict { #expect(blocked.fix == .chooseFolder) }
        let same = check(download: try FolderReference(url: folders.library), library: try FolderReference(url: folders.library))
        #expect(blockedMessage(same)?.contains("inside your music library") == true)
    }

    @Test func aLibraryInsideTheDownloadFolderIsFine() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let verdict = check(download: try FolderReference(url: folders.root), library: try FolderReference(url: folders.library))
        guard case .go = verdict else {
            Issue.record("Expected go, got \(verdict)")
            return
        }
    }

    @Test func aStartupDiskTooFullToSaveTheQueueIsRefused() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let reference = try FolderReference(url: folders.download)
        #expect(blockedMessage(check(download: reference, free: 1_000_000))
                == "Your Mac's startup disk is full, so the queue can't be saved during downloads. Free up some space, then try again.")
        guard case .go = check(download: reference, free: BatchPreflight.queueSaveReserveBytes) else {
            Issue.record("The reserve itself is enough")
            return
        }
        guard case .go = check(download: reference, free: nil) else {
            Issue.record("Unknown free space doesn't block")
            return
        }
    }

    @Test func freeSpaceIsReadForTheDiskHoldingAFolder() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let free = BatchPreflight.freeBytes(onVolumeOf: folders.root)
        #expect((free ?? 0) > 0)
    }

    @Test func beingSignedOutIsTheOnlyProblemSoTheSignInSheetOpensWithoutAHonk() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let reference = try FolderReference(url: folders.download)
        #expect(check(download: reference, signIn: .signedOut) == .signIn)
        #expect(check(download: reference, signIn: .invalid) == .signIn)
        #expect(BatchPreflight.Verdict.signIn.sound == nil)
    }

    @Test func signedOutWithNoFolderStillHonksForTheFolderFirst() {
        let verdict = check(download: nil, signIn: .signedOut)
        #expect(blockedMessage(verdict) == "Choose a download folder to start downloading.")
        #expect(verdict.sound == .warningHonk)
    }

    @Test func aSignInStillBeingReadIsRefusedWithItsOwnMessage() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let reference = try FolderReference(url: folders.download)
        #expect(blockedMessage(check(download: reference, signIn: .notLoaded))
                == "Your TIDAL sign-in is still being read. Try again in a moment.")
    }

    @Test func aSignInThatCannotBeReadIsRefusedWithItsOwnMessageAndTheHonk() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let reference = try FolderReference(url: folders.download)
        let verdict = check(download: reference, signIn: .unreadable(.undecodable))
        #expect(blockedMessage(verdict) == "Your saved TIDAL sign-in is damaged. Sign in again to replace it.")
        #expect(verdict.sound == .warningHonk)
    }

    @Test func nothingToDownloadIsRefused() throws {
        let folders = try PreflightFolders()
        defer { folders.remove() }
        let verdict = check(trackCount: 0, download: try FolderReference(url: folders.download))
        #expect(blockedMessage(verdict) == "Nothing in the queue can be downloaded.")
    }
}
