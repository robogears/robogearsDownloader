import Foundation
import Testing
@testable import RobogearsCore

/// The source shapes the AAC fallback (D4 2.10) refuses rather than copy
/// wrongly, each named by its M4AFormatError, and the QuickTime sound
/// entries it reads. Every case patches the plain or DASH fixture (or
/// rebuilds the plain one with SyntheticM4A), and a refusal never leaves a
/// file behind.
@Suite("AAC .m4a source rules")
struct M4ASourceRulesTests {
    let plain: Data
    let dash: Data

    init() throws {
        plain = try AudioFixture.data("aac-320.m4a")
        dash = try AudioFixture.data("dash-aac.mp4")
    }

    /// Saving `source` throws `error`, and the folder stays empty.
    func expectRefused(_ source: Data, _ error: M4AFormatError, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        #expect(throws: error, sourceLocation: sourceLocation) {
            try M4AWriter.write(source, tags: AudioFixture.tags, coverJPEG: nil, toolName: "test", to: url)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, sourceLocation: sourceLocation)
    }

    /// `data` with `bytes` written over it at `offset`.
    func overwrite(_ data: Data, at offset: Int, with bytes: Data) -> Data {
        var copy = data
        copy.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        return copy
    }

    func plainBox(_ path: [String]) throws -> FMP4Box {
        try #require(try MP4Inspector.find(plain, path))
    }

    /// The first DASH segment's run: flags 0x201, so its data offset is at
    /// body + 8 and the first sample's size at body + 12.
    func firstRun() throws -> FMP4Box {
        let trun = try #require(try MP4Inspector.find(dash, ["moof", "traf", "trun"]))
        try #require(FLACByteReader(dash).u32be(trun.bodyStart) == 0x201)
        return trun
    }

    /// The last DASH segment's tfhd: flags 0x20038, so its default size is
    /// at body + 12. Its one-packet run takes its size from there.
    func lastFragmentHeader() throws -> FMP4Box {
        let top = try MP4Inspector.boxes(dash, in: 0..<dash.count)
        let moof = try #require(top.last { $0.type == "moof" })
        let traf = try #require(try MP4Inspector.boxes(dash, in: moof.body).first { $0.type == "traf" })
        let tfhd = try #require(try MP4Inspector.boxes(dash, in: traf.body).first { $0.type == "tfhd" })
        try #require(FLACByteReader(dash).u32be(tfhd.bodyStart) == 0x02_0038)
        return tfhd
    }

    // MARK: Track setup

    @Test("a sound track with two sample descriptions is refused, since one copied entry can't keep both")
    func twoSampleDescriptions() throws {
        var source = try SyntheticM4A.Source.plainFixture()
        source.sampleEntry += source.sampleEntry
        let twoEntries = SyntheticM4A.progressive(source, chunkSizes: [45], gap: 0, wide: false)
        try expectRefused(twoEntries, .unsupportedMP4("several sample descriptions"))
        let stsd = try plainBox(MP4Inspector.sampleTablePath + ["stsd"])
        try expectRefused(overwrite(plain, at: stsd.bodyStart + 4, with: SyntheticFMP4.u32(2)),
                          .unsupportedMP4("several sample descriptions"))
    }

    @Test("an edit list with two edits, or one at another speed, is refused by name")
    func editListShapes() throws {
        let elst = try plainBox(MP4Inspector.trackPath + ["edts", "elst"])
        try #require(plain[elst.bodyStart] == 0) // version 0: 4-byte duration, media time and rate
        try expectRefused(overwrite(plain, at: elst.bodyStart + 4, with: SyntheticFMP4.u32(2)),
                          .unsupportedMP4("edit list with 2 edits"))
        try expectRefused(overwrite(plain, at: elst.bodyStart + 16, with: SyntheticFMP4.u32(0x0000_8000)),
                          .unsupportedMP4("edit list at another speed"))
    }

    @Test("a file without a sound track is refused")
    func noSoundTrack() throws {
        let hdlr = try plainBox(MP4Inspector.trackPath + ["mdia", "hdlr"])
        try expectRefused(overwrite(plain, at: hdlr.bodyStart + 8, with: Data("vide".utf8)), .unsupportedMP4("no sound track"))
    }

    // MARK: Samples

    @Test("compact sample sizes (stz2) are refused, not read as stsz")
    func compactSampleSizes() throws {
        let stsz = try plainBox(MP4Inspector.sampleTablePath + ["stsz"])
        try expectRefused(overwrite(plain, at: stsz.start + 4, with: Data("stz2".utf8)), .unsupportedMP4("compact sample sizes (stz2)"))
    }

    @Test("a file with no audio samples, a DASH init segment alone or empty tables, is refused")
    func noSamples() throws {
        let moov = try #require(try MP4Inspector.find(dash, ["moov"]))
        try expectRefused(dash.prefix(moov.end), .noAudioSamples)
        let stsz = try plainBox(MP4Inspector.sampleTablePath + ["stsz"])
        try expectRefused(overwrite(plain, at: stsz.bodyStart + 8, with: SyntheticFMP4.u32(0)), .noAudioSamples)
    }

    @Test("a sample of 0 bytes is refused, whether the tables, a run or tfhd's default give it")
    func emptySample() throws {
        let stsz = try plainBox(MP4Inspector.sampleTablePath + ["stsz"])
        try #require(FLACByteReader(plain).u32be(stsz.bodyStart + 4) == 0) // sizes listed one by one
        try expectRefused(overwrite(plain, at: stsz.bodyStart + 12, with: SyntheticFMP4.u32(0)), .inconsistent("a sample of 0 bytes"))
        try expectRefused(overwrite(dash, at: firstRun().bodyStart + 12, with: SyntheticFMP4.u32(0)), .inconsistent("a sample of 0 bytes"))
        try expectRefused(overwrite(dash, at: lastFragmentHeader().bodyStart + 12, with: SyntheticFMP4.u32(0)),
                          .inconsistent("a sample of 0 bytes"))
    }

    @Test("a sample that lies outside the file's mdat boxes is refused, from the tables or a fragment")
    func sampleOutsideMdat() throws {
        let outside = M4AFormatError.truncated("MP4 sample outside its mdat")
        // A chunk that starts in the ftyp.
        let stco = try plainBox(MP4Inspector.sampleTablePath + ["stco"])
        try expectRefused(overwrite(plain, at: stco.bodyStart + 8, with: SyntheticFMP4.u32(0)), outside)
        // A run whose data starts at its own moof.
        try expectRefused(overwrite(dash, at: firstRun().bodyStart + 8, with: SyntheticFMP4.u32(0)), outside)
        // A run's first sample, or tfhd's default size, longer than the mdat.
        try expectRefused(overwrite(dash, at: firstRun().bodyStart + 12, with: SyntheticFMP4.u32(100_000)), outside)
        try expectRefused(overwrite(dash, at: lastFragmentHeader().bodyStart + 12, with: SyntheticFMP4.u32(1000)), outside)
    }

    // MARK: QuickTime sound entries

    /// The plain fixture's mp4a entry as a QuickTime sound description:
    /// version 1 or 2 adds 16 or 36 bytes of fixed fields after the 28
    /// every version has, and `wave` puts the esds inside a "wave" box, as
    /// QuickTime writers do.
    static func quickTimeEntry(_ entry: Data, version: UInt16, wave: Bool) -> Data {
        var fields = entry.subdata(in: 8..<36)
        fields.replaceSubrange(8..<10, with: SyntheticM4A.u16(version))
        fields += Data(repeating: 0x11, count: version == 1 ? 16 : version == 2 ? 36 : 0)
        let children = entry.subdata(in: 36..<entry.count)
        return SyntheticFMP4.box("mp4a", fields + (wave ? SyntheticFMP4.box("wave", children) : children))
    }

    @Test("QuickTime sound entries (versions 1 and 2, the esds inside wave) are read past their extra fields")
    func quickTimeEntries() throws {
        let entry = try SyntheticM4A.Source.plainFixture().sampleEntry
        for version: UInt16 in [0, 1, 2] {
            for wave in [false, true] {
                let quickTime = Self.quickTimeEntry(entry, version: version, wave: wave)
                #expect(try M4AWriter.aacObjectType(quickTime) == 0x40, "version \(version), wave \(wave)")
                // The object type really is read there: MP3's is named as such.
                let mp3 = try MP4Inspector.patch(quickTime, replacing: [0x04, 0x80, 0x80, 0x80, 0x17, 0x40],
                                                 with: [0x04, 0x80, 0x80, 0x80, 0x17, 0x6B])
                #expect(try M4AWriter.aacObjectType(mp3) == 0x6B, "version \(version), wave \(wave)")
            }
        }
    }

    @Test("a plain download with a QuickTime sound entry keeps every packet and its entry as it was")
    func quickTimeEntrySaved() throws {
        var source = try SyntheticM4A.Source.plainFixture()
        source.sampleEntry = Self.quickTimeEntry(source.sampleEntry, version: 1, wave: true)
        let data = SyntheticM4A.progressive(source, chunkSizes: [45], gap: 0, wide: false)
        let folder = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Blue Lantern.m4a")
        _ = try M4AWriter.write(data, tags: AudioFixture.tags, coverJPEG: nil, toolName: "test", to: url)
        let written = try Data(contentsOf: url)
        #expect(try MP4Inspector.packets(written) == source.packets)
        #expect(try MP4Inspector.box(written, MP4Inspector.sampleTablePath + ["stsd"])
            == SyntheticFMP4.fullBox("stsd", SyntheticFMP4.u32(1) + source.sampleEntry))
    }
}
