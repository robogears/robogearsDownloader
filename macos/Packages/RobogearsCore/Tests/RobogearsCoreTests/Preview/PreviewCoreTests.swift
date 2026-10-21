import AVFoundation
import MediaPlayer
import Foundation
import Testing
@testable import RobogearsCore

private func audioFixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/audio/\(name)")
}

private func tempFolder(_ label: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A mono 16-bit WAV whose loudness follows `envelope`, one value per slice.
private func writeTone(_ url: URL, envelope: [Float], framesPerSlice: Int = 441) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
    ])
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(envelope.count * framesPerSlice))!
    buffer.frameLength = buffer.frameCapacity
    for (slice, level) in envelope.enumerated() {
        for i in 0..<framesPerSlice {
            buffer.floatChannelData![0][slice * framesPerSlice + i] = level * sin(Float(i) * 0.3)
        }
    }
    try file.write(from: buffer)
}

private func writeSamples(_ url: URL, _ samples: [Float]) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
    ])
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    for (i, value) in samples.enumerated() { buffer.floatChannelData![0][i] = value }
    try file.write(from: buffer)
}

@Suite("Waveform peaks") struct WaveformPeaksTests {
    @Test func aTrackGivesTwoHundredBarsWithTheLoudestAtOne() throws {
        let peaks = try WaveformPeaks.compute(from: audioFixture("bts-16-44100.flac"))
        #expect(peaks.count == 200)
        #expect(peaks.max() == 1)
        #expect(peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func eachBarIsTheLoudestMomentOfItsSlice() throws {
        // 200 slices: silent, except slice 50 at half and slice 150 at full level.
        var envelope = [Float](repeating: 0, count: 200)
        envelope[50] = 0.5
        envelope[150] = 1.0
        let url = tempFolder("envelope").appendingPathComponent("tone.wav")
        try writeTone(url, envelope: envelope)
        let peaks = try WaveformPeaks.compute(from: url)
        #expect(peaks[150] == 1)
        #expect(abs(peaks[50] - 0.5) < 0.02)
        #expect(peaks[10] == 0 && peaks[100] == 0 && peaks[199] == 0)
    }

    @Test func aShortSpikeInsideASliceSetsItsBar() throws {
        // Every sample at 0.1, except one spike of 0.9 in the middle of slice 20:
        // the bar takes the slice's loudest moment, not its first or last sample.
        let framesPerSlice = 100
        var samples = [Float](repeating: 0.1, count: 200 * framesPerSlice)
        samples[20 * framesPerSlice + 50] = 0.9
        let url = tempFolder("spike").appendingPathComponent("spike.wav")
        try writeSamples(url, samples)
        let peaks = try WaveformPeaks.compute(from: url)
        #expect(peaks[20] == 1)
        #expect(abs(peaks[10] - 0.1 / 0.9) < 0.01)
    }

    @Test func silenceStaysFlatInsteadOfDividingByZero() throws {
        let url = tempFolder("silence").appendingPathComponent("silence.wav")
        try writeTone(url, envelope: [Float](repeating: 0, count: 20))
        #expect(try WaveformPeaks.compute(from: url).allSatisfy { $0 == 0 })
    }

    @Test func aFileThatIsNotAudioIsReportedNotCrashed() throws {
        let url = tempFolder("junk").appendingPathComponent("junk.flac")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: WaveformPeaks.PeaksError.self) { try WaveformPeaks.compute(from: url) }
    }

    @Test func peaksSurviveTheOneBytePerBarStore() {
        let peaks: [Float] = (0..<200).map { Float($0) / 199 }
        let back = WaveformPeaks.decode(WaveformPeaks.encode(peaks))
        #expect(WaveformPeaks.encode(peaks).count == 200)
        #expect(zip(peaks, back).allSatisfy { abs($0 - $1) <= 1 / 255 })
    }
}

@Suite("Preview cache") struct PreviewCacheTests {
    private func file(_ dir: URL, _ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    @Test func aStoredPreviewIsFoundAgainByANewCache() async throws {
        let root = tempFolder("found")
        let cache = PreviewCache(directory: root.appendingPathComponent("Previews"))
        let incoming = try await cache.temporaryFile(for: 42, extension: "flac")
        try FileManager.default.copyItem(at: audioFixture("bts-16-44100.flac"), to: incoming)
        try await cache.store(incoming, for: 42)
        try await cache.storePeaks([Float](repeating: 0.5, count: 200), for: 42)
        // As after a relaunch:
        let again = PreviewCache(directory: root.appendingPathComponent("Previews"))
        #expect(await again.audio(for: 42) != nil)
        #expect(await again.peaks(for: 42)?.count == 200)
        #expect(await again.audio(for: 7) == nil)
    }

    @Test func theLeastRecentlyPlayedSongsAreDroppedFirst() async throws {
        let root = tempFolder("lru")
        let cache = PreviewCache(directory: root.appendingPathComponent("Previews"), byteLimit: 250)
        for id in Int64(1)...3 {
            try await cache.store(try file(root, "\(id).flac", bytes: 100), for: id)
            try await Task.sleep(for: .milliseconds(20))
        }
        // Three 100-byte files over a 250-byte limit: the oldest (1) goes.
        #expect(await cache.audio(for: 1) == nil)
        try await Task.sleep(for: .milliseconds(20))
        _ = await cache.audio(for: 2)          // playing 2 again makes 3 the oldest
        try await Task.sleep(for: .milliseconds(20))
        try await cache.store(try file(root, "4.flac", bytes: 100), for: 4)
        #expect(await cache.audio(for: 3) == nil)
        #expect(await cache.audio(for: 2) != nil)
        #expect(await cache.audio(for: 4) != nil)
        #expect(await cache.audioByteCount() <= 250)
    }

    @Test func aSongBiggerThanTheWholeCacheStillPlays() async throws {
        let root = tempFolder("big")
        let cache = PreviewCache(directory: root.appendingPathComponent("Previews"), byteLimit: 50)
        try await cache.store(try file(root, "9.flac", bytes: 100), for: 9)
        #expect(await cache.audio(for: 9) != nil)
    }

    @Test func storingTheSameTrackAgainReplacesItsOldCopy() async throws {
        let root = tempFolder("replace")
        let cache = PreviewCache(directory: root.appendingPathComponent("Previews"))
        try await cache.store(try file(root, "a.flac", bytes: 10), for: 5)
        try await cache.store(try file(root, "b.flac", bytes: 30), for: 5)
        #expect(await cache.audioByteCount() == 30)
    }

    @Test func clearPreviewCacheRemovesAudioPeaksAndUnfinishedDownloads() async throws {
        let root = tempFolder("clear")
        let cache = PreviewCache(directory: root.appendingPathComponent("Previews"))
        try await cache.store(try file(root, "x.flac", bytes: 10), for: 1)
        try await cache.storePeaks([Float](repeating: 1, count: 200), for: 1)
        _ = try await cache.temporaryFile(for: 2, extension: "flac")
        try await cache.clear()
        #expect(await cache.audio(for: 1) == nil)
        #expect(await cache.peaks(for: 1) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Previews").path))
    }

    @Test func peaksOfTheWrongLengthAreIgnored() async throws {
        let root = tempFolder("badpeaks")
        let cache = PreviewCache(directory: root.appendingPathComponent("Previews"))
        try await cache.storePeaks([0.1, 0.2], for: 3)
        #expect(await cache.peaks(for: 3) == nil)
    }
}

@Suite("Now Playing") struct NowPlayingTests {
    @Test func aPausedPreviewReportsRateZeroAndAClampedPosition() {
        let info = PreviewNowPlaying.Info(title: "Blue Lantern", artist: "Placeholder Artist",
                                          duration: 225, elapsed: 400, isPlaying: false)
        let dict = PreviewNowPlaying.dictionary(for: info)
        #expect(dict[MPMediaItemPropertyTitle] as? String == "Blue Lantern")
        #expect(dict[MPMediaItemPropertyArtist] as? String == "Placeholder Artist")
        #expect(dict[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
        #expect(dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 225)
    }

    @Test func aPlayingPreviewReportsRateOne() {
        let info = PreviewNowPlaying.Info(title: "T", artist: "A", duration: 10, elapsed: -1, isPlaying: true)
        let dict = PreviewNowPlaying.dictionary(for: info)
        #expect(dict[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1)
        #expect(dict[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 0)
    }
}
