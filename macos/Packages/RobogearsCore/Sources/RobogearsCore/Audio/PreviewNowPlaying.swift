import AppKit
import Foundation
import MediaPlayer

/// Shows the playing preview in Control Center's Now Playing and lets the
/// play/pause key control it (D4 5.13). When the preview stops, the app
/// steps back and the key goes to Music again.
@MainActor
public final class PreviewNowPlaying {
    /// What Control Center shows for one preview.
    public struct Info: Equatable, Sendable {
        public var title: String
        public var artist: String
        public var duration: TimeInterval
        public var elapsed: TimeInterval
        public var isPlaying: Bool

        public init(title: String, artist: String, duration: TimeInterval, elapsed: TimeInterval, isPlaying: Bool) {
            self.title = title
            self.artist = artist
            self.duration = duration
            self.elapsed = elapsed
            self.isPlaying = isPlaying
        }
    }

    public enum Command: Sendable { case play, pause, toggle, stop }

    private let center: MPNowPlayingInfoCenter
    private let commands: MPRemoteCommandCenter
    private var handler: (@MainActor (Command) -> Void)?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artwork: MPMediaItemArtwork?

    public init(center: MPNowPlayingInfoCenter = .default(), commands: MPRemoteCommandCenter = .shared()) {
        self.center = center
        self.commands = commands
    }

    /// Takes over the play/pause key; `handler` gets every command.
    public func activate(_ handler: @escaping @MainActor (Command) -> Void) {
        self.handler = handler
        guard targets.isEmpty else { return }
        let pairs: [(MPRemoteCommand, Command)] = [
            (commands.playCommand, .play), (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .toggle), (commands.stopCommand, .stop),
        ]
        for (remote, command) in pairs {
            remote.isEnabled = true
            let token = remote.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.handler?(command) }
                return .success
            }
            targets.append((remote, token))
        }
    }

    /// Updates title, artist, length, position and play state.
    public func update(_ info: Info) {
        var dictionary = Self.dictionary(for: info)
        if let artwork { dictionary[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = dictionary
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    /// The small cover, fetched only while a preview plays (D4 5.13).
    public func setCover(_ image: NSImage?) {
        artwork = image.map { image in MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        if var dictionary = center.nowPlayingInfo {
            dictionary[MPMediaItemPropertyArtwork] = artwork
            center.nowPlayingInfo = dictionary
        }
    }

    /// The preview stopped: clear Now Playing and give the key back.
    public func deactivate() {
        for (remote, token) in targets {
            remote.removeTarget(token)
            remote.isEnabled = false
        }
        targets.removeAll()
        handler = nil
        artwork = nil
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// The Now Playing fields for `info`, kept separate so the rule is testable.
    nonisolated public static func dictionary(for info: Info) -> [String: Any] {
        [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyPlaybackDuration: info.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(0, info.elapsed), info.duration),
            MPNowPlayingInfoPropertyPlaybackRate: info.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }
}
