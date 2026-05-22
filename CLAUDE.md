# Project: robogears Downloader (read this first)

You've just inherited a personal music-downloader app. **Read this entire file before doing anything.** It contains the working architecture, all mandatory rules, full history of what was tried and abandoned, and where the last session left off.

---

## What this is

A desktop app that downloads lossless FLAC tracks from TIDAL, driven by:

- A user's TIDAL subscription (OAuth via device-code flow, runs in-process in Electron main)
- Inputs: paste a TIDAL URL, paste a Spotify URL (track / album / playlist), or type a song name to search (screenshot-OCR drop-zone exists but is currently feature-gated off via `OCR_FEATURE_ENABLED = false` in `renderer/app.js` — greyed with a "Coming soon" badge)
- A "queue" UI where the user reviews tracks before downloading
- A read-only **music library folder** that the app scans (reads ID3/Vorbis/iTunes tags via `music-metadata`) to avoid re-downloading songs the user already has
- An in-app updater that quietly checks GitHub releases on launch and surfaces a download notice in the activity log

Tech: Node.js + Electron, no framework, vanilla HTML/CSS/JS for the renderer. All audio handling done via `ffmpeg-static` (bundled FFmpeg).

**Where it lives:** `Z:\robogearsDownloader\` (also published at https://github.com/robogears/robogearsDownloader)

**Current version:** v0.1.7. Ships as a portable Windows `.exe` and a macOS arm64 `.app` zip. Both are built on GitHub Actions and attached to a draft release on every `v*` tag push. Auto-updates in-place on Windows portable; macOS users still re-download manually (waiting on code-signing/notarization to do the proper auto-update dance).

---

## Quick orientation: what works today

| Feature | State |
|---|---|
| TIDAL URL → track/album/playlist resolve + download | ✅ works |
| Spotify URL (track / album / playlist) → public embed page → match each on TIDAL → download | ✅ works (**playlists capped at 100 tracks** — Spotify's embed limit) |
| Free-text search → modal of TIDAL results → pick → add to queue | ✅ works |
| Screenshot of tracklist → OCR → match each on TIDAL → add to queue | ⚠ feature-gated OFF (greyed drop-zone with "Coming soon" badge — flip `OCR_FEATURE_ENABLED` in `renderer/app.js` to re-enable) |
| Queue UI with per-item remove, "+ Add" button on exact-library-matches, "Download all" | ✅ works |
| Library deduplication via metadata + filename (exact vs similar) | ✅ works |
| Settings: download/library folders (blank on first launch), library refresh, Reset config, Updates section | ✅ works |
| In-app updater (checks GitHub releases on launch + manual button in Settings) | ✅ works |
| Self-installing updater on Windows portable: Download update → Restart to apply (no manual file replacement) | ✅ works (Windows portable only; macOS opens browser) |
| Cross-platform CI (Windows .exe + macOS arm64 .zip) via `.github/workflows/release.yml` | ✅ works |
| TIDAL OAuth runs in-process in Electron main (no spawned auth child) | ✅ works (`tidal_auth_node.authenticate()`) |
| Auto-fallback FLAC → .m4a when no lossless master | ✅ works |
| Cover art embedded via piped FFmpeg stdin | ✅ works (no temp file) |
| Parallel segment downloads (8 concurrent) | ✅ works |
| Retry on 429/5xx with exponential backoff | ✅ works |
| Library scan reads audio tags (title, artist, duration) via `music-metadata` | ✅ works |
| Funny rotating loading text during search/resolve | ✅ works |
| Sound effects (download chime, blocked-action warning honk, "Coming soon" clown horn easter egg) | ✅ works (Web Audio, no asset shipping) |
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
- `api.resolveInput({ input })` — URL or search query → tracks (pre-enriched with `libraryMatch`)
- `api.resolveOcr({ tracks })` — OCR'd {title,artist} → matched TIDAL tracks (only used if OCR is feature-flagged back on)

**Download**
- `api.startBulk({ tracks, outDir })` — kicks off batch download
- `api.startDownload({ input, outDir })` — legacy single-URL flow
- `api.cancelDownload()` — exists but no UI calls it
- `api.onDownloadLine(cb)` / `api.onDownloadDone(cb)` — stdout/exit events

**Library**
- `api.libraryStatus()` / `api.libraryRescan()` — scanner state + manual refresh
- `api.onLibraryScanned(cb)` — fires when an async scan completes

**Updater**
- `api.checkForUpdates()` — manual check, returns `{ status: 'available' | 'up-to-date' | 'error', ... }`
- `api.getAppVersion()` — `app.getVersion()`, used by topbar + Settings
- `api.onUpdateAvailable(cb)` — fires on launch (auto-check) AND on manual check when newer exists
- `api.canSelfInstall()` — returns `true` only on Windows portable builds where we have `process.env.PORTABLE_EXECUTABLE_FILE`. macOS / dev / non-portable returns `false` and the renderer falls back to opening the release page externally.
- `api.downloadUpdate(url)` — fetches the asset to a temp file, streaming progress events back. Returns `{ ok, path }` on success or `{ ok: false, error }`.
- `api.applyUpdate()` — writes the relauncher `.cmd` script, spawns it detached, calls `app.quit()` 200 ms later. Returns immediately so the renderer can update its state.
- `api.onUpdateDownloadProgress(cb)` — receives `{ downloaded, total }` byte counts during a self-install download. Renderer uses this to render `Downloading XX%` in the button.

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

For larger playlists, the user's workaround is splitting them in Spotify or using Soundiiz/Exportify to export tracks then pasting one at a time (or via the OCR queue).

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
- **Windows**: portable `.exe` (~90 MB) — one self-contained binary, no installer
- **macOS arm64**: `.app` zip — drag to `/Applications`, right-click → Open to bypass Gatekeeper

Build config lives in the `build` field of `package.json`. Key choices baked in:

- **`win.target: portable`** — single .exe (artifactName `robogears-downloader.exe`, no version suffix per user preference)
- **`mac.target: zip`** — arm64 only for now (artifactName `robogears-downloader-mac-${arch}.${ext}`)
- **`mac.identity: null`** — skip electron-builder's signing phase. The afterPack hook ad-hoc signs the .app instead (see below).
- **`afterPack: ./build/after-pack.js`** — runs `codesign --force --deep --sign -` on the .app on darwin builds. Without ANY signature, arm64 Gatekeeper shows "damaged and can't be opened"; the ad-hoc signature satisfies the must-be-signed check.
- **`asarUnpack: node_modules/ffmpeg-static/**/*`** — FFmpeg is a real binary; if it stays in the asar, `spawn()` can't invoke it and every download breaks. ⚠ This is necessary but *not sufficient*: see "Binary paths inside asar" below.
- **`publish: null`** — disables electron-builder's auto-publish (we publish via `softprops/action-gh-release` in the workflow). Without this, a `v*` tag push would auto-trigger publishing and demand `GH_TOKEN`, failing the build.
- **`directories.output: dist/`** (gitignored)

### Build commands

```sh
npm run build:win       # Windows portable .exe
npm run build:portable  # equivalent
npm run build:mac       # macOS arm64 .zip (only works on macOS — electron-builder refuses cross-build by default)
```

Outputs: `Z:\robogearsDownloader\dist\robogears-downloader.exe` and `dist/robogears-downloader-mac-arm64.zip`. Mac builds are produced by CI on a `macos-latest` runner; local Windows machines can't cross-build mac without Docker + the `electronuserland/builder` image.

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

1. **build-win** (windows-latest): `npm ci`, `npm run build:portable`, upload `dist/robogears-downloader.exe` as an artifact
2. **build-mac** (macos-latest): `npm ci`, `npm run build:mac`, upload `dist/robogears-downloader-mac-arm64.zip`
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

On launch, `electron-main.js#checkForUpdatesAndNotify` fetches `https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` (unauthenticated, 60/hr rate limit). If `release.tag_name` is strictly newer than `app.getVersion()`, it picks the platform-matching asset (`.exe` on win32, `mac-arm64.zip` on darwin, release page URL as fallback) and sends an `update:available` IPC event to the renderer. Errors / no-update are silent.

The renderer (`renderer/app.js`) listens for this event and inserts a styled notice — `🚀 New version available: vX.Y.Z` + a **Download update** button — immediately after the boot welcome line in the activity log. If the event arrives before the welcome line exists, the payload is queued and replayed once the welcome lands.

Settings → Updates surfaces `app.getVersion()` and a manual **Check for updates** button. The button uses the same `getUpdateStatus()` helper as the launch check; result reflects in the button label (*Checking…* → *vX.Y.Z available!* / *Up to date ✓* / *Check failed*, auto-reverts after 2.5s). When an update is available via the manual check, the activity-log notice also fires.

Note: GitHub's `/releases/latest` endpoint only returns the highest **published** release. Drafts and pre-releases are invisible to it. So users on the latest published version (e.g., v0.1.2) won't see notices for unpublished drafts (v0.1.3+) — only for releases the user has actually clicked Publish on.

### Self-installer (Windows portable only)

When the updater fires and the user clicks **Download update**, on a Windows portable build the renderer drives a small state machine:

1. **idle** → `api.downloadUpdate(url)` → button label changes to `Starting…`
2. **downloading** → `update:download-progress` events stream in, button shows `Downloading 42%`. Main process saves the .exe to `%TEMP%\robogears-downloader-<timestamp>.exe`. Path is remembered as `global._pendingUpdatePath`.
3. **ready** → button changes to `Restart to apply` (white-filled style via `.ready` class)
4. **restarting** → `api.applyUpdate()` → button shows `Restarting…`

`applyUpdate()` writes a small relauncher `.cmd` to `%TEMP%\robogears-update-<timestamp>.cmd`:

```cmd
@echo off
setlocal
set "LAUNCHER=<process.env.PORTABLE_EXECUTABLE_FILE>"
set "NEW=<global._pendingUpdatePath>"
set /a count=0
:retry
move /Y "%NEW%" "%LAUNCHER%" >NUL 2>&1
if errorlevel 1 (
    timeout /t 1 /nobreak >NUL
    set /a count+=1
    if %count% lss 30 goto retry
    exit /b 1
)
start "" "%LAUNCHER%"
del "%~f0"
```

Spawned detached (`detached: true, stdio: 'ignore', windowsHide: true`) so it survives the parent process death. Polls `move /Y` for up to 30 seconds — the launcher .exe is locked while the Electron app is running; once the app quits (200 ms later, via `app.quit()`), the launcher releases the lock and the move succeeds. Then relaunches the new .exe and self-deletes.

**Why `process.env.PORTABLE_EXECUTABLE_FILE` and not `process.execPath`:** in a portable build, `process.execPath` points at the temp-extracted copy of the Electron binary (inside `%LOCALAPPDATA%\Temp\<random>\`), not the file the user double-clicked. `PORTABLE_EXECUTABLE_FILE` is set by electron-builder's portable launcher specifically to give us the on-disk path of the user-visible .exe.

**Why not electron-updater:** electron-updater wants a fixed install location (NSIS / DMG) and a `latest.yml` published alongside releases. The portable target doesn't fit its model. We also avoid the macOS code-signing/notarization requirements electron-updater would push us into.

**macOS:** `api.canSelfInstall()` returns `false`; the renderer's update notice falls back to the old `api.openExternal(downloadUrl)` flow. Building a working in-place updater on macOS requires a Developer ID + notarized binary so Gatekeeper accepts the relaunched .app — not worth the $99/yr until we have more users.

---

## Settings UI sections (top to bottom)

1. **Download folder** — `folder-input` + `Browse…`. Blank on first launch.
2. **Music library folder** — `library-input` + `Browse…` + `Clear`. Below that: scan status + Refresh button.
3. **TIDAL account** — auth status + `Sign in to TIDAL` (or `Re-authenticate` if already signed in).
4. **Updates** — current version label + `Check for updates` button.
5. **Reset config** — text button. Clears download + library folders only; keeps TIDAL sign-in.

The auth modal (separate from settings, opened by the Sign-in button) has a URL row showing the verification URL with a Copy button, plus the live terminal output of the auth flow.

---

## Sound effects

`renderer/app.js` has a cached `getAudioCtx()` helper (creates AudioContext on first use, reused after, resumes if suspended). All sounds use Web Audio — no asset files shipped.

| Function | Trigger | Sound |
|---|---|---|
| `playDownloadChime` | "Download all" click, after all validation passes | Ascending C5 → G5 (sine pair, slight detune for warmth) |
| `playClownHorn` | Click on the "Coming soon" badge over the drop-zone | Two-tone descending honk, 420 → 310 Hz (sawtooth + 1800 Hz lowpass) — easter egg |
| `playWarningHonk` | "Download all" click when blocked (no folder / no auth / nothing downloadable) | Same shape as clown horn, lower octave (220 → 165 Hz, 1100 Hz lowpass) — a "wronnng" |

Internally these share a `_honkPair(highHz, lowHz, opts)` helper; tweak the args to add variants.

---

## Funny loading text

`renderer/app.js` defines `FUNNY_LOADING` — 10 music-themed loading messages ("Searching the seven seas for your music…", "Digging through the record crates…", etc.). `showLoading()` with no arg picks one at random and cycles to a fresh random message every 2.5s if the operation lasts longer. `showLoading(text)` with a specific string uses that instead (still used by the OCR step which has a clear "Running OCR on screenshot…" label).

Add more entries to the `FUNNY_LOADING` array if the user requests it. They should stay short, on-theme (music/audio/discovery vibes), and not promise specific behavior.

---

## Where the last session left off

Latest released version is **v0.1.7**. Nothing currently uncommitted. The Mac download bug chain (cwd: __dirname → ENOENT in v0.1.6; ffmpeg asar path → ENOTDIR in v0.1.7) should be fully closed; the user's verification on a freshly-downloaded v0.1.7 mac .app is the final confirmation.

### Just landed (latest first)

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

1. **Spotify playlists > 100 tracks** — hard limit, see "Spotify situation" above. User accepted this. Headless scraper approach is documented if anyone wants to revive it.
2. **Library scan takes ~18 sec for ~500 files** on first launch. No on-disk cache yet. The user explicitly said "refresh on every launch" so this is intentional, but a faster scan would still be nice.
3. **Bulk runner progress reporting** is line-based, parsed from child stdout. No per-track row spinners in the queue.
4. **No global cancel button** during a bulk download. `api.cancelDownload()` exists in the preload but no UI calls it.
5. **No app icon.** Windows uses the default Electron icon for the .exe and taskbar; macOS uses the default Electron icon. Drop a 256×256 PNG/ICO in `build/icon.png` and add `"icon": "build/icon.png"` under `win`/`mac` in `package.json` to fix.
6. **macOS x64 not built.** Only arm64 (Apple Silicon). Intel Mac users would need a separate target. Mostly fine in 2026.
7. **No macOS self-install.** The Download update button on macOS still opens the browser; user re-downloads + replaces the .app manually. Proper auto-update would need a paid Apple Developer Program membership + notarization so Gatekeeper accepts the relaunched .app.
8. **softprops empty-body quirk on re-tagged releases**: if a tag is deleted + re-created and the previous release on GitHub still exists, softprops/action-gh-release sometimes preserves the old (empty) body instead of using the new `body_path`. Fix: `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md` after CI completes. Always verify body length after a release. (We've hit this on EVERY release so far including v0.1.7 — investigate if there's a softprops option that forces body overwrite.)
9. **Node 20 deprecation warnings in CI.** GitHub deprecated Node 20 actions; will be forced to Node 24 on June 2, 2026 and Node 20 removed Sept 16, 2026. We use `actions/checkout@v4`, `actions/setup-node@v4`, `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `softprops/action-gh-release@v2` — all currently on Node 20. Bump to whatever Node 24-compatible versions exist before June 2026.

### Possible next steps (in rough priority order)

1. **Per-track progress in the queue UI** during bulk download. Map child stdout lines back to queue items, show a state per row + small progress bar.
2. **Disk-cached library scan** — JSON file keyed by file mtime/size; rebuild only when stale.
3. **Cancel button** for in-flight downloads.
4. **Revive the headless Spotify scraper** to remove the 100-track limit (see Spotify section).
5. **Better OCR** (currently feature-flagged off entirely): tune Tesseract config or accept plain text paste alongside images. Then flip `OCR_FEATURE_ENABLED` back on.
6. **Persist queue across app restarts.**
7. **History / "recent downloads" pane.**
8. **App icon** — see "Known rough" #5.
9. **macOS x64 build** — add `{ arch: ['x64', 'arm64'] }` to the mac target (or `universal`) once we have a use case.
10. **macOS self-install** — requires Apple Developer Program ($99/yr) + notarization. Pre-condition: code-signing the .app and notarizing it via `notarytool` in CI. Then we can mirror the Windows self-installer pattern on macOS (download .dmg or new .app, replace, relaunch).
11. **Bump GitHub Actions to Node-24-compatible versions** before June 2026 (see "Known rough" #9).
12. **Investigate why softprops always leaves the body empty** — maybe a flag, maybe we need to add a `gh release edit` step inside the workflow itself as a safety net.
13. **Add screenshots to `docs/` and reference in README.**

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
- Don't enable the self-installer (`canSelfInstall()` returning true) on macOS or Linux without first investing in code-signing/notarization. The relauncher script we use is Windows-specific (`cmd.exe`, `move /Y`, `start ""`), and on macOS Gatekeeper would block a relaunched ad-hoc-signed .app from running unattended.
- Don't break the relauncher script logic in `electron-main.js#update:apply`. The 30-retry polling loop is the critical bit — it waits out the launcher's file lock. Tweak the timeout if needed; don't drop the retry.
- Don't change `draft: true` to `false` in `.github/workflows/release.yml`. The user wants every release to land as a draft for manual review + publish.
- Don't force-move a published tag. Unpublished drafts can be re-done; published releases are immutable. Bump to a new version instead.
- Don't auto-release. See the `feedback-no-auto-releases` memory entry — make code changes only; wait for an explicit ship instruction.
- Don't accumulate old version sections in `RELEASE_NOTES.md`. The file holds the current version only; previous notes stay on the GitHub Releases page. See the `feedback-release-notes-format` memory entry.
