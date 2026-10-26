// Fetches a track's audio into a file, as it arrives.
//
// Download-pipeline.md B8 and B9: a BTS manifest (and a DASH one with only a
// BaseURL) gives one direct URL; a DASH manifest gives an init segment and
// numbered media segments that join, in order, into one fragmented MP4.
// The Electron app held every DASH segment in memory and wrote the track in
// one go, didn't retry the direct download, and let failed segment workers
// keep fetching (bugs 10 and 13). Here both kinds stream to disk (2.20), each
// request goes through the shared retry rule (1.4), and cancelling stops
// every request at once (2.4, 2.13).
import Foundation
import Synchronization

struct AudioFetcher: Sendable {
    /// At most this many segments are fetched at once, as today (B8).
    static let segmentsInFlight = 8
    /// How far ahead of the next segment to write a fetch may run, so a
    /// slow segment can't make the reorder buffer hold the whole track.
    static let readAhead = 24

    let client: HTTPClient
    let retry: RetryPolicy

    /// The CDN gets the User-Agent `fetchBuffer` and `downloadDirect` sent
    /// (reference C2), and asks for the body uncompressed. Node sent no
    /// Accept-Encoding, which means exactly that; URLSession would otherwise
    /// offer gzip on its own, and a compressed body can't be measured
    /// against its Content-Length to catch a cut-off transfer. As `.media`,
    /// redirects are followed as today, and an error answer is judged by
    /// its status, whatever its body.
    static func request(_ url: URL) -> HTTPRequest {
        HTTPRequest(method: .get, url: url, headers: [
            "User-Agent": TIDALHeaders.userAgent,
            "Accept-Encoding": "identity",
        ], expectedBody: .media)
    }

    /// Writes the audio at `location` to a new file at `file`. `progress`
    /// gets 0…1: bytes against `Content-Length` (or `estimatedBytes` when
    /// the server sends none) for one file, segments done for DASH.
    func fetch(
        _ location: TIDALManifest.Location, to file: URL, estimatedBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        switch location {
        case let .direct(url):
            try await fetchDirect(url, to: file, estimatedBytes: estimatedBytes, progress: progress)
        case let .segments(initialization, media):
            try await fetchSegments([initialization] + media, to: file, progress: progress)
        }
        progress(1)
    }

    private func fetchDirect(
        _ url: URL, to file: URL, estimatedBytes: Int64, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let response = try await client.download(Self.request(url), to: file, retry: retry) { received, expected in
            // Without a Content-Length, the estimate moves the bar; it stops
            // just short of the end until the transfer really ends.
            if let expected, expected > 0 {
                progress(Double(received) / Double(expected))
            } else if estimatedBytes > 0 {
                progress(min(Double(received) / Double(estimatedBytes), 0.99))
            }
        }
        try Self.requireAudio(response)
    }

    /// A 200 that is audio, or the error saying why not. A web page where
    /// audio was expected is a network sign-in page (1.7). An error answer
    /// is the CDN's own, so an expired link answered with an XML 403 or an
    /// HTML 404 fails the track as a stream link that stopped working,
    /// never as offline, which would pause the batch for good while online.
    static func requireAudio(_ response: HTTPResponse) throws {
        _ = try response.requireOK(expecting: .media)
    }

    /// Fetches up to eight segments at once and writes them strictly in
    /// order through a small reorder buffer. The first failure cancels the
    /// rest (the task group's rule), so nothing keeps fetching for a track
    /// that has already failed (bug 13).
    private func fetchSegments(_ urls: [URL], to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        let client = self.client, retry = self.retry
        let total = urls.count
        try await withThrowingTaskGroup(of: (index: Int, data: Data).self) { group in
            var nextToStart = 0
            var nextToWrite = 0
            var inFlight = 0
            var finished = 0
            var waiting: [Int: Data] = [:]

            func startMore(_ group: inout ThrowingTaskGroup<(index: Int, data: Data), any Error>) {
                while inFlight < Self.segmentsInFlight, nextToStart < total, nextToStart < nextToWrite + Self.readAhead {
                    let index = nextToStart, url = urls[index]
                    group.addTask {
                        let response = try await client.send(Self.request(url), retry: retry)
                        try Self.requireAudio(response)
                        return (index, response.body)
                    }
                    nextToStart += 1
                    inFlight += 1
                }
            }

            startMore(&group)
            while let (index, data) = try await group.next() {
                inFlight -= 1
                finished += 1
                waiting[index] = data
                while let ready = waiting.removeValue(forKey: nextToWrite) {
                    try handle.write(contentsOf: ready)
                    nextToWrite += 1
                }
                progress(Double(finished) / Double(total))
                startMore(&group)
            }
        }
        try handle.synchronize()
    }
}

/// Passes progress on only when the whole percentage goes up, so a row
/// redraws at most a hundred times per track, and never moves backwards
/// when a dropped transfer starts again.
final class ProgressThrottle: Sendable {
    private let lastPercent = Mutex(-1)
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) {
        self.report = report
    }

    func update(_ fraction: Double) {
        guard fraction.isFinite else { return }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        let isNew = lastPercent.withLock { last -> Bool in
            guard percent > last else { return false }
            last = percent
            return true
        }
        if isNew { report(Double(percent) / 100) }
    }
}
