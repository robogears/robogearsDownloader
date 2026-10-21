// The native FLAC writer: what FFmpeg did for the Electron app, without FFmpeg.
//
// The Electron app ran `ffmpeg -i <download> -f mjpeg -i pipe:0 … -c:a copy
// -c:v copy -metadata …` (tidal_download.js remuxToFlac; reference
// download-pipeline.md B11). That copies the audio frames untouched and only
// rewrites the metadata, which is simple enough to do here: STREAMINFO from
// the source, a PICTURE (front cover), a VORBIS_COMMENT with the same keys,
// 8 KiB of padding, then the source's frames byte for byte. The spike
// (docs/spikes/audio-and-tagging.md) checked the result against FFmpeg's
// output: identical frames and decoded audio, the same tag keys and values,
// and a byte-identical PICTURE block.
import Foundation

/// FLAC audio ready to be written: the STREAMINFO to use and where the
/// frames sit in the source bytes. Map large sources
/// (`Data(contentsOf:options: .alwaysMapped)`) so a 150 MB Hi-Res track
/// isn't copied into memory.
public struct FLACAudio: Sendable {
    /// The STREAMINFO to write: the source's own, except that an unknown
    /// total sample count (0) is filled in from the frames when they were
    /// counted. AVFoundation can't decode a FLAC whose count is 0 (spike, part a).
    public var streamInfo: FLACStreamInfo
    /// The total sample count the source declared; 0 means it didn't say.
    public var declaredSampleCount: UInt64
    /// Samples counted from every frame header, when the source's layout
    /// gave the frame boundaries (FLAC in MP4). Nil for native FLAC, whose
    /// encoder-written STREAMINFO is trusted.
    public var countedSampleCount: UInt64?
    /// The bytes the frames are in.
    public let source: Data
    /// The frames' positions in `source`, counted from its first byte, in
    /// playback order. Adjacent ranges are merged.
    public let frameRanges: [Range<Int>]

    init(streamInfo: FLACStreamInfo, countedSampleCount: UInt64?, source: Data, frameRanges: [Range<Int>]) {
        var info = streamInfo
        if info.totalSamples == 0, let counted = countedSampleCount { info.totalSamples = counted }
        self.streamInfo = info
        self.declaredSampleCount = streamInfo.totalSamples
        self.countedSampleCount = countedSampleCount
        self.source = source
        self.frameRanges = frameRanges
    }

    /// Takes the audio out of a native FLAC file (TIDAL's BTS streams).
    /// Throws unless the source's first frame header is valid.
    public init(nativeFLAC data: Data) throws {
        let layout = try FLACMetadataReader.read(data)
        guard FLACFrameHeader.parse(FLACByteReader(data), at: layout.audioOffset) != nil else {
            throw FLACFormatError.noAudioFrames
        }
        self.init(
            streamInfo: layout.streamInfo, countedSampleCount: nil,
            source: data, frameRanges: [layout.audioOffset..<data.count]
        )
    }

    /// False when the frames hold a different number of samples than the
    /// source declared, which means frames are missing or extra (a dropped
    /// segment, or a manifest read wrongly). Nil when either count is unknown.
    public var sampleCountMatches: Bool? {
        guard let counted = countedSampleCount, declaredSampleCount != 0 else { return nil }
        return counted == declaredSampleCount
    }

    public var frameByteCount: Int { frameRanges.reduce(0) { $0 + $1.count } }

    /// All frames joined, in order. Copies; meant for tests and small files.
    public func framesData() -> Data {
        var out = Data(capacity: frameByteCount)
        for range in frameRanges { out.append(slice(range)) }
        return out
    }

    func slice(_ range: Range<Int>) -> Data {
        source[(source.startIndex + range.lowerBound)..<(source.startIndex + range.upperBound)]
    }
}

/// The tags the app writes, one field per FFmpeg `-metadata` key the
/// Electron app passed. How each is filled from TIDAL's track and album
/// (artists joined with ", ", the album-artist fallbacks, the year as the
/// first four characters of the release date) is the download pipeline's
/// job; see download-pipeline.md B11. Empty values are left out, as the
/// Electron app did (`if (v)`), and a track or disc number of 0 counts as empty.
public struct FLACTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: String?
    public var copyright: String?
    public var isrc: String?

    public init(
        title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
        trackNumber: Int? = nil, discNumber: Int? = nil, year: String? = nil,
        copyright: String? = nil, isrc: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.copyright = copyright
        self.isrc = isrc
    }

    /// The Vorbis comment fields, spelled exactly as FFmpeg wrote them for
    /// the Electron app: FFmpeg renames `album_artist`, `track` and `disc`
    /// to ALBUMARTIST, TRACKNUMBER and DISCNUMBER and keeps the other keys in
    /// lower case (spike, part b). Readers ignore case, but matching the
    /// spelling keeps old and new files byte-comparable. The order is the
    /// Electron app's insertion order; FFmpeg's own order (ISRC first) is an
    /// accident of its option handling and means nothing to readers.
    /// `encoder` names the tool that wrote the file, as FFmpeg's
    /// `encoder=Lavf…` did.
    public func vorbisFields(encoder: String) -> [FLACVorbisComment.Field] {
        let pairs: [(String, String?)] = [
            ("title", title),
            ("artist", artist),
            ("album", album),
            ("ALBUMARTIST", albumArtist),
            ("TRACKNUMBER", trackNumber.flatMap { $0 > 0 ? String($0) : nil }),
            ("DISCNUMBER", discNumber.flatMap { $0 > 0 ? String($0) : nil }),
            ("date", year),
            ("copyright", copyright),
            ("isrc", isrc),
            ("encoder", encoder),
        ]
        return pairs.compactMap { name, value in
            guard let value, !value.isEmpty else { return nil }
            return FLACVorbisComment.Field(name, value)
        }
    }
}

public enum FLACWriter {
    /// FFmpeg's FLAC muxer leaves 8 KiB of padding, so taggers can edit the
    /// file later without rewriting the audio. Kept the same.
    public static let paddingSize = 8192

    /// Written as the Vorbis vendor string and the `encoder` tag.
    public static var defaultToolName: String { "robogears Downloader \(RobogearsCore.version)" }

    /// The file's metadata part: "fLaC", STREAMINFO, PICTURE (when there's a
    /// cover), VORBIS_COMMENT and PADDING, in the order FFmpeg wrote them.
    /// Tags from the source file are never carried over (FFmpeg carried
    /// them, and copied MP4 brand names into DASH tracks' tags; spike, part b).
    public static func header(
        streamInfo: FLACStreamInfo, tags: FLACTags, coverJPEG: Data?, toolName: String = defaultToolName
    ) throws -> Data {
        var blocks = [FLACMetadataBlock(.streamInfo, body: streamInfo.bytes)]
        if let coverJPEG {
            blocks.append(FLACMetadataBlock(.picture, body: try FLACPicture.frontCover(jpeg: coverJPEG).bytes))
        }
        let comment = FLACVorbisComment(vendor: toolName, fields: tags.vorbisFields(encoder: toolName))
        blocks.append(FLACMetadataBlock(.vorbisComment, body: comment.bytes))
        blocks.append(FLACMetadataBlock(.padding, body: Data(count: paddingSize)))

        var w = FLACByteWriter()
        w.append(Data("fLaC".utf8))
        for (index, block) in blocks.enumerated() {
            guard block.body.count <= 0xFF_FFFF else {
                throw FLACFormatError.blockTooLarge(typeCode: block.typeCode, size: block.body.count)
            }
            let isLast = index == blocks.count - 1
            w.u8(block.typeCode | (isLast ? 0x80 : 0))
            w.u24be(UInt32(block.body.count))
            w.append(block.body)
        }
        return w.data
    }

    /// The whole file in memory. Fine for tests and previews; use
    /// `write(_:tags:coverJPEG:to:)` for downloads.
    public static func data(
        _ audio: FLACAudio, tags: FLACTags, coverJPEG: Data?, toolName: String = defaultToolName
    ) throws -> Data {
        var out = try header(streamInfo: audio.streamInfo, tags: tags, coverJPEG: coverJPEG, toolName: toolName)
        out.reserveCapacity(out.count + audio.frameByteCount)
        for range in audio.frameRanges { out.append(audio.slice(range)) }
        return out
    }

    /// Writes a new file at `url`, streaming the frames from the source in
    /// chunks. Refuses to replace an existing file, and removes its own
    /// partial file if writing fails, so a failed write never leaves
    /// something that looks like a finished download (decision card G2-2:
    /// the pipeline writes to a temporary name, checks, then moves into place).
    public static func write(
        _ audio: FLACAudio, tags: FLACTags, coverJPEG: Data?, toolName: String = defaultToolName, to url: URL
    ) throws {
        let head = try header(streamInfo: audio.streamInfo, tags: tags, coverJPEG: coverJPEG, toolName: toolName)
        // Creating the file exclusively is the only step that can fail because
        // a file is already there; after it, the file is ours to remove.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            defer { try? handle.close() }
            try handle.write(contentsOf: head)
            let chunk = 4 << 20
            for range in audio.frameRanges {
                var start = range.lowerBound
                while start < range.upperBound {
                    let end = min(start + chunk, range.upperBound)
                    try handle.write(contentsOf: audio.slice(start..<end))
                    start = end
                }
            }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
