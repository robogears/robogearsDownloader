// Names of the files the app saves into the download folder.
//
// Rule 3 (owner's request): the file is "<Title>.flac", or "<Title>.m4a" for
// the AAC fallback, from TIDAL's title alone. The owner chose D4 2.6 and 2.7
// option A (21 Oct 2026): the name stays title-only, and the version goes in
// the title tag, not the name, unless a different song already holds the
// plain name. Only then does the track take one of the clash names below:
// the version, then the artist, then the album in brackets, and a number
// after the last of those when every one is taken. Whether a clash applies
// is decided by the download folder (Download/DownloadFolder.swift), which
// reads the existing file's tags.
//
// Sanitising keeps the Electron mapping exactly (`tidal_lib.js:616-618`;
// text-unicode-and-filenames.md §1) so files it saved are still found, then
// fixes its edge cases (card G2-X6): no leading dots (hidden files), no
// control characters or zero-width spaces, composed Unicode (NFC), and a byte
// cap that leaves room for the longest suffix the app adds.

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

    /// What the name is made from. Rule 3: TIDAL's bare title, nothing else
    /// (the version stays out of the plain name, 2.7). Clash names add to it.
    static func nameSource(title: String?) -> String {
        title ?? ""
    }

    // MARK: - Names a disk may treat as one

    /// The form two file names share when a disk may store them as one file:
    /// upper and lower case folded, and composed and decomposed accents made
    /// alike. APFS is usually case-insensitive and keeps either Unicode form,
    /// but external drives may differ, so the app compares by this key
    /// instead of asking the file system (2.2, 2.6: an existing "Intro.flac"
    /// blocks "INTRO.flac"). Accents themselves still count: "Cafe" and
    /// "Café" are different names. Folding a little more than some disk
    /// would only ever pick another free name, never replace a file.
    public static func comparisonKey(_ fileName: String) -> String {
        fileName.decomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    // MARK: - Clash names (D4 2.6, 2.7)

    /// Most bytes a clash name's bracketed part may take, so a long album
    /// name can't crowd the title out of the name.
    static let maxQualifierBytes = 120

    /// Room kept for " 999" after a numbered clash name.
    static let numberRoomBytes = 4

    /// The highest number a clash name gets before the app gives up.
    public static let maxClashNumber = 999

    /// The other names a track may take when a different song already holds
    /// its plain name (2.6), in the owner's fixed order: "<Title> (<Version>)",
    /// "<Title> (<Artist>)", "<Title> (<Album>)". Each part is sanitised like
    /// the plain name. A part that is missing or empty once sanitised, a
    /// version the title already contains, and a name that comes out the
    /// same as the plain name or an earlier one (two long titles cut to one
    /// name, 2.14) are skipped. The title part is shortened, never the
    /// bracketed part, so every name stays within `maxStemBytes`.
    public static func clashStems(title: String?, version: String?, artist: String?, album: String?) -> [String] {
        clashCandidates(title: title, version: version, artist: artist, album: album).map(\.stem)
    }

    /// The numbered name after every clash name is taken: the last clash
    /// name with " 2", " 3"… added (the plain name when there is none).
    public static func numberedClashStem(title: String?, version: String?, artist: String?, album: String?,
                                         number: Int) -> String {
        "\(numberedClashBase(title: title, version: version, artist: artist, album: album)) \(number)"
    }

    /// What every numbered clash name starts with. Built with room for
    /// " 999" so the start is the same for every number, which lets the
    /// folder find numbered files by their start.
    static func numberedClashBase(title: String?, version: String?, artist: String?, album: String?) -> String {
        let last = clashCandidates(title: title, version: version, artist: artist, album: album).last?.qualifier
        return clashStem(title: title, qualifier: last, reservedBytes: numberRoomBytes)
    }

    private static func clashCandidates(title: String?, version: String?, artist: String?,
                                        album: String?) -> [(qualifier: String, stem: String)] {
        var qualifiers: [String?] = []
        // 2.7: the version only names the file when the title doesn't already say it.
        if let version, EditionTitle.adds(version, to: title ?? "") { qualifiers.append(version) }
        qualifiers.append(artist)
        qualifiers.append(album)
        var seen: Set<String> = [comparisonKey(stem(title: title))]
        var out: [(qualifier: String, stem: String)] = []
        for case let qualifier? in qualifiers where !cleaned(qualifier).isEmpty {
            let candidate = clashStem(title: title, qualifier: qualifier, reservedBytes: 0)
            if seen.insert(comparisonKey(candidate)).inserted { out.append((qualifier, candidate)) }
        }
        return out
    }

    /// "<Title> (<Qualifier>)" within `maxStemBytes - reservedBytes`, or just
    /// the title when there is no qualifier.
    private static func clashStem(title: String?, qualifier: String?, reservedBytes: Int) -> String {
        var head = cleaned(nameSource(title: title))
        if head.isEmpty { head = "unknown" }
        let suffix = qualifier.map { " (\(capped(cleaned($0), maxBytes: maxQualifierBytes)))" } ?? ""
        let room = maxStemBytes - reservedBytes - storedBytes(suffix)
        return capped(head, maxBytes: room) + suffix
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

    /// Format characters that only make a name look like another one:
    /// zero-width space, word joiner and the Mongolian vowel separator. Card
    /// G2-X6 lists zero-width spaces among the defects, since
    /// "Blue\u{200B}Lantern.flac" looks identical to "BlueLantern.flac" in
    /// Finder. Joiners (U+200C, U+200D) and variation selectors stay: emoji
    /// and several scripts need them. Old files are still found through
    /// `legacyFileName`.
    private static let invisibleSpacers: Set<UInt32> = [0x200B, 0x2060, 0x180E]

    static func sanitizedStem(_ source: String) -> String {
        let name = capped(cleaned(source), maxBytes: maxStemBytes)
        return name.isEmpty ? "unknown" : name
    }

    /// The sanitising steps without the length cap or the "unknown" fallback,
    /// so clash names can share the byte budget between their parts.
    static func cleaned(_ source: String) -> String {
        let composed = source.precomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in composed.unicodeScalars {
            if javaScriptWhitespace.contains(scalar.value) {
                pendingSpace = true
                continue
            }
            if scalar.properties.generalCategory == .control || invisibleSpacers.contains(scalar.value) {
                continue
            }
            if pendingSpace, !scalars.isEmpty { scalars.append(" ") }
            pendingSpace = false
            scalars.append(unsafeCharacters.contains(scalar) ? "_" : scalar)
        }
        var name = String(scalars)
        // "...Ready" made a hidden "...Ready.flac" (G2-X6).
        while let first = name.first, first == "." || first == " " { name.removeFirst() }
        return name
    }

    /// The larger of a name's composed and decomposed UTF-8 lengths: the
    /// most bytes any volume may store it in.
    static func storedBytes(_ name: String) -> Int {
        max(name.utf8.count, name.decomposedStringWithCanonicalMapping.utf8.count)
    }

    /// Shortens at a whole character. Counts the decomposed form too, in case
    /// a volume stores names decomposed and they grow.
    private static func capped(_ name: String, maxBytes: Int) -> String {
        guard storedBytes(name) > maxBytes else {
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
