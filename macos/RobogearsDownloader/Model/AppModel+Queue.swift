import AppKit
import RobogearsCore

/// Queue edits. Remove, Clear Queue, Include / Leave Out, moves and the
/// end-of-batch clean-up are all undoable and named in Edit › Undo
/// (`undo-and-redo.md › Desktop (macOS)`; D4 3.14).
extension AppModel {
    // MARK: Adding rows (no undo: an add is undone with Remove)

    func appendRows(_ new: [QueueRow]) {
        guard !new.isEmpty else { return }
        rows.append(contentsOf: new)
        queueDidChange()
        for row in new { enqueuePreload(row.id) }
    }

    // MARK: Remove

    func remove(_ ids: Set<UUID>, actionName: String = "Remove from Queue") {
        let removed = rows.enumerated().filter { ids.contains($0.element.id) }.map { (index: $0.offset, row: $0.element) }
        guard !removed.isEmpty else { return }
        let removedIDs = Set(removed.map(\.row.id))

        // Rows in a running batch leave it (D4 2.13): a downloading row stops.
        if var batch {
            for entry in removed where entry.row.inBatch {
                let id = entry.row.id
                Task { await services.downloader.remove(id) }
                entry.row.inBatch = false
                batch.ids.removeAll { $0 == id }
                batch.total = max(batch.finished, batch.total - 1)
                entry.row.item.state = batch.retriedReasons[id].map { .failed(reason: $0) } ?? .waiting
            }
            self.batch = batch
        }
        if let playing = nowPlayingID, removedIDs.contains(playing) { stopPreview() }
        preloadQueue.removeAll { removedIDs.contains($0) }

        // Focus moves to the nearest row when the focused row is removed (6).
        let firstIndex = removed.map(\.index).min() ?? 0
        rows.removeAll { removedIDs.contains($0.id) }
        if !selection.isDisjoint(with: removedIDs) {
            selection.subtract(removedIDs)
            if selection.isEmpty, !rows.isEmpty {
                selection = [rows[min(firstIndex, rows.count - 1)].id]
            }
        }
        queueDidChange()

        undoManager?.registerUndo(withTarget: self) { model in
            model.reinsert(removed, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Puts removed rows back where they were (Undo Remove, Undo Clear Queue).
    private func reinsert(_ entries: [(index: Int, row: QueueRow)], actionName: String) {
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            let row = entry.row
            row.inBatch = false
            switch row.item.state {
            case .queued, .downloading: row.item.state = .waiting
            default: break
            }
            rows.insert(row, at: min(entry.index, rows.count))
        }
        queueDidChange()
        let ids = Set(entries.map(\.row.id))
        undoManager?.registerUndo(withTarget: self) { model in
            model.remove(ids, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    func removeSelected() { remove(selection) }

    /// Clear Queue (⇧⌘⌫): unavailable during a batch.
    func clearQueue() {
        guard batch == nil, !rows.isEmpty else { return }
        summary = nil
        remove(Set(rows.map(\.id)), actionName: "Clear Queue")
    }

    var canClearQueue: Bool { batch == nil && !rows.isEmpty }

    // MARK: Include / Leave Out

    func setIncluded(_ ids: Set<UUID>, _ included: Bool) {
        let changed = rows.filter { ids.contains($0.id) && $0.item.included != included && $0.item.tidalID != nil && !$0.inBatch }
        guard !changed.isEmpty else { return }
        let previous = Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0.item.included) })
        for row in changed {
            row.item.included = included
            if included { enqueuePreload(row.id) }
        }
        queueDidChange()
        let name = included ? "Include in Download" : "Leave Out of Download"
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreIncluded(previous, actionName: name)
        }
        undoManager?.setActionName(name)
    }

    private func restoreIncluded(_ values: [UUID: Bool], actionName: String) {
        var current: [UUID: Bool] = [:]
        for row in rows {
            guard let value = values[row.id] else { continue }
            current[row.id] = row.item.included
            row.item.included = value
        }
        queueDidChange()
        undoManager?.registerUndo(withTarget: self) { model in
            model.restoreIncluded(current, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Include in Download when any selected row is left out; otherwise Leave Out.
    var selectionIncludeTitle: String {
        selectedRows.contains { !$0.item.included } ? "Include in Download" : "Leave Out of Download"
    }

    func toggleIncludedForSelection() {
        let ids = selection
        let anyLeftOut = selectedRows.contains { !$0.item.included }
        setIncluded(ids, anyLeftOut)
    }

    // MARK: Move (drag to reorder)

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let before = rows.map(\.id)
        rows.move(fromOffsets: source, toOffset: destination)
        queueDidChange()
        registerOrderUndo(before)
    }

    private func registerOrderUndo(_ order: [UUID]) {
        undoManager?.registerUndo(withTarget: self) { model in
            let current = model.rows.map(\.id)
            let byID = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.id, $0) })
            model.rows = order.compactMap { byID[$0] } + model.rows.filter { !order.contains($0.id) }
            model.queueDidChange()
            model.registerOrderUndo(current)
        }
        undoManager?.setActionName("Move")
    }

    // MARK: End-of-batch clean-up (D4 3.6), undoable

    /// Removes finished rows, and after a complete Download All the rows that
    /// were left out as already in the library when it started.
    func cleanUpAfterBatch(_ batch: BatchState, complete: Bool) {
        var ids = Set<UUID>()
        for row in rows {
            switch row.item.state {
            case .done, .skipped: ids.insert(row.id)
            default: break
            }
        }
        var libraryCleared = 0
        if complete && batch.isDownloadAll {
            for row in rows where batch.libraryRowsAtStart.contains(row.id)
                && !row.item.included && row.item.libraryMatch?.kind == .exact {
                ids.insert(row.id)
                libraryCleared += 1
            }
        }
        guard !ids.isEmpty else { return }
        remove(ids, actionName: "Clear Finished Tracks")
        if libraryCleared > 0 {
            activity.add(.library, "Cleared \(Formatting.tracks(libraryCleared)) already in your library. Edit › Undo brings them back.")
        }
    }

    // MARK: Persistence

    /// Schedules a save (debounced by the store).
    func queueDidChange() {
        guard persists, let queueStore else { return }
        let items = rows.map(\.item)
        Task { await queueStore.save(items) }
    }

    /// Saves now (after each finished track and on quit).
    func flushQueue() async {
        guard persists, let queueStore else { return }
        await queueStore.save(rows.map(\.item))
        await queueStore.flush()
        if let error = await queueStore.lastError { activity.add(.failed, error) }
    }

    // MARK: Row commands (button, context menu, Queue menu, VoiceOver)

    func facts(_ row: QueueRow) -> RowFacts {
        RowFacts(item: row.item, percent: row.percent, isCheckingLibrary: row.isCheckingLibrary,
                 inDownloadFolder: row.inDownloadFolder, problem: row.problem, isAACOnly: row.isAACOnly,
                 hasSavedFile: row.savedFile != nil, preview: {
                     switch row.preview {
                     case .none: .none
                     case .loading: .loading
                     case .ready: .ready
                     case .unavailable: .unavailable
                     }
                 }())
    }

    func presentation(_ row: QueueRow) -> RowPresentation { RowPresentation.make(facts(row)) }

    /// Commands that apply to at least one of the rows, in menu order.
    func commands(for ids: Set<UUID>) -> [RowCommand] {
        let targets = rows.filter { ids.contains($0.id) }
        var all: [RowCommand] = []
        for row in targets { all += presentation(row).commands }
        let order: [RowCommand] = [.include, .leaveOut, .retry, .searchTIDAL, .matchAgain, .saveAs, .replace,
                                   .showInFinder, .showLibraryFile, .tryPreviewAgain, .copyTitleAndArtist, .remove]
        let present = Set(all)
        var result = order.filter { present.contains($0) }
        // A mixed selection offers both toggles only as one: Include wins.
        if result.contains(.include) { result.removeAll { $0 == .leaveOut } }
        return result
    }

    /// Runs a command on every row it applies to.
    func perform(_ command: RowCommand, on ids: Set<UUID>) {
        let targets = rows.filter { ids.contains($0.id) && presentation($0).commands.contains(command) }
        guard let first = targets.first else { return }
        switch command {
        case .include: setIncluded(Set(targets.map(\.id)), true)
        case .leaveOut: setIncluded(Set(targets.map(\.id)), false)
        case .retry: retry(Set(targets.map(\.id)))
        case .searchTIDAL: searchTIDAL(for: first.id)
        case .matchAgain: matchAgain(Set(targets.map(\.id)))
        case .saveAs: saveAs(first.id)
        case .replace: for row in targets { replace(row.id) }
        case .showInFinder: showInFinder(targets.map(\.id))
        case .showLibraryFile: showLibraryFiles(targets.map(\.id))
        case .tryPreviewAgain: for row in targets { retryPreview(row.id) }
        case .copyTitleAndArtist: copyTitleAndArtist(targets)
        case .remove: remove(Set(targets.map(\.id)))
        }
    }

    func copyTitleAndArtist(_ targets: [QueueRow]) {
        let lines = targets.map { row -> String in
            let title = row.item.version.map { "\(row.item.title) — \($0)" } ?? row.item.title
            return row.item.artist.isEmpty ? title : "\(title) — \(row.item.artist)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Match Again on "Couldn't check" rows.
    func matchAgain(_ ids: Set<UUID>) {
        let targets = rows.filter { ids.contains($0.id) }
        for row in targets {
            row.isCheckingLibrary = false
            let item = row.item
            Task {
                let updated = await services.resolver.matchAgain(item)
                guard let current = self.row(row.id) else { return }
                var next = updated
                next = QueueItem(id: current.id, tidalID: next.tidalID, title: next.title, version: next.version,
                                 artist: next.artist, album: next.album, durationSeconds: next.durationSeconds,
                                 isrc: next.isrc, hiRes: next.hiRes, explicit: next.explicit, source: current.item.source,
                                 originalTitle: current.item.originalTitle, originalArtist: current.item.originalArtist,
                                 match: next.match, libraryMatch: next.libraryMatch, included: next.included, state: .waiting)
                current.item = next
                queueDidChange()
                if case .matched = next.match {
                    activity.add(.search, "Matched \(next.title) on TIDAL.")
                    checkLibrary(for: [current])
                    enqueuePreload(current.id)
                } else {
                    activity.add(.warning, "\(current.item.title): still not matched on TIDAL.")
                }
            }
        }
    }
}
