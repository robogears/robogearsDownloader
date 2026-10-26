import Foundation

/// Where a batch sends its sounds: the start chime once it has really
/// started, the cancel chime on Cancel, and the ending sound (2.8, 2.18).
/// Injected, so core logic never plays audio by itself and tests can
/// listen for which sound played when.
public protocol BatchSoundPlaying: Sendable {
    func play(_ effect: SoundEffect)
}

/// Hands each sound to the app's `SoundPlayer`, which honours the "Play
/// sound effects" setting (5.3).
public struct SoundPlayerSink: BatchSoundPlaying {
    private let player: SoundPlayer

    public init(_ player: SoundPlayer) {
        self.player = player
    }

    public func play(_ effect: SoundEffect) {
        let player = self.player
        Task { @MainActor in player.play(effect) }
    }
}
