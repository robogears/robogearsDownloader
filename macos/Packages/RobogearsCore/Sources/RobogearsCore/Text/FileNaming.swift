// Names of the files the app saves into the download folder.
//
// Rule 3 (owner's request): the file is "<Title>.flac", or "<Title>.m4a" for
// the AAC fallback, from TIDAL's title alone. Cards G2-5 (same-title songs)
// and G2-6 (versions in the name) are waiting for the owner, so the policy
// lives in `nameSource(title:)` alone and can change there later.
//
// Sanitising keeps the Electron mapping exactly (`tidal_lib.js:616-618`;
// text-unicode-and-filenames.md §1) so files it saved are still found, then
// fixes its edge cases (card G2-X6): no leading dots (hidden files), no
// control characters, composed Unicode (NFC), and a byte cap that leaves room
// for the longest suffix the app adds.

import Foundation

public enum FileNaming {
    /// The audio formats the app saves.
    public enum AudioExtension: String, Sendable, CaseIterable {
        case flac
        case m4a
    }

    /// macOS limits one file name to 255 bytes.
    public static let maxNameBytes = 255

    /// Room kept free after the title: the longest extension (".flac") plus a
    /// temporary or partial-download suffix (".part", ".tmp"), with a spare
    /// leading dot for a hidden partial file (card G2-X6 skeptic; card G2-2's
    /// fallback name ".Blue Lantern.flac.part" is 11 bytes longer than the
    /// title). Suffixes the download code adds must stay within this.
    public static let reservedSuffixBytes = 16

    /// The longest title part, in UTF-8 bytes.
    public static var maxStemBytes: Int { maxNameBytes - reservedSuffixBytes }

    /// The file name for a track: "<Title>.flac" or "<Title>.m4a".
    public static func fileName(title: String?, extension ext: AudioExtension) -> String {
        "\(stem(title: title)).\(ext.rawValue)"
    }

    /// The name without its extension, sanitised.
    public static func stem(title: String?) -> String {
        sanitizedStem(nameSource(title: title))
    }

    /// Every name under which this track may already be in the download
    /// folder: today's names first, then the exact names the Electron app
    /// would have written where they differ (card G2-X6: "...Ready.flac" from
    /// the old app is still found, so it isn't downloaded twice). `.flac`
    /// before `.m4a`, as the Electron skip check did.
    public static func existingFileCandidates(title: String?) -> [String] {
        var names: [String] = []
        for ext in AudioExtension.allCases {
            names.append(fileName(title: title, extension: ext))
        }
        for ext in AudioExtension.allCases {
            let legacy = legacyFileName(title: title, extension: ext)
            // The old app failed to save a title with a NUL or one too long
            // for macOS, so there is nothing to find. Compared by bytes:
            // Swift's == treats composed and decomposed spellings as equal,
            // but some volumes don't.
            let couldExist = !legacy.unicodeScalars.contains("\u{0}") && legacy.utf8.count <= maxNameBytes
            let alreadyListed = names.contains { Array($0.utf8) == Array(legacy.utf8) }
            if couldExist, !alreadyListed {
                names.append(legacy)
            }
        }
        return names
    }

    // MARK: - Naming policy

    /// What the name is made from. Rule 3: TIDAL's title, nothing else.
    static func nameSource(title: String?) -> String {
        title ?? ""
    }

    // MARK: - Sanitising

    /// The nine characters Windows or macOS can't take in a name.
    private static let unsafeCharacters: Set<Unicode.Scalar> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]

    /// JavaScript's `\s`, written out because Foundation's whitespace sets
    /// differ: they include U+0085 and leave out U+FEFF
    /// (text-unicode-and-filenames.md §1).
    static let javaScriptWhitespace: Set<UInt32> = Set(
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
            + Array(0x2000...0x200A)
    )

    static func sanitizedStem(_ source: String) -> String {
        let composed = source.precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in composed.unicodeScalars {
            if javaScriptWhitespace.contains(scalar.value) {
                pendingSpace = true
                continue
            }
            if scalar.properties.generalCategory == .control {
                continue
            }
            if pendingSpace, !scalars.isEmpty { scalars.append(" ") }
            pendingSpace = false
            scalars.append(unsafeCharacters.contains(scalar) ? "_" : scalar)
        }
        var name = String(scalars)
        // "...Ready" made a hidden "...Ready.flac" (G2-X6).
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        name = capped(name, maxBytes: maxStemBytes)
        return name.isEmpty ? "unknown" : name
    }

    /// Shortens at a whole character. Counts the decomposed form too, in case
    /// a volume stores names decomposed and they grow.
    private static func capped(_ name: String, maxBytes: Int) -> String {
        guard name.utf8.count > maxBytes || name.decomposedStringWithCanonicalMapping.utf8.count > maxBytes else {
            return name
        }
        var result = ""
        var composedBytes = 0
        var decomposedBytes = 0
        for character in name {
            let piece = String(character)
            let nextComposed = composedBytes + piece.utf8.count
            let nextDecomposed = decomposedBytes + piece.decomposedStringWithCanonicalMapping.utf8.count
            if nextComposed > maxBytes || nextDecomposed > maxBytes { break }
            result.append(character)
            composedBytes = nextComposed
            decomposedBytes = nextDecomposed
        }
        while result.last == " " { result.removeLast() }
        return result
    }

    // MARK: - The Electron app's spelling

    /// Exactly what the Electron app's `sanitize` produced, for finding files
    /// it saved: `(str || 'unknown')`, the nine characters to `_`, runs of
    /// JavaScript whitespace to one space, then trimmed. A whitespace-only
    /// title gives "" (its file was the hidden ".flac").
    public static func legacyStem(title: String?) -> String {
        let source = title.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
        var scalars = String.UnicodeScalarView()
        var inWhitespace = false
        for scalar in source.unicodeScalars {
            if javaScriptWhitespace.contains(scalar.value) {
                if !inWhitespace { scalars.append(" ") }
                inWhitespace = true
                continue
            }
            inWhitespace = false
            scalars.append(unsafeCharacters.contains(scalar) ? "_" : scalar)
        }
        var view = scalars
        while let first = view.first, first == " " { view.removeFirst() }
        while let last = view.last, last == " " { view.removeLast() }
        return String(view)
    }

    /// The Electron app's full file name for a title.
    public static func legacyFileName(title: String?, extension ext: AudioExtension) -> String {
        "\(legacyStem(title: title)).\(ext.rawValue)"
    }
}
