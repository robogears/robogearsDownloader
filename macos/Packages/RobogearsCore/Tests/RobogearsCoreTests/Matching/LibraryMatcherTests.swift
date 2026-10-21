import Testing
@testable import RobogearsCore

@Suite("Library matcher")
struct LibraryMatcherTests {

    typealias Entry = LibraryMatcher.Entry
    typealias Query = LibraryMatcher.Query
    typealias Kind = LibraryMatcher.Match.Kind
    typealias Evidence = LibraryMatcher.Match.Evidence

    // MARK: - Library entries from library-scanner-and-matcher.md ("Match outcome examples")

    static let l1 = Entry(path: "/Music/Blue Lantern.flac", tagTitle: "Blue Lantern", tagArtists: ["Placeholder Artist"])
    static let l2 = Entry(path: "/Music/Placeholder Artist - Blue Lantern.mp3")
    static let l3 = Entry(path: "/Music/track03.flac", tagTitle: "Blue Lantern", tagArtists: [""])
    static let l4 = Entry(path: "/Music/track04.flac", tagTitle: "Blue Lantern", tagArtists: ["Ox"])
    static let l5 = Entry(path: "/Music/Blue Lantern (Live).flac", tagTitle: "Blue Lantern (Live)", tagArtists: ["Placeholder Artist"])
    static let l6 = Entry(path: "/Music/track06.flac", tagTitle: "Caf\u{E9} \u{C9}toile", tagArtists: ["Placeholder Duo"])
    static let l7 = Entry(path: "/Music/track07.flac", tagTitle: "Синий фонарь", tagArtists: ["Placeholder Artist"])
    static let l8 = Entry(path: "/Music/Placeholder Artist - Blue Lantern - Radio Edit.flac")
    static let l9 = Entry(path: "/Music/Seven.flac", tagTitle: "Seven", tagArtists: ["Placeholder Artist"])
    static let l10 = Entry(path: "/Music/track10.flac", tagTitle: "Go", tagArtists: ["Placeholder Artist"])
    static let l12 = Entry(path: "/Music/track12.flac", tagTitle: "Blue Lantern", tagArtists: ["Second Guest; Placeholder Artist"])
    static let l13 = Entry(path: "/Music/01. Blue Lantern.flac")

    static let placeholder: ArtistCredit = .names(["Placeholder Artist"])
    static let placeholderAndGuest: ArtistCredit = .names(["Placeholder Artist", "Second Guest"])

    static func match(_ title: String, _ artists: ArtistCredit = .unknown, in entries: [Entry],
                      edition: String? = nil, duration: Double? = nil, isrc: String? = nil) -> LibraryMatcher.Match? {
        LibraryMatcher.Index(entries: entries)
            .match(Query(title: title, edition: edition, artists: artists, durationSeconds: duration, isrc: isrc))
    }

    struct Outcome: CustomTestStringConvertible, Sendable {
        let row: Int
        let entries: [Entry]
        let title: String
        let artists: ArtistCredit
        let kind: Kind?
        let evidence: Evidence?
        let path: String?
        var testDescription: String { "row \(row): \(title)" }

        init(_ row: Int, _ entries: [Entry], _ title: String, _ artists: ArtistCredit,
             _ kind: Kind?, _ evidence: Evidence? = nil, path: String? = nil) {
            self.row = row; self.entries = entries; self.title = title; self.artists = artists
            self.kind = kind; self.evidence = evidence; self.path = path ?? entries.first?.path
        }
    }

    static let unchangedOutcomes: [Outcome] = [
        Outcome(1, [l1], "Blue Lantern", placeholder, .exact, .titleAndArtist),
        Outcome(2, [l1], "Blue Lantern", placeholderAndGuest, .exact, .titleAndArtist),
        Outcome(3, [l1], "Blue Lantern", .names(["Other Band"]), .similar, .titleOnly),
        Outcome(4, [l1], "Blue Lantern", .unknown, .similar, .titleOnly),
        Outcome(5, [l1], "Blue Lantern - Radio Edit", placeholder, .similar, .otherVersion),
        Outcome(7, [l1], "Blue Lanterns", placeholder, nil),
        Outcome(9, [l2], "Blue Lantern", .names(["Anyone"]), .similar, .fileName),
        Outcome(10, [l3], "Blue Lantern", placeholder, .similar, .titleOnly),
        Outcome(12, [l5], "Blue Lantern", placeholder, .similar, .otherVersion),
        Outcome(13, [l5], "Blue Lantern (Live)", placeholder, .exact, .titleAndArtist),
        Outcome(20, [l12], "Blue Lantern", placeholder, .exact, .titleAndArtist),
        Outcome(23, [l1, l2], "Blue Lantern", placeholder, .exact, .titleAndArtist, path: l1.path),
        Outcome(25, [l1], "", placeholder, nil),
    ]

    @Test("today's match outcomes that keep their result", arguments: unchangedOutcomes)
    func unchangedOutcome(_ outcome: Outcome) {
        let result = Self.match(outcome.title, outcome.artists, in: outcome.entries)
        #expect(result?.kind == outcome.kind)
        if outcome.kind != nil {
            #expect(result?.evidence == outcome.evidence)
            #expect(result?.path == outcome.path)
        }
    }

    static let changedOutcomes: [Outcome] = [
        // 6: "- 2011 Remaster" is now a version tail (was no match).
        Outcome(6, [l1], "Blue Lantern - 2011 Remaster", placeholder, .similar, .otherVersion),
        // 8: the Cyrillic part counts, so it is another version, not the same title (was exact).
        Outcome(8, [l1], "Blue Lantern (Синий)", placeholder, .similar, .otherVersion),
        // 11: "Ox" is not the same name as "Boxer Collective" (was a false exact).
        Outcome(11, [l4], "Blue Lantern", .names(["Boxer Collective"]), .similar, .titleOnly),
        // 14: accents fold (was no match).
        Outcome(14, [l6], "Cafe Etoile", .names(["Placeholder Duo"]), .exact, .titleAndArtist),
        // 15: non-Latin titles keep their letters (was no match).
        Outcome(15, [l7], "Синий фонарь", placeholder, .exact, .titleAndArtist),
        Outcome(15, [l7], "Синий фонарь", .names(["Other Band"]), .similar, .titleOnly),
        // 16: "Artist - Title - Version" files are read on the right part (was no match).
        Outcome(16, [l8], "Blue Lantern", .names(["Anyone"]), .similar, .otherVersion),
        // 17: …and no longer stand for a song called "Radio Edit" (was a false similar).
        Outcome(17, [l8], "Radio Edit", .names(["Anyone Else"]), nil),
        // 18: a bare "Ft" is not "featuring" (was a false similar).
        Outcome(18, [l9], "Seven Ft Harbor", .names(["Different Artist"]), nil),
        // 19: short titles are checked, but only as exact with the artist (was no match).
        Outcome(19, [l10], "Go", placeholder, .exact, .titleAndArtist),
        Outcome(19, [l10], "Go", .names(["Other Band"]), nil),
        // 21: a reordered artist list agrees (was similar).
        Outcome(21, [l12], "Blue Lantern", placeholderAndGuest, .exact, .titleAndArtist),
        // 22: a "01. " track number is removed from the file name (was no match).
        Outcome(22, [l13], "Blue Lantern", placeholder, .similar, .fileName),
        // 24: the reported file is the first in path order, whatever order the scan produced.
        Outcome(24, [l3, l1], "Blue Lantern", .names(["Other Band"]), .similar, .titleOnly, path: l1.path),
    ]

    @Test("today's match outcomes with the D4 3.1, 3.3, 3.12 and 3.13 result", arguments: changedOutcomes)
    func changedOutcome(_ outcome: Outcome) {
        let result = Self.match(outcome.title, outcome.artists, in: outcome.entries)
        #expect(result?.kind == outcome.kind)
        if outcome.kind != nil {
            #expect(result?.evidence == outcome.evidence)
            #expect(result?.path == outcome.path)
        }
    }

    @Test("library titles: the tag title for tag matches, the file name with extension otherwise")
    func libraryTitles() {
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [Self.l1])?.libraryTitle == "Blue Lantern")
        #expect(Self.match("Blue Lantern", in: [Self.l2])?.libraryTitle == "Placeholder Artist - Blue Lantern.mp3")
        #expect(Self.match("Blue Lantern - Radio Edit", in: [Self.l1])?.libraryTitle == "Blue Lantern")
        #expect(Self.match("Blue Lantern", in: [Self.l8])?.libraryTitle == "Placeholder Artist - Blue Lantern - Radio Edit.flac")
    }

    @Test("an empty library or a title with nothing to compare gives no match")
    func nothingToCompare() {
        #expect(Self.match("Blue Lantern", Self.placeholder, in: []) == nil)
        #expect(Self.match("   ", Self.placeholder, in: [Self.l1]) == nil)
        #expect(LibraryMatcher.Index(entries: [Self.l1, Self.l2]).count == 2)
    }

    @Test("an untitled library file never matches an untitled track")
    func emptyTitlesNeverAgree() {
        let untitled = Entry(path: "/Music/.flac", tagTitle: "  ", tagArtists: ["Placeholder Artist"])
        #expect(Self.match("", Self.placeholder, in: [untitled]) == nil)
        #expect(Self.match("!!!", Self.placeholder, in: [untitled]) == nil)
    }

    @Test("symbol-only titles match the same symbols only")
    func symbolTitles() {
        let heart = Entry(path: "/Music/heart.flac", tagTitle: "♡", tagArtists: ["Placeholder Artist"])
        #expect(Self.match("♡", Self.placeholder, in: [heart])?.kind == .exact)
        #expect(Self.match("!!!", Self.placeholder, in: [heart]) == nil)
    }

    // MARK: - ISRC (D4 3.5)

    static let downloadedExtendedMix = Entry(path: "/Music/Blue Lantern.flac", tagTitle: "Blue Lantern",
                                             tagArtists: ["Placeholder Artist"], tagDurationSeconds: 461,
                                             tagISRC: "ZZAAA2600007")

    @Test("the same ISRC is exact whatever the title, edition or length says")
    func sameRecordingCodeIsExact() {
        let library = Entry(path: "/Music/track01.flac", tagTitle: "Track 1", tagDurationSeconds: 238, tagISRC: "ZZ-AAA-26-00007")
        let result = Self.match("Blue Lantern", Self.placeholder, in: [library], edition: "Extended Mix",
                                duration: 461, isrc: "zzaaa2600007")
        #expect(result?.kind == .exact)
        #expect(result?.evidence == .sameRecordingCode)
        #expect(result?.libraryTitle == "Track 1")
    }

    @Test("a different ISRC proves nothing: the title rules still decide")
    func differentRecordingCodeFallsBack() {
        let result = Self.match("Blue Lantern", Self.placeholder, in: [Self.downloadedExtendedMix],
                                duration: 461, isrc: "ZZAAA2699999")
        #expect(result?.kind == .exact)
        #expect(result?.evidence == .titleAndArtist)
    }

    @Test("malformed ISRCs on both sides never match")
    func junkRecordingCodes() {
        let library = Entry(path: "/Music/track01.flac", tagTitle: "Track 1", tagISRC: "N/A")
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [library], isrc: "N/A") == nil)
    }

    // MARK: - Lengths (D4 3.4)

    static let radioEdit = Entry(path: "/Music/Blue Lantern.flac", tagTitle: "Blue Lantern",
                                 tagArtists: ["Placeholder Artist"], tagDurationSeconds: 238)

    @Test("an exact match becomes similar when the lengths are more than 10 seconds apart")
    func farApartLengthsDemote() {
        let result = Self.match("Blue Lantern", Self.placeholder, in: [Self.radioEdit], duration: 461)
        #expect(result?.kind == .similar)
        #expect(result?.evidence == .lengthsDiffer)
        #expect(result?.libraryDurationSeconds == 238)
    }

    @Test("lengths up to 10 seconds apart, or unknown, keep the match exact", arguments: [
        Double?.some(245), .some(248), .some(228), .some(0), .none,
    ])
    func closeOrUnknownLengthsStayExact(_ duration: Double?) {
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [Self.radioEdit], duration: duration)?.kind == .exact)
    }

    @Test("a library file with no readable length keeps the match exact")
    func unknownLibraryLength() {
        let noLength = Entry(path: "/Music/Blue Lantern.flac", tagTitle: "Blue Lantern",
                             tagArtists: ["Placeholder Artist"], tagDurationSeconds: 0)
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [noLength], duration: 461)?.kind == .exact)
    }

    @Test("an exact match anywhere beats a length-demoted one earlier in path order")
    func exactBeatsDemoted() {
        let extended = Entry(path: "/Music/zz Blue Lantern.flac", tagTitle: "Blue Lantern",
                             tagArtists: ["Placeholder Artist"], tagDurationSeconds: 460)
        let result = Self.match("Blue Lantern", Self.placeholder, in: [Self.radioEdit, extended], duration: 461)
        #expect(result?.kind == .exact)
        #expect(result?.path == extended.path)
    }

    // MARK: - Editions (D4 3.11)

    @Test("a library tag with the same title and edition is exact")
    func editionInTagIsExact() {
        let tagged = Entry(path: "/Music/x.flac", tagTitle: "Blue Lantern (Extended Mix)", tagArtists: ["Placeholder Artist"])
        let result = Self.match("Blue Lantern", Self.placeholder, in: [tagged], edition: "Extended Mix", duration: 461)
        #expect(result?.kind == .exact)
    }

    @Test("an old download with the bare title is exact when the lengths agree within 3 seconds")
    func bareTitleWithMatchingLengthIsExact() {
        let result = Self.match("Blue Lantern", Self.placeholder, in: [Self.downloadedExtendedMix],
                                edition: "Extended Mix", duration: 462.5)
        #expect(result?.kind == .exact)
        #expect(result?.evidence == .titleAndArtist)
    }

    @Test("a bare title can't confirm a named edition without a matching length", arguments: [
        Double?.none, .some(238), .some(465),
    ])
    func bareTitleWithoutMatchingLengthIsSimilar(_ libraryLength: Double?) {
        let library = Entry(path: "/Music/Blue Lantern.flac", tagTitle: "Blue Lantern",
                            tagArtists: ["Placeholder Artist"], tagDurationSeconds: libraryLength)
        let result = Self.match("Blue Lantern", Self.placeholder, in: [library], edition: "Extended Mix", duration: 461)
        #expect(result?.kind == .similar)
        #expect(result?.evidence == .editionUnconfirmed)
    }

    @Test("the same title and edition with lengths far apart is similar")
    func editionWithFarApartLengths() {
        let tagged = Entry(path: "/Music/x.flac", tagTitle: "Blue Lantern (Extended Mix)",
                           tagArtists: ["Placeholder Artist"], tagDurationSeconds: 238)
        let result = Self.match("Blue Lantern", Self.placeholder, in: [tagged], edition: "Extended Mix", duration: 461)
        #expect(result?.evidence == .lengthsDiffer)
    }

    @Test("an edition already in the title is treated as no extra edition")
    func editionAlreadyInTitle() {
        let tagged = Entry(path: "/Music/x.flac", tagTitle: "Blue Lantern (Extended Mix)", tagArtists: ["Placeholder Artist"])
        let result = Self.match("Blue Lantern (Extended Mix)", Self.placeholder, in: [tagged], edition: "Extended Mix")
        #expect(result?.kind == .exact)
    }

    @Test("an edition with no letters of its own changes nothing")
    func punctuationEditionIsIgnored() {
        let result = Self.match("Blue Lantern", Self.placeholder, in: [Self.radioEdit], edition: "—")
        #expect(result?.kind == .exact)
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [Self.radioEdit], edition: "(!)")?.kind == .exact)
    }

    @Test("a bare-titled file by another artist is similar for a named edition")
    func editionOtherArtist() {
        let result = Self.match("Blue Lantern", .names(["Other Band"]), in: [Self.radioEdit], edition: "Extended Mix")
        #expect(result?.kind == .similar)
        #expect(result?.evidence == .titleOnly)
    }

    // MARK: - Artists (D4 3.3)

    @Test("every artist value in the tags is used")
    func everyArtistTagCounts() {
        let multi = Entry(path: "/Music/x.flac", tagTitle: "Blue Lantern", tagArtists: ["Second Guest", "Placeholder Artist"])
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [multi])?.kind == .exact)
    }

    @Test("a tag naming a band with separators agrees with that band as a whole")
    func bandNameInTag() {
        let band = Entry(path: "/Music/x.flac", tagTitle: "Blue Lantern", tagArtists: ["Salt, Wind & Lantern"])
        #expect(Self.match("Blue Lantern", .names(["Salt, Wind & Lantern"]), in: [band])?.kind == .exact)
    }

    @Test("a shortened artist tag drops to similar, the safe direction")
    func shortenedArtistTag() {
        let short = Entry(path: "/Music/x.flac", tagTitle: "Blue Lantern", tagArtists: ["Placeholder"])
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [short])?.kind == .similar)
    }

    @Test("a CSV row's free-text artist line is split before comparing")
    func freeTextQueryArtists() {
        let result = Self.match("Blue Lantern", .text("Second Guest & Placeholder Artist"), in: [Self.l1])
        #expect(result?.kind == .exact)
    }

    // MARK: - Short titles (D4 3.13)

    @Test("a long full title is checked even when its core is short")
    func longFullTitleWithShortCore() {
        let twin = Entry(path: "/Music/x.flac", tagTitle: "Go (Placeholder Remix)", tagArtists: ["Other Band"])
        let result = Self.match("Go (Placeholder Remix)", Self.placeholder, in: [twin])
        #expect(result?.kind == .similar)
        #expect(result?.evidence == .titleOnly)
    }

    @Test("a short core never gives a similar badge on its own")
    func shortCoreGivesNothing() {
        #expect(Self.match("Go (Placeholder Remix)", Self.placeholder, in: [Self.l10]) == nil)
        #expect(Self.match("Go", Self.placeholder, in: [Entry(path: "/Music/Go.flac")]) == nil)
    }

    @Test("a short title with lengths far apart gives nothing, not a similar badge")
    func shortTitleLengthsApart() {
        let go = Entry(path: "/Music/x.flac", tagTitle: "Go", tagArtists: ["Placeholder Artist"], tagDurationSeconds: 200)
        #expect(Self.match("Go", Self.placeholder, in: [go], duration: 260) == nil)
        #expect(Self.match("Go", Self.placeholder, in: [go], duration: 205)?.kind == .exact)
    }

    @Test("two-character titles in other scripts follow the same rule")
    func shortNonLatinTitle() {
        let tokyo = Entry(path: "/Music/x.flac", tagTitle: "東京", tagArtists: ["Placeholder Artist"])
        #expect(Self.match("東京", Self.placeholder, in: [tokyo])?.kind == .exact)
        #expect(Self.match("東京", .names(["Other Band"]), in: [tokyo]) == nil)
    }

    // MARK: - File names (D4 3.12)

    static func nameKeys(_ fileName: String) -> Set<String> {
        Set(LibraryMatcher.fileNameTitles(fileName).map(Normalizer.fullKey))
    }

    @Test("an Artist - Title name keeps the whole name and the title (today's keys)")
    func artistTitleName() {
        #expect(Self.nameKeys("Placeholder Artist - Blue Lantern.flac") == ["placeholder artist blue lantern", "blue lantern"])
        #expect(Self.nameKeys("Blue Lantern.flac") == ["blue lantern"])
    }

    @Test("an Artist - Title - Version name splits at the first dash, not the last")
    func firstDashWins() {
        let keys = Self.nameKeys("Placeholder Artist - Blue Lantern - Radio Edit.mp3")
        #expect(keys.contains("blue lantern radio edit"))
        #expect(!keys.contains("radio edit"))
        let cores = Set(LibraryMatcher.fileNameTitles("Placeholder Artist - Blue Lantern - Radio Edit.mp3").map(Normalizer.coreKey))
        #expect(cores.contains("blue lantern"))
    }

    @Test("an en or em dash splits a name too")
    func otherDashesSplit() {
        #expect(Self.nameKeys("Placeholder Artist – Blue Lantern.flac").contains("blue lantern"))
        #expect(Self.nameKeys("Placeholder Artist — Blue Lantern.flac").contains("blue lantern"))
    }

    @Test("a title-only name with a version tail still finds the plain title")
    func titleOnlyNameWithVersion() {
        let file = Entry(path: "/Music/Blue Lantern - Radio Edit.flac")
        #expect(Self.match("Blue Lantern", Self.placeholder, in: [file])?.evidence == .otherVersion)
    }

    @Test("clear track numbers are removed, the unstripped name is kept", arguments: [
        ("01. Blue Lantern.flac", "01 blue lantern"),
        ("01 - Blue Lantern.flac", "01 blue lantern"),
        ("1-01 Blue Lantern.flac", "1 01 blue lantern"),
        ("01-Blue Lantern.flac", "01 blue lantern"),
        ("01 Blue Lantern.flac", "01 blue lantern"),
        ("1. Blue Lantern.flac", "1 blue lantern"),
    ])
    func trackNumbersRemoved(_ fileName: String, _ whole: String) {
        let keys = Self.nameKeys(fileName)
        #expect(keys.contains("blue lantern"))
        #expect(keys.contains(whole))
    }

    @Test("a number that is part of the title stays", arguments: [
        "22 Harbor Lights.flac", "7 Lanterns.flac", "1999.flac", "99 Red Lanterns.flac",
    ])
    func titleNumbersStay(_ fileName: String) {
        #expect(LibraryMatcher.removingTrackNumber(LibraryMatcher.removingExtension(fileName)) == nil)
    }

    @Test("a track number is kept when fewer than three characters of title would remain")
    func shortRemainderKeepsNumber() {
        #expect(LibraryMatcher.removingTrackNumber("01. Go") == nil)
        #expect(Self.nameKeys("01. Go.flac") == ["01 go"])
    }

    @Test("extensions follow Node's extname rule")
    func extensions() {
        #expect(LibraryMatcher.removingExtension("Blue Lantern.FLAC") == "Blue Lantern")
        #expect(LibraryMatcher.removingExtension("._Blue Lantern.flac") == "._Blue Lantern")
        #expect(LibraryMatcher.removingExtension(".flac") == ".flac")
        #expect(LibraryMatcher.removingExtension("Mr. Blue Lantern") == "Mr. Blue Lantern")
    }

    @Test("a file-name match is never exact, even with the artist in the name")
    func fileNameNeverExact() {
        let result = Self.match("Blue Lantern", Self.placeholder, in: [Self.l2])
        #expect(result?.kind == .similar)
    }
}
