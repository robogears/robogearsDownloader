import Foundation
@testable import RobogearsCore

/// A download folder made for one test, with its own stand-in Trash, so no
/// test touches the real Trash or any folder of the owner's.
final class TestFolder: @unchecked Sendable {
    /// Holds the download folder and the stand-in Trash.
    let root: URL
    let url: URL
    let trashFolder: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("robogears-folder-tests-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("Downloads", isDirectory: true)
        trashFolder = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashFolder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    /// The folder's names, sorted, as the disk stores them.
    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    func trashedNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: trashFolder.path).sorted()
    }

    /// The planner with the stand-in Trash; `noTrash` acts out a network
    /// share without one. `rename` replaces the exclusive rename.
    func planner(noTrash: Bool = false, tags: [String: AudioTags] = [:],
                 rename: (@Sendable (URL, URL) -> Int32)? = nil) -> DownloadFolder {
        let trashFolder = self.trashFolder
        let operations = FileOperations(
            trash: { url in
                if noTrash { throw CocoaError(.featureUnsupported) }
                try FileManager.default.moveItem(at: url, to: trashFolder.appendingPathComponent(url.lastPathComponent))
            },
            renameExclusive: rename ?? FileOperations.system.renameExclusive
        )
        return DownloadFolder(folder: url, tagReader: StubTagReader(byName: tags), fileOperations: operations)
    }

    func request(title: String, version: String? = nil, artist: String = "Placeholder Artist",
                 album: String? = "Paper Harbour", seconds: Int? = 1, isrc: String? = nil,
                 lossless: Bool? = true, replace: Bool = false) -> TrackDownloadRequest {
        TrackDownloadRequest(rowID: UUID(), tidalID: 1, title: title, version: version, artist: artist, album: album,
                             durationSeconds: seconds, isrc: isrc, losslessOnTIDAL: lossless, folder: url,
                             replaceExisting: replace)
    }

    // MARK: - Files

    /// A native FLAC like the ones this app saves, from a fixture's audio,
    /// with a cover in front of the tags as the writer puts it.
    @discardableResult
    func writeFLAC(_ name: String, title: String?, artist: String? = "Placeholder Artist", isrc: String? = nil,
                   source: String = "bts-16-44100.flac", in folder: URL? = nil) throws -> URL {
        let destination = (folder ?? url).appendingPathComponent(name)
        let audio = try FLACAudio(downloaded: AudioFixture.data(source))
        try FLACWriter.write(audio, tags: FLACTags(title: title, artist: artist, isrc: isrc),
                             coverJPEG: AudioFixture.data("cover.jpg"), to: destination)
        return destination
    }

    /// A fixture copied in under `name`.
    @discardableResult
    func copyFixture(_ fixture: String, as name: String, subfolder: String = "audio") throws -> URL {
        let source = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(subfolder)/\(fixture)")
        let destination = url.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Keeps the first `count` bytes, as a write cut short would.
    func cut(_ name: String, to count: Int) throws {
        let data = try Data(contentsOf: file(name))
        try data.prefix(count).write(to: file(name))
    }

    func cut(_ name: String, fraction: Double) throws {
        let size = try Data(contentsOf: file(name)).count
        try cut(name, to: Int(Double(size) * fraction))
    }

    func append(_ bytes: Data, to name: String) throws {
        let handle = try FileHandle(forWritingTo: file(name))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }
}

/// Apple's and the package's tag readers, except for the names given, whose
/// tags are made up: lets a real .m4a fixture stand for any song.
struct StubTagReader: TagReading {
    var byName: [String: AudioTags]

    func readTags(at url: URL) async -> AudioTags? {
        if let tags = byName[url.lastPathComponent] { return tags }
        return await TagReader().readTags(at: url)
    }
}

enum FLACFrames {
    /// Where each audio frame of a FLAC file starts, found by walking frame
    /// numbers 0, 1, 2… from the first frame. Only for the fixed-block-size
    /// test files, whose frames are numbered.
    static func starts(_ data: Data) throws -> [Int] {
        let layout = try FLACMetadataReader.read(data)
        let reader = FLACByteReader(data)
        let bytes = [UInt8](data)
        var starts = [layout.audioOffset]
        var position = layout.audioOffset + 1
        while position < bytes.count - 1 {
            if bytes[position] == 0xFF, bytes[position + 1] == 0xF8,
               FLACFrameHeader.parse(reader, at: position) != nil,
               ExistingFileCheck.codedNumber(bytes, at: position + 4) == UInt64(starts.count) {
                starts.append(position)
            }
            position += 1
        }
        return starts
    }
}
