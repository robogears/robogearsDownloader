import Foundation

/// Decides whether a track is already in the person's music library, which
/// sets the queue's greyed "already in library" (exact) and yellow "similar
/// version in library" (similar) marks.
///
/// The order of checks is today's (library-scanner-and-matcher.md §6): exact
/// before tag-title similar before file-name similar before core similar, each
/// pass over every entry before the next. What changed (D4 3.3–3.5, 3.11–3.13):
///
/// - The same ISRC is exact before anything else, whatever the title says (3.5).
/// - "Artist agrees" means a whole name matches, using every artist tag in the
///   file; "Ox" no longer agrees with "Boxer Collective", and a reordered
///   multi-artist line now does (3.3).
/// - An exact match becomes similar when both lengths are known and more than
///   10 seconds apart, so an extended mix isn't hidden behind a radio edit (3.4).
/// - A named edition must be confirmed: a library file with the bare title is
///   exact only when the lengths agree within 3 seconds, which keeps every
///   Extended Mix the app downloaded before (bare title tags) exact (3.11).
/// - File names are split at the first spaced dash and lose a leading track
///   number, and today's whole-name keys are kept too (3.12). A file-name match
///   is never exact (the v0.1.24 rule).
/// - A key shorter than 3 characters can only give exact, with the artist
///   agreeing; it never gives a yellow badge on its own (3.13).
///
/// Entries are kept in path order, so the reported file is the same on every
/// scan (G3-11; today it depended on which file finished parsing first).
public enum LibraryMatcher {

    /// One audio file in the library, as the scanner read it.
    public struct Entry: Sendable, Hashable {
        /// Absolute path; the file name (with its extension) is its last part.
        public var path: String
        public var tagTitle: String?
        /// Every artist value in the tags, each as written (they may hold
        /// several names, such as "Second Guest; Placeholder Artist").
        public var tagArtists: [String]
        public var tagDurationSeconds: Double?
        public var tagISRC: String?

        public init(path: String, tagTitle: String? = nil, tagArtists: [String] = [],
                    tagDurationSeconds: Double? = nil, tagISRC: String? = nil) {
            self.path = path
            self.tagTitle = tagTitle
            self.tagArtists = tagArtists
            self.tagDurationSeconds = tagDurationSeconds
            self.tagISRC = tagISRC
        }

        /// The file name with its extension, as the queue's library note shows it.
        public var fileName: String {
            path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        }
    }

    /// The incoming track, described the way the file and its tags will be:
    /// TIDAL's title, edition, artists, length and ISRC when matched (D4 4.14).
    public struct Query: Sendable, Hashable {
        public var title: String
        /// TIDAL's edition ("Extended Mix"), when it has one.
        public var edition: String?
        public var artists: ArtistCredit
        public var durationSeconds: Double?
        public var isrc: String?

        public init(title: String, edition: String? = nil, artists: ArtistCredit = .unknown,
                    durationSeconds: Double? = nil, isrc: String? = nil) {
            self.title = title
            self.edition = edition
            self.artists = artists
            self.durationSeconds = durationSeconds
            self.isrc = isrc
        }
    }

    public struct Match: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            /// Greyed, struck through and left out until + Add.
            case exact
            /// Yellow badge, still included.
            case similar
        }

        /// Why this verdict, so the queue's note can say it in words.
        public enum Evidence: String, Sendable, Hashable, Codable {
            /// exact: the file carries the same ISRC.
            case sameRecordingCode
            /// exact: tag title and an artist agree, lengths don't contradict.
            case titleAndArtist
            /// similar: title and artist agree but the lengths are more than
            /// 10 s apart; the note shows both lengths.
            case lengthsDiffer
            /// similar: the file has the bare title, the incoming track is a
            /// named edition, and the lengths don't confirm it is that edition.
            case editionUnconfirmed
            /// similar: the tag title agrees, the artist is missing or different.
            case titleOnly
            /// similar: the file name agrees (never proof on its own).
            case fileName
            /// similar: the same song once version text is removed.
            case otherVersion
        }

        public let kind: Kind
        public let path: String
        /// The tag title for tag-based matches, else the file name with its
        /// extension (today's `libraryTitle`).
        public let libraryTitle: String
        public let libraryDurationSeconds: Double?
        public let evidence: Evidence
    }

    /// More than this many seconds apart, an exact match becomes similar (D4 3.4).
    static let differentRecordingSeconds: Double = 10

    /// Keys shorter than this can only give exact, with the artist (D4 3.13).
    static let shortKeyLength = 3

    // MARK: - Index

    /// The library prepared for lookups: every key computed once, entries in
    /// path order, and a table from each key to the entries that have it.
    public struct Index: Sendable {
        let entries: [Prepared]
        private let byRecordingCode: [String: Int]
        private let byTagFull: [String: [Int]]
        private let byNameFull: [String: [Int]]
        private let byTagCore: [String: [Int]]
        private let byNameCore: [String: [Int]]

        public init(entries: [Entry]) {
            let ordered = entries.enumerated()
                .sorted { ($0.element.path, $0.offset) < ($1.element.path, $1.offset) }
                .map { Prepared($0.element) }
            self.entries = ordered
            var byRecordingCode: [String: Int] = [:]
            var byTagFull: [String: [Int]] = [:]
            var byNameFull: [String: [Int]] = [:]
            var byTagCore: [String: [Int]] = [:]
            var byNameCore: [String: [Int]] = [:]
            for (index, entry) in ordered.enumerated() {
                if let code = entry.recordingCode, byRecordingCode[code] == nil { byRecordingCode[code] = index }
                if !entry.tagTitleFull.isEmpty { byTagFull[entry.tagTitleFull, default: []].append(index) }
                if !entry.tagTitleCore.isEmpty { byTagCore[entry.tagTitleCore, default: []].append(index) }
                for key in entry.nameFullKeys { byNameFull[key, default: []].append(index) }
                for key in entry.nameCoreKeys { byNameCore[key, default: []].append(index) }
            }
            self.byRecordingCode = byRecordingCode
            self.byTagFull = byTagFull
            self.byNameFull = byNameFull
            self.byTagCore = byTagCore
            self.byNameCore = byNameCore
        }

        /// Number of files in the index.
        public var count: Int { entries.count }

        /// The library verdict for one incoming track, or nil when nothing in
        /// the library resembles it.
        public func match(_ query: Query) -> Match? {
            // 3.5: the same recording code is exact, before any title rule.
            if let code = MatchRules.recordingCodeKey(query.isrc), let index = byRecordingCode[code] {
                return verdict(.exact, .sameRecordingCode, entries[index], tagBased: true)
            }

            let bareFull = Normalizer.fullKey(query.title)
            guard !bareFull.isEmpty, !entries.isEmpty else { return nil }
            let shownFull = Normalizer.fullKey(EditionTitle.make(title: query.title, edition: query.edition))
            let namesEdition = shownFull != bareFull
            let titleKeys = namesEdition ? [shownFull, bareFull] : [bareFull]

            // Pass 1: tag title and artist agree. Exact unless the lengths say
            // otherwise; a contradicted one is held as the best similar so far.
            var heldSimilar: (entry: Prepared, evidence: Match.Evidence)?
            let queryArtistKeys = query.artists.comparisonKeys
            if !queryArtistKeys.isEmpty {
                for key in titleKeys {
                    for index in byTagFull[key] ?? [] {
                        let entry = entries[index]
                        guard !entry.artistKeys.isDisjoint(with: queryArtistKeys) else { continue }
                        let lengthGap = MatchRules.lengthGap(query.durationSeconds, entry.duration)
                        let evidence: Match.Evidence?
                        if namesEdition && key == bareFull {
                            // The file has the bare title; only a matching length
                            // shows it is this edition (D4 3.11).
                            evidence = MatchRules.lengthsClose(query.durationSeconds, entry.duration)
                                ? nil : .editionUnconfirmed
                        } else {
                            evidence = (lengthGap ?? 0) > differentRecordingSeconds ? .lengthsDiffer : nil
                        }
                        guard let evidence else {
                            return verdict(.exact, .titleAndArtist, entry, tagBased: true)
                        }
                        // 3.13: a short title gives exact or nothing.
                        if heldSimilar == nil && key.count >= shortKeyLength { heldSimilar = (entry, evidence) }
                    }
                }
            }
            if let held = heldSimilar {
                return verdict(.similar, held.evidence, held.entry, tagBased: true)
            }

            let similarKeys = titleKeys.filter { $0.count >= shortKeyLength }

            // Pass 2: tag title agrees, artist missing or different.
            for key in similarKeys {
                if let index = byTagFull[key]?.first {
                    return verdict(.similar, .titleOnly, entries[index], tagBased: true)
                }
            }

            // Pass 3: a file-name key agrees.
            for key in similarKeys {
                if let index = byNameFull[key]?.first {
                    return verdict(.similar, .fileName, entries[index], tagBased: false)
                }
            }

            // Pass 4: the same song once version text is removed, from the tag
            // title or the file name, whichever entry comes first.
            let core = Normalizer.coreKey(query.title)
            guard core.count >= shortKeyLength else { return nil }
            let tagIndex = byTagCore[core]?.first
            let nameIndex = byNameCore[core]?.first
            guard let index = [tagIndex, nameIndex].compactMap({ $0 }).min() else { return nil }
            let entry = entries[index]
            return verdict(.similar, .otherVersion, entry, tagBased: entry.tagTitleCore == core)
        }

        private func verdict(_ kind: Match.Kind, _ evidence: Match.Evidence, _ entry: Prepared, tagBased: Bool) -> Match {
            let title = tagBased ? (entry.tagTitle ?? entry.fileName) : entry.fileName
            return Match(kind: kind, path: entry.path, libraryTitle: title,
                         libraryDurationSeconds: entry.duration, evidence: evidence)
        }
    }

    /// An entry with every comparison key worked out once.
    struct Prepared: Sendable {
        let path: String
        let fileName: String
        let tagTitle: String?
        let tagTitleFull: String
        let tagTitleCore: String
        let nameFullKeys: [String]
        let nameCoreKeys: [String]
        /// Every tag artist value, whole and split into names (D4 3.3).
        let artistKeys: Set<String>
        let duration: Double?
        let recordingCode: String?

        init(_ entry: Entry) {
            path = entry.path
            fileName = entry.fileName
            let title = entry.tagTitle.flatMap { Normalizer.fullKey($0).isEmpty ? nil : $0 }
            tagTitle = title
            tagTitleFull = title.map(Normalizer.fullKey) ?? ""
            tagTitleCore = title.map(Normalizer.coreKey) ?? ""
            let names = LibraryMatcher.fileNameTitles(entry.fileName)
            nameFullKeys = LibraryMatcher.uniqueKeys(names.map(Normalizer.fullKey))
            nameCoreKeys = LibraryMatcher.uniqueKeys(names.map(Normalizer.coreKey))
            artistKeys = entry.tagArtists.reduce(into: Set<String>()) { keys, value in
                keys.formUnion(ArtistCredit.text(value).comparisonKeys)
            }
            duration = MatchRules.knownLength(entry.tagDurationSeconds)
            recordingCode = MatchRules.recordingCodeKey(entry.tagISRC)
        }
    }

    // MARK: - File names (D4 3.12)

    /// The titles a file name may stand for, most literal first:
    /// - the whole name without its extension (today's key, kept so
    ///   "Blue Lantern - Radio Edit.flac" still finds "Blue Lantern");
    /// - the name without a leading track number ("01. Blue Lantern");
    /// - for each of those, the part after the first spaced dash, so
    ///   "Artist - Blue Lantern - Radio Edit" gives "Blue Lantern - Radio Edit"
    ///   (today the last dash won and gave "Radio Edit"). En and em dashes count.
    static func fileNameTitles(_ fileName: String) -> [String] {
        let base = removingExtension(fileName)
        var names = [base]
        if let unnumbered = removingTrackNumber(base) { names.append(unnumbered) }
        for name in names {
            if let title = afterFirstSpacedDash(name) { names.append(title) }
        }
        return names
    }

    /// Node's `extname` rule: the part after the last dot, unless the dot is
    /// the first character ("._x.flac" → "._x"; ".flac" stays whole).
    static func removingExtension(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        let ext = fileName[fileName.index(after: dot)...]
        guard (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return fileName }
        return String(fileName[..<dot])
    }

    /// Removes a leading track number only when it is clearly one: followed by
    /// "." or a dash ("01. ", "01 - ", "1-01 "), or zero-padded ("01 "), and
    /// only if three or more characters of title remain. "22 Harbor Lights" and
    /// "7 Lanterns" are left alone (D4 3.12 with the G3-14 skeptic's limits).
    static func removingTrackNumber(_ name: String) -> String? {
        let characters = Array(name)
        var index = 0
        while index < characters.count, index < 3, characters[index].isASCII, characters[index].isNumber { index += 1 }
        let digits = index
        guard digits > 0, index < characters.count else { return nil }

        func skipWhitespace() { while index < characters.count && characters[index].isWhitespace { index += 1 } }

        if characters[index] == "." {
            index += 1
        } else if characters[index] == "-" {
            index += 1
            // Disc-track numbers such as "1-01".
            var discDigits = 0
            while index < characters.count, discDigits < 3, characters[index].isASCII, characters[index].isNumber {
                index += 1; discDigits += 1
            }
            if discDigits > 0, index < characters.count, characters[index] == "." { index += 1 }
        } else if characters[index].isWhitespace {
            skipWhitespace()
            if index < characters.count, Normalizer.isDash(characters[index]),
               index + 1 < characters.count, characters[index + 1].isWhitespace {
                index += 1
            } else if !(digits >= 2 && characters[0] == "0") {
                return nil
            }
        } else {
            return nil
        }
        skipWhitespace()
        let rest = String(characters[index...])
        return Normalizer.fullKey(rest).count >= shortKeyLength ? rest : nil
    }

    /// The text after the first spaced dash (" - ", " – ", " — "), if any.
    static func afterFirstSpacedDash(_ name: String) -> String? {
        let characters = Array(name)
        guard let dash = Normalizer.spacedDashPositions(characters).first else { return nil }
        let rest = String(characters[(dash + 1)...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    static func uniqueKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
