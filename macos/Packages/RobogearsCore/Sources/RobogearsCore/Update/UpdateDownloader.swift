import Foundation

/// Streams an update to disk with every hop pinned to GitHub's hosts, a byte
/// cap and integer-percent progress (recipe §6). The session's own temporary
/// file plays the ".part" role: the download only gets its final name once
/// it has finished, so a cut-short file is never mistaken for a whole one.
public final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let overridesAllowed: Bool
    private let byteCap: Int64
    private let progress: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastPercent = -1
    private var movedFile: URL?
    private var moveError: Error?

    /// - Parameters:
    ///   - destination: final path of the downloaded zip.
    ///   - advertisedSize: the asset size from the release; it rides the same
    ///     channel as the file, so the cap is clamped between 500 MB and 2 GB.
    public init(destination: URL, advertisedSize: Int64, overridesAllowed: Bool,
                progress: @escaping @Sendable (Int) -> Void) {
        self.destination = destination
        self.overridesAllowed = overridesAllowed
        self.byteCap = min(max(Int64(Double(advertisedSize) * 1.1), 500_000_000), 2_000_000_000)
        self.progress = progress
    }

    public func download(from url: URL) async throws -> URL {
        guard UpdateAssets.isAllowedDownloadURL(url, overridesAllowed: overridesAllowed) else {
            throw UpdateInstallError.download("the download link isn't on GitHub")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                lock.withLock { continuation = c }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let url = request.url, UpdateAssets.isAllowedDownloadURL(url, overridesAllowed: overridesAllowed) {
            completionHandler(request)
        } else {
            completionHandler(nil)   // refuse an off-GitHub redirect
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > byteCap {
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        let changed = lock.withLock { () -> Bool in
            guard percent != lastPercent else { return false }
            lastPercent = percent
            return true
        }
        if changed { progress(percent) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // The temporary file is deleted as soon as this returns: move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            lock.withLock { moveError = UpdateInstallError.download("GitHub answered \(http.statusCode)") }
            return
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
            lock.withLock { movedFile = destination }
        } catch {
            lock.withLock { moveError = UpdateInstallError.download(error.localizedDescription) }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, moved, moveError) = lock.withLock { () -> (CheckedContinuation<URL, Error>?, URL?, Error?) in
            defer { continuation = nil }
            return (continuation, movedFile, self.moveError)
        }
        guard let c else { return }
        if let moved, error == nil, moveError == nil {
            c.resume(returning: moved)
        } else if let moveError {
            c.resume(throwing: moveError)
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            c.resume(throwing: UpdateInstallError.download("it was stopped or grew larger than expected"))
        } else {
            c.resume(throwing: UpdateInstallError.download(error?.localizedDescription ?? "unknown error"))
        }
    }
}
