import Testing
@testable import RobogearsCore

/// The normaliser example table from library-scanner-and-matcher.md ("Normaliser
/// worked examples", rows 1–21). Rows whose result stays the same are parity
/// checks; rows marked "changed" carry the new result decided in D4 3.1
/// (Unicode-aware, accent-insensitive) and D4 3.12 (smarter version tails).
@Suite("Normalizer")
struct NormalizerTests {

    struct Row: CustomTestStringConvertible, Sendable {
        let input: String
        let full: String
        let core: String
        var testDescription: String { input }
    }

    static let unchangedRows: [Row] = [
        Row(input: "Blue Lantern", full: "blue lantern", core: "blue lantern"),                                   // 1
        Row(input: "(Paper) Harbor", full: "paper harbor", core: "paper harbor"),                                 // 2
        Row(input: "Blue Lantern - Radio Edit", full: "blue lantern radio edit", core: "blue lantern"),            // 3
        Row(input: "Blue Lantern (feat. Placeholder Artist)", full: "blue lantern feat placeholder artist", core: "blue lantern"), // 4
        Row(input: "Blue Lantern [Remastered 2011]", full: "blue lantern remastered 2011", core: "blue lantern"),  // 5
        Row(input: "Blue Lantern ft. Placeholder Artist", full: "blue lantern ft placeholder artist", core: "blue lantern"), // 10
        Row(input: "Blue Lantern -Radio Edit", full: "blue lantern radio edit", core: "blue lantern radio edit"), // 15
        Row(input: "Go (Placeholder Remix)", full: "go placeholder remix", core: "go"),                           // 16
        Row(input: "Blue Lantern - Live at Placeholder Hall", full: "blue lantern live at placeholder hall", core: "blue lantern"), // 18
        Row(input: "Blue Lantern (Extended", full: "blue lantern extended", core: "blue lantern"),                // 19
    ]

    @Test("today's normaliser examples that keep their result", arguments: unchangedRows)
    func unchangedExample(_ row: Row) {
        #expect(Normalizer.fullKey(row.input) == row.full)
        #expect(Normalizer.coreKey(row.input) == row.core)
    }

    static let changedRows: [Row] = [
        // 6: a version word after the dash, not straight after it, now counts.
        Row(input: "Blue Lantern - 2011 Remaster", full: "blue lantern 2011 remaster", core: "blue lantern"),
        // 7 and 8: accents fold, and NFC and NFD spellings agree (were "caf toile" / "cafe e toile").
        Row(input: "Caf\u{E9} \u{C9}toile", full: "cafe etoile", core: "cafe etoile"),
        Row(input: "Cafe\u{301} E\u{301}toile", full: "cafe etoile", core: "cafe etoile"),
        // 9: non-Latin titles keep their letters (were empty).
        Row(input: "青い灯籠", full: "青い灯籠", core: "青い灯籠"),
        Row(input: "Синий фонарь", full: "синии фонарь", core: "синии фонарь"),
        // 11: an en dash separates a version tail too.
        Row(input: "Blue Lantern – Radio Edit", full: "blue lantern radio edit", core: "blue lantern"),
        // 12: a leading bracket no longer protects the later "(Live)".
        Row(input: "(Paper) Harbor (Live)", full: "paper harbor live", core: "paper harbor"),
        // 13: a bare "Ft" is a word, not "featuring" (was cut to "seven").
        Row(input: "Seven Ft Harbor", full: "seven ft harbor", core: "seven ft harbor"),
        // 14: "Remixed by" is a version tail (was kept whole).
        Row(input: "Blue Lantern - Remixed by Placeholder", full: "blue lantern remixed by placeholder", core: "blue lantern"),
        // 17: the Cyrillic part stays in the full key, so it no longer equals plain "Blue Lantern".
        Row(input: "Blue Lantern (Синий)", full: "blue lantern синии", core: "blue lantern"),
        // 21: leading spaces before a bracket no longer cut the whole title away.
        Row(input: "  (Paper) Harbor", full: "paper harbor", core: "paper harbor"),
    ]

    @Test("today's normaliser examples with the D4 3.1 / 3.12 result", arguments: changedRows)
    func changedExample(_ row: Row) {
        #expect(Normalizer.fullKey(row.input) == row.full)
        #expect(Normalizer.coreKey(row.input) == row.core)
    }

    @Test("ampersand and 'and' still differ, as today (example 20)")
    func ampersandIsNotFuzzy() {
        #expect(Normalizer.fullKey("Salt & Lantern") == "salt lantern")
        #expect(Normalizer.fullKey("Salt and Lantern") == "salt and lantern")
    }

    // MARK: - Unicode rules (D4 3.1)

    @Test("accented and plain spellings give the same key")
    func accentsFold() {
        #expect(Normalizer.fullKey("Beyoncé") == Normalizer.fullKey("Beyonce"))
        #expect(Normalizer.fullKey("Café Lumière") == "cafe lumiere")
        #expect(Normalizer.fullKey("Zoë Rø") == "zoe rø")
    }

    @Test("letters without a removable accent stay distinct")
    func letterWithoutAccentStaysDistinct() {
        #expect(Normalizer.fullKey("Mø") != Normalizer.fullKey("Mo"))
        #expect(Normalizer.fullKey("Æther") == "æther")
    }

    @Test("full-width letters, digits and brackets read as plain ones")
    func widthFolds() {
        #expect(Normalizer.fullKey("Ｂｌｕｅ　Ｌａｎｔｅｒｎ　２") == "blue lantern 2")
        #expect(Normalizer.coreKey("Blue Lantern （Live）") == "blue lantern")
        #expect(Normalizer.fullKey("ｶﾀｶﾅ") == "カタカナ")
    }

    @Test("Japanese voicing marks and Indic vowel signs are kept, not folded away")
    func scriptMarksAreKept() {
        #expect(Normalizer.fullKey("がっこう") != Normalizer.fullKey("かっこう"))
        #expect(Normalizer.fullKey("हिन्दी गीत") == "हिन्दी गीत")
        #expect(Normalizer.fullKey("한국어 노래") == "한국어 노래")
    }

    @Test("German sharp s and Greek final sigma fold like full case folding")
    func caseFolding() {
        #expect(Normalizer.fullKey("Straße") == Normalizer.fullKey("STRASSE"))
        #expect(Normalizer.fullKey("ΟΔΟΣ") == Normalizer.fullKey("οδος"))
    }

    @Test("apostrophes of every kind become a space, as a plain one did")
    func apostrophesAreSpaces() {
        #expect(Normalizer.fullKey("Don't") == "don t")
        #expect(Normalizer.fullKey("Don’t") == "don t")
        #expect(Normalizer.fullKey("Donʼt") == "don t")
    }

    @Test("Japanese long-vowel mark stays part of the word")
    func japaneseLongVowelMark() {
        #expect(Normalizer.fullKey("ブルー・ランタン") == "ブルー ランタン")
    }

    // MARK: - Empty-key guard (G3-1 skeptic)

    @Test("titles made only of symbols are compared on their raw text")
    func symbolOnlyTitles() {
        #expect(Normalizer.fullKey("♡") == "♡")
        #expect(Normalizer.fullKey("!!!") == "!!!")
        #expect(Normalizer.fullKey(" ! ! ") == "! !")
        #expect(Normalizer.coreKey("♡ (Live)") == "♡")
        #expect(!Normalizer.keysAgree(Normalizer.fullKey("♡"), Normalizer.fullKey("!!!")))
        #expect(Normalizer.keysAgree(Normalizer.fullKey("♡"), Normalizer.fullKey("♡")))
    }

    @Test("an empty key never agrees, not even with another empty key")
    func emptyKeysNeverAgree() {
        #expect(Normalizer.fullKey("") == "")
        #expect(Normalizer.fullKey("   ") == "")
        #expect(!Normalizer.keysAgree("", ""))
        #expect(!Normalizer.keysAgree(Normalizer.fullKey("  "), Normalizer.fullKey("")))
    }

    // MARK: - Version tails (D4 3.12)

    @Test("a version word anywhere in a spaced-dash segment counts", arguments: [
        "Blue Lantern - 2011 Remaster",
        "Blue Lantern - Remastered 2011",
        "Blue Lantern - Remixed by Placeholder",
        "Blue Lantern — Extended Mix",
        "Blue Lantern - Deluxe Edition",
        "Blue Lantern - Mono Version",
        "Blue Lantern - Reprised",
    ])
    func versionSegmentsAreCut(_ title: String) {
        #expect(Normalizer.coreKey(title) == "blue lantern")
    }

    @Test("a dash segment without a version word is kept", arguments: [
        ("Blue Lantern - Part Two", "blue lantern part two"),
        ("Blue Lantern - Lively Harbor", "blue lantern lively harbor"),
        ("Blue Lantern - Mixtape Days", "blue lantern mixtape days"),
        // "-d" is for "reprise" only: "lived" and "singled" are ordinary words.
        ("Blue Lantern - We Lived", "blue lantern we lived"),
        ("Blue Lantern - Singled Out", "blue lantern singled out"),
        ("Anti-Hero Remix Night", "anti hero remix night"),
    ])
    func nonVersionSegmentsAreKept(_ title: String, _ core: String) {
        #expect(Normalizer.coreKey(title) == core)
    }

    @Test("only the segment naming the version is cut, earlier segments stay")
    func laterSegmentIsCut() {
        #expect(Normalizer.coreKey("Blue Lantern - Part 2 - Radio Edit") == "blue lantern part 2")
    }

    @Test("feat. with a dot and the spelled-out featuring are cut; bare feat is not")
    func featuringRules() {
        #expect(Normalizer.coreKey("Blue Lantern feat. Second Guest") == "blue lantern")
        #expect(Normalizer.coreKey("Blue Lantern ft.Second Guest") == "blue lantern")
        #expect(Normalizer.coreKey("Blue Lantern featuring Second Guest") == "blue lantern")
        #expect(Normalizer.coreKey("A Heroic Feat") == "a heroic feat")
        #expect(Normalizer.coreKey("Blue Lantern feat Second Guest") == "blue lantern feat second guest")
    }

    @Test("a bracket at the very start with nothing after it stays")
    func leadingBracketOnly() {
        #expect(Normalizer.coreKey("(Live)") == "live")
        #expect(Normalizer.coreKey("[Untitled]") == "untitled")
    }
}
