// The per-track downloader: one queue row in, one checked, tagged file in
// the download folder out.
//
// It replaces `tidal_download.js` (download-pipeline.md B5), in the order
// decision 4, area 2 asks for:
//  1. the download folder is there (2.19), and the song isn't already in it
//     (2.16), before anything is asked of TIDAL;
//  2. track and album details (2.15);
//  3. the playback reply, stepping down a quality only when TIDAL clearly
//     refuses one (2.21), and never accepting a preview (2.23);
//  4. the manifest says FLAC or the AAC fallback (2.10), and the folder
//     plans the file's name with the real extension (2.6);
//  5. room on the disk (2.20);
//  6. a temporary folder on the same disk (2.2);
//  7. the audio, streamed to disk, with the cover fetched alongside it;
//  8. the tags written by the native FLAC writer (or the AAC writer);
//  9. the length check (2.2);
// 10. the move into place, never over an existing file (2.6).
// Every failure becomes a `TrackDownloadError` (TrackDownloadFailures), and
// the temporary folder is removed whatever happens, cancellation included.
import Foundation

/// The three TIDAL calls a download makes. `TIDALAPI` is the real one; a
/// stand-in lets tests script TIDAL's answers.
public protocol TrackDownloadAPI: Sendable {
    /// `/v1/tracks/{id}`: the track's details as JSON.
    func track(id: Int) async throws -> Data
    /// `/v1/albums/{id}`: the album's details as JSON.
    func album(id: Int) async throws -> Data
    /// The playback reply for one quality, whatever its status (see
    /// `TIDALAPI.playbackInfoResponse`).
    func playbackInfoResponse(trackID: Int, quality: TIDALAPI.Quality) async throws -> HTTPResponse
}

extension TIDALAPI: TrackDownloadAPI {}

public struct TrackDownloader: TrackDownloading {
    public typealias FreeSpace = @Sendable (URL) -> Int64?

    /// Rule 5: Hi-Res, then lossless, then the 320 kbps AAC fallback. A
    /// step down happens only after TIDAL clearly refuses the quality above
    /// (2.21).
    static let qualityChain: [TIDALAPI.Quality] = [.hiResLossless, .lossless, .high]

    let api: any TrackDownloadAPI
    let audioClient: HTTPClient
    let folderPlanner: any DownloadFolderPlanning
    let m4aWriter: any M4AWriting
    let temporaries: TemporaryDownloads
    let freeSpace: FreeSpace
    let trashDirectories: @Sendable () -> [URL]
    let retry: RetryPolicy
    let log: @Sendable (String) -> Void

    /// Writes the audio at a location into a new file, reporting 0…1.
    typealias AudioFetch = @Sendable (
        _ location: TIDALManifest.Location, _ file: URL, _ estimatedBytes: Int64,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Void

    /// Stands in for `AudioFetcher` when set, so a test can make the disk
    /// fill up while the audio arrives (2.20), which no mock server can.
    var audioFetchOverride: AudioFetch?

    /// - Parameters:
    ///   - api: TIDAL's API (`TIDALAPI` in the app).
    ///   - audioClient: an `HTTPClient` with `.audio` limits, for the stream
    ///     and the cover: no total time limit, only an inactivity one (1.4).
    ///   - folderPlanner: the download folder's naming and final move.
    ///   - m4aWriter: writes the AAC fallback.
    ///   - temporaries: the list of temporary folders (2.2).
    ///   - freeSpace: free bytes on the disk holding a folder (2.20).
    ///   - trashDirectories: the Trash folders, for the folder check (2.19).
    ///   - retry: the shared retry rule (1.4).
    ///   - log: lines for the activity log. Never given a stream link, a
    ///     token or the client keys; TIDAL's own refusal text goes here and
    ///     nowhere else (1.4).
    public init(
        api: any TrackDownloadAPI,
        audioClient: HTTPClient,
        folderPlanner: any DownloadFolderPlanning,
        m4aWriter: any M4AWriting,
        temporaries: TemporaryDownloads,
        freeSpace: @escaping FreeSpace = DiskSpace.availableBytes(at:),
        trashDirectories: @escaping @Sendable () -> [URL] = { Folders.defaultTrashDirectories() },
        retry: RetryPolicy = .standard,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.api = api
        self.audioClient = audioClient
        self.folderPlanner = folderPlanner
        self.m4aWriter = m4aWriter
        self.temporaries = temporaries
        self.freeSpace = freeSpace
        self.trashDirectories = trashDirectories
        self.retry = retry
        self.log = log
    }

    // MARK: - One track

    public func download(
        _ request: TrackDownloadRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TrackDownloadOutcome {
        var estimate: Int64?
        do {
            // 1. The folder first, and a skip before any TIDAL request, so
            //    being offline can't turn "already there" into a failure (2.16).
            if let message = DownloadFolderCheck.problem(with: request.folder, trashDirectories: trashDirectories()) {
                throw TrackDownloadError.folderUnavailable(message: message)
            }
            if case let .skip(outcome) = try await decide(request, fileExtension: nil) { return outcome }

            // 2. Details.
            let track = try await trackDetails(for: request)
            let (album, albumNotes) = try await albumDetails(of: track, request: request)

            // 3. What TIDAL will stream.
            let playback = try await playbackInfo(for: request)

            // 4. FLAC or the AAC fallback, and the name to save under.
            let manifest: TIDALManifest
            do {
                manifest = try TIDALManifest(playbackInfo: playback)
            } catch {
                log("“\(request.title)”: \(error.errorDescription ?? "TIDAL's stream details couldn't be read.")")
                throw TrackDownloadFailures.mapped(error)
            }
            let fileExtension: FileNaming.AudioExtension = manifest.isFLAC ? .flac : .m4a
            var notes = albumNotes
            if !manifest.isFLAC {
                log("“\(request.title)”: TIDAL has no lossless version; saving as AAC (.m4a).")
                notes.insert(.savedAsAAC, at: 0)
            }
            let plannedName: String
            let folderNotes: [SaveNote]
            switch try await decide(request, fileExtension: fileExtension) {
            case let .skip(outcome):
                return outcome
            case let .save(fileName, decisionNotes):
                plannedName = fileName
                folderNotes = decisionNotes
            }

            // 5. Room for the download and its tagged copy.
            let duration = track.duration ?? request.durationSeconds
            let trackBytes = DiskSpace.estimatedTrackBytes(
                durationSeconds: duration, isFLAC: manifest.isFLAC,
                bitDepth: playback.bitDepth, sampleRate: playback.sampleRate
            )
            estimate = trackBytes
            if let shortfall = DiskSpace.shortfall(trackBytes: trackBytes, available: freeSpace(request.folder)) {
                throw TrackDownloadError.diskFull(bytesNeeded: shortfall)
            }

            // 6–11. Download, tag, check and move, in a temporary folder
            //       that is removed whatever happens.
            let work = try makeTemporaryFolder(for: request)
            do {
                let outcome = try await saveTrack(
                    request, track: track, album: album, playback: playback, manifest: manifest,
                    fileExtension: fileExtension, plannedName: plannedName,
                    notes: notes, folderNotes: folderNotes, tidalSeconds: duration,
                    estimatedBytes: trackBytes, work: work, progress: ProgressThrottle(progress)
                )
                temporaries.remove(work)
                return outcome
            } catch {
                temporaries.remove(work)
                throw error
            }
        } catch {
            throw finalError(error, request: request, estimatedBytes: estimate)
        }
    }

    // MARK: - Steps

    private func decide(_ request: TrackDownloadRequest, fileExtension: FileNaming.AudioExtension?) async throws -> FolderDecision {
        do {
            return try await folderPlanner.decide(for: request, fileExtension: fileExtension)
        } catch {
            throw TrackDownloadFailures.mapped(error, during: .saving)
        }
    }

    private func trackDetails(for request: TrackDownloadRequest) async throws -> TIDALTrack {
        let data: Data
        do {
            data = try await api.track(id: Int(request.tidalID))
        } catch {
            throw TrackDownloadFailures.mapped(error, during: .details)
        }
        guard let track = try? JSONDecoder().decode(TIDALTrack.self, from: data) else {
            throw TrackDownloadError.notAvailable(reason: TrackDownloadFailures.unreadableAnswer)
        }
        return track
    }

    /// The album's details, which carry the release year, album artist and
    /// copyright (2.15). An album TIDAL doesn't have (it answers 404, or
    /// refuses it outright) is saved with the track's own details and
    /// "Saved with limited tags"; temporary errors that outlast the retries
    /// fail the track.
    private func albumDetails(of track: TIDALTrack, request: TrackDownloadRequest) async throws -> (TIDALAlbum?, [SaveNote]) {
        guard let albumID = track.album?.id else {
            log("“\(request.title)”: TIDAL lists no album for this track; saving with its own details.")
            return (nil, [.limitedTags])
        }
        do {
            let data = try await api.album(id: Int(albumID))
            guard let album = try? JSONDecoder().decode(TIDALAlbum.self, from: data) else {
                throw TrackDownloadError.albumDetailsUnavailable
            }
            return (album, [])
        } catch let error as RequestError where TrackDownloadFailures.isClearRefusal(error) {
            log("“\(request.title)”: TIDAL has no details for this track's album (\(error)); saving with the track's own details.")
            return (nil, [.limitedTags])
        } catch {
            throw TrackDownloadFailures.mapped(error, during: .album)
        }
    }

    /// Asks for each quality in turn (2.21). Temporary errors were already
    /// retried under the shared pace by the time they arrive here, and they
    /// end the track as busy or offline: they never cause a step down. Only
    /// a clear refusal (a 4xx other than 401 and 429) moves to the next
    /// quality, unless it says the track isn't available in this country,
    /// which no quality would change. What TIDAL actually answers in each
    /// case needs a live check.
    private func playbackInfo(for request: TrackDownloadRequest) async throws -> TIDALPlaybackInfo {
        var refused: [TIDALAPI.Quality] = []
        for quality in Self.qualityChain {
            let response: HTTPResponse
            do {
                response = try await api.playbackInfoResponse(trackID: Int(request.tidalID), quality: quality)
            } catch {
                throw playbackFailure(error, request: request)
            }
            if response.status == 200 {
                guard let info = try? JSONDecoder().decode(TIDALPlaybackInfo.self, from: response.body) else {
                    throw TrackDownloadError.notAvailable(reason: TrackDownloadFailures.unreadableAnswer)
                }
                // 2.23: a preview clip must never be saved as the track.
                if let presentation = info.assetPresentation, presentation.uppercased() != "FULL" {
                    log("“\(request.title)”: TIDAL sent only a preview (\(presentation)).")
                    throw TrackDownloadError.previewOnly
                }
                if !refused.isEmpty {
                    log("“\(request.title)”: saving at \(quality.rawValue) after TIDAL refused \(refused.map(\.rawValue).joined(separator: " and ")).")
                }
                return info
            }
            let refusal = TIDALErrorResponse.decodeLeniently(response.body)
            log("“\(request.title)”: TIDAL refused \(quality.rawValue) (\(response.status)"
                + (refusal?.subStatus.map { ", sub-status \($0)" } ?? "") + ")"
                + (refusal?.userMessage.map { ": \($0)" } ?? "") + ".")
            guard (400...499).contains(response.status) else {
                throw TrackDownloadFailures.mapped(
                    RequestError.unexpectedStatus(response.status, subStatus: refusal?.subStatus), during: .playback
                )
            }
            if refusal?.saysNotInCountry == true {
                throw TrackDownloadError.notAvailable(reason: TrackDownloadFailures.notInCountry)
            }
            refused.append(quality)
        }
        throw TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamRefused)
    }

    /// TIDAL is believed to answer 401 with sub-status 4005 ("asset is not
    /// ready for playback") for a track it won't stream, even with a good
    /// sign-in (unverified; a live check). Read as a sign-in problem, one
    /// such track would stop the whole batch, so it fails only this track.
    /// Any other 401 that outlasts the keeper's one renewal is the sign-in
    /// (1.6).
    static let assetNotReadySubStatus = 4005

    private func playbackFailure(_ error: any Error, request: TrackDownloadRequest) -> any Error {
        if case let RequestError.unauthorized(subStatus)? = error as? RequestError, subStatus == Self.assetNotReadySubStatus {
            log("“\(request.title)”: TIDAL says the stream isn't ready for playback (401, sub-status 4005).")
            return TrackDownloadError.notAvailable(reason: TrackDownloadFailures.streamRefused)
        }
        return TrackDownloadFailures.mapped(error, during: .playback)
    }

    private func makeTemporaryFolder(for request: TrackDownloadRequest) throws -> URL {
        do {
            return try temporaries.makeFolder(near: request.folder)
        } catch let .noTemporaryFolder(detail) {
            log("No temporary folder on the download folder's disk: \(detail)")
            throw TrackDownloadError.folderUnavailable(message: DownloadFolderCheck.noTemporaryFolderMessage(for: request.folder))
        } catch let .listNotSaved(detail) {
            throw TrackDownloadError.writeFailed(detail: "the list of temporary downloads couldn't be saved: \(detail)")
        }
    }

    private enum FetchedPart: Sendable {
        case audio
        case cover(jpeg: Data?, notes: [SaveNote])
    }

    /// Steps 7 to 11, inside the temporary folder `work`.
    private func saveTrack(
        _ request: TrackDownloadRequest, track: TIDALTrack, album: TIDALAlbum?, playback: TIDALPlaybackInfo,
        manifest: TIDALManifest, fileExtension: FileNaming.AudioExtension, plannedName: String,
        notes: [SaveNote], folderNotes: [SaveNote], tidalSeconds: Int?,
        estimatedBytes: Int64, work: URL, progress: ProgressThrottle
    ) async throws -> TrackDownloadOutcome {
        let downloaded = work.appendingPathComponent("download.\(manifest.container.fileExtension)")
        let tagged = work.appendingPathComponent("tagged.\(fileExtension.rawValue)")
        let temporaries = self.temporaries
        let cleanUpLater: @Sendable () -> Void = { temporaries.remove(work) }

        // 7. The audio and the cover at the same time; the first failure
        //    cancels the other (2.15 keeps a failed cover from being silent).
        progress.update(0)
        let fetcher = AudioFetcher(client: audioClient, retry: retry)
        let fetchAudio: AudioFetch = audioFetchOverride ?? { location, file, estimatedBytes, progress in
            try await fetcher.fetch(location, to: file, estimatedBytes: estimatedBytes, progress: progress)
        }
        let log = self.log, title = request.title
        let covers = CoverFetcher(client: audioClient, retry: retry, log: { log("“\(title)”: \($0)") })
        // The album details' cover first; the track's own album when the
        // details are missing (limited tags) still lists it.
        let coverAlbum = (album?.cover?.isEmpty == false) ? album : track.album
        let cover = try await withThrowingTaskGroup(of: FetchedPart.self) { group in
            group.addTask {
                do {
                    try await fetchAudio(manifest.location, downloaded, estimatedBytes) { progress.update($0) }
                } catch {
                    throw TrackDownloadFailures.mapped(error, during: .audio)
                }
                return .audio
            }
            group.addTask {
                let cover = try await covers.fetch(coverOf: coverAlbum)
                return .cover(jpeg: cover.jpeg, notes: cover.notes)
            }
            var cover: (jpeg: Data?, notes: [SaveNote]) = (nil, [])
            for try await part in group {
                if case let .cover(jpeg, coverNotes) = part { cover = (jpeg, coverNotes) }
            }
            return cover
        }

        // 8. Tags (2.7) and the tagged copy.
        let tags = TrackTagging.tags(for: track, album: album)
        let quality: SavedQuality
        switch fileExtension {
        case .flac:
            quality = try await BackgroundWork.run({
                try Self.writeFLAC(from: downloaded, tags: tags, coverJPEG: cover.jpeg, to: tagged)
            }, afterAbandon: cleanUpLater)
        case .m4a:
            // Run apart, like the FLAC writer, so Cancel returns at once
            // even if the AAC writer finishes its file first (2.4).
            let writer = m4aWriter, coverJPEG = cover.jpeg
            _ = try await BackgroundWork.run(async: {
                try await writer.writeM4A(from: downloaded, tags: tags, coverJPEG: coverJPEG, to: tagged)
            }, afterAbandon: cleanUpLater)
            quality = .aac
        }

        // 9. The length check (2.2).
        let report: AudioProbe.Report
        do {
            report = try await BackgroundWork.run({ try AudioProbe.inspect(tagged) }, afterAbandon: cleanUpLater)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TrackDownloadError.unreadableAudio(detail: "the saved file couldn't be opened to check it: \(error)")
        }
        switch Self.checkLength(report, tidalSeconds: tidalSeconds) {
        case .fine:
            break
        case .cannotJudge:
            log("“\(request.title)”: the saved file doesn't state its length, so it couldn't be checked against TIDAL's.")
        case let .mismatch(error):
            throw error
        }

        // 10. Into the download folder, never over another file (2.6).
        try Task.checkCancellation()
        let moved = try await folderPlanner.moveIntoPlace(
            tagged, for: request, plannedName: plannedName, fileExtension: fileExtension
        )
        var pipelineNotes = notes + cover.notes
        if request.expectsHiRes, case .flac = quality, !quality.isHiRes {
            pipelineNotes.append(.belowHiRes)
        }
        return .saved(
            fileName: moved.fileName, quality: quality,
            notes: Self.mergedNotes(pipeline: pipelineNotes, decision: folderNotes, move: moved.notes)
        )
    }

    /// Reads the download (native FLAC or FLAC in fragmented MP4, sniffed
    /// from its first bytes) and writes the tagged copy with the native
    /// writer (docs/spikes/audio-and-tagging.md, part c).
    static func writeFLAC(from downloaded: URL, tags: FLACTags, coverJPEG: Data?, to tagged: URL) throws -> SavedQuality {
        let disk = try? downloaded.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey])
        let source = try Data(
            contentsOf: downloaded,
            options: readingOptions(isLocal: disk?.volumeIsLocal, isInternal: disk?.volumeIsInternal)
        )
        let audio: FLACAudio
        do {
            audio = try FLACAudio(downloaded: source)
        } catch {
            throw TrackDownloadError.unreadableAudio(detail: "\(error)")
        }
        do {
            try FLACWriter.write(audio, tags: tags, coverJPEG: coverJPEG, to: tagged)
        } catch let error as FLACFormatError {
            throw TrackDownloadError.writeFailed(detail: "\(error)")
        }
        return .flac(bitDepth: Int(audio.streamInfo.bitsPerSample), sampleRate: Int(audio.streamInfo.sampleRate))
    }

    // MARK: - Rules

    /// How to read the download for tagging. Mapping it saves holding a
    /// 150 MB track in memory, but a mapped page that can no longer be read
    /// in (the drive was unplugged, the share dropped) crashes the app
    /// instead of failing the save, and 2.19 asks for a drive that goes
    /// mid-batch to stop the batch once. The temporary folder sits on the
    /// download folder's disk, so the download is mapped only on a local,
    /// internal disk, and read into memory everywhere else, or when the
    /// disk can't say.
    static func readingOptions(isLocal: Bool?, isInternal: Bool?) -> Data.ReadingOptions {
        isLocal == true && isInternal == true ? .alwaysMapped : []
    }

    enum LengthCheck: Equatable {
        case fine
        /// The file doesn't state its length and nothing decoded, so it can't
        /// be judged; it's never called damaged (spike, part a).
        case cannotJudge
        case mismatch(TrackDownloadError)
    }

    /// 2.2: the saved file must decode to its own declared end, then be
    /// within 2 seconds or 1 %, whichever is larger, of the length TIDAL
    /// lists. Checking the file against itself first means a track whose
    /// TIDAL length is slightly off doesn't fail on every Retry. A file that
    /// doesn't state its length is judged by what decoded instead.
    static func checkLength(_ report: AudioProbe.Report, tidalSeconds: Int?) -> LengthCheck {
        let tidal = tidalSeconds.flatMap { $0 > 0 ? Double($0) : nil }
        let decoded = report.decodedFrames ?? 0
        let fileSeconds = report.sampleRate > 0 ? Double(decoded) / report.sampleRate : 0
        switch report.verdict {
        case .short:
            return .mismatch(.lengthMismatch(fileSeconds: fileSeconds, tidalSeconds: tidal))
        case .lengthUnknown, nil:
            if decoded == 0 { return .cannotJudge }
        case .complete:
            break
        }
        if let tidal, abs(fileSeconds - tidal) > max(2, tidal * 0.01) {
            return .mismatch(.lengthMismatch(fileSeconds: fileSeconds, tidalSeconds: tidal))
        }
        return .fine
    }

    /// The notes for the row, each once: the pipeline's own (AAC, limited
    /// tags, no cover, below Hi-Res), then the folder's. When the final move
    /// had to pick another name, its note replaces the planned one.
    static func mergedNotes(pipeline: [SaveNote], decision: [SaveNote], move: [SaveNote]) -> [SaveNote] {
        func isRename(_ note: SaveNote) -> Bool {
            if case .savedUnderAnotherName = note { return true }
            return false
        }
        var planned = decision
        if move.contains(where: isRename) { planned.removeAll(where: isRename) }
        var merged: [SaveNote] = []
        for note in pipeline + planned + move where !merged.contains(note) {
            merged.append(note)
        }
        return merged
    }

    /// The error the batch sees. A full disk found while writing reports
    /// the room still missing for this track (2.20). A write that failed
    /// because the download folder went away meanwhile (its drive was
    /// unplugged, it was moved to the Trash) is that folder problem, which
    /// stops the batch once instead of failing this row and then the next
    /// one at its folder check (2.19, 2.1).
    private func finalError(_ error: any Error, request: TrackDownloadRequest, estimatedBytes: Int64?) -> any Error {
        if error is CancellationError { return error }
        if TrackDownloadFailures.isOutOfSpace(error) {
            let needed = DiskSpace.requiredFreeBytes(forTrackBytes: estimatedBytes ?? 0)
            let shortfall = needed - (freeSpace(request.folder) ?? 0)
            return TrackDownloadError.diskFull(bytesNeeded: shortfall > 0 ? shortfall : max(estimatedBytes ?? 0, 1))
        }
        let mapped = TrackDownloadFailures.mapped(error, during: .saving)
        if case let .writeFailed(detail)? = mapped as? TrackDownloadError {
            log("“\(request.title)”: saving failed: \(detail)")
            if let message = DownloadFolderCheck.problem(with: request.folder, trashDirectories: trashDirectories()) {
                return TrackDownloadError.folderUnavailable(message: message)
            }
        } else if case let .unreadableAudio(detail)? = mapped as? TrackDownloadError {
            log("“\(request.title)”: TIDAL's audio couldn't be read: \(detail)")
        }
        return mapped
    }
}

extension TIDALErrorResponse {
    /// TIDAL's error body, if the answer is one.
    static func decodeLeniently(_ body: Data) -> TIDALErrorResponse? {
        try? JSONDecoder().decode(TIDALErrorResponse.self, from: body)
    }

    /// True when TIDAL's own words say the track isn't available where the
    /// account is. Read only to choose the reason; the words themselves go
    /// to the activity log, never to the row (1.4). Which answers TIDAL
    /// really gives needs a live check.
    var saysNotInCountry: Bool {
        guard let message = userMessage?.lowercased() else { return false }
        return message.contains("country") || message.contains("region")
    }
}
