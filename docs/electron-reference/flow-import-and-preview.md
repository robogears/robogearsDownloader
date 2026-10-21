## Tracklist import and waveform preview

Scope: the end-to-end path from "user hands the app a list of songs" (CSV file, text file, or clipboard paste) to matched rows in the queue, and the inline waveform preview on every queue row (background preloading, peak extraction, drawing, play/pause, scrub, track switching, caches, volume). Code version 0.1.30. Files: `renderer/app.js`, `renderer/index.html`, `renderer/styles.css`, `electron-preload.js`, `electron-main.js`, `tidal_lib.js`. No child process (`bulk_runner.js`, `tidal_download.js`) takes part in either flow; `bulk_runner.js` only matters here because it holds a fourth copy of the same title/artist matcher.

### Overview

**Import.** The drop zone on the main screen accepts a dropped file, a file picked through a hidden file input, or a paste anywhere in the window while no text field has focus. The renderer reads the text and parses it locally into a list of `{title, artist}` pairs: CSV when the first non-empty line has a comma and a recognisable title column exists, otherwise one track per line in `Title - Artist` form. The whole list goes to the main process in one IPC call. Main loads the TIDAL token from disk, then matches the tracks strictly one at a time with a TIDAL text search (10 results) and a title/artist score. After each track it sends a progress event, which the renderer shows as "Matching N / M tracks on TIDAL…" on a full-screen overlay that has no Cancel button. Main then tags every record with a music-library match and returns the list. The renderer drops duplicates already in the queue, appends the rest, and saves the queue to disk 400 ms later. Unmatched rows stay in the queue as faded "not found" rows that can't be previewed, downloaded, retried or re-matched; they can only be removed.

**Preview.** Every queue row that has a TIDAL id (and isn't "not found") gets a round play button and a waveform canvas. A renderer-side preloader, two at a time, asks main for each track's audio. Main fetches TIDAL's playback info at LOSSLESS quality and downloads the **entire track into memory** (one signed URL, or an init segment plus every DASH segment, eight at a time) and sends the bytes back over IPC. The renderer decodes the whole track with Web Audio, reduces it to 200 normalised peaks from the first channel, keeps only the peaks (unbounded cache, in memory only) and paints the canvas. Pressing play downloads the track **again**, wraps it in a Blob URL (LRU cache of 3) and plays it through an `<audio>` element at volume = slider². A `requestAnimationFrame` loop paints progress while playing. Pressing and dragging on the current track's waveform scrubs; clicking another row's waveform switches to that track and starts at the clicked point.

**Most serious defects.** Importing (or any preview fetch) while the token file is missing ends the whole app, because a CLI helper calls `process.exit(1)` inside the Electron main process; with a saved queue this happens on every launch. Overlapping play requests can leave an `<audio>` element playing that nothing can stop. The volume slider is restored from the squared value, so the saved volume ratchets down. Dropping a non-text file (for example an audio file) is parsed as a tracklist. The preloader downloads every queued track in full on every launch.

### Steps

#### A. Getting text into the app

**A1. Drop-zone markup** — `renderer/index.html:43-55`, `renderer/styles.css:268-314`.
`section#drop-zone` (dashed 1 px border, 12 px radius, `cursor: pointer`) contains an icon, the title "Drop a playlist CSV or paste tracks", the subtitle "For playlists over 100 tracks — export via Exportify and drop the CSV here" (where "Exportify" is `a#exportify-link`, `href="#"`), and a hidden `input#file-input type="file" accept=".csv,.txt,text/csv,text/plain"`. Hover and the `.dragover` class turn the border white and the background `#0a0a0a`. The section has no `tabindex` or role, so it is mouse-only.

**A2. Exportify link** — `renderer/app.js:1813-1816` → `electron-preload.js:11` → `electron-main.js:186-188`.
Click: `preventDefault()`, then `api.openExternal('https://exportify.net')`. Main calls `shell.openExternal(url)` only if the value is a string matching `^https?://`. The handler does **not** stop propagation, so the same click bubbles to the drop zone and also opens the file picker (see Bugs).

**A3. Click to pick a file** — `renderer/app.js:1763, 1784-1795`.
A click anywhere on the zone calls `fileInput.click()` (native open panel, filtered by the `accept` list). On `change`: take `files[0]`; `await file.text()` (UTF-8 decode; a leading UTF-8 BOM is dropped; other encodings come through garbled); `await handleTracklistInput(text, file.name)`; on a read error log `✗ Couldn't read <name>: <message>`; in `finally` reset `fileInput.value = ''` so the same file can be picked again.

**A4. Drag feedback** — `renderer/app.js:1765-1770`.
`dragenter`/`dragover` on the zone: `preventDefault()` and add `.dragover`. `dragleave`/`drop`: remove `.dragover`. Only the zone cancels the browser's default drop behaviour; nothing at `document`/`window` level does, and main registers no `will-navigate` guard (`electron-main.js:73-99`).

**A5. Drop** — `renderer/app.js:1772-1782`.
`preventDefault()`; take **only** `e.dataTransfer.files[0]` (extra files are ignored silently); no type or size check; `await file.text()`; `await handleTracklistInput(text, file.name)`; read errors log `✗ Couldn't read <name>: <message>`. Dropping text (not a file) gives no file and returns silently.

**A6. Paste** — `renderer/app.js:1800-1808`.
Document-level `paste` listener, active for the life of the window:
1. If `document.activeElement.tagName` is `INPUT` or `TEXTAREA`, return (the paste goes to the field).
2. `text = clipboardData.getData('text/plain') || ''`.
3. Ignore if `text.length < 10`.
4. Ignore unless the text contains `\n`, or `,`, or matches `/\s[-—–|]\s/` (a hyphen, em dash, en dash or pipe with whitespace on both sides).
5. `preventDefault()`, then `await handleTracklistInput(text, 'pasted text')`.
It also fires while a modal is open (focus on a button) or during a download batch. Ignored pastes give no feedback.

#### B. Parsing (renderer, synchronous)

**B1. `handleTracklistInput(text, sourceName)`** — `renderer/app.js:1830-1858`.
1. If `_tracklistInFlight` is true, return silently (no log line).
2. `tracks = parseTracklistText(text)`. If empty, log `✗ No tracks found in <sourceName>.` and stop.
3. Log `📋 Parsed <N> track(s) from <sourceName>. Matching against TIDAL…` ("track" or "tracks").
4. Unlike the URL/search path (`app.js:1290-1293`), there is **no** `api.tokenExists()` check and no `isDownloading` check.
5. Continues at C1.

**B2. Format choice** — `renderer/app.js:1862-1874`.
`looksLikeCsv(text)`: the first line with non-whitespace content contains `,` **and** `text.split(/\r?\n/).length >= 2` (at least one newline anywhere). If so, try `parseCsvTracklist`; if it returns at least one row use it, otherwise fall back to `parsePlainTextTracklist`. Otherwise go straight to plain text.

**B3. CSV tokenizer `parseCsv`** — `renderer/app.js:1878-1897`. Character state machine:
- Outside quotes: `"` opens a quoted field **only when the current field is empty** (a quote later in a field, or after leading spaces, is literal); `,` ends the field; `\r` is dropped; `\n` ends the field and the row; anything else is appended.
- Inside quotes: `""` appends one `"`; a single `"` closes the quote (characters after it are appended to the same field); everything else, including `,`, `\r` and `\n`, is appended.
- At the end, if the last field is non-empty or the row has fields, flush it as a final row (so a trailing newline doesn't add an empty row).

**B4. CSV mapping `parseCsvTracklist`** — `renderer/app.js:1899-1919`.
1. Fewer than 2 rows → `[]`.
2. Header = **row 0** (not the first non-empty line), each cell lowercased and trimmed.
3. `titleIdx` = index of the **first** header matching `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/`. `artistIdx` = index of the **first** header containing `artist`.
4. No title column → `[]` (caller falls back to plain text).
5. For each later row: `title = trim(row[titleIdx])`, `artist = trim(row[artistIdx])` or `''` without an artist column; skip empty titles; skip if `lower(title)|lower(artist)` was already seen; push `{title, artist}`. File order is kept. Every other column (duration, ISRC, album, URIs) is ignored.

**B5. Plain text `parsePlainTextTracklist`** — `renderer/app.js:1923-1939`.
Split on `/\r?\n/`, trim each line, drop empty lines. For each line, match `/^(.+?)\s*[-—–|\t]\s*(.+)$/`: group 1 → title, group 2 → artist (both trimmed). No match → `title = line`, `artist = ''`. Skip titles shorter than 2 characters. De-duplicate on `lower(title)|lower(artist)`. The separator class is hyphen, em dash, en dash, pipe or tab; spaces around it are optional, and the lazy `(.+?)` splits at the **first** separator character, so `Anti-Hero - Taylor Swift` gives title `Anti`. The order is always Title then Artist.

#### C. Matching (main process)

**C1. Start the resolve** — `renderer/app.js:1839-1843`.
`_tracklistInFlight = true`, `_tracklistTotal = N`, `showLoading('Matching 0 / N tracks on TIDAL…')` — the full-screen blur overlay (`position: fixed; inset: 0; z-index: 100`, blocks all clicks) with fixed text, no rotating jokes, Cancel button hidden and `_loadingOnCancel = null`. Then `await api.resolveTracklist({ tracks })` (`electron-preload.js:46` → `ipcRenderer.invoke('resolve:tracklist', p)`).

**C2. Load credentials** — `electron-main.js:925` → `tidal_lib.js:48-60`.
`loadCred()`: if the token file (`TIDAL_TOKEN_PATH`, set to `<userData>/token.json` in packaged builds at `electron-main.js:19-21`; otherwise `<source dir>/token.json`, `tidal_lib.js:13`) does not exist → `console.error(...)` then **`process.exit(1)`**, which ends the Electron main process and so the whole app. It then `JSON.parse`s the file; an array is used as-is, anything else is wrapped in an array; an empty array → also `process.exit(1)`. Returns entry 0. A parse error throws normally and is caught by the handler (→ `{ok:false, error}`).

**C3. Access token** — `electron-main.js:926` → `tidal_lib.js:97-102, 70-95`.
`getToken`: if `access_token` exists and `Date.now() < expires_at`, use it. Otherwise `refreshToken`: `POST https://auth.tidal.com/v1/oauth2/token`, HTTP Basic auth built from the token file's `client_ID`/`client_secret`, form body `client_id`, `refresh_token`, `grant_type=refresh_token`, `scope=r_usr+w_usr+w_sub` (form-encoded, so the server receives literal plus signs). Non-200 → throws `Token refresh failed: <status> <body>`. On success: `access_token` from the reply; `expires_at = now + (expires_in || 3600) × 1000 − 60 000`; copies `user.countryCode` if the file had none; re-reads the file, merges into entry 0 and rewrites it with `writeFileSync` (4-space JSON, not atomic). A `refresh_token` in the reply, if TIDAL sends one, is not stored.

**C4. Country** — `electron-main.js:927` → `tidal_lib.js:104-119`.
Use `cred.countryCode` if present. Otherwise `GET /v1/users/{userID}?countryCode=US`; on 200 with a `countryCode`, store it and rewrite the token file. Any failure → `'US'` (not saved).

**C5. Progress 0** — `electron-main.js:929-936`. `total = tracks.length`; `sendProgress(0)` sends `tracklist:progress {done: 0, total}` if the window still exists.

**C6. Per-track search, strictly sequential** — `electron-main.js:938-942` → `tidal_lib.js:298-302, 156-168, 129-154`.
`query = "<title> <artist>"` (trailing space when the artist is empty). `GET https://api.tidal.com/v1/search/tracks?query=<encodeURIComponent>&limit=10&countryCode=<cc>` with headers `Authorization: Bearer <token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. 30 s socket-inactivity timeout (`req.setTimeout`, not a total deadline). No retry. Non-200 throws `Search failed: <status> <body>`. The token and country from C3–C4 are used for the whole loop and never refreshed mid-run.

**C7. Scoring** — `electron-main.js:944-960`.
- `normalize(s)` = lowercase → replace every char not in `[a-z0-9 ]` with a space → collapse whitespace → trim. (Accented and non-Latin letters become spaces.)
- `wantT = normalize(title)`, `wantA = normalize(artist)`. For each search item: `itT = normalize(item.title)`, `itA` = the normalised artist names joined with spaces.
- `titleScore` = 100 if `itT === wantT`; else 50 if either starts with the other; else 25 if either contains the other; else 0.
- `aTokens` = words of `wantA` longer than 2 characters; `artistScore = round(100 × (tokens found as substrings of itA) / aTokens.length)`, or 0 if there are no tokens.
- Keep items with `titleScore === 100 || (titleScore >= 25 && artistScore >= 50)`; sort by `titleScore + artistScore` descending (stable, so ties keep TIDAL's order); `pick` = first.
- No duration term (the Spotify matcher, `tidal_lib.js:596-597`, adds 50/25/0 for < 3 s / < 8 s difference). TIDAL's `version` field and `mediaMetadata` are not read.

**C8. Output record** — `electron-main.js:961-974`. One record per input row, input order:
- Match: `{title: pick.title, artist: pick.artists[].name joined ", ", duration: pick.duration || 0, tidalId: pick.id, source: 'import', matchMethod: 'search', notFound: false, originalTitle, originalArtist}`.
- No acceptable candidate: same keys with `title`/`artist` = the input values, `duration: 0`, `tidalId: null`, `matchMethod: null`, `notFound: true`.
- Search threw (any HTTP error, timeout, JSON error): `{title, artist, tidalId: null, source: 'import', notFound: true}` — no duration, matchMethod or original fields.
- `hiRes` is never set (every other add path sets it).

**C9. Progress per track** — `electron-main.js:975` → `electron-preload.js:47` → `renderer/app.js:1823-1828`.
After each track (success or error) `sendProgress(i + 1)`. Renderer: ignore unless `_tracklistInFlight`; then `loadingTextEl.textContent = "Matching <done> / <_tracklistTotal || total> tracks on TIDAL…"`.

**C10. Library enrichment** — `electron-main.js:977` → `tidal_lib.js:836-844, 788-833, 674-757`.
`enrichWithLibraryStatus(out)` runs for **every** record, not-found ones included (using the CSV title/artist for those), one after another. `findInLibrary(title, artist, duration)`:
1. Empty title → null. Awaits `scanLibrary()`: returns the cached scan, joins an in-flight scan, or starts a fresh one with no progress callback. Empty library → null.
2. `tFull` = full normalisation; `tCore` = core normalisation (cut at the first `(`/`[` if it isn't the first character, strip `feat./ft./featuring …`, strip ` - remix|edit|mix|extended|radio|original|instrumental|acoustic|live|remaster(ed)|version|club|vip|dub|bootleg|rework|reprise|demo|single|album …`). `tCore` shorter than 3 characters → null.
3. First pass over all files: tag title equals `tFull` **and** artists agree (both non-empty and one contains the other) → `exact`.
4. Second pass: tag title equals `tFull` → `similar`.
5. Third pass: filename title part or whole filename equals `tFull` → `similar`.
6. Fourth pass, per file: tag core title equals `tCore`, then filename core forms → `similar`.
A hit adds `libraryMatch: {kind, path, libraryTitle}`. Per-track errors are swallowed. The library is only read. If a cold library scan is still running (started at boot), the reply waits here while the overlay still reads "Matching N / N".

**C11. Reply** — `electron-main.js:978-981`: `{ok: true, tracks: out}`; any throw from C2–C4 (or enrichment) → `{ok: false, error: e.message}`.

#### D. Into the queue (renderer)

**D1. Result handling** — `renderer/app.js:1844-1857`.
`hideLoading()`. If `!r.ok` → log `✗ <error>` and stop. Else `matched` = records with `!notFound`, `missing` = the rest, `added = addTracksToQueue(r.tracks)`, log `+ Added <added> from import. <matched> matched on TIDAL[, <missing> not found].` `catch` → `hideLoading()`, log `✗ <message>`. `finally` → `_tracklistInFlight = false`, `_tracklistTotal = 0`.

**D2. `addTracksToQueue`** — `renderer/app.js:1255-1272`.
Dedupe key = `id:<tidalId>` when there's an id, else `na:<title>|<artist>` (exact, case-sensitive), checked against the existing queue and within the batch. Each new record is pushed as `{...record, key: Math.random().toString(36).slice(2, 10)}` at the **end** of the queue. Every added row with a `tidalId` and `!notFound` is passed to `enqueuePreload` (starts E). Then `renderQueue()`, and `saveQueueSoon()` if anything was added. Returns the count added. Two CSV rows that match the same TIDAL id produce one row, so `added` can be lower than `matched`; `added` includes not-found rows.

**D3. Row rendering `renderQueue`** — `renderer/app.js:890-1022`, `styles.css:513-720`.
Rebuilds the whole list (`innerHTML = ''`) on every call. Per item:
- `included` defaults to `!(libraryMatch.kind === 'exact')` the first time it renders; `excluded = !included && !notFound`.
- Row classes: `notfound` (opacity .55, preview controls hidden), `excluded` (info column opacity .42, title struck through, ✕ at .42, bright "+ Add" button), `dl-<status>`.
- Status badge, first match wins: `↓ N%` / `✓ done` / `⏭ skipped` / `✗ failed` (download state) → `not found` (red, tooltip "Not on TIDAL") → `📁 already in library` (tooltip = file path) → `⚠ similar version in library` (tooltip = path) → source badge (`Spotify`, `Import`, `Spotify ext`; source `tidal` gets none). A separate `Hi-Res` badge appears when `t.hiRes`.
- Second line: `<artist>[ · m:ss]` then badges. `Library: <libraryTitle>` line for exact or similar matches — also on not-found rows.
- Play button and waveform canvas only when `PREVIEW_FEATURE_ENABLED && tidalId && !notFound` (excluded rows keep them). CSS also hides both on `.dl-downloading` and `.notfound` rows.
- Download button: `Downloading…` during a batch; `Download (N)` when some rows are excluded or not found; else `Download all`. Disabled when nothing is downloadable.
All titles, artists, paths and library titles go through `escapeHtml`.

**D4. Persist** — `renderer/app.js:73-83` → `electron-preload.js:59` → `electron-main.js:599-606`.
`saveQueueSoon`: 400 ms debounce; copy each item without `dlStatus`, `dlPercent`, `selected`; `api.saveQueue(array)`. Main writes `<userData>/queue.json` with `writeFileSync` (2-space JSON, not atomic). A write failure returns `{ok:false}`, which the renderer ignores.

**D5. Rows after creation.** Not-found rows have no preview, no retry, no re-match and no manual search; they can only be removed with ✕. They survive batch ends (`app.js:1468-1473` keeps `notFound` rows) and restarts. Exact-library rows that were never "+ Add"ed are **dropped** from the queue when any batch finishes (same filter keeps only `notFound`, `failed`, or `!dlStatus && included`).

#### E. Waveform preload

**E1. Triggers** — `renderer/app.js:1267, 1984-1986`. (1) Every row added by any path (import, URL, search, extension) with a `tidalId` and `!notFound`. (2) At boot, after the saved queue is restored and rendered with empty canvases, every restored row with a `tidalId` and `!notFound` — so the whole queue is re-downloaded on every launch.

**E2. `enqueuePreload` / `drainPreloader`** — `renderer/app.js:730-749`.
Skip if the feature flag is off, the id is falsy, peaks are already cached, or the id is already waiting in `preloader.queue`. Otherwise push and drain: while `inFlight < 2` and the queue isn't empty, shift an id, skip it if its peaks are now cached, `inFlight++`, `preloadOne(id).finally(() => { inFlight--; drain(); })`. Nothing removes ids when rows are removed or the queue is cleared, and nothing deduplicates against an in-flight preload or a play-path fetch.

**E3. `preloadOne` → `getPeaks` → `fetchAudioBytesIpc`** — `renderer/app.js:751-753, 692-700, 672-678` → `electron-preload.js:50` (`ipcRenderer.invoke('preview:get-audio', {tidalId})`).

**E4. Main: playback info** — `electron-main.js:873-880` → `tidal_lib.js:286-296`.
`loadCred` (same `process.exit(1)` behaviour as C2), `getToken`, `getCountryCode`, then `GET https://api.tidal.com/v1/tracks/{id}/playbackinfopostpaywall?countryCode=<cc>&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL` with the same headers as C6. 401 → throws `Unauthorized — token may be invalid`; other non-200 → `Playback info failed: <status> <body>`. Decode: `Buffer.from(manifest, 'base64').toString('utf8')`. Preview always asks for LOSSLESS (16-bit/44.1 kHz); downloads ask for HI_RES_LOSSLESS.

**E5. Main: BT/BTS manifest** (`manifestMimeType` starts with `application/vnd.tidal.`) — `electron-main.js:883-897`.
`JSON.parse` the decoded manifest. `encryptionType` present and not `NONE` → `{ok:false, error:'Track is DRM-encrypted'}`. No `urls` → `{ok:false, error:'No stream URL in manifest'}`. Else `fetchBuffer(urls[0], {timeout: 60 000, retries: 2})` — the whole file buffered in memory — and return `{ok:true, audioBytes, mimeType: json.mimeType || 'audio/flac'}`.

**E6. Main: DASH manifest** (`application/dash+xml`) — `electron-main.js:823-871, 899-911`.
`_parseDashForPreview`: first `<BaseURL>` text, trimmed and XML-unescaped (`&amp; &lt; &gt; &quot; &apos;`). If the XML has no `SegmentTemplate` and a BaseURL exists → direct: `fetchBuffer(baseUrl, 60 s, 2 retries)`, return `mimeType: 'audio/flac'` regardless of content. Otherwise take the first `initialization="…"` and `media="…"` (XML-unescaped; missing → throws `Could not parse DASH manifest`), `startNumber` (default 1), and for every `<S …/>` anywhere in the document add `r + 1` sequential segment numbers (`r` default 0); none → `No segments found in DASH manifest`. `_fetchDashAudioBuffer`: fetch `baseUrl + initialization` first, then 8 workers fetch `baseUrl + media.replace('$Number$', n)` (first occurrence only), each `fetchBuffer(60 s, 2 retries)`; `Buffer.concat([init, ...segments])` → a fragmented MP4 (FLAC-in-MP4 or AAC-in-MP4); return `mimeType: 'audio/mp4'`. No `ContentProtection`/DRM check. If one segment fails, `Promise.all` rejects while the other workers keep downloading into a discarded array.

**E7. Main: other cases** — `electron-main.js:913-916`. Unknown type → `{ok:false, error:'Unknown manifest type: <mime>'}`; any throw → `{ok:false, error:e.message}`. Nothing is written to disk anywhere in the preview path.

**E8. `fetchBuffer` behaviour** — `tidal_lib.js:174-232`. Plain `GET` with only `User-Agent: okhttp/5.3.2` (signed URLs need no auth). Follows 301/302/307 up to 5 times using the `Location` header as given (303/308 are treated as failures; a relative `Location` is not resolved). 429, 5xx, socket timeouts and network errors are retriable; other non-200 statuses fail immediately with `HTTP <code> for <url>`. Backoff `min(1000 × 2^attempt, 8000)` ms → 1 s then 2 s with `retries: 2` (three attempts). Errors without a `retriable` flag (for example `Too many redirects`) are also retried. The body is collected in chunks and concatenated.

**E9. Renderer: bytes** — `renderer/app.js:673-677`. `!r.ok` → `throw new Error(r.error || 'preview fetch failed')`. IPC delivers the Node `Buffer` as a `Uint8Array`; the code copies out an exactly sized `ArrayBuffer` (`bytes.buffer.slice(byteOffset, byteOffset + byteLength)`). `mimeType` falls back to `audio/flac`.

**E10. Decode and peaks** — `renderer/app.js:561-569, 682-687, 587-606`.
A preview-only `AudioContext` (separate from the sound-effects context), created on first use and `resume()`d if suspended. `decodeAudioData(ab)` decodes the **whole track** to float PCM (it detaches `ab`). `computePeaks(buffer, 200)`: channel 0 only; `samplesPerBar = max(1, floor(length / 200))`; bar *i* = max |sample| over `[i × spb, min((i+1) × spb, length))` (trailing remainder samples ignored); then divide every bar by the largest bar if it is > 0. Result: `Float32Array(200)` in 0…1.

**E11. Cache and paint** — `renderer/app.js:698, 754-766`. `peaksCache.set(id, peaks)`; the audio bytes are dropped. For every `.qi-waveform[data-tidal-id="<id>"]`: remove `.empty`, set `canvas.__peaks = peaks`, draw at `currentTime / duration` if that track is the current preview (and duration is known), else 0. Any preload error is swallowed silently and not remembered; the id is tried again only when it is enqueued again (next add or next launch).

**E12. `drawWaveform(canvas, peaks, progress = 0, hover = -1)`** — `renderer/app.js:608-650`.
1. CSS size = `clientWidth || width` × `clientHeight || height`; if the backing store isn't `css × devicePixelRatio`, resize it; `scale(dpr, dpr)`; clear.
2. `n = 200`, `barWidth = cssWidth / n`, `midY = cssHeight / 2`, `hoverBar = hover × n` (or −1).
3. For each bar *i*: `x = i × barWidth`; played if `(i + 0.5) / n <= progress`; `boost = 1 + (1 − dist/10) × 0.45` when `dist = |i − hoverBar| < 10`, else 1; `h = max(1, peak × cssHeight × 0.78 × boost)`; fill `#ffffff` (played) or `rgba(255,255,255,0.22)` (unplayed); rect `(x, midY − h/2, max(1, barWidth − 1), h)`.
4. If hovering: a 1 px wide `rgba(255,255,255,0.55)` line at `x = floor(hover × cssWidth)`, from `y = 2`, height `cssHeight − 4`.

**E13. Row controls** — `renderer/app.js:951-956, 981-996`, `styles.css:566-645`.
Each eligible row gets `button.qi-play[data-tidal-id]` (28 px circle, `title="Play preview"`, `aria-label="Play"`, 9×9 SVG triangle) and `canvas.qi-waveform.empty[data-tidal-id][height=22]` (`title="Click or drag to scrub"`, CSS height 22 px, `flex: 1 1 auto; min-width: 0`, so the title keeps its full width and the waveform shrinks to nothing if needed). On every re-render, if peaks are cached the new canvas is painted at once (with live progress for the current track) and the pause icon is restored if that track is playing; a row in the "loading" state is redrawn with the plain play icon.

#### F. Playback, switching and scrubbing

**F1. Play click** — `renderer/app.js:1061-1070`. Delegated click on `.qi-play`: `stopPropagation()`, `tidalId = Number(dataset.tidalId)`, `togglePreview(tidalId, row)`.

**F2. Same track** — `renderer/app.js:791-804`. If `playingTidalId === tidalId` and an audio element exists: paused → `play()` (rejection swallowed) and set the button to "playing" (pause icon, white fill) regardless of the outcome; playing → `pause()` and set "idle". (A seek-before-resume branch at 794-796 can never run; see Bugs.)

**F3. Different track** — `renderer/app.js:807-820, 769-786`.
`stopPreview()`: set `previewState.audio = null` and `playingTidalId = null` first, then `pause()` the old element and set `src = ''` (its delayed `error` event is ignored by the `isCurrent` guard), reset the old row's button to idle and redraw its canvas at progress 0. Find this row's canvas (none → return). If peaks are cached, paint them at `initialSeekRatio`. Set the button to "loading" (dashed ring rotating 1.2 s per turn).

**F4. `getPlayableEntry`** — `renderer/app.js:705-727, 571-585`.
`audioCache` hit → move the entry to the end (LRU). Miss → `fetchAudioBytesIpc` **again** (E3–E9; the preloader kept only peaks); if peaks aren't cached, decode a copy (`ab.slice(0)`) and cache peaks; `new Blob([ab], {type: mimeType})`, `URL.createObjectURL`, `audioCache.set(id, {blobUrl})`, then `evictAudioCache()`: while size > 3, look at the oldest key — if it is `playingTidalId`, move it to the end; otherwise `revokeObjectURL` and delete. After a normal click `playingTidalId` is already null here, so the guard only matters when overlapping requests have made another track current.

**F5. Start audio** — `renderer/app.js:825-834, 506-513`. `new Audio(blobUrl)`; `volume = getPreviewVolume()` = `clamp(settings.volume is a number ? settings.volume : 0.5, 0, 1)²`; `preload = 'auto'`; set `previewState.audio` and `playingTidalId`; paint peaks at `initialSeekRatio`. There is no check that this request is still the latest one.

**F6. Initial seek** — `renderer/app.js:839-846`. If `initialSeekRatio > 0`: when `duration` isn't finite or ≤ 0, await `loadedmetadata` (no timeout, no error path); then `currentTime = ratio × duration`.

**F7. Listeners** — `renderer/app.js:853-876`. All guarded by `isCurrent()` (`previewState.audio === audio`):
- `play` → start a `requestAnimationFrame` loop: re-look-up the live canvas for this id each frame, draw at `currentTime / duration` with the canvas's `data-hover` (if numeric), continue while not paused.
- `pause` → button idle. `ended` → `stopPreview()`. `error` → log `✗ Preview playback failed (<MediaError code or ?>).` and `stopPreview()`.
Then `await audio.play()` → button "playing". Any throw in F4–F7 → button idle and log `✗ Preview: <message>`.

**F8. Waveform mousedown** — `renderer/app.js:1144-1165`. Left button only. `rel = clamp((clientX − rect.left) / rect.width, 0, 1)`.
- Canvas belongs to the current track (playing **or paused**) and has `__peaks`: `preventDefault()`, `scrubbing = {canvas}`, `seekFromMouseEvent`. Play/pause state does not change.
- Otherwise (another track, or nothing current, including a still-empty canvas): `preventDefault()`, `togglePreview(id, row, {initialSeekRatio: rel})` — stops the current track and starts this one at the clicked point.

**F9. Scrub** — `renderer/app.js:1135-1142, 1184-1191`. `seekFromMouseEvent` requires a known `duration`; sets `currentTime = rel × duration`, draws with `progress = hover = rel`, stores `data-hover = rel`. A `document` `mousemove` keeps seeking while `scrubbing` is set, even off the canvas; audio keeps playing during the drag. `document` `mouseup` ends the scrub (hover is not cleared).

**F10. Hover** — `renderer/app.js:1168-1180, 1194-1205`. `mousemove` on a canvas with peaks (not while scrubbing): set `data-hover`, redraw with live progress and the spotlight. `mouseout` (capture phase, not while scrubbing, and not when moving into a child): delete `data-hover`, redraw without it.

**F11. Resize** — `renderer/app.js:1209-1222`. 120 ms debounce, then redraw every canvas that has `__peaks`.

**F12. Stop triggers** — `ended`, `error`, switching tracks, removing the current track's row with ✕ (`app.js:1118-1120`, before the filter), and Clear all (`app.js:1247-1253`). Rows removed at the end of a batch (`app.js:1468-1473`) do **not** stop the preview. Neither cache is ever cleared: `peaksCache` grows for the life of the window; `audioCache` keeps up to 3 Blob URLs.

**F13. Volume** — `renderer/app.js:501-524, 1947-1948`, `index.html:62-69`.
`input` on `#volume-slider` (0–100, HTML default 50): `settings.volume = value / 100` (the linear position); live audio volume = that value squared; after 300 ms of quiet, `api.saveSettings(settings)` writes the whole settings object to `<userData>/settings.json` (`electron-main.js:42-52`, `writeFileSync`, 2-space JSON). At boot the slider is set to `round(getPreviewVolume() × 100)` — the **squared** value (see Bugs). The boot comment says the default is 60 %; the code default is 0.5.

### Data formats

**Parsed tracklist entry (renderer → main):**
```
{ title: string, artist: string }        // artist may be ''
```

**IPC `resolve:tracklist`** (invoke) — request `{ tracks: [{title, artist}] }`; reply `{ ok: true, tracks: ImportRecord[] }` or `{ ok: false, error: string }`.

**IPC `tracklist:progress`** (main → renderer event) — `{ done: number, total: number }`, sent once with `done: 0` and once after each track.

**ImportRecord** (three shapes):
```
matched:   { title, artist /* "A, B" */, duration /* int seconds */, tidalId /* number */,
             source: "import", matchMethod: "search", notFound: false,
             originalTitle, originalArtist, libraryMatch? }
no match:  { title /* input */, artist /* input */, duration: 0, tidalId: null,
             source: "import", matchMethod: null, notFound: true,
             originalTitle, originalArtist, libraryMatch? }
error:     { title, artist, tidalId: null, source: "import", notFound: true, libraryMatch? }
libraryMatch: { kind: "exact" | "similar", path: string /* absolute file path */, libraryTitle: string }
```

**Queue item as saved in `<userData>/queue.json`** (a JSON array, 2-space indent): an ImportRecord plus `key` (8-char base-36 string) and `included` (boolean, set on first render). `dlStatus`, `dlPercent`, `selected` are stripped before saving; `hiRes` is absent for imported rows.

**IPC `preview:get-audio`** (invoke) — request `{ tidalId: number }`; reply `{ ok: true, audioBytes: Buffer /* arrives as Uint8Array */, mimeType: string }` or `{ ok: false, error: string }`. `mimeType` is the BTS manifest's `mimeType` (fallback `audio/flac`), `audio/flac` for DASH-direct, `audio/mp4` for DASH segments.

**TIDAL fields read:** search `items[]` → `id`, `title`, `artists[].name`, `duration`. Playback info → `manifestMimeType`, `manifest` (base64). BT/BTS manifest JSON → `encryptionType`, `urls[0]`, `mimeType`. DASH XML → first `<BaseURL>`, first `initialization="…"`, first `media="…"` (with `$Number$`), `startNumber`, every `<S … r="N"/>`.

**Token file** — JSON array (a bare object is also accepted); only entry 0 is used. Fields used here: `access_token`, `refresh_token`, `expires_at` (ms epoch), `countryCode`, `userID`, `client_ID`, `client_secret`. The client ID/secret pair is TIDAL app credentials that originally come from base64-encoded constants inside `tidal_auth_node.js`; values are not reproduced here.

**`settings.json`** — relevant key `volume: number` (0–1, the linear slider position; absent means 0.5).

**In-memory renderer state** — `previewState = {playingTidalId: number|null, audio: HTMLAudioElement|null, audioCtx, peaksCache: Map<id, Float32Array(200)>, audioCache: Map<id, {blobUrl}>, MAX_AUDIO_CACHE: 3}`; `preloader = {queue: number[], inFlight: number, CONCURRENCY: 2}`; `scrubbing = {canvas} | null`; `_tracklistInFlight: boolean`, `_tracklistTotal: number`; per-canvas `__peaks` property and `data-hover` attribute.

### External interfaces

| Interface | Used for | Details |
|---|---|---|
| `GET https://api.tidal.com/v1/search/tracks` | Matching each imported row | `query`, `limit=10`, `countryCode`; Bearer token; `X-Tidal-Platform: android`; UA `okhttp/5.3.2` |
| `GET https://api.tidal.com/v1/tracks/{id}/playbackinfopostpaywall` | Preview manifest | `countryCode`, `audioquality=LOSSLESS`, `playbackmode=STREAM`, `assetpresentation=FULL` |
| `GET https://api.tidal.com/v1/users/{userID}?countryCode=US` | Country code when the token file has none | Saved back to the token file |
| `POST https://auth.tidal.com/v1/oauth2/token` | Access-token refresh when expired | Basic auth with the stored client credentials; form body |
| TIDAL CDN signed URLs | Preview audio bytes | From the manifest; plain GET, no auth header |
| `https://exportify.net` | Opened in the default browser | Third-party Spotify-to-CSV exporter |
| Token file | Read on every import and every preview fetch; rewritten on refresh / country lookup | `TIDAL_TOKEN_PATH` or `<source>/token.json` |
| `<userData>/queue.json` | Queue persistence | Read at boot, written 400 ms after changes |
| `<userData>/settings.json` | Preview volume | Written 300 ms after slider changes |
| Music library folder | Read-only duplicate tagging | Via the library scanner |
| OS | File open panel, drag-and-drop, clipboard | Through Chromium |

IPC channels in this scope: `resolve:tracklist` (invoke), `tracklist:progress` (event), `preview:get-audio` (invoke), `queue:save`/`queue:get` (invoke), `settings:save` (invoke), `shell:open-external` (invoke).

### Constants and magic values

| Constant | Value | Where |
|---|---|---|
| `PREVIEW_FEATURE_ENABLED` | `true` | `app.js:58` |
| Preloader concurrency | 2 | `app.js:558` |
| Playable-audio LRU size (`MAX_AUDIO_CACHE`) | 3 | `app.js:549` |
| Peak bars | 200 | `app.js:686` |
| Bar height factor | 0.78 of canvas height | `app.js:638` |
| Spotlight radius / max boost | 10 bars / +45 % (linear falloff) | `app.js:633-636` |
| Played / unplayed bar colour | `#ffffff` / `rgba(255,255,255,0.22)` | `app.js:639` |
| Hover line | 1 px, `rgba(255,255,255,0.55)`, y 2 → h−2 | `app.js:644-648` |
| Bar gap | 1 px (`barWidth − 1`, min 1 px) | `app.js:640` |
| Waveform height | 22 CSS px | `app.js:955`, `styles.css:611-622` |
| Play button | 28 px circle; icons 9×9 SVG | `styles.css:566-581`, `app.js:653-655` |
| Loading ring spin | 1.2 s per turn | `styles.css:592-599` |
| Resize redraw debounce | 120 ms | `app.js:1221` |
| Queue save debounce | 400 ms | `app.js:82` |
| Volume save debounce | 300 ms | `app.js:523` |
| Volume default / curve | 0.5 linear; audio = slider² | `app.js:506-513` |
| Volume slider range / HTML default | 0–100 / 50 | `index.html:68` |
| Paste minimum length | 10 characters | `app.js:1804` |
| Plain-text minimum title length | 2 characters | `app.js:1932` |
| Library core-title minimum | 3 characters | `tidal_lib.js:795` |
| TIDAL search result limit | 10 | `electron-main.js:942` |
| API socket-inactivity timeout | 30 000 ms | `tidal_lib.js:15, 148-149` |
| Preview CDN timeout / retries | 60 000 ms inactivity / 2 (3 attempts) | `electron-main.js:858, 866, 891, 903` |
| Retry backoff | `min(1000 × 2^attempt, 8000)` ms | `tidal_lib.js:186` |
| DASH preview workers | 8 | `electron-main.js:869` |
| Redirects | 301/302/307, max 5 | `tidal_lib.js:199-204` |
| User-Agent / platform header | `okhttp/5.3.2` / `X-Tidal-Platform: android` | `tidal_lib.js:14, 165` |
| Token expiry margin / default lifetime | 60 s / 3600 s | `tidal_lib.js:88` |
| Fallback country | `US` | `tidal_lib.js:118` |
| Title score tiers | 100 equal / 50 prefix / 25 substring / 0 | `electron-main.js:950-953` |
| Acceptance | title 100, or title ≥ 25 and artist ≥ 50 | `electron-main.js:958` |
| Artist token minimum length | > 2 characters | `electron-main.js:954` |
| Preview MIME fallbacks | `audio/flac`; DASH segments `audio/mp4` | `electron-main.js:895, 904, 910`; `app.js:677` |
| Exportify URL | `https://exportify.net` | `app.js:1815` |
| File picker filter | `.csv,.txt,text/csv,text/plain` | `index.html:53` |

**Regular expressions** (exact):
- CSV title header: `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/` (on lowercased, trimmed header cells)
- CSV artist header: `/artist/`
- Plain-text line: `/^(.+?)\s*[-—–|\t]\s*(.+)$/` (hyphen-minus, U+2014 em dash, U+2013 en dash, pipe, tab)
- Paste separator test: `/\s[-—–|]\s/`
- Line split: `/\r?\n/`
- Match normalisation: lowercase, `/[^a-z0-9 ]/g` → space, `/\s+/g` → single space, trim
- `open-external` guard: `/^https?:\/\//`

**User-visible strings in scope:**

| Where | Text |
|---|---|
| Drop zone | "Drop a playlist CSV or paste tracks"; "For playlists over 100 tracks — export via Exportify and drop the CSV here" |
| Log | `✗ Couldn't read <name>: <message>` · `✗ No tracks found in <source>.` · `📋 Parsed <N> track(s) from <source>. Matching against TIDAL…` · `+ Added <added> from import. <matched> matched on TIDAL[, <missing> not found].` · `✗ <error>` |
| Source name for paste | `pasted text` |
| Overlay | `Matching <done> / <total> tracks on TIDAL…` |
| Row badges | `not found` (tooltip "Not on TIDAL") · `📁 already in library` (tooltip = path) · `⚠ similar version in library` · `Import` · `Hi-Res` · `Library: <title>` · `+ Add` (tooltip "Add to download list") · `✕` (aria "Remove from queue") |
| Download button | `Download all` · `Download (N)` · `Downloading…` |
| Preview | Play button title "Play preview", aria-label "Play"; canvas tooltip "Click or drag to scrub"; volume "Preview volume" |
| Preview errors (log) | `✗ Preview playback failed (<code>).` · `✗ Preview: <message>`, where the message can be `Track is DRM-encrypted`, `No stream URL in manifest`, `Unknown manifest type: <mime>`, `Could not parse DASH manifest`, `No segments found in DASH manifest`, `Unauthorized — token may be invalid`, `Playback info failed: <status> <body>`, `HTTP <code> for <signed URL>`, `Request timeout after <ms>ms`, `Too many redirects`, `Web Audio not supported`, `preview fetch failed`, or a Web Audio decode error |
| Import errors (log) | `✗ Token refresh failed: <status> <body>` or a JSON parse message |

### Rules and invariants

1. Parsing happens entirely in the renderer; main receives only `{title, artist}` pairs.
2. Only one import runs at a time (`_tracklistInFlight`); a second one is dropped silently.
3. Matching is sequential, one TIDAL search per input row, and every input row produces exactly one output record in input order.
4. A row is "matched" only if a candidate passes the acceptance rule; otherwise, and on any search error, it becomes `notFound: true` with `tidalId: null`.
5. Duplicates: case-insensitive `title|artist` within one parsed list; then queue-level `id:<tidalId>` or case-sensitive `na:<title>|<artist>` against the existing queue.
6. New rows always append to the end of the queue.
7. Exact library matches start excluded (`included = false`); similar matches and everything else start included. Not-found rows are never downloadable.
8. Preview controls exist only for rows with a `tidalId` and `!notFound`, and are hidden while the row downloads.
9. Exactly one preview is meant to be current (`previewState.audio` / `playingTidalId`); stale media events are ignored through `isCurrent()`. (The orphan bug breaks this.)
10. Peaks are cached forever per window; playable audio is cached for at most 3 tracks and evicted with `revokeObjectURL`.
11. Preview never writes to disk; import writes only `queue.json` (and the token file on refresh).
12. The music library is only read.
13. Text from CSVs and TIDAL is HTML-escaped before it reaches the DOM.
14. Volume is stored as the linear slider position; audio volume is its square.

### Edge cases and failure modes

| Situation | What happens | What the user sees | Left on disk |
|---|---|---|---|
| Import with no token file, or a token file holding `[]` | `loadCred` calls `process.exit(1)` in main (`tidal_lib.js:49-58`) | The window disappears with no message (exact visual behaviour unverified, needs a run) | `queue.json` from the last save; the last ≤ 400 ms of changes lost |
| Restored queue with TIDAL ids and no token file | The boot preloader immediately calls `preview:get-audio` → same exit (`app.js:1984-1986`) | The app closes within moments of every launch, before the user can sign in | Unchanged `queue.json`, so it repeats until the token file exists or the queue file is removed |
| Token refresh fails / token file isn't valid JSON | Whole import returns `{ok:false}` | Overlay hides; `✗ Token refresh failed: <status> <raw body>` or the parse message; nothing added | Nothing |
| Search error for one row (401, 429, 5xx, timeout, network) | Caught → `notFound: true` | A normal-looking "not found" row; indistinguishable from a true miss | Row saved in `queue.json` |
| Token expires mid-import | All later searches get 401 → not found | Many "not found" rows at the end of a long import | Saved |
| File can't be read (`file.text()` rejects, e.g. a folder) | — | `✗ Couldn't read <name>: <message>` | Nothing |
| Parser returns nothing | — | `✗ No tracks found in <name>.` | Nothing |
| Paste ignored (focus in a field, < 10 chars, no newline/comma/spaced separator) | — | Nothing at all | Nothing |
| Paste or drop while an import is running | Dropped silently | Nothing | Nothing |
| Non-text file dropped (audio, image, archive) | Read whole as UTF-8; random line breaks give many garbage "titles"; each is searched on TIDAL one by one | Overlay with "Matching 0 / <large N>" and no Cancel; eventually many not-found rows | Garbage rows in `queue.json` |
| CSV starting with a blank line | Header becomes `['']` → no title column → plain-text fallback; the real header line becomes a "track" | Junk rows, most not found | Saved |
| CSV with no recognised title column | Plain-text fallback; commas don't split | Rows titled with whole lines, mostly not found | Saved |
| Plain-text paste whose first line has a comma and the word title/song/name | Read as CSV; first line swallowed as the header; later lines split at the first comma, artist empty | Wrong titles, mostly not found | Saved |
| File outside the drop zone dropped | No handler cancels the default; Chromium is expected to navigate the window to the file (unverified, needs a run) | App UI replaced by the file's contents until reload/restart | Unsaved queue changes from the last 400 ms lost |
| Library scan still running when matching finishes | Reply waits for the scan | Overlay frozen on "Matching N / N" (around 18 s for ~500 files per the docs) | Nothing |
| Import during a download batch | Allowed | New rows appear; they survive the batch end unless they are excluded exact matches | Saved |
| Import while a URL resolve is running | Both share the overlay; the import removes the resolve's Cancel button; whichever finishes first hides the overlay | Confusing overlay text (the URL path's joke cycler may overwrite "Matching…") | — |
| `queue.json` write fails | `{ok:false}` ignored | Nothing; queue won't survive a restart | Previous or partially written file |
| Preview: playback info error, DRM BTS, no URL, unknown manifest | `{ok:false, error}` | Preload: nothing (waveform stays empty). Play: button returns to idle; `✗ Preview: <error>` (may include TIDAL's raw body) | Nothing |
| Preview: CDN failure | Retries for 429/5xx/network/inactivity; 4xx (and 303/308) fail at once | Spinner, then `✗ Preview: HTTP <code> for <full signed URL>` | Nothing |
| Preview: slow but steady CDN | Inactivity timeout never fires | Spinner for as long as the transfer takes | Nothing |
| Preview: decode fails | `decodeAudioData` rejects | Preload: silent. Play (peaks not yet cached): `✗ Preview: <DOMException message>` — the track never plays even if `<audio>` alone could have | Nothing |
| `<audio>` error or `play()` rejects | — | `✗ Preview playback failed (<code>).` and/or `✗ Preview: <message>`; button idle | Nothing |
| Waveform-click start and `loadedmetadata` never fires | Await hangs | Spinner forever, no log; that row then ignores scrubs (duration unknown) | Nothing |
| Clicking an empty (not yet loaded) waveform | Treated as a click on another track | Playback starts at the clicked point; waveform appears when the fetch finishes | Nothing |
| Current preview's row removed at batch end | Preview not stopped | Audio keeps playing with no visible control until another preview starts or Clear all | Nothing |
| Very large import (hundreds of rows) | One overlay for minutes; afterwards every matched row is preloaded in full, 2 at a time | App blocked during matching; heavy network use afterwards, also during downloads | Saved |

### Bugs and oddities

Severity scale: High = can close the app or lose the session; Medium = wrong behaviour or heavy waste a user will hit; Low = edge case or cosmetic; Oddity = harmless inconsistency worth knowing for the port.

1. **High — Import or preview without a token file quits the app, and a saved queue turns this into a crash on every launch.** `renderer/app.js:1830-1843` has no `api.tokenExists()` check (the URL path has one at `app.js:1290-1293`); `electron-main.js:925` (import) and `:875` (preview) call `lib.loadCred()`, which runs `process.exit(1)` when the token file is missing or holds `[]` (`tidal_lib.js:48-58`). The drop zone is on the first screen, so "drop a CSV before signing in" ends the app silently. At boot, `app.js:1984-1986` preloads every restored row, so a `queue.json` with TIDAL ids plus a missing token file closes the app moments after each launch. That combination is reachable: dev mode keeps the token next to the source while packaged builds keep it in userData, but both share `<userData>/queue.json`; or the user deletes the token file to sign out (there is no sign-out button). Exact on-screen behaviour unverified (needs a run); the code path is unambiguous.

2. **Medium — Overlapping play requests orphan an `<audio>` element.** `renderer/app.js:807, 822, 828`. `togglePreview` calls `stopPreview()` and then awaits `getPlayableEntry()` with no request/generation token. A second play or waveform click before the first fetch resolves finds `playingTidalId === null`, stops nothing, and starts its own fetch. Both later assign `previewState.audio` and call `play()`; the first element loses its reference (`isCurrent()` false), keeps playing to the end, and no control can stop it. Clicking the same row twice quickly downloads the track twice and the second `audioCache.set` overwrites the first entry without revoking its Blob URL (a leak until reload).

3. **Medium — Volume slider is restored from the squared value; the saved volume ratchets down.** `renderer/app.js:1947-1948` sets `volumeSlider.value = round(getPreviewVolume() × 100)`, but `getPreviewVolume()` returns the square (`app.js:506-513`) while `settings.volume` holds the linear position (`app.js:516-519`). A saved 0.5 shows as 25; touching the slider saves ≈ 0.25 and plays at ≈ 0.06; the next launch shows 6–7. The boot comment says the default is 60 %; the code default is 0.5.

4. **Medium — Any dropped file is parsed as a tracklist.** `renderer/app.js:1772-1782` reads `files[0]` whole with `file.text()` with no type or size check (the `accept` filter only applies to the picker). An audio or image file decodes to text with random line breaks; `parsePlainTextTracklist` (`app.js:1923-1939`) turns every chunk of ≥ 2 characters into a "track"; main then searches TIDAL once per chunk, sequentially (`electron-main.js:938-976`), behind an overlay with no Cancel (`app.js:1841`). In a music app, dropping an audio file onto the zone is a likely mistake. Exact row counts unverified (needs a run).

5. **Medium (plausible, unverified) — Dropping a file outside the drop zone probably navigates the window away.** Only `#drop-zone` cancels `dragover`/`drop` (`app.js:1765-1782`); there is no document-level guard and no `will-navigate` handler (`electron-main.js:73-99`). Chromium's default for an uncancelled file drop is to open the file in the window, replacing the app UI.

6. **Medium — The preloader downloads every queued track in full, on every launch, and can't be cancelled.** `renderer/app.js:730-767, 692-700, 1267, 1984-1986`. Drawing 200 bars costs a full LOSSLESS download through main plus a full PCM decode; the bytes are then thrown away, so the first play downloads the track again (`app.js:713`). Peaks live only in memory, so a restored queue is fully re-downloaded at every boot. Removing rows (`app.js:1115-1124`) or Clear all (`app.js:1247-1253`) doesn't remove ids from `preloader.queue`; there's no dedupe against in-flight preloads or play fetches; preloading keeps running during download batches.

7. **Medium — Search failures silently become "not found".** `electron-main.js:941-974`; `tidal_lib.js:129-154, 298-302`. The search has no retry and the token is never refreshed during the loop, so 429s, 5xx, timeouts and a token expiring mid-run all produce `notFound: true` rows that look identical to genuine misses and have no re-match path.

8. **Medium (conditional, unverified) — CSV header detection takes the first matching column.** `renderer/app.js:1903-1904`. Any header containing `name` matches the title regex (`album name`, `artist name(s)`), and any header containing `artist` matches the artist test (`artist uri(s)`, `artist ids`). If an export puts an artist-ID/URI column before the artist-name column, every artist becomes an ID string, which ruins both the search query and the artist score. Exportify's column order has changed over time and whether today's export has that order is unverified (needs a sample file).

9. **Low — Clicking the "Exportify" link also opens the file picker.** `renderer/app.js:1813-1816` calls `preventDefault()` but not `stopPropagation()`; the link sits inside `#drop-zone` (`index.html:43-53`), whose click handler (`app.js:1763`) calls `fileInput.click()` during the same user gesture. The browser opens and the app shows an open panel at the same time. Visual confirmation needs a run; the code path is clear.

10. **Low — Plain-text parser splits at the first separator character and assumes Title - Artist.** `renderer/app.js:1928`. Spaces around the separator are optional, so `Anti-Hero - Taylor Swift` becomes title `Anti`, artist `Hero - Taylor Swift`. The common `Artist - Title` order is read backwards. Artist-token overlap sometimes rescues the match; otherwise the row is not found or wrong.

11. **Low — Format detection misfires on some inputs.** `renderer/app.js:1870-1874, 1899-1905`. A CSV whose first line is blank is read as plain text because the header is taken from row 0, not the first non-empty line. A plain-text paste whose first line contains a comma and the word "title", "song" or "name" is read as CSV: the first line is swallowed as a header and later lines are split at commas with no artist.

12. **Low — Import has no cancel and blocks the window.** `renderer/app.js:1841` calls `showLoading` without `cancellable`, and the main loop never checks `resolverCancelled` (`electron-main.js:938-976`). Large imports lock the UI for minutes.

13. **Low — Imported tracks never get the Hi-Res flag.** `electron-main.js:961-971` omits `hiRes`; every other path sets it from `mediaMetadata.tags` including `HIRES_LOSSLESS` (`electron-main.js:737`; `tidal_lib.js:328, 385, 420`).

14. **Low — Non-Latin titles defeat the title score.** `electron-main.js:944-958`. `normalize` keeps only `a-z0-9` and spaces, so Japanese, Korean, Cyrillic or Greek titles become `''`. `'' === ''` scores 100 and `startsWith('')` scores 50, so the matcher effectively takes the first non-Latin search result rather than comparing titles. Accented Latin letters are also dropped (`Beyoncé` → `beyonc`).

15. **Low (unverified) — TIDAL's `version` field is ignored.** No code reads a track's `version` (grep of `tidal_lib.js`, `tidal_download.js`, `electron-main.js`). If TIDAL returns editions such as "Radio Edit" in a separate field (believed true for v1 track JSON; needs a run), different editions score the same, the first search hit wins, and the queue title loses the edition.

16. **Low — Non-ASCII characters can be garbled in API replies.** `tidal_lib.js:144-146` builds the body with `d += c`, decoding each network chunk to text separately. A multi-byte UTF-8 character split across two chunks becomes replacement characters in the queued title or artist. Frequency unverified (needs a run).

17. **Low — Waveform-click start can hang.** `renderer/app.js:839-846`. The `loadedmetadata` await has no timeout or error path, and the `error` listener is attached only afterwards. If the element never loads, the spinner runs forever and `previewState` points at a dead element.

18. **Low — Hover spotlight sticks after a scrub released off the canvas.** `renderer/app.js:1141, 1188-1195`. Scrubbing sets `data-hover`; `mouseout` is ignored while scrubbing and `mouseup` doesn't clear it, so the playback loop keeps drawing the cursor line and spotlight at the release point until the pointer enters and leaves the canvas again.

19. **Low (plausible) — Scrubbing across a queue re-render jumps to the end.** `renderer/app.js:893, 1135-1141, 1184-1187`. `renderQueue` replaces every canvas, but `scrubbing.canvas` still points at the detached one, whose bounding rect is all zeros. `rel = clientX / 0` → `+Infinity` → clamped to 1, so the track seeks to the end and stops; at `clientX = 0` the result is `NaN` and assigning it to `currentTime` throws. Re-renders happen on every per-track download event. Unverified (needs a run).

20. **Low — A preview keeps playing after its row disappears at the end of a batch.** `renderer/app.js:1457-1482` filters downloaded rows out without calling `stopPreview()`; the only way to stop it is to start another preview or press Clear all.

21. **Low — Reset config wipes the saved volume.** `renderer/app.js:1569-1577` replaces the whole `settings` object with `{downloadFolder: '', libraryFolder: ''}` returned by `electron-main.js:561-565`, which is also what gets written to disk; the slider still shows the old position.

22. **Oddity — Resuming shows the pause icon even when `play()` fails.** `renderer/app.js:797-798` swallows the rejection and sets "playing" anyway.

23. **Oddity — Unreachable seek-before-resume branch.** `renderer/app.js:794-796`. `initialSeekRatio` is passed only by mousedown on a non-current track (`app.js:1158-1163`), so the same-track branch never receives it.

24. **Oddity — Re-render during a preview fetch drops the spinner and can leave the canvas inert.** `renderer/app.js:951-996, 809-834, 1154`. Rows are rebuilt with the plain play icon; `togglePreview` keeps painting the old, detached canvas. If peaks weren't cached at re-render time, the new canvas keeps `.empty` and has no `__peaks`, so the playback loop draws on it but scrubbing returns early until the next re-render.

25. **Oddity — Not-found rows still get library matching.** `electron-main.js:977`; `renderer/app.js:901, 928-930`. A not-found row can show `Library: <title>` under its "not found" badge and gets `included = false`, which has no effect.

26. **Oddity — DASH "direct" preview is always labelled `audio/flac`.** `electron-main.js:902-904`, whatever the URL serves. Whether a mismatch breaks Chromium playback is unverified.

27. **Oddity — Peaks use the first channel only.** `renderer/app.js:588`. Material only on the right channel draws as silence.

28. **Oddity — Excluded exact-library rows vanish after any batch.** `renderer/app.js:1468-1473` keeps only `notFound`, `failed`, or `!dlStatus && included` rows, so imported exact matches the user never "+ Add"ed are removed whenever any batch finishes. May be intended; not documented.

29. **Oddity — Play button accessibility label never changes.** `renderer/app.js:952, 657-666`: `aria-label="Play"` and `title="Play preview"` stay the same while playing or loading; the waveform canvas is not focusable or labelled; the drop zone isn't keyboard-reachable.

30. **Oddity — Four copies of the title/artist matcher.** `electron-main.js:944-960` (import), `electron-main.js:712-727` (Chrome extension, adds `hiRes`), `tidal_lib.js:580-610` (Spotify, adds a duration score), `bulk_runner.js:13-29, 73-90` (search fallback for rows without an id; never reached from the GUI because not-found rows aren't sent).

31. **Oddity — Retry/redirect quirks in `fetchBuffer`.** `tidal_lib.js:184-185, 199-204`: only 301/302/307 are followed, a relative `Location` isn't resolved, and errors without a `retriable` flag (such as `Too many redirects`) are retried. The download pipeline uses the same helper with its defaults (30 s, 3 retries) while preview uses 60 s, 2 retries; the downloader's DASH-direct URL is not XML-unescaped while the preview's is.

32. **Oddity — Signed CDN URLs and raw TIDAL bodies reach the activity log.** `tidal_lib.js:207, 213, 294`; `renderer/app.js:879`.

33. **Inventory only (not ported) — Chrome-extension path.** `handleExtensionTracks` (`electron-main.js:696-751`) and the `extension:tracks-resolved` listener (`renderer/app.js:1641-1647`) reuse the import matcher and `addTracksToQueue`. The extension was dropped on 21 Oct 2026.

### Concurrency and timing notes

- One import = one IPC invoke containing N sequential HTTP requests, followed by library enrichment. Progress events and the final reply both travel main → renderer over the same webContents IPC, and are expected to arrive in order (unverified, needs a run); the renderer also gates progress on `_tracklistInFlight`.
- The token is read and, if needed, refreshed independently by every preview fetch and every import. Two parallel preloads plus a play fetch can each refresh an expired token and each rewrite the token file. Main uses synchronous file calls, so main itself never reads a half-written file; a download child process reading at the same moment could.
- Network competition: up to 2 preloads + 1 play fetch (each DASH fetch with 8 workers) + import searches + a download batch's child processes, all against TIDAL at once.
- Memory per preview fetch: the whole LOSSLESS track is held about twice in main (chunks + concatenated copy), copied across IPC, copied again for the decode (`ab.slice(0)` on the play path), and expanded to 32-bit float PCM by `decodeAudioData` (very roughly 80–100 MB for a 4-minute stereo track; unverified).
- `renderQueue` rebuilds every row on each add, remove, select, track-start and track-done, repainting each cached waveform (200 rectangles per row).
- The progress loop is restarted by each `play` event and ends at the first frame where the element is paused.
- Debounces: queue save 400 ms, volume save 300 ms, resize redraw 120 ms. An abrupt exit (such as Bug 1) inside a window loses that change.

### Platform-specific behaviour

- **Token location:** packaged builds use `<userData>/token.json` (`~/Library/Application Support/robogears Downloader/token.json` on macOS); dev mode uses `token.json` next to the source. `queue.json` and `settings.json` are always under userData (`app.setName('robogears Downloader')`, `electron-main.js:13`), so dev and packaged runs share the queue but not the token.
- **Retina:** the canvas backing store is scaled by `devicePixelRatio` (2 on Retina Macs).
- **Codecs:** playback and decoding rely on Chromium's media stack (plain FLAC, FLAC-in-fragmented-MP4, AAC-in-MP4). Not checked here.
- **File picker:** on macOS the `accept` list becomes the open panel's type filter; drops bypass it.
- **Default drop behaviour** (navigation) is Chromium's, not the app's.
- No platform branches exist in either flow.

### Porting notes for a native Swift macOS app

**Inputs**
- Make the import area a real drop target for file URLs (`UTType.commaSeparatedText`, `.plainText`, `.utf8PlainText`, `.tabSeparatedText`) and decide what drops elsewhere in the window do (accept them, or reject them). The window never navigates.
- Add **File > Import Tracklist…** with a standard shortcut, backed by `NSOpenPanel` / `.fileImporter` with the same types, so import is reachable by keyboard and from the menu bar.
- Route **Edit > Paste (⌘V)** to import only when the first responder isn't a text field, using the same heuristic (≥ 10 characters and a newline, a comma, or a spaced `- — – |` separator). Give feedback when a paste is ignored or an import is already running.
- Reject non-text files (check the type and look for NUL bytes in the first few KB) and cap the size. Decode UTF-8 (strip the BOM), then fall back to UTF-16 (BOM) and Windows-1252.
- The Exportify link must open the browser only (no file panel).

**Parsing (pure, unit-tested functions)**
- RFC 4180 CSV: quoted fields, embedded newlines, `""` escapes. Take the header from the first non-empty line.
- Header matching: prefer exact names (`track name`, `title`, `song`, then `name`) and an artist **name** column over any column containing `uri`/`id`. Whether to keep today's first-match behaviour is an owner decision. If the export has ISRC and duration columns, consider using them: ISRC lookup (`GET /v1/tracks?isrc=…&countryCode=…`) already exists for Spotify (`tidal_lib.js:560-568`), and duration enables the Spotify matcher's duration score.
- Plain text: separators `-`, `—`, `–`, `|`, tab; title first. Owner decisions: require spaces around `-`, and detect `Artist - Title`.
- De-duplicate on lowercase `title|artist`; skip titles shorter than 2 characters.

**Matching**
- One shared matcher replacing the four copies: today's `normalize` and scoring (100/50/25 title tiers, artist tokens longer than 2 characters matched as substrings, accept title = 100 or title ≥ 25 with artist ≥ 50, stable sort by total, take the first). Consider Unicode-aware normalisation (fold diacritics, keep letters from every script) so non-Latin titles compare properly; that is a behaviour change to agree with the owner.
- Run it as a cancellable Swift `Task` with progress (`done`, `total`) in an `@Observable` model. Show it as inline progress or a sheet with a **Cancel** button, not a window-blocking overlay, and show the library phase separately ("Checking your library…").
- Retry 429/5xx with backoff, refresh the token on 401 mid-run, and record "search failed" separately from "no match" so failed rows can be retried. Optional bounded concurrency (the Spotify path uses 8 workers) if TIDAL's rate limits allow.
- Set `hiRes` from `mediaMetadata.tags` like the other paths; consider showing TIDAL's `version` in the title.

**Credentials**
- Never terminate the process for a missing token: return a typed error that opens TIDAL sign-in, and check sign-in before starting an import or any preview fetch (including the boot preload).
- One token actor with single-flight refresh, so parallel requests share one refresh; store it atomically (or in the Keychain). Keep any rotated `refresh_token` the server returns.

**Queue model**
- `Codable` item: `tidalId: Int?`, `title`, `artist`, `duration: Int`, `source` (`import`/`tidal`/`spotify`), `matchMethod`, `notFound`, `originalTitle`, `originalArtist`, `hiRes`, `libraryMatch {kind, path, libraryTitle}`, `key`, `included`. Transient download state is not persisted.
- Persist to `~/Library/Application Support/robogears Downloader/queue.json` with a 400 ms debounce and an atomic write (`Data.write(options: .atomic)`); report write failures.
- Keep the badge precedence (download state → not found → already in library → similar → source `Import`), exact matches starting excluded with **+ Add**, the `Library: <title>` note, and the `Download (N)` count. Consider letting a not-found row reopen search.

**Preview fetch and playback**
- One Swift service for `playbackinfopostpaywall` + manifest parsing (BT/BTS JSON with `encryptionType == NONE` and `urls[0]`; DASH BaseURL-direct; DASH SegmentTemplate init + `$Number$` segments from `startNumber`, expanding `r + 1`), shared with the downloader instead of duplicated. Use `URLSession`; there's no reason to move audio bytes between processes.
- Spike early: AVFoundation decodes plain FLAC, but whether `AVPlayer`/`AVAudioFile` accept FLAC-in-fragmented-MP4 (the DASH LOSSLESS output) is unverified (needs a run). Fallbacks: remux to a plain `.flac` with the bundled FFmpeg (stream copy) into Caches, or read with `AVAssetReader`. A bounded, cleaned-up temp file in `~/Library/Caches` is likely simpler than holding the track in memory.
- Peaks: read in chunks with `AVAudioFile`/`AVAssetReader` and compute 200 max-abs values normalised to 0…1 without loading the whole PCM. Owner decision: first channel only (today) or the max across channels. Persist peaks per `tidalId` on disk so launches don't re-download.
- Owner decision on background preloading: keep it, limit it (first N rows, on hover, on demand, or a lower-quality stream such as AAC for peaks), and pause it during download batches. Whatever stays: an actor with concurrency 2, deduplicated against in-flight and play fetches, cancelled when a row is removed or the queue is cleared, reusing the preload's file for playback.
- One `PreviewController` owning a single `AVPlayer`/`AVAudioPlayer` with a generation token, so a late load can never start or orphan a second player (fixes Bug 2). Stop on end, on error, when the row is removed (including at batch end), and on Clear all. Same row toggles pause/resume; another row's waveform starts that track at the clicked ratio; clicking or dragging the current row's waveform seeks without changing play/pause; a waveform click on a loading track has a timeout.
- Volume: store the linear slider value, play at its square, and restore the slider from the stored value (fixes Bug 3). Keep volume out of "Reset config".

**Waveform view (`NSView` `draw(_:)` or SwiftUI `Canvas`)**
- 200 bars, height `peak × h × 0.78 × boost`, centred, width `w/200 − 1` (minimum 1 pt). Played vs unplayed are white vs 22 % white on black today; use semantic colours (for example primary label vs tertiary label) so Light, Dark and Increase Contrast all work.
- Hover spotlight: bars within 10 of the pointer grow by up to 45 % with linear falloff, plus a 1 pt pointer line; it's light reacting, not movement, which fits the "nothing moves on hover" rule. Under Reduce Motion, consider dropping the swell and keeping only the line.
- Drive progress with `TimelineView(.animation)` or a display link only while playing. Use `mouseDown`/`mouseDragged`/`mouseUp` (AppKit keeps sending drags outside the view, so no document-level listeners are needed) and clear hover on `mouseUp` outside the view. Redraw on resize. The title keeps its full width and the waveform shrinks.

**Accessibility and keyboard**
- Waveform as an adjustable element (value = position, increment/decrement seeks); play button label switches between Play and Pause; Space toggles the preview of the selected row; the loading indicator respects Reduce Motion; the drop zone is focusable and has a keyboard path through the menu command.

**Not ported (inventory only):** the Chrome extension's `Spotify ext` source, `handleExtensionTracks` (`electron-main.js:696-751`) and the `extension:tracks-resolved` listener (`renderer/app.js:1641-1647`).

### Open questions

1. What does today's Exportify CSV header look like: does an artist-URI/ID column come before `Artist Name(s)`, and does it include ISRC and duration columns? (Needs a sample file; the project docs say CSVs carry no ISRC.)
2. Plain-text order: keep strict `Title - Artist`, or auto-detect `Artist - Title`? Should an unspaced hyphen (`Anti-Hero`) stop counting as a separator?
3. Preloading: keep downloading every queued track in full, limit it, use a lower-quality stream for peaks, persist peaks, and/or pause during download batches?
4. Should not-found rows be re-matchable (manual search, or a retry for rows whose search failed rather than found nothing)?
5. Waveform peaks: first channel only, or the max across channels?
6. Is dropping never-"+ Add"ed exact-library rows at the end of every batch intended (`app.js:1468-1473`)?
7. Should imported rows show Hi-Res and TIDAL's edition (`version`) in the title, as the other add paths partly do?
8. Can AVFoundation play and decode TIDAL's DASH LOSSLESS output (FLAC in fragmented MP4) directly, or must the port remux it? (Needs a spike.)
9. How long do TIDAL access tokens last in practice, and does the refresh reply rotate the refresh token? This decides how much mid-import refresh handling is needed. (Unverified.)
10. Should non-Latin and accented titles be compared with Unicode-aware normalisation in the port (a deliberate behaviour change)?
11. Should a paste outside text fields keep importing silently, or ask first (it can be triggered while a modal is open)?
