import AppKit
import SwiftUI

/// The menu bar (DESIGN_DIRECTION 5). Standard order and groups; unavailable
/// items are disabled, never hidden. Custom shortcuts: ⌘L, ⌘↩, ⌘R, ⇧⌘O, ⌘K,
/// ⇧⌘L, ⇧⌘⌫. Escape never stops downloads. ⌫ and Space have no menu key
/// equivalent on purpose: as menu keys they would fire while typing in the
/// Add field, so ⌫ works through Edit › Delete and Space in the list itself.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About robogears Downloader") { openWindow(id: "about") }
        }
        CommandGroup(after: .appSettings) {
            Button("Check for Updates…") { model.checkForUpdates(fromMenu: true) }
                .disabled(model.update == nil || model.isCheckingForUpdates)
            Button(model.signInState == .signedOut ? "Sign In to TIDAL…" : "Sign Out of TIDAL") {
                if model.signInState == .signedOut { showMain(); model.showSignIn() } else { model.signOut() }
            }
            .disabled(!model.canChangeSignIn || model.isSigningIn || model.isModalUp)
        }

        CommandGroup(replacing: .newItem) {
            Button("Import Tracklist…") { showMain(); model.showImportPanel() }
                .keyboardShortcut("o")
                .disabled(model.adding != nil || model.isModalUp)
            Button("Open Download Folder") { model.openDownloadFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.settings.downloadFolder == nil)
        }

        CommandGroup(after: .textEditing) {
            Button("Clear Activity") { model.activity.clear() }
                .keyboardShortcut("k")
                .disabled(model.activity.entries.isEmpty)
        }

        CommandGroup(after: .toolbar) {
            Button(model.isActivityVisible ? "Hide Activity" : "Show Activity") { model.isActivityVisible.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandMenu("Queue") {
            QueueMenu(model: model, showMain: showMain)
        }

        CommandGroup(replacing: .help) {
            Button("robogears Downloader Help") { model.openHelp() }
                .keyboardShortcut("?")
            Divider()
            Button("What's New") { model.showWhatsNew() }
                .disabled(model.updateInfo == nil || model.isModalUp)
            Button("Open Exportify") { model.openExportify() }
        }
    }

    private func showMain() { openWindow(id: "main") }
}

/// The Queue menu, between View and Window.
private struct QueueMenu: View {
    let model: AppModel
    let showMain: () -> Void

    var body: some View {
        let selected = model.selection
        let commands = model.commands(for: selected)
        let previewRow = model.rows.first { selected.contains($0.id) && model.presentation($0).canPreview }

        Button("Add Link or Search") { showMain(); model.focusAddField() }
            .keyboardShortcut("l")
        // Disabled whenever a sheet or alert is up, so Return in a sheet can never start a batch.
        Button(model.downloadButtonTitle) { model.downloadAll() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canDownload || model.isModalUp)
        Button(model.batch == nil && model.adding != nil ? "Stop Adding Tracks" : "Stop Downloads") {
            model.cancelFrontmost()
        }
        .keyboardShortcut(".", modifiers: .command)
        .disabled(model.batch == nil && model.adding == nil)
        Button(model.retryTitle ?? "Retry All Failed") { model.retryFromHeader() }
            .keyboardShortcut("r")
            .disabled(model.retryTitle == nil || model.batch != nil)

        Divider()

        Button(previewRow.map { model.nowPlayingID == $0.id && model.isPreviewPlaying } == true ? "Pause Preview" : "Play Preview") {
            model.toggleSelectedPreview()
        }
        .disabled(previewRow == nil)
        Button("Stop Preview") { model.stopPreview() }
            .disabled(model.nowPlayingID == nil)

        Divider()

        Button(commands.contains(.include) ? "Include in Download" : "Leave Out of Download") {
            model.perform(commands.contains(.include) ? .include : .leaveOut, on: selected)
        }
        .disabled(!commands.contains(.include) && !commands.contains(.leaveOut))
        Button("Search TIDAL…") { model.perform(.searchTIDAL, on: selected) }
            .disabled(!commands.contains(.searchTIDAL) || selected.count != 1)
        Button("Match Again") { model.perform(.matchAgain, on: selected) }
            .disabled(!commands.contains(.matchAgain))
        Button("Show in Finder") { model.perform(.showInFinder, on: selected) }
            .disabled(!commands.contains(.showInFinder))
        Button("Show Library File in Finder") { model.perform(.showLibraryFile, on: selected) }
            .disabled(!commands.contains(.showLibraryFile))

        Divider()

        Button("Remove from Queue") { model.remove(selected) }
            .disabled(selected.isEmpty)
        Button("Clear Queue") { model.clearQueue() }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(!model.canClearQueue)
    }
}
