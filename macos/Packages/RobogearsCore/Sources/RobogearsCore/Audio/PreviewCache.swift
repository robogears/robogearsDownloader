import Foundation

/// Previews kept on disk so a song plays at once the second time and a
/// reopened app paints its waveforms with no download (D4 5.1, 5.2):
/// audio files up to a byte limit (about 1 GB), oldest-used dropped first,
/// and every track's peaks (one byte per bar, kept until Clear Preview
/// Cache). Lives in the app's Caches folder, which macOS may empty; nothing
/// here is the only copy of anything.
public actor PreviewCache {
    public static let defaultByteLimit: Int64 = 1_000_000_000

    public let directory: URL
    public let byteLimit: Int64
    private var audioDirectory: URL { directory.appendingPathComponent("audio", isDirectory: true) }
    private var peaksDirectory: URL { directory.appendingPathComponent("peaks", isDirectory: true) }

    public init(directory: URL, byteLimit: Int64 = PreviewCache.defaultByteLimit) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    /// `~/Library/Caches/<bundle id>/Previews`, or a folder under the temporary
    /// directory when the app has no Caches folder (command-line tests).
    public static func standardDirectory(bundleID: String = "com.robogears.downloader") -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("Previews", isDirectory: true)
    }

    // MARK: Audio

    /// The cached audio for a track, marking it as just used; nil when absent.
    public func audio(for tidalID: Int64) -> URL? {
        let url = audioURL(tidalID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    /// Moves a finished preview file into the cache (replacing an older copy
    /// of the same track), then drops the least recently used files until the
    /// cache fits its limit again. The newest file always stays, even when
    /// it alone is over the limit, so the song being played is never removed.
    @discardableResult
    public func store(_ file: URL, for tidalID: Int64) throws -> URL {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let destination = audioURL(tidalID)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
            try FileManager.default.moveItem(at: file, to: destination)
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        trim(keeping: destination)
        return destination
    }

    /// A place to write a preview while it downloads, inside the cache
    /// folder so `store` is a rename on the same disk.
    public func temporaryFile(for tidalID: Int64, extension ext: String) throws -> URL {
        let incoming = directory.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        return incoming.appendingPathComponent("\(tidalID)-\(UUID().uuidString).\(ext)")
    }

    /// Bytes of audio held now.
    public func audioByteCount() -> Int64 {
        audioFiles().reduce(0) { $0 + $1.size }
    }

    // MARK: Peaks

    public func peaks(for tidalID: Int64) -> [Float]? {
        guard let data = try? Data(contentsOf: peaksURL(tidalID)), data.count == WaveformPeaks.barCount else { return nil }
        return WaveformPeaks.decode(data)
    }

    public func storePeaks(_ peaks: [Float], for tidalID: Int64) throws {
        try FileManager.default.createDirectory(at: peaksDirectory, withIntermediateDirectories: true)
        try WaveformPeaks.encode(peaks).write(to: peaksURL(tidalID), options: .atomic)
    }

    // MARK: Housekeeping

    /// Settings › Clear Preview Cache: audio, peaks and unfinished downloads.
    public func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Removes unfinished preview downloads left by a quit or crash.
    public func sweepIncoming() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("incoming", isDirectory: true))
    }

    // MARK: Private

    private func audioURL(_ id: Int64) -> URL { audioDirectory.appendingPathComponent("\(id).flac") }
    private func peaksURL(_ id: Int64) -> URL { peaksDirectory.appendingPathComponent("\(id).peaks") }

    private struct CachedFile { let url: URL; let size: Int64; let used: Date }

    private func audioFiles() -> [CachedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return CachedFile(url: url, size: Int64(values.fileSize ?? 0), used: values.contentModificationDate ?? .distantPast)
        }
    }

    private func trim(keeping newest: URL) {
        var files = audioFiles().sorted { $0.used < $1.used }
        var total = files.reduce(0) { $0 + $1.size }
        while total > byteLimit, let oldest = files.first {
            files.removeFirst()
            if oldest.url.standardizedFileURL == newest.standardizedFileURL { continue }
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
        }
    }
}
