import Foundation
import Testing
@testable import RobogearsCore

@Suite("TIDAL matcher")
struct TidalMatcherTests {

    typealias Wanted = TidalMatcher.Wanted
    typealias Candidate = TidalMatcher.Candidate

    // MARK: - Today's worked examples (tidal-and-spotify-networking.md §G, wantDuration 200 s)

    static let stronger = Wanted(title: "Stronger", artists: .names(["Kanye West"]), durationSeconds: 200)

    @Test("exact title, same artist, close length scores 250 and is accepted (example 1)")
    func workedExampleOne() throws {
        let match = try #require(TidalMatcher.bestMatch(for: Self.stronger, among: [
            Candidate(title: "Stronger", artistNames: ["Kanye West"], durationSeconds: 201),
        ]))
        #expect(match.score == TidalMatcher.Score(title: 100, artist: 100, length: 50))
        #expect(match.score.total == 250)
        #expect(match.confirmation == .artistAgrees)
        #expect(!match.artistDiffers)
    }

    @Test("exact title by another band ranks below the right artist (example 2)")
    func workedExampleTwoRanking() throws {
        let match = try #require(TidalMatcher.bestMatch(for: Self.stronger, among: [
            Candidate(title: "Stronger", artistNames: ["Another Band"], durationSeconds: 222),
            Candidate(title: "Stronger", artistNames: ["Kanye West"], durationSeconds: 201),
        ]))
        #expect(match.index == 1)
    }

    @Test("exact title by another band, lengths apart, is no longer silently accepted (example 2, changed)")
    func workedExampleTwoAlone() throws {
        // Today: accepted at 100 with no artist check. Now: still offered, but
        // unconfirmed, so the queue adds it left out with "Different artist on TIDAL".
        let match = try #require(TidalMatcher.bestMatch(for: Self.stronger, among: [
            Candidate(title: "Stronger", artistNames: ["Another Band"], durationSeconds: 222),
        ]))
        #expect(match.score.total == 100)
        #expect(match.confirmation == .unconfirmed)
        #expect(match.startsLeftOut)
        #expect(match.artistDiffers)
    }

    @Test("a remix by the same artist is a partial title accepted on the artist (example 3)")
    func workedExampleThree() throws {
        let match = try #require(TidalMatcher.bestMatch(for: Self.stronger, among: [
            Candidate(title: "Stronger (Remix)", artistNames: ["Kanye West"], durationSeconds: 240),
        ]))
        #expect(match.score == TidalMatcher.Score(title: 50, artist: 100, length: 0))
        #expect(match.confirmation == .artistAgrees)
    }

    @Test("a partial title without the artist is rejected even with the right length (example 4)")
    func workedExampleFour() {
        let wanted = Wanted(title: "Free Your Mind", artists: .names(["En Vogue"]), durationSeconds: 200)
        let candidate = Candidate(title: "Mind", artistNames: ["Other Artist"], durationSeconds: 200)
        #expect(TidalMatcher.evaluate(wanted, candidate, index: 0) == nil)
        #expect(TidalMatcher.titleScore(wanted: wanted.title, candidate: candidate) == 25)
        #expect(TidalMatcher.lengthScore(200, 200) == 50)
    }

    @Test("'The' no longer makes The Weeknd agree with The Beatles (example 5, changed)")
    func workedExampleFive() {
        let wanted = Wanted(title: "Song", artists: .text("The Weeknd"), durationSeconds: 200)
        let candidate = Candidate(title: "Song Two", artistNames: ["The Beatles"], durationSeconds: 200)
        #expect(TidalMatcher.artistScore(wanted: wanted.artists, tidalNames: candidate.artistNames).score == 0)
        #expect(TidalMatcher.bestMatch(for: wanted, among: [candidate]) == nil)
    }

    // MARK: - Exact titles need the artist or the length (D4 3.2)

    static let intro = Wanted(title: "Intro", artists: .text("Placeholder Artist"), durationSeconds: 98)

    @Test("another artist's Intro of a different length is offered unconfirmed, not accepted")
    func wrongArtistIntroIsFlagged() throws {
        let match = try #require(TidalMatcher.bestMatch(for: Self.intro, among: [
            Candidate(title: "Intro", artistNames: ["Another Band"], durationSeconds: 141),
        ]))
        #expect(match.confirmation == .unconfirmed)
        #expect(match.startsLeftOut)
        #expect(match.artistDiffers)
    }

    @Test("an exact title by a differently written artist is accepted when the lengths agree")
    func lengthConfirmsDifferentlyWrittenArtist() throws {
        let wanted = Wanted(title: "夜の灯台", artists: .text("プレースホルダー"), durationSeconds: 212.4)
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "夜の灯台", artistNames: ["Placeholder"], durationSeconds: 211),
        ]))
        #expect(match.confirmation == .lengthAgrees)
        #expect(!match.startsLeftOut)
        #expect(match.artistDiffers)
    }

    @Test("lengths exactly 3 seconds apart don't confirm an exact title")
    func threeSecondsIsNotClose() throws {
        let match = try #require(TidalMatcher.bestMatch(for: Self.intro, among: [
            Candidate(title: "Intro", artistNames: ["Another Band"], durationSeconds: 101),
        ]))
        #expect(match.confirmation == .unconfirmed)
        #expect(match.score.length == 25)
    }

    @Test("a confirmed pick always beats an unconfirmed one with a higher total")
    func confirmedBeatsUnconfirmed() throws {
        let wanted = Wanted(title: "Intro", artists: .text("Placeholder Artist & Second Guest"), durationSeconds: 98)
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Intro", artistNames: ["Another Band"], durationSeconds: 103),                 // 100 + 0 + 25
            Candidate(title: "Intro to Blue Lantern", artistNames: ["Placeholder Artist"], durationSeconds: 300), // 50 + 50 + 0
        ]))
        #expect(match.index == 1)
        #expect(match.score.total == 100)
        #expect(match.confirmation == .artistAgrees)
    }

    @Test("a source with no artist keeps today's rule: an exact title is accepted")
    func noArtistKeepsTitleOnlyAcceptance() throws {
        let wanted = Wanted(title: "Intro", artists: .unknown, durationSeconds: nil)
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Intro", artistNames: ["Another Band"], durationSeconds: 141),
        ]))
        #expect(match.confirmation == .titleOnly)
        #expect(!match.artistDiffers)
        #expect(!match.startsLeftOut)
    }

    @Test("a source with no artist still can't accept a partial title")
    func noArtistRejectsPartialTitle() {
        let wanted = Wanted(title: "Intro", artists: .text("  "))
        #expect(!wanted.artists.isKnown)
        #expect(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Intro to Blue Lantern", artistNames: ["Placeholder Artist"]),
        ]) == nil)
    }

    // MARK: - Whole-name artists (D4 3.2, G3-2 skeptic)

    @Test("an artist word found inside another name no longer counts")
    func fragmentsDoNotCount() {
        #expect(TidalMatcher.artistScore(wanted: .text("Owls"), tidalNames: ["Bowls"]).agrees == false)
        #expect(TidalMatcher.artistScore(wanted: .text("The Placeholders"), tidalNames: ["Another Band"]).score == 0)
    }

    @Test("a partial title by 'The ...' no longer passes on the shared 'the'")
    func theDoesNotAcceptPartialTitle() {
        let wanted = Wanted(title: "Lantern Song", artists: .text("The Placeholders"))
        #expect(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Lantern Song Two", artistNames: ["The Other Band"]),
        ]) == nil)
    }

    @Test("a band name containing separators agrees with itself through the unsplit line")
    func bandNameWithSeparatorsAgrees() {
        let evidence = TidalMatcher.artistScore(wanted: .text("Salt, Wind & Lantern"), tidalNames: ["Salt, Wind & Lantern"])
        #expect(evidence.score == 100)
        #expect(evidence.agrees)
        #expect(!TidalMatcher.artistScore(wanted: .text("Salt, Wind & Lantern"), tidalNames: ["Wind Lantern"]).agrees)
    }

    @Test("free text is split, and each piece agrees only with a whole TIDAL name")
    func freeTextPiecesMatchWholeNames() {
        let evidence = TidalMatcher.artistScore(wanted: .text("Placeholder Artist feat. Second Guest"),
                                                tidalNames: ["Placeholder Artist"])
        #expect(evidence.score == 50)
        #expect(evidence.agrees)
        let reordered = TidalMatcher.artistScore(wanted: .text("Second Guest & Placeholder Artist"),
                                                 tidalNames: ["Placeholder Artist", "Second Guest"])
        #expect(reordered.score == 100)
    }

    @Test("listed names are never split")
    func listedNamesAreNotSplit() {
        // As a list, "Salt, Wind & Lantern" is one name and does not agree with "Lantern".
        #expect(!TidalMatcher.artistScore(wanted: .names(["Salt, Wind & Lantern"]), tidalNames: ["Lantern"]).agrees)
        // As free text the piece "Lantern" equals a whole TIDAL name: the accepted, rare cost (D4 3.3).
        #expect(TidalMatcher.artistScore(wanted: .text("Salt, Wind & Lantern"), tidalNames: ["Lantern"]).agrees)
    }

    @Test("the artist share rounds like today's Math.round")
    func artistShareRounds() {
        let evidence = TidalMatcher.artistScore(wanted: .names(["Placeholder Artist", "Second Guest", "Third Guest"]),
                                                tidalNames: ["Placeholder Artist", "Second Guest"])
        #expect(evidence.score == 67)
    }

    // MARK: - Unicode titles (D4 3.1, G4-18)

    @Test("an accented title finds TIDAL's plain spelling")
    func accentsMatch() throws {
        let wanted = Wanted(title: "Cafe Lumiere", artists: .text("Placeholder Duo"))
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Café Lumière", artistNames: ["Placeholder Duo"]),
        ]))
        #expect(match.score.title == 100)
    }

    @Test("a non-Latin title no longer matches another song by the same artist")
    func nonLatinTitleIsNotEmpty() {
        // Today the wanted title normalised to "" and every Latin title "started with" it.
        let wanted = Wanted(title: "夜の灯台", artists: .text("Placeholder Artist"))
        #expect(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Different Song", artistNames: ["Placeholder Artist"]),
            Candidate(title: "別の歌", artistNames: ["Other Artist"]),
        ]) == nil)
    }

    @Test("a non-Latin title picks the same title by the same artist")
    func nonLatinTitleMatchesItself() throws {
        let wanted = Wanted(title: "夜の灯台", artists: .text("Placeholder Artist"))
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "別の歌", artistNames: ["Placeholder Artist"]),
            Candidate(title: "夜の灯台", artistNames: ["Placeholder Artist"]),
        ]))
        #expect(match.index == 1)
    }

    @Test("symbol-only titles match only the same symbols")
    func symbolTitles() {
        #expect(TidalMatcher.titleScore(wanted: "♡", candidate: Candidate(title: "♡", artistNames: [])) == 100)
        #expect(TidalMatcher.titleScore(wanted: "♡", candidate: Candidate(title: "Love", artistNames: [])) == 0)
        #expect(TidalMatcher.titleScore(wanted: "", candidate: Candidate(title: "", artistNames: [])) == 0)
        #expect(TidalMatcher.titleScore(wanted: "", candidate: Candidate(title: "Blue Lantern", artistNames: [])) == 0)
    }

    // MARK: - Length and ordering

    @Test("length counts whenever both sides have one, and never when either is missing")
    func lengthOnlyWhenKnown() {
        #expect(TidalMatcher.lengthScore(200, 202.9) == 50)
        #expect(TidalMatcher.lengthScore(200, 207.9) == 25)
        #expect(TidalMatcher.lengthScore(200, 208) == 0)
        #expect(TidalMatcher.lengthScore(nil, 200) == 0)
        #expect(TidalMatcher.lengthScore(0, 0) == 0)
    }

    @Test("equal totals keep TIDAL's order")
    func tiesKeepSearchOrder() throws {
        let wanted = Wanted(title: "Blue Lantern", artists: .text("Placeholder Artist"))
        let candidates = (0..<5).map { _ in Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"]) }
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: candidates))
        #expect(match.index == 0)
    }

    // MARK: - ISRC (G3-2 skeptic, D4 3.5)

    @Test("the same ISRC wins over a higher-scoring result")
    func sameRecordingCodeWins() throws {
        let wanted = Wanted(title: "Blue Lantern", artists: .text("Placeholder Artist"), durationSeconds: 238, isrc: "ZZ-AAA-26-00007")
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"], durationSeconds: 238, isrc: "ZZAAA2600001"),
            Candidate(title: "Blue Lantern - 2011 Remaster", artistNames: ["Placeholder Artist"], durationSeconds: 240, isrc: "ZZAAA2600007"),
        ]))
        #expect(match.index == 1)
        #expect(match.confirmation == .sameRecordingCode)
    }

    @Test("several releases of one ISRC are ranked by length, then TIDAL's order")
    func isrcReleasesRankedByLength() throws {
        let wanted = Wanted(title: "Blue Lantern", artists: .text("Placeholder Artist"), durationSeconds: 238, isrc: "ZZAAA2600007")
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"], durationSeconds: 250, isrc: "ZZAAA2600007"),
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"], durationSeconds: 238, isrc: "ZZAAA2600007"),
        ]))
        #expect(match.index == 1)
    }

    @Test("malformed ISRCs never count as the same recording")
    func junkRecordingCodes() {
        #expect(!MatchRules.sameRecording("N/A", "N/A"))
        #expect(!MatchRules.sameRecording("0", "0"))
        #expect(!MatchRules.sameRecording(nil, nil))
        #expect(MatchRules.sameRecording("zz-aaa-26-00007", "ZZAAA2600007"))
    }

    // MARK: - Editions (D4 3.11)

    @Test("a title naming an edition prefers TIDAL's matching edition")
    func prefersRequestedEdition() throws {
        let wanted = Wanted(title: "Blue Lantern - Extended Mix", artists: .text("Placeholder Artist"))
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"]),
            Candidate(title: "Blue Lantern", version: "Extended Mix", artistNames: ["Placeholder Artist"]),
        ]))
        #expect(match.index == 1)
        #expect(match.score.title == 100)
    }

    @Test("a plain title prefers the plain version over an edition")
    func plainTitlePrefersPlainVersion() throws {
        let wanted = Wanted(title: "Blue Lantern", artists: .text("Placeholder Artist"))
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Blue Lantern", version: "Extended Mix", artistNames: ["Placeholder Artist"]),
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"]),
        ]))
        #expect(match.index == 1)
    }

    @Test("a plain title still counts as exact against the only, versioned, result")
    func bareTitleStillExact() throws {
        let wanted = Wanted(title: "Blue Lantern", artists: .unknown)
        let match = try #require(TidalMatcher.bestMatch(for: wanted, among: [
            Candidate(title: "Blue Lantern", version: "Remastered", artistNames: ["Placeholder Artist"]),
        ]))
        #expect(match.score.title == 90)
        #expect(match.confirmation == .titleOnly)
    }

    @Test("an edition already in TIDAL's title is not added twice")
    func editionNotDoubled() {
        #expect(EditionTitle.make(title: "Blue Lantern (Extended Mix)", edition: "Extended Mix") == "Blue Lantern (Extended Mix)")
        #expect(EditionTitle.make(title: "Blue Lantern", edition: " Extended Mix ") == "Blue Lantern (Extended Mix)")
        #expect(EditionTitle.make(title: "Blue Lantern", edition: nil) == "Blue Lantern")
        #expect(EditionTitle.make(title: "Blue Lantern", edition: "") == "Blue Lantern")
        // Whole words only: "Mix" is not already in "Remix Night".
        #expect(EditionTitle.make(title: "Remix Night", edition: "Mix") == "Remix Night (Mix)")
    }

    // MARK: - Several readings of one line (D4 4.6)

    @Test("an Artist - Title line is matched the other way round")
    func readingsPickTheBetterOrder() throws {
        let readings = [
            Wanted(title: "Placeholder Artist", artists: .text("Blue Lantern")),
            Wanted(title: "Blue Lantern", artists: .text("Placeholder Artist")),
        ]
        let best = try #require(TidalMatcher.bestMatch(forReadings: readings, among: [
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"]),
        ]))
        #expect(best.reading == 1)
        #expect(best.match.confirmation == .artistAgrees)
    }

    @Test("when both readings score the same, the first (Title - Artist) wins")
    func readingTieGoesToFirst() throws {
        let readings = [
            Wanted(title: "Echo", artists: .text("Echo")),
            Wanted(title: "Echo", artists: .text("Echo")),
        ]
        let best = try #require(TidalMatcher.bestMatch(forReadings: readings, among: [
            Candidate(title: "Echo", artistNames: ["Echo"]),
        ]))
        #expect(best.reading == 0)
    }

    @Test("an equal score keeps the first reading even when the other picks an earlier result")
    func readingTieIgnoresCandidatePosition() throws {
        let readings = [
            Wanted(title: "Blue Lantern", artists: .text("Placeholder Artist")),
            Wanted(title: "Placeholder Artist", artists: .text("Blue Lantern")),
        ]
        let best = try #require(TidalMatcher.bestMatch(forReadings: readings, among: [
            Candidate(title: "Placeholder Artist", artistNames: ["Blue Lantern"]),
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"]),
        ]))
        #expect(best.reading == 0)
        #expect(best.match.index == 1)
    }

    @Test("no reading matching gives no pick")
    func noReadingMatches() {
        #expect(TidalMatcher.bestMatch(forReadings: [Wanted(title: "Nothing Here")], among: [
            Candidate(title: "Blue Lantern", artistNames: ["Placeholder Artist"]),
        ]) == nil)
        #expect(TidalMatcher.bestMatch(forReadings: [], among: []) == nil)
    }

    // MARK: - A realistic search reply

    @Test("from a TIDAL search reply, the right artist's Intro of the right length is picked")
    func pickFromSearchFixture() throws {
        let candidates = try Self.loadSearchFixture()
        let match = try #require(TidalMatcher.bestMatch(for: Self.intro, among: candidates))
        #expect(match.index == 3)
        #expect(match.score.total == 250)
        #expect(match.confirmation == .artistAgrees)
    }

    @Test("from the same reply, only another band's Intro left: offered left out")
    func onlyWrongArtistInFixture() throws {
        let candidates = try Self.loadSearchFixture()
        let match = try #require(TidalMatcher.bestMatch(for: Self.intro, among: [candidates[0]]))
        #expect(match.startsLeftOut)
        #expect(match.candidate.artistNames == ["Another Band"])
    }

    private struct SearchReply: Decodable {
        struct Item: Decodable {
            struct Artist: Decodable { let name: String }
            let title: String
            let version: String?
            let duration: Double?
            let isrc: String?
            let artists: [Artist]
        }
        let items: [Item]
    }

    static func loadSearchFixture() throws -> [Candidate] {
        let url = try #require(Bundle.module.url(forResource: "tidal-search-intro", withExtension: "json",
                                                 subdirectory: "Fixtures/matching"))
        let reply = try JSONDecoder().decode(SearchReply.self, from: Data(contentsOf: url))
        return reply.items.map {
            Candidate(title: $0.title, version: $0.version, artistNames: $0.artists.map(\.name),
                      durationSeconds: $0.duration, isrc: $0.isrc)
        }
    }
}
