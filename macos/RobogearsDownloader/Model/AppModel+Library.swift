import AppKit
import RobogearsCore

/// The library index as Settings › Folders shows it (4.12).
enum LibraryStatus: Equatable, Sendable {
    /// No library folder: the duplicate check is off.
    case none
    case scanning(done: Int, total: Int)
    case indexed(files: Int)
    /// The folder can't be read; the sentence says what to do.
    case unavailable(String)

    var text: String {
        switch self {
        case .none: "No library folder: the duplicate check is off."
        case .scanning(let done, let total):
            total > 0 ? "Scanning \(Formatting.count(done)) / \(Formatting.count(total))…" : "Scanning…"
        case .indexed(let files): files == 1 ? "1 file indexed" : "\(Formatting.count(files)) files indexed"
        case .unavailable(let message): message
        }
    }

    var isScanning: Bool { if case .scanning = self { true } else { false } }
}

/// A folder choice Settings refused, shown under that folder.
enum FolderProblem: Equatable, Sendable {
    case download(String)
    case library(String)
}

extension AppModel {
    // MARK: Library index

    /// Refresh in Settings, a new library folder, and launch.
    func rescanLibrary() {
        libraryScanTask?.cancel()
        libraryScanTask = nil
        guard let reference = settings.libraryFolder else {
            libraryStatus = .none
            return
        }
        let status = Folders.status(of: reference, requireWritable: false)
        guard case .available(let url) = status else {
            let message = Folders.message(for: status, reference: reference, role: "music library")
                ?? "The music library isn't available."
            libraryStatus = .unavailable(message)
            activity.add(.library, message)
            return
        }
        libraryStatus = .scanning(done: 0, total: 0)
        let stream = services.library.scan(url)
        libraryScanTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .progress(let done, let total):
                    self.libraryStatus = .scanning(done: done, total: total)
                case .finished(let files):
                    self.libraryStatus = .indexed(files: files)
                    self.activity.add(.library, "Library indexed: \(LibraryStatus.indexed(files: files).text).")
                case .unavailable(let message):
                    self.libraryStatus = .unavailable(message)
                    self.activity.add(.library, message)
                }
            }
        }
    }

    // MARK: Preview cache (Settings › General)

    func refreshPreviewCacheSize() {
        Task { previewCacheBytes = await services.previews.cacheSize() }
    }

    func clearPreviewCache() {
        stopPreview()
        Task {
            await services.previews.clearCache()
            previewCacheBytes = await services.previews.cacheSize()
            activity.add(.notice, "Cleared the preview cache. Waveforms load again when needed.")
        }
    }

    var previewCacheText: String {
        guard let bytes = previewCacheBytes else { return "Measuring…" }
        if bytes == 0 { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
