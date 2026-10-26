// avprobe: what macOS's own audio frameworks make of a file.
//
// Spike tool for docs/spikes/audio-and-tagging.md, question (a). For each
// file it reports what AVAudioFile, AVAssetReader, AVAudioPlayer and AVPlayer
// say, decodes the whole file twice (AVAudioFile and AVAssetReader), times
// both decodes, hashes the decoded samples, and lists the tags and artwork
// AVFoundation exposes. Playback is checked silently (volume 0).
//
// Build and run (from the repository root):
//   swiftc -O docs/spikes/tools/avprobe.swift -o /tmp/avprobe
//   /tmp/avprobe file1.flac file2.m4a ...
import AVFoundation
import CryptoKit
import Foundation

func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
}

/// Apple's FLAC and ALAC descriptions carry the source bit depth in the
/// format flags (kAppleLosslessFormatFlag_16/20/24/32BitSourceData = 1...4).
func sourceBitDepth(_ d: AudioStreamBasicDescription) -> String {
    if d.mBitsPerChannel > 0 { return "\(d.mBitsPerChannel)" }
    switch d.mFormatFlags {
    case 1: return "16 (from flags)"
    case 2: return "20 (from flags)"
    case 3: return "24 (from flags)"
    case 4: return "32 (from flags)"
    default: return "unknown (flags=\(d.mFormatFlags))"
    }
}

func seconds(since start: ContinuousClock.Instant) -> String {
    let d = ContinuousClock.now - start
    let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    return String(format: "%.3f s", s)
}

func probeAudioFile(_ url: URL) {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        print("  AVAudioFile: FAILED to open \(error)"); return
    }
    let d = file.fileFormat.streamDescription.pointee
    let rate = file.fileFormat.sampleRate
    print("  AVAudioFile: opened. format=\(fourCC(d.mFormatID)) rate=\(rate) Hz channels=\(d.mChannelsPerFrame) sourceBits=\(sourceBitDepth(d)) length=\(file.length) frames (\(String(format: "%.3f", Double(file.length) / rate)) s)")
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else {
        print("  AVAudioFile: could not make a buffer"); return
    }
    var hasher = SHA256()
    var decoded: Int64 = 0
    var failure: Error?
    let start = ContinuousClock.now
    while file.framePosition < file.length {
        do { try file.read(into: buffer) } catch { failure = error; break }
        if buffer.frameLength == 0 { break }
        decoded += Int64(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            let p = buffer.floatChannelData![ch]
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: p, count: Int(buffer.frameLength) * 4))
        }
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
    let ending = failure.map { "; then FAILED \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? ""
    print("  AVAudioFile: decoded \(decoded) of \(file.length) frames in \(seconds(since: start)); float PCM sha256 \(digest)…\(ending)")
}

func probeAsset(_ url: URL) async {
    let asset = AVURLAsset(url: url)
    do {
        let (duration, playable, formats) = try await asset.load(.duration, .isPlayable, .availableMetadataFormats)
        print("  AVURLAsset: duration=\(String(format: "%.3f", duration.seconds)) s playable=\(playable) metadataFormats=\(formats.map(\.rawValue))")
        let common = try await asset.load(.commonMetadata)
        var described: [String] = []
        for item in common {
            let key = item.commonKey?.rawValue ?? "?"
            if let s = try? await item.load(.stringValue) { described.append("\(key)=\(s)") }
            else if let data = try? await item.load(.dataValue) { described.append("\(key)=<\(data.count) bytes>") }
            else { described.append("\(key)=<no value>") }
        }
        print("  AVURLAsset: commonMetadata [\(described.joined(separator: " | "))]")
        for format in formats {
            let items = try await asset.loadMetadata(for: format)
            var listed: [String] = []
            for item in items {
                let key = item.identifier?.rawValue ?? "?"
                if let s = try? await item.load(.stringValue) { listed.append("\(key)=\(s)") }
                else if let data = try? await item.load(.dataValue) { listed.append("\(key)=<\(data.count) bytes>") }
                else { listed.append("\(key)=<no value>") }
            }
            print("  AVURLAsset: \(format.rawValue) items [\(listed.joined(separator: " | "))]")
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { print("  AVAssetReader: no audio track"); return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        let start = ContinuousClock.now
        guard reader.startReading() else { print("  AVAssetReader: FAILED to start \(String(describing: reader.error))"); return }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        let status = reader.status == .completed ? "completed" : "status=\(reader.status.rawValue) error=\(String(describing: reader.error))"
        print("  AVAssetReader: decoded \(frames) frames in \(seconds(since: start)), \(status)")
    } catch {
        print("  AVURLAsset/AVAssetReader: FAILED \(error)")
    }
}

@MainActor
func probePlayers(_ url: URL) async {
    do {
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = 0
        let prepared = player.prepareToPlay()
        let started = player.play()
        try await Task.sleep(for: .milliseconds(400))
        print("  AVAudioPlayer: prepared=\(prepared) play=\(started) duration=\(String(format: "%.3f", player.duration)) s currentTime after 0.4 s=\(String(format: "%.3f", player.currentTime))")
        player.stop()
    } catch {
        print("  AVAudioPlayer: FAILED \(error)")
    }
    let item = AVPlayerItem(url: url)
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    for _ in 0..<50 where item.status == .unknown {
        try? await Task.sleep(for: .milliseconds(100))
    }
    if item.status == .readyToPlay {
        player.play()
        try? await Task.sleep(for: .milliseconds(400))
        print("  AVPlayer: readyToPlay, currentTime after 0.4 s=\(String(format: "%.3f", player.currentTime().seconds))")
        player.pause()
    } else {
        print("  AVPlayer: status=\(item.status.rawValue) error=\(String(describing: item.error))")
    }
}

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    print("== \(url.lastPathComponent)")
    probeAudioFile(url)
    await probeAsset(url)
    await probePlayers(url)
}
