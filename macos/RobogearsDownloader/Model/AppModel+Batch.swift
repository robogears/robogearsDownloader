import AppKit
import RobogearsCore

/// Download All, Stop Downloads, Retry and the end of a batch (D4 2.1, 2.4,
/// 2.8, 2.12, 2.13, 3.6). One batch at a time, tracks in sequence.
extension AppModel {
    // MARK: Starting

    /// The toolbar's primary action, ⌘↩ and the Dock menu.
    func downloadAll() {
        guard batch == nil, sheet == nil else { return }
        guard isSignedIn else {
            // D4 2.18: signed out opens the sign-in sheet, not the honk. Nothing
            // starts by itself afterwards.
            sheet = .signIn(resumeAdd: nil)
            return
        }
        guard let folder = availableDownloadFolder() else { return }
        let tracks = rows.filter { $0.item.isDownloadable && !$0.isCheckingLibrary }
        guard !tracks.isEmpty else {
            sounds.play(.warningHonk)
            return
        }
        let libraryRows = Set(rows.filter { !$0.item.included && $0.item.libraryMatch?.kind == .exact }.map(\.id))
        startBatch(tracks, folder: folder, isDownloadAll: true, libraryRowsAtStart: libraryRows)
    }

    /// Retry on a row, Retry Selected, Retry All Failed (⌘R).
    func retry(_ ids: Set<UUID>) {
        guard batch == nil else { return }
        let targets = rows.filter { row in
            guard ids.contains(row.id), row.item.tidalID != nil else { return false }
            if case .failed = row.item.state { return true }
            return false
        }
        guard !targets.isEmpty, let folder = availableDownloadFolder() else { return }
        var reasons: [UUID: String] = [:]
        for row in targets { if case .failed(let reason) = row.item.state { reasons[row.id] = reason } }
        activity.add(.retry, "Retrying \(Formatting.tracks(targets.count)).")
        startBatch(targets, folder: folder, isDownloadAll: false, retried: reasons)
    }

    /// The header and Queue menu button: selected failed rows, else every failed row.
    func retryFromHeader() {
        let selectedFailed = failedRows.filter { selection.contains($0.id) }
        retry(Set((selectedFailed.isEmpty ? failedRows : selectedFailed).map(\.id)))
    }

    /// The download folder if it's usable; otherwise the notice that says why.
    private func availableDownloadFolder() -> URL? {
        guard let reference = settings.downloadFolder else {
            summary = BatchSummary(outcome: .noFolder)
            sounds.play(.warningHonk)
            announce("Choose a download folder to start downloading.")
            return nil
        }
        let status = Folders.status(of: reference, requireWritable: true)
        if case .available(let url) = status { return url }
        let message = Folders.message(for: status, reference: reference, role: "download folder") ?? "The download folder isn't available."
        summary = BatchSummary(outcome: .stoppedByCause(BatchStopCause(message: message, fix: .chooseFolder)))
        activity.add(.failed, message)
        sounds.play(.warningHonk)
        announce(message)
        return nil
    }

    private func startBatch(_ tracks: [QueueRow], folder: URL, isDownloadAll: Bool,
                            libraryRowsAtStart: Set<UUID> = [], retried: [UUID: String] = [:]) {
        summary = nil
        for row in tracks {
            row.inBatch = true
            row.item.state = .queued
            row.percent = 0
            row.problem = nil
        }
        batch = BatchState(folder: folder, ids: tracks.map(\.id), total: tracks.count, isDownloadAll: isDownloadAll,
                           libraryRowsAtStart: libraryRowsAtStart, retriedReasons: retried)
        sounds.play(.downloadChime)
        // The Mac stays awake while downloads run (D4 2.12).
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading tracks")
        dockProgress.show(fraction: 0)
        let sentence = "Downloading \(Formatting.tracks(tracks.count)) into \(Formatting.abbreviatedPath(folder.path))."
        activity.add(.notice, sentence)
        announce(sentence)
        stopPreloading()

        let items = tracks.map(\.item)
        batchTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.services.downloader.download(items, into: folder) {
                self.apply(event)
            }
            await self.finishBatch()
        }
    }

    // MARK: Events

    private func apply(_ event: BatchEvent) {
        guard var batch else { return }
        switch event {
        case .started(let id):
            guard let row = row(id), row.inBatch else { return }
            row.percent = 0
            row.item.state = .downloading(percent: 0)
            return
        case .progress(let id, let percent):
            // A tick touches this row's percent only: never `batch`, never the list.
            row(id)?.percent = percent
            return
        case .finished(let id, let outcome):
            guard let row = row(id), row.inBatch else { return }
            row.inBatch = false
            batch.finished += 1
            record(outcome, for: row, in: &batch)
            self.batch = batch
            dockProgress.show(fraction: batch.total > 0 ? Double(batch.finished) / Double(batch.total) : 1)
            Task { await self.flushQueue() }
            return
        case .waitingForTIDAL(let waiting):
            guard batch.waitingForTIDAL != waiting else { return }
            batch.waitingForTIDAL = waiting
        case .stopped(let cause):
            batch.stopCause = cause
            activity.add(.stopped, cause.message)
        case .ended:
            return
        }
        self.batch = batch
    }

    private func record(_ outcome: TrackOutcome, for row: QueueRow, in batch: inout BatchState) {
        let title = row.item.title
        switch outcome {
        case .saved(let quality, let file, let isAAC):
            row.item.state = .done(quality: isAAC ? "AAC" : quality)
            row.savedFile = file
            row.isAACOnly = isAAC
            batch.downloaded += 1
            if isAAC { batch.savedAsAAC += 1 }
            activity.add(.saved, "Saved \(file.lastPathComponent) (\(isAAC ? "AAC: TIDAL has no lossless version" : quality)).")
        case .alreadyInFolder(let file):
            row.item.state = .skipped(reason: "Already in your download folder")
            row.savedFile = file
            batch.alreadyInFolder += 1
            activity.add(.notice, "Skipped \(file.lastPathComponent): already in your download folder.")
        case .failed(let reason):
            row.item.state = .failed(reason: reason)
            batch.failed += 1
            activity.add(.failed, "\(title): \(reason)")
        case .clash(let name):
            row.item.state = .waiting
            row.problem = .clash(fileName: name)
            batch.failed += 1
            activity.add(.failed, "\(title) wasn't downloaded: a different song is already saved as \(name).")
        case .damaged(let name):
            row.item.state = .waiting
            row.problem = .damaged(fileName: name)
            row.savedFile = batch.folder.appendingPathComponent(name)
            batch.failed += 1
            activity.add(.failed, "\(title) wasn't downloaded: \(name) looks damaged.")
        }
    }

    // MARK: Stopping

    /// Stop Downloads (⌘., the toolbar, the Dock menu): stops at once, no
    /// confirmation; Escape never does this (D4 2.4).
    func stopDownloads() {
        guard var batch, !batch.stoppedByPerson else { return }
        batch.stoppedByPerson = true
        self.batch = batch
        sounds.play(.cancelChime)
        Task { await services.downloader.stop() }
    }

    /// ⌘. honours the frontmost cancellable thing: a sheet › the adding
    /// cover › the batch (DESIGN_DIRECTION 5).
    func cancelFrontmost() {
        if sheet != nil {
            sheet = nil
        } else if adding != nil {
            cancelAdd()
        } else if batch != nil {
            stopDownloads()
        }
    }

    // MARK: The end

    private func finishBatch() async {
        guard let batch else { return }
        batchTask = nil
        var waiting = 0
        for id in batch.ids {
            guard let row = row(id) else { continue }
            if row.inBatch || row.item.state == .queued || { if case .downloading = row.item.state { true } else { false } }() {
                row.inBatch = false
                row.item.state = batch.retriedReasons[id].map { .failed(reason: $0) } ?? .waiting
                waiting += 1
            }
        }
        let outcome: BatchSummary.Outcome
        if batch.stoppedByPerson {
            outcome = .stoppedByPerson
        } else if let cause = batch.stopCause {
            outcome = .stoppedByCause(cause)
        } else if batch.failed > 0 {
            outcome = .someFailed
        } else {
            outcome = .allGood
        }
        var notice = BatchSummary(outcome: outcome)
        notice.downloaded = batch.downloaded
        notice.alreadyInFolder = batch.alreadyInFolder
        notice.failed = batch.failed
        notice.waiting = waiting
        notice.savedAsAAC = batch.savedAsAAC

        self.batch = nil
        summary = notice
        switch outcome {
        case .allGood: sounds.play(.successPing)
        case .someFailed, .stoppedByCause: sounds.play(.finishedWithProblems)
        default: break // the cancel chime already played
        }
        activity.add(outcome == .allGood ? .saved : (outcome == .stoppedByPerson ? .stopped : .warning), notice.sentence)
        announce(notice.sentence)

        let complete = !batch.stoppedByPerson && batch.stopCause == nil
        cleanUpAfterBatch(batch, complete: complete)
        await flushQueue()

        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        dockProgress.clear()
        // The end of a batch while the window isn't key: one Dock bounce, and
        // a notification only when the person turned them on (4.11, D4 2.12).
        if !isMainWindowKey {
            NSApp.requestUserAttention(.informationalRequest)
            postBatchNotification(notice)
        }
        resumePreloading()
        if updateAfterBatch {
            updateAfterBatch = false
            performUpdate()
        }
    }

    func dismissSummary() { summary = nil }

    func performSummaryButton(_ button: BatchSummary.Button) {
        switch button {
        case .openFolder: openDownloadFolder()
        case .retryFailed: retry(Set(failedRows.map(\.id)))
        case .chooseFolder: chooseDownloadFolder()
        case .signIn: sheet = .signIn(resumeAdd: nil)
        case .openExportify: openExportify()
        }
    }

    // MARK: Clash and damaged files

    func saveAs(_ id: UUID) {
        guard let row = row(id), batch == nil, let folder = settings.downloadFolder,
              case .available(let folderURL) = Folders.status(of: folder, requireWritable: true) else { return }
        let panel = NSSavePanel()
        panel.directoryURL = folderURL
        panel.nameFieldStringValue = "\(row.item.title) (\(row.item.artist)).flac"
        panel.allowedContentTypes = [.init(filenameExtension: "flac") ?? .audio]
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        resolveProblem(row, .saveAs(fileName: url.lastPathComponent), folder: folderURL)
    }

    func replace(_ id: UUID) {
        guard let row = row(id), batch == nil, let folder = settings.downloadFolder,
              case .available(let folderURL) = Folders.status(of: folder, requireWritable: true) else { return }
        resolveProblem(row, .replace, folder: folderURL)
    }

    private func resolveProblem(_ row: QueueRow, _ resolution: ClashResolution, folder: URL) {
        let item = row.item
        row.item.state = .downloading(percent: 0)
        Task {
            let outcome = await services.downloader.resolve(item, resolution, in: folder)
            row.problem = nil
            var scratch = BatchState(folder: folder, ids: [row.id], total: 1, isDownloadAll: false)
            record(outcome, for: row, in: &scratch)
            queueDidChange()
        }
    }
}
