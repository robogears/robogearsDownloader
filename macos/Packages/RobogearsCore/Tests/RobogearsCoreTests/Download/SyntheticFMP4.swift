import Foundation
@testable import RobogearsCore

/// Small fragmented MP4 files built box by box, for the extractor rules no
/// FFmpeg fixture reaches: every DASH fixture has the same tfhd flags
/// (0x20038), runs that always carry a data offset, and a trex default size
/// of 0 (spike review, 21 Oct 2026). Only the fields the extractor reads are
/// filled in; the rest are zeros.
enum SyntheticFMP4 {
    static func box(_ type: String, _ body: Data) -> Data {
        var w = FLACByteWriter()
        w.u32be(UInt32(8 + body.count))
        w.append(Data(type.utf8))
        w.append(body)
        return w.data
    }

    /// A box whose body starts with a version byte and 24 bits of flags.
    static func fullBox(_ type: String, flags: UInt32 = 0, _ body: Data = Data()) -> Data {
        var w = FLACByteWriter()
        w.u32be(flags & 0xFF_FFFF)
        w.append(body)
        return box(type, w.data)
    }

    static func u32(_ values: UInt32...) -> Data {
        var w = FLACByteWriter()
        for v in values { w.u32be(v) }
        return w.data
    }

    /// `size` bytes that start with a valid 256-sample FLAC frame header
    /// (with its CRC-8), then zeros. The extractor checks headers only.
    static func frame(number: UInt8, size: Int) -> Data {
        let header: [UInt8] = [0xFF, 0xF8, 0x69, 0x18, number & 0x7F, 0xFF]
        let crc = header.reduce(UInt8(0)) { FLACFrameHeader.crc8Table[Int($0 ^ $1)] }
        return Data(header + [crc]) + Data(count: size - 7)
    }

    static let samplesPerFrame = 256

    /// ftyp and moov for one FLAC sound track with ID 1.
    static func initSegment(trexDefaultSize: UInt32 = 0) throws -> Data {
        let streamInfo = try FLACMetadataReader.read(AudioFixture.data("bts-16-44100.flac")).blocks[0].body
        let dfLa = fullBox("dfLa", Data([0x80, 0x00, 0x00, 0x22]) + streamInfo)
        let sampleEntry = box("fLaC", Data(count: 28) + dfLa)
        let stsd = fullBox("stsd", u32(1) + sampleEntry)
        let hdlr = fullBox("hdlr", u32(0) + Data("soun".utf8) + Data(count: 13))
        let mdia = box("mdia", hdlr + box("minf", box("stbl", stsd)))
        let tkhd = fullBox("tkhd", flags: 7, u32(0, 0, 1) + Data(count: 68))
        let trex = fullBox("trex", u32(1, 1, 0, trexDefaultSize, 0))
        let moov = box("moov", box("trak", tkhd + mdia) + box("mvex", trex))
        return box("ftyp", Data("iso5".utf8) + u32(512) + Data("iso5iso6mp41".utf8)) + moov
    }

    /// One track run: how many of the fragment's frames it takes, whether it
    /// carries a data offset and per-sample sizes, and (for corrupt files) a
    /// sample count to write instead of the real one.
    struct Run {
        var samples: Int
        var dataOffset = true
        var sizes = true
        var claimedCount: UInt32?
    }

    /// A moof + mdat pair holding `frames`, described by `runs` in order.
    static func fragment(
        tfhdFlags: UInt32 = 0x02_0000, tfhdDefaultSize: UInt32? = nil, runs: [Run], frames: [Data]
    ) -> Data {
        func moof(dataStartFromMoof: Int) -> Data {
            var tfhd = FLACByteWriter()
            var flags = tfhdFlags
            tfhd.u32be(1) // track ID
            if flags & 0x01 != 0 { tfhd.u64be(0) } // base data offset
            if let size = tfhdDefaultSize {
                flags |= 0x10
                tfhd.u32be(size)
            }
            var truns = Data()
            var taken = 0
            for run in runs {
                var body = FLACByteWriter()
                body.u32be(run.claimedCount ?? UInt32(run.samples))
                if run.dataOffset {
                    let before = frames[..<taken].reduce(0) { $0 + $1.count }
                    body.u32be(UInt32(dataStartFromMoof + before))
                }
                if run.sizes {
                    for frame in frames[taken..<(taken + run.samples)] { body.u32be(UInt32(frame.count)) }
                }
                let runFlags: UInt32 = (run.dataOffset ? 0x01 : 0) | (run.sizes ? 0x200 : 0)
                truns.append(fullBox("trun", flags: runFlags, body.data))
                taken += run.samples
            }
            let traf = box("traf", fullBox("tfhd", flags: flags, tfhd.data) + truns)
            return box("moof", fullBox("mfhd", u32(1)) + traf)
        }
        // A run's data offset counts from the moof's first byte, so measure
        // the moof once, then write it with the real offsets.
        let size = moof(dataStartFromMoof: 0).count
        return moof(dataStartFromMoof: size + 8) + box("mdat", frames.reduce(Data(), +))
    }
}
