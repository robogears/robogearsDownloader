import AppKit
import RobogearsCore
import SwiftUI

/// The harness's second half (a debug instrument, never shipped behaviour):
/// everything outside the main window, rendered off-screen at 2× in Light,
/// Dark and both Increase Contrast looks. Sheets draw on the system window
/// background in a borderless window (a real sheet hangs from its window's
/// title bar; the content and controls are the same). Alerts are NSAlerts
/// built from the app's AlertContent: the quit alert as presented, the
/// SwiftUI-presented ones approximately. Settings panes sit under a real preference-style
/// toolbar. No window is ever shown, nothing is saved, nothing is loaded.
@MainActor
enum SnapshotWindows {
    typealias Look = SnapshotHarness.Look

    struct Item {
        var name: String
        var looks: [Look] = Look.all
        var render: @MainActor (Look, URL) -> Bool
    }

    static func renderAll(into directory: URL, only: String?) -> [String] {
        var written: [String] = []
        for item in items() where only.map({ item.name.hasPrefix($0) }) ?? true {
            let started = Date()
            for look in item.looks {
                let url = directory.appendingPathComponent("\(item.name)-\(look.name).png")
                IncreasedContrastTable.isForced = look.overrides.increasedContrast == true
                if item.render(look, url) { written.append(url.path) }
                IncreasedContrastTable.isForced = false
            }
            FileHandle.standardError.write(Data(String(format: "%@: %.1f s\n", item.name, Date().timeIntervalSince(started)).utf8))
        }
        return written
    }

    // MARK: What gets rendered

    static func items() -> [Item] {
        var list: [Item] = []

        // Sign-in sheet (4.6): before the link, waiting with the code, failed, signed in.
        let link = URL(string: "https://link.tidal.com/ABCDE")!
        let signInStates: [(String, SignInSheetState)] = [
            ("starting", SignInSheetState()),
            ("waiting", SignInSheetState(link: link, code: "ABCDE", status: "Waiting for TIDAL…")),
            ("failed", SignInSheetState(link: link, code: "ABCDE", status: "The sign-in code expired. Click Try Again for a new one.",
                                        failure: "The sign-in code expired. Click Try Again for a new one.")),
            ("signed-in", SignInSheetState(link: link, code: "ABCDE", status: "Signed in.", signedIn: true)),
        ]
        for (name, state) in signInStates {
            list.append(Item(name: "sheet-sign-in-\(name)") { look, url in
                sheet(SignInSheet(model: model(), resume: nil, preset: state), look: look, to: url)
            })
        }

        // Search results (4.7): library marks, an In Queue row, one ticked;
        // refined; no results; pick-one mode.
        list.append(Item(name: "sheet-search-results") { look, url in
            let (m, results) = searchModel()
            return sheet(SearchResultsSheet(model: m, query: "Blue Lantern", results: results, pickOneRowID: nil,
                                            presetTicked: [results[1].id]),
                         size: CGSize(width: 600, height: 480), look: look, to: url)
        })
        list.append(Item(name: "sheet-search-refined", looks: [Look.light, Look.dark]) { look, url in
            let (m, results) = searchModel()
            return sheet(SearchResultsSheet(model: m, query: "Blue Lantern", results: results, pickOneRowID: nil,
                                            presetTicked: [results[1].id, results[2].id], presetRefine: "mix"),
                         size: CGSize(width: 600, height: 480), look: look, to: url)
        })
        list.append(Item(name: "sheet-search-empty") { look, url in
            sheet(SearchResultsSheet(model: model(), query: "Blue Lanturn Placeholdr", results: [], pickOneRowID: nil),
                  size: CGSize(width: 600, height: 480), look: look, to: url)
        })
        list.append(Item(name: "sheet-pick-one") { look, url in
            let (m, results) = searchModel()
            return sheet(SearchResultsSheet(model: m, query: "Glass Orchard Northbound Choir", results: results,
                                            pickOneRowID: UUID(), presetHighlight: results[0].id),
                         size: CGSize(width: 600, height: 480), look: look, to: url)
        })

        // What's New (4.8), and the copy that can't install itself.
        list.append(Item(name: "sheet-whats-new") { look, url in
            sheet(WhatsNewSheet(model: updateModel(canSelfInstall: true)), look: look, to: url)
        })
        list.append(Item(name: "sheet-whats-new-release-page", looks: [Look.light, Look.dark]) { look, url in
            sheet(WhatsNewSheet(model: updateModel(canSelfInstall: false)), look: look, to: url)
        })

        // The previous version's files (4.11, D4 5.11), with and without the old sign-in.
        list.append(Item(name: "sheet-old-files") { look, url in
            sheet(OldFilesSheet(model: model(oldItems: ["settings.json", "queue.json", "token.json", "Cache", "Local Storage"])),
                  look: look, to: url)
        })
        list.append(Item(name: "sheet-old-files-no-sign-in", looks: [Look.light, Look.dark]) { look, url in
            sheet(OldFilesSheet(model: model(oldItems: ["settings.json", "queue.json", "Cache"])), look: look, to: url)
        })

        // Alerts from the same AlertContent. The quit alert with the window
        // closed is exactly this NSAlert; the others are presented through
        // SwiftUI's `.alert`, so these are close approximations of them.
        let pending = PendingAdd(source: .tracklist(text: "", name: nil), description: "2 tracks from pasted text")
        let alerts: [(String, AlertRoute)] = [
            ("sign-in-to-continue", .signInToContinue(pending)),
            ("quit-during-batch", .quitDuringBatch(remaining: 12)),
            ("update-during-batch", .updateDuringBatch(remaining: 12)),
            ("reset-folders", .resetFolders),
            ("move-to-applications", .moveToApplications),
            ("large-import", .largeImport(lines: 12_000, text: "", name: nil)),
            ("check-up-to-date", .information(title: "You're up to date.",
                                              message: "robogears Downloader 0.1.31 is the newest version.")),
        ]
        for (name, route) in alerts {
            list.append(Item(name: "alert-\(name)") { look, url in alert(route.content, look: look, to: url) })
        }

        // Settings (4.12): every pane, plus the states that change a pane.
        let settings: [(String, SettingsPane, @MainActor () -> AppModel)] = [
            ("general", .general, { settingsModel() }),
            ("general-notifications-off", .general, {
                let m = settingsModel(notify: true)
                m.notificationsBlocked = true
                return m
            }),
            ("folders", .folders, { settingsModel() }),
            ("folders-scanning-during-batch", .folders, {
                let m = settingsModel()
                m.libraryStatus = .scanning(done: 120, total: 500)
                m.folderProblem = .download(AppModel.downloadInsideLibraryMessage)
                m.batch = BatchState(folder: SnapshotScenarios.folderURL, ids: [], total: 12, isDownloadAll: true)
                return m
            }),
            ("folders-not-chosen", .folders, { settingsModel(folders: false) }),
            ("tidal", .tidal, { settingsModel() }),
            ("tidal-signed-out", .tidal, { settingsModel(signedIn: false) }),
            ("tidal-invalid", .tidal, {
                let m = settingsModel(signedIn: false)
                m.signInState = .invalid
                return m
            }),
            ("tidal-during-batch", .tidal, {
                let m = settingsModel()
                m.batch = BatchState(folder: SnapshotScenarios.folderURL, ids: [], total: 12, isDownloadAll: true)
                return m
            }),
            ("updates", .updates, { settingsModel(status: .upToDate) }),
            ("updates-available", .updates, {
                let m = settingsModel(status: .available(version: "0.1.32"))
                m.updateInfoOverride = sampleUpdate(canSelfInstall: true)
                return m
            }),
            ("updates-offline", .updates, { settingsModel(status: .offline) }),
            ("updates-rate-limited", .updates, { settingsModel(status: .rateLimited) }),
        ]
        for (name, pane, make) in settings {
            list.append(Item(name: "settings-\(name)") { look, url in settingsWindow(pane, model: make(), look: look, to: url) })
        }

        // About (4.13).
        list.append(Item(name: "about") { look, url in
            titledWindow(AboutWindow(model: model()), title: "About robogears Downloader", showsTitle: false,
                         size: Metrics.aboutSize, look: look, to: url)
        })

        // The Dock tile during a batch (3.3): one look each, the tile doesn't follow the appearance.
        list.append(Item(name: "dock-tile-42-percent", looks: [Look.light]) { look, url in dockTile(fraction: 0.42, to: url) })
        list.append(Item(name: "dock-tile-3-percent", looks: [Look.light]) { look, url in dockTile(fraction: 0.03, to: url) })
        return list
    }

    // MARK: Sample models

    static func model(signedIn: Bool = true, oldItems: [String] = []) -> AppModel {
        var services = StandIn.services()
        services.oldFiles = StandInOldAppFiles(sampleItems: oldItems)
        var settings = AppSettings()
        settings.downloadFolder = SnapshotScenarios.folderReference
        let model = AppModel(services: services, player: StandInPreviewPlayer(), settings: settings,
                             settingsStore: nil, queueStore: nil, update: nil)
        model.prepareForSnapshot()
        model.signInState = signedIn ? .signedIn(country: "United States") : .signedOut
        return model
    }

    static var libraryReference: FolderReference? {
        let path = NSHomeDirectory() + "/Music/Library"
        let json = #"{"bookmark":"","lastKnownPath":"\#(path)"}"#
        return try? JSONDecoder().decode(FolderReference.self, from: Data(json.utf8))
    }

    static func settingsModel(signedIn: Bool = true, folders: Bool = true, notify: Bool = false,
                              status: UpdateStatusLine = .none) -> AppModel {
        var settings = AppSettings()
        if folders {
            settings.downloadFolder = SnapshotScenarios.folderReference
            settings.libraryFolder = libraryReference
        }
        settings.notifyWhenDownloadsFinish = notify
        let model = AppModel(services: StandIn.services(), player: StandInPreviewPlayer(), settings: settings,
                             settingsStore: nil, queueStore: nil, update: nil)
        model.prepareForSnapshot()
        model.signInState = signedIn ? .signedIn(country: "United States") : .signedOut
        model.libraryStatus = folders ? .indexed(files: 1_240) : .none
        model.previewCacheBytes = 84_000_000
        model.updateStatusOverride = status
        return model
    }

    /// Ten results: library marks, one already queued.
    static func searchModel() -> (AppModel, [SearchResult]) {
        let m = model()
        var results = [
            StandIn.item("Blue Lantern", version: "Extended Mix", hiRes: true, explicit: true),
            StandIn.item("Blue Lantern", hiRes: true),
            StandIn.item("Blue Lantern", version: "Radio Edit", artist: "Another Artist"),
            StandIn.item("Blue Lantern", version: "Live", artist: "Placeholder Artist", album: "Live at the Harbour"),
            StandIn.item("Blue Lantern", version: "Dub Mix", artist: "Sunline", hiRes: true),
            StandIn.item("Blue Lanterns", artist: "Sample Choir"),
            StandIn.item("Blue Lantern", version: "Remastered", artist: "Coastline", hiRes: true),
            StandIn.item("Blue Lantern", version: "Acoustic", artist: "Harbour Lights"),
        ].map { SearchResult(track: $0) }
        results[0].track.libraryMatch = .init(kind: .similar, path: NSHomeDirectory() + "/Music/Library/Blue Lantern (Remix).mp3",
                                              libraryTitle: "Blue Lantern (Remix)")
        results[6].track.libraryMatch = .init(kind: .exact, path: NSHomeDirectory() + "/Music/Library/Blue Lantern.flac",
                                              libraryTitle: "Blue Lantern")
        // One result is already in the queue.
        m.rows = [QueueRow(item: results[3].track)]
        return (m, results)
    }

    static func sampleUpdate(canSelfInstall: Bool) -> UpdateInfo {
        UpdateInfo(version: "0.1.32", notes: """
            # What's new in v0.1.32
            ## Previews
            - Waveforms come back from the disk cache at launch, so nothing downloads again.
            - The **play/pause** key and Control Center work while a preview plays.
            ## Downloads
            - A track that fails now says why on its row, and **Retry All Failed** tries it again.
            - The Dock icon shows the batch's progress while the window is closed.

            ## Requirements
            macOS 15 or later on a Mac with Apple silicon.
            """, releaseURL: nil, canSelfInstall: canSelfInstall)
    }

    static func updateModel(canSelfInstall: Bool) -> AppModel {
        let m = model()
        m.updateInfoOverride = sampleUpdate(canSelfInstall: canSelfInstall)
        return m
    }

    // MARK: Rendering

    /// The overrides and the person's display settings for a look.
    private static func dressed<V: View>(_ view: V, look: Look) -> some View {
        var overrides = look.overrides
        overrides.reduceMotion = true
        return view
            .environment(\.displayOverrides, overrides)
            .resolvingDisplayPreferences()
    }

    /// A sheet's content on the system window background, sized to fit
    /// unless a size is given.
    static func sheet<V: View>(_ view: V, size: CGSize? = nil, look: Look, to url: URL) -> Bool {
        let root = dressed(view, look: look).background(.windowBackground)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.appearance)
        window.contentView = host
        settle(window, host)
        window.setContentSize(size ?? host.fittingSize)
        settle(window, host)
        defer { window.close() }
        return capture(host, look: look, to: url)
    }

    /// A titled window (About): the title bar is part of the capture.
    static func titledWindow<V: View>(_ view: V, title: String, showsTitle: Bool, size: CGSize,
                                      look: Look, to url: URL) -> Bool {
        let host = NSHostingView(rootView: dressed(view, look: look))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.appearance)
        window.title = title
        window.titleVisibility = showsTitle ? .visible : .hidden
        window.contentView = host
        window.setContentSize(size)
        settle(window, host)
        defer { window.close() }
        return capture(host.superview ?? host, look: look, to: url)
    }

    /// One Settings pane under the system's preference toolbar, the window
    /// titled with the pane's name and sized to the pane.
    static func settingsWindow(_ pane: SettingsPane, model: AppModel, look: Look, to url: URL) -> Bool {
        let host = NSHostingView(rootView: dressed(SettingsPaneView(pane: pane, model: model), look: look))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: Metrics.settingsWidth, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: look.appearance)
        window.title = pane.title
        let toolbar = NSToolbar(identifier: "settings-snapshot")
        let switcher = PaneSwitcher()
        toolbar.delegate = switcher
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
        // Minimize and zoom are dimmed in Settings (settings.md).
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentView = host
        settle(window, host)
        window.setContentSize(CGSize(width: Metrics.settingsWidth, height: host.fittingSize.height))
        settle(window, host)
        defer { window.close() }
        return withExtendedLifetime(switcher) { capture(host.superview ?? host, look: look, to: url) }
    }

    /// The pane switcher's items (General · Folders · TIDAL · Updates).
    private final class PaneSwitcher: NSObject, NSToolbarDelegate {
        private var ids: [NSToolbarItem.Identifier] { SettingsPane.allCases.map { .init($0.rawValue) } }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            guard let pane = SettingsPane(rawValue: id.rawValue) else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            return item
        }
    }

    /// The real NSAlert, laid out but never shown.
    static func alert(_ content: AlertContent, look: Look, to url: URL) -> Bool {
        let alert = content.makeNSAlert()
        alert.window.appearance = NSAppearance(named: look.appearance)
        alert.layout()
        guard let view = alert.window.contentView?.superview ?? alert.window.contentView else { return false }
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        return capture(view, look: look, to: url)
    }

    /// The Dock tile's view at 128 pt (256 px), as the Dock draws it.
    static func dockTile(fraction: Double, to url: URL) -> Bool {
        let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        view.fraction = fraction
        return capture(view, look: Look.light, to: url)
    }

    private static func settle(_ window: NSWindow, _ host: NSView) {
        for _ in 0..<6 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private static func capture(_ view: NSView, look: Look, to url: URL) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2),
                                         pixelsHigh: Int(bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = bounds.size
        NSAppearance(named: look.appearance)?.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            FileHandle.standardError.write(Data("Can't write \(url.path): \(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
