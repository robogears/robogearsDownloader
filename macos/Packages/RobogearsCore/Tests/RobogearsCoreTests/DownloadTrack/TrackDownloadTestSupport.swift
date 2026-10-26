import Foundation
import Synchronization
@testable import RobogearsCore

// Test support for the per-track downloader. Every name carries a TrackDL
// prefix so it can't collide with helpers other lanes add to the same test
// target. Nothing here reaches the network: every session routes through
// `TrackDLURLProtocol`, which answers from a per-test `TrackDLServer`, and
// every file goes into a temporary folder the test removes.

// MARK: - Replies

enum TrackDLReply: Sendable {
    /// A whole answer, delivered in `chunks` pieces.
    case data(status: Int, headers: [String: String], body: Data, chunks: Int)
    case failure(URLError.Code)
    /// The head and the first `prefix` bytes, then nothing until cancelled.
    case stall(headers: [String: String], body: Data, prefix: Int)
    /// A redirect to `location`, sent the way a server sends one; when the
    /// client refuses it, the 3xx itself is the answer.
    case redirect(status: Int, to: URL)

    static func json(_ status: Int, _ body: Data, headers: [String: String] = [:]) -> TrackDLReply {
        var all = ["Content-Type": "application/json"]
        all.merge(headers) { $1 }
        return .data(status: status, headers: all, body: body, chunks: 1)
    }

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> TrackDLReply {
        json(status, Data(text.utf8), headers: headers)
    }

    static func bytes(_ body: Data, chunks: Int = 4, contentLength: Bool = true, status: Int = 200) -> TrackDLReply {
        var headers = ["Content-Type": "application/octet-stream"]
        if contentLength { headers["Content-Length"] = String(body.count) }
        return .data(status: status, headers: headers, body: body, chunks: chunks)
    }

    static func status(_ code: Int, _ text: String = "{}") -> TrackDLReply {
        json(code, text)
    }
}

/// What a test scripts: one answer per kind of request. `attempt` counts
/// earlier requests of the same kind (the same quality, the same audio
/// path, the same cover size), so retries can be scripted.
struct TrackDLRoutes: Sendable {
    var track: @Sendable (_ attempt: Int) -> TrackDLReply = { _ in .json(200, TrackDLFixtures.trackJSON()) }
    var album: @Sendable (_ attempt: Int) -> TrackDLReply = { _ in .json(200, TrackDLFixtures.albumJSON()) }
    var playback: @Sendable (_ quality: String, _ attempt: Int) -> TrackDLReply = { _, _ in
        .json(200, TrackDLFixtures.playbackJSON(manifest: .bts(TrackDLFixtures.directURL)))
    }
    var audio: @Sendable (_ path: String, _ attempt: Int) -> TrackDLReply = { _, _ in
        .bytes((try? AudioFixture.data("bts-16-44100.flac")) ?? Data())
    }
    var cover: @Sendable (_ size: Int, _ attempt: Int) -> TrackDLReply = { _, _ in
        .data(status: 200, headers: ["Content-Type": "image/jpeg"], body: (try? AudioFixture.data("cover.jpg")) ?? Data(), chunks: 1)
    }
    var refresh: @Sendable (_ attempt: Int) -> TrackDLReply = { _ in
        .json(200, TIDALClientFixtures.data("refresh-renewed.json"))
    }
}

// MARK: - Server

final class TrackDLServer: Sendable {
    let route = UUID().uuidString
    let routes: TrackDLRoutes
    private let recorded = Mutex<[TIDALRecordedRequest]>([])
    private let attempts = Mutex<[String: Int]>([:])
    /// Set once a `.stall` reply has sent its first bytes.
    let stalled = TIDALFlag()

    private static let registry = Mutex<[String: TrackDLServer]>([:])

    init(_ routes: TrackDLRoutes = TrackDLRoutes()) {
        self.routes = routes
        Self.registry.withLock { $0[route] = self }
    }

    static func lookup(_ route: String) -> TrackDLServer? {
        registry.withLock { $0[route] }
    }

    var requests: [TIDALRecordedRequest] { recorded.withLock { $0 } }

    /// The requests whose path contains `fragment`.
    func requests(matching fragment: String) -> [TIDALRecordedRequest] {
        requests.filter { $0.url.absoluteString.contains(fragment) }
    }

    /// The `audioquality` of each playback request, in order.
    var qualitiesAsked: [String] {
        requests(matching: "playbackinfopostpaywall").compactMap { request in
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "audioquality" }?.value
        }
    }

    private func nextAttempt(_ key: String) -> Int {
        attempts.withLock { counts in
            let attempt = counts[key, default: 0]
            counts[key] = attempt + 1
            return attempt
        }
    }

    func reply(to request: TIDALRecordedRequest) -> TrackDLReply {
        recorded.withLock { $0.append(request) }
        let url = request.url
        let host = url.host ?? ""
        let path = url.path
        if host == "auth.tidal.com" {
            return routes.refresh(nextAttempt("refresh"))
        }
        if host == "resources.tidal.com" {
            let size = Int(url.lastPathComponent.split(separator: "x").first ?? "") ?? 0
            return routes.cover(size, nextAttempt("cover:\(size)"))
        }
        if host == "api.tidal.com" {
            if path.hasSuffix("/playbackinfopostpaywall") {
                let quality = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "audioquality" }?.value ?? ""
                return routes.playback(quality, nextAttempt("playback:\(quality)"))
            }
            if path.hasPrefix("/v1/tracks/") { return routes.track(nextAttempt("track")) }
            if path.hasPrefix("/v1/albums/") { return routes.album(nextAttempt("album")) }
            return .status(404)
        }
        return routes.audio(path, nextAttempt("audio:\(path)"))
    }

    func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrackDLURLProtocol.self]
        configuration.httpAdditionalHeaders = [TrackDLURLProtocol.routeHeader: route]
        return configuration
    }

    func makeClient(limits: HTTPClient.Limits, clock: any NetworkClock) -> HTTPClient {
        HTTPClient(limits: limits, clock: clock, sessionConfiguration: sessionConfiguration())
    }
}

final class TrackDLURLProtocol: URLProtocol, @unchecked Sendable {
    static let routeHeader = "X-TrackDL-Route"
    private let work = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let route = request.value(forHTTPHeaderField: Self.routeHeader),
              let server = TrackDLServer.lookup(route), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: Self.routeHeader)
        let recorded = TIDALRecordedRequest(
            method: request.httpMethod ?? "GET", url: url, headers: headers,
            body: request.httpBody ?? Data(), timeoutInterval: request.timeoutInterval
        )
        let target = Delivery(target: self)
        let task = Task {
            // Hop off the loader's thread, as a real server answers later.
            await Task.yield()
            let reply = server.reply(to: recorded)
            guard !Task.isCancelled else { return }
            target.target.deliver(reply, server: server)
        }
        work.withLock { $0 = task }
    }

    private struct Delivery: @unchecked Sendable {
        let target: TrackDLURLProtocol
    }

    override func stopLoading() {
        work.withLock { $0?.cancel() }
    }

    private func deliver(_ reply: TrackDLReply, server: TrackDLServer) {
        guard let url = request.url else { return }
        switch reply {
        case let .data(status, headers, body, chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let size = max((body.count + max(chunks, 1) - 1) / max(chunks, 1), 1)
            var offset = 0
            while offset < body.count {
                let end = min(offset + size, body.count)
                client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
                offset = end
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case let .stall(headers, body, prefix):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body.prefix(prefix))
            server.stalled.set()
        case let .redirect(status, target):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

// MARK: - Fixtures

enum TrackDLFixtures {
    static let trackID: Int64 = 900000101
    static let albumID: Int64 = 800000100
    static let coverID = "1a2b3c4d-0000-4000-8000-00000000abcd"
    /// Signed-looking links, so a test can check none of them reaches a log.
    static let directURL = URL(string: "https://audio.example.test/mediatracks/direct.flac?token=SECRET-TOKEN&sig=abc")!
    static let initURL = "https://audio.example.test/dash/init.mp4?token=SECRET-TOKEN&amp;sig=abc"
    static let mediaTemplate = "https://audio.example.test/dash/$Number$.mp4?token=SECRET-TOKEN&amp;sig=abc"

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func trackJSON(
        title: String = "Blue Lantern", version: String? = nil, duration: Int? = 1,
        albumID: Int64? = albumID, cover: String? = coverID, releaseDate: String? = "2011-05-02",
        artists: [String] = ["Placeholder Artist", "Second Example"], isrc: String? = "ZZX001100003",
        copyright: String? = "2011 Track Copyright", trackNumber: Int? = 3, volumeNumber: Int? = 2
    ) -> Data {
        var album: [String: Any] = ["title": "Harbour Lights"]
        if let albumID { album["id"] = albumID }
        if let cover { album["cover"] = cover }
        if let releaseDate { album["releaseDate"] = releaseDate }
        var track: [String: Any] = [
            "id": trackID, "title": title, "album": album,
            "artists": artists.map { ["name": $0, "type": "MAIN"] },
            "streamStartDate": "2014-01-01T00:00:00.000+0000",
            "audioQuality": "LOSSLESS",
        ]
        if let version { track["version"] = version }
        if let duration { track["duration"] = duration }
        if let isrc { track["isrc"] = isrc }
        if let copyright { track["copyright"] = copyright }
        if let trackNumber { track["trackNumber"] = trackNumber }
        if let volumeNumber { track["volumeNumber"] = volumeNumber }
        return json(track)
    }

    static func albumJSON(
        releaseDate: String = "1985-03-01", cover: String? = coverID,
        artist: String = "Various Artists", copyright: String = "(P) 1985 Album Copyright"
    ) -> Data {
        var album: [String: Any] = [
            "id": albumID, "title": "Harbour Lights", "releaseDate": releaseDate,
            "copyright": copyright, "artist": ["name": artist],
        ]
        if let cover { album["cover"] = cover }
        return json(album)
    }

    enum Manifest {
        case bts(URL, mimeType: String = "audio/flac", codecs: String = "flac")
        case dash(segments: Int)
    }

    static func playbackJSON(
        manifest: Manifest, audioQuality: String = "LOSSLESS", presentation: String? = "FULL",
        bitDepth: Int? = 16, sampleRate: Int? = 44100
    ) -> Data {
        var reply: [String: Any] = ["trackId": trackID, "audioQuality": audioQuality]
        if let presentation { reply["assetPresentation"] = presentation }
        if let bitDepth { reply["bitDepth"] = bitDepth }
        if let sampleRate { reply["sampleRate"] = sampleRate }
        switch manifest {
        case let .bts(url, mimeType, codecs):
            reply["manifestMimeType"] = "application/vnd.tidal.bts"
            let inner = json(["mimeType": mimeType, "codecs": codecs, "encryptionType": "NONE", "urls": [url.absoluteString]])
            reply["manifest"] = inner.base64EncodedString()
        case let .dash(segments):
            reply["manifestMimeType"] = "application/dash+xml"
            reply["manifest"] = Data(dashMPD(segments: segments).utf8).base64EncodedString()
        }
        return json(reply)
    }

    static func dashMPD(segments: Int) -> String {
        """
        <?xml version='1.0' encoding='UTF-8'?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static">
          <Period id="0">
            <AdaptationSet id="0" contentType="audio" mimeType="audio/mp4">
              <Representation id="FLAC,96000,24" codecs="flac" bandwidth="2000000" audioSamplingRate="96000">
                <SegmentTemplate timescale="96000" initialization="\(initURL)" media="\(mediaTemplate)" startNumber="1">
                  <SegmentTimeline><S d="384000" r="\(segments - 1)"/></SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
    }

    /// Splits a joined DASH download back into what the CDN serves: the
    /// init segment (everything before the first segment) and one media
    /// segment per fragment, each starting at its `styp` (or at its `moof`
    /// when there is none).
    static func dashSegments(of data: Data) throws -> (initialization: Data, media: [Data]) {
        let r = FLACByteReader(data)
        let boxes = try FMP4FLACExtractor.boxes(r, in: 0..<data.count)
        var starts: [Int] = []
        for (index, box) in boxes.enumerated() {
            let previous = index > 0 ? boxes[index - 1].type : ""
            if box.type == "styp" || (box.type == "moof" && previous != "styp" && previous != "sidx") {
                starts.append(box.start)
            }
        }
        guard let first = starts.first else { throw CocoaError(.fileReadCorruptFile) }
        let bounds = starts + [data.count]
        let media = (0..<starts.count).map { data.subdata(in: bounds[$0]..<bounds[$0 + 1]) }
        return (data.subdata(in: 0..<first), media)
    }
}

// MARK: - Stand-ins for the other lanes

/// The folder lane's seam, scripted: a decision per extension, and a move
/// that really moves the file (never over an existing one).
final class TrackDLFolderPlanner: DownloadFolderPlanning {
    struct Move: Sendable {
        let temporaryFile: URL
        let plannedName: String
        let fileExtension: FileNaming.AudioExtension
    }

    private let decisions: @Sendable (FileNaming.AudioExtension?) -> FolderDecision?
    private let moveNotes: [SaveNote]
    private let beforeMove: @Sendable (TrackDownloadRequest) throws -> Void
    private let decided = Mutex<[FileNaming.AudioExtension?]>([])
    private let moved = Mutex<[Move]>([])

    /// `beforeMove` runs just before the move, so a test can make it fail
    /// (a full disk) or take the folder away (an unplugged drive).
    init(
        moveNotes: [SaveNote] = [],
        decisions: @escaping @Sendable (FileNaming.AudioExtension?) -> FolderDecision? = { _ in nil },
        beforeMove: @escaping @Sendable (TrackDownloadRequest) throws -> Void = { _ in }
    ) {
        self.decisions = decisions
        self.moveNotes = moveNotes
        self.beforeMove = beforeMove
    }

    var decideCalls: [FileNaming.AudioExtension?] { decided.withLock { $0 } }
    var moves: [Move] { moved.withLock { $0 } }

    func decide(for request: TrackDownloadRequest, fileExtension: FileNaming.AudioExtension?) async throws -> FolderDecision {
        decided.withLock { $0.append(fileExtension) }
        return decisions(fileExtension)
            ?? .save(fileName: FileNaming.fileName(title: request.title, extension: fileExtension ?? .flac), notes: [])
    }

    func moveIntoPlace(_ temporaryFile: URL, for request: TrackDownloadRequest, plannedName: String,
                       fileExtension: FileNaming.AudioExtension) async throws -> (fileName: String, notes: [SaveNote]) {
        moved.withLock { $0.append(Move(temporaryFile: temporaryFile, plannedName: plannedName, fileExtension: fileExtension)) }
        try beforeMove(request)
        try FileManager.default.moveItem(at: temporaryFile, to: request.folder.appendingPathComponent(plannedName))
        return (plannedName, moveNotes)
    }
}

/// The AAC lane's seam: copies the download as the "tagged" file and
/// records what it was given.
final class TrackDLM4AWriter: M4AWriting {
    struct Call: Sendable {
        let source: URL
        let tags: FLACTags
        let coverJPEG: Data?
    }

    private let recorded = Mutex<[Call]>([])
    private let beforeWrite: @Sendable () throws -> Void
    var calls: [Call] { recorded.withLock { $0 } }

    /// `beforeWrite` runs first, so a test can make the write fail.
    init(beforeWrite: @escaping @Sendable () throws -> Void = {}) {
        self.beforeWrite = beforeWrite
    }

    func writeM4A(from source: URL, tags: FLACTags, coverJPEG: Data?, to destination: URL) async throws -> M4AWriteResult {
        recorded.withLock { $0.append(Call(source: source, tags: tags, coverJPEG: coverJPEG)) }
        try beforeWrite()
        let data = try Data(contentsOf: source)
        guard FileManager.default.createFile(atPath: destination.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return M4AWriteResult(durationSeconds: 1.5)
    }
}

/// Lines given to the activity log.
final class TrackDLLog: Sendable {
    private let list = Mutex<[String]>([])
    func append(_ line: String) { list.withLock { $0.append(line) } }
    var lines: [String] { list.withLock { $0 } }
}

/// Progress values a download reported.
final class TrackDLProgress: Sendable {
    private let list = Mutex<[Double]>([])
    func append(_ value: Double) { list.withLock { $0.append(value) } }
    var values: [Double] { list.withLock { $0 } }
}

// MARK: - One test's world

/// Everything one download test needs, in its own temporary folder.
final class TrackDLWorld: Sendable {
    let server: TrackDLServer
    let clock = TIDALTestClock()
    let store: TIDALMemoryStore
    let keeper: TokenKeeper
    let api: TIDALAPI
    let audioClient: HTTPClient
    let base: URL
    let folder: URL
    let temporaries: TemporaryDownloads
    let planner: TrackDLFolderPlanner
    let m4a: any M4AWriting
    let log = TrackDLLog()
    let progress = TrackDLProgress()

    /// `systemFolderNear`, when given, stands in for macOS's per-disk
    /// temporary folder (2.2).
    init(
        _ routes: TrackDLRoutes = TrackDLRoutes(), planner: TrackDLFolderPlanner = TrackDLFolderPlanner(),
        m4a: any M4AWriting = TrackDLM4AWriter(),
        systemFolderNear: (@Sendable (URL) throws -> URL)? = nil
    ) throws {
        server = TrackDLServer(routes)
        store = TIDALMemoryStore(TIDALClientFixtures.credential())
        let apiClient = server.makeClient(limits: .api, clock: clock)
        keeper = TokenKeeper(store: store, client: apiClient, keys: TIDALClientFixtures.keys)
        api = TIDALAPI(client: apiClient, keeper: keeper)
        audioClient = server.makeClient(limits: .audio, clock: clock)
        base = try AudioFixture.temporaryFolder()
        folder = base.appendingPathComponent("TIDAL", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let registry = base.appendingPathComponent("temporary-downloads.json")
        temporaries = systemFolderNear.map { TemporaryDownloads(registryFile: registry, systemFolderNear: $0) }
            ?? TemporaryDownloads(registryFile: registry)
        self.planner = planner
        self.m4a = m4a
    }

    func downloader(
        freeSpace: @escaping TrackDownloader.FreeSpace = { _ in 10_000_000_000 },
        trash: [URL] = []
    ) -> TrackDownloader {
        let log = self.log
        return TrackDownloader(
            api: api, audioClient: audioClient, folderPlanner: planner, m4aWriter: m4a,
            temporaries: temporaries, freeSpace: freeSpace, trashDirectories: { trash },
            log: { log.append($0) }
        )
    }

    func request(
        title: String = "Blue Lantern", version: String? = nil, expectsHiRes: Bool = false, folder: URL? = nil
    ) -> TrackDownloadRequest {
        TrackDownloadRequest(
            rowID: UUID(), tidalID: TrackDLFixtures.trackID, title: title, version: version,
            artist: "Placeholder Artist, Second Example", durationSeconds: 1,
            expectsHiRes: expectsHiRes, folder: folder ?? self.folder
        )
    }

    func download(_ request: TrackDownloadRequest? = nil, using downloader: TrackDownloader? = nil) async throws -> TrackDownloadOutcome {
        let progress = self.progress
        return try await (downloader ?? self.downloader()).download(request ?? self.request()) { progress.append($0) }
    }

    /// The files in the download folder.
    var savedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// No temporary folder is left listed or on disk.
    var temporariesAreGone: Bool {
        temporaries.registered.isEmpty && planner.moves.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.temporaryFile.deletingLastPathComponent().path)
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}
