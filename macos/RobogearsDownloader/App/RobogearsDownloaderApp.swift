import SwiftUI
import RobogearsCore

// Placeholder shell: the real windows come from the design pass
// (docs/DESIGN.md). Kept minimal so the project builds from day one.
@main
struct RobogearsDownloaderApp: App {
    var body: some Scene {
        Window("robogears Downloader", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 540)
        }
        .defaultSize(width: 980, height: 740)

        Settings {
            Text("Settings")
                .padding()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("robogears Downloader")
                .font(.title2.weight(.semibold))
            Text("Version \(RobogearsCore.version)")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
