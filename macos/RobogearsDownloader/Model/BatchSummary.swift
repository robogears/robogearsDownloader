import Foundation

/// The notice in the batch slot after a batch (DESIGN_DIRECTION 4.10). Never
/// says "finished" when anything failed.
struct BatchSummary: Equatable, Sendable, Identifiable {
    enum Outcome: Equatable, Sendable {
        case allGood
        case someFailed
        case stoppedByPerson
        case stoppedByCause(BatchStopCause)
        /// Download All was clicked with no download folder chosen.
        case noFolder
        /// Not a batch result: Spotify shared only 100 tracks (D4 4.4). Uses
        /// the same slot and notice so the window has one place for notices.
        case spotifyCap(String)
    }

    enum Button: Equatable, Sendable, Hashable {
        case openFolder
        case retryFailed(Int)
        case chooseFolder
        case signIn
        case openExportify

        var title: String {
            switch self {
            case .openFolder: "Open Folder"
            case .retryFailed(let n): "Retry All Failed (\(Formatting.count(n)))"
            case .chooseFolder: "Choose Folder…"
            case .signIn: "Sign In…"
            case .openExportify: "Open Exportify"
            }
        }
    }

    let id = UUID()
    var outcome: Outcome
    var downloaded = 0
    var alreadyInFolder = 0
    var failed = 0
    var waiting = 0
    var savedAsAAC = 0

    var symbol: String {
        switch outcome {
        case .allGood: "checkmark.circle.fill"
        case .someFailed, .stoppedByCause: "exclamationmark.circle.fill"
        case .stoppedByPerson: "stop.circle"
        case .noFolder: "folder.badge.questionmark"
        case .spotifyCap: "info.circle"
        }
    }

    var tone: Tone {
        switch outcome {
        case .allGood: .done
        case .someFailed, .stoppedByCause: .failed
        case .stoppedByPerson, .noFolder, .spotifyCap: .secondary
        }
    }

    var sentence: String {
        switch outcome {
        case .allGood:
            var parts = ["\(Formatting.count(downloaded)) downloaded"]
            if alreadyInFolder > 0 { parts.append("\(Formatting.count(alreadyInFolder)) already in your folder") }
            if savedAsAAC > 0 { parts.append("\(Formatting.count(savedAsAAC)) saved as AAC") }
            if downloaded == 0 && alreadyInFolder > 0 { return "Done: \(Formatting.tracks(alreadyInFolder)) already in your folder." }
            return "Done: " + parts.joined(separator: ", ") + "."
        case .someFailed:
            if downloaded == 0 && alreadyInFolder == 0 {
                return "Nothing downloaded: \(Formatting.count(failed)) failed."
            }
            var parts = ["\(Formatting.count(downloaded)) downloaded"]
            if alreadyInFolder > 0 { parts.append("\(Formatting.count(alreadyInFolder)) already in your folder") }
            parts.append("\(Formatting.count(failed)) failed")
            return "Finished with problems: " + parts.joined(separator: ", ") + "."
        case .stoppedByPerson:
            return "Stopped: \(Formatting.count(downloaded)) downloaded, \(Formatting.count(waiting)) waiting."
        case .stoppedByCause(let cause):
            return cause.message
        case .noFolder:
            return "Choose a download folder to start downloading."
        case .spotifyCap(let message):
            return message
        }
    }

    var buttons: [Button] {
        switch outcome {
        case .allGood, .stoppedByPerson: [.openFolder]
        case .someFailed: [.retryFailed(failed), .openFolder]
        case .stoppedByCause(let cause):
            switch cause.fix {
            case .chooseFolder: [.chooseFolder]
            case .signIn: [.signIn]
            case .none: [.openFolder]
            }
        case .noFolder: [.chooseFolder]
        case .spotifyCap: [.openExportify]
        }
    }
}
