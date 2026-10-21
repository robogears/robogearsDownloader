# robogears Downloader (Electron v0.1.30): reference for the Swift rewrite

_Written 21 Oct 2026. Describes the code in this folder, which is identical to GitHub `robogears/robogearsDownloader` main at `b60576d1` (v0.1.30, the latest release). No code was changed and nothing was run._

This folder is the complete, checked description of the existing Electron app. It exists so the Swift version can be built without anyone needing to open the JavaScript again. Start here; the 19 detailed sections are listed at the end.

---

## How this was researched

- **First-hand read.** I read every core source file in full: `tidal_lib.js`, `tidal_download.js`, `bulk_runner.js`, `tidal_auth_node.js`, `tidal_search.js`, `tidal_check_quality.js`, `electron-main.js`, `electron-preload.js`, `renderer/app.js`, `renderer/index.html`, the CI workflow, the signing hook and the ship process. I wrote my own list of 25 issues before seeing any agent output, as an independent check.
- **Multi-agent research (35 agents).**
  - Eleven analysts each mapped one subsystem, reading every line of it. Four more traced end-to-end flows across files, including every failure path.
  - Each of those 15 results went to a skeptic. The skeptic re-read the code, tried to refute every claim and every reported bug, and then wrote the final section.
  - A completeness critic inventoried the whole codebase: 143 functions, 25 IPC request channels, 13 event channels, 53 event listeners, 11 process spawns, 16 network endpoints and 6 environment variables. Everything mapped to a section. Four gap sections then covered the cross-cutting topics: lifecycle, security, logging, and Unicode/filenames.
- **Verification numbers.**
  - 1,945 claims checked; 114 corrected and 221 omissions added.
  - 18 claimed bugs refuted.
  - Every issue on my own list was independently confirmed by at least one section.
- **Limits.**
  - Nothing was run: no app launch, no TIDAL or Spotify calls, no CI. Anything that depends on runtime behaviour is marked **"unverified (needs a run)"** in the sections.
  - `node_modules` is not present, so FFmpeg's and `music-metadata`'s exact behaviour comes from documentation, not observation.
- **Secrets.** The four embedded TIDAL client credential strings appear nowhere in these documents. This was checked by script.

## What the app is

A personal desktop app that downloads lossless FLAC files from TIDAL using the owner's TIDAL subscription.

- **Ways to add tracks:**
  - paste a TIDAL or Spotify link (track, album or playlist);
  - type a song name and pick from search results;
  - drop a CSV, paste text, or pick a file (an Exportify export, or lines of `Title - Artist`).
- **The queue.** Everything lands in a review queue first. Each row has a waveform preview you can play and scrub. Rows that are already in the user's music library are greyed out; rows similar to something in the library get a yellow badge. **Download all** then saves each track as `<Title>.flac` into one flat folder, with full tags and the cover art.
- **Quality.** It always asks for the best TIDAL has: Hi-Res, then CD-quality FLAC, then `.m4a` AAC only when no lossless master exists.
- **Updates.** The app updates itself from GitHub releases.

Owner decision on 21 Oct 2026: **support for the Chrome extension ends**. The Swift app will not include it (see [chrome-extension-removal.md](chrome-extension-removal.md)).

## Architecture today

```
┌──────────── Electron main process (electron-main.js, Node) ────────────┐
│ window · settings.json · queue.json · library index (in memory)        │
│ TIDAL sign-in (in-process) · link/search/import resolving · previews   │
│ GitHub update check / download / macOS relauncher · ffmpeg probe       │
│ localhost:8273 extension bridge (being dropped)                        │
└───────┬───────────────────────────────▲───────────────────┬────────────┘
        │ 25 request channels           │ 13 event channels │ spawn
        ▼                               │                   ▼
┌──── Renderer (renderer/*) ────┐       │     bulk_runner.js (Electron-as-Node)
│ queue UI, waveform canvas,    │       │       one track at a time ──spawn──► tidal_download.js
│ Web Audio sound effects,      │       │       stdout markers:                 manifest → segments
│ activity log, modals          │       └──────  __TRACK_START__/PROGRESS/DONE  → ffmpeg remux + tags
└───────────────────────────────┘                                                → <Title>.flac
```

- All TIDAL, Spotify and file-system work happens in Node; the page only draws.
- Downloads run in two levels of child processes. A batch is one `bulk_runner`. Each track is one `tidal_download` process that runs FFmpeg.
- The child processes report progress through text markers printed on stdout, plus exit codes: `0` downloaded, `2` skipped, anything else failed.
- In the Swift app all of this becomes one process. The only possible external program left is FFmpeg.

## What happens when you…

- **Paste a link.**
  1. The page checks that a TIDAL token file exists.
  2. Main parses the input, trying Spotify, then a TIDAL URL, then bare digits (a track id), then a bare UUID (a playlist). Anything else becomes a search.
  3. TIDAL album and playlist items are fetched 100 at a time. Spotify comes from the public `open.spotify.com/embed/...` page, where playlists are capped at 100 tracks. Each Spotify track is then matched on TIDAL by a title and artist search, eight at a time.
  4. Every track is checked against the library index.
  5. The page adds rows, removes duplicates by TIDAL id, and saves `queue.json` 400 ms later.
- **Press Download all.**
  1. Only included, found rows are sent.
  2. Main writes `pending-tracklist.json` and starts `bulk_runner`. For each track it runs `tidal_download <id> <folder> --skip-library-check`.
  3. `tidal_download` fetches the track and album info, then the playback manifest at `HI_RES_LOSSLESS` (`LOSSLESS` only if that request fails). The manifest is either a BTS JSON with one URL, or a DASH segment list fetched eight at a time.
  4. Meanwhile it fetches the 1280×1280 cover. FFmpeg then copies the audio into `<Title>.flac` (or `.m4a`) with tags, and adds the cover piped on stdin as picture type 3.
  5. A decode check runs (it only warns). The temp file is deleted.
  6. The page updates each row and a batch `N / M` bar. At the end it plays a ping and removes downloaded and skipped rows.
- **Preview a track.** Main downloads the whole `LOSSLESS` stream. The page decodes 200 peaks from channel 0, draws them on a canvas, and plays the file through a blob-URL `<audio>` element at slider². Every queued track is also pre-loaded this way, two at a time, keeping only its peaks.
- **Import a CSV or text list.** The page parses it, picks CSV columns by header name or splits text on ` - `, ` — `, `|` or tab, and removes duplicates. Main then searches TIDAL for each track one at a time and scores the results. Progress shows as `Matching N / M tracks on TIDAL…`.
- **Sign in.** This uses TIDAL's OAuth device-code flow with one embedded client pair. The token is saved to `token.json` together with a *different* embedded client pair, which is used for refresh. Access tokens expire after `expires_in − 60 s` and are refreshed when needed.
- **Update.** On launch the app reads GitHub `/releases/latest` and compares version numbers, then finds the asset whose name contains `mac-arm64.dmg` (macOS) or `setup.exe` (Windows). On macOS it mounts the DMG, copies the `.app` out, quits, and a double-forked bash script waits, backs up, replaces, strips quarantine, ad-hoc re-signs and reopens the app. On Windows it runs the NSIS installer with `/S --updated`.

## Files on disk (`~/Library/Application Support/robogears Downloader/`)

| File | What it holds | Notes for the port |
|---|---|---|
| `settings.json` | `{ downloadFolder, libraryFolder, volume }`. `volume` is the linear slider value. | The whole file is rewritten on every save. A file that can't be read is silently treated as `{}`. |
| `queue.json` | An array of queue rows: `tidalId, title, artist, duration, source (tidal/spotify/import/extension), matchMethod, notFound, hiRes, album, libraryMatch {kind, path, libraryTitle}, included, key, originalTitle/Artist`. | Download status fields are stripped before saving. Old queues may contain `source:"extension"` rows. |
| `token.json` | A **JSON array** of `{access_token, refresh_token, userID, countryCode, expires_at (ms), client_ID, client_secret}`. | Plaintext with default permissions. The readers use `entries[0]`, but a new sign-in is appended at the end. |
| `pending-tracklist.json` | `{ tracks, outDir }`, used to hand a batch to `bulk_runner`. | Deleted when the batch ends. |
| `extension-token.txt`, `chrome-extension/` | Extension bridge leftovers. | Not ported; clean-up is an owner decision. |
| `~/Library/Logs/robogears Downloader/` | `attempts.log` and `update-<ts>.log` from the macOS updater. | The only persistent log. |
| Download folder | `<Title>.flac` / `<Title>.m4a`, flat. Temp files are `<Title>.tmp.m4a` / `<Title>.tmp.flac`. | A temp file is left behind on failure. |

In dev mode `token.json` lives next to the source instead.

## External services

| Service | Calls |
|---|---|
| TIDAL auth `auth.tidal.com` | `POST /v1/oauth2/device_authorization`, `POST /v1/oauth2/token` (device poll and refresh). The form body carries scope `r_usr+w_usr+w_sub`, sent as `%2B`. |
| TIDAL API `api.tidal.com` (Bearer, `X-Tidal-Platform: android`, UA `okhttp/5.3.2`) | `/v1/tracks/{id}`, `/v1/albums/{id}`, `/v1/albums/{id}/items`, `/v1/playlists/{uuid}`, `/v1/playlists/{uuid}/items`, `/v1/tracks/{id}/playbackinfopostpaywall`, `/v1/search/tracks`, `/v1/users/{id}`, `/v1/tracks?isrc=` (never reached) |
| TIDAL CDN | segment and stream URLs taken from manifests; covers at `resources.tidal.com/images/<id with / >/1280x1280.jpg` |
| Spotify | `open.spotify.com/embed/{track,album,playlist}/{id}`. The app parses `__NEXT_DATA__` → `props.pageProps.state.data.entity`. No Spotify credentials are used. |
| GitHub | `api.github.com/repos/robogears/robogearsDownloader/releases/latest`, plus the release asset download. |
| Exportify | Only opened in the browser from the drop zone. |

## Product rules the Swift app must keep (checked against the code)

| Rule | Status today |
|---|---|
| Download folder starts blank; nothing downloads until the user picks one. | Holds |
| All files go flat into the chosen folder: no album or playlist subfolders. | Holds |
| Filename is the sanitized TIDAL title only: `<Title>.flac`, or `.m4a` for the AAC fallback. | Holds. Consequence: different songs with the same title skip each other. |
| An existing `<Title>.flac` or `<Title>.m4a` in the download folder means "skip". | Holds. A half-written file also counts as done (defect M1). |
| Library folder is read-only. Exact matches (title **and** artist agree) are greyed out with **+ Add**; similar matches get a yellow badge and stay included. | Holds |
| Quality: Hi-Res, then lossless, then `.m4a` only if TIDAL has no lossless master. `audioQuality` decides FLAC or not. | Holds |
| Cover art is held in memory and written as front-cover picture type 3 (needed by Rekordbox and Serato). It is never saved as a temp `.cover.jpg`. | Holds |
| Tags: title, all artists joined with `, `, album, album artist, track, disc, year, copyright, ISRC. | Holds |
| No Spotify API keys or OAuth; public embed only, with the 100-track cap warning. CSV import is the workaround. | Holds |
| Queue survives restarts. | Holds |
| Monochrome identity: pure black, white text, colour only for status; music-themed loading lines; the sound effects and easter eggs. | Holds (keep, unless the owner says otherwise) |
| Never auto-release. Release notes hold the current version only. Releases are drafts. | Process rule. The owner's global versioning rule overrides the project's `ship.md`. |

## Defects not to carry over (deduplicated by root cause)

The severity scale follows the owner's manual: silently losing data the person expects kept is at least Medium. Section files hold the evidence, worked examples and exact line references.

| # | What goes wrong | Sev. | Where |
|---|---|---|---|
| H1 | **The app quits when TIDAL isn't signed in.** `loadCred()` calls `process.exit(1)` inside the main process. Dropping or pasting a CSV while signed out triggers it, and so does previewing. With a saved queue and a missing or empty `token.json`, the boot pre-loader quits the app **on every launch**. | High | `tidal_lib.js:48-58`; `electron-main.js:661, 702, 875, 925`; `app.js:1830-1843, 1984-1986` |
| H2 | **Signing in again never takes effect.** `saveToken` appends a new entry, but every reader uses `entries[0]`, so a dead credential can't be replaced from the app. | High | `tidal_auth_node.js:53-59`; `tidal_lib.js:59, 66` |
| H3 | **Queue rows vanish when a batch dies early.** Rows still `queued` or `downloading` are dropped and the loss is saved. Triggers include a refresh failure and Retry without sign-in. | High | `app.js:1468-1481`; `bulk_runner.js:53-58, 115-118` |
| M1 | **A half-written file counts as downloaded forever.** FFmpeg writes straight to the final name; skip-if-exists trusts any file with that name; the integrity check only warns. | Medium | `tidal_download.js:289-309, 355-366, 464` |
| M2 | **Cancel doesn't stop the track in progress, and quitting stops nothing.** Cancel kills `bulk_runner` only. The track finishes in the background while its row says failed, and the done signal waits for it. ⌘Q and Update now leave the downloads orphaned. | Medium | `electron-main.js:548-551, 646-653`; `bulk_runner.js:41-44` |
| M3 | **Same-title songs collide.** The second song is silently skipped and then removed from the queue. On case-insensitive APFS, `Intro` and `INTRO` collide too. | Medium | `tidal_download.js:352-366` |
| M4 | **TIDAL API calls never retry.** A 429, 5xx or timeout during Spotify or import matching shows as "not found", and the real reason for a manifest failure is hidden. (CLAUDE.md wrongly says the API retries.) | Medium | `tidal_lib.js:156-168`; `electron-main.js:972-974`; `tidal_download.js:325-342` |
| M5 | **Text matching is ASCII-only.** Non-Latin titles normalize to an empty string and match the wrong song; accents are dropped (`café` → `caf`); non-Latin library files never match. The matcher is also copied four times with different rules: an exact title is accepted with no artist check, and `the` counts as an artist word. | Medium | `tidal_lib.js:580-610, 626-653`; `electron-main.js:707-743, 938-974`; `bulk_runner.js:11-29` |
| M6 | **Sign-in can't be cancelled or dismissed.** A failed sign-in leaves a full-window modal with no way out. The auth requests have no timeout, and `slow_down` is treated as fatal. | Medium | `index.html:205-220`; `app.js:1716-1729`; `tidal_auth_node.js:133-170` |
| M7 | **The library index can keep the old folder** when the folder is changed, cleared or reset during a scan. | Medium | `tidal_lib.js:28-31, 674-757` |
| M8 | **Two quick preview clicks leave an orphaned player** that no control can stop. | Medium | `app.js:788-881` |
| M9 | **The waveform pre-loader downloads every queued track's full lossless file**, again on every launch for a restored queue, and is never cancelled. Play downloads the file again, and the batch a third time. | Medium | `app.js:730-767, 1984-1986`; `electron-main.js:873-917` |
| M10 | **State files are written non-atomically.** Corrupt files silently become empty, and several processes can write `token.json` at once. | Medium | `electron-main.js:38-44, 594-606`; `tidal_lib.js:62-68` |
| M11 | **Updates are not verified.** There is no integrity check of the downloaded update. If no asset matches, the release *web page* URL is handed to the installer. | Medium | `electron-main.js:156-160, 204-235, 288-469` |
| L1 | **UTF-8 text can be garbled** when a multi-byte character is split across network chunks. | Low | `tidal_lib.js:144-146` (and copies) |
| L2 | **"Batch finished" and the success ping play even when every track failed.** `bulk_runner` always exits 0. | Low | `bulk_runner.js:114`; `app.js:1457-1461` |
| L3 | **Greyed "already in library" rows are removed after any batch.** | Low | `app.js:1468-1473` |
| L4 | **The volume slider is restored as the squared value**, and Reset config wipes the volume. | Low | `app.js:1947-1948`; `electron-main.js:561-565` |
| L5 | **The Exportify link also opens the file picker.** A file dropped outside the drop zone probably navigates the window away (unverified). | Low | `app.js:1763, 1813-1816` |
| L6 | **The UI can stick in "Downloading…".** Errors from `startBulk` are ignored, and closing the window on macOS mid-batch can wedge it. | Low | `app.js:1112, 1416, 1453`; `electron-main.js:1004-1039` |
| L7 | **Launch-time messages are probably lost.** They are likely sent before the page listens (FFmpeg missing, for example), and the FFmpeg probe ignores the exit code. | Low | `electron-main.js:476-546` |
| L8 | **Input quirks.** Bare digits are treated as a TIDAL id, unsupported links are searched as text, and the 100-track warning fires at exactly 100. CSV import takes the first header containing "artist", which may be an artist URI (unverified). Plain-text import splits at the first hyphen (`Anti-Hero`). | Low | `tidal_lib.js:431-551`; `app.js:1899-1939` |
| L9 | **No single-instance lock.** The default Electron menu exposes Reload and DevTools during a batch. | Low | `electron-main.js` (absent) |
| L10 | **The log can't be selected or copied.** Signed CDN URLs and raw API bodies end up in it. | Low | `styles.css:36`; `tidal_lib.js:207-214` |
| L11 | **Accessibility gaps.** No keyboard or VoiceOver access to the waveform or retry checkboxes; no Escape for modals; the play button's accessible name never changes. | Low | `app.js:946-956, 322-326` |
| L12 | **Imported rows never show Hi-Res.** A rotated refresh token is ignored, there is no refresh after a 401, and the country-code fallback isn't cached. | Low | `electron-main.js:961-971`; `tidal_lib.js:86-119` |
| L13 | **CI release bodies are empty.** The release job never checks out the repo, so `RELEASE_NOTES.md` is missing. This is the probable root cause of the documented quirk; unverified. | Low | `.github/workflows/release.yml:44-58` |

There are about 200 smaller items (stale comments, dead code, CLI-only quirks) in the sections.

## Porting map: what each piece becomes

| Today | Swift equivalent | Difficulty |
|---|---|---|
| Two processes with IPC, plus `bulk_runner` and `tidal_download` child processes, plus stdout markers | One app. Services and actors with `async` methods; progress as `@Observable` state or `AsyncStream`. One batch `Task`, one track at a time, segments in a `TaskGroup` of 8. | Medium |
| Node `https` with hand-rolled redirects and retries | `URLSession` with the same per-call headers. Use a custom percent-encoder (`URLQueryItem` leaves `+` unescaped and would break both search and the auth form). Add a retry wrapper (`min(1000·2ⁿ, 8000)` ms). | Easy |
| `token.json` | One credential actor with a single in-flight refresh. Keychain or an atomic 0600 file (owner decision). Throws "not signed in" and never exits. | Medium |
| Device-code sign-in | Same requests and headers. A sheet with the URL, Copy, Cancel and Close; a deadline; `slow_down` handled. | Easy |
| Spotify embed scrape and matcher | Same regex and JSON path. **One** matcher function: stable sort, Unicode-scalar normalization (exact parity, or fixed and Unicode-aware — owner decision). | Easy |
| Library scan (`music-metadata`) | `FileManager` enumerator off the main thread; an actor-owned index with a generation counter. FLAC, Ogg and Opus tags need TagLib, SFBAudioEngine or small hand-written parsers, because AVFoundation's FLAC tag support is weak. | Hard |
| Manifest parsing | `JSONDecoder` for BTS; regex or `XMLParser` for DASH (`startNumber` defaults to 1; each `<S>` element contributes `r + 1` segments). | Easy |
| FFmpeg remux and tagging | Option A: bundle a signed `ffmpeg` in `Contents/Helpers` and keep the exact argument list (licence review needed). Option B: a native FLAC writer (STREAMINFO from BTS FLAC, or from the `dfLa` box in fMP4, plus `VORBIS_COMMENT` and a `PICTURE` of type 3), and `AVAssetExportSession` for `.m4a`. | Medium (A) / Hard (B) |
| Preview: Web Audio peaks plus `<audio>` | `AVAudioFile`/`AVAssetReader` for peaks and `AVPlayer` for playback, *if* AVFoundation decodes TIDAL's FLAC and FLAC-in-fragmented-MP4 (unverified). Load on demand and cache peaks on disk. | Hard (until the spike) |
| Web Audio sound effects | `AVAudioEngine` with source nodes, or pre-rendered short buffers using the exact frequencies and envelopes in [waveform-preview-and-sounds.md](waveform-preview-and-sounds.md). | Easy |
| HTML and CSS UI | SwiftUI plus AppKit where needed: menu bar commands with shortcuts, Settings window (⌘,), sheets, toolbar, hover and right-click menus, keyboard access. The monochrome identity mapped onto native materials. Design led per the owner's rules (Fable lead, `apple-design` skill). | Medium |
| Self-updater | Keep the GitHub release contract, or move to Sparkle 2 (EdDSA). Either way add integrity checking. Migrating existing Electron users depends on the repository, tag and asset-name contract below. | Medium |
| electron-builder, NSIS, DMG, CI | `xcodebuild` archive, ad-hoc or Developer ID signing, DMG, GitHub Actions on `macos-latest`. Windows builds end unless the owner says otherwise. | Medium |

## Spikes needed before building (each needs a live run)

1. **TIDAL from Swift.** Run the device sign-in and a token refresh with today's exact headers and encoding. Check that refreshing with the second client pair still works for tokens issued to the first. Check whether `verificationUriComplete` includes `https://`.
2. **Audio decoding.** Can AVFoundation decode and play TIDAL's raw FLAC (BTS) and FLAC-in-fragmented-MP4 (DASH)? This decides the preview design and whether FFmpeg stays.
3. **Remux and tags.** Record exactly which Vorbis comment and MP4 keys FFmpeg writes today, so files from the Swift app stay identical for Rekordbox, Serato and the owner's library. Then choose between a bundled FFmpeg and a native writer.
4. **Library tag reading.** Pick a FLAC, Ogg and Opus tag reader. Measure scan time on the owner's real library (today about 18 s for about 500 files, unverified).
5. **Migration path.** The v0.1.30 updater only looks at `robogears/robogearsDownloader` `/releases/latest`. It needs a tag numerically above `0.1.30` and an asset whose name contains `mac-arm64.dmg`, with the `.app` at the DMG root. It installs over `/Applications/robogears Downloader.app`. If the Swift app ships anywhere else or restarts at `0.1.1`, existing users won't be offered it. Windows users would be sent a macOS-only release unless that is handled.

## Abandoned approaches (don't repeat)

| Approach | Why it was dropped |
|---|---|
| Spotify Client Credentials or user OAuth | Blocked for new developer apps since Nov 2024. |
| Anonymous `/get_access_token` | Returns 403. |
| Hidden-browser scraping of the Spotify web player | Scrolling was unreliable; never built properly. |
| OCR drop zone | Replaced by the CSV import. |
| TIDAL v2 `trackManifests` | Returned 404. |
| Windows portable exe with a `.cmd` file swap | Replaced by the NSIS installer. |
| Topbar loading pill | Reverted; the full-screen overlay reads better. |
| `cwd: __dirname` spawns | Electron-only problem. |
| electron-updater | Needs a Developer ID. |
| Chrome extension | Support ended 21 Oct 2026. |

Full history in [docs-drift-rules-and-history.md](docs-drift-rules-and-history.md).

## Documentation that is out of date

- `CLAUDE.md` describes v0.1.25. It never mentions the extension (v0.1.26–v0.1.30), and claims a few things the code doesn't do: API retries, `getManifestV2`, three Settings tabs, and a `Z:\Downloads` fallback in `bulk_runner`.
- `BOT_PROMPT.md` describes v0.1.16 and its portable `.exe`.
- `ONBOARDING.md` predates the GUI.
- `updater.md` and `waveformplayback.md` are generic guides that differ from this repo's code.

The full drift ledger is in [docs-drift-rules-and-history.md](docs-drift-rules-and-history.md).

## Section index

| Section | Covers |
|---|---|
| [tidal-and-spotify-networking.md](tidal-and-spotify-networking.md) | HTTP helpers, every TIDAL call, URL parsing, the Spotify embed, the Spotify→TIDAL matcher with worked scoring examples |
| [library-scanner-and-matcher.md](library-scanner-and-matcher.md) | Folder walk, tag reading, normalisers with worked examples, the four-pass match order, an exact/similar/none example table |
| [download-pipeline.md](download-pipeline.md) | `bulk_runner`, `tidal_download`, manifests, segments, the exact FFmpeg arguments, tags, exit codes, CLI tools |
| [main-process-and-ipc.md](main-process-and-ipc.md) | Startup, window, every IPC channel, settings and queue files, resolve, import, preview, batch, cancel |
| [renderer-queue-and-flows.md](renderer-queue-and-flows.md) | Queue model, row rendering and badge precedence, input, search modal, downloads, retry, Settings, update UI, import parsers |
| [waveform-preview-and-sounds.md](waveform-preview-and-sounds.md) | Preview player and caches, peaks, canvas drawing, scrubbing, the exact synthesis of every sound effect |
| [visual-design-and-copy.md](visual-design-and-copy.md) | Colours, type, spacing, motion, every component, badge styles, the full copy deck, accessibility baseline |
| [tidal-sign-in-and-tokens.md](tidal-sign-in-and-tokens.md) | Device-code flow, header matrix, token file, refresh, country code, sign-in UI |
| [packaging-ci-and-updater.md](packaging-ci-and-updater.md) | electron-builder config, CI, ship process, updater, the verbatim macOS relauncher, migration notes |
| [chrome-extension-removal.md](chrome-extension-removal.md) | What the extension did, every touchpoint, what to keep (the shared matcher), leftovers on disk |
| [docs-drift-rules-and-history.md](docs-drift-rules-and-history.md) | Product rules with status, doc drift, release history, abandoned approaches, backlog status |
| [flow-link-to-flac.md](flow-link-to-flac.md) | End-to-end trace: input → queue → FLAC on disk |
| [flow-launch-and-quit.md](flow-launch-and-quit.md) | Boot order, what quitting or closing does to work in flight |
| [flow-import-and-preview.md](flow-import-and-preview.md) | CSV/text import trace and preview trace |
| [flow-failures-and-data-safety.md](flow-failures-and-data-safety.md) | Every failure path: what the user sees, what is left on disk |
| [lifecycle-and-concurrency.md](lifecycle-and-concurrency.md) | Lifecycle hooks, single instance, start-up and shut-down races, power management, concurrency limits |
| [security-model.md](security-model.md) | Trust zones, HTML sinks, privileged IPC verbs, update trust chain, secrets at rest |
| [logging-and-diagnostics.md](logging-and-diagnostics.md) | Every diagnostic channel, silent failures, what can't be copied or turned on |
| [text-unicode-and-filenames.md](text-unicode-and-filenames.md) | `sanitize`, name collisions, library walk edge cases, ASCII normalization effects, import encodings, dates |
