<!-- Written 26 Oct 2026 by a read-only planning agent while the lanes were still being finished; re-check every line against the merged code before building from it (manual 3.3: a brief goes stale once code merges). -->

# Plan: connecting the SwiftUI app to the real RobogearsCore services

**Status of what I read:** every lane was still being edited while I worked. The folder lane and the resolver lane had temporary rule-breaking edits in their working copies (a mutation check in progress; details in section 6). The batch lane committed a fix for one such leftover (`12c51bd`) while I was reading. The UI lane has 16 modified files that aren't committed yet. Line numbers below are from the committed or on-disk state at that time.

---

## 1. Each app protocol: what backs it, the adapter, and every mismatch

**The approach I recommend.** The app's service types (`AddEvent`, `BatchEvent`, `TrackOutcome`, `LibraryVerdict` and the rest, in `Services/ServiceProtocols.swift`) were written before core existed. Core now has fuller types that are already tested against D4's wording.

So the app should switch its protocols to core's types wherever core has a complete one, and keep app-only types only where core has none (sign-in state, preview asset). Each adapter then becomes a thin forwarder.

Because the app target has no test bundle (`Snapshot/SelfChecks.swift:5-9`), the split is:
- everything that does input/output (network, files) lives in core and is proven by `swift test` with the existing mock URLProtocol;
- what stays in the app is pure mapping, checked by `--run-checks`.

### 1a. `TrackResolving` (`ServiceProtocols.swift:54-62`) → `TrackResolver` (resolver lane, `Resolve/`)

- **Adapter:** a struct `CoreResolver` holding a `TrackResolver` (`TrackResolver.swift:37-42`).

| Mismatch | Change which side | Why |
|---|---|---|
| `AddSource` (`ServiceProtocols.swift:19-28`) has no file-bytes case. Core has `ResolveSource.tracklistFile(Data, name:)` (`ResolveTypes.swift:22`). The app reads files itself with a naive decoder (`AppModel+Adding.swift:434-441`, marked TODO). | App: replace `AddSource` with `ResolveSource`. Send dropped or opened files as bytes. For the 2,000-line question, count lines after `TracklistTextDecoder.decode`. | Core already handles encodings and refuses binary files (D4 4.17, 4.8). |
| `AddEvent.progress(done,total)` only. Core has `ResolveProgress.loading(done:total?)` and `.matching` (`ResolveTypes.swift:105-113`). | App: `AddingState` gets a phase, shown as "Loading 300 of 1,250 tracks…" or "Matching 34 / 100 tracks on TIDAL…". | D4 4.21 asks for both lines. |
| `.items` vs `.rows([QueueItem])`. Core rows arrive already de-duplicated against the queue and already carry library marks or "checking". | App: delete its own de-duplication (`AppModel+Adding.swift:89-100`) and the library check after an add (`:132`). Keep `checkDownloadFolder`. | Core does both. Keeping the app's copy would double-count the "already in the queue" totals. |
| `.capped(playlistName:)` vs `.capped(SpotifyCapNotice)`, which carries exact counts in its `message`. | App: show `notice.message`. Delete the hand-written sentence at `AppModel+Adding.swift:128`. | D4 4.4: the notice only claims a cut-off when the playlist really is longer. |
| `.failed(String)` vs `.failed(ResolveFailure)`, which has a `kind` and a `retry` source. | App: "signInNeeded" opens the existing sign-in-to-continue alert with `retry` as the waiting add. "signInInvalid" sets the state to `.invalid`. "offline" or "busy" show Try Again, which runs `retry`. | D4 1.7: Try Again keeps what was pasted. D4 1.1 and 1.6. |
| `.finished(sourceName:)` vs `.finished(ResolveSummary)`. | App: log `summary.message`. Drop its own sentence building (`:107-119`). | Core's text already covers D4 4.2 and 4.9: skipped links, CSV columns, "Stopped matching after…". |
| The app has no `.log(String)` event. | App: add it; it goes to the activity log only. | Core sends server details only on this channel (D4 1.4). |
| Cancel model. The app cancels the task that reads the stream (`cancelAdd`, `:74-76`). Core's job says that ends the add without a summary, and rows already sent but not yet read are lost (`ResolveTypes.swift:152-156`). | App: the protocol returns a job with `stop()`, and Cancel calls `stop()`. The stopped state comes from `summary.stopped`, not from `Task.isCancelled` (`:68`). | D4 4.9: Cancel keeps finished rows. |
| Core's `add` needs `queue: QueueContents`. | App: pass `QueueContents(rows.map(\.item))`. | Core de-duplicates against it. |
| `search` returns `[SearchResult]` in the app, `SearchResults` (hits with `inQueue`, plus `emptyMessage`) in core. | App: show `emptyMessage` ("Paste its link instead", D4 4.1). Drop `markLibrary` (`:192-200`), because core already marks hits. | Duplicated work. |
| Match Again: the app rebuilds the item (`AppModel+Queue.swift:263-267`) and drops core-only fields. | App: use core's returned item as-is (core keeps the id). | Otherwise `libraryCheckPending` and `losslessOnTIDAL` get lost. |
| The app builds its own search text and pick (`AppModel+Adding.swift:171-188`, `:227-241`). | App: call `searchQuery(for:)` / `search(forRow:)` and `replace(_:with:)` (`TrackResolver+Search.swift:58-88`). | Core keeps the person's own words only when they differ (D4 4.14). |
| Paste, drop and Return routing are guessed by `AddInputKind.classify` and `hasSeparator` (`Routes.swift:99-111`, `AppModel+Adding.swift:291-293`). | App: use `AddRoute.forField` and `AddRoute.forPaste` (`ResolveTypes.swift:43-52`), including `.refuse(message)`. | D4 4.1, 4.2, 4.7 and 4.13 are already tested in core. |
| `SearchHit`, `SearchResults`, `SpotifyCapNotice` and `ResolveJob` have no public initialisers (`ResolveTypes.swift:145, 215-223, 288-305`). | Core: add public initialisers. | Without them the app's stand-ins can't build these values. |

### 1b. `LibraryChecking` (`:91-100`) → `LibraryIndexService` (`Library/LibraryScanner.swift:136-239`) plus `LibraryMarks` (`Resolve/LibraryMarking.swift`)

- **Adapter:** an actor `CoreLibrary`. It has to be an actor so it can own the scan stream described below.

| Mismatch | Change which side | Why |
|---|---|---|
| `check(_:) -> [UUID: LibraryVerdict]` mostly duplicates what the resolver already marks. Core has no public "re-mark these rows": `LibraryMarks.query(for row:)` and `apply` are internal (`LibraryMarking.swift:51-72`); only `fillPending` is public (`:77-84`). | Core: add `public static func recheck(_ items: [QueueItem], using: any LibraryMarking) async -> [QueueItem]`. App: the protocol becomes `recheck`, plus `fillPending` (or call `resolver.fillLibraryMarks`). | D4 3.9 (re-check after the library changes) and D4 4.20 (fill in pending marks). |
| `LibraryVerdict.durationSeconds` exists only in the app. The app's own comment says `QueueItem.LibraryMatch` lacks it (`ServiceProtocols.swift:82-85`). Core's `LibraryMatcher.Match.libraryDurationSeconds` already exists (`LibraryMatcher.swift:110`), but is dropped at `LibraryLookup.swift:26-28`. | Core: add an optional `libraryDurationSeconds: Int?` to `QueueItem.LibraryMatch` (old saved queues still load). App: delete `LibraryVerdict` and `QueueRow.libraryDurationSeconds`. | The "4:12 vs 3:58" row text should survive a relaunch. |
| `QueueRow.isCheckingLibrary` lasts one session; core has the saved `libraryCheckPending` (resolver lane, `QueueItem.swift:67-70`). | App: read `item.isLibraryCheckPending`; `downloadableCount` follows it. | D4 4.20: Download All holds pending rows, after a relaunch too. |
| `scan(_:) -> AsyncStream<LibraryScanEvent>`. Core has `scan(_ folder: URL?)` plus a single `setOnChange` handler (`:177-212`). A single handler is overwritten by the next subscriber. | Core: add a multi-subscriber `statusChanges() -> AsyncStream<Status>` (the same pattern as `TokenKeeper.stateChanges`). The adapter maps `.scanning`→`.progress`, `.ready`→`.finished`, `.unavailable` or `.failed`→`.unavailable`, and `.off`→`LibraryStatus.none`. | Settings and the re-check-on-ready logic both need to listen. |
| `isInDownloadFolder(_:folder:) -> Bool` is called once per row (`AppModel+Adding.swift:493`). Core's answer has four outcomes, `DownloadFolder.InFolderStatus`, and works on many rows at once through `inFolderStatuses(for:)` (folder lane, `DownloadFolder.swift:187-221`). | App: move this check to the download side (it is the folder lane's API). Keep the full status on the row, so "A different song is already saved as Intro.flac" and the damaged-file row show before a batch. Call it once per add, once per folder change, and once before each batch. | D4 2.16 option A, and one folder listing per call. |
| Online-only library files (D4 3.8 consent: `LibraryScanOptions.readOnlineOnlyFiles`, `unreadOnlineOnlyCount`) have no UI. | App, later. | Out of scope; note it. |

### 1c. `BatchDownloading` (`:146-155`) → `DownloadBatch` (batch lane) driving `TrackDownloader` (track lane), `DownloadFolder` (folder lane) and `M4AWriter` (m4a lane)

- **Adapter:** an actor `CoreDownloader`. It holds `current: DownloadBatch?` and builds one `TrackDownloader` and one `DownloadFolder(folder:)` per batch, because a folder planner is tied to one folder (D4 2.17).
- **Stand-in:** the app's stand-in should become the real `DownloadBatch` running a scripted `TrackDownloading`, with a stand-in network monitor and a no-op sleep preventer. Snapshots and self-checks then exercise the real batch rules without any network.

| Mismatch | Change which side | Why |
|---|---|---|
| Lifecycle. The app has one `download` stream, plus `stop()` and `remove()`. Core makes one actor per batch: `events()`, `start()`, `cancel()`, `remove()`, `resumeOnThisNetwork()`, `stopForQuit()` and `unfinishedCount` (`DownloadBatch.swift:244-358`). | App: the protocol becomes `start(tracks: [DownloadBatch.Track], folder:, kind:) -> AsyncStream<DownloadBatch.Event>`, `cancel()`, `remove(_:)`, `resumeOnThisNetwork()` and `stopForQuit() -> Summary?`. | Core is the tested runner for D4 2.1, 2.4, 2.5 and 2.13. |
| `TrackOutcome` vs `TrackDownloadOutcome` plus `TrackDownloadError`, delivered inside `RowUpdate` (`:64-88`). | App: apply `RowUpdate.apply(to:)` to `row.item`. Work out `problem`, `savedFile` and `isAACOnly` from `item.lastOutcome` (batch lane, `QueueItem.swift:70`), not from fields that last one session. | `lastOutcome` is saved with the queue, so Replace and Save As… survive a relaunch. |
| The app's `.clash` means "a different song holds the name". Core saves such a song under another name automatically (`.saved` with the note `.savedUnderAnotherName`). Its only blocking case is `.nameTakenByUnreadableFile`. | App: map `.nameTakenByUnreadableFile`→Save As…, and `.existingLooksDamaged`→Replace. | D4 2.6. |
| **Cleanup bug.** Core gives damaged and name-taken rows the `.skipped` state (`BatchSummary.swift:58-61`). The app's `cleanUpAfterBatch` removes every `.done`/`.skipped` row (`AppModel+Queue.swift:156-158`). | App: keep rows whose `lastOutcome` is damaged or name-taken. | Otherwise the rows offering Replace and Save As… disappear when the batch ends. |
| The app builds its own row states and retried reasons (`AppModel+Batch.swift:69-77`, `:196-203`). | App: build `DownloadBatch.Track(row:folder:)` before touching any row state, then only apply what core sends. | Core restores retried failures itself (D4 2.1). Setting `.queued` first would lose the failure it needs to restore. |
| Sounds play twice. Core plays them through `sounds:` (`DownloadBatch.swift:264, 288, 560`); the app plays them too (`AppModel+Batch.swift:78, 174, 223-227`). | Pass `sounds: nil`. The app plays `Summary.sound` at the end. | The app's `SoundPlayer` applies the "Play sound effects" switch, and nothing double-chimes. |
| Keep-awake runs twice. The app calls `ProcessInfo.beginActivity` (`:80-81`); core uses an IOKit power assertion (`KeepAwake.swift`) and releases it while waiting for the network. | App: delete its own. | D4 1.7 and 2.12: the Mac may sleep while the batch waits offline. |
| Events the app has no case for: `waitingForNetwork`, `askToResume`, `resumed`, `counter`, `rowRemoved`. | App: add the "Waiting for an internet connection…" state, a "Resume downloads on this network?" alert that calls `resumeOnThisNetwork()` or `cancel()`, and take counts from `Counter`. | D4 1.7 and its sub-choice, D4 2.22. |
| `waitingForTIDAL(Bool)` doesn't come from the batch. It comes from `TIDALPace.statusChanges()` (`TIDALPace.swift:252-259`). | App: listen to the pace separately. `.waiting(until:)` can show a countdown; `.busy` shows "TIDAL is busy". | D4 1.4. |
| `BatchStopCause` vs `StopNotice`: `text` maps to `message`, and `fix` maps `.signIn`/`.chooseFolder`/nil (`BatchSummary.swift:77-161`). | App: thin mapping. Take the summary sentence, sound and notification text from core's `Summary`; keep the app's `BatchSummary` only for its symbol, tone and buttons. | One set of D4 2.8 wording. |
| `resolve(_:_:in:)` for Save As… and Replace. Core has no "save under the name I chose": `TrackDownloadRequest` has no name field. Replace exists as `replaceExisting`. | Core: add an optional `chosenFileName` to `TrackDownloadRequest` (a contract addition), honoured by `DownloadFolder` with the no-overwrite rule. App: run Replace and Save As… as a one-row retry batch. | Same progress, stop and keep-awake as any batch. |
| Folders without a Trash: `TrackDownloadError.folderHasNoTrash` (folder lane, `DownloadContracts.swift:156`) needs a "Delete … permanently?" alert, then `deleteDamagedCopyPermanently` (`DownloadFolder.swift:245`), then a retry. | App: new alert route. | D4 2.3. Today it would show up as a failed row whose reason is a question. |
| Pre-batch checks. The app checks sign-in first (`AppModel+Batch.swift:12-17`); `BatchPreflight.check` checks the folder, then the startup-disk space, then sign-in (`BatchPreflight.swift:53-93`). It also takes a `TokenKeeper.State`. | App: use `BatchPreflight`. Core: add an overload taking a small sign-in enum, so the app doesn't have to fake a `TIDALAccount`. | D4 2.18 sets the order. |
| Quit. `prepareForQuit` calls `stop()` (`RobogearsDownloaderApp.swift:165`). | App: call `stopForQuit()`, apply `summary.returnedRows`, then save the queue. | D4 2.5. |

### 1d. `PreviewProviding` (`:167-177`) → a new core `PreviewService`, plus `PreviewCache` and `WaveformPeaks`

See section 3 for what has to be built. Mismatches on the app side:
- **No priority parameter.** Add `preview(for:priority:)`. A click uses interactive; pre-loading uses background.
- **The download isn't cancelled.** The task at `AppModel+Preview.swift:53` is never cancelled, which breaks D4 5.16 ("cancels … its download at once"). The app should keep a `previewTask` and cancel it in `stopPreview()`.
- **No error kinds.** The app needs a kind so it can write the D4 5.19 sentence with the track's title.

### 1e. `PreviewPlaying` (`:180-194`) → no core type

- `StandInPreviewPlayer` (`StandInServices.swift:243-277`) is already a working AVAudioPlayer player. Move it to `Services/PreviewPlayer.swift`, keep it for the instruments too, and then delete the old copy.
- `PreviewNowPlaying` (core, D4 5.13) is not used anywhere in the app. Wire it into `AppModel` (section 3).

### 1f. `SignInProviding` (`:214-219`) → `DeviceSignIn` plus `TokenKeeper` with a `FileCredentialStore`

- **Adapter:** a struct `CoreSignIn`. Mismatches (all changes on the app side):
  - **Unreadable sign-in.** Add `SignInState.unreadable(String)`. `TokenKeeper.State` has `.unreadable` (`TokenKeeper.swift:76-84`), and D4 1.5 says an unreadable sign-in never counts as signed out.
  - **Push updates.** Add `stateChanges() -> AsyncStream<SignInState>`. Today the app only asks once (`AppModel.swift:190`), so a sign-in refused in the middle of a batch never reaches Settings (D4 1.6).
  - **Sign-out failures.** `signOut()` should return a problem, because `TokenKeeper.signOut` can throw.
  - **Country.** Core gives `TIDALCountry.code` ("US") plus `isAssumed`. Show the localized country name, and "(assumed)" when it is assumed (D4 1.8).

### 1g. `OldAppFilesProviding` (`:228-241`) → `LegacyElectronFiles`

- Already done: the conformance is at `ServiceProtocols.swift:243` (not committed yet) and is used in `AppModel.live()` (`:165`). Nothing further is needed.

---

## 2. What gets built at launch, and who owns what

`AppModel.live()` (`AppModel.swift:146-173`) calls a new **`CoreServices.live(support: StorageLocation.supportDirectory, caches: StorageLocation.cachesDirectory)`**. `cachesDirectory` is new, so the instruments' Caches folder is isolated too: `PreviewCache.standardDirectory` (`PreviewCache.swift:24-28`) points at the real Caches today.

It builds, in this order (constructing anything must not touch the network or start a sweep):

| # | Object | Type, isolation | Notes |
|---|---|---|---|
| 1 | `pace = TIDALPace()` | actor, one for the whole app | |
| 2 | `apiClient = HTTPClient(limits: .api, pacing: pace)` | final class, Sendable | One 429 pauses every caller (`HTTPClient.swift:346, 409, 435`, resolver lane). It must be the client that `TIDALAPI` uses: the resolver relies on it. |
| 3 | `signInClient = HTTPClient(limits: .signIn)` | not paced | Device sign-in on auth.tidal.com. |
| 4 | `audioClient = HTTPClient(limits: .audio)` | not paced | Audio, segments and covers from the CDN. See section 6 for why the CDN is left outside the pace. |
| 5 | `webClient = HTTPClient()` | not paced | Spotify pages (`TrackResolver.web`). |
| 6 | `store = FileCredentialStore(fileURL: .defaultFileURL(in: support))` | struct | D4 1.5, file stage. |
| 7 | `keeper = TokenKeeper(store:, client: apiClient)` | actor | Renewals also wait during a 429 pause. |
| 8 | `tidal = TIDALAPI(client: apiClient, keeper:)` | struct | |
| 9 | `library = LibraryIndexService(cacheFile: AppPaths.libraryIndexFile(in: support))` | actor | `AppPaths.libraryIndexFile` is new. |
| 10 | `resolver = TrackResolver(tidal:, pace:, web: webClient, library:)` | struct | |
| 11 | `previewCache = PreviewCache(directory: caches/Previews)`, `previews = PreviewService(...)` | actors | |
| 12 | `temporaries = TemporaryDownloads(registryFile: AppPaths.temporaryDownloadsFile(in: support))`, `m4a = M4AWriter()` | final class Sendable, struct | `AppPaths.temporaryDownloadsFile` is new. |
| 13 | `CoreDownloader(makeBatch:)` | actor | Each batch: `TrackDownloader(api: PacedTrackDownloadAPI(tidal, pace), audioClient:, folderPlanner: DownloadFolder(folder:), m4aWriter: m4a, temporaries:, log:)` inside `DownloadBatch(tracks:, folder:, kind:, downloader:, sounds: nil)`. `PacedTrackDownloadAPI` is a new core wrapper that runs each API call through `pace.run(.download)`. |

- **On the main actor:** `AppModel`, `QueueRow`, `PreviewPlayer`, `PreviewNowPlaying` and `SoundPlayer`.
- **Actors:** `TIDALPace`, `TokenKeeper`, `LibraryIndexService`, `PreviewCache`, `PreviewService`, `DownloadBatch` and the adapters `CoreLibrary` and `CoreDownloader`.
- **Ownership:** `AppModel.shared` holds `AppServices`, which holds everything above for the app's life.
- **Log lines** from `TrackDownloader` and the resolver's `.log` event reach the activity log through `@Sendable` closures that hop to the main actor.

**Work at launch goes in `start()`, never in `live()`** (`SelfChecks.swift:399` builds `live()` twice):
- `keeper.load()`, then listen to `keeper.stateChanges()` and `pace.statusChanges()`;
- library scan, then on `.ready`: `fillPending`, then `recheck` on every row;
- `temporaries.sweepLeftovers()`, `previewCache.sweepIncoming()`, and `DownloadFolder(folder:).removeLeftoverCopies()` for the current download folder.

**How settings changes reach the services:**

| Change | What happens |
|---|---|
| Download folder | Nothing long-lived holds it. The next batch gets it from the pre-batch check and keeps it to the end (D4 2.17). Badges are re-checked (`setDownloadFolder` already calls `checkDownloadFolder`). |
| Library folder set, cleared or reset | `library.scan(url)` or `scan(nil)`. The newest request wins (D4 3.15). When it reaches `.ready`, every row is re-checked. |
| Sign in | `keeper.replaceSignIn`; the state stream updates the app. |
| Sign out | `keeper.signOut()`, then `stopPreview()`, cancel preview fetches and clear the pre-load queue (D4 5.16, 1.1). It is already blocked during a batch (`AppModel+Folders.swift:209`). |
| Clear Preview Cache | Stop the preview, cancel in-flight fetches, then `clear()`. Otherwise `store` would write into a folder that was just deleted. |
| Sound effects switch, preview volume | Already handled in the app; core plays no sounds. |

---

## 3. Previews

**What exists:**
- `PreviewCache` (`Audio/PreviewCache.swift`): disk cache, LRU trimming, peaks stored at one byte per bar.
- `WaveformPeaks.compute(from:)`: honours cancellation between chunks (`:38`).
- `PreviewNowPlaying`: Now Playing info and the play/pause key.
- The track lane's `AudioFetcher` (internal, `AudioFetcher.swift:14`): direct streams to disk, DASH with 8 segments in flight.
- `FLACAudio(downloaded:)` plus `FLACWriter.write`.

**What's missing:**
1. **A core `PreviewService` actor**, in `Audio/PreviewService.swift`. It has to live in core because `AudioFetcher` is internal there. API: `cachedPeaks(for:)`, `preview(for:priority:) throws(PreviewError) -> PreviewFile(peaks, file, duration)`, `cacheSize()`, `clear()`, `cancelAll()`. Steps:
   - If the cache has the audio, use it. If it has no peaks yet, compute them.
   - Otherwise ask TIDAL for playback info at `.lossless` (D4 5.2: previews stay CD quality) inside `pace.run(priority)`. Hold the pace slot only for that API call, never during the CDN transfer.
   - Read the manifest. Fetch with `AudioFetcher` into `cache.temporaryFile`.
   - Turn DASH into a playable file: if the download is FLAC inside fragmented MP4, write a native `.flac` with `FLACAudio(downloaded:)` and `FLACWriter.write(audio, tags: FLACTags(), coverJPEG: nil, to:)`. The audio spike recommends this because AVAudioFile overstates a joined DASH file's length (`docs/spikes/audio-and-tagging.md:86`).
   - Compute peaks off the actor, with cancellation passed through, then `storePeaks` and `store`.
   - If two requests ask for the same track at once, the second joins the first's download instead of starting another.
   - Error kinds: `signInNeeded`, `offline`, `busy`, `notOffered`, `unreadable`. The app turns them into D4 5.19's sentences with the title.
   - Open question: if TIDAL refuses lossless (an AAC-only track), fall back to `.high`. The track lane added that tier (`TIDALAPI.swift:24`).
2. **`PreviewCache` change:** keep the file's real extension. `audioURL` is fixed to `.flac` (`PreviewCache.swift:98`), so an `.m4a` preview stored under that name won't open in AVAudioPlayer.
3. **One-player rule (D4 5.16), app side:**
   - keep and cancel `previewTask`;
   - only pre-load when signed in (D4 1.1). `pumpPreloads` (`AppModel+Preview.swift:140-166`) doesn't check today;
   - cancel in-flight pre-loads when a batch starts (today `stopPreloading` only empties the waiting list), and when the window closes;
   - stop on sign-out.
4. **Now Playing (D4 5.13):** `AppModel` owns a `PreviewNowPlaying`:
   - on play: `activate { cmd in … }` (play, pause and toggle go to the app's own functions; stop goes to `stopPreview`), then `update(Info(title:, artist:, duration: player.duration, elapsed:, isPlaying:))`;
   - on pause, seek and finish: `update` again;
   - in `stopPreview`: `deactivate()`.
   
   The cover is optional and later: it needs one `TIDALAPI.track` call to find the album cover.
5. **Preview in search ("allow song preview on search"):** `WaveformView` and the preview functions are tied to queue row ids (`WaveformView.swift:10,23`; `startPreview` uses `row(id)`).
   - Hold the open sheet's hits as `QueueRow` objects in `searchRows`, and look up `previewRow(id) = row(id) ?? searchRows[id]`.
   - "Add Selected" appends those same objects to the queue, so bars and playback carry over.
   - The sheet shows cached peaks immediately. Play uses `.interactive` priority, so it still plays during a batch. Pressing on blank bars starts at that point.
   - Closing the sheet stops a preview whose hit wasn't added. One player across the queue and search.
   - **For the owner to decide:**
     - Should search results pre-load at all? I'd say no: it costs about 30 MB a hit, and D4 5.1 covers queue rows only.
     - Space is already "tick" in the search list (`SheetHost.swift:272-277`, D4 4.11), so in search, previews play from the button, the VoiceOver action and Queue › Play/Stop Preview applied to the highlighted hit.
   - VoiceOver labels per D4 5.18: "Play Preview of Blue Lantern", and "Preview position".

---

## 4. Sign-in

**How the sheet maps to core.** `SignInSheet.run` (`SheetHost.swift:125-147`) reads `CoreSignIn.signIn()`, which does:
1. `DeviceSignIn(client: signInClient).requestAuthorization()`, then `.link(auth.verificationURL, code: auth.userCode)` and `.status("Waiting for TIDAL…")`. The link is already guaranteed to be an https tidal.com address.
2. `waitForApproval(of:)` returns a credential.
3. `try keeper.replaceSignIn(with:)`. If saving fails, the person is still signed in for this session; log "won't be remembered after quitting" from `keeper.saveProblem`.
4. `try? await keeper.country()`, then `.signedIn(country:)`.

Cancel or closing the sheet ends the task (`.task(id: attempt)`). The poll's wait throws `CancellationError`, and only one sign-in runs at a time.

Map each `DeviceSignInError` case to D4 1.3's words:

| `DeviceSignInError` | Sentence |
|---|---|
| `.expired` | "The sign-in code expired. Click Try Again for a new one." |
| `.denied` | "You declined access in the browser." |
| `.unreachable` | "Can't reach TIDAL. Check your connection and try again." |
| `.refused`, `.rejected`, `.malformedResponse` | "TIDAL didn't accept the sign-in request. Check for an app update." |
| `.unexpectedVerificationURL` | Say the link wasn't a tidal.com address. |

The raw error description goes to the activity log only.

**Where the sign-in is kept.** `FileCredentialStore` at `~/Library/Application Support/com.robogears.downloader/tidal-sign-in.json` (`CredentialStore.swift:162-174`): mode 0600, written atomically.
- It must be built from `StorageLocation.supportDirectory`, so instrument runs stay isolated. Add a self-check for this.
- Leave `KeychainCredentialStore` (`:303`) unused until the owner creates the certificate (that item is parked). The later one-time move to the Keychain is out of scope here.

**First real sign-in: a live check for the owner** (write it down as `docs/LIVE_CHECK.md`):
1. Settings › TIDAL › Sign In… Record whether TIDAL's link had `https://` or was `link.tidal.com/…` without it, whether a short code appears, whether the browser opened by itself, and what TIDAL's approval page names the app.
2. Approve. The sheet closes about 0.6 s after "Signed in." Settings shows the country, and whether it says "(assumed)".
3. Run `stat -f '%Sp' ~/Library/Application\ Support/com.robogears.downloader/tidal-sign-in.json` and expect `-rw-------`. Confirm the activity log has no token, link or code.
4. Quit, turn Wi-Fi off, relaunch: still "Signed in" (a local check, D4 1.1).
5. Search for a known track; add a TIDAL album link and a Spotify playlist; preview one row; Download All on one track. Check the `.flac` with `/opt/homebrew/bin/ffprobe`: tags, ISRC and cover.
6. Force a renewal: quit, set `expires_at_ms` in the file to the past, relaunch, search. The file gets a new access token (and maybe a new refresh token), and `client_pair` stays the same label (D4 1.9).
7. Optional: click Deny ("You declined…"), and remove the Mac from TIDAL's devices mid-batch to see the D4 1.6 stop.
8. Record everything D4 asks to be checked live: field names, `expires_in`, `interval`, whether any account name or email comes back (D4 1.2), and whether a country code is present.

---

## 5. Build order

Each step is small and can be tested on its own. Everything starts after the final UI-lane merge onto the loop branch: the app's core copy doesn't have the lanes' types until then.

1. **Merge gate (core).** For each lane, before merging:
   - `git diff` is empty and `git status` is clean;
   - search the lane's diff for `if false`, `true,`, `rename(from` and the like;
   - `swift test` passes.
   
   After the resolver merge, reconcile `QueueItem`:
   - keep both sets of new fields;
   - `withID` (`QueueRows.swift:64-73`) copies `losslessOnTIDAL`;
   - `isDownloadable` excludes rows whose library check is pending;
   - `NewRow.tidal` sets `losslessOnTIDAL` from `TIDALAudioQuality.isLosslessTier(track.audioQuality)`.
   
   *Done when* `swift test` is green. *Tests:* an old `queue-v2.json` without the new keys decodes; a round trip keeps every field; `withID` keeps every field (compare `Mirror` children); a track listed only as "HIGH" quality gives `losslessOnTIDAL == false`; a pending row isn't downloadable.
2. **Core: library additions.** `LibraryMatch.libraryDurationSeconds`, `LibraryMarks.recheck`, `LibraryIndexService.statusChanges()`. *Done when* tested: exact matches become left out, similar matches keep the person's choice, no match clears the mark, two listeners both get `.ready`.
3. **Core: public initialisers** for `SearchHit`, `SearchResults`, `SpotifyCapNotice` and `ResolveJob`, plus the `BatchPreflight` sign-in overload. *Done when* the app's stand-ins compile against them.
4. **App: graph skeleton, sign-in only.** `CoreServices.live`, `CoreSignIn`, `SignInState.unreadable`, `stateChanges`; every other service stays a stand-in. *Done when* the app builds and `--run-checks` passes. *Self-checks:*
   - every file path (`tidal-sign-in.json`, library index, temporary-downloads list, preview cache) is inside the instrument run's own folder;
   - a recording URLProtocol passed into `CoreServices.live` sees zero requests while `live()` is built;
   - every `DeviceSignInError` and `TokenKeeper.State` mapping gives the right sentence or state.
5. **App: library.** `CoreLibrary`, `recheck` on `.ready`, `isLibraryCheckPending`. *Self-checks:* the pure `Status` mapping; the stand-in's library lines in Settings are unchanged.
6. **App: resolver.** `ResolveSource`/`ResolveEvent` used in place of the app's own types, `AddRoute`, `job.stop()`, Try Again using `retry`. Rewrite `StandInResolver` to emit `ResolveEvent`. *Self-checks:* Cancel keeps the rows already sent; the summary line comes from `ResolveSummary.message`; a "signInNeeded" failure opens the sign-in-to-continue alert with the source; the cap notice uses core's text.
7. **Core: previews.** `PreviewCache` keeps the extension; `PreviewService`. *Tests, using the mock URLProtocol and the fixtures in `Fixtures/audio/`:*
   - `bts-16-44100.flac` gives 200 peaks with the loudest exactly 1, and a file AVAudioFile can open;
   - the split `dash-24-96000.mp4` gives a native `.flac` that decodes the same number of frames;
   - a second call makes no request;
   - cancelling mid-transfer leaves nothing in `incoming/` and no cache entry;
   - two calls for the same track at once make one fetch;
   - signed out fails with `signInNeeded` and makes no request;
   - offline gives `.offline`, and a 404 gives `notOffered`;
   - a background preview waits while the pace is full.
8. **App: previews.** `CorePreviews`; promote the player; cancel `previewTask`; only pre-load when signed in; cancel pre-loads on batch start, window close and sign-out; Now Playing. *Self-checks:* starting row B cancels row A's fetch (the stand-in records cancellations); sign-out stops playback; a batch start empties the pre-load list and cancels what's in flight.
9. **App: search preview (owner item 3).** `searchRows`, the row's play button and waveform, stop when the sheet closes. *Done when* snapshots show playing, loading and unavailable hits in Light, Dark and both high-contrast appearances. *Self-checks:* one player across the queue and search; an added hit keeps playing.
10. **Core: download additions.** `PacedTrackDownloadAPI`; `TrackDownloadRequest.chosenFileName` honoured by `DownloadFolder`. *Tests:* a download's API calls hold `.download` slots, and an interactive search overtakes them; a 429 on playback info pauses a search running at the same time; a chosen name is never written over an existing file.
11. **App: downloads.** `CoreDownloader`; `StandInDownloader` becomes the real `DownloadBatch` with a scripted per-track downloader; core `Summary` text and sounds; no app keep-awake; the network-pause and resume alert; the no-Trash alert; Replace and Save As… as one-row retries; quit through `stopForQuit`. *Self-checks:*
    - a sign-in rejection at track 1 puts every row back;
    - a retried row returns to its old failure;
    - damaged and name-taken rows survive cleanup and a queue save-and-reload;
    - Cancel plays one chime;
    - Quit applies the returned rows before saving.
12. **App: launch sweeps and the pace status.** Sweeps in `start()`; `pace.statusChanges()` drives "waiting for TIDAL…". *Self-check:* the sweeps run from `start()` only, never from `live()`.
13. **Write `docs/LIVE_CHECK.md`** (section 4) for the owner.

---

## 6. Risks

1. **Lanes edited mid-mutation-check.**
   - **Folder lane, working copy (observed while reading):**
     - `renamex_np(..., RENAME_EXCL)` was replaced by plain `rename`, which would overwrite existing files;
     - `mayTrash: true` in the badge check, which would send damaged copies to the Trash just from showing the queue;
     - `.m4a: true`;
     - `if false, lastFrameEnd != declared`;
     - the CRC check replaced by `true`;
     - the case and Unicode folding removed from the name comparison.
   - **Resolver lane, working copy:** `TIDALPace.canStart` dropped the extra interactive slot; `dispatch` ignores priority; `tooManyRequests` returns at once.
   - **Already happened once:** the batch lane's WIP commit `2a6923d` shipped `if false` around the "three busy failures stop the batch" rule (fixed in `12c51bd`).
   - **Gate:** no "loop: WIP" commit merges without the lane's tests passing and a clean working copy.
2. **`QueueItem.swift`:**
   - the batch fields (`:65-70`, plus new init parameters) and the resolver fields (`:67-70`) are inserted at the same place, so the merge will conflict;
   - the resolver's `withID` drops `losslessOnTIDAL`;
   - neither lane makes `isDownloadable` hold rows whose library check is pending (D4 4.20), although the resolver brief asked the batch lane to;
   - nothing in the resolver sets `losslessOnTIDAL`.
3. **`DownloadContracts.swift`:**
   - the three lanes' edits sit in separate places (track: `M4AWriting` doc; folder: the new `folderHasNoTrash` case and its `rowMessage`; batch: `TrackDownloadOutcome` made `Codable`), so the text should merge cleanly;
   - **but** `folderHasNoTrash` reaches the batch as an ordinary per-row failure whose saved reason is a question, so it needs the app alert from step 11;
   - **and** an unreadable stored sign-in is treated two ways: the track lane maps it to "sign-in no longer valid" (`TrackDownloadFailures.swift:60-62`), the batch lane to "write failed" (`DownloadBatch.swift:670`). The track lane's mapping wins in practice, and it fits the file stage, but it will be wrong once the Keychain stage arrives (D4 1.5).
4. **`HTTPClient.swift`:**
   - the edits don't overlap as text;
   - **but** the track lane's streaming `download()` (`:583`) has its own retry loop with no pace hook, while `send` has one (resolver lane, `:409, :435`). If the audio client were paced, direct streams and segment fetches would behave differently. Keep the audio client unpaced, as in section 2, and record that choice.
   - The new `.media` body type follows redirects. Only audio and cover requests should use it.
5. **`TIDALAPI.swift`:** the track lane adds `.high` to a `CaseIterable` enum (`:24`). Nothing loops over `allCases` today; check again after the merge.
6. **`AudioFetcher` and `ProgressThrottle` are internal,** so `PreviewService` has to live in core.
7. **The pace's rule "never call `run` inside `run`"** (`TIDALPace.swift:53-54`): `PacedTrackDownloadAPI` and `PreviewService` must wrap single API calls only, never a whole download.
8. **The resolver needs the TIDAL client built with `pacing: pace`.** A check for this was added and then removed during this session. Prove it with a test in step 10.
9. **Behaviour that would break silently in the app:**
   - row cleanup deletes damaged and name-taken rows (1c);
   - adding sounds and keep-awake in two places;
   - add-cancel losing buffered rows;
   - preview downloads never cancelled;
   - pre-loading while signed out;
   - `PreviewNowPlaying` never used;
   - `PreviewCache` writing to the real Caches folder in instrument runs.
10. **Still unbuilt:** the online-only library consent (D4 3.8); the Now Playing cover; previews starting before the whole file arrives (D4 5.2 allows download-then-play as the fallback).

### Critical files for implementation
- /Users/william/Developer/swiftRobotDownloader-lane-ui/macos/RobogearsDownloader/Services/ServiceProtocols.swift
- /Users/william/Developer/swiftRobotDownloader-lane-ui/macos/RobogearsDownloader/Model/AppModel+Batch.swift
- /Users/william/Developer/swiftRobotDownloader-lane-batch/macos/Packages/RobogearsCore/Sources/RobogearsCore/Download/DownloadBatch.swift
- /Users/william/Developer/swiftRobotDownloader-lane-resolve/macos/Packages/RobogearsCore/Sources/RobogearsCore/Resolve/ResolveTypes.swift
- /Users/william/Developer/swiftRobotDownloader-lane-ui/macos/Packages/RobogearsCore/Sources/RobogearsCore/State/QueueItem.swift
