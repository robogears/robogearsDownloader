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

    @Test("a DASH run that leaves out its sizes takes them from tfhd, or else from trex, and saves the same file")
    func defaultSizes() throws {
        // A default size fits a run whose packets are all that size, so each
        // such run here holds one packet. Packets 0 and 20 differ in size, so
        // taking the wrong default would misplace every later packet.
        let first = UInt32(plain.packets[0].count), other = UInt32(plain.packets[20].count)
        try #require(first != other)
        let source = SyntheticM4A.fragmented(plain, trexDuration: 1024, trexSize: other, segments: [
            // tfhd's default wins over trex's.
            .init(tfhdFlags: 0x02_0010, defaultSize: first,
                  runs: [.init(packets: 0..<1, sizes: false), .init(packets: 1..<20, dataOffset: false)]),
            .init(runs: [.init(packets: 20..<21, sizes: false), .init(packets: 21..<44, dataOffset: false)]),
            .init(runs: [.init(packets: 44..<45, durations: true)]),
        ])
        let read = try MP4AudioTrackReader.read(source)
        #expect(read.samples.map { source.subdata(in: $0.range) } == plain.packets)
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

    /// A track shaped so every table is as large as it can be: each packet
    /// has its own duration and size, and the packets per chunk alternate
    /// 1, 2 (700 KB alone, then two of 400 KB), so stsc needs an entry for
    /// every chunk.
    func largestTables(count: Int) -> MP4AudioTrack {
        var track = syntheticTrack(count: count, size: 1)
        let sizes = [700_000, 400_000, 400_000]
        track.samples = (0..<count).map { MP4Sample(offset: 0, size: sizes[$0 % 3] + $0, duration: UInt32($0 + 1)) }
        return track
    }

    @Test("a corrupt file whose sample tables would pass 4 GB is refused before any table is built, not crashed on")
    func oversizedTablesRefused() throws {
        let track = largestTables(count: 3000)
        let tags = FLACTags(title: "Odd")
        let layout = try M4AWriter.layout(track, tags: tags, coverJPEG: nil, toolName: "test")
        let (boxes, _) = try split(layout.header)
        let stbl = MP4Inspector.sampleTablePath
        #expect(try entries(MP4Inspector.box(boxes, stbl + ["stts"])).count == 3000)
        #expect(try entries(MP4Inspector.box(boxes, stbl + ["stsc"])).count == 2000)
        let moovBytes = UInt64(boxes.count - M4AWriter.fileType().count)

        // The limit stands in for 4 GB: a moov even one byte over it is
        // refused, so the bound the guard checks covers these tables.
        #expect(throws: M4AFormatError.unsupportedMP4("sample tables larger than 4 GB")) {
            try M4AWriter.layout(track, tags: tags, coverJPEG: nil, toolName: "test", movieByteLimit: moovBytes - 1)
        }
        // The real limit is the 32-bit box size, and still far beyond any real
        // track: a month of 320 kbps AAC at 44.1 kHz (112 million packets)
        // needs about a third of it.
        #expect(M4AWriter.maximumMovieBytes == UInt64(UInt32.max))
        let month = 30 * 24 * 3600
        let bound = M4AWriter.movieBytesBound(sampleCount: month * 44100 / 1024,
                                              chunkCount: month * 40_000 / M4AWriter.maximumChunkBytes * 2, otherBytes: 1 << 20)
        #expect(bound < M4AWriter.maximumMovieBytes / 2)
    }

    @Test("a track whose every packet has its own duration is laid out in moments, not minutes")
    func everyDurationDifferentIsQuick() {
        // stts needs an entry per packet here. Joining the entries by copying
        // the growing table at every step took time growing with the square
        // of their number (half a minute for these in a debug build), and
        // nothing could cancel it. Built in one buffer, it takes about as long
        // as the stsz table for as many packets, so that table is timed just
        // before and after: on a busy machine both slow down together.
        let count = 100_000
        let durations = (0..<count).map { UInt32($0 + 1) }
        let sizes = (0..<count).map { $0 + 1 }
        let clock = ContinuousClock()
        var stsz = Data(), stts = Data()
        let before = clock.measure { stsz = MP4BoxWriter.sampleSizes(sizes) }
        let elapsed = clock.measure { stts = MP4BoxWriter.timeToSample(durations) }
        let after = clock.measure { stsz = MP4BoxWriter.sampleSizes(sizes) }
        #expect(stsz.count == 20 + 4 * count)
        #expect(stts.count == 16 + 8 * count)
        // Size, type, version and flags, the entry count, then (1, 1), (1, 2), …
        #expect(stts.prefix(32) == SyntheticFMP4.u32(UInt32(16 + 8 * count)) + Data("stts".utf8)
            + SyntheticFMP4.u32(0, UInt32(count), 1, 1, 1, 2))
        #expect(stts.suffix(8) == SyntheticFMP4.u32(1, UInt32(count)))
        #expect(elapsed < max(before, after) * 15)
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
