import AVFoundation
import Foundation

/// The bars of a row's waveform: the loudest sample in each of 200 equal
/// slices of the track, scaled so the loudest bar is exactly 1. The same
/// downsample-by-max and normalising as the Electron renderer
/// (flow-import-and-preview.md, "Waveform"; DESIGN_DIRECTION 3.4), done
/// natively from a file instead of from Web Audio's decoded buffer.
public enum WaveformPeaks {
    public static let barCount = 200

    public enum PeaksError: Error, Sendable, Equatable {
        /// AVFoundation couldn't open or decode the file.
        case unreadable(String)
        /// The file holds no audio frames.
        case empty
    }

    /// Reads the whole file in chunks (never the whole track in memory) and
    /// returns `bars` values in 0…1. All zeros for pure silence. Checks for
    /// cancellation between chunks, so a preview that is no longer wanted
    /// stops decoding at once (D4 5.16).
    public static func compute(from url: URL, bars: Int = barCount) throws -> [Float] {
        precondition(bars > 0)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw PeaksError.unreadable(error.localizedDescription) }
        let length = file.length
        guard length > 0 else { throw PeaksError.empty }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw PeaksError.unreadable("no buffer for \(format)")
        }

        var peaks = [Float](repeating: 0, count: bars)
        var frameIndex: AVAudioFramePosition = 0
        while frameIndex < length {
            if Task.isCancelled { throw CancellationError() }
            do { try file.read(into: buffer, frameCount: chunk) } catch {
                // A file can declare more frames than it holds (a joined DASH
                // download, spike part a); keep what was read.
                if frameIndex > 0 { break }
                throw PeaksError.unreadable(error.localizedDescription)
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { throw PeaksError.unreadable("not float audio") }
            for frame in 0..<frames {
                var loudest: Float = 0
                for channel in 0..<Int(format.channelCount) {
                    loudest = max(loudest, abs(channels[channel][frame]))
                }
                let bar = min(bars - 1, Int((frameIndex + AVAudioFramePosition(frame)) * AVAudioFramePosition(bars) / length))
                if loudest > peaks[bar] { peaks[bar] = loudest }
            }
            frameIndex += AVAudioFramePosition(frames)
        }
        return normalized(peaks)
    }

    /// Scales so the loudest is exactly 1; silence stays all zeros.
    public static func normalized(_ peaks: [Float]) -> [Float] {
        guard let top = peaks.max(), top > 0 else { return peaks.map { _ in 0 } }
        return peaks.map { min(1, $0 / top) }
    }

    /// One byte per bar, for the on-disk store (under 1 KB a track, D4 5.1).
    public static func encode(_ peaks: [Float]) -> Data {
        Data(peaks.map { UInt8((min(1, max(0, $0)) * 255).rounded()) })
    }

    public static func decode(_ data: Data) -> [Float] {
        data.map { Float($0) / 255 }
    }
}
