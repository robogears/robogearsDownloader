import Foundation

/// Turns titles and artist names into the keys every matcher compares.
///
/// The Electron app had four copies of an ASCII-only normaliser: every character
/// outside `a-z`, `0-9` became a space, so "Café Étoile" turned into "caf toile"
/// and a title written only in Japanese or Cyrillic turned into an empty string
/// that then "matched" every other empty title with no artist check
/// (reference: library-scanner-and-matcher.md §2, tidal-and-spotify-networking.md
/// §G, defect M5). The owner chose the Unicode-aware, accent-insensitive rule
/// (D4 3.1, card G3-1 option A with the skeptic's empty-key guard):
///
/// - letters and digits from every script are kept;
/// - accents, letter width and case are folded, so "Cafe Etoile" equals
///   "Café Étoile" and the two ways a Mac can store "é" compare alike;
/// - a title made only of symbols or emoji ("♡", "!!!") is compared on its raw
///   folded text instead of becoming empty;
/// - an empty key never agrees with anything, not even another empty key.
public enum Normalizer {

    // MARK: - Keys

    /// The "full" key: folded text with punctuation turned into single spaces.
    /// Version text such as "Radio Edit" stays in, so two editions differ.
    public static func fullKey(_ text: String) -> String {
        key(fromFolded: fold(text))
    }

    /// The "core" key: like `fullKey`, after removing the tails that only name a
    /// version of the same song, so different versions compare equal:
    /// - a bracketed or parenthesised tail with text before it, `Song (Live)`;
    /// - a featuring tail, `Song feat. Guest`;
    /// - a spaced-dash tail that names a version, `Song - 2011 Remaster`.
    public static func coreKey(_ text: String) -> String {
        key(fromFolded: stripVersionTails(fold(text)))
    }

    /// Two keys agree only when both are non-empty and equal. Every matcher goes
    /// through this, so an untitled or unreadable entry can never match another
    /// one by both being empty (the G3-1 skeptic's guard).
    public static func keysAgree(_ a: String, _ b: String) -> Bool {
        !a.isEmpty && a == b
    }

    // MARK: - Folding

    /// Compatibility-maps, lowercases and strips accents, keeping punctuation so
    /// the version-tail rules can still see brackets and dashes.
    ///
    /// - NFKC maps full-width letters and brackets, ligatures and superscripts to
    ///   their plain forms (`（Live）` → `(live)`, `ﬁ` → `fi`, `²` → `2`).
    /// - `ß` becomes `ss` and final `ς` becomes `σ`, as full case folding does.
    /// - Only the general-purpose accent marks are removed (the Combining
    ///   Diacritical Marks blocks used with Latin, Greek and Cyrillic), plus
    ///   Hebrew points and Arabic vowel marks, which are usually left out in
    ///   writing. Marks that change the letter itself are kept: Japanese voicing
    ///   marks (が is not か) and Indic vowel signs. Letters with no removable mark
    ///   stay distinct, so `ø` and `o` still differ (D4 3.1 cost note).
    static func fold(_ text: String) -> String {
        var lowered = text.precomposedStringWithCompatibilityMapping.lowercased()
        if lowered.contains("ß") { lowered = lowered.replacingOccurrences(of: "ß", with: "ss") }
        if lowered.contains("ς") { lowered = lowered.replacingOccurrences(of: "ς", with: "σ") }
        var kept = String.UnicodeScalarView()
        for scalar in lowered.decomposedStringWithCanonicalMapping.unicodeScalars
        where !isFoldedAway(scalar) {
            kept.append(scalar)
        }
        return String(kept).precomposedStringWithCanonicalMapping
    }

    private static func isFoldedAway(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F,   // Combining Diacritical Marks
             0x1AB0...0x1AFF,   // … Extended
             0x1DC0...0x1DFF,   // … Supplement
             0x20D0...0x20FF,   // … for Symbols (keycaps, enclosing circles)
             0xFE20...0xFE2F,   // Combining Half Marks
             0xFE00...0xFE0F,   // variation selectors (emoji presentation)
             0xE0100...0xE01EF, // variation selectors supplement
             0x0591...0x05BD, 0x05BF, 0x05C1...0x05C2, 0x05C4...0x05C5, 0x05C7, // Hebrew points
             0x064B...0x065F, 0x0670: // Arabic vowel marks
            return true
        default:
            return false
        }
    }

    /// Keeps letters, digits and the marks `fold` left in place; everything else
    /// (punctuation, symbols, spaces) becomes one space. A title with no letters
    /// or digits at all falls back to its folded text with spaces collapsed.
    static func key(fromFolded folded: String) -> String {
        var letters = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if isKeyScalar(scalar) {
                if pendingSpace && !letters.isEmpty { letters.append(" ") }
                pendingSpace = false
                letters.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        if !letters.isEmpty { return String(letters) }
        return symbolKey(fromFolded: folded)
    }

    private static func isKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        case .modifierLetter:
            // Spacing Modifier Letters (U+02B0–U+02FF) include apostrophe look-alikes
            // such as ʼ (U+02BC); treat them as punctuation, like a plain ' is.
            // Modifier letters elsewhere (Japanese ー, 々) are part of words.
            return !(0x02B0...0x02FF).contains(scalar.value)
        default:
            return false
        }
    }

    private static func symbolKey(fromFolded folded: String) -> String {
        var symbols = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format:
                continue
            default:
                break
            }
            if pendingSpace && !symbols.isEmpty { symbols.append(" ") }
            pendingSpace = false
            symbols.append(scalar)
        }
        return String(symbols)
    }

    // MARK: - Version tails

    /// The words that mark a tail as "another version of the same song". The
    /// list is today's (`VERSION_RE` in tidal_lib.js:646-649); what changed is
    /// where they may appear (see `isVersionSegment`).
    public static let versionWords: [String] = [
        "remix", "edit", "mix", "extended", "radio", "original", "instrumental",
        "acoustic", "live", "remaster", "version", "club", "vip", "dub",
        "bootleg", "rework", "reprise", "demo", "single", "album",
    ]

    /// Endings a version word may carry and still count: "Remastered",
    /// "Remixed by", "Deluxe Edition", "Remixes". Kept short so that ordinary
    /// words starting the same way ("lively", "mixtape", "dubai") don't count.
    private static let versionWordEndings: Set<String> = ["", "s", "es", "ed", "ing", "ion", "ions", "er", "ers"]

    /// "Reprise" makes its past tense with a plain "-d" ("Reprised"), which the
    /// endings above can't express (matching review, finding 3). Only this
    /// stem gets it: "Lived" and "Singled" are ordinary words, so "live" and
    /// "single" must not.
    private static let stemsTakingD: Set<String> = ["reprise"]

    static func stripVersionTails(_ folded: String) -> String {
        var text = Array(folded)
        text = cutAtBracket(text)
        text = cutAtFeaturing(text)
        text = cutAtVersionDash(text)
        return String(text)
    }

    /// Cuts at the first `(` or `[` that has text before it. Today's rule cut
    /// only at the very first bracket and only when it wasn't at index 0, so
    /// "(Paper) Harbor (Live)" kept "(Live)" and "  (Paper) Harbor" was cut to
    /// nothing (reference §2, normaliser examples 12 and 21). A missing closing
    /// bracket still cuts, as today.
    private static func cutAtBracket(_ text: [Character]) -> [Character] {
        var seenText = false
        for (index, character) in text.enumerated() {
            if (character == "(" || character == "[") && seenText {
                return Array(text[..<index])
            }
            if !character.isWhitespace { seenText = true }
        }
        return text
    }

    /// Cuts at "feat." / "ft." (with the dot) or the spelled-out "featuring".
    /// A bare "ft" or "feat" no longer counts, so "Seven Ft Harbor" stays whole
    /// (D4 3.12 option A); inside brackets the bracket rule already cuts it.
    private static func cutAtFeaturing(_ text: [Character]) -> [Character] {
        var index = 1
        while index < text.count {
            if text[index - 1].isWhitespace, hasTextBefore(text, index - 1) {
                let rest = text[index...]
                if rest.starts(with: "feat.") || rest.starts(with: "ft.")
                    || (rest.starts(with: "featuring") && rest.count > 9
                        && rest[rest.startIndex + 9].isWhitespace) {
                    return trimmingTrailingWhitespace(Array(text[..<index]))
                }
            }
            index += 1
        }
        return text
    }

    /// Cuts at the first spaced dash (" - ", " – ", " — ") whose segment names a
    /// version anywhere in it, so "- 2011 Remaster" and "- Remixed by X" are
    /// recognised as well as "- Radio Edit" (D4 3.12 option A). The segment runs
    /// to the next spaced dash, so "Song - Part 2 - Radio Edit" keeps "Part 2".
    /// An unspaced hyphen ("Anti-Hero", "Song -Radio Edit") never cuts.
    private static func cutAtVersionDash(_ text: [Character]) -> [Character] {
        let separators = spacedDashPositions(text)
        for (number, position) in separators.enumerated() {
            let segmentEnd = number + 1 < separators.count ? separators[number + 1] : text.count
            let segment = text[(position + 1)..<segmentEnd]
            if isVersionSegment(segment) {
                return trimmingTrailingWhitespace(Array(text[..<position]))
            }
        }
        return text
    }

    /// Positions of dash characters with whitespace on both sides and text before.
    static func spacedDashPositions(_ text: [Character]) -> [Int] {
        guard text.count >= 3 else { return [] }
        var positions: [Int] = []
        for index in 1..<(text.count - 1)
        where isDash(text[index]) && text[index - 1].isWhitespace && text[index + 1].isWhitespace
            && hasTextBefore(text, index) {
            positions.append(index)
        }
        return positions
    }

    static func isDash(_ character: Character) -> Bool {
        // Hyphen-minus, hyphen, non-breaking hyphen, figure dash, en dash, em
        // dash, horizontal bar, minus sign. NFKC already maps the small and
        // full-width forms onto these.
        "-‐‑‒–—―−".contains(character)
    }

    private static func isVersionSegment(_ segment: ArraySlice<Character>) -> Bool {
        var word = ""
        for character in segment {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                if isVersionWord(word) { return true }
                word = ""
            }
        }
        return isVersionWord(word)
    }

    private static func isVersionWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        for stem in versionWords where word.hasPrefix(stem) {
            let ending = String(word.dropFirst(stem.count))
            if versionWordEndings.contains(ending) { return true }
            if ending == "d" && stemsTakingD.contains(stem) { return true }
        }
        return false
    }

    private static func hasTextBefore(_ text: [Character], _ index: Int) -> Bool {
        text[..<index].contains { !$0.isWhitespace }
    }

    private static func trimmingTrailingWhitespace(_ text: [Character]) -> [Character] {
        var end = text.count
        while end > 0 && text[end - 1].isWhitespace { end -= 1 }
        return Array(text[..<end])
    }
}
