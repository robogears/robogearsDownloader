import Foundation
import Testing
@testable import RobogearsCore

/// Taking FLAC out of a joined DASH download (init segment + media segments),
/// the way the Electron app's `.tmp.m4a` file was built.
@Suite("FLAC in fragmented MP4")
struct FMP4FLACExtractorTests {
    @Test("STREAMINFO comes from the dfLa box")
    func streamInfoFromDfLa() throws {
        let audio = try FLACAudio(fragmentedMP4: AudioFixture.data("dash-24-96000.mp4"))
        let original = try FLACMetadataReader.read(AudioFixture.data("bts-24-96000.flac")).streamInfo
        #expect(audio.streamInfo == original)
    }

    @Test("frames come out byte for byte as FFmpeg copied them")
    func framesMatchFFmpeg() throws {
        let audio = try FLACAudio(fragmentedMP4: AudioFixture.data("dash-24-96000.mp4"))
        let ffmpegFrames = try AudioFixture.frames(ofFLAC: AudioFixture.data("ffmpeg-dash-24-96000.flac"))
        let originalFrames = try AudioFixture.frames(ofFLAC: AudioFixture.data("bts-24-96000.flac"))
        #expect(audio.framesData() == ffmpegFrames)
        #expect(audio.framesData() == originalFrames)
        // Every segment's samples are contiguous, so each mdat becomes one range.
        #expect(audio.frameRanges.count == 3)
    }

    @Test("every frame's samples are counted, and the count matches dfLa")
    func countMatchesDeclared() throws {
        let audio = try FLACAudio(fragmentedMP4: AudioFixture.data("dash-24-96000.mp4"))
        #expect(audio.countedSampleCount == 57600)
        #expect(audio.declaredSampleCount == 57600)
        #expect(audio.sampleCountMatches == true)
    }

    @Test("an unknown sample count in dfLa is filled in from the frames")
    func unknownCountFilledIn() throws {
        let audio = try FLACAudio(fragmentedMP4: AudioFixture.data("dash-live-16-44100.mp4"))
        #expect(audio.declaredSampleCount == 0)
        #expect(audio.countedSampleCount == 44100)
        #expect(audio.streamInfo.totalSamples == 44100)
        #expect(audio.sampleCountMatches == nil)
        // Only the count changes; the encoder's other placeholders stay as they were.
        #expect(audio.streamInfo.minimumFrameSize == 0)
        #expect(audio.streamInfo.md5 == Data(count: 16))
        let ffmpegFrames = try AudioFixture.frames(ofFLAC: AudioFixture.data("ffmpeg-dash-live-16-44100.flac"))
        #expect(audio.framesData() == ffmpegFrames)
    }

    @Test("a segment's last frame, sized only by the fragment's default, is kept")
    func runWithoutPerSampleFields() throws {
        // FFmpeg ends the live fixture with a run that lists only a data offset;
        // its one sample takes tfhd's default size.
        let data = try AudioFixture.data("dash-live-16-44100.mp4")
        let top = try FMP4FLACExtractor.boxes(FLACByteReader(data), in: 0..<data.count)
        let lastMdat = try #require(top.last { $0.type == "mdat" })
        let audio = try FLACAudio(fragmentedMP4: data)
        #expect(audio.frameRanges.last?.upperBound == lastMdat.end)
    }

    @Test("a dropped segment shows up as a sample-count mismatch")
    func droppedSegmentIsVisible() throws {
        let data = try AudioFixture.data("dash-24-96000.mp4")
        let top = try FMP4FLACExtractor.boxes(FLACByteReader(data), in: 0..<data.count)
        let moofs = top.indices.filter { top[$0].type == "moof" }
        let secondMoof = top[moofs[1]]
        let itsMdat = try #require(top[moofs[1]...].first { $0.type == "mdat" })
        var shortened = data
        shortened.removeSubrange(secondMoof.start..<itsMdat.end)

        let audio = try FLACAudio(fragmentedMP4: shortened)
        #expect(audio.sampleCountMatches == false)
        #expect((audio.countedSampleCount ?? 0) < 57600)
    }

    @Test("AAC in MP4 is refused with its codec name")
    func aacRefused() throws {
        #expect(throws: FLACFormatError.notFLACInMP4(codec: "mp4a")) {
            try FLACAudio(fragmentedMP4: AudioFixture.data("dash-aac.mp4"))
        }
        #expect(throws: FLACFormatError.notFLACInMP4(codec: "mp4a")) {
            try FLACAudio(fragmentedMP4: AudioFixture.data("aac-320.m4a"))
        }
    }

    @Test("a native FLAC handed to the MP4 reader is refused")
    func nativeFLACIsNotMP4() throws {
        #expect(throws: FLACFormatError.notMP4) {
            try FLACAudio(fragmentedMP4: AudioFixture.data("bts-16-44100.flac"))
        }
    }

    @Test("a download cut off mid-segment is refused")
    func truncatedDownload() throws {
        let data = try AudioFixture.data("dash-24-96000.mp4")
        #expect(throws: FLACFormatError.self) { try FLACAudio(fragmentedMP4: data.prefix(data.count - 100)) }
    }

    @Test("a sample that doesn't start with a FLAC frame header is refused")
    func sampleIsNotAFrame() throws {
        var data = try AudioFixture.data("dash-24-96000.mp4")
        let top = try FMP4FLACExtractor.boxes(FLACByteReader(data), in: 0..<data.count)
        let firstMdat = try #require(top.first { $0.type == "mdat" })
        data[firstMdat.bodyStart] = 0x00
        #expect(throws: FLACFormatError.invalidFrame(offset: firstMdat.bodyStart)) {
            try FLACAudio(fragmentedMP4: data)
        }
    }

    @Test("a sample pointing outside its mdat is refused")
    func sampleOutsideMdat() throws {
        var data = try AudioFixture.data("dash-24-96000.mp4")
        let r = FLACByteReader(data)
        let top = try FMP4FLACExtractor.boxes(r, in: 0..<data.count)
        let moof = try #require(top.first { $0.type == "moof" })
        let traf = try #require(try FMP4FLACExtractor.child(r, "traf", in: moof))
        let trun = try #require(try FMP4FLACExtractor.child(r, "trun", in: traf))
        // The run's data offset follows its flags and sample count.
        data.replaceSubrange((trun.bodyStart + 8)..<(trun.bodyStart + 12), with: [0x00, 0x7F, 0x00, 0x00])
        #expect(throws: FLACFormatError.truncated("MP4 sample outside its mdat")) {
            try FLACAudio(fragmentedMP4: data)
        }
    }

    @Test("the download reader picks native FLAC or MP4 from the first bytes")
    func sniffing() throws {
        let native = try FLACAudio(downloaded: AudioFixture.data("bts-16-44100.flac"))
        #expect(native.countedSampleCount == nil)
        #expect(native.frameRanges == [8288..<73998])
        let dash = try FLACAudio(downloaded: AudioFixture.data("dash-24-96000.mp4"))
        #expect(dash.countedSampleCount == 57600)
    }

    @Test("64-bit box sizes and size 0 (to the end) are understood")
    func boxSizeForms() throws {
        var data = Data([0, 0, 0, 1]) + Data("free".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 24])
        data.append(Data(count: 8))
        data.append(Data([0, 0, 0, 0]) + Data("skip".utf8) + Data(count: 4))
        let boxes = try FMP4FLACExtractor.boxes(FLACByteReader(data), in: 0..<data.count)
        #expect(boxes == [
            FMP4Box(type: "free", start: 0, bodyStart: 16, end: 24),
            FMP4Box(type: "skip", start: 24, bodyStart: 32, end: 36),
        ])
    }

    @Test("a box claiming more bytes than are left is refused")
    func boxOverrun() {
        let data = Data([0, 0, 1, 0]) + Data("free".utf8) + Data(count: 8)
        #expect(throws: FLACFormatError.truncated("MP4 free box")) {
            try FMP4FLACExtractor.boxes(FLACByteReader(data), in: 0..<data.count)
        }
    }
}
