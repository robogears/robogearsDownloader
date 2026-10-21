import Foundation
import Testing
@testable import RobogearsCore

/// Reads the files FFmpeg wrote with the Electron app's exact arguments and
/// pins what's in them (spike part b). These are the facts the native writer
/// is built to match.
@Suite("FLAC metadata reader")
struct FLACMetadataReaderTests {
    @Test("FFmpeg wrote STREAMINFO, PICTURE, VORBIS_COMMENT, then 8 KiB of padding")
    func ffmpegBlockOrder() throws {
        let layout = try FLACMetadataReader.read(AudioFixture.data("ffmpeg-bts-16-44100.flac"))
        #expect(layout.blocks.map(\.type) == [.streamInfo, .picture, .vorbisComment, .padding])
        #expect(layout.blocks.last?.body == Data(count: 8192))
        #expect(layout.leadingTagSize == 0)
    }

    @Test("FFmpeg's tag keys: lower case, except ALBUMARTIST, TRACKNUMBER and DISCNUMBER")
    func ffmpegVorbisKeys() throws {
        let comment = try #require(try FLACMetadataReader.read(AudioFixture.data("ffmpeg-bts-16-44100.flac")).vorbisComment)
        let named = comment.fields.filter { $0.name != "encoder" }.map { "\($0.name)=\($0.value)" }
        #expect(named == [
            "isrc=ZZXX12600001",
            "title=Blue Lantern – Café 東京",
            "artist=Placeholder Artist, Second Example",
            "album=Paper Harbour",
            "ALBUMARTIST=Placeholder Artist",
            "TRACKNUMBER=7",
            "DISCNUMBER=1",
            "date=2011",
            "copyright=℗ 2011 Example Records",
        ])
        // FFmpeg names itself twice: in the vendor string and in an encoder tag.
        #expect(comment.vendor.hasPrefix("Lavf"))
        #expect(comment.values(for: "encoder") == [comment.vendor])
        #expect(comment.fields.last?.name == "encoder")
    }

    @Test("FFmpeg copied the MP4 brand names into the tags of DASH tracks")
    func ffmpegCopiesBrandTagsFromDASH() throws {
        let comment = try #require(try FLACMetadataReader.read(AudioFixture.data("ffmpeg-dash-24-96000.flac")).vorbisComment)
        #expect(comment.fields.prefix(3).map { "\($0.name)=\($0.value)" } == [
            "major_brand=iso5", "minor_version=512", "compatible_brands=iso5iso6mp41",
        ])
    }

    @Test("FFmpeg's cover is a front cover (type 3) described as Album cover")
    func ffmpegPictureBlock() throws {
        let layout = try FLACMetadataReader.read(AudioFixture.data("ffmpeg-bts-16-44100.flac"))
        let picture = try #require(layout.pictures.first)
        #expect(layout.pictures.count == 1)
        #expect(picture.pictureType == 3)
        #expect(picture.mimeType == "image/jpeg")
        #expect(picture.description == "Album cover")
        #expect(picture.width == 48 && picture.height == 40)
        #expect(picture.colorDepth == 12) // FFmpeg's bits per pixel for 4:2:0 JPEG
        #expect(picture.colorCount == 0)
        #expect(picture.data == (try AudioFixture.data("cover.jpg")))
    }

    @Test("STREAMINFO reads sample rate, channels, bit depth and length")
    func streamInfoFields() throws {
        let cd = try FLACMetadataReader.read(AudioFixture.data("bts-16-44100.flac")).streamInfo
        #expect(cd.sampleRate == 44100 && cd.channelCount == 2 && cd.bitsPerSample == 16)
        #expect(cd.totalSamples == 44100 && cd.duration == 1.0)
        #expect(cd.minimumBlockSize == 4608 && cd.maximumBlockSize == 4608)
        let hiRes = try FLACMetadataReader.read(AudioFixture.data("bts-24-96000.flac")).streamInfo
        #expect(hiRes.sampleRate == 96000 && hiRes.bitsPerSample == 24 && hiRes.totalSamples == 57600)
    }

    @Test("STREAMINFO encodes back to the same 34 bytes")
    func streamInfoRoundTrip() throws {
        for name in ["bts-16-44100.flac", "bts-24-96000.flac", "ffmpeg-dash-live-16-44100.flac"] {
            let block = try FLACMetadataReader.read(AudioFixture.data(name)).blocks[0].body
            #expect(try FLACStreamInfo(bytes: block).bytes == block, "\(name)")
        }
    }

    @Test("an unknown sample count reads as 0 with no duration")
    func unknownSampleCount() throws {
        let info = try FLACMetadataReader.read(AudioFixture.data("ffmpeg-dash-live-16-44100.flac")).streamInfo
        #expect(info.totalSamples == 0)
        #expect(info.duration == nil)
        #expect(info.md5 == Data(count: 16))
    }

    @Test("a STREAMINFO with sample rate 0 still reads, with no duration")
    func zeroSampleRateReads() throws {
        var info = try FLACMetadataReader.read(AudioFixture.data("bts-16-44100.flac")).streamInfo
        info.sampleRate = 0
        let read = try FLACStreamInfo(bytes: info.bytes)
        #expect(read.sampleRate == 0 && read.totalSamples == 44100)
        #expect(read.duration == nil)
    }

    @Test("a file that isn't FLAC is refused")
    func notFLAC() {
        #expect(throws: FLACFormatError.notFLAC) { try FLACMetadataReader.read(Data("RIFF....WAVE".utf8)) }
        #expect(throws: FLACFormatError.notFLAC) { try FLACMetadataReader.read(Data()) }
    }

    @Test("a file cut off inside its metadata is refused")
    func truncatedMetadata() throws {
        let data = try AudioFixture.data("ffmpeg-bts-16-44100.flac")
        #expect(throws: FLACFormatError.truncated("metadata block body")) { try FLACMetadataReader.read(data.prefix(500)) }
        #expect(throws: FLACFormatError.truncated("metadata block header")) { try FLACMetadataReader.read(data.prefix(42)) }
    }

    @Test("STREAMINFO that isn't the first block is refused")
    func streamInfoNotFirst() throws {
        var data = Data("fLaC".utf8)
        data.append(contentsOf: [0x81, 0x00, 0x00, 0x04, 0, 0, 0, 0]) // a last PADDING block only
        #expect(throws: FLACFormatError.invalidStreamInfo) { try FLACMetadataReader.read(data) }
    }

    @Test("an ID3v2 tag in front of fLaC is skipped")
    func leadingID3Tag() throws {
        let flac = try AudioFixture.data("bts-16-44100.flac")
        var data = Data("ID3".utf8) + Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14]) // syncsafe size 20
        data.append(Data(count: 20))
        data.append(flac)
        let layout = try FLACMetadataReader.read(data)
        #expect(layout.leadingTagSize == 30)
        #expect(layout.audioOffset == 30 + (try FLACMetadataReader.read(flac)).audioOffset)
        #expect(layout.streamInfo.totalSamples == 44100)
    }

    @Test("reads a Data slice whose indices don't start at 0")
    func readsSlices() throws {
        let flac = try AudioFixture.data("bts-16-44100.flac")
        let padded = Data(count: 7) + flac
        let slice = padded[7...]
        #expect(slice.startIndex == 7)
        #expect(try FLACMetadataReader.read(slice) == FLACMetadataReader.read(flac))
    }

    @Test("Vorbis comments keep non-ASCII text, '=' inside values and the exact key case")
    func vorbisRoundTrip() throws {
        let comment = FLACVorbisComment(vendor: "tool 1.0", fields: [
            .init("title", "Café 東京 = live"), .init("ARTIST", "Ünïcødé"),
        ])
        let read = try FLACVorbisComment(bytes: comment.bytes)
        #expect(read == comment)
        #expect(read.values(for: "TITLE") == ["Café 東京 = live"])
        #expect(read.values(for: "artist") == ["Ünïcødé"])
    }

    @Test("a Vorbis field without '=' is kept as a name, not a failure")
    func vorbisFieldWithoutEquals() throws {
        var w = FLACByteWriter()
        w.u32le(1); w.append(Data("v".utf8)); w.u32le(1); w.u32le(5); w.append(Data("BROKE".utf8))
        #expect(try FLACVorbisComment(bytes: w.data).fields == [.init("BROKE", "")])
    }

    @Test("a Vorbis comment whose lengths run past its end is refused")
    func vorbisOverrun() {
        var w = FLACByteWriter()
        w.u32le(1); w.append(Data("v".utf8)); w.u32le(1_000_000)
        #expect(throws: FLACFormatError.invalidVorbisComment) { try FLACVorbisComment(bytes: w.data) }
    }

    @Test("the first frame header of a real stream reads as 4608 samples")
    func frameHeaderOfRealStream() throws {
        let data = try AudioFixture.data("bts-16-44100.flac")
        let layout = try FLACMetadataReader.read(data)
        let header = try #require(FLACFrameHeader.parse(FLACByteReader(data), at: layout.audioOffset))
        #expect(header.blockSize == 4608)
    }

    @Test("a frame header with one changed byte fails its CRC")
    func frameHeaderCRC() throws {
        var data = try AudioFixture.data("bts-16-44100.flac")
        let offset = try FLACMetadataReader.read(data).audioOffset
        data[offset + 4] ^= 0x01 // the frame number
        #expect(FLACFrameHeader.parse(FLACByteReader(data), at: offset) == nil)
    }

    @Test("block sizes stored after the header (8-bit and 16-bit) are read")
    func frameHeaderTrailingBlockSize() {
        func header(_ bytes: [UInt8]) -> Data {
            let crc = bytes.reduce(UInt8(0)) { FLACFrameHeader.crc8Table[Int($0 ^ $1)] }
            return Data(bytes + [crc])
        }
        let eightBit = header([0xFF, 0xF8, 0x69, 0x18, 0x00, 0xFF])        // code 6: 255 + 1
        let sixteenBit = header([0xFF, 0xF8, 0x79, 0x18, 0x00, 0x11, 0xFF]) // code 7: 4607 + 1
        #expect(FLACFrameHeader.parse(FLACByteReader(eightBit), at: 0) == FLACFrameHeader(blockSize: 256, length: 7))
        #expect(FLACFrameHeader.parse(FLACByteReader(sixteenBit), at: 0) == FLACFrameHeader(blockSize: 4608, length: 8))
    }
}
