import Foundation

/// The one sheet on the main window (one at a time, `sheets.md`).
enum SheetRoute: Identifiable, Equatable {
    /// TIDAL sign-in (4.6). `resumeAdd` is the add waiting for it, if any.
    case signIn(resumeAdd: PendingAdd?)
    /// Search results for a typed query (4.7).
    case searchResults(query: String, results: [SearchResult])
    /// Pick the TIDAL track for a "Not on TIDAL" or left-out row (4.7, pick-one mode).
    case pickOne(rowID: UUID, query: String, results: [SearchResult])
    /// What's New for an available update (4.8).
    case whatsNew

    var id: String {
        switch self {
        case .signIn: "signIn"
        case .searchResults(let q, _): "search-\(q)"
        case .pickOne(let id, _, _): "pick-\(id)"
        case .whatsNew: "whatsNew"
        }
    }
}

/// An add held back until sign-in finishes (D4 1.1): nothing downloads by itself.
struct PendingAdd: Equatable, Sendable {
    var source: AddSource
    /// "2 tracks from pasted text", for the alert's sentence.
    var description: String
}

/// System alerts on the main window.
enum AlertRoute: Identifiable, Equatable {
    /// "Sign in to TIDAL to add 2 tracks from pasted text." (4.6)
    case signInToContinue(PendingAdd)
    /// "Quit while 12 tracks are still downloading?" (4.9)
    case quitDuringBatch(remaining: Int)
    /// "Update now or when downloads finish?" (4.8)
    case updateDuringBatch(remaining: Int)
    /// A huge tracklist: "This file has 12,000 lines. Import the first 2,000?" (D4 4.8)
    case largeImport(lines: Int, text: String, name: String?)

    var id: String {
        switch self {
        case .signInToContinue: "signInToContinue"
        case .quitDuringBatch: "quit"
        case .updateDuringBatch: "update"
        case .largeImport: "largeImport"
        }
    }
}

/// The ten loading lines, verbatim (DESIGN.md §6).
enum LoadingLines {
    static let all = [
        "Searching the seven seas for your music…",
        "Digging through the record crates…",
        "Asking TIDAL nicely…",
        "Following the bass line…",
        "Tracking down these bangers…",
        "Bribing the algorithm…",
        "Polishing the vinyl…",
        "Listening for the drop…",
        "Tuning the frequencies…",
        "Whispering to the music gods…",
    ]

    /// The line for a given tick: steps by 7 (coprime with 10) so the line
    /// always changes and every line comes round.
    static func line(seed: Int, tick: Int) -> String {
        all[((seed + tick * 7) % all.count + all.count) % all.count]
    }
}

/// What the Add field's text will do on Return (D4 4.2), for the hint.
enum AddInputKind: Equatable {
    case empty
    case link
    case search(String)

    /// A light classification for the hint only; the resolver decides what a
    /// link really is and refuses the unusable ones with a reason.
    // TODO(core-input lane): replace with the RobogearsCore link parser once merged.
    static func classify(_ raw: String) -> AddInputKind {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("spotify:")
            || lower.hasPrefix("tidal.com/") || lower.hasPrefix("open.spotify.com/") || lower.hasPrefix("listen.tidal.com/") {
            return .link
        }
        return .search(text)
    }

    var hint: String {
        switch self {
        case .empty: "Paste a Spotify or TIDAL link, or type a song name."
        case .link: "Press Return to add every track from this link."
        case .search(let text): "Press Return to search TIDAL for “\(text)”."
        }
    }
}
