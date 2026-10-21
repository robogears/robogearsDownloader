import Foundation
@testable import RobogearsCore

/// The generated audio in Fixtures/audio (made by Scripts/make-audio-fixtures.sh).
enum AudioFixture {
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/audio") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/audio/\(name)"])
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// The tags the fixture script passed to FFmpeg with `-metadata`, as the
    /// native writer takes them.
    static let tags = FLACTags(
        title: "Blue Lantern – Café 東京",
        artist: "Placeholder Artist, Second Example",
        album: "Paper Harbour",
        albumArtist: "Placeholder Artist",
        trackNumber: 7,
        discNumber: 1,
        year: "2011",
        copyright: "℗ 2011 Example Records",
        isrc: "ZZXX12600001"
    )

    /// The audio frames of a FLAC file: everything after its metadata.
    static func frames(ofFLAC data: Data) throws -> Data {
        let layout = try FLACMetadataReader.read(data)
        return data.subdata(in: layout.audioOffset..<data.count)
    }

    /// A fresh folder for files a test writes, removed by the caller.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("robogears-audio-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
