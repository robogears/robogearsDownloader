/// Picks the TIDAL track a Spotify track, an imported line or any other source
/// means, from TIDAL's search results.
///
/// The Electron app had this rule in four copies that disagreed (only Spotify
/// links used length; reference: tidal-and-spotify-networking.md §G). Here
/// there is one matcher for every source (D4 3.2 option A; cards G3-2 and G4-18
/// with the skeptics' corrections). The scores are today's:
///
/// - title: 100 when the titles are the same, 50 when one starts with the other,
///   25 when one contains the other;
/// - artist: the share of the wanted artists TIDAL also lists, 0–100;
/// - length: 50 when the lengths are less than 3 s apart, 25 when less than 8 s.
///
/// What changed is how artists are compared (whole names, see `ArtistCredit`),
/// that length counts whenever the source has one, and what an exact title
/// needs to be accepted:
///
/// - When the source names an artist, an exact title is accepted only when an
///   artist agrees or the lengths are less than 3 s apart. Otherwise the best
///   exact-title result is still returned, flagged `.unconfirmed`, so the queue
///   can add it left out with "Different artist on TIDAL" instead of silently
///   downloading another band's "Intro".
/// - When the source names no artist (a CSV without an artist column), an exact
///   title is accepted as today.
/// - A partial title still needs an artist score of at least 50, the fix for the
///   "Free Your Mind" false matches recorded in CLAUDE.md.
/// - A result with the same ISRC as the source is the same recording and is
///   preferred over everything else (G3-2 skeptic). When several releases
///   share it, the one on the source's album wins (D4 4.5, G4-5 skeptic).
public enum TidalMatcher {

    /// What the source asks for.
    public struct Wanted: Sendable, Hashable {
        public var title: String
        public var artists: ArtistCredit
        /// Seconds; nil or 0 when the source has no length.
        public var durationSeconds: Double?
        public var isrc: String?
        /// The album the source names (a Spotify link's album, a CSV's album
        /// column), used to choose among releases of the same recording.
        public var album: String?

        public init(title: String, artists: ArtistCredit = .unknown, durationSeconds: Double? = nil,
                    isrc: String? = nil, album: String? = nil) {
            self.title = title
            self.artists = artists
            self.durationSeconds = durationSeconds
            self.isrc = isrc
            self.album = album
        }
    }

    /// One TIDAL search result (or ISRC lookup result), in the order TIDAL
    /// returned it.
    public struct Candidate: Sendable, Hashable {
        public var title: String
        /// TIDAL's edition field ("Radio Edit"), when it has one.
        public var version: String?
        /// TIDAL's artist list, never split.
        public var artistNames: [String]
        public var durationSeconds: Double?
        public var isrc: String?
        /// The title of the TIDAL album this result comes from.
        public var album: String?

        public init(title: String, version: String? = nil, artistNames: [String], durationSeconds: Double? = nil,
                    isrc: String? = nil, album: String? = nil) {
            self.title = title
            self.version = version
            self.artistNames = artistNames
            self.durationSeconds = durationSeconds
            self.isrc = isrc
            self.album = album
        }
    }

    /// Why a pick was accepted, from strongest to weakest.
    public enum Confirmation: String, Sendable, Hashable, Codable {
        /// The same ISRC as the source: certainly the same recording.
        case sameRecordingCode
        /// A TIDAL artist is the same name as a wanted artist.
        case artistAgrees
        /// Exact title, a different artist, lengths less than 3 s apart; for
        /// example one act written in Japanese script on Spotify and in Latin
        /// letters on TIDAL.
        case lengthAgrees
        /// Exact title, and the source names no artist to check.
        case titleOnly
        /// Exact title by a different artist, with nothing to confirm it. The
        /// queue adds it left out (greyed, with + Add) and the note "Different
        /// artist on TIDAL" (D4 3.2 option A).
        case unconfirmed
    }

    public struct Score: Sendable, Hashable {
        public let title: Int
        public let artist: Int
        public let length: Int
        public var total: Int { title + artist + length }
    }

    public struct Match: Sendable, Hashable {
        /// Position of the pick in the candidate list passed in.
        public let index: Int
        public let candidate: Candidate
        public let score: Score
        public let confirmation: Confirmation
        /// True when the source names an artist and none of TIDAL's artists for
        /// the pick is the same name, so the queue can show the source's names
        /// beside TIDAL's (D4 4.14).
        public let artistDiffers: Bool
        /// True when the source and TIDAL name the same album. It decides
        /// between releases of one recording (album, single, compilation).
        public let albumAgrees: Bool

        /// The row starts left out of Download all until the person clicks + Add.
        public var startsLeftOut: Bool { confirmation == .unconfirmed }
    }

    /// Title points. 90 is new: the title equals TIDAL's bare title but TIDAL
    /// lists an edition the source didn't name. It still counts as an exact
    /// title (as it did when the edition field was ignored), but ranks below a
    /// result whose edition matches, so "Blue Lantern" prefers the plain version
    /// over the Extended Mix and "Blue Lantern - Extended Mix" prefers the
    /// Extended Mix (D4 3.11).
    static let exactTitlePoints = 100
    static let exactBareTitlePoints = 90
    static let prefixTitlePoints = 50
    static let containedTitlePoints = 25
    static let partialTitleNeedsArtistScore = 50

    // MARK: - Picking

    /// The best candidate for one wanted track, or nil when nothing fits.
    /// Ties keep TIDAL's order: highest total first, then the earlier result.
    public static func bestMatch(for wanted: Wanted, among candidates: [Candidate]) -> Match? {
        candidates.enumerated()
            .compactMap { evaluate(wanted, $0.element, index: $0.offset) }
            .min(by: ranksBefore)
    }

    /// The best candidate over several readings of the same source line, for
    /// example "A - B" read as Title - Artist and as Artist - Title, scored
    /// against one set of search results (D4 4.6). A stronger confirmation wins,
    /// then the higher total; ties go to the earlier reading.
    public static func bestMatch(forReadings readings: [Wanted], among candidates: [Candidate]) -> (reading: Int, match: Match)? {
        var best: (reading: Int, match: Match)?
        for (number, wanted) in readings.enumerated() {
            guard let match = bestMatch(for: wanted, among: candidates) else { continue }
            if let current = best {
                // Only a stronger confirmation or a higher total displaces an
                // earlier reading; the candidate's position doesn't.
                let tierNow = tier(match.confirmation), tierBest = tier(current.match.confirmation)
                let better = tierNow < tierBest
                    || (tierNow == tierBest && match.score.total > current.match.score.total)
                if !better { continue }
            }
            best = (number, match)
        }
        return best
    }

    /// Strict ordering: confirmation tier, then total (higher first), then the
    /// earlier position. Written out because Swift's sort isn't documented as
    /// stable, and ties must keep TIDAL's relevance order.
    ///
    /// Among releases of the same recording (one ISRC on an album, a single
    /// and a compilation), the one on the source's album comes first, then
    /// the total, which carries the length (D4 4.5 option A; G4-5 skeptic:
    /// "pick by duration and album name rather than the first item").
    static func ranksBefore(_ a: Match, _ b: Match) -> Bool {
        let tierA = tier(a.confirmation), tierB = tier(b.confirmation)
        if tierA != tierB { return tierA < tierB }
        if a.confirmation == .sameRecordingCode, a.albumAgrees != b.albumAgrees { return a.albumAgrees }
        if a.score.total != b.score.total { return a.score.total > b.score.total }
        return a.index < b.index
    }

    private static func tier(_ confirmation: Confirmation) -> Int {
        switch confirmation {
        case .sameRecordingCode: return 0
        case .artistAgrees, .lengthAgrees, .titleOnly: return 1
        case .unconfirmed: return 2
        }
    }

    // MARK: - Scoring one candidate

    /// Scores one candidate and decides whether it may be picked at all.
    /// Returns nil for a candidate that is never acceptable.
    static func evaluate(_ wanted: Wanted, _ candidate: Candidate, index: Int) -> Match? {
        let titlePoints = titleScore(wanted: wanted.title, candidate: candidate)
        let artist = artistScore(wanted: wanted.artists, tidalNames: candidate.artistNames)
        let lengthPoints = lengthScore(wanted.durationSeconds, candidate.durationSeconds)
        let score = Score(title: titlePoints, artist: artist.score, length: lengthPoints)
        let exactTitle = titlePoints >= exactBareTitlePoints
        let artistKnown = wanted.artists.isKnown

        let confirmation: Confirmation
        if MatchRules.sameRecording(wanted.isrc, candidate.isrc) {
            confirmation = .sameRecordingCode
        } else if !artistKnown {
            guard exactTitle else { return nil }
            confirmation = .titleOnly
        } else if exactTitle && artist.agrees {
            confirmation = .artistAgrees
        } else if exactTitle && MatchRules.lengthsClose(wanted.durationSeconds, candidate.durationSeconds) {
            confirmation = .lengthAgrees
        } else if titlePoints >= containedTitlePoints && artist.score >= partialTitleNeedsArtistScore {
            confirmation = .artistAgrees
        } else if exactTitle {
            confirmation = .unconfirmed
        } else {
            return nil
        }
        let albumAgrees = Normalizer.keysAgree(Normalizer.fullKey(wanted.album ?? ""),
                                               Normalizer.fullKey(candidate.album ?? ""))
        return Match(index: index, candidate: candidate, score: score, confirmation: confirmation,
                     artistDiffers: artistKnown && !artist.agrees, albumAgrees: albumAgrees)
    }

    /// Compares the wanted title with TIDAL's title as it reads with its
    /// edition. Two empty keys never agree, so a title made only of symbols or
    /// one that can't be read no longer scores 100 against every other such
    /// title, nor 50 against everything ("starts with an empty string").
    static func titleScore(wanted: String, candidate: Candidate) -> Int {
        let wantedKey = Normalizer.fullKey(wanted)
        let bareKey = Normalizer.fullKey(candidate.title)
        let shownKey = Normalizer.fullKey(EditionTitle.make(title: candidate.title, edition: candidate.version))
        if Normalizer.keysAgree(wantedKey, shownKey) { return exactTitlePoints }
        if Normalizer.keysAgree(wantedKey, bareKey) { return exactBareTitlePoints }
        return max(partialTitleScore(wantedKey, shownKey), partialTitleScore(wantedKey, bareKey))
    }

    private static func partialTitleScore(_ a: String, _ b: String) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a.hasPrefix(b) || b.hasPrefix(a) { return prefixTitlePoints }
        if a.contains(b) || b.contains(a) { return containedTitlePoints }
        return 0
    }

    /// The share of wanted artists that TIDAL lists, as whole names, rounded
    /// like today's `Math.round`. A free-text line that equals one of TIDAL's
    /// names, or all of them together, counts as complete agreement, so a band
    /// whose name contains a separator ("Salt, Wind & Lantern") still agrees
    /// with itself. When such a band is credited beside someone else
    /// ("Tyler, The Creator, Kali Uchis"), the neighbouring pieces that make up
    /// its TIDAL name count as that one artist (`ArtistCredit.artistKeys`).
    static func artistScore(wanted: ArtistCredit, tidalNames: [String]) -> (score: Int, agrees: Bool) {
        guard wanted.isKnown else { return (0, false) }
        let tidalKeys = Set(ArtistCredit.names(tidalNames).pieceKeys)
        if let whole = wanted.wholeLineKey,
           tidalKeys.contains(whole)
            || Normalizer.keysAgree(whole, Normalizer.fullKey(tidalNames.joined(separator: " "))) {
            return (100, true)
        }
        let artists = wanted.artistKeys(readAgainst: tidalNames)
        let agreeing = artists.filter(tidalKeys.contains).count
        let share = (Double(agreeing) * 100 / Double(artists.count)).rounded()
        return (Int(share), agreeing > 0)
    }

    /// Today's length bands, now used for every source that has a length.
    static func lengthScore(_ wanted: Double?, _ candidate: Double?) -> Int {
        guard let gap = MatchRules.lengthGap(wanted, candidate) else { return 0 }
        if gap < MatchRules.closeLengthSeconds { return 50 }
        if gap < 8 { return 25 }
        return 0
    }
}
