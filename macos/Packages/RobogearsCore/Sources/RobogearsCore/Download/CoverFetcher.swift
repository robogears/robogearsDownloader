// The album cover for a download (decision 4, item 2.15).
//
// The Electron app tried the 1280 px cover twice and saved the file without
// art on any failure, silently (download-pipeline.md C4 `fetchCover`). Now a
// cover is retried like the audio, smaller sizes are tried when the large
// one isn't there, and a track is saved without art only when TIDAL really
// has none: "none listed, or 'not found' at every size". A cover that keeps
// failing for a temporary reason fails the track instead, so Retry can get
// it later (skip-if-exists would otherwise keep the bare copy for good).
import Foundation

struct CoverFetcher: Sendable {
    /// Largest first. Which smaller sizes TIDAL serves needs a live check (2.15).
    static let sizes = [1280, 640, 320]

    let client: HTTPClient
    let retry: RetryPolicy
    let log: @Sendable (String) -> Void

    /// The cover's JPEG bytes, or nil with `.withoutCoverArt` when TIDAL has
    /// none. Throws `coverUnavailable` when temporary errors outlast the
    /// retries, `offline` when the network is gone (1.7).
    func fetch(coverOf album: TIDALAlbum?) async throws -> (jpeg: Data?, notes: [SaveNote]) {
        guard let album, album.coverURL(size: Self.sizes[0]) != nil else {
            log("TIDAL lists no cover for this album; saving without cover art.")
            return (nil, [.withoutCoverArt])
        }
        for size in Self.sizes {
            guard let url = album.coverURL(size: size) else { break }
            let response: HTTPResponse
            do {
                response = try await client.send(AudioFetcher.request(url), retry: retry)
                if let interference = response.networkInterference(expecting: .data) { throw interference }
            } catch {
                throw TrackDownloadFailures.mapped(error, during: .cover)
            }
            switch response.status {
            case 200:
                // Only a JPEG can be the front cover (the Electron app fed
                // FFmpeg `-f mjpeg`); anything else counts as no cover.
                guard (try? FLACPicture.frontCover(jpeg: response.body)) != nil else {
                    log("TIDAL's cover for this album isn't a JPEG image; saving without cover art.")
                    return (nil, [.withoutCoverArt])
                }
                return (response.body, [])
            case 400...499:
                // "Not found" at this size: the next smaller one may exist.
                continue
            default:
                throw TrackDownloadFailures.mapped(RequestError.unexpectedStatus(response.status, subStatus: nil), during: .cover)
            }
        }
        log("TIDAL has no cover image at any size for this album; saving without cover art.")
        return (nil, [.withoutCoverArt])
    }
}
