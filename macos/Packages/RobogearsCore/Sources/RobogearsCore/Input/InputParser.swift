// Reads the main input field: a TIDAL or Spotify link, some other link, or a
// search.
//
// Reference: docs/electron-reference/tidal-and-spotify-networking.md §D and
// text-unicode-and-filenames.md §9. Behaviour changes follow decision cards
// G4-1 (plain text always searches), G4-2 (unsupported links are named, never
// searched) and G4-3 (every common link form is accepted; an album+track link
// adds just the track).

import Foundation

public enum InputParser {
    /// Reads `text` the way Return in the main field will act on it.
    ///
    /// The first link found anywhere in the text wins, so words before or
    /// after a link are ignored (G4-3: words after a TIDAL link used to become
    /// part of its ID). Text with no link is a search.
    public static func parse(_ text: String) -> ParsedInput {
        let trimmed = text.trimmingCharacters(in: trimSet)
        guard !trimmed.isEmpty else { return .empty }
        for token in trimmed.split(whereSeparator: { $0.isWhitespace }) {
            let candidate = stripWrapping(token)
            if candidate.isEmpty { continue }
            if let link = findLink(in: candidate) { return link }
        }
        return .search(query: trimmed, looksLikeID: looksLikeTidalID(trimmed))
    }

    /// Whether `text` is shaped like a bare TIDAL ID: only digits, or a
    /// playlist UUID. The Electron app opened these directly; now they are
    /// searched, and this lets "no results" point at pasting the link instead
    /// (G4-1 skeptic refinement).
    public static func looksLikeTidalID(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: trimSet)
        return isASCIIDigits(s) || isUUID(s)
    }

    // MARK: - Tokens

    /// Whitespace plus a stray byte-order mark, which Foundation's whitespace
    /// set doesn't include (text-unicode-and-filenames.md §6).
    static let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static let openers: Set<Character> = [
        "<", "(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}", "\u{00AB}", "\u{2039}",
        // Full-width and CJK brackets: （ 「 『 【 《 〈
        "\u{FF08}", "\u{300C}", "\u{300E}", "\u{3010}", "\u{300A}", "\u{3008}",
    ]
    private static let closers: Set<Character> = [
        ">", ")", "]", "}", "\"", "'", "\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}",
        ",", ".", ";", ":", "!", "?",
        // Typographic punctuation: … — –
        "\u{2026}", "\u{2014}", "\u{2013}",
        // CJK and full-width punctuation: 。 、 ， ． ！ ？ ： ； ） 」 』 】 》 〉
        "\u{3002}", "\u{3001}", "\u{FF0C}", "\u{FF0E}", "\u{FF01}", "\u{FF1F}", "\u{FF1A}", "\u{FF1B}",
        "\u{FF09}", "\u{300D}", "\u{300F}", "\u{3011}", "\u{300B}", "\u{3009}",
    ]

    /// Links pasted from chats and Markdown arrive wrapped in brackets or
    /// quotes, or followed by punctuation, including the CJK full stop the
    /// Electron pattern simply stopped at.
    private static func stripWrapping(_ token: Substring) -> Substring {
        var t = token
        while let first = t.first, openers.contains(first) { t = t.dropFirst() }
        while let last = t.last, closers.contains(last) { t = t.dropLast() }
        return t
    }

    // MARK: - Finding a link inside a token

    /// The link in one whitespace-free token, which may have text stuck to
    /// its front: "Listen:https://…", "[Blue Lantern](https://…)" or an emoji
    /// before the address. The Electron patterns matched anywhere in the
    /// text, so these worked there (G4-3 TODAY); without this they would be
    /// searched as song names, which G4-2 forbids.
    ///
    /// Every place a link could start is tried, earliest first. A TIDAL or
    /// Spotify link found further in beats a refusal for the outer address,
    /// so a redirect such as "https://example.org/out?u=https://tidal.com/…"
    /// still adds the TIDAL link.
    static func findLink(in token: Substring) -> ParsedInput? {
        var refusal: ParsedInput?
        for start in linkStarts(in: token) {
            guard let result = classifyLink(token[start...]) else { continue }
            if case .unsupported = result {
                refusal = refusal ?? result
                continue
            }
            return result
        }
        return refusal
    }

    /// The token's start, then the start of every "<letters>://" scheme and
    /// every "spotify:" that begins a word, in order.
    private static func linkStarts(in token: Substring) -> [Substring.Index] {
        var starts: [Substring.Index] = [token.startIndex]
        var searchFrom = token.startIndex
        while let separator = token.range(of: "://", range: searchFrom..<token.endIndex) {
            var schemeStart = separator.lowerBound
            while schemeStart > token.startIndex {
                let previous = token.index(before: schemeStart)
                guard token[previous].isASCII, token[previous].isLetter else { break }
                schemeStart = previous
            }
            if schemeStart < separator.lowerBound { starts.append(schemeStart) }
            searchFrom = separator.upperBound
        }
        searchFrom = token.startIndex
        while let uri = token.range(of: "spotify:", options: .caseInsensitive, range: searchFrom..<token.endIndex) {
            // "notspotify:track:…" isn't a URI; "URI:spotify:track:…" is.
            if uri.lowerBound > token.startIndex {
                let previous = token[token.index(before: uri.lowerBound)]
                if !(previous.isASCII && (previous.isLetter || previous.isNumber)) { starts.append(uri.lowerBound) }
            }
            searchFrom = uri.upperBound
        }
        var seen = Set<Substring.Index>()
        return starts.sorted().filter { seen.insert($0).inserted }
    }

    // MARK: - Link classification

    /// Returns nil when the token isn't a link at all.
    static func classifyLink(_ token: Substring) -> ParsedInput? {
        if token.lowercased().hasPrefix("spotify:") {
            return spotifyURI(token)
        }
        guard let parts = LinkParts(token) else { return nil }
        let host = parts.host

        if spotifyShortLinkHosts.contains(host) {
            let path = parts.path
            guard path.count > 1, let url = URL(string: "https://\(host)\(path)") else {
                return .unsupported(.init(service: .spotify, reason: .unrecognisedPage, link: String(token)))
            }
            return .spotifyShortLink(url)
        }

        let service = service(forHost: host)
        if !parts.hadScheme {
            // Without "https://", only addresses of services we know (or a
            // "www." address) count as links, so a title like "Ex.Machina/2"
            // stays a search.
            if case .website = service, !host.hasPrefix("www.") { return nil }
        }

        switch service {
        case .tidal:
            return tidal(segments: parts.segments, link: String(token))
        case .spotify:
            return spotify(segments: parts.segments, link: String(token))
        default:
            return .unsupported(.init(service: service, reason: .otherService, link: String(token)))
        }
    }

    // MARK: TIDAL

    private static let tidalContent: [String: ParsedInput.Content] = [
        "track": .track, "tracks": .track,
        "album": .album, "albums": .album,
        "playlist": .playlist, "playlists": .playlist,
    ]

    private static let tidalPages: [String: ParsedInput.Page] = [
        "artist": .artist, "artists": .artist,
        "mix": .mix, "mixes": .mix,
        "video": .video, "videos": .video,
        "user": .profile, "profile": .profile,
        "my-collection": .collection,
    ]

    /// Any tidal.com host, with or without `/browse`. The last kind/ID pair
    /// wins, so `…/album/A/track/T` adds only track T (G4-3).
    private static func tidal(segments: [String], link: String) -> ParsedInput {
        func refuse(_ reason: ParsedInput.Unsupported.Reason) -> ParsedInput {
            .unsupported(.init(service: .tidal, reason: reason, link: link))
        }
        switch lastPair(in: segments, kinds: tidalContent) {
        case .pair(let content, let id, let kindIndex):
            switch content {
            case .track, .album:
                if let number = digitsValue(id) {
                    return .tidal(content == .track ? .track(id: number) : .album(id: number))
                }
            case .playlist:
                if isUUID(id) { return .tidal(.playlist(uuid: id)) }
            }
            if let page = firstPage(in: segments[..<kindIndex], pages: tidalPages) { return refuse(.unsupportedPage(page)) }
            return refuse(.malformedID(content))
        case .missingID(let content, let kindIndex):
            if let page = firstPage(in: segments[..<kindIndex], pages: tidalPages) { return refuse(.unsupportedPage(page)) }
            return refuse(.malformedID(content))
        case .none:
            if let page = firstPage(in: segments[...], pages: tidalPages) { return refuse(.unsupportedPage(page)) }
            return refuse(.unrecognisedPage)
        }
    }

    // MARK: Spotify

    private static let spotifyContent: [String: ParsedInput.Content] = [
        "track": .track, "album": .album, "playlist": .playlist,
    ]

    private static let spotifyPages: [String: ParsedInput.Page] = [
        "artist": .artist,
        "episode": .podcast, "show": .podcast,
        "user": .profile,
        "collection": .collection,
        "audiobook": .audiobook, "chapter": .audiobook,
        "genre": .other("genre"), "concert": .other("concert"), "search": .other("search"),
        "local": .other("local"), "prerelease": .other("prerelease"),
    ]

    static let spotifyShortLinkHosts: Set<String> = ["spotify.link", "spoti.fi", "spotify.app.link"]

    /// `open.spotify.com` links, including `/intl-xx/`, `/embed/` and the old
    /// `/user/<name>/playlist/<id>` forms (G4-3).
    private static func spotify(segments: [String], link: String) -> ParsedInput {
        func refuse(_ reason: ParsedInput.Unsupported.Reason) -> ParsedInput {
            .unsupported(.init(service: .spotify, reason: reason, link: link))
        }
        let meaningful = segments.filter { segment in
            let lower = segment.lowercased()
            return !(lower.hasPrefix("intl-") || lower == "embed" || lower == "embed-legacy")
        }
        // Before a track, album or playlist word, "user" is the old
        // `/user/<name>/playlist/<id>` form, not a profile page.
        let pagesBeforeKind = spotifyPages.filter { $0.key != "user" }
        switch lastPair(in: meaningful, kinds: spotifyContent) {
        case .pair(let content, let id, let kindIndex):
            if let id = spotifyIDPrefix(id) { return .spotify(.init(content: content, id: id)) }
            if let page = firstPage(in: meaningful[..<kindIndex], pages: pagesBeforeKind) { return refuse(.unsupportedPage(page)) }
            return refuse(.malformedID(content))
        case .missingID(let content, let kindIndex):
            if let page = firstPage(in: meaningful[..<kindIndex], pages: pagesBeforeKind) { return refuse(.unsupportedPage(page)) }
            return refuse(.malformedID(content))
        case .none:
            if let first = meaningful.first, let page = spotifyPages[first.lowercased()] {
                return refuse(.unsupportedPage(page))
            }
            return refuse(.unrecognisedPage)
        }
    }

    /// "Copy Spotify URI" gives `spotify:track:<id>`; old playlists are
    /// `spotify:user:<name>:playlist:<id>`. Anything shorter than
    /// `spotify:<kind>:<id>` isn't treated as a link, so a search for
    /// "Spotify: Blue Lantern" still searches.
    private static func spotifyURI(_ token: Substring) -> ParsedInput? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return spotify(segments: Array(parts.dropFirst()), link: String(token))
    }

    // MARK: Shared helpers

    private enum PairResult {
        /// A kind word at `kindIndex`, followed by the segment that should be
        /// its ID.
        case pair(ParsedInput.Content, id: String, kindIndex: Int)
        /// A kind word that ends the path, with nothing after it.
        case missingID(ParsedInput.Content, kindIndex: Int)
        case none
    }

    /// Finds the last `<kind>/<id>` pair in a path.
    private static func lastPair(in segments: [String], kinds: [String: ParsedInput.Content]) -> PairResult {
        var trailing: (content: ParsedInput.Content, index: Int)?
        for index in segments.indices.reversed() {
            guard let content = kinds[segments[index].lowercased()] else { continue }
            if index + 1 < segments.count { return .pair(content, id: segments[index + 1], kindIndex: index) }
            trailing = trailing ?? (content, index)
        }
        if let trailing { return .missingID(trailing.content, kindIndex: trailing.index) }
        return .none
    }

    /// The first page word in `segments`. When an address names a page the
    /// app can't add before its track, album or playlist word
    /// ("…/artist/<id>/discography/album", "…/my-collection/tracks"), the
    /// refusal names that page rather than calling the link broken (G4-2).
    private static func firstPage(in segments: ArraySlice<String>, pages: [String: ParsedInput.Page]) -> ParsedInput.Page? {
        segments.lazy.compactMap { pages[$0.lowercased()] }.first
    }

    static func service(forHost host: String) -> ParsedInput.Service {
        func within(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if within("tidal.com") { return .tidal }
        if within("spotify.com") { return .spotify }
        if within("music.youtube.com") { return .youTubeMusic }
        if within("youtube.com") || within("youtu.be") || within("youtube-nocookie.com") { return .youTube }
        if within("music.apple.com") || within("itunes.apple.com") { return .appleMusic }
        if within("soundcloud.com") || within("snd.sc") { return .soundCloud }
        if within("deezer.com") || within("deezer.page.link") || within("dzr.page.link") { return .deezer }
        if within("bandcamp.com") { return .bandcamp }
        if host.hasPrefix("music.amazon.") || host.contains(".music.amazon.") { return .amazonMusic }
        if within("qobuz.com") { return .qobuz }
        if within("beatport.com") { return .beatport }
        return .website(host: host)
    }

    static func isASCIIDigits<S: StringProtocol>(_ s: S) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// The value of an all-digits ID, or nil when it isn't one or doesn't fit.
    static func digitsValue(_ s: String) -> Int? {
        isASCIIDigits(s) ? Int(s) : nil
    }

    /// TIDAL playlist IDs: 8-4-4-4-12 hexadecimal, either case (the Electron
    /// pattern, `tidal_lib.js:442`).
    static func isUUID<S: StringProtocol>(_ s: S) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                if byte != UInt8(ascii: "-") { return false }
            } else if !isHexDigit(byte) {
                return false
            }
        }
        return true
    }

    private static func isHexDigit(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }

    /// The leading base-62 run of a Spotify ID segment, or nil when it has
    /// none. Spotify IDs are base-62, and the Electron pattern
    /// `[a-zA-Z0-9]+` stopped at the first other character, so punctuation
    /// stuck to the end of a link ("…/track/<id>’s") is left behind rather
    /// than refusing the link. Nothing else ever reaches a request.
    private static func spotifyIDPrefix(_ s: String) -> String? {
        let run = s.utf8.prefix { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
        }
        return run.isEmpty ? nil : String(decoding: run, as: UTF8.self)
    }
}

/// A link split into host and path segments without Foundation's URL parser,
/// which rejects some pasted forms (no scheme, stray characters) outright.
struct LinkParts {
    /// Lowercased host with any user, port and trailing dot removed.
    let host: String
    /// The path, case preserved, without query or fragment ("" or "/…").
    let path: String
    let segments: [String]
    let hadScheme: Bool

    init?(_ token: Substring) {
        var rest = token
        if let separator = token.range(of: "://") {
            let scheme = token[..<separator.lowerBound]
            guard !scheme.isEmpty, scheme.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
            rest = token[separator.upperBound...]
            hadScheme = true
        } else {
            hadScheme = false
        }

        let hostEnd = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var hostPart = rest[..<hostEnd]
        if let at = hostPart.lastIndex(of: "@") { hostPart = hostPart[hostPart.index(after: at)...] }
        if let colon = hostPart.lastIndex(of: ":"),
           hostPart[hostPart.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            hostPart = hostPart[..<colon]
        }
        var host = hostPart.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        guard host.contains("."), !host.hasPrefix(".") else { return nil }
        self.host = host

        let afterHost = rest[hostEnd...]
        let pathEnd = afterHost.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? afterHost.endIndex
        let path = String(afterHost[..<pathEnd])
        self.path = path
        self.segments = path.split(separator: "/").map(String.init)
    }
}
