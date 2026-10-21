import Foundation

/// How a track's title reads once TIDAL's edition is added.
///
/// TIDAL is believed to keep a track's edition ("Radio Edit", "Extended Mix")
/// in a separate `version` field that the Electron app never read (D4 3.11 and
/// 4.15, needs a live check). Matching uses "Title (Edition)" so two editions
/// no longer compare as the same title. File names are not built here: they
/// stay TIDAL's title only (rule 3; D4 2.6 and 2.7 are pending the owner).
public enum EditionTitle {
    /// "Blue Lantern" + "Extended Mix" → "Blue Lantern (Extended Mix)". The
    /// edition is not added twice when the title already contains it, compared
    /// as whole words: "Blue Lantern (Extended Mix)" + "Extended Mix" stays as is.
    public static func make(title: String, edition: String?) -> String {
        guard let edition, adds(edition, to: title) else { return title }
        return "\(title) (\(edition.trimmingCharacters(in: .whitespacesAndNewlines)))"
    }

    /// True when the edition has words the title doesn't already contain.
    static func adds(_ edition: String, to title: String) -> Bool {
        let editionKey = Normalizer.fullKey(edition)
        guard !editionKey.isEmpty else { return false }
        return !" \(Normalizer.fullKey(title)) ".contains(" \(editionKey) ")
    }
}

/// Small rules both matchers share.
enum MatchRules {

    /// The comparable form of an ISRC, the industry code for one specific
    /// recording: upper-case, without hyphens or spaces, and only when it has
    /// the 12-character shape (2 letters, 3 letters or digits, 7 digits), so
    /// junk such as "N/A" or "0" on both sides never counts as the same
    /// recording (D4 3.5).
    static func recordingCodeKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        let characters = Array(compact)
        guard characters.count == 12,
              characters[0..<2].allSatisfy({ $0.isASCII && $0.isLetter }),
              characters[2..<5].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              characters[5..<12].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return compact
    }

    /// The same code proves the same recording whatever the title says; a
    /// different or missing code proves nothing, because one recording can
    /// carry different codes on different releases (D4 3.5 option A).
    static func sameRecording(_ a: String?, _ b: String?) -> Bool {
        guard let a = recordingCodeKey(a), let b = recordingCodeKey(b) else { return false }
        return a == b
    }

    /// A length of 0 or less, or none at all, is unknown and never counts for
    /// or against a match (D4 3.4).
    static func knownLength(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// The gap between two lengths, in seconds, when both are known.
    static func lengthGap(_ a: Double?, _ b: Double?) -> Double? {
        guard let a = knownLength(a), let b = knownLength(b) else { return nil }
        return abs(a - b)
    }

    /// "Lengths agree within about 3 seconds" (D4 3.2 and 3.11). The same
    /// boundary as the 50-point length band in the TIDAL score, so one rule
    /// decides both.
    static let closeLengthSeconds: Double = 3

    static func lengthsClose(_ a: Double?, _ b: Double?) -> Bool {
        guard let gap = lengthGap(a, b) else { return false }
        return gap < closeLengthSeconds
    }
}
