// The words a batch leaves behind: each row's line (2.9), the one notice
// when a shared problem stops the batch (2.1), and the summary with its
// ending sound (2.8) and notification text (2.12). All pure functions of
// the batch's results, so every sentence is tested without a download.
import Foundation

extension DownloadBatch {
    // MARK: - Row lines

    /// The row's line for a finished download, in plain words (2.9):
    /// "Saved Blue Lantern.flac, 24-bit / 96 kHz", "Already in your download
    /// folder", "Saved as Intro (Second Example).flac — another song is
    /// already named Intro". Extra notes follow as short sentences.
    public static func message(for outcome: TrackDownloadOutcome) -> String {
        switch outcome {
        case let .saved(fileName, quality, notes):
            var parts: [String] = []
            let takenName = notes.lazy.compactMap { note -> String? in
                if case let .savedUnderAnotherName(name) = note { return name }
                return nil
            }.first
            let isAAC = quality == .aac || notes.contains(.savedAsAAC)
            if let takenName {
                parts.append("Saved as \(fileName) — another song is already named \(Self.titlePart(of: takenName))")
                if isAAC { parts.append("AAC (.m4a): TIDAL has no lossless version") }
            } else if isAAC {
                parts.append("Saved as AAC (.m4a): TIDAL has no lossless version")
            } else {
                parts.append("Saved \(fileName), \(quality.label)")
            }
            for note in notes {
                switch note {
                case .savedAsAAC, .savedUnderAnotherName:
                    continue
                case .withoutCoverArt:
                    parts.append("Without cover art: TIDAL has none for this album")
                case .limitedTags:
                    parts.append("With limited tags: TIDAL has no details for this album")
                case .belowHiRes:
                    parts.append("Below Hi-Res: TIDAL had only \(quality.label)")
                case let .savedNextToAAC(aacName):
                    parts.append("The older \(aacName) is still in your download folder")
                }
            }
            return parts.joined(separator: ". ")
        case .alreadyInFolder:
            return "Already in your download folder"
        case let .existingLooksDamaged(fileName):
            return "\(fileName) in your download folder looks damaged"
        case let .nameTakenByUnreadableFile(fileName):
            return "Not downloaded: \(fileName) already exists and can't be identified"
        }
    }

    /// The queue state a finished row takes. Only a save is "done"; the
    /// other outcomes say why nothing was downloaded, and the row keeps the
    /// outcome for its Show in Finder, Replace or Save As… button.
    public static func rowState(for outcome: TrackDownloadOutcome) -> QueueItem.DownloadState {
        if case let .saved(_, quality, _) = outcome { return .done(quality: quality.label) }
        return .skipped(reason: message(for: outcome))
    }

    /// "Intro" from "Intro.flac": the clash sentence names the song, not the file.
    static func titlePart(of name: String) -> String {
        for ext in FileNaming.AudioExtension.allCases {
            let suffix = ".\(ext.rawValue)"
            if name.count > suffix.count, name.lowercased().hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
        }
        return name
    }

    // MARK: - Fixes

    /// The button a notice offers for its fix.
    public enum Fix: Sendable, Equatable {
        /// Sign In…, which opens the sign-in sheet (1.3, 1.6).
        case signIn
        /// Choose Folder…, when the download folder can't be used (2.11, 2.19).
        case chooseFolder
        /// Create Folder beside Choose Folder…, for a download folder that
        /// no longer exists (2.19). Only the person's click creates it.
        case createFolder
    }

    // MARK: - Stop notice

    /// The one notice inside the window when a shared problem stops the
    /// batch (2.1), instead of every remaining row failing one by one.
    public struct StopNotice: Sendable, Equatable {
        public enum Reason: Sendable, Equatable {
            /// TIDAL no longer accepts the sign-in, even after one renewal (1.6).
            case signInRejected
            /// TIDAL said the plan isn't active (1.10).
            case subscriptionInactive
            /// The first track TIDAL streamed in this batch was only a
            /// preview: probably the plan, but TIDAL didn't say so (2.23).
            /// Its own reason rather than `subscriptionInactive`, because
            /// TIDAL never said the plan had lapsed. That row fails with
            /// 2.23's preview line; the rest go back to waiting (2.1).
            case previewsOnly
            /// The folder's own message, from 2.19's list.
            case folderUnavailable(message: String)
            case diskFull(bytesNeeded: Int64)
            /// TIDAL failed this many tracks in a row while the Mac was online.
            case tidalFailing(tracksInARow: Int)
        }

        public var reason: Reason
        /// Rows put back in the queue: waiting, or their earlier failure.
        public var unfinished: Int

        public init(reason: Reason, unfinished: Int) {
            self.reason = reason
            self.unfinished = unfinished
        }

        /// "Downloads stopped: your TIDAL sign-in is no longer valid. 288
        /// tracks are still in your queue." What to do follows when no
        /// button says it.
        public var text: String {
            var sentences = ["Downloads stopped: \(cause)"]
            if unfinished > 0 {
                sentences.append(unfinished == 1
                                 ? "1 track is still in your queue."
                                 : "\(unfinished) tracks are still in your queue.")
            }
            if let nextStep { sentences.append(nextStep) }
            return sentences.joined(separator: " ")
        }

        /// The button beside the notice, if one fixes it.
        public var fix: Fix? {
            switch reason {
            case .signInRejected: .signIn
            case .folderUnavailable: .chooseFolder
            case .subscriptionInactive, .previewsOnly, .diskFull, .tidalFailing: nil
            }
        }

        private var cause: String {
            switch reason {
            case .signInRejected:
                return "your TIDAL sign-in is no longer valid."
            case .subscriptionInactive:
                return "your TIDAL subscription isn't active. Downloads need a TIDAL plan with lossless streaming."
            case .previewsOnly:
                return "TIDAL sent only a preview instead of the full track."
            case let .folderUnavailable(message):
                // Folder messages start "The download folder …" (Folders.message).
                var text = message.hasPrefix("The ") ? "the " + message.dropFirst(4) : message
                if !text.hasSuffix(".") { text += "." }
                return text
            case let .diskFull(bytes):
                return "the disk with your download folder is full (about \(TrackDownloadError.megabytes(bytes)) more needed)."
            case let .tidalFailing(count):
                return "TIDAL couldn't send \(count) tracks in a row."
            }
        }

        private var nextStep: String? {
            switch reason {
            case .diskFull: "Free up space, then choose Download All."
            case .tidalFailing: "Try Download All again in a few minutes."
            case .previewsOnly: "Check that your TIDAL subscription is active, then choose Download All."
            case .signInRejected, .subscriptionInactive, .folderUnavailable: nil
            }
        }
    }

    // MARK: - Summary

    /// What a batch did, and the text, sound and notification that say so.
    public struct Summary: Sendable, Equatable {
        public enum Ending: Sendable, Equatable {
            /// Every track ran (a batch that paused for the internet and then
            /// ran to the end counts too, 3.6).
            case finished
            /// A shared problem stopped it (2.1).
            case stopped(StopNotice)
            /// Cancel or ⌘. (2.4).
            case cancelled
            /// The app is quitting (2.5).
            case quit
        }

        /// What happened to the batch's tracks.
        public struct Counts: Sendable, Equatable {
            public var downloaded = 0
            public var alreadyInFolder = 0
            /// Existing files that looked damaged, left for Replace (2.3).
            public var lookedDamaged = 0
            /// Untagged files holding the name, left for Save As… (2.6).
            public var nameTaken = 0
            public var failed = 0
            /// Rows put back in the queue by a stop, Cancel or Quit.
            public var unfinished = 0
            // Notes on saved files (2.8's list).
            public var savedAsAAC = 0
            public var savedUnderAnotherName = 0
            public var withoutCoverArt = 0
            public var limitedTags = 0
            public var belowHiRes = 0
            public var savedNextToAAC = 0

            public init() {}

            /// Rows that need the person's choice before they can download.
            public var needsAttention: Int { lookedDamaged + nameTaken }
            /// Every track the batch finished, whatever the result.
            public var finished: Int { downloaded + alreadyInFolder + needsAttention + failed }
        }

        public var kind: Kind
        /// The folder the batch saved into, for Open Folder (2.17).
        public var folder: URL
        public var ending: Ending
        public var counts: Counts
        /// The most frequent failure, without its "Failed: " start.
        public var mostCommonFailure: String?
        /// The rows put back, in queue order, with the state each returned to.
        public var returnedRows: [RowUpdate]

        public init(kind: Kind, folder: URL, ending: Ending,
                    results: [Result<TrackDownloadOutcome, TrackDownloadError>],
                    unfinished: Int, returnedRows: [RowUpdate] = []) {
            self.kind = kind
            self.folder = folder
            self.ending = ending
            self.returnedRows = returnedRows
            var counts = Counts()
            counts.unfinished = unfinished
            var reasons: [String: Int] = [:]
            var reasonOrder: [String] = []
            for result in results {
                switch result {
                case let .success(.saved(_, quality, notes)):
                    counts.downloaded += 1
                    if quality == .aac || notes.contains(.savedAsAAC) { counts.savedAsAAC += 1 }
                    for note in Set(notes) {
                        switch note {
                        case .savedAsAAC: break
                        case .savedUnderAnotherName: counts.savedUnderAnotherName += 1
                        case .withoutCoverArt: counts.withoutCoverArt += 1
                        case .limitedTags: counts.limitedTags += 1
                        case .belowHiRes: counts.belowHiRes += 1
                        case .savedNextToAAC: counts.savedNextToAAC += 1
                        }
                    }
                case .success(.alreadyInFolder):
                    counts.alreadyInFolder += 1
                case .success(.existingLooksDamaged):
                    counts.lookedDamaged += 1
                case .success(.nameTakenByUnreadableFile):
                    counts.nameTaken += 1
                case let .failure(error):
                    counts.failed += 1
                    var reason = error.rowMessage
                    if reason.hasPrefix("Failed: ") { reason.removeFirst("Failed: ".count) }
                    if reasons[reason] == nil { reasonOrder.append(reason) }
                    reasons[reason, default: 0] += 1
                }
            }
            self.counts = counts
            // Ties go to the reason seen first.
            var mostCommon: String?
            for reason in reasonOrder where reasons[reason, default: 0] > mostCommon.map({ reasons[$0, default: 0] }) ?? 0 {
                mostCommon = reason
            }
            mostCommonFailure = mostCommon
        }

        /// Not cancelled, not stopped, not quit: the condition for clearing
        /// greyed library rows after a Download All (3.6).
        public var isComplete: Bool { ending == .finished }

        /// Every track was saved or already there, and none needs a choice.
        public var everythingWorked: Bool {
            ending == .finished && counts.failed == 0 && counts.needsAttention == 0
                && counts.downloaded + counts.alreadyInFolder > 0
        }

        /// The summary line (2.8). Always carries the result, because a
        /// sound alone isn't accessible: a stopped batch says what it did
        /// before its notice ("11 downloaded. Downloads stopped: …").
        public var text: String {
            let c = counts
            switch ending {
            case let .stopped(notice):
                let parts = resultParts(includeDownloaded: c.downloaded > 0)
                guard !parts.isEmpty else { return notice.text }
                return parts.joined(separator: ", ") + "." + notesSentence + " " + notice.text
            case .cancelled, .quit:
                var parts = ["\(c.downloaded) downloaded"] + resultParts(includeDownloaded: false)
                if c.unfinished > 0 { parts.append("\(c.unfinished) still in your queue") }
                return (ending == .cancelled ? "Cancelled: " : "Stopped: ") + parts.joined(separator: ", ") + "."
            case .finished:
                if c.finished == 0 { return "Nothing downloaded." }
                if everythingWorked {
                    // "Done: 2 already in your folder." rather than "0 downloaded, …".
                    let parts = resultParts(includeDownloaded: c.downloaded > 0)
                    return "Done: " + parts.joined(separator: ", ") + "." + notesSentence
                }
                if c.downloaded == 0 {
                    var text = "Nothing downloaded: " + resultParts(includeDownloaded: false).joined(separator: ", ") + "."
                    if let mostCommonFailure { text += " Most common reason: \(Self.sentence(mostCommonFailure))" }
                    return text
                }
                return resultParts(includeDownloaded: true).joined(separator: ", ") + "." + notesSentence
            }
        }

        /// The ending sound (2.8): the bells only when everything worked; the
        /// quieter sound after failures and beside a stop notice; nothing for
        /// Cancel, whose chime played when it was pressed, or for Quit.
        public var sound: SoundEffect? {
            switch ending {
            case .cancelled, .quit:
                return nil
            case .stopped:
                return .finishedWithProblems
            case .finished:
                if counts.finished == 0 { return nil }
                return everythingWorked ? .successPing : .finishedWithProblems
            }
        }

        /// The text for the opt-in "downloads finished" notification (2.12):
        /// "Downloaded 47 tracks. 2 failed." A stopped batch uses its summary
        /// line, counts and notice both. Nil when the person ended the batch
        /// themselves, or nothing ran.
        public var notificationText: String? {
            let c = counts
            switch ending {
            case .cancelled, .quit:
                return nil
            case .stopped:
                return text
            case .finished:
                if c.finished == 0 { return nil }
                var sentences: [String] = []
                if c.downloaded > 0 {
                    sentences.append("Downloaded \(Self.tracks(c.downloaded)).")
                    if c.failed > 0 { sentences.append("\(c.failed) failed.") }
                } else if c.failed > 0 {
                    sentences.append("Nothing downloaded: \(c.failed) failed.")
                } else if c.alreadyInFolder > 0 {
                    sentences.append(c.alreadyInFolder == 1
                                     ? "The track was already in your download folder."
                                     : "All \(c.alreadyInFolder) tracks were already in your download folder.")
                }
                if c.needsAttention > 0 {
                    sentences.append(c.needsAttention == 1 ? "1 track needs your attention." : "\(c.needsAttention) tracks need your attention.")
                }
                return sentences.joined(separator: " ")
            }
        }

        /// "12 downloaded", "2 already in your folder", "1 failed"…
        private func resultParts(includeDownloaded: Bool) -> [String] {
            let c = counts
            var parts: [String] = []
            if includeDownloaded { parts.append("\(c.downloaded) downloaded") }
            if c.alreadyInFolder > 0 { parts.append("\(c.alreadyInFolder) already in your folder") }
            if c.lookedDamaged > 0 { parts.append("\(c.lookedDamaged) \(c.lookedDamaged == 1 ? "looks" : "look") damaged in your folder") }
            if c.nameTaken > 0 { parts.append("\(c.nameTaken) not saved: name already taken") }
            if c.failed > 0 { parts.append("\(c.failed) failed") }
            return parts
        }

        /// " 1 saved as AAC, 2 without cover art." — what saved files carry (2.8).
        private var notesSentence: String {
            let c = counts
            var parts: [String] = []
            if c.savedAsAAC > 0 { parts.append("\(c.savedAsAAC) saved as AAC") }
            if c.savedUnderAnotherName > 0 { parts.append("\(c.savedUnderAnotherName) saved under another name") }
            if c.withoutCoverArt > 0 { parts.append("\(c.withoutCoverArt) without cover art") }
            if c.limitedTags > 0 { parts.append("\(c.limitedTags) with limited tags") }
            if c.belowHiRes > 0 { parts.append("\(c.belowHiRes) below Hi-Res") }
            return parts.isEmpty ? "" : " " + parts.joined(separator: ", ") + "."
        }

        /// "1 track", "2 tracks".
        static func tracks(_ count: Int) -> String {
            count == 1 ? "1 track" : "\(count) tracks"
        }

        /// Ends a reason with a full stop unless it has one.
        private static func sentence(_ text: String) -> String {
            text.hasSuffix(".") || text.hasSuffix("…") ? text : text + "."
        }
    }

    // MARK: - Quit and Settings

    /// The question before quitting during a batch (2.5), with Cancel and
    /// Quit as its buttons.
    public struct QuitQuestion: Sendable, Equatable {
        /// "Quit while 12 tracks are still downloading?"
        public var title: String
        /// What quitting does to the track in progress and the rest.
        public var message: String
    }

    /// Nil when nothing would be interrupted, so the app quits without asking.
    public static func quitQuestion(unfinished: Int) -> QuitQuestion? {
        guard unfinished > 0 else { return nil }
        if unfinished == 1 {
            return QuitQuestion(title: "Quit while 1 track is still downloading?",
                                message: "The track in progress is discarded. It stays in your queue for next time.")
        }
        return QuitQuestion(title: "Quit while \(unfinished) tracks are still downloading?",
                            message: "The track in progress is discarded. The others stay in your queue for next time.")
    }

    /// Settings' line under the download folder while a batch runs (2.17):
    /// "Downloads in progress are saved to “TIDAL”. The new folder is used
    /// from the next batch."
    public static func inProgressFolderNote(folderName: String) -> String {
        "Downloads in progress are saved to “\(folderName)”. The new folder is used from the next batch."
    }

    /// The same line for this batch's folder.
    public nonisolated var inProgressFolderNote: String {
        Self.inProgressFolderNote(folderName: folder.lastPathComponent)
    }
}
