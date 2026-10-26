import AVFoundation
import Foundation
import RobogearsCore

// TEMPORARY (see StandIn.swift): library check, downloader, previews and sign-in.

/// Marks a few invented titles as already in the library or similar.
struct StandInLibrary: LibraryChecking {
    func check(_ items: [QueueItem]) async -> [UUID: LibraryVerdict] {
        try? await Task.sleep(for: .milliseconds(700))
        var result: [UUID: LibraryVerdict] = [:]
        for item in items {
            let h = StandIn.hash(item.title.lowercased())
            if item.title == "Slow Motion" || (h % 11 == 0) {
                result[item.id] = LibraryVerdict(
                    match: .init(kind: .exact, path: "/Volumes/Library/\(item.title).flac", libraryTitle: item.title),
                    durationSeconds: item.durationSeconds)
            } else if item.title == "Blue Lantern" || (h % 7 == 0) {
                // The remix in the library runs 23 s shorter.
                result[item.id] = LibraryVerdict(
                    match: .init(kind: .similar, path: "/Volumes/Library/\(item.title) (Remix).mp3",
                                 libraryTitle: "\(item.title) (Remix)"),
                    durationSeconds: item.durationSeconds.map { max(1, $0 - 23) })
            }
        }
        return result
    }

    /// Read-only: only looks for "<Title>.flac" / ".m4a" in the folder.
    func isInDownloadFolder(_ item: QueueItem, folder: URL) async -> Bool {
        let fm = FileManager.default
        return ["flac", "m4a"].contains { fm.fileExists(atPath: folder.appendingPathComponent("\(item.title).\($0)").path) }
    }

    /// Pretends to index 1,240 files in steps of 25 without reading the
    /// folder's contents; a folder that isn't there reads as unavailable.
    func scan(_ folder: URL) -> AsyncStream<LibraryScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    continuation.yield(.unavailable("The music library “\(folder.lastPathComponent)” isn't available. Connect its drive, then click Refresh."))
                    continuation.finish()
                    return
                }
                let total = 1_240
                var done = 0
                while done < total {
                    try? await Task.sleep(for: .milliseconds(12))
                    if Task.isCancelled { continuation.finish(); return }
                    done = min(total, done + 25)
                    continuation.yield(.progress(done: done, total: total))
                }
                continuation.yield(.finished(files: total))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Pretends to download: progress ticks and deterministic outcomes. It never
/// writes a file anywhere, so "saved" rows point at files that don't exist.
actor StandInDownloader: BatchDownloading {
    private var stopRequested = false
    private var removed: Set<UUID> = []
    private var current: UUID?

    nonisolated func download(_ tracks: [QueueItem], into folder: URL) -> AsyncStream<BatchEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(tracks, folder, continuation)
                continuation.yield(.ended)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ tracks: [QueueItem], _ folder: URL, _ out: AsyncStream<BatchEvent>.Continuation) async {
        stopRequested = false
        removed = []
        for (index, track) in tracks.enumerated() {
            if stopRequested || Task.isCancelled { return }
            if removed.contains(track.id) { continue }
            current = track.id
            out.yield(.started(track.id))
            if index > 0 && index % 9 == 0 {
                out.yield(.waitingForTIDAL(true))
                try? await Task.sleep(for: .milliseconds(1200))
                out.yield(.waitingForTIDAL(false))
            }
            var percent = 0
            while percent < 100 {
                try? await Task.sleep(for: .milliseconds(60))
                if stopRequested || Task.isCancelled { return }
                if removed.contains(track.id) { break }
                percent = min(100, percent + 7)
                out.yield(.progress(track.id, percent: percent))
            }
            if removed.contains(track.id) { continue }
            out.yield(.finished(track.id, outcome(for: track, folder: folder)))
        }
        current = nil
    }

    private func outcome(for track: QueueItem, folder: URL) -> TrackOutcome {
        let file = folder.appendingPathComponent("\(track.title).flac")
        let h = StandIn.hash(track.title.lowercased())
        if track.title.hasPrefix("Glass") || h % 17 == 0 {
            return .failed(reason: "TIDAL couldn't send this track. Try again later.")
        }
        if track.title.hasPrefix("Echo") { return .clash(fileName: "\(track.title).flac") }
        if track.title.hasPrefix("Paper") {
            return .saved(quality: "AAC", file: folder.appendingPathComponent("\(track.title).m4a"), isAAC: true)
        }
        return .saved(quality: track.hiRes ? "24-bit / 96 kHz" : "16-bit / 44.1 kHz", file: file, isAAC: false)
    }

    func stop() async { stopRequested = true }

    func remove(_ id: UUID) async { removed.insert(id) }

    func resolve(_ item: QueueItem, _ resolution: ClashResolution, in folder: URL) async -> TrackOutcome {
        try? await Task.sleep(for: .milliseconds(800))
        switch resolution {
        case .saveAs(let name):
            return .saved(quality: item.hiRes ? "24-bit / 96 kHz" : "16-bit / 44.1 kHz",
                          file: folder.appendingPathComponent(name), isAAC: false)
        case .replace:
            return .saved(quality: item.hiRes ? "24-bit / 96 kHz" : "16-bit / 44.1 kHz",
                          file: folder.appendingPathComponent("\(item.title).flac"), isAAC: false)
        }
    }
}

/// Peaks from the invented catalogue, and a quiet generated tone as the
/// "playable file" (written to the temporary folder, never a download).
actor StandInPreviews: PreviewProviding {
    private var made: [Int64: PreviewAsset] = [:]

    /// Stands in for the on-disk peaks cache: bars appear without writing
    /// anything; only pressing play makes the tone file.
    func cachedPeaks(for tidalID: Int64) async -> [Float]? {
        tidalID % 23 == 0 ? nil : StandIn.peaks(for: tidalID)
    }

    func preview(for tidalID: Int64) async throws -> PreviewAsset {
        if let asset = made[tidalID] { return asset }
        try await Task.sleep(for: .milliseconds(350))
        if tidalID % 23 == 0 {
            throw ServiceError("TIDAL didn't send a preview for this track. Try again.")
        }
        let peaks = StandIn.peaks(for: tidalID)
        let duration = TimeInterval(StandIn.duration(for: tidalID))
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(tidalID).wav")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Self.tone(peaks: peaks, seconds: duration).write(to: file, options: .atomic)
        }
        let asset = PreviewAsset(peaks: peaks, file: file, duration: duration)
        made[tidalID] = asset
        return asset
    }

    /// The stand-in's own tone files, in a folder only it uses.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("robogears-stand-in-previews", isDirectory: true)
    }

    func cacheSize() async -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Removes only the stand-in's generated tone files.
    func clearCache() async {
        made.removeAll()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "wav" {
            try? fm.removeItem(at: file)
        }
    }

    /// 8 kHz, 8-bit mono WAV: two soft sines whose loudness follows the peaks.
    static func tone(peaks: [Float], seconds: Double) -> Data {
        let rate = 8_000
        let frames = Int(seconds * Double(rate))
        var data = Data(capacity: 44 + frames)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + frames))
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        le32(16); le16(1); le16(1); le32(UInt32(rate)); le32(UInt32(rate)); le16(1); le16(8)
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(frames))
        var samples = [UInt8](repeating: 128, count: frames)
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            let bar = min(peaks.count - 1, Int(Double(i) / Double(frames) * Double(peaks.count)))
            let level = 0.18 * Double(peaks[bar])
            let v = level * (sin(2 * .pi * 196 * t) * 0.6 + sin(2 * .pi * 293.7 * t) * 0.4)
            samples[i] = UInt8(max(0, min(255, 128 + v * 127)))
        }
        data.append(contentsOf: samples)
        return data
    }
}

/// A pretend device-code sign-in that succeeds after a few seconds.
actor StandInSignIn: SignInProviding {
    private var state: SignInState = .signedOut

    func currentState() async -> SignInState { state }

    nonisolated func signIn() -> AsyncStream<SignInEvent> {
        AsyncStream { continuation in
            let task = Task {
                // An address that can never resolve: the stand-in must not send
                // anyone to TIDAL with a made-up code.
                continuation.yield(.link(URL(string: "https://sign-in.stand-in.invalid/ABCDE")!, code: "ABCDE"))
                continuation.yield(.status("Waiting for TIDAL…"))
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { continuation.finish(); return }
                await self.setState(.signedIn(country: "United States"))
                continuation.yield(.signedIn(country: "United States"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func setState(_ new: SignInState) { state = new }

    func signOut() async { state = .signedOut }
}

/// Plays the stand-in tone files with AVAudioPlayer. The real player comes
/// from the preview lane (Now Playing, the disk cache, streaming starts).
@MainActor
final class StandInPreviewPlayer: NSObject, PreviewPlaying, AVAudioPlayerDelegate {
    private var audio: AVAudioPlayer?
    var volume: Float = 0.25 { didSet { audio?.volume = volume } }
    var onFinish: (@MainActor () -> Void)?

    func load(_ asset: PreviewAsset) throws {
        let player = try AVAudioPlayer(contentsOf: asset.file)
        player.delegate = self
        player.volume = volume
        player.prepareToPlay()
        audio = player
    }

    func play() { audio?.play() }
    func pause() { audio?.pause() }

    func stop() {
        audio?.stop()
        audio = nil
    }

    func seek(toFraction fraction: Double) {
        guard let audio else { return }
        audio.currentTime = audio.duration * min(1, max(0, fraction))
    }

    var isPlaying: Bool { audio?.isPlaying ?? false }
    var currentTime: TimeInterval { audio?.currentTime ?? 0 }
    var duration: TimeInterval { audio?.duration ?? 0 }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}
