import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import RobogearsCore

/// What Apple's own decoder makes of each kind of file (spike part a), and
/// whether it reads the native writer's output and cover (part c).
@Suite("AVFoundation on TIDAL-style audio")
struct AudioProbeTests {
    /// Writes the native FLAC for a fixture into a temporary folder.
    func writeNative(from source: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("\(source).native.flac")
        let audio = try FLACAudio(downloaded: AudioFixture.data(source))
        try FLACWriter.write(audio, tags: AudioFixture.tags, coverJPEG: AudioFixture.data("cover.jpg"), to: url)
        return url
    }

    /// SHA-256 of every decoded sample, as AVAudioFile delivers them.
    func pcmDigest(_ url: URL) throws -> String {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 15))
        var hasher = SHA256()
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = try #require(buffer.floatChannelData)[channel]
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: samples, count: Int(buffer.frameLength) * 4))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @Test("native FLAC at 16-bit/44.1 kHz decodes to the end")
    func decodesCDQuality() throws {
        let report = try AudioProbe.inspect(AudioFixture.url("bts-16-44100.flac"))
        #expect(report.formatID == "flac")
        #expect(report.sampleRate == 44100 && report.channelCount == 2 && report.sourceBitDepth == 16)
        #expect(report.declaredFrames == 44100)
        #expect(report.decodedToTheEnd)
    }

    @Test("native FLAC at 24-bit/96 kHz decodes to the end")
    func decodesHiRes() throws {
        let report = try AudioProbe.inspect(AudioFixture.url("bts-24-96000.flac"))
        #expect(report.sampleRate == 96000 && report.sourceBitDepth == 24)
        #expect(report.declaredFrames == 57600)
        #expect(report.decodedToTheEnd)
    }

    @Test("AAC .m4a decodes to the end, with no source bit depth")
    func decodesAAC() throws {
        let report = try AudioProbe.inspect(AudioFixture.url("aac-320.m4a"))
        #expect(report.formatID == "aac ")
        #expect(report.sourceBitDepth == nil)
        #expect(report.decodedToTheEnd)
    }

    @Test("a joined DASH download decodes every real frame")
    func decodesJoinedDASH() throws {
        let report = try AudioProbe.inspect(AudioFixture.url("dash-24-96000.mp4"))
        #expect(report.formatID == "flac" && report.sourceBitDepth == 24)
        // AVAudioFile rounds the declared length up to whole 4608-sample
        // frames, so it overstates the length and its last read fails; the
        // decoded count is still exact.
        #expect(report.decodedFrames == 57600)
        #expect(report.declaredFrames >= 57600)
    }

    @Test("FFmpeg's FLAC with an unknown sample count can't be decoded; the native file can")
    func unknownCountBreaksAVFoundation() throws {
        let ffmpeg = try AudioProbe.inspect(AudioFixture.url("ffmpeg-dash-live-16-44100.flac"))
        #expect(ffmpeg.declaredFrames == 0)
        #expect(!ffmpeg.decodedToTheEnd)

        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let native = try AudioProbe.inspect(writeNative(from: "dash-live-16-44100.mp4", in: folder))
        #expect(native.declaredFrames == 44100)
        #expect(native.decodedToTheEnd)
    }

    @Test("the native file decodes to exactly the same samples as FFmpeg's")
    func samePCMAsFFmpeg() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (source, ffmpeg) in [("bts-16-44100.flac", "ffmpeg-bts-16-44100.flac"), ("dash-24-96000.mp4", "ffmpeg-dash-24-96000.flac")] {
            let native = try writeNative(from: source, in: folder)
            #expect(try pcmDigest(native) == pcmDigest(AudioFixture.url(ffmpeg)), "\(source)")
        }
    }

    @Test("AVFoundation reads the native file's tags and front cover")
    func readsNativeTagsAndCover() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try writeNative(from: "dash-24-96000.mp4", in: folder)
        let items = try await AVURLAsset(url: url).loadMetadata(for: AVMetadataFormat(rawValue: "org.xiph.vorbis-comment"))
        var strings: [String: String] = [:]
        var cover: Data?
        for item in items {
            let key = item.identifier?.rawValue ?? ""
            if key == "vorb/METADATA_BLOCK_PICTURE" { cover = try await item.load(.dataValue) }
            else if let value = try await item.load(.stringValue) { strings[key] = value }
        }
        #expect(strings["vorb/TITLE"] == "Blue Lantern – Café 東京")
        #expect(strings["vorb/ARTIST"] == "Placeholder Artist, Second Example")
        #expect(strings["vorb/ALBUMARTIST"] == "Placeholder Artist")
        #expect(strings["vorb/TRACKNUMBER"] == "7")
        #expect(strings["vorb/ISRC"] == "ZZXX12600001")
        #expect(cover == (try AudioFixture.data("cover.jpg")))
    }

    @Test("FFmpeg's .m4a has the iTunes title, artist, album, year, copyright, cover, track and disc, but no ISRC")
    func ffmpegM4AAtoms() async throws {
        let items = try await AVURLAsset(url: AudioFixture.url("ffmpeg-aac.m4a")).loadMetadata(for: .iTunesMetadata)
        let identifiers = Set(items.compactMap { $0.identifier?.rawValue })
        #expect(identifiers == [
            "itsk/%A9nam", "itsk/%A9ART", "itsk/aART", "itsk/%A9alb", "itsk/%A9day",
            "itsk/%A9too", "itsk/cprt", "itsk/covr", "itsk/trkn", "itsk/disk",
        ])
    }
}
