import Foundation
import Synchronization
import Testing
@testable import RobogearsCore

/// The per-track downloader end to end, on synthetic streams served by a
/// mock server: no network, no TIDAL, no real folders.
@Suite("Track downloader")
struct TrackDownloaderTests {
    // MARK: Each kind of stream

    @Test func aBTSStreamIsSavedAsTaggedFLACUnderItsTitle() async throws {
        let world = try TrackDLWorld()
        defer { world.cleanUp() }

        let outcome = try await world.download(world.request())

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 16, sampleRate: 44100), notes: []))
        #expect(world.savedFiles == ["Blue Lantern.flac"])
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        let layout = try FLACMetadataReader.read(saved)
        let comment = try #require(layout.vorbisComment)
        #expect(comment.values(for: "title") == ["Blue Lantern"])
        #expect(comment.values(for: "artist") == ["Placeholder Artist, Second Example"])
        #expect(comment.values(for: "ALBUMARTIST") == ["Various Artists"])
        #expect(comment.values(for: "date") == ["1985"])
        #expect(comment.values(for: "isrc") == ["ZZX001100003"])
        #expect(layout.pictures.first?.pictureType == FLACPicture.frontCoverType)
        #expect(layout.pictures.first?.data == (try AudioFixture.data("cover.jpg")))
        // The audio frames are TIDAL's, byte for byte.
        #expect(try AudioFixture.frames(ofFLAC: saved) == AudioFixture.frames(ofFLAC: AudioFixture.data("bts-16-44100.flac")))
        // Hi-Res was asked for first and answered, so nothing stepped down.
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS"])
        #expect(world.progress.values.last == 1)
        #expect(world.temporariesAreGone)
    }

    @Test func aDASHStreamIsJoinedInOrderAndSavedAsHiResFLAC() async throws {
        let joined = try AudioFixture.data("dash-24-96000.mp4")
        let parts = try TrackDLFixtures.dashSegments(of: joined)
        #expect(parts.media.count == 3)
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(
                manifest: .dash(segments: parts.media.count), audioQuality: "HI_RES_LOSSLESS", bitDepth: 24, sampleRate: 96000
            ))
        }
        routes.audio = { path, _ in
            if path.hasSuffix("/init.mp4") { return .bytes(parts.initialization) }
            let number = Int(path.split(separator: "/").last?.split(separator: ".").first ?? "") ?? 0
            return (1...parts.media.count).contains(number) ? .bytes(parts.media[number - 1]) : .status(404)
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download(world.request(expectsHiRes: true))

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 24, sampleRate: 96000), notes: []))
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        // The same frames FFmpeg copied out of the joined file for the Electron app.
        #expect(try AudioFixture.frames(ofFLAC: saved) == AudioFixture.frames(ofFLAC: AudioFixture.data("ffmpeg-dash-24-96000.flac")))
        #expect(world.server.requests(matching: "audio.example.test").count == 4)
        #expect(world.temporariesAreGone)
    }

    @Test func anAACStreamIsSavedAsM4AThroughTheAACWriterAndSaysSo() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(
                manifest: .bts(TrackDLFixtures.directURL, mimeType: "audio/mp4", codecs: "mp4a.40.2"),
                audioQuality: "HIGH", bitDepth: nil, sampleRate: nil
            ))
        }
        routes.audio = { _, _ in .bytes((try? AudioFixture.data("aac-320.m4a")) ?? Data()) }
        routes.track = { _ in .json(200, TrackDLFixtures.trackJSON(duration: 2)) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download(world.request(expectsHiRes: true))

        #expect(outcome == .saved(fileName: "Blue Lantern.m4a", quality: .aac, notes: [.savedAsAAC]))
        #expect(world.savedFiles == ["Blue Lantern.m4a"])
        #expect(world.planner.decideCalls == [nil, .m4a])
        let call = try #require((world.m4a as? TrackDLM4AWriter)?.calls.first)
        #expect(call.tags.title == "Blue Lantern")
        #expect(call.coverJPEG == (try AudioFixture.data("cover.jpg")))
        #expect(world.temporariesAreGone)
    }

    // MARK: The download folder (2.16, 2.19)

    @Test func aSongAlreadyInTheFolderIsSkippedWithoutAskingTIDAL() async throws {
        let planner = TrackDLFolderPlanner { ext in ext == nil ? .skip(.alreadyInFolder(fileName: "Blue Lantern.flac")) : nil }
        let world = try TrackDLWorld(planner: planner)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .alreadyInFolder(fileName: "Blue Lantern.flac"))
        #expect(world.server.requests.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func aSkipFoundOnceTheExtensionIsKnownStopsBeforeTheAudio() async throws {
        let planner = TrackDLFolderPlanner { ext in ext == .flac ? .skip(.existingLooksDamaged(fileName: "Blue Lantern.flac")) : nil }
        let world = try TrackDLWorld(planner: planner)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .existingLooksDamaged(fileName: "Blue Lantern.flac"))
        #expect(world.server.requests(matching: "audio.example.test").isEmpty)
        #expect(world.server.requests(matching: "resources.tidal.com").isEmpty)
    }

    @Test func aMissingDownloadFolderStopsTheTrackBeforeAnyRequest() async throws {
        let world = try TrackDLWorld()
        defer { world.cleanUp() }
        let gone = world.base.appendingPathComponent("Renamed Away", isDirectory: true)

        await #expect(throws: TrackDownloadError.folderUnavailable(
            message: "The download folder “Renamed Away” no longer exists. Create it again or choose another folder."
        )) {
            _ = try await world.download(world.request(folder: gone))
        }
        #expect(world.server.requests.isEmpty)
        #expect(world.planner.decideCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func aDownloadFolderOnAnUnpluggedDriveNamesTheDrive() async throws {
        let world = try TrackDLWorld()
        defer { world.cleanUp() }
        let disk = "Music SSD \(UUID().uuidString.prefix(8))"
        let unplugged = URL(fileURLWithPath: "/Volumes/\(disk)/TIDAL", isDirectory: true)

        await #expect(throws: TrackDownloadError.folderUnavailable(
            message: "The download folder “TIDAL” on \(disk) isn't available. Connect the drive or choose another folder."
        )) {
            _ = try await world.download(world.request(folder: unplugged))
        }
        #expect(world.server.requests.isEmpty)
    }

    @Test func aDownloadFolderInTheTrashIsRefused() async throws {
        let world = try TrackDLWorld()
        defer { world.cleanUp() }
        let trash = world.base.appendingPathComponent("Trash", isDirectory: true)
        let trashed = trash.appendingPathComponent("TIDAL", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)

        await #expect(throws: TrackDownloadError.folderUnavailable(
            message: "The download folder “TIDAL” is in the Trash. Put it back or choose another folder."
        )) {
            _ = try await world.download(world.request(folder: trashed), using: world.downloader(trash: [trash]))
        }
        #expect(world.server.requests.isEmpty)
    }

    @Test func aDownloadFolderThatCantBeWrittenIsRefused() async throws {
        let world = try TrackDLWorld()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.folder.path)
            world.cleanUp()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.folder.path)

        await #expect(throws: TrackDownloadError.folderUnavailable(
            message: "robogears Downloader can't save into the download folder “TIDAL”. Check its permissions or choose another folder."
        )) {
            _ = try await world.download()
        }
        #expect(world.server.requests.isEmpty)
    }

    // MARK: Album and cover (2.15)

    @Test func anAlbumTIDALDoesntHaveIsSavedWithTheTracksOwnDetailsAndLimitedTags() async throws {
        var routes = TrackDLRoutes()
        routes.album = { _ in .status(404, #"{"status":404,"subStatus":2001,"userMessage":"Album not found"}"#) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes == [.limitedTags])
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        let comment = try #require(try FLACMetadataReader.read(saved).vorbisComment)
        // The track's own year, copyright and first artist stand in.
        #expect(comment.values(for: "date") == ["2011"])
        #expect(comment.values(for: "copyright") == ["2011 Track Copyright"])
        #expect(comment.values(for: "ALBUMARTIST") == ["Placeholder Artist"])
        // The track still lists its album's cover.
        #expect(try FLACMetadataReader.read(saved).pictures.count == 1)
    }

    @Test func anAlbumTIDALRefusesOutrightIsSavedWithLimitedTagsRatherThanFailing() async throws {
        var routes = TrackDLRoutes()
        routes.album = { _ in .status(403, #"{"status":403,"subStatus":4033}"#) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes == [.limitedTags])
        // A clear answer isn't retried.
        #expect(world.server.requests(matching: "/v1/albums/").count == 1)
    }

    @Test func albumDetailsThatStayBusyPastTheRetriesFailTheTrack() async throws {
        var routes = TrackDLRoutes()
        routes.album = { _ in .status(503) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.albumDetailsUnavailable) { _ = try await world.download() }
        #expect(world.server.requests(matching: "/v1/albums/").count == 5)
        #expect(world.savedFiles.isEmpty)
    }

    @Test func aLargeCoverThatIsntThereFallsBackToASmallerSize() async throws {
        var routes = TrackDLRoutes()
        let jpeg = try AudioFixture.data("cover.jpg")
        routes.cover = { size, _ in size == 1280 ? .status(404) : .data(status: 200, headers: [:], body: jpeg, chunks: 1) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes.isEmpty)
        #expect(world.server.requests(matching: "resources.tidal.com").map(\.url.lastPathComponent) == ["1280x1280.jpg", "640x640.jpg"])
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        #expect(try FLACMetadataReader.read(saved).pictures.first?.data == jpeg)
    }

    @Test func aCoverNotFoundAtEverySizeSavesWithoutCoverArt() async throws {
        var routes = TrackDLRoutes()
        routes.cover = { _, _ in .status(404) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes == [.withoutCoverArt])
        #expect(world.server.requests(matching: "resources.tidal.com").count == 3)
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        #expect(try FLACMetadataReader.read(saved).pictures.isEmpty)
    }

    @Test func anAlbumWithNoCoverListedSavesWithoutCoverArtAndAsksForNone() async throws {
        var routes = TrackDLRoutes()
        routes.album = { _ in .json(200, TrackDLFixtures.albumJSON(cover: nil)) }
        routes.track = { _ in .json(200, TrackDLFixtures.trackJSON(cover: nil)) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes == [.withoutCoverArt])
        #expect(world.server.requests(matching: "resources.tidal.com").isEmpty)
    }

    @Test func aCoverThatIsntAJPEGCountsAsNoCover() async throws {
        var routes = TrackDLRoutes()
        routes.cover = { _, _ in .data(status: 200, headers: [:], body: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]), chunks: 1) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes == [.withoutCoverArt])
        #expect(world.log.lines.contains { $0.hasPrefix("“Blue Lantern”: ") && $0.contains("isn't a JPEG") })
    }

    @Test func aCoverThatStaysBusyPastTheRetriesFailsTheTrackAndSavesNothing() async throws {
        var routes = TrackDLRoutes()
        routes.cover = { _, _ in .status(502) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.coverUnavailable) { _ = try await world.download() }
        // Retried like the audio, and never stepped down to a smaller size.
        #expect(world.server.requests(matching: "resources.tidal.com").map(\.url.lastPathComponent)
            == Array(repeating: "1280x1280.jpg", count: 5))
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    // MARK: Quality (2.21, 1.4)

    @Test func aBusyHiResRequestIsRetriedAndNeverStepsDown() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { quality, attempt in
            attempt < 2 ? .status(503) : .json(200, TrackDLFixtures.playbackJSON(manifest: .bts(TrackDLFixtures.directURL)))
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        _ = try await world.download()

        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS", "HI_RES_LOSSLESS", "HI_RES_LOSSLESS"])
    }

    @Test func aHiResRequestBusyPastTheRetriesFailsAsBusyWithoutSteppingDown() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .status(500) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.busy) { _ = try await world.download() }
        #expect(Set(world.server.qualitiesAsked) == ["HI_RES_LOSSLESS"])
        #expect(world.server.qualitiesAsked.count == 5)
    }

    @Test func aHiResRequestThatKeepsTimingOutNeverStepsDown() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .failure(.timedOut) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.offline) { _ = try await world.download() }
        #expect(world.server.qualitiesAsked == Array(repeating: "HI_RES_LOSSLESS", count: 5))
    }

    @Test func aDroppedConnectionOnTheHiResRequestIsRetriedAndNeverStepsDown() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, attempt in
            attempt == 0 ? .failure(.networkConnectionLost) : .json(200, TrackDLFixtures.playbackJSON(manifest: .bts(TrackDLFixtures.directURL)))
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        _ = try await world.download()

        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS", "HI_RES_LOSSLESS"])
    }

    @Test func tooManyRequestsPastTheRetriesFailsAsBusy() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .status(429) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.busy) { _ = try await world.download() }
        #expect(Set(world.server.qualitiesAsked) == ["HI_RES_LOSSLESS"])
    }

    @Test func aClearHiResRefusalStepsDownToLosslessAndFlagsARowThatShowedHiRes() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { quality, _ in
            quality == "HI_RES_LOSSLESS"
                ? .status(403, #"{"status":403,"subStatus":4007,"userMessage":"Quality not allowed"}"#)
                : .json(200, TrackDLFixtures.playbackJSON(manifest: .bts(TrackDLFixtures.directURL)))
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download(world.request(expectsHiRes: true))

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 16, sampleRate: 44100), notes: [.belowHiRes]))
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS", "LOSSLESS"])
        #expect(world.log.lines.contains { $0.contains("Quality not allowed") })
    }

    @Test func refusalsForBothLosslessTiersStepDownToTheAACFallback() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { quality, _ in
            quality == "HIGH"
                ? .json(200, TrackDLFixtures.playbackJSON(
                    manifest: .bts(TrackDLFixtures.directURL, mimeType: "audio/mp4", codecs: "mp4a.40.2"), audioQuality: "HIGH"
                ))
                : .status(404, #"{"status":404,"subStatus":4004}"#)
        }
        routes.audio = { _, _ in .bytes((try? AudioFixture.data("aac-320.m4a")) ?? Data()) }
        routes.track = { _ in .json(200, TrackDLFixtures.trackJSON(duration: 2)) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .saved(fileName: "Blue Lantern.m4a", quality: .aac, notes: [.savedAsAAC]))
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS", "LOSSLESS", "HIGH"])
    }

    @Test func aStreamRefusedAtEveryQualityFailsWithAPlainReason() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .status(403, #"{"status":403,"subStatus":4032,"userMessage":"raw server words"}"#) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: "TIDAL refused this stream")) {
            _ = try await world.download()
        }
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS", "LOSSLESS", "HIGH"])
        // TIDAL's own words go to the activity log only.
        #expect(world.log.lines.contains { $0.contains("raw server words") })
    }

    @Test func aTrackNotAvailableInTheCountryFailsWithoutSteppingDown() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .status(404, #"{"status":404,"subStatus":4032,"userMessage":"This track is not available in your country"}"#)
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: "Not available in your country")) {
            _ = try await world.download()
        }
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS"])
    }

    @Test func aPreviewClipIsNeverSaved() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(manifest: .bts(TrackDLFixtures.directURL), presentation: "PREVIEW"))
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.previewOnly) { _ = try await world.download() }
        #expect(world.server.requests(matching: "audio.example.test").isEmpty)
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS"])
    }

    // MARK: Sign-in (1.6)

    @Test func aSignInRejectedAgainAfterOneRenewalStopsTheBatch() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .status(401, #"{"status":401,"subStatus":11002,"userMessage":"Token is invalid"}"#) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.signInRejected) { _ = try await world.download() }
        #expect(world.server.requests(matching: "auth.tidal.com").count == 1)
        #expect(world.server.qualitiesAsked == ["HI_RES_LOSSLESS", "HI_RES_LOSSLESS"])
        #expect(TrackDownloadError.signInRejected.stopsBatch)
    }

    @Test func aRenewalTIDALRefusesStopsTheBatchAsSignInRejected() async throws {
        var routes = TrackDLRoutes()
        routes.track = { _ in .status(401, #"{"status":401,"subStatus":11003}"#) }
        routes.refresh = { _ in .json(400, TIDALClientFixtures.data("refresh-invalid-grant.json")) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.signInRejected) { _ = try await world.download() }
        #expect(world.server.qualitiesAsked.isEmpty)
    }

    @Test func aStreamNotReadyForPlaybackFailsOnlyThisTrack() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .status(401, #"{"status":401,"subStatus":4005,"userMessage":"Asset is not ready for playback"}"#) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: "TIDAL refused this stream")) {
            _ = try await world.download()
        }
    }

    // MARK: Network (1.7)

    @Test func noInternetConnectionPausesInsteadOfFailing() async throws {
        var routes = TrackDLRoutes()
        routes.track = { _ in .failure(.notConnectedToInternet) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.offline) { _ = try await world.download() }
        #expect(TrackDownloadError.offline.pausesBatch)
    }

    @Test func aHotelSignInPageInsteadOfTIDALReadsAsOffline() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .data(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>Welcome to the hotel</html>".utf8), chunks: 1)
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.offline) { _ = try await world.download() }
    }

    @Test func aConnectionThatDropsDuringTheAudioPausesAndLeavesNothing() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .failure(.networkConnectionLost) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.offline) { _ = try await world.download() }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func aTrackTIDALNoLongerHasFailsWithAPlainReason() async throws {
        var routes = TrackDLRoutes()
        routes.track = { _ in .status(404, #"{"status":404,"subStatus":2001}"#) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: "TIDAL no longer has this track")) {
            _ = try await world.download()
        }
    }

    @Test func aSegmentThatIsBusyOnceIsRetriedAndTheTrackIsStillWhole() async throws {
        let parts = try TrackDLFixtures.dashSegments(of: AudioFixture.data("dash-24-96000.mp4"))
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(manifest: .dash(segments: 3), audioQuality: "HI_RES_LOSSLESS", bitDepth: 24, sampleRate: 96000))
        }
        routes.audio = { path, attempt in
            if path.hasSuffix("/init.mp4") { return .bytes(parts.initialization) }
            let number = Int(path.split(separator: "/").last?.split(separator: ".").first ?? "") ?? 0
            if number == 2 && attempt == 0 { return .status(503) }
            return .bytes(parts.media[number - 1])
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 24, sampleRate: 96000), notes: []))
        #expect(world.server.requests(matching: "/dash/2.mp4").count == 2)
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        #expect(try AudioFixture.frames(ofFLAC: saved) == AudioFixture.frames(ofFLAC: AudioFixture.data("ffmpeg-dash-24-96000.flac")))
    }

    @Test func aSegmentLinkThatStopsWorkingFailsTheTrackAndCleansUp() async throws {
        let parts = try TrackDLFixtures.dashSegments(of: AudioFixture.data("dash-24-96000.mp4"))
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .json(200, TrackDLFixtures.playbackJSON(manifest: .dash(segments: 3))) }
        routes.audio = { path, _ in
            if path.hasSuffix("/init.mp4") { return .bytes(parts.initialization) }
            if path.hasSuffix("/2.mp4") { return .status(403) }
            return .bytes(parts.media[0])
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamLinkFailed)) {
            _ = try await world.download()
        }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    // MARK: Space (2.20)

    @Test func aFullDiskStopsTheBatchBeforeAnyAudioWithTheRoomStillNeeded() async throws {
        let world = try TrackDLWorld()
        defer { world.cleanUp() }

        let asked = Mutex<[URL]>([])

        // 1 s of 16-bit/44.1 kHz stereo FLAC: 123,480 bytes estimated, twice that needed.
        await #expect(throws: TrackDownloadError.diskFull(bytesNeeded: 2 * 123_480 - 1_000)) {
            _ = try await world.download(using: world.downloader(freeSpace: { url in
                asked.withLock { $0.append(url) }
                return 1_000
            }))
        }
        #expect(world.server.requests(matching: "audio.example.test").isEmpty)
        #expect(world.temporaries.registered.isEmpty)
        #expect(asked.withLock { $0 } == [world.folder])
        #expect(TrackDownloadError.diskFull(bytesNeeded: 1).stopsBatch)
    }

    @Test func aDiskThatFillsUpWhileSavingStopsTheBatchAsFull() async throws {
        let planner = TrackDLFolderPlanner(beforeMove: { _ in throw POSIXError(.ENOSPC) })
        let world = try TrackDLWorld(planner: planner)
        defer { world.cleanUp() }

        // The room still missing can't be less than the track itself.
        await #expect(throws: TrackDownloadError.diskFull(bytesNeeded: 123_480)) { _ = try await world.download() }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporariesAreGone)
    }

    @Test func aDriveUnpluggedWhileSavingStopsTheBatchWithTheFolderMessage() async throws {
        let planner = TrackDLFolderPlanner(beforeMove: { request in
            try FileManager.default.removeItem(at: request.folder)
        })
        let world = try TrackDLWorld(planner: planner)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.folderUnavailable(
            message: "The download folder “TIDAL” no longer exists. Create it again or choose another folder."
        )) {
            _ = try await world.download()
        }
        #expect(world.temporariesAreGone)
        #expect(!FileManager.default.fileExists(atPath: world.folder.path))
    }

    @Test func anAACWriteThatFailsFailsTheTrackAndLeavesNothingBehind() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(
                manifest: .bts(TrackDLFixtures.directURL, mimeType: "audio/mp4", codecs: "mp4a.40.2"),
                audioQuality: "HIGH", bitDepth: nil, sampleRate: nil
            ))
        }
        routes.audio = { _, _ in .bytes((try? AudioFixture.data("aac-320.m4a")) ?? Data()) }
        let world = try TrackDLWorld(routes, m4a: TrackDLM4AWriter { throw CocoaError(.fileWriteUnknown) })
        defer { world.cleanUp() }

        do {
            _ = try await world.download()
            Issue.record("a failed AAC write was reported as saved")
        } catch TrackDownloadError.writeFailed {
        }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
        #expect(TrackDownloadError.writeFailed(detail: "x").rowMessage == "Failed: the file couldn't be saved. Retry to try again.")
    }

    // MARK: Damage and cancellation (2.2, 2.4)

    @Test func aCutOffStreamFailsTheLengthCheckAndNothingLandsInTheFolder() async throws {
        let whole = try AudioFixture.data("bts-16-44100.flac")
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .bytes(whole.prefix(whole.count * 6 / 10), contentLength: false) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        do {
            _ = try await world.download()
            Issue.record("a cut-off stream was saved")
        } catch let TrackDownloadError.lengthMismatch(fileSeconds, tidalSeconds) {
            #expect(fileSeconds > 0.3 && fileSeconds < 0.8)
            #expect(tidalSeconds == 1)
        }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func aWholeFileFarShorterThanTIDALListsFails() async throws {
        var routes = TrackDLRoutes()
        routes.track = { _ in .json(200, TrackDLFixtures.trackJSON(duration: 240)) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.lengthMismatch(fileSeconds: 1, tidalSeconds: 240)) {
            _ = try await world.download()
        }
        #expect(world.savedFiles.isEmpty)
    }

    @Test func audioThatIsntFLACAtAllIsUnreadable() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .bytes(Data(repeating: 0x42, count: 4096)) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        do {
            _ = try await world.download()
            Issue.record("unreadable audio was saved")
        } catch TrackDownloadError.unreadableAudio {
        }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func cancellingMidDownloadStopsAtOnceAndDeletesTheTemporaryFile() async throws {
        let whole = try AudioFixture.data("bts-16-44100.flac")
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in
            .stall(headers: ["Content-Length": String(whole.count)], body: whole, prefix: whole.count / 2)
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let task = Task { try await world.download() }
        #expect(try await world.server.stalled.wait(upTo: .seconds(20)))
        let temporary = try #require(world.temporaries.registered.first)
        #expect(FileManager.default.fileExists(atPath: temporary.path))

        task.cancel()
        let result = await task.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(world.temporaries.registered.isEmpty)
        #expect(world.savedFiles.isEmpty)
    }

    @Test func cancellingWhileSegmentsArriveStopsEveryRequestAndDeletesTheTemporaryFile() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .json(200, TrackDLFixtures.playbackJSON(manifest: .dash(segments: 40))) }
        routes.audio = { path, _ in
            path.hasSuffix("/dash/2.mp4")
                ? .stall(headers: ["Content-Length": "1000"], body: Data(count: 1000), prefix: 10)
                : .bytes(Data(count: 1000))
        }
        let made = TrackDLTemporaryFolders()
        let world = try TrackDLWorld(routes, systemFolderNear: { try made.folder(near: $0) })
        defer { world.cleanUp() }

        let task = Task { try await world.download() }
        #expect(try await world.server.stalled.wait(upTo: .seconds(20)))
        let temporary = try #require(world.temporaries.registered.first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).contains { $0.hasPrefix("download.") })

        task.cancel()
        let result = await task.result
        let requestsByCancel = world.server.requests(matching: "audio.example.test").count
        try await Task.sleep(for: .milliseconds(200))

        #expect(throws: CancellationError.self) { try result.get() }
        // Segment 2 holds back the writing, so the read-ahead window caps
        // what started, and nothing more starts once Cancel is pressed.
        #expect(requestsByCancel <= 2 + AudioFetcher.readAhead)
        #expect(world.server.requests(matching: "audio.example.test").count == requestsByCancel)
        #expect(made.folders == [temporary])
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(world.temporaries.registered.isEmpty)
        #expect(world.savedFiles.isEmpty)
    }

    @Test func cancellingWhileTheAACWriterIsBusyReturnsAtOnceAndLeavesNothing() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(
                manifest: .bts(TrackDLFixtures.directURL, mimeType: "audio/mp4", codecs: "mp4a.40.2"),
                audioQuality: "HIGH", bitDepth: nil, sampleRate: nil
            ))
        }
        routes.audio = { _, _ in .bytes((try? AudioFixture.data("aac-320.m4a")) ?? Data()) }
        let writer = TrackDLStubbornM4AWriter()
        let world = try TrackDLWorld(routes, m4a: writer)
        defer {
            writer.release()
            world.cleanUp()
        }

        let task = Task { try await world.download() }
        #expect(try await writer.entered.wait(upTo: .seconds(20)))
        let temporary = try #require(world.temporaries.registered.first)

        // If Cancel waited for the writer, this lets the writer go after a
        // while, so the test fails instead of hanging.
        let watchdog = Task {
            guard (try? await Task.sleep(for: .seconds(5))) != nil else { return }
            writer.release()
        }
        task.cancel()
        let result = await task.result
        let returnedWhileWriting = !writer.isReleased
        watchdog.cancel()

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(returnedWhileWriting)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(world.temporaries.registered.isEmpty)

        // The writer ends on its own later, and leaves nothing anywhere.
        writer.release()
        #expect(try await writer.finished.wait(upTo: .seconds(5)))
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    // MARK: The CDN's own answers (2.15, 1.7)

    @Test func coverErrorPagesFromTheCDNTryTheNextSizeInsteadOfReadingAsOffline() async throws {
        let jpeg = try AudioFixture.data("cover.jpg")
        var routes = TrackDLRoutes()
        routes.cover = { size, _ in
            switch size {
            case 1280: .htmlError(404)
            case 640: .xmlError(403)
            default: .data(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg, chunks: 1)
            }
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 16, sampleRate: 44100), notes: []))
        #expect(world.server.requests(matching: "resources.tidal.com").map(\.url.lastPathComponent)
            == ["1280x1280.jpg", "640x640.jpg", "320x320.jpg"])
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        #expect(try FLACMetadataReader.read(saved).pictures.first?.data == jpeg)
    }

    @Test func aCoverMissingAtEverySizeBehindErrorPagesSavesWithoutCoverArt() async throws {
        var routes = TrackDLRoutes()
        routes.cover = { size, _ in size == 640 ? .xmlError(404) : .htmlError(404) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        guard case let .saved(_, _, notes) = outcome else { Issue.record("not saved: \(outcome)"); return }
        #expect(notes == [.withoutCoverArt])
        #expect(world.server.requests(matching: "resources.tidal.com").count == 3)
    }

    @Test func anExpiredSegmentLinkAnsweredWithXMLFailsTheTrackInsteadOfPausing() async throws {
        let parts = try TrackDLFixtures.dashSegments(of: AudioFixture.data("dash-24-96000.mp4"))
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in .json(200, TrackDLFixtures.playbackJSON(manifest: .dash(segments: 3))) }
        routes.audio = { path, _ in
            if path.hasSuffix("/init.mp4") { return .bytes(parts.initialization) }
            if path.hasSuffix("/2.mp4") { return .xmlError(403) }
            return .bytes(parts.media[0])
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamLinkFailed)) {
            _ = try await world.download()
        }
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func aStreamLinkAnsweredWithAnHTMLNotFoundFailsTheTrackInsteadOfPausing() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .htmlError(404) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamLinkFailed)) {
            _ = try await world.download()
        }
        #expect(world.server.requests(matching: "audio.example.test").count == 1)
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func aStreamLinkTheCDNRedirectsIsFollowedToTheAudio() async throws {
        let flac = try AudioFixture.data("bts-16-44100.flac")
        var routes = TrackDLRoutes()
        routes.audio = { path, _ in
            path == "/mediatracks/direct.flac"
                ? .redirect(status: 302, to: URL(string: "https://edge.example.test/cache/direct.flac?token=SECRET-TOKEN")!)
                : .bytes(flac)
        }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 16, sampleRate: 44100), notes: []))
        let followed = world.server.requests(matching: "edge.example.test")
        #expect(followed.count == 1)
        // A CDN request carries no sign-in, so nothing secret moves with it.
        #expect(followed.allSatisfy { $0.headers["Authorization"] == nil })
        #expect(try AudioFixture.frames(ofFLAC: Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac")))
            == AudioFixture.frames(ofFLAC: flac))
    }

    @Test func segmentsAndCoversTheCDNRedirectsAreFollowedToo() async throws {
        let parts = try TrackDLFixtures.dashSegments(of: AudioFixture.data("dash-24-96000.mp4"))
        let jpeg = try AudioFixture.data("cover.jpg")
        var routes = TrackDLRoutes()
        routes.playback = { _, _ in
            .json(200, TrackDLFixtures.playbackJSON(manifest: .dash(segments: 3), audioQuality: "HI_RES_LOSSLESS", bitDepth: 24, sampleRate: 96000))
        }
        routes.audio = { path, _ in
            guard path.hasPrefix("/edge/") else {
                return .redirect(status: 307, to: URL(string: "https://edge.example.test/edge\(path)?sig=abc")!)
            }
            if path == "/edge/cover.jpg" { return .data(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg, chunks: 1) }
            if path.hasSuffix("/init.mp4") { return .bytes(parts.initialization) }
            let number = Int(path.split(separator: "/").last?.split(separator: ".").first ?? "") ?? 0
            return (1...3).contains(number) ? .bytes(parts.media[number - 1]) : .status(404)
        }
        routes.cover = { _, _ in .redirect(status: 301, to: URL(string: "https://edge.example.test/edge/cover.jpg")!) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .saved(fileName: "Blue Lantern.flac", quality: .flac(bitDepth: 24, sampleRate: 96000), notes: []))
        let saved = try Data(contentsOf: world.folder.appendingPathComponent("Blue Lantern.flac"))
        #expect(try AudioFixture.frames(ofFLAC: saved) == AudioFixture.frames(ofFLAC: AudioFixture.data("ffmpeg-dash-24-96000.flac")))
        #expect(try FLACMetadataReader.read(saved).pictures.first?.data == jpeg)
        #expect(world.server.requests(matching: "edge.example.test").count == 5)
    }

    @Test func aRedirectToAPlainHTTPAddressIsRefusedAndFailsOnlyThisTrack() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .redirect(status: 302, to: URL(string: "http://edge.example.test/direct.flac")!) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamLinkFailed)) {
            _ = try await world.download()
        }
        #expect(world.server.requests(matching: "edge.example.test").isEmpty)
        #expect(world.savedFiles.isEmpty)
        #expect(world.temporaries.registered.isEmpty)
    }

    @Test func aCDNThatKeepsRedirectingIsGivenUpOnAfterFiveHops() async throws {
        var routes = TrackDLRoutes()
        routes.audio = { _, _ in .redirect(status: 302, to: URL(string: "https://edge.example.test/hop/\(UUID().uuidString)")!) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamLinkFailed)) {
            _ = try await world.download()
        }
        // The stream link, then the five redirects followed; never retried.
        #expect(world.server.requests(matching: "audio.example.test").count == 1)
        #expect(world.server.requests(matching: "edge.example.test").count == MediaRedirects.limit)
        #expect(world.savedFiles.isEmpty)
    }

    // MARK: Space and temporary folders while saving (2.20, 2.2)

    @Test func aDiskThatFillsUpWhileTheAudioArrivesStopsTheBatchAsFull() async throws {
        for full: any Error in [POSIXError(.ENOSPC), CocoaError(.fileWriteOutOfSpace)] {
            let world = try TrackDLWorld()
            defer { world.cleanUp() }
            var downloader = world.downloader()
            downloader.audioFetchOverride = { _, file, _, _ in
                try Data(count: 4096).write(to: file)
                throw full
            }

            // Not "the file couldn't be saved", which would let the next
            // track start and fill the disk again.
            await #expect(throws: TrackDownloadError.diskFull(bytesNeeded: 123_480)) {
                _ = try await world.download(using: downloader)
            }
            #expect(world.savedFiles.isEmpty)
            #expect(world.temporaries.registered.isEmpty)
        }
    }

    @Test func aDiskWhoseTemporaryFolderWouldSitInsideTheDownloadFolderStopsTheBatchOnce() async throws {
        let made = TrackDLTemporaryFolders { folder in
            let inside = folder.appendingPathComponent(".TemporaryItems/folders.501/TemporaryItems/work", isDirectory: true)
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
            return inside
        }
        let world = try TrackDLWorld(systemFolderNear: { try made.folder(near: $0) })
        defer { world.cleanUp() }

        let refusal = TrackDownloadError.folderUnavailable(
            message: "The disk with the download folder “TIDAL” doesn't allow the temporary files a download needs. Choose a folder on another disk."
        )
        await #expect(throws: refusal) { _ = try await world.download() }
        #expect(refusal.stopsBatch)
        #expect(world.server.requests(matching: "audio.example.test").isEmpty)
        #expect(world.temporaries.registered.isEmpty)
        let offered = try #require(made.folders.first)
        #expect(!FileManager.default.fileExists(atPath: offered.path))
    }

    @Test func aDiskThatOffersNoTemporaryFolderStopsTheBatchOnce() async throws {
        let world = try TrackDLWorld(systemFolderNear: { _ in throw CocoaError(.fileWriteVolumeReadOnly) })
        defer { world.cleanUp() }

        await #expect(throws: TrackDownloadError.folderUnavailable(
            message: "The disk with the download folder “TIDAL” doesn't allow the temporary files a download needs. Choose a folder on another disk."
        )) {
            _ = try await world.download()
        }
        #expect(world.server.requests(matching: "audio.example.test").isEmpty)
        #expect(world.log.lines.contains { $0.hasPrefix("No temporary folder on the download folder's disk") })
    }

    // MARK: Privacy

    @Test func noSignedStreamLinkOrTokenReachesTheActivityLog() async throws {
        var routes = TrackDLRoutes()
        routes.playback = { quality, _ in
            quality == "HI_RES_LOSSLESS"
                ? .status(403, #"{"status":403,"userMessage":"nope"}"#)
                : .json(200, TrackDLFixtures.playbackJSON(manifest: .bts(TrackDLFixtures.directURL)))
        }
        routes.cover = { _, _ in .status(404) }
        let world = try TrackDLWorld(routes)
        defer { world.cleanUp() }

        _ = try await world.download()

        #expect(!world.log.lines.isEmpty)
        for line in world.log.lines {
            #expect(!line.contains("SECRET-TOKEN"))
            #expect(!line.contains("audio.example.test"))
            #expect(!line.contains("fake-access"))
        }
    }

    // MARK: Notes from the folder

    @Test func theFolderPlansNotesAndTheFinalMoveNotesAreMerged() async throws {
        let planner = TrackDLFolderPlanner(moveNotes: [.savedUnderAnotherName(takenName: "Blue Lantern (Placeholder Artist).flac")]) { ext in
            ext == .flac ? .save(fileName: "Blue Lantern (Extended Mix).flac", notes: [.savedUnderAnotherName(takenName: "Blue Lantern.flac")]) : nil
        }
        let world = try TrackDLWorld(planner: planner)
        defer { world.cleanUp() }

        let outcome = try await world.download()

        #expect(outcome == .saved(
            fileName: "Blue Lantern (Extended Mix).flac", quality: .flac(bitDepth: 16, sampleRate: 44100),
            notes: [.savedUnderAnotherName(takenName: "Blue Lantern (Placeholder Artist).flac")]
        ))
        #expect(world.planner.moves.first?.plannedName == "Blue Lantern (Extended Mix).flac")
    }
}
