// The native AAC writer: the Electron app's .m4a fallback, without FFmpeg.
//
// When TIDAL has no lossless version, the Electron app saved TIDAL's AAC as
// "<Title>.m4a" with FFmpeg copying the audio and adding the tags and cover
// (download-pipeline.md B11; D4 2.10 keeps the fallback). The spike
// (docs/spikes/audio-and-tagging.md, "AAC .m4a output") recorded what
// FFmpeg wrote and found Apple's passthrough export lost packets from a
// joined DASH download. So this copies every AAC packet itself, from a
// plain MP4 or a fragmented one, into a new progressive .m4a: ftyp, moov
// (one sound track with the source's own sample description, priming edit
// and timescale, and the iTunes tags), then mdat with the packets in order.
import Foundation

/// Writes TIDAL's AAC as a tagged .m4a. Conforms to the pipeline's
/// `M4AWriting` seam, so the track downloader never needs FFmpeg.
public struct M4AWriter: M4AWriting {
    /// Written as the encoder tag (©too), as FFmpeg wrote "Lavf…"; the FLAC
    /// writer names the app the same way.
    public var toolName: String

    public init(toolName: String = FLACWriter.defaultToolName) {
        self.toolName = toolName
    }

    /// Reads `source` (mapped, not copied into memory), checks it holds
    /// unencrypted AAC, and writes `destination` exclusively. A source that
    /// can't be used throws `M4AFormatError` before anything is created; an
    /// existing destination throws `POSIXError(.EEXIST)` and is left as it
    /// was; any later failure, cancellation included, removes the new file.
    public func writeM4A(from source: URL, tags: FLACTags, coverJPEG: Data?, to destination: URL) async throws -> M4AWriteResult {
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        return try Self.write(data, tags: tags, coverJPEG: coverJPEG, toolName: toolName, to: destination)
    }

    // MARK: Writing

    /// Mirrors `FLACWriter.write`: the samples are streamed from the source
    /// in pieces of at most `pieceBytes`, checking for cancellation between
    /// them so a cancelled download stops at once (2.4). `afterPiece` runs
    /// after each piece; tests use it to fail part-way.
    static func write(
        _ source: Data, tags: FLACTags, coverJPEG: Data?, toolName: String, to url: URL,
        pieceBytes: Int = 4 << 20, afterPiece: (() throws -> Void)? = nil
    ) throws -> M4AWriteResult {
        let track = try aacTrack(source)
        let file = try layout(track, tags: tags, coverJPEG: coverJPEG, toolName: toolName)
        try Task.checkCancellation()
        // Creating the file exclusively is the only step that can fail because
        // a file is already there; after it, the file is ours to remove.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            defer { try? handle.close() }
            try handle.write(contentsOf: file.header)
            for run in contiguousRuns(track.samples) {
                var start = run.lowerBound
                while start < run.upperBound {
                    try Task.checkCancellation()
                    let end = min(start + pieceBytes, run.upperBound)
                    try handle.write(contentsOf: source[(source.startIndex + start)..<(source.startIndex + end)])
                    try afterPiece?()
                    start = end
                }
            }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return M4AWriteResult(durationSeconds: file.durationSeconds)
    }

    /// The samples' byte ranges with neighbours joined, so a progressive
    /// source (one long run per chunk) is copied in a few large writes.
    static func contiguousRuns(_ samples: [MP4Sample]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for sample in samples {
            if let last = runs.last, last.upperBound == sample.offset {
                runs[runs.count - 1] = last.lowerBound..<sample.range.upperBound
            } else {
                runs.append(sample.range)
            }
        }
        return runs
    }

    // MARK: Reading the source

    /// MPEG-4 Audio (0x40) and the three MPEG-2 AAC profiles (0x66 to 0x68),
    /// the object types an "mp4a" entry uses for AAC (ISO/IEC 14496-1 table 5).
    static let aacObjectTypes: Set<UInt8> = [0x40, 0x66, 0x67, 0x68]

    /// The source's sound track, refused unless it's unencrypted AAC.
    static func aacTrack(_ data: Data) throws(M4AFormatError) -> MP4AudioTrack {
        let track = try MP4AudioTrackReader.read(data)
        switch track.sampleEntryType {
        case "mp4a": break
        case "enca": throw .encryptedAudio
        default: throw .notAAC(codec: track.sampleEntryType)
        }
        let objectType = try aacObjectType(track.sampleEntry)
        guard aacObjectTypes.contains(objectType) else {
            throw .notAAC(codec: "mp4a." + String(objectType, radix: 16, uppercase: true))
        }
        return track
    }

    /// The object type in an "mp4a" entry's esds: ES_Descriptor (tag 3),
    /// then its DecoderConfigDescriptor (tag 4), whose first byte names the
    /// codec. QuickTime-style entries (versions 1 and 2) have extra fixed
    /// fields and may wrap the esds in a "wave" box.
    static func aacObjectType(_ entry: Data) throws(M4AFormatError) -> UInt8 {
        let r = FLACByteReader(entry)
        // Box header (8), reserved (6), data reference index (2), then the
        // version of the sound description and the rest of its 28 bytes.
        guard r.has(8, 28) else { throw .truncated("MP4 mp4a sample entry") }
        let version = r.u16be(16)
        let extra = version == 1 ? 16 : version == 2 ? 36 : 0
        let childStart = 8 + 28 + extra
        guard childStart <= r.count else { throw .truncated("MP4 mp4a sample entry") }
        var children = try MP4AudioTrackReader.boxes(r, in: childStart..<r.count)
        if let wave = children.first(where: { $0.type == "wave" }) {
            children = try MP4AudioTrackReader.boxes(r, in: wave.body)
        }
        guard let esds = children.first(where: { $0.type == "esds" }) else {
            throw .unsupportedMP4("mp4a sample entry without esds")
        }

        var o = esds.bodyStart + 4
        /// A descriptor's tag and length (7 bits per byte, high bit = more).
        func descriptor() throws(M4AFormatError) -> (tag: UInt8, end: Int) {
            guard o < esds.end else { throw .truncated("MP4 esds box") }
            let tag = r.u8(o)
            o += 1
            var length = 0
            for _ in 0..<4 {
                guard o < esds.end else { throw .truncated("MP4 esds box") }
                let byte = r.u8(o)
                o += 1
                length = length << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
            guard length <= esds.end - o else { throw .truncated("MP4 esds box") }
            return (tag, o + length)
        }
        let es = try descriptor()
        guard es.tag == 0x03, o + 3 <= es.end else { throw .unsupportedMP4("esds without an ES descriptor") }
        let esFlags = r.u8(o + 2)
        o += 3
        if esFlags & 0x80 != 0 { o += 2 } // depends on another stream
        if esFlags & 0x40 != 0 { // URL
            guard o < es.end else { throw .truncated("MP4 esds box") }
            o += 1 + Int(r.u8(o))
        }
        if esFlags & 0x20 != 0 { o += 2 } // OCR stream
        let config = try descriptor()
        guard config.tag == 0x04, o < config.end else { throw .unsupportedMP4("esds without a decoder configuration") }
        return r.u8(o)
    }

    // MARK: The new file's layout

    /// Everything before the first sample byte, and the length it declares.
    struct Layout {
        /// ftyp, moov and the mdat box header.
        var header: Data
        var durationSeconds: Double
    }

    /// How long the new file plays, in each of the units its boxes use.
    struct Timing: Equatable {
        /// Every sample's duration added up (mdhd), in the track's timescale.
        var mediaDuration: UInt64
        /// What plays after the priming is skipped, in the track's timescale.
        var presentedMedia: UInt64
        /// The edit to write, in the movie's timescale; nil without one.
        var edit: MP4AudioTrack.Edit?
        /// The movie's and track's length (mvhd, tkhd), in the movie's timescale.
        var movieDuration: UInt64
    }

    /// The source's edit, kept so playback starts where it says (skipping the
    /// encoder's priming), with two repairs. A fragmented file's "to the end"
    /// duration of 0 becomes the real length, as FFmpeg writes it (rounded
    /// up, so no audio is cut). An edit longer than the audio left after the
    /// priming is cut to fit, so a download that stopped early declares its
    /// real length and the length check (2.2) sees it.
    static func timing(_ track: MP4AudioTrack) throws(M4AFormatError) -> Timing {
        let media = track.totalDuration
        guard let edit = track.edit else {
            let movie = rescale(media, from: track.timescale, to: track.movieTimescale, roundingUp: true)
            return Timing(mediaDuration: media, presentedMedia: media, edit: nil, movieDuration: movie)
        }
        guard edit.mediaTime < media else { throw .inconsistent("the edit list starts after the audio ends") }
        let remaining = media - edit.mediaTime
        var segment = edit.segmentDuration
        var presented = rescale(segment, from: track.movieTimescale, to: track.timescale, roundingUp: false)
        if segment == 0 || presented > remaining {
            segment = rescale(remaining, from: track.timescale, to: track.movieTimescale, roundingUp: true)
            presented = remaining
        }
        return Timing(
            mediaDuration: media, presentedMedia: presented,
            edit: MP4AudioTrack.Edit(segmentDuration: segment, mediaTime: edit.mediaTime), movieDuration: segment
        )
    }

    /// `value` converted between timescales without overflowing; a result
    /// too large for 64 bits (only from a corrupt file) is capped.
    static func rescale(_ value: UInt64, from: UInt32, to: UInt32, roundingUp: Bool) -> UInt64 {
        let product = value.multipliedFullWidth(by: UInt64(to))
        let divisor = UInt64(from)
        guard product.high < divisor else { return .max }
        let (quotient, remainder) = divisor.dividingFullWidth(product)
        return roundingUp && remainder > 0 && quotient < .max ? quotient + 1 : quotient
    }

    /// FFmpeg's chunking (movenc.c build_chunks): consecutive samples share
    /// a chunk until it would reach 1 MiB. Returns the samples in each chunk.
    static func chunkSampleCounts(_ samples: [MP4Sample]) -> [Int] {
        var counts: [Int] = []
        var bytes = 0
        for sample in samples {
            if let last = counts.last, bytes + sample.size < maximumChunkBytes {
                counts[counts.count - 1] = last + 1
                bytes += sample.size
            } else {
                counts.append(1)
                bytes = sample.size
            }
        }
        return counts
    }

    static let maximumChunkBytes = 1 << 20

    /// The most samples one file can list while its largest table (stts at
    /// 8 bytes per sample) still fits a 32-bit box size, with room for the
    /// box headers.
    static let maximumSampleCount = 500_000_000

    static func layout(_ track: MP4AudioTrack, tags: FLACTags, coverJPEG: Data?, toolName: String) throws(M4AFormatError) -> Layout {
        if let coverJPEG, !(coverJPEG.count >= 2 && coverJPEG.first == 0xFF && coverJPEG.dropFirst().first == 0xD8) {
            throw .coverIsNotJPEG
        }
        // Every table box has a 32-bit size, and stts can need 8 bytes per
        // sample (when every duration differs). No real track comes near
        // this (it's months of audio); only a corrupt file of several GB
        // could, and refusing it keeps every table box below 4 GB.
        guard track.samples.count <= maximumSampleCount else { throw .unsupportedMP4("more than 500 million samples") }
        let timing = try timing(track)
        let chunks = chunkSampleCounts(track.samples)
        // Where each chunk starts, counted from the first sample byte.
        var chunkStarts: [UInt64] = []
        chunkStarts.reserveCapacity(chunks.count)
        var position: UInt64 = 0
        var sample = 0
        for count in chunks {
            chunkStarts.append(position)
            for s in sample..<(sample + count) { position += UInt64(track.samples[s].size) }
            sample += count
        }
        let sampleBytes = position
        let mdatHeader = MP4BoxWriter.mdatHeader(bodySize: sampleBytes)
        let ftyp = fileType()
        let ilst = MP4BoxWriter.box("ilst", tagAtoms(tags, coverJPEG: coverJPEG, toolName: toolName).reduce(Data(), +))

        // The chunk offsets count from the file's start, so they depend on
        // the moov's size, which depends on whether they need 64 bits. The
        // size doesn't depend on the values, so measure with zeros (real
        // offsets past 4 GB wouldn't fit the 32-bit table being measured),
        // then fill in.
        func moov(_ offsets: [UInt64], wide: Bool) -> Data {
            movie(track, timing: timing, chunks: chunks, chunkOffsets: offsets, wide: wide, ilst: ilst)
        }
        let zeros = [UInt64](repeating: 0, count: chunkStarts.count)
        var wide = false
        var base = UInt64(ftyp.count + moov(zeros, wide: false).count + mdatHeader.count)
        if base + (chunkStarts.last ?? 0) > UInt64(UInt32.max) {
            wide = true
            base = UInt64(ftyp.count + moov(zeros, wide: true).count + mdatHeader.count)
        }
        return Layout(
            header: ftyp + moov(chunkStarts.map { base + $0 }, wide: wide) + mdatHeader,
            durationSeconds: Double(timing.presentedMedia) / Double(track.timescale)
        )
    }

    /// FFmpeg's .m4a brands: "M4A " (version 512), compatible with M4A,
    /// isom and iso2.
    static func fileType() -> Data {
        MP4BoxWriter.box("ftyp", Data("M4A ".utf8) + MP4BoxWriter.u32(512) + Data("M4A isomiso2".utf8))
    }

    /// The moov: mvhd, one trak, and udta with the tags. Times of creation
    /// and change are 0 (FFmpeg's bit-exact output does the same), so the
    /// same download always gives the same bytes.
    static func movie(
        _ track: MP4AudioTrack, timing: Timing, chunks: [Int], chunkOffsets: [UInt64], wide: Bool, ilst: Data
    ) -> Data {
        typealias W = MP4BoxWriter
        let durations = track.samples.map(\.duration)
        let stbl = W.box("stbl",
            W.fullBox("stsd", W.u32(1) + track.sampleEntry)
            + W.timeToSample(durations)
            + W.sampleToChunk(chunks)
            + W.sampleSizes(track.samples.map(\.size))
            + W.chunkOffsets(chunkOffsets, wide: wide)
            + W.rollGroup(sampleCount: track.samples.count))
        let minf = W.box("minf",
            W.fullBox("smhd", W.u32(0))
            + W.box("dinf", W.fullBox("dref", W.u32(1) + W.fullBox("url ", flags: 1)))
            + stbl)
        let mdia = W.box("mdia",
            W.mediaHeader(timescale: track.timescale, duration: timing.mediaDuration, language: track.language)
            + W.fullBox("hdlr", W.u32(0) + Data("soun".utf8) + Data(count: 12) + Data("SoundHandler\0".utf8))
            + minf)
        var trak = W.trackHeader(duration: timing.movieDuration)
        if let edit = timing.edit { trak += W.editList(edit) }
        trak += mdia
        let meta = W.fullBox("meta",
            W.fullBox("hdlr", W.u32(0) + Data("mdir".utf8) + Data("appl".utf8) + Data(count: 8) + Data([0]))
            + ilst)
        return W.box("moov",
            W.movieHeader(timescale: track.movieTimescale, duration: timing.movieDuration)
            + W.box("trak", trak)
            + W.box("udta", meta))
    }

    // MARK: Tags

    /// The iTunes tag atoms, one per `FLACTags` field: the ten FFmpeg wrote
    /// for the Electron app, in its order (spike, "AAC .m4a output"), plus
    /// the ISRC that files this app saves carry (D4 3.5) as the freeform
    /// atom "----:com.apple.iTunes:ISRC", which is where iTunes-style
    /// taggers keep it. Empty values are left out, and a track or disc
    /// number of 0 counts as empty, as in `FLACTags.vorbisFields`.
    static func tagAtoms(_ tags: FLACTags, coverJPEG: Data?, toolName: String) -> [Data] {
        typealias W = MP4BoxWriter
        func text(_ name: String, _ value: String?) -> Data? {
            guard let value, !value.isEmpty else { return nil }
            return W.box(name, W.dataAtom(type: 1, Data(value.utf8)))
        }
        /// trkn and disk as FFmpeg writes them: 2 empty bytes, the number,
        /// a total of 0, 2 empty bytes.
        func number(_ name: String, _ value: Int?) -> Data? {
            guard let value, value > 0, value <= Int(UInt16.max) else { return nil }
            return W.box(name, W.dataAtom(type: 0, W.u16(0) + W.u16(UInt16(value)) + W.u16(0) + W.u16(0)))
        }
        var isrc: Data?
        if let code = tags.isrc, !code.isEmpty {
            isrc = W.box("----",
                W.fullBox("mean", Data("com.apple.iTunes".utf8))
                + W.fullBox("name", Data("ISRC".utf8))
                + W.dataAtom(type: 1, Data(code.utf8)))
        }
        let atoms: [Data?] = [
            text("©nam", tags.title),
            text("©ART", tags.artist),
            text("aART", tags.albumArtist),
            text("©alb", tags.album),
            text("©day", tags.year),
            text("©too", toolName),
            text("cprt", tags.copyright),
            coverJPEG.map { W.box("covr", W.dataAtom(type: 13, $0)) },
            number("trkn", tags.trackNumber),
            number("disk", tags.discNumber),
            isrc,
        ]
        return atoms.compactMap { $0 }
    }
}

/// Builds the boxes of a progressive MP4 (ISO/IEC 14496-12). Every box is
/// small except the sample tables, which grow by 4 bytes per AAC packet
/// (about 100 KB for a ten-minute track).
enum MP4BoxWriter {
    /// A box type's four bytes. Types are Latin-1, so "©nam" is A9 6E 61 6D,
    /// not the UTF-8 spelling of "©".
    static func type(_ name: String) -> Data {
        let bytes = name.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
        precondition(bytes.count == 4 && name.unicodeScalars.allSatisfy { $0.value <= 0xFF }, "box type \(name)")
        return Data(bytes)
    }

    static func box(_ name: String, _ body: Data = Data()) -> Data {
        u32(UInt32(8 + body.count)) + type(name) + body
    }

    /// A box whose body starts with a version byte and 24 bits of flags.
    static func fullBox(_ name: String, version: UInt8 = 0, flags: UInt32 = 0, _ body: Data = Data()) -> Data {
        box(name, u32(UInt32(version) << 24 | flags & 0xFF_FFFF) + body)
    }

    static func u16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
    static func u32(_ v: UInt32) -> Data { var w = FLACByteWriter(); w.u32be(v); return w.data }
    static func u64(_ v: UInt64) -> Data { var w = FLACByteWriter(); w.u64be(v); return w.data }

    static let identityMatrix = [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000].map { u32(UInt32($0)) }.reduce(Data(), +)

    /// mdat's header. A body that doesn't fit a 32-bit size gets the 64-bit form.
    static func mdatHeader(bodySize: UInt64) -> Data {
        if bodySize + 8 <= UInt64(UInt32.max) { return u32(UInt32(bodySize + 8)) + type("mdat") }
        return u32(1) + type("mdat") + u64(bodySize + 16)
    }

    /// Version 1 (64-bit times) only when a duration needs it.
    static func movieHeader(timescale: UInt32, duration: UInt64) -> Data {
        let wide = duration > UInt64(UInt32.max)
        let times = wide ? u64(0) + u64(0) + u32(timescale) + u64(duration) : u32(0) + u32(0) + u32(timescale) + u32(UInt32(duration))
        // Rate 1.0, volume 1.0, 10 reserved bytes, the matrix, 24 bytes of
        // pre-defined zeros, and the next free track ID.
        let rest = u32(0x0001_0000) + u16(0x0100) + Data(count: 10) + identityMatrix + Data(count: 24) + u32(2)
        return fullBox("mvhd", version: wide ? 1 : 0, times + rest)
    }

    /// Track 1, enabled and in the movie (flags 3); alternate group 1 and
    /// full volume, as FFmpeg writes audio tracks.
    static func trackHeader(duration: UInt64) -> Data {
        let wide = duration > UInt64(UInt32.max)
        let times = wide ? u64(0) + u64(0) + u32(1) + u32(0) + u64(duration) : u32(0) + u32(0) + u32(1) + u32(0) + u32(UInt32(duration))
        let rest = Data(count: 8) + u16(0) + u16(1) + u16(0x0100) + u16(0) + identityMatrix + u32(0) + u32(0)
        return fullBox("tkhd", version: wide ? 1 : 0, flags: 3, times + rest)
    }

    static func mediaHeader(timescale: UInt32, duration: UInt64, language: UInt16) -> Data {
        let wide = duration > UInt64(UInt32.max)
        let times = wide ? u64(0) + u64(0) + u32(timescale) + u64(duration) : u32(0) + u32(0) + u32(timescale) + u32(UInt32(duration))
        return fullBox("mdhd", version: wide ? 1 : 0, times + u16(language) + u16(0))
    }

    static func editList(_ edit: MP4AudioTrack.Edit) -> Data {
        let wide = edit.segmentDuration > UInt64(UInt32.max) || edit.mediaTime > UInt64(Int32.max)
        let entry = wide ? u64(edit.segmentDuration) + u64(edit.mediaTime) : u32(UInt32(edit.segmentDuration)) + u32(UInt32(edit.mediaTime))
        return box("edts", fullBox("elst", version: wide ? 1 : 0, u32(1) + entry + u32(0x0001_0000)))
    }

    /// stts: runs of equal durations.
    static func timeToSample(_ durations: [UInt32]) -> Data {
        var runs: [(count: UInt32, delta: UInt32)] = []
        for d in durations {
            if let last = runs.last, last.delta == d { runs[runs.count - 1].count += 1 } else { runs.append((1, d)) }
        }
        return fullBox("stts", u32(UInt32(runs.count)) + runs.map { u32($0.count) + u32($0.delta) }.reduce(Data(), +))
    }

    /// stsc: a new entry wherever the samples per chunk change; every chunk
    /// uses sample description 1.
    static func sampleToChunk(_ chunks: [Int]) -> Data {
        var entries = Data()
        var count: UInt32 = 0
        var previous: Int?
        for (index, samples) in chunks.enumerated() where samples != previous {
            entries += u32(UInt32(index + 1)) + u32(UInt32(samples)) + u32(1)
            count += 1
            previous = samples
        }
        return fullBox("stsc", u32(count) + entries)
    }

    /// stsz: one size for every sample when they're all equal, as FFmpeg
    /// writes it; otherwise a table.
    static func sampleSizes(_ sizes: [Int]) -> Data {
        if let first = sizes.first, sizes.allSatisfy({ $0 == first }) {
            return fullBox("stsz", u32(UInt32(first)) + u32(UInt32(sizes.count)))
        }
        var table = FLACByteWriter()
        for size in sizes { table.u32be(UInt32(size)) }
        return fullBox("stsz", u32(0) + u32(UInt32(sizes.count)) + table.data)
    }

    /// stco, or co64 when an offset needs 64 bits.
    static func chunkOffsets(_ offsets: [UInt64], wide: Bool) -> Data {
        var table = FLACByteWriter()
        for offset in offsets { if wide { table.u64be(offset) } else { table.u32be(UInt32(offset)) } }
        return fullBox(wide ? "co64" : "stco", u32(UInt32(offsets.count)) + table.data)
    }

    /// The AAC pre-roll group FFmpeg writes (movenc.c
    /// mov_preroll_write_stbl): every sample needs the one before it decoded
    /// first (roll distance -1), so a player that seeks starts one packet early.
    static func rollGroup(sampleCount: Int) -> Data {
        fullBox("sgpd", version: 1, Data("roll".utf8) + u32(2) + u32(1) + u16(0xFFFF))
            + fullBox("sbgp", Data("roll".utf8) + u32(1) + u32(UInt32(sampleCount)) + u32(1))
    }

    /// An iTunes "data" atom: the value's type (1 text, 13 JPEG, 0 binary),
    /// a locale of 0, then the value.
    static func dataAtom(type: UInt32, _ value: Data) -> Data {
        box("data", u32(type) + u32(0) + value)
    }
}
