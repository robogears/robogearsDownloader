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

    // MARK: Layouts the FFmpeg fixtures don't reach

    /// The fixture's first box of `type` found by walking `path` from the top.
    func box(_ data: Data, _ path: [String]) throws -> FMP4Box {
        let r = FLACByteReader(data)
        let top = try FMP4FLACExtractor.boxes(r, in: 0..<data.count)
        let first = try #require(top.first { $0.type == path[0] })
        return try #require(try FMP4FLACExtractor.path(r, Array(path.dropFirst()), from: first))
    }

    func renamed(_ data: Data, box target: FMP4Box, to type: String) -> Data {
        var copy = data
        copy.replaceSubrange((target.start + 4)..<(target.start + 8), with: Data(type.utf8))
        return copy
    }

    @Test("an explicit tfhd base data offset is refused")
    func tfhdBaseDataOffsetRefused() throws {
        // Joined segments lose the file each offset counted from (live check 1).
        var data = try AudioFixture.data("dash-24-96000.mp4")
        let tfhd = try box(data, ["moof", "traf", "tfhd"])
        data[tfhd.bodyStart + 3] |= 0x01
        #expect(throws: FLACFormatError.unsupportedMP4("tfhd base data offset")) { try FLACAudio(fragmentedMP4: data) }
    }

    @Test("an encrypted sample entry (enca) is refused by name")
    func encryptedAudioRefused() throws {
        let data = try AudioFixture.data("dash-24-96000.mp4")
        let stsd = try box(data, ["moov", "trak", "mdia", "minf", "stbl", "stsd"])
        let entry = try #require(try FMP4FLACExtractor.boxes(FLACByteReader(data), in: (stsd.bodyStart + 8)..<stsd.end).first)
        #expect(entry.type == "fLaC")
        #expect(throws: FLACFormatError.unsupportedMP4("encrypted audio")) {
            try FLACAudio(fragmentedMP4: renamed(data, box: entry, to: "enca"))
        }
    }

    @Test("a FLAC sample entry without a dfLa box is refused")
    func missingDfLaRefused() throws {
        let data = try AudioFixture.data("dash-24-96000.mp4")
        let stsd = try box(data, ["moov", "trak", "mdia", "minf", "stbl", "stsd"])
        let r = FLACByteReader(data)
        let entry = try #require(try FMP4FLACExtractor.boxes(r, in: (stsd.bodyStart + 8)..<stsd.end).first)
        let dfLa = try #require(try FMP4FLACExtractor.boxes(r, in: (entry.bodyStart + 28)..<entry.end).first { $0.type == "dfLa" })
        #expect(throws: FLACFormatError.missingFLACConfiguration) {
            try FLACAudio(fragmentedMP4: renamed(data, box: dfLa, to: "free"))
        }
    }

    @Test("a progressive (unfragmented) MP4 is refused as having no movie fragments")
    func progressiveMP4Refused() throws {
        // FFmpeg read these; the native reader doesn't yet (spike write-up,
        // recommendation). Same file with every moof taken out, mdats kept.
        let data = try AudioFixture.data("dash-24-96000.mp4")
        let top = try FMP4FLACExtractor.boxes(FLACByteReader(data), in: 0..<data.count)
        let progressive = top.filter { $0.type != "moof" }.reduce(Data()) { $0 + data.subdata(in: $1.start..<$1.end) }
        #expect(throws: FLACFormatError.unsupportedMP4("no movie fragments")) { try FLACAudio(fragmentedMP4: progressive) }
        #expect(throws: FLACFormatError.unsupportedMP4("no movie fragments")) { try FLACAudio(downloaded: progressive) }
    }

    @Test("a run with neither a data offset nor sample sizes takes the next mdat and the track's default size")
    func runUsesFollowingMdatAndTrexSize() throws {
        let frames = (0..<3).map { SyntheticFMP4.frame(number: UInt8($0), size: 32) }
        let file = try SyntheticFMP4.initSegment(trexDefaultSize: 32)
            + SyntheticFMP4.fragment(runs: [.init(samples: 3, dataOffset: false, sizes: false)], frames: frames)
        let audio = try FLACAudio(fragmentedMP4: file)
        #expect(audio.framesData() == frames.reduce(Data(), +))
        #expect(audio.countedSampleCount == UInt64(3 * SyntheticFMP4.samplesPerFrame))
    }

    @Test("the fragment's default size wins over the track's")
    func tfhdDefaultSizeWins() throws {
        let frames = (0..<2).map { SyntheticFMP4.frame(number: UInt8($0), size: 40) }
        let file = try SyntheticFMP4.initSegment(trexDefaultSize: 32)
            + SyntheticFMP4.fragment(tfhdDefaultSize: 40, runs: [.init(samples: 2, sizes: false)], frames: frames)
        #expect(try FLACAudio(fragmentedMP4: file).framesData() == frames.reduce(Data(), +))
    }

    @Test("a second run without a data offset continues where the first ended")
    func runContinuesFromCursor() throws {
        let frames = [40, 50, 30, 60].enumerated().map { SyntheticFMP4.frame(number: UInt8($0.offset), size: $0.element) }
        let file = try SyntheticFMP4.initSegment() + SyntheticFMP4.fragment(
            runs: [.init(samples: 2), .init(samples: 2, dataOffset: false)], frames: frames
        )
        let audio = try FLACAudio(fragmentedMP4: file)
        #expect(audio.framesData() == frames.reduce(Data(), +))
        #expect(audio.frameRanges.count == 1)
        #expect(audio.countedSampleCount == UInt64(4 * SyntheticFMP4.samplesPerFrame))
    }

    @Test("a run with no sample sizes anywhere is refused")
    func noSampleSizesRefused() throws {
        let frames = [SyntheticFMP4.frame(number: 0, size: 32)]
        let file = try SyntheticFMP4.initSegment()
            + SyntheticFMP4.fragment(runs: [.init(samples: 1, sizes: false)], frames: frames)
        #expect(throws: FLACFormatError.unsupportedMP4("no sample sizes")) { try FLACAudio(fragmentedMP4: file) }
    }

    @Test("a run claiming more samples than its mdat holds is refused before its samples are listed")
    func corruptCountRefusedWhileListing() throws {
        // With only a default size, nothing else bounds the count; the
        // extractor must not build one range per claimed sample first.
        func samples(_ file: Data) throws -> [Range<Int>] {
            let r = FLACByteReader(file)
            let top = try FMP4FLACExtractor.boxes(r, in: 0..<file.count)
            let moov = try #require(top.first { $0.type == "moov" })
            let moofIndex = try #require(top.firstIndex { $0.type == "moof" })
            let traf = try #require(try FMP4FLACExtractor.child(r, "traf", in: top[moofIndex]))
            return try FMP4FLACExtractor.trackFragmentSamples(
                r, traf: traf, moof: top[moofIndex], trackID: 1,
                defaults: FMP4FLACExtractor.trackDefaults(r, moov: moov, trackID: 1),
                followingMdat: top[(moofIndex + 1)...].first { $0.type == "mdat" }?.bodyStart,
                mdats: top.filter { $0.type == "mdat" }.map(\.body)
            )
        }
        let frame = SyntheticFMP4.frame(number: 0, size: 40)
        let defaultSized = try SyntheticFMP4.initSegment()
            + SyntheticFMP4.fragment(tfhdDefaultSize: 1, runs: [.init(samples: 1, sizes: false, claimedCount: 200)], frames: [frame])
        #expect(defaultSized.count > 200) // so the old whole-file bound let it through
        #expect(throws: FLACFormatError.truncated("MP4 sample outside its mdat")) { try samples(defaultSized) }

        // Per-sample sizes: the first sample that runs past the mdat stops the listing.
        var sized = try SyntheticFMP4.initSegment()
            + SyntheticFMP4.fragment(runs: [.init(samples: 2)], frames: [frame, SyntheticFMP4.frame(number: 1, size: 40)])
        let trun = try box(sized, ["moof", "traf", "trun"])
        sized.replaceSubrange((trun.bodyStart + 16)..<(trun.bodyStart + 20), with: SyntheticFMP4.u32(41))
        #expect(throws: FLACFormatError.truncated("MP4 sample outside its mdat")) { try samples(sized) }
        #expect(throws: FLACFormatError.truncated("MP4 sample outside its mdat")) { try FLACAudio(fragmentedMP4: sized) }
    }

    @Test("the download reader drops an ID3v2 tag in front of a native FLAC")
    func downloadedNativeWithID3() throws {
        let flac = try AudioFixture.data("bts-16-44100.flac")
        let tagged = Data("ID3".utf8) + Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14]) + Data(count: 20) + flac
        let audio = try FLACAudio(downloaded: tagged)
        #expect(audio.frameRanges == [(30 + 8288)..<tagged.count])
        #expect(audio.framesData() == (try AudioFixture.frames(ofFLAC: flac)))
        let written = try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: nil)
        #expect(written.prefix(4) == Data("fLaC".utf8))
        #expect(try FLACMetadataReader.read(written).leadingTagSize == 0)
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
