# Project: robogears Downloader (read this first)

You've just inherited a personal music-downloader app. **Read this entire file before doing anything.** It contains the working architecture, all mandatory rules, full history of what was tried and abandoned, and where the last session left off.

---

## What this is

A desktop app that downloads lossless FLAC tracks from TIDAL, driven by:

- A user's TIDAL subscription (OAuth via device-code flow, runs in-process in Electron main)
- Inputs: paste a TIDAL URL, paste a Spotify URL (track / album / playlist), type a song name to search, or drop a CSV / paste a tracklist into the import drop-zone (bypasses Spotify's 100-track embed cap)
- A "queue" UI where the user reviews tracks before downloading, with inline waveform preview + scrub-to-skim per row
- A read-only **music library folder** that the app scans (reads ID3/Vorbis/iTunes tags via `music-metadata`) to avoid re-downloading songs the user already has
- An in-app updater that quietly checks GitHub releases on launch — both a one-click "Update now" pill next to the version label AND a download notice in the activity log

Tech: Node.js + Electron, no framework, vanilla HTML/CSS/JS for the renderer. All audio handling done via `ffmpeg-static` (bundled FFmpeg).

**Where it lives:** `Z:\robogearsDownloader\` (also published at https://github.com/robogears/robogearsDownloader)

**Current version:** v0.1.25 (published). Ships as an **NSIS installer for Windows** (`robogears-downloader-setup.exe`, installs per-user to `%LOCALAPPDATA%\Programs\robogears Downloader\`) and a **macOS arm64 DMG** (turntable-themed install window). Both built on GitHub Actions and attached to a draft release on every `v*` tag push. **Auto-updates apply in-place on both platforms.** Windows uses NSIS oneClick silent-install (`installer.exe /S --updated` — the installer handles process detection, file replacement, and relaunch); macOS mounts the DMG (`hdiutil`), extracts the `.app` (`ditto`), and a double-fork bash relauncher installs to `/Applications/`, strips quarantine, re-signs ad-hoc, and `open`s it.

---

## Quick orientation: what works today

| Feature | State |
|---|---|
| TIDAL URL → track/album/playlist resolve + download | ✅ works |
| Spotify URL (track / album / playlist) → public embed page → match each on TIDAL → download | ✅ works (**playlists capped at 100 tracks** — Spotify's embed limit; workaround: CSV import via Exportify, see below) |
| Free-text search → modal of TIDAL results → pick → add to queue | ✅ works |
| **CSV / text-paste import** into the drop-zone → matched on TIDAL → added to queue (with live `Matching N / M` progress) | ✅ works — accepts Exportify CSVs, any tool with title/artist columns, or pasted lines of `Title - Artist`. Bypasses the Spotify 100-track cap |
| Queue UI with per-item remove, "+ Add" button on exact-library-matches, "Download all" | ✅ works |
| **Inline waveform preview** per queue row — circular play button + scrubbable waveform | ✅ works — click play, hold-and-drag the waveform to scrub. Spotlight hover effect. Pre-loads in background (concurrency 2) as tracks enter the queue. Works on both BTS and DASH manifests |
| **Volume slider** for previews (squared curve so the low end gets quiet faster than linear) | ✅ works — defaults 50%, persists to settings |
| Settings split into **Folders / TIDAL / Updates tabs** | ✅ works |
| **Persistent queue across restarts** — saved to `<userData>/queue.json` | ✅ works |
| Library deduplication via metadata + filename — **requires title AND artist to confirm for "exact" matches** (otherwise demotes to similar, with warning badge) | ✅ works (tightened in v0.1.24 — false-positive title-only matches downgraded) |
| Settings: download/library folders (blank on first launch), library refresh w/ live "Scanning N / M…" progress, Reset config, Updates section | ✅ works |
| In-app updater (checks GitHub releases on launch + manual button in Settings) | ✅ works |
| **Topbar "Update now" pill** next to the version label — single-click download + auto-apply + restart | ✅ works — pulses subtly when an update is available. Activity-log notice (two-click Download then Restart) still exists alongside |
| Self-installing updater on **both** Windows and macOS | ✅ works — Windows runs the downloaded NSIS installer in silent mode (`/S --updated`), which handles process kill + file replace + relaunch; macOS mounts the DMG (`hdiutil`), copies the `.app` out (`ditto`), and a double-fork bash relauncher installs to `/Applications/`, strips quarantine, re-signs ad-hoc, and `open`s it |
| FFmpeg presence verified at startup; clear warning in activity log if missing | ✅ works |
| Activity log capped at 2000 lines so long sessions don't bog down the DOM | ✅ works |
| Cross-platform CI (Windows `.exe` + macOS arm64 `.dmg`) via `.github/workflows/release.yml` | ✅ works |
| macOS DMG with custom install window (turntable scene: app icon as record, `/Applications` as platter, vertical tonearm) | ✅ works |
| Custom monochrome app icon (vinyl + download arrow), shown in topbar and as `.exe` / `.app` icon | ✅ works |
| Per-track progress in the queue during bulk downloads (badge + thin progress bar per row) | ✅ works |
| Overall batch progress bar above the queue (`N / M` counter) | ✅ works |
| Cancel button during downloads + descending cancel chime | ✅ works |
| Per-row `↻ Retry` button on failures + header `↻ Retry all (N)` / `↻ Retry selected (M)` with checkbox multi-select | ✅ works |
| TIDAL OAuth runs in-process in Electron main (no spawned auth child) | ✅ works (`tidal_auth_node.authenticate()`) |
| Auto-fallback FLAC → .m4a when no lossless master; FLAC detection uses `audioQuality` as primary signal | ✅ works |
| Cover art embedded via piped FFmpeg stdin | ✅ works (no temp file) |
| Parallel segment downloads (8 concurrent) for DASH; streaming direct download with byte-level progress for BTS manifests | ✅ works |
| Accepts both old `application/vnd.tidal.bt` and new `application/vnd.tidal.bts` manifest variants | ✅ works |
| Retry on 429/5xx with exponential backoff | ✅ works |
| Library scan reads audio tags (title, artist, duration) via `music-metadata` | ✅ works |
| Funny rotating loading text during search/resolve | ✅ works |
| Sound effects: download chime, cancel chime, blocked-action warning honk, batch-success ping, brand-click fart (high-pitched on version-click) | ✅ works (Web Audio, no asset shipping) |
| Batch summary distinguishes downloaded / skipped / failed / not-found | ✅ works |
| Skip messages clarify "in downloads folder" vs "in music library" | ✅ works |

---

## MANDATORY RULES (these are non-negotiable)

### 1. Download folder defaults — CLI vs GUI

- **CLI** (`tidal_download.js`, `bulk_runner.js`): hard-coded fallback is `Z:\Downloads` when no path is passed via the command line. **Never use `Z:\Downloads\Music`, the current working directory, or anything else.**
- **GUI**: starts **blank** on first launch — no auto-applied default folder. The user must pick one in Settings before `Download all` works (it errors out with "Pick a download folder in Settings first" otherwise). The boot welcome message reflects this state. Do not reintroduce a `DEFAULT_DOWNLOAD` constant in `electron-main.js`.

### 2. Album and playlist downloads land directly in the output dir

No per-album subfolders, no per-playlist subfolders. Every file goes flat into the chosen dir. The skip-if-exists check handles name collisions safely.

### 3. Filename is `<Title>.flac` (or `<Title>.m4a` for AAC fallback)

Title only — no artist prefix, no track number prefix. User explicitly requested this.

### 4. Library deduplication is enforced before every download

`tidal_download.js#downloadTrack` calls `lib.findInLibrary(title, artist, duration)` before any network fetch. If the result is `kind: 'exact'`, skip silently. If `kind: 'similar'`, also skip with a warning. Only `--force` (or `--skip-library-check` from `bulk_runner`) bypasses this.

The GUI surfaces library matches in the **queue itself** — no modal. Exact matches are greyed out with a "+ Add" button so the user can explicitly opt in. Similar matches show a yellow `⚠ similar version in library` badge but remain included by default.

**Strict artist check (v0.1.24+):** an `exact` match now requires title AND artist to both be present and overlap. Library files with empty/missing artist ID3 metadata (common in SpotDownloader-style MP3 dumps) used to slip past the over-lenient `artistOk` check and be flagged as exact duplicates based on title alone. They now demote to `similar` (yellow badge, still downloads) so the user sees the warning but doesn't get falsely auto-skipped. Filename-based matches also demoted to `similar` — a filename's title is no proof of identity without artist confirmation.

**Never** write to the library folder. It's read-only by design — the user manages it themselves.

### 5. Quality policy — always go for the highest lossless TIDAL has

1. Request `HI_RES_LOSSLESS` (24-bit, up to 192 kHz)
2. TIDAL auto-downgrades to `LOSSLESS` (16-bit/44.1 kHz) when no Hi-Res master exists
3. If TIDAL has neither (rare — old indie etc.), output a `.m4a` (320 kbps AAC) with full metadata + cover

Pass `--flac-only` only if the user explicitly asks. Default is "take whatever TIDAL has."

### 6. Cover art is piped to FFmpeg via stdin

Never write a temp `.cover.jpg`. `fetchCover()` returns a Buffer; `remuxToFlac()` passes it as `-f mjpeg -i pipe:0` to FFmpeg's stdin. If you see code creating `Title.cover.jpg`, that's a regression — it was deliberately removed earlier.

---

## Architecture: how the pieces fit together

```
Z:\robogearsDownloader\
├── electron-main.js          ← Electron main process (Node). All IPC handlers,
│                              download child-process spawns, in-process TIDAL
│                              auth, GitHub release update check, BrowserWindow
│                              lifecycle, library scan kickoff at boot.
├── electron-preload.js       ← Sandboxed bridge. Exposes a curated `api` object
│                              to the renderer via `contextBridge`.
├── renderer/
│   ├── index.html            ← Single-page UI. Modals: settings (folders +
│   │                              TIDAL + Updates + Reset), search results,
│   │                              auth-progress (with URL + Copy), loading.
│   ├── styles.css            ← Monochrome (pure black, stark white) theme.
│   └── app.js                ← Renderer logic: queue, modals, sound effects,
│                              funny loading text, IPC calls, update notice.
├── tidal_lib.js              ← The brain. Shared between Electron main AND CLI
│                              scripts. Token mgmt, HTTP w/ retry+timeout, TIDAL
│                              API wrappers, Spotify embed scraping,
│                              library scanner, URL/search resolver.
├── tidal_download.js         ← CLI: download one URL or numeric track ID.
│                              Spawned by Electron main as a child process per
│                              track during bulk runs. Also usable standalone.
├── tidal_auth_node.js        ← TIDAL OAuth device-code flow. Exports
│                              `authenticate({onLog, onVerificationUrl, ...})`
│                              for in-process use from electron-main. CLI mode
│                              still works via `require.main === module`.
├── tidal_search.js           ← CLI: search TIDAL by free text. Standalone tool.
├── tidal_check_quality.js    ← CLI: probe what quality tiers TIDAL has for a
│                              track ID. Diagnostic.
├── bulk_runner.js            ← Takes a tracklist JSON, spawns tidal_download.js
│                              per track. Used by the GUI's "Download all".
├── build/
│   └── after-pack.js         ← electron-builder afterPack hook. Ad-hoc signs
│                              the macOS .app (codesign --sign -) so Apple
│                              Silicon Gatekeeper doesn't show "damaged".
├── .github/
│   └── workflows/
│       └── release.yml       ← CI: triggers on `v*` tag push. Builds .exe on
│                              windows-latest, mac arm64 .zip on macos-latest,
│                              attaches both to a draft GitHub release.
├── RELEASE_NOTES.md          ← Body of the current draft release. Overwritten
│                              on each version bump — current version only.
│                              Consumed by softprops/action-gh-release via
│                              `body_path` in release.yml.
├── token.json                ← TIDAL OAuth tokens (access + refresh + expires_at
│                              + countryCode). Gitignored. Lives at
│                              %APPDATA%\Roaming\robogears Downloader\ in both
│                              dev and packaged builds (via app.setName).
├── package.json              ← Deps, build config (electron-builder), CI scripts.
├── start_app.bat             ← Convenience launcher: `npm start`
├── README.md                 ← Public, user-facing readme (GitHub front page)
├── ONBOARDING.md             ← Older docs for the CLI workflow. Still mostly
│                              accurate for CLI usage. The GUI superseded most.
└── CLAUDE.md                 ← This file.
```

### Process model

- **Electron main** (`electron-main.js`): owns the BrowserWindow, all IPC, the library scanner cache, the TIDAL auth flow (in-process via `require('./tidal_auth_node').authenticate(...)`), and the GitHub-release update check. Imports `tidal_lib.js` directly.
- **Renderer** (`renderer/`): UI only. Talks to main via `window.api.*` (preload bridge). Never touches files or network directly.
- **Spawned download children** (`tidal_download.js`, `bulk_runner.js`): spawned by main with `ELECTRON_RUN_AS_NODE=1` and `TIDAL_LIBRARY_FOLDER` / `TIDAL_TOKEN_PATH` env vars inherited via `childEnv()`. Output streamed back to renderer via stdout/stderr capture in main.
- **Auth is NOT a child** anymore. Old design spawned `tidal_auth_node.js` as a child, but `cwd: __dirname` resolved to an asar virtual path in packaged builds and `posix_spawn`/`CreateProcess` choked with ENOENT. Auth now runs in-process; same class of bug remains a risk for any future child spawn — see "Don't reintroduce `cwd: __dirname`" in the Don'ts.

### IPC surface (preload → main)

See `electron-preload.js` for the full list. Grouped:

**Settings**
- `api.getSettings()` / `api.saveSettings(s)` / `api.resetSettings()` (clears download + library folders, keeps TIDAL sign-in)
- `api.pickFolder()` — native folder picker
- `api.openFolder(p)` — `shell.openPath` for local paths
- `api.openExternal(url)` — `shell.openExternal`, https-only

**Auth**
- `api.tokenExists()` / `api.runAuth()` — TIDAL device-code flow (in-process)
- `api.onAuthOutput(cb)` — status lines streamed into the auth modal terminal
- `api.onAuthUrl(cb)` — receives the verification URL once known, used to populate the URL input + Copy button

**Resolver**
- `api.resolveInput({ input })` — URL or search query → tracks (pre-enriched with `libraryMatch`). Returns `{ ok, kind: 'url'|'search', tracks, capped }`; `capped: true` when a Spotify playlist hit the 100-track embed cap. Cancellable via `cancelResolve`
- `api.cancelResolve()` — flips a flag the in-progress resolver checks at iteration boundaries; backed by `resolverCancelled` in `electron-main.js`
- `api.resolveTracklist({ tracks })` — `[{title, artist}]` from a parsed CSV/text import → matched TIDAL tracks. Emits `tracklist:progress` events during the resolve so the loading overlay can show `Matching N / M tracks…`
- `api.onTracklistProgress(cb)` — receives `{ done, total }` from the resolver

**Queue persistence**
- `api.getQueue()` — reads `<userData>/queue.json` and returns the array; empty on first launch
- `api.saveQueue(queue)` — writes the array. Renderer strips transient fields (`dlStatus`, `dlPercent`, `selected`) before calling. Debounced 400 ms via `saveQueueSoon()` to avoid hammering disk on every mutation

**Preview audio (experimental waveform feature)**
- `api.getPreviewAudio(tidalId)` — fetches the LOSSLESS audio bytes for a track and returns `{ ok, audioBytes: Buffer, mimeType }`. Supports both BTS (single direct URL) and DASH (parallel segment fetch + concat) manifests. Renderer decodes for peaks + creates a Blob URL for the `<audio>` element

**Download**
- `api.startBulk({ tracks, outDir })` — kicks off batch download (single-track downloads also go through here — there's no separate single-URL IPC)
- `api.cancelDownload()` — kills the active bulk_runner child; called from the renderer's Cancel button
- `api.onDownloadLine(cb)` / `api.onDownloadDone(cb)` — stdout/exit events (shared by the bulk flow)
- `api.onTrackStart(cb)` / `api.onTrackProgress(cb)` / `api.onTrackDone(cb)` — per-track lifecycle events for the queue row state machine (`bulk_runner` emits `__TRACK_START__:<id>` / `__TRACK_PROGRESS__:<id>:<pct>` / `__TRACK_DONE__:<id>:<status>` markers that electron-main parses into typed events)

**Library**
- `api.libraryStatus()` / `api.libraryRescan()` — scanner state + manual refresh
- `api.onLibraryScanned(cb)` — fires when an async scan completes with a final count
- `api.onLibraryScanProgress(cb)` — receives `{ done, total }` during scan, throttled in the scanner to one event per ~25 files

**Updater**
- `api.checkForUpdates()` — manual check, returns `{ status: 'available' | 'up-to-date' | 'error', ... }`
- `api.getAppVersion()` — `app.getVersion()`, used by topbar + Settings
- `api.onUpdateAvailable(cb)` — fires on launch (auto-check) AND on manual check when newer exists. Both the activity-log notice and the topbar `Update now` pill subscribe
- `api.canSelfInstall()` — returns `true` when packaged on Windows (NSIS installer) or macOS (DMG). Returns `false` in dev mode and on Linux, where the renderer falls back to opening the release page externally
- `api.downloadUpdate(url)` — fetches the asset to a temp file, streaming progress events back. Returns `{ ok, path }` on success or `{ ok: false, error }`
- `api.applyUpdate()` — on Windows, spawns the downloaded NSIS installer with `/S --updated`; on macOS, writes the double-fork bash relauncher and spawns it. Either way calls `app.quit()` 200 ms later. Returns immediately so the renderer can flip its button state
- `api.onUpdateDownloadProgress(cb)` — receives `{ downloaded, total }` byte counts during a self-install download. Both update UIs (activity-log button and topbar pill) listen and render `Downloading XX%`

---

## Library deduplication system (read carefully)

`tidal_lib.js` exposes:

- `scanLibrary()` → async. Recursively walks `LIBRARY_PATH`, reads both filename AND audio-tag metadata (`music-metadata` library) for each file. Each entry gets **four** normalized title forms:
  - `fnFull` — full filename, normalized (lowercase + alphanumeric)
  - `fnTitleFull` — just the title-part of an "Artist - Title" filename, normalized
  - `fnCore` — like `fnFull` but with `(remix)`/`[edit]`/`feat. X`/`- mix indicator` suffixes stripped
  - `fnTitleCore` — title-part with suffixes stripped
  - `metaTitleFull` / `metaTitleCore` — same two forms but read from the audio file's ID3/Vorbis tags
  - `metaArtist`, `metaDuration` — also from tags
- `findInLibrary(title, artist?, duration?)` → async. Returns:
  - `{ kind: 'exact', path, libraryTitle }` — same song, definitely a duplicate
  - `{ kind: 'similar', path, libraryTitle }` — same core title with a remix/edit/feat suffix difference (i.e., probably the same song in a different version)
  - `null` — no match
  
  **Match priority:**
  1. Exact metadata title match + artist sanity check
  2. Exact filename match
  3. Core metadata title match → `similar`
  4. Core filename match → `similar`

- `enrichWithLibraryStatus(tracks)` — mutates an array of track objects, adding `libraryMatch` to any that hit. Called from the resolver, so by the time tracks enter the queue, they already carry their library status.

- `rescanLibrary()` — drops the cache. Next `scanLibrary()` call re-reads everything from disk.

### Scan cache

Cached for the process lifetime in `_libraryCache`. Reset by:
- `rescanLibrary()` (user clicks Refresh in Settings)
- `setLibraryPath()` (path changed in Settings — auto-invalidates)
- App restart (lib module re-imports)

### Normalization rules (`normalizeCoreForMatch`)

Strips:
- `(...)` or `[...]` to end (if there's content before — preserves "(I Can't Get No) Satisfaction")
- `feat. X` / `ft. X` / `featuring X` to end
- ` - <mix indicator>` patterns (remix, edit, extended, radio, live, instrumental, etc.)
- Then lowercases and reduces to alphanumeric + spaces

`normalizeFullForMatch` does only the lowercase + alphanumeric step — preserves the suffix info.

### Library-status GUI flow (in the queue itself, no modal)

Each queue item carries an `included` boolean:
- For `kind: 'exact'` matches: `included = false` by default. Row is greyed out + line-through on the title + `📁 already in library` badge + a bright **"+ Add"** button. User must click "+ Add" to opt in.
- For `kind: 'similar'` matches: `included = true` by default. NOT greyed out — just a yellow `⚠ similar version in library` badge as info.
- For everything else: `included = true` by default.

Clicking "+ Add" on an exact-match item flips `included = true`; the row de-greys and the badge stays as a reminder. Clicking ✕ removes the item from the queue entirely.

**Download all** filters by `t.included === true && !t.notFound` and sends that list to `bulk_runner.js`. The button label updates to reflect the actual count (e.g., "Download (47)" when 3 of 50 are excluded). Reverts to "Download all" when nothing's excluded.

The `bulk_runner` passes `--skip-library-check` to each spawned `tidal_download.js` because the queue already vetted everything.

---

## Spotify situation (history + current state)

The journey here was painful — knowing what was tried saves the next session from repeating dead-ends.

### What we tried and abandoned

1. **Monochrome web app** (the original starting point) — relied on third-party Qobuz proxy servers that went offline. Replaced by our own scripts.
2. **Spotify Client Credentials Flow** — app-only auth via `clientId`+`clientSecret`. Spotify quietly restricted this for new dev apps in November 2024: `/v1/playlists/{id}` returns 200 with **no `tracks` field**, `/v1/playlists/{id}/tracks` returns **403 Forbidden**. Confirmed via direct testing.
3. **Spotify Authorization Code (user OAuth)** — full user sign-in via device redirect. Same restrictions apply to new apps in Development mode — `tracks` field stripped, `/tracks` endpoint 403. Confirmed even for the user's *own* playlists. This is a Spotify-side block on apps that haven't been approved for Extended Quota Mode (a slow review process). Code removed cleanly.
4. **Headless `BrowserWindow` web-player scrape** — opened `open.spotify.com/playlist/<id>` in a hidden window, attached Chrome DevTools Protocol to intercept Spotify's internal GraphQL responses, programmatically scrolled to trigger lazy-loading. Worked in principle but kept hanging on "Resolving link…" — auto-scroll wasn't reliably triggering the lazy loads (Spotify's scroll container detection is fragile across page versions). Code removed but the design notes are below in case a future session wants to take another swing.
5. **Anonymous web-player bearer token** (`/get_access_token` scraping) — returns 403 for unauthenticated callers as of mid-2024.

### Current state: public embed page (100-track cap)

`tidal_lib.js#getSpotifyPlaylist(id)` fetches `https://open.spotify.com/embed/playlist/<id>`, parses the `__NEXT_DATA__` JSON blob, and returns the playlist's tracks. Same approach for tracks and albums (`/embed/track/<id>`, `/embed/album/<id>`).

**Hard limitation**: the playlist embed caps at 100 tracks with no pagination. Track 101+ simply isn't in the response. The user has accepted this for now ("just to get the ball rolling").

**Current workaround for >100-track playlists:** the CSV/text-paste drop-zone. The user opens [Exportify](https://exportify.net) (linked directly from the drop-zone subtitle), logs into Spotify there, exports the playlist as CSV, drops the file onto our drop-zone. The resolver parses the title/artist columns and matches each on TIDAL the same way Spotify-URL resolves do (just via search rather than ISRC, since CSVs don't carry ISRCs). The drop-zone also accepts pasted text (lines of `Title - Artist`) and plain `.txt` files for any other source.

If we ever want to skip the manual Exportify step entirely, the path is "Spotify Pathfinder GraphQL with logged-in token harvest" — hidden BrowserWindow + cookies persist via `partition: 'persist:spotify'` + scrape JWT from `/get_access_token` + paginate the internal GraphQL API. Documented in updater.md's patterns section as a possible future direction. Not built yet.

### If you want to revive the headless scraper

The previous implementation lived in `electron-main.js`:

- `scrapeSpotifyPlaylist(playlistId, opts)` — created a `BrowserWindow({ partition: 'persist:spotify', show: false })`, navigated to the playlist URL
- Attached `webContents.debugger` (CDP), enabled `Network` domain
- Listened for `Network.responseReceived` events, fetched response bodies via `Network.getResponseBody`, filtered URLs containing `pathfinder` or `api-partner.spotify`
- Walked the JSON tree extracting objects with `__typename: 'Track'`, deduped by URI
- `executeJavaScript` ran a loop trying to scroll the page (tried multiple scroll-container selectors)
- IPC handler `spotify:scrape` exposed it; `lib.setWebPlaylistScraper(fn)` injected it

The git history of the repo shows the full code if you want to bring it back. Main failure mode was that the auto-scroll JS finished too fast — the scroll container wasn't actually being scrolled because the selector didn't match. Likely fix: wait for `document.readyState === 'complete'` THEN poll for the specific Spotify UI element to render before scrolling.

### Spotify→TIDAL track matching

`spotifyTrackToTidal(spTrack, tidalToken, countryCode)`:

1. If `spTrack.external_ids.isrc` exists, search TIDAL by ISRC first (perfect match). The embed doesn't expose ISRCs so this branch is rarely hit (would require API-path access).
2. Otherwise: TIDAL search by `"<title> <artist>"`, score top 10 results by:
   - Title exact match (100), startsWith (50), includes (25)
   - Artist token overlap (0-100)
   - Duration proximity (50 if <3s diff, 25 if <8s, else 0)
3. Acceptance: `titleScore === 100` OR (`titleScore >= 25 && artistScore >= 50`). Prevents "Free Your Mind" from matching unrelated tracks purely on artist overlap.

---

## TIDAL details

### Auth

OAuth device-code flow lives in `tidal_auth_node.js`, exported as `authenticate({ onLog, onVerificationUrl, suppressBrowser })`. **Runs in-process** in the Electron main when the user clicks **Sign in to TIDAL** (the IPC handler in `electron-main.js#token:run-auth` calls it directly). Status messages stream to the auth modal via the `auth:output` IPC channel; the verification URL goes to the renderer via the separate `auth:url` IPC so the modal can show it in an input field with a Copy button. `shell.openExternal()` opens the URL in the default browser.

CLI usage (`node tidal_auth_node.js`) still works for headless TIDAL sign-in — when invoked directly, it logs to stdout and runs its own platform-specific browser-open fallback (cmd/open/xdg-open). The fallback is skipped when called in-process because electron-main passes `suppressBrowser: true`.

Saved to `token.json`:

```json
[{
    "access_token": "...",
    "refresh_token": "...",
    "userID": 12345,
    "countryCode": "US",
    "expires_at": 1234567890000,
    "client_ID": "...",
    "client_secret": "..."
}]
```

`tidal_lib.js#getToken(cred)` checks `expires_at`; if expired, calls `refreshToken(cred)` which hits `/v1/oauth2/token` with `grant_type=refresh_token`.

### Hardcoded TIDAL client credentials

Embedded as base64 in `tidal_auth_node.js`. They unlock LOSSLESS and HI_RES_LOSSLESS streaming. If TIDAL ever rotates them and breaks the flow, check the original `hifi-api` Python project on GitHub (`binimum/hifi-api` or `sachinsenal0x64/hifi`) for the new ones.

### Download pipeline (`tidal_download.js`)

1. Parse input (URL or numeric ID)
2. Skip-if-exists check on destination (both `.flac` and `.m4a` extensions)
3. Library check (async; honors `--skip-library-check` flag from bulk runner)
4. Fetch `/v1/tracks/{id}` for track metadata
5. Fetch `/v1/albums/{id}` for accurate release date + copyright
6. Fetch `/v1/tracks/{id}/playbackinfopostpaywall?audioquality=HI_RES_LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`
7. Parse the manifest. MPEG-DASH manifests have `<S d="..." r="N"/>` segment-timeline entries where `r=N` means N+1 segments. Off-by-one here is a common bug — the parser handles it correctly.
8. Detect FLAC vs AAC from the manifest's `codecs="..."` attribute. If not FLAC and not `--flac-only`, log a notice and proceed as .m4a.
9. **In parallel:** download all segments (worker pool, concurrency 8, retries 3 with exponential backoff) + fetch the album cover from `resources.tidal.com`
10. Concatenate segments to a temp `.tmp.m4a` (or `.tmp.flac` for direct-URL responses)
11. Spawn FFmpeg: `-i tmpAudio -f mjpeg -i pipe:0 -map 0:a -map 1:v -disposition:v attached_pic -c:a copy -c:v copy -metadata title=...` etc. Pipe the cover buffer to stdin.
12. Run `ffmpeg -v error -i file.flac -f null -` as an integrity check (FLAC output only). Logs a warning if it fails; keeps the file.

### V2 API path (`/v2/trackManifests/`)

We attempted this earlier; it consistently 404s for individual tracks. The `getManifestV2()` function exists in `tidal_lib.js` but is **not called from anywhere** anymore. Don't waste time on it unless TIDAL changes their API again.

---

## Auto-fallback to AAC (.m4a)

`downloadTrack` checks the manifest's codec. If it doesn't contain `flac`, the script:

- Default behavior: logs `ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC)` and proceeds, naming the output `<Title>.m4a` instead of `.flac`. FFmpeg remux still embeds full metadata + cover.
- `--flac-only` flag: throws `AacOnlyError`; bulk callers collect these and report at end-of-run summary.

The integrity check (`verifyFlac`) only runs on `.flac` outputs (it's a FLAC-specific decode test).

---

## Packaging / distribution

Two artifacts:
- **Windows**: NSIS installer `robogears-downloader-setup.exe` (~90 MB). Per-user install (no admin) to `%LOCALAPPDATA%\Programs\robogears Downloader\`. Adds Start Menu + Desktop shortcuts. Listed in Add/Remove Programs. Launches automatically on install.
- **macOS arm64**: `.dmg` with a custom turntable-themed install window — drag the app icon onto the Applications shortcut. First launch needs the Privacy & Security allow-step on Ventura+.

Build config lives in the `build` field of `package.json`. Key choices baked in:

- **`win.target: nsis`** — oneClick installer (artifactName `robogears-downloader-setup.exe`)
- **`nsis: { oneClick: true, perMachine: false, runAfterFinish: true, deleteAppDataOnUninstall: false }`** — silent install, per-user, runs the app after install, preserves user data on uninstall
- **`mac.target: dmg`** — arm64 only (artifactName `robogears-downloader-mac-${arch}.${ext}`)
- **`mac.identity: null`** — skip electron-builder's signing phase. The afterPack hook ad-hoc signs the .app instead (see below).
- **`afterPack: ./build/after-pack.js`** — runs `codesign --force --deep --sign -` on the .app on darwin builds. Without ANY signature, arm64 Gatekeeper shows "damaged and can't be opened"; the ad-hoc signature satisfies the must-be-signed check.
- **`asarUnpack: node_modules/ffmpeg-static/**/*`** — FFmpeg is a real binary; if it stays in the asar, `spawn()` can't invoke it and every download breaks. ⚠ This is necessary but *not sufficient*: see "Binary paths inside asar" below.
- **`publish: null`** — disables electron-builder's auto-publish (we publish via `softprops/action-gh-release` in the workflow). Without this, a `v*` tag push would auto-trigger publishing and demand `GH_TOKEN`, failing the build.
- **`directories.output: dist/`** (gitignored)

### Build commands

```sh
npm run build:win       # Windows NSIS installer → dist/robogears-downloader-setup.exe
npm run build:mac       # macOS arm64 .dmg (only works on macOS — electron-builder refuses cross-build by default)
```

⚠ Don't add a `build:portable` script back. It would pass `--win portable` to electron-builder, which silently **overrides** the `nsis` target declared in `package.json#build.win.target` (CLI flag wins). The build would succeed but produce a portable .exe with the wrong name; CI's `upload-artifact` step would then fail. The old `build:portable` script was removed in v0.1.24's fix-up commit for exactly this reason. If you need to build a one-off portable for testing, do it directly: `npx electron-builder --win portable`.

Outputs: `Z:\robogearsDownloader\dist\robogears-downloader-setup.exe` and `dist/robogears-downloader-mac-arm64.dmg`. Mac builds are produced by CI on a `macos-latest` runner; local Windows machines can't cross-build mac without Docker + the `electronuserland/builder` image.

### userData path — consistent across dev and packaged

`electron-main.js` calls `app.setName('robogears Downloader')` early in startup, before anything that touches paths. Without this, `app.getName()` would return:
- Dev: `robogears-downloader` (from package.json `name`, hyphenated)
- Packaged: `robogears Downloader` (from build config `productName`, with space)

…and `app.getPath('userData')` would diverge between the two. With the explicit `setName`, both modes write to `%APPDATA%\Roaming\robogears Downloader\` (and `~/Library/Application Support/robogears Downloader/` on macOS).

### token.json path

The packaged binary lives in a read-only asar, so the historical `path.join(__dirname, 'token.json')` doesn't work. `electron-main.js` sets:

```js
if (app.isPackaged) {
    process.env.TIDAL_TOKEN_PATH = path.join(app.getPath('userData'), 'token.json');
}
```

`tidal_lib.js` and `tidal_auth_node.js` both honor `TIDAL_TOKEN_PATH` and fall back to `./token.json` if unset. Spawned download children inherit the env var via `childEnv()`. Dev mode uses `./token.json` next to source; packaged mode uses userData.

### Binary paths inside asar

`asarUnpack` puts ffmpeg's binary on disk at `app.asar.unpacked/node_modules/ffmpeg-static/ffmpeg(.exe)`. But `require('ffmpeg-static')` still returns the path *inside* the asar (`app.asar/node_modules/...`). Electron's `fs` is patched to read from `app.asar` transparently, so `fs.existsSync(asarPath)` returns true — but `child_process.spawn()` goes through the raw OS exec syscall, which doesn't know about asar. On Linux/macOS, the OS treats `app.asar` (a file) as a non-directory in the middle of a path and `posix_spawn` fails with `ENOTDIR`. On Windows, `CreateProcess` rejects the path too, though we hadn't been hitting it because Windows dev mode masked the issue.

**Fix (in `tidal_download.js`):**

```js
const _ffmpegStatic = require('ffmpeg-static');
const _ffmpegUnpacked = _ffmpegStatic && _ffmpegStatic.replace('app.asar', 'app.asar.unpacked');
const ffmpegPath = (_ffmpegUnpacked && fs.existsSync(_ffmpegUnpacked)) ? _ffmpegUnpacked : ...fallback...;
```

In dev mode there's no `app.asar` in the path so `.replace()` is a no-op. In packaged mode the path now points at the real on-disk copy. This is the canonical fix for any npm-packaged binary used inside an Electron app with asarUnpack.

If any future feature spawns another binary from a package (sharp, a transcoder, etc.), it MUST do the same rewrite. Add it to the asarUnpack list AND rewrite the path before spawning.

### Code signing

- **Windows**: unsigned. First launch shows the blue **"Windows protected your PC"** SmartScreen dialog. Users click **More info → Run anyway**. Normal for personal apps. A real cert is $80–300/yr.
- **macOS**: ad-hoc signed only (no Apple Developer Program). First launch needs **right-click → Open** to bypass Gatekeeper's "unidentified developer" warning. Without ad-hoc signing, Apple Silicon shows the harsher "damaged and can't be opened" — see `build/after-pack.js`.

---

## Releases (CI + version process)

Releases are automated by `.github/workflows/release.yml`. Trigger: pushing any tag matching `v*`. Three jobs:

1. **build-win** (windows-latest): `npm ci`, `npm run build:win`, upload `dist/robogears-downloader-setup.exe` as an artifact
2. **build-mac** (macos-latest): `npm ci`, `npm run build:mac`, upload `dist/robogears-downloader-mac-arm64.dmg`
3. **release** (ubuntu-latest, needs both): downloads both artifacts, uses `softprops/action-gh-release@v2` to create a **draft** release with both attached. Body comes from `RELEASE_NOTES.md` via `body_path`.

### Ship process

When the user explicitly asks to ship (and not before — see "no auto-releases" memory rule):

1. **Bump the patch version** in `package.json`. Next tag is the smallest unused `vX.Y.Z`. Never force-move an existing tag (with the narrow exception of unpublished drafts — both drafts must still be on GitHub, never publicly visible).
2. **Overwrite `RELEASE_NOTES.md`** with the new version's body. Only the current version goes in — no cumulative section list (per the "release notes format" memory rule). Must include all four parts: `# What's new in vX.Y.Z` with `##` subsections, `# Install` block, `## Requirements`, `**Full Changelog**: ...vPREV...vCURR` link.
3. `git add ...; git commit -m "vX.Y.Z: <summary>" ; git push origin main`
4. `git tag -a vX.Y.Z -m "vX.Y.Z" ; git push origin vX.Y.Z` (this is what triggers CI)
5. After CI completes, **verify the release body**: `gh release view vX.Y.Z --json body --jq '(.body | length)'`. If 0 (softprops sometimes preserves an empty body on re-runs of an existing tag), fix with `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md`.
6. Tell the user where the draft is — they review and click Publish manually.

### gh CLI

`gh` is installed at `C:\Users\william\AppData\Local\Microsoft\WinGet\Links\gh.exe` and authenticated as `robogears` with `repo` + `workflow` scopes. Use this binary directly in PowerShell calls (the WinGet Links path isn't always on PATH in fresh shells). Memory location: Windows Credential Manager keyring.

---

## In-app updater

On launch, `electron-main.js#checkForUpdatesAndNotify` fetches `https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` (unauthenticated, 60/hr rate limit). If `release.tag_name` is strictly newer than `app.getVersion()`, it picks the platform-matching asset (`setup.exe` on win32, `mac-arm64.dmg` on darwin, release page URL as fallback) and sends an `update:available` IPC event to the renderer. Errors / no-update are silent.

The renderer has **two parallel update UIs** that share the same backend IPCs:
1. **Activity-log notice** (`insertUpdateNotice` in `renderer/app.js`) — styled `🚀 New version available: vX.Y.Z` row with a Download button. Two-click flow: Download → "Restart to apply" → Restart. For users who want to review before restarting. Inserted after the boot welcome line; if the event arrives before the welcome exists, payload is queued and replayed.
2. **Topbar pulsing pill** (`#brand-update-pill`) — appears next to the version label. Single-click flow: download with live `Downloading N%` → auto-apply + restart, no second click. For impatient users. Both UIs run in independent state machines; both call the same `api.downloadUpdate(url)` / `api.applyUpdate()` IPCs.

Settings → Updates surfaces `app.getVersion()` and a manual **Check for updates** button. The button uses the same `getUpdateStatus()` helper as the launch check; result reflects in the button label (*Checking…* → *vX.Y.Z available!* / *Up to date ✓* / *Check failed*, auto-reverts after 2.5s). When an update is available via the manual check, both the activity-log notice and the topbar pill fire.

Note: GitHub's `/releases/latest` endpoint only returns the highest **published** release. Drafts and pre-releases are invisible to it. So users on the latest published version won't see notices for unpublished drafts — only for releases the user has actually clicked Publish on.

### Self-installer

**Windows (NSIS, as of v0.1.24):** the downloaded asset is `robogears-downloader-setup.exe` — an NSIS installer. `apply:update` spawns it with `/S --updated` (silent install + "this is an auto-update" hint), then `app.quit()` 200 ms later. NSIS detects the running app via its semaphore, closes it, replaces files in `%LOCALAPPDATA%\Programs\robogears Downloader\`, and relaunches the new version (via `runAfterFinish: true` in `package.json#build.nsis`). Much simpler than the old portable-era `.cmd` polling-retry swap — NSIS handles all the file-lock / process-detection / atomic-replace concerns internally.

```js
// electron-main.js, update:apply Windows branch
const child = spawn(newPath, ['/S', '--updated'], {
    detached: true, stdio: 'ignore', windowsHide: true,
});
child.unref();
setTimeout(() => app.quit(), 200);
```

**macOS:** download the `.dmg`, mount via `hdiutil attach -nobrowse -mountpoint <tmp>`, find the `.app` inside, copy it out via `ditto <src>.app <staging>` (preserves extended attributes that plain `cp` mangles), detach. A double-fork bash relauncher script (re-exec'd with `--daemonized` so it survives `app.quit()` via `nohup ... & disown`) waits for the parent PID, detects App Translocation (installs to `/Applications/` if running from a read-only shadow), backs up the existing `.app` to `.bak`, moves the new in, strips quarantine (`xattr -dr com.apple.quarantine`), re-signs ad-hoc (`codesign --force --deep --sign -`), and `open`s it. Diagnostic logs in `~/Library/Logs/robogears Downloader/`.

**Bootstrap pain when changing asset formats:** every asset-format migration leaves the version just before the change unable to auto-update (its substring match was for the old name). We've paid this cost twice — `.zip` → `.dmg` on macOS (v0.1.16 → v0.1.17), and portable `.exe` → NSIS `setup.exe` on Windows (v0.1.23 → v0.1.24). Documented in each release's notes as a one-time manual install. See `updater.md` for the three strategies (manual / dual-ship / pre-patch).

**Why not electron-updater:** electron-updater wants a `latest.yml` manifest, publishes via its own flow, and on macOS requires a Developer ID + notarized binary so Gatekeeper trusts the relaunched .app. The custom approach above works without paying $99/yr for Apple Developer.

---

## Settings UI (tabs, as of v0.1.20)

The Settings modal is split into three tabs in `renderer/index.html` (`.modal-tab` + `.modal-pane` pattern; switching handled in `renderer/app.js` near the end). Each tab fills the modal body; the tab bar lives at the top.

**Folders tab**
1. **Download folder** — `folder-input` + `Browse…` + `Open` (the Open button calls `api.openFolder(settings.downloadFolder)`). Blank on first launch — `Download all` errors out with "Pick a download folder in Settings first" until set
2. **Music library folder** — `library-input` + `Browse…` + `Open` + `Clear`. Below that: scan status (`library-status`) with live `Scanning N / M…` progress + Refresh button
3. **Reset config** — text button at bottom of pane. Clears download + library folders only; keeps TIDAL sign-in

**TIDAL tab**
- Auth status + `Sign in to TIDAL` (or `Re-authenticate` if already signed in). The button opens the auth modal which runs `tidal_auth_node.authenticate()` in-process

**Updates tab**
- Current version label (`update-status`)
- `Check for updates` button — runs `getUpdateStatus()`, reflects result in its own label briefly
- `made with love by robogears :)` signature — anchored to bottom-left via `margin: auto 0 -8px 0` on a flex-column pane

The auth modal (separate from settings, opened by the Sign-in button) has a URL row showing the verification URL with a Copy button, plus the live terminal output of the auth flow.

---

## Sound effects

`renderer/app.js` has a cached `getAudioCtx()` helper (creates AudioContext on first use, reused after, resumes if suspended). All sounds use Web Audio — no asset files shipped.

| Function | Trigger | Sound |
|---|---|---|
| `playDownloadChime` | "Download all" click, after all validation passes | Ascending C5 → G5 (sine pair, slight detune for warmth) |
| `playSuccessPing` | Batch finishes cleanly (`onDownloadDone` with code 0) | 3-bell major-triad arpeggio G5 → C6 → E6, bell-like decay (~400ms total) |
| `playFart({ pitchScale })` | Click on the brand logo, name, or version label in the topbar (easter egg) | Sawtooth + 17 Hz LFO wobble + 480 Hz lowpass + ~420ms envelope. Version-click uses `pitchScale: 7` for the "tiny fart" variant |
| `playClownHorn` | Unused — leftover from the v0.1.0–v0.1.24 "Coming soon" badge that the v0.1.25 CSV drop-zone replaced. Still defined in `app.js` in case we want to repurpose | Two-tone descending honk, 420 → 310 Hz (sawtooth + 1800 Hz lowpass) |
| `playWarningHonk` | "Download all" click when blocked (no folder / no auth / nothing downloadable) | Same shape as clown horn, lower octave (220 → 165 Hz, 1100 Hz lowpass) — a "wronnng" |

Internally these share a `_honkPair(highHz, lowHz, opts)` helper; tweak the args to add variants.

---

## Funny loading text

`renderer/app.js` defines `FUNNY_LOADING` — 10 music-themed loading messages ("Searching the seven seas for your music…", "Digging through the record crates…", etc.). `showLoading()` with no arg picks one at random and cycles to a fresh random message every 2.5s if the operation lasts longer. `showLoading(text)` with a specific string uses that instead (e.g., `Matching 234 / 500 tracks on TIDAL…` during a tracklist import resolve).

Add more entries to the `FUNNY_LOADING` array if the user requests it. They should stay short, on-theme (music/audio/discovery vibes), and not promise specific behavior.

---

## Where the last session left off

Latest released version is **v0.1.25** (published). Working tree is clean as of the last ship. Most recent additions in v0.1.25: CSV/text-paste playlist import (replaces the feature-gated OCR drop-zone), one-click "Update now" pill in the topbar next to the version label, live `Matching N / M tracks` progress on the loading overlay during tracklist resolve, and CSP tightened (Tesseract.js CDN script removed).

The Windows distribution flipped to **NSIS oneClick installer** in v0.1.24 — installs to `%LOCALAPPDATA%\Programs\robogears Downloader\`, adds Start Menu + Desktop shortcuts, registers in Add/Remove Programs. Auto-update flow simplified: just spawn the installer with `/S --updated` and let NSIS handle process detection + file replace + relaunch. Replaces the portable-era `.cmd` polling-retry pattern entirely. Bootstrap pain: anyone still on v0.1.23 portable needs a one-time manual install of `robogears-downloader-setup.exe`. Documented in v0.1.24 release notes.

Library matcher tightened in v0.1.24 — `exact` matches now require BOTH title and artist to confidently agree. Files with empty/missing artist ID3 metadata (common in SpotDownloader-style MP3 dumps) used to false-positive based on title alone and get auto-skipped. Now they show the yellow `⚠ similar version in library` badge with the file path, and stay in the queue by default.

### Just landed (latest first)

**v0.1.25 — CSV/text playlist import + topbar update pill + import progress:**
- Drop-zone repurposed from the (feature-gated-off) OCR placeholder into a CSV/text-paste importer. Accepts Exportify CSVs out of the box (detects `Track Name` / `title` / `name` and `artist` columns), plain `.txt` files, and clipboard paste anywhere in the app. Plain-text fallback handles `-`, `—`, `–`, `|`, tab separators.
- Drop-zone has a clickable `Exportify` link in the subtitle — opens [exportify.net](https://exportify.net) in the user's browser for the one-click handoff. Killed the Tesseract.js CDN script (was loading 67 KB on every launch even with OCR off); CSP no longer needs `cdn.jsdelivr.net` exceptions.
- New topbar pulsing pill `Update now` next to the version label. Single-click: download → auto-apply → restart, no second click. Activity-log notice (two-click Download then Restart) stays alongside for users who prefer to review.
- Loading overlay during tracklist resolve now ticks: `Matching 234 / 500 tracks on TIDAL…` instead of a generic spinner. Backed by `tracklist:progress` IPC events from `resolve:tracklist`.
- IPC rename `resolve:ocr-tracks` → `resolve:tracklist`. Track source field `'ocr'` → `'import'`. Queue badge shows `Import` instead of `OCR`.

**v0.1.24 — Windows NSIS installer + stricter library dedup:**
- Windows distribution switched from portable single-`.exe` to NSIS oneClick installer. `robogears-downloader-setup.exe` installs to `%LOCALAPPDATA%\Programs\robogears Downloader\` per-user, adds Start Menu + Desktop shortcuts, registers in Add/Remove Programs. Auto-update spawns the installer with `/S --updated` — NSIS handles process kill + file replace + relaunch. Replaces the `.cmd` polling-retry swap that the portable target needed.
- Bootstrap pain for v0.1.23 portable users: their updater code finds `setup.exe` (since `.exe` substring matches), but their swap mechanism doesn't know what to do with an installer. One-time manual install of the setup.exe.
- Library matcher (`tidal_lib.js#findInLibrary`) tightened: `exact` now requires title AND artist to confidently agree. Title-only matches (where the library file has empty/missing artist metadata) demote to `similar` so the file shows the yellow warning badge but stays in the queue.
- CI workflow gotcha discovered: `npm run build:portable` was passing `--win portable` to electron-builder, which silently overrode `package.json#build.win.target`. Fix: dropped that script entirely, workflow now calls `npm run build:win` which uses whatever's in the config.

**v0.1.23 — restore full-screen loading overlay + README refresh:**
- Brought back the v0.1.19-and-earlier full-screen blur overlay for URL resolution. The v0.1.20 topbar pill experiment read as too understated.
- README rewritten: pre-built binary install instructions first (Windows + macOS), OCR dropped from the feature list (was being advertised even though it was feature-gated off), in-app updater + waveform preview + volume slider added, stale ONBOARDING.md link removed. Links out to `waveformplayback.md` and `updater.md` for the portable docs.

**v0.1.22 — queue title takes priority over waveform width:**
- Song titles in the queue now always render in full; the waveform shrinks (down to 0 if needed) when row width is tight. `flex: 0 0 auto` on the title (with `overflow: visible` overriding the default ellipsis) and `min-width: 0` on the waveform (down from 80px).

**v0.1.21 — preview polish (volume slider, scrub-any-waveform, pre-load, ping):**
- Volume slider in the queue header — squared curve (slider 50% → audio 25%), persists to `settings.volume`, defaults 50%.
- Clicking any waveform (not just the playing one) starts that track at the clicked position. Hold-to-scrub stays scoped to the currently-playing track.
- Background pre-loader fires when tracks land in the queue or are restored — concurrency 2, peaks-only (audio bytes discarded after decode). By the time you click play, the waveform is already painted.
- Three-bell major-triad arpeggio "success ping" on batch completion (G5 → C6 → E6 with bell-like decay).
- Cache split into `peaksCache` (unlimited, ~800 bytes per entry) and `audioCache` (LRU 3) so pre-loaded entries don't pin audio bytes in memory.
- Fixed "Preview playback failed (code 4)" log noise on rapid track switches — was a stale `error` event from a torn-down `<audio>` element. All audio listeners now guard against firing on a no-longer-current element via `isCurrent()`.
- Easter eggs: click the topbar logo/name for a fart noise (sawtooth + 17 Hz LFO wobble + 480 Hz lowpass), click the version number for the same fart at 7× pitch (mouse-fart edition). "made with love by robogears :)" anchored to bottom-left of Settings → Updates.

**v0.1.20 — experimental inline waveform preview + topbar loading:**
- Each queue row gets a circular play button + dynamic waveform filling the space between the title and the action buttons. Click-and-hold to scrub the playing track; audio keeps playing through the drag for the "skim" effect. Spotlight hover (bars near cursor swell, vertical cursor line). Works on both DASH (parallel segment fetch + concat) and BTS (single direct URL) manifests.
- Implementation: Web Audio `decodeAudioData` extracts peaks via downsample-by-max, blob URL feeds `<audio>` element for playback. 200 bars, peaks normalized to [0..1]. Documented end-to-end in `waveformplayback.md` for portability.
- Loading indicator was briefly moved to a topbar pill in this version (replaced the full-screen overlay). Reverted in v0.1.23 — the overlay reads better.
- Play/pause/loading icons swapped from unicode to inline SVG so they center precisely in the button.

**v0.1.17–v0.1.19 — DMG-only macOS distribution + validation bumps:**
- v0.1.17 dropped the `.zip` from `mac.target`. Updater fetches `.dmg`, mounts via `hdiutil`, extracts via `ditto`. Bootstrap pain: v0.1.16 portable-zip-era macOS users need a one-time manual `.dmg` install.
- v0.1.17 also fixed the Rekordbox cover-art bug: FLAC PICTURE block was being written with picture type 0 (`Other`) which strict DJ players silently skip. Now `-metadata:s:v comment="Cover (front)"` sets it to type 3, which Rekordbox/Mixxx/Serato actually render. Existing files on disk need a one-time re-tag (FFmpeg `-c copy` rewrite).
- v0.1.17 also bundled the queue-persistence-across-restarts + Settings tabs + Hi-Res badge in queue + Spotify-100-cap warning + library scan progress + FFmpeg startup check + activity-log cap quality-of-life batch.
- v0.1.18 and v0.1.19 were back-to-back validation bumps with no code changes — shipped to test the v0.1.16 → v0.1.17+ DMG auto-update path end-to-end now that the format-transition bootstrap was paid.

**v0.1.16 — DMG install-window polish:**
- DMG background canvas extended from 540×400 to 1920×1200 so resizing the Finder window no longer reveals the default white area beyond the original image.
- Tonearm in the install-window backdrop moved from a diagonal sweep across the platter to a vertical at-rest position to the right of the platter rings — doesn't overlap the groove rings.
- Footer reworded from "First launch: right-click → Open" to bold-white **DON'T FORGET to allow the app in System Settings → Privacy & Security** because newer macOS routes Gatekeeper-blocked apps through System Settings instead of the right-click bypass.
- Pure art-only release. No code changes.

**v0.1.15 — DMG installer + App Translocation fix:**
- `mac.target` adds `dmg` alongside `zip`. New `build.dmg` config with a custom turntable-themed background image (`build/dmg-background.{svg,png}`): app icon as a record on the left, `/Applications` shortcut as a turntable platter on the right, tonearm between them. Subtitle "Drop the needle — drag the record onto the platter."
- `update:apply` on macOS now detects when `app.getPath('exe')` points inside `/AppTranslocation/` (Gatekeeper Path Randomization for a quarantined `.app` launched outside `/Applications/`) and installs to `/Applications/<App>.app` instead of trying to swap the read-only translocated copy in place. Relauncher bash script unified around a `TARGET` variable that can differ from where the running app is loaded from.
- First version where the macOS update path actually works for users who haven't yet installed the app to `/Applications/` via the DMG.

**v0.1.13 / v0.1.14 — macOS update relauncher diagnostics + validation bump:**
- v0.1.13: rewrote the bash relauncher to **double-fork daemonize** itself (`nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 & disown`). Stage 1 backgrounds immediately and exits; stage 2 with `--daemonized` does the actual work with `trap "" HUP TERM`. Survives the parent Electron process's death.
- v0.1.13: moved the script log from `os.tmpdir()` (which is `/var/folders/<random>/T/` on macOS — basically un-findable) to **`~/Library/Logs/robogears Downloader/`** with two files: `attempts.log` (appended *before* spawn, so we can prove the IPC fired even if the script never ran) and `update-<ts>.log` (verbose `set -x` trace if it did run).
- v0.1.14: validation bump only, no code changes. Existed so v0.1.13 had something newer to update to and we could exercise the diagnostic trail. The user's log file from this attempt is what surfaced the App Translocation bug.

**v0.1.12 — first macOS self-install hardening attempt:**
- Wrapped the macOS relauncher spawn in `nohup` and bumped the parent-exit delay 200ms → 500ms. Wasn't enough on its own — the script still got reaped before running. v0.1.13's diagnostic logging + v0.1.15's translocation fix were what actually closed it.
- Also added `start_app.command` (the macOS analog of `start_app.bat`) and a `.gitattributes` rule pinning shell scripts to LF endings.

**v0.1.11 — Cancel + Retry-all/selected + topbar logo:**
- New red **Cancel** button next to "Clear all", visible only during a batch. Click plays `playCancelChime` (G5 → C5 — mirror of the existing download chime) and fires `api.cancelDownload`. In-flight + queued tracks flip to `failed` so they get retry buttons.
- Queue header shows `↻ Retry all (N)` when 2+ failed; multi-select checkboxes appear on failed rows; the button switches to `↻ Retry selected (M)` if any checkbox is ticked. Selections clear when the retry batch fires.
- Topbar `.logo-dot` replaced with an inline-SVG mini-version of the app icon (vinyl + download arrow, 22 px, no outer rounded square since it'd blend with the black topbar).

**v0.1.10 — macOS self-install + per-track progress + retry:**
- First version with `canSelfInstall()` returning true on macOS. Relauncher writes a detached bash script that waits for the parent PID, strips quarantine, mv-swaps the .app, re-signs ad-hoc, and `open`s the result. (Spawn-survival issues were addressed iteratively in v0.1.12-v0.1.15.)
- Bulk-runner now emits `__TRACK_START__:<id>` and `__TRACK_DONE__:<id>:<status>` markers around each track. `tidal_download.js` emits `__TRACK_PROGRESS__:<id>:<pct>` (gated by `BULK_RUNNER_PROGRESS=1` env, throttled to one emission per integer-percent change). electron-main parses markers into typed `bulk:track-*` IPC events. Renderer attaches per-row state (`dlStatus`, `dlPercent`) and renders a thin progress bar under each downloading track plus an overall `N / M` batch progress bar above the queue. Per-row `↻ Retry` button appears on failures.
- `downloadDirect` rewritten as a streaming HTTP download (no longer buffers the whole file in memory) so BTS-manifest direct downloads also tick progress.

**v0.1.9 — FLAC detection fix + custom app icon:**
- FLAC vs `.m4a` detection now prefers `raw.audioQuality === 'LOSSLESS' | 'HI_RES_LOSSLESS' | 'HI_RES'` as the primary signal (it's TIDAL's own tier label, more authoritative than the manifest's codec string — which the newer BTS manifests sometimes report differently). Case-insensitive codec/regex fallbacks still apply.
- Custom monochrome app icon: black rounded square, white vinyl with subtle grooves, prominent white download arrow on the label. `build/icon.svg` is the source (1024×1024 PNG export at `build/icon.png` is what electron-builder picks up). Both `win.icon` and `mac.icon` point at it.

**v0.1.8 — TIDAL BTS manifest:**
- Accepts the newer `application/vnd.tidal.bts` manifest variant (was `application/vnd.tidal.bt`). Same JSON shape inside (single direct URL). Match changed from exact-string to `startsWith('application/vnd.tidal.')` so future variants don't break us.
- Bundled with the CLAUDE.md refresh.

**v0.1.7 — self-installing updater + ffmpeg path fix:**
- **Self-installer on Windows portable.** Update notice in the activity log now has a multi-state button: `Download update` → `Downloading XX%` (live progress) → `Restart to apply` (white-filled style) → `Restarting…`. Main process downloads the new .exe to temp, then on apply writes a detached `.cmd` script that polls until the launcher file unlocks, swaps the .exe, relaunches it, and self-deletes. See "Self-installer" subsection under In-app updater.
- **ffmpeg-static path rewrite** for `app.asar` → `app.asar.unpacked`. In packaged builds, `require('ffmpeg-static')` returns a path inside the asar archive — but `spawn()` goes through the raw OS exec, which doesn't honor Electron's asar fs patches. On macOS this surfaced as `Error: spawn ... ENOTDIR` because `posix_spawn` saw `app.asar` as a file and refused to traverse into it. Standard canonical fix. Was the second of two Mac-specific bugs blocking downloads end-to-end.
- New IPC: `update:can-self-install`, `update:download`, `update:apply`, plus `update:download-progress` event for streaming bytes.
- New preload bindings: `canSelfInstall`, `downloadUpdate`, `applyUpdate`, `onUpdateDownloadProgress`.
- macOS / dev / non-portable falls back to the previous `shell.openExternal(downloadUrl)` path.

**v0.1.6 — macOS download spawn ENOENT fix:**
- Removed `cwd: __dirname` from both download spawns in `electron-main.js` and from the nested `tidal_download.js` spawn in `bulk_runner.js`. In packaged builds `__dirname` is an asar virtual path; `posix_spawn`/`CreateProcess` can't `chdir()` into it before `exec`. Default cwd (inherited from parent) is fine — none of the child scripts use cwd-relative paths.
- Same class of bug as the auth ENOENT we fixed in v0.1.4. The user reported "download doesn't work on Mac" — this was the first half of the cause (v0.1.7 fixed the second half).
- Also refreshed `CLAUDE.md` end-to-end (this doc) with everything that had landed since v0.1.0.

**v0.1.5 — Copy URL button, manual update check, topbar version:**
- TIDAL sign-in modal now surfaces the verification URL in a read-only input with a **Copy** button. Main process sends `auth:url` IPC alongside `shell.openExternal` so the renderer can populate the field as soon as the URL is known. Clipboard write uses `navigator.clipboard.writeText` with `execCommand` fallback; button shows "Copied ✓" for 1.5s.
- New **Updates** section in Settings. Reuses the GitHub-releases check from on-launch, refactored into `getUpdateStatus()` returning `{ status: 'available' | 'up-to-date' | 'error', ... }`. New `update:check` + `app:version` IPCs feed a manual-check button that reflects state in its own label.
- Current version now appears next to the brand name in the topbar (11px, bold, muted color). Populated on boot via `api.getAppVersion`.

**v0.1.4 — in-process auth (spawn ENOENT fix):**
- Refactored `tidal_auth_node.js` to export `authenticate({onLog, onVerificationUrl, suppressBrowser})`. CLI mode (`require.main === module`) preserved.
- `electron-main.js#token:run-auth` now calls `authenticate()` directly in-process instead of spawning a child. Removed the old `__OPEN_BROWSER__:` stdout marker, line buffering, and `ELECTRON_RUN_AS_NODE` child spawn. `shell.openExternal()` opens the verification URL.
- Root cause was the same `cwd: __dirname` in `spawn()` — asar virtual path → ENOENT in packaged builds.

**v0.1.3 (consolidated) — TIDAL browser-open + in-app updater:**
- On launch, fetches `api.github.com/.../releases/latest`, compares with `app.getVersion()`, sends `update:available` IPC if newer. Renderer inserts a styled `🚀` notice with a Download button right after the welcome line. Failures silent.
- Cross-platform browser-open for the TIDAL OAuth URL via `shell.openExternal()` (was originally a stdout marker + main-process parse, now superseded by the in-process refactor in v0.1.4).
- Originally shipped as separate v0.1.3 (browser fix) and v0.1.4 (updater) tags, then consolidated when the user discarded both unpublished drafts.

**v0.1.2 — macOS ad-hoc signing:**
- `build/after-pack.js` runs `codesign --force --deep --sign -` on the .app on darwin builds (afterPack hook in `package.json#build`). Without any signature, arm64 Gatekeeper shows "damaged and can't be opened" rather than the standard unsigned warning. Ad-hoc sig is enough to flip it into the standard right-click→Open dance.
- Un-ignored `build/` directory (was being treated as build output; it's actually build inputs — icons, afterPack hooks). Output goes to `dist/`.

**v0.1.1 — CI publish fix:**
- Added `publish: null` to `package.json#build`. electron-builder was auto-publishing on tag push and demanding `GH_TOKEN`, failing the mac build. Now we publish only via `softprops/action-gh-release` in the workflow.

**v0.1.0 (initial release) — many things:**
- Blank-on-first-launch for both folders, library scan gated on a configured path, `app.setName('robogears Downloader')` for consistent userData paths in dev + packaged
- **Reset config** button in Settings (forgets folders, keeps TIDAL token)
- Drop-zone greyed with **Coming soon** badge — `OCR_FEATURE_ENABLED = false` in `renderer/app.js` for the entire OCR flow
- Three Web Audio SFX (clown horn / download chime / warning honk) — see Sound effects section
- Batch summary distinguishes downloaded / skipped / failed / not-found via exit code 2 from `tidal_download.js` on skip
- Skip messages clarify "in downloads folder" vs "in music library"
- GitHub Actions workflow (`release.yml`) and `RELEASE_NOTES.md` with `body_path` integration
- Packaged as a single portable Windows .exe via electron-builder

### Known things still rough

1. **Spotify playlists > 100 tracks** — the public embed is hard-capped. Current workaround: the CSV/text-paste drop-zone + Exportify (one-click link from the drop-zone). Fully-automated path would be the Pathfinder GraphQL approach (hidden BrowserWindow → token harvest → paginate). Not built.
2. **Library scan takes ~18 sec for ~500 files** on first launch. No on-disk cache yet. Live "Scanning N / M…" progress was added in v0.1.20 so the user knows it's not stuck, but a faster scan would still be nicer.
3. **macOS x64 not built.** Only arm64 (Apple Silicon). Intel Mac users would need a separate target. Mostly fine in 2026.
4. **softprops empty-body on every release**: `softprops/action-gh-release@v2` produces a release with `body: ""` despite `body_path: RELEASE_NOTES.md` being set. Treat as guaranteed, fix unconditionally post-CI with `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md`. Documented as a baked-in step. Hits every single release.
5. **Node 20 deprecation in CI.** GitHub deprecates Node 20 on June 2, 2026; removed Sept 16, 2026. We use `actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `softprops/action-gh-release@v2` — all currently Node-20-based. Bump before June.
6. **`ffmpeg-static` postinstall download is a network-flake risk in CI.** `npm ci` on the Windows runner sometimes hits a 502 from GitHub's release-asset CDN trying to download the bundled FFmpeg binary. Workaround: `gh run rerun <id> --failed` — transient. Could be mitigated by pre-bundling the binary or caching `node_modules` more aggressively.

### Possible next steps (in rough priority order)

1. **Disk-cached library scan** — JSON file keyed by file mtime/size at `<userData>/library-cache.json`; rebuild only when stale. Cuts the 18s cold-start scan to <100ms.
2. **Spotify Pathfinder GraphQL with logged-in token harvest** — hidden BrowserWindow + cookies persist via `partition: 'persist:spotify'` + scrape JWT from `/get_access_token` + paginate the internal GraphQL API. Removes the >100-track Exportify-detour for users willing to log in. Documented in `updater.md`'s patterns section.
3. **History / "recent downloads" pane.**
4. **macOS x64 / universal build** — add `{ arch: ['x64', 'arm64'] }` (or `universal`) to the mac target once there's a use case.
5. **macOS self-install via electron-updater** — would require Apple Developer Program ($99/yr) + notarization, which would also unlock block-level differential updates. The current `hdiutil`-mount + bash-relauncher works fine without it.
6. **Bump GitHub Actions to Node-24-compatible versions** before June 2026.
7. **Investigate the softprops empty-body root cause** — maybe a `body_path` quoting issue, maybe softprops needs an explicit flag, maybe we need a workflow step that calls `gh release edit` as belt-and-suspenders. Currently fixed manually post-CI on every ship.
8. **Add screenshots to `docs/` and reference in README.**

### Done since the last big CLAUDE.md refresh (so we don't accidentally re-do)

- ✓ Per-track progress in queue UI (v0.1.10)
- ✓ Cancel button for in-flight downloads (v0.1.11)
- ✓ App icon — custom monochrome vinyl + download arrow (v0.1.9)
- ✓ macOS self-install via DMG + bash relauncher (v0.1.10–v0.1.15) — works without Apple Developer cost
- ✓ Persist queue across restarts (v0.1.20)
- ✓ Inline waveform preview with hold-to-scrub (v0.1.20)
- ✓ Volume slider for previews (v0.1.21)
- ✓ Pre-load waveforms in background (v0.1.21)
- ✓ Settings tabs (v0.1.20)
- ✓ Live library scan progress (v0.1.20)
- ✓ FFmpeg startup verification (v0.1.20)
- ✓ Activity log cap (v0.1.20)
- ✓ Rekordbox cover-art picture-type fix (v0.1.17)
- ✓ Tightened library matcher (v0.1.24)
- ✓ Windows NSIS installer (v0.1.24) — replaced portable
- ✓ One-click topbar update pill (v0.1.25)
- ✓ CSV/text playlist import — replaces the OCR placeholder (v0.1.25)

---

## User preferences and communication style

The user is a power user comfortable with technical detail but values brevity and "no fluff." Tone preferences observed across many sessions:

- **Direct answers first, explanations second.** Don't open with "Great question!" or recap the request. Start with the answer.
- **Show, don't talk.** When you change code, briefly summarize what changed in a table. When you propose options, list them in a table with trade-offs.
- **Diagnose precisely.** When something breaks, write a tiny script that reproduces the issue and shows the actual data (like the throwaway `debug_user_token.js` we used for Spotify). Then fix from evidence, not guesses.
- **No emojis in code or filenames** unless explicitly requested. Emoji *characters* in log output (✓, ✗, ⚠, 📁, 🎵) are fine and already used throughout for status.
- **Always restart Electron after changes** to renderer/main code (HMR is not wired up). The pattern: `Get-Process electron | Stop-Process -Force; cd Z:\robogearsDownloader; npm start`. The user will *see* the restart and doesn't need it announced — just do it and verify the app comes up.
- **Library is read-only.** Never propose writing to `Z:\Dropbox\Music` or wherever the library path is set.
- **The user signs off sessions warmly** ("great job", "amazing", etc.). Don't make a big deal out of compliments — a brief thanks + recap of what landed is the right tone.
- **Never auto-release.** Make code changes only; don't bump version, edit `RELEASE_NOTES.md`, commit, push, or tag without an explicit ship instruction ("ship it", "push it", "release", "tag X.Y.Z"). See the `feedback-no-auto-releases` memory entry.
- **Release notes are current-version-only.** When you do ship, overwrite `RELEASE_NOTES.md` with the new version's body alone — don't keep old sections below. See the `feedback-release-notes-format` memory entry.

---

## Sanity-check commands (run after any major change)

Lib loads cleanly:

```
cd Z:\robogearsDownloader
node -e "const lib = require('./tidal_lib'); console.log('OK. exports:', Object.keys(lib).length, 'symbols');"
```

Library scan + matcher (use a title you know is in the user's library):

```
node -e "(async () => { const lib = require('./tidal_lib'); const t0 = Date.now(); const r = await lib.scanLibrary(); console.log('Scanned', r.entries.length, 'files in', Date.now()-t0, 'ms'); console.log('Stronger ->', JSON.stringify(await lib.findInLibrary('Stronger'))); console.log('Stronger (Remix) ->', JSON.stringify(await lib.findInLibrary('Stronger (Remix)'))); console.log('FakeFakeFake ->', JSON.stringify(await lib.findInLibrary('FakeFakeFake'))); })()"
```

TIDAL auth state:

```
Test-Path Z:\robogearsDownloader\token.json
```

App launches and binds Electron window:

```
cd Z:\robogearsDownloader; npm start
```

`git` status (no secrets staged):

```
cd Z:\robogearsDownloader; git status; git check-ignore -v token.json
```

`gh` is reachable + authenticated (for release ops):

```powershell
$gh = "C:\Users\william\AppData\Local\Microsoft\WinGet\Links\gh.exe"; & $gh auth status; & $gh release list --limit 5
```

---

## Common diagnostic patterns

- **`Error: spawn <path> ENOENT` in a packaged build** — the spawn is using `cwd: __dirname`, which in a packaged build is an asar virtual filesystem path the kernel can't `chdir()` into. Remove the cwd (default-inherited cwd is real) or set it to `path.dirname(app.getPath('exe'))`. We've hit this for auth (fixed by going in-process in v0.1.4) and downloads (fixed by dropping cwd in v0.1.6).
- **`Error: spawn <binary> ENOTDIR` in a packaged build** — the binary path points *inside* `app.asar`. Electron's fs patches make `existsSync` return true, but `spawn`/`exec` go through the raw OS syscall which sees the asar archive as a file and refuses to traverse into it. Fix: rewrite the path with `.replace('app.asar', 'app.asar.unpacked')`. Only works if the binary's package is in `asarUnpack`. We hit this with `ffmpeg-static` in v0.1.7 — only manifested on macOS but the Windows path was bugged the same way.
- **"Cannot read properties of undefined (reading 'X')"** — usually a Spotify/TIDAL API response had an unexpected shape. Check for defensive `?.` and `|| []` guards.
- **"Resolving link…" stuck forever** — resolver threw and the error didn't propagate. Add try/catch around the resolver call in `electron-main.js#resolve:input`.
- **"0 tracks from link"** — resolver returned an empty array. Spotify playlists >100 tracks hit the embed limit. For TIDAL: playlist UUID typo or region-locked.
- **FLAC integrity warning after a successful save** — segment came down corrupt. File is kept and warning logged but not fatal. Re-run with `--force`.
- **"AAC-only on TIDAL"** — no lossless master. Default saves as `.m4a` anyway; `--flac-only` makes it a hard skip.
- **Library re-scan takes forever** — `music-metadata` per-file parsing is the bottleneck. Disk-cache it (next-steps item).
- **macOS .app shows "damaged and can't be opened"** — the build skipped ad-hoc signing (or the signature got stripped). Check `build/after-pack.js` is wired up and `mac.identity: null` is set so electron-builder doesn't try to sign with a missing real cert. Workaround for users: `xattr -cr "/Applications/robogears Downloader.app"`.
- **GitHub release body is empty after a workflow run** — softprops sometimes preserves an empty body when updating an existing release (e.g., re-tag scenarios). Fix: `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md`. Always verify with `gh release view vX.Y.Z --json body --jq '(.body | length)'`.
- **CI build fails with "GH_TOKEN is not set"** — `publish: null` is missing from `package.json#build`. electron-builder is auto-publishing on tag push and demanding a token. We use `softprops/action-gh-release` instead.

---

## Don'ts

- Don't reintroduce the Spotify Client Credentials Flow. It does not work for new dev apps.
- Don't reintroduce the OAuth user-context flow for Spotify. Same restriction.
- Don't add Spotify `clientId`/`clientSecret` settings UI back. They're not needed.
- Don't subfolder album/playlist downloads. User explicitly does not want that.
- Don't write to the user's music library folder. Read-only.
- Don't fetch cover art to a temp file. Buffer piped to FFmpeg stdin.
- Don't bypass `findInLibrary` without an explicit user opt-in (`--force` or "+ Add" click).
- Don't strip `--skip-library-check` from `bulk_runner.js` — queue is the source of truth.
- Don't bring back the `#similar-modal`. The user reviews matches in the queue inline.
- Don't commit `token.json`, `node_modules/`, `dist/`, or anything in `.gitignore`. `build/` is for inputs (icons, hooks) and IS committed — don't gitignore it.
- Don't replace `process.env.TIDAL_TOKEN_PATH || path.join(__dirname, 'token.json')` with just the source-relative path. The env var is what makes packaged builds work.
- Don't remove `asarUnpack: ['node_modules/ffmpeg-static/**/*']` from `package.json`. FFmpeg is a real binary; in the asar, `spawn()` can't invoke it.
- Don't remove `publish: null` from `package.json#build`. Without it, tag pushes auto-trigger electron-builder's publisher and fail demanding `GH_TOKEN`.
- Don't remove the afterPack hook (`build/after-pack.js`). Without ad-hoc signing on macOS arm64, Gatekeeper blocks the .app as "damaged".
- Don't reintroduce `cwd: __dirname` in any `spawn()` or `child_process.exec()` call. In packaged builds it resolves to an asar virtual path; the OS can't `chdir()` into it; `posix_spawn`/`CreateProcess` fails with ENOENT before exec. Default (inherited) cwd is fine.
- Don't spawn a binary using a path returned by an npm package without rewriting `app.asar` → `app.asar.unpacked`. ffmpeg-static is the obvious one — `tidal_download.js` does this rewrite — but the same rule applies to any future binary dependency (sharp, ytdl-binaries, etc.). Add it to the asarUnpack list AND rewrite the path string before passing to spawn.
- Don't change the Windows updater to do anything other than spawning the downloaded NSIS installer with `/S --updated`. The installer handles process detection, file replacement, and relaunch internally — much simpler than the portable-era `.cmd` polling-retry loop. Don't add manual file-swap logic. The old `.cmd` script approach is gone; don't bring it back.
- Don't pass `--win <target>` flags in `npm` scripts that go through CI. CLI flags silently override `package.json#build.win.target` — the `nsis` declaration gets ignored, electron-builder produces a portable .exe with the wrong name, and `upload-artifact` fails. Use plain `electron-builder --win` so the config wins. v0.1.24's first CI run failed for exactly this reason.
- Don't reintroduce the `build:portable` npm script. If you need a one-off portable build for testing, run `npx electron-builder --win portable` directly so it can't get picked up by the workflow by accident.
- Don't change the macOS bash relauncher's double-fork pattern (`nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 & disown`). It's what makes the script survive `app.quit()`. Plain `detached: true` + `unref()` isn't enough — SIGHUP propagation killed earlier attempts.
- Don't change `draft: true` to `false` in `.github/workflows/release.yml`. The user wants every release to land as a draft for manual review + publish.
- Don't force-move a published tag. Unpublished drafts can be re-done; published releases are immutable. Bump to a new version instead.
- Don't auto-release. See the `feedback-no-auto-releases` memory entry — make code changes only; wait for an explicit ship instruction.
- Don't accumulate old version sections in `RELEASE_NOTES.md`. The file holds the current version only; previous notes stay on the GitHub Releases page. See the `feedback-release-notes-format` memory entry.
