import Foundation
import Synchronization
import Testing
@testable import RobogearsCore

@Suite("Track download parts")
struct TrackDownloadPartsTests {
    // MARK: Tags (2.7, reference B11)

    private func track(_ json: Data) throws -> TIDALTrack {
        try JSONDecoder().decode(TIDALTrack.self, from: json)
    }

    @Test func theTitleTagCarriesTheVersion() {
        #expect(TrackTagging.titleTag(title: "Blue Lantern", version: "Radio Edit") == "Blue Lantern (Radio Edit)")
    }

    @Test func aVersionAlreadyInTheTitleIsNeverDoubledWhateverItsCase() {
        #expect(TrackTagging.titleTag(title: "Blue Lantern (radio edit)", version: "Radio Edit") == "Blue Lantern (radio edit)")
        #expect(TrackTagging.titleTag(title: "Blue Lantern - 2011 REMASTER", version: "2011 Remaster") == "Blue Lantern - 2011 REMASTER")
    }

    @Test func aVersionThatIsOnlyPartOfAWordStillGoesIn() {
        // "Edit" inside "Meditation" is not the edition (the queue's rule, G3-12).
        #expect(TrackTagging.titleTag(title: "Meditation", version: "Edit") == "Meditation (Edit)")
    }

    @Test func noVersionLeavesTheTitleAlone() {
        #expect(TrackTagging.titleTag(title: "Blue Lantern", version: nil) == "Blue Lantern")
        #expect(TrackTagging.titleTag(title: "Blue Lantern", version: "  ") == "Blue Lantern")
        #expect(TrackTagging.titleTag(title: nil, version: nil) == nil)
    }

    @Test func tagsFollowTheElectronAppsFieldsAndFallbacks() throws {
        let tags = TrackTagging.tags(
            for: try track(TrackDLFixtures.trackJSON(version: "Extended Mix")),
            album: try JSONDecoder().decode(TIDALAlbum.self, from: TrackDLFixtures.albumJSON())
        )
        #expect(tags == FLACTags(
            title: "Blue Lantern (Extended Mix)",
            artist: "Placeholder Artist, Second Example",
            album: "Harbour Lights",
            albumArtist: "Various Artists",
            trackNumber: 3,
            discNumber: 2,
            year: "1985",
            copyright: "(P) 1985 Album Copyright",
            isrc: "ZZX001100003"
        ))
    }

    @Test func withoutAlbumDetailsTheTracksOwnFieldsFillIn() throws {
        let tags = TrackTagging.tags(for: try track(TrackDLFixtures.trackJSON()), album: nil)
        #expect(tags.albumArtist == "Placeholder Artist")
        #expect(tags.year == "2011")
        #expect(tags.copyright == "2011 Track Copyright")
    }

    @Test func theYearFallsBackToTheStreamStartDate() throws {
        let tags = TrackTagging.tags(for: try track(TrackDLFixtures.trackJSON(releaseDate: nil)), album: nil)
        #expect(tags.year == "2014")
    }

    @Test func emptyFieldsAreLeftOutRatherThanWrittenEmpty() throws {
        let tags = TrackTagging.tags(for: try track(TrackDLFixtures.trackJSON(isrc: "", copyright: nil)), album: nil)
        #expect(tags.isrc == nil)
        #expect(tags.copyright == nil)
    }

    @Test func aRowsIdentityMatchesWhatTheDownloadWritesForTheSameSong() throws {
        let request = TrackDownloadRequest(
            rowID: UUID(), tidalID: 1, title: "Blue Lantern", version: "Extended Mix",
            artist: "Placeholder Artist, Second Example", isrc: "ZZX001100003", folder: URL(fileURLWithPath: "/tmp")
        )
        let written = TrackTagging.tags(for: try track(TrackDLFixtures.trackJSON(version: "Extended Mix")), album: nil)
        let identity = TrackTagging.identity(of: request)
        #expect(identity.title == written.title)
        #expect(identity.artist == written.artist)
        #expect(identity.isrc == written.isrc)
    }

    // MARK: Space (2.20)

    @Test func aFourMinuteHiResTrackNeedsRoughlyTheRoomDecisionFourQuotes() {
        // 2.20 quotes "roughly 330 MB for a 4-minute Hi-Res track".
        let unknown = DiskSpace.estimatedTrackBytes(durationSeconds: 240, isFLAC: true, bitDepth: nil, sampleRate: nil)
        let needed = DiskSpace.requiredFreeBytes(forTrackBytes: unknown)
        #expect(needed > 300_000_000 && needed < 420_000_000)
    }

    @Test func theEstimateUsesTheStreamsBitDepthAndRateWhenTIDALSaysThem() {
        let cd = DiskSpace.estimatedTrackBytes(durationSeconds: 100, isFLAC: true, bitDepth: 16, sampleRate: 44100)
        #expect(abs(Double(cd) - 100 * 16 * 44100 * 2 / 8 * 0.7) <= 1)
        let aac = DiskSpace.estimatedTrackBytes(durationSeconds: 100, isFLAC: false, bitDepth: 24, sampleRate: 96000)
        #expect(aac == 4_000_000)
    }

    @Test func aTrackWithNoListedLengthIsAssumedLong() {
        let unknown = DiskSpace.estimatedTrackBytes(durationSeconds: nil, isFLAC: false, bitDepth: nil, sampleRate: nil)
        #expect(unknown == 600 * 40_000)
    }

    @Test func theShortfallIsWhatTwiceTheTrackNeedsBeyondTheFreeRoom() {
        #expect(DiskSpace.shortfall(trackBytes: 100, available: 150) == 50)
        #expect(DiskSpace.shortfall(trackBytes: 100, available: 200) == nil)
        #expect(DiskSpace.shortfall(trackBytes: 100, available: nil) == nil)
    }

    @Test func theRealDiskReportsItsFreeRoom() {
        #expect((DiskSpace.availableBytes(at: FileManager.default.temporaryDirectory) ?? 0) > 0)
    }

    // MARK: The length check (2.2)

    private func report(declared: Int64, decoded: Int64?, error: String? = nil, rate: Double = 44100) -> AudioProbe.Report {
        AudioProbe.Report(
            formatID: "flac", sampleRate: rate, channelCount: 2, sourceBitDepth: 16,
            declaredFrames: declared, decodedFrames: decoded, decodeError: error
        )
    }

    @Test func aFileThatStopsBeforeItsDeclaredEndFailsEvenWhenTIDALsLengthIsClose() {
        let check = TrackDownloader.checkLength(report(declared: 44100, decoded: 30000, error: "-39"), tidalSeconds: 1)
        #expect(check == .mismatch(.lengthMismatch(fileSeconds: 30000.0 / 44100, tidalSeconds: 1)))
    }

    @Test func aCompleteFileWithinTwoSecondsOfTIDALPasses() {
        #expect(TrackDownloader.checkLength(report(declared: 44100 * 243, decoded: 44100 * 243), tidalSeconds: 245) == .fine)
    }

    @Test func longTracksGetOnePercentOfLeeway() {
        // 600 s listed: 1 % is 6 s, more than 2 s.
        #expect(TrackDownloader.checkLength(report(declared: 44100 * 595, decoded: 44100 * 595), tidalSeconds: 600) == .fine)
        #expect(TrackDownloader.checkLength(report(declared: 44100 * 593, decoded: 44100 * 593), tidalSeconds: 600)
            == .mismatch(.lengthMismatch(fileSeconds: 593, tidalSeconds: 600)))
    }

    @Test func aCompleteFileFarFromTIDALsLengthFails() {
        #expect(TrackDownloader.checkLength(report(declared: 44100 * 30, decoded: 44100 * 30), tidalSeconds: 245)
            == .mismatch(.lengthMismatch(fileSeconds: 30, tidalSeconds: 245)))
    }

    @Test func withoutATIDALLengthOnlyTheFilesOwnCheckApplies() {
        #expect(TrackDownloader.checkLength(report(declared: 44100 * 30, decoded: 44100 * 30), tidalSeconds: nil) == .fine)
        #expect(TrackDownloader.checkLength(report(declared: 44100 * 30, decoded: 44100 * 30), tidalSeconds: 0) == .fine)
    }

    @Test func aFileThatDoesntStateItsLengthIsNeverCalledDamaged() {
        #expect(TrackDownloader.checkLength(report(declared: 0, decoded: 0), tidalSeconds: 245) == .cannotJudge)
    }

    // MARK: Errors in the row's terms (1.4, 1.6, 1.7, 2.15)

    /// What the downloader turns `error` into, through the same entry point
    /// it uses for every failure.
    private func row(_ error: any Error, _ step: TrackDownloadStep) -> TrackDownloadError? {
        TrackDownloadFailures.mapped(error, during: step) as? TrackDownloadError
    }

    @Test func temporaryProblemsWithTheAlbumOrCoverHaveTheirOwnReasons() {
        let timeout = RequestError.offline(detail: RequestError.offlineDetail(for: .timedOut))
        #expect(row(RequestError.server(status: 503), .album) == .albumDetailsUnavailable)
        #expect(row(RequestError.busy(retryAfter: nil), .cover) == .coverUnavailable)
        #expect(row(timeout, .album) == .albumDetailsUnavailable)
        #expect(row(timeout, .cover) == .coverUnavailable)
        // Elsewhere a busy TIDAL is "busy", and no internet pauses the batch.
        #expect(row(RequestError.server(status: 500), .playback) == .busy)
        #expect(row(RequestError.busy(retryAfter: nil), .audio) == .busy)
        let noInternet = RequestError.offline(detail: RequestError.offlineDetail(for: .notConnectedToInternet))
        #expect(row(noInternet, .cover) == .offline)
        #expect(row(timeout, .playback) == .offline)
    }

    @Test func everySignInProblemStopsTheBatchAsSignInRejected() {
        #expect(row(TokenError.signInInvalid, .details) == .signInRejected)
        #expect(row(TokenError.notSignedIn, .playback) == .signInRejected)
        #expect(row(RequestError.unauthorized(subStatus: 11002), .playback) == .signInRejected)
    }

    @Test func aCDNThatAnswers401IsALinkThatStoppedWorkingNotTheSignIn() {
        let refused = RequestError.unauthorized(subStatus: nil)
        #expect(row(refused, .audio) == .notAvailable(reason: TrackDownloadFailures.streamLinkFailed))
        #expect(row(refused, .cover) == .coverUnavailable)
        // TIDAL's own calls keep the rule: a 401 there is the sign-in (1.6).
        for step in [TrackDownloadStep.details, .album, .playback] {
            #expect(row(refused, step) == .signInRejected)
        }
    }

    @Test func cancellationAndRowErrorsPassThroughUnchanged() {
        #expect(TrackDownloadFailures.mapped(CancellationError(), during: .audio) is CancellationError)
        #expect(row(TrackDownloadError.previewOnly, .saving) == .previewOnly)
    }

    @Test func onlyAClearFourHundredCountsAsTIDALsRefusal() {
        #expect(TrackDownloadFailures.isClearRefusal(.notFound(subStatus: nil)))
        #expect(TrackDownloadFailures.isClearRefusal(.forbidden(subStatus: 4033)))
        #expect(TrackDownloadFailures.isClearRefusal(.unexpectedStatus(410, subStatus: nil)))
        #expect(!TrackDownloadFailures.isClearRefusal(.unexpectedStatus(204, subStatus: nil)))
        #expect(!TrackDownloadFailures.isClearRefusal(.unauthorized(subStatus: nil)))
        #expect(!TrackDownloadFailures.isClearRefusal(.busy(retryAfter: nil)))
        #expect(!TrackDownloadFailures.isClearRefusal(.server(status: 503)))
        #expect(!TrackDownloadFailures.isClearRefusal(.offline(detail: "no internet connection")))
    }

    @Test func aFullDiskIsRecognisedHoweverTheFileSystemSaysIt() {
        #expect(TrackDownloadFailures.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(TrackDownloadFailures.isOutOfSpace(POSIXError(.EDQUOT)))
        #expect(TrackDownloadFailures.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(TrackDownloadFailures.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
        ])
        #expect(TrackDownloadFailures.isOutOfSpace(wrapped))
        #expect(!TrackDownloadFailures.isOutOfSpace(POSIXError(.EACCES)))
        #expect(!TrackDownloadFailures.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
    }

    @Test func aFullDiskKeepsItsMeaningThroughEveryStepSoItCanStopTheBatch() {
        for step in [TrackDownloadStep.audio, .cover, .saving] {
            #expect(TrackDownloadFailures.mapped(POSIXError(.ENOSPC), during: step) is POSIXError)
            #expect(TrackDownloadFailures.isOutOfSpace(TrackDownloadFailures.mapped(CocoaError(.fileWriteOutOfSpace), during: step)))
        }
        // Any other write failure is this track's own.
        guard case .writeFailed? = row(POSIXError(.EACCES), .audio) else {
            Issue.record("a refused write wasn't a failed save")
            return
        }
    }

    // MARK: The CDN's answers (2.15, 1.7)

    @Test func aCDNErrorAnswerIsJudgedByItsStatusWhateverItsBody() {
        let notFound = HTTPResponse(status: 404, headers: ["Content-Type": "text/html"], body: Data("<html><body>Not Found</body></html>".utf8))
        #expect(notFound.networkInterference(expecting: .media) == nil)
        #expect(throws: RequestError.notFound(subStatus: nil)) { try notFound.requireOK(expecting: .media) }
        let expired = HTTPResponse(
            status: 403, headers: ["Content-Type": "application/xml"],
            body: Data(#"<?xml version="1.0"?><Error><Code>AccessDenied</Code></Error>"#.utf8)
        )
        #expect(throws: RequestError.forbidden(subStatus: nil)) { try expired.requireOK(expecting: .media) }
        // A redirect the client refused is the CDN's answer too.
        let refused = HTTPResponse(status: 302, headers: ["Location": "http://edge.example.test/a"], body: Data())
        #expect(throws: RequestError.unexpectedStatus(302, subStatus: nil)) { try refused.requireOK(expecting: .media) }
        // TIDAL's API keeps its rule: a web page or a redirect there is the network.
        #expect(notFound.networkInterference(expecting: .data) == .offline(detail: HTTPResponse.webPageDetail))
        #expect(refused.networkInterference(expecting: .data) != nil)
    }

    @Test func aWebPageInsteadOfAudioOrA511StillReadsAsTheNetworkInTheWay() {
        let portal = HTTPResponse(status: 200, headers: [:], body: Data("  <html>Log in to the Wi-Fi</html>".utf8))
        #expect(portal.networkInterference(expecting: .media) == .offline(detail: HTTPResponse.webPageDetail))
        let authenticate = HTTPResponse(status: 511, headers: [:], body: Data())
        #expect(authenticate.networkInterference(expecting: .media) == .offline(detail: HTTPResponse.webPageDetail))
        // Audio the CDN labels as a web page is still audio.
        let audio = HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("fLaC".utf8))
        #expect(audio.networkInterference(expecting: .media) == nil)
    }

    @Test func mediaRedirectsAreFollowedUpToFiveTimesAndOnlyToSecureAddresses() {
        let secure = URLRequest(url: URL(string: "https://edge.example.test/a")!)
        let plain = URLRequest(url: URL(string: "http://edge.example.test/a")!)
        #expect(MediaRedirects.limit == 5)
        #expect((0..<MediaRedirects.limit).allSatisfy { MediaRedirects.follows(secure, afterHops: $0) })
        #expect(!MediaRedirects.follows(secure, afterHops: MediaRedirects.limit))
        #expect(!MediaRedirects.follows(plain, afterHops: 0))
        #expect(AudioFetcher.request(TrackDLFixtures.directURL).expectedBody == .media)
    }

    // MARK: Reading the download for tagging (2.19)

    @Test func theDownloadIsMappedOnlyOnAFixedInternalDisk() {
        #expect(TrackDownloader.readingOptions(isLocal: true, isInternal: true, isRemovable: false, isEjectable: false) == .alwaysMapped)
        // An external drive, an SD card in the Mac's own slot, a disk
        // image, a network share, and a disk that can't say.
        #expect(TrackDownloader.readingOptions(isLocal: true, isInternal: false, isRemovable: false, isEjectable: true) == [])
        #expect(TrackDownloader.readingOptions(isLocal: true, isInternal: true, isRemovable: true, isEjectable: true) == [])
        #expect(TrackDownloader.readingOptions(isLocal: true, isInternal: true, isRemovable: false, isEjectable: true) == [])
        #expect(TrackDownloader.readingOptions(isLocal: false, isInternal: false, isRemovable: false, isEjectable: false) == [])
        #expect(TrackDownloader.readingOptions(isLocal: nil, isInternal: nil, isRemovable: nil, isEjectable: nil) == [])
    }

    // MARK: Notes

    @Test func notesAppearOnceWithTheMovesNewNameReplacingThePlannedOne() {
        let merged = TrackDownloader.mergedNotes(
            pipeline: [.savedAsAAC, .withoutCoverArt],
            decision: [.savedUnderAnotherName(takenName: "A.m4a"), .savedNextToAAC(aacName: "B.m4a")],
            move: [.savedUnderAnotherName(takenName: "C.m4a"), .withoutCoverArt]
        )
        #expect(merged == [.savedAsAAC, .withoutCoverArt, .savedNextToAAC(aacName: "B.m4a"), .savedUnderAnotherName(takenName: "C.m4a")])
    }

    // MARK: Temporary folders (2.2)

    @Test func aTemporaryFolderIsOnTheSameDiskButNeverInsideTheDownloadFolder() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = TemporaryDownloads(registryFile: base.appendingPathComponent("list.json"))

        let made = try registry.makeFolder(near: base)
        defer { registry.remove(made) }

        #expect(Folders.relationship(of: made, to: base) == .other)
        let volume = { (url: URL) in try url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject }
        #expect(try volume(made) == volume(base))
        #expect(registry.registered.map(\.path) == [made.path])
    }

    @Test func removingATemporaryFolderDeletesItAndTakesItOffTheList() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = TemporaryDownloads(registryFile: base.appendingPathComponent("list.json"))
        let made = try registry.makeFolder(near: base)
        try Data("audio".utf8).write(to: made.appendingPathComponent("download.flac"))

        registry.remove(made)

        #expect(!FileManager.default.fileExists(atPath: made.path))
        #expect(registry.registered.isEmpty)
        #expect(TemporaryDownloads(registryFile: base.appendingPathComponent("list.json")).registered.isEmpty)
    }

    @Test func theNextLaunchSweepsFoldersACrashLeftBehind() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let listFile = base.appendingPathComponent("list.json")
        let crashed = TemporaryDownloads(registryFile: listFile)
        let leftover = try crashed.makeFolder(near: base)
        try Data(count: 1000).write(to: leftover.appendingPathComponent("download.flac"))

        let nextLaunch = TemporaryDownloads(registryFile: listFile)
        #expect(nextLaunch.registered.map(\.path) == [leftover.path])
        #expect(nextLaunch.sweepLeftovers() == 1)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(nextLaunch.registered.isEmpty)
        #expect(TemporaryDownloads(registryFile: listFile).registered.isEmpty)
    }

    @Test func aTemporaryFolderOfferedInsideTheDownloadFolderIsRefusedAndRemoved() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        // What macOS offers for a download folder at the top of a drive:
        // the drive's own hidden temporary folder, inside it.
        let inside = base.appendingPathComponent(".TemporaryItems/folders.501/TemporaryItems/work", isDirectory: true)
        let registry = TemporaryDownloads(registryFile: base.appendingPathComponent("list.json")) { _ in
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            return inside
        }

        #expect(throws: TemporaryDownloads.Failure.noTemporaryFolder(detail: "macOS offered a temporary folder inside the download folder")) {
            try registry.makeFolder(near: base)
        }
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(registry.registered.isEmpty)
    }

    @Test func aTemporaryFolderOfferedOnAnotherDiskIsRefusedAndRemoved() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let download = base.appendingPathComponent("TIDAL", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Startup disk/TemporaryItems/work", isDirectory: true)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        // macOS handing back a folder on the startup disk for a download
        // folder on an exFAT or network drive.
        let registry = TemporaryDownloads(
            registryFile: base.appendingPathComponent("list.json"),
            systemFolderNear: { _ in
                try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
                return elsewhere
            },
            sameDisk: { _, _ in false }
        )

        #expect(throws: TemporaryDownloads.Failure.noTemporaryFolder(detail: "macOS offered a temporary folder on another disk")) {
            try registry.makeFolder(near: download)
        }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
        #expect(registry.registered.isEmpty)
    }

    @Test func twoFoldersCountAsOneDiskOnlyWhenBothSaySo() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let inner = base.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        #expect(TemporaryDownloads.onSameDisk(inner, base))
        // A disk that can't say (here, a folder that isn't there) is never
        // assumed to be the same one.
        #expect(!TemporaryDownloads.onSameDisk(base.appendingPathComponent("gone", isDirectory: true), base))
        #expect(!TemporaryDownloads.onSameDisk(inner, base.appendingPathComponent("gone", isDirectory: true)))
    }

    @Test func aDownloadFolderAtTheTopOfADriveIsToldToChooseAFolderOnThatDrive() {
        let drive = URL(fileURLWithPath: "/Volumes/Music SSD", isDirectory: true)
        #expect(DownloadFolderCheck.noTemporaryFolderMessage(for: drive, isDriveRoot: true)
            == "Downloads can't be saved at the top level of “Music SSD”. Create a folder on the drive and choose that instead.")
        #expect(DownloadFolderCheck.noTemporaryFolderMessage(for: drive.appendingPathComponent("TIDAL"), isDriveRoot: false)
            == "The disk with the download folder “TIDAL” doesn't allow the temporary files a download needs. Choose a folder on another disk.")
        #expect(DownloadFolderCheck.isDriveRoot(URL(fileURLWithPath: "/", isDirectory: true)))
        #expect(!DownloadFolderCheck.isDriveRoot(FileManager.default.temporaryDirectory))
    }

    @Test func theSweepNeverDeletesAFolderTheAppDidntMake() throws {
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let precious = base.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: precious.appendingPathComponent("song.flac"))
        let listFile = base.appendingPathComponent("list.json")
        try JSONEncoder().encode([precious.path]).write(to: listFile)

        let registry = TemporaryDownloads(registryFile: listFile)
        #expect(registry.sweepLeftovers() == 0)

        #expect(FileManager.default.fileExists(atPath: precious.appendingPathComponent("song.flac").path))
        #expect(registry.registered.isEmpty)
    }

    // MARK: Streaming download (HTTPClient)

    private func audioClient(_ routes: TrackDLRoutes) -> (TrackDLServer, HTTPClient, TIDALTestClock) {
        let server = TrackDLServer(routes)
        let clock = TIDALTestClock()
        return (server, server.makeClient(limits: .audio, clock: clock), clock)
    }

    private static let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    @Test func aDirectDownloadStreamsTheWholeBodyToTheFile() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .bytes(Self.body, chunks: 50) }
        let (server, client, _) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("download.flac")
        let seen = TrackDLProgress()

        let response = try await client.download(AudioFetcher.request(TrackDLFixtures.directURL), to: file) { received, expected in
            #expect(expected == Int64(Self.body.count))
            seen.append(Double(received))
        }

        #expect(response.status == 200)
        #expect(try Data(contentsOf: file) == Self.body)
        #expect(seen.values.last == Double(Self.body.count))
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.headers["User-Agent"] == "okhttp/5.3.2")
        #expect(server.requests.first?.headers["Accept-Encoding"] == "identity")
    }

    @Test func aCompressedBodyIsNotMeasuredAgainstItsContentLength() async throws {
        // URLSession hands over a compressed body decoded, so its length and
        // the Content-Length never agree; that must not read as a cut-off.
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in
            .data(status: 200, headers: ["Content-Length": "1200", "Content-Encoding": "gzip"], body: Self.body, chunks: 8)
        }
        let (server, client, _) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("download.flac")

        _ = try await client.download(AudioFetcher.request(TrackDLFixtures.directURL), to: file)

        #expect(try Data(contentsOf: file) == Self.body)
        #expect(server.requests.count == 1)
    }

    @Test func aBodyCutShortOfItsContentLengthIsRetriedFromTheStart() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, attempt in
            attempt == 0
                ? .data(status: 200, headers: ["Content-Length": String(Self.body.count)], body: Self.body.prefix(5000), chunks: 2)
                : .bytes(Self.body)
        }
        let (server, client, clock) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("download.flac")

        _ = try await client.download(AudioFetcher.request(TrackDLFixtures.directURL), to: file)

        #expect(try Data(contentsOf: file) == Self.body)
        #expect(server.requests.count == 2)
        #expect(clock.sleeps == [.seconds(1)])
    }

    @Test func aServerErrorIsRetriedThenBusyGivesUpAndLeavesNoFile() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .status(503) }
        let (server, client, clock) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("download.flac")

        await #expect(throws: RequestError.server(status: 503)) {
            _ = try await client.download(AudioFetcher.request(TrackDLFixtures.directURL), to: file)
        }
        #expect(server.requests.count == 5)
        #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRefusalIsReturnedAtOnceWithItsBodyAndNoFile() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .status(403, #"{"status":403}"#) }
        let (server, client, _) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("download.flac")

        let response = try await client.download(AudioFetcher.request(TrackDLFixtures.directURL), to: file)

        #expect(response.status == 403)
        #expect(response.text == #"{"status":403}"#)
        #expect(server.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aDownloadNeverReplacesAnExistingFile() async throws {
        let (server, client, _) = audioClient(TrackDLRoutes())
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("Blue Lantern.flac")
        try Data("mine".utf8).write(to: file)

        await #expect(throws: POSIXError.self) {
            _ = try await client.download(AudioFetcher.request(TrackDLFixtures.directURL), to: file)
        }
        #expect(try Data(contentsOf: file) == Data("mine".utf8))
        #expect(server.requests.isEmpty)
    }

    @Test func aSignInPageAnsweringForTheCDNReadsAsOffline() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .data(status: 200, headers: [:], body: Data("<html><body>Log in to the Wi-Fi</body></html>".utf8), chunks: 1) }
        let (_, client, _) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let fetcher = AudioFetcher(client: client, retry: .standard)

        do {
            try await fetcher.fetch(.direct(TrackDLFixtures.directURL), to: base.appendingPathComponent("a.flac"), estimatedBytes: 1) { _ in }
            Issue.record("a web page was taken as audio")
        } catch let RequestError.offline(detail) {
            #expect(detail.contains("web page"))
        }
    }

    // MARK: Segments

    @Test func segmentsAreFetchedEightAtATimeAndWrittenStrictlyInOrder() async throws {
        let inFlight = Mutex((now: 0, most: 0))
        var routes = TrackDLRoutes()
        routes.audio = { path, _ in
            inFlight.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            // Later segments answer sooner, so they arrive out of order.
            let number = Int(path.split(separator: "/").last ?? "") ?? 0
            Thread.sleep(forTimeInterval: Double(40 - number) / 4000)
            inFlight.withLock { $0.now -= 1 }
            return .bytes(Data("[\(number)]".utf8))
        }
        let (server, client, _) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("download.m4a")
        let urls = (0...30).map { URL(string: "https://audio.example.test/seg/\($0)")! }
        let fetcher = AudioFetcher(client: client, retry: .standard)
        let seen = TrackDLProgress()

        try await fetcher.fetch(.segments(initialization: urls[0], media: Array(urls.dropFirst())), to: file, estimatedBytes: 0) {
            seen.append($0)
        }

        let expected = (0...30).map { "[\($0)]" }.joined()
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == expected)
        let most = inFlight.withLock { $0.most }
        #expect(most <= AudioFetcher.segmentsInFlight)
        #expect(most > 1)
        #expect(server.requests.count == 31)
        #expect(seen.values.last == 1)
    }

    @Test func aFailedSegmentStopsTheOthersFromBeingFetched() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { path, _ in
            if path.hasSuffix("/seg/3") { return .status(404) }
            Thread.sleep(forTimeInterval: 0.002)
            return .bytes(Data("x".utf8))
        }
        let (server, client, _) = audioClient(routes)
        let base = try AudioFixture.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let urls = (0...200).map { URL(string: "https://audio.example.test/seg/\($0)")! }
        let fetcher = AudioFetcher(client: client, retry: .standard)

        await #expect(throws: RequestError.notFound(subStatus: nil)) {
            try await fetcher.fetch(
                .segments(initialization: urls[0], media: Array(urls.dropFirst())),
                to: base.appendingPathComponent("d.m4a"), estimatedBytes: 0
            ) { _ in }
        }
        // The read-ahead window bounds what was started before the failure.
        #expect(server.requests.count < 4 + AudioFetcher.readAhead + AudioFetcher.segmentsInFlight)
    }

    // MARK: Progress

    @Test func progressMovesOnlyUpInWholePercents() {
        let seen = TrackDLProgress()
        let throttle = ProgressThrottle { seen.append($0) }
        for step in 0...1000 { throttle.update(Double(step) / 1000) }
        throttle.update(0.5)
        throttle.update(.nan)

        #expect(seen.values.count == 101)
        #expect(seen.values.first == 0)
        #expect(seen.values.last == 1)
        #expect(zip(seen.values, seen.values.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: Background work

    @Test func cancelledBackgroundWorkReturnsAtOnceAndCleansUpAfterwards() async throws {
        let gate = TIDALFlag()
        let cleaned = TIDALFlag()
        let task = Task {
            try await BackgroundWork.run({
                while !gate.isSet { Thread.sleep(forTimeInterval: 0.001) }
                return 1
            }, afterAbandon: { cleaned.set() })
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.result.get() }
        #expect(!cleaned.isSet)
        gate.set()
        #expect(try await cleaned.wait(upTo: .seconds(5)))
    }

    @Test func finishedBackgroundWorkHandsBackItsResult() async throws {
        #expect(try await BackgroundWork.run({ 42 }) == 42)
        #expect(try await BackgroundWork.run(async: { 43 }) == 43)
    }

    @Test func cancelledAsyncWorkIsAskedToStopTooAndCleansUpWhenItDoes() async throws {
        let started = TIDALFlag()
        let cleaned = TIDALFlag()
        let task = Task {
            try await BackgroundWork.run(async: {
                started.set()
                // Work that honours cancellation, as an AAC writer should.
                try await Task.sleep(for: .seconds(60))
                return 1
            }, afterAbandon: { cleaned.set() })
        }
        #expect(try await started.wait(upTo: .seconds(5)))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.result.get() }
        #expect(try await cleaned.wait(upTo: .seconds(5)))
    }
}
