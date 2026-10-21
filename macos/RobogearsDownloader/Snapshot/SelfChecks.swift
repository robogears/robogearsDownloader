#if DEBUG
import AppKit
import RobogearsCore

/// A debug instrument (debug builds only): `--run-checks` drives AppModel
/// through its real flows with the stand-in services, headlessly (no window,
/// no sounds, nothing saved), asserts the outcomes and exits non-zero on any
/// failure. The app target has no test bundle because a hosted test would
/// launch the app; this covers the same ground.
@MainActor
enum SelfChecks {
    static func requested(_ arguments: [String]) -> Bool { arguments.contains("--run-checks") }

    private static var failures: [String] = []
    private static var passed = 0

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await runAll()
            print("\(passed) checks passed, \(failures.count) failed")
            for failure in failures { print("FAIL: \(failure)") }
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }

    private static func expect(_ condition: Bool, _ name: String, file: StaticString = #fileID, line: UInt = #line) {
        if condition { passed += 1 } else { failures.append("\(name) (\(file):\(line))") }
    }

    private static func model(signedIn: Bool = true, folder: URL? = nil) -> AppModel {
        var settings = AppSettings()
        settings.playSoundEffects = false
        if let folder { settings.downloadFolder = try? FolderReference(url: folder) }
        let model = AppModel(services: StandIn.services(), player: StandInPreviewPlayer(), settings: settings,
                             settingsStore: nil, queueStore: nil, update: nil)
        model.prepareForSnapshot()
        model.signInState = signedIn ? .signedIn(country: nil) : .signedOut
        return model
    }

    /// Waits (up to `timeout`) for a condition, letting the main actor run.
    private static func wait(_ timeout: Double = 20, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func runAll() async {
        presentationRules()
        textRules()
        await addFlows()
        await undoFlows()
        await batchFlows()
    }

    // MARK: Pure rules

    private static func presentationRules() {
        let folder = URL(fileURLWithPath: "/tmp/none")
        let sample = StandInSampleQueue.everyState(folder: folder)
        let m = model()
        func p(_ title: String) -> RowPresentation? {
            sample.rows.first { $0.item.title == title }.map { m.presentation($0) }
        }
        expect(p("Intro")?.status?.text == "42%" && p("Intro")?.showsProgressLine == true, "downloading shows percent and line")
        expect(p("Seven")?.status?.text == "Waiting" && p("Seven")?.status?.symbol == "clock", "queued shows Waiting")
        expect(p("Northern Lights")?.status?.text == "Done · 24-bit / 96 kHz" && p("Northern Lights")?.status?.tone == .done, "done shows quality in green")
        expect(p("Paper Boats")?.secondLine == "Saved as AAC (.m4a): TIDAL has no lossless version", "AAC second line")
        expect(p("Late Ferry")?.action == .showInFinder, "skipped offers Show in Finder")
        expect(p("Glass Houses")?.action == .retry && p("Glass Houses")?.secondLine == "TIDAL couldn't send this track. Try again later.", "failed: Retry and reason")
        expect(p("Midnight Static")?.action == .searchTIDAL && p("Midnight Static")?.canPreview == false, "not on TIDAL: Search…, no preview")
        expect(p("Golden Hour")?.status?.text == "Couldn't check: TIDAL was busy" && p("Golden Hour")?.action == .matchAgain, "couldn't check: Match Again")
        expect(p("Slow Motion")?.isLeftOut == true && p("Slow Motion")?.action == .include && p("Slow Motion")?.secondLine == "Library: Slow Motion", "library exact: left out with + Add")
        expect(p("Satellite")?.status?.text == "Different artist on TIDAL" && p("Satellite")?.isLeftOut == true, "different artist left out")
        expect(p("Blue Lantern")?.status?.tone == .similar && p("Blue Lantern")?.commands.contains(.leaveOut) == true, "similar: amber, Leave Out")
        expect(p("Afterglow")?.status?.text == "In your download folder", "in download folder")
        expect(p("Echo Park")?.action == .saveAs && p("Echo Park")?.status?.text == "Not downloaded", "clash: Save As…")
        expect(p("Driftwood")?.action == .replace, "damaged: Replace")
        expect(p("Hollow")?.status?.showsSpinner == true, "checking library spinner")
        expect(p("Undertow")?.status?.text == "Preview unavailable" && p("Undertow")?.action == .tryPreviewAgain, "preview unavailable: Try Again")
        expect(p("Tidepool")?.status?.text == "Left out by you", "left out by the person")
        expect(p("Lanterns")?.status == nil && p("Lanterns")?.secondLine == "Spotify: Lanterns (feat. Sample Choir) — Sample Choir", "waiting row: source wording only")
        expect(p("Glass Houses")?.commands.last == .remove, "Remove is always last")
        if let intro = sample.rows.first(where: { $0.item.title == "Intro" }) {
            let label = RowPresentation.accessibilityLabel(m.facts(intro), m.presentation(intro))
            expect(label.hasPrefix("Intro — Extended Mix, explicit, Placeholder Artist,") && label.contains("Hi-Res, downloading 42 percent"),
                   "VoiceOver row label")
        }
    }

    private static func textRules() {
        expect(AddInputKind.classify("https://tidal.com/browse/track/1") == .link, "link classified")
        expect(AddInputKind.classify("blue lantern") == .search("blue lantern"), "search classified")
        expect(AddInputKind.classify("  ") == .empty, "empty classified")
        expect(AppModel.hasSeparator("Blue Lantern - Placeholder Artist") && !AppModel.hasSeparator("Blue-Lantern"), "separator rule")
        expect(AppModel.refusal(for: URL(fileURLWithPath: "/tmp/Blue Lantern.mp3"))?.contains("is an audio file") == true, "audio drop refused")
        expect(AppModel.refusal(for: URL(fileURLWithPath: "/tmp/list.csv")) == nil, "csv accepted")
        expect(Formatting.duration(238) == "3:58" && Formatting.duration(nil) == nil && Formatting.duration(3725) == "1:02:05", "durations")
        expect(Metrics.addFieldWidth(forWindowWidth: 720) == 320 && Metrics.addFieldWidth(forWindowWidth: 980) == 560, "Add field width")
        var summary = BatchSummary(outcome: .someFailed)
        summary.downloaded = 10; summary.failed = 2
        expect(summary.sentence == "Finished with problems: 10 downloaded, 2 failed.", "summary never says finished-clean with failures")
        let lines = Set((0..<10).map { LoadingLines.line(seed: 3, tick: $0) })
        expect(lines.count == 10 && LoadingLines.line(seed: 3, tick: 0) != LoadingLines.line(seed: 3, tick: 1), "loading lines rotate through all ten")
    }

    // MARK: Adding

    private static func addFlows() async {
        let m = model()
        m.beginAdd(.link("https://tidal.com/browse/album/123"), description: "tracks from this link")
        expect(m.adding != nil, "adding cover up")
        let finished = await wait { m.adding == nil }
        expect(finished && m.rows.count == 9, "album link adds 9 rows (got \(m.rows.count))")
        expect(m.activity.entries.last { $0.kind == .added }?.text.hasPrefix("Added 9 tracks from TIDAL link") == true, "add logged")

        // One add at a time.
        m.beginAdd(.link("https://open.spotify.com/playlist/abc"), description: "x")
        let refused = m.beginAdd(.link("https://tidal.com/browse/track/1"), description: "y")
        expect(!refused, "second add refused while one runs")
        // Cancel keeps what's matched.
        _ = await wait(5) { (m.adding?.done ?? 0) >= 15 }
        m.cancelAdd()
        _ = await wait { m.adding == nil }
        let added = m.rows.count - 9
        expect(added > 0 && added < 100, "cancel keeps matches so far (kept \(added))")
        expect(m.activity.entries.contains { $0.text.hasPrefix("Stopped matching after") }, "cancel logged")

        // Duplicates aren't added twice.
        let before = m.rows.count
        m.beginAdd(.link("https://tidal.com/browse/album/123"), description: "again")
        _ = await wait { m.adding == nil }
        expect(m.rows.count == before, "same album twice adds nothing")

        // Signed out: the add waits behind the sign-in alert.
        let signedOut = model(signedIn: false)
        signedOut.beginAdd(.link("https://tidal.com/browse/track/1"), description: "1 track")
        if case .signInToContinue = signedOut.alert { expect(true, "") } else { expect(false, "signed out shows Sign in to continue") }
        expect(signedOut.rows.isEmpty, "nothing added while signed out")

        // A bare pasted name goes to the field.
        signedOut.pasteText("blue lantern")
        expect(signedOut.addFieldText == "blue lantern" && signedOut.focusAddFieldRequest == 1, "bare paste fills the field")

        // Library check runs after an add when a library is set.
        let lib = model()
        lib.settings.libraryFolder = try? FolderReference(url: FileManager.default.temporaryDirectory)
        lib.beginAdd(.line("Slow Motion - Placeholder Artist"), description: "1 track")
        _ = await wait { lib.adding == nil }
        expect(lib.rows.first?.isCheckingLibrary == true, "new row shows Checking library…")
        _ = await wait { lib.rows.first?.isCheckingLibrary == false }
        expect(lib.rows.first?.item.libraryMatch?.kind == .exact && lib.rows.first?.item.included == false,
               "library exact match starts left out")
    }

    // MARK: Undo

    private static func undoFlows() async {
        let m = model()
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        m.rows = StandInSampleQueue.afterBatch(failed: 1, waiting: 5)
        let order = m.rows.map(\.id)

        undo.beginUndoGrouping(); m.remove([order[1], order[3]]); undo.endUndoGrouping()
        expect(m.rows.count == 4 && undo.undoActionName == "Remove from Queue", "remove two, named")
        undo.undo()
        expect(m.rows.map(\.id) == order, "undo remove restores order")
        undo.redo()
        expect(m.rows.count == 4, "redo remove")
        undo.undo()

        undo.beginUndoGrouping(); m.clearQueue(); undo.endUndoGrouping()
        expect(m.rows.isEmpty && undo.undoActionName == "Clear Queue", "clear queue, named")
        undo.undo()
        expect(m.rows.map(\.id) == order, "undo clear queue")

        undo.beginUndoGrouping(); m.setIncluded([order[2]], false); undo.endUndoGrouping()
        expect(m.rows[2].item.included == false && undo.undoActionName == "Leave Out of Download", "leave out, named")
        expect(m.downloadButtonTitle == "Download (5)", "toolbar counts left-out rows")
        undo.undo()
        expect(m.rows[2].item.included == true && m.downloadButtonTitle == "Download All", "undo leave out")

        undo.beginUndoGrouping(); m.move(fromOffsets: [0], toOffset: 3); undo.endUndoGrouping()
        expect(m.rows[2].id == order[0], "move")
        undo.undo()
        expect(m.rows.map(\.id) == order, "undo move")
    }

    // MARK: Batches

    private static func batchFlows() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("robogears-checks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // No folder: the notice says so and nothing starts.
        let noFolder = model()
        noFolder.rows = StandInSampleQueue.afterBatch(failed: 0, waiting: 2)
        noFolder.downloadAll()
        expect(noFolder.batch == nil && noFolder.summary?.outcome == .noFolder, "no folder: notice, no batch")

        // A full Download All: done rows leave, failures stay, library rows cleared, undoable.
        let m = model(folder: folder)
        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        let glass = QueueRow(item: StandIn.item("Glass Houses"))
        let fine = QueueRow(item: StandIn.item("Northern Lights", artist: "Coastline", hiRes: true))
        let fine2 = QueueRow(item: StandIn.item("Seven", artist: "The Band"))
        let lib = QueueRow(item: StandIn.item("Slow Motion"))
        lib.item.libraryMatch = .init(kind: .exact, path: "/x", libraryTitle: "Slow Motion")
        lib.item.included = false
        m.rows = [glass, fine, fine2, lib]
        undo.beginUndoGrouping()
        m.downloadAll()
        expect(m.batch?.total == 3, "batch counts included rows only (got \(m.batch?.total ?? -1))")
        expect(m.batchCounterText == "0 of 3", "counter starts at 0 of 3")
        let ended = await wait(30) { m.batch == nil }
        undo.endUndoGrouping()
        expect(ended, "batch ends")
        expect(m.summary?.outcome == .someFailed && m.summary?.sentence == "Finished with problems: 2 downloaded, 1 failed.",
               "summary: \(m.summary?.sentence ?? "none")")
        expect(m.rows.map(\.item.title) == ["Glass Houses"], "done and library rows leave; failed stays (left \(m.rows.map(\.item.title)))")
        if case .failed(let reason) = m.rows.first?.item.state {
            expect(reason == "TIDAL couldn't send this track. Try again later.", "failure keeps its reason")
        } else { expect(false, "failed row stays failed") }
        expect(m.activity.entries.contains { $0.text.hasPrefix("Cleared 1 track already in your library") }, "library clean-up logged")
        undo.undo()
        expect(m.rows.count == 4, "undo brings cleaned-up rows back (got \(m.rows.count))")

        // Stop mid-batch: unfinished rows go back to waiting; nothing newly red.
        let s = model(folder: folder)
        s.rows = (0..<6).map { QueueRow(item: StandIn.item("Halcyon \($0)", artist: "Harbour Lights")) }
        s.downloadAll()
        _ = await wait(10) { (s.batch?.finished ?? 0) >= 1 }
        s.stopDownloads()
        _ = await wait(10) { s.batch == nil }
        expect(s.summary?.outcome == .stoppedByPerson, "stopped by the person")
        expect(s.rows.allSatisfy { $0.item.state == .waiting && !$0.inBatch }, "unfinished rows wait again")
        expect(s.summary?.sentence.hasPrefix("Stopped: 1 downloaded,") == true || s.summary?.sentence.hasPrefix("Stopped: 2 downloaded,") == true,
               "stop sentence: \(s.summary?.sentence ?? "none")")

        // Remove during a batch takes the row out of it.
        let r = model(folder: folder)
        r.rows = (0..<4).map { QueueRow(item: StandIn.item("Low Tide \($0)", artist: "Coastline")) }
        r.downloadAll()
        let last = r.rows[3].id
        r.remove([last])
        expect(r.batch?.total == 3, "removing a row shrinks the batch")
        _ = await wait(30) { r.batch == nil }
        expect(r.summary?.downloaded == 3, "the removed row never downloads (downloaded \(r.summary?.downloaded ?? -1))")

        // Retry runs only the failed rows and keeps library rows.
        let t = model(folder: folder)
        let failed = QueueRow(item: StandIn.item("Glass Houses"))
        failed.item.state = .failed(reason: "old reason")
        t.rows = [failed, QueueRow(item: StandIn.item("Afterglow"))]
        t.retry([failed.id])
        expect(t.batch?.total == 1 && t.batch?.isDownloadAll == false, "retry batch holds the failed row only")
        _ = await wait(30) { t.batch == nil }
        expect(t.rows.count == 2, "retry leaves the waiting row alone")
    }
}
#endif
