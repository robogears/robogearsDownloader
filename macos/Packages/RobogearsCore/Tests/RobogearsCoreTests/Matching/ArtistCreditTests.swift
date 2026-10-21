import Testing
@testable import RobogearsCore

/// Whole-name artist rules (D4 3.2 and 3.3, G3-2 and G3-3 skeptics).
@Suite("Artist credit")
struct ArtistCreditTests {

    @Test("free text splits at commas, semicolons, slashes, ampersands, feat. and x", arguments: [
        ("Placeholder Artist, Second Guest", ["placeholder artist", "second guest"]),
        ("Second Guest; Placeholder Artist", ["second guest", "placeholder artist"]),
        ("Placeholder Artist/Second Guest", ["placeholder artist", "second guest"]),
        ("Placeholder Artist & Second Guest", ["placeholder artist", "second guest"]),
        ("Placeholder Artist feat. Second Guest", ["placeholder artist", "second guest"]),
        ("Placeholder Artist ft. Second Guest", ["placeholder artist", "second guest"]),
        ("Placeholder Artist featuring Second Guest", ["placeholder artist", "second guest"]),
        ("Placeholder Artist X Second Guest", ["placeholder artist", "second guest"]),
        ("Placeholder Artist (feat. Second Guest)", ["placeholder artist", "second guest"]),
        ("プレースホルダー、セカンド", ["プレースホルダー", "セカンド"]),
        ("Placeholder Artist ＆ Second Guest", ["placeholder artist", "second guest"]),
    ])
    func splitsFreeText(_ line: String, _ names: [String]) {
        #expect(ArtistCredit.text(line).pieceKeys == names)
    }

    @Test("a letter x inside a name, or at its edge, is not a separator")
    func xInsideNamesStays() {
        #expect(ArtistCredit.text("Xenon Harbor").pieceKeys == ["xenon harbor"])
        #expect(ArtistCredit.text("Placeholder X").pieceKeys == ["placeholder x"])
        #expect(ArtistCredit.text("X Harbor Band").pieceKeys == ["x harbor band"])
        #expect(ArtistCredit.text("Placeholder Artist, X Harbor Band").pieceKeys == ["placeholder artist", "x harbor band"])
    }

    @Test("listed names are kept whole, separators and all")
    func listedNamesStayWhole() {
        #expect(ArtistCredit.names(["Salt, Wind & Lantern"]).pieceKeys == ["salt wind lantern"])
        #expect(ArtistCredit.names(["Salt, Wind & Lantern"]).comparisonKeys == ["salt wind lantern"])
    }

    @Test("free text compares its pieces and its whole line")
    func freeTextKeepsWholeLine() {
        #expect(ArtistCredit.text("Salt, Wind & Lantern").comparisonKeys
                == ["salt", "wind", "lantern", "salt wind lantern"])
    }

    @Test("neighbouring free-text pieces count as one listed name that splits into them")
    func runsRebuildSeparatedListedNames() {
        let line = ArtistCredit.text("Salt, Wind & Lantern, Second Guest")
        #expect(line.artistKeys(readAgainst: ["Salt, Wind & Lantern"]) == ["salt wind lantern", "second guest"])
        #expect(line.artistKeys(readAgainst: ["Wind & Lantern"]) == ["salt", "wind lantern", "second guest"])
        #expect(line.artistKeys(readAgainst: ["Wind Lantern"]) == ["salt", "wind", "lantern", "second guest"])
        #expect(line.artistKeys(readAgainst: []) == line.pieceKeys)
    }

    @Test("only names with a separator have a run key, and only lists offer them")
    func separatedNameKeys() throws {
        #expect(ArtistCredit.separatedNameKey("Wind Lantern") == nil)
        let band = try #require(ArtistCredit.separatedNameKey("Salt, Wind & Lantern"))
        #expect(ArtistCredit.names(["Salt, Wind & Lantern", "Second Guest"]).separatedNameKeys == [band])
        #expect(ArtistCredit.text("Salt, Wind & Lantern").separatedNameKeys.isEmpty)
        #expect(ArtistCredit.names(["Salt, Wind & Lantern"]).runKeys.isEmpty)
        #expect(ArtistCredit.text("Salt, Wind & Lantern, Second Guest").runKeys.contains(band))
    }

    @Test("empty or blank credits are unknown", arguments: [
        ArtistCredit.unknown, .text(""), .text("  , & "), .names([]), .names(["", " "]),
    ])
    func blankCreditsAreUnknown(_ credit: ArtistCredit) {
        #expect(!credit.isKnown)
        #expect(credit.comparisonKeys.isEmpty)
    }

    @Test("accented artist names agree with their plain spelling")
    func accentedArtists() {
        #expect(ArtistCredit.text("Zoë Rø").pieceKeys == ArtistCredit.names(["Zoe Rø"]).pieceKeys)
        #expect(ArtistCredit.text("Beyoncé").pieceKeys == ["beyonce"])
    }

    @Test("repeated names count once")
    func repeatedNamesCountOnce() {
        #expect(ArtistCredit.text("Placeholder Artist, placeholder artist").pieceKeys == ["placeholder artist"])
    }
}
