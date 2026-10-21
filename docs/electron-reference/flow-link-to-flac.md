## Happy path: input to FLAC on disk

Code version traced: v0.1.30 (`package.json:3`, Electron `^33`, `ffmpeg-static ^5.3.0`, `music-metadata ^7.14.0`). Files: `renderer/app.js`, `renderer/index.html`, `renderer/styles.css`, `electron-preload.js`, `electron-main.js`, `tidal_lib.js`, `bulk_runner.js`, `tidal_download.js`, plus the token-saving part of `tidal_auth_node.js`. Nothing was run; anything that depends on runtime behaviour is marked "unverified (needs a run)".

### Overview

The user types or pastes something into one text field. The app turns it into a list of TIDAL tracks: a TIDAL track/album/playlist link is read straight from TIDAL's API; a Spotify track/album/playlist link is read from Spotify's public "embed" web page and each song is looked up on TIDAL by a fuzzy text search; anything else is a TIDAL text search whose results the user picks from in a dialog. A dropped CSV or pasted tracklist goes through a separate, similar matcher. Before the renderer ever sees the rows, the main process tags each one with whether a song of the same title already exists in the user's read-only music library.

The rows land in a persistent queue (`queue.json`). In the background the app downloads each row's full lossless audio once, only to draw a 200-bar waveform. When the user clicks **Download all**, the main process writes the chosen rows to `pending-tracklist.json` and starts a helper process (`bulk_runner.js`), which downloads the tracks strictly one at a time by starting a fresh worker process (`tidal_download.js`) per track. Each worker re-reads the track from TIDAL by ID, skips if `<Title>.flac` or `<Title>.m4a` already exists in the download folder, asks TIDAL for the Hi-Res stream (falling back to CD quality on any error), downloads it to a temporary file while fetching the 1280×1280 album cover, and runs FFmpeg to copy the audio into `<Title>.flac` (or `<Title>.m4a` when TIDAL has no lossless master) with tags and the embedded cover. It then decode-checks the FLAC and prints `✓ Saved`.

Progress travels back as plain text: the workers print special marker lines (`__TRACK_START__`, `__TRACK_PROGRESS__`, `__TRACK_DONE__`) on standard output, the main process turns them into typed events for the queue rows, and every other line goes into the Activity log. When the helper process ends, the renderer removes downloaded and skipped rows from the queue and saves it again.

### Steps

#### Stage 1: input and routing (renderer)

1. **Trigger** (`renderer/app.js:1284-1285`). Clicking **Add to queue** (`#add-btn`) or pressing Enter in `#url-input` calls `handleInput()` (`app.js:1287-1325`). `input = urlInput.value.trim()`; empty → return silently.
   - `URL_RE = /^https?:\/\/|spotify\.com|tidal\.com/i` (`app.js:66`) only changes the hint text under the field (`app.js:1278-1282`): "Detected a link — will resolve all tracks on add." vs "Type to search TIDAL by song name (or paste a link)." The initial hint (`index.html:43`) is "Paste a Spotify or TIDAL link to add all its tracks. Or type a song name to search." Routing is decided later, in the main process.
   - Enter is never blocked: `setDownloading(true)` disables only `#add-btn` and **Clear all** (`app.js:1361-1372`), so Enter, paste and drop still add rows during a batch.
2. **Sign-in check** (`app.js:1290` → `electron-preload.js:26` → `electron-main.js:610-613`). `invoke('token:exists')` returns `fs.existsSync(process.env.TIDAL_TOKEN_PATH || <source folder>/token.json)`. Packaged builds set `TIDAL_TOKEN_PATH = <userData>/token.json` before `tidal_lib` is loaded (`electron-main.js:19-21`); dev builds use the file next to the source. `false` → log `⚠ Sign in to TIDAL first (Settings → Sign in).` and stop. Only existence is checked, not readability.
3. **Loading overlay** (`app.js:1295-1298`, `showLoading` at `app.js:289-309`). The full-screen `#loading` overlay shows a random line from `FUNNY_LOADING` (`app.js:271-282`, 10 lines), changing every 2.5 s to a different line, plus a **Cancel** button. Cancel → button disabled, text `Cancelling…` → `api.cancelResolve()` (`preload:45`) → `resolve:cancel` sets the single global `resolverCancelled = true` (`electron-main.js:689`). Keyboard focus stays in the text field, so a second Enter starts a second, parallel resolve.
4. **Resolve call** (`preload:44` → `electron-main.js:658-687`). `invoke('resolve:input', { input })`. Main sets `resolverCancelled = false`, then:
   - `cred = lib.loadCred()` (`tidal_lib.js:48-60`): reads `token.json`, accepts an array or a single object, returns `entries[0]`. Missing file or empty array → `console.error(...)` + `process.exit(1)`, which **ends the whole Electron app** when it runs in the main process. A JSON parse error throws normally and is caught.
   - `token = await lib.getToken(cred)` (`tidal_lib.js:97-102`): uses `access_token` if `Date.now() < expires_at`, otherwise `refreshToken` (step 5).
   - `country = await lib.getCountryCode(cred)` (`tidal_lib.js:104-119`): `cred.countryCode` if present (normally set at sign-in); else `GET /v1/users/{userID}?countryCode=US`, saves the result, falls back to `'US'` on any failure.
   - `parsed = lib.parseInputUrl(input)` (step 6). Parsed → `resolveUrlToTracks`; otherwise → `searchTracksForQueue`.
5. **Token refresh** (`tidal_lib.js:70-95`). `POST https://auth.tidal.com/v1/oauth2/token`, form body `client_id=<cred.client_ID>&refresh_token=…&grant_type=refresh_token&scope=r_usr%2Bw_usr%2Bw_sub` (the `+` signs are percent-encoded by `formEncode`, so the server receives the literal string `r_usr+w_usr+w_sub`), HTTP Basic auth `client_ID:client_secret`, 30 s timeout, no retry. 200 → `access_token` replaced, `expires_at = now + (expires_in || 3600)·1000 − 60 000`, `countryCode` copied from `json.user.countryCode` if it was missing, then `saveCred` merges into `entries[0]` and rewrites the whole file with `writeFileSync` (4-space JSON, not atomic). Any `refresh_token` in the response is ignored. Non-200 → `Token refresh failed: <status> <body>`.
6. **Input parsing** (`tidal_lib.js:457-463`), first match wins:
   1. Spotify: `/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i` → `{ source:'spotify', type, id }`.
   2. TIDAL: `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i` (any subdomain, e.g. `listen.tidal.com`). This is a search anywhere in the string, so the first `track|album|playlist` segment wins: a link of the form `…/album/<A>/track/<T>` resolves to the **album**.
   3. Whole input `/^\d+$/` → TIDAL track ID (so a search for the song "1999" becomes a track-ID lookup).
   4. Whole input is a UUID (`8-4-4-4-12` hex) → TIDAL playlist.
   5. Otherwise `null` → free-text search. Other link types (TIDAL artist/mix/video, Spotify artist, `spotify:` URIs, `spotify.link` short links, `open.spotify.com/embed/...`) also fall through to a text search for the raw link text.

#### Stage 2: resolve, by input type (main process, `tidal_lib.js`)

All TIDAL API calls go through `tidalGet` (`tidal_lib.js:156-168`) → `httpsRequest` (`tidal_lib.js:129-154`): host `api.tidal.com`, headers `Authorization: Bearer <token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`; query keys are not encoded, values use `encodeURIComponent`; 30 s timeout; **no retry**; redirects not followed. The response body is built with `d += c` on raw Buffer chunks (`tidal_lib.js:145`), see Bugs.

A row built from a TIDAL track object is `tidalEntry(t)` (`tidal_lib.js:321-329`): `{ tidalId: t.id, title: t.title, artist: t.artists[].name joined ', ', duration: t.duration (s), source:'tidal', matchMethod:'direct', hiRes: t.mediaMetadata.tags includes 'HIRES_LOSSLESS' }`.

7. **TIDAL track** (`tidal_lib.js:333-335`, `236-240`): `GET /v1/tracks/{id}?countryCode=CC` → one `tidalEntry`. Non-200 → `Track info failed: <status> <body>`.
8. **TIDAL album** (`tidal_lib.js:336-338`, `248-262`): `GET /v1/albums/{id}/items?countryCode=CC&limit=100&offset=N`, `offset += 100` until a page returns fewer than 100 `items`. Each item is unwrapped as `i.item || i`, kept if it has an `id` and its `type !== 'video'`, mapped by `tidalEntry`. Non-200 → `Album items failed: <status> <body>`.
9. **TIDAL playlist** (`tidal_lib.js:339-341`, `270-284`): same paging on `GET /v1/playlists/{uuid}/items`; `Playlist items failed: …`.
   - After 7–9: if cancelled → `{ tracks: [], cancelled: true }` (`tidal_lib.js:343`); else `enrichWithLibraryStatus(out)` and `{ tracks, capped:false }`.
10. **Spotify** (`tidal_lib.js:348-405`). `fetchSpotifyEmbed(type, id)` (`tidal_lib.js:474-489`): `GET https://open.spotify.com/embed/{track|album|playlist}/{id}` with `User-Agent` = Chrome 120 on Windows desktop string (`tidal_lib.js:472`), `Accept: text/html` (still `Accept-Encoding: identity`), 30 s, redirects not followed. Non-200 → `Spotify <type> embed failed: HTTP <n>`. The body is regex-matched for `<script id="__NEXT_DATA__"…>(…)</script>`; missing → `No __NEXT_DATA__ in Spotify <type> embed`. `JSON.parse`, then `props.pageProps.state.data.entity`; missing → `Unexpected Spotify embed shape for <type>/<id>`.
    - Track (`505-515`): `{ id: e.id||id, name: e.name||e.title, artists: e.artists[].name or splitArtists(e.subtitle), duration_ms: e.duration, external_ids:{}, album:null }`.
    - Album (`517-530`): `entity.trackList[]` → `{ id: uri 'spotify:track:<ID>' → ID, name: t.title, artists: splitArtists(t.subtitle) or the album artists, duration_ms: t.duration }`.
    - Playlist (`532-551`): same mapping without the album-artist fallback; `_embedCapped = tracks.length >= 100` (a playlist of exactly 100 tracks also warns).
    - `splitArtists` splits on commas not inside parentheses (`/,(?![^(]*\))/`), trims, drops empties.
    - Cancel check (`363`), then **8 workers** pull tracks by index (`365-399`), each checking cancel before taking the next. Per track `spotifyTrackToTidal` (step 11). Success row: `{ title: sp.name, artist: Spotify artists joined ', ', duration: round(duration_ms/1000), source:'spotify', tidalId: match.track.id || null, matchMethod: match.method || null, notFound: !match, hiRes }`. If the lookup throws (429, timeout, 5xx), the row is `{ title, artist, duration, source:'spotify', tidalId:null, notFound:true }` with no retry. Original order is kept; holes left by a cancel are filtered (`402`). Cancel check (`400`), `enrichWithLibraryStatus`, `{ tracks, capped }`.
11. **Spotify → TIDAL match** (`tidal_lib.js:558-611`).
    - ISRC first if `external_ids.isrc` exists (`GET /v1/tracks?isrc=…&countryCode=CC`, first item, method `'isrc'`). The embed never provides ISRCs, so this branch never runs.
    - Otherwise `GET /v1/search/tracks?query=<title + ' ' + artists joined by spaces>&limit=10&countryCode=CC`. Non-200 throws `Search failed: …`.
    - `norm(s)` = lowercase, every character outside `[a-z0-9 ]` → space, collapse spaces, trim (so accented and non-Latin letters vanish).
    - Per result: `titleScore` 100 if equal; 50 if either `startsWith` the other; 25 if either `includes` the other; else 0. `artistScore` = round(100 × share of wanted-artist tokens longer than 2 characters found as substrings of the result's joined, normalized artist names); 0 if there are no such tokens (e.g. "U2"). `durationScore` = 50 if |diff| < 3 s, 25 if < 8 s, else 0.
    - Accept if `titleScore === 100` or (`titleScore >= 25` and `artistScore >= 50`); sort by total descending (stable, so ties keep TIDAL's order); first wins with method `'search'`.
12. **Free-text search** (`electron-main.js:680-683`; `tidal_lib.js:412-426`): `GET /v1/search/tracks?query=<input>&limit=10&countryCode=CC` → rows `{ tidalId, title, artist, album: t.album.title || '', duration, hiRes, source:'tidal', matchMethod:'search' }` → `enrichWithLibraryStatus`. The cancel flag is only checked after the request returns (`electron-main.js:682`).
13. **CSV / pasted tracklist** (adjacent input path; `app.js:1763-1939` → `electron-main.js:919-982`). Drop or pick a `.csv/.txt` on `#drop-zone`, or paste ≥ 10 characters containing a newline, a comma, or ` - `/` — `/` – `/` | ` while no input/textarea is focused. `parseTracklistText`: if the first non-empty line has a comma and there are ≥ 2 lines, parse as CSV (quoted fields, `""` escapes); title column = first header matching `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/`, artist column = first header containing `artist`; otherwise each line is split by `/^(.+?)\s*[-—–|\t]\s*(.+)$/` into title/artist (titles shorter than 2 characters dropped); duplicates by lowercased `title|artist` dropped. **No sign-in check** before `invoke('resolve:tracklist')`. Main resolves **one search at a time** with the same scoring as step 11 minus the duration score, sends `tracklist:progress {done,total}` (overlay text `Matching N / M tracks on TIDAL…`), and returns rows `{ title: pick.title || t.title, artist: TIDAL artists joined ', ' (or the imported artist), duration: pick.duration || 0, tidalId, source:'import', matchMethod, notFound, originalTitle, originalArtist }` — note: **no `hiRes` field**. Search errors → `{ title, artist, tidalId:null, source:'import', notFound:true }`. Log: `📋 Parsed N track(s) from <name>. Matching against TIDAL…`, then `+ Added N from import. M matched on TIDAL, K not found.`

#### Stage 3: library tagging (main process)

14. **Library scan** (`tidal_lib.js:674-757`). `scanLibrary()` returns the cached result; if a scan is in flight it returns that scan's promise. Started at launch when a library folder is set (`electron-main.js:481-485`) and when the folder changes (`electron-main.js:42-52`). The scan: if `LIBRARY_PATH` is empty or missing → no entries. Otherwise a **synchronous** recursive `readdirSync` walk in the main process (directories and regular files only — symlinks are skipped) collecting extensions `.flac .m4a .mp3 .wav .aac .ogg .opus .alac` (macOS `._*` AppleDouble files with those extensions are included too); then 8 workers read tags with `music-metadata` (`{ duration:true, skipCovers:true, skipPostHeaders:true }`): `title`, `artist` (or `artists[0]`), rounded `duration`. Tag-read failures fall back to the filename. Entries are pushed in completion order, so their order differs between scans. Progress `library:scan-progress {done,total}` about every 25 files.
15. **Per-row lookup** (`tidal_lib.js:788-844`). `enrichWithLibraryStatus` walks the rows one after another and calls `findInLibrary(title, artist, duration)` (duration unused). Returns `null` when the title is empty, the library is empty, or the normalized "core" title is shorter than 3 characters (so titles like "22" or "Go" are never checked). With `tFull = normalizeFull(title)`, `tCore = normalizeCore(title)`, `aFull = normalizeFull(artist)`:
    1. any entry with `metaTitleFull === tFull` **and** artists agree (both non-empty and one contains the other) → `exact`;
    2. any entry with `metaTitleFull === tFull` → `similar`;
    3. any entry with `fnTitleFull === tFull` or `fnFull === tFull` → `similar`;
    4. any entry with `metaTitleCore === tCore`, or `fnTitleCore`/`fnCore === tCore` (checked together per entry) → `similar`.
    The first matching entry in scan order wins. Result `t.libraryMatch = { kind, path, libraryTitle }` where `libraryTitle` is the tag title, or the file's basename for filename matches. Per-row errors are swallowed.
    - `normalizeFull` (`626-629`): lowercase, non-`[a-z0-9 ]` → space, collapse, trim.
    - `normalizeCore` (`635-653`): lowercase; cut at the first `(` or `[` only if it is not at index 0; strip `\s+(feat|ft|featuring)\.?\s+.*$`; strip `\s+-\s+(remix|edit|mix|extended|radio|original|instrumental|acoustic|live|remaster(ed)?|version|club|vip|dub|bootleg|rework|reprise|demo|single|album)\b.*$`; then as `normalizeFull`.
    - Filename title = the part after the last `' - '` in the basename without extension.
16. **Reply** (`electron-main.js:670-686`): `{ ok:true, kind:'url', tracks, capped }` | `{ ok:true, kind:'search', tracks }` | `{ ok:false, cancelled:true }` | `{ ok:false, error }`.

#### Stage 4: into the queue (renderer)

17. **Handle reply** (`app.js:1300-1324`). `hideLoading()`. Cancelled → `⊗ Resolve cancelled.`; error → `✗ <error>`. URL kind → `addTracksToQueue`, log `+ Added N track(s) from link (M not on TIDAL).` (the bracket only when M > 0; N counts rows actually added after de-duplication); if `capped` also `⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren't included.`; clear the field. Search kind → step 18.
18. **Search dialog** (`app.js:1329-1357`). Title `Search results for "<query>"`, hint `N result(s). Pick the ones to add to your queue.`, one checkbox row per result: title + Hi-Res badge, `artist · album · m:ss`. The dialog does not show library status. **Add selected** with nothing ticked does nothing; otherwise `addTracksToQueue(picks)`, close, log `+ Added N track(s) from search.`, clear the field. **Cancel** / ✕ just close (the text stays).
19. **addTracksToQueue** (`app.js:1255-1272`). De-duplicates against the current queue by `id:<tidalId>`, or `na:<title>|<artist>` when there is no ID. Each new row is pushed as `{ ...t, key: uniqueKey() }` (`Math.random().toString(36).slice(2,10)`). For rows with a `tidalId` that are not `notFound` → `enqueuePreload(tidalId)`. Then `renderQueue()`, and `saveQueueSoon()` if anything was added.
20. **renderQueue** (`app.js:890-1022`) rebuilds the whole list each call.
    - If `t.included === undefined` it becomes `!(libraryMatch.kind === 'exact')` — this also applies to rows the user explicitly picked in the search dialog.
    - Status badge, first match wins: `↓ N%` (downloading), `✓ done`, `⏭ skipped`, `✗ failed`, `not found` (notFound or dlStatus notFound), `📁 already in library` (exact; tooltip = path), `⚠ similar version in library` (similar; tooltip = path), `Spotify`, `Import`, `Spotify ext`. A separate `Hi-Res` badge when `t.hiRes`.
    - `Library: <libraryTitle>` note under exact/similar rows. **+ Add** on excluded rows (`!included && !notFound`). **↻ Retry** on failed rows; a selection checkbox on failed rows that have a `tidalId`. Play button + `canvas.qi-waveform` for rows with a `tidalId` that are not `notFound`.
    - CSS (`styles.css:630-635`) hides only the **waveform** while a row is downloading; the play button stays. Not-found rows hide both (they are not rendered anyway).
    - Main button: `Download (N)` when some rows are excluded or not found, else `Download all`; `Downloading…` during a batch; disabled when nothing is downloadable. Header retry button: `↻ Retry selected (M)` if any failed row is ticked, else `↻ Retry all (N)` when 2+ rows failed, else hidden.
21. **Persist** (`app.js:71-83` → `preload:59` → `electron-main.js:599-606`). `saveQueueSoon` restarts a 400 ms timer; when it fires, it copies the queue without `dlStatus`, `dlPercent`, `selected` and calls `queue:save` → `fs.writeFileSync(<userData>/queue.json, JSON 2-space)`. A `{ ok:false }` reply is ignored; the write is not atomic; nothing flushes a pending save on quit.

#### Stage 5: waveform preloader (runs alongside everything after step 19)

22. (`app.js:730-767`, `672-700` → `preload:50` → `electron-main.js:873-917`). A queue with at most **2** fetches in flight; skips IDs already queued or already in `peaksCache`. `invoke('preview:get-audio', { tidalId })`: main calls `loadCred()` **without a sign-in check**, `getToken`, `getCountryCode`, then `GET /v1/tracks/{id}/playbackinfopostpaywall?countryCode=CC&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`. BTS-family manifest → reject if encrypted (`Track is DRM-encrypted`), no URLs (`No stream URL in manifest`), else `fetchBuffer(urls[0], { timeout:60000, retries:2 })`, `mimeType = json.mimeType || 'audio/flac'`. DASH → inline parser (`electron-main.js:823-853`, same rules as step 31, BaseURL XML-unescaped); no `SegmentTemplate` → fetch BaseURL, `audio/flac`; else init + all segments, 8 at a time, joined, `audio/mp4`. Reply `{ ok:true, audioBytes, mimeType }` | `{ ok:false, error }`. The renderer copies the bytes into an `ArrayBuffer`, `decodeAudioData`, keeps channel 0 only, splits it into 200 equal bars, takes the max |sample| per bar, normalizes so the loudest bar = 1, caches the `Float32Array` (unbounded, memory only) and paints matching canvases. Errors are silent. The whole lossless file is downloaded and copied over IPC for each row; on every launch the restored queue is preloaded again (`app.js:1984-1986`).

#### Stage 6: start the batch

23. **Download all** (`app.js:1419-1454`). Returns silently if a batch is running or the queue is empty. No download folder → warning honk + `⚠ Pick a download folder in Settings first.` `token:exists` false → honk + `⚠ Sign in to TIDAL first (Settings → Sign in).` `downloadable = queue.filter(t => !t.notFound && t.included)`; none → honk + `⚠ Nothing in the queue can be downloaded.` Otherwise: download chime (C5 → G5), `setDownloading(true)` (disables Add and Clear all, shows **Cancel**), an empty log line, `=== Starting batch (N tracks) ===`, each downloadable row `dlStatus='queued'`, `dlPercent=0`, `renderQueue()`, `await api.startBulk({ tracks: downloadable, outDir: settings.downloadFolder })`. The reply is ignored. The download folder is not checked for existence or writability here.
    - Per-row **↻ Retry** (`app.js:1093-1114`) and **Retry all/selected** (`app.js:1397-1417`) call the same `startBulk` with the chosen failed rows; neither checks sign-in. Per-row retry logs `↻ Retrying <title>…` and plays no chime; it refuses during a batch with `⚠ A batch is already running — retry once it finishes.`
24. **bulk:start** (`electron-main.js:986-999`). `activeChild` set → `{ ok:false, error:'Another download is already running.' }`. No `outDir` → `{ ok:false, error:'No download folder configured. Pick one in Settings.' }`. Writes `<userData>/pending-tracklist.json` (`{ tracks, outDir }`, 2-space; the `tracks` are the full queue rows). A throw here (e.g. disk full) rejects the invoke and leaves the renderer showing `Downloading…` forever. Then `spawn(process.execPath, [<app>/bulk_runner.js, listPath], { stdio: ['pipe','pipe','pipe'], env: childEnv() })`, no `cwd`, no `'error'` listener. `childEnv()` (`electron-main.js:60-71`) = `process.env` + `ELECTRON_RUN_AS_NODE=1`, `FORCE_COLOR=0`, `TIDAL_LIBRARY_FOLDER=<settings.libraryFolder || ''>` (re-read from `settings.json`), `BULK_RUNNER_PROGRESS=1`; `TIDAL_TOKEN_PATH` is inherited in packaged builds.
25. **Line routing** (`electron-main.js:1004-1031`). stdout and stderr each have their own buffer, split on `/\r?\n/`, holding back the trailing partial line (never flushed at stream end). `dispatchLine`:
    - `^__TRACK_START__:(\d+)$` → `bulk:track-start { tidalId: Number }`
    - `^__TRACK_PROGRESS__:(\d+):(\d+)$` → `bulk:track-progress { tidalId, percent }`
    - `^__TRACK_DONE__:(\d+):(\w+)$` → `bulk:track-done { tidalId, status }`
    - any other non-empty line → `download:line <line>`; empty lines are dropped.
    None of these sends checks `mainWindow.isDestroyed()`.

#### Stage 7: batch runner (`bulk_runner.js`)

26. (`bulk_runner.js:49-61`). Reads the list; no tracks → `No tracks in list.` exit 1. `loadCred()` (missing token → `token.json not found. Run tidal_auth_node.js first.` exit 1), `getToken` (may refresh and rewrite `token.json`), `getCountryCode`. Any thrown error → `Fatal: <msg>` on stderr, exit 1 (`115-118`). Prints `=== Batch download → <outDir> ===` and `<N> tracks queued.` (each wrapped in blank lines).
27. Loop, strictly sequential (`bulk_runner.js:64-112`): print `[i/N] <title or ?> — <artist or ?>` (the queue's strings). `trackId = t.tidalId`. A title+artist search fallback (`73-90`) and a `__TRACK_DONE__:<id>:notFound` marker (`97`) exist only for rows without a `tidalId`, which the GUI never sends. Print `__TRACK_START__:<trackId>`, run the worker, map its exit code (0 → `downloaded`, 2 → `skipped`, anything else including `null` → `failed`), print `__TRACK_DONE__:<trackId>:<status>` and a blank line.
28. **Worker spawn** (`bulk_runner.js:33-47`): `spawn(process.execPath, [<app>/tidal_download.js, String(trackId), outDir, '--skip-library-check'], { stdio:'inherit', env: { ...process.env, ELECTRON_RUN_AS_NODE:'1', FORCE_COLOR:'0' } })`, no `cwd`; waits for `'close'`. With `'inherit'`, the worker writes straight into main's pipes.
29. After the loop: `=== Batch complete: X downloaded, S skipped, F failed, NF not found ===` and a normal exit with code **0**, whatever the counts (`bulk_runner.js:114`).

#### Stage 8: one track (`tidal_download.js`)

30. **Start** (`tidal_download.js:663-690`). Flags `{ quality:null, concurrency:8, force:false, debug:!!process.env.DEBUG, flacOnly:false, skipLibraryCheck:true }`. `parseInputUrl('<digits>')` → TIDAL track. `outDir = path.resolve(argv[1])`, created with `mkdirSync({ recursive:true })` if missing — this happens **before** `loadCred()`.
31. **downloadTrack** (`tidal_download.js:346-469`):
    1. `getToken` (may refresh), `getCountryCode`, `GET /v1/tracks/{id}?countryCode=CC` → `info`. `artist = sanitize(first artist)`, `title = sanitize(info.title)`, `album = sanitize(info.album.title)`. `sanitize` (`tidal_lib.js:616-618`): falsy → `'unknown'`; `\ / : * ? " < > |` → `_`; whitespace runs → one space; trim. TIDAL's separate `version` field is never read.
    2. **Skip if exists**: `<outDir>/<title>.flac` exists → `  ⏭  <title>.flac already in downloads folder — skipping (use --force to overwrite)`, return skipped; same for `.m4a`. Exit code 2.
    3. Library check skipped (`--skip-library-check`). Log `  <artist> — <title> (<album>)`.
    4. `albumInfo = GET /v1/albums/{info.album.id}?countryCode=CC` (non-200 → `null`).
    5. **getBestManifest** (`325-342`): `GET /v1/tracks/{id}/playbackinfopostpaywall?countryCode=CC&audioquality=HI_RES_LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`; **any** error (401 → `Unauthorized — token may be invalid`, other non-200 → `Playback info failed: …`, timeout) → same request with `LOSSLESS`; both fail → `Could not get playback manifest at any quality.` (the underlying reasons are printed only with `--debug`). Keeps `{ manifest (base64), manifestMimeType, audioQuality }`.
    6. **parseManifest** (`107-169`), manifest base64 → UTF-8:
       - `manifestMimeType` starts with `application/vnd.tidal.` (BT/BTS): JSON; `encryptionType` present and not `NONE` → `Track is DRM-encrypted (<type>)`; no `urls` → `BT-family manifest (<mime>) had no urls field: <first 200 chars>`; else `{ type:'direct', mimeType: json.mimeType, url: urls[0], codec: json.codecs }`.
       - `application/dash+xml`: `BaseURL` text; if the document has no `SegmentTemplate` and a BaseURL → `{ type:'direct', url: BaseURL (not XML-unescaped), mimeType:'audio/flac' }`. Else first `initialization="…"`, `media="…"` (both required, else `Could not parse MPEG-DASH segment template.`), first `mimeType="…"` (default `audio/flac`), first `codecs="…"`, `startNumber` (default 1); each self-closing `<S …/>` adds `r+1` consecutive segment numbers (`r` default 0); none → `No segments found in MPEG-DASH manifest.` BaseURL/init/media are XML-unescaped (`&amp; &lt; &gt; &quot; &apos;`).
       - Anything else → `Unknown manifest type: <mime>`. No manifest → `No manifest in playback response`.
    7. **Output format**: FLAC if `audioQuality ∈ { LOSSLESS, HI_RES_LOSSLESS, HI_RES }`, or `codec` contains `flac` (case-insensitive), or the decoded manifest contains `codecs="flac"`. Otherwise log `  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).` (or with `--flac-only`, `AacOnlyError`; never in the GUI). `finalPath = <outDir>/<title>.flac|.m4a`; `tmpPath = <outDir>/<title>.tmp.m4a` if the manifest `mimeType` contains `mp4`, else `.tmp.flac`.
    8. **Progress markers** (`433-442`, only when `BULK_RUNNER_PROGRESS` is set): `__TRACK_PROGRESS__:<trackId>:<0-100>`, clamped, printed only when the integer value changes.
    9. **Audio and cover in parallel** (`445-451`):
       - DASH (`173-208`): `fetchBuffer(baseUrl + init)` first; then `min(8, n)` workers fetch `baseUrl + media` with the first `$Number$` replaced; progress = `floor(done/n × 100)` per finished segment; everything is held in memory and written once: `writeFileSync(tmpPath, init + segments)`. One segment failing after retries fails the track (nothing written).
       - Direct (`215-256`): streaming GET, `User-Agent: okhttp/5.3.2`, follows 301/302/303/307/308 up to 5 (`Too many redirects`), non-200 → `HTTP <n> for <url>`, piped to `tmpPath`; progress = bytes / `Content-Length` (stays 0 when the length is unknown), then 100 when the file is closed; 60 s socket-idle timeout → `Download timed out`; **no retry**, no size check, a partial `tmpPath` is left behind on error.
       - Cover (`tidal_lib.js:846-857`): `https://resources.tidal.com/images/<album.cover with every '-' → '/'>/1280x1280.jpg` via `fetchBuffer(url, { retries:1 })`; any failure or no cover ID → `null` (file gets no picture).
    10. **FFmpeg remux** (`275-310`), see External interfaces for the exact arguments. Cover bytes go to FFmpeg's stdin; stdout ignored; stderr captured. Failure → stderr `  ✘ FFmpeg failed: ffmpeg exited <code>: <last 500 chars of stderr>`, stdout `     Raw file kept at: <tmpPath>`, rethrow. Success → delete `tmpPath` (errors ignored).
    11. **Integrity check** (FLAC only, `313-321`): `ffmpeg -v error -i <final> -f null -` (a full decode). Failure → `  ⚠ FLAC integrity check failed: <last line of the error>`, file kept, track still counts as downloaded.
    12. `statSync` → `  ✓ Saved: <file name> (<bytes/1048576 to 1 decimal> MB)`.
32. **Exit** (`tidal_download.js:715-724`): saved → 0; skipped → `process.exitCode = 2`; any error → `console.error('\nError:', msg)` (shown as `Error: <msg>`) then `process.exit(1)`.

#### Stage 9: progress and completion (renderer)

33. **Per-track events** (`app.js:1225-1245`; `preload:39-41`). `track-start` → row `dlStatus='downloading'`, `dlPercent=0`, full `renderQueue()`. `track-progress` → `item.dlPercent` and an in-place update of that row's `↓ N%` badge and `.qi-progress-fill` width (`app.js:1052-1059`). `track-done` → `dlStatus = status`; `dlPercent = 100` when downloaded; full `renderQueue()`. Rows are matched by `queue.find(t => t.tidalId === tidalId)`; rows removed mid-batch are ignored.
34. **Activity log** (`app.js:1456`, `330-359`): each `download:line` is appended with a class from `classify()`: `ok` (`^\s*✓ Saved`), `error` (`^\s*✘`, `✗ `, `Error:`, `FFmpeg failed`), `warning` (`^\s*⚠`), `skip` (`^\s*⏭`, `📁 Already in library`), `warning` (`^\s*ℹ`), `header` (`^===`), `summary` (`complete:` — never reached for the batch summary, which starts with `===`), `muted` (`[debug]`). The log keeps at most 2000 elements, never trimming the welcome line.
35. **Batch bar** (`app.js:1026-1048`), shown only during a batch: total = **all** queue rows with `included && !notFound`; done = those whose `dlStatus` is downloaded/skipped/failed/notFound; width `floor(done/total × 100)%`, label `done / total`.
36. **Child closes** (`electron-main.js:1033-1040`): send `download:done { code }` (number, or `null` when killed by a signal), `activeChild = null`, delete `pending-tracklist.json`, resolve `{ ok: code === 0, code }`.
37. **onDownloadDone** (`app.js:1457-1482`): `setDownloading(false)`. `code === 0` → success ping (G5 → C6 → E6 bells) and a `✓ Batch finished.` row with an **Open folder** button (`shell.openPath(downloadFolder)`). Otherwise `=== Exit code <code> ===`. Then the queue keeps only rows that are `notFound`, `dlStatus === 'failed'`, `dlStatus === 'notFound'`, or (no `dlStatus` **and** `included`). `dlStatus`/`dlPercent` are cleared on kept rows that are not failed/notFound. `renderQueue()`, `saveQueueSoon()`.
38. **Saved state**: `queue.json` now holds the remaining rows. Failed rows are saved without `dlStatus`, so after a restart they come back as ordinary included rows (no Retry button), and the preloader fetches them again.

#### Cancel during a batch

39. (`app.js:1374-1392` → `electron-main.js:646-653`). Cancel chime (G5 → C5), button `Cancelling…`, `download:cancel` → `activeChild.kill()` (SIGTERM to `bulk_runner` only) and `activeChild = null` immediately. The renderer then marks every `queued`/`downloading` row `failed` (`dlPercent=0`) and logs `⊗ Download cancelled.` `isDownloading` stays true until `download:done` arrives (later reported as `=== Exit code null ===`). The running `tidal_download` is not signalled and keeps going (see Bugs).

### Data formats

**`token.json`** (`<userData>/token.json` packaged, `<source>/token.json` dev). JSON array, 4-space indent, written by `tidal_auth_node.js:53-59` and `tidal_lib.js:62-68`:

```json
[
  {
    "access_token": "<string>",
    "refresh_token": "<string>",
    "userID": 12345,
    "countryCode": "US",
    "expires_at": 1767225600000,
    "client_ID": "<REQUEST client id>",
    "client_secret": "<REQUEST client secret>"
  }
]
```

`expires_at` is ms since epoch with 60 s already subtracted. `tidal_auth_node.js:17-20` holds two different client id/secret pairs as base64 string literals decoded at load time (values not reproduced): the AUTH pair runs the device-code sign-in; the REQUEST pair is what gets stored in each entry and used for refreshes. Only `entries[0]` is ever read or updated by `tidal_lib`.

**`settings.json`** (`<userData>`): `{ "downloadFolder": string, "libraryFolder": string, "volume": number 0–1 }` — the renderer saves its whole `settings` object.

**Queue row** (in memory, `queue.json`, and `pending-tracklist.json`):

| Field | Type | Set by | Notes |
|---|---|---|---|
| `tidalId` | number \| null | resolver | `null` only when `notFound` |
| `title`, `artist` | string | resolver | TIDAL strings for TIDAL/import rows; Spotify strings for Spotify rows; artists joined `', '` |
| `duration` | number (s) | resolver | 0 for unmatched import rows |
| `source` | `'tidal'` \| `'spotify'` \| `'import'` (\| `'extension'`) | resolver | drives the badge |
| `matchMethod` | `'direct'` \| `'search'` \| `'isrc'` \| null | resolver | absent on failed-lookup rows |
| `hiRes` | boolean | resolver | absent on import rows and failed-lookup rows |
| `album` | string | search only | shown in the search dialog |
| `notFound` | boolean | Spotify/import | |
| `originalTitle`, `originalArtist` | string | import | |
| `libraryMatch` | `{ kind:'exact'\|'similar', path, libraryTitle }` | main | absent when no match |
| `key` | 8-char base36 | renderer | row identity |
| `included` | boolean | renderer | default `!(libraryMatch.kind==='exact')` |
| `dlStatus` | `'queued'\|'downloading'\|'downloaded'\|'skipped'\|'failed'\|'notFound'` | renderer | not persisted |
| `dlPercent` | 0–100 | renderer | not persisted |
| `selected` | boolean | renderer | not persisted |

**`queue.json`**: JSON array (2-space) of rows without `dlStatus`, `dlPercent`, `selected`. Read with `queue:get` (`[]` on any error); on restore the three fields are stripped again and a missing `key` is regenerated (`app.js:1971-1988`).

**`pending-tracklist.json`**: `{ "tracks": [ <full queue rows, dlStatus "queued", dlPercent 0> ], "outDir": "<absolute path>" }`, 2-space; fixed path `<userData>/pending-tracklist.json`; deleted when `bulk_runner` closes.

**IPC used by this flow**

| Channel | Direction | Payload → reply |
|---|---|---|
| `token:exists` | invoke | → boolean |
| `resolve:input` | invoke | `{ input }` → see step 16 |
| `resolve:cancel` | invoke | → `{ ok:true }` |
| `resolve:tracklist` | invoke | `{ tracks:[{title,artist}] }` → `{ ok, tracks }` \| `{ ok:false, error }` |
| `tracklist:progress` | event | `{ done, total }` |
| `preview:get-audio` | invoke | `{ tidalId }` → `{ ok:true, audioBytes, mimeType }` \| `{ ok:false, error }` |
| `queue:get` / `queue:save` | invoke | → array / array → `{ ok }` \| `{ ok:false, error }` |
| `bulk:start` | invoke | `{ tracks, outDir }` → `{ ok: code===0, code }` (or an error object) when the child closes |
| `download:cancel` | invoke | → `{ ok:true }` \| `{ ok:false }` |
| `bulk:track-start` / `-progress` / `-done` | event | `{ tidalId }` / `{ tidalId, percent }` / `{ tidalId, status }` |
| `download:line` | event | string |
| `download:done` | event | `{ code: number \| null }` |
| `library:scan-progress` / `library:scanned` | event | `{ done, total }` / `{ count }` |
| `open-folder` | invoke | path → `shell.openPath` result |

**Marker lines** (stdout, one per line, exact): `__TRACK_START__:<digits>`, `__TRACK_PROGRESS__:<digits>:<digits>`, `__TRACK_DONE__:<digits>:<word>`.

**Exit codes**: `tidal_download` 0 saved / 2 skipped / 1 error; `bulk_runner` 0 after any completed loop / 1 on startup failure / `null` when killed.

### External interfaces

**HTTP**

| Purpose | Request | Notes |
|---|---|---|
| Token refresh | `POST https://auth.tidal.com/v1/oauth2/token` | form body, Basic auth with stored client pair, no retry |
| Country lookup | `GET https://api.tidal.com/v1/users/{userID}?countryCode=US` | only when `countryCode` missing |
| Track info | `GET /v1/tracks/{id}?countryCode=CC` | resolve (TIDAL track) and every download |
| Album info | `GET /v1/albums/{id}?countryCode=CC` | download only; non-200 → null |
| Album items | `GET /v1/albums/{id}/items?countryCode=CC&limit=100&offset=N` | paged |
| Playlist items | `GET /v1/playlists/{uuid}/items?countryCode=CC&limit=100&offset=N` | paged |
| Search | `GET /v1/search/tracks?query=…&limit=10&countryCode=CC` | free text, Spotify match, import |
| ISRC lookup | `GET /v1/tracks?isrc=…&countryCode=CC` | never reached in practice |
| Playback | `GET /v1/tracks/{id}/playbackinfopostpaywall?countryCode=CC&audioquality=HI_RES_LOSSLESS\|LOSSLESS&playbackmode=STREAM&assetpresentation=FULL` | download tries Hi-Res then LOSSLESS; preview uses LOSSLESS |
| Stream | BTS `urls[0]`, or DASH `BaseURL + initialization` / `BaseURL + media($Number$)` | signed CDN URLs from the manifest; `User-Agent: okhttp/5.3.2` only |
| Cover | `GET https://resources.tidal.com/images/<a>/<b>/<c>/<d>/<e>/1280x1280.jpg` | 1 retry |
| Spotify | `GET https://open.spotify.com/embed/{track\|album\|playlist}/{id}` | Chrome UA, HTML scrape |

All `api.tidal.com` calls send `Authorization: Bearer`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, and have a 30 s timeout with no retry. `fetchBuffer` (segments, preview, cover; `tidal_lib.js:174-232`): default 30 s timeout and 3 retries (so up to 4 attempts) with 1 s/2 s/4 s back-off (capped 8 s); retries network errors, timeouts, 429 and 5xx; other non-200 fail at once; follows 301/302/307 up to 5 times, choosing `http`/`https` from the **original** URL only.

**Processes**

```
<Electron binary> <app>/bulk_runner.js <userData>/pending-tracklist.json
  env: ELECTRON_RUN_AS_NODE=1 FORCE_COLOR=0 TIDAL_LIBRARY_FOLDER=… BULK_RUNNER_PROGRESS=1 (+ TIDAL_TOKEN_PATH when packaged)
<Electron binary> <app>/tidal_download.js <tidalId> <outDir> --skip-library-check
  env: inherited + ELECTRON_RUN_AS_NODE=1 FORCE_COLOR=0; stdio inherited from bulk_runner
```

**FFmpeg** (binary = `ffmpeg-static` path with `app.asar` → `app.asar.unpacked` if that file exists, else the original path if it exists, else `ffmpeg` on `PATH`; `tidal_download.js:32-36`). Remux, with a cover:

```
ffmpeg -y -i <tmpPath> -f mjpeg -i pipe:0 -map 0:a -map 1:v -disposition:v attached_pic
       -c:a copy -c:v copy -metadata:s:v "title=Album cover" -metadata:s:v "comment=Cover (front)"
       -metadata title=… -metadata artist=… -metadata album=… -metadata album_artist=…
       -metadata track=… -metadata disc=… -metadata date=… -metadata copyright=… -metadata isrc=…
       <finalPath>
```

Without a cover the `-f mjpeg -i pipe:0`, `-map 1:v …`, `-c:v copy` and both `-metadata:s:v` items are left out. Arguments are passed as an array (no shell quoting). Each `-metadata` is added only when its value is non-empty, in the order shown:

| Tag | Value |
|---|---|
| `title` | `info.title` |
| `artist` | all `info.artists[].name` joined `', '` (fallback `info.artist.name`) |
| `album` | `info.album.title` |
| `album_artist` | `albumInfo.artist.name` → `info.album.artist.name` → first artist |
| `track` | `info.trackNumber` |
| `disc` | `info.volumeNumber` |
| `date` | first 4 characters of `albumInfo.releaseDate` → `info.album.releaseDate` → `info.streamStartDate` |
| `copyright` | `albumInfo.copyright` → `info.copyright` |
| `isrc` | `info.isrc` |

How FFmpeg maps these generic keys to FLAC Vorbis comments or MP4 atoms (and whether `isrc`/`disc` survive in `.m4a`) is FFmpeg's own behaviour; unverified (needs a run). `comment=Cover (front)` makes FFmpeg's FLAC muxer write picture type 3, which strict DJ software (Rekordbox) needs.

Integrity check: `ffmpeg -v error -i <finalPath> -f null -`.

### Constants and magic values

| Name / value | Where | Meaning |
|---|---|---|
| `okhttp/5.3.2` | `tidal_lib.js:14`, `tidal_download.js:220` | User-Agent for TIDAL API and CDN |
| `X-Tidal-Platform: android` | `tidal_lib.js:165` | TIDAL API header |
| 30 000 ms | `tidal_lib.js:15` | default request timeout |
| 3 | `tidal_lib.js:16` | default `fetchBuffer` retries |
| 1000·2^n, max 8000 ms | `tidal_lib.js:186` | retry back-off |
| 5 | `tidal_lib.js:199`, `tidal_download.js:218` | max redirects |
| 60 000 ms | `tidal_lib.js:88` | subtracted from token lifetime |
| 3600 s | `tidal_lib.js:88` | default `expires_in` |
| `r_usr+w_usr+w_sub` | `tidal_lib.js:80` | OAuth scope |
| `'US'` | `tidal_lib.js:108,118` | country fallback |
| 100 | `tidal_lib.js:251,273` | page size for album/playlist items |
| 10 | `tidal_lib.js:298`, `electron-main.js:681` | search result limit |
| 8 | `tidal_lib.js:399` | parallel Spotify→TIDAL matches |
| 100 / 50 / 25 | `tidal_lib.js:588-590` | title scores |
| > 2 chars | `tidal_lib.js:592` | artist token length |
| 3 s → 50, 8 s → 25 | `tidal_lib.js:597` | duration scores |
| `titleScore===100 \|\| (≥25 && artist ≥50)` | `tidal_lib.js:607` | match acceptance |
| ≥ 100 tracks | `tidal_lib.js:549` | Spotify "capped" flag |
| Chrome 120 Windows UA | `tidal_lib.js:472` | Spotify embed fetch |
| `.flac .m4a .mp3 .wav .aac .ogg .opus .alac` | `tidal_lib.js:25` | library file types |
| 8 / 25 files | `tidal_lib.js:744,750` | library tag-read workers / progress throttle |
| core title < 3 chars | `tidal_lib.js:795` | skip library check |
| 2000 | `app.js:54` | Activity log line cap |
| 2500 ms | `app.js:302` | loading text rotation |
| 400 ms | `app.js:82` | queue save debounce |
| 2 | `app.js:558` | waveform preload concurrency |
| 200 bars | `app.js:686` | waveform resolution |
| 3 | `app.js:549` | cached playable previews (LRU) |
| 60 000 ms, 2 retries | `electron-main.js:858,866,891,903` | preview fetches |
| `HI_RES_LOSSLESS`, `LOSSLESS` | `tidal_download.js:39` | quality order |
| `LOSSLESS`, `HI_RES_LOSSLESS`, `HI_RES` | `tidal_download.js:401` | tiers treated as FLAC |
| 8 | `tidal_download.js:38` | segment workers |
| 60 000 ms | `tidal_download.js:252` | direct-download idle timeout |
| 1280×1280 | `tidal_lib.js:846` | cover size |
| 500 chars | `tidal_download.js:267` | FFmpeg stderr kept in the error |
| `Z:\Downloads` | `tidal_download.js:40` | CLI-only default folder (unused by the GUI) |
| 0 / 2 / other | `bulk_runner.js:107-109` | exit code → downloaded / skipped / failed |
| `pending-tracklist.json`, `queue.json`, `settings.json`, `token.json` | `electron-main.js:20,26-27,991` | files in userData |

### Rules and invariants

- The main process decides routing; the renderer's URL regex only changes hint text.
- Every resolved row carries its library status before it reaches the renderer; the queue, not the download worker, decides what is downloaded (the worker always gets `--skip-library-check`).
- Exact library matches start excluded; similar matches start included with a warning badge. The library folder is only ever read.
- Downloads are sequential, one track at a time; each track is a fresh process that re-fetches everything by TIDAL ID. Queue strings are display-only; the file uses TIDAL's metadata.
- Files go flat into the download folder as `<sanitized TIDAL title>.flac` (or `.m4a`); no artist or track number; no subfolders. An existing `.flac` **or** `.m4a` with the same name means "skip", even if it is a different song (including two different tracks with the same title in one batch; on case-insensitive APFS, titles that differ only in case also collide).
- Quality: ask for `HI_RES_LOSSLESS`, fall back to `LOSSLESS`; write FLAC whenever TIDAL labels the stream lossless; otherwise `.m4a` with the same tags and cover.
- The cover is never written to disk separately; it is piped to FFmpeg.
- After a batch, downloaded and skipped rows leave the queue; failed and not-found rows stay.

### Edge cases and failure modes

| Where | What happens | User sees | Left on disk |
|---|---|---|---|
| `tidal_lib.js:48-58` via CSV import (`app.js:1830-1843` → `electron-main.js:925`) or preview (`electron-main.js:875`) | `loadCred()` → `process.exit(1)` in the main process when `token.json` is missing/empty | App disappears with no message (e.g. dropping a CSV before signing in; launching with a saved queue but no token, as in a dev build whose token lives next to the source) | Nothing new |
| `tidal_lib.js:70-95` | Refresh fails | `✗ Token refresh failed: <status> <body>` | — |
| `tidal_lib.js:236-302` | Bad ID, region lock, 401 | `✗ Track info failed: …` / `✗ Album items failed: …` / `✗ Search failed: …` (numeric search text lands here) | — |
| `tidal_lib.js:474-489` | Spotify page changed, redirected or blocked | `✗ Spotify playlist embed failed: HTTP n` / `✗ No __NEXT_DATA__ …` / `✗ Unexpected Spotify embed shape …` | — |
| `tidal_lib.js:375-396` | One Spotify match throws (429/timeout) or nothing passes the rule | `not found` row, no retry; log `(M not on TIDAL)` | row in `queue.json` |
| `bulk_runner.js:56-58,115-118` | Token missing/unreadable or refresh fails at batch start | `token.json not found…` or `Fatal: <msg>`, then `=== Exit code 1 ===`; **every row of the batch disappears** | `queue.json` rewritten without them; list file deleted |
| `tidal_download.js:355-366` | `<Title>.flac`/`.m4a` exists | `⏭ … already in downloads folder — skipping …`; row `⏭ skipped`, then removed | existing file untouched |
| `tidal_download.js:325-342` | Playback refused at both tiers | `Error: Could not get playback manifest at any quality.`; row `✗ failed` | — |
| `tidal_download.js:118-126` | Encrypted or URL-less BTS manifest | `Error: Track is DRM-encrypted (…)` / `Error: BT-family manifest …` | — |
| `tidal_download.js:173-208` | A DASH segment fails after retries | `Error: HTTP 403 for <url>` or a timeout | nothing (segments were in memory) |
| `tidal_download.js:215-256` | BTS download error/timeout | `Error: HTTP n for <url>` / `Error: Download timed out` | partial `<Title>.tmp.flac` |
| `tidal_download.js:454-460` | FFmpeg fails (bad input, disk full, missing binary) | `✘ FFmpeg failed: …`, `Raw file kept at: …`, `Error: …` | `<Title>.tmp.*`; possibly a partial `<Title>.flac` — unverified (needs a run) |
| `tidal_download.js:313-321` | Decode check fails | `⚠ FLAC integrity check failed: …` then `✓ Saved`; row `✓ done` | possibly damaged FLAC, kept |
| `tidal_lib.js:851-857` | Cover fetch fails / no cover ID | nothing | file without picture |
| `tidal_download.js:688` | Download folder on an unmounted volume or not writable | `Error: EACCES …` / `ENOENT …` on every track | nothing, or a newly created folder |
| `tidal_lib.js:616-618` | Title of only whitespace, or starting with `.`; title longer than the 255-byte name limit | file named `.flac` / hidden file; `ENAMETOOLONG` failure | hidden file / nothing |
| `electron-main.js:646-653` | Cancel | `⊗ Download cancelled.`, rows `✗ failed`, later `=== Exit code null ===`; the in-flight track still finishes (its `✓ Saved` may appear) | the finished `<Title>.flac` |
| `electron-main.js:548-551`, `1007-1018`, `1035` (macOS window closed mid-batch) | `bulk_runner` killed; later sends go to a destroyed window | expected main-process error dialog — unverified (needs a run) | orphan's output; list file may remain |
| `electron-main.js:599-606` | `queue.json` write fails | nothing | old or truncated `queue.json` |
| `electron-main.js:992` | `pending-tracklist.json` write throws | UI stuck on `Downloading…` until restart | — |
| `electron-main.js:495,529-546` | FFmpeg binary missing | intended: `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.`; the spawn error likely fires before the page has loaded, so the line is probably lost — unverified (needs a run). Per track: `Error: spawn … ENOENT`, row failed | `<Title>.tmp.*` after each attempt |
| `tidal_lib.js:687-698` | Library on a slow/network volume, or very large | main process blocked during the synchronous folder walk; first resolve waits for the whole tag scan with no progress on the overlay | — |
| Library contains `._Song.flac` AppleDouble files | tag read fails, filename `._Song` normalizes to `song` | spurious `⚠ similar version in library` pointing at the `._` file | — |

### Bugs and oddities

1. **Queue rows silently deleted when a batch ends without per-track results** — Medium. `app.js:1447-1450` marks rows `queued`; `app.js:1468-1473` keeps only `notFound`, `failed`, or no-`dlStatus`-and-included rows. If `bulk_runner` exits before its loop (`bulk_runner.js:56-58`, `115-118`: missing token, refresh failure) or crashes mid-loop, every row still `queued`/`downloading` is dropped and `saveQueueSoon()` writes that to `queue.json`. The per-row and Retry-all paths reach this too, since they never check sign-in.
2. **Main process exits through `loadCred()`** — Medium. `tidal_lib.js:49-57` calls `process.exit(1)`; it runs inside IPC handlers at `electron-main.js:661, 702, 875, 925`. `handleInput` and Download all check `token:exists` first, but `handleTracklistInput` (`app.js:1830-1843`) and the preloader (`app.js:730-767`, run at boot for a restored queue at `app.js:1984-1986`) do not.
3. **Re-authenticating has no effect when an entry already exists** — Medium. `tidal_auth_node.js:53-59` removes only entries with the same `client_ID` **and** `refresh_token`, then appends the new entry at the end; `tidal_lib.js:59` always reads `entries[0]` and `tidal_lib.js:66` updates `entries[0]`. A new sign-in issues a new refresh token, so the old first entry stays in use. If it was revoked or expired, **Re-authenticate** cannot fix it; signing into a different account is ignored.
4. **UTF-8 text can be corrupted in API responses** — Low–Medium. `httpsRequest` builds the body with `res.on('data', c => d += c)` on raw Buffers without `setEncoding` (`tidal_lib.js:144-146`), so a multi-byte character that straddles two chunks becomes two `U+FFFD` characters. Large responses (album/playlist pages, search, the Spotify embed HTML) span many chunks, so accented or non-Latin titles/artists in the queue can be garbled, which also affects library matching and the `na:` de-dupe key. The per-download track-info response is small and usually one chunk, so filenames and tags are rarely affected (frequency unverified, needs a run). `tidal_auth_node.js:26` and `electron-main.js:128` use the same pattern.
5. **Cancel does not stop the track being downloaded** — Low–Medium. `electron-main.js:648` signals only `bulk_runner`; `tidal_download` (`bulk_runner.js:41-45`, non-detached, `stdio:'inherit'`) is not signalled and keeps downloading, remuxing and writing `<Title>.flac` while the row shows `✗ failed`; a later Retry then reports it as skipped. Because the orphan still holds the inherited stdout/stderr pipes, the `'close'` event (and so `download:done`) is probably delayed until it finishes, keeping **Cancel** at `Cancelling…` — unverified (needs a run).
6. **Window closed mid-batch on macOS** — Low–Medium. `window-all-closed` (`electron-main.js:548-551`) kills `bulk_runner` but does not quit on macOS, and `mainWindow` is never cleared. Later `dispatchLine` sends and the close handler (`electron-main.js:1007-1018, 1035`) call `mainWindow.webContents.send` without `isDestroyed()` checks. If that throws (expected for a destroyed window; unverified, needs a run), lines 1036-1038 never run: `activeChild` stays set, `pending-tracklist.json` stays, and after reopening the window every **Download all** is refused by main (`Another download is already running.`), a reply the renderer ignores, leaving it on `Downloading…` until the app restarts. If a new window already exists when `'close'` fires, that fresh window receives `download:done` and runs the post-batch filter on its restored queue (dropping excluded rows).
7. **Success ping and `✓ Batch finished.` even when every track failed** — Low. `bulk_runner.js:114` never sets a non-zero exit code from its counters; `app.js:1459-1461` treats code 0 as success.
8. **A transient error on the Hi-Res request gives a 16-bit file** — Low. `tidal_download.js:328-340` catches any error (timeout, 429, 5xx; `tidalGet` has no retry) and moves to `LOSSLESS`, against the "highest lossless" rule; the queue's Hi-Res badge is not re-checked.
9. **Library cache can keep an old folder's scan** — Low. `setLibraryPath` (`tidal_lib.js:28-31`) clears `_libraryCache` but not `_libraryScanPromise`, so a call during a running scan gets the old folder's result and caches it (`tidal_lib.js:676, 754`). After **Refresh** (`rescanLibrary`, `760-763`) an older scan that finishes later overwrites the new cache and clears the new scan's promise (`754-755`), which can start a third scan. Duplicate checks then use the wrong library until restart.
10. **Batch counter counts rows that are not in the batch** — Low. `app.js:1028-1038` uses every `included && !notFound` row as the total, and counts left-over `failed` rows from earlier batches as done. A single-row retry, a selected-rows retry, or rows added mid-batch show e.g. `2 / 8` and never reach 100%.
11. **Excluded rows vanish after any batch** — Low. Exact-match rows the user left excluded have no `dlStatus` and `included === false`, so `app.js:1468-1473` drops them, even after a single-row retry that never touched them.
12. **Partial files left in the download folder** — Low. Direct downloads leave `<Title>.tmp.flac` on error (`tidal_download.js:215-256`); FFmpeg failures keep the tmp file on purpose (`454-460`). If FFmpeg leaves a partial `<Title>.flac` (unverified, needs a run), every retry skips it as "already in downloads folder" (`355-366`).
13. **Numeric search text becomes a track-ID lookup; bare UUIDs become playlists** — Low. `tidal_lib.js:439, 442`. Searching "1999" or "22" fails with `Track info failed: 404` or adds an unrelated track.
14. **Some links resolve wrongly or not at all** — Low. `tidal_lib.js:435` takes the first `track|album|playlist` segment, so `…/album/<A>/track/<T>` adds the whole album. Unsupported link shapes (TIDAL artist/mix/video, Spotify artist, `spotify:` URIs, `spotify.link`, `/embed/` links) fall through to a text search for the raw link while the hint says "Detected a link".
15. **TIDAL `version` field ignored** — Low. Only `info.title` is used (`tidal_download.js:352`, `278`; `tidal_lib.js:323`); `version` is never read. Two versions of a song on one album (e.g. original and remaster) would map to the same `<Title>.flac`, and the second is skipped. Depends on TIDAL keeping version text in that field; unverified against live data (needs a run).
16. **Rate-limited Spotify matches become permanent `not found` rows** — Low. 8 parallel searches with no retry (`tidal_lib.js:365-399`); any error → `notFound:true`, and not-found rows get no Retry.
17. **Video filter may test the wrong object** — Low, unverified. `tidal_lib.js:338, 341` unwrap `i.item || i` before testing `t.type !== 'video'`; TIDAL's items response normally carries `type` on the wrapper. Whether inner video objects carry `type === 'video'` is unverified (needs a run); if not, videos are queued and later fail.
18. **Waveform preload downloads the full lossless file for every row** — Low. `app.js:730-767`, `electron-main.js:873-917`: 30–150 MB per row for 200 numbers, copied across IPC, repeated on every launch, competing with the batch for bandwidth and TIDAL rate limits.
19. **Non-atomic writes, uncoordinated refreshes, no single-instance lock** — Low. `queue.json`, `settings.json`, `token.json`, `pending-tracklist.json` are rewritten in place (`electron-main.js:44, 601, 992`; `tidal_lib.js:67`; `tidal_auth_node.js:58`). Main and each child refresh the token independently, so a reader can catch a half-written `token.json` (timing unverified). No `requestSingleInstanceLock`: two instances share every file, and one instance's close handler deletes the other's list file.
20. **Second Enter during the overlay starts a parallel resolve** — Low. Focus stays in `#url-input` (`app.js:1285`); `resolve:input` resets the one shared cancel flag (`electron-main.js:659`), the first reply hides the overlay while the second is still running, and both results are added.
21. **DASH "direct" BaseURL is not XML-unescaped in the downloader** — Low. `tidal_download.js:134` uses the raw BaseURL, while the preview path unescapes it (`electron-main.js:826`); a BaseURL containing `&amp;` would be requested literally.
22. **Spotify cap warning at exactly 100 tracks** — Oddity. `tidal_lib.js:549` uses `>= 100`.
23. **Imported rows never show Hi-Res** — Oddity. `electron-main.js:961-971` omits `hiRes` (the extension path at `737` sets it).
24. **Picked search results arrive excluded** — Oddity. A ticked result that exactly matches the library gets `included = false` at `app.js:901` and needs a second **+ Add** click.
25. **Spotify rows show Spotify metadata; files use TIDAL's** — Oddity. `tidal_lib.js:377-386` vs `tidal_download.js:350-352`. Library matching, de-dupe and log labels use Spotify strings; the file name and tags use TIDAL's.
26. **Library entry order is not fixed** — Oddity. Entries are pushed when each tag read completes (`tidal_lib.js:730`), so when several files match, the reported file can change between scans.
27. **Dead code in the GUI flow** — Oddity. `bulk_runner.js:73-99` (search fallback, `notFound` marker) and `tidal_download.js:490-659` (album, playlist, Spotify modes) are reachable only from the command line.
28. **Preview volume slider shows the squared value after restart** — Oddity, adjacent to this flow. `app.js:1948` sets the slider to `getPreviewVolume() × 100`, which is the squared audio volume, not the saved slider position (saved 0.5 shows as 25).
29. **Inventory only: Chrome extension bridge** — Info. `extension-server.js` (localhost bridge), `electron-main.js:24, 497-522, 691-812`, `electron-preload.js:52-55`, `app.js:1591-1647`, `index.html` Extension tab, `chrome-extension/`. Support ended 21 Oct 2026; not ported. It feeds rows with `source:'extension'` into the same `addTracksToQueue`.

### Platform-specific behaviour

- `app.setName('robogears Downloader')` (`electron-main.js:13`) puts userData at `~/Library/Application Support/robogears Downloader/` on macOS in both dev and packaged builds. `token.json` lives there only when packaged; dev uses the source folder.
- Children run the app's own Electron binary (`process.execPath`, e.g. `…/robogears Downloader.app/Contents/MacOS/robogears Downloader`) with `ELECTRON_RUN_AS_NODE=1`, reading scripts from inside `app.asar`. No `cwd` is passed, on purpose (an asar path cannot be a working directory).
- FFmpeg comes from `ffmpeg-static` unpacked to `app.asar.unpacked`; the path rewrite is required because `spawn` cannot run a file inside the archive.
- macOS: closing the last window does not quit; it kills only `bulk_runner` (Bug 6). Cmd+Q does not emit `window-all-closed` and there is no `will-quit` handler, so `bulk_runner` and the current worker keep running after the app exits; they probably die at their next write to the closed pipe, leaving tmp files — unverified (needs a run).
- Cancel uses SIGTERM (Node's default `kill()`), so the exit code is `null`.
- `sanitize` targets Windows-illegal characters; on macOS `:` is replaced too. APFS is case-insensitive by default, so name collisions are broader than on Windows/Linux.
- The CLI default folder `Z:\Downloads` is Windows-only and unused by the GUI.
- The Spotify request claims to be Chrome 120 on Windows regardless of platform.

### Porting notes for a native Swift macOS app

- **Process model.** Replace the two child-process levels with Swift concurrency: a batch actor that runs tracks one at a time, and per track a task group for up to 8 segment fetches plus the cover. Model the outcome as an enum (`downloaded`, `skipped`, `failed(reason)`, `notFound`) instead of exit codes and stdout markers. Cancel must cancel the URLSession tasks, terminate the FFmpeg `Process`, and delete that track's tmp file (and any partial final file).
- **Routing**, in this order: Spotify regex (with optional `/intl-xx/`), then TIDAL `/(browse/)?(track|album|playlist)/<id>` on any subdomain, then bare digits = track ID, then bare UUID = playlist, else text search. Decide on purpose whether to keep digits-as-ID and whether `album/<A>/track/<T>` should mean the track, and give unsupported link types a clear message instead of searching for the URL.
- **TIDAL client**: send `User-Agent: okhttp/5.3.2`, `X-Tidal-Platform: android`, `Accept: application/json`, `Accept-Encoding: identity`, `Authorization: Bearer`, and `countryCode` on every call; endpoints and paging as in External interfaces. Decode bodies as whole UTF-8 data (fixes Bug 4). Add one retry/back-off policy for API calls (the JS has none there) and keep 429/5xx retries for CDN fetches.
- **Credentials**: device-code sign-in with the AUTH client pair; store the REQUEST pair with the token and use it for refresh (both pairs are base64 literals in `tidal_auth_node.js:17-20`; keep them out of logs and source control in readable form). Refresh: `POST auth.tidal.com/v1/oauth2/token`, Basic auth, scope `r_usr+w_usr+w_sub`, `expires_at = now + expires_in − 60 s`; consider storing a rotated `refresh_token` if TIDAL returns one. Keep **one** current credential that a re-auth replaces (fixes Bug 3), refresh through a single actor, write atomically or use the Keychain, and migrate an existing `token.json` once. Never terminate the app because the token is missing; show "Sign in to TIDAL first" everywhere (fixes Bug 2).
- **Spotify**: `GET https://open.spotify.com/embed/{type}/{id}` with a desktop browser User-Agent; extract the JSON from `<script id="__NEXT_DATA__">`, read `props.pageProps.state.data.entity`; map `trackList[].{uri,title,subtitle,duration(ms)}` (track: `name|title`, `artists|subtitle`, `duration`); split artists on commas outside parentheses; `capped` when ≥ 100 (consider `== 100` only). Fail with a clear message when the shape changes.
- **Matching**: reproduce `norm`, the 100/50/25 title scores, the >2-character artist-token percentage, the 3 s/8 s duration scores (Spotify only), the acceptance rule and the stable sort exactly; 8 at a time for Spotify, keep original order. Decide whether `norm` should keep non-ASCII letters (today "Beyoncé" and Japanese titles lose those characters before comparison).
- **Library index**: walk recursively off the main thread, skip `._*` files, decide on symlinks; read title, artist (or first of artists) and duration. AVFoundation alone may not read Vorbis comments in FLAC/OGG/Opus, so plan on TagLib or a small tag parser. Keep both normalizers and the four-step match order with the strict artist rule for `exact`. Key the cache to the folder path and generation (fixes Bug 9), and persist it to disk (already on the roadmap). Read-only always.
- **Queue model** as in Data formats; save about 400 ms after the last change, atomically, and flush on quit. After a batch remove downloaded and skipped rows, but never drop rows that got no result, and decide whether excluded rows should stay (Bugs 1, 11). Count the batch bar over the rows actually sent.
- **Manifests**: BTS = base64 JSON `{ mimeType, codecs, encryptionType, urls[] }`, reject encryption; DASH = parse with `XMLParser` (BaseURL, `SegmentTemplate@initialization/@media/@startNumber`, `S@r` → r+1 segments each, unescape all URLs). FLAC when `audioQuality ∈ {LOSSLESS, HI_RES_LOSSLESS, HI_RES}` or codec contains `flac`. Fall back from Hi-Res to LOSSLESS only when TIDAL says the tier is unavailable, not on transient errors (Bug 8).
- **Files**: flat folder; `<sanitized Title>.flac|.m4a`; sanitize `\ / : * ? " < > |` → `_`, collapse whitespace, `unknown` if empty — and also handle whitespace-only/leading-dot names and the 255-byte UTF-8 limit. Skip when either extension exists (compare case-insensitively on APFS). Temp file `<Title>.tmp.(m4a|flac)` in the same folder; stream DASH segments to disk in order rather than holding the whole file in RAM; check received bytes against `Content-Length` for direct downloads; delete partial files on failure.
- **FFmpeg**: bundle a signed binary (e.g. `Contents/Helpers/ffmpeg`), run it with `Process`, pipe the JPEG on stdin, keep the exact arguments and tag order (including `comment=Cover (front)` for picture type 3), then run the decode check. Decide whether a failed check is a failure. Check that the binary runs at launch and show the warning only after the UI exists.
- **Feedback**: per-track start / integer percent (segments done ÷ total for DASH, bytes ÷ length for direct) / result; `↓ N%` badge with a thin bar; `done / total` batch bar; the activity-log lines and summary `=== Batch complete: X downloaded, S skipped, F failed, NF not found ===`; chimes (start, cancel, warning, success). Play the success sound only when nothing failed (Bug 7). Keep **Open folder**.
- **Waveform**: only 200 peaks are needed. Fetch on demand or cache peaks on disk keyed by TIDAL ID instead of downloading every row's full file at every launch. Whether AVFoundation can decode TIDAL's fragmented-MP4 FLAC (DASH) is unverified (needs a run).
- **macOS app lifecycle**: a native app is single-instance by default; tie batch lifetime to the app (cancel or finish cleanly on quit and on window close). If sandboxed, the download and library folders need security-scoped bookmarks and the bundled FFmpeg inherits the sandbox; the current distribution (ad-hoc signed, not sandboxed) avoids that. Check the download folder exists and is writable before a batch.

### Open questions

1. Same-title collisions: keep "skip if `<Title>` exists" (rule 3), or add a disambiguator (artist or TIDAL `version`) when the TIDAL IDs differ?
2. Should TIDAL's `version` text be part of the title tag and file name?
3. Cancel: stop the in-flight track and delete its partial file, or let it finish and mark it done?
4. Should the success sound and `✓ Batch finished.` appear only when nothing failed, with a distinct summary otherwise?
5. Should excluded exact-match rows survive a batch?
6. For Spotify rows, show TIDAL's matched title/artist (what gets saved) or Spotify's? This also changes which strings the library check uses.
7. Waveform: keep background preloading of full lossless audio, or fetch on play and cache peaks on disk?
8. Token storage: Keychain (with a one-time migration from `token.json`) or a file in Application Support?
9. After a failed integrity check, count the file as done or as failed-and-retryable?
10. Should digits-only and UUID-only input keep meaning "TIDAL ID", or always search unless it is a link?
