# Project: robogears Downloader (read this first)

You've just inherited a personal music-downloader app. **Read this entire file before doing anything.** It contains the working architecture, all mandatory rules, full history of what was tried and abandoned, and where the last session left off.

---

## What this is

A desktop app that downloads lossless FLAC tracks from TIDAL, driven by:

- A user's TIDAL subscription (OAuth via device-code flow)
- Inputs: paste a TIDAL URL, paste a Spotify URL (track / album / playlist), type a song name to search, or drop a screenshot of a tracklist
- Tesseract.js OCR for screenshots
- A "queue" UI where the user reviews tracks before downloading
- A read-only **music library folder** that the app scans (reads ID3/Vorbis/iTunes tags via `music-metadata`) to avoid re-downloading songs the user already has

Tech: Node.js + Electron, no framework, vanilla HTML/CSS/JS for the renderer. All audio handling done via `ffmpeg-static` (bundled FFmpeg).

**Where it lives:** `Z:\robogearsDownloader\` (also published at https://github.com/robogears/robogearsDownloader)

**Current version:** v0.1.0 — packaged as a single portable `.exe` (~90 MB) via `electron-builder`. See "Packaging / distribution" section below.

---

## Quick orientation: what works today

| Feature | State |
|---|---|
| TIDAL URL → track/album/playlist resolve + download | ✅ works |
| Spotify URL (track / album / playlist) → public embed page → match each on TIDAL → download | ✅ works (**playlists capped at 100 tracks** — Spotify's embed limit) |
| Free-text search → modal of TIDAL results → pick → add to queue | ✅ works |
| Screenshot of tracklist → OCR → match each on TIDAL → add to queue | ✅ works (Tesseract.js, CDN-loaded) |
| Queue UI with per-item remove, "+ Add" button on exact-library-matches, "Download all" | ✅ works |
| Library deduplication via metadata + filename (exact vs similar) | ✅ works |
| Settings: download folder, library folder, library refresh | ✅ works |
| Auto-fallback FLAC → .m4a when no lossless master | ✅ works |
| Cover art embedded via piped FFmpeg stdin | ✅ works (no temp file) |
| Parallel segment downloads (8 concurrent) | ✅ works |
| Retry on 429/5xx with exponential backoff | ✅ works |
| Library scan reads audio tags (title, artist, duration) via `music-metadata` | ✅ works |
| Funny rotating loading text during search/resolve | ✅ works |
| Packaged as a single portable Windows .exe via electron-builder | ✅ works (`npm run build:win`) |

---

## MANDATORY RULES (these are non-negotiable)

### 1. Default download folder is `Z:\Downloads`

User has stated this loudly multiple times. The default is hard-coded in `tidal_download.js` (`DEFAULT_OUT_DIR`) and `bulk_runner.js`. If the user supplies an explicit path on the command line, honor it; otherwise tools fall back to `Z:\Downloads`. **Never use `Z:\Downloads\Music`, the current working directory, or anything else.**

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
│                              child-process spawn, BrowserWindow lifecycle,
│                              library scan kickoff at boot.
├── electron-preload.js       ← Sandboxed bridge. Exposes a curated `api` object
│                              to the renderer via `contextBridge`.
├── renderer/
│   ├── index.html            ← Single-page UI. Modals: settings, search results,
│   │                              auth-progress, loading overlay.
│   ├── styles.css            ← Monochrome (pure black, stark white) theme.
│   └── app.js                ← Renderer logic: queue, modals, OCR (Tesseract.js
│                              via CDN), funny loading text, IPC calls.
├── tidal_lib.js              ← The brain. Shared between Electron main AND CLI
│                              scripts. Token mgmt, HTTP w/ retry+timeout, TIDAL
│                              API wrappers, Spotify embed scraping,
│                              library scanner, URL/search resolver.
├── tidal_download.js         ← CLI: download one URL or numeric track ID.
│                              Spawned by Electron main as a child process per
│                              track during bulk runs. Also usable standalone.
├── tidal_auth_node.js        ← One-time TIDAL OAuth device-code flow. Writes
│                              token.json. Invoked by main on "Sign in to TIDAL".
├── tidal_search.js           ← CLI: search TIDAL by free text. Standalone tool.
├── tidal_check_quality.js    ← CLI: probe what quality tiers TIDAL has for a
│                              track ID. Diagnostic.
├── bulk_runner.js            ← CLI: takes a tracklist JSON (with TIDAL IDs or
│                              {title,artist} pairs), spawns tidal_download.js
│                              per track. Used by the GUI's "Download all".
├── token.json                ← TIDAL OAuth tokens (access + refresh + expires_at
│                              + countryCode). Gitignored.
├── package.json              ← Node deps (ffmpeg-static, music-metadata, electron)
├── start_app.bat             ← Convenience launcher: `npm start`
├── README.md                 ← Public, user-facing readme (GitHub front page)
├── ONBOARDING.md             ← Older docs for the CLI workflow. Still mostly
│                              accurate for CLI usage. The GUI superseded most
│                              of it.
└── CLAUDE.md                 ← This file.
```

### Process model

- **Electron main** (`electron-main.js`): owns the BrowserWindow, all IPC, the library scanner (cache lives here). Imports `tidal_lib.js` directly.
- **Renderer** (`renderer/`): UI only. Talks to main via `window.api.*` (preload bridge). Never touches files or network directly.
- **Spawned children** (`tidal_download.js`, `bulk_runner.js`): plain Node.js processes spawned by main with `ELECTRON_RUN_AS_NODE=1` and `TIDAL_LIBRARY_FOLDER` env vars. Output streamed back to renderer via stdout/stderr capture in main.

### IPC surface (preload → main)

See `electron-preload.js` for the full list. Key ones:

- `api.getSettings()` / `api.saveSettings(s)`
- `api.pickFolder()` — opens native folder picker
- `api.tokenExists()` / `api.runAuth()` — TIDAL device-code flow
- `api.resolveInput({ input })` — URL or search query → tracks. Returns `{ ok, kind: 'url'|'search', tracks }`. Tracks come pre-enriched with `libraryMatch`.
- `api.resolveOcr({ tracks })` — OCR'd {title,artist} list → matched TIDAL tracks
- `api.startBulk({ tracks, outDir })` — kicks off batch download
- `api.startDownload({ input, outDir })` — legacy single-URL flow, still used in places
- `api.libraryStatus()` / `api.libraryRescan()` — library scanner state + manual refresh
- `api.onDownloadLine(cb)` / `api.onDownloadDone(cb)` — stdout/exit events from spawned children
- `api.onLibraryScanned(cb)` — fires when an async scan completes

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

OAuth device-code flow in `tidal_auth_node.js`. Opens browser to `link.tidal.com/...`, polls `https://auth.tidal.com/v1/oauth2/token` until user authorizes. Saves to `token.json`:

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

The app ships as a single portable Windows `.exe` (~90 MB) built with `electron-builder`. Build config lives in the `build` field of `package.json`. Key choices baked in:

- **`win.target`**: only `portable` (one self-contained `.exe`; no installer, no shortcuts, no registry entries — runs from anywhere)
- **`portable.artifactName`**: `robogears-downloader.exe` (no version suffix in the filename, by user preference)
- **`asarUnpack`**: `node_modules/ffmpeg-static/**/*` — `ffmpeg.exe` is a real binary that must live on disk for `spawn()` to invoke it; can't stay in the asar
- **`directories.output`**: `dist/` (gitignored)

### Build commands

```sh
npm run build:win     # full build (current preset = portable only)
npm run build:portable  # equivalent
npm run build         # whatever the default OS resolves to
```

Output: `Z:\robogearsDownloader\dist\robogears-downloader.exe`

### Path migration: source-relative vs userData

The packaged `.exe` lives in a read-only asar archive. That means `path.join(__dirname, 'token.json')` (which the original CLI scripts used) doesn't work — there's no writable token.json next to the source. We solved this with an env var + `app.isPackaged` check:

```js
// In electron-main.js, BEFORE require('./tidal_lib'):
if (app.isPackaged) {
    process.env.TIDAL_TOKEN_PATH = path.join(app.getPath('userData'), 'token.json');
}
```

`tidal_lib.js` and `tidal_auth_node.js` both honor `TIDAL_TOKEN_PATH` and fall back to the source-relative path if it's unset. Spawned children inherit the env var via `childEnv()` (because the spread `...process.env` includes it).

**Net effect:**
- Dev mode (`npm start`): token at `./token.json`, same as before
- Packaged (.exe): token at `%APPDATA%\robogears Downloader\token.json`
- Both contexts work without code changes

Settings already used `app.getPath('userData')` before this — no migration needed there.

### Code signing — there isn't any

The build uses electron-builder's bundled self-signed cert via `signtool`. Windows doesn't trust that, so first launch shows the blue **"Windows protected your PC"** SmartScreen dialog. Users click **More info → Run anyway** to proceed. This is normal for unsigned personal-use apps. A real code-signing cert costs $80-300/year and isn't worth it unless distributing widely.

### Distribution

For now: the user attaches `dist/robogears-downloader.exe` to wherever they're sharing it (USB / Dropbox / Discord / GitHub Releases). No GitHub Actions workflow set up yet — that's a possible next step (see below).

---

## Funny loading text

`renderer/app.js` defines `FUNNY_LOADING` — 10 music-themed loading messages ("Searching the seven seas for your music…", "Digging through the record crates…", etc.). `showLoading()` with no arg picks one at random and cycles to a fresh random message every 2.5s if the operation lasts longer. `showLoading(text)` with a specific string uses that instead (still used by the OCR step which has a clear "Running OCR on screenshot…" label).

Add more entries to the `FUNNY_LOADING` array if the user requests it. They should stay short, on-theme (music/audio/discovery vibes), and not promise specific behavior.

---

## Where the last session left off

The just-completed session **packaged the app as a portable Windows `.exe` via electron-builder** and tagged it **v0.1.0**. The session before that published the project to GitHub (`https://github.com/robogears/robogearsDownloader`) and cleaned out all the upstream Python remnants. Before that, the major work was the library matcher UX refinement and the funny loading text.

### Just landed (latest first)

**Packaging as a portable .exe (v0.1.0):**
- `electron-builder@26.8.1` added as a devDependency
- `build` config in `package.json` — `appId: com.robogears.downloader`, `productName: robogears Downloader`, `directories.output: dist`, `win.target: portable` only (single .exe, no installer), `portable.artifactName: robogears-downloader.exe` (no version suffix in filename per user preference)
- `asarUnpack: node_modules/ffmpeg-static/**/*` so `ffmpeg.exe` stays on disk where `spawn()` can find it
- npm scripts added: `build`, `build:win`, `build:portable`
- **Token path migration**: `electron-main.js` sets `process.env.TIDAL_TOKEN_PATH` to `app.getPath('userData') + '/token.json'` when `app.isPackaged === true`, BEFORE requiring `tidal_lib`. The lib (and `tidal_auth_node.js`) honor `TIDAL_TOKEN_PATH` if set, fall back to `./token.json` otherwise. Spawned children inherit it via `...process.env` in `childEnv()`. Net effect: dev mode unchanged; packaged mode writes tokens to `%APPDATA%\robogears Downloader\`.
- Window title + `.brand-name` text updated from "TIDAL Downloader" → "robogears Downloader"
- `version` in `package.json` bumped from `1.0.0` → `0.1.0` (initial public release tag)
- Build output: `dist/robogears-downloader.exe` (90.6 MB)

**Repo publish + cleanup (one session ago):**
- Deleted all Python remnants from the original upstream fork: `main.py`, `Dockerfile`, `docker-compose.yml`, `requirements.txt`, `tidal_auth/`, `tests/`, `.env`, `.env.example`, `.github/`
- Deleted legacy `bulk_download.js` (replaced by `bulk_runner.js`)
- Wrote a public-facing `README.md` (GitHub front page)
- Cleaned up `.gitignore` — no more Python boilerplate, just Node/Electron-relevant excludes. `token.json` correctly ignored.
- Updated `package.json` — name `robogears-downloader`, MIT license declared, repo URL set
- First commit pushed to `main` (19 files, 5566 LoC)
- LICENSE preserved upstream author's MIT copyright (legally required)

**Funny loading text:**
- 10 music-themed rotating messages during URL resolution / search
- Cycles every 2.5s to a new random message, won't repeat back-to-back
- `_loadingCycler` interval cleaned up in `hideLoading`
- OCR's "Running OCR on screenshot…" phase keeps its specific text (different operation from search)

**Library matcher UX refinement:**
- Exact matches: greyed (line-through + faded info column) + `+ Add` button. Bright button stays visible (only the info column is faded so the button doesn't get dimmed via parent opacity).
- Similar matches: yellow badge only — no border, no grey-out, included by default
- Removed the entire `#similar-modal` and the `askAboutSimilar()` function — the queue is now the only review surface
- `Download all` button label switches to `Download (N)` when some items are excluded
- Each queue item gets an `included` flag (defaults `false` for exact, `true` for everything else)
- "+ Add" click handler in queue list flips `included = true` and re-renders

**Spotify scraper revert (earlier in session):**
- Removed `scrapeSpotifyPlaylist`, `extractTracksFromGraphQL`, `spotify:scrape` IPC, `lib.setWebPlaylistScraper`
- Removed `onSpotifyScrapeProgress` and `onSpotifyScrapeLog` from preload + renderer
- Removed `http`/`https`/`crypto` imports from `electron-main.js` (no longer needed)
- Back to the simple, working embed-only path with 100-track cap

### Known things still rough

1. **Spotify playlists > 100 tracks** — hard limit, see "Spotify situation" above. User has explicitly accepted this for now. The headless scraper approach can be revived if someone wants to fix the auto-scroll issue.

2. **Library scan takes ~18 sec for ~500 files** on first launch. No on-disk cache yet — runs every app launch. Could add an mtime-keyed JSON cache to speed up subsequent launches. The user explicitly said "refresh on every launch" so this is intentional, but a faster scan would still be nice.

3. **The bulk runner's progress reporting** is line-based, parsed from child stdout. The activity log shows progress per track but there's no per-track row in the queue showing in-flight state. Could add per-row spinners.

4. **No global cancel button** during a bulk download. If user wants to abort mid-batch, they have to wait or kill the app. `api.cancelDownload()` exists in the preload but no UI calls it.

5. **OCR accuracy on screenshots** is decent (anchors on row numbers + grabs title and artist below) but fails on non-Spotify formats. The `extractTracksFromOCR` heuristic has a fallback that looks for "Title — Artist" line format, but otherwise just returns empty.

6. **No CHANGELOG, no release-tag commits, no GitHub Releases page.** The `.exe` exists in `dist/` (gitignored) but there's no automated `gh release create` or CI workflow to publish builds. Each release is manual right now.

7. **No app icon.** Windows uses the default Electron icon for the packaged `.exe` and taskbar. Drop a 256×256 `.png` (or `.ico`) in `build/icon.png` and add `"icon": "build/icon.png"` under the `win` config in `package.json` to fix.

### Possible next steps (in rough priority order)

1. **Per-track progress in the queue UI** during bulk download. Map child stdout lines back to queue items, show a state per row (downloading / done / failed / skipped) plus a small progress bar.
2. **Disk-cached library scan** to bring app-launch time from 18s down to <1s. JSON file keyed by file mtime/size; rebuild only when stale.
3. **Cancel button** for in-flight downloads (wire up `api.cancelDownload()`).
4. **Revive the headless Spotify scraper** to remove the 100-track limit. See "If you want to revive the headless scraper" section above.
5. **Better OCR**: tune Tesseract config or accept user paste of plain text alongside images.
6. **Persist queue across app restarts** (currently lost on close).
7. **History / "recent downloads" pane.**
8. **App icon** (see "Known rough" #7 above).
9. **GitHub Actions release workflow** — auto-build on tag push, upload to GitHub Releases, give users a download link from the repo page.
10. **Add screenshots to `docs/` and reference in README.**

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

---

## Common diagnostic patterns

- **"Cannot read properties of undefined (reading 'X')"** — usually means a Spotify/TIDAL API response had an unexpected shape. Check whether the relevant function has defensive `?.` and `|| []` guards.
- **"Resolving link…" stuck forever** — usually because the resolver threw and the error didn't propagate. Add a try/catch around the resolver call in `electron-main.js#resolve:input` and surface the error to the activity log.
- **"0 tracks from link"** — resolver returned an empty array. For Spotify playlists with >100 tracks, this can happen if Spotify changed the embed page structure. Check `tidal_lib.js#fetchSpotifyEmbed` and the `__NEXT_DATA__` JSON shape. For TIDAL: playlist UUID typo or the playlist is region-locked.
- **FLAC integrity warning after a successful save** — segment came down corrupt. The file is kept and the warning is logged but not fatal. Re-run with `--force` to redownload.
- **"AAC-only on TIDAL"** — TIDAL doesn't carry a lossless master for this track. Default behavior is to save as `.m4a` anyway; `--flac-only` makes it a hard skip.
- **Library re-scan takes forever** — if the user pointed at a folder with thousands of files, `music-metadata` parsing each one becomes the bottleneck. Disk-cache it (next-steps item #2).

---

## Don'ts

- Don't reintroduce the Spotify Client Credentials Flow. It does not work for new dev apps.
- Don't reintroduce the OAuth user-context flow for Spotify. Same restriction.
- Don't add Spotify `clientId`/`clientSecret` settings UI back. They're not needed — embed scraping handles everything within the 100-track limit.
- Don't subfolder album/playlist downloads. User explicitly does not want that.
- Don't write to the user's music library folder. Read-only.
- Don't fetch cover art to a temp file. It's a Buffer piped to FFmpeg stdin.
- Don't bypass `findInLibrary` without an explicit user opt-in (the `--force` flag or the user clicking "+ Add" in the queue).
- Don't strip the `--skip-library-check` flag from `bulk_runner.js` — the queue is the source of truth for the bulk pipeline.
- Don't bring back the `#similar-modal`. The user explicitly preferred reviewing in the queue inline.
- Don't commit `token.json`, `node_modules/`, or anything in the `.gitignore`. The first commit was clean — keep it that way.
- Don't replace `process.env.TIDAL_TOKEN_PATH || path.join(__dirname, 'token.json')` with just `path.join(__dirname, 'token.json')`. The env-var fallback is what makes the packaged `.exe` work — packaged mode points it at `%APPDATA%\robogears Downloader\token.json`.
- Don't remove `asarUnpack: ['node_modules/ffmpeg-static/**/*']` from `package.json`. FFmpeg is a real binary; if it stays in the asar, `spawn()` can't invoke it and every download breaks in the packaged build.
