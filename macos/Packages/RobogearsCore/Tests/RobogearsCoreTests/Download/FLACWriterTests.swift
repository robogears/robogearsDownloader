import Foundation
import Testing
@testable import RobogearsCore

/// The native writer against what FFmpeg wrote with the Electron app's
/// arguments (spike part c). Same frames, same STREAMINFO, same picture
/// block, same tag keys and values; only the tool name differs, plus the
/// deliberate changes the spike recommends (no carried-over or MP4 brand
/// tags, and a filled-in sample count).
@Suite("Native FLAC writer")
struct FLACWriterTests {
    func nativeFile(from source: String, cover: Bool = true) throws -> Data {
        let audio = try FLACAudio(downloaded: AudioFixture.data(source))
        return try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: cover ? AudioFixture.data("cover.jpg") : nil)
    }

    /// The last-block flags of every metadata block, read straight from the bytes.
    func lastBlockFlags(_ data: Data) -> [Bool] {
        var flags: [Bool] = []
        var o = 4
        while o + 4 <= data.count {
            let isLast = data[o] & 0x80 != 0
            flags.append(isLast)
            if isLast { break }
            o += 4 + (Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3]))
        }
        return flags
    }

    @Test("BTS: the audio frames are copied byte for byte")
    func btsFramesUnchanged() throws {
        let native = try nativeFile(from: "bts-16-44100.flac")
        let source = try AudioFixture.data("bts-16-44100.flac")
        #expect(try AudioFixture.frames(ofFLAC: native) == AudioFixture.frames(ofFLAC: source))
    }

    @Test("BTS: STREAMINFO is kept exactly")
    func btsStreamInfoUnchanged() throws {
        let native = try FLACMetadataReader.read(nativeFile(from: "bts-16-44100.flac"))
        let source = try FLACMetadataReader.read(AudioFixture.data("bts-16-44100.flac"))
        #expect(native.blocks[0].body == source.blocks[0].body)
    }

    @Test("blocks come in FFmpeg's order, with 8 KiB of padding last")
    func blockOrder() throws {
        let data = try nativeFile(from: "bts-16-44100.flac")
        let layout = try FLACMetadataReader.read(data)
        #expect(layout.blocks.map(\.type) == [.streamInfo, .picture, .vorbisComment, .padding])
        #expect(layout.blocks.last?.body == Data(count: 8192))
        #expect(lastBlockFlags(data) == [false, false, false, true])
    }

    @Test("the tags match FFmpeg's keys and values, apart from the tool name")
    func tagsMatchFFmpeg() throws {
        let native = try #require(try FLACMetadataReader.read(nativeFile(from: "bts-16-44100.flac")).vorbisComment)
        let ffmpeg = try #require(try FLACMetadataReader.read(AudioFixture.data("ffmpeg-bts-16-44100.flac")).vorbisComment)
        func tagSet(_ c: FLACVorbisComment) -> Set<String> {
            Set(c.fields.filter { $0.name != "encoder" }.map { "\($0.name)=\($0.value)" })
        }
        #expect(tagSet(native) == tagSet(ffmpeg))
        #expect(Set(native.fields.map(\.name)) == Set(ffmpeg.fields.map(\.name)))
        #expect(native.vendor == "robogears Downloader \(RobogearsCore.version)")
        #expect(native.values(for: "encoder") == [native.vendor])
    }

    @Test("the tag fields keep the Electron app's order and FFmpeg's spelling")
    func fieldOrder() {
        let names = AudioFixture.tags.vorbisFields(encoder: "tool").map(\.name)
        #expect(names == ["title", "artist", "album", "ALBUMARTIST", "TRACKNUMBER", "DISCNUMBER", "date", "copyright", "isrc", "encoder"])
    }

    @Test("the cover block is byte-identical to FFmpeg's")
    func pictureMatchesFFmpeg() throws {
        let native = try FLACMetadataReader.read(nativeFile(from: "bts-16-44100.flac"))
        let ffmpeg = try FLACMetadataReader.read(AudioFixture.data("ffmpeg-bts-16-44100.flac"))
        let nativePicture = try #require(native.blocks.first { $0.type == .picture })
        let ffmpegPicture = try #require(ffmpeg.blocks.first { $0.type == .picture })
        #expect(nativePicture.body == ffmpegPicture.body)
        #expect(native.pictures.first?.pictureType == 3)
    }

    @Test("DASH: the output's frames and STREAMINFO are FFmpeg's")
    func dashMatchesFFmpeg() throws {
        let native = try nativeFile(from: "dash-24-96000.mp4")
        let ffmpeg = try AudioFixture.data("ffmpeg-dash-24-96000.flac")
        #expect(try AudioFixture.frames(ofFLAC: native) == AudioFixture.frames(ofFLAC: ffmpeg))
        #expect(try FLACMetadataReader.read(native).blocks[0] == FLACMetadataReader.read(ffmpeg).blocks[0])
    }

    @Test("DASH: the MP4 brand names FFmpeg copied into the tags are not written")
    func noBrandTags() throws {
        let comment = try #require(try FLACMetadataReader.read(nativeFile(from: "dash-24-96000.mp4")).vorbisComment)
        for name in ["major_brand", "minor_version", "compatible_brands"] {
            #expect(comment.values(for: name).isEmpty, "\(name)")
        }
    }

    @Test("DASH with an unknown sample count: the count is filled in where FFmpeg left 0")
    func unknownCountFilled() throws {
        let native = try FLACMetadataReader.read(nativeFile(from: "dash-live-16-44100.mp4")).streamInfo
        var ffmpeg = try FLACMetadataReader.read(AudioFixture.data("ffmpeg-dash-live-16-44100.flac")).streamInfo
        #expect(ffmpeg.totalSamples == 0)
        #expect(native.totalSamples == 44100)
        ffmpeg.totalSamples = native.totalSamples
        #expect(native == ffmpeg) // nothing else differs
    }

    @Test("tags already in the downloaded file are never carried over")
    func sourceTagsDropped() throws {
        // A native FLAC whose own tags include lyrics and a different title.
        let source = try AudioFixture.data("bts-16-44100.flac")
        let layout = try FLACMetadataReader.read(source)
        let ownTags = FLACVorbisComment(vendor: "someone else", fields: [.init("TITLE", "Source Title"), .init("LYRICS", "la la")])
        var w = FLACByteWriter()
        w.append(Data("fLaC".utf8))
        w.u8(0x00); w.u24be(34); w.append(layout.blocks[0].body)
        let comment = ownTags.bytes
        w.u8(0x84); w.u24be(UInt32(comment.count)); w.append(comment)
        w.append(source.subdata(in: layout.audioOffset..<source.count))

        let written = try FLACWriter.data(FLACAudio(nativeFLAC: w.data), tags: AudioFixture.tags, coverJPEG: nil)
        let tags = try #require(try FLACMetadataReader.read(written).vorbisComment)
        #expect(tags.values(for: "LYRICS").isEmpty)
        #expect(tags.values(for: "TITLE") == ["Blue Lantern – Café 東京"])
        #expect(!tags.fields.contains { $0.value.contains("Lavf") || $0.value.contains("someone else") })
    }

    @Test("empty tags, and a track or disc number of 0, are left out")
    func emptyTagsLeftOut() {
        let tags = FLACTags(title: "Only Title", artist: "", album: nil, trackNumber: 0, discNumber: nil, year: "")
        #expect(tags.vorbisFields(encoder: "tool") == [.init("title", "Only Title"), .init("encoder", "tool")])
    }

    @Test("no cover means no PICTURE block")
    func noCover() throws {
        let layout = try FLACMetadataReader.read(nativeFile(from: "bts-16-44100.flac", cover: false))
        #expect(layout.blocks.map(\.type) == [.streamInfo, .vorbisComment, .padding])
    }

    @Test("a cover that isn't a JPEG is refused")
    func coverNotJPEG() throws {
        let audio = try FLACAudio(nativeFLAC: AudioFixture.data("bts-16-44100.flac"))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(throws: FLACFormatError.coverIsNotJPEG) { try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: png) }
        #expect(throws: FLACFormatError.coverUnreadable) {
            try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
    }

    @Test("cover bits per pixel match FFmpeg's for 4:2:0, 4:2:2, 4:4:4 and grey JPEGs")
    func jpegBitsPerPixel() throws {
        func jpeg(_ sampling: [UInt8]) -> Data {
            var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC0, 0x00, UInt8(8 + sampling.count * 3), 8, 0x01, 0x2C, 0x01, 0x90, UInt8(sampling.count)]
            for (i, s) in sampling.enumerated() { bytes += [UInt8(i + 1), s, 0] }
            return Data(bytes)
        }
        let cases: [([UInt8], UInt32)] = [([0x22, 0x11, 0x11], 12), ([0x21, 0x11, 0x11], 16), ([0x11, 0x11, 0x11], 24), ([0x11], 8)]
        for (sampling, bits) in cases {
            let info = try JPEGFrameInfo(jpeg(sampling))
            #expect(info.width == 400 && info.height == 300)
            #expect(info.bitsPerPixel == bits, "sampling \(sampling)")
        }
    }

    @Test("a cover too big for one FLAC block is refused")
    func coverTooBig() throws {
        let audio = try FLACAudio(nativeFLAC: AudioFixture.data("bts-16-44100.flac"))
        var huge = try AudioFixture.data("cover.jpg")
        huge.append(Data(count: 0xFF_FFFF - huge.count))
        #expect(throws: FLACFormatError.self) { try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: huge) }
        do {
            _ = try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: huge)
        } catch let FLACFormatError.blockTooLarge(typeCode, _) {
            #expect(typeCode == FLACBlockType.picture.rawValue)
        }
    }

    @Test("a native FLAC whose audio doesn't start with a frame is refused")
    func nativeWithoutFrames() throws {
        let source = try AudioFixture.data("bts-16-44100.flac")
        let layout = try FLACMetadataReader.read(source)
        #expect(throws: FLACFormatError.noAudioFrames) { try FLACAudio(nativeFLAC: source.prefix(layout.audioOffset)) }
    }

    @Test("writing to a file gives the same bytes, and never replaces an existing file")
    func writeToFile() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try FLACAudio(downloaded: AudioFixture.data("dash-24-96000.mp4"))
        let cover = try AudioFixture.data("cover.jpg")
        let url = folder.appendingPathComponent("Blue Lantern.flac")
        try FLACWriter.write(audio, tags: AudioFixture.tags, coverJPEG: cover, to: url)
        let expected = try FLACWriter.data(audio, tags: AudioFixture.tags, coverJPEG: cover)
        #expect(try Data(contentsOf: url) == expected)

        #expect(throws: (any Error).self) { try FLACWriter.write(audio, tags: AudioFixture.tags, coverJPEG: nil, to: url) }
        #expect(try Data(contentsOf: url) == expected) // the first file is untouched
    }

    @Test("a write that fails before the audio leaves no file behind")
    func failedWriteLeavesNothing() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try FLACAudio(nativeFLAC: AudioFixture.data("bts-16-44100.flac"))
        let url = folder.appendingPathComponent("Blue Lantern.flac")
        #expect(throws: FLACFormatError.coverIsNotJPEG) {
            try FLACWriter.write(audio, tags: AudioFixture.tags, coverJPEG: Data("not a jpeg".utf8), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
