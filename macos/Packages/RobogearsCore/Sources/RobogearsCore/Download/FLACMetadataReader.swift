// Reads the metadata part of a .flac file and checks FLAC frame headers.
//
// Used by the native writer (to take a BTS stream's STREAMINFO and find
// where its audio starts) and by the spike to record exactly what FFmpeg
// wrote. It reads only the metadata blocks, so the library scanner can hand
// it the head of a file (decision card G3-10, recommended option: small own
// readers instead of a tag library).
import Foundation

/// The layout of a FLAC file: its metadata blocks and where the audio begins.
public struct FLACFileLayout: Sendable, Equatable {
    /// Bytes in front of "fLaC". Some taggers put an ID3v2 tag there; the
    /// FLAC format doesn't allow it, but players skip it, so the reader does too.
    public var leadingTagSize: Int
    /// Every metadata block, in file order.
    public var blocks: [FLACMetadataBlock]
    /// Where the first audio frame starts, counted from the start of the data.
    public var audioOffset: Int
    public var streamInfo: FLACStreamInfo
    /// The first VORBIS_COMMENT block (the format allows only one).
    public var vorbisComment: FLACVorbisComment?
    public var pictures: [FLACPicture]
}

public enum FLACMetadataReader {
    /// Reads the metadata blocks. The data needs to reach the end of the last
    /// block; audio frames after that are neither needed nor checked.
    public static func read(_ data: Data) throws -> FLACFileLayout {
        let r = FLACByteReader(data)
        let start = leadingID3v2Size(r)
        guard r.has(start, 4),
              r.u8(start) == 0x66, r.u8(start + 1) == 0x4C, r.u8(start + 2) == 0x61, r.u8(start + 3) == 0x43
        else { throw FLACFormatError.notFLAC }

        var blocks: [FLACMetadataBlock] = []
        var o = start + 4
        var isLast = false
        while !isLast {
            guard r.has(o, 4) else { throw FLACFormatError.truncated("metadata block header") }
            let header = r.u8(o)
            isLast = header & 0x80 != 0
            let length = Int(r.u24be(o + 1))
            guard r.has(o + 4, length) else { throw FLACFormatError.truncated("metadata block body") }
            blocks.append(FLACMetadataBlock(typeCode: header & 0x7F, body: r.bytes(o + 4, length)))
            o += 4 + length
        }

        guard let first = blocks.first, first.type == .streamInfo else { throw FLACFormatError.invalidStreamInfo }
        let streamInfo = try FLACStreamInfo(bytes: first.body)
        let comment = try blocks.first { $0.type == .vorbisComment }.map { try FLACVorbisComment(bytes: $0.body) }
        let pictures = try blocks.filter { $0.type == .picture }.map { try FLACPicture(bytes: $0.body) }
        return FLACFileLayout(
            leadingTagSize: start, blocks: blocks, audioOffset: o,
            streamInfo: streamInfo, vorbisComment: comment, pictures: pictures
        )
    }

    /// The size of an ID3v2 tag at the start of the data, or 0 when there is none.
    static func leadingID3v2Size(_ r: FLACByteReader) -> Int {
        guard r.has(0, 10), r.u8(0) == 0x49, r.u8(1) == 0x44, r.u8(2) == 0x33 else { return 0 }
        // The size is "syncsafe": four bytes of seven bits each.
        let size = (0..<4).reduce(0) { $0 << 7 | Int(r.u8(6 + $1) & 0x7F) }
        let hasFooter = r.u8(5) & 0x10 != 0
        return 10 + size + (hasFooter ? 10 : 0)
    }
}

// MARK: - Frame headers

/// What a FLAC frame header says (RFC 9639 §9.1). The writer never decodes
/// audio; it only reads headers to prove that bytes taken out of an MP4 are
/// really FLAC frames and to count their samples.
struct FLACFrameHeader: Equatable {
    /// Samples per channel in this frame.
    var blockSize: Int
    /// Header length in bytes, including its CRC-8.
    var length: Int

    /// Parses the header at `offset`, or returns nil unless the sync code,
    /// every field and the header's CRC-8 are valid. The CRC makes a false
    /// match on random audio bytes a 1-in-256 chance on top of the sync code
    /// and field checks.
    static func parse(_ r: FLACByteReader, at offset: Int) -> FLACFrameHeader? {
        guard r.has(offset, 5) else { return nil }
        // 14-bit sync code 0b11111111111110, a reserved 0 bit, then the blocking strategy bit.
        guard r.u8(offset) == 0xFF, r.u8(offset + 1) & 0xFE == 0xF8 else { return nil }
        let blockCode = r.u8(offset + 2) >> 4
        let rateCode = r.u8(offset + 2) & 0x0F
        let channelCode = r.u8(offset + 3) >> 4
        let sizeCode = (r.u8(offset + 3) >> 1) & 0x07
        guard blockCode != 0, rateCode != 0x0F, channelCode <= 10, sizeCode != 3 else { return nil }

        // The frame or sample number, coded like UTF-8 (up to 7 bytes).
        var o = offset + 4
        let lead = r.u8(o)
        let extra: Int
        switch lead {
        case 0x00...0x7F: extra = 0
        case 0xC0...0xDF: extra = 1
        case 0xE0...0xEF: extra = 2
        case 0xF0...0xF7: extra = 3
        case 0xF8...0xFB: extra = 4
        case 0xFC...0xFD: extra = 5
        case 0xFE: extra = 6
        default: return nil
        }
        guard r.has(o, 1 + extra) else { return nil }
        for i in 0..<extra where r.u8(o + 1 + i) & 0xC0 != 0x80 { return nil }
        o += 1 + extra

        var blockSize: Int
        switch blockCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << (Int(blockCode) - 2)
        case 6:
            guard r.has(o, 1) else { return nil }
            blockSize = Int(r.u8(o)) + 1
            o += 1
        case 7:
            guard r.has(o, 2) else { return nil }
            blockSize = Int(r.u16be(o)) + 1
            o += 2
        default: blockSize = 256 << (Int(blockCode) - 8)
        }
        switch rateCode {
        case 12: o += 1
        case 13, 14: o += 2
        default: break
        }
        guard r.has(o, 1) else { return nil }
        var crc: UInt8 = 0
        for i in offset..<o { crc = crc8Table[Int(crc ^ r.u8(i))] }
        guard crc == r.u8(o) else { return nil }
        return FLACFrameHeader(blockSize: blockSize, length: o + 1 - offset)
    }

    /// CRC-8 with polynomial x⁸ + x² + x + 1 (0x07), as RFC 9639 §9.1.8 specifies.
    static let crc8Table: [UInt8] = (0..<256).map { byte in
        var c = UInt8(byte)
        for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        return c
    }
}
