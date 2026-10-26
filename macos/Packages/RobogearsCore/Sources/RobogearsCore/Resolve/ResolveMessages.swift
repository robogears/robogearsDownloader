import Foundation

/// Every sentence the resolver hands the window. Plain words that say what
/// happened and what to do (the owner's copy rule; D4 4.2), naming the
/// source. Raw server text never appears here: it goes to `.log` lines only.
enum ResolveMessages {

    // MARK: Network and sign-in (D4 1.4, 1.6, 1.7)

    static let noInternet = "No internet connection. Check your connection, then click Try Again."
    static let tidalBusy = "TIDAL is busy. Wait a minute, then click Try Again."
    static let spotifyBusy = "Spotify isn't answering right now. Wait a minute, then click Try Again."
    static let tidalUnreadable = "TIDAL's answer couldn't be read. Try again in a minute."

    static func signInNeeded(_ name: String) -> String {
        "Sign in to TIDAL to add tracks from \(sourceName(for: name))."
    }

    /// The reasons a row shows when its lookup failed rather than found
    /// nothing. They look different from the red "not found" (D4 1.4).
    enum CouldNotCheck {
        static let busy = "Couldn't check: TIDAL was busy"
        static let refused = "Couldn't check: TIDAL refused the search"
        static let unreadable = "Couldn't check: TIDAL's answer couldn't be read"
        static let offline = "Couldn't check: no internet connection"
        static let signIn = "Couldn't check: sign in to TIDAL first"
    }

    // MARK: Links (D4 4.2, 4.3)

    static func unsupported(_ link: ParsedInput.Unsupported) -> String {
        let service = link.service.displayName
        switch link.reason {
        case .otherService:
            if case let .website(host) = link.service {
                return "Links to \(host) aren't supported. Paste a TIDAL or Spotify link, or type the song's name."
            }
            return "\(service) links aren't supported. Paste a TIDAL or Spotify link, or type the song's name."
        case let .unsupportedPage(page):
            switch page {
            case .artist:
                return "\(service) artist pages can't be added. Open an album or playlist and copy its link."
            case .mix:
                return "\(service) mixes can't be added. Open an album or playlist and copy its link."
            case .video:
                return "\(service) videos can't be added. Open a track, album or playlist and copy its link."
            case .profile:
                return "\(service) profile pages can't be added. Open one of the playlists and copy its link."
            case .podcast:
                return "\(service) podcasts can't be added. Paste a link to a track, album or playlist."
            case .audiobook:
                return "\(service) audiobooks can't be added. Paste a link to a track, album or playlist."
            case .collection:
                return "Your \(service) library can't be added as a whole. Copy a playlist's link, or export it with Exportify."
            case let .other(word):
                return "\(service) \(word) pages can't be added. Paste a link to a track, album or playlist."
            }
        case .unrecognisedPage:
            return "This \(service) link doesn't lead to a track, album or playlist. Copy the link from one of those."
        case let .malformedID(content):
            return "This \(service) \(content.rawValue) link looks incomplete. Copy it again from \(service)."
        }
    }

    static let notALink = "There's no link here. Paste a TIDAL or Spotify link, or type a song name to search."

    static func tidalNotAvailable(_ content: ParsedInput.Content) -> String {
        "This TIDAL \(content.rawValue) isn't available. It may have been removed, or it isn't offered in your country."
    }

    static func tidalRefused(_ content: ParsedInput.Content) -> String {
        "TIDAL refused to open this \(content.rawValue). Check that your TIDAL subscription is active, then try again."
    }

    static func spotifyRefused(_ content: ParsedInput.Content) -> String {
        switch content {
        case .playlist:
            return "Spotify won't share this playlist. Make it public in Spotify, or export it with Exportify."
        case .album, .track:
            return "Spotify couldn't find this \(content.rawValue). Check the link, or type the song's name to search."
        }
    }

    static let shortLinkPage = "Short links can't be opened here. Open it in your browser, then copy the open.spotify.com link."
    static let shortLinkElsewhere = "This short link doesn't lead to a Spotify track, album or playlist."

    // MARK: Tracklists (D4 4.8, 4.17)

    static func notText(_ name: String) -> String {
        "\(name) isn't a text tracklist. Drop a CSV or text tracklist, or a TIDAL or Spotify link."
    }

    static func emptyTracklist(_ name: String?) -> String {
        let place = name.map { "in \($0)" } ?? "in the pasted text"
        return "No songs or links were found \(place). Use one song per line (“Title - Artist”) or a CSV with title and artist columns."
    }

    // MARK: Spotify's 100-track cap (D4 4.4)

    /// Nil when Spotify's page says the playlist isn't longer than what it
    /// listed: then nothing was left out and nothing should be claimed
    /// (D4 4.4 A: with a real count, "the message appears only for longer
    /// playlists").
    static func spotifyCap(playlistName: String, listed: Int, total: Int?) -> String? {
        let name = playlistName.isEmpty ? "the playlist" : playlistName
        if let total {
            guard total > listed else { return nil }
            return "Added the first \(number(listed)) of \(number(total)) tracks. "
                + "To get the other \(number(total - listed)), export the playlist with Exportify and drop the CSV here."
        }
        return "Spotify only shares the first \(number(listed)) tracks of a playlist. "
            + "If \(name) is longer, export it with Exportify and drop the CSV here. "
            + "Songs matched to the same TIDAL track aren't added twice."
    }

    // MARK: Search (D4 4.1, 4.11)

    static func noResults(_ query: String, looksLikeID: Bool) -> String {
        var text = "No TIDAL results for “\(query)”. Check the spelling or try fewer words."
        if looksLikeID {
            text += " Looking for a TIDAL track or playlist by its ID? Paste its link instead."
        }
        return text
    }

    // MARK: Summaries (D4 4.2, 4.9)

    static func summary(_ s: ResolveSummary) -> String {
        var sentences: [String] = []
        let unitWord = s.unit == .lines ? "line" : "track"

        if s.stopped {
            var head = "Stopped"
            if let total = s.total, total > 0 { head += " after \(number(s.processed)) of \(number(total))" }
            sentences.append(head + ".")
            var added = "Added \(count(s.added, "track"))"
            if s.notOnTIDAL > 0 { added += ", \(number(s.notOnTIDAL)) not found" }
            sentences.append(added + ".")
            if let total = s.total, total > s.processed {
                let rest = total - s.processed
                sentences.append("The other \(count(rest, unitWord)) \(rest == 1 ? "wasn't" : "weren't") added.")
            }
        } else if s.added == 0, s.alreadyInQueue > 0, s.notOnTIDAL == 0, s.couldNotCheck == 0 {
            sentences.append(s.alreadyInQueue == 1
                ? "This track is already in the queue."
                : "All \(number(s.alreadyInQueue)) tracks are already in the queue.")
        } else if s.added == 0 {
            sentences.append("No tracks were found in \(sourceName(for: s.sourceName)).")
        } else {
            var head = "Added \(count(s.added, "track")) from \(sourceName(for: s.sourceName))"
            if s.notOnTIDAL > 0 || s.couldNotCheck > 0 {
                var parts = ["\(number(s.found)) found on TIDAL"]
                if s.notOnTIDAL > 0 { parts.append("\(number(s.notOnTIDAL)) not found") }
                if s.couldNotCheck > 0 { parts.append("\(number(s.couldNotCheck)) couldn't be checked") }
                head += ": " + parts.joined(separator: ", ")
            }
            sentences.append(head + ".")
        }

        if !(s.added == 0 && s.alreadyInQueue > 0 && !s.stopped) {
            if s.alreadyInQueue > 0 {
                sentences.append("\(number(s.alreadyInQueue)) \(s.alreadyInQueue == 1 ? "was" : "were") already in the queue.")
            }
        }
        if s.differentArtist > 0 {
            sentences.append("\(number(s.differentArtist)) \(s.differentArtist == 1 ? "is" : "are") left out: TIDAL credits a different artist.")
        }
        if s.sameTIDALTrack > 0 {
            sentences.append("\(number(s.sameTIDALTrack)) matched the same TIDAL track as another row.")
        }
        if s.videosSkipped > 0 {
            sentences.append("Skipped \(count(s.videosSkipped, "video")).")
        }
        if !s.skippedLinks.isEmpty {
            let reasons = Set(s.skippedLinks.map(\.reason))
            var text = "Skipped \(count(s.skippedLinks.count, "link")) the app can't add"
            if reasons.count == 1, let reason = reasons.first { text += ": " + reason } else { text += "." }
            sentences.append(text)
        }
        return sentences.joined(separator: " ")
    }

    /// "the link" reads better than "link" inside a sentence.
    static func sourceName(for name: String) -> String {
        name == "link" ? "the link" : name
    }

    // MARK: Numbers

    /// Thousands separators, as the copy rules ask ("1,250"), fixed to the
    /// English the copy is written in.
    static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    static func count(_ value: Int, _ noun: String) -> String {
        "\(number(value)) \(noun)\(value == 1 ? "" : "s")"
    }
}
