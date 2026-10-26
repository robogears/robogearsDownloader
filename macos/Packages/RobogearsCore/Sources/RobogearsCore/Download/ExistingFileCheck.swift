// The quick check of a file the app is about to skip (D4 2.3, option A).
//
// The Electron app skipped a song whenever "<Title>.flac" existed, without
// opening it, so a file cut short by a crash or a full disk blocked that
// song for good (2.2, 2.3). Before skipping, the Swift app now reads the
// start and the last stretch of the existing file and judges its structure,
// never its tags, so files the person put there by hand are judged the same
// way. It catches the likely failure, a file that stops early, at almost no
// cost; it can't see damage in the middle of a file (2.3's stated cost).
//
// A full decode isn't used: AVFoundation can't decode an Electron-era FLAC
// whose STREAMINFO leaves the sample count at 0 (the "length unknown" trap in
// docs/spikes/audio-and-tagging.md, part a), and decoding a Hi-Res track
// takes seconds. The FLAC check is the native frame walk the spike asked
// for, limited to the final frame.
import AVFoundation
import Foundation

public enum ExistingFileCheck {
    /// What the check found.
    public enum Verdict: Sendable, Equatable {
        case healthy
        case damaged(Problem)

        public var isHealthy: Bool { self == .healthy }
    }

    /// Why a file looks damaged, for the activity log and the tests. The row
    /// only ever says "looks damaged" (2.3).
    public enum Problem: Sendable, Equatable {
        /// The file's own structure can't be read: no "fLaC" marker, a bad
        /// STREAMINFO, or an MP4 that doesn't start with its "ftyp" box.
        case unreadable
        /// No valid FLAC frame where the audio should start.
        case noAudioFrames
        /// The file doesn't end with a complete FLAC frame whose checksum
        /// holds: it was cut off, or something other than audio follows.
        case cutOff
        /// More zero bytes after the last frame than any tool leaves.
        case unexpectedDataAtEnd
        /// The last frame is complete but ends before (or after) the length
        /// STREAMINFO declares: whole frames are missing.
        case endsBeforeDeclaredLength(declaredSamples: UInt64, lastFrameEnd: UInt64)
        /// The MP4's top-level boxes don't add up to the file's size, or a
        /// box needed to play it is missing.
        case boxesDontAddUp
        /// The file's length is too far from the length TIDAL lists.
        case lengthDiffers(fileSeconds: Double, tidalSeconds: Double)
    }

    /// "Within 2 seconds or 1%, whichever is larger" (2.2, 2.3).
    public static func lengthTolerance(forTIDALSeconds tidal: Double) -> Double {
        max(2, tidal * 0.01)
    }

    public static func lengthsAgree(fileSeconds: Double, tidalSeconds: Double) -> Bool {
        abs(fileSeconds - tidalSeconds) <= lengthTolerance(forTIDALSeconds: tidalSeconds)
    }

    /// Judges a .flac or .m4a by its structure. `tidalSeconds` is TIDAL's
    /// length when the row knows it; without it, only the file's agreement
    /// with itself is checked. Never writes anything.
    public static func check(_ url: URL, as kind: FileNaming.AudioExtension, tidalSeconds: Double?) async -> Verdict {
        let tidal = tidalSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        switch kind {
        case .flac: return checkFLAC(url, tidalSeconds: tidal)
        case .m4a: return await checkM4A(url, tidalSeconds: tidal)
        }
    }

    // MARK: - FLAC

    /// Zero bytes allowed after the last frame. Some tools pad a file; a long
    /// run of zeros is what a crash can leave where the data never landed.
    static let allowedZeroPadding = 64 << 10

    /// The ID3v1 tag some taggers append: 128 bytes starting "TAG". The FLAC
    /// format doesn't allow it, but players skip it, so the check does too.
    static let id3v1Size = 128

    /// How far back from the end the last frame is looked for. Real frames
    /// are a few KB; the window grows for formats whose frames can be larger.
    static let minimumSearchWindow = 64 << 10
    static let maximumSearchWindow = 16 << 20

    /// The checks, in order:
    /// 1. STREAMINFO is valid (sample rate, channels and bit depth set).
    /// 2. A valid frame header sits where the audio starts.
    /// 3. The file ends with a complete frame: the last frame header in the
    ///    final stretch (sync code 0xFFF8/0xFFF9, CRC-8 checked) is followed
    ///    by exactly one frame whose CRC-16 footer closes the file. Allowed
    ///    after it: up to 64 KB of zero bytes and one ID3v1 tag.
    /// 4. That frame's position (from its frame or sample number) ends the
    ///    stream at the sample count STREAMINFO declares. A declared count of
    ///    0 means "unknown" (Electron-era files copied from live-packaged DASH
    ///    streams); then the last frame's end is the file's length.
    /// 5. The length is within the tolerance of TIDAL's, when known.
    static func checkFLAC(_ url: URL, tidalSeconds: Double?) -> Verdict {
        guard let summary = try? FLACMetadataReader.summary(of: url),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return .damaged(.unreadable) }
        defer { try? handle.close() }
        let info = summary.streamInfo
        guard info.sampleRate > 0, info.channelCount >= 1, info.bitsPerSample >= 4,
              let fileSize = try? Int(handle.seekToEnd())
        else { return .damaged(.unreadable) }

        // 2. The first frame. A header is at most 16 bytes.
        guard fileSize > summary.audioOffset,
              let head = read(handle, at: summary.audioOffset, count: min(32, fileSize - summary.audioOffset)),
              let first = FLACFrameHeader.parse(FLACByteReader(head), at: 0)
        else { return .damaged(.noAudioFrames) }

        // 3. The end, without a trailing ID3v1 tag.
        var end = fileSize
        if end - summary.audioOffset > id3v1Size,
           let tag = read(handle, at: end - id3v1Size, count: 3), tag == Data("TAG".utf8) {
            end -= id3v1Size
        }
        let blockSize = max(Int(info.maximumBlockSize), first.blockSize)
        let frameBound = info.maximumFrameSize > 0
            ? Int(info.maximumFrameSize)
            : blockSize * Int(info.channelCount) * 4 + 64
        let search = min(max(minimumSearchWindow, 2 * frameBound), maximumSearchWindow)
        let windowStart = max(summary.audioOffset, end - search - allowedZeroPadding)
        guard end > windowStart, let tail = read(handle, at: windowStart, count: end - windowStart) else {
            return .damaged(.cutOff)
        }
        let bytes = [UInt8](tail)
        var contentEnd = bytes.count
        while contentEnd > 0, bytes[contentEnd - 1] == 0 { contentEnd -= 1 }
        guard bytes.count - contentEnd <= allowedZeroPadding else { return .damaged(.unexpectedDataAtEnd) }
        guard let last = lastCompleteFrame(bytes, contentEnd: contentEnd) else { return .damaged(.cutOff) }

        // 4. Where that frame ends the stream.
        let lastFrameEnd: UInt64 = last.variableBlockSize
            ? last.number + UInt64(last.blockSize)
            : last.number * UInt64(first.blockSize) + UInt64(last.blockSize)
        let declared = info.totalSamples
        if declared != 0, lastFrameEnd != declared {
            return .damaged(.endsBeforeDeclaredLength(declaredSamples: declared, lastFrameEnd: lastFrameEnd))
        }
        let samples = declared != 0 ? declared : lastFrameEnd
        let fileSeconds = Double(samples) / Double(info.sampleRate)

        // 5. Against TIDAL.
        if let tidalSeconds, !lengthsAgree(fileSeconds: fileSeconds, tidalSeconds: tidalSeconds) {
            return .damaged(.lengthDiffers(fileSeconds: fileSeconds, tidalSeconds: tidalSeconds))
        }
        return .healthy
    }

    struct LastFrame: Equatable {
        /// The frame number (fixed block size) or the first sample's number
        /// (variable block size), as the header codes it.
        var number: UInt64
        var variableBlockSize: Bool
        var blockSize: Int
    }

    /// The frame that closes the data: the latest valid header whose bytes
    /// through the end (zero padding included) pass the CRC-16 check. A
    /// frame's CRC-16 over itself and its footer is 0, and trailing zero
    /// bytes keep it 0, while they can never turn a wrong sum into 0 (the
    /// polynomial has a constant term). So a frame cut short or followed by
    /// anything but zeros fails, whatever comes after it.
    static func lastCompleteFrame(_ bytes: [UInt8], contentEnd: Int) -> LastFrame? {
        guard contentEnd >= 2 else { return nil }
        let reader = FLACByteReader(Data(bytes))
        var position = contentEnd - 2
        while position >= 0 {
            defer { position -= 1 }
            guard bytes[position] == 0xFF, bytes[position + 1] & 0xFE == 0xF8,
                  let header = FLACFrameHeader.parse(reader, at: position),
                  position + header.length + 2 <= bytes.count,
                  crc16(bytes, from: position) == 0,
                  let number = codedNumber(bytes, at: position + 4)
            else { continue }
            return LastFrame(number: number, variableBlockSize: bytes[position + 1] & 0x01 != 0,
                             blockSize: header.blockSize)
        }
        return nil
    }

    /// The frame or sample number after the frame header's first four bytes,
    /// coded like UTF-8 (RFC 9639 §9.1.5).
    static func codedNumber(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset < bytes.count else { return nil }
        let lead = bytes[offset]
        let (extra, mask): (Int, UInt8)
        switch lead {
        case 0x00...0x7F: (extra, mask) = (0, 0x7F)
        case 0xC0...0xDF: (extra, mask) = (1, 0x1F)
        case 0xE0...0xEF: (extra, mask) = (2, 0x0F)
        case 0xF0...0xF7: (extra, mask) = (3, 0x07)
        case 0xF8...0xFB: (extra, mask) = (4, 0x03)
        case 0xFC...0xFD: (extra, mask) = (5, 0x01)
        case 0xFE: (extra, mask) = (6, 0x00)
        default: return nil
        }
        guard offset + extra < bytes.count else { return nil }
        var value = UInt64(lead & mask)
        for continuation in bytes[(offset + 1)..<(offset + 1 + extra)] {
            value = value << 6 | UInt64(continuation & 0x3F)
        }
        return value
    }

    /// CRC-16 with polynomial x¹⁶ + x¹⁵ + x² + 1 (0x8005), initial value 0,
    /// as RFC 9639 §9.3 specifies for the frame footer.
    static func crc16(_ bytes: [UInt8], from start: Int) -> UInt16 {
        var crc: UInt16 = 0
        for index in start..<bytes.count {
            crc = (crc << 8) ^ crc16Table[Int(UInt8(crc >> 8) ^ bytes[index])]
        }
        return crc
    }

    static let crc16Table: [UInt16] = (0..<256).map { byte in
        var c = UInt16(byte) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
        return c
    }

    // MARK: - M4A

    /// 1. The file starts with an "ftyp" box, its top-level boxes add up to
    ///    exactly the file's size, and it has "moov" and "mdat". A file cut
    ///    short ends inside a box (FFmpeg's .m4a has "moov" at the end, so a
    ///    cut-off copy also lacks it).
    /// 2. AVFoundation reads a length, and it is within the tolerance of
    ///    TIDAL's when known.
    static func checkM4A(_ url: URL, tidalSeconds: Double?) async -> Verdict {
        guard let boxes = topLevelBoxes(url) else { return .damaged(.boxesDontAddUp) }
        guard boxes.first == "ftyp" else { return .damaged(.unreadable) }
        guard boxes.contains("moov"), boxes.contains("mdat") else { return .damaged(.boxesDontAddUp) }
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return .damaged(.unreadable) }
        let fileSeconds = CMTimeGetSeconds(duration)
        guard fileSeconds.isFinite, fileSeconds > 0 else { return .damaged(.unreadable) }
        if let tidalSeconds, !lengthsAgree(fileSeconds: fileSeconds, tidalSeconds: tidalSeconds) {
            return .damaged(.lengthDiffers(fileSeconds: fileSeconds, tidalSeconds: tidalSeconds))
        }
        return .healthy
    }

    /// The four-character types of the top-level boxes, or nil when their
    /// sizes don't add up to the file's size. Reads only the box headers.
    static func topLevelBoxes(_ url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? Int(handle.seekToEnd()) else { return nil }
        var types: [String] = []
        var offset = 0
        while offset < size {
            guard let header = read(handle, at: offset, count: 8) else { return nil }
            let r = FLACByteReader(header)
            var boxSize = Int(r.u32be(0))
            var headerSize = 8
            if boxSize == 1 {
                guard let large = read(handle, at: offset + 8, count: 8) else { return nil }
                let value = FLACByteReader(large).u64be(0)
                guard value <= UInt64(Int.max) else { return nil }
                boxSize = Int(value)
                headerSize = 16
            } else if boxSize == 0 {
                // "To the end of the file", allowed for the last box only.
                boxSize = size - offset
            }
            guard boxSize >= headerSize, boxSize <= size - offset else { return nil }
            types.append(String(decoding: header[(header.startIndex + 4)..<(header.startIndex + 8)], as: UTF8.self))
            offset += boxSize
        }
        return types
    }

    // MARK: - Reading

    /// Exactly `count` bytes at `offset`, or nil.
    static func read(_ handle: FileHandle, at offset: Int, count: Int) -> Data? {
        guard offset >= 0, count >= 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: count) ?? Data()
            return data.count == count ? data : nil
        } catch {
            return nil
        }
    }
}
