// FLAC metadata blocks: the pieces of a .flac file that aren't audio.
//
// The Electron app let FFmpeg write these (tidal_download.js remuxToFlac,
// docs/electron-reference/download-pipeline.md B11). The Swift app writes
// them itself, so this file holds the block formats from RFC 9639 §8 with
// a decoder and an encoder for each. docs/spikes/audio-and-tagging.md records
// exactly what FFmpeg wrote and why the native writer matches it.
import Foundation

/// Everything that can go wrong reading or writing FLAC and FLAC-in-MP4.
/// Cases name the problem in the file, so the download pipeline can choose
/// its own wording for the row.
public enum FLACFormatError: Error, Sendable, Equatable {
    /// The data doesn't start with "fLaC" (after an optional ID3v2 tag).
    case notFLAC
    /// The data ends inside the named structure.
    case truncated(String)
    /// STREAMINFO is missing, not first, or not 34 bytes long.
    case invalidStreamInfo
    case invalidVorbisComment
    case invalidPicture
    /// A metadata block body is longer than the 24-bit length field allows.
    case blockTooLarge(typeCode: UInt8, size: Int)
    /// No valid FLAC frame header where the audio should start.
    case noAudioFrames
    /// A sample inside an MP4 fragment doesn't start with a valid FLAC frame
    /// header; `offset` is where the sample starts in the source.
    case invalidFrame(offset: Int)
    /// The data isn't an ISO base media (MP4) file.
    case notMP4
    /// The MP4's audio track holds another codec, such as "mp4a" for AAC.
    case notFLACInMP4(codec: String)
    /// The FLAC sample entry has no dfLa box, so there's no STREAMINFO.
    case missingFLACConfiguration
    /// A layout this extractor doesn't handle; the text names it.
    case unsupportedMP4(String)
    /// The cover bytes don't start with a JPEG start-of-image marker.
    case coverIsNotJPEG
    /// The JPEG has no frame header, so its size can't be read.
    case coverUnreadable
}

/// The metadata block types in RFC 9639 §8.1.
public enum FLACBlockType: UInt8, Sendable, CaseIterable {
    case streamInfo = 0
    case padding = 1
    case application = 2
    case seekTable = 3
    case vorbisComment = 4
    case cueSheet = 5
    case picture = 6
}

/// One metadata block as stored: its 7-bit type code and its body.
/// Unknown type codes are kept rather than rejected, so a file from a newer
/// encoder still reads.
public struct FLACMetadataBlock: Sendable, Equatable {
    public var typeCode: UInt8
    public var body: Data

    public var type: FLACBlockType? { FLACBlockType(rawValue: typeCode) }

    public init(typeCode: UInt8, body: Data) {
        self.typeCode = typeCode
        self.body = body
    }

    public init(_ type: FLACBlockType, body: Data) {
        self.init(typeCode: type.rawValue, body: body)
    }
}

// MARK: - STREAMINFO

/// The STREAMINFO block (RFC 9639 §8.2): the stream's shape and length.
/// Zero means "unknown" for the frame sizes, the total sample count and the
/// MD5, which is what a live encoder leaves when it can't go back and fill
/// them in (see the spike: FFmpeg copies such a block unchanged, and
/// AVFoundation then can't decode the file).
public struct FLACStreamInfo: Sendable, Equatable {
    public static let byteCount = 34

    public var minimumBlockSize: UInt16
    public var maximumBlockSize: UInt16
    public var minimumFrameSize: UInt32
    public var maximumFrameSize: UInt32
    public var sampleRate: UInt32
    public var channelCount: UInt8
    public var bitsPerSample: UInt8
    public var totalSamples: UInt64
    public var md5: Data

    public init(
        minimumBlockSize: UInt16, maximumBlockSize: UInt16,
        minimumFrameSize: UInt32, maximumFrameSize: UInt32,
        sampleRate: UInt32, channelCount: UInt8, bitsPerSample: UInt8,
        totalSamples: UInt64, md5: Data
    ) {
        self.minimumBlockSize = minimumBlockSize
        self.maximumBlockSize = maximumBlockSize
        self.minimumFrameSize = minimumFrameSize
        self.maximumFrameSize = maximumFrameSize
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
        self.totalSamples = totalSamples
        self.md5 = md5
    }

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw FLACFormatError.invalidStreamInfo }
        let r = FLACByteReader(bytes)
        minimumBlockSize = r.u16be(0)
        maximumBlockSize = r.u16be(2)
        minimumFrameSize = r.u24be(4)
        maximumFrameSize = r.u24be(7)
        // 20 bits sample rate, 3 bits channels - 1, 5 bits bits-per-sample - 1,
        // 36 bits total samples, packed into the next eight bytes.
        let packed = r.u64be(10)
        sampleRate = UInt32(packed >> 44)
        channelCount = UInt8((packed >> 41) & 0x7) + 1
        bitsPerSample = UInt8((packed >> 36) & 0x1F) + 1
        totalSamples = packed & 0xF_FFFF_FFFF
        md5 = r.bytes(18, 16)
        guard sampleRate > 0 else { throw FLACFormatError.invalidStreamInfo }
    }

    public var bytes: Data {
        var w = FLACByteWriter()
        w.u16be(minimumBlockSize)
        w.u16be(maximumBlockSize)
        w.u24be(minimumFrameSize)
        w.u24be(maximumFrameSize)
        var packed = UInt64(sampleRate & 0xF_FFFF) << 44
        packed |= UInt64((max(channelCount, 1) - 1) & 0x7) << 41
        packed |= UInt64((max(bitsPerSample, 1) - 1) & 0x1F) << 36
        packed |= totalSamples & 0xF_FFFF_FFFF
        w.u64be(packed)
        var digest = md5.prefix(16)
        if digest.count < 16 { digest.append(Data(count: 16 - digest.count)) }
        w.append(digest)
        return w.data
    }

    /// Length in seconds, when the total sample count is known.
    public var duration: Double? {
        totalSamples == 0 ? nil : Double(totalSamples) / Double(sampleRate)
    }
}

// MARK: - VORBIS_COMMENT

/// The VORBIS_COMMENT block (RFC 9639 §8.6): the vendor string and the tags.
/// Field names are compared without regard to case, as the format says, but
/// stored exactly as written so a byte-level comparison with FFmpeg's files
/// stays possible.
public struct FLACVorbisComment: Sendable, Equatable {
    public struct Field: Sendable, Equatable {
        public var name: String
        public var value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    public var vendor: String
    public var fields: [Field]

    public init(vendor: String, fields: [Field]) {
        self.vendor = vendor
        self.fields = fields
    }

    /// Reads a block body. A field without "=" is kept as a name with an
    /// empty value rather than failing the whole file, because the library
    /// scanner reads files written by any tagger.
    public init(bytes: Data) throws {
        let r = FLACByteReader(bytes)
        var o = 0
        func string() throws -> String {
            guard r.has(o, 4) else { throw FLACFormatError.invalidVorbisComment }
            let length = Int(r.u32le(o))
            guard r.has(o + 4, length) else { throw FLACFormatError.invalidVorbisComment }
            let text = String(decoding: r.bytes(o + 4, length), as: UTF8.self)
            o += 4 + length
            return text
        }
        vendor = try string()
        guard r.has(o, 4) else { throw FLACFormatError.invalidVorbisComment }
        let count = Int(r.u32le(o))
        o += 4
        // Each field needs at least its 4-byte length, which bounds a corrupt count.
        guard count <= (r.count - o) / 4 else { throw FLACFormatError.invalidVorbisComment }
        var fields: [Field] = []
        fields.reserveCapacity(count)
        for _ in 0..<count {
            let entry = try string()
            if let equals = entry.firstIndex(of: "=") {
                fields.append(Field(String(entry[..<equals]), String(entry[entry.index(after: equals)...])))
            } else {
                fields.append(Field(entry, ""))
            }
        }
        self.fields = fields
    }

    public var bytes: Data {
        var w = FLACByteWriter()
        let vendorBytes = Data(vendor.utf8)
        w.u32le(UInt32(vendorBytes.count))
        w.append(vendorBytes)
        w.u32le(UInt32(fields.count))
        for field in fields {
            let entry = Data("\(field.name)=\(field.value)".utf8)
            w.u32le(UInt32(entry.count))
            w.append(entry)
        }
        return w.data
    }

    /// Every value stored under `name`, matched without regard to case.
    public func values(for name: String) -> [String] {
        let wanted = name.uppercased()
        return fields.filter { $0.name.uppercased() == wanted }.map(\.value)
    }
}

// MARK: - PICTURE

/// The PICTURE block (RFC 9639 §8.8). Type 3 is the front cover, the only
/// type Rekordbox shows (owner's v0.1.17 fix; CLAUDE.md "Cover art").
public struct FLACPicture: Sendable, Equatable {
    public static let frontCoverType: UInt32 = 3
    /// The description FFmpeg wrote from the Electron app's
    /// `-metadata:s:v title=Album cover` (download-pipeline.md B11 step 7).
    public static let frontCoverDescription = "Album cover"

    public var pictureType: UInt32
    public var mimeType: String
    public var description: String
    public var width: UInt32
    public var height: UInt32
    public var colorDepth: UInt32
    public var colorCount: UInt32
    public var data: Data

    public init(
        pictureType: UInt32, mimeType: String, description: String,
        width: UInt32, height: UInt32, colorDepth: UInt32, colorCount: UInt32, data: Data
    ) {
        self.pictureType = pictureType
        self.mimeType = mimeType
        self.description = description
        self.width = width
        self.height = height
        self.colorDepth = colorDepth
        self.colorCount = colorCount
        self.data = data
    }

    public init(bytes: Data) throws {
        let r = FLACByteReader(bytes)
        var o = 0
        func u32() throws -> UInt32 {
            guard r.has(o, 4) else { throw FLACFormatError.invalidPicture }
            defer { o += 4 }
            return r.u32be(o)
        }
        func blob() throws -> Data {
            let length = Int(try u32())
            guard r.has(o, length) else { throw FLACFormatError.invalidPicture }
            defer { o += length }
            return r.bytes(o, length)
        }
        pictureType = try u32()
        mimeType = String(decoding: try blob(), as: UTF8.self)
        description = String(decoding: try blob(), as: UTF8.self)
        width = try u32()
        height = try u32()
        colorDepth = try u32()
        colorCount = try u32()
        data = try blob()
    }

    public var bytes: Data {
        var w = FLACByteWriter()
        let mime = Data(mimeType.utf8)
        let text = Data(description.utf8)
        w.u32be(pictureType)
        w.u32be(UInt32(mime.count))
        w.append(mime)
        w.u32be(UInt32(text.count))
        w.append(text)
        w.u32be(width)
        w.u32be(height)
        w.u32be(colorDepth)
        w.u32be(colorCount)
        w.u32be(UInt32(data.count))
        w.append(data)
        return w.data
    }

    /// A front cover built from JPEG bytes, filled in the way FFmpeg filled
    /// it for the Electron app: type 3, "image/jpeg", "Album cover", the
    /// JPEG's own width and height, its average bits per pixel and no
    /// palette. Only JPEG is accepted because the Electron app fed covers to
    /// FFmpeg as `-f mjpeg`, which fails on anything else.
    public static func frontCover(jpeg: Data) throws -> FLACPicture {
        let frame = try JPEGFrameInfo(jpeg)
        return FLACPicture(
            pictureType: frontCoverType, mimeType: "image/jpeg", description: frontCoverDescription,
            width: frame.width, height: frame.height, colorDepth: frame.bitsPerPixel, colorCount: 0, data: jpeg
        )
    }
}

/// The size and average bits per pixel from a JPEG's frame header (SOFn).
/// Bits per pixel is precision × Σ(Hᵢ·Vᵢ) / (Hmax·Vmax), which is what FFmpeg
/// reports for the decoded pixel format: 12 for 4:2:0 colour, 16 for 4:2:2,
/// 24 for 4:4:4 and 8 for greyscale.
struct JPEGFrameInfo: Equatable {
    var width: UInt32
    var height: UInt32
    var bitsPerPixel: UInt32

    init(_ jpeg: Data) throws {
        let r = FLACByteReader(jpeg)
        guard r.has(0, 2), r.u8(0) == 0xFF, r.u8(1) == 0xD8 else { throw FLACFormatError.coverIsNotJPEG }
        var o = 2
        while r.has(o, 2) {
            guard r.u8(o) == 0xFF else { throw FLACFormatError.coverUnreadable }
            // Fill bytes: any number of 0xFF may precede the marker code.
            var p = o + 1
            while r.has(p, 1), r.u8(p) == 0xFF { p += 1 }
            guard r.has(p, 1) else { break }
            let marker = r.u8(p)
            o = p + 1
            // Markers without a length: TEM and the restart markers. SOI again is malformed.
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { continue }
            if marker == 0xD9 || marker == 0xDA { break } // end of image, or scan data with no frame header seen
            guard r.has(o, 2) else { break }
            let length = Int(r.u16be(o))
            guard length >= 2, r.has(o, length) else { break }
            let isFrameHeader = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if isFrameHeader {
                guard length >= 8 else { break }
                let precision = UInt32(r.u8(o + 2))
                let height = UInt32(r.u16be(o + 3))
                let width = UInt32(r.u16be(o + 5))
                let components = Int(r.u8(o + 7))
                guard components > 0, length >= 8 + components * 3 else { break }
                var sum: UInt32 = 0
                var hMax: UInt32 = 1
                var vMax: UInt32 = 1
                for c in 0..<components {
                    let sampling = r.u8(o + 8 + c * 3 + 1)
                    let h = UInt32(sampling >> 4), v = UInt32(sampling & 0x0F)
                    sum += h * v
                    hMax = max(hMax, h)
                    vMax = max(vMax, v)
                }
                self.width = width
                self.height = height
                self.bitsPerPixel = precision * sum / (hMax * vMax)
                return
            }
            o += length
        }
        throw FLACFormatError.coverUnreadable
    }
}

// MARK: - Byte helpers

/// Big- and little-endian reads over Data. Data slices keep their parent's
/// indices, so every read is offset from `startIndex`; callers check `has`
/// before reading, and a read past the end traps rather than misreading.
struct FLACByteReader {
    let data: Data

    init(_ data: Data) { self.data = data }

    var count: Int { data.count }

    func has(_ offset: Int, _ length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= data.count && length <= data.count - offset
    }

    func u8(_ o: Int) -> UInt8 { data[data.startIndex + o] }
    func u16be(_ o: Int) -> UInt16 { UInt16(u8(o)) << 8 | UInt16(u8(o + 1)) }
    func u24be(_ o: Int) -> UInt32 { UInt32(u8(o)) << 16 | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) }
    func u32be(_ o: Int) -> UInt32 { UInt32(u16be(o)) << 16 | UInt32(u16be(o + 2)) }
    func u64be(_ o: Int) -> UInt64 { UInt64(u32be(o)) << 32 | UInt64(u32be(o + 4)) }
    func u32le(_ o: Int) -> UInt32 {
        UInt32(u8(o)) | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) << 16 | UInt32(u8(o + 3)) << 24
    }

    /// A copy of `length` bytes, re-based to start at index 0.
    func bytes(_ o: Int, _ length: Int) -> Data {
        Data(data[(data.startIndex + o)..<(data.startIndex + o + length)])
    }
}

/// The matching writer: appends big- and little-endian integers to a Data.
struct FLACByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16be(_ v: UInt16) { data.append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func u24be(_ v: UInt32) {
        data.append(contentsOf: [UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    mutating func u32be(_ v: UInt32) { u16be(UInt16(v >> 16)); u16be(UInt16(v & 0xFFFF)) }
    mutating func u64be(_ v: UInt64) { u32be(UInt32(v >> 32)); u32be(UInt32(v & 0xFFFF_FFFF)) }
    mutating func u32le(_ v: UInt32) {
        data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }
    mutating func append(_ bytes: Data) { data.append(bytes) }
}
