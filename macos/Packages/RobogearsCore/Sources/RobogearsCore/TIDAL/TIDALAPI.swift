import Foundation

/// Thin wrappers around the TIDAL v1 endpoints the app uses
/// (tidal-and-spotify-networking.md, component C), returning the raw JSON
/// body. The models lane decodes it; keeping the bytes here means nothing
/// TIDAL sends is lost before the models exist.
///
/// Every call goes through the token keeper (current token, one renewal and
/// one retry on a 401), carries the account's country, and uses the shared
/// retry rule (G1-4). A non-200 answer throws the matching `RequestError`,
/// so "TIDAL is busy" and "removed from TIDAL" are never confused with an
/// empty result. This differs on purpose from today's `getAlbumInfo` and
/// `getPlaylistInfo`, which returned null on any failure and silently lost
/// the year and copyright (G1 missing card on cover and album details).
public struct TIDALAPI: Sendable {
    /// The stream quality to ask for. Hi-Res first, then lossless, is the
    /// download rule (product rule 5); previews ask for lossless.
    public enum Quality: String, Sendable, CaseIterable {
        case hiResLossless = "HI_RES_LOSSLESS"
        case lossless = "LOSSLESS"
        /// 320 kbps AAC, asked for only after TIDAL clearly refused both
        /// lossless tiers: the last step of rule 5's chain (Hi-Res, then
        /// lossless, then .m4a; decision 4, items 2.10 and 2.21).
        case high = "HIGH"
    }

    static let base = "https://api.tidal.com"
    /// Album and playlist items come 100 at a time, as today.
    public static let pageSize = 100
    /// Today's search size everywhere (`tidal_lib.js:298`).
    public static let defaultSearchLimit = 10
    /// A guard the Electron loop lacked: a server that ignored `offset` and
    /// kept sending full pages would have looped forever (reference edge
    /// case). 500 pages is 50,000 items, far past any real album or playlist.
    public static let maxPages = 500

    let client: HTTPClient
    let keeper: TokenKeeper
    let retry: RetryPolicy

    public init(client: HTTPClient, keeper: TokenKeeper, retry: RetryPolicy = .standard) {
        self.client = client
        self.keeper = keeper
        self.retry = retry
    }

    // MARK: Endpoints

    /// `GET /v1/tracks/{id}?countryCode=`
    public func track(id: Int) async throws -> Data {
        let country = try await keeper.country().code
        return try await get("/v1/tracks/\(id)", [(name: "countryCode", value: country)])
    }

    /// `GET /v1/albums/{id}?countryCode=`
    public func album(id: Int) async throws -> Data {
        let country = try await keeper.country().code
        return try await get("/v1/albums/\(id)", [(name: "countryCode", value: country)])
    }

    /// `GET /v1/albums/{id}/items?countryCode=&limit=100&offset=N`, every
    /// page in order (each body as TIDAL sent it).
    public func albumItemPages(id: Int) async throws -> [Data] {
        try await pages("/v1/albums/\(id)/items")
    }

    /// `GET /v1/playlists/{uuid}?countryCode=`. The id is percent-encoded as
    /// a path segment; today the captured text went into the path raw
    /// (reference bug 25).
    public func playlist(id: String) async throws -> Data {
        let country = try await keeper.country().code
        return try await get("/v1/playlists/\(URIComponent.encode(id))", [(name: "countryCode", value: country)])
    }

    /// `GET /v1/playlists/{uuid}/items?countryCode=&limit=100&offset=N`.
    public func playlistItemPages(id: String) async throws -> [Data] {
        try await pages("/v1/playlists/\(URIComponent.encode(id))/items")
    }

    /// `GET /v1/tracks/{id}/playbackinfopostpaywall?countryCode=&audioquality=
    /// &playbackmode=STREAM&assetpresentation=FULL`
    public func playbackInfo(trackID: Int, quality: Quality) async throws -> Data {
        let country = try await keeper.country().code
        return try await get("/v1/tracks/\(trackID)/playbackinfopostpaywall", [
            (name: "countryCode", value: country),
            (name: "audioquality", value: quality.rawValue),
            (name: "playbackmode", value: "STREAM"),
            (name: "assetpresentation", value: "FULL"),
        ])
    }

    /// The same playback request, answered with TIDAL's reply as it came
    /// instead of an error for every status other than 200. The download
    /// needs the refusal itself: a 4xx for one quality means "step down to
    /// the next", while a 429, a 5xx or a timeout must never cause a step
    /// down (decision 4, item 2.21), and a refusal's sub-status and message
    /// tell "not in your country" from "not at this quality" (1.4).
    ///
    /// As with every call: the shared retry rule runs first (so a 429 or
    /// 5xx that outlasts it throws `busy` or `server`), a 401 renews the
    /// sign-in once and retries once (a second 401 throws `unauthorized`),
    /// and a web page or redirect instead of TIDAL throws `offline`.
    public func playbackInfoResponse(trackID: Int, quality: Quality) async throws -> HTTPResponse {
        let country = try await keeper.country().code
        let client = self.client, retry = self.retry
        let path = "/v1/tracks/\(trackID)/playbackinfopostpaywall"
        let parameters = [
            (name: "countryCode", value: country),
            (name: "audioquality", value: quality.rawValue),
            (name: "playbackmode", value: "STREAM"),
            (name: "assetpresentation", value: "FULL"),
        ]
        return try await keeper.withAuthorizedRequest { token in
            let response = try await client.send(Self.request(path: path, parameters: parameters, bearer: token), retry: retry)
            if let interference = response.networkInterference() { throw interference }
            if response.status == 401 { throw RequestError.unauthorized(subStatus: response.subStatus) }
            if response.status == 200 { _ = try response.requireJSONBody() }
            return response
        }
    }

    /// `GET /v1/search/tracks?query=&limit=&countryCode=`, in that order.
    /// The query is encoded like `encodeURIComponent`, so `+` arrives as `+`.
    public func searchTracks(query: String, limit: Int = TIDALAPI.defaultSearchLimit) async throws -> Data {
        let country = try await keeper.country().code
        return try await get("/v1/search/tracks", [
            (name: "query", value: query),
            (name: "limit", value: String(limit)),
            (name: "countryCode", value: country),
        ])
    }

    /// `GET /v1/users/{id}?countryCode=US`. US is what today's lookup sends;
    /// the call exists to find the country, so it can't use the account's.
    public func user(id: Int) async throws -> Data {
        try await get("/v1/users/\(id)", [(name: "countryCode", value: "US")])
    }

    /// `GET /v1/tracks?isrc=&countryCode=`. Never reached in the Electron
    /// app (Spotify embeds carry no ISRC); kept for imports that have one.
    public func tracks(isrc: String) async throws -> Data {
        let country = try await keeper.country().code
        return try await get("/v1/tracks", [
            (name: "isrc", value: isrc),
            (name: "countryCode", value: country),
        ])
    }

    // MARK: Plumbing

    /// A GET on api.tidal.com with today's headers and a query built like
    /// `tidalGet`: keys raw, values encoded, order kept.
    static func request(path: String, parameters: [(name: String, value: String)], bearer: String) -> HTTPRequest {
        let query = parameters.isEmpty ? "" : "?" + URIComponent.query(parameters)
        guard let url = URL(string: base + path + query) else {
            preconditionFailure("TIDAL API paths are built from encoded parts only.")
        }
        return HTTPRequest(method: .get, url: url, headers: TIDALHeaders.api(bearer: bearer))
    }

    private func get(_ path: String, _ parameters: [(name: String, value: String)]) async throws -> Data {
        let client = self.client, retry = self.retry
        return try await keeper.withAuthorizedRequest { token in
            let response = try await client.send(Self.request(path: path, parameters: parameters, bearer: token), retry: retry)
            _ = try response.requireOK()
            return try response.requireJSONBody()
        }
    }

    /// Fetches pages until one holds fewer than 100 items, as today. A list
    /// whose size is an exact multiple of 100 costs one extra, empty request,
    /// also as today.
    private func pages(_ path: String) async throws -> [Data] {
        var pages: [Data] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let country = try await keeper.country().code
            let page = try await get(path, [
                (name: "countryCode", value: country),
                (name: "limit", value: String(Self.pageSize)),
                (name: "offset", value: String(offset)),
            ])
            pages.append(page)
            if try Self.itemCount(in: page) < Self.pageSize { return pages }
            guard pages.count < Self.maxPages else {
                throw RequestError.decoding(detail: "TIDAL kept sending full pages past \(Self.maxPages * Self.pageSize) items")
            }
            offset += Self.pageSize
        }
    }

    /// How many entries a page's `items` array holds; a missing array counts
    /// as empty, like `json.items || []`.
    static func itemCount(in page: Data) throws -> Int {
        do {
            return try JSONDecoder().decode(ItemsPage.self, from: page).items?.count ?? 0
        } catch {
            throw RequestError.decoding(detail: "a page of items wasn't the expected JSON")
        }
    }
}

private struct ItemsPage: Decodable {
    let items: [AnyEntry]?

    /// Accepts any JSON value; only the count matters here.
    struct AnyEntry: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

// MARK: - One page at a time (resolver lane)

extension TIDALAPI {
    /// `GET /v1/albums/{id}/items?countryCode=&limit=100&offset=N`, one page.
    /// The resolver pages itself so a long list can show "Loading 300 of
    /// 1,250 tracks…" (D4 4.21), stop between pages when cancelled (D4 1.11),
    /// and free its slot in the shared pace between pages (D4 1.4).
    public func albumItemsPage(id: Int, offset: Int) async throws -> Data {
        try await itemsPage("/v1/albums/\(id)/items", offset: offset)
    }

    /// `GET /v1/playlists/{uuid}/items?countryCode=&limit=100&offset=N`, one page.
    public func playlistItemsPage(id: String, offset: Int) async throws -> Data {
        try await itemsPage("/v1/playlists/\(URIComponent.encode(id))/items", offset: offset)
    }

    private func itemsPage(_ path: String, offset: Int) async throws -> Data {
        let country = try await keeper.country().code
        return try await get(path, [
            (name: "countryCode", value: country),
            (name: "limit", value: String(Self.pageSize)),
            (name: "offset", value: String(offset)),
        ])
    }
}
