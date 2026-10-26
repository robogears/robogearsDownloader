import Foundation
import Testing
@testable import RobogearsCore

// D4 2.3 option A: before skipping, the existing file's structure is checked,
// never its tags. Healthy files skip; cut-off ones are reported as damaged.

@Suite("Quick check of an existing file")
struct ExistingFileCheckTests {
    func check(_ folder: TestFolder, _ name: String, _ kind: FileNaming.AudioExtension = .flac,
               tidal: Double? = 1) async -> ExistingFileCheck.Verdict {
        await ExistingFileCheck.check(folder.file(name), as: kind, tidalSeconds: tidal)
    }

    // MARK: FLAC

    @Test func aCompleteFLACThisAppSavedIsHealthy() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern")
        #expect(await check(folder, "Blue Lantern.flac") == .healthy)
        try folder.writeFLAC("Hi-Res.flac", title: "Hi-Res", source: "bts-24-96000.flac")
        #expect(await check(folder, "Hi-Res.flac") == .healthy)
    }

    @Test func aFLACThisAppSavedFromADASHStreamIsHealthy() async throws {
        // The main Hi-Res path: FLAC frames taken out of fragmented MP4, with
        // the sample count filled in from the counted frames. The check's
        // position rule needs their frame numbers to start at 0.
        let folder = try TestFolder()
        for source in ["dash-24-96000.mp4", "dash-live-16-44100.mp4"] {
            let name = "\(source).flac"
            let url = try folder.writeFLAC(name, title: "Hi-Res", source: source)
            #expect(try FLACMetadataReader.summary(of: url).streamInfo.totalSamples > 0, "\(source)")
            #expect(await check(folder, name) == .healthy, "\(source)")
            try folder.cut(name, fraction: 0.7)
            #expect(await check(folder, name, tidal: nil) != .healthy, "\(source) cut short")
        }
    }

    @Test func filesTheOldAppsFFmpegWroteAreHealthy() async throws {
        let folder = try TestFolder()
        for name in ["ffmpeg-bts-16-44100.flac", "ffmpeg-dash-24-96000.flac", "ffmpeg-dash-live-16-44100.flac"] {
            try folder.copyFixture(name, as: name)
            #expect(await check(folder, name) == .healthy, "\(name)")
        }
    }

    @Test func aFLACCutOffPartWayLooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern")
        try folder.cut("Blue Lantern.flac", fraction: 0.6)
        #expect(await check(folder, "Blue Lantern.flac") == .damaged(.cutOff))
    }

    @Test func aFLACMissingOnlyItsLastByteLooksDamaged() async throws {
        let folder = try TestFolder()
        let url = try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern")
        try folder.cut("Blue Lantern.flac", to: try Data(contentsOf: url).count - 1)
        #expect(await check(folder, "Blue Lantern.flac") == .damaged(.cutOff))
    }

    @Test func aFLACCutExactlyBetweenFramesLooksDamagedByItsPosition() async throws {
        // Every remaining frame is complete, so only the last frame's
        // position against the declared length shows what's missing.
        let folder = try TestFolder()
        let url = try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern")
        let starts = try FLACFrames.starts(Data(contentsOf: url))
        #expect(starts.count == 10) // 44100 samples in frames of 4608
        try folder.cut("Blue Lantern.flac", to: starts[9])
        #expect(await check(folder, "Blue Lantern.flac", tidal: nil)
            == .damaged(.endsBeforeDeclaredLength(declaredSamples: 44100, lastFrameEnd: 9 * 4608)))
    }

    @Test func anOldHiResFileThatDoesntStateItsLengthIsJudgedByItsLastFrame() async throws {
        // FFmpeg copied a 0 sample count from live-packaged DASH (spike part a).
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-dash-live-16-44100.flac", as: "Live.flac")
        #expect(try FLACMetadataReader.summary(of: folder.file("Live.flac")).streamInfo.totalSamples == 0)
        #expect(await check(folder, "Live.flac", tidal: 1) == .healthy)
        #expect(await check(folder, "Live.flac", tidal: 10) == .damaged(.lengthDiffers(fileSeconds: 1, tidalSeconds: 10)))
        try folder.cut("Live.flac", fraction: 0.7)
        #expect(await check(folder, "Live.flac", tidal: nil) == .damaged(.cutOff))
    }

    @Test func aFLACMuchShorterThanTIDALsLengthLooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Blue Lantern.flac", title: "Blue Lantern")
        // 1 s against TIDAL's 3 s is within 2 s; against 4 s it isn't.
        #expect(await check(folder, "Blue Lantern.flac", tidal: 3) == .healthy)
        #expect(await check(folder, "Blue Lantern.flac", tidal: 4) == .damaged(.lengthDiffers(fileSeconds: 1, tidalSeconds: 4)))
    }

    @Test func toleranceIsTwoSecondsOrOnePercentWhicheverIsLarger() {
        #expect(ExistingFileCheck.lengthTolerance(forTIDALSeconds: 60) == 2)
        #expect(ExistingFileCheck.lengthTolerance(forTIDALSeconds: 600) == 6)
        #expect(ExistingFileCheck.lengthsAgree(fileSeconds: 594, tidalSeconds: 600))
        #expect(!ExistingFileCheck.lengthsAgree(fileSeconds: 593.9, tidalSeconds: 600))
    }

    @Test func anID3v1TagOrALittleZeroPaddingAfterTheAudioIsAllowed() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Tagged.flac", title: "Tagged")
        var id3 = Data("TAG".utf8)
        id3.append(Data(repeating: 0x20, count: 125))
        try folder.append(id3, to: "Tagged.flac")
        #expect(await check(folder, "Tagged.flac") == .healthy)

        try folder.writeFLAC("Padded.flac", title: "Padded")
        try folder.append(Data(count: 1000), to: "Padded.flac")
        #expect(await check(folder, "Padded.flac") == .healthy)
    }

    @Test func aLongRunOfZerosAfterTheAudioLooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Zeros.flac", title: "Zeros")
        try folder.append(Data(count: ExistingFileCheck.allowedZeroPadding + 1), to: "Zeros.flac")
        #expect(await check(folder, "Zeros.flac") == .damaged(.unexpectedDataAtEnd))
    }

    @Test func otherBytesAfterTheLastFrameLookDamaged() async throws {
        let folder = try TestFolder()
        try folder.writeFLAC("Junk.flac", title: "Junk")
        try folder.append(Data("not audio".utf8), to: "Junk.flac")
        #expect(await check(folder, "Junk.flac") == .damaged(.cutOff))
    }

    @Test func aFLACWithNoAudioAfterItsTagsLooksDamaged() async throws {
        let folder = try TestFolder()
        let url = try folder.writeFLAC("Empty.flac", title: "Empty")
        let layout = try FLACMetadataReader.read(Data(contentsOf: url))
        try folder.cut("Empty.flac", to: layout.audioOffset)
        #expect(await check(folder, "Empty.flac") == .damaged(.noAudioFrames))
    }

    @Test func aFileThatIsntFLACAtAllLooksDamaged() async throws {
        let folder = try TestFolder()
        try Data("hello".utf8).write(to: folder.file("Text.flac"))
        #expect(await check(folder, "Text.flac") == .damaged(.unreadable))
    }

    @Test func frameFooterChecksumMatchesTheFLACSpecification() {
        // RFC 9639's CRC-16 (CRC-16/UMTS): check value for "123456789" is 0xFEE8.
        #expect(ExistingFileCheck.crc16(Array("123456789".utf8), from: 0) == 0xFEE8)
    }

    @Test func frameNumbersAreDecodedLikeUTF8() {
        #expect(ExistingFileCheck.codedNumber([0x05], at: 0) == 5)
        #expect(ExistingFileCheck.codedNumber([0xC2, 0x80], at: 0) == 128)
        #expect(ExistingFileCheck.codedNumber([0xE1, 0x80, 0x80], at: 0) == 4096)
        #expect(ExistingFileCheck.codedNumber([0xC2], at: 0) == nil)
        #expect(ExistingFileCheck.codedNumber([0xFF], at: 0) == nil)
    }

    // MARK: M4A

    @Test func completeM4AFilesAreHealthy() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Old App.m4a")
        try folder.copyFixture("aac-320.m4a", as: "Plain.m4a")
        try folder.copyFixture("dash-aac.mp4", as: "Fragmented.m4a")
        #expect(await check(folder, "Old App.m4a", .m4a) == .healthy)
        #expect(await check(folder, "Plain.m4a", .m4a) == .healthy)
        #expect(await check(folder, "Fragmented.m4a", .m4a) == .healthy)
    }

    @Test func anM4ACutOffPartWayLooksDamaged() async throws {
        let folder = try TestFolder()
        // FFmpeg put "moov" at the end, so a cut copy has none.
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Old App.m4a")
        try folder.cut("Old App.m4a", fraction: 0.6)
        #expect(await check(folder, "Old App.m4a", .m4a) == .damaged(.boxesDontAddUp))
        // A cut inside the last box is caught by the sizes alone.
        let size = try Data(contentsOf: try AudioFixture.url("aac-320.m4a")).count
        try folder.copyFixture("aac-320.m4a", as: "Plain.m4a")
        try folder.cut("Plain.m4a", to: size - 10)
        #expect(await check(folder, "Plain.m4a", .m4a) == .damaged(.boxesDontAddUp))
    }

    @Test func anM4AWithExtraBytesAfterItsBoxesLooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Old App.m4a")
        try folder.append(Data("trailing".utf8), to: "Old App.m4a")
        #expect(await check(folder, "Old App.m4a", .m4a) == .damaged(.boxesDontAddUp))
    }

    @Test func anM4AMuchShorterThanTIDALsLengthLooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("ffmpeg-aac.m4a", as: "Old App.m4a")
        let verdict = await check(folder, "Old App.m4a", .m4a, tidal: 30)
        guard case let .damaged(.lengthDiffers(fileSeconds, tidalSeconds)) = verdict else {
            Issue.record("expected a length difference, got \(verdict)")
            return
        }
        #expect(abs(fileSeconds - 1) < 0.1 && tidalSeconds == 30)
    }

    @Test func aFileThatIsntMP4LooksDamaged() async throws {
        let folder = try TestFolder()
        try folder.copyFixture("bts-16-44100.flac", as: "Really FLAC.m4a")
        #expect(await check(folder, "Really FLAC.m4a", .m4a) != .healthy)
    }
}
