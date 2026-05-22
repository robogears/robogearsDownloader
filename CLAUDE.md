# Project: TIDAL Downloader (read this first)

You've just inherited a personal music-downloader app. **Read this entire file before doing anything.** It contains the working architecture, all mandatory rules, full history of what was tried and abandoned, and where the last session left off.

---

## What this is

A desktop app that downloads lossless FLAC tracks from TIDAL, driven by:

- A user's TIDAL subscription (OAuth via device-code flow)
- Inputs: paste a TIDAL URL, paste a Spotify URL (track / album / playlist), type a song name to search, or drop a screenshot of a tracklist
- A hidden Electron `BrowserWindow` that scrapes the Spotify web player (for unlimited-size playlists — see "Spotify situation" below)
- Tesseract.js OCR for screenshots
- A "queue" UI where the user reviews tracks before downloading
- A read-only **music library folder** that the app scans to avoid re-downloading songs the user already has

Tech: Node.js + Electron, no framework, vanilla HTML/CSS/JS for the renderer. All audio handling done via `ffmpeg-static` (bundled FFmpeg).

**Where it lives:** `Z:\robogearsDownloader\`

---

## Quick orientation: what works today

| Feature | State |
|---|---|
| TIDAL URL → track/album/playlist resolve + download | ✅ works |
| Spotify URL → resolve via headless web-player scrape → match each track on TIDAL via ISRC/search → download from TIDAL | ✅ works (no track-count limit) |
| Free-text search → modal of TIDAL results → pick → add to queue | ✅ works |
| Screenshot of tracklist → OCR → match each on TIDAL → add to queue | ✅ works (Tesseract.js, CDN-loaded) |
| Queue UI with per-item remove, "Download all" | ✅ works |
| Library deduplication via metadata + filename | ✅ works — exact/similar split |
| Similar-tracks confirmation modal before download | ✅ works |
| Settings: download folder, library folder, library refresh | ✅ works |
| Auto-fallback FLAC → .m4a when no lossless master | ✅ works |
| Cover art embedded via piped FFmpeg stdin | ✅ works (no temp file) |
| Parallel segment downloads (8 concurrent) | ✅ works |
| Retry on 429/5xx with exponential backoff | ✅ works |
| Library scan reads audio tags (title, artist, duration) via `music-metadata` | ✅ works |

---

## MANDATORY RULES (these are non-negotiable)

### 1. Default download folder is `Z:\Downloads`

User has stated this loudly multiple times. The default is hard-coded in `tidal_download.js` (`DEFAULT_OUT_DIR`) and `bulk_runner.js`. If the user supplies an explicit path on the command line, honor it; otherwise tools fall back to `Z:\Downloads`. **Never use `Z:\Downloads\Music`, the current working directory, or anything else.**

### 2. Album and playlist downloads land directly in the output dir

No per-album subfolders, no per-playlist subfolders. Every file goes flat into the chosen dir. The skip-if-exists check handles name collisions safely.

### 3. Filename is `<Title>.flac` (or `<Title>.m4a` for AAC fallback)

Title only — no artist prefix, no track number prefix. User explicitly requested this.

### 4. Library deduplication is enforced before every download

`tidal_download.js#downloadTrack` calls `lib.findInLibrary(title, artist, duration)` before any network fetch. If the result is `kind: 'exact'`, skip silently. If `kind: 'similar'`, skip with a warning (the GUI prompts the user about these *before* download starts). Only `--force` (or `--skip-library-check` from `bulk_runner`) bypasses this.

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
│                              child-process spawn, BrowserWindow lifecycle.
├── electron-preload.js       ← Sandboxed bridge. Exposes a curated `api` object
│                              to the renderer via `contextBridge`.
├── renderer/
│   ├── index.html            ← Single-page UI. Modals: settings, search results,
│   │                              similar-tracks, auth-progress, loading overlay.
│   ├── styles.css            ← Monochrome (black/white) theme.
│   └── app.js                ← Renderer logic: queue, modals, OCR (Tesseract.js
│                              via CDN), IPC calls.
├── tidal_lib.js              ← The brain. Shared between Electron main AND CLI
│                              scripts. Token mgmt, HTTP w/ retry+timeout, TIDAL
│                              API wrappers, Spotify embed scraping (fallback),
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
├── spotify-credentials.json  ← DELETED — no longer used. Spotify uses headless
│                              web-player scrape now.
├── spotify-token.json        ← DELETED — no longer used.
├── package.json              ← Node deps (ffmpeg-static, music-metadata, electron)
├── start_app.bat             ← Convenience launcher: `npm start`
└── ONBOARDING.md             ← Older docs for the CLI workflow. Still mostly
                                accurate for CLI usage. The GUI superseded most
                                of it.
```

### Process model

- **Electron main** (`electron-main.js`): owns the BrowserWindow, all IPC, the library scanner (cache lives here), the Spotify web-player scraper. Imports `tidal_lib.js` directly.
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
- `api.libraryStatus()` / `api.libraryRescan()` — library scanner state
- `api.onDownloadLine(cb)` / `api.onDownloadDone(cb)` — stdout/exit events from spawned children
- `api.onSpotifyScrapeProgress(cb)` / `api.onSpotifyScrapeLog(cb)` — progress + diagnostic logs from the headless Spotify scrape
- `api.onLibraryScanned(cb)` — fires when an async scan completes

---

## Library deduplication system (read carefully)

`tidal_lib.js` exposes:

- `scanLibrary()` → async. Recursively walks `LIBRARY_PATH`, reads both filename AND audio-tag metadata (`music-metadata` library) for each file. Returns a list of entries with **four** normalized title forms per file:
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
- `rescanLibrary()` (user clicks Refresh)
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
- For `kind: 'exact'` matches: `included = false` by default (greyed out, "**+ Add**" button visible). User must click "+ Add" to opt in.
- For `kind: 'similar'` matches: `included = true` by default (NOT greyed out, just a yellow `⚠ similar version in library` badge as info).
- For everything else: `included = true` by default.

The user reviews all of this directly in the queue — no separate modal. Clicking "+ Add" flips an exact-match item to included; it loses the grey-out and the badge stays as a reminder. Clicking the ✕ removes the item from the queue entirely.

**Download all** filters by `t.included === true && !t.notFound` and sends that list to `bulk_runner.js`. The button label updates to reflect the actual count (e.g., "Download (47)" when 3 of 50 are excluded).

The `bulk_runner` passes `--skip-library-check` to each spawned `tidal_download.js` because the queue already vetted everything.

---

## Spotify situation (history + current solution)

The journey here was painful — knowing what was tried saves the next session from repeating it.

### What we tried and abandoned

1. **Monochrome web app** (the original starting point) — relied on third-party Qobuz proxy servers that went offline. Replaced by our own scripts.
2. **Spotify Client Credentials Flow** — app-only auth via `clientId`+`clientSecret`. Spotify quietly restricted this for new dev apps in November 2024: `/v1/playlists/{id}` returns 200 with **no `tracks` field**, `/v1/playlists/{id}/tracks` returns **403 Forbidden**. Confirmed via direct testing.
3. **Spotify Authorization Code (user OAuth)** — full user sign-in via device redirect. Same restrictions apply to new apps in Development mode — `tracks` field stripped, `/tracks` endpoint 403. Confirmed even for the user's *own* playlists. This is a Spotify-side block on apps that haven't been approved for Extended Quota Mode (a slow review process).
4. **Anonymous web-player bearer token** (`/get_access_token` scraping) — returns 403 for unauthenticated callers as of mid-2024.

### Current solution: public embed page (100-track cap, no setup)

`tidal_lib.js#getSpotifyPlaylist(id)` fetches `https://open.spotify.com/embed/playlist/<id>`, parses the `__NEXT_DATA__` JSON blob, and returns the playlist's tracks. Same approach is used for tracks and albums (`/embed/track/<id>`, `/embed/album/<id>`).

**Limitation**: the embed page caps playlist tracks at 100. There is no pagination — track 101+ is simply not in the response.

A previous session tried a headless `BrowserWindow` scrape with Chrome DevTools Protocol to capture Spotify's internal GraphQL responses (which paginate properly). It worked in principle but kept hanging on "Resolving link…" in practice — auto-scroll wasn't reliably triggering lazy-loads. Code was removed. If you want to revive it, the implementation lived in `electron-main.js` (functions `scrapeSpotifyPlaylist`, `extractTracksFromGraphQL`, IPC handler `spotify:scrape`, plus `lib.setWebPlaylistScraper` injection). Check the user's git history if they have one — otherwise rebuild from the design notes in this paragraph.

For now, large playlists need to be split manually, or use Soundiiz/Exportify-style CSV export → paste into the OCR queue (or build a CSV importer).

### Spotify tracks and albums (not playlists)

`getSpotifyTrack` and `getSpotifyAlbum` use the public `/embed/track/<id>` and `/embed/album/<id>` pages. These don't have the Nov 2024 restriction and don't need any credentials. Result: no ISRCs available, so the Spotify→TIDAL matcher falls back to title + artist + duration scoring (which already had to be the case since the embed never returned ISRCs).

### Spotify→TIDAL matching

`spotifyTrackToTidal(spTrack, tidalToken, countryCode)`:

1. If `spTrack.external_ids.isrc` exists, search TIDAL by ISRC first (perfect match). The embed doesn't expose ISRCs so this branch is rarely hit; it's the API-path fallback.
2. Otherwise: TIDAL search by `"<title> <artist>"`, score top 10 results by:
   - Title exact match (100), startsWith (50), includes (25)
   - Artist token overlap (0-100)
   - Duration proximity (50 if <3s diff, 25 if <8s, else 0)
3. Acceptance: `titleScore === 100` OR (`titleScore >= 25 && artistScore >= 50`). Prevents "Free Your Mind" matching "I Never Thought I'd See the Day" purely on artist overlap.

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

## Where the last session left off

The just-completed session built the **metadata-based library scanner** with the **exact vs similar** distinction and a **GUI modal** that prompts the user before downloading similar tracks. Specifically:

### Just landed (verified working)

- `music-metadata` v7 installed and integrated. Library scan now reads ID3/FLAC/iTunes/Vorbis tags from each file, parallel concurrency 8, ~18 sec for 492 files
- Two-tier normalization (`normalizeFullForMatch` vs `normalizeCoreForMatch`) detecting "Song" vs "Song (Extended Mix)" as different but related
- `findInLibrary` is async, returns `{ kind: 'exact' | 'similar', path, libraryTitle }` or null
- `enrichWithLibraryStatus(tracks)` called automatically inside `resolveUrlToTracks` and `searchTracksForQueue` so queue items already carry their library state
- Queue renders three states with badges: normal, exact (grayed + line-through), similar (yellow left-border)
- `#similar-modal` opens before bulk download starts if any queue items are similar; each row has a checkbox + library file path; bulk "Skip all" / "Include all" buttons
- Library settings: folder picker + Clear + Refresh button + live "N files indexed" status
- IPC: `library:status`, `library:rescan`, `library:scanned` event
- Library scan starts in background at app boot (`app.whenReady().then(...)`); doesn't block UI
- `bulk_runner.js` passes `--skip-library-check` to spawned children since the queue has already vetted them
- `tidal_download.js` honors the new `--skip-library-check` flag

### Known things still rough

1. **Library scan takes ~18 sec for 492 files** at first run. No on-disk cache yet — runs every app launch. Could add an mtime-keyed JSON cache to speed up subsequent launches. The user has explicitly said "refresh on every launch" so this is intentional, but a faster scan would still be nice.

2. **Spotify scraper has a 60-second hard timeout.** For very large playlists (1000+ tracks), this might not be enough. The progress events do fire so the timeout fires only on real hangs, but bump it if needed.

3. **The bulk runner's progress reporting** is line-based, parsed from child stdout. The activity log shows progress per track but there's no per-track row in the queue showing in-flight state. Could add per-row spinners.

4. **No global cancel button** during a bulk download. If user wants to abort mid-batch, they have to wait or kill the app. `api.cancelDownload()` exists in the preload but no UI calls it.

5. **The headless Spotify window is `show: false`** so the user never sees if it's hitting a login wall. For public playlists this never happens, but if Spotify ever requires login, the scrape silently times out. Could detect a `/login` redirect and either show the window or surface a clear error.

6. **OCR accuracy on screenshots** is decent (anchors on row numbers + grabs title and artist below) but fails on non-Spotify formats. The `extractTracksFromOCR` heuristic has a fallback that looks for "Title — Artist" line format, but otherwise just returns empty.

### Possible next steps (in rough priority order)

1. **Per-track progress in the queue UI** during bulk download. Map child stdout lines back to queue items, show a state per row (downloading / done / failed / skipped) plus a small progress bar.
2. **Disk-cached library scan** to bring app-launch time from 18s down to <1s. JSON file keyed by file mtime/size; rebuild only when stale.
3. **In-window Spotify sign-in detection** for the rare case where a private/region-restricted playlist requires it. If `/login` appears in the URL, briefly show the window and tell the user.
4. **Cancel button** for in-flight downloads (wire up `api.cancelDownload()`).
5. **Better OCR**: tune Tesseract config or accept user paste of plain text alongside images.
6. **Persist queue across app restarts** (currently lost on close).
7. **History / "recent downloads" pane**.

---

## User preferences and communication style

The user is a power user comfortable with technical detail but values brevity and "no fluff." Tone preferences observed across many sessions:

- **Direct answers first, explanations second.** Don't open with "Great question!" or recap the request. Start with the answer.
- **Show, don't talk.** When you change code, briefly summarize what changed in a table. When you propose options, list them in a table with trade-offs.
- **Diagnose precisely.** When something breaks, write a tiny script that reproduces the issue and shows the actual data (like `debug_user_token.js` we did for Spotify). Then fix from evidence, not guesses.
- **No emojis in code or filenames** unless explicitly requested. Emoji *characters* in log output (✓, ✗, ⚠, 📁) are fine — they're already used throughout for status.
- **Always restart Electron after changes** to renderer/main code (HMR is not wired up). The pattern: `Get-Process electron | Stop-Process -Force; cd Z:\robogearsDownloader; npm start`. The user will *see* the restart and doesn't need it announced — just do it and verify the app comes up.
- **Library is read-only.** Never propose writing to `Z:\Dropbox\Music` or wherever the library path is set.

---

## Sanity-check commands (run after any major change)

Lib loads cleanly:

```
cd Z:\robogearsDownloader
node -e "const lib = require('./tidal_lib'); console.log('OK. exports:', Object.keys(lib).length, 'symbols');"
```

Library scan + matcher:

```
node -e "(async () => { const lib = require('./tidal_lib'); const t0 = Date.now(); const r = await lib.scanLibrary(); console.log('Scanned', r.entries.length, 'files in', Date.now()-t0, 'ms'); console.log('Stronger ->', JSON.stringify(await lib.findInLibrary('Stronger'))); console.log('Stronger (Remix) ->', JSON.stringify(await lib.findInLibrary('Stronger (Remix)'))); console.log('FakeFakeFake ->', JSON.stringify(await lib.findInLibrary('FakeFakeFake'))); })()"
```

Spotify scrape (manual smoke test — opens a hidden window):

```
# From inside the running app, paste any open.spotify.com/playlist/<id> URL.
# Activity log should show:
#   [spotify-scrape] CDP attached
#   [spotify-scrape] page did-finish-load
#   [spotify-scrape] starting auto-scroll
#   [spotify-scrape] +N tracks (total now N/M)  ← these should keep coming
#   [spotify-scrape] auto-scroll finished
#   [spotify-scrape] finish (settle); tracks=M, ...
```

TIDAL auth state:

```
Test-Path Z:\robogearsDownloader\token.json
```

App launches and binds Electron window:

```
cd Z:\robogearsDownloader; npm start
```

---

## Common diagnostic patterns

- **"Cannot read properties of undefined (reading 'X')"** — usually means a Spotify/TIDAL API response had an unexpected shape. Check whether the relevant function has defensive `?.` and `|| []` guards.
- **Downloads stalling at "Resolving link..."** — Spotify scrape is hanging. The activity log will tell you (see scrape logs above). Most common cause: page didn't fully render before scroll triggered, or the GraphQL endpoint changed shape.
- **"0 tracks from link"** — resolver returned an empty array. For Spotify: scraper found no GraphQL responses matching its URL filter (currently `pathfinder` or `api-partner.spotify`). For TIDAL: playlist UUID typo or the playlist is region-locked.
- **FLAC integrity warning after a successful save** — segment came down corrupt. The file is kept and the warning is logged but not fatal. Re-run with `--force` to redownload.
- **"AAC-only on TIDAL"** — TIDAL doesn't carry a lossless master for this track. Default behavior is to save as `.m4a` anyway; `--flac-only` makes it a hard skip.

---

## Don'ts

- Don't reintroduce the Spotify Client Credentials Flow. It does not work for new dev apps.
- Don't reintroduce the OAuth user-context flow for Spotify. Same restriction.
- Don't add Spotify `clientId`/`clientSecret` settings UI back. They're not needed — headless scraping handles everything.
- Don't subfolder album/playlist downloads. User explicitly does not want that.
- Don't write to `Z:\Dropbox\Music` (or wherever the library path points).
- Don't fetch cover art to a temp file. It's a Buffer piped to FFmpeg stdin.
- Don't bypass `findInLibrary` without an explicit user opt-in (the `--force` flag or the similar-modal "Include" action).
- Don't strip the `--skip-library-check` flag from `bulk_runner.js` — the queue is the source of truth for the bulk pipeline.
