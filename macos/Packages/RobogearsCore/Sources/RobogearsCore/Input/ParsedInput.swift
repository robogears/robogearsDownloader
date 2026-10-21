// What the main input field means once it has been read.
//
// One shared classifier decides both the live hint under the field and what
// Return does, so the two can never disagree again (decision card G4-2; the
// Electron app used a loose hint regex and a different parser for Return).

import Foundation

/// The result of reading text typed or pasted into the main field.
public enum ParsedInput: Sendable, Hashable {
    /// Nothing but whitespace.
    case empty

    /// Plain text: search TIDAL for it. Digits and playlist-style IDs typed
    /// without a link land here too (G4-1): TIDAL IDs only arrive through
    /// links. `looksLikeID` lets the empty-results message suggest pasting the
    /// link instead (G4-1 skeptic refinement).
    case search(query: String, looksLikeID: Bool)

    /// A TIDAL track, album or playlist link with a valid ID.
    case tidal(TidalLink)

    /// A Spotify track, album or playlist (link, embed link or `spotify:` URI).
    case spotify(SpotifyLink)

    /// A `spotify.link` (or older `spoti.fi`) short link. It has to be opened
    /// once to see where it leads, then the result is parsed again (G4-3).
    case spotifyShortLink(URL)

    /// A link the app can't add. Nothing is searched; the UI says why and what
    /// is supported (G4-2).
    case unsupported(Unsupported)

    /// Whether this input is a link of any kind (supported or not).
    public var isLink: Bool {
        switch self {
        case .tidal, .spotify, .spotifyShortLink, .unsupported: true
        case .empty, .search: false
        }
    }
}

extension ParsedInput {
    /// What a supported link points at.
    public enum Content: String, Sendable, Hashable, CaseIterable {
        case track, album, playlist
    }

    /// A TIDAL link, reduced to what the API needs. Track and album IDs are
    /// numbers and playlist IDs are UUIDs; anything else is refused before a
    /// request is built (G4-3: the Electron app put "123 great one" straight
    /// into the request path).
    public enum TidalLink: Sendable, Hashable {
        case track(id: Int)
        case album(id: Int)
        /// The playlist UUID exactly as written in the link.
        case playlist(uuid: String)

        public var content: Content {
            switch self {
            case .track: .track
            case .album: .album
            case .playlist: .playlist
            }
        }
    }

    /// A Spotify item. `id` is Spotify's base-62 ID, case preserved.
    public struct SpotifyLink: Sendable, Hashable {
        public let content: Content
        public let id: String

        public init(content: Content, id: String) {
            self.content = content
            self.id = id
        }
    }

    /// A link that can't be added, with enough detail for a specific message
    /// ("YouTube links aren't supported…", "TIDAL artist pages can't be
    /// added…").
    public struct Unsupported: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// A service other than TIDAL or Spotify, or an unknown website.
            case otherService
            /// A TIDAL or Spotify page that isn't a track, album or playlist,
            /// named by the word in its address ("artist", "mix", "episode"…).
            case unsupportedPage(String)
            /// A TIDAL or Spotify address that doesn't name any page we know.
            case unrecognisedPage
            /// A track, album or playlist link whose ID isn't valid (for example
            /// a TIDAL track ID that isn't a number).
            case malformedID(Content)
        }

        public let service: Service
        public let reason: Reason
        /// The link as it appeared in the text.
        public let link: String

        public init(service: Service, reason: Reason, link: String) {
            self.service = service
            self.reason = reason
            self.link = link
        }
    }

    /// Music services recognised by their web address, so a refusal can name
    /// the service ("Apple Music links aren't supported").
    public enum Service: Sendable, Hashable {
        case tidal
        case spotify
        case appleMusic
        case youTube
        case youTubeMusic
        case soundCloud
        case deezer
        case bandcamp
        case amazonMusic
        case qobuz
        case beatport
        /// Any other website, by host name.
        case website(host: String)

        /// The service's name as its owner writes it.
        public var displayName: String {
            switch self {
            case .tidal: "TIDAL"
            case .spotify: "Spotify"
            case .appleMusic: "Apple Music"
            case .youTube: "YouTube"
            case .youTubeMusic: "YouTube Music"
            case .soundCloud: "SoundCloud"
            case .deezer: "Deezer"
            case .bandcamp: "Bandcamp"
            case .amazonMusic: "Amazon Music"
            case .qobuz: "Qobuz"
            case .beatport: "Beatport"
            case .website(let host): host
            }
        }
    }
}
