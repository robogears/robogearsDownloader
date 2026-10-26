// Room on the download folder's disk, checked before each track.
//
// Decision 4, item 2.20: "the app checks for room before each track (about
// twice the track's estimated size to cover the temporary copy, roughly
// 330 MB for a 4-minute Hi-Res track) … When space runs out the batch stops
// once". The Electron app downloaded each track whole, failed to save it
// with "no space left on device", and moved on to fail the next one.
import Foundation

public enum DiskSpace {
    /// FLAC usually packs audio to well under its raw size; 0.7 is the
    /// generous end (2.20 asks for an estimate, not a promise).
    static let flacCompression = 0.7
    /// When TIDAL doesn't say what it's sending: 24-bit / 192 kHz stereo,
    /// the largest stream it offers, so the check errs on the side of room.
    static let unknownLosslessBytesPerSecond = 24.0 * 192_000 * 2 / 8 * flacCompression
    /// The AAC fallback is 320 kbps (rule 5).
    static let aacBytesPerSecond = 320_000.0 / 8
    /// A track TIDAL lists no length for is assumed to be this long.
    static let unknownDurationSeconds = 600

    /// The track's likely size on disk: its length times the stream's rate.
    /// For FLAC, bit depth × sample rate × channels × 0.7 when TIDAL said
    /// the bit depth and rate, a generous Hi-Res rate otherwise.
    public static func estimatedTrackBytes(
        durationSeconds: Int?, isFLAC: Bool, bitDepth: Int?, sampleRate: Int?, channels: Int = 2
    ) -> Int64 {
        let seconds = Double(durationSeconds.flatMap { $0 > 0 ? $0 : nil } ?? unknownDurationSeconds)
        let rate: Double
        if !isFLAC {
            rate = aacBytesPerSecond
        } else if let bitDepth, let sampleRate, bitDepth > 0, sampleRate > 0 {
            rate = Double(bitDepth) * Double(sampleRate) * Double(max(channels, 1)) / 8 * flacCompression
        } else {
            rate = unknownLosslessBytesPerSecond
        }
        return Int64((seconds * rate).rounded(.up))
    }

    /// About twice the track: the download and its tagged copy sit side by
    /// side in the temporary folder until the copy moves in (2.2, 2.20).
    public static func requiredFreeBytes(forTrackBytes trackBytes: Int64) -> Int64 {
        trackBytes * 2
    }

    /// How much more room is needed, or nil when there is enough (or the
    /// disk won't say how much it has).
    public static func shortfall(trackBytes: Int64, available: Int64?) -> Int64? {
        guard let available else { return nil }
        let needed = requiredFreeBytes(forTrackBytes: trackBytes)
        return available >= needed ? nil : needed - available
    }

    /// The room macOS says is free for files a person asked for, on the disk
    /// holding `url`. "Important usage" counts space macOS can free by
    /// clearing purgeable caches, as Finder does; nil when the disk won't say.
    @Sendable
    public static func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
