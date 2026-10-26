// How a failure anywhere in one track's download becomes the row's reason.
//
// The Electron app turned every failure into one of a few raw strings, and
// a busy TIDAL read the same as a track not available in your country
// ("Could not get playback manifest at any quality.", download-pipeline.md
// bug 11). Decision 4 asks for plain reasons (1.4), one batch stop for the
// problems every track shares (2.1) and a pause when offline (1.7); this
// maps each error to the `TrackDownloadError` that says so.
import Foundation

/// The step a failure happened in, which decides what a temporary error
/// means: album details and cover art have their own reasons (2.15).
enum TrackDownloadStep: Sendable {
    case details, album, playback, audio, cover, saving
}

enum TrackDownloadFailures {
    /// Plain reasons for `notAvailable`, shown after "Failed: ".
    static let trackGone = "TIDAL no longer has this track"
    static let trackRefused = "TIDAL refused this track"
    static let streamRefused = "TIDAL refused this stream"
    static let notInCountry = "Not available in your country"
    static let unreadableAnswer = "TIDAL's answer couldn't be read"
    static let streamLinkFailed = "TIDAL's stream link stopped working. Retry to download it again"
    static let copyProtected = "TIDAL sent this track with copy protection"
    static let noUsableStream = "TIDAL didn't send a usable stream"
    static let unsupportedStream = "TIDAL sent a stream format the app can't read"

    /// The error to throw for `error`, raised during `step`. Cancellation
    /// and errors already in the row's terms pass through unchanged.
    static func mapped(_ error: any Error, during step: TrackDownloadStep) -> any Error {
        if error is CancellationError { return error }
        if let error = error as? TrackDownloadError { return error }
        if let error = error as? TokenError { return mapped(error) }
        if let error = error as? RequestError { return mapped(error, during: step) }
        if let error = error as? TIDALManifestError { return mapped(error) }
        if let error = error as? FLACFormatError { return TrackDownloadError.unreadableAudio(detail: "\(error)") }
        if let error = error as? TemporaryDownloads.Failure {
            switch error {
            case let .noTemporaryFolder(detail), let .listNotSaved(detail):
                return TrackDownloadError.writeFailed(detail: detail)
            }
        }
        return TrackDownloadError.writeFailed(detail: String(describing: error))
    }

    /// Every sign-in problem stops the batch once (1.6). A sign-in store
    /// that can't be read also lands here: every remaining track would hit
    /// it, and signing in again replaces the unreadable item (1.5).
    static func mapped(_ error: TokenError) -> TrackDownloadError {
        .signInRejected
    }

    static func mapped(_ error: RequestError, during step: TrackDownloadStep) -> TrackDownloadError {
        switch error {
        case .busy, .server:
            switch step {
            case .album: return .albumDetailsUnavailable
            case .cover: return .coverUnavailable
            default: return .busy
            }
        case let .offline(detail):
            // A timeout that outlasts the retries is one of 2.15's
            // "temporary problems" for the cover and the album; everything
            // else that reads as offline pauses the batch (1.7).
            if detail == RequestError.offlineDetail(for: .timedOut) {
                if step == .album { return .albumDetailsUnavailable }
                if step == .cover { return .coverUnavailable }
            }
            return .offline
        case .unauthorized:
            return .signInRejected
        case .notFound:
            switch step {
            case .details: return .notAvailable(reason: trackGone)
            case .audio: return .notAvailable(reason: streamLinkFailed)
            case .album: return .albumDetailsUnavailable
            case .cover: return .coverUnavailable
            default: return .notAvailable(reason: streamRefused)
            }
        case .forbidden, .unexpectedStatus:
            switch step {
            case .details: return .notAvailable(reason: trackRefused)
            case .audio: return .notAvailable(reason: streamLinkFailed)
            case .album: return .albumDetailsUnavailable
            case .cover: return .coverUnavailable
            default: return .notAvailable(reason: streamRefused)
            }
        case .decoding:
            switch step {
            case .album: return .albumDetailsUnavailable
            case .audio: return .unreadableAudio(detail: error.description)
            default: return .notAvailable(reason: unreadableAnswer)
            }
        }
    }

    static func mapped(_ error: TIDALManifestError) -> TrackDownloadError {
        switch error {
        case .copyProtected:
            .notAvailable(reason: copyProtected)
        case .missingManifest, .noStreamURL, .invalidStreamURL, .unreadableEncoding, .unreadableManifest:
            .notAvailable(reason: noUsableStream)
        case .unsupportedType, .missingSegmentTemplate, .noSegments, .openEndedTimeline, .unsupportedTemplate, .tooManySegments:
            .notAvailable(reason: unsupportedStream)
        }
    }

    /// True for TIDAL's clear "no": a 404, a 403 or another 4xx other than
    /// 401 and 429. That is an answer, not a hiccup, so the retries never
    /// ran and trying again won't change it. For the album details it means
    /// "Saved with limited tags": 2.15 fails a track only when timeouts,
    /// server errors or "too many requests" outlast the retries.
    static func isClearRefusal(_ error: RequestError) -> Bool {
        switch error {
        case .notFound, .forbidden: true
        case let .unexpectedStatus(status, _): (400...499).contains(status)
        default: false
        }
    }

    /// True when writing failed because the disk is full.
    static func isOutOfSpace(_ error: any Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }
}
