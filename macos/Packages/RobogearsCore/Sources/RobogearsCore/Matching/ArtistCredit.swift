/// Who a source says performs a track, in the shape the source gave it.
///
/// The shape matters because of how artists are compared (D4 3.2 and 3.3,
/// cards G3-2 and G3-3 with the skeptics' corrections). The Electron app took
/// each word of the wanted artist longer than two letters and looked for it
/// anywhere inside TIDAL's joined artist names, so "the" in "The Placeholders"
/// was found inside "Another Band", and a library tag "Ox" agreed with "Boxer
/// Collective". Now artists are compared as whole names:
///
/// - TIDAL (and Spotify's artist array) already give separate names, which are
///   never split, so a band called "Salt, Wind & Lantern" stays one name.
/// - Free text (Spotify's subtitle line, a CSV cell, a library tag) is split at
///   commas, semicolons, slashes, "&", brackets and "feat."/"featuring", and at
///   " x " or " vs " between two names; the unsplit line is kept as well. A
///   piece counts only by equalling a whole name on the other side, never as a
///   fragment inside one.
public enum ArtistCredit: Sendable, Hashable {
    /// The source has no artist at all, for example a CSV without an artist
    /// column. Matching then keeps today's title-only acceptance.
    case unknown
    /// Separate names from a structured list (TIDAL's `artists[]`, Spotify's
    /// track `artists[]`). Each name is compared whole.
    case names([String])
    /// One free-text line that may hold several names.
    case text(String)

    /// True when the credit names at least one artist that gives a usable key.
    public var isKnown: Bool { !pieceKeys.isEmpty }

    /// The keys that count as "one artist" on this side: each listed name, or
    /// each piece of a free-text line. Deduplicated, in order, never empty.
    var pieceKeys: [String] {
        switch self {
        case .unknown:
            return []
        case .names(let names):
            return Self.uniqueKeys(names.map(Normalizer.fullKey))
        case .text(let line):
            return Self.uniqueKeys(Self.splitFreeText(line).map(Normalizer.fullKey))
        }
    }

    /// The key of the whole unsplit line, for free text only. A line made only
    /// of separators (", &") names nobody and has no key.
    var wholeLineKey: String? {
        guard case .text(let line) = self, isKnown else { return nil }
        let key = Normalizer.fullKey(line)
        return key.isEmpty ? nil : key
    }

    /// Every key that may confirm an artist on this side: the pieces plus the
    /// unsplit line. Two credits agree when these sets share a key.
    var comparisonKeys: Set<String> {
        var keys = Set(pieceKeys)
        if let whole = wholeLineKey { keys.insert(whole) }
        return keys
    }

    // MARK: - Splitting free text

    /// Characters that always separate names in a free-text artist line.
    /// "、" is the Japanese list comma; brackets catch "A (feat. B)".
    private static let separatorCharacters: Set<Character> = [",", ";", "/", "&", "、", "(", ")", "[", "]"]

    /// Whole words that separate names when they stand alone between spaces.
    private static let joinerWords: Set<String> = ["x", "vs", "vs."]
    private static let featuringWords: Set<String> = ["feat", "feat.", "ft", "ft.", "featuring"]

    /// Splits a free-text artist line into names. Works on folded text so
    /// "X", "Feat." and full-width "＆" are recognised; the pieces are only
    /// used to build keys, never shown.
    static func splitFreeText(_ line: String) -> [String] {
        let folded = Normalizer.fold(line)
        var pieces: [String] = []
        var current: [Substring] = []

        func closePiece() {
            if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
            current = []
        }

        var spaced = ""
        for character in folded {
            if separatorCharacters.contains(character) {
                spaced.append(" \u{1F} ")
            } else {
                spaced.append(character)
            }
        }
        let words = spaced.split(whereSeparator: \.isWhitespace)
        for (index, word) in words.enumerated() {
            let nameFollows = index + 1 < words.count && words[index + 1] != "\u{1F}"
            // "x" and "vs" separate only between two names, so "X Harbor Band"
            // and "Placeholder X" stay whole. "feat." may also open a bracket,
            // "(feat. Second Guest)", where it is simply dropped.
            let isJoiner = joinerWords.contains(String(word)) && !current.isEmpty && nameFollows
            let isFeaturing = featuringWords.contains(String(word)) && index > 0 && nameFollows
            if word == "\u{1F}" || isJoiner || isFeaturing {
                closePiece()
            } else {
                current.append(word)
            }
        }
        closePiece()
        return pieces
    }

    private static func uniqueKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
