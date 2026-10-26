// What macOS's own decoder makes of an audio file.
//
// The spike (docs/spikes/audio-and-tagging.md, part a) found that
// AVAudioFile decodes native FLAC at 16 and 24 bit, and AAC, but can't
// decode a FLAC whose STREAMINFO leaves the sample count at 0. Decision card
// G2-2 (recommended option) wants every finished file checked before it is
// moved into the download folder: does it play to the end, and is it as
// long as it says? Card G2-2b wants the old app's files checked before they
// are trusted. This answers both with Apple's decoder, no FFmpeg, as far as
// a file that states its length allows (see `Verdict.lengthUnknown`).
import AVFoundation
import Foundation

public enum AudioProbe {
    public struct Report: Sendable, Equatable {
        /// Core Audio's four-character format code, such as "flac" or "aac ".
        public var formatID: String
        public var sampleRate: Double
        public var channelCount: Int
        /// The source's bit depth: from the PCM description, or for FLAC and
        /// ALAC from Apple's 16/20/24/32-bit source flags. Nil for lossy formats.
        public var sourceBitDepth: Int?
        /// The length the file declares, in sample frames.
        public var declaredFrames: Int64
        /// Frames actually decoded, when a decode was asked for.
        public var decodedFrames: Int64?
        /// Why decoding stopped early, when it did.
        public var decodeError: String?

        /// What the decode says about the file. Nil when no decode was asked for.
        public var verdict: Verdict? {
            guard let decodedFrames else { return nil }
            if declaredFrames == 0 { return .lengthUnknown }
            return decodeError == nil && decodedFrames == declaredFrames ? .complete : .short
        }

        /// True only for `Verdict.complete`. False is not a damage verdict on
        /// its own: with `declaredFrames` 0 it means "can't judge", so read
        /// `verdict` before telling anyone a file looks damaged (card G2-2b).
        public var decodedToTheEnd: Bool { verdict == .complete }

        public var declaredDuration: Double { sampleRate > 0 ? Double(declaredFrames) / sampleRate : 0 }
    }

    /// Three answers, because "didn't decode to the end" has two causes that
    /// must never be shown the same way (review of the spike, 21 Oct 2026).
    public enum Verdict: Sendable, Equatable {
        /// Every frame the file declares decoded.
        case complete
        /// Decoding stopped before the declared length: the file is cut off
        /// or damaged. A joined DASH download (fragmented MP4) lands here
        /// too although it's whole, because AVAudioFile rounds its length up
        /// to whole frames (spike part a); the probe is for finished files,
        /// and a download's own check is `FLACAudio.sampleCountMatches`.
        case short
        /// The file doesn't say how long it is: a FLAC whose STREAMINFO
        /// sample count is 0, which FFmpeg copied from live-packaged DASH
        /// sources into Electron-era Hi-Res files. AVFoundation decodes
        /// nothing from such a file, whole or cut off, so this is "can't
        /// judge", never "damaged" (the healthy fixture
        /// ffmpeg-dash-live-16-44100.flac lands here). Judging these needs a
        /// native frame walk: find each frame by its sync code and header
        /// CRC-8, check its CRC-16 footer, sum the block sizes, and compare
        /// the total with TIDAL's duration. Not built yet.
        case lengthUnknown
    }

    /// Opens the file with AVAudioFile and, when `decode` is true, decodes
    /// every frame. A file AVAudioFile can't open throws.
    public static func inspect(_ url: URL, decode: Bool = true) throws -> Report {
        let file = try AVAudioFile(forReading: url)
        let description = file.fileFormat.streamDescription.pointee
        var report = Report(
            formatID: fourCC(description.mFormatID),
            sampleRate: file.fileFormat.sampleRate,
            channelCount: Int(description.mChannelsPerFrame),
            sourceBitDepth: sourceBitDepth(description),
            declaredFrames: file.length
        )
        guard decode else { return report }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 16) else {
            report.decodedFrames = 0
            report.decodeError = "no buffer"
            return report
        }
        var decoded: Int64 = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                report.decodeError = String(describing: error)
                break
            }
            if buffer.frameLength == 0 { break }
            decoded += Int64(buffer.frameLength)
        }
        report.decodedFrames = decoded
        return report
    }

    static func fourCC(_ code: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }, as: UTF8.self)
    }

    /// kAppleLosslessFormatFlag_16/20/24/32BitSourceData are 1 to 4, and
    /// Apple's FLAC decoder reports FLAC's bit depth the same way.
    static func sourceBitDepth(_ d: AudioStreamBasicDescription) -> Int? {
        if d.mBitsPerChannel > 0 { return Int(d.mBitsPerChannel) }
        guard d.mFormatID == kAudioFormatFLAC || d.mFormatID == kAudioFormatAppleLossless else { return nil }
        switch d.mFormatFlags {
        case 1: return 16
        case 2: return 20
        case 3: return 24
        case 4: return 32
        default: return nil
        }
    }
}
