import AppKit
import RobogearsCore

/// The states the harness renders (DESIGN_DIRECTION 7): the full queue with
/// every row state, each empty state, the adding cover, a running batch and
/// every summary notice.
@MainActor
struct SnapshotScenario {
    var name: String
    var looks: [SnapshotHarness.Look]
    var sizes: [CGSize]
    var reduceTransparency = false
    var makeModel: @MainActor () -> AppModel
    var hover: @MainActor (AppModel) -> SnapshotHover? = { _ in nil }
}

@MainActor
enum SnapshotScenarios {
    typealias Look = SnapshotHarness.Look

    static var folderPath: String { NSHomeDirectory() + "/Music/TIDAL" }
    static var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    /// A remembered folder for display only (no bookmark: nothing is resolved).
    static var folderReference: FolderReference? {
        let json = #"{"bookmark":"","lastKnownPath":"\#(folderPath)"}"#
        return try? JSONDecoder().decode(FolderReference.self, from: Data(json.utf8))
    }

    static func baseModel(signedIn: Bool = true, folder: Bool = true) -> AppModel {
        var settings = AppSettings()
        if folder { settings.downloadFolder = folderReference }
        let model = AppModel(services: StandIn.services(), player: StandInPreviewPlayer(), settings: settings,
                             settingsStore: nil, queueStore: nil, update: nil)
        model.prepareForSnapshot()
        model.signInState = signedIn ? .signedIn(country: "United States") : .signedOut
        return model
    }

    static func fullQueue() -> AppModel {
        let model = baseModel()
        let sample = StandInSampleQueue.everyState(folder: folderURL)
        model.rows = sample.rows
        model.selection = [sample.selectedID]
        model.nowPlayingID = sample.playingID
        model.isPreviewPlaying = true
        model.previewProgressOverride = 0.4
        var batch = BatchState(folder: folderURL, ids: sample.rows.filter(\.inBatch).map(\.id), total: 120,
                               isDownloadAll: true)
        batch.finished = 37
        model.batch = batch
        model.updateControlOverride = .available(version: "0.1.32")
        for (kind, text) in StandInSampleQueue.activity { model.activity.add(kind, text) }
        return model
    }

    static func summaryModel(_ outcome: BatchSummary.Outcome, downloaded: Int, already: Int, failed: Int,
                             waiting: Int, rows: [QueueRow]) -> AppModel {
        let model = baseModel(folder: outcome != .noFolder)
        model.rows = rows
        var summary = BatchSummary(outcome: outcome)
        summary.downloaded = downloaded
        summary.alreadyInFolder = already
        summary.failed = failed
        summary.waiting = waiting
        model.summary = summary
        model.activity.add(.notice, "Downloading 14 tracks into ~/Music/TIDAL.")
        model.activity.add(outcome == .allGood ? .saved : .warning, summary.sentence)
        return model
    }

    static func all() -> [SnapshotScenario] {
        let both = [Look.light, Look.dark]
        let bothSizes = [SnapshotHarness.large, SnapshotHarness.small]
        var list: [SnapshotScenario] = []

        // Every row state, four appearances, both sizes; hover pinned on Blue Lantern at 40 %.
        list.append(SnapshotScenario(name: "queue-every-state", looks: Look.all, sizes: bothSizes,
                                     makeModel: fullQueue,
                                     hover: { model in
                                         model.rows.first { $0.item.title == "Blue Lantern" }
                                             .map { SnapshotHover(rowID: $0.id, fraction: 0.4) }
                                     }))

        // The rest of the states, scrolled into view: checking, preview
        // unavailable, left out by you, the long-title truncation rule.
        list.append(SnapshotScenario(name: "queue-more-states", looks: Look.all, sizes: bothSizes,
                                     makeModel: {
                                         let model = fullQueue()
                                         let split = model.rows.firstIndex { $0.item.title == "Afterglow" } ?? 0
                                         model.rows = Array(model.rows[split...]) + Array(model.rows[..<split])
                                         model.selection = Set(model.rows.filter { $0.item.title == "Tidepool" || $0.item.title == "Echo Park" }.map(\.id))
                                         return model
                                     },
                                     hover: { model in
                                         model.rows.first { $0.item.title == "Lanterns" }
                                             .map { SnapshotHover(rowID: $0.id, fraction: 0.4) }
                                     }))

        // Empty states.
        list.append(SnapshotScenario(name: "empty-signed-out", looks: both, sizes: bothSizes,
                                     makeModel: { baseModel(signedIn: false, folder: false) }))
        list.append(SnapshotScenario(name: "empty-no-folder", looks: both, sizes: bothSizes,
                                     makeModel: { baseModel(folder: false) }))
        list.append(SnapshotScenario(name: "empty-ready", looks: Look.all, sizes: bothSizes,
                                     makeModel: { baseModel() }))

        // Adding cover: a loading line, then the count; and under Reduce Transparency.
        list.append(SnapshotScenario(name: "adding-line", looks: both, sizes: [SnapshotHarness.large], makeModel: {
            let model = baseModel()
            model.rows = StandInSampleQueue.afterBatch(failed: 0, waiting: 8)
            model.adding = AddingState(seed: 1)
            return model
        }))
        list.append(SnapshotScenario(name: "adding-count", looks: both, sizes: [SnapshotHarness.large], makeModel: {
            let model = baseModel()
            model.rows = StandInSampleQueue.afterBatch(failed: 0, waiting: 8)
            var state = AddingState(seed: 1)
            state.done = 34
            state.total = 100
            model.adding = state
            return model
        }))
        list.append(SnapshotScenario(name: "adding-reduce-transparency", looks: both, sizes: [SnapshotHarness.large],
                                     reduceTransparency: true, makeModel: {
            let model = baseModel()
            model.rows = StandInSampleQueue.afterBatch(failed: 0, waiting: 8)
            var state = AddingState(seed: 1)
            state.done = 34
            state.total = 100
            model.adding = state
            return model
        }))

        // A running batch, with TIDAL asking to wait.
        list.append(SnapshotScenario(name: "batch-running", looks: both, sizes: [SnapshotHarness.large], makeModel: {
            let model = fullQueue()
            model.batch?.waitingForTIDAL = true
            model.selection = []
            model.nowPlayingID = nil
            model.isPreviewPlaying = false
            return model
        }))

        // Every summary notice.
        let stopCause = BatchStopCause(
            message: "Stopped: the download folder “TIDAL” on Music SSD isn't available. Connect the drive or choose another folder.",
            fix: .chooseFolder)
        let summaries: [(String, @MainActor () -> AppModel)] = [
            ("summary-all-good", { summaryModel(.allGood, downloaded: 12, already: 2, failed: 0, waiting: 0, rows: []) }),
            ("summary-some-failed", { summaryModel(.someFailed, downloaded: 10, already: 0, failed: 2, waiting: 0,
                                                   rows: StandInSampleQueue.afterBatch(failed: 2, waiting: 4)) }),
            ("summary-stopped", { summaryModel(.stoppedByPerson, downloaded: 5, already: 0, failed: 0, waiting: 115,
                                               rows: StandInSampleQueue.afterBatch(failed: 0, waiting: 12)) }),
            ("summary-stopped-cause", { summaryModel(.stoppedByCause(stopCause), downloaded: 3, already: 0, failed: 0, waiting: 9,
                                                     rows: StandInSampleQueue.afterBatch(failed: 0, waiting: 9)) }),
            ("summary-no-folder", { summaryModel(.noFolder, downloaded: 0, already: 0, failed: 0, waiting: 0,
                                                 rows: StandInSampleQueue.afterBatch(failed: 0, waiting: 6)) }),
            ("notice-spotify-cap", { summaryModel(.spotifyCap("Spotify only shares the first 100 tracks of a playlist. If Late Ferry is longer, export it with Exportify and drop the CSV here."),
                                                  downloaded: 0, already: 0, failed: 0, waiting: 0,
                                                  rows: StandInSampleQueue.afterBatch(failed: 0, waiting: 10)) }),
        ]
        for (name, make) in summaries {
            list.append(SnapshotScenario(name: name, looks: both, sizes: [SnapshotHarness.large], makeModel: make))
        }
        return list
    }
}
