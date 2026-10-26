import Foundation
import Testing
@testable import RobogearsCore

/// Source layouts and file sizes the fixtures don't reach (D4 2.10's AAC
/// fallback). TIDAL's real AAC container is a live check (spike, "Needs a
/// live TIDAL check" 3), so every layout the spec allows for one sound
/// track is read the same way: each gives the very file the plain fixture gives.
@Suite("AAC .m4a layouts")
struct M4ALayoutTests {
    let plain: SyntheticM4A.Source
    let expected: Data

    init() throws {
        plain = try SyntheticM4A.Source.plainFixture()
        expected = try Self.save(AudioFixture.data("aac-320.m4a"))
    }

    /// The bytes the writer saves for `source`, with fixed tags and cover.
    static func save(_ source: Data) throws -> Data {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        _ = try M4AWriter.write(source, tags: AudioFixture.tags, coverJPEG: AudioFixture.data("cover.jpg"), toolName: "test", to: url)
        return try Data(contentsOf: url)
    }

    // MARK: Progressive sources

    @Test("a plain download stored in uneven chunks with gaps between them saves the same file",
          arguments: [false, true])
    func unevenChunks(wideOffsets: Bool) throws {
        let source = SyntheticM4A.progressive(plain, chunkSizes: [7, 3, 3, 11], gap: 13, wide: wideOffsets)
        let read = try MP4AudioTrackReader.read(source)
        #expect(read.samples.map { source.subdata(in: $0.range) } == plain.packets)
        #expect(read.samples.map(\.duration) == plain.durations)
        #expect(try Self.save(source) == expected)
    }

    // MARK: Fragmented sources

    /// Every way a run can find its data and its durations: right after the
    /// mdat, after the previous run, at a stated offset; from trex, from
    /// tfhd, from the run itself (which holds the short last packet).
    static let fragmentLayouts: [(trexDuration: UInt32, segments: [SyntheticM4A.Segment])] = [
        (1024, [
            .init(tfhdFlags: 0, runs: [.init(packets: 0..<10, dataOffset: false)]),
            .init(tfhdFlags: 0x02_0008, defaultDuration: 1024,
                  runs: [.init(packets: 10..<20), .init(packets: 20..<30, dataOffset: false)]),
            .init(runs: [.init(packets: 30..<45, durations: true)]),
        ]),
        // tfhd's default wins over trex's (which would give the wrong length).
        (500, [
            .init(tfhdFlags: 0x08, defaultDuration: 1024, runs: [.init(packets: 0..<25, dataOffset: false)]),
            .init(tfhdFlags: 0x02_0008, defaultDuration: 1024, runs: [.init(packets: 25..<40)]),
            .init(runs: [.init(packets: 40..<45, durations: true)]),
        ]),
    ]

    @Test("a joined DASH download saves the same file whichever way its runs give offsets and durations",
          arguments: 0..<2)
    func fragmentLayouts(layout: Int) throws {
        let (trex, segments) = Self.fragmentLayouts[layout]
        let source = SyntheticM4A.fragmented(plain, trexDuration: trex, segments: segments)
        let read = try MP4AudioTrackReader.read(source)
        #expect(read.isFragmented)
        #expect(read.samples.map { source.subdata(in: $0.range) } == plain.packets)
        #expect(read.samples.map(\.duration) == plain.durations)
        #expect(try Self.save(source) == expected)
    }

    @Test("a DASH run with no duration anywhere, or offsets counted from the lost segment file, is refused")
    func unreadableFragmentsRefused() throws {
        let noDuration = SyntheticM4A.fragmented(plain, trexDuration: 0, segments: [
            .init(runs: [.init(packets: 0..<45)]),
        ])
        #expect(throws: M4AFormatError.unsupportedMP4("no sample durations")) { try Self.save(noDuration) }
        let baseOffset = SyntheticM4A.fragmented(plain, trexDuration: 1024, segments: [
            .init(tfhdFlags: 0x01, runs: [.init(packets: 0..<45)]),
        ])
        #expect(throws: M4AFormatError.unsupportedMP4("tfhd base data offset")) { try Self.save(baseOffset) }
    }

    // MARK: Long and very large files

    /// A track of `count` packets of `size` bytes, without real audio:
    /// the layout only needs sizes and durations.
    func syntheticTrack(count: Int, size: Int) -> MP4AudioTrack {
        MP4AudioTrack(
            sampleEntry: plain.sampleEntry, sampleEntryType: "mp4a", timescale: 44100, language: plain.language,
            movieTimescale: 1000, edit: nil,
            samples: Array(repeating: MP4Sample(offset: 0, size: size, duration: 1024), count: count), isFragmented: false
        )
    }

    /// The header's ftyp and moov (the part a box walker can read without
    /// the samples), and the mdat header after them.
    func split(_ header: Data) throws -> (boxes: Data, mdatHeader: Data) {
        let r = FLACByteReader(header)
        let moovEnd = Int(r.u32be(0)) + Int(r.u32be(Int(r.u32be(0))))
        return (header.prefix(moovEnd), header.subdata(in: moovEnd..<header.count))
    }

    /// A table box's 32-bit entries after its version, flags and count.
    func entries(_ box: Data?, width: Int = 4) throws -> [UInt64] {
        let box = try #require(box)
        let r = FLACByteReader(box)
        let count = Int(r.u32be(12))
        return (0..<count).map { width == 8 ? r.u64be(16 + 8 * $0) : UInt64(r.u32be(16 + 4 * $0)) }
    }

    @Test("a long track is split into chunks below 1 MiB, as FFmpeg does")
    func chunksBelowOneMiB() throws {
        // 1048 packets of 1000 bytes fit under 1 MiB (1,048,576 bytes); 1049 don't.
        let layout = try M4AWriter.layout(syntheticTrack(count: 3000, size: 1000), tags: FLACTags(title: "Long"),
                                          coverJPEG: nil, toolName: "test")
        let (boxes, mdat) = try split(layout.header)
        let stbl = MP4Inspector.sampleTablePath
        let stsc = try #require(try MP4Inspector.box(boxes, stbl + ["stsc"]))
        #expect(stsc == SyntheticFMP4.fullBox("stsc", SyntheticFMP4.u32(2, 1, 1048, 1, 3, 904, 1)))
        let base = UInt64(layout.header.count)
        #expect(try entries(MP4Inspector.box(boxes, stbl + ["stco"])) == [base, base + 1_048_000, base + 2_096_000])
        #expect(try MP4Inspector.box(boxes, stbl + ["stsz"]) == SyntheticFMP4.fullBox("stsz", SyntheticFMP4.u32(1000, 3000)))
        #expect(mdat == SyntheticFMP4.u32(3_000_008) + Data("mdat".utf8))
        #expect(layout.durationSeconds == 3000 * 1024 / 44100.0)
    }

    @Test("the sample limit keeps the largest table, stts with every duration different, under a 32-bit box size")
    func sampleLimitFitsTheTables() {
        // stts: box header, version and flags, the run count, then 8 bytes per run.
        let worstStts = 16 + 8 * UInt64(M4AWriter.maximumSampleCount)
        #expect(worstStts < UInt64(UInt32.max) - (1 << 20))
        // The limit is still far beyond any real track: a month of 44.1 kHz AAC.
        #expect(M4AWriter.maximumSampleCount > 30 * 24 * 3600 * 44100 / 1024)
    }

    @Test("a file past 4 GB gets 64-bit chunk offsets and a 64-bit mdat size")
    func past4GB() throws {
        let size = 1_200_000_000
        let layout = try M4AWriter.layout(syntheticTrack(count: 5, size: size), tags: FLACTags(title: "Huge"),
                                          coverJPEG: nil, toolName: "test")
        let (boxes, mdat) = try split(layout.header)
        let stbl = MP4Inspector.sampleTablePath
        let base = UInt64(layout.header.count)
        #expect(try MP4Inspector.box(boxes, stbl + ["stco"]) == nil)
        #expect(try entries(MP4Inspector.box(boxes, stbl + ["co64"]), width: 8) == (0..<5).map { base + UInt64($0 * size) })
        #expect(mdat == SyntheticFMP4.u32(1) + Data("mdat".utf8) + SyntheticM4A.u64(UInt64(5 * size + 16)))
    }
}
