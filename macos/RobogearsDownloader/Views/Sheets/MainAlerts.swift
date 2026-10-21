import AppKit
import SwiftUI

/// The main window's system alerts (4.6, 4.8, 4.9; D4 4.8). The default is
/// always the safe button; Escape picks Cancel or Keep Downloading.
struct MainAlerts: ViewModifier {
    @Bindable var model: AppModel

    private var isPresented: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    func body(content: Content) -> some View {
        content.alert(Text(title), isPresented: isPresented, presenting: model.alert) { route in
            actions(route)
        } message: { route in
            if let message = message(route) { Text(message) }
        }
    }

    private var title: String {
        switch model.alert {
        case .signInToContinue(let pending): "Sign in to TIDAL to add \(pending.description)."
        case .quitDuringBatch(let n): "Quit while \(Formatting.tracks(n)) \(n == 1 ? "is" : "are") still downloading?"
        case .updateDuringBatch: "Update now or when downloads finish?"
        case .largeImport(let lines, _, _): "This file has \(Formatting.count(lines)) lines. Import the first \(Formatting.count(AppModel.largeImportLines))?"
        case nil: ""
        }
    }

    private func message(_ route: AlertRoute) -> String? {
        switch route {
        case .signInToContinue: "The tracks are added once you're signed in. Nothing downloads until you choose Download All."
        case .quitDuringBatch: "Downloads stop. Finished tracks stay in your folder; the rest go back to Waiting."
        case .updateDuringBatch(let n): "\(Formatting.tracks(n)) \(n == 1 ? "is" : "are") still downloading."
        case .largeImport: "Lines after the first \(Formatting.count(AppModel.largeImportLines)) aren't added. Split the file to import the rest."
        }
    }

    @ViewBuilder
    private func actions(_ route: AlertRoute) -> some View {
        switch route {
        case .signInToContinue(let pending):
            Button("Cancel", role: .cancel) {}
            Button("Sign In…") { model.sheet = .signIn(resumeAdd: pending) }
                .keyboardShortcut(.defaultAction)
        case .quitDuringBatch:
            Button("Quit") {
                model.quitConfirmed = true
                NSApp.terminate(nil)
            }
            Button("Keep Downloading", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        case .updateDuringBatch:
            Button("Cancel", role: .cancel) {}
            Button("Update Now") {
                model.stopDownloads()
                model.updateAfterBatch = true
            }
            Button("Update When Downloads Finish") { model.updateAfterBatch = true }
                .keyboardShortcut(.defaultAction)
        case .largeImport(_, let text, let name):
            Button("Cancel", role: .cancel) {}
            Button("Import First \(Formatting.count(AppModel.largeImportLines))") { model.importFirstLines(text, name: name) }
                .keyboardShortcut(.defaultAction)
        }
    }
}
