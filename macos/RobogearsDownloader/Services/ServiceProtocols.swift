import Foundation
import RobogearsCore

// The seams between the window and the work. The real TIDAL client,
// resolver, matcher, download pipeline, library scanner and preview player
// are being built in other lanes; until they land, StandIn/ provides a
// deterministic implementation of each protocol so every screen and state
// can be exercised without a network or a TIDAL account.
//
// Rules every implementation keeps (DESIGN.md §7):
// - nothing it returns contains a signed link, a raw server reply or the
//   account's name: reasons are plain sentences for the row and the log;
// - long work honours Task cancellation and stops promptly (D4 1.11);
// - nothing ever writes to the music library folder.

// MARK: - Adding tracks (links, searches, tracklists)

/// What the person brought to the queue.
enum AddSource: Sendable, Equatable {
    /// A TIDAL or Spotify link typed, pasted or dropped.
    case link(String)
    /// A pasted or dropped tracklist (CSV or lines of "Title - Artist"),
    /// with the file's name when it came from a file.
    case tracklist(text: String, name: String?)
    /// One pasted line with a separator ("Blue Lantern - Placeholder Artist"):
    /// matched and added directly (D4 4.7).
    case line(String)
}

/// The resolver's progress, streamed while the adding cover is up.
enum AddEvent: Sendable {
    /// How many tracks will be matched, once known: the cover's loading
    /// line hands over to "Matching N / M tracks on TIDAL…" (D4 4.21).
    case progress(done: Int, total: Int)
    /// Rows ready for the queue, in order (matched, not on TIDAL, or
    /// couldn't check). Sent as they're made, so Cancel keeps them (D4 4.9).
    case items([QueueItem])
    /// Spotify only shared the first 100 tracks of a playlist (D4 4.4).
    case capped(playlistName: String)
    /// Nothing could be added; the sentence says what happened and what to do.
    case failed(String)
    /// The add finished; `sourceName` names where the tracks came from
    /// ("link", "Late Ferry", "pasted text", "Exportify CSV").
    case finished(sourceName: String)
}

/// One TIDAL search result, shown in the search sheet.
struct SearchResult: Identifiable, Sendable, Equatable {
    var id: Int64 { track.tidalID ?? 0 }
    /// The track as a ready queue row (library mark filled in when known).
    var track: QueueItem
}

protocol TrackResolving: Sendable {
    /// Resolves a link, a line or a tracklist into queue rows. Ends with
    /// `.finished` or `.failed`; cancelling the consuming task stops it.
    func add(_ source: AddSource) -> AsyncStream<AddEvent>
    /// Up to ten TIDAL results for a typed search. Throws `ServiceError`.
    func search(_ query: String) async throws -> [SearchResult]
    /// Looks a "Couldn't check" or "Not on TIDAL" row up again.
    func matchAgain(_ item: QueueItem) async -> QueueItem
}

/// A failure with a sentence ready to show.
struct ServiceError: Error, Sendable, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Library and download folder checks

/// The library scan's progress, for Settings › Folders ("Scanning 120 / 500…",
/// then "1,240 files indexed"). The scanner reports about every 25 files.
enum LibraryScanEvent: Sendable, Equatable {
    case progress(done: Int, total: Int)
    case finished(files: Int)
    /// The folder couldn't be read (an unplugged drive): the sentence says
    /// what happened and what to do. Earlier duplicate marks stay.
    case unavailable(String)
}

/// A library match plus the library file's length when its tags give one,
/// so the row can show both lengths when they're more than 10 s apart
/// (DESIGN_DIRECTION 4.4). The length isn't saved with the queue yet:
/// RobogearsCore's LibraryMatch has no field for it.
struct LibraryVerdict: Sendable, Equatable {
    var match: QueueItem.LibraryMatch
    var durationSeconds: Int?
}

protocol LibraryChecking: Sendable {
    /// The library verdict for each row (a missing key means no match).
    /// Never writes to the library folder.
    func check(_ items: [QueueItem]) async -> [UUID: LibraryVerdict]
    /// Whether a file for this row already sits in the download folder (D4 2.16).
    func isInDownloadFolder(_ item: QueueItem, folder: URL) async -> Bool
    /// Reads (or re-reads) the library folder's index. Read-only; cancelling
    /// the consuming task stops it. Ends with `.finished` or `.unavailable`.
    func scan(_ folder: URL) -> AsyncStream<LibraryScanEvent>
}

// MARK: - Downloading

/// How one track of a batch ended.
enum TrackOutcome: Sendable, Equatable {
    /// Saved; `quality` reads "24-bit / 96 kHz", "16-bit / 44.1 kHz" or "AAC".
    case saved(quality: String, file: URL, isAAC: Bool)
    /// A file with this name was already in the download folder and checked fine.
    case alreadyInFolder(file: URL)
    case failed(reason: String)
    /// A different song is already saved under the same name (D4 2.6).
    case clash(fileName: String)
    /// The file already there looks damaged (D4 2.3).
    case damaged(fileName: String)
}

/// Why a batch stopped before its end (D4 2.1): one shared problem stops it once.
struct BatchStopCause: Sendable, Equatable {
    enum Fix: Sendable, Equatable { case chooseFolder, signIn, none }
    /// The sentence for the summary notice, for example "Stopped: the download
    /// folder “TIDAL” on Music SSD isn't available. Connect the drive or choose another folder."
    var message: String
    var fix: Fix
}

enum BatchEvent: Sendable, Equatable {
    case started(UUID)
    /// Whole percents, at most one event per change.
    case progress(UUID, percent: Int)
    case finished(UUID, TrackOutcome)
    /// TIDAL asked the app to slow down; the counter shows the wait.
    case waitingForTIDAL(Bool)
    /// The batch stopped on a shared problem; unfinished rows go back to waiting.
    case stopped(BatchStopCause)
    /// Every track was handled (or the batch was stopped by `stop()`).
    case ended
}

/// How the person resolves a same-name clash.
enum ClashResolution: Sendable, Equatable {
    case saveAs(fileName: String)
    /// Moves the old file to the Trash, then saves.
    case replace
}

protocol BatchDownloading: Sendable {
    /// Downloads the tracks one at a time into `folder`. Ends with `.ended`.
    func download(_ tracks: [QueueItem], into folder: URL) -> AsyncStream<BatchEvent>
    /// Stops at once: the current track's temporary file is deleted (D4 2.4).
    func stop() async
    /// Takes one track out of the running batch, stopping it if it's downloading (D4 2.13).
    func remove(_ id: UUID) async
    /// Saves a clashing or damaged row the way the person chose.
    func resolve(_ item: QueueItem, _ resolution: ClashResolution, in folder: URL) async -> TrackOutcome
}

// MARK: - Previews

struct PreviewAsset: Sendable, Equatable {
    /// 200 peaks in 0…1, the loudest exactly 1 (DESIGN_DIRECTION 3.4).
    var peaks: [Float]
    /// A local file the player can open (never a signed link).
    var file: URL
    var duration: TimeInterval
}

protocol PreviewProviding: Sendable {
    /// Peaks already saved on disk, without any download (D4 5.1).
    func cachedPeaks(for tidalID: Int64) async -> [Float]?
    /// Peaks and a playable file for a track. Throws `ServiceError`.
    func preview(for tidalID: Int64) async throws -> PreviewAsset
    /// Bytes the preview cache holds on disk (Settings › General).
    func cacheSize() async -> Int64
    /// Clear Preview Cache: removes cached previews and peaks. Never touches
    /// the download or library folder.
    func clearCache() async
}

/// Exactly one preview player (D4 5.16). Main-actor bound: it drives the UI.
@MainActor
protocol PreviewPlaying: AnyObject {
    func load(_ asset: PreviewAsset) throws
    func play()
    func pause()
    func stop()
    func seek(toFraction fraction: Double)
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    /// The gain, already squared from the slider position.
    var volume: Float { get set }
    /// Called when playback reaches the end.
    var onFinish: (@MainActor () -> Void)? { get set }
}

// MARK: - TIDAL sign-in

enum SignInState: Sendable, Equatable {
    case signedOut
    case signedIn(country: String?)
    /// TIDAL stopped accepting the stored sign-in.
    case invalid
}

enum SignInEvent: Sendable, Equatable {
    /// The link to open (and TIDAL's short code when it sends one).
    case link(URL, code: String?)
    /// One status line ("Waiting for TIDAL…").
    case status(String)
    case signedIn(country: String?)
    case failed(String)
}

protocol SignInProviding: Sendable {
    func currentState() async -> SignInState
    /// The device-code flow. Cancelling the consuming task stops polling.
    func signIn() -> AsyncStream<SignInEvent>
    func signOut() async
}

// MARK: - The previous version's files (first launch, D4 5.11)

/// The Electron app's files in ~/Library/Application Support/robogears
/// Downloader. Shaped exactly like RobogearsCore's `LegacyElectronFiles` on
/// the integration branch, so wiring the real one is
/// `extension LegacyElectronFiles: OldAppFilesProviding {}`. Nothing here
/// runs without the person's click, and only items known by exact name are
/// ever touched.
protocol OldAppFilesProviding: Sendable {
    /// The old app's data folder.
    var folder: URL { get }
    /// The known old items that are actually there, app files first.
    func presentItems() -> [URL]
    /// There's something of the old app's to talk about.
    var shouldOfferNotice: Bool { get }
    /// The old plain-text TIDAL sign-in (token.json) is there.
    var hasOldSignIn: Bool { get }
    /// Move Old Files to Trash: every known item, recoverable. Returns what moved.
    @discardableResult func moveToTrash() throws -> [URL]
    /// Delete Old Sign-in: removes token.json for good (in the Trash it stays readable).
    func deleteOldSignIn() throws
}

/// Everything the window talks to, bundled so the app can swap stand-ins
/// for the real services in one place.
struct AppServices: Sendable {
    var resolver: any TrackResolving
    var library: any LibraryChecking
    var downloader: any BatchDownloading
    var previews: any PreviewProviding
    var signIn: any SignInProviding
    var oldFiles: any OldAppFilesProviding
}
