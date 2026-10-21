import Foundation
import Testing
@testable import RobogearsCore

// Rule 3 (title-only names), the Electron `sanitize` table in
// text-unicode-and-filenames.md §1, and card G2-X6's edge-case fixes.
//
// Names are compared as UTF-8 bytes where Unicode form matters: Swift's ==
// treats "é" and "e + ◌́" as equal, so it can't catch a missing NFC step.

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

@Suite("File names")
struct FileNamingTests {
    @Test func ordinaryTitleGivesTitleDotFlacAndMatchesTheOldApp() {
        #expect(FileNaming.fileName(title: "Blue Lantern", extension: .flac) == "Blue Lantern.flac")
        #expect(FileNaming.fileName(title: "Blue Lantern", extension: .m4a) == "Blue Lantern.m4a")
        #expect(FileNaming.legacyFileName(title: "Blue Lantern", extension: .flac) == "Blue Lantern.flac")
        #expect(FileNaming.existingFileCandidates(title: "Blue Lantern") == ["Blue Lantern.flac", "Blue Lantern.m4a"])
    }

    @Test func unsafeCharactersBecomeUnderscoresExactlyAsBefore() {
        let title = #"AC/DC: "Live" *?<>|\ Night"#
        #expect(FileNaming.stem(title: title) == "AC_DC_ _Live_ ______ Night")
        #expect(FileNaming.stem(title: title) == FileNaming.legacyStem(title: title))
    }

    @Test func titlesThatSanitiseAlikeShareAName() {
        // Kept from the Electron app; the clash policy is card G2-5's, pending.
        #expect(FileNaming.stem(title: "Night/Day") == FileNaming.stem(title: "Night:Day"))
    }

    @Test func whitespaceRunsCollapseAndEndsAreTrimmedAsBefore() {
        let title = "  Blue\t\tLantern\n(Live)\u{00A0} "
        #expect(FileNaming.stem(title: title) == "Blue Lantern (Live)")
        #expect(FileNaming.legacyStem(title: title) == "Blue Lantern (Live)")
    }

    @Test func ideographicSpaceCollapsesLikeJavaScript() {
        #expect(FileNaming.stem(title: "夜の\u{3000}灯台") == "夜の 灯台")
        #expect(FileNaming.legacyStem(title: "夜の\u{3000}灯台") == "夜の 灯台")
    }

    @Test func missingOrEmptyTitleIsUnknown() {
        #expect(FileNaming.stem(title: nil) == "unknown")
        #expect(FileNaming.stem(title: "") == "unknown")
        #expect(FileNaming.legacyStem(title: nil) == "unknown")
        #expect(FileNaming.legacyStem(title: "") == "unknown")
    }

    @Test func spacesOnlyTitleIsUnknownNotAHiddenFile() {
        #expect(FileNaming.fileName(title: "   ", extension: .flac) == "unknown.flac")
        // The old app wrote ".flac"; it is still looked for.
        #expect(FileNaming.legacyFileName(title: "   ", extension: .flac) == ".flac")
        #expect(FileNaming.existingFileCandidates(title: "   ") == ["unknown.flac", "unknown.m4a", ".flac", ".m4a"])
    }

    @Test func leadingDotsAreRemovedSoTheFileIsntHidden() {
        #expect(FileNaming.fileName(title: "...Ready", extension: .flac) == "Ready.flac")
        #expect(FileNaming.stem(title: ". . .Ready") == "Ready")
        #expect(FileNaming.stem(title: "...") == "unknown")
        #expect(FileNaming.existingFileCandidates(title: "...Ready") == ["Ready.flac", "Ready.m4a", "...Ready.flac", "...Ready.m4a"])
    }

    @Test func dotsInsideOrAtTheEndStay() {
        #expect(FileNaming.stem(title: "Mr. Brightside...") == "Mr. Brightside...")
    }

    @Test func controlCharactersAreRemoved() {
        #expect(FileNaming.stem(title: "Blue\u{0001}Lantern\u{007F}\u{0085}\u{009F}") == "BlueLantern")
        #expect(FileNaming.stem(title: "Blue \u{0001} Lantern") == "Blue Lantern")
        // The old spelling kept them.
        #expect(FileNaming.legacyStem(title: "Blue\u{0001}Lantern") == "Blue\u{0001}Lantern")
    }

    @Test func zeroWidthJoinersAndVariationSelectorsStay() {
        // Joiners and variation selectors hold emoji and scripts together.
        let family = "\u{1F469}\u{200D}\u{1F467}"
        #expect(bytes(FileNaming.stem(title: "Song \(family)")) == bytes("Song \(family)"))
        #expect(bytes(FileNaming.stem(title: "\u{0646}\u{200C}\u{0627} \u{2764}\u{FE0F}")) == bytes("\u{0646}\u{200C}\u{0627} \u{2764}\u{FE0F}"))
    }

    @Test func zeroWidthSpacesAreRemovedSoNamesDontLookAlike() {
        // G2-X6: "Blue\u{200B}Lantern.flac" looked identical to "BlueLantern.flac".
        #expect(FileNaming.stem(title: "Blue\u{200B}Lantern") == "BlueLantern")
        #expect(FileNaming.stem(title: "Blue\u{2060}Lan\u{180E}tern") == "BlueLantern")
        #expect(FileNaming.stem(title: "Blue \u{200B} Lantern") == "Blue Lantern")
        // The old app's file is still looked for.
        #expect(FileNaming.existingFileCandidates(title: "Blue\u{200B}Lantern") == [
            "BlueLantern.flac", "BlueLantern.m4a", "Blue\u{200B}Lantern.flac", "Blue\u{200B}Lantern.m4a",
        ])
    }

    @Test func namesAreComposedNFC() {
        let decomposed = "Beyonce\u{0301}"
        #expect(bytes(FileNaming.stem(title: decomposed)) == bytes("Beyonc\u{00E9}"))
    }

    @Test func decomposedTitleStillLooksForTheOldDecomposedFile() {
        let decomposed = "Beyonce\u{0301}"
        let candidates = FileNaming.existingFileCandidates(title: decomposed)
        #expect(candidates.map(bytes) == [
            bytes("Beyonc\u{00E9}.flac"), bytes("Beyonc\u{00E9}.m4a"),
            bytes("Beyonce\u{0301}.flac"), bytes("Beyonce\u{0301}.m4a"),
        ])
    }

    @Test func longTitleIsCappedLeavingRoomForSuffixes() {
        let stem = FileNaming.stem(title: String(repeating: "a", count: 300))
        #expect(stem.utf8.count == FileNaming.maxStemBytes)
        // The longest name the app may write: a hidden partial download.
        #expect(".\(stem).flac.part".utf8.count <= FileNaming.maxNameBytes)
    }

    @Test func longJapaneseTitleIsCutAtAWholeCharacter() {
        let stem = FileNaming.stem(title: String(repeating: "夜", count: 100))
        #expect(stem == String(repeating: "夜", count: FileNaming.maxStemBytes / 3))
    }

    @Test func emojiClustersAreNeverSplit() {
        let family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}" // 18 bytes
        let stem = FileNaming.stem(title: String(repeating: family, count: 20))
        #expect(stem.utf8.count <= FileNaming.maxStemBytes)
        #expect(stem.utf8.count % family.utf8.count == 0)
    }

    @Test func capAlsoFitsTheDecomposedSpelling() {
        let stem = FileNaming.stem(title: String(repeating: "\u{00E9}", count: 100)) // 200 bytes composed, 300 decomposed
        #expect(stem.decomposedStringWithCanonicalMapping.utf8.count <= FileNaming.maxStemBytes)
        #expect(stem.count == FileNaming.maxStemBytes / 3)
    }

    @Test func cutNeverLeavesATrailingSpace() {
        let title = String(repeating: "a", count: FileNaming.maxStemBytes - 1) + " bcd"
        let stem = FileNaming.stem(title: title)
        #expect(stem == String(repeating: "a", count: FileNaming.maxStemBytes - 1))
    }

    @Test func oldSpellingWithANULIsNotLookedFor() {
        #expect(FileNaming.existingFileCandidates(title: "Blue\u{0}Lantern") == ["BlueLantern.flac", "BlueLantern.m4a"])
    }

    @Test func oldSpellingTooLongToHaveBeenSavedIsNotLookedFor() {
        let candidates = FileNaming.existingFileCandidates(title: String(repeating: "a", count: 300))
        #expect(candidates.count == 2)
        #expect(candidates.allSatisfy { $0.utf8.count <= FileNaming.maxNameBytes })
    }

    @Test func nameComesFromTheTitleAlone() {
        // Rule 3, literal (cards G2-5 and G2-6 pending): no artist, version
        // or track number in the name.
        #expect(FileNaming.nameSource(title: "Blue Lantern") == "Blue Lantern")
        #expect(FileNaming.nameSource(title: nil) == "")
    }
}
