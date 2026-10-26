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
    /// Folders this run made in the temporary folder, removed at the end.
    private static var scratch: [URL] = []

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await runAll()
            print("\(passed) checks passed, \(failures.count) failed")
            for failure in failures { print("FAIL: \(failure)") }
            for folder in scratch { try? FileManager.default.removeItem(at: folder) }
            StorageLocation.removeInstrumentFolder()
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
    }

    /// A fresh folder of this run's own inside the temporary folder.
    private static func scratchFolder(_ name: String) -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("robogears-checks-\(UUID().uuidString)", isDirectory: true)
        scratch.append(parent)
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

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
        // First: nothing below may reach the person's folders or preferences.
        // Without the isolation the other checks don't run at all.
        guard await storageStaysInTheInstrumentFolder() else { return }
        presentationRules()
        textRules()
        waveformRules()
        contrastTableMatchesAssets()
        await addFlows()
        await undoFlows()
        await batchFlows()
        await commandRules()
        alertRules()
        await firstLaunchFlows()
        oldFilesFlows()
        settingsRules()
        await signInAlertFlows()
        await updateRules()
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
        if let blue = sample.rows.first(where: { $0.item.title == "Blue Lantern" }), let own = blue.item.durationSeconds {
            expect(p("Blue Lantern")?.secondLine == "Library: Blue Lantern (Remix) · \(Formatting.duration(own)!) vs \(Formatting.duration(own - 23)!)",
                   "similar: both lengths when more than 10 s apart")
        }
        expect(RowPresentation.lengthComparison(238, 230) == "" && RowPresentation.lengthComparison(238, nil) == ""
               && RowPresentation.lengthComparison(252, 238) == " · 4:12 vs 3:58", "lengths shown only when known and > 10 s apart")
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
        expect(InkProminentLabel.usesCanvas(appearsActive: true, isEnabled: true)
               && !InkProminentLabel.usesCanvas(appearsActive: false, isEnabled: true)
               && !InkProminentLabel.usesCanvas(appearsActive: true, isEnabled: false),
               "the prominent label takes the canvas colour only on the ink fill")
        let lines = Set((0..<10).map { LoadingLines.line(seed: 3, tick: $0) })
        expect(lines.count == 10 && LoadingLines.line(seed: 3, tick: 0) != LoadingLines.line(seed: 3, tick: 1), "loading lines rotate through all ten")
    }

    // MARK: Waveform (DESIGN_DIRECTION 3.4)

    /// Review, 26 Oct: under 200 pt the 1 pt bars overlapped and their alpha
    /// stacked, so an unplayed waveform at the 720 pt window looked played.
    private static func waveformRules() {
        let loud = [Float](repeating: 1, count: 200)
        func layout(_ width: CGFloat, scale: CGFloat = 2, progress: Double = 0, hover: Double? = nil) -> [WaveformBars.Bar] {
            WaveformBars.layout(peaks: loud, size: CGSize(width: width, height: Metrics.waveformHeight), scale: scale,
                                progress: progress, hover: hover, unplayedAlpha: 0.22, hoverMaxAlpha: 0.60)
        }
        for width in [30, 120.5, 185, 199, 200, 333.3, 560] as [CGFloat] {
            for scale in [1, 2] as [CGFloat] {
                let rects = layout(width, scale: scale).map(\.rect).sorted { $0.minX < $1.minX }
                let overlaps = zip(rects, rects.dropFirst()).contains { $1.minX < $0.maxX - 0.001 }
                let alphas = Set(layout(width, scale: scale).map(\.alpha))
                expect(!overlaps && alphas == [0.22] && (rects.last?.maxX ?? .infinity) <= width + 0.5,
                       "a \(width) pt waveform at \(Int(scale))x: bars never overlap, so unplayed stays at 22 %")
            }
        }
        expect(layout(30).count == 30 && layout(600).count == 200, "one bar per point under 200 pt, one per peak above")
        expect(layout(30, progress: 0.5).filter { $0.alpha == 1 }.count == 15
               && layout(600, progress: 0.5).filter { $0.alpha == 1 }.count == 100, "the played half is half the bars at any width")
        // The pointer over a bar's centre: that bar reaches 60 %, the far ones stay at 22 %.
        let narrow = layout(30, hover: 14.5 / 30).map(\.alpha)
        let wide = layout(600, hover: 100.5 / 200).map(\.alpha)
        expect(abs((narrow.max() ?? 0) - 0.60) < 0.001 && abs((wide.max() ?? 0) - 0.60) < 0.001
               && narrow.min() == 0.22 && wide.min() == 0.22, "hover brightens the bar under the pointer to 60 % at any width")
    }

    // MARK: Colours

    /// The harness's Increase Contrast table equals the asset catalog's
    /// high-contrast variants, read from the colour sets' Contents.json in the
    /// source tree (found from this file's compile-time path).
    private static func contrastTableMatchesAssets(sourceFile: String = #filePath) {
        let assets = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets.xcassets")
        guard FileManager.default.fileExists(atPath: assets.path) else {
            expect(false, "asset catalog found at \(assets.path)")
            return
        }
        for (name, variants) in IncreasedContrastTable.colors.sorted(by: { $0.key < $1.key }) {
            let file = assets.appendingPathComponent("\(name).colorset/Contents.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let colors = json["colors"] as? [[String: Any]] else {
                expect(false, "\(name) colour set readable")
                continue
            }
            var found: [String: (hex: String, alpha: Double)] = [:]
            for entry in colors {
                let appearances = (entry["appearances"] as? [[String: String]]) ?? []
                let dark = appearances.contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" }
                let high = appearances.contains { $0["appearance"] == "contrast" && $0["value"] == "high" }
                guard high, let components = (entry["color"] as? [String: Any])?["components"] as? [String: String] else { continue }
                func byte(_ key: String) -> Int {
                    let raw = components[key] ?? "0"
                    return raw.hasPrefix("0x") ? Int(raw.dropFirst(2), radix: 16) ?? 0 : Int(((Double(raw) ?? 0) * 255).rounded())
                }
                let hex = String(format: "%02X%02X%02X", byte("red"), byte("green"), byte("blue"))
                found[dark ? "dark" : "light"] = (hex, Double(components["alpha"] ?? "1") ?? 1)
            }
            let ok = found["light"]?.hex == variants.lightHex && found["dark"]?.hex == variants.darkHex
                && abs((found["light"]?.alpha ?? -1) - Double(variants.alpha)) < 0.005
                && abs((found["dark"]?.alpha ?? -1) - Double(variants.alpha)) < 0.005
            expect(ok, "\(name) Increase Contrast table matches the asset catalog")
        }
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

        await batchStartedAsTheLastEnds()
    }

    /// Review, 26 Oct: the end of a batch waited on the queue save before
    /// ending its keep-awake and Dock bar, so a batch started in that moment
    /// lost its own and the first one's never ended. This model saves (into
    /// a scratch folder) so the save really waits.
    private static func batchStartedAsTheLastEnds() async {
        let support = scratchFolder("Support")
        var settings = AppSettings()
        settings.playSoundEffects = false
        settings.downloadFolder = try? FolderReference(url: scratchFolder("Downloads"))
        let m = AppModel(services: StandIn.services(), player: StandInPreviewPlayer(), settings: settings,
                         settingsStore: SettingsStore(file: AppPaths.settingsFile(in: support)),
                         queueStore: QueueStore(file: AppPaths.queueFile(in: support)), update: nil)
        m.prepareForSnapshot()
        m.signInState = .signedIn(country: nil)
        let first = QueueRow(item: StandIn.item("Low Tide 0", artist: "Coastline"))
        first.item.state = .failed(reason: "TIDAL couldn't send this track. Try again later.")
        m.rows = [first] + (1..<6).map { QueueRow(item: StandIn.item("Low Tide \($0)", artist: "Coastline")) }
        m.retry([first.id])
        expect(m.persists && m.batch?.total == 1, "a one-track batch runs on a model that saves")
        // Start the next batch the first moment the main actor sees no batch.
        let end = Date().addingTimeInterval(30)
        while m.batch != nil, Date() < end { await Task.yield() }
        m.downloadAll()
        let started = m.batch != nil
        try? await Task.sleep(for: .milliseconds(400))
        expect(started && m.batch != nil && m.awakeActivity != nil,
               "a batch started as the last one ends keeps its own keep-awake (the Mac stays awake)")
        m.stopDownloads()
        _ = await wait(30) { m.batch == nil }
        expect(m.awakeActivity == nil, "and it ends with that batch")
    }

    // MARK: Menu commands (DESIGN_DIRECTION 5)

    private static func commandRules() async {
        // Retry Selected when a selected row failed; otherwise Retry All Failed (N).
        let f = model()
        let a = QueueRow(item: StandIn.item("Glass Houses"))
        a.item.state = .failed(reason: "TIDAL couldn't send this track. Try again later.")
        let b = QueueRow(item: StandIn.item("Echo Park"))
        b.item.state = .failed(reason: "TIDAL couldn't send this track. Try again later.")
        f.rows = [a, b, QueueRow(item: StandIn.item("Afterglow"))]
        expect(f.retryTitle == "Retry All Failed (2)", "retry names the failed count")
        expect(BatchSummary.Button.retryFailed(2).title == f.retryTitle,
               "the summary notice and the queue header give Retry the same name")
        f.selection = [a.id]
        expect(f.retryTitle == "Retry Selected", "retry follows the selection")

        // ⌘. answers the frontmost thing: a sheet › the adding cover › the batch.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("robogears-checks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let m = model(folder: folder)
        m.rows = (0..<8).map { QueueRow(item: StandIn.item("Halcyon \($0)", artist: "Harbour Lights")) }
        m.downloadAll()
        expect(m.canStopFromMenu && m.stopCommandTitle == "Stop Downloads", "during a batch the menu offers Stop Downloads")
        m.sheet = .whatsNew
        expect(m.isModalUp && !m.canDownload, "with a sheet up ⌘↩ has nothing to start")
        expect(!m.canStopFromMenu, "with a sheet up the menu's ⌘. is unavailable; the sheet's own ⌘. answers")
        m.cancelFrontmost()
        expect(m.sheet == nil && m.batch?.stoppedByPerson == false, "⌘. closes the sheet first; downloads keep going")
        // Review, 26 Oct: an alert used to be skipped, so ⌘. stopped the
        // downloads and left "Update now or when downloads finish?" up.
        m.alert = .updateDuringBatch(remaining: 8)
        m.sheet = nil
        expect(!m.canStopFromMenu, "with an alert up the menu's ⌘. is unavailable")
        m.cancelFrontmost()
        expect(m.alert == nil && m.batch?.stoppedByPerson == false, "⌘. closes an alert first; downloads keep going")
        m.settingsAlert = .resetFolders
        m.cancelFrontmost()
        expect(m.settingsAlert == nil && m.batch?.stoppedByPerson == false, "⌘. closes Settings' alert first; downloads keep going")
        m.beginAdd(.link("https://tidal.com/browse/album/123"), description: "tracks from this link")
        expect(m.adding != nil, "adding works during a batch")
        expect(m.canStopFromMenu && m.stopCommandTitle == "Stop Adding Tracks",
               "with an add running during a batch, the menu item says it stops the add")
        m.cancelFrontmost()
        _ = await wait { m.adding == nil }
        expect(m.batch != nil && m.batch?.stoppedByPerson == false, "⌘. stops the add before the downloads")
        m.cancelFrontmost()
        expect(m.batch?.stoppedByPerson == true, "then ⌘. stops the downloads")
        _ = await wait(30) { m.batch == nil }
        expect(m.summary?.outcome == .stoppedByPerson, "stopped by the person after ⌘.")
    }
    // MARK: Storage (an instrument run never touches the person's folders)

    /// 26 Oct: a test run left a real settings file with a download folder,
    /// so a first launch looked as if a default folder existed. This run's
    /// settings, queue, small values and old-files folder must all live in
    /// its own temporary folder, and the real factory must save there.
    private static func storageStaysInTheInstrumentFolder() async -> Bool {
        func path(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let applicationSupport = path(AppPaths.supportDirectory().deletingLastPathComponent())
        let temporary = path(FileManager.default.temporaryDirectory)
        let support = path(StorageLocation.supportDirectory)
        let legacy = path(StorageLocation.legacyElectronDirectory)
        let isolated = StorageLocation.isIsolated
            && support.hasPrefix(temporary + "/") && legacy.hasPrefix(temporary + "/")
            && !support.hasPrefix(applicationSupport + "/") && !legacy.hasPrefix(applicationSupport + "/")
            && StorageLocation.values is InMemoryValues
        expect(isolated, "the checks keep settings, the queue and small values in a temporary folder of their own, never in Application Support or the preferences (support: \(support))")
        // Nothing gets saved until that holds, so a broken isolation fails
        // here without writing anything to the person's folders.
        guard isolated else { return false }

        let first = AppModel.live()
        first.preloadingEnabled = false
        expect(first.persists, "the real factory saves")
        expect(first.settings.downloadFolder == nil && first.settings.libraryFolder == nil,
               "a first launch starts with no download folder (product rule 1)")
        expect(first.update == nil, "an instrument run builds no updater")
        expect(first.services.oldFiles is LegacyElectronFiles && path(first.services.oldFiles.folder) == legacy,
               "the running app's old-files notice uses LegacyElectronFiles (here pointed at the run's own folder)")
        let downloads = scratchFolder("Downloads")
        expect(first.setDownloadFolder(downloads), "a download folder can be chosen")
        first.appendRows([QueueRow(item: StandIn.item("Blue Lantern"))])
        await first.flushQueue()
        expect(exists(AppPaths.settingsFile(in: StorageLocation.supportDirectory))
               && exists(AppPaths.queueFile(in: StorageLocation.supportDirectory)),
               "settings and queue are saved inside the run's own folder")
        let second = AppModel.live()
        expect(second.settings.downloadFolder.map { path(URL(fileURLWithPath: $0.lastKnownPath)) } == path(downloads),
               "a second model reads the folder back from the run's own folder")
        first.setSkippedVersion("0.1.99")
        first.markShown(.moveToApplications)
        expect(StorageLocation.values.string(forKey: AppModel.skippedVersionKey) == "0.1.99"
               && StorageLocation.values.bool(forKey: FirstLaunch.moveOfferedKey),
               "small values stay in memory")

        // The instruments' own models never save at all.
        expect(!model().persists && !SnapshotScenarios.baseModel().persists && !SnapshotWindows.model().persists
               && !SnapshotWindows.settingsModel().persists, "snapshot and check models save nothing")
        let standIn = StandIn.services().oldFiles
        expect(!(standIn is LegacyElectronFiles) && standIn.presentItems().isEmpty && !standIn.shouldOfferNotice,
               "the instruments' old files are samples that never look at the disk")
        return true
    }

    // MARK: Alerts (4.6, 4.8, 4.9, 4.11, 4.12)

    private static func alertRules() {
        let pending = PendingAdd(source: .tracklist(text: "", name: nil), description: "2 tracks from pasted text")
        let routes: [AlertRoute] = [
            .signInToContinue(pending), .quitDuringBatch(remaining: 12), .updateDuringBatch(remaining: 1),
            .largeImport(lines: 12_000, text: "", name: nil), .resetFolders, .moveToApplications,
            .information(title: "You're up to date.", message: nil),
        ]
        for route in routes {
            let content = route.content
            expect(content.buttons.filter(\.isDefault).count == 1, "\(route.id): exactly one default button")
            let alert = content.makeNSAlert()
            expect(alert.buttons.first?.title == content.defaultButton?.title && alert.buttons.first?.keyEquivalent == "\r"
                   && content.action(for: .alertFirstButtonReturn) == content.defaultButton?.action,
                   "\(route.id): the default is the first NSAlert button and answers Return")
        }
        expect(content(of: routes).allSatisfy { $0.defaultButton?.title != "Cancel" }, "Cancel is never the default button")
        let quit = AlertRoute.quitDuringBatch(remaining: 12).content
        let quitAlert = quit.makeNSAlert()
        expect(quit.title == "Quit while 12 tracks are still downloading?" && quit.defaultButton?.title == "Keep Downloading"
               && quit.defaultButton?.role == .cancel && quit.action(for: .alertSecondButtonReturn) == .quit
               && quitAlert.buttons.last?.title == "Quit" && quitAlert.buttons.last?.keyEquivalent == "",
               "quit during a batch: Keep Downloading answers Return; Quit has no key (Escape is a live check)")
        expect(AlertRoute.quitDuringBatch(remaining: 1).content.title == "Quit while 1 track is still downloading?", "quit alert singular")
        let update = AlertRoute.updateDuringBatch(remaining: 12).content
        expect(update.defaultButton?.action == .updateWhenDownloadsFinish && update.buttons.contains { $0.role == .cancel },
               "update during a batch: waiting is the default; Cancel is there")
        // Review, 26 Oct (alerts.md › Buttons): the person chose Reset
        // Folders… on purpose, so Reset is the default and not red; this
        // replaces the earlier rule that made Cancel the default.
        let reset = AlertRoute.resetFolders.content
        expect(reset.defaultButton?.action == .resetFolders && reset.defaultButton?.role == .normal
               && reset.buttons.contains { $0.title == "Cancel" && $0.role == .cancel && !$0.isDefault },
               "Reset Folders: Reset is the default and not destructive; Cancel answers Escape")
        expect(AlertRoute.moveToApplications.content.defaultButton?.action == .moveToApplications
               && AlertRoute.moveToApplications.content.buttons.contains { $0.title == "Not Now" && $0.role == .cancel },
               "Move to Applications: Move is the default, Not Now cancels")

        // ⌘Q during a batch asks; after Quit was chosen, or to install an update, it doesn't.
        var batch = BatchState(folder: URL(fileURLWithPath: "/tmp/none"), ids: [], total: 12, isDownloadAll: true)
        batch.finished = 2
        expect(QuitDecision.make(batch: nil, quitConfirmed: false, quittingForUpdate: false) == .quit, "quit with no batch")
        expect(QuitDecision.make(batch: batch, quitConfirmed: false, quittingForUpdate: false) == .ask(remaining: 10),
               "quit during a batch asks, naming what's left")
        expect(QuitDecision.make(batch: batch, quitConfirmed: true, quittingForUpdate: false) == .quit
               && QuitDecision.make(batch: batch, quitConfirmed: false, quittingForUpdate: true) == .quit,
               "a confirmed quit or an update's quit goes straight through")
    }

    private static func content(of routes: [AlertRoute]) -> [AlertContent] { routes.map(\.content) }

    // MARK: First launch (4.11; D4 5.11, 5.15)

    private static func firstLaunchFlows() async {
        expect(FirstLaunch.notices(moveOffered: false, outsideApplications: true, oldFilesShown: false,
                                   oldFilesPresent: true, oldAppRunning: false) == [.moveToApplications, .oldFiles],
               "Move to Applications first, then the old files")
        expect(FirstLaunch.notices(moveOffered: true, outsideApplications: true, oldFilesShown: true,
                                   oldFilesPresent: true, oldAppRunning: false).isEmpty, "each question only once")
        expect(FirstLaunch.notices(moveOffered: false, outsideApplications: false, oldFilesShown: false,
                                   oldFilesPresent: true, oldAppRunning: true).isEmpty,
               "no move offer inside Applications; the old files wait while the old app runs")
        expect(FirstLaunch.notices(moveOffered: false, outsideApplications: false, oldFilesShown: false,
                                   oldFilesPresent: false, oldAppRunning: false).isEmpty, "no notice without old files")
        expect(FirstLaunch.pendingNotices(oldFiles: StandInOldAppFiles(sampleItems: ["token.json"]), oldAppNoticeShown: false).isEmpty,
               "debug builds never offer the move or the old-files notice")

        // One after the other, never together; the old-files notice is
        // remembered in the settings file (AppSettings.oldAppNoticeShown).
        let m = model()
        // The storage check recorded the offer already; start from "never asked".
        StorageLocation.values.removeObject(forKey: FirstLaunch.moveOfferedKey)
        let before = StorageLocation.values.bool(forKey: FirstLaunch.moveOfferedKey)
        m.firstLaunchQueue = [.moveToApplications, .oldFiles]
        m.presentNextFirstLaunchNotice()
        let asked = await wait(5) { m.alert == .moveToApplications }
        expect(asked && m.sheet == nil, "the move offer comes alone")
        expect(!before && StorageLocation.values.bool(forKey: FirstLaunch.moveOfferedKey), "the move offer is remembered once shown")
        expect(!m.settings.oldAppNoticeShown, "the old-files notice isn't marked before it shows")
        m.alert = nil
        let second = await wait(5) { m.sheet == .oldFiles }
        expect(second && m.alert == nil, "the old-files notice follows once the alert has gone")
        expect(m.settings.oldAppNoticeShown && m.firstLaunchQueue.isEmpty, "the old-files notice is recorded in settings: explained once")
    }

    // MARK: The previous version's files (D4 5.11), through the real type in a scratch folder

    private static func oldFilesFlows() {
        let legacy = scratchFolder("robogears Downloader")
        let trash = scratchFolder("Trash")
        let fm = FileManager.default
        for name in ["settings.json", "queue.json", "token.json", "update-cache.json"] {
            fm.createFile(atPath: legacy.appendingPathComponent(name).path, contents: Data("{}".utf8))
        }
        try? fm.createDirectory(at: legacy.appendingPathComponent("Cache"), withIntermediateDirectories: true)
        let files = LegacyElectronFiles(folder: legacy) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        var services = StandIn.services()
        services.oldFiles = files
        let m = AppModel(services: services, player: StandInPreviewPlayer(), settings: AppSettings(),
                         settingsStore: nil, queueStore: nil, update: nil)
        m.prepareForSnapshot()
        expect(files.shouldOfferNotice && files.hasOldSignIn, "the old files and the old sign-in are found by exact name")
        expect(m.deleteOldSignIn() == nil && !exists(legacy.appendingPathComponent("token.json"))
               && !exists(trash.appendingPathComponent("token.json")) && exists(legacy.appendingPathComponent("settings.json")),
               "Delete Old Sign-in removes token.json for good and nothing else")
        expect(m.trashOldFiles() == nil, "Move to Trash succeeds")
        expect(!exists(legacy.appendingPathComponent("settings.json")) && !exists(legacy.appendingPathComponent("Cache"))
               && exists(trash.appendingPathComponent("queue.json")) && exists(legacy.appendingPathComponent("update-cache.json")),
               "Move to Trash moves only the known items; update-cache.json stays")
        expect(m.activity.entries.last?.text == "Moved 3 items from the previous version to the Trash.",
               "the log says what moved (got \(m.activity.entries.last?.text ?? "nothing"))")

        // A Trash that refuses: the notice says what's left and where.
        fm.createFile(atPath: legacy.appendingPathComponent("settings.json").path, contents: Data("{}".utf8))
        var refusing = services
        refusing.oldFiles = LegacyElectronFiles(folder: legacy) { _ in throw CocoaError(.fileWriteNoPermission) }
        let r = AppModel(services: refusing, player: StandInPreviewPlayer(), settings: AppSettings(),
                         settingsStore: nil, queueStore: nil, update: nil)
        let problem = r.trashOldFiles()
        expect(problem?.contains("1 item is still in") == true, "a refused Trash says what's left (got \(problem ?? "nothing"))")
        expect(exists(legacy.appendingPathComponent("settings.json")), "nothing is lost when the Trash refuses")
    }

    // MARK: Settings (4.12)

    private static func settingsRules() {
        let library = scratchFolder("Library")
        let inside = library.appendingPathComponent("TIDAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let m = model()
        expect(m.setLibraryFolder(library), "a library folder can be chosen")
        expect(!m.setDownloadFolder(inside) && m.folderProblem == .download(AppModel.downloadInsideLibraryMessage)
               && m.settings.downloadFolder == nil, "a download folder inside the library is refused with the message")
        let outside = scratchFolder("Downloads")
        expect(m.setDownloadFolder(outside) && m.folderProblem == nil, "a folder outside the library is taken")
        let parentOfDownloads = outside.deletingLastPathComponent()
        expect(!m.setLibraryFolder(parentOfDownloads) && m.folderProblem == .library(AppModel.libraryContainsDownloadMessage),
               "a library that contains the download folder is refused")

        m.askToResetFolders()
        expect(m.settingsAlert == .resetFolders, "Reset Folders… asks first")
        m.settingsAlert = nil
        m.perform(.resetFolders)
        expect(m.settings.downloadFolder == nil && m.settings.libraryFolder == nil && m.isSignedIn,
               "Reset forgets both folders and keeps the TIDAL sign-in")

        // Sign In… / Sign Out are unavailable during a batch.
        m.batch = BatchState(folder: outside, ids: [], total: 3, isDownloadAll: true)
        expect(!m.canChangeSignIn, "sign-in changes wait for the batch")
        m.showSignIn(onSettings: true)
        expect(!m.isSettingsSignInPresented, "Sign In Again… does nothing during a batch")
        m.batch = nil
        m.showSignIn(onSettings: true)
        expect(m.isSettingsSignInPresented && m.isSigningIn && m.isModalUp, "Sign In… from Settings opens its sheet; one at a time")
        m.showSignIn()
        expect(m.sheet == nil, "no second sign-in sheet on the main window")
        m.isSettingsSignInPresented = false

        // A sign-in in progress may switch the account: no batch starts under it (D4 1.2).
        let d = model(folder: scratchFolder("Downloads"))
        let failed = QueueRow(item: StandIn.item("Glass Houses"))
        failed.item.state = .failed(reason: "TIDAL couldn't send this track. Try again later.")
        d.rows = [QueueRow(item: StandIn.item("Afterglow")), failed]
        d.isSettingsSignInPresented = true
        expect(!d.canDownload, "Download All is unavailable while signing in")
        d.downloadAll()
        d.retry([failed.id])
        expect(d.batch == nil && d.sheet == nil, "no batch and no second sign-in sheet while Settings signs in")
        d.isSettingsSignInPresented = false
        let signedOut = model(signedIn: false, folder: scratchFolder("Downloads"))
        signedOut.rows = [QueueRow(item: StandIn.item("Afterglow"))]
        signedOut.downloadAll()
        expect(signedOut.batch == nil && signedOut.sheet == .signIn(resumeAdd: nil), "Download All signed out opens the sign-in sheet")

        m.signInState = .signedIn(country: "United States")
        expect(m.signInStatusText == "Signed in to TIDAL · United States", "signed-in line names the country only")
        m.signInState = .invalid
        expect(m.signInStatusText == "Your TIDAL sign-in is no longer valid.", "invalid sign-in line")
        m.signInState = .signedOut
        expect(m.signInStatusText == "Not signed in", "signed-out line")

        expect(LibraryStatus.scanning(done: 120, total: 500).text == "Scanning 120 / 500…"
               && LibraryStatus.indexed(files: 1_240).text == "1,240 files indexed"
               && LibraryStatus.indexed(files: 1).text == "1 file indexed", "library status lines")
        expect(UpdateStatusLine.rateLimited.text == "GitHub is limiting checks; try again in an hour"
               && UpdateStatusLine.offline.text == "No internet connection", "offline and rate limit read differently")
    }

    // MARK: Sign in to continue (4.6; D4 1.2, 1.3)

    private static func signInAlertFlows() async {
        // Review, 26 Oct: the alert's Sign In… skipped the one-at-a-time
        // rule, so a second sign-in could run beside Settings' own.
        let pending = PendingAdd(source: .tracklist(text: "", name: nil), description: "2 tracks from pasted text")
        let s = model(signedIn: false)
        s.isSettingsSignInPresented = true
        s.perform(.signIn(pending))
        let besideSettings = await wait(1.5) { s.sheet != nil }
        expect(!besideSettings && s.activity.entries.last?.text == "Finish signing in to TIDAL in Settings, then try again.",
               "Sign In… in the alert opens no second sign-in while Settings signs in, and says why")
        s.isSettingsSignInPresented = false
        s.batch = BatchState(folder: URL(fileURLWithPath: "/tmp/none"), ids: [], total: 3, isDownloadAll: true)
        s.perform(.signIn(pending))
        let duringBatch = await wait(1.5) { s.sheet != nil }
        expect(!duringBatch, "Sign In… in the alert opens no sign-in during a batch")
        s.batch = nil
        s.perform(.signIn(pending))
        let opened = await wait(5) { s.sheet != nil }
        expect(opened && s.sheet == .signIn(resumeAdd: pending), "otherwise Sign In… opens the sign-in sheet")

        // Review, 26 Oct: Search TIDAL… on a "Not on TIDAL" row, signed out,
        // came back after sign-in as a plain search that added a new row.
        let p = model(signedIn: false)
        let lost = QueueRow(item: StandIn.item("Midnight Static"))
        p.rows = [lost]
        p.searchTIDAL(for: lost.id)
        guard case .signInToContinue(let held) = p.alert else {
            expect(false, "Search TIDAL… signed out asks to sign in")
            return
        }
        expect(held.pickOneRowID == lost.id, "the held search remembers its row")
        p.alert = nil
        p.signInState = .signedIn(country: nil)
        p.continueAfterSignIn(held)
        let picking = await wait(10) { if case .pickOne(let id, _, _) = p.sheet { id == lost.id } else { false } }
        expect(picking && p.rows.count == 1, "after sign-in, Search TIDAL… comes back in pick-one mode for its row")
    }

    // MARK: Updates (4.2, 4.8; D4 5.9, 5.12)

    private static func updateRules() async {
        expect(UpdateControlState.available(version: "0.1.32").title == "Update to 0.1.32"
               && UpdateControlState.available(version: "0.1.32").isEnabled, "update control: Update to 0.1.32")
        expect(UpdateControlState.downloading(percent: 42).title == "Downloading 42%"
               && !UpdateControlState.downloading(percent: 42).isEnabled, "update control: downloading is unavailable")
        expect(!UpdateControlState.afterDownloads.isEnabled && UpdateControlState.relaunchToUpdate.isEnabled,
               "update control: waiting for the batch, or for a quit")

        let m = model()
        m.batch = BatchState(folder: URL(fileURLWithPath: "/tmp/none"), ids: [], total: 12, isDownloadAll: true)
        m.updateControlClicked()
        expect(m.alert == .updateDuringBatch(remaining: 12), "Update during a batch asks first")
        m.alert = nil
        m.perform(.updateWhenDownloadsFinish)
        expect(m.updateAfterBatch && m.batch?.stoppedByPerson == false, "Update When Downloads Finish waits; downloads keep going")
        m.updateAfterBatch = false
        m.perform(.updateNow)
        expect(m.updateAfterBatch && m.batch?.stoppedByPerson == true, "Update Now stops the downloads, then updates")

        // Review, 26 Oct: the batch can end while the alert is still up.
        // Either button then updates at once; neither waits for a batch
        // that's gone (which left the control stuck on "Relaunching…").
        for (button, name) in [(AlertAction.updateWhenDownloadsFinish, "Update When Downloads Finish"), (.updateNow, "Update Now")] {
            let late = model(folder: scratchFolder("Downloads"))
            late.rows = [QueueRow(item: StandIn.item("Low Tide 0", artist: "Coastline"))]
            late.downloadAll()
            late.updateControlClicked()
            let ended = await wait(30) { late.batch == nil }
            expect(ended && late.alert == .updateDuringBatch(remaining: 1), "the alert outlives the batch it asked about")
            late.alert = nil
            late.perform(button)
            expect(!late.updateAfterBatch && late.batch == nil, "\(name) after the batch ended updates now, not after a next batch")
        }
    }
}
#endif
