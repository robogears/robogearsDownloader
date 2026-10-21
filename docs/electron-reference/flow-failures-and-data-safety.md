## Failure paths and data safety

### Overview

This section follows every error path through the whole download lifecycle in v0.1.30: launch, adding tracks, starting a batch, the per-track download child, FFmpeg, ending or cancelling a batch, quitting, saving state, signing in and self-updating. For each failure it records what the code does, what the user sees, and what is left on disk.

Most single-track failures are contained. Each track runs in its own `tidal_download.js` child process. Any thrown error becomes an `Error: <message>` line in the activity log, exit code 1, and a red `✗ failed` row with a `↻ Retry` button. The dangerous paths are elsewhere:

- **Missing credentials can quit the app.** `tidal_lib.loadCred()` calls `process.exit(1)` when `token.json` is missing or holds an empty array, and four IPC handlers in the Electron main process call it.
- **An early batch failure deletes the batch.** If `bulk_runner.js` dies before it marks any track, the renderer drops every still-`queued` row and saves that to `queue.json`.
- **Signing in again does not replace a dead credential.**
- **FFmpeg writes straight to the final filename**, and the "already exists" check trusts any file with that name.
- **Cancel does not stop the track in flight.**
- **TIDAL API calls never retry.**
- **State files are written in place**, and a corrupt file is silently treated as empty, then overwritten.

The library folder is never written by any code path.

Severity scale used below: High = the app becomes unusable or the user's queue is silently destroyed. Medium = data or work can be lost or corrupted in realistic conditions, or recovery is broken. Low = a misleading message, a wasted retry, or a rare edge case.

---

### Steps (the lifecycle, in order)

#### A. Launch

1. **Read settings.** `renderer/app.js:1944` calls `api.getSettings()`, which sends IPC `settings:get` to `loadSettings()` at `electron-main.js:38-41`. That function runs `JSON.parse(fs.readFileSync(<userData>/settings.json))`. Any read or parse error is swallowed and `{}` is returned, so the user sees first-launch state (blank folders) with no warning. The slider is set at `app.js:1948` to `Math.round(getPreviewVolume()*100)`, which is the *squared* audio volume, not the saved slider value (see Bugs).
2. **Sign-in state.** `token:exists` (`electron-main.js:610-613`) only checks `fs.existsSync(process.env.TIDAL_TOKEN_PATH || <source dir>/token.json)`. The welcome line is picked at `app.js:1960-1966`:
   - no token file: `👋 Welcome! Click the ⚙ icon to sign in to TIDAL.`
   - no download folder: `Pick a download folder in Settings to get started.`
   - otherwise: `Ready. Downloads go to: <folder>`

   Settings shows `✓ Signed in` / `Re-authenticate` whenever the file merely exists (`app.js:1703-1714`). That includes a corrupt file, an empty `[]` file, or a revoked credential.
3. **Restore queue.** `queue:get` (`electron-main.js:594-597`) runs `JSON.parse(<userData>/queue.json)` and returns `[]` on any error. The renderer restores the queue only if the result is a non-empty array (`app.js:1971-1988`). It strips `dlStatus`, `dlPercent` and `selected`, adds a `key` if missing, and logs `↺ Restored N track(s) from your last session.` A corrupt or non-array file therefore produces a silently empty queue, and the next queue mutation overwrites the file for good.
4. **Waveform pre-load of the restored queue.** `app.js:1984-1986` calls `enqueuePreload(tidalId)` for every row that has a `tidalId` and is not `notFound`. This runs **with no sign-in check**. `drainPreloader` (concurrency 2, `app.js:739-749`) calls `getPeaks`, which calls `api.getPreviewAudio`, which sends IPC `preview:get-audio` (`electron-main.js:873-917`). That handler calls `lib.loadCred()` **inside the Electron main process**. If `token.json` is missing, `loadCred` prints `token.json not found. Run tidal_auth_node.js first.` and calls `process.exit(1)`, so the whole app quits.

   Otherwise the handler runs `getToken`, `getCountryCode` and `getPlaybackInfo(…,'LOSSLESS',…)`, then fetches the **entire track**:
   - BTS manifest: `fetchBuffer(url, {timeout:60_000, retries:2})`
   - DASH manifest: init segment plus every segment, 8 workers, the same options

   Preload errors are swallowed (`app.js:763-766`). Peaks live only in memory, so every launch downloads every restored track again in the background.
5. **Library scan.** If `settings.libraryFolder` is set, `setLibraryPath` and `scanLibrary(sendScanProgress)` run (`electron-main.js:473-485`):
   - A missing or unmounted path returns `{entries: []}` (`tidal_lib.js:680-682`), and that empty result is **cached for the process lifetime**.
   - The directory walk is synchronous `readdirSync`, running on the main-process thread. Per-directory errors are swallowed.
   - Tag reads use `music-metadata` at concurrency 8. A failed read falls back to the filename only.
   - Scan rejections are swallowed by `.catch(() => {})`.

   The user is never told that the library could not be read. Duplicate detection simply stops working until Refresh or a path change.
6. **Update check.** `checkForUpdatesAndNotify` (`electron-main.js:115-176`) sends `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` with a 10 s socket timeout. A non-200 response (rate-limit 403, 404 when there is no published release), a network error, a timeout or bad JSON all resolve `null`. That becomes `{status:'error', message:'Could not reach GitHub'}`, and nothing is sent at launch, so failure is silent.
7. **FFmpeg probe.** `verifyFfmpegAvailable` (`electron-main.js:529-546`) spawns `<ffmpeg-static path rewritten app.asar→app.asar.unpacked | raw path | 'ffmpeg'> -version`. Only a spawn `error` event (ENOENT, EACCES, wrong architecture) sends the `download:line` message `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` A non-zero exit from the probe is ignored. The message is sent milliseconds after `createWindow()`, probably before `app.js` has registered `onDownloadLine`, so it may be dropped (unverified, needs a run). Inventory only: the Chrome-extension bridge start failure (`electron-main.js:517-522`) has the same timing.

#### B. Adding tracks

8. **URL or search** (`app.js:1287-1325`). The renderer first checks `tokenExists` (else `⚠ Sign in to TIDAL first (Settings → Sign in).`), then shows a cancellable loading overlay. `resolve:input` (`electron-main.js:658-687`) runs `loadCred`, `getToken` and `getCountryCode`, then `resolveUrlToTracks` or `searchTracksForQueue`. Any throw comes back as `{ok:false,error}` and the renderer logs `✗ <error>`. A cancel gives `{ok:false, cancelled:true}`, logged as `⊗ Resolve cancelled.`

   TIDAL non-200 responses on `/v1/tracks/{id}`, `/v1/albums/{id}/items` or `/v1/playlists/{uuid}/items` fail the whole resolve at once; the message includes TIDAL's response body. A failed Spotify→TIDAL match for one track becomes a `notFound` row. A `token.json` holding `[]` passes the existence check, but `loadCred` then calls `process.exit(1)` and the app quits.
9. **CSV, text-file or paste import** (`app.js:1830-1858`). The tracklist is parsed locally, then `api.resolveTracklist` is called **without a `tokenExists` check**. The import can be triggered by dropping a file, picking a file, or **any multi-line paste while no input field has focus** (`app.js:1800-1808`).

   `resolve:tracklist` (`electron-main.js:919-982`) calls `lib.loadCred()` first, so a missing token quits the app. Otherwise it searches each line one after another. A per-line error (including 429) becomes a `notFound` row with no retry. There is no Cancel button. Progress is sent as `tracklist:progress {done,total}` and shown as `Matching d / n tracks on TIDAL…`.
10. **Spotify embed** (`tidal_lib.js:474-551`). The fetch can fail in four ways, each surfacing as `✗ <msg>`:
    - non-200 response: `Spotify <type> embed failed: HTTP <status>`
    - no `<script id="__NEXT_DATA__">` in the page: `No __NEXT_DATA__ in Spotify <type> embed`
    - bad JSON: a `SyntaxError`
    - no `props.pageProps.state.data.entity`: `Unexpected Spotify embed shape for <type>/<id>`

    A missing `entity.trackList` silently yields 0 tracks, logged as `+ Added 0 tracks from link.` A track with no `title` gets `name: undefined`. The scorer then sees an empty wanted title and may accept an unrelated track by the same artist (see Bugs).
11. **Library tagging.** `enrichWithLibraryStatus` (`tidal_lib.js:836-844`) is computed once, when tracks are resolved; it is persisted in `queue.json` and never refreshed. Per-track errors are ignored. `findInLibrary` awaits any scan that is still running, so a resolve can block for the whole scan.

#### C. Starting a batch

12. **Download all guards** (`app.js:1419-1454`), checked in this order:
    1. `isDownloading` is true or the queue is empty: silent return.
    2. No `settings.downloadFolder`: warning honk and `⚠ Pick a download folder in Settings first.`
    3. `tokenExists()` is false: honk and `⚠ Sign in to TIDAL first (Settings → Sign in).`
    4. No row is both included and found: honk and `⚠ Nothing in the queue can be downloaded.`

    If all pass, the app plays the download chime, calls `setDownloading(true)`, appends a blank line, logs `=== Starting batch (N tracks) ===`, sets every downloadable row to `dlStatus='queued'`, and runs `await api.startBulk({tracks, outDir})`. The result `{ok:false}` and any rejection are both ignored.
13. **Retry guards.** The per-row `↻ Retry` (`app.js:1093-1114`) checks only `isDownloading` (`⚠ A batch is already running — retry once it finishes.`) and the download folder. **It never checks sign-in.** It logs `↻ Retrying <title>…` and calls `api.startBulk` without awaiting it. The header `↻ Retry all (N)` / `↻ Retry selected (M)` (`app.js:1397-1417`) has the same gaps and logs `↻ Retrying N track(s)…`.
14. **`bulk:start`** (`electron-main.js:986-1041`):
    - If `activeChild` is set: returns `{ok:false, error:'Another download is already running.'}`.
    - If `outDir` is empty: returns `{ok:false, error:'No download folder configured. Pick one in Settings.'}`.
    - `fs.writeFileSync(<userData>/pending-tracklist.json)` is not wrapped in try/catch. On ENOSPC or EACCES the invoke rejects.
    - Spawns `process.execPath bulk_runner.js <listPath>` with `stdio: ['pipe','pipe','pipe']` and `childEnv()`. The child gets **no `error` listener**.
    - Returns a promise that resolves only when the child emits `close`.

    In every early-return or rejection case the renderer stays in `Downloading…` with rows `queued`. No `download:done` will ever arrive, and Cancel cannot clear the state (see step 32).
15. **`bulk_runner` startup** (`bulk_runner.js:49-61`). Any of these exits 1 **before any per-track marker** is printed:
    - the list file fails to parse
    - the list is empty: `No tracks in list.`
    - `loadCred` finds no file: `token.json not found. Run tidal_auth_node.js first.`
    - `loadCred` hits corrupt JSON: it throws
    - `getToken` refresh fails: `Fatal: Token refresh failed: <status> <body>`
    - any other throw: `Fatal: <msg>`

    On success it prints `\n=== Batch download → <outDir> ===\n` and `<N> tracks queued.\n`.
16. **Per track** (`bulk_runner.js:64-112`):
    1. Prints `[i/N] <title|?> — <artist|?>`.
    2. Uses `t.tidalId`. The search fallback runs only for rows without one, which the GUI never sends.
    3. Prints `__TRACK_START__:<id>`.
    4. Spawns `process.execPath tidal_download.js <id> <outDir> --skip-library-check` with `stdio:'inherit'`, sharing main's pipes, and env `{...process.env, ELECTRON_RUN_AS_NODE:'1', FORCE_COLOR:'0'}`, which keeps `BULK_RUNNER_PROGRESS=1` and `TIDAL_TOKEN_PATH`.
    5. Has no `error` listener on that child either.

#### D. The per-track child (`tidal_download.js`)

17. **Start-up** (`tidal_download.js:663-690`). Parses arguments, then `outDir = path.resolve(arg)`. **If the folder does not exist it is silently created with `mkdirSync({recursive:true})`.** A deleted download folder therefore comes back. Behaviour for a path on an unmounted `/Volumes/<Drive>` is unverified (needs a run). Then `loadCred()`.
18. **Token, country and track info** (`tidal_download.js:347-350`):
    - `getToken`: if expired, POSTs to `auth.tidal.com/v1/oauth2/token`. A non-200 response throws `Token refresh failed: <status> <body>`; a network error throws too.
    - `getCountryCode`: uses the cached `cred.countryCode`. Otherwise it calls `GET /v1/users/<id>`, and **any failure silently returns `'US'`**.
    - `getTrackInfo`: a non-200 response throws `Track info failed: <status> <body>`.
    - All API calls use `tidalGet`/`httpsRequest` (`tidal_lib.js:129-168`): a 30 s idle timeout (`Request timeout after 30000ms`), **no retry, no backoff, no Retry-After, and no refresh after a 401**.
19. **Skip if the file exists** (`tidal_download.js:355-366`). Checks only whether `<outDir>/<sanitize(info.title)>.flac`, then `.m4a`, exists. There is no size or integrity check. The log line is `  ⏭  <Title>.flac already in downloads folder — skipping (use --force to overwrite)` (note the two spaces after the icon). The track is returned as skipped, so the process exits with code 2. Because this check needs the TIDAL title, it runs only after three network calls: when offline, an already-downloaded track reports `failed`, not `skipped`.
20. **Library check** (`tidal_download.js:370-383`). Runs only in the CLI; the GUI passes `--skip-library-check`.
21. **Album info** (`tidal_lib.js:242-246`). A non-200 response returns `null` silently, so the tags fall back to the track's own date and copyright. A network error throws and the track fails.
22. **Manifest** (`tidal_download.js:325-342`). Requests `HI_RES_LOSSLESS`, then `LOSSLESS`, via `/v1/tracks/<id>/playbackinfopostpaywall?countryCode&audioquality&playbackmode=STREAM&assetpresentation=FULL`.
    - **Every error is swallowed** and logged only with `--debug`: 401 (`Unauthorized — token may be invalid`), 403, 404, 429, 5xx, region lock and JSON errors.
    - If both tiers fail, the error is `Could not get playback manifest at any quality.`
    - A transient failure on the Hi-Res request silently produces the 16-bit LOSSLESS stream.
23. **Manifest parsing** (`tidal_download.js:107-169`). Each failure throws one of these messages:
    - `No manifest in playback response`
    - `Track is DRM-encrypted (<type>)`
    - `BT-family manifest (<mime>) had no urls field: <first 200 chars>`
    - `Could not parse MPEG-DASH segment template.`
    - `No segments found in MPEG-DASH manifest.`
    - `Unknown manifest type: <mime>`

    The DASH "direct" branch (no `SegmentTemplate`, line 133-134) uses `BaseURL` **without** XML-unescaping it, unlike the DASH segment branch and the preview parser.
24. **Format decision** (`tidal_download.js:400-428`). The output is FLAC if any of these is true:
    - `audioQuality` is one of `LOSSLESS`, `HI_RES_LOSSLESS`, `HI_RES`
    - the codec contains `flac`
    - `/codecs="flac"/i` matches the decoded manifest

    Otherwise the log reads `  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).` and the track still exits 0. The GUI never passes `--flac-only`. File names:
    - `finalPath = <outDir>/<Title>.<flac|m4a>`
    - `tmpPath = <outDir>/<Title>.tmp.<m4a if manifest mimeType contains "mp4" else flac>`
25. **Audio and cover fetched in parallel** (`tidal_download.js:445-451`).
    - **DASH:** the init segment, then all segments with 8 workers. Each fetch uses `fetchBuffer` with a 30 s idle timeout and 3 retries (backoff 1 s, 2 s, 4 s). It retries network errors, timeouts, 429 and 5xx. Other non-200 responses fail at once, and only 301, 302 and 307 redirects are followed. **The whole track is held in memory**, then written to `tmpPath` with one `writeFileSync`.
    - **BTS/direct:** a streaming GET into `createWriteStream(tmpPath)` with a 60 s idle timeout (`Download timed out`) and **no retry**. It follows 301, 302, 303, 307 and 308 redirects, up to 5 (`Too many redirects`). On error the write stream is not closed; the process exits soon after.
    - **Cover:** `fetchCover` uses `fetchBuffer` with 1 retry. Any failure returns `null`, so the file silently has no artwork.
    - **Progress:** `__TRACK_PROGRESS__:<id>:<0-100>` is printed on each integer change, but only when `BULK_RUNNER_PROGRESS` is set. Unknown content-length stays at 0 until 100.
26. **Remux** (`tidal_download.js:275-310, 454-460`). Command:

    ```
    ffmpeg -y -i <tmp> [-f mjpeg -i pipe:0] -map 0:a
           [-map 1:v -disposition:v attached_pic] -c:a copy
           [-c:v copy -metadata:s:v "title=Album cover" -metadata:s:v "comment=Cover (front)"]
           -metadata title=… artist=… album=… album_artist=… track=… disc=…
           date=<YYYY> copyright=… isrc=…   (each tag only if non-empty)
           <finalPath>
    ```

    The cover is piped to stdin. **FFmpeg writes straight to the final name.** On a spawn error (FFmpeg missing) or a non-zero exit, the error message is `spawn <path> ENOENT` or `ffmpeg exited <code>: <last 500 chars of stderr>`. The child logs `  ✘ FFmpeg failed: <msg>` and `     Raw file kept at: <tmpPath>`, then rethrows. **Nothing deletes a partial `finalPath`.**
27. **Clean-up and check** (`tidal_download.js:461-468`). `unlinkSync(tmp)`, with errors ignored. For FLAC only, `verifyFlac` runs `ffmpeg -v error -i <final> -f null -`. A **non-zero exit only logs** `  ⚠ FLAC integrity check failed: <last stderr line>`; the track is still a success. Only the exit code is checked. FFmpeg normally exits 0 even when it prints decode errors, unless they exceed its default error-rate threshold, so most corruption probably passes silently (unverified, needs a run). The child then calls `statSync`, logs `  ✓ Saved: <name> (<MB, 1 decimal> MB)` and exits 0.
28. **Any uncaught error** (`tidal_download.js:720-724`) prints `\nError: <message>` to stderr (with the stack only when `DEBUG` is set) and calls `process.exit(1)`. This line is the only failure reason the user ever sees; the row just shows `✗ failed`.

#### E. Batch end, cancel, quit

29. **Status mapping** (`bulk_runner.js:105-114`):

    | Child exit code | Status |
    |---|---|
    | 0 | `downloaded` |
    | 2 | `skipped` |
    | anything else, including `null` from a signal | `failed` |

    It prints `__TRACK_DONE__:<id>:<status>` and moves on. At the end it prints `\n=== Batch complete: X downloaded, Y skipped, Z failed, W not found ===` and **exits 0 even if every track failed**.
30. **Main line router** (`electron-main.js:1004-1031`). stdout and stderr are buffered **separately** and split on `\r?\n`. A trailing partial line is never flushed.

    | Line pattern | IPC event sent |
    |---|---|
    | `^__TRACK_START__:(\d+)$` | `bulk:track-start {tidalId:Number}` |
    | `^__TRACK_PROGRESS__:(\d+):(\d+)$` | `bulk:track-progress {tidalId, percent}` |
    | `^__TRACK_DONE__:(\d+):(\w+)$` | `bulk:track-done {tidalId, status}` |
    | any other non-empty line | `download:line` |
    | empty line | dropped |

    None of these sends checks `mainWindow.isDestroyed()`.
31. **Renderer per-track handling** (`app.js:1225-1245`). On start the row becomes `downloading` at 0%. Progress events update only the badge and bar in place, without a re-render. On done the row takes the status (100% if `downloaded`). Rows are found with `queue.find(t => t.tidalId === id)`. Log lines are classified by `classify()` (`app.js:330-340`):

    | Pattern | Class |
    |---|---|
    | `^\s*✓ Saved` | ok |
    | `^\s*✘`, `✗ `, `Error:`, `FFmpeg failed` | error |
    | `^\s*⚠`, `^\s*ℹ` | warning |
    | `^\s*⏭`, `📁 Already in library` | skip |
    | `^===` | header |
    | `complete:` | summary |
    | `[debug]` | muted |

    The log is capped at 2000 lines. `Fatal: …` lines from bulk_runner are **not** styled as errors.
32. **Cancel** (`app.js:1374-1392`, `electron-main.js:646-653`). The renderer plays the cancel chime and sets the button to `Cancelling…`, disabled. It runs `await api.cancelDownload()`; main calls `activeChild.kill()` (SIGTERM to **bulk_runner only**), sets `activeChild = null`, and returns `{ok:true}`, or `{ok:false}` when no child is set. In either case the renderer then marks every `downloading` or `queued` row `failed` and logs `⊗ Download cancelled.` It does **not** call `setDownloading(false)`; only `download:done` does.

    The running `tidal_download` and its FFmpeg are not signalled. They keep running, keep logging through the shared pipes, and write the final file.
33. **Batch closes** (`electron-main.js:1033-1040`). On bulk_runner `close`, main sends `download:done {code}` (`null` if killed), sets `activeChild = null`, deletes `pending-tracklist.json` and resolves `{ok: code===0, code}`.

    Node emits `close` only after every holder of the child's stdout and stderr pipes has exited. After a Cancel during a track, that probably means `download:done`, and so the end of `Cancelling…`, waits for the orphaned `tidal_download` to finish (unverified, needs a run).
34. **Renderer batch end** (`app.js:1457-1482`). Calls `setDownloading(false)`. For `code === 0` it plays the success ping and appends `✓ Batch finished.` with an `Open folder` button. Otherwise it logs `=== Exit code <code> ===`. Then the **queue is filtered** to keep only rows where:

    ```
    t.notFound || t.dlStatus === 'failed' || t.dlStatus === 'notFound' || (!t.dlStatus && t.included)
    ```

    Rows that are `downloaded`, `skipped`, **still `queued` or `downloading`**, or **excluded** (an exact library match without `+ Add`) are removed. `dlStatus` and `dlPercent` are cleared on the survivors except `failed`/`notFound`, and `saveQueueSoon()` persists the result.
35. **Quitting.** `window-all-closed` (`electron-main.js:548-551`) calls `activeChild.kill()` without clearing the variable, then quits on non-darwin platforms; on macOS the app stays alive. Cmd+Q, `app.quit()` and the update restart **do not** emit `window-all-closed`. There is no `before-quit` or `will-quit` handler, so nothing is killed and nothing is flushed. Orphaned children probably die with EPIPE on their next stdout write once main is gone (unverified, needs a run).

#### F. Persistence

36. **Queue saves** (`app.js:73-83`, `electron-main.js:599-606`). `saveQueueSoon` debounces 400 ms, strips transient fields, and calls `api.saveQueue`. Main runs `writeFileSync(queue.json, JSON.stringify(q,null,2))` **in place**; errors return `{ok:false,error}`, which the renderer ignores. There is no flush on quit or reload. `onTrackDone` never saves, so after a mid-batch quit or crash `queue.json` still holds the pre-batch list. Failed status is transient: after a restart, failed rows come back as plain included rows with no Retry button.
37. **Settings saves** (`electron-main.js:42-52, 555-565`). The renderer's whole `settings` object is written in place with no try/catch, so a write error is an unhandled rejection in the renderer. A changed `libraryFolder` triggers a new background scan. `settings:reset` writes `{downloadFolder:'', libraryFolder:''}`, which drops `volume`.
38. **Token writes.** `saveCred` (`tidal_lib.js:62-68`) does a read-modify-write of `entries[0]` with 4-space JSON, in place. It runs from main (preview, resolve, import) and from every child (refresh, country code), with no lock.

#### G. Sign-in

39. **Device-code flow** (`tidal_auth_node.js:75-171`, called in-process from `electron-main.js:614-642`):
    1. `POST auth.tidal.com/v1/oauth2/device_authorization`. A non-200 response throws `Device authorization failed: <status> <body>`.
    2. Polls `POST /v1/oauth2/token` every `interval` seconds (default 5):
       - 200: save and return
       - 400 with `authorization_pending`: keep polling
       - any other 400, including `slow_down`: throw `Auth error: <json>`
       - any other status: throw `Unexpected poll response: <status> <body>`

    There is no request timeout, and the poll keeps running if the modal is closed. On failure the modal shows `ERROR: <msg>` then `✗ Sign-in failed.` On success it shows `Authorization successful! token.json saved.`, `User ID: <id>` and `Country: <cc>`.
40. **Saving the new login.** `saveToken` (`tidal_auth_node.js:53-58`) loads the array (a parse error gives `[]`), removes only an entry with the **same** `client_ID` **and** `refresh_token`, **appends** the new entry, and writes in place. Every reader uses `entries[0]`, so signing in again with a valid existing file leaves the old credential active.

#### H. Self-update

41. **`update:download`** (`electron-main.js:204-312`). Requires a packaged build and an `http(s)` URL. It streams the asset to `os.tmpdir()/robogears-downloader-<ts>.<dmg|exe>` with a 60 s idle timeout and up to 5 redirects; any non-200 is `HTTP <s> for <url>`.

    On macOS it then:
    1. runs `hdiutil attach -nobrowse -quiet -mountpoint <tmp>/robogears-mount-<ts> <dmg>`
    2. finds the first `*.app` in the mounted volume
    3. runs `ditto <app> <tmp>/robogears-update-<ts>/<app>`
    4. starts a fire-and-forget `hdiutil detach -quiet` that it never waits for
    5. deletes the dmg

    Possible errors: `hdiutil attach exit <n>`, `Could not read mounted DMG: …`, `No .app bundle found inside the DMG`, `ditto exit <n>`. Any error unlinks the dmg and returns `{ok:false,error}`. There is no checksum. The renderer shows `Download failed — retry` (log notice) or `Retry update` (topbar pill) and **never shows the error text**.
42. **`update:apply` on macOS** (`electron-main.js:314-469`):
    1. Computes the target. If the running bundle path contains `/AppTranslocation/`, the target is `/Applications/<name>.app`; otherwise it is the running bundle.
    2. Appends a breadcrumb to `~/Library/Logs/robogears Downloader/attempts.log`.
    3. Writes a bash script to `os.tmpdir()/robogears-update-<ts>.sh`. The write is not wrapped in try/catch: a throw leaves the renderer at `Restarting…`.
    4. Spawns the script detached. A spawn error is only appended to `attempts.log`.
    5. Calls **`app.quit()` 500 ms later, unconditionally**.

    The script:
    1. double-forks itself
    2. waits up to 30 × 1 s for the parent PID, then continues anyway
    3. runs `xattr -dr com.apple.quarantine` on the new app
    4. if the target exists, renames it to `TARGET.bak`; if that fails it logs `ERROR: could not back up existing TARGET (permission?). Aborting.`, exits 1 and **does not relaunch**
    5. renames the new app to TARGET. On failure it restores `.bak` only if TARGET is absent, then opens whatever is at TARGET.
    6. runs ad-hoc `codesign --force --deep --sign -`, ignoring errors
    7. **deletes `.bak` before the new app has launched**
    8. runs `open TARGET`

    It logs to `~/Library/Logs/robogears Downloader/update-<ts>.log`. Paths are interpolated into double-quoted bash strings without escaping. Apply does not check for a running batch.

---

### Data formats

| File | Location | Shape | Written by |
|---|---|---|---|
| `settings.json` | `<userData>` (`~/Library/Application Support/robogears Downloader/` on macOS; same in dev and packaged because of `app.setName`) | `{ downloadFolder: string, libraryFolder: string, volume?: number /*slider position 0..1*/ }`, JSON with 2-space indent | `saveSettings`, in place |
| `queue.json` | `<userData>` | array of queue items (below), 2-space indent; transient fields stripped | `queue:save`, in place, debounced 400 ms |
| `pending-tracklist.json` | `<userData>` | `{ tracks: QueueItem[] /*with dlStatus:'queued', dlPercent:0*/, outDir: string }`, 2-space | `bulk:start`; deleted on child `close` |
| `token.json` | packaged: `<userData>/token.json` (`TIDAL_TOKEN_PATH`); dev: `<source dir>/token.json` | array (a bare object is also accepted and wrapped) of `{ access_token, refresh_token, userID, countryCode, expires_at /*ms, now+expires_in*1000−60000*/, client_ID, client_secret }`, 4-space indent; only `entries[0]` is ever used | `saveToken` (append), `saveCred` (merge into `[0]`), in place |
| `<Title>.tmp.<m4a\|flac>` | download folder | raw stream (fragmented MP4 or FLAC) | `tidal_download`; deleted after a successful remux, **kept** when FFmpeg fails, partial on a BTS network failure |
| `<Title>.<flac\|m4a>` | download folder | final tagged file | FFmpeg, directly |
| `attempts.log`, `update-<ts>.log` | `~/Library/Logs/robogears Downloader/` | text | macOS apply and relauncher |
| dmg, mount point, staging `.app`, `.sh` | `os.tmpdir()` | — | updater |

**Queue item.** Fields vary by source:

```
{ tidalId: number|null, title, artist, duration /*s*/,
  source: 'tidal'|'spotify'|'import'|'extension', matchMethod: 'direct'|'search'|'isrc'|null,
  hiRes?: bool, album?: string, notFound?: bool, originalTitle?, originalArtist?,
  libraryMatch?: { kind:'exact'|'similar', path, libraryTitle },
  included: bool, key: string /*8 chars*/,
  // transient, never saved:
  dlStatus?: 'queued'|'downloading'|'downloaded'|'skipped'|'failed'|'notFound', dlPercent?: 0..100, selected?: bool }
```

**Child stdout protocol** (one per line): `__TRACK_START__:<id>`, `__TRACK_PROGRESS__:<id>:<pct>`, `__TRACK_DONE__:<id>:<downloaded|skipped|failed|notFound>`. Everything else is human text.

**Exit codes:**

| Process | Code | Meaning |
|---|---|---|
| `tidal_download.js` | 0 | saved (including the AAC fallback and a failed FLAC check) |
| `tidal_download.js` | 2 | skipped (file exists or library match) |
| `tidal_download.js` | 1 | any error |
| `bulk_runner.js` | 0 | finished, regardless of per-track results |
| `bulk_runner.js` | 1 | fatal before or outside the loop |
| either | `null` | killed by a signal |

**IPC payloads in this flow:**

| Channel | Payload |
|---|---|
| `bulk:start` | `{tracks, outDir}` → `{ok:false,error}` or (at close) `{ok, code}` |
| `download:cancel` | `→ {ok:true}` or `{ok:false}` |
| `download:done` | `{code}` |
| `download:line` | `string` |
| `bulk:track-start` | `{tidalId}` |
| `bulk:track-progress` | `{tidalId, percent}` |
| `bulk:track-done` | `{tidalId, status}` |
| `preview:get-audio` | `{tidalId}` → `{ok:true, audioBytes:Buffer, mimeType}` or `{ok:false,error}` |
| `resolve:input` | `{input}` → `{ok:true, kind:'url'|'search', tracks, capped?}`, `{ok:false, cancelled:true}` or `{ok:false,error}` |
| `resolve:tracklist` | `{tracks:[{title,artist}]}` → `{ok:true,tracks}` or `{ok:false,error}`; progress `tracklist:progress {done,total}` |
| `queue:save` | `→ {ok:true}` or `{ok:false,error}` |
| `token:run-auth` | `→ {ok:true}` or `{ok:false,error}` |
| `update:download` | `→ {ok:true,path}` or `{ok:false,error}`; progress `update:download-progress {downloaded,total}` |
| `update:apply` | `→ {ok:true}` or `{ok:false,error}` |

---

### External interfaces

| Endpoint | Used for | Failure handling |
|---|---|---|
| `POST https://auth.tidal.com/v1/oauth2/token` (`grant_type=refresh_token`, Basic auth with the stored client pair, `scope` sent percent-encoded as `r_usr%2Bw_usr%2Bw_sub`) | refresh | non-200 → throw; no retry |
| `POST https://auth.tidal.com/v1/oauth2/device_authorization`, then polling `/v1/oauth2/token` | sign-in | see step 39; no timeout |
| `GET https://api.tidal.com/v1/tracks/{id}`, `/v1/albums/{id}`, `/v1/albums/{id}/items`, `/v1/playlists/{uuid}`, `/v1/playlists/{uuid}/items`, `/v1/search/tracks`, `/v1/tracks?isrc=`, `/v1/users/{id}`, `/v1/tracks/{id}/playbackinfopostpaywall` | metadata, search, manifest | headers `Authorization: Bearer`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`; 30 s idle timeout; **no retry** |
| CDN URLs from the manifest | audio | DASH: `fetchBuffer` retries 3 times; BTS: a single streamed attempt |
| `https://resources.tidal.com/images/<cover id with - replaced by />/1280x1280.jpg` | cover | 1 retry, then no cover |
| `https://open.spotify.com/embed/{track|album|playlist}/{id}` | Spotify resolve | 30 s, no retry; desktop-Chrome User-Agent |
| `https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` | update check | 10 s; any failure → "Could not reach GitHub" |
| GitHub asset URL (redirects to S3) | update download | 60 s idle, 5 redirects, no checksum |
| `ffmpeg` (bundled `ffmpeg-static`, path rewritten `app.asar`→`app.asar.unpacked`; falls back to `ffmpeg` on PATH) | remux, verify, launch probe | spawn error or non-zero exit → track fails |
| `hdiutil`, `ditto`, `/bin/bash`, `xattr`, `codesign`, `open`, `ps` | macOS update | see steps 41-42 |

TIDAL client credentials are embedded in `tidal_auth_node.js:17-20` as four base64 string constants, decoded with `Buffer.from(…,'base64').toString('latin1')`. One pair is used for device authorization and polling. A different pair is written into `token.json` and later used for refresh.

---

### Constants and magic values

| Constant | Value | Where |
|---|---|---|
| TIDAL API / Spotify request idle timeout | 30 000 ms (`DEFAULT_TIMEOUT`) | `tidal_lib.js:15,148-149` |
| `fetchBuffer` retries | 3 (4 attempts) | `tidal_lib.js:16,174-193` |
| `fetchBuffer` backoff | `min(1000 × 2^attempt, 8000)` ms → 1 s, 2 s, 4 s | `tidal_lib.js:186` |
| `fetchBuffer` retriable conditions | network error, timeout, 429, ≥500; other non-200 is final | `tidal_lib.js:205-228` |
| `fetchBuffer` redirects | follows 301/302/307, max 5 | `tidal_lib.js:199-204` |
| BTS direct download idle timeout | 60 000 ms, no retry; follows 301/302/303/307/308, max 5 | `tidal_download.js:215-256` |
| Preview fetch | timeout 60 000 ms, retries 2 | `electron-main.js:858,866,891,903` |
| Cover fetch | retries 1, size 1280 | `tidal_lib.js:846-857` |
| DASH segment workers | 8 (`CONCURRENCY_DEFAULT`) | `tidal_download.js:38` |
| Quality tiers tried | `HI_RES_LOSSLESS`, then `LOSSLESS` | `tidal_download.js:39` |
| Tiers treated as FLAC | `LOSSLESS`, `HI_RES_LOSSLESS`, `HI_RES` | `tidal_download.js:401` |
| CLI fallback output dir | `Z:\Downloads` (the GUI always passes a folder) | `tidal_download.js:40` |
| Preview preloader concurrency | 2 | `app.js:555-559` |
| Library tag-read concurrency / progress throttle | 8 / every 25 files | `tidal_lib.js:744,750` |
| Queue save debounce | 400 ms | `app.js:82` |
| Volume save debounce | 300 ms | `app.js:523` |
| Activity log cap | 2000 lines | `app.js:54` |
| Token expiry margin | `expires_at = now + expires_in(default 3600)·1000 − 60 000` | `tidal_lib.js:88`, `tidal_auth_node.js:153` |
| Auth poll interval | server `interval`, default 5 s | `tidal_auth_node.js:99,134` |
| GitHub check timeout | 10 000 ms | `electron-main.js:125` |
| Update download idle timeout / redirects | 60 000 ms / < 5 | `electron-main.js:209,230` |
| Quit delay after apply | 500 ms | `electron-main.js:467` |
| Relauncher parent wait | 30 × 1 s | `electron-main.js:407-410` |
| Update-button label revert | 2.5 s | `app.js:1669-1672` |

---

### Rules and invariants (as the code enforces them today)

- **Library is read-only.** No path writes there. The GUI decides library status once, at resolve time, and passes `--skip-library-check` to every child.
- **One batch at a time.** Enforced twice: `isDownloading` in the renderer, `activeChild` in main. The two can disagree after a cancel, a window close or reopen, or a renderer reload.
- **Never overwrite.** A destination file with the same sanitized title (either extension) means "skipped". The GUI has no `--force`.
- **Flat output, title-only filename** `<sanitize(info.title)>.<flac|m4a>`. `sanitize` replaces `\ / : * ? " < > |` with `_`, collapses whitespace and trims; empty becomes `unknown`.
- **Cover is never written to a temp file.** It is piped to FFmpeg's stdin.
- **Highest quality first.** Hi-Res, then LOSSLESS, then an AAC `.m4a` fallback (which counts as a success).
- **Queue keeps only unfinished work.** After a batch, only `notFound`, `failed` and never-attempted included rows survive.
- **Transient row state is never persisted** (`dlStatus`, `dlPercent`, `selected`).

---

### Edge cases and failure modes

| Where | What happens | User sees | Left on disk |
|---|---|---|---|
| **No download folder** — `app.js:1102-1106, 1403-1407, 1421-1425`; backstop `electron-main.js:988` | Renderer blocks before any IPC | Honk + `⚠ Pick a download folder in Settings first.` | Nothing. A folder deleted later is silently re-created by `mkdir -p` (`tidal_download.js:688`) |
| **Not signed in** (no `token.json`) — `tidal_lib.js:48-52` | URL/search and Download all are guarded. **Import/paste, preview play, the boot preloader** and (inventory) the extension push are not: `loadCred` runs in main and `process.exit(1)` quits the app. **Retry** is not guarded: bulk_runner exits 1 and the retried rows are deleted (step 34) | The window vanishes. With a saved queue it vanishes **at every launch**, before Settings can be opened. Retry: `token.json not found. Run tidal_auth_node.js first.`, `=== Exit code 1 ===`, rows gone | `queue.json` unchanged (quit case) or rewritten without the retried rows |
| **`token.json` is `[]`** | Passes `tokenExists`, so even URL/search reach `loadCred` and it exits | Window vanishes; Settings says `✓ Signed in` | — |
| **`token.json` corrupt** | Main handlers: `✗ <JSON parse error>`. bulk_runner: `Fatal: …`, exit 1, queued rows deleted. Re-auth repairs it (`loadTokens` returns `[]`) | Parse errors; `✓ Signed in` still shown | `queue.json` rewritten without the batch |
| **Token expired, refresh fails at batch start** (revoked refresh token, offline, auth 5xx) | bulk_runner `getToken` throws → `Fatal: Token refresh failed: …` or a network error, exit 1, before any marker → **every queued row deleted and saved** | Fatal line (unstyled), `=== Exit code 1 ===`, the batch's rows disappear | `queue.json` without them |
| **Token expires mid-batch** | Each later child refreshes, fails and exits 1: one auth POST per track, all remaining rows `failed`; bulk_runner exits 0 | One `Error: Token refresh failed: 400 {…}` per track, then success ping and `✓ Batch finished.` | No audio |
| **Revoked but not yet expired token** | Never refreshed (no 401 handling) until `expires_at`. Track info: `Track info failed: 401 …`. The playbackinfo 401 is hidden behind `Could not get playback manifest at any quality.` | Failed rows; Re-authenticate "succeeds" but changes nothing (`entries[0]`) | Second entry appended to `token.json` |
| **TIDAL 403/404, region lock, unavailable track** | No `streamReady`/`allowStreaming` check at resolve. At download: `Track info failed: 404 …` or the generic manifest message; DRM gives `Track is DRM-encrypted (<type>)`; album-info 4xx silently degrades tags | Failed row, generic reason | Nothing |
| **TIDAL 429/5xx on API calls** | Fails on the first attempt; the batch moves on and usually hits 429 again. A 5xx on the Hi-Res tier silently falls through to 16-bit LOSSLESS | Cascade of failed rows; silent quality drop | Nothing |
| **Network drop mid-track** | DASH: each segment retries 3 times (30 s idle each); then `Promise.all` rejects and the other workers run on until `process.exit(1)`; nothing written. BTS: no retry; reset or 60 s stall rejects. Offline: every track fails fast; batch exits 0 | `Error: aborted` / `Request timeout after 30000ms` / `getaddrinfo ENOTFOUND api.tidal.com` / `Download timed out` | BTS: partial `<Title>.tmp.<ext>` (truncated and rewritten on retry). DASH: nothing, unless ENOSPC hits during the single write |
| **FFmpeg missing** | The launch warning may never be shown. Each track downloads in full, then the spawn fails: `✘ FFmpeg failed: spawn <path> ENOENT`, `Raw file kept at: …`, exit 1. The `ffmpeg` PATH fallback will not see Homebrew in a Finder-launched app | Every track fails after downloading | One complete raw `.tmp.<ext>` per track |
| **FFmpeg exits non-zero** (ENOSPC, odd stream, kill) | Error message, tmp kept, exit 1. **A partial or zero-byte `finalPath` may remain** and nothing deletes it (plausible; needs a run) | `✘ FFmpeg failed: ffmpeg exited N: …` (later stderr lines unstyled, error repeated as `Error: …`). On retry: `⏭ … already in downloads folder`, row `skipped` and removed | Raw tmp + possibly a truncated final file treated as complete forever |
| **FLAC check fails** | Warning only; exit 0 | `⚠ FLAC integrity check failed: …` then `✓ Saved: …`, row done and removed | A possibly corrupt FLAC under the final name |
| **AAC-only track** | `ℹ No FLAC master…`, remuxed to `.m4a`, no FLAC check, exit 0 | Amber info line; row done | `<Title>.m4a` |
| **Destination name already taken** | Existence-only check, exit 2. Different songs with the same title, or titles differing only in case (case-insensitive APFS), collide. TIDAL "version" variants (e.g. Radio Edit) probably share `info.title` too (unverified) | `⏭  <Title>.flac already in downloads folder — skipping (use --force to overwrite)`; row removed at batch end | Existing file untouched; the wanted track never downloaded |
| **Disk full** | DASH `writeFileSync` throws ENOSPC; a BTS stream errors; FFmpeg fails mid-write. `queue:save` returns `{ok:false}` (ignored); `settings:save` throws (unhandled). The `pending-tracklist.json` write throws, so `bulk:start` rejects and the renderer is stuck `Downloading…` (Cancel cannot clear it) | `Error: ENOSPC: no space left on device…` per track, or a frozen UI; save failures silent | Partial tmp; maybe a partial final; possibly a truncated `queue.json`/`settings.json` that is read as empty next launch |
| **Download folder not writable / is a file** | EACCES or ENOTDIR on the tmp write. For DASH this happens only after the whole track is in memory, and repeats per track | `Error: EACCES: permission denied, open '…tmp.flac'` | Usually nothing |
| **Cancel mid-track** | Only bulk_runner is killed. The orphaned `tidal_download` (and FFmpeg) finishes normally. Rows flip to `failed` immediately. `download:done {code:null}` probably waits for the orphan to exit | `⊗ Download cancelled.`, then possibly `✓ Saved: …`; `Cancelling…` until the orphan exits, then `=== Exit code null ===`. The finished track shows `✗ failed`; retrying reports `skipped` | The in-flight track's complete final file |
| **Removing a row mid-batch** | The `✕` button is not disabled during a batch; the row leaves the UI but bulk_runner still downloads it (its markers find no row) | Track silently downloads anyway | The file |
| **Adding tracks mid-batch** | Import/paste, the Enter key in the URL field, and (inventory) the extension are not blocked; new rows have no `dlStatus`, so they survive batch end | Works | — |
| **Quit (Cmd+Q / update restart) mid-batch** | Nothing killed, nothing flushed. Orphans probably die of EPIPE on their next write (unverified). A remux already in progress completes | Nothing at quit. On relaunch the queue is the pre-batch list, including tracks already downloaded (re-downloading reports `skipped`) | BTS: partial tmp. DASH: nothing. During remux: a complete final file. Power loss/SIGKILL during remux: a truncated final file that later counts as complete |
| **macOS window close mid-batch** | `window-all-closed` kills bulk_runner but **leaves `activeChild` set**; app stays alive; orphan keeps writing. `dispatchLine` and the `close` handler call `mainWindow.webContents.send` on the destroyed window (no `isDestroyed()` check, `mainWindow` never nulled). This probably throws in main; if it throws in the `close` handler, `activeChild = null` never runs and every later batch is refused until restart (unverified) | On reopen (Dock `activate`): `Download all` silently does nothing useful (`Another download is already running.` ignored) and stays `Downloading…` | Orphan's file |
| **Renderer reload / reopened window during a batch** (the default Electron menu has View → Reload; no custom menu is set) | New renderer starts with `isDownloading=false` and the pre-batch `queue.json`. Old batch markers still update matching rows. A new Download all is refused by main (ignored). When the old batch's `download:done` arrives, rows still `queued` from the refused attempt, and excluded rows, are **deleted and saved** | Confusing states; rows vanish | `queue.json` loses rows |
| **Corrupt `settings.json`** | Read as `{}`; the next save (folder pick, volume drag, reset) overwrites it | First-launch state, no message | Corrupt file, then replaced without backup |
| **Corrupt `queue.json`** | Read as `[]` (or ignored if not an array); the next queue change overwrites it | Empty queue, no message | Old queue lost |
| **Library folder unmounted / moved** | Scan returns 0 entries, cached for the session; `library:scanned {count:0}` | `0 files indexed` in Settings; no duplicate warnings | — |
| **Library path changed or cleared during a scan** | `setLibraryPath` clears `_libraryCache` but **not** `_libraryScanPromise`; the next `scanLibrary()` returns the old in-flight promise and the old library's entries are cached under the new path. (`rescanLibrary` during a scan can also be overwritten by the old scan's completion) | Wrong duplicate badges until Refresh | — |
| **Spotify embed shape change** | Clear errors for non-200 / missing `__NEXT_DATA__` / bad JSON / missing entity. Missing `trackList` → 0 tracks, no warning. Missing title → empty wanted title → a same-artist track can be accepted | `✗ …`, or `+ Added 0 tracks from link.`, or a blank-title row pointing at the wrong song | Wrong match persisted in `queue.json` |
| **Large restored queue at launch** | Every restored row's full LOSSLESS audio is downloaded in the background (2 at a time), every launch; peaks are not cached on disk. These playbackinfo calls compete with any batch for TIDAL's rate limit | Slow network; possible 429-driven download failures (unverified) | — |
| **GitHub check fails** | Collapses to `Could not reach GitHub` | Launch: nothing. Manual: `Check failed` for 2.5 s | — |
| **Update download fails** | `{ok:false,error}`; dmg unlinked; error text discarded. If no matching asset was found, `downloadUrl` is the HTML release page and `hdiutil attach` fails | `Download failed — retry` / `Retry update` | Possibly an empty staging dir, a partial `ditto` copy, or a volume still mounted after a failed detach |
| **Two update UIs clicked** | Both start independent downloads; `global._pendingUpdatePath` is whichever finished last | Two progress readouts | Two staged copies in tmp |
| **Relauncher fails** | Spawn error: logged only; app quits after 500 ms; nothing relaunches. Script write error: IPC throws before quit; button stuck `Restarting…`. Backup rename fails: abort, no relaunch | App disappears and does not return, or `Restarting…` forever. Details only in `~/Library/Logs/robogears Downloader/` | Staged `.app` in tmp; maybe `<App>.app.bak` |
| **Auth modal closed mid-flow / clicked twice** | Poll keeps running; a second click starts a second concurrent flow; both may append entries | — | Extra entries in `token.json` |

#### Timing and concurrency

- **Cancel vs. `download:done`.** Rows are flipped to `failed` only after `await api.cancelDownload()` resolves. If `download:done` were delivered first (bulk_runner killed between tracks closes almost immediately), `onDownloadDone` would delete the still-`queued` rows. In practice the invoke reply is sent first on the same channel (unverified ordering).
- **Stale `close` after Cancel.** Cancel sets `activeChild = null` at once. A later `close` from that old child sets `activeChild = null` again, deletes `pending-tracklist.json`, and sends `download:done` to whatever window `mainWindow` now points at. In a reopened or reloaded window that has meanwhile started a new batch, this ends the new batch's UI state early, deletes its `queued` rows and drops main's handle to the new child.
- **No `isDestroyed()` guard** in `dispatchLine` (`electron-main.js:1007-1018`), the `close` handler (`:1035`), `library:scanned` sends (`:49, :483, :585`, the first two inside promise chains whose `.catch` swallows a throw) or `handleExtensionTracks` final sends.
- **Order of stdout vs stderr.** They are buffered separately, so `Error: …` (child stderr) can appear after `__TRACK_DONE__` (bulk_runner stdout) has already flipped the row.
- **`token.json` is shared mutable state.** Main (preview, resolve, import) and each child read, refresh and rewrite it in place with no lock. A reader that catches a half-written file gets a JSON parse error. If that reader is bulk_runner, the queued rows are deleted.
- **Library scan blocks.** The directory walk is synchronous on the Electron main thread (it freezes IPC on a slow or network volume), and `findInLibrary` awaits a running scan (about 18 s cold for about 500 files per the docs), so URL/search/import resolves wait for it.
- **Queue persistence lags reality.** `onTrackDone` never saves; the queue is saved only at batch end or on user edits; there is no flush on quit, reload or crash.
- **Update apply during a batch** quits the app with children orphaned; the relauncher continues after 30 s even if the parent is still alive.

---

### Bugs and oddities

1. **`loadCred()` exits the whole Electron app** — **High.** `tidal_lib.js:48-58` calls `process.exit(1)` when `token.json` is missing or holds an empty array. It is called in-process from `electron-main.js:661` (resolve), `:702` (extension, inventory), `:875` (preview) and `:925` (import). The boot preloader (`app.js:1984-1986`) and import/paste (`app.js:1830-1843`, triggered by any multi-line paste) have no sign-in guard. With a saved queue and no token, the app quits within a second of every launch, before the user can reach Sign in. A realistic trigger: `queue.json` lives in `<userData>` for both dev and packaged builds, but `token.json` lives in the source folder in dev and in `<userData>` when packaged. Deleting `token.json` to work around bug 3 also triggers it.
2. **An early batch failure deletes the whole batch from the saved queue** — **High.** `app.js:1468-1481` drops every row still `queued` or `downloading` and persists the result. bulk_runner can exit 1 before its first marker in several ways (`bulk_runner.js:53-58,115-118`):
   - refresh failure with an expired token (offline, revoked)
   - corrupt `token.json`
   - missing token via Retry (Retry has no sign-in check, `app.js:1093-1114, 1397-1417`)
   - an uncaught spawn error (no `error` listener, `bulk_runner.js:41-45`)

   The same deletion hits rows left `queued` by a refused `bulk:start` in a reopened or reloaded window when an older batch's `download:done` arrives. A carefully built queue (for example a 500-line CSV import) is lost with no message.
3. **Re-authenticate never replaces the active credential** — **Medium.** `saveToken` (`tidal_auth_node.js:53-58`) appends the new login and removes only an identical `client_ID`+`refresh_token` entry. `loadCred`/`saveCred` always use `entries[0]` (`tidal_lib.js:59,66`). After a refresh token dies, "Re-authenticate" reports success and nothing changes. The only fix is deleting `token.json` by hand, which then triggers bug 1 if a queue is saved.
4. **FFmpeg writes straight to the final filename; a partial output later counts as complete** — **Medium (plausible; needs a run).** `tidal_download.js:289-309, 454-460`: there is no temp-then-rename step and no clean-up of `finalPath` on failure or interruption. The next attempt's existence check (`:359-366`) reports `already in downloads folder`, exit 2, and the row is removed.
5. **The FLAC integrity check can never fail a track, and probably misses most corruption** — **Medium.** `verifyFlac` (`tidal_download.js:313-321`) only warns, and the process exits 0, so the GUI marks it done and drops the row. It also checks only FFmpeg's exit code with `-v error`; without `-xerror`, FFmpeg normally exits 0 when it logs isolated decode errors (unverified, needs a run).
6. **Cancel does not stop the running track** — **Medium.** `activeChild.kill()` (`electron-main.js:648`) signals bulk_runner only. The grandchild (`bulk_runner.js:41-44`, `stdio:'inherit'`) and its FFmpeg keep running and write the file. The row shows `failed` although the file completes; `Cancelling…` probably persists until the orphan exits (Node `close` semantics; unverified).
7. **No retry, backoff or 401 recovery on TIDAL API calls; real errors hidden** — **Medium.** `httpsRequest`/`tidalGet` (`tidal_lib.js:129-168`) never retry; only CDN `fetchBuffer` does. `getBestManifest` (`tidal_download.js:325-342`) swallows the actual 401/403/429/region error and reports `Could not get playback manifest at any quality.` A transient Hi-Res failure silently yields 16-bit. A 429 during import marks every remaining line `not found` permanently.
8. **State files written in place; corrupt files silently replaced** — **Medium.** `settings.json`, `queue.json` (`electron-main.js:44, 601`) and `token.json` (`tidal_lib.js:67`, `tidal_auth_node.js:58`) use plain `writeFileSync`. A crash or full disk mid-write corrupts them. Corrupt settings and queue files are read as empty (`:39-40, :595-596`) and overwritten on the next save with no backup and no message. `queue:save` failures are ignored (`app.js:81`); `settings:save` has no try/catch.
9. **Total failure is celebrated** — **Low.** bulk_runner exits 0 whatever happened (`bulk_runner.js:114`), so the renderer plays the success ping and shows `✓ Batch finished.` with `Open folder` (`app.js:1459-1461`).
10. **`startBulk` refusals and rejections leave the UI stuck in `Downloading…`** — **Low.** `app.js:1112, 1416, 1453` ignore `{ok:false}` and never catch. `setDownloading(false)` runs only on `download:done`, which never comes. Cancel then gets `{ok:false}`, flips rows to failed, but leaves `Cancelling…` forever.
11. **Main sends to a destroyed window; `activeChild` can stay set forever** — **Low (unverified).** `mainWindow` is never nulled and no `closed` handler exists. `window-all-closed` (`electron-main.js:548-551`) kills bulk_runner but keeps `activeChild`. A throw in the `close` handler (`:1035`) would skip `activeChild = null` (`:1036`), so no batch could start again until restart (macOS, window closed mid-batch).
12. **Library cache can hold the wrong library or an empty one** — **Low.** `setLibraryPath` (`tidal_lib.js:28-31`) does not reset `_libraryScanPromise`; an unreachable path is cached as 0 entries (`:680-682`) with no message.
13. **FFmpeg-missing warning probably lost** — **Low (unverified).** Sent at `electron-main.js:540-545` immediately after window creation; only spawn errors are detected.
14. **Title-only filenames collide** — **Low (owner rule 3).** `tidal_download.js:352-366`. Same-title songs, case-only differences, and probably TIDAL `version` variants map to one file. The second is skipped and dropped from the queue. A name over 255 bytes gives ENAMETOOLONG (failed). A leading `.` makes a hidden file.
15. **macOS self-update can quit without relaunching** — **Low.** `electron-main.js:442-467`: the quit is unconditional; a backup failure aborts with no relaunch; `.bak` is deleted before `open`; the renderer ignores `{ok:false}` (`app.js:420, 476`); apply does not check for a running batch; paths are unescaped in bash.
16. **An empty normalized title accepts arbitrary matches** — **Low.** All scorers (`tidal_lib.js:580-609`, `electron-main.js:712-727, 944-959`, `bulk_runner.js:13-29`) normalize to `[a-z0-9 ]`. An empty wanted title (missing Spotify `title`, or a title written entirely in non-Latin script) makes `startsWith('')` true (score 50). If both sides normalize to empty, the score is 100 and the match is accepted regardless of artist. The queue row shows the Spotify or import title while `tidalId` points at a different song.
17. **DASH "direct" `BaseURL` not XML-unescaped in the downloader** — **Low (plausible).** `tidal_download.js:130-134` uses the raw `BaseURL` (with `&amp;`) for the direct branch, while the preview parser unescapes it (`electron-main.js:826`). Whether TIDAL ever sends this shape is unknown.
18. **Saved preview volume restored as its square** — **Low.** `app.js:1948` sets the slider to `getPreviewVolume()*100` (audio volume = slider²). A saved 0.5 displays as 25, and the next touch saves the lower value, so volume drifts down every session. The comment there also says "defaults to 60%", but the code default is slider 0.5.
19. **Auth has no timeout, cancel or `slow_down` handling** — **Low.** `tidal_auth_node.js:22-33` sets no request timeout. The poll loop (`:133-170`) outlives the modal, treats `slow_down` as fatal, and can run twice concurrently.
20. **Failed status not persisted; the preloader re-downloads everything each launch** — **Low.** `TRANSIENT_QUEUE_FIELDS` (`app.js:71`) drops `failed`, so Retry buttons vanish after a restart. Peaks are memory-only (`app.js:543-550`), so every launch fetches the full LOSSLESS audio for every restored row.
21. **Misleading messages** — **Low.** The missing-token message tells a GUI user to `Run tidal_auth_node.js first.`; `Fatal: …` is not styled as an error; FFmpeg errors print twice (`✘ FFmpeg failed: …` and `Error: …`); multi-line FFmpeg stderr becomes several unstyled log lines.

---

### Platform-specific behaviour

- **macOS:**
  - Closing the last window keeps the app (and any batch) alive. The Dock `activate` event re-creates the window with fresh renderer state.
  - Cmd+Q never runs `window-all-closed`, so nothing is killed.
  - A Finder-launched app's PATH does not include Homebrew, so the `ffmpeg` fallback fails if the bundled binary is missing.
  - Self-update uses `hdiutil`/`ditto` and a double-forked bash relauncher with an App Translocation redirect to `/Applications/`. Logs go to `~/Library/Logs/robogears Downloader/`.
  - APFS is case-insensitive by default, widening filename collisions.
  - Behaviour of `mkdir -p` under an unmounted `/Volumes/<Drive>` is unverified.
- **Windows (not ported):**
  - `window-all-closed` kills bulk_runner and quits; grandchildren are orphaned the same way.
  - Self-update spawns the downloaded NSIS installer with `/S --updated` (detached, hidden) and quits after 500 ms; there is no fallback if the spawn fails.
- **Both:** `ChildProcess.kill()` signals one PID only; there is no process-group or job-object kill.

---

### Porting notes for a native Swift macOS app

- **Sign-in is state, not a crash.** Model it as `signedOut` / `signedIn` / `needsReauth`. Check it at every entry point: URL, search, import, paste, preview, preload, Download all, Retry. Never terminate the app; show "Sign in to TIDAL" instead. The Settings status should reflect a credential that actually works, not merely a file that exists.
- **One credential, replaced on re-auth.** Store it in the Keychain. Serialize refresh through an actor so concurrent callers share one refresh. On a 401, refresh once and retry. On refresh failure, set `needsReauth`, stop the batch with one clear message, and leave unstarted tracks pending.
- **API retry policy.** Apply the CDN policy to TIDAL API calls too: honour `Retry-After` on 429, use exponential backoff on 5xx and network errors, and bound the attempts. Keep the real reason (401, 403, 404, region, DRM, 429, timeout) per row and show it on the row. Do not silently fall back from Hi-Res on a transient error; only on TIDAL's own downgrade.
- **Downloads are atomic.**
  1. Write `<Title>.flac.part` (or similar) in the destination folder.
  2. Remux into a second temp file.
  3. Verify the result.
  4. Move it into place (`FileManager.replaceItemAt` / same-volume rename).
  5. Delete temps on any failure or cancel.

  A failed verification is a failure. The "already exists" rule should trust only completed files. Exclude temp names from the library scanner.
- **Verification that can fail.** If FFmpeg is kept, run the check with `-xerror` (or inspect stderr). Or decode natively and treat decode errors as failure.
- **Cancellation reaches everything.** Use structured concurrency for network tasks and `Process.terminate()` for any FFmpeg run. Then clean up partial files and mark rows `cancelled` (distinct from `failed`). Return the UI to idle when cancellation actually completes.
- **Quit and update safety.** Implement `applicationShouldTerminate`: if a batch is running, ask (`Cancel Downloads` / `Keep Downloading`), cancel cleanly and flush the queue save before replying. The updater must take the same path, and must refuse to restart silently mid-batch.
- **Queue state machine.** A batch-level failure must never delete tracks that did not reach a terminal state; reset them to pending or failed with a reason. Persist after each terminal track event, not only at batch end. Decide (open question) whether `failed` should survive a restart. Batch-end feedback should come from the per-track outcomes (for example "12 downloaded, 3 failed"), not from a process exit code.
- **Persistence.** Use atomic writes (`Data.write(options: .atomic)`) for settings and queue. On a decode error, move the bad file aside (for example `queue.corrupt-<date>.json`) and tell the user. Surface save failures. Keep a 400 ms debounce but flush on termination.
- **Folder access.** In a sandboxed app, store the download and library folders as security-scoped bookmarks. Before a batch, check that the folder exists, is writable and its volume is mounted. Do not silently `mkdir -p` a missing folder (ask instead). Check free space early instead of failing after a whole track has downloaded.
- **FFmpeg.** If bundled, verify it at launch and show the result in persistent UI (a Settings row or banner), not a log line that can be lost. Keep the remux contract:
  - `-c copy`
  - cover piped via stdin (never a temp cover file), `attached_pic`, picture type 3 via `comment=Cover (front)`
  - tags `title`/`artist`/`album`/`album_artist`/`track`/`disc`/`date`(YYYY)/`copyright`/`isrc`, each only if non-empty
  - `.m4a` fallback for AAC

  A native FLAC metadata writer is an alternative, but its PICTURE block must still be type 3.
- **Library scanning.** Run it off the main thread, make it cancellable, and cancel and restart it when the path changes. Report an unreachable library rather than caching an empty index.
- **Matching guards.** Reject candidates when the normalized wanted title is empty, and normalize with Unicode-aware folding rather than ASCII-only stripping. Warn when a link yields 0 tracks.
- **Preview preloading.** Cache peaks on disk, keyed by TIDAL id. Do not re-download whole tracks for the entire queue at every launch, and pause preloading while a batch runs.
- **Updater (macOS).** Verify the asset (size plus SHA-256) and show the error text. Quit only once the relauncher has confirmed it started. Pass paths as arguments, never interpolated into shell text. Delete the `.bak` only after the new app has launched. Check for a running batch first.
- **Refresh request encoding.** The current refresh posts `scope` percent-encoded as `r_usr%2Bw_usr%2Bw_sub` (literal plus signs) with the client pair stored in `token.json` (different from the device-authorization pair). Reproduce exactly what works before changing either.
- **Keep the working rules.** The library folder is never written; downloads land flat in the chosen folder; filenames are `<Title>.flac` / `<Title>.m4a` (owner rule 3); exact library matches start excluded with `+ Add`, similar ones included with a warning; an existing destination file is never overwritten.
- **Inventory only:** `extension-server.js` and `handleExtensionTracks` (`electron-main.js:696-751`) call `loadCred` in-process and share bug 1. The extension is not part of the port (owner decision, 21 Oct 2026).

---

### Open questions

1. **Owner:** on a title collision (including TIDAL `version` variants such as "Radio Edit"), keep today's silent skip (rule 3), or add the version or a suffix to the filename?
2. **Owner:** on Cancel, should the track in progress be kept if it completes, or should its partial and temp files be deleted?
3. **Owner:** should excluded exact-library-match rows keep disappearing from the queue after every batch, as they do today?
4. **Owner:** should `failed` (with its reason) survive an app restart?
5. **Unverified (needs a run):** what FFmpeg leaves at `finalPath` on ENOSPC, a header-write failure, or a kill. This decides how often bug 4 fires today.
6. **Unverified:** is `download:done` really delayed until the orphaned `tidal_download` exits after Cancel? Do orphans die of EPIPE after Cmd+Q?
7. **Unverified:** does `mainWindow.webContents.send` on a destroyed window throw in main, leaving `activeChild` set (bug 11)?
8. **Unverified:** does the launch-time `⚠ FFmpeg not found…` line reach the renderer?
9. **Unverified:** does `ffmpeg -v error … -f null -` exit 0 on a FLAC with a few corrupt frames (bug 5)?
10. **Unverified:** refresh uses a different embedded client pair from device authorization. It evidently works today; if TIDAL ever rejects cross-client refresh, every refresh fails, and bug 3 blocks recovery.
11. **Unverified:** does TIDAL's v1 track `title` exclude the separate `version` field?
12. **Unverified:** on current macOS, does `mkdir -p` under an unmounted `/Volumes/<Drive>` fail (EACCES) or create a stray folder on the startup disk?
