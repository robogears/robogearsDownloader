import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import RobogearsCore

/// The AAC fallback (D4 2.10) written natively: every packet of TIDAL's AAC
/// copied into a tagged .m4a, checked against what the Electron app's FFmpeg
/// wrote for the same audio (Fixtures/audio/ffmpeg-aac.m4a).
@Suite("AAC .m4a writer")
struct M4AWriterTests {
    let cover: Data
    let ffmpeg: Data

    init() throws {
        cover = try AudioFixture.data("cover.jpg")
        ffmpeg = try AudioFixture.data("ffmpeg-aac.m4a")
    }

    /// Converts a fixture through the public API into `folder`.
    func convert(_ fixture: String, in folder: URL, tags: FLACTags = AudioFixture.tags) async throws -> (url: URL, result: M4AWriteResult) {
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        let result = try await M4AWriter().writeM4A(from: AudioFixture.url(fixture), tags: tags, coverJPEG: cover, to: url)
        return (url, result)
    }

    /// Converts in-memory source bytes (a patched fixture) into `folder`.
    func convert(_ source: Data, in folder: URL, tags: FLACTags = AudioFixture.tags, coverJPEG: Data? = nil) throws -> (url: URL, result: M4AWriteResult) {
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        let result = try M4AWriter.write(source, tags: tags, coverJPEG: coverJPEG, toolName: FLACWriter.defaultToolName, to: url)
        return (url, result)
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

    // MARK: Packets

    @Test("every packet of a plain .m4a is copied byte for byte, as FFmpeg copied them")
    func plainPacketsSurvive() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try Data(contentsOf: try await convert("aac-320.m4a", in: folder).url)
        let source = try AudioFixture.data("aac-320.m4a")

        let packets = try MP4Inspector.packets(written)
        #expect(packets.count == 45)
        #expect(packets == (try MP4Inspector.packets(source)))
        #expect(try MP4Inspector.mdatBodies(written) == MP4Inspector.mdatBodies(ffmpeg))
        #expect(try MP4Inspector.topLevelTypes(written) == ["ftyp", "moov", "mdat"])
    }

    @Test("every packet of a joined DASH download is kept, where Apple's export kept 43 of 45")
    func dashPacketsSurvive() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try Data(contentsOf: try await convert("dash-aac.mp4", in: folder).url)
        let source = try AudioFixture.data("dash-aac.mp4")

        let packets = try MP4Inspector.packets(written)
        #expect(packets.count == 45)
        // The five segments' mdat bodies, joined, are exactly the packets.
        #expect(try MP4Inspector.mdatBodies(written) == MP4Inspector.mdatBodies(source))
        #expect(try MP4Inspector.mdatBodies(written) == MP4Inspector.mdatBodies(ffmpeg))
        #expect(try MP4Inspector.topLevelTypes(written) == ["ftyp", "moov", "mdat"])
    }

    @Test("the sample tables, edit list and headers match FFmpeg's box for box",
          arguments: ["aac-320.m4a", "dash-aac.mp4"])
    func tablesMatchFFmpeg(fixture: String) async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try Data(contentsOf: try await convert(fixture, in: folder).url)
        let source = try AudioFixture.data(fixture)

        let stbl = MP4Inspector.sampleTablePath
        for path in [["ftyp"], ["moov", "mvhd"], ["moov", "trak", "tkhd"], ["moov", "trak", "edts", "elst"],
                     ["moov", "trak", "mdia", "mdhd"], ["moov", "trak", "mdia", "hdlr"],
                     stbl + ["stts"], stbl + ["stsc"], stbl + ["stsz"], stbl + ["sgpd"], stbl + ["sbgp"]] {
            let ours = try MP4Inspector.box(written, path)
            #expect(ours != nil && ours == (try MP4Inspector.box(ffmpeg, path)), "\(path.joined(separator: "/"))")
        }
        // The sample description is the source's own, unchanged (the DASH
        // one keeps its btrt box, which FFmpeg dropped).
        #expect(try MP4Inspector.box(written, stbl + ["stsd"]) == MP4Inspector.box(source, stbl + ["stsd"]))
    }

    // MARK: Length and decoding

    @Test("the length leaves out the priming the edit list skips", arguments: ["aac-320.m4a", "dash-aac.mp4"])
    func lengthWithoutPriming(fixture: String) async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (_, result) = try await convert(fixture, in: folder)
        // 44 packets of 1024 samples and one of 68 is 45124; the edit skips 1024.
        #expect(result.durationSeconds == 1.0)
    }

    @Test("Apple's decoders read the file to the end, giving the same audio as FFmpeg's file",
          arguments: ["aac-320.m4a", "dash-aac.mp4"])
    func decodesToTheEnd(fixture: String) async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, _) = try await convert(fixture, in: folder)
        let reference = try AudioFixture.url("ffmpeg-aac.m4a")

        let report = try AudioProbe.inspect(url)
        #expect(report.formatID == "aac ")
        #expect(report.declaredFrames == 44100)
        #expect(report.verdict == .complete)
        #expect(try pcmDigest(url) == pcmDigest(reference))

        let ours = try await MP4Inspector.decodeWithAssetReader(url)
        let theirs = try await MP4Inspector.decodeWithAssetReader(reference)
        #expect(ours.status == .completed)
        #expect(ours.frames > 0 && ours.frames == theirs.frames)
    }

    @Test("a DASH segment that never arrived shows as a shorter length")
    func droppedSegmentIsShorter() throws {
        let data = try AudioFixture.data("dash-aac.mp4")
        let top = try MP4Inspector.boxes(data, in: 0..<data.count)
        let moofs = top.indices.filter { top[$0].type == "moof" }
        let itsMdat = try #require(top[moofs[1]...].first { $0.type == "mdat" })
        var shortened = data
        shortened.removeSubrange(top[moofs[1]].start..<itsMdat.end)

        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, result) = try convert(shortened, in: folder)
        #expect(try MP4Inspector.packets(Data(contentsOf: url)).count == 34)
        #expect(result.durationSeconds == Double(45124 - 11 * 1024 - 1024) / 44100)
        #expect(try AudioProbe.inspect(url).verdict == .complete)
    }

    @Test("a download that stopped part-way is refused, not saved short")
    func truncatedSourceRefused() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = try AudioFixture.data("aac-320.m4a")
        let dash = try AudioFixture.data("dash-aac.mp4")
        #expect(throws: M4AFormatError.truncated("MP4 mdat box")) { try convert(plain.prefix(20_000), in: folder) }
        #expect(throws: M4AFormatError.truncated("MP4 mdat box")) { try convert(dash.prefix(dash.count - 5), in: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    // MARK: Edit list

    /// aac-320.m4a with its one edit's segment duration and media time changed.
    func plainSource(segmentDuration: UInt32? = nil, mediaTime: UInt32? = nil) throws -> Data {
        var data = try AudioFixture.data("aac-320.m4a")
        let elst = try #require(try MP4Inspector.find(data, MP4Inspector.trackPath + ["edts", "elst"]))
        let entry = elst.bodyStart + 8
        if let segmentDuration { data.replaceSubrange(entry..<(entry + 4), with: MP4BoxWriter.u32(segmentDuration)) }
        if let mediaTime { data.replaceSubrange((entry + 4)..<(entry + 8), with: MP4BoxWriter.u32(mediaTime)) }
        return data
    }

    @Test("an edit longer than the audio is cut to fit, so the file states its real length")
    func overlongEditIsCut() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // The edit claims 5 s of a 1 s track, as a cut-off download's would.
        let (url, result) = try convert(plainSource(segmentDuration: 5000), in: folder)
        #expect(result.durationSeconds == 1.0)
        let written = try Data(contentsOf: url)
        #expect(try MP4Inspector.box(written, MP4Inspector.trackPath + ["edts", "elst"])
            == MP4Inspector.box(ffmpeg, MP4Inspector.trackPath + ["edts", "elst"]))
        #expect(try AudioProbe.inspect(url).declaredFrames == 44100)
    }

    @Test("without an edit list every sample plays, priming included")
    func noEditList() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try MP4Inspector.patch(AudioFixture.data("aac-320.m4a"), replacing: Array("edts".utf8), with: Array("free".utf8))
        let (url, result) = try convert(source, in: folder)
        #expect(result.durationSeconds == 45124.0 / 44100)
        #expect(try MP4Inspector.box(Data(contentsOf: url), MP4Inspector.trackPath + ["edts"]) == nil)
    }

    @Test("an edit list that delays the start, or starts after the end, is refused")
    func oddEditListsRefused() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: M4AFormatError.unsupportedMP4("edit list with an empty edit")) {
            try convert(plainSource(mediaTime: 0xFFFF_FFFF), in: folder)
        }
        #expect(throws: M4AFormatError.inconsistent("the edit list starts after the audio ends")) {
            try convert(plainSource(mediaTime: 50_000), in: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    // MARK: Tags and cover

    @Test("TagReader reads back the title, artist and ISRC")
    func tagReaderReadsBack() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, _) = try await convert("dash-aac.mp4", in: folder)
        let tags = try #require(await TagReader().readTags(at: url))
        #expect(tags.title == "Blue Lantern – Café 東京")
        #expect(tags.artists == ["Placeholder Artist, Second Example"])
        #expect(tags.isrc == "ZZXX12600001")
    }

    @Test("the tag atoms are FFmpeg's ten, written the same way, plus the ISRC")
    func tagAtomsMatchFFmpeg() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, _) = try await convert("aac-320.m4a", in: folder)
        let ours = try MP4Inspector.tagAtoms(Data(contentsOf: url))
        let theirs = try MP4Inspector.tagAtoms(ffmpeg)

        #expect(theirs.map(\.name) == ["©nam", "©ART", "aART", "©alb", "©day", "©too", "cprt", "covr", "trkn", "disk"])
        #expect(ours.map(\.name) == theirs.map(\.name) + ["----"])
        for (mine, reference) in zip(ours, theirs) where mine.name != "©too" {
            #expect(mine.bytes == reference.bytes, "\(mine.name)")
        }
        let tool = try MP4Inspector.value(of: try #require(ours.first { $0.name == "©too" }).bytes)
        #expect(tool.type == 1 && String(decoding: tool.bytes, as: UTF8.self) == FLACWriter.defaultToolName)

        // The ISRC is a freeform atom: mean, name, then the text value.
        let isrc = try #require(ours.last).bytes
        let parts = try MP4Inspector.boxes(isrc, in: 8..<isrc.count)
        #expect(parts.map(\.type) == ["mean", "name", "data"])
        #expect(isrc.subdata(in: (parts[0].bodyStart + 4)..<parts[0].end) == Data("com.apple.iTunes".utf8))
        #expect(isrc.subdata(in: (parts[1].bodyStart + 4)..<parts[1].end) == Data("ISRC".utf8))
        let value = try MP4Inspector.value(of: isrc)
        #expect(value.type == 1 && value.bytes == Data("ZZXX12600001".utf8))

        // AVFoundation sees FFmpeg's ten iTunes items and the ISRC.
        let items = try await AVURLAsset(url: url).load(.metadata)
        let identifiers = Set(items.compactMap { $0.identifier?.rawValue })
        #expect(identifiers == [
            "itsk/%A9nam", "itsk/%A9ART", "itsk/aART", "itsk/%A9alb", "itsk/%A9day",
            "itsk/%A9too", "itsk/cprt", "itsk/covr", "itsk/trkn", "itsk/disk", "itlk/com.apple.iTunes.ISRC",
        ])
    }

    @Test("the cover is stored as a JPEG covr atom that AVFoundation reads back")
    func coverIsJPEG() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, _) = try await convert("aac-320.m4a", in: folder)
        let covr = try #require(try MP4Inspector.tagAtoms(Data(contentsOf: url)).first { $0.name == "covr" })
        let value = try MP4Inspector.value(of: covr.bytes)
        #expect(value.type == 13)
        #expect(value.bytes == cover)

        let items = try await AVURLAsset(url: url).loadMetadata(for: .iTunesMetadata)
        let artwork = try #require(items.first { $0.identifier == .iTunesMetadataCoverArt })
        #expect(try await artwork.load(.dataValue) == cover)
    }

    @Test("without a cover there's no covr atom, and a cover that isn't a JPEG is refused before anything is created")
    func coverRules() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try AudioFixture.data("aac-320.m4a")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(throws: M4AFormatError.coverIsNotJPEG) { try convert(source, in: folder, coverJPEG: png) }
        #expect(throws: M4AFormatError.coverIsNotJPEG) { try convert(source, in: folder, coverJPEG: Data()) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

        let (url, _) = try convert(source, in: folder, coverJPEG: nil)
        #expect(try !MP4Inspector.tagAtoms(Data(contentsOf: url)).contains { $0.name == "covr" })
    }

    @Test("empty values are left out, and so is a track or disc number of 0")
    func emptyTagsLeftOut() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tags = FLACTags(title: "Intro", artist: "", album: nil, albumArtist: "", trackNumber: 0, discNumber: 0,
                            year: "", copyright: nil, isrc: "")
        let (url, _) = try convert(AudioFixture.data("aac-320.m4a"), in: folder, tags: tags)
        #expect(try MP4Inspector.tagAtoms(Data(contentsOf: url)).map(\.name) == ["©nam", "©too"])
    }

    // MARK: Safety

    @Test("an existing file is never replaced")
    func existingFileKept() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        try Data("the person's own file".utf8).write(to: url)
        let error = await #expect(throws: POSIXError.self) {
            try await M4AWriter().writeM4A(from: AudioFixture.url("aac-320.m4a"), tags: AudioFixture.tags, coverJPEG: self.cover, to: url)
        }
        #expect(error?.code == .EEXIST)
        #expect(try Data(contentsOf: url) == Data("the person's own file".utf8))
    }

    @Test("a failure part-way through removes the partial file")
    func failurePartWayLeavesNothing() throws {
        struct DiskFailed: Error {}
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        var pieces = 0
        #expect(throws: DiskFailed.self) {
            try M4AWriter.write(
                AudioFixture.data("aac-320.m4a"), tags: AudioFixture.tags, coverJPEG: cover, toolName: "test", to: url,
                pieceBytes: 4096, afterPiece: {
                    pieces += 1
                    #expect(FileManager.default.fileExists(atPath: url.path))
                    if pieces == 3 { throw DiskFailed() }
                }
            )
        }
        #expect(pieces == 3)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("cancelling part-way stops at once and removes the partial file")
    func cancelPartWayLeavesNothing() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        let source = try AudioFixture.data("aac-320.m4a")
        let task = Task { () -> (pieces: Int, error: (any Error)?) in
            var pieces = 0
            do {
                _ = try M4AWriter.write(source, tags: AudioFixture.tags, coverJPEG: nil, toolName: "test", to: url,
                                        pieceBytes: 4096, afterPiece: {
                                            pieces += 1
                                            withUnsafeCurrentTask { $0?.cancel() }
                                        })
                return (pieces, nil)
            } catch {
                return (pieces, error)
            }
        }
        let outcome = await task.value
        #expect(outcome.error is CancellationError)
        #expect(outcome.pieces == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a download cancelled before writing creates nothing")
    func cancelBeforeWriting() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        let source = try AudioFixture.url("aac-320.m4a")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await M4AWriter().writeM4A(from: source, tags: AudioFixture.tags, coverJPEG: nil, to: url)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("audio that isn't unencrypted AAC is refused by name, and nothing is created")
    func nonAACRefused() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = try AudioFixture.data("aac-320.m4a")
        // The esds's decoder configuration: tag 4, a 4-byte length, then the
        // object type (0x40, MPEG-4 Audio). 0x6B is MP3.
        let mp3 = try MP4Inspector.patch(plain, replacing: [0x04, 0x80, 0x80, 0x80, 0x17, 0x40],
                                         with: [0x04, 0x80, 0x80, 0x80, 0x17, 0x6B])
        let encrypted = try MP4Inspector.patch(plain, replacing: Array("mp4a".utf8), with: Array("enca".utf8))
        let cases: [(Data, M4AFormatError)] = [
            (try AudioFixture.data("dash-24-96000.mp4"), .notAAC(codec: "fLaC")),
            (try AudioFixture.data("bts-16-44100.flac"), .notMP4),
            (mp3, .notAAC(codec: "mp4a.6B")),
            (encrypted, .encryptedAudio),
        ]
        for (source, expected) in cases {
            #expect(throws: expected) { try convert(source, in: folder) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("the same download always gives the same bytes")
    func deterministic() throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try AudioFixture.data("dash-aac.mp4")
        let first = folder.appendingPathComponent("a.m4a"), second = folder.appendingPathComponent("b.m4a")
        _ = try M4AWriter.write(source, tags: AudioFixture.tags, coverJPEG: cover, toolName: "test", to: first)
        _ = try M4AWriter.write(source, tags: AudioFixture.tags, coverJPEG: cover, toolName: "test", to: second)
        #expect(try Data(contentsOf: first) == Data(contentsOf: second))
    }

    @Test("the writer is the pipeline's M4AWriting seam and names the tool it's given")
    func conformsToTheSeam() async throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let writer: any M4AWriting = M4AWriter(toolName: "Custom Tool 1.0")
        let url = folder.appendingPathComponent("Paper Harbour.m4a")
        let result = try await writer.writeM4A(from: AudioFixture.url("aac-320.m4a"), tags: AudioFixture.tags, coverJPEG: nil, to: url)
        #expect(result == M4AWriteResult(durationSeconds: 1.0))
        let tool = try #require(try MP4Inspector.tagAtoms(Data(contentsOf: url)).first { $0.name == "©too" })
        #expect(try MP4Inspector.value(of: tool.bytes).bytes == Data("Custom Tool 1.0".utf8))
    }
}
