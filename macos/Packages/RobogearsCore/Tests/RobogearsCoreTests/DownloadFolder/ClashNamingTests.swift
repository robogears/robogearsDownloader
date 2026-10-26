import Foundation
import Testing
@testable import RobogearsCore

// D4 2.6 and 2.7 option A: a file is "<Title>.flac" unless a different song
// already holds that name; then it takes the first free clash name, in the
// owner's fixed order (version, artist, album, then a number). 2.14: every
// part is sanitised like the plain name, and long names still fit.

@Suite("Clash names")
struct ClashNamingTests {
    @Test func clashNamesComeInTheOwnersOrderVersionArtistAlbum() {
        let stems = FileNaming.clashStems(title: "Intro", version: "Radio Edit", artist: "Second Example",
                                          album: "Paper Harbour")
        #expect(stems == ["Intro (Radio Edit)", "Intro (Second Example)", "Intro (Paper Harbour)"])
    }

    @Test func aVersionTheTitleAlreadyCarriesIsntAddedAgain() {
        let stems = FileNaming.clashStems(title: "Blue Lantern (Radio Edit)", version: "Radio Edit",
                                          artist: "Placeholder Artist", album: nil)
        #expect(stems == ["Blue Lantern (Radio Edit) (Placeholder Artist)"])
    }

    @Test func missingEmptyOrRepeatedPartsAreSkipped() {
        // A blank version, and an album named like the artist (a self-titled record).
        let stems = FileNaming.clashStems(title: "Intro", version: "  ", artist: "Paper Harbour", album: "Paper Harbour")
        #expect(stems == ["Intro (Paper Harbour)"])
        #expect(FileNaming.clashStems(title: "Intro", version: nil, artist: "\u{200B} ", album: nil).isEmpty)
    }

    @Test func clashNamesAreSanitisedLikeThePlainName() {
        let stems = FileNaming.clashStems(title: "Night/Day", version: nil, artist: "AC/DC: Live", album: nil)
        #expect(stems == ["Night_Day (AC_DC_ Live)"])
    }

    @Test func numberedNamesAddToTheLastClashName() {
        #expect(FileNaming.numberedClashStem(title: "Intro", version: "Radio Edit", artist: "Second Example",
                                             album: "Paper Harbour", number: 2) == "Intro (Paper Harbour) 2")
        // With nothing to add, the number goes after the title.
        #expect(FileNaming.numberedClashStem(title: "Intro", version: nil, artist: "", album: nil, number: 3) == "Intro 3")
    }

    @Test func aLongTitleIsShortenedNeverTheBracketedPartAndStillFitsANumber() {
        let title = String(repeating: "Lantern ", count: 60)
        for stem in FileNaming.clashStems(title: title, version: nil, artist: "Second Example", album: "Paper Harbour") {
            #expect(FileNaming.storedBytes(stem) <= FileNaming.maxStemBytes)
            #expect(stem.hasSuffix(" (Second Example)") || stem.hasSuffix(" (Paper Harbour)"))
        }
        let numbered = FileNaming.numberedClashStem(title: title, version: nil, artist: "Second Example",
                                                    album: "Paper Harbour", number: FileNaming.maxClashNumber)
        #expect(FileNaming.storedBytes(numbered) <= FileNaming.maxStemBytes)
        #expect(numbered.hasSuffix(" (Paper Harbour) 999"))
    }

    @Test func aLongAlbumCantCrowdTheTitleOut() {
        let album = String(repeating: "Harbour ", count: 50)
        let stem = FileNaming.clashStems(title: "Intro", version: nil, artist: "", album: album).first ?? ""
        #expect(stem.hasPrefix("Intro ("))
        #expect(FileNaming.storedBytes(stem) <= FileNaming.maxStemBytes)
    }

    @Test func twoLongTitlesThatShortenToOneNameShareAPlainName() {
        // 2.14: such a pair is a clash, so the folder sends the second one on
        // to its clash names; here only the shared plain name is pinned.
        let start = String(repeating: "a", count: 300)
        #expect(FileNaming.stem(title: start + "x") == FileNaming.stem(title: start + "y"))
        #expect(FileNaming.clashStems(title: start + "y", version: nil, artist: "Second Example", album: nil)
            == [String(repeating: "a", count: FileNaming.maxStemBytes - 17) + " (Second Example)"])
    }

    @Test func namesDifferingOnlyInCaseOrAccentStorageShareAComparisonKey() {
        #expect(FileNaming.comparisonKey("Intro.flac") == FileNaming.comparisonKey("INTRO.FLAC"))
        #expect(FileNaming.comparisonKey("Cafe\u{301}.flac") == FileNaming.comparisonKey("Caf\u{E9}.flac"))
        // Accents themselves still count.
        #expect(FileNaming.comparisonKey("Cafe.flac") != FileNaming.comparisonKey("Caf\u{E9}.flac"))
    }
}
