// Takes FLAC audio out of a fragmented MP4 (TIDAL's DASH streams).
//
// The Electron app downloaded the DASH init segment and every media segment,
// joined them in order into "<Title>.tmp.m4a", and let FFmpeg copy the
// audio into a .flac (download-pipeline.md B8 and B11). The joined file is
// an ordinary fragmented MP4: an init part (ftyp, moov) whose FLAC sample
// entry carries STREAMINFO in a dfLa box, then one moof + mdat pair per
// segment, where every sample is exactly one FLAC frame. So the native path
// is: STREAMINFO from dfLa, then each sample's bytes in order. Layout rules
// follow ISO/IEC 14496-12 (boxes, movie fragments) and the "Encapsulation
// of FLAC in ISO Base Media File Format" spec (dfLa).
import Foundation

extension FLACAudio {
    /// Takes the audio out of a joined DASH download (init segment, then
    /// media segments in order). Every sample must start with a valid FLAC
    /// frame header; the frames' samples are counted, and an unknown total
    /// in dfLa is filled in from that count.
    public init(fragmentedMP4 data: Data) throws {
        self = try FMP4FLACExtractor.extract(data)
    }

    /// Picks the right reader from the first bytes: "fLaC" (or an ID3 tag)
    /// is a native FLAC stream, anything else is read as fragmented MP4.
    /// The Electron app chose by the manifest's MIME type instead
    /// (download-pipeline.md B7); sniffing can't be fooled by a manifest
    /// that names the wrong type.
    ///
    /// These are the only two layouts taken. FFmpeg read any container, so a
    /// progressive (unfragmented) MP4 is where the native path falls short:
    /// it's refused with `unsupportedMP4("no movie fragments")`, and reading
    /// it would need the stsz/stsc/stco sample tables. Whether TIDAL ever
    /// sends one is a live check (docs/spikes/audio-and-tagging.md).
    public init(downloaded data: Data) throws {
        let r = FLACByteReader(data)
        let isNative = r.has(0, 4)
            && ((r.u8(0) == 0x66 && r.u8(1) == 0x4C && r.u8(2) == 0x61 && r.u8(3) == 0x43)
                || (r.u8(0) == 0x49 && r.u8(1) == 0x44 && r.u8(2) == 0x33))
        self = isNative ? try FLACAudio(nativeFLAC: data) : try FLACAudio(fragmentedMP4: data)
    }
}

/// One ISO BMFF box: where its header starts, where its body starts, and its end.
struct FMP4Box: Equatable {
    var type: String
    var start: Int
    var bodyStart: Int
    var end: Int

    var body: Range<Int> { bodyStart..<end }
}

enum FMP4FLACExtractor {
    /// Box types that can open a file or a segment. Anything else at offset 0
    /// means the data isn't MP4 at all.
    static let leadingBoxTypes: Set<String> = ["ftyp", "styp", "moov", "sidx", "free", "skip", "wide", "moof", "mdat", "emsg"]

    static func extract(_ data: Data) throws -> FLACAudio {
        let r = FLACByteReader(data)
        guard r.has(0, 8), leadingBoxTypes.contains(fourCC(r, 4)) else { throw FLACFormatError.notMP4 }
        let top = try boxes(r, in: 0..<r.count)

        guard let moov = top.first(where: { $0.type == "moov" }) else { throw FLACFormatError.unsupportedMP4("no moov box") }
        let track = try audioTrack(r, moov: moov)
        let defaults = try trackDefaults(r, moov: moov, trackID: track.id)

        let mdatBodies = top.filter { $0.type == "mdat" }.map(\.body)
        var ranges: [Range<Int>] = []
        var counted: UInt64 = 0
        var sawFragment = false

        for (index, box) in top.enumerated() where box.type == "moof" {
            sawFragment = true
            let followingMdat = top[(index + 1)...].first { $0.type == "mdat" }?.bodyStart
            for traf in try boxes(r, in: box.body) where traf.type == "traf" {
                let samples = try trackFragmentSamples(
                    r, traf: traf, moof: box, trackID: track.id, defaults: defaults,
                    followingMdat: followingMdat, mdats: mdatBodies
                )
                for sample in samples {
                    guard let header = FLACFrameHeader.parse(r, at: sample.lowerBound), header.length <= sample.count
                    else { throw FLACFormatError.invalidFrame(offset: sample.lowerBound) }
                    counted += UInt64(header.blockSize)
                    if let last = ranges.last, last.upperBound == sample.lowerBound {
                        ranges[ranges.count - 1] = last.lowerBound..<sample.upperBound
                    } else {
                        ranges.append(sample)
                    }
                }
            }
        }
        guard sawFragment else { throw FLACFormatError.unsupportedMP4("no movie fragments") }
        guard !ranges.isEmpty else { throw FLACFormatError.noAudioFrames }
        return FLACAudio(streamInfo: track.streamInfo, countedSampleCount: counted, source: data, frameRanges: ranges)
    }

    // MARK: Boxes

    static func fourCC(_ r: FLACByteReader, _ o: Int) -> String {
        String(decoding: [r.u8(o), r.u8(o + 1), r.u8(o + 2), r.u8(o + 3)], as: UTF8.self)
    }

    /// The boxes directly inside `range`. Size 1 means a 64-bit size follows;
    /// size 0 means "to the end of the enclosing range".
    static func boxes(_ r: FLACByteReader, in range: Range<Int>) throws -> [FMP4Box] {
        var result: [FMP4Box] = []
        var o = range.lowerBound
        while o < range.upperBound {
            guard range.upperBound - o >= 8 else { throw FLACFormatError.truncated("MP4 box header") }
            var size = Int(r.u32be(o))
            let type = fourCC(r, o + 4)
            var header = 8
            if size == 1 {
                guard range.upperBound - o >= 16 else { throw FLACFormatError.truncated("MP4 box header") }
                let large = r.u64be(o + 8)
                guard large <= UInt64(Int.max) else { throw FLACFormatError.truncated("MP4 box") }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = range.upperBound - o
            }
            guard size >= header, size <= range.upperBound - o else { throw FLACFormatError.truncated("MP4 \(type) box") }
            result.append(FMP4Box(type: type, start: o, bodyStart: o + header, end: o + size))
            o += size
        }
        return result
    }

    static func child(_ r: FLACByteReader, _ type: String, in box: FMP4Box) throws -> FMP4Box? {
        try boxes(r, in: box.body).first { $0.type == type }
    }

    static func path(_ r: FLACByteReader, _ types: [String], from box: FMP4Box) throws -> FMP4Box? {
        var current = box
        for type in types {
            guard let next = try child(r, type, in: current) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Track setup (moov)

    struct AudioTrack {
        var id: UInt32
        var streamInfo: FLACStreamInfo
    }

    /// The first sound track. Its sample entry must be "fLaC" with a dfLa box.
    static func audioTrack(_ r: FLACByteReader, moov: FMP4Box) throws -> AudioTrack {
        for trak in try boxes(r, in: moov.body) where trak.type == "trak" {
            guard let hdlr = try path(r, ["mdia", "hdlr"], from: trak), r.has(hdlr.bodyStart, 12),
                  fourCC(r, hdlr.bodyStart + 8) == "soun"
            else { continue }
            guard let tkhd = try child(r, "tkhd", in: trak), r.has(tkhd.bodyStart, 4) else {
                throw FLACFormatError.unsupportedMP4("track without tkhd")
            }
            // tkhd version 1 has 64-bit creation and modification times before the track ID.
            let idOffset = tkhd.bodyStart + (r.u8(tkhd.bodyStart) == 1 ? 20 : 12)
            guard idOffset + 4 <= tkhd.end else { throw FLACFormatError.truncated("MP4 tkhd box") }
            let trackID = r.u32be(idOffset)

            guard let stsd = try path(r, ["mdia", "minf", "stbl", "stsd"], from: trak), stsd.body.count >= 8 else {
                throw FLACFormatError.unsupportedMP4("sound track without stsd")
            }
            // stsd: version and flags, entry count, then the sample entries.
            guard let entry = try boxes(r, in: (stsd.bodyStart + 8)..<stsd.end).first else {
                throw FLACFormatError.unsupportedMP4("empty stsd")
            }
            switch entry.type {
            case "fLaC": break
            case "enca": throw FLACFormatError.unsupportedMP4("encrypted audio")
            default: throw FLACFormatError.notFLACInMP4(codec: entry.type)
            }
            // An AudioSampleEntry has 28 bytes of fixed fields before its child boxes.
            guard entry.body.count >= 28 else { throw FLACFormatError.truncated("MP4 fLaC sample entry") }
            let children = try boxes(r, in: (entry.bodyStart + 28)..<entry.end)
            guard let dfLa = children.first(where: { $0.type == "dfLa" }) else {
                throw FLACFormatError.missingFLACConfiguration
            }
            return AudioTrack(id: trackID, streamInfo: try streamInfo(r, dfLa: dfLa))
        }
        throw FLACFormatError.unsupportedMP4("no sound track")
    }

    /// dfLa holds a version-and-flags word, then FLAC metadata blocks whose
    /// first must be STREAMINFO.
    static func streamInfo(_ r: FLACByteReader, dfLa: FMP4Box) throws -> FLACStreamInfo {
        let o = dfLa.bodyStart + 4
        guard o + 4 <= dfLa.end else { throw FLACFormatError.truncated("dfLa box") }
        let type = r.u8(o) & 0x7F
        let length = Int(r.u24be(o + 1))
        guard type == FLACBlockType.streamInfo.rawValue, length == FLACStreamInfo.byteCount else {
            throw FLACFormatError.invalidStreamInfo
        }
        guard o + 4 + length <= dfLa.end else { throw FLACFormatError.truncated("dfLa box") }
        return try FLACStreamInfo(bytes: r.bytes(o + 4, length))
    }

    struct SampleDefaults {
        var size: UInt32?
    }

    /// The track's default sample size from mvex/trex, used when neither the
    /// fragment header nor the run gives one.
    static func trackDefaults(_ r: FLACByteReader, moov: FMP4Box, trackID: UInt32) throws -> SampleDefaults {
        guard let mvex = try child(r, "mvex", in: moov) else { return SampleDefaults() }
        for trex in try boxes(r, in: mvex.body) where trex.type == "trex" {
            guard trex.body.count >= 24 else { throw FLACFormatError.truncated("MP4 trex box") }
            if r.u32be(trex.bodyStart + 4) == trackID {
                let size = r.u32be(trex.bodyStart + 16)
                return SampleDefaults(size: size == 0 ? nil : size)
            }
        }
        return SampleDefaults()
    }

    // MARK: Fragments (moof)

    /// The byte ranges of one track fragment's samples, in order. Every
    /// sample lies inside one of `mdats` (the file's mdat bodies), or this throws.
    ///
    /// Offsets in a run count from the start of the moof (tfhd's
    /// default-base-is-moof flag, or the spec's rule for the first track
    /// fragment when no base offset is given). An explicit base data offset
    /// is refused: it counts from the start of the original segment file,
    /// which is unknown once segments are joined.
    static func trackFragmentSamples(
        _ r: FLACByteReader, traf: FMP4Box, moof: FMP4Box, trackID: UInt32,
        defaults: SampleDefaults, followingMdat: Int?, mdats: [Range<Int>]
    ) throws -> [Range<Int>] {
        let children = try boxes(r, in: traf.body)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }), tfhd.body.count >= 8 else {
            throw FLACFormatError.unsupportedMP4("track fragment without tfhd")
        }
        let tfhdFlags = r.u32be(tfhd.bodyStart) & 0xFF_FFFF
        guard r.u32be(tfhd.bodyStart + 4) == trackID else { return [] }
        guard tfhdFlags & 0x01 == 0 else { throw FLACFormatError.unsupportedMP4("tfhd base data offset") }
        var o = tfhd.bodyStart + 8
        if tfhdFlags & 0x02 != 0 { o += 4 } // sample description index
        if tfhdFlags & 0x08 != 0 { o += 4 } // default sample duration
        var defaultSize = defaults.size
        if tfhdFlags & 0x10 != 0 {
            guard o + 4 <= tfhd.end else { throw FLACFormatError.truncated("MP4 tfhd box") }
            defaultSize = r.u32be(o)
        }

        var samples: [Range<Int>] = []
        var cursor: Int? = nil
        for trun in children where trun.type == "trun" {
            guard trun.body.count >= 8 else { throw FLACFormatError.truncated("MP4 trun box") }
            let flags = r.u32be(trun.bodyStart) & 0xFF_FFFF
            let count = Int(r.u32be(trun.bodyStart + 4))
            var p = trun.bodyStart + 8
            var dataStart: Int
            if flags & 0x01 != 0 {
                guard p + 4 <= trun.end else { throw FLACFormatError.truncated("MP4 trun box") }
                dataStart = moof.start + Int(Int32(bitPattern: r.u32be(p)))
                p += 4
            } else if let cursor {
                dataStart = cursor
            } else if let followingMdat {
                dataStart = followingMdat
            } else {
                throw FLACFormatError.unsupportedMP4("trun without data offset or mdat")
            }
            if flags & 0x04 != 0 { p += 4 } // first sample flags
            // Every sample is at least one byte of the file, which bounds a
            // corrupt count even when the run lists no per-sample fields.
            guard count <= r.count else { throw FLACFormatError.truncated("MP4 trun box") }
            let fieldSizes = [0x100, 0x200, 0x400, 0x800].map { flags & UInt32($0) != 0 ? 4 : 0 }
            let entrySize = fieldSizes.reduce(0, +)
            // A run may list no per-sample fields at all (FFmpeg writes one for
            // a segment's single last frame, sized by tfhd's default).
            guard p + count * entrySize <= trun.end else {
                throw FLACFormatError.truncated("MP4 trun box")
            }
            guard flags & 0x200 != 0 || defaultSize != nil else {
                throw FLACFormatError.unsupportedMP4("no sample sizes")
            }
            // A run's samples sit back to back, so all of them belong to the
            // mdat that holds the first. Checking against it while listing
            // keeps a corrupt count from building millions of ranges before
            // anything notices: with only a default size of 1, a 150 MB
            // download could otherwise list ~150 M ranges (spike review).
            var mdatEnd = 0
            if count > 0 {
                guard let mdat = mdats.first(where: { $0.contains(dataStart) }) else {
                    throw FLACFormatError.truncated("MP4 sample outside its mdat")
                }
                mdatEnd = mdat.upperBound
                if flags & 0x200 == 0 {
                    let size = Int(defaultSize ?? 0)
                    guard size > 0 else { throw FLACFormatError.invalidFrame(offset: dataStart) }
                    guard count <= (mdatEnd - dataStart) / size else {
                        throw FLACFormatError.truncated("MP4 sample outside its mdat")
                    }
                }
            }
            for _ in 0..<count {
                p += fieldSizes[0]
                let size: Int
                if flags & 0x200 != 0 { size = Int(r.u32be(p)) } else { size = Int(defaultSize ?? 0) }
                p += fieldSizes[1] + fieldSizes[2] + fieldSizes[3]
                guard size > 0 else { throw FLACFormatError.invalidFrame(offset: dataStart) }
                guard size <= mdatEnd - dataStart else { throw FLACFormatError.truncated("MP4 sample outside its mdat") }
                samples.append(dataStart..<(dataStart + size))
                dataStart += size
            }
            cursor = dataStart
        }
        return samples
    }
}
