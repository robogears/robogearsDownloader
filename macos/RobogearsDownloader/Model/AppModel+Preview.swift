import Foundation
import RobogearsCore

/// The one preview player (D4 5.16) and the background pre-loader (D4 5.1).
extension AppModel {
    /// Tracks longer than this aren't pre-loaded (DESIGN.md §4).
    static let preloadMaxSeconds = 20 * 60
    static let preloadConcurrency = 2

    // MARK: Playback

    /// The play button, Space (list focus only) and Queue › Play Preview.
    func togglePreview(_ id: UUID) {
        if nowPlayingID == id, previewLoadingID != id {
            if player.isPlaying { pausePreview() } else { resumePreview() }
        } else {
            startPreview(id, atFraction: nil)
        }
    }

    func toggleSelectedPreview() {
        guard let id = rows.first(where: { selection.contains($0.id) && presentation($0).canPreview })?.id else { return }
        togglePreview(id)
    }

    /// Press on a waveform: the current track seeks (never pauses); another row
    /// starts at the pressed point (DESIGN_DIRECTION 3.4).
    func seekPreview(_ id: UUID, toFraction fraction: Double) {
        let clamped = min(1, max(0, fraction))
        if nowPlayingID == id, previewLoadingID != id {
            player.seek(toFraction: clamped)
            if !player.isPlaying { resumePreview() }
        } else {
            startPreview(id, atFraction: clamped)
        }
    }

    /// Keyboard seeking on a focused waveform: ← → 5 s, ⇧ 30 s.
    func seekPreview(_ id: UUID, bySeconds delta: Double) {
        guard nowPlayingID == id, player.duration > 0 else { return }
        let target = (player.currentTime + delta) / player.duration
        player.seek(toFraction: min(1, max(0, target)))
        previewPositionToken += 1
    }

    func startPreview(_ id: UUID, atFraction fraction: Double?) {
        guard let row = row(id), let tidalID = row.item.tidalID, presentation(row).canPreview else { return }
        stopPreview()
        previewGeneration += 1
        let generation = previewGeneration
        nowPlayingID = id
        previewLoadingID = id
        Task {
            do {
                let asset = try await services.previews.preview(for: tidalID)
                guard generation == previewGeneration, self.row(id) != nil else { return }
                row.preview = .ready(asset.peaks)
                try player.load(asset)
                player.volume = settings.previewGain
                if let fraction { player.seek(toFraction: fraction) }
                player.play()
                isPreviewPlaying = true
                previewLoadingID = nil
            } catch {
                guard generation == previewGeneration else { return }
                let message = (error as? ServiceError)?.message ?? "The preview couldn't load. Try again."
                row.preview = .unavailable(message)
                activity.add(.warning, "Preview of \(row.item.title): \(message)")
                nowPlayingID = nil
                previewLoadingID = nil
                isPreviewPlaying = false
            }
        }
    }

    func pausePreview() {
        player.pause()
        isPreviewPlaying = false
        previewPositionToken += 1
    }

    func resumePreview() {
        guard nowPlayingID != nil else { return }
        player.play()
        isPreviewPlaying = true
    }

    /// Queue › Stop Preview; also when the row leaves or the window closes.
    func stopPreview() {
        previewGeneration += 1
        player.stop()
        nowPlayingID = nil
        previewLoadingID = nil
        isPreviewPlaying = false
    }

    func previewDidFinish() {
        isPreviewPlaying = false
    }

    /// The playhead, 0…1, for the playing row's waveform.
    var previewProgress: Double {
        if let previewProgressOverride { return previewProgressOverride }
        guard player.duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime / player.duration))
    }

    /// "1 minute 23 seconds of 3 minutes 45 seconds" for VoiceOver.
    func previewPositionDescription(for id: UUID) -> String {
        guard nowPlayingID == id, player.duration > 0 else { return "Not playing" }
        return "\(Formatting.spokenDuration(player.currentTime)) of \(Formatting.spokenDuration(player.duration))"
    }

    func retryPreview(_ id: UUID) {
        guard let row = row(id) else { return }
        row.preview = .none
        enqueuePreload(id, front: true)
    }

    // MARK: Pre-loading peaks (D4 5.1)

    /// Rows ask for their bars when they come on screen.
    func rowAppeared(_ id: UUID) { enqueuePreload(id) }

    func enqueuePreload(_ id: UUID, front: Bool = false) {
        guard preloadingEnabled, let row = row(id), case .none = row.preview, row.item.included,
              row.item.tidalID != nil, presentation(row).canPreview,
              (row.item.durationSeconds ?? 0) <= Self.preloadMaxSeconds,
              !preloadQueue.contains(id) else { return }
        if front { preloadQueue.insert(id, at: 0) } else { preloadQueue.append(id) }
        pumpPreloads()
    }

    func stopPreloading() { preloadQueue.removeAll() }

    func resumePreloading() {
        for row in rows { enqueuePreload(row.id) }
    }

    private func pumpPreloads() {
        // Paused during any batch; previews the person clicks still play.
        guard batch == nil else { return }
        while preloadInFlight < Self.preloadConcurrency, !preloadQueue.isEmpty {
            let id = preloadQueue.removeFirst()
            guard let row = row(id), case .none = row.preview, let tidalID = row.item.tidalID else { continue }
            preloadInFlight += 1
            row.preview = .loading
            Task {
                defer {
                    preloadInFlight -= 1
                    pumpPreloads()
                }
                if let peaks = await services.previews.cachedPeaks(for: tidalID) {
                    row.preview = .ready(peaks)
                    return
                }
                do {
                    let asset = try await services.previews.preview(for: tidalID)
                    if case .loading = row.preview { row.preview = .ready(asset.peaks) }
                } catch {
                    let message = (error as? ServiceError)?.message ?? "The preview couldn't load."
                    if case .loading = row.preview { row.preview = .unavailable(message) }
                }
            }
        }
    }
}
