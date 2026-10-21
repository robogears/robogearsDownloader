import RobogearsCore
import SwiftUI

// A first working Settings window (4.12): General · Folders · TIDAL ·
// Updates, each a grouped Form, changes applied at once, system colours only.
// The Settings pass completes it (library scan status, Reset Folders…,
// the preview cache, offline and rate-limit wording).

struct SettingsWindow: View {
    @Bindable var model: AppModel
    @AppStorage("settingsPane") private var pane = "general"

    var body: some View {
        TabView(selection: $pane) {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            FoldersPane(model: model)
                .tabItem { Label("Folders", systemImage: "folder") }
                .tag("folders")
            TIDALPane(model: model)
                .tabItem { Label("TIDAL", systemImage: "waveform") }
                .tag("tidal")
            UpdatesPane(model: model)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag("updates")
        }
        .frame(width: 480)
        .resolvingDisplayPreferences()
    }
}

private struct GeneralPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("Play sound effects", isOn: $model.settings.playSoundEffects)
            Toggle("Notify When Downloads Finish", isOn: $model.settings.notifyWhenDownloadsFinish)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FoldersPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Download folder") {
                    Text(model.settings.downloadFolder.map { Formatting.abbreviatedPath($0.lastKnownPath) } ?? "Not chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { model.openDownloadFolder() }
                        .disabled(model.settings.downloadFolder == nil)
                    Button("Choose…") { model.chooseDownloadFolder() }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Every download goes here directly — no subfolders.")
                    if model.batch != nil {
                        Text("A change applies from the next batch.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Music library folder") {
                    Text(model.settings.libraryFolder.map { Formatting.abbreviatedPath($0.lastKnownPath) } ?? "Not chosen")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Clear") { model.clearLibraryFolder() }
                        .disabled(model.settings.libraryFolder == nil)
                    Button("Choose…") { model.chooseLibraryFolder() }
                }
            } footer: {
                Text("Read-only. The app reads audio tags and file names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TIDALPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch model.signInState {
                    case .signedIn(let country): Text(country.map { "Signed in to TIDAL · \($0)" } ?? "Signed in to TIDAL")
                    case .signedOut: Text("Not signed in")
                    case .invalid: Text("Your TIDAL sign-in is no longer valid.").foregroundStyle(Palette.statusFailed)
                    }
                }
                HStack {
                    Spacer()
                    if model.isSignedIn {
                        Button("Sign Out") { model.signOut() }
                        Button("Sign In Again…") { model.showSignIn() }
                    } else {
                        Button("Sign In…") { model.showSignIn() }
                    }
                }
                .disabled(!model.canChangeSignIn)
            } footer: {
                if !model.canChangeSignIn {
                    Text("Unavailable while downloads are running.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct UpdatesPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? RobogearsCore.version)
            }
            HStack {
                Text(statusText).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { model.checkForUpdates() }
                    .disabled(model.isCheckingForUpdates || model.update == nil)
            }
            Toggle("Check for updates automatically", isOn: $model.settings.checkForUpdatesAutomatically)
            Text("made with love by robogears :)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusText: String {
        guard let update = model.update else { return "" }
        switch update.phase {
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available: return "\(update.available?.version ?? "") available"
        case .offline: return "No internet connection"
        case .rateLimited: return "GitHub is limiting checks; try again in an hour"
        case .noReleases: return "No releases yet"
        case .failed(let message): return message
        case .downloading(let p): return "Downloading \(p)%"
        case .verifying, .readyToInstall, .applying: return "Installing…"
        case .idle: return ""
        }
    }
}

/// About (4.13): the icon (click: joke), name, version (click: the 7× joke),
/// the signature and a GitHub link. Fixed size, system background.
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
            Text("robogears Downloader").font(.title2)
            Button { model.sounds.play(.versionFart) } label: {
                Text("Version \(Self.version)")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Text("made with love by robogears :)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Link("GitHub", destination: URL(string: "https://github.com/robogears/robogearsDownloader")!)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 300, height: 340)
    }

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? RobogearsCore.version
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
