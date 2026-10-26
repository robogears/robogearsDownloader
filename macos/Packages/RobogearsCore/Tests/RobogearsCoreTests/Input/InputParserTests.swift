import Foundation
import Testing
@testable import RobogearsCore

// Worked examples from docs/electron-reference/tidal-and-spotify-networking.md
// §D and text-unicode-and-filenames.md §9, plus the changes in decision cards
// G4-1, G4-2 and G4-3.

@Suite("Main field: TIDAL links")
struct TidalLinkParsingTests {
    @Test func browseTrackLinkOpensTheTrack() {
        #expect(InputParser.parse("https://tidal.com/browse/track/103805726") == .tidal(.track(id: 103805726)))
    }

    @Test func listenSubdomainAlbumLinkOpensTheAlbum() {
        #expect(InputParser.parse("https://listen.tidal.com/album/103805725") == .tidal(.album(id: 103805725)))
    }

    @Test func shareLinkEndingInQuestionUStillOpensTheTrack() {
        #expect(InputParser.parse("https://tidal.com/track/123?u") == .tidal(.track(id: 123)))
    }

    @Test func shareLinkEndingInSlashUStillOpensTheTrack() {
        #expect(InputParser.parse("https://tidal.com/browse/track/123/u") == .tidal(.track(id: 123)))
    }

    @Test func playlistLinkKeepsItsUUIDAsWritten() {
        let uuid = "4b3d9e2a-1c5f-4e8a-9b7d-0123456789AB"
        #expect(InputParser.parse("https://tidal.com/browse/playlist/\(uuid)") == .tidal(.playlist(uuid: uuid)))
    }

    @Test func albumPlusTrackLinkAddsJustTheTrack() {
        // G4-3: the Electron app queued the whole album A.
        #expect(InputParser.parse("https://listen.tidal.com/album/555/track/777") == .tidal(.track(id: 777)))
    }

    @Test func linkWithoutSchemeOrWithWwwIsStillALink() {
        #expect(InputParser.parse("tidal.com/browse/album/42") == .tidal(.album(id: 42)))
        #expect(InputParser.parse("www.tidal.com/track/9") == .tidal(.track(id: 9)))
    }

    @Test func embedStylePluralPathsAreAccepted() {
        #expect(InputParser.parse("https://embed.tidal.com/tracks/31") == .tidal(.track(id: 31)))
    }

    @Test func wordsAfterATidalLinkDontBecomePartOfTheID() {
        // G4-3: "123 great one" used to reach the request path.
        #expect(InputParser.parse("https://tidal.com/browse/track/123 great one") == .tidal(.track(id: 123)))
    }

    @Test func wordsBeforeALinkAreIgnored() {
        #expect(InputParser.parse("see https://tidal.com/browse/track/123 now") == .tidal(.track(id: 123)))
    }

    @Test func nonNumericTrackIDIsRefusedBeforeAnyRequest() {
        let result = InputParser.parse("https://tidal.com/browse/track/12a3")
        #expect(result == .unsupported(.init(service: .tidal, reason: .malformedID(.track), link: "https://tidal.com/browse/track/12a3")))
    }

    @Test func playlistLinkWithANumberInsteadOfAUUIDIsRefused() {
        guard case .unsupported(let info) = InputParser.parse("https://tidal.com/playlist/12345") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.reason == .malformedID(.playlist))
    }

    @Test func trackLinkWithNoIDIsRefused() {
        guard case .unsupported(let info) = InputParser.parse("https://tidal.com/browse/track/") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.reason == .malformedID(.track))
    }

    @Test func tidalArtistMixAndVideoPagesAreNamedNotSearched() {
        let cases: [(String, ParsedInput.Page)] = [
            ("https://tidal.com/browse/artist/1", .artist),
            ("https://tidal.com/browse/mix/0123abc", .mix),
            ("https://tidal.com/browse/video/1", .video),
        ]
        for (link, page) in cases {
            #expect(InputParser.parse(link) == .unsupported(.init(service: .tidal, reason: .unsupportedPage(page), link: link)))
        }
    }

    @Test func myCollectionTracksIsACollectionPageNotABrokenTrackLink() {
        // "tracks" ends the address, which used to read as a track link with
        // its ID missing (G4-2 wants the specific reason).
        let link = "https://listen.tidal.com/my-collection/tracks"
        #expect(InputParser.parse(link) == .unsupported(.init(service: .tidal, reason: .unsupportedPage(.collection), link: link)))
    }

    @Test func artistAlbumsPageIsAnArtistPageNotABrokenAlbumLink() {
        let link = "https://tidal.com/browse/artist/123/albums"
        #expect(InputParser.parse(link) == .unsupported(.init(service: .tidal, reason: .unsupportedPage(.artist), link: link)))
    }

    @Test func pageWordBeforeAKindWithABadIDNamesThePage() {
        // "created" isn't a playlist UUID, and the page is My Collection.
        guard case .unsupported(let info) = InputParser.parse("https://listen.tidal.com/my-collection/playlists/created") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.reason == .unsupportedPage(.collection))
    }

    @Test func linkStuckToAnEmojiIsStillFound() {
        #expect(InputParser.parse("\u{1F449}https://tidal.com/browse/track/123") == .tidal(.track(id: 123)))
    }

    @Test func cjkPunctuationAfterATidalLinkIsLeftOut() {
        #expect(InputParser.parse("https://tidal.com/browse/track/123\u{3001}") == .tidal(.track(id: 123)))
        // Without "https://", the bracket would otherwise become part of the host.
        #expect(InputParser.parse("\u{300C}tidal.com/browse/album/42\u{300D}") == .tidal(.album(id: 42)))
        #expect(InputParser.parse("https://tidal.com/browse/track/123\u{2026}") == .tidal(.track(id: 123)))
    }

    @Test func tidalLinkInsideAnotherSitesRedirectIsAdded() {
        // The Electron pattern matched anywhere, so this worked there.
        #expect(InputParser.parse("https://example.org/out?u=https://tidal.com/browse/track/77") == .tidal(.track(id: 77)))
    }

    @Test func refusalForTheOuterLinkWinsWhenNothingInsideIsSupported() {
        let link = "https://example.org/out?u=https://youtu.be/abc"
        #expect(InputParser.parse(link) == .unsupported(.init(service: .website(host: "example.org"), reason: .otherService, link: link)))
    }

    @Test func otherTidalPagesAreUnrecognisedNotSearched() {
        guard case .unsupported(let info) = InputParser.parse("https://tidal.com/pricing") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.service == .tidal)
        #expect(info.reason == .unrecognisedPage)
    }

    @Test func hostThatOnlyEndsInTidalTextIsNotTidal() {
        // The Electron regex had no host boundary: "nottidal.com/track/1" matched.
        guard case .unsupported(let info) = InputParser.parse("https://nottidal.com/track/1") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.service == .website(host: "nottidal.com"))
    }
}

@Suite("Main field: Spotify links")
struct SpotifyLinkParsingTests {
    let id = "4uLU6hMCjMI75M1A2tKUQC"

    @Test func trackLinkWithShareQueryOpensTheTrack() {
        #expect(InputParser.parse("https://open.spotify.com/track/\(id)?si=abc") == .spotify(.init(content: .track, id: id)))
    }

    @Test func intlSegmentIsSkipped() {
        #expect(InputParser.parse("https://open.spotify.com/intl-de/album/\(id)") == .spotify(.init(content: .album, id: id)))
    }

    @Test func intlSegmentWithTwoHyphensIsSkipped() {
        // G4-3: `\w` stopped at the second hyphen.
        #expect(InputParser.parse("https://open.spotify.com/intl-pt-BR/playlist/\(id)") == .spotify(.init(content: .playlist, id: id)))
    }

    @Test func embedLinkFromAWebsiteIsAccepted() {
        #expect(InputParser.parse("https://open.spotify.com/embed/playlist/\(id)?utm_source=generator") == .spotify(.init(content: .playlist, id: id)))
    }

    @Test func legacyUserPlaylistLinkIsAccepted() {
        #expect(InputParser.parse("https://open.spotify.com/user/someone/playlist/\(id)") == .spotify(.init(content: .playlist, id: id)))
    }

    @Test func copySpotifyURIFormIsAccepted() {
        #expect(InputParser.parse("spotify:track:\(id)") == .spotify(.init(content: .track, id: id)))
        #expect(InputParser.parse("spotify:album:\(id)") == .spotify(.init(content: .album, id: id)))
        #expect(InputParser.parse("spotify:user:someone:playlist:\(id)") == .spotify(.init(content: .playlist, id: id)))
    }

    @Test func idKeepsItsCase() {
        guard case .spotify(let link) = InputParser.parse("open.spotify.com/track/AbCdEf123") else {
            Issue.record("expected a Spotify link"); return
        }
        #expect(link.id == "AbCdEf123")
    }

    @Test func shortLinkIsReturnedForResolving() {
        #expect(InputParser.parse("https://spotify.link/AbC123xyz") == .spotifyShortLink(URL(string: "https://spotify.link/AbC123xyz")!))
        #expect(InputParser.parse("spoti.fi/3xYz") == .spotifyShortLink(URL(string: "https://spoti.fi/3xYz")!))
    }

    @Test func shortLinkWithoutACodeIsRefused() {
        guard case .unsupported(let info) = InputParser.parse("https://spotify.link/") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.service == .spotify)
    }

    @Test func artistEpisodeShowAndOtherPagesAreNamedNotSearched() {
        let cases: [(String, ParsedInput.Page)] = [
            ("artist", .artist), ("episode", .podcast), ("show", .podcast), ("user", .profile),
            ("collection", .collection), ("audiobook", .audiobook), ("genre", .other("genre")),
        ]
        for (word, page) in cases {
            let link = "https://open.spotify.com/\(word)/\(id)"
            #expect(InputParser.parse(link) == .unsupported(.init(service: .spotify, reason: .unsupportedPage(page), link: link)), "\(word)")
        }
        #expect(InputParser.parse("spotify:artist:\(id)") == .unsupported(.init(service: .spotify, reason: .unsupportedPage(.artist), link: "spotify:artist:\(id)")))
    }

    @Test func artistDiscographyAlbumsPageIsAnArtistPageNotABrokenAlbumLink() {
        let link = "https://open.spotify.com/artist/\(id)/discography/album"
        #expect(InputParser.parse(link) == .unsupported(.init(service: .spotify, reason: .unsupportedPage(.artist), link: link)))
    }

    @Test func legacyUserPlaylistLinkWithoutAnIDIsABrokenPlaylistLink() {
        // "user" before "playlist" is the old link form, not a profile page.
        guard case .unsupported(let info) = InputParser.parse("https://open.spotify.com/user/someone/playlist") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.reason == .malformedID(.playlist))
    }

    @Test func idWithNoBase62CharactersIsRefused() {
        guard case .unsupported(let info) = InputParser.parse("https://open.spotify.com/track/-abc") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.reason == .malformedID(.track))
    }

    @Test func idStopsAtTheFirstCharacterThatCantBeInAnID() {
        // As the Electron pattern `[a-zA-Z0-9]+` did.
        #expect(InputParser.parse("https://open.spotify.com/track/\(id)\u{2019}s") == .spotify(.init(content: .track, id: id)))
        #expect(InputParser.parse("https://open.spotify.com/track/\(id)%E3%80%82") == .spotify(.init(content: .track, id: id)))
    }

    @Test func cjkFullStopAfterASpotifyLinkIsLeftOut() {
        #expect(InputParser.parse("https://open.spotify.com/track/\(id)\u{3002}") == .spotify(.init(content: .track, id: id)))
    }

    @Test func linkStuckToTheWordBeforeItIsStillFound() {
        // Was searched as text: "Listen:https" isn't a scheme.
        #expect(InputParser.parse("Listen:https://open.spotify.com/track/\(id)") == .spotify(.init(content: .track, id: id)))
    }

    @Test func markdownLinkIsFound() {
        #expect(InputParser.parse("[Blue Lantern](https://open.spotify.com/track/\(id))") == .spotify(.init(content: .track, id: id)))
    }

    @Test func spotifyURIStuckToALabelIsFound() {
        #expect(InputParser.parse("URI:spotify:track:\(id)") == .spotify(.init(content: .track, id: id)))
    }

    @Test func spotifyInsideAWordIsNotAURI() {
        #expect(InputParser.parse("notspotify:track:\(id)") == .search(query: "notspotify:track:\(id)", looksLikeID: false))
    }

    @Test func linkWrappedInAngleBracketsOrFollowedByPunctuationIsFound() {
        #expect(InputParser.parse("<https://open.spotify.com/track/\(id)>") == .spotify(.init(content: .track, id: id)))
        #expect(InputParser.parse("listen: https://open.spotify.com/track/\(id).") == .spotify(.init(content: .track, id: id)))
    }

    @Test func spotifyWordFollowedByAColonStillSearches() {
        #expect(InputParser.parse("Spotify: Blue Lantern") == .search(query: "Spotify: Blue Lantern", looksLikeID: false))
    }
}

@Suite("Main field: other links and searches")
struct SearchAndUnsupportedInputTests {
    @Test func plainDigitsSearchInsteadOfOpeningATrackID() {
        // G4-1: "2041" was opened as TIDAL track 2041.
        #expect(InputParser.parse("2041") == .search(query: "2041", looksLikeID: true))
    }

    @Test func bareUUIDSearchesInsteadOfOpeningAPlaylist() {
        let uuid = "4b3d9e2a-1c5f-4e8a-9b7d-0123456789ab"
        #expect(InputParser.parse(uuid) == .search(query: uuid, looksLikeID: true))
    }

    @Test func songNameSearchesAndIsTrimmed() {
        #expect(InputParser.parse("  Blue Lantern Placeholder Artist \n") == .search(query: "Blue Lantern Placeholder Artist", looksLikeID: false))
    }

    @Test func digitsWithWordsAreAnOrdinarySearch() {
        #expect(InputParser.parse("2041 Placeholder Artist") == .search(query: "2041 Placeholder Artist", looksLikeID: false))
    }

    @Test func titlesWithDotsAndSlashesStaySearches() {
        for text in ["Mr. Brightside", "AC/DC", "Ex.Machina/2", "St. Elmo's Fire (Man in Motion)"] {
            #expect(InputParser.parse(text) == .search(query: text, looksLikeID: false), "\(text)")
        }
    }

    @Test func emptyOrWhitespaceInputIsEmpty() {
        #expect(InputParser.parse("") == .empty)
        #expect(InputParser.parse(" \t\n\u{FEFF}") == .empty)
    }

    @Test func otherServicesAreNamedAndNeverSearched() {
        // G4-2: these were sent to TIDAL search as song names.
        let cases: [(String, ParsedInput.Service)] = [
            ("https://www.youtube.com/watch?v=abc", .youTube),
            ("https://youtu.be/abc", .youTube),
            ("https://music.youtube.com/watch?v=abc", .youTubeMusic),
            ("https://music.apple.com/us/album/x/123?i=456", .appleMusic),
            ("https://soundcloud.com/someone/song", .soundCloud),
            ("https://www.deezer.com/track/1", .deezer),
            ("https://someone.bandcamp.com/track/song", .bandcamp),
            ("https://music.amazon.co.uk/albums/B0", .amazonMusic),
            ("https://open.qobuz.com/album/x", .qobuz),
            ("https://www.beatport.com/track/x/1", .beatport),
        ]
        for (link, service) in cases {
            #expect(InputParser.parse(link) == .unsupported(.init(service: service, reason: .otherService, link: link)), "\(link)")
        }
    }

    @Test func unknownWebsiteIsRefusedByHostName() {
        let link = "https://example.org/song"
        #expect(InputParser.parse(link) == .unsupported(.init(service: .website(host: "example.org"), reason: .otherService, link: link)))
        #expect(ParsedInput.Service.website(host: "example.org").displayName == "example.org")
    }

    @Test func knownServiceWithoutSchemeIsALink() {
        guard case .unsupported(let info) = InputParser.parse("youtu.be/abc") else {
            Issue.record("expected a refusal"); return
        }
        #expect(info.service == .youTube)
    }

    @Test func serviceNamesReadAsTheirOwnersWriteThem() {
        #expect(ParsedInput.Service.tidal.displayName == "TIDAL")
        #expect(ParsedInput.Service.youTube.displayName == "YouTube")
        #expect(ParsedInput.Service.appleMusic.displayName == "Apple Music")
    }

    @Test func linkFlagSeparatesLinksFromSearches() {
        #expect(InputParser.parse("https://youtu.be/abc").isLink)
        #expect(InputParser.parse("https://tidal.com/track/1").isLink)
        #expect(!InputParser.parse("Blue Lantern").isLink)
        #expect(!InputParser.parse("").isLink)
    }

    @Test func tidalAddressWithPortAndUserInfoIsStillTidal() {
        #expect(InputParser.parse("https://me@listen.tidal.com:443/track/5") == .tidal(.track(id: 5)))
    }
}
