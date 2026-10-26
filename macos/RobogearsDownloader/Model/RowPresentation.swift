import Foundation
import RobogearsCore

/// Commands a row can offer: its one button, its context menu, the Queue
/// menu and its VoiceOver actions all come from the same list.
enum RowCommand: Hashable, Sendable {
    case include
    case leaveOut
    case retry
    case searchTIDAL
    case matchAgain
    case saveAs
    case replace
    case showInFinder
    case showLibraryFile
    case tryPreviewAgain
    case copyTitleAndArtist
    case remove

    var title: String {
        switch self {
        case .include: "Include in Download"
        case .leaveOut: "Leave Out of Download"
        case .retry: "Retry"
        case .searchTIDAL: "Search TIDAL…"
        case .matchAgain: "Match Again"
        case .saveAs: "Save As…"
        case .replace: "Replace"
        case .showInFinder: "Show in Finder"
        case .showLibraryFile: "Show Library File in Finder"
        case .tryPreviewAgain: "Try Again"
        case .copyTitleAndArtist: "Copy Title and Artist"
        case .remove: "Remove from Queue"
        }
    }

    /// The row button's own wording, where it differs from the menu's.
    var buttonTitle: String {
        switch self {
        case .include: "+ Add"
        case .searchTIDAL: "Search…"
        default: title
        }
    }
}

/// Everything about a row that decides how it looks, as plain values, so the
/// rule is a pure function (DESIGN_DIRECTION 4.4 and 4.5).
struct RowFacts: Equatable, Sendable {
    var item: QueueItem
    var percent: Int = 0
    var isCheckingLibrary = false
    var inDownloadFolder = false
    var problem: QueueRow.Problem?
    var isAACOnly = false
    var hasSavedFile = false
    var preview: Preview = .none
    /// The library file's length, when known.
    var libraryDurationSeconds: Int?

    enum Preview: Equatable, Sendable { case none, loading, ready, unavailable }
}

struct RowPresentation: Equatable, Sendable {
    struct Status: Equatable, Sendable {
        /// SF Symbol, monochrome, small, in the status colour; nil for none.
        var symbol: String?
        /// A small system spinner instead of a symbol ("Checking library…").
        var showsSpinner = false
        var text: String
        var tone: Tone
    }

    var status: Status?
    /// The row's one button (DESIGN_DIRECTION 4.5 "Action").
    var action: RowCommand?
    /// The quiet second line; the row grows to 44 pt when present.
    var secondLine: String?
    /// Dimmed 50 % with the title struck through (not dimmed under Increase Contrast).
    var isLeftOut = false
    /// False for rows with no TIDAL track to play (Not on TIDAL, Couldn't check).
    var canPreview = true
    /// The play button is shown but dimmed after a failed load.
    var previewDimmed = false
    /// "Hi-Res" or "AAC"; at most one.
    var badge: String?
    /// The 2 pt line along the bottom edge while downloading.
    var showsProgressLine = false
    /// Commands for this row (context menu, Queue menu, VoiceOver), in menu order.
    var commands: [RowCommand] = []

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func make(_ f: RowFacts) -> RowPresentation {
        var p = RowPresentation()
        let item = f.item

        p.canPreview = item.tidalID != nil && {
            switch item.match {
            case .notOnTIDAL, .couldNotCheck: false
            case .matched, .differentArtist: true
            }
        }()
        p.badge = item.hiRes ? "Hi-Res" : (f.isAACOnly ? "AAC" : nil)

        // Second-line candidates, highest first: failure or clash › library › source.
        var failureLine: String?
        let libraryLine = item.libraryMatch.map {
            "Library: \($0.libraryTitle)" + lengthComparison(item.durationSeconds, f.libraryDurationSeconds)
        }
        let sourceLine = sourceWording(item)

        // Status, by priority: download result › clash or damaged › Not on
        // TIDAL › Couldn't check › left out › similar › in download folder ›
        // checking › preview unavailable.
        switch item.state {
        case .downloading:
            p.status = Status(text: "\(f.percent)%", tone: .ink)
            p.showsProgressLine = true
        case .queued:
            p.status = Status(symbol: "clock", text: "Waiting", tone: .secondary)
        case .done(let quality):
            p.status = Status(symbol: "checkmark.circle.fill", text: "Done · \(quality)", tone: .done)
            if quality == "AAC" { failureLine = "Saved as AAC (.m4a): TIDAL has no lossless version" }
            if f.hasSavedFile { p.commands.append(.showInFinder) }
        case .skipped:
            p.status = Status(symbol: "folder", text: "Already in your download folder", tone: .secondary)
            p.action = .showInFinder
            p.commands.append(.showInFinder)
        case .failed(let reason):
            p.status = Status(symbol: "exclamationmark.circle.fill", text: "Failed", tone: .failed)
            failureLine = reason
            if item.tidalID != nil { p.action = .retry; p.commands.append(.retry) }
        case .waiting:
            break
        }

        if p.status == nil, let problem = f.problem {
            p.status = Status(symbol: "exclamationmark.circle.fill", text: "Not downloaded", tone: .failed)
            switch problem {
            case .clash(let name):
                failureLine = "A different song is already saved as \(name)"
                p.action = .saveAs
                p.commands += [.saveAs, .replace]
            case .damaged(let name):
                failureLine = "\(name) looks damaged"
                p.action = .replace
                p.commands += [.replace, .showInFinder]
            }
        }

        if p.status == nil {
            switch item.match {
            case .notOnTIDAL:
                p.status = Status(symbol: "questionmark.circle", text: "Not on TIDAL", tone: .failed)
                p.action = .searchTIDAL
                p.commands.append(.searchTIDAL)
            case .couldNotCheck(let reason):
                p.status = Status(symbol: "exclamationmark.triangle", text: "Couldn't check: \(reason)", tone: .secondary)
                p.action = .matchAgain
                p.commands.append(.matchAgain)
            case .differentArtist where !item.included:
                p.status = Status(symbol: "person.crop.circle.badge.questionmark", text: "Different artist on TIDAL", tone: .secondary)
                p.isLeftOut = true
                p.action = .include
                p.commands += [.include, .searchTIDAL]
            case .matched where !item.included:
                p.isLeftOut = true
                p.action = .include
                p.commands.append(.include)
                if item.libraryMatch?.kind == .exact {
                    p.status = Status(symbol: "books.vertical", text: "In your library", tone: .secondary)
                } else {
                    // A similar (or unmarked) row the person left out (D4 3.14).
                    p.status = Status(symbol: "minus.circle", text: "Left out by you", tone: .secondary)
                }
            default:
                break
            }
        }

        if p.status == nil, item.libraryMatch?.kind == .similar {
            p.status = Status(symbol: "exclamationmark.triangle.fill", text: "Similar version in library", tone: .similar)
            p.commands.append(.leaveOut)
        }

        if p.status == nil, f.inDownloadFolder {
            p.status = Status(symbol: "folder", text: "In your download folder", tone: .secondary)
            p.action = .showInFinder
            p.commands.append(.showInFinder)
        }

        if p.status == nil, f.isCheckingLibrary {
            p.status = Status(showsSpinner: true, text: "Checking library…", tone: .secondary)
        }

        if f.preview == .unavailable, p.canPreview {
            p.previewDimmed = true
            if p.status == nil {
                p.status = Status(text: "Preview unavailable", tone: .secondary)
                p.action = .tryPreviewAgain
            }
            p.commands.append(.tryPreviewAgain)
        }

        // Include / leave out for rows not already offering one.
        let canToggle: Bool = {
            switch item.state {
            case .waiting, .failed: return item.tidalID != nil
            default: return false
            }
        }()
        if canToggle, !p.commands.contains(.include), !p.commands.contains(.leaveOut) {
            switch item.match {
            case .matched, .differentArtist: p.commands.append(item.included ? .leaveOut : .include)
            default: break
            }
        }
        if item.libraryMatch != nil { p.commands.append(.showLibraryFile) }
        p.commands.append(.copyTitleAndArtist)
        p.commands.append(.remove)
        p.commands = p.commands.uniqued()

        p.secondLine = failureLine ?? libraryLine ?? sourceLine
        return p
    }

    /// " · 4:12 vs 3:58" (this track's length, then the library file's) when
    /// both are known and more than 10 s apart; otherwise nothing.
    static func lengthComparison(_ track: Int?, _ library: Int?) -> String {
        guard let track, let library, track > 0, library > 0, abs(track - library) > 10,
              let a = Formatting.duration(track), let b = Formatting.duration(library) else { return "" }
        return " · \(a) vs \(b)"
    }

    /// "Spotify: Intro — Placeholder Artist" when the source named the track
    /// differently from TIDAL (D4 4.14).
    static func sourceWording(_ item: QueueItem) -> String? {
        let title = item.originalTitle ?? item.title
        let artist = item.originalArtist ?? item.artist
        guard item.originalTitle != nil || item.originalArtist != nil,
              title != item.title || artist != item.artist else { return nil }
        let label: String
        switch item.source {
        case .spotify: label = "Spotify"
        case .importList: label = "Your list"
        case .tidal: label = "TIDAL link"
        case .search: label = "Search"
        }
        return artist.isEmpty ? "\(label): \(title)" : "\(label): \(title) — \(artist)"
    }

    /// The row's single VoiceOver label (DESIGN_DIRECTION 6): title, explicit,
    /// artist, length, quality, status, second line, then "left out".
    static func accessibilityLabel(_ f: RowFacts, _ p: RowPresentation) -> String {
        let item = f.item
        var parts: [String] = [item.version.map { "\(item.title) — \($0)" } ?? item.title]
        if item.explicit { parts.append("explicit") }
        if !item.artist.isEmpty { parts.append(item.artist) }
        if let seconds = item.durationSeconds, seconds > 0 { parts.append(Formatting.spokenDuration(Double(seconds))) }
        if let badge = p.badge { parts.append(badge) }
        if let status = p.status {
            if case .downloading = item.state {
                parts.append("downloading \(f.percent) percent")
            } else {
                parts.append(status.text)
            }
        }
        if let line = p.secondLine { parts.append(line) }
        if p.isLeftOut { parts.append("left out") }
        return parts.joined(separator: ", ")
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
