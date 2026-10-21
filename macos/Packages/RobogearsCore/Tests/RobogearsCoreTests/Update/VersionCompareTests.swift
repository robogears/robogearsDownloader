import Testing
@testable import RobogearsCore

// The Electron `isNewerVersion` rules (packaging-ci-and-updater.md, item 10)
// plus pre-release ordering.

@Suite("Update version compare")
struct VersionCompareTests {
    @Test func higherPatchIsNewer() {
        #expect(VersionCompare.isNewer("v0.1.31", than: "0.1.30"))
        #expect(VersionCompare.isNewer("0.1.31", than: "0.1.30"))
        #expect(!VersionCompare.isNewer("v0.1.30", than: "0.1.31"))
    }

    @Test func numbersCompareAsNumbersNotText() {
        #expect(VersionCompare.isNewer("0.1.100", than: "0.1.99"))
        #expect(VersionCompare.isNewer("0.10.0", than: "0.9.9"))
    }

    @Test func equalIsNotNewer() {
        #expect(!VersionCompare.isNewer("v0.1.30", than: "0.1.30"))
    }

    @Test func missingPartsCountAsZero() {
        #expect(!VersionCompare.isNewer("0.2", than: "0.2.0"))
        #expect(!VersionCompare.isNewer("0.2.0", than: "0.2"))
        #expect(VersionCompare.isNewer("0.2.0.1", than: "0.2"))
        #expect(VersionNumber("0.2") == VersionNumber("0.2.0"))
        #expect(!(VersionNumber("0.2") < VersionNumber("0.2.0")))
        #expect(!(VersionNumber("0.2.0") < VersionNumber("0.2")))
    }

    @Test func swiftAppsFirstVersionIsNewerThanTheLastElectronRelease() {
        // The v0.1.30 updater must be offered the Swift app (card G5-11).
        #expect(VersionCompare.isNewer("v\(RobogearsCore.version)", than: "0.1.30"))
    }

    @Test func onlyALowercaseVIsStripped() {
        // Exact port: "V1.0" reads as 0.0, as parseInt("V1") is NaN.
        #expect(VersionNumber("V1.0").numbers == [0, 0])
        #expect(!VersionCompare.isNewer("V9.0.0", than: "0.1.30"))
    }

    @Test func partsAreReadLikeParseInt() {
        #expect(VersionNumber.parseIntLikeJavaScript("31") == 31)
        #expect(VersionNumber.parseIntLikeJavaScript(" 7") == 7)
        #expect(VersionNumber.parseIntLikeJavaScript("12abc") == 12)
        #expect(VersionNumber.parseIntLikeJavaScript("+5") == 5)
        #expect(VersionNumber.parseIntLikeJavaScript("-3") == -3)
        #expect(VersionNumber.parseIntLikeJavaScript("x1") == nil)
        #expect(VersionNumber.parseIntLikeJavaScript("") == nil)
        #expect(VersionNumber.parseIntLikeJavaScript("99999999999999999999999") == Int.max)
    }

    @Test func tagWithNoNumbersIsNeverNewer() {
        #expect(VersionNumber("latest").numbers == [0])
        #expect(!VersionCompare.isNewer("latest", than: "0.1.30"))
    }

    @Test func emptyPartsReadAsZero() {
        #expect(VersionNumber("1..2").numbers == [1, 0, 2])
    }

    @Test func preReleaseIsOlderThanTheSameRelease() {
        // The Electron code read "0.1.31-rc1" as equal to 0.1.31.
        #expect(!VersionCompare.isNewer("0.1.31-rc1", than: "0.1.31"))
        #expect(VersionCompare.isNewer("0.1.31", than: "0.1.31-rc1"))
        #expect(VersionNumber("0.1.31-rc1") < VersionNumber("0.1.31"))
        #expect(!(VersionNumber("0.1.31") < VersionNumber("0.1.31-rc1")))
        #expect(VersionNumber("0.1.31") != VersionNumber("0.1.31-rc1"))
    }

    @Test func dottedPreReleaseIsNoLongerReadAsAnExtraNumber() {
        // The Electron code read "0.1.31-rc.1" as 0.1.31.1, newer than 0.1.31.
        #expect(!VersionCompare.isNewer("v0.1.31-rc.1", than: "0.1.31"))
    }

    @Test func preReleaseOfANewerVersionIsStillNewerThanTheOldRelease() {
        #expect(VersionCompare.isNewer("0.1.31-rc1", than: "0.1.30"))
    }

    @Test func preReleasesOrderBySemanticVersioningRules() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (older, newer) in zip(ordered, ordered.dropFirst()) {
            #expect(VersionCompare.isNewer(newer, than: older), "\(newer) > \(older)")
            #expect(!VersionCompare.isNewer(older, than: newer), "\(older) < \(newer)")
            #expect(VersionNumber(older) != VersionNumber(newer), "\(older) != \(newer)")
        }
    }

    @Test func buildMetadataIsIgnored() {
        #expect(!VersionCompare.isNewer("0.1.31+build7", than: "0.1.31"))
        #expect(VersionNumber("0.1.31+build7") == VersionNumber("0.1.31"))
    }

    @Test func descriptionShowsWhatWasRead() {
        #expect(VersionNumber("v0.1.31-rc.1").description == "0.1.31-rc.1")
        #expect(VersionNumber("v0.1.31-rc.1").isPreRelease)
        #expect(!VersionNumber("v0.1.31").isPreRelease)
    }
}
