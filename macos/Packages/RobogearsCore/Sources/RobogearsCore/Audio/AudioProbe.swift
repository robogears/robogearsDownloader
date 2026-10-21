// What macOS's own decoder makes of an audio file.
//
// The spike (docs/spikes/audio-and-tagging.md, part a) found that
// AVAudioFile decodes native FLAC at 16 and 24 bit, and AAC, but can't
// decode a FLAC whose STREAMINFO leaves the sample count at 0. Decision card
// G2-2 (recommended option) wants every finished file checked before it is
// moved into the download folder: does it play to the end, and is it as
// long as it says? This answers both with Apple's decoder, no FFmpeg.
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

        /// True when the whole file decoded and matched its declared length.
        public var decodedToTheEnd: Bool {
            decodeError == nil && decodedFrames == declaredFrames && declaredFrames > 0
        }

        public var declaredDuration: Double { sampleRate > 0 ? Double(declaredFrames) / sampleRate : 0 }
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
