// The shapes the download pipeline is built from: one track's request and
// result, the errors that fail a row or stop a batch, and the two seams the
// pieces meet at (the per-track downloader and the AAC writer). Written
// first so the track pipeline, the AAC writer and the batch runner could be
// built side by side; each implementation lives in its own file.
//
// Decision 4, area 2 (docs/D4_BEHAVIOUR_DECISIONS.md) sets the behaviour;
// item numbers below refer to it.
import Foundation

// MARK: - One track

/// Everything one download needs, copied from a queue row when the batch
/// starts, so later edits to the row can't change a download in flight.
public struct TrackDownloadRequest: Sendable, Equatable {
    public var rowID: UUID
    public var tidalID: Int64
    /// TIDAL's bare title, without the version (2.7).
    public var title: String
    /// The edition, for example "Radio Edit" (2.7).
    public var version: String?
    /// The artist line the row shows.
    public var artist: String
    public var album: String?
    /// TIDAL's length in seconds, when the row knows it.
    public var durationSeconds: Int?
    public var isrc: String?
    /// The row showed the Hi-Res badge; saving below it is flagged (2.21).
    public var expectsHiRes: Bool
    /// The folder the batch started with; a batch keeps it to the end (2.17).
    public var folder: URL
    /// The person chose Replace on a damaged existing file (2.3): the old
    /// file goes to the Trash before the new one is saved.
    public var replaceExisting: Bool

    public init(rowID: UUID, tidalID: Int64, title: String, version: String? = nil, artist: String,
                album: String? = nil, durationSeconds: Int? = nil, isrc: String? = nil,
                expectsHiRes: Bool = false, folder: URL, replaceExisting: Bool = false) {
        self.rowID = rowID
        self.tidalID = tidalID
        self.title = title
        self.version = version
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.isrc = isrc
        self.expectsHiRes = expectsHiRes
        self.folder = folder
        self.replaceExisting = replaceExisting
    }
}

/// The quality actually saved, for the row's "Saved" line (2.21).
public enum SavedQuality: Codable, Sendable, Equatable {
    /// A FLAC; Hi-Res when deeper than 16 bits or faster than 48 kHz.
    case flac(bitDepth: Int, sampleRate: Int)
    /// The lossy fallback (2.10).
    case aac

    public var isHiRes: Bool {
        if case let .flac(bits, rate) = self { return bits > 16 || rate > 48_000 }
        return false
    }

    /// "24-bit / 96 kHz", "16-bit / 44.1 kHz" or "AAC".
    public var label: String {
        switch self {
        case .aac:
            return "AAC"
        case let .flac(bits, rate):
            let khz = Double(rate) / 1000
            let rateText = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            return "\(bits)-bit / \(rateText) kHz"
        }
    }
}

/// Things worth saying about a saved file; the batch summary counts them (2.8).
public enum SaveNote: Codable, Sendable, Equatable, Hashable {
    /// Saved as .m4a because TIDAL has no lossless version (2.10).
    case savedAsAAC
    /// A different song already had the plain name (2.6).
    case savedUnderAnotherName(takenName: String)
    /// TIDAL has no cover for the album (2.15).
    case withoutCoverArt
    /// The album details were missing; the track's own were used (2.15).
    case limitedTags
    /// The row showed Hi-Res but TIDAL clearly had only CD quality (2.21).
    case belowHiRes
    /// A FLAC was saved next to an older .m4a of the same song (2.10).
    case savedNextToAAC(aacName: String)
}

/// How a track download ended without an error.
public enum TrackDownloadOutcome: Sendable, Equatable {
    case saved(fileName: String, quality: SavedQuality, notes: [SaveNote])
    /// The same recording is already in the download folder and looks
    /// healthy (2.3, 2.6, 2.16).
    case alreadyInFolder(fileName: String)
    /// A file that would be skipped looks damaged; it stays untouched and
    /// the row offers Show in Finder and Replace (2.3).
    case existingLooksDamaged(fileName: String)
    /// A file with the plain name exists, but its title and artist can't be
    /// read, so it can't be told apart from this song; the row stays with
    /// Save As… (2.6's fallback for untagged files).
    case nameTakenByUnreadableFile(fileName: String)
}

// MARK: - Errors

/// Why a track didn't download. `stopsBatch` errors end the whole batch once
/// with one notice instead of failing every remaining row (2.1).
public enum TrackDownloadError: Error, Sendable, Equatable {
    // Problems shared by every remaining track: the batch stops once.
    /// TIDAL no longer accepts the sign-in, even after one renewal (1.6).
    case signInRejected
    /// The subscription isn't active, or TIDAL sends only previews on the
    /// first track of a batch (1.10, 2.23).
    case subscriptionInactive
    /// The download folder is missing, in the Trash or on an unplugged
    /// drive (2.19); the message says which and what to do.
    case folderUnavailable(message: String)
    /// Not enough room; `bytesNeeded` is the shortfall to report (2.20).
    case diskFull(bytesNeeded: Int64)
    /// No internet, or a login page such as a hotel's: the batch pauses
    /// rather than stopping, and the row goes back to waiting (1.7).
    case offline

    // Problems with this track only.
    /// TIDAL sent a preview clip instead of the full track (2.23).
    case previewOnly
    /// TIDAL won't stream it here, for example "Not available in your country".
    case notAvailable(reason: String)
    /// TIDAL stayed busy (429) or failing (5xx) past the retries (1.4).
    case busy
    /// The saved audio isn't as long as TIDAL lists, or doesn't decode to its
    /// own declared end (2.2).
    case lengthMismatch(fileSeconds: Double, tidalSeconds: Double?)
    /// The download couldn't be read as audio at all.
    case unreadableAudio(detail: String)
    /// Temporary errors outlasted the retries for the cover or album (2.15).
    case coverUnavailable
    case albumDetailsUnavailable
    /// Writing the file failed for another reason; `detail` goes to the
    /// activity log, never into the row.
    case writeFailed(detail: String)

    /// True for the problems every remaining track would hit.
    public var stopsBatch: Bool {
        switch self {
        case .signInRejected, .subscriptionInactive, .folderUnavailable, .diskFull: true
        default: false
        }
    }

    /// True when the batch should wait for the network instead of failing.
    public var pausesBatch: Bool { self == .offline }

    /// The row's text, in plain words with what to do next.
    public var rowMessage: String {
        switch self {
        case .signInRejected:
            "Failed: your TIDAL sign-in is no longer valid. Sign in again, then Retry."
        case .subscriptionInactive:
            "Failed: TIDAL sent only a preview. Check that your TIDAL subscription is active, then Retry."
        case let .folderUnavailable(message):
            message
        case let .diskFull(bytes):
            "Failed: the disk with your download folder is full (about \(Self.megabytes(bytes)) more needed)."
        case .offline:
            "Waiting for an internet connection…"
        case .previewOnly:
            "Failed: TIDAL sent only a preview. Check that your TIDAL subscription is active, then Retry."
        case let .notAvailable(reason):
            "Failed: \(reason)"
        case .busy:
            "Failed: TIDAL is busy. Try again in a few minutes."
        case let .lengthMismatch(file, tidal):
            if let tidal {
                "Failed: the file is \(Self.clock(file)) but TIDAL lists \(Self.clock(tidal)). Retry to download it again."
            } else {
                "Failed: the download stopped early. Retry to download it again."
            }
        case .unreadableAudio:
            "Failed: TIDAL's audio couldn't be read. Retry to download it again."
        case .coverUnavailable:
            "Failed: TIDAL didn't send the cover art. Retry to try again."
        case .albumDetailsUnavailable:
            "Failed: TIDAL didn't return the album details. Retry to try again."
        case .writeFailed:
            "Failed: the file couldn't be saved. Retry to try again."
        }
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(max(1, (bytes + 999_999) / 1_000_000)) MB"
    }

    /// "3:12"; lengths of an hour or more as "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Seams

/// Downloads, checks and saves one track. The batch runner talks only to
/// this, so its tests use a stand-in and never touch the network.
public protocol TrackDownloading: Sendable {
    /// `progress` gets 0…1 as audio arrives. Cancelling the task stops the
    /// download and tagging at once and deletes the temporary file (2.4);
    /// it then throws `CancellationError`.
    func download(_ request: TrackDownloadRequest,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> TrackDownloadOutcome
}

/// What an AAC write produced.
public struct M4AWriteResult: Sendable, Equatable {
    /// The audio's length, from the written file's own sample count.
    public var durationSeconds: Double
    public init(durationSeconds: Double) { self.durationSeconds = durationSeconds }
}

/// Turns a downloaded AAC stream (a plain MP4, or the joined segments of a
/// fragmented one) into a tagged .m4a with its cover, without FFmpeg.
public protocol M4AWriting: Sendable {
    /// Creates `destination` exclusively (never replaces a file) and removes
    /// its own partial file if writing fails. Tags use the same fields as
    /// the FLAC writer.
    func writeM4A(from source: URL, tags: FLACTags, coverJPEG: Data?, to destination: URL) async throws -> M4AWriteResult
}
