import Foundation
import Synchronization
@testable import RobogearsCore

// A small fake of the TIDAL API and Spotify's public pages, answering by
// path, behind the TIDAL lane's mock URLProtocol. Every title, artist, ISRC
// and id is invented.

// MARK: - JSON and HTML builders

enum ResolveJSON {
    /// One TIDAL track object.
    static func track(
        _ id: Int64, _ title: String, artists: [String], duration: Int? = 200, isrc: String? = nil,
        version: String? = nil, explicit: Bool = false, hiRes: Bool = false, album: String? = "Glass Orchard",
        type: String? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "title": title, "explicit": explicit, "audioQuality": "LOSSLESS",
            "mediaMetadata": ["tags": hiRes ? ["LOSSLESS", "HIRES_LOSSLESS"] : ["LOSSLESS"]],
            "artists": artists.enumerated().map { ["id": 7_100_000 + $0.offset, "name": $0.element] },
        ]
        if let duration { object["duration"] = duration }
        if let isrc { object["isrc"] = isrc }
        if let version { object["version"] = version }
        if let album { object["album"] = ["id": 8_100_000, "title": album] }
        if let type { object["type"] = type }
        return object
    }

    /// A search or ISRC reply: bare tracks.
    static func results(_ tracks: [[String: Any]]) -> Data {
        data(["limit": 10, "offset": 0, "totalNumberOfItems": tracks.count, "items": tracks])
    }

    /// One page of album or playlist items, each wrapped as TIDAL sends them.
    static func itemsPage(_ tracks: [[String: Any]], offset: Int, total: Int) -> Data {
        let items = tracks.map { track -> [String: Any] in
            ["item": track, "type": (track["type"] as? String) == "video" ? "video" : "track"]
        }
        return data(["limit": 100, "offset": offset, "totalNumberOfItems": total, "items": items])
    }

    static func data(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

enum ResolveSpotifyHTML {
    struct Track {
        var title: String
        var artists: String
        var milliseconds: Int = 200_000
    }

    static func page(entity: [String: Any]) -> Data {
        let root: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
        let json = String(decoding: ResolveJSON.data(root), as: UTF8.self)
        return Data("""
        <!DOCTYPE html><html><head><title>Spotify Embed</title></head><body>\
        <script id="__NEXT_DATA__" type="application/json">\(json)</script></body></html>
        """.utf8)
    }

    static func playlist(_ id: String, name: String, tracks: [Track], extra: [String: Any] = [:]) -> Data {
        var entity: [String: Any] = [
            "type": "playlist", "id": id, "name": name, "subtitle": "Placeholder Owner",
            "trackList": tracks.enumerated().map { index, track in
                ["uri": "spotify:track:SynTrack\(index)", "title": track.title,
                 "subtitle": track.artists, "duration": track.milliseconds]
            },
        ]
        entity.merge(extra) { $1 }
        return page(entity: entity)
    }

    static func album(_ id: String, name: String, artists: [String], tracks: [Track]) -> Data {
        page(entity: [
            "type": "album", "id": id, "name": name,
            "artists": artists.map { ["name": $0] },
            "trackList": tracks.enumerated().map { index, track in
                ["uri": "spotify:track:SynAlbumTrack\(index)", "title": track.title,
                 "subtitle": track.artists, "duration": track.milliseconds]
            },
        ])
    }
}

// MARK: - The fake backend

/// Answers TIDAL API and Spotify requests from what a test put in. Anything
/// not set up answers 404, so a stray request shows in the test.
final class ResolveFakeBackend: Sendable {
    struct State {
        var searches: [String: Data] = [:]
        var isrcs: [String: Data] = [:]
        var tracks: [Int64: Data] = [:]
        var albums: [Int64: Data] = [:]
        var albumPages: [Int64: [Data]] = [:]
        var playlists: [String: Data] = [:]
        var playlistPages: [String: [Data]] = [:]
        var webPages: [String: Data] = [:]
        var redirects: [String: String] = [:]
    }

    typealias Override = @Sendable (TIDALRecordedRequest, Int) async -> TIDALMockReply?

    private let state = Mutex(State())
    private let override = Mutex<Override?>(nil)

    func setUp(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    /// Answers before the routes; return nil to fall through to them.
    func intercept(_ handler: @escaping Override) { override.withLock { $0 = handler } }

    func search(_ query: String, _ tracks: [[String: Any]]) {
        let reply = ResolveJSON.results(tracks)
        setUp { $0.searches[query] = reply }
    }

    func reply(to request: TIDALRecordedRequest, index: Int) async -> TIDALMockReply {
        if let handler = override.withLock({ $0 }), let reply = await handler(request, index) { return reply }
        let snapshot = state.withLock { $0 }
        let url = request.url
        let host = url.host ?? ""
        let path = url.path
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        if host == "api.tidal.com" {
            let parts = path.split(separator: "/").map(String.init)
            switch parts.count {
            case 3 where parts[1] == "search":
                return .json(200, snapshot.searches[query["query"] ?? ""] ?? ResolveJSON.results([]))
            case 2 where parts[1] == "tracks":
                return .json(200, snapshot.isrcs[query["isrc"] ?? ""] ?? ResolveJSON.results([]))
            case 3 where parts[1] == "tracks":
                if let id = Int64(parts[2]), let body = snapshot.tracks[id] { return .json(200, body) }
            case 3 where parts[1] == "albums":
                if let id = Int64(parts[2]), let body = snapshot.albums[id] { return .json(200, body) }
            case 4 where parts[1] == "albums" && parts[3] == "items":
                if let id = Int64(parts[2]), let pages = snapshot.albumPages[id] {
                    let page = (Int(query["offset"] ?? "0") ?? 0) / 100
                    if page < pages.count { return .json(200, pages[page]) }
                }
            case 3 where parts[1] == "playlists":
                if let body = snapshot.playlists[parts[2]] { return .json(200, body) }
            case 4 where parts[1] == "playlists" && parts[3] == "items":
                if let pages = snapshot.playlistPages[parts[2]] {
                    let page = (Int(query["offset"] ?? "0") ?? 0) / 100
                    if page < pages.count { return .json(200, pages[page]) }
                }
            default:
                break
            }
            return .json(404, "{\"status\":404,\"subStatus\":2001,\"userMessage\":\"not found\"}")
        }
        if let location = snapshot.redirects[url.absoluteString] {
            return .redirect(to: URL(string: location)!)
        }
        if let page = snapshot.webPages[url.absoluteString] {
            return .response(status: 200, headers: ["Content-Type": "text/html"], body: page, chunks: 1)
        }
        return .response(status: 404, headers: ["Content-Type": "text/html"], body: Data("<html>gone</html>".utf8), chunks: 1)
    }
}

// MARK: - A resolver wired to the fake

struct ResolveHarness {
    let backend: ResolveFakeBackend
    let server: TIDALMockServer
    let pace: TIDALPace
    let resolver: TrackResolver

    init(
        library: any LibraryMarking = NoLibrary(),
        credential: TIDALCredential? = TIDALClientFixtures.credential(),
        clock: any NetworkClock = TIDALTestClock(),
        paceLimits: TIDALPace.Limits = .standard
    ) {
        let backend = ResolveFakeBackend()
        let server = TIDALMockServer { request, index in await backend.reply(to: request, index: index) }
        let pace = TIDALPace(limits: paceLimits, clock: clock)
        let client = HTTPClient(clock: clock, sessionConfiguration: server.sessionConfiguration(), pacing: pace)
        let keeper = TokenKeeper(store: TIDALMemoryStore(credential), client: client, keys: TIDALClientFixtures.keys)
        let web = HTTPClient(clock: clock, sessionConfiguration: server.sessionConfiguration())
        self.backend = backend
        self.server = server
        self.pace = pace
        self.resolver = TrackResolver(tidal: TIDALAPI(client: client, keeper: keeper), pace: pace, web: web, library: library)
    }

    /// Runs an add to its end and returns every event.
    func run(_ source: ResolveSource, queue: QueueContents = .empty) async -> [ResolveEvent] {
        var events: [ResolveEvent] = []
        for await event in resolver.add(source, queue: queue) { events.append(event) }
        return events
    }

    /// The TIDAL API paths requested, in order, with their query.
    var tidalRequests: [String] {
        server.requests.filter { $0.url.host == "api.tidal.com" }.map { request in
            request.url.path + (request.url.query.map { "?" + $0 } ?? "")
        }
    }

    var searchQueries: [String] {
        server.requests.filter { $0.url.path == "/v1/search/tracks" }.compactMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value
        }
    }
}

extension Array where Element == ResolveEvent {
    var rows: [QueueItem] {
        flatMap { event -> [QueueItem] in
            if case let .rows(rows) = event { return rows }
            return []
        }
    }

    var summary: ResolveSummary? {
        compactMap { event -> ResolveSummary? in
            if case let .finished(summary) = event { return summary }
            return nil
        }.last
    }

    var failure: ResolveFailure? {
        compactMap { event -> ResolveFailure? in
            if case let .failed(failure) = event { return failure }
            return nil
        }.last
    }

    var progress: [ResolveProgress] {
        compactMap { event -> ResolveProgress? in
            if case let .progress(progress) = event { return progress }
            return nil
        }
    }

    var caps: [SpotifyCapNotice] {
        compactMap { event -> SpotifyCapNotice? in
            if case let .capped(notice) = event { return notice }
            return nil
        }
    }

    var logs: [String] {
        compactMap { event -> String? in
            if case let .log(line) = event { return line }
            return nil
        }
    }
}

/// Library marks a test controls: pending until `ready` is set, then the
/// answer for each title.
final class ResolveFakeLibrary: LibraryMarking {
    private let state = Mutex<(ready: Bool, marks: [String: QueueItem.LibraryMatch])>((true, [:]))

    init(ready: Bool = true, marks: [String: QueueItem.LibraryMatch] = [:]) {
        state.withLock { $0 = (ready, marks) }
    }

    func setReady(_ ready: Bool) { state.withLock { $0.ready = ready } }

    func mark(for query: LibraryMatcher.Query) -> LibraryMark {
        state.withLock { state in
            state.ready ? .checked(state.marks[query.title]) : .pending
        }
    }
}
