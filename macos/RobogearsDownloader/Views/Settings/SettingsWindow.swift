import AppKit
import RobogearsCore
import SwiftUI

// Settings (DESIGN_DIRECTION 4.12): General · Folders · TIDAL · Updates in the
// system pane switcher; each pane a grouped Form, 480 pt wide and sized to
// its content; changes apply at once (no Done); system colours (the black
// canvas is content, not chrome). The window title is the pane name
// and minimize and zoom are dimmed: the Settings scene does both itself.
// Error text uses StatusFailed, the one failure red the whole app uses.

struct SettingsWindow: View {
    @Bindable var model: AppModel
    @AppStorage("settingsPane") private var pane = SettingsPane.general.rawValue

    var body: some View {
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases) { item in
                SettingsPaneView(pane: item, model: model)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item.rawValue)
            }
        }
        .settingsChrome(model: model)
    }
}

/// The four panes, in order (open question 5: General first).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, folders, tidal, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .tidal: "TIDAL"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .tidal: "waveform"
        case .updates: "arrow.down.circle"
        }
    }
}

/// One pane's content at the Settings width.
struct SettingsPaneView: View {
    let pane: SettingsPane
    let model: AppModel

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane(model: model)
            case .folders: FoldersPane(model: model)
            case .tidal: TIDALPane(model: model)
            case .updates: UpdatesPane(model: model)
            }
        }
        .frame(width: Metrics.settingsWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// What every Settings presentation carries: the Reset Folders… alert,
    /// the TIDAL sign-in sheet, and the person's display settings.
    func settingsChrome(model: AppModel) -> some View {
        modifier(SettingsChrome(model: model))
    }
}

private struct SettingsChrome: ViewModifier {
    @Bindable var model: AppModel

    private var alertShown: Binding<Bool> {
        Binding(get: { model.settingsAlert != nil }, set: { if !$0 { model.settingsAlert = nil } })
    }

    func body(content: Content) -> some View {
        content
            .systemAlert(model.settingsAlert?.content, isPresented: alertShown) { model.perform($0) }
            .sheet(isPresented: $model.isSettingsSignInPresented) {
                SignInSheet(model: model, resume: nil)
                    .resolvingDisplayPreferences()
            }
            .resolvingDisplayPreferences()
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Play sound effects", isOn: $model.settings.playSoundEffects)
                Toggle("Notify when downloads finish", isOn: $model.settings.notifyWhenDownloadsFinish)
                if model.settings.notifyWhenDownloadsFinish, model.notificationsBlocked {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Notifications for robogears Downloader are turned off in System Settings.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Notifications Settings…") { model.openNotificationSettings() }
                    }
                }
            } footer: {
                Text("A notification comes only when downloads finish while the window isn't in front.")
            }
            Section {
                LabeledContent("Preview cache") {
                    HStack(spacing: 8) {
                        Text(model.previewCacheText).monospacedDigit()
                        Button("Clear Preview Cache") { model.clearPreviewCache() }
                            .disabled((model.previewCacheBytes ?? 0) == 0)
                    }
                }
            } footer: {
                Text("Waveforms and preview audio kept on this Mac. They load again when needed.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear {
            model.refreshPreviewCacheSize()
            // Notifications may have been turned on in System Settings since launch.
            model.refreshNotificationPermission()
        }
    }
}

// MARK: - Folders

private struct FoldersPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                FolderRow(title: "Download folder", reference: model.settings.downloadFolder)
                if case .download(let message) = model.folderProblem {
                    ProblemLine(message)
                }
                HStack {
                    Spacer()
                    Button("Choose…") { model.chooseDownloadFolder() }
                    Button("Show in Finder") { model.openDownloadFolder() }
                        .disabled(model.settings.downloadFolder == nil)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every download goes here directly — no subfolders.")
                    if let batch = model.batch {
                        // D4 2.17: the running batch keeps its folder.
                        Text("Downloads in progress are saved to “\(batch.folder.lastPathComponent)”. A new folder is used from the next batch.")
                    }
                }
            }
            Section {
                FolderRow(title: "Music library folder", reference: model.settings.libraryFolder)
                if case .library(let message) = model.folderProblem {
                    ProblemLine(message)
                }
                // The status is the label's second line (the grouped form
                // draws it as secondary text), so it never wraps beside Refresh.
                LabeledContent {
                    HStack(spacing: 8) {
                        if model.libraryStatus.isScanning {
                            ProgressView().controlSize(.small)
                        }
                        Button("Refresh") { model.rescanLibrary() }
                            .disabled(model.settings.libraryFolder == nil || model.libraryStatus.isScanning)
                    }
                } label: {
                    Text("Library index")
                    Text(model.libraryStatus.text).monospacedDigit()
                }
                HStack {
                    Spacer()
                    Button("Choose…") { model.chooseLibraryFolder() }
                    Button("Show in Finder") { model.showLibraryFolder() }
                        .disabled(model.settings.libraryFolder == nil)
                    Button("Clear") { model.clearLibraryFolder() }
                        .disabled(model.settings.libraryFolder == nil)
                }
            } footer: {
                Text("Read-only. The app reads audio tags and file names.")
            }
            Section {
                HStack {
                    Text("Forget both folders. Your TIDAL sign-in stays.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Folders…") { model.askToResetFolders() }
                        .disabled(model.settings.downloadFolder == nil && model.settings.libraryFolder == nil)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

/// "Download folder   ~/Music/TIDAL", the full path on hover.
private struct FolderRow: View {
    let title: String
    let reference: FolderReference?

    var body: some View {
        LabeledContent(title) {
            if let reference {
                Text(Formatting.abbreviatedPath(reference.lastKnownPath))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(reference.lastKnownPath)
            } else {
                Text("Not chosen").foregroundStyle(.secondary)
            }
        }
    }
}

/// Why a folder choice was refused: the symbol, the words, the app's one
/// failure red (StatusFailed: system red is under 4.5:1 for 13 pt text).
private struct ProblemLine: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Palette.statusFailed)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - TIDAL

private struct TIDALPane: View {
    let model: AppModel

    var body: some View {
        let stored = model.signInState != .signedOut
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    if model.signInState == .invalid {
                        Label(model.signInStatusText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.statusFailed)
                    } else {
                        Text(model.signInStatusText)
                    }
                    Spacer()
                    Group {
                        if stored {
                            Button("Sign Out") { model.signOut() }
                            Button("Sign In Again…") { model.showSignIn(onSettings: true) }
                        } else {
                            Button("Sign In…") { model.showSignIn(onSettings: true) }
                        }
                    }
                    .disabled(!model.canChangeSignIn || model.isSigningIn)
                }
            } footer: {
                if !model.canChangeSignIn {
                    Text("Unavailable while downloads are running.")
                } else if stored {
                    Text("Sign Out removes your TIDAL sign-in from this Mac. Your queue and folders stay.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Updates

private struct UpdatesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Version") {
                        Text(AppModel.currentVersion).monospacedDigit().textSelection(.enabled)
                    }
                    HStack(spacing: 8) {
                        statusLine
                        Spacer()
                        if case .available = model.updateStatusLine {
                            Button("What's New…") { model.showWhatsNew() }
                        }
                        Button("Check Now") { model.checkForUpdates() }
                            .disabled(model.isCheckingForUpdates || !model.canCheckForUpdates)
                    }
                    Toggle("Check for updates automatically", isOn: $model.settings.checkForUpdatesAutomatically)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            Text("made with love by robogears :)")
                .font(Typography.signature)
                .foregroundStyle(.tertiary)
                .padding(.leading, 20)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let line = model.updateStatusLine
        if line == .checking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(line.text).foregroundStyle(.secondary)
            }
        } else if line == .upToDate {
            Label(line.text, systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if line.isProblem {
            Label(line.text, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            Text(line.text).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - About (4.13)

/// The real app icon (click: the joke sound), the name, the version (click:
/// the 7× joke), the signature and a GitHub link. Fixed 300×340, system
/// background, minimize dimmed.
struct AboutWindow: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            Button { model.sounds.play(.brandFart) } label: {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 128, height: 128)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("robogears Downloader icon")
            .accessibilityHint("Plays a sound")
            Text("robogears Downloader")
                .font(Typography.aboutName)
                .padding(.top, 4)
            Button { model.sounds.play(.versionFart) } label: {
                Text("Version \(Self.version)")
                    .font(Typography.aboutVersion)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Plays a sound")
            Text("made with love by robogears :)")
                .font(Typography.signature)
                .foregroundStyle(.tertiary)
            Link("GitHub", destination: URL(string: "https://github.com/robogears/robogearsDownloader")!)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(width: 300, height: 340)
        .resolvingDisplayPreferences()
    }

    static var version: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(AppModel.currentVersion) (\(build))"
    }
}
