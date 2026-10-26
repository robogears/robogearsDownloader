import AVFoundation
import Foundation
import Testing
@testable import RobogearsCore

/// Looks inside MP4 files for the AAC writer's tests: whole boxes by path,
/// the mdat bodies, and the iTunes tag atoms. Uses the FLAC extractor's box
/// walker, which the writer's reader shares, so a broken walker fails the
/// FLAC tests too.
enum MP4Inspector {
    static func boxes(_ data: Data, in range: Range<Int>) throws -> [FMP4Box] {
        try FMP4FLACExtractor.boxes(FLACByteReader(data), in: range)
    }

    /// The box at `path`, starting from the top level, with its offsets in
    /// `data`; nil when any step is missing.
    static func find(_ data: Data, _ path: [String]) throws -> FMP4Box? {
        var range = 0..<data.count
        var found: FMP4Box?
        for type in path {
            guard let next = try boxes(data, in: range).first(where: { $0.type == type }) else { return nil }
            found = next
            // meta is a full box: its children follow a version-and-flags word.
            range = type == "meta" ? (next.bodyStart + 4)..<next.end : next.body
        }
        return found
    }

    /// The whole box (header included) at `path`, or nil.
    static func box(_ data: Data, _ path: [String]) throws -> Data? {
        try find(data, path).map { data.subdata(in: $0.start..<$0.end) }
    }

    static let trackPath = ["moov", "trak"]
    static let sampleTablePath = ["moov", "trak", "mdia", "minf", "stbl"]

    static func topLevelTypes(_ data: Data) throws -> [String] {
        try boxes(data, in: 0..<data.count).map(\.type)
    }

    /// Every mdat body, joined in file order.
    static func mdatBodies(_ data: Data) throws -> Data {
        try boxes(data, in: 0..<data.count).filter { $0.type == "mdat" }.reduce(Data()) { $0 + data.subdata(in: $1.body) }
    }

    /// The ilst atoms in order, named in Latin-1 so "©nam" reads as written.
    static func tagAtoms(_ data: Data) throws -> [(name: String, bytes: Data)] {
        guard let ilst = try box(data, ["moov", "udta", "meta", "ilst"]) else { return [] }
        return try boxes(ilst, in: 8..<ilst.count).map { atom in
            let name = String(String.UnicodeScalarView(ilst[(atom.start + 4)..<(atom.start + 8)].map { Unicode.Scalar($0) }))
            return (name, ilst.subdata(in: atom.start..<atom.end))
        }
    }

    /// One atom's value: the bytes after its data atom's type and locale.
    static func value(of atom: Data) throws -> (type: UInt32, bytes: Data) {
        let inner = try boxes(atom, in: 8..<atom.count)
        let data = try #require(inner.last { $0.type == "data" })
        let r = FLACByteReader(atom)
        return (r.u32be(data.bodyStart), atom.subdata(in: (data.bodyStart + 8)..<data.end))
    }

    /// The source's or the output's AAC packets, through the writer's reader.
    static func packets(_ data: Data) throws -> [Data] {
        try MP4AudioTrackReader.read(data).samples.map { data.subdata(in: $0.range) }
    }

    /// Decodes the whole file with AVAssetReader into PCM; returns the frame
    /// count and the reader's final status.
    static func decodeWithAssetReader(_ url: URL) async throws -> (frames: Int, status: AVAssetReader.Status) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)
        guard reader.startReading() else { return (0, reader.status) }
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(buffer) }
        return (frames, reader.status)
    }

    /// `data` with the first occurrence of `find` (after `from`) replaced.
    static func patch(_ data: Data, replacing find: [UInt8], with replacement: [UInt8], from: Int = 0) throws -> Data {
        let range = try #require(data.range(of: Data(find), in: from..<data.count))
        var copy = data
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
