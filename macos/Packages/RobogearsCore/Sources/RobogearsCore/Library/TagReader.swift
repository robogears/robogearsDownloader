import AVFoundation
import Foundation

/// The tags the library check needs from one audio file.
public struct AudioTags: Codable, Equatable, Sendable {
    public var title: String?
    /// Every ARTIST value the file carries, in order (FLAC and Ogg may repeat it).
    public var artists: [String]
    public var durationSeconds: Double?
    /// The industry code for one recording; files this app saved carry it
    /// (decision 4, item 3.5).
    public var isrc: String?

    public init(title: String? = nil, artists: [String] = [], durationSeconds: Double? = nil, isrc: String? = nil) {
        self.title = title
        self.artists = artists
        self.durationSeconds = durationSeconds
        self.isrc = isrc
    }
}

public protocol TagReading: Sendable {
    func readTags(at url: URL) async -> AudioTags?
}

/// Reads tags the way decision 4, item 3.10 recommends: Apple's reader for
/// MP3, M4A, AAC, WAV and AIFF, and small parsers of our own for FLAC and
/// Ogg (Vorbis and Opus), whose tags AVFoundation reads poorly.
public struct TagReader: TagReading {
    public init() {}

    public func readTags(at url: URL) async -> AudioTags? {
        switch url.pathExtension.lowercased() {
        case "flac":
            return try? FLACCommentReader.read(url)
        case "ogg", "oga", "opus":
            return try? OggCommentReader.read(url)
        default:
            return await Self.readWithAVFoundation(url)
        }
    }

    static func readWithAVFoundation(_ url: URL) async -> AudioTags? {
        let asset = AVURLAsset(url: url)
        guard let (metadata, duration) = try? await asset.load(.metadata, .duration) else { return nil }
        var tags = AudioTags()
        let seconds = CMTimeGetSeconds(duration)
        if seconds.isFinite, seconds > 0 { tags.durationSeconds = seconds }
        for item in metadata {
            let common = item.commonKey
            let raw = (item.identifier?.rawValue ?? "").lowercased()
            if common == .commonKeyTitle, tags.title == nil {
                tags.title = try? await item.load(.stringValue)
            } else if common == .commonKeyArtist, tags.artists.isEmpty,
                      let artist = try? await item.load(.stringValue), !artist.isEmpty {
                tags.artists = [artist]
            } else if raw.hasSuffix("/tsrc") || raw.hasSuffix("isrc") || raw.contains("/isrc") {
                tags.isrc = (try? await item.load(.stringValue)).flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        return tags
    }
}

/// Vorbis comments ("KEY=value" pairs) — the tag format FLAC and Ogg share.
enum VorbisComments {
    /// Parses a comment block: vendor length + vendor + count + entries,
    /// all lengths little-endian 32-bit.
    static func parse(_ data: Data) -> [(key: String, value: String)] {
        var reader = ByteReader(data)
        guard let vendorLength = reader.uint32LE(), reader.skip(Int(vendorLength)),
              let count = reader.uint32LE() else { return [] }
        var out: [(String, String)] = []
        for _ in 0..<min(Int(count), 10_000) {
            guard let length = reader.uint32LE(), let bytes = reader.bytes(Int(length)) else { break }
            let text = String(decoding: bytes, as: UTF8.self)
            guard let eq = text.firstIndex(of: "=") else { continue }
            out.append((String(text[..<eq]).uppercased(), String(text[text.index(after: eq)...])))
        }
        return out
    }

    static func tags(from comments: [(key: String, value: String)], durationSeconds: Double?) -> AudioTags {
        func first(_ key: String) -> String? { comments.first { $0.key == key }.map(\.value).flatMap { $0.isEmpty ? nil : $0 } }
        return AudioTags(
            title: first("TITLE"),
            artists: comments.filter { $0.key == "ARTIST" && !$0.value.isEmpty }.map(\.value),
            durationSeconds: durationSeconds,
            isrc: first("ISRC")
        )
    }
}

/// FLAC: "fLaC" then metadata blocks, each with a 4-byte header (last-block
/// flag + type, 24-bit length). STREAMINFO gives the length; VORBIS_COMMENT
/// the tags. Pictures are skipped without being read.
enum FLACCommentReader {
    static func read(_ url: URL) throws -> AudioTags? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        var duration: Double?
        var comments: [(key: String, value: String)] = []
        for _ in 0..<128 {
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
            let isLast = header[0] & 0x80 != 0
            let type = header[0] & 0x7F
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            switch type {
            case 0: // STREAMINFO
                guard let block = try handle.read(upToCount: length), block.count >= 18 else { return nil }
                // Bits 80–99: sample rate (20 bits); bits 108–143: total samples (36 bits).
                let sampleRate = Int(block[10]) << 12 | Int(block[11]) << 4 | Int(block[12]) >> 4
                let totalSamples = (Int(block[13]) & 0x0F) << 32 | Int(block[14]) << 24 | Int(block[15]) << 16
                    | Int(block[16]) << 8 | Int(block[17])
                if sampleRate > 0, totalSamples > 0 { duration = Double(totalSamples) / Double(sampleRate) }
            case 4: // VORBIS_COMMENT
                guard let block = try handle.read(upToCount: length) else { return nil }
                comments = VorbisComments.parse(block)
            default:
                try handle.seek(toOffset: try handle.offset() + UInt64(length))
            }
            if isLast { break }
        }
        return VorbisComments.tags(from: comments, durationSeconds: duration)
    }
}

/// Ogg Vorbis and Ogg Opus: the comment header is the second packet of the
/// first logical stream; the length comes from the last page's granule
/// position divided by the sample rate (Opus counts at 48 kHz after the
/// encoder's pre-skip).
enum OggCommentReader {
    static func read(_ url: URL) throws -> AudioTags? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Headers sit at the start; 1 MB is far more than any comment block
        // without embedded artwork, and artwork isn't needed here.
        guard let head = try handle.read(upToCount: 1 << 20) else { return nil }
        let packets = firstPackets(in: head, count: 2)
        guard packets.count == 2 else { return nil }
        let id = packets[0], commentPacket = packets[1]

        var sampleRate = 0, preSkip = 0, commentBody: Data
        if id.starts(with: Data([0x01]) + Data("vorbis".utf8)), id.count >= 16,
           commentPacket.starts(with: Data([0x03]) + Data("vorbis".utf8)) {
            sampleRate = Int(id[12]) | Int(id[13]) << 8 | Int(id[14]) << 16 | Int(id[15]) << 24
            commentBody = commentPacket.dropFirst(7)
        } else if id.starts(with: Data("OpusHead".utf8)), id.count >= 12,
                  commentPacket.starts(with: Data("OpusTags".utf8)) {
            sampleRate = 48_000
            preSkip = Int(id[10]) | Int(id[11]) << 8
            commentBody = commentPacket.dropFirst(8)
        } else {
            return nil
        }

        var duration: Double?
        if sampleRate > 0, let granule = try lastGranule(handle), granule > Int64(preSkip) {
            duration = Double(granule - Int64(preSkip)) / Double(sampleRate)
        }
        return VorbisComments.tags(from: VorbisComments.parse(Data(commentBody)), durationSeconds: duration)
    }

    /// Reassembles the first `count` packets from Ogg pages (lacing values of
    /// 255 continue a packet onto the next segment or page).
    static func firstPackets(in data: Data, count: Int) -> [Data] {
        var packets: [Data] = []
        var current = Data()
        var offset = data.startIndex
        while packets.count < count, offset + 27 <= data.endIndex {
            guard data[offset..<offset + 4] == Data("OggS".utf8) else { break }
            let segments = Int(data[offset + 26])
            let tableStart = offset + 27
            guard tableStart + segments <= data.endIndex else { break }
            var bodyOffset = tableStart + segments
            for i in 0..<segments {
                let lace = Int(data[tableStart + i])
                guard bodyOffset + lace <= data.endIndex else { return packets }
                current.append(data[bodyOffset..<bodyOffset + lace])
                bodyOffset += lace
                if lace < 255 {
                    packets.append(current)
                    current = Data()
                    if packets.count == count { return packets }
                }
            }
            offset = bodyOffset
        }
        return packets
    }

    /// The granule position of the last page: read the file's tail and take
    /// the last "OggS" capture pattern.
    static func lastGranule(_ handle: FileHandle) throws -> Int64? {
        let size = try handle.seekToEnd()
        let tailLength = min(size, 65_536)
        try handle.seek(toOffset: size - tailLength)
        guard let tail = try handle.read(upToCount: Int(tailLength)) else { return nil }
        let marker = Data("OggS".utf8)
        guard let range = tail.range(of: marker, options: .backwards), range.lowerBound + 14 <= tail.endIndex else { return nil }
        var granule: Int64 = 0
        for i in 0..<8 { granule |= Int64(tail[range.lowerBound + 6 + i]) << (8 * Int64(i)) }
        return granule >= 0 ? granule : nil
    }
}

/// Bounds-checked little-endian reading.
struct ByteReader {
    private let data: Data
    private var position: Data.Index

    init(_ data: Data) { self.data = data; position = data.startIndex }

    mutating func uint32LE() -> UInt32? {
        guard let b = bytes(4) else { return nil }
        return UInt32(b[b.startIndex]) | UInt32(b[b.startIndex + 1]) << 8
            | UInt32(b[b.startIndex + 2]) << 16 | UInt32(b[b.startIndex + 3]) << 24
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, position + count <= data.endIndex else { return nil }
        defer { position += count }
        return data[position..<position + count]
    }

    mutating func skip(_ count: Int) -> Bool { bytes(count) != nil }
}
