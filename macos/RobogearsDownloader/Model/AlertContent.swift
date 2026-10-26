import Foundation

/// What an alert says and offers, in one place: the SwiftUI alerts on the
/// main and Settings windows, the app-modal quit alert and the snapshot
/// harness all read it, so the words can't drift apart.
///
/// Buttons are listed in AppKit order: the first is the default (rightmost,
/// or top when macOS stacks three buttons), then the others. Exactly one
/// button is the default: the safe choice when the alert interrupts, or
/// the action the person deliberately asked for (Reset Folders…). Cancel is
/// never the default (`alerts.md › Buttons`).
struct AlertContent: Equatable {
    var title: String
    var message: String?
    var buttons: [AlertButton]

    var defaultButton: AlertButton? { buttons.first { $0.isDefault } }
}

struct AlertButton: Equatable, Identifiable {
    enum Role: Equatable { case normal, cancel, destructive }

    var id: String { title }
    var title: String
    var role: Role = .normal
    var isDefault = false
    var action: AlertAction
}

/// What a button does; the model performs it (`AppModel.perform(_:)`).
enum AlertAction: Equatable {
    case dismiss
    case signIn(PendingAdd)
    case quit
    case updateNow
    case updateWhenDownloadsFinish
    case importFirstLines(text: String, name: String?)
    case resetFolders
    case moveToApplications
}

extension AlertRoute {
    var content: AlertContent {
        switch self {
        case .signInToContinue(let pending):
            // 4.6: after sign-in the add resumes; nothing downloads by itself.
            return AlertContent(
                title: "Sign in to TIDAL to add \(pending.description).",
                message: "The tracks are added once you're signed in. Nothing downloads until you choose Download All.",
                buttons: [
                    AlertButton(title: "Sign In…", isDefault: true, action: .signIn(pending)),
                    AlertButton(title: "Cancel", role: .cancel, action: .dismiss),
                ])

        case .quitDuringBatch(let n):
            // 4.9: Keep Downloading is the default and the cancel choice;
            // Quit gets no key, so neither Return nor Escape can quit.
            return AlertContent(
                title: "Quit while \(Formatting.tracks(n)) \(n == 1 ? "is" : "are") still downloading?",
                message: "Downloads stop. Finished tracks stay in your folder; the rest go back to Waiting.",
                buttons: [
                    AlertButton(title: "Keep Downloading", role: .cancel, isDefault: true, action: .dismiss),
                    AlertButton(title: "Quit", action: .quit),
                ])

        case .updateDuringBatch(let n):
            // 4.8, D4 5.12: waiting is the default.
            return AlertContent(
                title: "Update now or when downloads finish?",
                message: "\(Formatting.tracks(n)) \(n == 1 ? "is" : "are") still downloading. Updating now stops them; finished tracks stay in your folder.",
                buttons: [
                    AlertButton(title: "Update When Downloads Finish", isDefault: true, action: .updateWhenDownloadsFinish),
                    AlertButton(title: "Update Now", action: .updateNow),
                    AlertButton(title: "Cancel", role: .cancel, action: .dismiss),
                ])

        case .largeImport(let lines, let text, let name):
            return AlertContent(
                title: "This file has \(Formatting.count(lines)) lines. Import the first \(Formatting.count(AppModel.largeImportLines))?",
                message: "Lines after the first \(Formatting.count(AppModel.largeImportLines)) aren't added. Split the file to import the rest.",
                buttons: [
                    AlertButton(title: "Import First \(Formatting.count(AppModel.largeImportLines))", isDefault: true,
                                action: .importFirstLines(text: text, name: name)),
                    AlertButton(title: "Cancel", role: .cancel, action: .dismiss),
                ])

        case .resetFolders:
            // 4.12. The person chose Reset Folders… on purpose and nothing on
            // disk changes, so Reset is the default and not styled as
            // destructive; Cancel answers Escape (`alerts.md › Buttons`).
            return AlertContent(
                title: "Forget the download and library folders?",
                message: "Your TIDAL sign-in stays. Nothing in either folder is changed.",
                buttons: [
                    AlertButton(title: "Reset", isDefault: true, action: .resetFolders),
                    AlertButton(title: "Cancel", role: .cancel, action: .dismiss),
                ])

        case .moveToApplications:
            // 4.11 (1), D4 5.15.
            return AlertContent(
                title: "Move robogears Downloader to Applications?",
                message: "Updates install into the Applications folder, so opening the app from there keeps you on the newest version.",
                buttons: [
                    AlertButton(title: "Move", isDefault: true, action: .moveToApplications),
                    AlertButton(title: "Not Now", role: .cancel, action: .dismiss),
                ])

        case .information(let title, let message):
            return AlertContent(title: title, message: message,
                                buttons: [AlertButton(title: "OK", isDefault: true, action: .dismiss)])
        }
    }
}
