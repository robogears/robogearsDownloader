// Reads one sound track's samples out of an MP4, progressive or fragmented.
//
// TIDAL's AAC fallback (2.10) arrives either as one plain MP4 (a BTS
// stream) or as a DASH init segment plus media segments, joined in order
// like the Electron app's "<Title>.tmp.m4a" (download-pipeline.md B8). The
// spike (docs/spikes/audio-and-tagging.md, "AAC .m4a output") found Apple's
// passthrough export dropped 2 of 45 packets from the joined DASH file, so
// the native path reads the samples itself: from the sample tables in moov
// (stsz, stsc, stco/co64, stts) and from every moof/mdat pair (trun, tfhd,
// trex), into one list of byte ranges and durations. Nothing here is AAC
// specific; the AAC checks are in M4AWriter.swift. Layout rules follow
// ISO/IEC 14496-12 (sample tables, edit lists, movie fragments).
import Foundation

/// Why an AAC download couldn't be turned into an .m4a. Cases name the
/// problem in the file, so the download pipeline can choose its own wording
/// for the row; I/O failures (a full disk, an existing destination) come
/// through as the system's own errors instead.
public enum M4AFormatError: Error, Sendable, Equatable {
    /// The data isn't an ISO base media (MP4) file.
    case notMP4
    /// The data ends inside the named structure.
    case truncated(String)
    /// The sound track holds another codec: the sample entry type (such as
    /// "fLaC" or "Opus"), or "mp4a." and the object type for MPEG audio that
    /// isn't AAC (such as "mp4a.6B" for MP3).
    case notAAC(codec: String)
    /// The sound track is encrypted ("enca"); it can't be copied as is.
    case encryptedAudio
    /// A layout this reader doesn't handle; the text names it.
    case unsupportedMP4(String)
    /// The file's own tables contradict each other; the text names them.
    case inconsistent(String)
    /// The sound track holds no samples.
    case noAudioSamples
    /// The cover bytes don't start with a JPEG start-of-image marker.
    case coverIsNotJPEG
}

/// One sample: where its bytes sit in the source, and how long it plays in
/// the track's timescale.
struct MP4Sample: Equatable {
    var offset: Int
    var size: Int
    var duration: UInt32

    var range: Range<Int> { offset..<(offset + size) }
}

/// The first sound track of an MP4, with its samples in playback order.
struct MP4AudioTrack {
    /// The edit list's single edit: playback starts `mediaTime` into the
    /// media (the encoder's priming) and lasts `segmentDuration` in the
    /// movie's timescale. A duration of 0 means "to the end of the media",
    /// which is what a fragmented file writes because the length isn't
    /// known when the init segment is made.
    struct Edit: Equatable {
        var segmentDuration: UInt64
        var mediaTime: UInt64
    }

    /// The whole sample entry box (header included), for example "mp4a"
    /// with its esds, copied unchanged into the new file.
    var sampleEntry: Data
    var sampleEntryType: String
    /// mdhd's timescale: sample durations count in these units.
    var timescale: UInt32
    /// mdhd's packed ISO 639-2 language code.
    var language: UInt16
    /// mvhd's timescale: the edit's segment duration counts in these units.
    var movieTimescale: UInt32
    var edit: Edit?
    var samples: [MP4Sample]
    /// True when any samples came from movie fragments.
    var isFragmented: Bool

    var totalDuration: UInt64 { samples.reduce(0) { $0 + UInt64($1.duration) } }
}

enum MP4AudioTrackReader {
    static func read(_ data: Data) throws(M4AFormatError) -> MP4AudioTrack {
        let r = FLACByteReader(data)
        guard r.has(0, 8), FMP4FLACExtractor.leadingBoxTypes.contains(fourCC(r, 4)) else { throw .notMP4 }
        let top = try boxes(r, in: 0..<r.count)
        guard let moov = top.first(where: { $0.type == "moov" }) else { throw .unsupportedMP4("no moov box") }
        let mdats = top.filter { $0.type == "mdat" }.map(\.body)

        guard let mvhd = try child(r, "mvhd", in: moov) else { throw .unsupportedMP4("no mvhd box") }
        let movieTimescale = try timescale(r, header: mvhd)
        guard movieTimescale > 0 else { throw .inconsistent("mvhd timescale of 0") }

        let trak = try soundTrack(r, moov: moov)
        guard let mdhd = try path(r, ["mdia", "mdhd"], from: trak) else { throw .unsupportedMP4("sound track without mdhd") }
        let mediaTimescale = try timescale(r, header: mdhd)
        guard mediaTimescale > 0 else { throw .inconsistent("mdhd timescale of 0") }
        let languageOffset = mdhd.bodyStart + (r.u8(mdhd.bodyStart) == 1 ? 32 : 20)
        guard languageOffset + 2 <= mdhd.end else { throw .truncated("MP4 mdhd box") }

        guard let stbl = try path(r, ["mdia", "minf", "stbl"], from: trak) else {
            throw .unsupportedMP4("sound track without stbl")
        }
        let entry = try sampleEntry(r, stbl: stbl)
        let trackID = try self.trackID(r, trak: trak)
        let edit = try self.edit(r, trak: trak)

        var samples = try tableSamples(r, stbl: stbl, mdats: mdats)
        let defaults = try trackDefaults(r, moov: moov, trackID: trackID)
        var sawFragment = false
        for (index, box) in top.enumerated() where box.type == "moof" {
            sawFragment = true
            let followingMdat = top[(index + 1)...].first { $0.type == "mdat" }?.bodyStart
            for traf in try boxes(r, in: box.body) where traf.type == "traf" {
                samples += try fragmentSamples(
                    r, traf: traf, moof: box, trackID: trackID, defaults: defaults,
                    followingMdat: followingMdat, mdats: mdats
                )
            }
        }
        guard !samples.isEmpty else { throw .noAudioSamples }
        return MP4AudioTrack(
            sampleEntry: r.bytes(entry.start, entry.end - entry.start), sampleEntryType: entry.type,
            timescale: mediaTimescale, language: r.u16be(languageOffset), movieTimescale: movieTimescale,
            edit: edit, samples: samples, isFragmented: sawFragment
        )
    }

    // MARK: Boxes

    static func fourCC(_ r: FLACByteReader, _ o: Int) -> String { FMP4FLACExtractor.fourCC(r, o) }

    /// The FLAC extractor's box walker, with its errors in this file's terms.
    static func boxes(_ r: FLACByteReader, in range: Range<Int>) throws(M4AFormatError) -> [FMP4Box] {
        do {
            return try FMP4FLACExtractor.boxes(r, in: range)
        } catch let FLACFormatError.truncated(what) {
            throw .truncated(what)
        } catch {
            throw .truncated("MP4 box")
        }
    }

    static func child(_ r: FLACByteReader, _ type: String, in box: FMP4Box) throws(M4AFormatError) -> FMP4Box? {
        try boxes(r, in: box.body).first { $0.type == type }
    }

    static func path(_ r: FLACByteReader, _ types: [String], from box: FMP4Box) throws(M4AFormatError) -> FMP4Box? {
        var current = box
        for type in types {
            guard let next = try child(r, type, in: current) else { return nil }
            current = next
        }
        return current
    }

    /// mvhd and mdhd share their start: version and flags, two times (32 or
    /// 64 bits by version), then the timescale.
    static func timescale(_ r: FLACByteReader, header box: FMP4Box) throws(M4AFormatError) -> UInt32 {
        guard r.has(box.bodyStart, 1) else { throw .truncated("MP4 \(box.type) box") }
        let o = box.bodyStart + (r.u8(box.bodyStart) == 1 ? 20 : 12)
        guard o + 4 <= box.end else { throw .truncated("MP4 \(box.type) box") }
        return r.u32be(o)
    }

    // MARK: Track setup (moov)

    /// The first track whose handler is "soun".
    static func soundTrack(_ r: FLACByteReader, moov: FMP4Box) throws(M4AFormatError) -> FMP4Box {
        for trak in try boxes(r, in: moov.body) where trak.type == "trak" {
            if let hdlr = try path(r, ["mdia", "hdlr"], from: trak), r.has(hdlr.bodyStart, 12),
               hdlr.bodyStart + 12 <= hdlr.end, fourCC(r, hdlr.bodyStart + 8) == "soun" {
                return trak
            }
        }
        throw .unsupportedMP4("no sound track")
    }

    static func trackID(_ r: FLACByteReader, trak: FMP4Box) throws(M4AFormatError) -> UInt32 {
        guard let tkhd = try child(r, "tkhd", in: trak), r.has(tkhd.bodyStart, 1) else {
            throw .unsupportedMP4("track without tkhd")
        }
        // tkhd version 1 has 64-bit creation and modification times before the track ID.
        let o = tkhd.bodyStart + (r.u8(tkhd.bodyStart) == 1 ? 20 : 12)
        guard o + 4 <= tkhd.end else { throw .truncated("MP4 tkhd box") }
        return r.u32be(o)
    }

    /// The track's one sample entry. Several entries would let chunks or
    /// fragments switch codec settings part-way, which a copy into one
    /// entry can't keep, so they're refused.
    static func sampleEntry(_ r: FLACByteReader, stbl: FMP4Box) throws(M4AFormatError) -> FMP4Box {
        guard let stsd = try child(r, "stsd", in: stbl), stsd.body.count >= 8 else {
            throw .unsupportedMP4("sound track without stsd")
        }
        let count = r.u32be(stsd.bodyStart + 4)
        let entries = try boxes(r, in: (stsd.bodyStart + 8)..<stsd.end)
        guard let first = entries.first, count >= 1 else { throw .unsupportedMP4("empty stsd") }
        guard count == 1, entries.count == 1 else { throw .unsupportedMP4("several sample descriptions") }
        return first
    }

    /// The edit list, when there is one. Only the shape encoders write for
    /// audio is taken: one edit at normal speed that skips the priming.
    /// Anything else (a delayed start, several edits, another speed) is
    /// refused by name rather than copied wrongly.
    static func edit(_ r: FLACByteReader, trak: FMP4Box) throws(M4AFormatError) -> MP4AudioTrack.Edit? {
        guard let elst = try path(r, ["edts", "elst"], from: trak) else { return nil }
        guard elst.body.count >= 8 else { throw .truncated("MP4 elst box") }
        let version = r.u8(elst.bodyStart)
        let count = Int(r.u32be(elst.bodyStart + 4))
        if count == 0 { return nil }
        guard count == 1 else { throw .unsupportedMP4("edit list with \(count) edits") }
        let o = elst.bodyStart + 8
        let entrySize = version == 1 ? 20 : 12
        guard o + entrySize <= elst.end else { throw .truncated("MP4 elst box") }
        let segmentDuration: UInt64
        let mediaTime: Int64
        if version == 1 {
            segmentDuration = r.u64be(o)
            mediaTime = Int64(bitPattern: r.u64be(o + 8))
        } else {
            segmentDuration = UInt64(r.u32be(o))
            mediaTime = Int64(Int32(bitPattern: r.u32be(o + 4)))
        }
        let rate = r.u32be(o + entrySize - 4)
        guard mediaTime >= 0 else { throw .unsupportedMP4("edit list with an empty edit") }
        guard rate == 0x0001_0000 else { throw .unsupportedMP4("edit list at another speed") }
        return MP4AudioTrack.Edit(segmentDuration: segmentDuration, mediaTime: UInt64(mediaTime))
    }

    // MARK: Sample tables (stbl)

    /// The samples the moov's own tables list. A fragmented file's init
    /// segment lists none; a progressive file lists them all.
    static func tableSamples(_ r: FLACByteReader, stbl: FMP4Box, mdats: [Range<Int>]) throws(M4AFormatError) -> [MP4Sample] {
        let children = try boxes(r, in: stbl.body)
        if children.contains(where: { $0.type == "stz2" }) { throw .unsupportedMP4("compact sample sizes (stz2)") }
        guard let stsz = children.first(where: { $0.type == "stsz" }), stsz.body.count >= 12 else {
            throw .unsupportedMP4("sound track without stsz")
        }
        let constantSize = Int(r.u32be(stsz.bodyStart + 4))
        let count = Int(r.u32be(stsz.bodyStart + 8))
        if count == 0 { return [] }
        if constantSize == 0 {
            guard count <= (stsz.body.count - 12) / 4 else { throw .truncated("MP4 stsz box") }
        } else {
            // Every sample is a part of the file, which bounds a corrupt count.
            guard count <= r.count / constantSize else { throw .truncated("MP4 stsz box") }
        }
        func size(_ i: Int) -> Int { constantSize != 0 ? constantSize : Int(r.u32be(stsz.bodyStart + 12 + 4 * i)) }

        let chunkOffsets = try chunkOffsets(r, children)
        guard let stsc = children.first(where: { $0.type == "stsc" }), stsc.body.count >= 8 else {
            throw .unsupportedMP4("sound track without stsc")
        }
        let runCount = Int(r.u32be(stsc.bodyStart + 4))
        guard runCount <= (stsc.body.count - 8) / 12 else { throw .truncated("MP4 stsc box") }
        // stsc lists runs of chunks: from `firstChunk` (counting from 1) on,
        // each chunk holds `perChunk` samples, until the next run starts.
        var runs: [(firstChunk: Int, perChunk: Int)] = []
        for i in 0..<runCount {
            let o = stsc.bodyStart + 8 + 12 * i
            let first = Int(r.u32be(o)), perChunk = Int(r.u32be(o + 4))
            guard first >= 1, first > (runs.last?.firstChunk ?? 0) else { throw .inconsistent("stsc chunk numbers") }
            runs.append((first, perChunk))
        }

        var samples: [MP4Sample] = []
        samples.reserveCapacity(count)
        var run = -1
        for (chunkIndex, chunkStart) in chunkOffsets.enumerated() where samples.count < count {
            while run + 1 < runs.count, runs[run + 1].firstChunk <= chunkIndex + 1 { run += 1 }
            guard run >= 0 else { throw .inconsistent("stsc doesn't start at chunk 1") }
            let inChunk = min(runs[run].perChunk, count - samples.count)
            var offset = chunkStart
            for _ in 0..<inChunk {
                let sample = MP4Sample(offset: offset, size: size(samples.count), duration: 0)
                guard sample.size > 0 else { throw .inconsistent("a sample of 0 bytes") }
                guard mdats.contains(where: { $0.lowerBound <= sample.offset && sample.range.upperBound <= $0.upperBound }) else {
                    throw .truncated("MP4 sample outside its mdat")
                }
                samples.append(sample)
                offset += sample.size
            }
        }
        guard samples.count == count else { throw .inconsistent("stsz lists more samples than the chunks hold") }

        guard let stts = children.first(where: { $0.type == "stts" }), stts.body.count >= 8 else {
            throw .unsupportedMP4("sound track without stts")
        }
        let timeRuns = Int(r.u32be(stts.bodyStart + 4))
        guard timeRuns <= (stts.body.count - 8) / 8 else { throw .truncated("MP4 stts box") }
        var next = 0
        for i in 0..<timeRuns {
            let o = stts.bodyStart + 8 + 8 * i
            let runLength = Int(r.u32be(o)), delta = r.u32be(o + 4)
            guard runLength <= count - next else { throw .inconsistent("stts lists more samples than stsz") }
            for j in next..<(next + runLength) { samples[j].duration = delta }
            next += runLength
        }
        guard next == count else { throw .inconsistent("stts lists fewer samples than stsz") }
        return samples
    }

    /// Where each chunk starts, from stco (32-bit) or co64 (64-bit).
    static func chunkOffsets(_ r: FLACByteReader, _ children: [FMP4Box]) throws(M4AFormatError) -> [Int] {
        let wide: Bool
        let box: FMP4Box
        if let stco = children.first(where: { $0.type == "stco" }) {
            (wide, box) = (false, stco)
        } else if let co64 = children.first(where: { $0.type == "co64" }) {
            (wide, box) = (true, co64)
        } else {
            throw .unsupportedMP4("sound track without stco or co64")
        }
        guard box.body.count >= 8 else { throw .truncated("MP4 \(box.type) box") }
        let count = Int(r.u32be(box.bodyStart + 4))
        let width = wide ? 8 : 4
        guard count <= (box.body.count - 8) / width else { throw .truncated("MP4 \(box.type) box") }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count {
            let o = box.bodyStart + 8 + width * i
            let value = wide ? r.u64be(o) : UInt64(r.u32be(o))
            guard value < UInt64(r.count) else { throw .truncated("MP4 sample outside its mdat") }
            offsets.append(Int(value))
        }
        return offsets
    }

    // MARK: Fragments (moof)

    struct SampleDefaults {
        var duration: UInt32?
        var size: UInt32?
    }

    /// The track's default sample duration and size from mvex/trex, used
    /// when neither the fragment header nor the run gives one.
    static func trackDefaults(_ r: FLACByteReader, moov: FMP4Box, trackID: UInt32) throws(M4AFormatError) -> SampleDefaults {
        guard let mvex = try child(r, "mvex", in: moov) else { return SampleDefaults() }
        for trex in try boxes(r, in: mvex.body) where trex.type == "trex" {
            guard trex.body.count >= 24 else { throw .truncated("MP4 trex box") }
            if r.u32be(trex.bodyStart + 4) == trackID {
                let duration = r.u32be(trex.bodyStart + 12), size = r.u32be(trex.bodyStart + 16)
                return SampleDefaults(duration: duration == 0 ? nil : duration, size: size == 0 ? nil : size)
            }
        }
        return SampleDefaults()
    }

    /// One track fragment's samples, in order. Every sample lies inside one
    /// of `mdats` (the file's mdat bodies), or this throws.
    ///
    /// Offsets follow the FLAC extractor's rules (FMP4FLACExtractor
    /// `trackFragmentSamples`): a run's data offset counts from the moof's
    /// first byte, a run without one continues where the last ended (or
    /// starts at the following mdat), and an explicit base data offset is
    /// refused because it counts from the start of the original segment
    /// file, which is unknown once segments are joined.
    static func fragmentSamples(
        _ r: FLACByteReader, traf: FMP4Box, moof: FMP4Box, trackID: UInt32,
        defaults: SampleDefaults, followingMdat: Int?, mdats: [Range<Int>]
    ) throws(M4AFormatError) -> [MP4Sample] {
        let children = try boxes(r, in: traf.body)
        guard let tfhd = children.first(where: { $0.type == "tfhd" }), tfhd.body.count >= 8 else {
            throw .unsupportedMP4("track fragment without tfhd")
        }
        let tfhdFlags = r.u32be(tfhd.bodyStart) & 0xFF_FFFF
        guard r.u32be(tfhd.bodyStart + 4) == trackID else { return [] }
        guard tfhdFlags & 0x01 == 0 else { throw .unsupportedMP4("tfhd base data offset") }
        var o = tfhd.bodyStart + 8
        if tfhdFlags & 0x02 != 0 { o += 4 } // sample description index
        var defaultDuration = defaults.duration
        if tfhdFlags & 0x08 != 0 {
            guard o + 4 <= tfhd.end else { throw .truncated("MP4 tfhd box") }
            defaultDuration = r.u32be(o)
            o += 4
        }
        var defaultSize = defaults.size
        if tfhdFlags & 0x10 != 0 {
            guard o + 4 <= tfhd.end else { throw .truncated("MP4 tfhd box") }
            defaultSize = r.u32be(o)
        }

        var samples: [MP4Sample] = []
        var cursor: Int? = nil
        for trun in children where trun.type == "trun" {
            guard trun.body.count >= 8 else { throw .truncated("MP4 trun box") }
            let flags = r.u32be(trun.bodyStart) & 0xFF_FFFF
            let count = Int(r.u32be(trun.bodyStart + 4))
            var p = trun.bodyStart + 8
            var dataStart: Int
            if flags & 0x01 != 0 {
                guard p + 4 <= trun.end else { throw .truncated("MP4 trun box") }
                dataStart = moof.start + Int(Int32(bitPattern: r.u32be(p)))
                p += 4
            } else if let cursor {
                dataStart = cursor
            } else if let followingMdat {
                dataStart = followingMdat
            } else {
                throw .unsupportedMP4("trun without data offset or mdat")
            }
            if flags & 0x04 != 0 { p += 4 } // first sample flags
            guard count <= r.count else { throw .truncated("MP4 trun box") }
            let fieldSizes = [0x100, 0x200, 0x400, 0x800].map { flags & UInt32($0) != 0 ? 4 : 0 }
            guard p + count * fieldSizes.reduce(0, +) <= trun.end else { throw .truncated("MP4 trun box") }
            guard flags & 0x200 != 0 || defaultSize != nil else { throw .unsupportedMP4("no sample sizes") }
            guard flags & 0x100 != 0 || defaultDuration != nil else { throw .unsupportedMP4("no sample durations") }
            // A run's samples sit back to back, so all of them belong to the
            // mdat that holds the first; checking as they're listed keeps a
            // corrupt count from building millions of samples first.
            var mdatEnd = 0
            if count > 0 {
                guard let mdat = mdats.first(where: { $0.contains(dataStart) }) else {
                    throw .truncated("MP4 sample outside its mdat")
                }
                mdatEnd = mdat.upperBound
                if flags & 0x200 == 0 {
                    let size = Int(defaultSize ?? 0)
                    guard size > 0 else { throw .inconsistent("a sample of 0 bytes") }
                    guard count <= (mdatEnd - dataStart) / size else { throw .truncated("MP4 sample outside its mdat") }
                }
            }
            samples.reserveCapacity(samples.count + count)
            for _ in 0..<count {
                let duration = flags & 0x100 != 0 ? r.u32be(p) : (defaultDuration ?? 0)
                p += fieldSizes[0]
                let size = flags & 0x200 != 0 ? Int(r.u32be(p)) : Int(defaultSize ?? 0)
                p += fieldSizes[1] + fieldSizes[2] + fieldSizes[3]
                guard size > 0 else { throw .inconsistent("a sample of 0 bytes") }
                guard size <= mdatEnd - dataStart else { throw .truncated("MP4 sample outside its mdat") }
                samples.append(MP4Sample(offset: dataStart, size: size, duration: duration))
                dataStart += size
            }
            cursor = dataStart
        }
        return samples
    }
}
