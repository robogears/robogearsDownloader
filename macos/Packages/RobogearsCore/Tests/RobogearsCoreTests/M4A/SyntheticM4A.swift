import Foundation
import Testing
@testable import RobogearsCore

/// The plain AAC fixture's 45 packets laid out in ways no FFmpeg fixture
/// reaches: a progressive file with uneven chunks, gaps between them and
/// 64-bit chunk offsets, and fragmented files whose runs take their sizes,
/// durations and data offsets from every place the spec allows. The writer
/// should save each of them as the very same file it saves for the plain
/// fixture. Built with the FLAC tests' box helpers, not the writer's, and
/// only the fields the reader looks at are filled in.
enum SyntheticM4A {
    typealias S = SyntheticFMP4

    /// What the plain fixture's own tables say, used to rebuild it.
    struct Source {
        var packets: [Data]
        var durations: [UInt32]
        var sampleEntry: Data
        var timescale: UInt32
        var movieTimescale: UInt32
        var language: UInt16
        var edit: MP4AudioTrack.Edit?

        static func plainFixture() throws -> Source {
            let data = try AudioFixture.data("aac-320.m4a")
            let track = try MP4AudioTrackReader.read(data)
            return Source(
                packets: track.samples.map { data.subdata(in: $0.range) }, durations: track.samples.map(\.duration),
                sampleEntry: track.sampleEntry, timescale: track.timescale, movieTimescale: track.movieTimescale,
                language: track.language, edit: track.edit
            )
        }
    }

    static func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func u64(_ v: UInt64) -> Data { S.u32(UInt32(v >> 32), UInt32(v & 0xFFFF_FFFF)) }

    static let ftyp = S.box("ftyp", Data("M4A ".utf8) + S.u32(0) + Data("M4A isom".utf8))

    static func movieHeader(_ source: Source) -> Data {
        S.fullBox("mvhd", S.u32(0, 0, source.movieTimescale, 0) + Data(count: 80))
    }

    /// One sound track (ID 1) around `sampleTable`'s boxes.
    static func track(_ source: Source, edit: MP4AudioTrack.Edit?, sampleTable: Data) -> Data {
        var trak = S.fullBox("tkhd", flags: 3, S.u32(0, 0, 1, 0, 0) + Data(count: 60))
        if let edit {
            trak += S.box("edts", S.fullBox("elst", S.u32(1, UInt32(edit.segmentDuration), UInt32(edit.mediaTime), 0x0001_0000)))
        }
        let minf = S.box("minf",
            S.fullBox("smhd", S.u32(0))
            + S.box("dinf", S.fullBox("dref", S.u32(1) + S.fullBox("url ", flags: 1)))
            + S.box("stbl", S.fullBox("stsd", S.u32(1) + source.sampleEntry) + sampleTable))
        trak += S.box("mdia",
            S.fullBox("mdhd", S.u32(0, 0, source.timescale, 0) + u16(source.language) + u16(0))
            + S.fullBox("hdlr", S.u32(0) + Data("soun".utf8) + Data(count: 12) + Data([0]))
            + minf)
        return S.box("trak", trak)
    }

    // MARK: Progressive

    /// The packets in chunks of `chunkSizes` (repeated until every packet is
    /// placed), each chunk after `gap` bytes that belong to no sample, with
    /// stco or, when `wide`, co64.
    static func progressive(_ source: Source, chunkSizes: [Int], gap: Int, wide: Bool) -> Data {
        var chunks: [Range<Int>] = []
        var next = 0
        while next < source.packets.count {
            let size = min(chunkSizes[chunks.count % chunkSizes.count], source.packets.count - next)
            chunks.append(next..<(next + size))
            next += size
        }
        var body = Data()
        var starts: [Int] = []
        for chunk in chunks {
            body += Data(repeating: 0xEE, count: gap)
            starts.append(body.count)
            for i in chunk { body += source.packets[i] }
        }

        // stsc: a new run wherever the samples per chunk change.
        var runs = Data()
        var runCount: UInt32 = 0
        for (index, chunk) in chunks.enumerated() where index == 0 || chunk.count != chunks[index - 1].count {
            runs += S.u32(UInt32(index + 1), UInt32(chunk.count), 1)
            runCount += 1
        }
        var times = Data()
        for d in source.durations { times += S.u32(1, d) }
        func moov(mdatBody: Int) -> Data {
            let offsets = starts.map { UInt64(mdatBody + $0) }
            let table = S.fullBox("stts", S.u32(UInt32(source.durations.count)) + times)
                + S.fullBox("stsc", S.u32(runCount) + runs)
                + S.fullBox("stsz", S.u32(0, UInt32(source.packets.count)) + source.packets.map { S.u32(UInt32($0.count)) }.reduce(Data(), +))
                + (wide
                    ? S.fullBox("co64", S.u32(UInt32(offsets.count)) + offsets.map(u64).reduce(Data(), +))
                    : S.fullBox("stco", S.u32(UInt32(offsets.count)) + offsets.map { S.u32(UInt32($0)) }.reduce(Data(), +)))
            return S.box("moov", movieHeader(source) + track(source, edit: source.edit, sampleTable: table))
        }
        let mdatBody = ftyp.count + moov(mdatBody: 0).count + 8
        return ftyp + moov(mdatBody: mdatBody) + S.box("mdat", body)
    }

    // MARK: Fragmented

    struct Run {
        var packets: Range<Int>
        /// The run states where its data starts, counted from the moof.
        var dataOffset = true
        /// The run lists each sample's duration.
        var durations = false
        /// The run lists each sample's size; without, the size is tfhd's or trex's.
        var sizes = true
    }

    struct Segment {
        var tfhdFlags: UInt32 = 0x02_0000 // default-base-is-moof
        /// Written when `tfhdFlags` has 0x08.
        var defaultDuration: UInt32 = 0
        /// Written when `tfhdFlags` has 0x10.
        var defaultSize: UInt32 = 0
        var runs: [Run]
    }

    /// An init segment (with trex's default duration and size and the
    /// source's edit, its length left as 0 the way a DASH packager writes
    /// it), then one moof + mdat per segment.
    static func fragmented(_ source: Source, trexDuration: UInt32, trexSize: UInt32 = 0, segments: [Segment]) -> Data {
        let edit = source.edit.map { MP4AudioTrack.Edit(segmentDuration: 0, mediaTime: $0.mediaTime) }
        let emptyTable = S.fullBox("stts", S.u32(0)) + S.fullBox("stsc", S.u32(0))
            + S.fullBox("stsz", S.u32(0, 0)) + S.fullBox("stco", S.u32(0))
        let mvex = S.box("mvex", S.fullBox("trex", S.u32(1, 1, trexDuration, trexSize, 0)))
        var file = ftyp + S.box("moov", movieHeader(source) + track(source, edit: edit, sampleTable: emptyTable) + mvex)

        for (number, segment) in segments.enumerated() {
            var tfhd = S.u32(1)
            if segment.tfhdFlags & 0x01 != 0 { tfhd += u64(0) }
            if segment.tfhdFlags & 0x08 != 0 { tfhd += S.u32(segment.defaultDuration) }
            if segment.tfhdFlags & 0x10 != 0 { tfhd += S.u32(segment.defaultSize) }
            // A run's data offset depends on the moof's size, which doesn't
            // depend on the offsets' values: measure, then fill in.
            func moof(size: Int) -> Data {
                var truns = Data()
                var position = 0
                for run in segment.runs {
                    var flags: UInt32 = 0
                    if run.dataOffset { flags |= 0x01 }
                    if run.sizes { flags |= 0x200 }
                    if run.durations { flags |= 0x100 }
                    var body = S.u32(UInt32(run.packets.count))
                    if run.dataOffset { body += S.u32(UInt32(size + 8 + position)) }
                    for i in run.packets {
                        if run.durations { body += S.u32(source.durations[i]) }
                        if run.sizes { body += S.u32(UInt32(source.packets[i].count)) }
                        position += source.packets[i].count
                    }
                    truns += S.fullBox("trun", flags: flags, body)
                }
                return S.box("moof",
                    S.fullBox("mfhd", S.u32(UInt32(number + 1)))
                    + S.box("traf", S.fullBox("tfhd", flags: segment.tfhdFlags, tfhd) + S.fullBox("tfdt", S.u32(0)) + truns))
            }
            let mdat = segment.runs.flatMap { $0.packets }.reduce(Data()) { $0 + source.packets[$1] }
            file += moof(size: moof(size: 0).count) + S.box("mdat", mdat)
        }
        return file
    }
}
