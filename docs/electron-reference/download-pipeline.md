## Download pipeline and CLI tools

Scope: `tidal_download.js`, `bulk_runner.js`, `tidal_search.js`, `tidal_check_quality.js`, the `tidal_lib.js` functions they call, and the `electron-main.js` code that starts, watches and cancels a download batch (`bulk:start`, `download:cancel`, `childEnv`, `verifyFfmpegAvailable`, `window-all-closed`). The renderer's handling of the batch events is summarised at the end of Components because the pipeline's exit behaviour drives it. Code version: v0.1.30.

### Overview

This part of the app turns a TIDAL track id into a tagged audio file in the download folder. In the GUI every download, including a single-row retry, goes through one batch path. The renderer sends `bulk:start` with `{ tracks, outDir }`. The main process writes the list to `<userData>/pending-tracklist.json` and starts `bulk_runner.js` as a child process (the Electron binary running as Node). `bulk_runner` handles the tracks one at a time. For each one it starts a fresh `tidal_download.js` child with `<tidalId> <outDir> --skip-library-check` and turns that child's exit code (0, 2 or anything else) into a status. It also prints marker lines (`__TRACK_START__`, `__TRACK_DONE__`) around each track. The `tidal_download` child prints `__TRACK_PROGRESS__` lines as it downloads. The main process reads all of this text, turns marker lines into typed IPC events for the queue rows, and forwards every other non-empty line to the activity log.

For one track, `tidal_download` does this, in order:
1. Gets a valid access token and the country code.
2. Fetches the track's metadata.
3. Builds the file name from the cleaned track title.
4. Skips the track if `<title>.flac` or `<title>.m4a` already exists.
5. Checks the music library (CLI only; GUI batches turn this off).
6. Fetches the album's metadata.
7. Asks TIDAL for a playback manifest, `HI_RES_LOSSLESS` first and then `LOSSLESS`.
8. Decodes the manifest. A BT/BTS manifest holds one direct URL; a DASH manifest holds segment templates.
9. Decides between `.flac` and `.m4a`.
10. Downloads the audio to `<title>.tmp.<m4a|flac>` in the download folder while fetching the 1280×1280 cover at the same time.
11. Runs FFmpeg to copy the audio, without re-encoding, into the final container. FFmpeg also writes the tags and the front cover; the cover reaches it through stdin.
12. Deletes the temp file.
13. For FLAC output, runs an FFmpeg decode check.

Exit code 0 means the track was saved. Exit code 2 means a single track was skipped. Exit code 1 means an error.

`tidal_download.js` can also be run by hand as a command-line tool. That way it accepts TIDAL album and playlist URLs and Spotify track, album and playlist URLs, which the GUI never sends to it. `tidal_search.js` and `tidal_check_quality.js` are small diagnostic command-line tools that only print to the terminal. The GUI never uses them.

### Components

#### A. GUI batch path (main process → bulk_runner → tidal_download)

**A1. `bulk:start` IPC handler** (`electron-main.js:986-1041`)
1. If `activeChild` (module-level) is set, return `{ ok: false, error: 'Another download is already running.' }`.
2. If `outDir` is falsy, return `{ ok: false, error: 'No download folder configured. Pick one in Settings.' }`.
3. Write `path.join(app.getPath('userData'), 'pending-tracklist.json')` = `JSON.stringify({ tracks, outDir }, null, 2)`. These are the full renderer queue items; see Data formats. This write is synchronous and not wrapped in try/catch.
4. `activeChild = spawn(process.execPath, [path.join(__dirname, 'bulk_runner.js'), listPath], { stdio: ['pipe','pipe','pipe'], env: childEnv() })`. No `cwd` is set (an asar path cannot be a working directory). No `'error'` listener is attached. stdin is a pipe that is never written to or closed.
5. stdout and stderr each get their own text buffer. On every `data` event the handler appends the text, splits on `/\r?\n/` and keeps the last (partial) piece for later. Each complete line goes to `dispatchLine` (`:1004-1019`), first match wins:
   - `/^__TRACK_START__:(\d+)$/` → send `bulk:track-start` `{ tidalId: Number(id) }`
   - `/^__TRACK_PROGRESS__:(\d+):(\d+)$/` → send `bulk:track-progress` `{ tidalId: Number, percent: Number }`
   - `/^__TRACK_DONE__:(\d+):(\w+)$/` → send `bulk:track-done` `{ tidalId: Number, status: string }`
   - anything else with `line.length > 0` → send `download:line` with the raw line. Blank lines are dropped. Marker lines never reach the log.
   - A trailing partial line still buffered when the stream ends is never sent.
   - Every `mainWindow.webContents.send` here has no `isDestroyed()` guard.
6. The handler returns a Promise that settles on the child's `'close'` event, which waits for both process exit and EOF on its stdio pipes. On close it:
   - sends `download:done` `{ code }`;
   - sets `activeChild = null`;
   - deletes `listPath`, ignoring errors;
   - resolves `{ ok: code === 0, code }`.
   `code` is `null` when the child was killed by a signal (POSIX cancel).

**A2. `childEnv()`** (`electron-main.js:60-71`)
- Returns `{ ...process.env, ELECTRON_RUN_AS_NODE: '1', FORCE_COLOR: '0', TIDAL_LIBRARY_FOLDER: settings.libraryFolder || '', BULK_RUNNER_PROGRESS: '1' }`.
- Reads `settings.json` each time it is called.
- `TIDAL_TOKEN_PATH` is inherited from `process.env`. `electron-main.js:19-21` sets it to `<userData>/token.json` only when `app.isPackaged`. In dev, `tidal_lib` falls back to `token.json` next to the source.
- `TIDAL_LIBRARY_FOLDER` has no effect on GUI downloads, because `bulk_runner` always passes `--skip-library-check`.

**A3. `download:cancel`** (`electron-main.js:646-653`)
- If `activeChild` is set: `activeChild.kill()` (default signal SIGTERM on POSIX, TerminateProcess on Windows; errors swallowed), then `activeChild = null`, then return `{ ok: true }`.
- Otherwise return `{ ok: false }`.
- Only the `bulk_runner` process is signalled. The running `tidal_download` grandchild and any FFmpeg it started are not. See Bugs.

**A4. `window-all-closed`** (`electron-main.js:548-551`)
- Calls `activeChild.kill()` if a child is running, but does not null `activeChild`.
- Quits the app unless the platform is `darwin`.
- Per Electron's documented behaviour, Cmd+Q or `app.quit()` does not emit `window-all-closed`. Nothing kills the batch on a normal macOS quit.

**A5. `verifyFfmpegAvailable()`** (`electron-main.js:529-546`, called once from `app.whenReady` at `:495`)
- Chooses the FFmpeg path the same way as `tidal_download` (see B1). A throw from `require('ffmpeg-static')` falls back to `'ffmpeg'`.
- Spawns `<path> -version` with `stdio: 'ignore'`.
- Only the `'error'` event is handled (spawn failure such as ENOENT). It sends `download:line` `'⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.'`, guarded by `!mainWindow.isDestroyed()`.
- The exit code is ignored.
- The probe runs right after `createWindow()`, so the renderer may not yet be listening when the error arrives. Unverified (needs a run): whether that message is ever seen.

**A6. `bulk_runner.js`**

- `normalize(s)` (`:11`): `(s||'').toLowerCase()`, then `/[^a-z0-9 ]/g → ' '`, then `/\s+/g → ' '`, then `trim()`. Every non-ASCII letter becomes a space.
- `scoreMatch(item, wantTitle, wantArtist)` (`:13-29`):
  - `itemTitle = normalize(item.title)`
  - `itemArtists = item.artists[].name`, each normalized, joined with `' '`
  - `wt = normalize(wantTitle)`, `wa = normalize(wantArtist)`
  - `titleScore`: 100 if equal; else 50 if either string `startsWith` the other; else 25 if either `includes` the other; else 0
  - `waTokens` = `wa.split(' ')` keeping tokens longer than 2 characters. `artistScore = round(matched / count × 100)`, where a token matches if it is a substring of `itemArtists`; 0 if there are no tokens.
  - Returns `{ titleScore, artistScore, total }`. There is no duration term.
- `runDownload(trackId, outDir)` (`:33-47`):
  - `spawn(process.execPath, [<dir>/tidal_download.js, String(trackId), outDir, '--skip-library-check'], { stdio: 'inherit', env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', FORCE_COLOR: '0' } })`. No cwd.
  - Because stdio is inherited, the grandchild writes straight into the pipes the main process reads, so its `__TRACK_PROGRESS__` lines and log lines reach the main process without passing through `bulk_runner`.
  - Resolves with the `'close'` exit code (`null` if signalled). No `'error'` listener.
- Main IIFE (`:49-118`):
  1. `listPath = argv[2]`. If missing: stderr `Usage: node bulk_runner.js <tracklist.json>`, exit 1.
  2. `{ tracks, outDir } = JSON.parse(readFileSync(listPath,'utf8'))`. If `!tracks?.length`: stderr `No tracks in list.`, exit 1.
  3. `cred = loadCred(); token = await getToken(cred); country = await getCountryCode(cred)`. This always runs and may refresh and rewrite the token file. The token and country are only used by the search fallback below. A failure here prints `Fatal: <msg>` and exits 1 before any marker is printed.
  4. Prints `\n=== Batch download → ${outDir} ===\n`, then `${tracks.length} tracks queued.\n`.
  5. For each track `t`, one at a time:
     - Print `[${i+1}/${n}] ${t.title||'?'} — ${t.artist||'?'}`.
     - `trackId = t.tidalId`.
     - If `!trackId && t.title && t.artist`: `searchTracks(`${t.title} ${t.artist}`, token, country, 10)`. Score each item, keep `titleScore === 100 || (titleScore >= 25 && artistScore >= 50)`, and sort by `total` descending (stable). If anything is left, take the first and print `    → matched (id X, score Y)`; otherwise print `    → no good match`. A search exception prints `    → search error: <msg>`. No GUI path sends an item without a `tidalId` (unmatched items are flagged `notFound` and filtered out first), so this branch is effectively CLI-only.
     - If there is still no `trackId`: `notFound++`. The line `__TRACK_DONE__:${t.tidalId}:notFound` is printed only `if (t.tidalId)`, which is always false here, so it never prints. Print `''` and continue.
     - Print `__TRACK_START__:${trackId}`.
     - `code = await runDownload(trackId, outDir)`. Map 0 → `downloaded` (ok++), 2 → `skipped` (skipped++), anything else including `null` → `failed` (failed++).
     - Print `__TRACK_DONE__:${trackId}:${status}`, then `''`.
  6. Print `\n=== Batch complete: ${ok} downloaded, ${skipped} skipped, ${failed} failed, ${notFound} not found ===`. The process then ends normally with exit code 0, however many tracks failed.
  7. Any rejection prints `Fatal: <msg>` to stderr and exits 1.

#### B. `tidal_download.js`

**B1. Module load** (`:18-40`)
- `_ffmpegStatic = require('ffmpeg-static')` in a try/catch (null on throw). The package exports an absolute path to its downloaded binary.
- `_ffmpegUnpacked = _ffmpegStatic.replace('app.asar', 'app.asar.unpacked')`. This is a plain-string replace of the first match only, so it does nothing in dev.
- `ffmpegPath` is chosen in this order:
  - `_ffmpegUnpacked`, if it exists;
  - else `_ffmpegStatic`, if it exists;
  - else the bare string `'ffmpeg'`, which `spawn` looks up on the inherited `PATH`.
  The choice is never logged.
- Constants: `CONCURRENCY_DEFAULT = 8`, `FLAC_QUALITIES = ['HI_RES_LOSSLESS','LOSSLESS']`, `DEFAULT_OUT_DIR = 'Z:\\Downloads'`.
- `main()` runs at module load, so the file cannot be `require`d without starting the CLI. This is why `electron-main.js` keeps its own copy of the DASH parser.

**B2. `parseArgs(argv)`** (`:44-67`)
- Defaults: `quality: null`, `concurrency: 8`, `force: false`, `debug: !!process.env.DEBUG`, `help: false`, `flacOnly: false`, `skipLibraryCheck: false`. Any non-empty `DEBUG`, including `"0"`, turns debug on.
- Single pass, exact string matches:
  - `--help` or `-h` → help
  - `--force`
  - `--debug`
  - `--flac-only`
  - `--skip-library-check`
  - `--quality` → takes the next token as-is (`undefined` if there is none; it consumes the next token even if that is a flag or the URL)
  - `--concurrency` → `parseInt(next, 10)` (NaN if not numeric)
- Everything else, including unknown `--xyz` flags, is positional. Flags may come before or after positionals. `main()` uses `positional[0]` (input) and `positional[1]` (outDir) and ignores the rest.

**B3. `printHelp()`** (`:69-103`)
Prints, in order:
- `TIDAL FLAC downloader` and the usage line `node tidal_download.js <track-or-album-or-playlist-url-or-id> [outDir] [flags]`.
- The accepted inputs: TIDAL track id, track URL, album URL, playlist URL/UUID; Spotify track, album and playlist URLs.
- A paragraph claiming Spotify goes through "Spotify's anonymous web API → ISRC match … → fall back to title+artist+duration search". This is stale: the code scrapes embed pages, which carry no ISRC.
- Flags: `--quality LOSSLESS | HI_RES_LOSSLESS`, `--concurrency N` (default 8), `--force`, `--flac-only`, `--debug`, `--help, -h`. `--skip-library-check` is not listed.
- A "Default quality behavior" paragraph: Hi-Res FLAC → CD FLAC → `.m4a` 320 kbps AAC, and `--flac-only` refuses the AAC fallback.
- "First-time setup: node tidal_auth_node.js".

The header comment (`:1-16`) lists only `--quality`, `--concurrency`, `--force`, `--debug` and `--help`.

**B4. `main()`** (`:663-724`)
1. `parseArgs(process.argv.slice(2))`.
2. If `help`: `printHelp()`, exit 0. If there is no positional: `printHelp()`, exit 1.
3. If `flags.quality` is truthy and not in `FLAC_QUALITIES`: stderr `Invalid --quality. Must be one of: HI_RES_LOSSLESS, LOSSLESS`, exit 1. `HI_RES` is rejected here even though B5 treats it as FLAC.
4. `parsed = lib.parseInputUrl(positional[0])`. If null: stderr `Cannot parse input: "<input>"` and `Provide a TIDAL or Spotify track/album/playlist URL, or a numeric TIDAL track ID.`, exit 1.
5. `outDir = positional[1] ? path.resolve(positional[1]) : DEFAULT_OUT_DIR`. The default is not resolved. If `outDir` does not exist, `fs.mkdirSync(outDir, { recursive: true })`. In the GUI this silently re-creates a deleted download folder, once per track.
6. `cred = lib.loadCred()`. A missing or empty token file prints to stderr and calls `process.exit(1)`.
7. `singleTrackCatcher(fn)` turns an `AacOnlyError` into `null` and adds its `trackInfo` to `aacOnly`; other errors are re-thrown.
8. Dispatch:

   | source | type | handler | result kept? |
   |---|---|---|---|
   | spotify | track | `downloadSpotifyTrack` (wrapped in `singleTrackCatcher`) | yes |
   | spotify | album | `downloadSpotifyAlbum` | no |
   | spotify | playlist | `downloadSpotifyPlaylist` | no |
   | tidal | track | `downloadTrack` (wrapped in `singleTrackCatcher`) | yes |
   | tidal | album | `downloadAlbum` | no |
   | tidal | playlist | `downloadPlaylist` | no |

9. If `trackResult?.skipped`: `process.exitCode = 2`.
10. `handleAacSummary(aacOnly)`.
11. `main().catch`: stderr `\nError: <message>` (plus `e.stack` if `process.env.DEBUG`), then `process.exit(1)`.

Exit-code contract:

| code | when |
|---|---|
| 0 | single track saved; album or playlist run finished, even with failed tracks; Spotify track with no TIDAL match; single AAC-only track under `--flac-only`; FLAC integrity check failed but file kept |
| 2 | single-track skip: `<title>.flac` or `<title>.m4a` already in outDir, or (CLI only) an exact or similar library match |
| 1 | usage or validation error, missing token file, any uncaught error (token refresh, track info, manifest, download, FFmpeg, file system). An uncaught exception thrown inside an HTTP callback also ends the process with code 1. |

**B5. `downloadTrack(trackId, outDir, cred, flags, { albumPreFetched = null })`** (`:346-469`)
1. `token = await lib.getToken(cred)`. This may refresh the token and rewrite the token file.
2. `countryCode = await lib.getCountryCode(cred)`.
3. `info = await lib.getTrackInfo(trackId, token, countryCode)`. A non-200 response throws `Track info failed: <status> <body>`.
4. Builds display strings with `lib.sanitize`:
   - `artist = sanitize(info.artists?.[0]?.name || info.artist?.name)`
   - `title = sanitize(info.title)`
   - `album = sanitize(info.album?.title)`
   TIDAL's separate `version` field is never read.
5. `flacPath = outDir/<title>.flac`, `m4aPath = outDir/<title>.m4a`.
6. Unless `--force`, the existence check:
   - If `flacPath` exists: log `  ⏭  <title>.flac already in downloads folder — skipping (use --force to overwrite)` and return `{ path: flacPath, skipped: true }`.
   - Then the same for `m4aPath` (`.m4a` in the message).
   This only tests that the file exists: no size, format or integrity check, case follows the file system, and the result does not depend on which format the new download would produce.
7. Unless `--force` or `--skip-library-check`:
   - `artistStr` = all `info.artists[].name` joined with `', '`.
   - `existing = await lib.findInLibrary(info.title, artistStr, info.duration)`. Note that the title is passed raw, not sanitized.
   - `kind === 'exact'` → log `  📁 Already in music library: <path>` and `     Skipping download (use --force to download anyway)`, then return `{ path: existing.path, skipped: true }`.
   - `kind === 'similar'` → log `  ⚠ Similar version in music library: <libraryTitle || path>` and `     Skipping. Use --force or include via GUI to download anyway.`, then return `{ path: existing.path, skipped: true }`.
8. Log `  <artist> — <title> (<album>)`, using the sanitized strings.
9. `albumInfo = albumPreFetched ?? (info.album?.id ? await lib.getAlbumInfo(info.album.id, token, countryCode) : null)`. `getAlbumInfo` returns null on any non-200.
10. `raw = await getBestManifest(trackId, token, countryCode, flags.quality, flags.debug)` (B6).
11. `manifest = parseManifest(raw)` (B7).
12. Choose the output format:
    - `decodedManifest = base64-decode(raw.manifest)` as UTF-8.
    - `isFlacOutput` is true if any of these holds:
      - `{'LOSSLESS','HI_RES_LOSSLESS','HI_RES'}` contains `raw.audioQuality`;
      - `(manifest.codec || '').toLowerCase()` includes `'flac'`;
      - `/codecs="flac"/i` matches `decodedManifest`.
13. With `--debug`, log five lines: `[debug] manifest type`, `[debug] audioQuality`, `[debug] codec: …, mimeType: …`, `[debug] segments: <count or 'direct'>`, `[debug] isFlacOutput`.
14. If `!isFlacOutput`:
    - with `--flac-only`: log `  ⚠ AAC-only on TIDAL — skipped (--flac-only mode).` and `throw new lib.AacOnlyError(info)`;
    - otherwise log `  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).`
15. Paths:
    - `finalPath = outDir/<title>.<flac|m4a>`
    - `tmpExt = manifest.mimeType?.includes('mp4') ? 'm4a' : 'flac'`
    - `tmpPath = outDir/<title>.tmp.<tmpExt>`
    A DASH lossless track therefore downloads to `.tmp.m4a` (FLAC inside fragmented MP4) and ends up as `.flac`.
16. `onProgress` exists only if `process.env.BULK_RUNNER_PROGRESS` is truthy. It clamps `pct` to 0..100. If the value differs from the last one printed (initially −1), it prints `__TRACK_PROGRESS__:<trackId>:<pct>` with `console.log`. `trackId` is the string as received.
17. Start both at once:
    - `audioPromise` = `downloadSegmentsParallel(manifest, tmpPath, flags.concurrency, onProgress)` for `dash_segments`, else `downloadDirect(manifest.url, tmpPath, onProgress)`;
    - `coverPromise = lib.fetchCover(info.album?.cover)`, which never rejects.
18. `await audioPromise`, then `coverBuf = await coverPromise`. With `--debug`, log the cover size in KB.
19. `remuxToFlac(tmpPath, finalPath, info, albumInfo, coverBuf)`. On error:
    - stderr `  ✘ FFmpeg failed: <message>`;
    - stdout `     Raw file kept at: <tmpPath>`;
    - re-throw. The temp file stays on purpose.
20. `fs.unlinkSync(tmpPath)`, ignoring errors.
21. If `isFlacOutput`: `await verifyFlac(finalPath)`. Its result is ignored.
22. `statSync(finalPath)`; log `  ✓ Saved: <basename> (<size/1024/1024 to 1 decimal> MB)`; return `{ path: finalPath, skipped: false }`.

Network calls per track, in order: an optional token refresh (POST); an optional `/v1/users/{id}` (only if the country code is not cached); `/v1/tracks/{id}`; `/v1/albums/{id}` (skipped when pre-fetched); `playbackinfopostpaywall` once or twice; then the cover in parallel with the audio (DASH init plus N segments, or one direct GET).

**B6. `getBestManifest(trackId, token, countryCode, forceQuality, debug)`** (`:325-342`)
- `tiers = forceQuality ? [forceQuality] : ['HI_RES_LOSSLESS','LOSSLESS']`.
- For each tier, call `lib.getPlaybackInfo(trackId, token, tier, countryCode)`. The first success returns `{ manifest, manifestMimeType, audioQuality }`; with `debug` it also logs `  [debug] Got <audioQuality> at request tier <tier>`.
- Any throw (401, other non-200, network, timeout) is swallowed. It is logged only with debug, as `  [debug] <tier> unavailable: <msg>`, and the next tier is tried.
- If every tier fails it throws `Could not get playback manifest at any quality.` and the underlying reason is lost.
- It never requests `HIGH` or `LOW`. The `.m4a` fallback relies on TIDAL answering a lossless request for an AAC-only track with an AAC manifest.

**B7. `parseManifest({ manifestMimeType, manifest })`** (`:107-169`)
1. If `manifest` is falsy, throw `No manifest in playback response`.
2. `decoded = Buffer.from(manifest,'base64').toString('utf8')`.
3. BT family (`manifestMimeType` starts with `'application/vnd.tidal.'`, which covers `.bt` and `.bts`):
   - `json = JSON.parse(decoded)`; a SyntaxError propagates.
   - If `json.encryptionType` is set and not `'NONE'`, throw `Track is DRM-encrypted (<type>)`.
   - If `json.urls` is missing or empty, throw `BT-family manifest (<mime>) had no urls field: <first 200 chars of decoded>`.
   - Return `{ type:'direct', mimeType: json.mimeType, url: json.urls[0], codec: json.codecs, raw: decoded }`. Only `urls[0]` is used.
4. DASH (`manifestMimeType === 'application/dash+xml'`):
   - `baseUrl` = trimmed group 1 of `/<BaseURL[^>]*>(.*?)<\/BaseURL>/s`, or `''` if there is no match.
   - If `decoded` does not contain the substring `SegmentTemplate` and `baseUrl` is non-empty, return `{ type:'direct', url: baseUrl, mimeType:'audio/flac', raw }`. This `baseUrl` is not XML-unescaped and there is no `codec` field.
   - Otherwise take the first match of each of `/initialization="([^"]+)"/`, `/media="([^"]+)"/`, `/mimeType="([^"]+)"/` and `/codecs="([^"]+)"/`. If `initialization` or `media` is missing, throw `Could not parse MPEG-DASH segment template.`
   - Segment numbers:
     - `segNum = parseInt(first /startNumber="(\d+)"/)`, or 1 if absent;
     - for every match of `/<S\b[^>]*\/>/g`, in document order: `repeat = parseInt(/\br="(\d+)"/)` (0 if absent), then push `segNum++` `repeat + 1` times;
     - the `d=` and `t=` attributes are ignored. A negative `r` such as `r="-1"` fails `\d+` and counts as 0. All `<S>` elements in the whole document are counted, even if there are several Representations.
     - If no segments were found, throw `No segments found in MPEG-DASH manifest.`
   - `xmlUnescape` replaces `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, in that order.
   - Return `{ type:'dash_segments', baseUrl: unescape(baseUrl), initTemplate: unescape(init), mediaTemplate: unescape(media), mimeType: mimeMatch || 'audio/flac', codec: codecMatch || '', segments: number[], raw: decoded }`.
5. Any other mime type throws `Unknown manifest type: <mime>`.

DASH encryption (`ContentProtection`) is never checked.

**B8. `downloadSegmentsParallel(manifest, dest, concurrency, onProgress)`** (`:173-208`)
1. `initBuf = await lib.fetchBuffer(baseUrl + initTemplate)` (30 s idle timeout, 3 retries). This finishes before any media segment starts and does not count toward progress.
2. Workers share `nextIdx` and `completed` counters. Each loop:
   - `i = nextIdx++`; return when `i >= segments.length`;
   - `segUrl = baseUrl + mediaTemplate.replace('$Number$', segments[i])` (plain concatenation, first `$Number$` only; no `$Number%0Nd$`, `$Time$` or `$RepresentationID$`);
   - `results[i] = await lib.fetchBuffer(segUrl)`, so results stay in manifest order;
   - `completed++`;
   - if `process.stdout.isTTY`, write `\r    Downloaded <completed>/<total> segments...`;
   - if `onProgress` is set, call `onProgress(floor(completed / total × 100))`.
3. `workerCount = Math.min(concurrency, segments.length)`; `await Promise.all(workers)`. The first rejection rejects the call, but sibling workers are not cancelled and keep fetching.
4. If TTY, write `\n`. Then `fs.writeFileSync(dest, Buffer.concat([initBuf, ...results]))`. The whole track is held in memory and written in one non-atomic write.

**B9. `downloadDirect(url, dest, onProgress)`** (`:215-256`)
1. `doGet(u, redirects = 0)`. If `redirects > 5`, reject `Too many redirects`.
2. The module is `https` if `u.startsWith('https')`, else `http`, chosen again on every hop. GET with header `User-Agent: okhttp/5.3.2` only.
3. Status 301, 302, 303, 307 or 308 with a `Location` header: drain the body and recurse with the `Location` value as-is. A relative `Location` is not resolved, and `http.get` throws inside the callback.
4. Any other status that is not 200: drain and reject `HTTP <status> for <u>`.
5. `total = parseInt(content-length || '0') || 0`. `fs.createWriteStream(dest)` truncates any existing file. On each `data` chunk, add to `downloaded` and call `onProgress(total > 0 ? floor(downloaded / total × 100) : 0)`. Pipe the response to the file. On the write stream's `finish`: `out.close()`, then `onProgress(100)`, then resolve. `error` on the write stream or the response rejects.
6. `req.on('error')` rejects. `req.setTimeout(60000)` is a 60 s socket idle timeout; when it fires, the request is destroyed with `Error('Download timed out')`.

No retries. Received bytes are never compared with Content-Length. On failure the partial temp file is neither closed explicitly nor deleted.

**B10. `runFfmpeg(args, stdinBuffer = null)`** (`:260-273`)
- `stdio` is `['pipe','ignore','pipe']` with a buffer, otherwise `['ignore','ignore','pipe']`. `spawn(ffmpegPath, args, { stdio })`: no cwd, no timeout.
- All of stderr is collected as text.
- `'error'` rejects (for example ENOENT).
- On `'close'`: exit code 0 resolves; anything else rejects `ffmpeg exited <code>: <last 500 chars of stderr>`.
- With a buffer: stdin errors such as EPIPE are swallowed, and `p.stdin.end(buffer)` writes the whole buffer and closes stdin.

**B11. `remuxToFlac(srcTmp, dst, info, albumInfo, coverBuf)`** (`:275-310`). The name is historical; it is also used for `.m4a` output.

`releaseDate = albumInfo?.releaseDate || info.album?.releaseDate || info.streamStartDate || ''`

Tags, in insertion order. Each is added only when its value is non-empty.

| key | value |
|---|---|
| `title` | `info.title` |
| `artist` | `info.artists[].name` joined `', '`, else `info.artist?.name` |
| `album` | `info.album?.title` |
| `album_artist` | `albumInfo?.artist?.name` → `info.album?.artist?.name` → `info.artists?.[0]?.name` |
| `track` | `String(info.trackNumber)` if truthy |
| `disc` | `String(info.volumeNumber)` if truthy |
| `date` | `releaseDate.slice(0,4)`: the year only |
| `copyright` | `albumInfo?.copyright || info.copyright` |
| `isrc` | `info.isrc` |

Exact FFmpeg argument list, in order:
1. `-y -i <srcTmp>`
2. if cover: `-f mjpeg -i pipe:0`
3. `-map 0:a`
4. if cover: `-map 1:v -disposition:v attached_pic`
5. `-c:a copy`
6. if cover: `-c:v copy`
7. if cover: `-metadata:s:v "title=Album cover" -metadata:s:v "comment=Cover (front)"`. FFmpeg's FLAC muxer maps the stream `comment` onto the ID3v2 picture-type names, so this writes PICTURE type 3 (front cover) instead of 0 (other); Rekordbox needs type 3. The stream `title` becomes the picture description.
8. for each non-empty tag: `-metadata <key>=<value>`
9. `<dst>`

There is no `-loglevel`, `-map_metadata`, `-movflags` or `-fflags +bitexact`. The output container follows the file extension. Then `runFfmpeg(args, coverBuf)` runs, so the JPEG goes in on stdin only when a cover was fetched. FFmpeg writes straight to the final path.

**B12. `verifyFlac(filePath)`** (`:313-321`)
- Runs `ffmpeg -v error -i <file> -f null -`. Exit 0 → `true`.
- On rejection: stderr `  ⚠ FLAC integrity check failed: <last line of the error message>` and return `false`. The last line is often empty, because FFmpeg's stderr usually ends with a newline.
- The caller ignores the result; the file is kept and the exit code is unaffected.

**B13. `handleAacSummary(list)`** (`:478-486`)
- Does nothing if the list is empty.
- Otherwise prints `\n⚠ <n> track<s> skipped (--flac-only): TIDAL has no FLAC master for them:`, then `    - <artists[0].name || artist.name || '?'> — <title>` per track, then `Re-run without --flac-only to grab them as .m4a (320 kbps AAC).`

**B14. CLI-only multi-track paths.** Each fetches its own token and country code, processes tracks one at a time in the same process, and writes flat into `outDir`. None of them affects the exit code.
- `downloadAlbum(albumId)` (`:490-522`):
  - `getAlbumInfo`; if null, throw `Album <id> not found`.
  - Prints `\n=== Album: <artist.name> — <title> ===` and `    Released: <releaseDate||'unknown'> | Output: <outDir>\n`.
  - Gets the album items, mapped `it.item || it` and keeping only `t && t.id && t.type !== 'video'`. Prints `Found <n> tracks.\n`.
  - Per track: prints `[i/n]` and calls `downloadTrack(..., { albumPreFetched: albumInfo })`.
    - `result.skipped` → skipped++, else ok++.
    - `AacOnlyError` → added to the list.
    - Other errors → stderr `  ✘ <t.title>: <msg>`, failed++.
  - Summary `\nAlbum complete: <ok> downloaded, <failed> failed, <aac> AAC-only, <n-ok-failed-aac> skipped.` The skipped figure is correct here, though the local `skipped` variable is unused.
- `downloadPlaylist(uuid)` (`:627-659`):
  - `getPlaylistInfo`; if null, throw `Playlist <uuid> not found`.
  - Prints `\n=== Playlist: <title> ===` and `    Output: <outDir>\n`, then gets the items with the same filter.
  - No `albumPreFetched`, so album info is fetched for every track.
  - `ok++` after any return, so skipped tracks count as downloaded and the "skipped" figure is always 0.
  - Summary `\nPlaylist complete: … downloaded, … failed, … AAC-only, … skipped.`
- `downloadSpotifyTrack(id)` (`:526-541`):
  - Prints `Fetching Spotify track <id>...`; `sp = getSpotifyTrack(id)`; prints `  Spotify: <artists> — <name>`.
  - `match = spotifyTrackToTidal(sp, token, cc)`. If null: print `  ✗ No TIDAL match found.` and return null (exit 0).
  - Otherwise print `  → TIDAL match (<method>): id <id>` and return `downloadTrack(match.track.id, …)`.
- `downloadSpotifyPlaylist(id)` (`:543-584`):
  - Prints `Fetching Spotify playlist <id>...`, `\n=== Spotify playlist: <name> ===`, `    Tracks: <n> | Owner: <display_name||'?'>`.
  - If `_embedCapped`, prints `    ⚠ Spotify embed caps at 100 tracks. If this playlist has more,` and `      the rest won't be downloaded by this run.`
  - Then prints `''` and `    Output: <outDir>\n`.
  - Per track: prints `[i/n] <artists> — <name>`, then matches.
    - No match → `    ✗ No TIDAL match`, notFound++.
    - Otherwise prints `    → TIDAL (<method>[, score <score>]): id <id>`, runs `downloadTrack`, then ok++. Skips also count as ok.
    - `AacOnlyError` → added to the list.
    - Other errors → stderr `    ✘ <msg>`, failed++.
    - A blank line after each track, except after an AAC-only `continue`.
  - Summary `\nPlaylist complete: <ok> downloaded, <notFound> not on TIDAL, <aac> AAC-only, <failed> errored.`
- `downloadSpotifyAlbum(id)` (`:586-625`):
  - Same as the Spotify playlist, but the header prints `\n=== Spotify album: <artists> — <name> ===` and `    Tracks: <n>\n`.
  - Before matching each track it calls `getSpotifyTrack(t.id)`, ignoring errors and falling back to `t`. The comment says this is "for ISRC", but the embed scraper never returns one, so it is one wasted request per track.
  - The match line has no score.
  - Summary `\nAlbum complete: … downloaded, … not on TIDAL, … AAC-only, … errored.`

#### C. `tidal_lib.js` functions this area depends on

**C1. Credentials** (`:13, 48-119`)
- `TOKEN_FILE = process.env.TIDAL_TOKEN_PATH || <dir of tidal_lib.js>/token.json`.
- `loadCred()`:
  - If the file is missing: stderr `token.json not found. Run tidal_auth_node.js first.` and `process.exit(1)`.
  - Parses the JSON. An array is used as-is; an object is wrapped in an array. Invalid JSON throws.
  - An empty array: `No credentials in token.json. Run tidal_auth_node.js first.` and exit 1.
  - Returns `entries[0]`.
- `getToken(cred)`:
  - Returns `cred.access_token` when `access_token` and `expires_at` are set and `Date.now() < expires_at`.
  - Otherwise calls `refreshToken`: POST `https://auth.tidal.com/v1/oauth2/token` with a form-urlencoded body `client_id=<cred.client_ID>&refresh_token=…&grant_type=refresh_token&scope=r_usr%2Bw_usr%2Bw_sub`. (`formEncode` percent-encodes the literal `r_usr+w_usr+w_sub`.) It uses HTTP Basic auth `client_ID:client_secret` from the token file.
  - A non-200 response throws `Token refresh failed: <status> <body>`.
  - On success it sets `access_token`, sets `expires_at = now + (expires_in || 3600) × 1000 − 60000`, and copies `json.user.countryCode` if `cred.countryCode` was not set.
  - A new `refresh_token` in the response is ignored.
  - Then `saveCred`.
- `saveCred(cred)`: re-reads the file, merges `cred` into entry 0, and writes it pretty-printed with 4-space indentation. The write is not atomic.
- `getCountryCode(cred)`:
  - Returns the cached `cred.countryCode` if present.
  - Otherwise calls `GET /v1/users/<userID>?countryCode=US`. A 200 response with a `countryCode` is cached and saved.
  - Any failure falls back to `'US'`.
- The TIDAL client credentials used for the first sign-in are four base64-encoded constants at `tidal_auth_node.js:17-20` (`AUTH_CLIENT_ID`, `AUTH_CLIENT_SECRET`, `REQUEST_CLIENT_ID`, `REQUEST_CLIENT_SECRET`). Their values are deliberately not reproduced. The pipeline itself only uses the `client_ID` and `client_secret` stored in the token file.

**C2. HTTP helpers** (`:123-232`)
- `httpsRequest(opts, body, { auth })`:
  - Headers, in this order: `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, then `opts.headers`, which may override the first three.
  - With a body: `Content-Type` defaults to `application/x-www-form-urlencoded`, and `Content-Length` is set.
  - With `auth`: `Authorization: Basic base64(id:secret)`.
  - Resolves `{ status, body: string }` for any status code.
  - Idle timeout `opts.timeout || 30000`; on timeout the request is destroyed with `Request timeout after <n>ms`.
  - No retries.
- `tidalGet(path, token, params)`:
  - GET `https://api.tidal.com` + `path` + `?` + `k=encodeURIComponent(v)` pairs joined with `&`, in insertion order. Keys are not encoded.
  - Headers `Authorization: Bearer <token>` and `X-Tidal-Platform: android`.
  - 30 s timeout.
- `fetchBuffer(url, { timeout = 30000, retries = 3 })`:
  - Tries `fetchBufferOnce` for `attempt = 0..retries`.
  - It stops if `e.retriable === false` or this was the last attempt.
  - Otherwise it waits `min(1000 × 2^attempt, 8000)` ms (1 s, 2 s, 4 s with the defaults) and tries again.
  - Rejects with the last error.
- `fetchBufferOnce(url, timeout)`:
  - The `http`/`https` module is chosen once, from the original URL.
  - It follows 301, 302 and 307 only (max 5 hops), using `Location` as-is.
  - 429 or ≥500 → retriable `HTTP <s> for <u>`. Any other non-200 → non-retriable `HTTP <s> for <u>`.
  - Collects the chunks into one Buffer.
  - A socket idle timeout gives a retriable `Request timeout after <n>ms`. Network errors are marked retriable. `Too many redirects` has no flag, so it is retried too.
  - Sends only the `User-Agent: okhttp/5.3.2` header.

**C3. TIDAL API wrappers** (`:236-302`). All go through `tidalGet`, and ids are inserted into the path unencoded.

| function | request | non-200 |
|---|---|---|
| `getTrackInfo` | `GET /v1/tracks/{id}?countryCode=CC` | throws `Track info failed: <s> <body>` |
| `getAlbumInfo` | `GET /v1/albums/{id}?countryCode=CC` | returns `null` |
| `getAlbumItems` | `GET /v1/albums/{id}/items?countryCode=CC&limit=100&offset=N`, paged until a page has fewer than 100 items | throws `Album items failed: …` |
| `getPlaylistInfo` | `GET /v1/playlists/{uuid}?countryCode=CC` | returns `null` |
| `getPlaylistItems` | `GET /v1/playlists/{uuid}/items?countryCode=CC&limit=100&offset=N`, same paging | throws `Playlist items failed: …` |
| `getPlaybackInfo(id, token, q='HI_RES_LOSSLESS', cc)` | `GET /v1/tracks/{id}/playbackinfopostpaywall?countryCode=CC&audioquality=Q&playbackmode=STREAM&assetpresentation=FULL` | 401 → `Unauthorized — token may be invalid`; other → `Playback info failed: <s> <body>` |
| `searchTracks(q, token, cc, limit=10)` | `GET /v1/search/tracks?query=…&limit=10&countryCode=CC` | throws `Search failed: …` |

**C4. Input parsing, file names, cover, AAC error**
- `parseInputUrl(input)` (`:457-463`):
  - Tries Spotify first: `input.trim()` against `/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i`.
  - Then TIDAL on the trimmed input:
    - `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i`; the type is lowercased.
    - else `/^\d+$/` → TIDAL track.
    - else `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i` → TIDAL playlist.
  - Else `null`.
  - Returns `{ source, type, id }`.
  - The TIDAL regex takes the first `type/id` pair in the string. A URL like `…tidal.com/album/123/track/456` therefore resolves to the album.
- `sanitize(str)` (`:616-618`): `(str || 'unknown').replace(/[\\/:*?"<>|]/g,'_').replace(/\s+/g,' ').trim()`. It does not limit length, strip control characters or leading dots, or handle Windows reserved names.
- `coverUrl(coverId, size = 1280)` returns `https://resources.tidal.com/images/<coverId with every '-' → '/'>/1280x1280.jpg`, or `null` if there is no id.
- `fetchCover(coverId)` = `fetchBuffer(url, { retries: 1 })`: at most 2 attempts, 1 s backoff, 30 s timeout. Returns `null` on any error.
- `class AacOnlyError extends Error`: message `Track is AAC-only on TIDAL`, `name = 'AacOnlyError'`, `.trackInfo` = the TIDAL track JSON.

**C5. Spotify embed scrape and matcher** (`:472-611`). Used only by the CLI Spotify paths here.
- `fetchSpotifyEmbed(type, id)`:
  - GET `https://open.spotify.com/embed/<type>/<id>` with `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36` and `Accept: text/html`. The `Accept-Encoding: identity` default still applies.
  - Extracts `/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/`, parses it and returns `props.pageProps.state.data.entity`.
  - Errors: `Spotify <type> embed failed: HTTP <n>`, `No __NEXT_DATA__ in Spotify <type> embed`, `Unexpected Spotify embed shape for <type>/<id>`.
- `getSpotifyTrack(id)` → `{ id, name: e.name||e.title, artists: e.artists, else the subtitle split on commas outside parentheses, duration_ms: e.duration, external_ids: {}, album: null }`.
- `getSpotifyAlbum(id)` → `{ id, name, artists, tracks: { items: [{ id from 'spotify:track:<id>' uri, name: title, artists (subtitle, else album artists), duration_ms, external_ids: {}, album: { name } }] } }`.
- `getSpotifyPlaylist(id)` → `{ id, name, description, owner: { display_name: subtitle }, tracks: [...], _embedCapped: tracks.length >= 100 }`.
- `spotifyTrackToTidal(sp, token, cc)`:
  - If `external_ids.isrc` is set (never, with the embed): `GET /v1/tracks?isrc=…&countryCode=…` and take `items[0]`, method `'isrc'`.
  - Otherwise search `"<name> <artists joined by ' '>"` with limit 10.
  - Scoring: title and artist scores as in A6, plus `durationScore` = 50 if the gap is under 3 s, 25 if under 8 s, else 0.
  - Accept `titleScore === 100 || (titleScore >= 25 && artistScore >= 50)` and sort by total descending.
  - Returns `{ track, method:'search', score: total }` or `null`.

**C6. `findInLibrary(title, artist, _duration)`** (`:788-833`, scan `:674-757`). CLI only here; full detail belongs to the library section.
- Returns `null` when:
  - the title is empty;
  - the library has no entries. `LIBRARY_PATH` comes only from env `TIDAL_LIBRARY_FOLDER`, default `''`, so a plain CLI run never checks;
  - the core-normalized title is shorter than 3 characters.
- Checks, first hit wins:
  1. metadata title (full form) equal **and** artists agree (both non-empty and one contains the other) → `exact`;
  2. metadata title equal alone → `similar`;
  3. filename title or full filename equal → `similar`;
  4. core (suffix-stripped) metadata or filename title equal → `similar`.
- Returns `{ kind, path, libraryTitle }`.
- A standalone process scans the whole library on the first call (8 parallel tag reads) and caches the result for the process lifetime only.

#### D. Diagnostic CLIs

**`tidal_search.js`** (`:1-35`)
1. `query = argv.slice(2).join(' ')`. If empty: print `Usage: node tidal_search.js "<search terms>"` to stdout and exit 0.
2. `loadCred`, then `getToken`, then `getCountryCode`, then `searchTracks(query, token, cc, 10)`.
3. If there are no items: print `No results.` and exit 0.
4. Otherwise print `\nTop <n> results for "<query>":\n`, then for each item:
   `  [<i>] ID <id>  <artists ', '> — <title> (<album.title>) [<m>:<ss>]` plus ` [Hi-Res]` when `mediaMetadata.tags` includes `HIRES_LOSSLESS`.
   A missing duration prints `NaN:NaN`; a missing album prints `(undefined)`.
5. A trailing empty line.
6. Errors: stderr `Error: <msg>`, exit 1.

**`tidal_check_quality.js`** (`:1-43`)
1. `id = argv[2]`. If missing: print `Usage: node tidal_check_quality.js <track-id>` and exit 0.
2. `getTrackInfo`, then print:
   - `\nTrack: <artists[0].name> — <title>`
   - `  audioQuality: …`
   - `  audioModes:   <JSON>`
   - `  mediaMetadata.tags: <JSON>`
3. Print `\n— Probing each quality tier —`.
4. For each of `LOW, HIGH, LOSSLESS, HI_RES, HI_RES_LOSSLESS, DOLBY_ATMOS`, one at a time, call `getPlaybackInfo(id, token, q, cc)`.
   - Build `line = audioQuality`. If there is a manifest, base64-decode it and append ` | codec=<codecs="…"> | rate=<audioSamplingRate="…"> | rep=<Representation id="…">`. These regexes only work on DASH XML, so BTS JSON manifests print `undefined` for all three.
   - Print `  <q padded to 18> → <line>`.
   - An error prints `  <q padded> → <message>` and the loop continues.
5. A fatal error prints `Error: <msg>` to stderr and exits 1.

#### E. Neighbours that share or consume this pipeline

**E1. `preview:get-audio`** (`electron-main.js:823-917`). Not part of the download path, but it duplicates the manifest handling.
- It always requests `LOSSLESS`.
- BT family: the same DRM and `urls` checks as B7, returned as `{ ok:false, error }`. Then `fetchBuffer(urls[0], { timeout: 60000, retries: 2 })`, with `mimeType = json.mimeType || 'audio/flac'`.
- DASH: `_parseDashForPreview` copies B7's DASH branch, except that it does XML-unescape the direct `BaseURL`. `_fetchDashAudioBuffer` fetches the init segment, then the media segments with 8 workers, each fetch `{ timeout: 60000, retries: 2 }`, and concatenates them. `mimeType: 'audio/mp4'`.

**E2. Renderer consumers of the batch events** (`renderer/app.js:886-888, 1052-1059, 1225-1245, 1361-1392, 1420-1482`)
- Per-row `dlStatus` values: `queued | downloading | downloaded | skipped | failed | notFound`.
- Starting a batch. These three paths call `setDownloading(true)` and are all blocked while `isDownloading` is true; none of them looks at `startBulk`'s return value.
  - **Download all**: checks that a download folder is set and that the token exists, sends `queue.filter(t => !t.notFound && t.included)`, and marks those items `queued` at 0%.
  - **Retry all / Retry selected**: sends the failed items that have a `tidalId`.
  - **Row ↻ retry**: sends the one item.
- `bulk:track-start` → the first item with `t.tidalId === tidalId` (strict numeric equality) becomes `downloading` at 0%.
- `bulk:track-progress` → sets `dlPercent` and patches the row badge `↓ N%` and the width of `.qi-progress-fill`.
- `bulk:track-done` → `dlStatus = status`; `dlPercent = 100` if `downloaded`.
- **Cancel**:
  - plays the cancel chime;
  - sets the button text to `Cancelling…`;
  - `await api.cancelDownload()`;
  - marks every `downloading` or `queued` item `failed` at 0%;
  - logs `⊗ Download cancelled.`;
  - `isDownloading` stays true until `download:done` arrives.
- `download:done`:
  - `setDownloading(false)`.
  - If `code === 0`: success ping, then the log row `✓ Batch finished.` with an **Open folder** button. Otherwise the line `=== Exit code <code> ===`, which shows `null` after a POSIX cancel.
  - Then the queue is filtered to keep only items that are `t.notFound || dlStatus === 'failed' || dlStatus === 'notFound' || (!dlStatus && t.included)`.
    - `downloaded`, `skipped`, leftover `queued` and `downloading` items are dropped.
    - So are excluded items (exact library matches the user never re-included), because `renderQueue` sets `included = false` on them.
  - Surviving non-failed items lose their `dlStatus` and `dlPercent`. The queue is saved.

### User-visible messages produced by this area

In the GUI every non-marker, non-empty line below appears in the activity log. stdout and stderr are buffered separately, so lines from the two streams can arrive in either order.

| source | text (exact; `<…>` = value) | stream |
|---|---|---|
| bulk_runner | `=== Batch download → <outDir> ===` (with blank lines) / `<n> tracks queued.` | out |
| bulk_runner | `[<i>/<n>] <title> — <artist>` | out |
| bulk_runner | `    → matched (id <id>, score <n>)` / `    → no good match` / `    → search error: <msg>` | out |
| bulk_runner | `=== Batch complete: <a> downloaded, <b> skipped, <c> failed, <d> not found ===` | out |
| bulk_runner | `Fatal: <msg>` / `Usage: node bulk_runner.js <tracklist.json>` / `No tracks in list.` | err |
| tidal_download | `  ⏭  <title>.flac already in downloads folder — skipping (use --force to overwrite)` (same for `.m4a`) | out |
| tidal_download | `  📁 Already in music library: <path>` + `     Skipping download (use --force to download anyway)` | out |
| tidal_download | `  ⚠ Similar version in music library: <title or path>` + `     Skipping. Use --force or include via GUI to download anyway.` | out |
| tidal_download | `  <artist> — <title> (<album>)` (sanitized) | out |
| tidal_download | `  ⚠ AAC-only on TIDAL — skipped (--flac-only mode).` | out |
| tidal_download | `  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).` | out |
| tidal_download | `  ✘ FFmpeg failed: ffmpeg exited <code>: <stderr tail>` | err |
| tidal_download | `     Raw file kept at: <tmpPath>` | out |
| tidal_download | `  ⚠ FLAC integrity check failed: <last line>` | err |
| tidal_download | `  ✓ Saved: <file> (<x.y> MB)` | out |
| tidal_download | `Error: <message>` (after a blank line) | err |
| tidal_lib | `token.json not found. Run tidal_auth_node.js first.` / `No credentials in token.json. Run tidal_auth_node.js first.` | err |
| electron-main | `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` | IPC |

Common `<message>` values in the `Error:` line:
- `Track info failed: <s> <body>`
- `Could not get playback manifest at any quality.`
- `Track is DRM-encrypted (<type>)`
- `Unknown manifest type: <mime>`
- `HTTP <s> for <signed URL>`
- `Request timeout after 30000ms`
- `Download timed out`
- `Token refresh failed: <s> <body>`
- `ffmpeg exited <code>: …`

### Data formats

**`pending-tracklist.json`** (bulk_runner input). Written at `electron-main.js:991-992`, read at `bulk_runner.js:53`, deleted on close.
```json
{
  "tracks": [
    { "tidalId": 12345, "title": "…", "artist": "A, B",
      "...": "every other renderer queue-item field (key, duration, source, matchMethod, hiRes, libraryMatch, included, dlStatus, dlPercent, originalTitle, …)" }
  ],
  "outDir": "/absolute/download/folder"
}
```
`bulk_runner` reads only `tidalId`, `title` and `artist`. The header comment's `{ tracks:[{title,artist}], outDir }` shape is a leftover from the OCR era.

**Marker lines** (stdout, one per line):
```
__TRACK_START__:<tidalId>
__TRACK_PROGRESS__:<tidalId>:<integer 0-100>
__TRACK_DONE__:<tidalId>:<downloaded|skipped|failed>
```
- `notFound` exists in the code but is never printed.
- The id must be all digits to match the parser.
- PROGRESS is printed by the grandchild, only when `BULK_RUNNER_PROGRESS` is set, and only when the integer value changes.

**IPC produced by a batch:**
- `bulk:track-start` `{ tidalId: number }`
- `bulk:track-progress` `{ tidalId: number, percent: number }`
- `bulk:track-done` `{ tidalId: number, status: string }`
- `download:line` `string`
- `download:done` `{ code: number|null }`
- `bulk:start` invoke result: `{ ok, code }` or `{ ok:false, error }`
- `download:cancel` result: `{ ok }`
- Preload bindings (`electron-preload.js:33-41`): `cancelDownload`, `onDownloadLine`, `onDownloadDone`, `startBulk`, `onTrackStart`, `onTrackProgress`, `onTrackDone`

**Playback response (fields used):** `{ audioQuality: 'LOW'|'HIGH'|'LOSSLESS'|'HI_RES'|'HI_RES_LOSSLESS'|…, manifestMimeType: 'application/vnd.tidal.bt'|'application/vnd.tidal.bts'|'application/dash+xml'|…, manifest: <base64> }`

**BT/BTS manifest (decoded JSON):** `{ mimeType: string, codecs: string, encryptionType: 'NONE'|…, urls: [string, …] }`. `urls[0]` is a signed direct media URL.

**DASH manifest (decoded XML, read only by regex):** the optional `<BaseURL>`, the first `initialization="…"`, `media="…$Number$…"`, `startNumber="N"`, `mimeType="…"`, `codecs="…"`, and every self-closing `<S … r="K"/>`. `tidal_check_quality` also reads `audioSamplingRate` and `<Representation id>`.

**`parseManifest` result:** `{ type:'direct', url, mimeType, codec?, raw }` or `{ type:'dash_segments', baseUrl, initTemplate, mediaTemplate, mimeType, codec, segments: number[], raw }`.

**TIDAL track JSON (fields used):** `id, title, duration (s), trackNumber, volumeNumber, isrc, copyright, streamStartDate, type, audioQuality, audioModes, mediaMetadata.tags[], artist.name, artists[].name, album.{id, title, cover (UUID with '-'), releaseDate, artist.name}`. `version` is not used.

**TIDAL album JSON (fields used):** `title, releaseDate ('YYYY-MM-DD'), copyright, artist.name`.

**Album/playlist items page:** `{ items: [ { item: <track>, type } | <track> ] }`.

**Search response:** `{ items: [<track>] }`.

**Token file:** an array (or single object). Entry `[0]` has `access_token, refresh_token, userID, countryCode, expires_at (ms epoch), client_ID, client_secret`. It holds per-user secrets.

**`downloadTrack` result:** `{ path: string, skipped: boolean }`.

### External interfaces

| interface | detail |
|---|---|
| TIDAL API `https://api.tidal.com` | Bearer token, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. Endpoints in C3 plus `GET /v1/users/{userID}?countryCode=US` and `GET /v1/tracks?isrc=…&countryCode=…`. 30 s idle timeout, no retries. |
| TIDAL auth `https://auth.tidal.com/v1/oauth2/token` | POST form refresh, Basic auth from the token file (C1). |
| TIDAL media CDN (signed URLs from the manifest) | DASH init and segments via `fetchBuffer`: 30 s idle timeout, 3 retries with 1/2/4 s backoff, retried on 429/5xx/network/timeout, follows 301/302/307. BTS direct via `downloadDirect`: streamed, 60 s idle timeout, follows 301/302/303/307/308 up to 5 hops, no retries. |
| TIDAL images `https://resources.tidal.com/images/<a/b/c/…>/1280x1280.jpg` | 1 retry; failure means no cover. |
| Spotify `https://open.spotify.com/embed/{track|album|playlist}/{id}` | CLI only; HTML scrape of `__NEXT_DATA__`. |
| FFmpeg | remux (B11), verify `-v error -i <f> -f null -`, startup probe `-version`. |
| Child processes | main → `<execPath> bulk_runner.js <listPath>` (3 pipes, `childEnv()`); bulk_runner → `<execPath> tidal_download.js <id> <outDir> --skip-library-check` (inherited stdio). No cwd anywhere. |
| Env vars | `TIDAL_TOKEN_PATH` (token file), `TIDAL_LIBRARY_FOLDER` (library root), `BULK_RUNNER_PROGRESS` (progress markers), `DEBUG` (debug output and stack traces), `ELECTRON_RUN_AS_NODE=1`, `FORCE_COLOR=0`. |
| File system | outDir: existence of `<title>.flac` and `<title>.m4a`; write `<title>.tmp.<ext>` then `<title>.<ext>`; delete the temp file; `mkdir -p` of outDir. `<userData>/pending-tracklist.json` is written and deleted. The token file is read and rewritten. The library is read only. |

### Constants and magic values

| name | value | where | meaning |
|---|---|---|---|
| `CONCURRENCY_DEFAULT` | `8` | tidal_download.js:38 | DASH segment workers (`--concurrency`) |
| `FLAC_QUALITIES` | `['HI_RES_LOSSLESS','LOSSLESS']` | :39 | tier request order; also the only valid `--quality` values |
| `DEFAULT_OUT_DIR` | `Z:\Downloads` | :40 | CLI default output; not `path.resolve`d |
| FLAC tiers | `LOSSLESS`, `HI_RES_LOSSLESS`, `HI_RES` | :401 | `audioQuality` values that mean `.flac` |
| FLAC regex | `/codecs="flac"/i` | :404 | third FLAC signal |
| BT prefix | `application/vnd.tidal.` | :118; electron-main.js:883 | JSON direct-URL manifest |
| DASH mime | `application/dash+xml` | :129 | MPD manifest |
| Segment placeholder | `$Number$` (first occurrence) | :185 | segment URL template |
| Default `startNumber` | `1` | :146 | |
| Direct redirects / hops / idle timeout | 301, 302, 303, 307, 308 / 5 / 60000 ms | :218-252 | `downloadDirect` |
| User-Agent | `okhttp/5.3.2` | tidal_lib.js:14; tidal_download.js:220 | API and CDN |
| `DEFAULT_TIMEOUT` | 30000 ms | tidal_lib.js:15 | API and `fetchBuffer` idle timeout |
| `DEFAULT_RETRIES` | 3 (4 attempts) | :16 | `fetchBuffer` |
| Backoff | `min(1000·2^attempt, 8000)` ms | :186 | 1 s, 2 s, 4 s |
| Buffer redirects | 301, 302, 307 (max 5) | :199-204 | 303 and 308 count as hard errors |
| Retriable statuses | 429, ≥500 | :205 | |
| Cover | 1280×1280, `retries: 1` | :846-856 | |
| Cover stream tags | `title=Album cover`, `comment=Cover (front)` | tidal_download.js:301-302 | FLAC PICTURE type 3 |
| Cover input | `-f mjpeg -i pipe:0` | :290 | JPEG on stdin; never a temp file |
| FFmpeg error tail | 500 chars | :267 | |
| Page size | 100 | tidal_lib.js:251,273 | album and playlist items |
| Search limit | 10 | bulk_runner.js:75; tidal_search.js:17; tidal_lib.js:298,576 | |
| Match acceptance | `titleScore===100 \|\| (titleScore>=25 && artistScore>=50)` | bulk_runner.js:79; tidal_lib.js:607 | title 100/50/25; artist tokens longer than 2 chars |
| Duration score (Spotify only) | 50 if <3 s, 25 if <8 s | tidal_lib.js:596-597 | |
| Token expiry margin | `now + (expires_in‖3600)·1000 − 60000` | :88 | refreshes 60 s early |
| Refresh scope | `r_usr+w_usr+w_sub` (sent as `%2B`) | :80 | |
| Fallback country | `US` | :108,118 | |
| Embed cap | `tracks.length >= 100` | :549 | warning only |
| Spotify UA | Chrome 120 / Windows 10 string | :472 | |
| Probe tiers | `LOW, HIGH, LOSSLESS, HI_RES, HI_RES_LOSSLESS, DOLBY_ATMOS` | tidal_check_quality.js:24 | |
| Exit codes | 0 / 2 / 1 | tidal_download.js:666-724 | mapped by bulk_runner to downloaded / skipped / failed |
| Status strings | `downloaded`, `skipped`, `failed`, (`notFound`) | bulk_runner.js:97,107-109 | |
| File names | `<sanitized title>.tmp.<m4a|flac>` → `<sanitized title>.<flac|m4a>` | tidal_download.js:355-356, 425-428 | flat in outDir, title only |
| Batch file | `<userData>/pending-tracklist.json` | electron-main.js:991 | |
| Preview fetch | `LOSSLESS`, 60000 ms, retries 2, 8 workers | electron-main.js:857-917 | sibling path |

### Rules and invariants

- Output is flat in `outDir`. The file name is the sanitized TIDAL title plus `.flac` or `.m4a`: no artist, track number, album or playlist folder. This is an explicit owner rule.
- The existence skip runs after the token, country and track-info calls (the title is needed) but before the library check and the manifest request. It checks `.flac`, then `.m4a`, by existence only. `--force` bypasses it and the library check.
- The library check runs only without `--force` and without `--skip-library-check`. In the CLI, both `exact` and `similar` matches skip. GUI batches always pass `--skip-library-check` because the queue has already been vetted, so in the GUI the only skip reason is an existing file in outDir. The library is never written to.
- Quality order: `HI_RES_LOSSLESS`, then `LOSSLESS`, but only if the first request throws. `--quality` pins a single tier.
- The format is decided by `audioQuality`, then the manifest codec, then a regex. A non-FLAC result becomes `.m4a`, or `AacOnlyError` under `--flac-only`.
- Audio and cover are stream-copied (`-c:a copy`, `-c:v copy`), never re-encoded. The cover reaches FFmpeg on stdin and never touches disk.
- Only non-empty tags are written. `date` is always the 4-character year.
- The temp file lives in `outDir` and is deleted only after a successful remux. It is deliberately kept when FFmpeg fails.
- The integrity check runs only for `.flac` and never fails the track.
- Tracks are processed one at a time everywhere. The only parallelism within a track is the DASH segment pool (default 8) and the cover fetch.
- In the GUI each track runs in its own `tidal_download` process, which re-reads the token file and refreshes the token if it has expired.
- `__TRACK_PROGRESS__` markers are printed only when `BULK_RUNNER_PROGRESS` is set. The carriage-return segment line is printed only when stdout is a TTY, so the two never mix in the GUI.
- No `spawn()` in this area sets `cwd`.
- Only one batch runs at a time in the main process (`activeChild` guard). In practice it is the renderer's `isDownloading` flag that stops a second batch, because it stays true until `download:done`.
- The GUI refuses an empty `outDir`, so `DEFAULT_OUT_DIR` only matters for hand-run CLI use.

### Edge cases and failure modes

- **Same title, different song.** For example two tracks called `Intro`, or a remaster whose difference lives only in TIDAL's unread `version` field. The second is skipped with the "already in downloads folder" message and status `skipped`, and the GUI then drops it from the queue as if it were done.
- **Case-insensitive volumes** (default APFS, NTFS): `Song.flac` and `song.flac` collide.
- **An existing `.m4a` blocks a later lossless download** of the same title, and vice versa. Even with `--force`, an old `.m4a` stays next to a new `.flac`.
- **Empty title** → `unknown.flac` / `unknown.tmp.flac`.
- **Very long titles.** There is no length cap. `existsSync` returns false, the whole track downloads (DASH holds it all in memory), and then the temp write fails with ENAMETOOLONG, so the track is `failed`.
- **Odd file names.** A title starting with `.` makes a hidden file on macOS. Windows reserved names (`CON`, `NUL`, …) and trailing dots or spaces are not handled.
- **Old temp files.** A `.tmp.*` file left by an earlier failure is silently overwritten on retry, and never cleaned up if no retry happens.
- **Missing or unreachable download folder.** It is re-created with `mkdir -p` by every track. An unmounted volume path usually fails (EACCES under `/Volumes`), so the track fails.
- **No cover id, or the cover fails twice.** The file is saved without a picture and no error is shown. Cover bytes that are not JPEG would make the `mjpeg` input fail, so the whole remux fails and the temp file is kept (unverified (needs a run)).
- **No Content-Length on a BTS download.** Progress stays at 0 and jumps to 100 at the end.
- **DASH with only a `BaseURL`** (no `SegmentTemplate`): treated as a direct download with `mimeType 'audio/flac'` and no codec.
- **Unusual DASH timelines.** `r="-1"`, `<S>` elements that are not self-closing, or several Representations give a wrong segment count. The result is a silently truncated or corrupt file, or `No segments found`.
- **Encrypted DASH** (`ContentProtection`) is not detected.
- **A segment fails after 4 attempts.** The track fails. In CLI album or playlist runs the sibling workers keep fetching into the next track; in the GUI the process exits.
- **Bad `--concurrency`** (`0`, negative or non-numeric): zero workers, so `Buffer.concat` throws a TypeError on DASH tracks.
- **Bad `--quality`.** With no value it is silently ignored. `--quality HI_RES` is rejected.
- **Spotify CLI cases.** A track with no TIDAL match exits 0. An album track whose uri does not parse makes `getSpotifyTrack(null)` fail; the error is swallowed and the item is used as-is.
- **Long CLI runs.** The token is re-checked per track and refreshed when needed (the shared `cred` object is mutated).
- **Several writers to the token file.** The main process (preview, resolve) and a download child can refresh at about the same time and each rewrite the file non-atomically. A reader could see a truncated file and fail with a JSON parse error (unverified (needs a run)).
- **Cancel during download or remux.** The grandchild keeps going and the file usually still lands (see Bugs).
- **Batch fails before any track starts** (token refresh failure, invalid token file): `Fatal:`/exit 1, and every `queued` item disappears from the GUI queue (see Bugs).
- **`startBulk` rejects** (for example the `pending-tracklist.json` write throws): the renderer's `await` rejects, `isDownloading` stays true, and the items stay `queued` until restart.
- **No overall timeout** on FFmpeg, `writeFileSync` or a slow network volume.
- **Multi-pair TIDAL URLs** such as `…/album/X/track/Y` are parsed as the album.

### Bugs and oddities

| # | severity | issue | evidence |
|---|---|---|---|
| 1 | Medium | **Cancel stops only `bulk_runner`; the running `tidal_download` and its FFmpeg keep going.** `kill()` signals one pid, and nothing kills the process group or tree. The grandchild inherited `bulk_runner`'s stdout and stderr, so it holds the pipe's write end. The main process's `'close'` (and therefore `download:done`) is then delayed until that grandchild exits. The UI stays in `Cancelling…`/`Downloading…`, late progress lines still arrive, and the track usually still lands in the folder. On macOS, Cmd+Q does not emit `window-all-closed`, so nothing kills the batch at all; the orphans most likely die with EPIPE on their next write to the closed pipe. Exact timing: unverified (needs a run). | electron-main.js:646-653, 548-551; bulk_runner.js:41-44 |
| 2 | Medium | **A partial or bad output file counts as "already downloaded" forever.** FFmpeg writes straight to the final `<title>.flac`/`.m4a` with no temp-then-rename. A remux that dies part-way (disk full, process killed, or after a cancel or quit as in #1) can leave a partial final file. A file that fails `verifyFlac` is kept and reported as downloaded. Every later run skips both, because the check is existence-only. Unverified (needs a run): whether FFmpeg removes its partial output on a non-zero exit. | tidal_download.js:359-366, 289-309, 454-467 |
| 3 | Medium | **Queue items vanish when a batch dies early.** The renderer marks every sent item `queued`. If `bulk_runner` exits before printing `__TRACK_DONE__` for an item, `onDownloadDone`'s filter drops `queued` and `downloading` items silently. Examples: a token refresh failure prints `Fatal:` and exits 1 before the loop; a crash part-way through. Renderer area, triggered by this pipeline's exit behaviour. | renderer/app.js:1445-1453, 1466-1472; bulk_runner.js:56-58, 115-118 |
| 4 | Low | **`bulk_runner` exits 0 even when every track failed**, so the GUI plays the success ping and shows `✓ Batch finished.` | bulk_runner.js:114-115; renderer/app.js:1457-1462 |
| 5 | Low | **Skipped tracks are counted as "downloaded"** in `downloadPlaylist`, `downloadSpotifyPlaylist` and `downloadSpotifyAlbum`, because `ok++` runs without checking `result.skipped`. The playlist "skipped" figure is always 0. In `downloadAlbum` the computed figure is right but the local `skipped` variable is unused. | tidal_download.js:573-574, 614-615, 649-650, 506-520 |
| 6 | Low | **The Windows default output folder is used on macOS too.** `'Z:\\Downloads'` is not resolved and is created with `mkdir -p`, so on POSIX the CLI makes a folder literally named `Z:\Downloads` in the current directory. | tidal_download.js:40, 687-688 |
| 7 | Low | **`--concurrency 0`, a negative number or a non-numeric value breaks DASH downloads:** zero workers, so `Buffer.concat` throws on the undefined entries. | tidal_download.js:63, 203-207 |
| 8 | Low | **`--quality` with no value is silently ignored**, and the flag always consumes the next token. | tidal_download.js:62, 675 |
| 9 | Low | **`fetchBufferOnce` redirects are fragile.** The protocol module is chosen once, so an https↔http redirect calls the wrong module, which throws inside the response callback (an uncaught exception, exit 1). Only 301/302/307 are followed (303/308 become hard errors). A missing `Location` header also throws. `Too many redirects` has no `retriable` flag, so it is retried. | tidal_lib.js:184-204 |
| 10 | Low | **`downloadDirect` has no retries and leaves a partial `.tmp` file** in the user's folder when it fails. It does not check the byte count against Content-Length. Unverified (needs a run): whether a connection dropped mid-body resolves with a truncated file. | tidal_download.js:215-256 |
| 11 | Low | **`getBestManifest` hides the real failure** (401, 404, network). Users see only `Could not get playback manifest at any quality.` unless `--debug` is on. | tidal_download.js:337-341 |
| 12 | Low | **The DASH "direct" branch does not XML-unescape `BaseURL`**, so `&amp;` in a signed query would break the request. The segmented branch and the preview copy do unescape. | tidal_download.js:133-134 vs electron-main.js:826 |
| 13 | Low | **A failed segment does not stop its sibling workers.** In CLI album or playlist runs they overlap the next track's downloads. | tidal_download.js:181-204 |
| 14 | Low | **The batch dispatcher has no `isDestroyed()` guard.** On macOS, closing the window during a batch kills `bulk_runner` (without nulling `activeChild`). The later `close` handler, and any grandchild output, then call `mainWindow.webContents.send` on a destroyed window, which throws in the main process (what the user sees: unverified (needs a run)). A final partial line is never sent. | electron-main.js:1004-1038, 548-551 |
| 15 | Low | **Error messages contain full signed CDN URLs** (`HTTP <s> for <url>`), which appear in the activity log. | tidal_lib.js:207,213; tidal_download.js:227 |
| 16 | Low | **Excluded queue items are removed after any batch.** Exact library matches the user never re-included have `included = false` and no `dlStatus`, so `onDownloadDone`'s filter drops them. The code comment only mentions dropping downloaded and skipped tracks. (Renderer area.) | renderer/app.js:901, 1466-1472 |
| 17 | Info | **The FFmpeg-missing warning may never be seen**: it is sent right after `createWindow()`, possibly before the renderer listens. It also only catches spawn errors, not a binary that runs and fails. Unverified (needs a run). | electron-main.js:476, 495, 529-546 |
| 18 | Info | **No `'error'` listener on the `bulk_runner` child or on its `tidal_download` child.** A spawn failure would crash the parent. Practically unreachable, since `process.execPath` always exists. | bulk_runner.js:41-45; electron-main.js:996-999 |
| 19 | Info | **The `notFound` marker is dead code**: `if (t.tidalId)` sits inside `if (!trackId)` with `trackId = t.tidalId`. | bulk_runner.js:70, 92-97 |
| 20 | Info | **A Spotify single-track "no match" and a `--flac-only` AAC skip both exit 0**, the same as a successful download. | tidal_download.js:535-538, 694-700 |
| 21 | Info | **`verifyFlac` is weak.** It only reacts to a non-zero exit; with `-v error` and no `-xerror`, many decode errors probably still exit 0 (unverified). The warning often ends with an empty "last line", and the result is ignored. | tidal_download.js:313-321, 464 |
| 22 | Info | **Wasted per-track `getSpotifyTrack` call "for ISRC"**: the embed never provides one. | tidal_download.js:602-604; tidal_lib.js:505-515 |
| 23 | Info | **A new `refresh_token` returned by TIDAL is ignored**; only `access_token` and `expires_at` are stored. | tidal_lib.js:86-93 |
| 24 | Info | **No guard in the main process against a second batch.** After a cancel, `activeChild` is null while the old child's `close` is still pending. Only the renderer's `isDownloading` flag stops a second `bulk:start`. If the renderer were reloaded, a new batch's `activeChild` and `pending-tracklist.json` could be clobbered by the old `close`. Not reachable through the normal UI. | electron-main.js:646-650, 1034-1038; renderer/app.js:1361-1362, 1458 |
| 25 | Info | **Duplicated logic.** There are two DASH parsers (they already differ on unescaping) and four copies of the title/artist scoring rule (bulk_runner.js:11-29, electron-main.js:712-727 and 944-959, tidal_lib.js:580-608); only the Spotify copy has the duration term. | as listed |
| 26 | Info | **Stale help text, comments and docs:** | tidal_download.js:1-16, 83-84; bulk_runner.js:1-5; electron-main.js:984, 994 |
| | | - The help describes an "anonymous web API → ISRC" Spotify path, omits `--skip-library-check`, and the header comment omits `--flac-only`. | |
| | | - `bulk_runner`'s header describes OCR. | |
| | | - `electron-main.js` refers to a "single-track spawn above" that no longer exists, and calls `bulk:start` "screenshot OCR". | |
| | | - CLAUDE.md says `getManifestV2` exists in `tidal_lib.js` (it does not) and that the library check runs "before any network fetch" (track info is fetched first). | |
| 27 | Info | **Misc.** | tidal_download.js:275, 351-385; tidal_search.js:27; tidal_check_quality.js:29-33 |
| | | - `remuxToFlac` also writes `.m4a`. | |
| | | - Log lines show sanitized names (`/` and `:` become `_`). | |
| | | - `tidal_search` prints `NaN:NaN` / `(undefined)` for missing fields. | |
| | | - `tidal_check_quality` prints `undefined` codec, rate and rep for BTS manifests. | |
| | | - The refresh scope is sent as `%2B`; it works today, so replicate it exactly. | |

### Platform-specific behaviour

- **asar path rewrite.** `app.asar` → `app.asar.unpacked` exists only because Electron packs code into an asar archive. `asarUnpack: ['node_modules/ffmpeg-static/**/*']` in `package.json` puts the binary on disk. `ffmpeg-static ^5.3.0` downloads a platform binary at install time; `node_modules` is not in this checkout.
- **Children run the Electron binary as Node** (`process.execPath` + `ELECTRON_RUN_AS_NODE=1`), reading scripts from inside the asar.
- **The bare `ffmpeg` fallback is resolved through `PATH`.** A Finder-launched macOS app has a minimal `PATH` (no `/opt/homebrew/bin`), so the fallback rarely works there.
- **`DEFAULT_OUT_DIR` is a Windows drive path.**
- **`sanitize` removes the Windows-illegal set `\ / : * ? " < > |`**, which covers what macOS forbids (`/`, and `:` in Finder).
- **`kill()` does not reach grandchildren on either OS.** On POSIX the close code is `null` (SIGTERM); on Windows it is the TerminateProcess code. On macOS, closing the window does not quit the app, and Cmd+Q does not trigger the kill path at all.
- **The line splitter handles CRLF** from Windows children.
- **The carriage-return progress line** only appears when stdout is a terminal (`process.stdout.isTTY`).
- **`userData`** is `%APPDATA%\robogears Downloader` or `~/Library/Application Support/robogears Downloader`. `pending-tracklist.json`, and in packaged builds `token.json`, live there.
- **Default APFS and NTFS are case-insensitive**, which widens the existence-skip collisions.

### Porting notes for a native Swift macOS app

| topic | current mechanism | what Swift needs | difficulty |
|---|---|---|---|
| Process model | main → `bulk_runner` → one `tidal_download` per track; state carried by marker text and exit codes | One in-process batch loop (structured concurrency) calling `downloadTrack(id, outDir, options) async throws -> TrackOutcome`, where `TrackOutcome` is downloaded, skipped(reason) or failed(error). Report progress through a closure or `AsyncStream`, throttled to integer-percent changes. Keep the status vocabulary `queued / downloading / downloaded / skipped / failed / notFound`. Task cancellation should cancel URLSession work **and** terminate any FFmpeg `Process`, which fixes Bug 1. | easy |
| FFmpeg | `ffmpeg-static` binary, path rewrite, `PATH` fallback | Option A: bundle a signed `ffmpeg` in `Contents/Helpers` and run it with `Process` (absolute `executableURL`) using the exact argument list in B11. Write the JPEG to a `Pipe` on `standardInput` while reading `standardError` at the same time (`readabilityHandler`) to avoid a pipe deadlock. Needs a licence review (GPL/LGPL build) and signing under the hardened runtime. Option B: no FFmpeg. BTS lossless files are already native FLAC, so only the metadata blocks need rewriting (STREAMINFO kept, a new VORBIS_COMMENT and a PICTURE type 3 with description `Album cover`). DASH lossless is FLAC in fragmented MP4: take STREAMINFO from the `dfLa` box and write `fLaC` + metadata blocks + the FLAC frames from each `mdat`. AAC `.m4a` could go through `AVAssetExportSession` passthrough with metadata and artwork (fMP4 input support: unverified). | medium (A) / hard (B) |
| HTTP | Node `https`, hand-rolled redirects, socket idle timeouts, retry/backoff, worker pool of 8 | `URLSession` with `timeoutIntervalForRequest` (an idle timeout; 30 s for API and segments, 60 s for direct). It follows redirects, including 303/308 and relative ones, automatically. Add a retry wrapper with `min(1000·2ⁿ, 8000)` ms backoff that retries on 429, ≥500, transport errors and timeouts (3 retries for segments and init, 1 for the cover, none today for direct or API calls). Run segments in a `TaskGroup` capped at 8, assembled in index order; consider streaming to a `FileHandle`. Send `User-Agent: okhttp/5.3.2`, plus `X-Tidal-Platform: android` and `Accept-Encoding: identity` on API calls. | easy |
| Manifests | base64 + `JSON.parse`; regexes over the MPD; manual XML unescape | `Data(base64Encoded:)` and `JSONDecoder` for BT/BTS. For DASH, either copy the regex rules exactly (`NSRegularExpression` with dot-matches-newlines for `BaseURL`) or use `XMLParser`, which unescapes for you and could handle `r=-1` and multiple Representations. Keep the default `startNumber` of 1, count `r+1` segments, and fill in `$Number$`. | easy |
| File naming and skip | `sanitize`, title only, `existsSync` on `.flac`/`.m4a` | Reproduce `sanitize` exactly (the 9-character set → `_`, collapse whitespace, trim, `'unknown'` if empty). Keep the existence skip in the same order. Writing to a temp name and renaming only after success (and verification) would fix Bug 2; that is a behaviour change for the owner to approve. | easy |
| Tags | FFmpeg `-metadata` keys (B11) | Decide the exact Vorbis and iTunes key names (see Open questions) and keep the fallbacks for `album_artist`, the date, and the copyright source order. | easy |
| Credentials | plain `token.json` (path from env), refreshed non-atomically | Store the same fields; Keychain is the native choice for the secrets. Keep the refresh rule: refresh when `now ≥ expires_at`; store `now + expires_in·1000 − 60000`; capture `user.countryCode` if missing; fall back to `US`. Reproduce the form body (scope `%2B`) and Basic auth. Use a single writer to avoid the multi-process race. Migrating an existing `token.json` is an owner decision. | medium |
| Env-var plumbing | `TIDAL_TOKEN_PATH`, `TIDAL_LIBRARY_FOLDER`, `BULK_RUNNER_PROGRESS`, `DEBUG`, `ELECTRON_RUN_AS_NODE`, `FORCE_COLOR` | Pass explicit parameters; none of these are needed. | easy |
| Fuzzy match for id-less items | `scoreMatch`, ASCII-only `normalize` | A pure function with the same regex behaviour. Swift's `lowercased()` is Unicode-aware, but JS `toLowerCase` + `[^a-z0-9 ]` turns every non-ASCII letter into a space, so non-Latin titles normalize to almost nothing today. Match that if parity matters. Use `round`, and a stable sort by total descending. | easy |
| Cancellation | SIGTERM to `bulk_runner` only; no cleanup | Cooperative cancellation that stops network work, terminates FFmpeg, and then applies a clear policy for `*.tmp.*` files and partial final files (today both are left behind). | easy |
| File access | plain `fs` in any folder | With App Sandbox, use security-scoped bookmarks for the download folder and the read-only library folder. | easy / medium if sandboxed |
| CLI tools and CLI-only paths | album, playlist and Spotify download paths, `tidal_search`, `tidal_check_quality` | Optional. The GUI never uses them; it resolves everything to per-track ids first. Keep them as a Swift command-line target sharing the core module, or drop them. | easy |

### Open questions

1. For an AAC-only track, does TIDAL answer a `HI_RES_LOSSLESS` request with an AAC manifest (for example `audioQuality: HIGH`), or with an error? If it errors on both requested tiers, the track fails instead of falling back to `.m4a`. Unverified (needs a run).
2. Which Vorbis comment keys does FFmpeg write for these tags (believed `ALBUMARTIST`, `TRACKNUMBER`, `DISCNUMBER`, and lowercase or uppercase for the rest)? Does it add `encoder=Lavf…` (there is no `+bitexact`)? FFmpeg's documented default copies global metadata from the first input; does any tag carry over from the source? Unverified.
3. For `.m4a` output, are `isrc` and `copyright` written without `-movflags use_metadata_tags`, and how is the cover stored (`covr`)? Unverified.
4. Does TIDAL's `title` already contain version text (for example "Remastered 2011"), or only the separate `version` field? This decides how often distinct recordings collide on file name.
5. Which FFmpeg build and version does `ffmpeg-static ^5.3.0` install for darwin-arm64, and under which licence?
6. Does FFmpeg leave a partial output file when it exits non-zero? This sets the real severity of Bug 2.
7. Do real TIDAL DASH manifests always have absolute template URLs (empty `BaseURL`), a single Representation, non-negative `r`, and no `ContentProtection`?
8. For BTS, is `json.mimeType` `audio/flac` for lossless and `audio/mp4` for AAC? It only affects the temp extension.
9. After a GUI cancel, how long does the orphaned `tidal_download` run, does the UI stay in its downloading state until then, and does the file land? Needs a run.
10. Does Node resolve `downloadDirect` successfully when the server drops the connection mid-body?
11. Does TIDAL still return `HI_RES` (the old MQA label), and should the port keep treating it as FLAC?
12. Should the Swift port keep the CLI tools and the CLI-only album, playlist and Spotify download paths?
13. Owner decisions on these behaviours: keep title-only flat names with an existence-only skip? Keep CLI "similar" library matches skipping? Make the batch report failure when tracks fail? Keep removing excluded items from the queue after a batch? Keep `.tmp` files after a failure?
