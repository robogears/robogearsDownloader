import Foundation
import Testing
@testable import RobogearsCore

// Worked examples from renderer-queue-and-flows.md §18 and
// text-unicode-and-filenames.md §6 where the behaviour stays, and decision
// cards G4-5, G4-6, G4-14, G4-15 and the "header-less lists" card where it
// changes.

private typealias Reading = ParsedTracklist.Reading

@Suite("Tracklists: CSV fields")
struct DelimitedTextTests {
    private func row(_ text: String, _ delimiter: Unicode.Scalar = ",") -> [String] {
        DelimitedText.fields(Substring(text), delimiter: delimiter)
    }

    @Test func quotedFieldKeepsItsComma() {
        #expect(row("a,\"b,c\",d") == ["a", "b,c", "d"])
    }

    @Test func doubledQuoteInsideQuotesIsOneQuote() {
        #expect(row("\"She said \"\"hi\"\"\",x") == ["She said \"hi\"", "x"])
    }

    @Test func quoteInTheMiddleOfAFieldIsLiteral() {
        #expect(row("ab\"c,d") == ["ab\"c", "d"])
    }

    @Test func textAfterAClosingQuoteJoinsTheField() {
        #expect(row("\"abc\"def,g") == ["abcdef", "g"])
    }

    @Test func quoteAfterLeadingSpacesStillOpensAQuotedField() {
        #expect(row("Blue Lantern, \"Hello, World\"") == ["Blue Lantern", "Hello, World"])
    }

    @Test func semicolonAndTabCanBeTheDelimiter() {
        #expect(row("Café;Placeholder Artist", ";") == ["Café", "Placeholder Artist"])
        #expect(row("Café\tPlaceholder Artist", "\t") == ["Café", "Placeholder Artist"])
    }

    @Test func crLfAndCrlfAllEndARowButQuotedBreaksStay() {
        let rows = DelimitedText.rows("a,b\r\nc,d\re,f\ng,\"h\r\ni\"\n", delimiter: ",")
        #expect(rows == [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h\r\ni"]])
    }

    @Test func trailingLineBreakAddsNoRowButABlankLineInTheMiddleDoes() {
        #expect(DelimitedText.rows("a\n\nb\n", delimiter: ",") == [["a"], [""], ["b"]])
    }

    @Test func linesSplitOnEveryKindOfLineBreak() {
        #expect(DelimitedText.lines("a\r\nb\rc\nd") == ["a", "b", "c", "d"])
    }
}

@Suite("Tracklists: CSV with a header")
struct TracklistTableTests {
    private func table(_ text: String) -> (ParsedTracklist.Columns?, [ParsedTracklist.Entry]) {
        let parsed = TracklistParser.parse(text)
        if case .table(let columns) = parsed.format { return (columns, parsed.entries) }
        return (nil, parsed.entries)
    }

    @Test func exportifyHeadersPickTrackNameAndArtistName() {
        let (columns, entries) = table("Track Name,Artist Name(s)\nBlue Lantern,Placeholder Artist\n")
        #expect(columns?.title == "Track Name")
        #expect(columns?.artist == "Artist Name(s)")
        #expect(entries.map(\.readings) == [[Reading("Blue Lantern", "Placeholder Artist")]])
    }

    @Test func artistBeforeTitleIsReadTheRightWayRound() {
        let (columns, entries) = table("Artist,Title\nPlaceholder Artist,Blue Lantern\n")
        #expect(columns?.title == "Title")
        #expect(entries.first?.readings == [Reading("Blue Lantern", "Placeholder Artist")])
    }

    @Test func songWithoutArtistColumnLeavesTheArtistEmpty() {
        let (columns, entries) = table("Song,Album\nBlue Lantern,Glass Orchard\n")
        #expect(columns?.artist == nil)
        #expect(entries.first?.readings == [Reading("Blue Lantern", "")])
    }

    @Test func artistNameColumnFirstNoLongerBecomesTheTitle() {
        // The Electron app used column 0 for both title and artist here.
        let (columns, entries) = table("Artist Name(s),Track Name\nPlaceholder Artist,Blue Lantern\n")
        #expect(columns?.title == "Track Name")
        #expect(columns?.artist == "Artist Name(s)")
        #expect(entries.first?.readings == [Reading("Blue Lantern", "Placeholder Artist")])
    }

    @Test func artistURIColumnBeforeArtistNameIsNotTheArtist() {
        let (columns, entries) = table("Track Name,Artist URI(s),Artist Name(s)\nBlue Lantern,spotify:artist:0b1,Placeholder Artist\n")
        #expect(columns?.artist == "Artist Name(s)")
        #expect(entries.first?.artist == "Placeholder Artist")
    }

    @Test func albumNameBeforeTrackNameIsNotTheTitle() {
        let (columns, _) = table("Album Name,Track Name,Artist\nGlass Orchard,Blue Lantern,Placeholder Artist\n")
        #expect(columns?.title == "Track Name")
    }

    @Test func trackNumberColumnIsNeverTheTitle() {
        // Music's export has "Name" and "Track Number"; a loose "contains
        // track" rule would have imported track numbers as titles.
        let (columns, entries) = table("Track Number,Name,Artist\n1,Blue Lantern,Placeholder Artist\n")
        #expect(columns?.title == "Name")
        #expect(entries.first?.title == "Blue Lantern")
    }

    @Test func columnNamedTrackHoldingNumbersIsSkippedForTheNextTitle() {
        let (columns, _) = table("Track,Song,Artist\n1,Blue Lantern,Placeholder Artist\n2,Copper Sky,Placeholder Artist\n")
        #expect(columns?.title == "Song")
    }

    @Test func looseRuleFindsAnUnusualTitleHeaderButNotADurationOne() {
        let (columns, _) = table("Track Duration (ms),Song Title (Original),Artist\n215000,Blue Lantern,Placeholder Artist\n")
        #expect(columns?.title == "Song Title (Original)")
        #expect(columns?.duration == "Track Duration (ms)")
    }

    @Test func blankFirstLineNoLongerHidesTheHeader() {
        let (columns, entries) = table("\n\nTrack Name,Artist Name(s)\nBlue Lantern,Placeholder Artist\n")
        #expect(columns?.title == "Track Name")
        #expect(entries.count == 1)
    }

    @Test func pastedListWhoseFirstLineMentionsANameIsNotSwallowedAsAHeader() {
        let parsed = TracklistParser.parse("The Name of the Game, Placeholder Artist\nBlue Lantern - Placeholder Artist\n")
        #expect(parsed.entries.count == 2)
        #expect(parsed.format == .plainText)
    }

    @Test func rowsWithEmptyTitlesAreSkippedAndDuplicatesRemovedCaseInsensitively() {
        let (_, entries) = table("Title,Artist\n,Placeholder Artist\nBlue Lantern,Placeholder Artist\nBLUE LANTERN,placeholder artist\n")
        #expect(entries.map(\.title) == ["Blue Lantern"])
    }

    @Test func exportifyClassicLayoutKeepsISRCAndDuration() throws {
        let parsed = try InputLaneFixtures.parsed("exportify-classic.csv")
        guard case .table(let columns) = parsed.format else { Issue.record("expected a table"); return }
        #expect(columns.delimiter == .comma)
        #expect(columns.title == "Track Name")
        #expect(columns.artist == "Artist Name(s)")
        #expect(columns.isrc == "ISRC")
        #expect(columns.duration == "Track Duration (ms)")

        let entries = parsed.entries
        #expect(entries.count == 3) // the repeated Blue Lantern row is dropped
        #expect(entries[0].readings == [Reading("Blue Lantern", "Placeholder Artist")])
        #expect(entries[0].isrc == "QZABC1100001")
        #expect(entries[0].duration == 221)
        #expect(entries[0].searchText == "Blue Lantern Placeholder Artist")
        #expect(entries[1].title == "Paper-Thin Harbor, Part 2")
        #expect(entries[1].artist == "Northbound Choir,Second Example")
        #expect(entries[1].duration == 185.5)
        #expect(entries[2].title == "The \"Copper\" Sky")
        #expect(entries[2].isrc == nil) // "not-an-isrc"
    }

    @Test func exportifyCurrentLayoutWithByteOrderMarkAndCRLF() throws {
        let parsed = try InputLaneFixtures.parsed("exportify-current.csv")
        guard case .table(let columns) = parsed.format else { Issue.record("expected a table"); return }
        #expect(columns.title == "Track Name")
        #expect(columns.artist == "Artist Name(s)")
        #expect(columns.isrc == nil)
        #expect(parsed.entries.map(\.title) == ["Blue Lantern", "Café Lumière"])
        #expect(parsed.entries.map(\.duration) == [221, 185.5])
    }

    @Test func musicAppExportReadsNameArtistAndTimeInSeconds() throws {
        let parsed = try InputLaneFixtures.parsed("music-app-export.txt")
        guard case .table(let columns) = parsed.format else { Issue.record("expected a table"); return }
        #expect(columns.delimiter == .tab)
        #expect(columns.title == "Name")
        #expect(columns.artist == "Artist")
        #expect(columns.duration == "Time")
        #expect(parsed.entries.map(\.readings) == [
            [Reading("Blue Lantern", "Placeholder Artist")],
            [Reading("夜の灯台", "Placeholder Artist")],
            [Reading("Café Lumière", "Northbound Choir")],
        ])
        #expect(parsed.entries.map(\.duration) == [221, 198, 185])
    }

    @Test func excelSemicolonCSVInWindowsEncoding() throws {
        let parsed = try InputLaneFixtures.parsed("excel-semicolon-windows1252.csv")
        guard case .table(let columns) = parsed.format else { Issue.record("expected a table"); return }
        #expect(columns.delimiter == .semicolon)
        #expect(parsed.entries.map(\.readings) == [
            [Reading("Café Lumière", "Northbound Choir")],
            [Reading("Blue Lantern \u{2013} Live", "Placeholder Artist")],
        ])
    }
}

@Suite("Tracklists: values")
struct TracklistValueTests {
    @Test func durationUnitsFollowTheHeader() {
        #expect(TracklistColumns.parseDuration("221000", unit: .milliseconds) == 221)
        #expect(TracklistColumns.parseDuration("221", unit: .seconds) == 221)
        #expect(TracklistColumns.parseDuration("3:41", unit: .milliseconds) == 221)
        #expect(TracklistColumns.parseDuration("1:02:03", unit: .automatic) == 3723)
        #expect(TracklistColumns.parseDuration("221000", unit: .automatic) == 221)
        #expect(TracklistColumns.parseDuration("221", unit: .automatic) == 221)
        #expect(TracklistColumns.parseDuration("", unit: .seconds) == nil)
        #expect(TracklistColumns.parseDuration("0", unit: .seconds) == nil)
        #expect(TracklistColumns.parseDuration("three", unit: .seconds) == nil)
    }

    @Test func isrcIsNormalisedOrRejected() {
        #expect(TracklistColumns.parseISRC("qz-abc-11-00001") == "QZABC1100001")
        #expect(TracklistColumns.parseISRC("QZABC1100001") == "QZABC1100001")
        #expect(TracklistColumns.parseISRC("QZABC110000") == nil)
        #expect(TracklistColumns.parseISRC("1ZABC1100001") == nil)
        #expect(TracklistColumns.parseISRC("") == nil)
    }
}

@Suite("Tracklists: lists without a header")
struct HeaderlessListTests {
    @Test func singleTitleCommaArtistLineIsReadAsTwoColumns() {
        // The Electron app read the whole line as a title with no artist.
        let parsed = TracklistParser.parse("Blue Lantern, Placeholder Artist")
        #expect(parsed.format == .headerlessColumns(.comma))
        #expect(parsed.entries.first?.readings == [
            Reading("Blue Lantern", "Placeholder Artist"),
            Reading("Placeholder Artist", "Blue Lantern"),
            Reading("Blue Lantern, Placeholder Artist", ""),
        ])
        #expect(parsed.entries.first?.searchText == "Blue Lantern Placeholder Artist")
    }

    @Test func webTableRowsSkipTheNumberColumnAndKeepTheLength() throws {
        // The Electron app split at the first tab, got the title "1", and
        // dropped every line.
        let parsed = try InputLaneFixtures.parsed("web-table-rows.txt")
        #expect(parsed.format == .headerlessColumns(.tab))
        #expect(parsed.entries.count == 3)
        #expect(parsed.entries[0].readings == [Reading("Blue Lantern", "Placeholder Artist"), Reading("Placeholder Artist", "Blue Lantern")])
        #expect(parsed.entries[0].duration == 221)
        #expect(parsed.entries[1].title == "Paper-Thin Harbor")
    }

    @Test func semicolonLineWithThreeFieldsUsesTheFirstTwo() {
        // Was one title, "Song;Artist;Album" style, with no artist.
        let parsed = TracklistParser.parse("Blue Lantern;Placeholder Artist;Glass Orchard")
        #expect(parsed.format == .headerlessColumns(.semicolon))
        #expect(parsed.entries.first?.readings.first == Reading("Blue Lantern", "Placeholder Artist"))
    }

    @Test func tabSeparatedLineWithThreeFieldsUsesTheFirstTwo() {
        // Was split at the first tab: artist "Placeholder Artist⇥Glass Orchard".
        let parsed = TracklistParser.parse("Blue Lantern\tPlaceholder Artist\tGlass Orchard")
        #expect(parsed.entries.first?.readings.first == Reading("Blue Lantern", "Placeholder Artist"))
    }

    @Test func headerRowWithNoDataGivesNoSongs() {
        // A lone "Song;Artist;Album" is a header, not a song called that.
        let parsed = TracklistParser.parse("Song;Artist;Album")
        #expect(parsed.isEmpty)
        guard case .table(let columns) = parsed.format else { Issue.record("expected a table"); return }
        #expect(columns.delimiter == .semicolon)
    }

    @Test func titlesWithCommasInASpacedDashListStayWhole() {
        let parsed = TracklistParser.parse("Ob-La-Di, Ob-La-Da - The Beatles")
        #expect(parsed.format == .plainText)
        #expect(parsed.entries.first?.readings.first == Reading("Ob-La-Di, Ob-La-Da", "The Beatles"))
    }

    @Test func linesWithAnOddFieldCountFallBackToPlainText() {
        let parsed = TracklistParser.parse("""
        Blue Lantern, Placeholder Artist
        Copper Sky, Second Example
        Glass Orchard, Northbound Choir
        Late Ferry, Placeholder Artist
        Paper-Thin Harbor | Northbound Choir
        """)
        #expect(parsed.format == .headerlessColumns(.comma))
        #expect(parsed.entries.count == 5)
        #expect(parsed.entries[4].readings.first == Reading("Paper-Thin Harbor", "Northbound Choir"))
    }
}

@Suite("Tracklists: pasted lines")
struct PlainTextTracklistTests {
    private func readings(_ line: String) -> [Reading] {
        TracklistParser.parse(line).entries.first?.readings ?? []
    }

    @Test func hyphenInsideAnArtistNameDoesntSplit() {
        #expect(readings("Empire State of Mind - Jay-Z").first == Reading("Empire State of Mind", "Jay-Z"))
    }

    @Test func hyphenInsideATitleDoesntSplit() {
        // Was title "Anti", artist "Hero - Taylor Swift".
        #expect(readings("Anti-Hero - Taylor Swift").first == Reading("Anti-Hero", "Taylor Swift"))
        #expect(readings("Paper-Thin Harbor - Placeholder Artist").first == Reading("Paper-Thin Harbor", "Placeholder Artist"))
    }

    @Test func artistTitleOrderIsOfferedAsTheSecondReading() {
        #expect(readings("Jay-Z - Empire State of Mind") == [
            Reading("Jay-Z", "Empire State of Mind"),
            Reading("Empire State of Mind", "Jay-Z"),
            Reading("Jay-Z - Empire State of Mind", ""),
        ])
    }

    @Test func everySeparatorIsTriedInBothOrdersTitleArtistFirst() {
        #expect(readings("Blue Lantern - Live at Home - Placeholder Artist") == [
            Reading("Blue Lantern - Live at Home", "Placeholder Artist"),
            Reading("Blue Lantern", "Live at Home - Placeholder Artist"),
            Reading("Live at Home - Placeholder Artist", "Blue Lantern"),
            Reading("Placeholder Artist", "Blue Lantern - Live at Home"),
            Reading("Blue Lantern - Live at Home - Placeholder Artist", ""),
        ])
    }

    @Test func artistTitleWithASuffixHasAReadingThatKeepsTheSuffix() {
        // G4-6 skeptic: splitting only at the last separator lost this one.
        #expect(readings("Placeholder Artist - Blue Lantern - Radio Edit").contains(Reading("Blue Lantern - Radio Edit", "Placeholder Artist")))
    }

    @Test func emDashEnDashPipeAndTabAllSplitWhenSpaced() {
        for line in ["Blue Lantern \u{2014} Placeholder Artist", "Blue Lantern \u{2013} Placeholder Artist", "Blue Lantern | Placeholder Artist", "Blue Lantern\tPlaceholder Artist"] {
            #expect(readings(line).first == Reading("Blue Lantern", "Placeholder Artist"), "\(line)")
        }
    }

    @Test func unspacedDashesNeverSplit() {
        #expect(readings("Blue Lantern\u{2014}Placeholder Artist") == [Reading("Blue Lantern\u{2014}Placeholder Artist", "")])
        #expect(readings("Blue Lantern -Placeholder Artist") == [Reading("Blue Lantern -Placeholder Artist", "")])
    }

    @Test func oneCharacterTitleIsKeptWhenAnArtistIsGiven() {
        // Was dropped. A bare "7" is still dropped.
        #expect(readings("7 - Prince").first == Reading("7", "Prince"))
        #expect(TracklistParser.parse("7").isEmpty)
    }

    @Test func leadingListNumbersAreRemoved() {
        #expect(readings("1. Song - Artist").first == Reading("Song", "Artist"))
        #expect(readings("01) Song - Artist").first == Reading("Song", "Artist"))
        #expect(readings("12\tSong - Artist").first == Reading("Song", "Artist"))
    }

    @Test func aNumberThatStartsATitleStays() {
        #expect(readings("99 Luftballons - Placeholder Artist").first == Reading("99 Luftballons", "Placeholder Artist"))
        #expect(readings("1999 - Placeholder Artist").first == Reading("1999", "Placeholder Artist"))
    }

    @Test func titleByArtistIsOfferedAfterTheWholeLine() {
        #expect(readings("Blue Lantern by Placeholder Artist") == [
            Reading("Blue Lantern by Placeholder Artist", ""),
            Reading("Blue Lantern", "Placeholder Artist"),
        ])
        #expect(readings("Stand By Me").first == Reading("Stand By Me", ""))
    }

    @Test func searchTextUsesAllTheWordsWithoutSeparators() {
        let entry = TracklistParser.parse("1. Blue Lantern - Live at Home | Placeholder Artist").entries.first
        #expect(entry?.searchText == "Blue Lantern Live at Home Placeholder Artist")
    }

    @Test func lineWithoutSeparatorIsATitleWithNoArtist() {
        #expect(readings("Blue Lantern") == [Reading("Blue Lantern", "")])
    }

    @Test func oldMacLineEndingsGiveOneSongPerLine() {
        #expect(TracklistParser.parse("Blue Lantern - Placeholder Artist\rCopper Sky - Second Example\r").entries.count == 2)
    }

    @Test func pastedListKeepsOrderTurnsLinksIntoLinksAndDropsDuplicates() throws {
        let parsed = try InputLaneFixtures.parsed("pasted-list.txt")
        #expect(parsed.format == .plainText)
        let summary: [String] = parsed.items.map { item in
            switch item {
            case .track(let entry): "track: \(entry.title) / \(entry.artist)"
            case .link(.spotify(let link)): "spotify \(link.content.rawValue): \(link.id)"
            case .link(.unsupported(let info)): "unsupported: \(info.service.displayName)"
            case .link(let other): "link: \(other)"
            }
        }
        #expect(summary == [
            "track: Blue Lantern / Placeholder Artist",
            "track: Paper-Thin Harbor / Northbound Choir",
            "track: Placeholder Artist - Copper Sky / Radio Edit",
            "spotify track: 4uLU6hMCjMI75M1A2tKUQC",
            "unsupported: YouTube",
            "track: Glass Orchard / Second Example",
            "track: 7 / Prince",
        ])
        #expect(parsed.links.count == 2)
        #expect(parsed.entries.count == 5)
    }

    @Test func emptyOrBlankTextHasNoItems() {
        #expect(TracklistParser.parse("").isEmpty)
        #expect(TracklistParser.parse("\n \r\n\t\n").isEmpty)
        #expect(TracklistParser.parse("\u{FEFF}").isEmpty)
    }
}
