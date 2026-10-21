import AVFoundation

/// Plays the app's sound effects. Each sound is rendered once and cached;
/// playing never throws into the caller, so a sound can't stop the action it
/// accompanies (in the Electron app every sound ran before its action and a
/// failure there would have blocked it — waveform-preview-and-sounds.md A1).
@MainActor
public final class SoundPlayer {
    /// The "Play sound effects" switch in Settings (decision 4, item 5.3).
    public var isEnabled = true

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var buffers: [SoundEffect: AVAudioPCMBuffer] = [:]
    private let format: AVAudioFormat

    /// Overlapping sounds (a chime right after a honk) each get their own
    /// player node; four is more than any real sequence needs.
    private let voiceCount = 4

    public init() {
        format = AVAudioFormat(standardFormatWithSampleRate: SoundSynth.defaultSampleRate, channels: 1)!
    }

    public func play(_ effect: SoundEffect) {
        guard isEnabled, let buffer = buffer(for: effect) else { return }
        guard startEngineIfNeeded() else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
    }

    private func buffer(for effect: SoundEffect) -> AVAudioPCMBuffer? {
        if let cached = buffers[effect] { return cached }
        let samples = SoundSynth.render(effect, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffers[effect] = buffer
        return buffer
    }

    private func startEngineIfNeeded() -> Bool {
        if players.isEmpty {
            for _ in 0..<voiceCount {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: format)
                players.append(node)
            }
        }
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            // No output device (or it is busy): stay silent rather than fail.
            return false
        }
    }
}
