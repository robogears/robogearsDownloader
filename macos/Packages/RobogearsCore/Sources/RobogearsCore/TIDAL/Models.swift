import Foundation

// The TIDAL v1 objects the app reads, and the queue-ready track built from them.
//
// Every field is optional because TIDAL omits fields freely, and every field
// decodes leniently: a field with an unexpected type becomes nil instead of
// failing the whole response. One odd value must never make a 100-track album
// page unreadable (reference: tidal-and-spotify-networking.md, porting note
// "JSON decoding"; the Electron code read these objects with optional chaining,
// which never failed on shape).

// MARK: - Shared pieces

/// An artist as it appears inside tracks and albums.
public struct TIDALArtist: Codable, Sendable, Hashable {
    public var id: Int64?
    public var name: String?
    /// For example `MAIN` or `FEATURED`.
    public var type: String?

    public init(id: Int64? = nil, name: String? = nil, type: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        name = c.lenientString(.name)
        type = c.lenientString(.type)
    }
}

/// `mediaMetadata` on tracks and albums. Its `tags` carry `HIRES_LOSSLESS`
/// when a Hi-Res master exists.
public struct TIDALMediaMetadata: Codable, Sendable, Hashable {
    public var tags: [String]?

    public init(tags: [String]? = nil) {
        self.tags = tags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = c.lenientArrayIfPresent(String.self, .tags)
    }
}

/// The audio-quality labels TIDAL uses, and the one rule for what counts as
/// lossless. Values stay plain strings in the models so labels TIDAL adds
/// later still decode.
public enum TIDALAudioQuality {
    public static let low = "LOW"
    public static let high = "HIGH"
    public static let lossless = "LOSSLESS"
    public static let hiResLossless = "HI_RES_LOSSLESS"
    /// The old MQA label; still treated as lossless, as the Electron app did
    /// (download-pipeline.md, open question 11).
    public static let hiRes = "HI_RES"

    /// The tiers whose files are saved as `.flac`
    /// (download-pipeline.md B5 step 12, `tidal_download.js:401`).
    public static let losslessTiers: Set<String> = [lossless, hiResLossless, hiRes]

    /// The tag in `mediaMetadata.tags` that marks a Hi-Res master.
    public static let hiResTag = "HIRES_LOSSLESS"

    /// True when `quality` is one of the lossless tiers. Compared without
    /// regard to case so a lowercase label can't turn a lossless track into AAC.
    public static func isLosslessTier(_ quality: String?) -> Bool {
        guard let quality else { return false }
        return losslessTiers.contains(quality.uppercased())
    }
}

// MARK: - Album

/// An album, either embedded in a track (`id`, `title`, `cover`, sometimes
/// `releaseDate`) or fetched in full from `/v1/albums/{id}`.
public struct TIDALAlbum: Codable, Sendable, Hashable {
    public var id: Int64?
    public var title: String?
    public var version: String?
    /// The cover image id, a UUID with dashes (`resources.tidal.com` path).
    public var cover: String?
    /// `YYYY-MM-DD`. The file's year tag is its first four characters.
    public var releaseDate: String?
    public var copyright: String?
    public var duration: Int?
    public var numberOfTracks: Int?
    public var numberOfVolumes: Int?
    public var explicit: Bool?
    public var audioQuality: String?
    public var upc: String?
    public var type: String?
    public var artist: TIDALArtist?
    public var artists: [TIDALArtist]?
    public var mediaMetadata: TIDALMediaMetadata?

    public init(
        id: Int64? = nil, title: String? = nil, version: String? = nil, cover: String? = nil,
        releaseDate: String? = nil, copyright: String? = nil, duration: Int? = nil,
        numberOfTracks: Int? = nil, numberOfVolumes: Int? = nil, explicit: Bool? = nil,
        audioQuality: String? = nil, upc: String? = nil, type: String? = nil,
        artist: TIDALArtist? = nil, artists: [TIDALArtist]? = nil,
        mediaMetadata: TIDALMediaMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.cover = cover
        self.releaseDate = releaseDate
        self.copyright = copyright
        self.duration = duration
        self.numberOfTracks = numberOfTracks
        self.numberOfVolumes = numberOfVolumes
        self.explicit = explicit
        self.audioQuality = audioQuality
        self.upc = upc
        self.type = type
        self.artist = artist
        self.artists = artists
        self.mediaMetadata = mediaMetadata
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        title = c.lenientString(.title)
        version = c.lenientString(.version)
        cover = c.lenientString(.cover)
        releaseDate = c.lenientString(.releaseDate)
        copyright = c.lenientString(.copyright)
        duration = c.lenientInt(.duration)
        numberOfTracks = c.lenientInt(.numberOfTracks)
        numberOfVolumes = c.lenientInt(.numberOfVolumes)
        explicit = c.lenientBool(.explicit)
        audioQuality = c.lenientString(.audioQuality)
        upc = c.lenientString(.upc)
        type = c.lenientString(.type)
        artist = c.lenient(TIDALArtist.self, .artist)
        artists = c.lenientArrayIfPresent(TIDALArtist.self, .artists)
        mediaMetadata = c.lenient(TIDALMediaMetadata.self, .mediaMetadata)
    }

    /// The cover image on TIDAL's image server: every `-` in the id becomes
    /// `/`, then `<size>x<size>.jpg`. Nil when the album has no cover id
    /// (tidal-and-spotify-networking.md H, `coverUrl`).
    public func coverURL(size: Int = 1280) -> URL? {
        guard let cover, !cover.isEmpty else { return nil }
        let path = cover.replacingOccurrences(of: "-", with: "/")
        return URL(string: "https://resources.tidal.com/images/\(path)/\(size)x\(size).jpg")
    }
}

// MARK: - Track

/// A track from `/v1/tracks/{id}`, a search result, or an album or playlist page.
public struct TIDALTrack: Codable, Sendable, Hashable {
    public var id: Int64?
    /// TIDAL's bare title, without the edition text in `version`.
    public var title: String?
    /// The edition, for example `Radio Edit` or `2011 Remaster`. Never read by
    /// the Electron app (decision cards G3-12, G2-6).
    public var version: String?
    /// Seconds.
    public var duration: Int?
    public var trackNumber: Int?
    public var volumeNumber: Int?
    public var isrc: String?
    public var copyright: String?
    public var explicit: Bool?
    public var audioQuality: String?
    public var audioModes: [String]?
    public var mediaMetadata: TIDALMediaMetadata?
    public var streamStartDate: String?
    /// Whether TIDAL will stream the track. Read so a row can be marked before
    /// Download All (G2-X4 skeptic); what TIDAL actually sends is unverified.
    public var allowStreaming: Bool?
    public var streamReady: Bool?
    /// Present on some list items; `video` marks a music video.
    public var type: String?
    public var artists: [TIDALArtist]?
    /// The main artist, used when `artists` is empty.
    public var artist: TIDALArtist?
    public var album: TIDALAlbum?

    public init(
        id: Int64? = nil, title: String? = nil, version: String? = nil, duration: Int? = nil,
        trackNumber: Int? = nil, volumeNumber: Int? = nil, isrc: String? = nil,
        copyright: String? = nil, explicit: Bool? = nil, audioQuality: String? = nil,
        audioModes: [String]? = nil, mediaMetadata: TIDALMediaMetadata? = nil,
        streamStartDate: String? = nil, allowStreaming: Bool? = nil, streamReady: Bool? = nil,
        type: String? = nil, artists: [TIDALArtist]? = nil, artist: TIDALArtist? = nil,
        album: TIDALAlbum? = nil
    ) {
        self.id = id
        self.title = title
        self.version = version
        self.duration = duration
        self.trackNumber = trackNumber
        self.volumeNumber = volumeNumber
        self.isrc = isrc
        self.copyright = copyright
        self.explicit = explicit
        self.audioQuality = audioQuality
        self.audioModes = audioModes
        self.mediaMetadata = mediaMetadata
        self.streamStartDate = streamStartDate
        self.allowStreaming = allowStreaming
        self.streamReady = streamReady
        self.type = type
        self.artists = artists
        self.artist = artist
        self.album = album
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        title = c.lenientString(.title)
        version = c.lenientString(.version)
        duration = c.lenientInt(.duration)
        trackNumber = c.lenientInt(.trackNumber)
        volumeNumber = c.lenientInt(.volumeNumber)
        isrc = c.lenientString(.isrc)
        copyright = c.lenientString(.copyright)
        explicit = c.lenientBool(.explicit)
        audioQuality = c.lenientString(.audioQuality)
        audioModes = c.lenientArrayIfPresent(String.self, .audioModes)
        mediaMetadata = c.lenient(TIDALMediaMetadata.self, .mediaMetadata)
        streamStartDate = c.lenientString(.streamStartDate)
        allowStreaming = c.lenientBool(.allowStreaming)
        streamReady = c.lenientBool(.streamReady)
        type = c.lenientString(.type)
        artists = c.lenientArrayIfPresent(TIDALArtist.self, .artists)
        artist = c.lenient(TIDALArtist.self, .artist)
        album = c.lenient(TIDALAlbum.self, .album)
    }

    /// Every artist name in TIDAL's order, falling back to the single `artist`
    /// when the list is empty (the tag writer's fallback, download-pipeline.md
    /// B11). Blank names are dropped, as JavaScript's `join` dropped `undefined`.
    public var artistNames: [String] {
        let listed = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }
        if !listed.isEmpty { return listed }
        if let name = artist?.name, !name.isEmpty { return [name] }
        return []
    }

    /// One Hi-Res rule for every path: link, search, import and Spotify match
    /// all read the same tag (G4-10; the Electron import path never set it).
    public var isHiRes: Bool {
        mediaMetadata?.tags?.contains(TIDALAudioQuality.hiResTag) ?? false
    }

    /// True when the item is a music video rather than a track. The Electron
    /// code checked only the inner item's `type` against exactly `video`
    /// (tidal-and-spotify-networking.md bug 19); this reads it without regard
    /// to case and also catches labels such as `Music Video`.
    public var isVideo: Bool {
        type?.lowercased().contains("video") ?? false
    }
}

// MARK: - Playlist

/// A playlist from `/v1/playlists/{uuid}`. Its id is a UUID string, not a number.
public struct TIDALPlaylist: Codable, Sendable, Hashable {
    public var uuid: String?
    public var title: String?
    public var description: String?
    public var numberOfTracks: Int?
    public var numberOfVideos: Int?
    public var duration: Int?
    public var type: String?
    public var image: String?
    public var squareImage: String?

    public init(
        uuid: String? = nil, title: String? = nil, description: String? = nil,
        numberOfTracks: Int? = nil, numberOfVideos: Int? = nil, duration: Int? = nil,
        type: String? = nil, image: String? = nil, squareImage: String? = nil
    ) {
        self.uuid = uuid
        self.title = title
        self.description = description
        self.numberOfTracks = numberOfTracks
        self.numberOfVideos = numberOfVideos
        self.duration = duration
        self.type = type
        self.image = image
        self.squareImage = squareImage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = c.lenientString(.uuid)
        title = c.lenientString(.title)
        description = c.lenientString(.description)
        numberOfTracks = c.lenientInt(.numberOfTracks)
        numberOfVideos = c.lenientInt(.numberOfVideos)
        duration = c.lenientInt(.duration)
        type = c.lenientString(.type)
        image = c.lenientString(.image)
        squareImage = c.lenientString(.squareImage)
    }
}

// MARK: - Pages

/// One page of a list: album items, playlist items or search results. TIDAL
/// pages 100 at a time; `totalNumberOfItems` lets a caller stop without the
/// extra empty request the Electron paging made (tidal-and-spotify-networking.md C).
public struct TIDALPage<Item: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var limit: Int?
    public var offset: Int?
    public var totalNumberOfItems: Int?
    /// Elements that can't be read at all (not an object, for example) are
    /// skipped so the rest of the page still arrives.
    public var items: [Item]

    public init(limit: Int? = nil, offset: Int? = nil, totalNumberOfItems: Int? = nil, items: [Item] = []) {
        self.limit = limit
        self.offset = offset
        self.totalNumberOfItems = totalNumberOfItems
        self.items = items
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limit = c.lenientInt(.limit)
        offset = c.lenientInt(.offset)
        totalNumberOfItems = c.lenientInt(.totalNumberOfItems)
        items = c.lenientArrayIfPresent(Item.self, .items) ?? []
    }
}

/// An element of an album or playlist page. TIDAL sends either the wrapper
/// `{ "item": <track>, "type": "track" }` or a bare track; the Electron code
/// read both with `i.item || i` (tidal-and-spotify-networking.md F).
public struct TIDALPageItem: Codable, Sendable, Hashable {
    /// The wrapper's `type` (`track` or `video`), or the bare track's own `type`.
    public var type: String?
    public var track: TIDALTrack?

    public init(type: String? = nil, track: TIDALTrack? = nil) {
        self.type = type
        self.track = track
    }

    private enum CodingKeys: String, CodingKey {
        case item, type
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.item) {
            track = c.lenient(TIDALTrack.self, .item)
            type = c.lenientString(.type)
        } else {
            let bare = try TIDALTrack(from: decoder)
            track = bare
            type = bare.type
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(track, forKey: .item)
        try c.encodeIfPresent(type, forKey: .type)
    }

    /// The track, when this element is a playable music track: it has an id
    /// and neither the wrapper nor the track says video. The wrapper is
    /// checked too because the Electron filter looked only at the inner item
    /// (bug 19, unverified which of the two TIDAL fills in).
    public var musicTrack: TIDALTrack? {
        guard let track, track.id != nil else { return nil }
        if type?.lowercased().contains("video") == true || track.isVideo { return nil }
        return track
    }
}

extension TIDALPage where Item == TIDALPageItem {
    /// The page's music tracks in TIDAL's order, videos and id-less items removed.
    public var musicTracks: [TIDALTrack] {
        items.compactMap(\.musicTrack)
    }
}

/// `/v1/search/tracks` answers with a page of bare tracks.
public typealias TIDALSearchResult = TIDALPage<TIDALTrack>

// MARK: - Playback

/// The reply from `/v1/tracks/{id}/playbackinfopostpaywall`. The manifest is
/// base64; `TIDALManifest` decodes it.
public struct TIDALPlaybackInfo: Codable, Sendable, Hashable {
    public var trackId: Int64?
    public var assetPresentation: String?
    public var audioMode: String?
    /// The tier TIDAL actually delivered, which may be lower than requested.
    public var audioQuality: String?
    /// `application/vnd.tidal.bt`, `application/vnd.tidal.bts` or `application/dash+xml`.
    public var manifestMimeType: String?
    public var manifestHash: String?
    /// Base64 text.
    public var manifest: String?
    /// Read so the saved line can name what arrived ("24-bit/96 kHz", G1-10
    /// skeptic). Whether TIDAL's v1 reply carries these is unverified.
    public var bitDepth: Int?
    public var sampleRate: Int?

    public init(
        trackId: Int64? = nil, assetPresentation: String? = nil, audioMode: String? = nil,
        audioQuality: String? = nil, manifestMimeType: String? = nil, manifestHash: String? = nil,
        manifest: String? = nil, bitDepth: Int? = nil, sampleRate: Int? = nil
    ) {
        self.trackId = trackId
        self.assetPresentation = assetPresentation
        self.audioMode = audioMode
        self.audioQuality = audioQuality
        self.manifestMimeType = manifestMimeType
        self.manifestHash = manifestHash
        self.manifest = manifest
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackId = c.lenientInt64(.trackId)
        assetPresentation = c.lenientString(.assetPresentation)
        audioMode = c.lenientString(.audioMode)
        audioQuality = c.lenientString(.audioQuality)
        manifestMimeType = c.lenientString(.manifestMimeType)
        manifestHash = c.lenientString(.manifestHash)
        manifest = c.lenientString(.manifest)
        bitDepth = c.lenientInt(.bitDepth)
        sampleRate = c.lenientInt(.sampleRate)
    }
}

// MARK: - Users and errors

/// `/v1/users/{id}`; only the country code is used.
public struct TIDALUser: Codable, Sendable, Hashable {
    public var id: Int64?
    public var countryCode: String?

    public init(id: Int64? = nil, countryCode: String? = nil) {
        self.id = id
        self.countryCode = countryCode
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientInt64(.id)
        countryCode = c.lenientString(.countryCode)
    }
}

/// The JSON body `api.tidal.com` sends with an error status. Kept typed so a
/// caller can tell a clear refusal from a busy server without showing the raw
/// body to the person (G5-16, G1-10).
public struct TIDALErrorResponse: Codable, Sendable, Hashable {
    public var status: Int?
    public var subStatus: Int?
    public var userMessage: String?

    public init(status: Int? = nil, subStatus: Int? = nil, userMessage: String? = nil) {
        self.status = status
        self.subStatus = subStatus
        self.userMessage = userMessage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lenientInt(.status)
        subStatus = c.lenientInt(.subStatus)
        userMessage = c.lenientString(.userMessage)
    }
}

// MARK: - Sign-in

/// The reply from `POST auth.tidal.com/v1/oauth2/device_authorization`.
/// The Electron app read only `verificationUriComplete`, `deviceCode` and
/// `interval`; the rest is kept so the sign-in sheet can show the code and a
/// deadline (tidal-sign-in-and-tokens.md, "Responses consumed").
public struct TIDALDeviceAuthorization: Codable, Sendable, Hashable {
    public var deviceCode: String?
    public var userCode: String?
    public var verificationUri: String?
    public var verificationUriComplete: String?
    /// Seconds until the device code stops working.
    public var expiresIn: Int?
    /// Seconds between polls; TIDAL may omit it.
    public var interval: Int?

    public init(
        deviceCode: String? = nil, userCode: String? = nil, verificationUri: String? = nil,
        verificationUriComplete: String? = nil, expiresIn: Int? = nil, interval: Int? = nil
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationUri = verificationUri
        self.verificationUriComplete = verificationUriComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = c.lenientString(.deviceCode)
        userCode = c.lenientString(.userCode)
        verificationUri = c.lenientString(.verificationUri)
        verificationUriComplete = c.lenientString(.verificationUriComplete)
        expiresIn = c.lenientInt(.expiresIn)
        interval = c.lenientInt(.interval)
    }

    /// The poll interval, 5 s when TIDAL leaves it out (the Electron default).
    public var pollInterval: Int {
        if let interval, interval > 0 { return interval }
        return 5
    }

    /// The link to open in the browser. ONBOARDING.md describes it as a bare
    /// `link.tidal.com/...`, so a missing scheme gets `https://` (whether TIDAL
    /// includes it is unverified, README spike 1). Falls back to the plain
    /// verification link when the complete one is missing.
    public var verificationURL: URL? {
        let raw = (verificationUriComplete ?? verificationUri)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        let lowered = raw.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return URL(string: raw)
        }
        return URL(string: "https://" + raw)
    }
}

/// The user block inside a token reply.
public struct TIDALTokenUser: Codable, Sendable, Hashable {
    public var userId: Int64?
    public var countryCode: String?
    public var username: String?

    public init(userId: Int64? = nil, countryCode: String? = nil, username: String? = nil) {
        self.userId = userId
        self.countryCode = countryCode
        self.username = username
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = c.lenientInt64(.userId)
        countryCode = c.lenientString(.countryCode)
        username = c.lenientString(.username)
    }
}

/// A 200 reply from `POST auth.tidal.com/v1/oauth2/token`, for both the
/// device-code grant and a refresh. Its descriptions never show the tokens,
/// so printing or logging one can't leak a credential (owner's manual 2.3).
public struct TIDALTokenGrant: Codable, Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String?
    /// A refresh may return a new refresh token; the Electron app ignored it
    /// (tidal-and-spotify-networking.md bug 17).
    public var refreshToken: String?
    public var tokenType: String?
    /// Seconds; the Electron app assumed 3600 when missing.
    public var expiresIn: Int?
    public var scope: String?
    public var user: TIDALTokenUser?

    public init(
        accessToken: String? = nil, refreshToken: String? = nil, tokenType: String? = nil,
        expiresIn: Int? = nil, scope: String? = nil, user: TIDALTokenUser? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
        self.user = user
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case user
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = c.lenientString(.accessToken)
        refreshToken = c.lenientString(.refreshToken)
        tokenType = c.lenientString(.tokenType)
        expiresIn = c.lenientInt(.expiresIn)
        scope = c.lenientString(.scope)
        user = c.lenient(TIDALTokenUser.self, .user)
    }

    public var description: String {
        let access = accessToken == nil ? "none" : "<redacted>"
        let refresh = refreshToken == nil ? "none" : "<redacted>"
        let expires = expiresIn.map(String.init) ?? "nil"
        let userId = user?.userId.map { String($0) } ?? "nil"
        return "TIDALTokenGrant(accessToken: \(access), refreshToken: \(refresh), expiresIn: \(expires), userId: \(userId))"
    }

    public var debugDescription: String { description }
}

/// The error body of `POST auth.tidal.com/v1/oauth2/token`, for example
/// `authorization_pending`, `slow_down` or `expired_token` while polling.
public struct TIDALOAuthError: Codable, Sendable, Hashable {
    public var error: String?
    public var errorDescription: String?
    public var status: Int?
    public var subStatus: Int?

    public init(error: String? = nil, errorDescription: String? = nil, status: Int? = nil, subStatus: Int? = nil) {
        self.error = error
        self.errorDescription = errorDescription
        self.status = status
        self.subStatus = subStatus
    }

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case status
        case subStatus = "sub_status"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = c.lenientString(.error)
        errorDescription = c.lenientString(.errorDescription)
        status = c.lenientInt(.status)
        subStatus = c.lenientInt(.subStatus)
    }
}

// MARK: - Queue-ready track

/// A TIDAL track in the shape the queue keeps: the facts every row source
/// (link, search, import, Spotify match) reads the same way. It is saved in
/// the queue file, so decoding tolerates missing fields from older saves.
public struct TIDALQueueTrack: Codable, Sendable, Hashable, Identifiable {
    public var tidalId: Int64
    /// TIDAL's bare title. File names come from this alone: `<Title>.flac`
    /// (owner's rule 3; the edition-in-name cards G2-5 and G2-6 are pending).
    public var title: String
    /// The edition text, shown next to the title (G3-12).
    public var version: String?
    public var artists: [String]
    /// The album title.
    public var album: String?
    /// Seconds.
    public var duration: Int?
    public var isrc: String?
    public var hiRes: Bool
    public var explicit: Bool
    /// The tier TIDAL lists for the track, kept so an AAC-only track can be
    /// marked before download (G2-10).
    public var audioQuality: String?

    public var id: Int64 { tidalId }

    public init(
        tidalId: Int64, title: String, version: String? = nil, artists: [String] = [],
        album: String? = nil, duration: Int? = nil, isrc: String? = nil, hiRes: Bool = false,
        explicit: Bool = false, audioQuality: String? = nil
    ) {
        self.tidalId = tidalId
        self.title = title
        self.version = version
        self.artists = artists
        self.album = album
        self.duration = duration
        self.isrc = isrc
        self.hiRes = hiRes
        self.explicit = explicit
        self.audioQuality = audioQuality
    }

    /// Builds the queue value from any TIDAL track reply. Nil when the track
    /// has no id, because nothing can be downloaded without one (the Electron
    /// filter `t?.id`).
    public init?(_ track: TIDALTrack) {
        guard let id = track.id else { return nil }
        let version = track.version?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            tidalId: id,
            title: track.title ?? "",
            version: (version?.isEmpty ?? true) ? nil : version,
            artists: track.artistNames,
            album: track.album?.title,
            duration: track.duration,
            isrc: track.isrc,
            hiRes: track.isHiRes,
            explicit: track.explicit ?? false,
            audioQuality: track.audioQuality
        )
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientInt64(.tidalId) else {
            throw DecodingError.keyNotFound(
                CodingKeys.tidalId,
                .init(codingPath: c.codingPath, debugDescription: "A queued TIDAL track needs its id.")
            )
        }
        tidalId = id
        title = c.lenientString(.title) ?? ""
        version = c.lenientString(.version)
        artists = c.lenientArrayIfPresent(String.self, .artists) ?? []
        album = c.lenientString(.album)
        duration = c.lenientInt(.duration)
        isrc = c.lenientString(.isrc)
        hiRes = c.lenientBool(.hiRes) ?? false
        explicit = c.lenientBool(.explicit) ?? false
        audioQuality = c.lenientString(.audioQuality)
    }

    /// The artists as one line, `A, B`, the way rows and tags always joined them.
    public var artistLine: String {
        artists.joined(separator: ", ")
    }

    /// The title as TIDAL shows it: `Blue Lantern (Extended Mix)`, without
    /// doubling the edition when the title already contains it (G3-12). For
    /// display and matching only, never for file names (rule 3).
    public var displayTitle: String {
        guard let version, !version.isEmpty else { return title }
        if title.range(of: version, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return title
        }
        return title.isEmpty ? version : "\(title) (\(version))"
    }

    /// Whether TIDAL lists a lossless version: true or false from the
    /// track's quality tier or tags, nil when TIDAL said nothing. Drives the
    /// AAC badge before download (G2-10; reliability needs a live check).
    public var offersLossless: Bool? {
        guard let audioQuality, !audioQuality.isEmpty else { return hiRes ? true : nil }
        return TIDALAudioQuality.isLosslessTier(audioQuality) || hiRes
    }
}

// MARK: - Lenient decoding

/// Decodes and throws away one value, so a bad array element can be skipped.
private struct SkippedValue: Decodable {
    init(from decoder: any Decoder) throws {}
}

extension KeyedDecodingContainer {
    /// A nested value, or nil when it is missing or has the wrong shape.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    fileprivate func lenientString(_ key: Key) -> String? {
        lenient(String.self, key)
    }

    fileprivate func lenientBool(_ key: Key) -> Bool? {
        lenient(Bool.self, key)
    }

    /// Whole numbers sent as `245`, `245.0` or `"245"` all read as 245.
    fileprivate func lenientInt64(_ key: Key) -> Int64? {
        if let value = lenient(Int64.self, key) { return value }
        if let value = lenient(Double.self, key), value.isFinite, value == value.rounded(),
           abs(value) < 9_007_199_254_740_992 {
            return Int64(value)
        }
        if let text = lenient(String.self, key) {
            return Int64(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Like `lenientInt64`, and a fractional number (a duration of `245.4`)
    /// rounds to the nearest whole number.
    fileprivate func lenientInt(_ key: Key) -> Int? {
        if let value = lenient(Int.self, key) { return value }
        if let value = lenient(Double.self, key), value.isFinite, abs(value) < 9_007_199_254_740_992 {
            return Int(value.rounded())
        }
        if let text = lenient(String.self, key) {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// The readable elements of an array, in order; nil when the key is
    /// missing, null or not an array. Unreadable elements are skipped.
    fileprivate func lenientArrayIfPresent<T: Decodable>(_ type: T.Type, _ key: Key) -> [T]? {
        guard contains(key), (try? decodeNil(forKey: key)) == false,
              var list = try? nestedUnkeyedContainer(forKey: key) else { return nil }
        var result: [T] = []
        while !list.isAtEnd {
            let before = list.currentIndex
            if (try? list.decodeNil()) == true { continue }
            if let element = try? list.decode(type) {
                result.append(element)
            } else {
                _ = try? list.decode(SkippedValue.self)
            }
            // Never loop forever if a decoder fails to move past an element.
            if list.currentIndex == before { break }
        }
        return result
    }
}
