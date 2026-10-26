import Foundation
import Testing
@testable import RobogearsCore

// D4 2.16 option A: the queue shows a quiet "In your download folder" badge,
// worked out from the folder alone with the batch's own decision, and warns
// before Download All when a different song holds the name (2.6).

@Suite("In your download folder badge")
struct InFolderBadgeTests {
    @Test func aHealthyCopyEarnsTheBadge() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        let status = try await folder.planner().inFolderStatus(for: folder.request(title: "Blue Lantern", isrc: isrc(1)))
        #expect(status == .inFolder(fileName: "Blue Lantern.flac", looksDamaged: false))
    }

    @Test func aDamagedCopyIsFlaggedAndNeverMovedToTheTrashByTheBadge() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        try folder.cut("Blue Lantern.flac", fraction: 0.6)
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1), replace: true)
        #expect(try await folder.planner().inFolderStatus(for: request)
            == .inFolder(fileName: "Blue Lantern.flac", looksDamaged: true))
        #expect(try folder.names() == ["Blue Lantern.flac"])
        #expect(try folder.trashedNames().isEmpty)
    }

    @Test func aDifferentSongHoldingTheNameIsShownBeforeDownloadAll() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(1))
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        #expect(try await folder.planner().inFolderStatus(for: request)
            == .differentSongHoldsName(fileName: "Intro.flac", plannedName: "Intro (Second Example).flac"))
    }

    @Test func anUnreadableFileHoldingTheNameIsShown() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: nil, artist: nil)
        #expect(try await folder.planner().inFolderStatus(for: folder.request(title: "Blue Lantern"))
            == .nameTakenByUnreadableFile(fileName: "Blue Lantern.flac"))
    }

    @Test func anM4AEarnsNoBadgeWhenTIDALListsALosslessVersion() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Paper Harbour.m4a")
        let planner = folder.planner(tags: ["Paper Harbour.m4a": AudioTags(title: "Paper Harbour", artists: ["Placeholder Artist"])])
        #expect(try await planner.inFolderStatus(for: folder.request(title: "Paper Harbour", lossless: true)) == .notInFolder)
        #expect(try await planner.inFolderStatus(for: folder.request(title: "Paper Harbour", lossless: nil)) == .notInFolder)
        #expect(try await planner.inFolderStatus(for: folder.request(title: "Paper Harbour", lossless: false))
            == .inFolder(fileName: "Paper Harbour.m4a", looksDamaged: false))
    }

    @Test func manyRowsAreBadgedFromOneLookAtTheFolder() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(2))
        let have = folder.request(title: "Blue Lantern", isrc: isrc(1))
        let clash = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(3))
        let new = folder.request(title: "Copper Sky", isrc: isrc(4))
        let statuses = try await folder.planner().inFolderStatuses(for: [have, clash, new])
        #expect(statuses == [
            have.rowID: .inFolder(fileName: "Blue Lantern.flac", looksDamaged: false),
            clash.rowID: .differentSongHoldsName(fileName: "Intro.flac", plannedName: "Intro (Second Example).flac"),
            new.rowID: .notInFolder,
        ])
    }

    @Test func theBadgeMatchesWhatTheBatchWillDo() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Intro.flac", title: "Intro", artist: "Placeholder Artist", isrc: isrc(1))
        let planner = folder.planner()
        let request = folder.request(title: "Intro", artist: "Second Example", isrc: isrc(2))
        let decision = try await planner.decide(for: request, fileExtension: nil)
        #expect(DownloadFolder.status(for: decision) == (try await planner.inFolderStatus(for: request)))
    }

    @Test func theBadgeCanBeWorkedOutFromManyTasksAtOnce() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern", isrc: isrc(1))
        let planner = folder.planner()
        let request = folder.request(title: "Blue Lantern", isrc: isrc(1))
        let statuses = try await withThrowingTaskGroup(of: DownloadFolder.InFolderStatus.self) { group in
            for _ in 0..<16 {
                group.addTask { try await planner.inFolderStatus(for: request) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses.count == 16)
        #expect(statuses.allSatisfy { $0 == .inFolder(fileName: "Blue Lantern.flac", looksDamaged: false) })
    }
}
