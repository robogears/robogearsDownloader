import Foundation
import Testing
@testable import RobogearsCore

/// Reads a synthetic fixture from Fixtures/tidal.
private func manifestFixture(_ file: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Fixtures/tidal"),
        "missing fixture \(file)"
    )
    return try Data(contentsOf: url)
}

/// Parses a fixture file as TIDAL would send it: base64 inside the playback reply.
private func manifest(
    _ file: String, type: String, quality: String? = "LOSSLESS"
) throws -> TIDALManifest {
    try TIDALManifest(
        manifestMimeType: type,
        base64Manifest: manifestFixture(file).base64EncodedString(),
        audioQuality: quality
    )
}

private func manifest(text: String, type: String, quality: String? = "LOSSLESS") throws -> TIDALManifest {
    try TIDALManifest(
        manifestMimeType: type,
        base64Manifest: Data(text.utf8).base64EncodedString(),
        audioQuality: quality
    )
}

private let dash = "application/dash+xml"
private let bts = "application/vnd.tidal.bts"

/// A minimal one-template MPD around the given timeline and template attributes.
private func mpd(timeline: String, template: String = #"initialization="https://a.example.test/0.mp4" media="https://a.example.test/$Number$.mp4""#) -> String {
    """
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011"><Period><AdaptationSet mimeType="audio/mp4" codecs="flac">
    <SegmentTemplate \(template)><SegmentTimeline>\(timeline)</SegmentTimeline></SegmentTemplate>
    </AdaptationSet></Period></MPD>
    """
}

private func mediaNumbers(_ manifest: TIDALManifest) -> [String] {
    guard case .segments(_, let media) = manifest.location else { return [] }
    return media.map { $0.deletingPathExtension().lastPathComponent }
}

@Suite struct BTSManifestTests {
    @Test func btsManifestGivesOneDirectURLWithCodecAndType() throws {
        let parsed = try manifest("manifest-bts.json", type: bts)
        #expect(parsed.format == .bts)
        #expect(parsed.location == .direct(URL(string:
            "https://audio.example.test/mediatracks/synthetic/0.flac?token=1700000000~c3ludGhldGlj&sig=abc123")!))
        #expect(parsed.mimeType == "audio/flac")
        #expect(parsed.codecs == "flac")
        #expect(parsed.isFLAC)
        #expect(parsed.container == .flac)
        #expect(parsed.requestCount == 1)
    }

    @Test func everyVndTidalVariantIsReadAsJSON() throws {
        // Electron matched the prefix so `.bt`, `.bts` and later variants all work.
        for type in ["application/vnd.tidal.bt", "application/vnd.tidal.bts", "application/vnd.tidal.btx"] {
            #expect(try manifest("manifest-bts.json", type: type).format == .bts)
        }
    }

    @Test func aacOnlyBTSIsSavedAsM4A() throws {
        let parsed = try manifest("manifest-bts-aac.json", type: bts, quality: "HIGH")
        #expect(!parsed.isFLAC)
        #expect(parsed.container == .mp4)
        #expect(parsed.container.fileExtension == "m4a")
        #expect(parsed.container.mimeType == "audio/mp4")
    }

    @Test func encryptedBTSIsRefusedAsCopyProtected() {
        #expect(throws: TIDALManifestError.copyProtected("OLD_AES")) {
            try manifest("manifest-bts-encrypted.json", type: bts)
        }
    }

    @Test func encryptionTypeNoneOrAbsentIsNotProtection() throws {
        #expect(try manifest(text: #"{"urls":["https://a.example.test/x.flac"]}"#, type: bts).isFLAC)
        #expect(throws: Never.self) {
            try manifest(text: #"{"encryptionType":null,"urls":["https://a.example.test/x.flac"]}"#, type: bts)
        }
        #expect(throws: Never.self) {
            try manifest(text: #"{"encryptionType":"none","urls":["https://a.example.test/x.flac"]}"#, type: bts)
        }
    }

    @Test func btsWithoutURLsSaysThereIsNoStream() {
        #expect(throws: TIDALManifestError.noStreamURL) {
            try manifest(text: #"{"mimeType":"audio/flac","urls":[]}"#, type: bts)
        }
        #expect(throws: TIDALManifestError.noStreamURL) {
            try manifest(text: #"{"mimeType":"audio/flac"}"#, type: bts)
        }
    }

    @Test func onlyTheFirstURLIsUsed() throws {
        let parsed = try manifest(
            text: #"{"urls":["https://a.example.test/first.flac","https://a.example.test/second.flac"]}"#, type: bts)
        #expect(parsed.location == .direct(URL(string: "https://a.example.test/first.flac")!))
    }

    @Test func manifestNeverPointsTheDownloaderAtALocalFile() {
        #expect(throws: TIDALManifestError.invalidStreamURL) {
            try manifest(text: #"{"urls":["file:///etc/hosts"]}"#, type: bts)
        }
        #expect(throws: TIDALManifestError.invalidStreamURL) {
            try manifest(text: #"{"urls":["not a link"]}"#, type: bts)
        }
    }

    @Test func brokenJSONIsUnreadable() {
        #expect(throws: TIDALManifestError.unreadableManifest) {
            try manifest(text: "{not json", type: bts)
        }
    }

    @Test func fullPlaybackReplyParsesThroughTheModel() throws {
        let info = try JSONDecoder().decode(TIDALPlaybackInfo.self, from: manifestFixture("playback-bts.json"))
        let parsed = try TIDALManifest(playbackInfo: info)
        #expect(parsed.format == .bts)
        #expect(parsed.isFLAC)
        #expect(info.bitDepth == 16)
    }
}

@Suite struct DASHManifestTests {
    @Test func timelineEntryWithRepeatNMeansNPlusOneSegments() throws {
        // <S r="3"/> is four segments and <S/> one more: five, numbered from 1.
        let parsed = try manifest("manifest-dash.mpd", type: dash)
        #expect(parsed.format == .dash)
        #expect(mediaNumbers(parsed) == ["1", "2", "3", "4", "5"])
        #expect(parsed.requestCount == 6)
    }

    @Test func segmentURLsAreXMLUnescapedAndNumbered() throws {
        let parsed = try manifest("manifest-dash.mpd", type: dash)
        guard case .segments(let initialization, let media) = parsed.location else {
            Issue.record("expected segments")
            return
        }
        #expect(initialization.absoluteString ==
            "https://audio.example.test/mediatracks/synthetic/0.mp4?token=abc&expires=1700000000")
        #expect(media.first?.absoluteString ==
            "https://audio.example.test/mediatracks/synthetic/1.mp4?token=abc&expires=1700000000")
        #expect(media.last?.absoluteString ==
            "https://audio.example.test/mediatracks/synthetic/5.mp4?token=abc&expires=1700000000")
        #expect(!media.contains { $0.absoluteString.contains("&amp;") })
    }

    @Test func dashReadsCodecsAndMimeTypeAndJoinsIntoMP4() throws {
        let parsed = try manifest("manifest-dash.mpd", type: dash, quality: nil)
        #expect(parsed.codecs == "flac")
        #expect(parsed.mimeType == "audio/mp4")
        #expect(parsed.container == .mp4)
        #expect(parsed.isFLAC)   // from the codec, with no quality label at all
    }

    @Test func missingStartNumberStartsAtOne() throws {
        let parsed = try manifest(text: mpd(timeline: #"<S d="1" r="1"/>"#), type: dash)
        #expect(mediaNumbers(parsed) == ["1", "2"])
    }

    @Test func startNumberZeroAndPaddedNumbersAndClosingTagsWork() throws {
        let parsed = try manifest("manifest-dash-relative.mpd", type: dash)
        guard case .segments(let initialization, let media) = parsed.location else {
            Issue.record("expected segments")
            return
        }
        // Relative templates are appended to the (unescaped) BaseURL.
        #expect(initialization.absoluteString == "https://audio.example.test/mediatracks/a&b/init.mp4")
        #expect(media.map(\.lastPathComponent) == ["seg-00000.m4s", "seg-00001.m4s", "seg-00002.m4s"])
    }

    @Test func baseURLOnlyManifestIsOneDirectFileUnescaped() throws {
        // Electron's download parser skipped unescaping here (bug 12), so a
        // signed query with &amp; would have broken the request.
        let parsed = try manifest("manifest-dash-direct.mpd", type: dash)
        #expect(parsed.location == .direct(URL(string:
            "https://audio.example.test/mediatracks/synthetic/whole.flac?token=abc&expires=1700000000")!))
        #expect(parsed.container == .flac)
        #expect(parsed.codecs == "flac")
    }

    @Test func baseURLOnlyManifestIsFLACEvenWhenTheMPDSaysMP4() throws {
        // Both Electron parsers hard-coded audio/flac for a BaseURL-only MPD,
        // whatever its attributes said (download-pipeline.md B7 step 4,
        // main-process-and-ipc.md section 12 step 5).
        let parsed = try manifest("manifest-dash-direct-mp4.mpd", type: dash)
        guard case .direct = parsed.location else {
            Issue.record("expected one direct file")
            return
        }
        #expect(parsed.mimeType == "audio/mp4")   // reported as declared
        #expect(parsed.container == .flac)
        #expect(parsed.container.fileExtension == "flac")
        #expect(parsed.container.mimeType == "audio/flac")
    }

    @Test func onlyTheFirstSegmentTemplateCounts() throws {
        // Electron counted every <S> in the document: 3 + 10 segments would
        // have been requested from the first template's URLs.
        let parsed = try manifest("manifest-dash-two-representations.mpd", type: dash)
        guard case .segments(let initialization, let media) = parsed.location else {
            Issue.record("expected segments")
            return
        }
        #expect(initialization.absoluteString == "https://audio.example.test/hi/0.mp4")
        #expect(media.count == 3)
        #expect(media.allSatisfy { $0.absoluteString.hasPrefix("https://audio.example.test/hi/") })
    }

    @Test func contentProtectionIsTreatedAsCopyProtected() {
        #expect(throws: TIDALManifestError.copyProtected("ContentProtection")) {
            try manifest("manifest-dash-protected.mpd", type: dash)
        }
    }

    @Test func templateWithoutTimelineHasNoSegments() {
        #expect(throws: TIDALManifestError.noSegments) {
            try manifest(text: mpd(timeline: ""), type: dash)
        }
    }

    @Test func openEndedRepeatIsRefusedRatherThanCutShort() {
        // r="-1" means "until the end"; Electron counted it as one segment.
        #expect(throws: TIDALManifestError.openEndedTimeline) {
            try manifest(text: mpd(timeline: #"<S d="1" r="-1"/>"#), type: dash)
        }
    }

    @Test func absurdRepeatCountIsRefused() {
        #expect(throws: TIDALManifestError.tooManySegments) {
            try manifest(text: mpd(timeline: #"<S d="1" r="999999999999"/>"#), type: dash)
        }
    }

    @Test func timePlaceholderIsRefusedInsteadOfSentLiterally() {
        let template = #"initialization="https://a.example.test/0.mp4" media="https://a.example.test/$Time$.mp4""#
        #expect(throws: TIDALManifestError.unsupportedTemplate("$Time$")) {
            try manifest(text: mpd(timeline: #"<S d="1"/>"#, template: template), type: dash)
        }
    }

    @Test func missingInitializationOrMediaIsNotATemplate() {
        #expect(throws: TIDALManifestError.missingSegmentTemplate) {
            try manifest(text: mpd(timeline: #"<S d="1"/>"#, template: #"media="https://a.example.test/$Number$.mp4""#), type: dash)
        }
        #expect(throws: TIDALManifestError.missingSegmentTemplate) {
            try manifest(text: "<MPD><Period/></MPD>", type: dash)
        }
    }

    @Test func malformedXMLIsUnreadable() {
        #expect(throws: TIDALManifestError.unreadableManifest) {
            try manifest(text: "<MPD><Period>", type: dash)
        }
    }

    @Test func nonNumericRepeatIsUnreadable() {
        #expect(throws: TIDALManifestError.unreadableManifest) {
            try manifest(text: mpd(timeline: #"<S d="1" r="two"/>"#), type: dash)
        }
    }

    @Test func fullDASHPlaybackReplyParsesThroughTheModel() throws {
        let info = try JSONDecoder().decode(TIDALPlaybackInfo.self, from: manifestFixture("playback-dash.json"))
        let parsed = try TIDALManifest(playbackInfo: info)
        #expect(mediaNumbers(parsed).count == 5)
        #expect(info.sampleRate == 96_000)
    }
}

@Suite struct SegmentTemplateTests {
    @Test func numberIsFilledInEveryPlace() throws {
        #expect(try DASHManifestReader.expand("a/$Number$/b-$Number$", number: 7) == "a/7/b-7")
    }

    @Test func paddedNumberUsesTheGivenWidth() throws {
        #expect(try DASHManifestReader.expand("s$Number%04d$.m4s", number: 12) == "s0012.m4s")
        #expect(try DASHManifestReader.expand("s$Number%02d$.m4s", number: 123) == "s123.m4s")
    }

    @Test func doubledDollarIsALiteralDollar() throws {
        #expect(try DASHManifestReader.expand("price$$5/$Number$", number: 1) == "price$5/1")
    }

    @Test func loneDollarIsKeptAsWritten() throws {
        #expect(try DASHManifestReader.expand("a$b", number: 1) == "a$b")
    }

    @Test func initializationTemplateCannotAskForANumber() {
        #expect(throws: TIDALManifestError.unsupportedTemplate("$Number$")) {
            try DASHManifestReader.expand("init-$Number$.mp4", number: nil)
        }
    }

    @Test func segmentNumbersFollowStartNumberAndRepeats() throws {
        #expect(try DASHManifestReader.segmentNumbers(startNumber: "5", repeats: [nil, "2"]) == [5, 6, 7, 8])
        #expect(try DASHManifestReader.segmentNumbers(startNumber: nil, repeats: ["0"]) == [1])
    }
}

@Suite struct ManifestTypeAndEncodingTests {
    @Test func unknownManifestTypeIsATypedError() {
        #expect(throws: TIDALManifestError.unsupportedType("application/x-unknown")) {
            try manifest("manifest-bts.json", type: "application/x-unknown")
        }
        #expect(throws: TIDALManifestError.unsupportedType(nil)) {
            try TIDALManifest(manifestMimeType: nil, base64Manifest: "e30=", audioQuality: nil)
        }
    }

    @Test func missingOrEmptyManifestSaysSo() {
        #expect(throws: TIDALManifestError.missingManifest) {
            try TIDALManifest(manifestMimeType: bts, base64Manifest: nil, audioQuality: nil)
        }
        #expect(throws: TIDALManifestError.missingManifest) {
            try TIDALManifest(manifestMimeType: bts, base64Manifest: "", audioQuality: nil)
        }
    }

    @Test func dashTypeWithParametersAndOtherCaseIsStillDASH() throws {
        let data = try manifestFixture("manifest-dash.mpd").base64EncodedString()
        let parsed = try TIDALManifest(
            manifestMimeType: "Application/DASH+XML; charset=utf-8", base64Manifest: data, audioQuality: nil)
        #expect(parsed.format == .dash)
    }

    @Test func base64IsDecodedAsForgivinglyAsNode() throws {
        // Node accepts missing padding, line breaks and URL-safe letters.
        let json = #"{"urls":["https://a.example.test/x.flac?q=>>>"]}"#
        let standard = Data(json.utf8).base64EncodedString()
        let unpadded = standard.replacingOccurrences(of: "=", with: "")
        let wrapped = standard.enumerated().map { $0.offset % 20 == 19 ? "\($0.element)\n" : "\($0.element)" }.joined()
        let urlSafe = standard.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        for variant in [standard, unpadded, wrapped, urlSafe] {
            let parsed = try TIDALManifest(manifestMimeType: bts, base64Manifest: variant, audioQuality: nil)
            #expect(parsed.format == .bts)
        }
    }

    @Test func textThatIsNotBase64IsUnreadable() {
        #expect(throws: TIDALManifestError.unreadableEncoding) {
            try TIDALManifest(manifestMimeType: bts, base64Manifest: "!!!", audioQuality: nil)
        }
    }

    @Test func errorMessagesNeverIncludeLinksOrRawReplies() {
        let all: [TIDALManifestError] = [
            .missingManifest, .unreadableEncoding, .unsupportedType("x/y"), .unsupportedType(nil),
            .copyProtected("OLD_AES"), .noStreamURL, .invalidStreamURL, .unreadableManifest,
            .missingSegmentTemplate, .noSegments, .openEndedTimeline, .unsupportedTemplate("$Time$"),
            .tooManySegments,
        ]
        for error in all {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty)
            #expect(!text.contains("http"))
            #expect(!text.contains("{"))
        }
    }

    @Test func describingAManifestNeverPrintsTheSignedLinks() throws {
        let parsed = try manifest("manifest-dash.mpd", type: dash)
        #expect(!parsed.description.contains("http"))
        #expect(!String(describing: parsed).contains("token="))
        #expect(parsed.description.contains("5 segments"))
    }

    @Test func dumpingAManifestOrItsLocationNeverPrintsTheSignedLinks() throws {
        // `dump` and reflecting loggers read the mirror, not the description.
        for file in ["manifest-dash.mpd", "manifest-dash-direct.mpd"] {
            let parsed = try manifest(file, type: dash)
            for text in everyPrintedForm(of: parsed) + everyPrintedForm(of: parsed.location) {
                #expect(!text.contains("http"))
                #expect(!text.contains("token="))
            }
        }
    }
}

@Suite struct FLACDecisionTests {
    @Test func losslessTierLabelsMeanFLACWhateverTheCodecSays() {
        for quality in ["LOSSLESS", "HI_RES_LOSSLESS", "HI_RES"] {
            #expect(TIDALManifest.isFLAC(audioQuality: quality, codecs: "mp4a.40.2", manifestText: ""))
        }
    }

    @Test func codecContainingFlacMeansFLACInAnyCase() {
        #expect(TIDALManifest.isFLAC(audioQuality: "HIGH", codecs: "FLAC", manifestText: ""))
        #expect(TIDALManifest.isFLAC(audioQuality: nil, codecs: "flac", manifestText: ""))
    }

    @Test func codecsAttributeInTheRawTextIsTheLastResort() {
        #expect(TIDALManifest.isFLAC(audioQuality: nil, codecs: nil, manifestText: #"<R codecs="FLAC"/>"#))
        #expect(!TIDALManifest.isFLAC(audioQuality: nil, codecs: nil, manifestText: #"<R codecs="mp4a.40.2"/>"#))
    }

    @Test func aacQualityWithAACCodecIsNotFLAC() {
        #expect(!TIDALManifest.isFLAC(audioQuality: "HIGH", codecs: "mp4a.40.2", manifestText: "{}"))
    }
}
