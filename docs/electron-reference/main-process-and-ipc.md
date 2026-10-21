## Electron main process and preload bridge

Scope: `electron-main.js` (1041 lines) and `electron-preload.js` (66 lines) at v0.1.30, plus the parts of their callees and callers that define behaviour here: `tidal_lib.js`, `bulk_runner.js`, `tidal_auth_node.js`, the marker and exit-code side of `tidal_download.js`, and the `renderer/app.js` call sites. The self-updater and the Chrome-extension bridge are summarised only: the updater has its own section, and the extension is being dropped from the Swift port (owner decision, 21 Oct 2026).

### Overview

`electron-main.js` is the app's whole "backend". The web page in the window (the renderer) never touches files or the network. It calls a small set of named functions, `window.api.*`, which the preload script (`electron-preload.js`) forwards to the main process over Electron's IPC (inter-process messaging). Each call is a request/response pair (`ipcRenderer.invoke` to `ipcMain.handle`). The main process also pushes one-way events back to the page (`webContents.send` to `ipcRenderer.on`). There are 25 request channels and 13 event channels. No other IPC style is used.

The main process does five kinds of work:

1. **Local state.** `settings.json` and `queue.json` in the app's data folder, a read-only index of the user's music library, and the TIDAL token file.
2. **TIDAL calls made in-process.** Resolving a pasted URL or search text into tracks, matching an imported CSV/text tracklist, fetching a whole track's audio for the waveform preview, and the device-code sign-in.
3. **Downloads, run out of process.** It writes the batch to a JSON file and runs `bulk_runner.js` as a child process using the Electron binary in plain-Node mode. That child then runs `tidal_download.js` once per track, and that runs FFmpeg. Per-track state comes back as specially formatted stdout lines (`__TRACK_START__`, etc.). Everything else the children print becomes the activity log.
4. **Startup chores.** A background library scan, a GitHub update check, an FFmpeg probe, and (being dropped) the Chrome-extension file sync and localhost HTTP server.
5. **The self-updater.** Downloads and installs a new release; covered in its own section.

Most of this disappears in a native single-process Swift app: IPC becomes method calls, and child processes become in-process tasks. What must carry over is the behaviour. That means the rules for each request and result, the order of the startup steps, the per-track state machine, the matching rules, the file formats, and the decisions the current code makes, including the defective ones listed under Bugs.

### Components

#### 1. Module load and startup order — `electron-main.js:1-28, 54-58, 203`

Steps, in order:

1. Requires `electron` (`app, BrowserWindow, ipcMain, dialog, shell`), `path`, `fs`, `https` and `child_process.spawn` (1-6).
2. `app.setName('robogears Downloader')` (13). This must run before any `app.getPath()`. Without it, dev builds would use the package name `robogears-downloader` and packaged builds the product name `robogears Downloader`, giving two different data folders.
3. Packaged builds only: `process.env.TIDAL_TOKEN_PATH = <userData>/token.json` (19-21). In dev the variable is unset, so the token lives at `<repo>/token.json`. Settings and queue are in userData in both modes, so dev and packaged builds share settings and queue but not the token. (The comment at 15-18 says "token.json + settings" move only when packaged; only the token does.)
4. `require('./tidal_lib')` (23). `tidal_lib` captures `TOKEN_FILE = process.env.TIDAL_TOKEN_PATH || <dir>/token.json` (tidal_lib.js:13) and the initial `LIBRARY_PATH = process.env.TIDAL_LIBRARY_FOLDER || ''` (tidal_lib.js:24) once, at this moment. That is why step 3 must come first. `tidal_auth_node.js` captures its own `TOKEN_FILE` the same way when it is first required, lazily, at the first sign-in.
5. `require('./extension-server')` (24). Being dropped.
6. Lazy path helpers, all in userData (26-28): `SETTINGS_PATH()` gives `settings.json`, `QUEUE_PATH()` gives `queue.json`, `EXTENSION_TOKEN_PATH()` gives `extension-token.txt`.
7. Global state (54-58): `mainWindow = null`, `activeChild = null` (the running `bulk_runner` process) and `resolverCancelled = false`.
8. All 25 `ipcMain.handle` registrations, plus `app.on('window-all-closed')`, run at module top level, before the app is ready.
9. `const os = require('os')` sits mid-file at 203.

The following are deliberately absent (confirmed by search): `requestSingleInstanceLock`, `Menu.setApplicationMenu`, `before-quit`/`will-quit` handlers, a `'closed'` handler on the window, `setWindowOpenHandler`, `will-navigate` guards, session or webRequest configuration, and IPC sender validation.

#### 2. `createWindow()` — `electron-main.js:73-99`

- Creates the single `BrowserWindow`: `width 980, height 740, minWidth 720, minHeight 540, backgroundColor '#0a0a0a', title 'robogears Downloader'`.
- `webPreferences: { preload: <__dirname>/electron-preload.js, contextIsolation: true, nodeIntegration: false, sandbox: false }`.
- `autoHideMenuBar: true` has an effect on Windows/Linux only.
- No `frame` or `titleBarStyle` option, so the window has the standard OS title bar. No `show: false` / `ready-to-show` handling.
- Dev only (`!app.isPackaged`): `icon = <__dirname>/build/icon.png`. Packaged builds use the icon embedded by electron-builder.
- Loads `<__dirname>/renderer/index.html`. The `openDevTools` call at 98 is commented out.
- The content security policy is not set by main. It comes from the meta tag at `renderer/index.html:5`: `default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;`.
- `mainWindow` is assigned here and never cleared.

#### 3. Boot sequence (`app.whenReady`) — `electron-main.js:471-527`

Steps, in order:

1. `s = loadSettings()`. If `typeof s.libraryFolder === 'string'`, call `lib.setLibraryPath(s.libraryFolder)` (473-474).
2. `createWindow()` (476). The page load is asynchronous; everything below runs in the same tick, before the page has registered its listeners.
3. If `s.libraryFolder` is truthy: `lib.scanLibrary(sendScanProgress)`, then on success `library:scanned {count}` if `mainWindow` exists. Errors are swallowed (481-485). The recursive directory walk inside `scanLibrary` is synchronous, so it blocks the main thread right here (see component 8).
4. `checkForUpdatesAndNotify().catch(() => {})` (489). Fire-and-forget GitHub check; sends `update:available` if a newer release exists.
5. `verifyFfmpegAvailable()` (495).
6. `ensureExtensionBundle()` (500). Extension; being dropped.
7. `extensionServer.startServer({...})` (506-522). This creates or loads `extension-token.txt` on every launch and listens on `127.0.0.1:8273`. On failure it sends `download:line` with `⚠ Chrome-extension bridge couldn't start: <msg> (tracks won't push from Spotify)`. Extension; being dropped.
8. Registers `app.on('activate')`: if `BrowserWindow.getAllWindows().length === 0`, `createWindow()` (524-526). This is the macOS Dock-click reopen. The new page boots from scratch and restores the queue from `queue.json`.

#### 4. App and window lifecycle — `electron-main.js:548-551, 524-526`

- `window-all-closed`:
  - If `activeChild` exists, call `activeChild.kill()` inside try/catch. `activeChild` is not set to null.
  - Then, if `process.platform !== 'darwin'`, call `app.quit()`.
- Effects of that handler:
  - On every platform, closing the window kills the `bulk_runner` process. It does not kill the `tidal_download` grandchild (see component 13).
  - On macOS the app keeps running with no window; a Dock click re-creates it.
- Quitting by `app.quit()` or Cmd+Q does not emit `window-all-closed`, so quitting that way never kills `activeChild`.
- There is no other quit cleanup: the extension server is not stopped, and temp files and the pending tracklist are not removed. What happens to still-running children after main exits (their stdout pipe breaks) is unverified (needs a run).
- There is no custom menu, so on macOS Electron's default application menu is shown. It includes View → Reload (Cmd+R) and Toggle Developer Tools. Reloading the page mid-batch makes the page forget the batch while main still has `activeChild`. The page's next `startBulk` gets `{ok:false, error:'Another download is already running.'}`, which the page ignores (see Bugs). It recovers when the old batch's `download:done` arrives.

#### 5. Settings persistence — `electron-main.js:38-52, 555-565`

- `loadSettings()`: `JSON.parse(readFileSync(<userData>/settings.json, 'utf8'))`. Any error (missing file or bad JSON) returns `{}`.
- `saveSettings(s)`:
  1. `prev = loadSettings()`.
  2. `writeFileSync(path, JSON.stringify(s, null, 2))`. This replaces the whole file with whatever object the page sent (no merge). The write is direct, not atomic.
  3. If `typeof s.libraryFolder === 'string' && s.libraryFolder !== prev.libraryFolder`: call `lib.setLibraryPath(s.libraryFolder)` (trims it and drops the cache). Then `lib.scanLibrary(sendScanProgress)`, and on success `library:scanned {count}` if `mainWindow` is truthy (no destroyed-window check). Errors are swallowed.
  - A failed write throws, and the page's `invoke` rejects.
- `settings:get` returns `loadSettings()`.
- `settings:save` calls `saveSettings(s)` and returns the same `s`.
- `settings:reset` writes exactly `{downloadFolder:'', libraryFolder:''}` through `saveSettings` and returns it. The TIDAL token is untouched, and `volume` is lost because the write is a full replace. If the library folder was set, this also resets the library path and runs an (empty) scan.
- The page always sends its whole in-memory settings object:
  - after a folder Browse or Clear (`renderer/app.js:1517-1550`);
  - 300 ms after the last volume-slider movement (`renderer/app.js:515-524`).

#### 6. Folder picker, open folder, open URL — `electron-main.js:567-575, 186-188`

- `settings:pick-folder`:
  - Calls `dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'], defaultPath: <saved downloadFolder, if set> })`, a sheet attached to the window on macOS.
  - Returns `result.canceled ? null : result.filePaths[0]`.
  - The same handler serves both the download-folder and library-folder Browse buttons, so the library picker also opens at the download folder.
- `open-folder` returns `shell.openPath(p)`'s promise: `''` on success, otherwise an error string. The page ignores it, and there is no validation. `openPath` also opens or launches files, not only folders.
- `shell:open-external`: only if `typeof url === 'string'` and it matches `/^https?:\/\//` does it call `shell.openExternal(url)` (not awaited). Returns `undefined`. Plain `http` is allowed.

#### 7. Queue persistence — `electron-main.js:594-606`

- `queue:get` returns `JSON.parse(readFileSync(<userData>/queue.json))`, whatever JSON value that is, or `[]` on any error. The page checks `Array.isArray`.
- `queue:save`:
  - Writes `JSON.stringify(queue || [], null, 2)` directly (not atomic).
  - Returns `{ok:true}` or `{ok:false, error}`.
- The page debounces saves by 400 ms and strips `dlStatus`, `dlPercent` and `selected` before sending (`renderer/app.js:71-83`).

#### 8. Library index IPC — `electron-main.js:32-36, 577-587`; callee `tidal_lib.js:28-31, 674-844`

- `sendScanProgress(done, total)` sends `library:scan-progress {done, total}` only if `mainWindow` exists and is not destroyed.
- `scanLibrary(onProgress)` (tidal_lib.js:674-757):
  1. If a cached result exists, return it. If a scan is in flight, return its promise; a second caller's `onProgress` is ignored.
  2. The scan body runs synchronously up to its first `await`. If `LIBRARY_PATH` is empty or does not exist, the result is `{entries: []}`, and that empty result is cached.
  3. Otherwise it walks the folder recursively with `fs.readdirSync(dir, {withFileTypes:true})`. This is synchronous on the Electron main thread. Unreadable folders are skipped. Symlinks report neither `isDirectory` nor `isFile`, so they are skipped. It collects files whose lowercased extension is one of `.flac .m4a .mp3 .wav .aac .ogg .opus .alac`.
  4. Calls `onProgress(0, total)`.
  5. Eight async workers each call `music-metadata`'s `parseFile(full, {duration:true, skipCovers:true, skipPostHeaders:true})`. A per-file tag error falls back to the filename.
  6. Progress throttle: `onProgress(done, total)` whenever `done - lastReportedAt >= 25` or `done === total`.
  7. Stores the result in the cache, then clears the in-flight promise.
- `rescanLibrary()` clears both the cache and the in-flight promise. `setLibraryPath(p)` sets `LIBRARY_PATH = (p||'').trim()` and clears the cache only.
- `library:status` awaits `scanLibrary(sendScanProgress)` and returns `{count: entries.length, path: lib.LIBRARY_PATH}`. The page calls it every time the Settings modal opens (`renderer/app.js:1505-1508, 1675-1685`), so opening Settings can start or wait for a full scan.
- `library:rescan` calls `rescanLibrary()`, then a full scan, then sends `library:scanned {count}` (only `if (mainWindow)`), and returns `{ok:true, count}`.
- `findInLibrary` and `enrichWithLibraryStatus` also call `scanLibrary()`. Every resolve, search and import therefore waits for any in-flight library scan to finish before it returns. Matching rules are in the library-matcher section.
- Status texts in the page:
  - `Scanning N / M…`
  - `Scanning…` (shown when total is 0)
  - `N file indexed` / `N files indexed`
  - `(no library folder set)`
  - `(scan failed)` / `Scan failed`
- The library folder is only ever read, never written.

#### 9. Sign-in IPC — `electron-main.js:610-642`; callee `tidal_auth_node.js:15-171`

- `token:exists` returns `fs.existsSync(process.env.TIDAL_TOKEN_PATH || <__dirname>/token.json)`. It checks existence only: an empty array, `{}` or corrupt JSON all count as "signed in".
- `token:run-auth`:
  - Lazily requires `./tidal_auth_node`.
  - Calls `authenticate({ onLog: send, onVerificationUrl, suppressBrowser: true })`.
    - `send(line)` emits `auth:output` with `line + '\n'` (destroyed-window guarded).
    - `onVerificationUrl(url)` calls `shell.openExternal(url)` with no scheme check and not awaited, then sends `auth:url` with the URL.
  - Returns `{ok:true}`. On any exception it sends `ERROR: <msg>` and returns `{ok:false, error}`.
- `authenticate()`:
  1. **Device code request.** `POST https://auth.tidal.com/v1/oauth2/device_authorization` with a form body built by `formEncode` (`encodeURIComponent` on keys and values).
     - Body: `client_id=<AUTH client id>&scope=r_usr%2Bw_usr%2Bw_sub`. The scope is the literal string `r_usr+w_usr+w_sub`, and its `+` signs are percent-encoded on the wire.
     - Headers: `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, `Accept-Language: en-US,en;q=0.9`, `X-Platform: android`, `Content-Type: application/x-www-form-urlencoded`, `Content-Length`.
     - A non-200 reply throws `Device authorization failed: <status> <body>`.
  2. **Show the URL.** Reads `{verificationUriComplete, deviceCode, interval = 5}` from the reply.
     - Calls `onVerificationUrl(verificationUriComplete)` first.
     - Then logs these lines: `=== TIDAL Login ===`, `Open this URL in your browser and log in:`, ``, `  <url>`, ``.
     - Because `suppressBrowser` is true, the CLI's `cmd /c start` / `open` / `xdg-open` fallback is skipped.
     - Logs `Waiting for authorization...`.
  3. **Poll.** Loop forever: sleep `interval * 1000` ms, then `POST https://auth.tidal.com/v1/oauth2/token`.
     - Body: `client_id`, `device_code`, `grant_type=urn:ietf:params:oauth:grant-type:device_code` and the same scope, all percent-encoded.
     - Headers: the same as step 1 plus `Authorization: Basic base64(<AUTH id>:<AUTH secret>)`.
     - **200:** build the entry `{access_token, refresh_token, userID: user.userId, countryCode: user.countryCode, expires_at: now + (expires_in || 3600)*1000 - 60000, client_ID: <REQUEST id>, client_secret: <REQUEST secret>}` and save it with `saveToken`.
     - `saveToken` reads the array, drops entries with the same `client_ID` and `refresh_token`, appends the new entry at the end, and writes JSON with a 4-space indent (not atomic).
     - After saving it logs ``, `Authorization successful! token.json saved.`, `User ID: <id>`, and `Country: <cc>` if present, then returns the entry.
     - **400 with `error === 'authorization_pending'`:** keep polling. Any other 400 throws `Auth error: <json>`. A 400 whose body is not JSON throws a parse error.
     - **Any other status** throws `Unexpected poll response: <status> <body>`.
  4. There is no overall timeout, no per-request timeout (its `httpsRequest` sets none) and no cancel.
- **Client credentials.** Four TIDAL client credentials are embedded as base64 string literals at `tidal_auth_node.js:17-20` and decoded at module load with `Buffer.from(…, 'base64').toString('latin1')`.
  - `AUTH_CLIENT_ID` / `AUTH_CLIENT_SECRET` drive the device flow.
  - `REQUEST_CLIENT_ID` / `REQUEST_CLIENT_SECRET` are stored in each token entry. `tidal_lib.refreshToken` later uses them for HTTP Basic auth on `grant_type=refresh_token`.
  - The values are intentionally not reproduced here.
- **The page side** (`renderer/app.js:1716-1740`, `renderer/index.html:205-219`):
  - "Sign in to TIDAL" / "Re-authenticate" opens an auth modal that has no close or cancel control.
  - On success the page refreshes the auth status and closes the modal after 1.2 s.
  - On failure it appends `✗ Sign-in failed.` and leaves the modal open with no way to dismiss it.
  - The URL row with its Copy button appears when `auth:url` arrives.

#### 10. Resolve a URL or search text — `electron-main.js:56-58, 658-689`; callee `tidal_lib.js:316-463`

The page trims the input and checks `tokenExists` before calling (`renderer/app.js:1287-1300`). It shows a cancellable full-screen loading overlay with rotating "funny" texts.

1. `resolverCancelled = false`.
2. Credentials:
   - `cred = lib.loadCred()`. If the token file is missing or holds an empty array, this calls `process.exit(1)` and the whole app quits (see Bugs).
   - `token = await lib.getToken(cred)` refreshes the access token if `expires_at` has passed.
   - `country = await lib.getCountryCode(cred)` uses the cached `cred.countryCode`. Failing that, it calls `GET /v1/users/{userID}?countryCode=US` and saves the result, or falls back to `'US'`.
3. `parsed = lib.parseInputUrl(input)` tests these in order, unanchored, after trimming:
   - Spotify: `/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i`
   - TIDAL: `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i`
   - `/^\d+$/` → TIDAL track ID. Purely numeric search text such as `1999` is looked up as a track ID, while the page's hint still says it will search.
   - UUID `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i` → TIDAL playlist.
4. If parsed: `result = lib.resolveUrlToTracks(input, token, country, { isCancelled: () => resolverCancelled })`. If `resolverCancelled || result?.cancelled`, return `{ok:false, cancelled:true}`. Otherwise return `{ok:true, kind:'url', tracks: result?.tracks || [], capped: !!result?.capped}`.
   - **TIDAL track:** `GET /v1/tracks/{id}`.
   - **TIDAL album or playlist:**
     - Pages through `/v1/albums/{id}/items` or `/v1/playlists/{uuid}/items` with `limit=100` and `offset += 100`, until a page returns fewer than 100 items.
     - Keeps `item.item || item` and drops entries without an `id` or with `type === 'video'`.
     - Cancellation is checked only once, after all pages are fetched.
   - **Spotify:**
     - Scrapes the embed page (album, track or playlist).
     - Then 8 parallel workers run `spotifyTrackToTidal`; each worker checks cancellation before taking the next item. A worker error turns that row into a `notFound` row.
     - `capped` is true when a playlist embed returned 100 or more tracks.
   - Library enrichment (`enrichWithLibraryStatus`) runs before returning.
5. If not parsed: `tracks = lib.searchTracksForQueue(input, token, country, 10)` (`GET /v1/search/tracks?query=…&limit=10&countryCode=…`, then library enrichment). If `resolverCancelled`, return `{ok:false, cancelled:true}`; else return `{ok:true, kind:'search', tracks}`.
6. Any exception returns `{ok:false, error: e.message}`.

`resolve:cancel` only sets the flag and returns `{ok:true}`. In-flight HTTP is never aborted. The page keeps its overlay up, with the Cancel button reading `Cancelling…`, until `resolve:input` returns.

Page results:
- Cancelled → `⊗ Resolve cancelled.`
- Error → `✗ <error>`
- URL → tracks added straight to the queue, logging `+ Added N track(s) from link (M not on TIDAL).`, plus a 100-track warning when `capped`.
- Search → a modal of up to 10 results to pick from.

#### 11. Import a tracklist (CSV / pasted text) — `electron-main.js:919-982`

Input is `{tracks: [{title, artist}]}`, where `artist` is always a string, possibly `''`. It comes from the page's `parseTracklistText` (`renderer/app.js:1860-1939`). The page does not check `tokenExists` first (`renderer/app.js:1830-1843`), and its loading overlay is not cancellable.

1. `loadCred` (exits the app if the token is missing), `getToken`, `getCountryCode`.
2. `total = tracks.length`. Sends `tracklist:progress {done:0, total}`.
3. Strictly sequential loop: one TIDAL search at a time, no cancellation, no ISRC lookup, no duration score. For each `t`:
   1. `query = \`${t.title} ${t.artist}\`` (with a trailing space when the artist is empty). `json = lib.searchTracks(query, token, country, 10)`.
   2. `normalize = s => (s||'').toLowerCase().replace(/[^a-z0-9 ]/g,' ').replace(/\s+/g,' ').trim()`. Then `wantT = normalize(title)` and `wantA = normalize(artist)`.
   3. For each result `item`: `itT = normalize(item.title)` and `itA` = each `item.artists[].name` normalized, joined with `' '`.
      - `titleScore` = 100 if `itT === wantT`; else 50 if `itT.startsWith(wantT) || wantT.startsWith(itT)`; else 25 if `itT.includes(wantT) || wantT.includes(itT)`; else 0.
      - `aTokens` = `wantA.split(' ')`, keeping only tokens longer than 2 characters. `matched` = how many of them appear as substrings of `itA`.
      - `artistScore` = `aTokens.length ? Math.round(matched / aTokens.length * 100) : 0`. Then `total = titleScore + artistScore`.
   4. Keep a result only if `titleScore === 100 || (titleScore >= 25 && artistScore >= 50)`. Sort by `total`, descending; ties keep TIDAL's order (stable sort). `pick` is the first.
   5. Push this row:
      ```
      { title: pick?.title || t.title,
        artist: pick ? <pick artists joined ', '> : t.artist,
        duration: pick?.duration || 0,
        tidalId: pick?.id || null,
        source: 'import',
        matchMethod: pick ? 'search' : null,
        notFound: !pick,
        originalTitle: t.title,
        originalArtist: t.artist }
      ```
      `hiRes` is never set, so imported rows never show a Hi-Res badge.
   6. On a per-track exception (including any HTTP 429/5xx, because API calls are not retried), push `{title, artist, tidalId:null, source:'import', notFound:true}`.
   7. Send `tracklist:progress {done: i+1, total}`.
4. `await lib.enrichWithLibraryStatus(out)`.
5. Return `{ok:true, tracks: out}`. An outer exception returns `{ok:false, error}`.

The page shows `Matching N / M tracks on TIDAL…` using its own stored total, then logs `+ Added N from import. M matched on TIDAL, K not found.`

#### 12. Preview audio — `electron-main.js:823-917`

**`_parseDashForPreview(xml)`** (823-853) is a local copy of the DASH branch of `tidal_download`'s manifest parser. It is kept separate because requiring `tidal_download.js` would run its `main()`.

1. `xmlUnescape` replaces `&amp; &lt; &gt; &quot; &apos;`.
2. `baseUrl` = the first `/<BaseURL[^>]*>(.*?)<\/BaseURL>/s` match, trimmed and unescaped, else `''`.
3. If the XML does not contain `SegmentTemplate` and `baseUrl` is set, return `{type:'direct', url: baseUrl}`.
4. Take the first `/initialization="([^"]+)"/` and the first `/media="([^"]+)"/`. If either is missing, throw `Could not parse DASH manifest`.
5. `segNum` = `startNumber="(\d+)"`, or 1. For each self-closing `/<S\b[^>]*\/>/g` element: `repeat` = `/\br="(\d+)"/`, or 0; push `segNum++` `repeat + 1` times. Duration (`d`) attributes are ignored, and a negative `r` is not recognised.
6. If there are no segments, throw `No segments found in DASH manifest`. Otherwise return `{type:'dash_segments', baseUrl, initTemplate, mediaTemplate, segments:[numbers]}` with unescaped templates.

**`_fetchDashAudioBuffer(parsed)`** (857-871):

1. `initBuf = lib.fetchBuffer(baseUrl + initTemplate, {timeout:60000, retries:2})`.
2. 8 workers pull indexes from a shared counter and fetch `baseUrl + mediaTemplate.replace('$Number$', n)` (first occurrence only, plain `$Number$` only) with the same options, storing each result by index.
3. Return `Buffer.concat([initBuf, ...segments])` in index order: a fragmented MP4. The first failure rejects the whole call (`Promise.all`); the other workers are not stopped.

`lib.fetchBuffer` behaviour (tidal_lib.js:174-232):
- Retries network errors, timeouts, 429 and any status ≥ 500. Backoff is `min(1000·2^attempt, 8000)` ms, so `retries: 2` means 3 attempts with 1 s and 2 s waits.
- Any other non-200 status fails at once.
- Follows 301/302/307 for up to 5 hops (not 303/308).
- Sends `User-Agent: okhttp/5.3.2`.
- The timeout is a socket-idle timeout.

**`preview:get-audio` with `{tidalId}`** (873-917):

1. `loadCred` (exits the app if the token is missing), `getToken`, `getCountryCode`.
2. `playback = lib.getPlaybackInfo(tidalId, token, 'LOSSLESS', country)`.
   - Calls `GET https://api.tidal.com/v1/tracks/{id}/playbackinfopostpaywall?countryCode=<cc>&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`.
   - A 401 throws `Unauthorized — token may be invalid`; any other non-200 throws `Playback info failed: <status> <body>`.
   - Preview asks for LOSSLESS; real downloads ask for HI_RES_LOSSLESS. `tidalId` is not validated.
3. `decoded = base64decode(manifest)` as UTF-8.
4. If `manifestMimeType` starts with `application/vnd.tidal.` (the BT/BTS JSON manifests), parse the JSON:
   - `encryptionType` present and `!== 'NONE'` → `{ok:false, error:'Track is DRM-encrypted'}`.
   - No `urls` → `{ok:false, error:'No stream URL in manifest'}`.
   - Otherwise `audioBytes = fetchBuffer(urls[0], {timeout:60000, retries:2})`, returning `{ok:true, audioBytes, mimeType: json.mimeType || 'audio/flac'}`.
5. Else if `manifestMimeType === 'application/dash+xml'`, parse it with `_parseDashForPreview`:
   - `'direct'` → fetch the URL and return `mimeType: 'audio/flac'` (hard-coded).
   - Otherwise `_fetchDashAudioBuffer` → `mimeType: 'audio/mp4'`.
6. Otherwise → `{ok:false, error: \`Unknown manifest type: ${manifestMimeType}\`}`. Any exception → `{ok:false, error}`.

The entire track crosses IPC as a Node `Buffer`, which arrives in the page as a `Uint8Array`.

Page side (`renderer/app.js:672-760`):
- The page decodes the bytes with Web Audio into 200 peak bars and plays them through a Blob-URL `<audio>` element.
- It keeps two caches: `peaksCache` (unbounded) and `audioCache` (LRU, 3 entries).
- A background pre-loader with concurrency 2 calls this handler for every queued track that has a `tidalId` and is not `notFound`. It runs when tracks are added (`renderer/app.js:1267`) and for the whole restored queue at boot (`renderer/app.js:1985`), with no sign-in check.

#### 13. Batch download — `electron-main.js:60-71, 986-1041`; child `bulk_runner.js`; grandchild markers `tidal_download.js:430-442, 715, 723`

**`childEnv()`** (60-71) re-reads `settings.json` on every call and returns:

```
{ ...process.env,
  ELECTRON_RUN_AS_NODE: '1',
  FORCE_COLOR: '0',
  TIDAL_LIBRARY_FOLDER: s.libraryFolder || '',
  BULK_RUNNER_PROGRESS: '1' }
```

- `TIDAL_TOKEN_PATH` rides along in `process.env` (packaged builds only).
- `ELECTRON_RUN_AS_NODE` makes the Electron binary act as plain Node.
- `bulk_runner` passes `{...process.env, ELECTRON_RUN_AS_NODE:'1', FORCE_COLOR:'0'}` to each grandchild, so all four variables reach `tidal_download`.

**`bulk:start` with `{tracks, outDir}`:**

1. If `activeChild` is set → `{ok:false, error:'Another download is already running.'}`.
2. If `!outDir` → `{ok:false, error:'No download folder configured. Pick one in Settings.'}`. The folder's existence is not checked; `tidal_download` creates it recursively.
3. Write `<userData>/pending-tracklist.json` = `JSON.stringify({tracks, outDir}, null, 2)`. `tracks` are the page's full queue objects. A write failure throws and the `invoke` rejects.
4. `activeChild = spawn(process.execPath, [<__dirname>/bulk_runner.js, listPath], {stdio:['pipe','pipe','pipe'], env: childEnv()})`. There is deliberately no `cwd`, because the asar virtual folder breaks spawn. There is no `'error'` listener.
5. `forward(stream)` runs for stdout and for stderr, each with its own text buffer:
   - On each data chunk, `buf += chunk.toString()`.
   - Split on `/\r?\n/`; keep the last fragment as the new `buf`.
   - Call `dispatchLine` for each complete line. A fragment left over at close is never processed.
6. `dispatchLine(line)`:
   - `/^__TRACK_START__:(\d+)$/` → `bulk:track-start {tidalId: Number}`
   - `/^__TRACK_PROGRESS__:(\d+):(\d+)$/` → `bulk:track-progress {tidalId, percent}`
   - `/^__TRACK_DONE__:(\d+):(\w+)$/` → `bulk:track-done {tidalId, status}`
   - Otherwise, if `line.length` is non-zero → `download:line <line>`. Empty lines are dropped, and marker lines never reach the log.
   - None of these sends checks whether the window still exists.
7. Return a Promise. On `activeChild` `'close'` (code):
   1. Send `download:done {code}`.
   2. Set `activeChild = null`.
   3. Delete `listPath` (errors ignored).
   4. Resolve `{ok: code === 0, code}`. The page ignores this return value.

**`bulk_runner.js` behaviour:**

1. No list path → `Usage: node bulk_runner.js <tracklist.json>` and exit 1. An empty `tracks` → stderr `No tracks in list.` and exit 1.
2. `loadCred` / `getToken` / `getCountryCode`.
   - A missing token prints `token.json not found. Run tidal_auth_node.js first.` and exits 1.
   - Any thrown error prints `Fatal: <msg>` on stderr and exits 1.
3. Prints `\n=== Batch download → <outDir> ===\n` and `<N> tracks queued.\n`.
4. For each track, in sequence:
   1. Prints `[i/N] <title or ?> — <artist or ?>`.
   2. `trackId = t.tidalId`. Only when that is empty and both title and artist exist does it search TIDAL with the same scoring and acceptance rule as component 11. It prints `    → matched (id X, score S)`, `    → no good match` or `    → search error: <msg>`. The page only sends rows that have a `tidalId`, so this fallback is effectively unused from the GUI.
   3. No id → `notFound++` and continue. The `__TRACK_DONE__:<id>:notFound` line is unreachable (see Bugs).
   4. Prints `__TRACK_START__:<id>`. Spawns `process.execPath tidal_download.js <id> <outDir> --skip-library-check` with `stdio:'inherit'`, so the grandchild writes straight into the same pipes main is reading.
   5. Exit code 0 → `downloaded`, 2 → `skipped` (the file already exists in the download folder), anything else → `failed`. Prints `__TRACK_DONE__:<id>:<status>` and a blank line.
5. Final line: `\n=== Batch complete: X downloaded, Y skipped, Z failed, W not found ===`. The process exits 0 however many tracks failed.

**Grandchild markers.** `tidal_download.js` prints `__TRACK_PROGRESS__:<id>:<integer 0-100>`:
- only when `BULK_RUNNER_PROGRESS` is set;
- at most once per change in the integer percent;
- based on segment count for DASH, or on bytes and `content-length` for direct downloads (0 until done if the length is unknown, then 100).

It exits 2 when the single track is skipped (`tidal_download.js:715`) and 1 on error (`:723`).

**Page side:**
- `Download all` sends only rows with `!notFound && included`, after marking each `dlStatus:'queued', dlPercent:0`.
- Retry-all/selected and the per-row `↻ Retry` send failed rows through the same channel; the retry paths do not check `tokenExists`.
- Per-track events find the row by `queue.find(t => t.tidalId === tidalId)` (strict, numeric).
- On `download:done` (`renderer/app.js:1457-1481`):
  - Code 0 → success ping plus `✓ Batch finished.` with an Open folder button.
  - Anything else → `=== Exit code <code> ===`.
  - The queue then keeps only rows that are `notFound`, `dlStatus === 'failed'`, `dlStatus === 'notFound'`, or `!dlStatus && included`. Everything else is removed and saved: downloaded rows, skipped rows, rows still `queued`/`downloading`, and excluded "already in library" rows.

#### 14. Cancel a batch — `electron-main.js:646-653`

- If `activeChild` exists: `activeChild.kill()` inside try/catch, then `activeChild = null`, then return `{ok:true}`. Otherwise return `{ok:false}`.
  - `kill()` sends SIGTERM to the `bulk_runner` PID on macOS/Linux and calls TerminateProcess on Windows.
  - The `tidal_download` grandchild and its FFmpeg are never signalled, so they finish the current track and save it.
- **Close is delayed.** The grandchild holds the inherited pipes. By Node's `'close'` semantics, `download:done` (and the deletion of `pending-tracklist.json`) should therefore wait until the grandchild exits (unverified, needs a run).
- **Late output.** Until then, the grandchild's log lines and `__TRACK_PROGRESS__` markers keep arriving, because the stream listeners outlive `activeChild`. No `__TRACK_DONE__` follows, since `bulk_runner` is dead.
- **Exit code.** A killed `bulk_runner` reports `code === null` on POSIX; the Windows value is unverified.
- **Page side** (`renderer/app.js:1374-1392`):
  - Immediately marks every `downloading`/`queued` row `failed` (percent 0) and logs `⊗ Download cancelled.`
  - The Cancel button stays disabled as `Cancelling…`, and `isDownloading` stays true until `download:done` arrives.
  - The file saved by the still-running grandchild shows as `failed`; retrying it then reports `skipped`.

#### 15. FFmpeg probe — `electron-main.js:529-546`

1. `fp = require('ffmpeg-static')`, then `unpacked = fp.replace('app.asar', 'app.asar.unpacked')`.
2. Path choice: `unpacked` if it exists, else `fp` if it exists, else `'ffmpeg'` on PATH. A require failure also gives `'ffmpeg'`.
3. `spawn(ffmpegPath, ['-version'], {stdio:'ignore'})`.
4. Only the `'error'` event is handled. It sends `download:line` with `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` if the window is alive. The exit code is ignored and success is silent.

#### 16. Self-updater (summary; full detail in the updater section) — `electron-main.js:101-469`

- `isNewerVersion` (103-113): numeric dot-by-dot compare; a leading `v` is stripped and missing parts count as 0.
- `fetchLatestRelease` (115-139):
  - `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` with `User-Agent: robogears-downloader/<version>` and `Accept: application/vnd.github+json`, 10 s timeout.
  - A non-200 reply or an error resolves `null`.
- `getUpdateStatus` (145-162) returns one of:
  - `{status:'available', version: tag_name, downloadUrl, releaseUrl}`, where the asset is the one whose name includes `mac-arm64.dmg` on darwin or `setup.exe` on win32, falling back to `html_url`;
  - `{status:'up-to-date', version}`;
  - `{status:'error', message:'Could not reach GitHub'}`.
- `update:check` (178-182) returns that status and also re-sends `update:available` when one is available. `app:version` (184) returns `app.getVersion()`.
- `update:can-self-install` (194-201) is true only when packaged on win32 or darwin.
- `update:download` (288-312):
  - Refusals: `Self-install not supported on this build` and `Invalid URL` (the URL must match `/^https?:\/\//`).
  - Downloads to `<tmp>/robogears-downloader-<ts>.dmg|.exe`, following 301/302/303/307/308 for up to 5 hops with a 60 s idle timeout, and streams `update:download-progress {downloaded, total}`.
  - On macOS: `hdiutil attach -nobrowse -quiet -mountpoint <tmp>/robogears-mount-<ts>`, then `ditto` the first `*.app` into `<tmp>/robogears-update-<ts>/`, then a fire-and-forget `hdiutil detach -quiet`, then the DMG is deleted.
  - Sets `global._pendingUpdatePath` and returns `{ok:true, path}` or `{ok:false, error}`.
- `update:apply` (314-469):
  - Refusals: `Self-install not supported on this build`, `No downloaded update available` and `Self-install not implemented for <platform>`.
  - **Windows:** spawns the installer with `/S --updated`, detached, with no `'error'` listener.
  - **macOS:**
    - Logs to `~/Library/Logs/robogears Downloader/attempts.log`, then writes `<tmp>/robogears-update-<ts>.sh` (mode 755).
    - The script is a double-fork bash relauncher. It waits up to 30 s for the parent PID to exit, then removes the quarantine attribute. It backs the old app up to `.bak`, moves the new app into place, re-signs it ad hoc with `codesign --force --deep --sign -`, and opens it. If the move fails it rolls back. It logs to `update-<ts>.log`.
    - If the running path contains `/AppTranslocation/`, the target is `/Applications/<app name>.app`.
  - Either way, `app.quit()` runs after 500 ms. `global._lastUpdateLogPath` is set but never read.

#### 17. Chrome-extension bridge (inventory only; being removed)

Items to drop:
- `electron-main.js:24, 28, 497-522, 691-812`:
  - `handleExtensionTracks`: sequential matching with the same scoring, `source:'extension'`, sets `hiRes`.
  - `ensureExtensionBundle`: copies the top-level files of `<resources>/chrome-extension` to `<userData>/chrome-extension` when the bundled manifest version is newer, packaged builds only.
  - `getManagedExtensionPath` and `readManifestVersion`.
  - IPC `extension:info` → `{port, token, managedPath}` and `extension:regenerate-token` → `{token}`.
  - The event `extension:tracks-resolved {tracks}`.
- `electron-preload.js:52-55`.
- `extension-server.js`: an HTTP server on `127.0.0.1:8273` with an unauthenticated `GET /ping`, `POST /queue/add` (Bearer token, 256 KB body cap), CORS that echoes the request origin, and a 32-hex-character token in `<userData>/extension-token.txt`. Its `stopServer` is never called.
- `renderer/app.js:1587-1647` and the Settings → Extension tab (`renderer/index.html:119, 163-185`).
- `chrome-extension/` (README.md, background.js, content.css, content.js, icon.png, manifest.json, options.*, popup.*), `scripts/sync-extension-version.js`, and in `package.json` the `build.extraResources` entry and `scripts.sync-ext`.

### IPC reference

All requests are `ipcRenderer.invoke` → `ipcMain.handle`. A handler that throws rejects the page's promise; most handlers catch and return `{ok:false, error}` instead. The preload exposes everything as `window.api` via `contextBridge.exposeInMainWorld('api', …)` (`electron-preload.js:4`). Event subscriptions are plain `ipcRenderer.on` wrappers with no way to unsubscribe.

**Request channels (25)**

| `window.api` method | Channel | Main line | Argument | Result |
|---|---|---|---|---|
| `getSettings()` | `settings:get` | 555 | – | settings object, or `{}` |
| `saveSettings(s)` | `settings:save` | 556 | full settings object | the same `s`; may trigger a library scan |
| `resetSettings()` | `settings:reset` | 561 | – | `{downloadFolder:'', libraryFolder:''}` |
| `pickFolder()` | `settings:pick-folder` | 567 | – | path string, or `null` |
| `openFolder(p)` | `open-folder` | 575 | path | `''` on success, else an error string |
| `openExternal(url)` | `shell:open-external` | 186 | URL | `undefined` (opens only http/https) |
| `checkForUpdates()` | `update:check` | 178 | – | update status object (component 16) |
| `getAppVersion()` | `app:version` | 184 | – | e.g. `'0.1.30'` |
| `canSelfInstall()` | `update:can-self-install` | 201 | – | boolean |
| `downloadUpdate(url)` | `update:download` | 288 | URL | `{ok:true, path}` or `{ok:false, error}` |
| `applyUpdate()` | `update:apply` | 314 | – | `{ok:true}` or `{ok:false, error}`; app quits 500 ms later |
| `tokenExists()` | `token:exists` | 610 | – | boolean (file exists) |
| `runAuth()` | `token:run-auth` | 614 | – | `{ok:true}` or `{ok:false, error}` |
| `cancelDownload()` | `download:cancel` | 646 | – | `{ok:true}` if a child existed, else `{ok:false}` |
| `startBulk(p)` | `bulk:start` | 986 | `{tracks, outDir}` | `{ok:false, error}` at once, or `{ok: code===0, code}` at child close |
| `resolveInput(p)` | `resolve:input` | 658 | `{input}` | `{ok:true, kind:'url', tracks, capped}`, `{ok:true, kind:'search', tracks}`, `{ok:false, cancelled:true}` or `{ok:false, error}` |
| `cancelResolve()` | `resolve:cancel` | 689 | – | `{ok:true}` |
| `resolveTracklist(p)` | `resolve:tracklist` | 919 | `{tracks:[{title, artist}]}` | `{ok:true, tracks}` or `{ok:false, error}` |
| `getPreviewAudio(id)` | `preview:get-audio` | 873 | sent as `{tidalId}` | `{ok:true, audioBytes, mimeType}` or `{ok:false, error}` |
| `extensionInfo()` | `extension:info` | 805 | – | `{port, token, managedPath}` (dropped) |
| `regenerateExtensionToken()` | `extension:regenerate-token` | 810 | – | `{token}` (dropped) |
| `getQueue()` | `queue:get` | 594 | – | parsed `queue.json`, or `[]` |
| `saveQueue(q)` | `queue:save` | 599 | array | `{ok:true}` or `{ok:false, error}` |
| `libraryStatus()` | `library:status` | 577 | – | `{count, path}` (may wait for a full scan) |
| `libraryRescan()` | `library:rescan` | 582 | – | `{ok:true, count}` |

**Event channels (13, main → page)**

| Subscriber | Channel | Sent at (main) | Payload |
|---|---|---|---|
| `onUpdateAvailable(cb)` | `update:available` | 166 | `{version (raw tag, e.g. 'v0.1.31'), downloadUrl, releaseUrl}` |
| `onUpdateDownloadProgress(cb)` | `update:download-progress` | 296 | `{downloaded, total}`; `total` is 0 when unknown |
| `onAuthOutput(cb)` | `auth:output` | 623 | string: one line plus `'\n'` |
| `onAuthUrl(cb)` | `auth:url` | 632 | verification URL string |
| `onDownloadLine(cb)` | `download:line` | 519, 542, 699, 748, 796, 1018 | string: one activity-log line |
| `onDownloadDone(cb)` | `download:done` | 1035 | `{code}`: child exit code, or `null` when killed |
| `onTrackStart(cb)` | `bulk:track-start` | 1007 | `{tidalId: Number}` |
| `onTrackProgress(cb)` | `bulk:track-progress` | 1011 | `{tidalId: Number, percent: Number}` |
| `onTrackDone(cb)` | `bulk:track-done` | 1015 | `{tidalId: Number, status: 'downloaded'\|'skipped'\|'failed'\|'notFound'}` |
| `onTracklistProgress(cb)` | `tracklist:progress` | 933 | `{done, total}` |
| `onExtensionTracks(cb)` | `extension:tracks-resolved` | 746 | `{tracks}` (dropped) |
| `onLibraryScanned(cb)` | `library:scanned` | 49, 483, 585 | `{count}` |
| `onLibraryScanProgress(cb)` | `library:scan-progress` | 34 | `{done, total}` |

### Data formats

**`settings.json`**: at `<userData>/settings.json` (macOS: `~/Library/Application Support/robogears Downloader/settings.json`), 2-space JSON.

```json
{ "downloadFolder": "string", "libraryFolder": "string", "volume": 0.5 }
```

- Every field is optional; a missing or corrupt file reads as `{}`.
- `volume` is the linear slider position, 0..1. The audio gain is `volume²`, and the default is 0.5 (gain 0.25), per `renderer/app.js:506-513`.
- A blank `downloadFolder` blocks downloads with `⚠ Pick a download folder in Settings first.`
- The file is a full replace of whatever object the page sends.

**`queue.json`**: at `<userData>/queue.json`, a 2-space JSON array of queue rows.

```
{ key: string (up to 8 base36 chars),
  tidalId: number | null,
  title, artist,
  duration: seconds,
  source: 'tidal' | 'spotify' | 'import' | 'extension',
  matchMethod: 'direct' | 'search' | 'isrc' | null,
  notFound?: boolean,
  hiRes?: boolean,
  album?: string,                          // search results only
  originalTitle?, originalArtist?,         // import / extension rows
  libraryMatch?: { kind: 'exact' | 'similar', path, libraryTitle },
  included?: boolean }                     // set lazily by the page
```

- `dlStatus`, `dlPercent` and `selected` are stripped before saving.
- `queue:get` does no shape check.

**`pending-tracklist.json`**: at `<userData>/pending-tracklist.json`, 2-space JSON.

```
{ "tracks": [ <queue rows, including key, included, libraryMatch, dlStatus:'queued', dlPercent:0> ],
  "outDir": "string" }
```

- Written on every `bulk:start` and deleted when the child closes.
- `bulk_runner` reads only `tidalId`, `title` and `artist` from each row.

**`token.json`**: packaged builds keep it at `<userData>/token.json`; dev builds at `<repo>/token.json`. A 4-space JSON array of entries:

```
{ access_token, refresh_token,
  userID: number, countryCode,
  expires_at: epoch ms (now + expires_in·1000 − 60000),
  client_ID, client_secret }
```

- A single object is also accepted on read.
- `loadCred` returns `entries[0]`; `saveCred` merges into `entries[0]`; sign-in appends at the end.
- A refresh updates only `access_token` and `expires_at`, plus `countryCode` if it was missing. A new `refresh_token` from TIDAL would not be saved.
- The file holds secrets in plain text (contents not inspected).

**Resolver track rows**:

| Source | Shape |
|---|---|
| TIDAL URL | `{tidalId, title, artist (names joined ', '), duration, source:'tidal', matchMethod:'direct', hiRes}` |
| Spotify | `{title (Spotify name), artist, duration: round(duration_ms/1000), source:'spotify', tidalId \| null, matchMethod:'isrc'\|'search'\|null, notFound, hiRes}`; the error variant omits `matchMethod` and `hiRes` |
| Search | `{tidalId, title, artist, album, duration, hiRes, source:'tidal', matchMethod:'search'}` |
| Import | as in component 11 (never has `hiRes`) |

- Every variant may carry `libraryMatch`.
- `hiRes` = `mediaMetadata.tags` includes `'HIRES_LOSSLESS'`.

**Child stdout protocol.** Whole lines after splitting on `\r?\n`:

- `__TRACK_START__:<digits>`
- `__TRACK_PROGRESS__:<digits>:<0-100>`
- `__TRACK_DONE__:<digits>:<downloaded|skipped|failed|notFound>`
- Every other non-empty line is activity-log text.

Exit codes:
- `tidal_download`: 0 saved, 2 skipped, 1 error.
- `bulk_runner`: 0 after any normal run (even if every track failed), 1 on a fatal error or an empty list, `null` when killed.

**Preview result:** `{ok:true, audioBytes: Buffer → Uint8Array, mimeType}`. `mimeType` is the BTS `json.mimeType` (or `'audio/flac'`), `'audio/flac'` for DASH direct, or `'audio/mp4'` for DASH segments. The bytes are the entire track at LOSSLESS quality.

**TIDAL BT/BTS manifest (decoded):** `{mimeType?, encryptionType?, urls: [string]}`, when `manifestMimeType` starts with `application/vnd.tidal.`.

**Update status:** see component 16. The `update:available` event payload has no `status` field.

### External interfaces

| Interface | Detail |
|---|---|
| TIDAL REST (`api.tidal.com`) | **Headers:** `Authorization: Bearer <token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. 30 s idle timeout, no retries. Query values are `encodeURIComponent`'d; keys are not. **Used here:** `/v1/search/tracks?query&limit=10&countryCode`, `/v1/tracks/{id}?countryCode`, `/v1/albums/{id}/items?countryCode&limit=100&offset`, `/v1/playlists/{uuid}/items?…`, `/v1/tracks/{id}/playbackinfopostpaywall?countryCode&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`, `/v1/users/{userID}?countryCode=US`, `/v1/tracks?isrc&countryCode`. |
| TIDAL OAuth (`auth.tidal.com`) | `POST /v1/oauth2/device_authorization`; `POST /v1/oauth2/token` (device-code grant, polled every `interval` s, default 5). Refresh: `POST /v1/oauth2/token` with `client_id`, `refresh_token`, `grant_type=refresh_token`, `scope=r_usr%2Bw_usr%2Bw_sub`, Basic auth from the stored `client_ID:client_secret`, and headers `okhttp` UA, `Accept: application/json`, `Accept-Encoding: identity`, form content type. |
| TIDAL media CDN | Signed URLs from manifests (BTS `urls[0]`, DASH init and media segments) via `fetchBuffer`. |
| Spotify public embed | `https://open.spotify.com/embed/{track\|album\|playlist}/{id}` with a Chrome 120 Windows user agent and `Accept: text/html`; reads the `<script id="__NEXT_DATA__">` JSON at `props.pageProps.state.data.entity`. Playlists are capped at 100. |
| GitHub | Releases API and asset downloads (component 16). |
| Child processes | `process.execPath` + `ELECTRON_RUN_AS_NODE=1` runs `bulk_runner.js <pending-tracklist.json>`, which runs `tidal_download.js <id> <outDir> --skip-library-check`, which runs FFmpeg. |
| FFmpeg | `ffmpeg-static` binary (path rewritten from `app.asar` to `app.asar.unpacked`) or `ffmpeg` on PATH; probed with `-version`. |
| OS shell and dialogs | `shell.openExternal`, `shell.openPath`, `dialog.showOpenDialog` (choose folder, attached to the window). |
| macOS tools (updater) | `hdiutil`, `ditto`, `/bin/bash`, `ps`, `xattr`, `mv`, `codesign`, `open`. |
| Localhost server (dropped) | `127.0.0.1:8273`, `/ping` and `/queue/add`. |

### Constants and magic values

| Name | Value | Where | Meaning |
|---|---|---|---|
| App name | `'robogears Downloader'` | main:13, 80 | userData folder name and window title |
| Token path | `<userData>/token.json` (packaged); `<repo>/token.json` (dev) | main:19-21, 611 | TIDAL credentials |
| Data files | `settings.json`, `queue.json`, `extension-token.txt`, `pending-tracklist.json` in userData | main:26-28, 991 | persistence |
| Window | 980×740, min 720×540, background `#0a0a0a` | main:75-79 | main window |
| Child env | `ELECTRON_RUN_AS_NODE='1'`, `FORCE_COLOR='0'`, `TIDAL_LIBRARY_FOLDER`, `BULK_RUNNER_PROGRESS='1'` | main:62-70 | download children |
| Search limit | 10 | main:681, 942; bulk_runner:75 | TIDAL search results |
| Match acceptance | `titleScore===100 \|\| (titleScore>=25 && artistScore>=50)`; title 100/50/25/0; artist tokens longer than 2 characters, substring match | main:950-959; bulk_runner:13-29, 79 | fuzzy match |
| Normalise | `toLowerCase` → `[^a-z0-9 ]`→space → collapse spaces → trim | main:944 | matching |
| Preview quality | `'LOSSLESS'` | main:878 | preview (downloads use HI_RES_LOSSLESS) |
| Preview fetch | `{timeout: 60_000, retries: 2}`; DASH workers 8 | main:858-869, 891, 903 | preview download |
| HTTP defaults | timeout 30 000 ms, retries 3, UA `okhttp/5.3.2` | tidal_lib:14-16 | all TIDAL calls |
| Backoff | `min(1000·2^attempt, 8000)` ms | tidal_lib:186 | `fetchBuffer` |
| Library | extensions `.flac .m4a .mp3 .wav .aac .ogg .opus .alac`; 8 tag workers; progress every 25 files and at the end | tidal_lib:25, 744, 750 | scan |
| Spotify | 8 match workers; `capped` when ≥ 100 tracks | tidal_lib:399, 549 | resolve |
| Markers | `/^__TRACK_START__:(\d+)$/`, `/^__TRACK_PROGRESS__:(\d+):(\d+)$/`, `/^__TRACK_DONE__:(\d+):(\w+)$/` | main:1006-1014 | child protocol |
| Line split | `/\r?\n/` | main:1025 | child output framing |
| URL guard | `/^https?:\/\//` | main:187, 290 | open-external and update download |
| Auth scope | literal `r_usr+w_usr+w_sub`, sent as `r_usr%2Bw_usr%2Bw_sub` | tidal_auth_node:86, 128; tidal_lib:80 | OAuth |
| Auth poll | `interval` from the reply, default 5 s; token expiry minus 60 s | tidal_auth_node:99, 134, 153 | sign-in |
| GitHub | `/repos/robogears/robogearsDownloader/releases/latest`, 10 s; assets `mac-arm64.dmg` / `setup.exe` | main:117-125, 153-155 | update check |
| Quit delay | 500 ms after apply; relauncher waits ≤ 30 s | main:467, 407 | updater |
| Extension port | `127.0.0.1:8273` | extension-server:17-18 | dropped |

User-visible strings produced in this area:

| Where | String |
|---|---|
| `bulk:start` | `Another download is already running.` / `No download folder configured. Pick one in Settings.` |
| FFmpeg probe | `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` |
| Preview | `Track is DRM-encrypted` / `No stream URL in manifest` / `Unknown manifest type: <type>` / `Could not parse DASH manifest` / `No segments found in DASH manifest` |
| Auth | `ERROR: <msg>`, `Device authorization failed: …`, `Auth error: …`, `Unexpected poll response: …`, plus the log lines in component 9 |
| `tidal_lib` errors surfacing through `{ok:false, error}` | `Unauthorized — token may be invalid`, `Playback info failed: …`, `Search failed: …`, `Track info failed: …`, `Album items failed: …`, `Playlist items failed: …`, `Token refresh failed: …`, `Spotify <type> embed failed: HTTP <n>`, `No __NEXT_DATA__ in Spotify <type> embed`, `Unexpected Spotify embed shape for <type>/<id>`, `Request timeout after <ms>ms`, `HTTP <n> for <url>`, `Too many redirects` |
| `bulk_runner` | the lines in component 13, `Fatal: <msg>`, `token.json not found. Run tidal_auth_node.js first.`, `No credentials in token.json. Run tidal_auth_node.js first.` |
| Updater | `Could not reach GitHub`, `Self-install not supported on this build`, `Invalid URL`, `No downloaded update available`, `Self-install not implemented for <platform>` |

### Rules and invariants

- Set the app name before any data path is read, so dev and packaged builds share one userData folder (main:13).
- Set `TIDAL_TOKEN_PATH` before `tidal_lib` is loaded; the library reads it once (main:19-23; tidal_lib:13).
- Only one batch at a time: `bulk:start` refuses while `activeChild` is set.
- No batch without a download folder. The GUI has no default folder; it is blank on first launch.
- Child processes get no `cwd`, so they inherit the parent's (main:994-999; bulk_runner:36-44).
- `bulk_runner` always passes `--skip-library-check`: the queue is the source of truth for library duplicates. The "already in the download folder" skip still applies (exit 2 → `skipped`).
- The library folder is never written. It is scanned at boot only if set, and again whenever its value changes on save.
- Reset clears only the two folders and never touches the token.
- The page never touches files or the network.
- Only http/https URLs are opened externally or accepted for update downloads.
- Preview requests LOSSLESS. BT/BTS manifests whose `encryptionType` is present and not `'NONE'` are refused.
- Fuzzy matches are accepted only by the rule above; the highest total wins and ties keep TIDAL's order.
- Saved filenames come from TIDAL metadata inside `tidal_download`, not from queue titles.
- Per-track events are keyed by numeric `tidalId`.
- Marker lines and empty lines never reach the activity log.
- Every TIDAL-touching handler reloads credentials from disk on each call and refreshes the access token when `expires_at` has passed.

### Edge cases and failure modes

- **Token file missing or `[]`.** `loadCred` calls `process.exit(1)` and the app quits silently, from `resolve:input`, `resolve:tracklist`, `preview:get-audio` or the extension handler. A corrupt file throws instead and becomes `{ok:false, error}`; `{}` fails at token refresh.
- **Dev vs packaged.** They share `queue.json` but not the token. Starting a dev build with a queue saved by the packaged build, and no dev token, makes the boot pre-loader call `preview:get-audio`, and the app exits within moments.
- **Numeric input, e.g. `1999`, is treated as a TIDAL track ID**, and a UUID as a TIDAL playlist.
- **Plain-text line with no separator.** The artist is `''`, so `artistScore` is 0 and only an exact normalised-title match is accepted.
- **Non-Latin text normalises to `''`.**
  - Both sides empty → `titleScore` 100 (the first result is accepted).
  - Only one side empty → `startsWith('')` gives 50, so the result is accepted only with `artistScore >= 50`.
  - Accented letters are dropped (`beyoncé` → `beyonc`).
- **Artist tokens match as substrings** (`the` inside `other`); tokens of 1-2 characters are ignored.
- **API calls are not retried.** A 429/5xx during import, Spotify matching or bulk fallback search marks that track "not found" with no error shown.
- **Cancelled resolves** still finish their in-flight HTTP. A TIDAL album or playlist fetches every page before the cancel is seen.
- **Resolves wait on the library scan.** Every resolve, search and import waits for an in-flight library scan, which can take tens of seconds on a large library after launch or a folder change.
- **Unmounted library folder.** A library on a drive that is not mounted at launch is cached as empty (0 files) until Refresh or a folder change.
- **Spotify playlists of ≥ 100 tracks** set `capped`; the page warns that tracks past #100 are missing.
- **DASH oddities.** A manifest with `BaseURL` and no `SegmentTemplate` is treated as one direct file labelled `audio/flac`. `r="-1"`, non-self-closing `<S>` tags and `$Number%0Nd$` templates are not handled. Whether TIDAL emits these is unverified.
- **Cancel mid-track.** The current track still downloads and is saved. Its log lines and progress keep arriving after `⊗ Download cancelled.`, the row shows `failed`, and the Cancel button reads `Cancelling…` until the track ends.
- **A batch that fails at startup** (token refresh error, missing token on a Retry, bad list) ends with `download:done {code:1}`. Its rows are still `queued`, so the page removes them from the queue.
- **After any batch, excluded "already in library" rows are removed from the queue.** The filter keeps `!dlStatus` rows only if `included`.
- **`bulk:start` with `tracks = []`** makes `bulk_runner` print `No tracks in list.`, exit 1, and the page shows `=== Exit code 1 ===`.
- **Closing the window on macOS during a batch** kills `bulk_runner`. The later `'close'` handler then sends to a destroyed window (see Bugs). Reopening from the Dock boots a fresh page that knows nothing of the batch.
- **Cmd+Q or `app.quit()` during a batch** does not kill the children. What they do after main exits is unverified (needs a run).
- **Cmd+R (default menu)** reloads the page mid-batch; the page loses its batch state while main still has `activeChild`.
- **Opening Settings** calls `library:status`, which may start or wait for a full scan.
- **The library picker opens at the download folder.**
- **Library scan details.** Symlinked files and folders are skipped. AppleDouble `._name.flac` files are indexed (the tag read fails and the filename is used instead).
- **A library-folder change during an in-flight scan** can leave the old folder's index cached (see Bugs).
- **Token races.** Concurrent token refreshes (pre-loader, resolves and child processes each refresh on their own) do unlocked read-modify-writes of `token.json`.
- **Sign-in has no cancel and no timeouts.** An abandoned or failed sign-in leaves the auth modal on screen with no close button.
- **Two app instances** (no single-instance lock) share `settings.json`, `queue.json` and `pending-tracklist.json`; the second one fails to bind port 8273.
- **Startup warnings can be lost.** Warnings sent during boot (FFmpeg missing, extension notices, the first library-progress tick) are sent before the page has registered its listeners (see Bugs).

### Bugs and oddities

Severity uses: High = breaks a core flow or kills the app; Medium = silent loss of data the person expects kept, or a serious functional fault; Low = a silent failure that loses nothing; Info = not a defect, but worth knowing for the port.

1. **High: a missing token quits the whole app.**
   - Evidence: `tidal_lib.js:48-58`, reached from `electron-main.js:661, 875, 925` (and 702, extension).
   - `loadCred` was written for the command-line scripts and calls `process.exit(1)` inside Electron main when the token file is absent or holds `[]`.
   - `resolve:input` is protected by the page's `tokenExists` check (`renderer/app.js:1290`). These callers are not: tracklist import (`renderer/app.js:1830-1843`), the waveform pre-loader for a restored queue at boot (`renderer/app.js:1984-1986`), the preview play button, and the extension handler.
   - No message is shown.
2. **High: "Re-authenticate" does not replace the credentials the app uses.**
   - Evidence: `tidal_auth_node.js:53-59` vs `tidal_lib.js:59`.
   - `saveToken` removes only entries with the same `client_ID` and `refresh_token`, then appends the new entry at the end. `loadCred` always reads `entries[0]`.
   - Once a file has an older entry, a fresh sign-in is ignored, and a broken first token keeps being used. The only fix is deleting `token.json` by hand.
3. **Medium: Cancel does not stop the track in progress.**
   - Evidence: `electron-main.js:646-653`; `bulk_runner.js:41-44`.
   - Only `bulk_runner` is signalled. The `tidal_download` grandchild (inherited stdio) and FFmpeg finish and save the file while the row shows `failed`.
   - `download:done` and the pending-file cleanup are delayed until the grandchild exits (Node `'close'` semantics; unverified, needs a run).
   - `activeChild` is cleared at once, so main would accept a new batch. The old close handler would then clear the new `activeChild` and send a stale `download:done`. The page's `isDownloading` gate normally prevents this.
4. **Medium: sends to a destroyed window.**
   - Evidence: `electron-main.js:49, 483, 585, 1007, 1011, 1015, 1018, 1035` (and 746, 748 for the extension).
   - These check only `if (mainWindow)` or nothing, and `mainWindow` is never cleared.
   - On macOS, closing the window during a batch triggers `window-all-closed` → `kill()`. The later `'close'` handler, and any late grandchild output, then call `webContents.send` on the destroyed window. In Electron that throws "Object has been destroyed" as an uncaught exception in main (unverified for v33; needs a run).
5. **Medium: a batch that dies early drops its rows from the queue.**
   - Evidence: `renderer/app.js:1468-1473`; `bulk_runner.js:51-58, 115-118`.
   - On `download:done` the page keeps only failed, not-found, or never-sent-and-included rows. If `bulk_runner` exits before processing (token refresh failure `Fatal: …`, missing token on a Retry path, a crash), every row still marked `queued` is silently removed and the queue is saved.
6. **Medium: sign-in cannot be cancelled and a failure cannot be dismissed.**
   - Evidence: `tidal_auth_node.js:22-33, 133-170`; `renderer/index.html:205-219`; `renderer/app.js:1716-1729`.
   - There is no cancel channel, no request timeout and no overall timeout. The auth modal has no close control and closes only on success.
   - After `✗ Sign-in failed.` (or a hung request), the modal covers the app until it is reloaded or quit.
7. **Medium: the library cache races on path change or rescan.**
   - Evidence: `tidal_lib.js:28-31, 674-763`.
   - `setLibraryPath` clears the cache but not the in-flight promise. A folder change during a scan therefore gets the old scan's promise, and its old-folder result is cached as the new folder's index. Duplicate verdicts are wrong until the next Refresh.
   - `rescanLibrary` during a scan: the old scan's continuation (754-755) writes its stale result into the cache and clears the new scan's promise reference. The new result usually overwrites it later, leaving a window in which the index is stale.
8. **Medium: the directory walk runs synchronously on the main thread.**
   - Evidence: `tidal_lib.js:678-700`; reached at boot right after `createWindow()` (`electron-main.js:476-485`), on save and on Settings open.
   - All IPC and window handling stall during the walk of a large or network-mounted library. At boot this likely delays the first paint (unverified, needs a run).
9. **Medium (cost): the pre-loader downloads every queued track in full.**
   - Evidence: `electron-main.js:878-910`; `renderer/app.js:1267, 1985`.
   - Each call fetches the whole LOSSLESS file (tens of MB) and sends it over IPC, just to draw 200 waveform bars, after which the bytes are discarded. A restored 500-track queue triggers about 500 full downloads in the background.
10. **Low: messages sent during boot are probably lost.**
    - Evidence: `electron-main.js:476-522, 542, 796`.
    - `createWindow()` starts an asynchronous page load. The extension-bundle notice is sent in the same tick, and the FFmpeg-missing and extension-server warnings follow within milliseconds, likely before the page has subscribed (unverified, needs a run).
    - `update:available` is safe only once the page's listener exists; the page's `pendingUpdate` covers only the missing-welcome-line case.
11. **Low: the FFmpeg probe ignores the exit status.** Evidence: `electron-main.js:539-545`. A binary that launches but fails (wrong architecture, broken) passes silently.
12. **Low: the `bulk_runner` spawn has no `'error'` listener.** Evidence: `electron-main.js:996-999`. A spawn failure would be an uncaught exception in main. The Windows installer spawn (`314-336`) has the same gap.
13. **Low: child output framing.**
    - Evidence: `electron-main.js:1021-1029`.
    - Each chunk is decoded on its own, so a multi-byte character split across chunks (the `✓ ⏭ ⚠ —` glyphs used in log lines) becomes U+FFFD.
    - A final line without a newline is never processed.
    - stdout and stderr are buffered separately, so their relative order is lost.
14. **Low: a batch reports success even if every track failed.** Evidence: `bulk_runner.js:63-115`. `bulk_runner` exits 0 regardless, so the page plays the success ping and shows `✓ Batch finished.`
15. **Low: the page ignores `bulk:start`'s result.**
    - Evidence: `renderer/app.js:1112, 1416, 1453`.
    - An early `{ok:false, error}` (another batch running after a page reload, no folder) is never shown.
    - A rejected invoke (e.g. the pending file cannot be written) leaves the page stuck in `Downloading…` with no `download:done` coming.
16. **Info: the `notFound` marker can never be printed.**
    - Evidence: `bulk_runner.js:92-98`.
    - `__TRACK_DONE__:<id>:notFound` is printed only `if (t.tidalId)`, inside `if (!trackId)` where `trackId = t.tidalId`. The `notFound` status that main and the page handle is never emitted, and the search fallback around it is unused from the GUI.
17. **Low: Reset drops the volume.** Evidence: `electron-main.js:561-565`. The full overwrite loses `settings.volume`.
18. **Low: the volume slider is restored from the squared value.**
    - Evidence: `renderer/app.js:1948`.
    - `volumeSlider.value = round(getPreviewVolume()·100)`, but `getPreviewVolume()` returns `volume²` (the gain). A saved 0.5 shows as 25, and the next nudge saves about 0.25.
    - The comment says "defaults to 60%"; the code default is 0.5.
19. **Low: writes are not atomic.** Evidence: `electron-main.js:44, 601, 992`; `tidal_auth_node.js:58`; `tidal_lib.js:67`. A crash mid-write leaves corrupt JSON, which reads back as `{}` or `[]` without any message, silently losing the folders or the queue.
20. **Low: one folder picker for both folders.** Evidence: `electron-main.js:567-573`. The library picker opens at the download folder.
21. **Low: tracklist import is sequential, cannot be cancelled, and omits `hiRes`.** Evidence: `electron-main.js:938-976`. Compare the 8-way Spotify resolver and the `hiRes` set in the URL, search and extension paths.
22. **Info: the matching code is duplicated four times.** Evidence: `electron-main.js:712-727, 944-959`; `bulk_runner.js:11-29`; `tidal_lib.js:580-610` (that copy also scores duration).
23. **Low: one global cancel flag.** Evidence: `electron-main.js:58, 659, 689`. The flag is reset at the start of every `resolve:input`. Cancel never aborts HTTP; it is noticed only at checkpoints.
24. **Low: `fetchBuffer` redirects can throw outside the promise.**
    - Evidence: `tidal_lib.js:197-204`.
    - The protocol module is chosen from the original URL. A cross-scheme or relative `Location` header makes `proto.get` throw inside the response callback: an uncaught exception in main, while that fetch's promise never settles (the IPC call hangs).
    - 303/308 are not followed.
25. **Low: a manual update check resets the topbar pill mid-download.** Evidence: `renderer/app.js:444-450`; `electron-main.js:178-182`. `update:check` re-sends `update:available`, which sets the pill back to "Update now" and allows a second concurrent download. `global._pendingUpdatePath` is last-writer-wins.
26. **Info: `open-folder` and `openExternal` inputs are not validated.** Evidence: `electron-main.js:575, 186-188`. Any path goes to `shell.openPath` (which also launches files), and `http` is allowed as well as `https`.
27. **Info: stale comments.**
    - `electron-main.js:15-18` (settings "move" only when packaged).
    - `191-193` (Windows portable, `PORTABLE_EXECUTABLE_FILE`).
    - `504` and `761-763` (`onUpdateSelf` / `handleExtensionUpdateSelf` do not exist).
    - `984` ("used by screenshot OCR").
    - `994` ("single-track spawn above" does not exist).
    - `electron-preload.js:18-19` ("Windows portable only").
    - `bulk_runner.js:1-2` (OCR).
    - `package.json` description ("screenshot OCR").
28. **Info: hardening gaps.** No single-instance lock and no app menu: the default macOS menu exposes Reload and Developer Tools. `sandbox: false`, although the preload needs only `contextBridge` and `ipcRenderer`. No navigation or window-open guards, no IPC sender checks.
29. **Info: preload listeners cannot be removed.** Evidence: `electron-preload.js:14-65`. Every `on*` call adds another permanent `ipcRenderer.on` handler.

### Platform-specific behaviour

- **macOS:**
  - `window-all-closed` does not quit; a Dock click re-creates the window (main:524-526, 550).
  - Closing the window still kills the batch child.
  - Electron's default menu is shown.
- **Windows/Linux:** closing the window kills the child and quits. `autoHideMenuBar` hides the default menu (Alt shows it).
- **userData:**
  - macOS: `~/Library/Application Support/robogears Downloader/`.
  - Windows: `%APPDATA%\robogears Downloader\`.
  - Updater logs (macOS): `~/Library/Logs/robogears Downloader/`.
- **Dev vs packaged:** only dev sets the window icon (`build/icon.png`), and only packaged builds move the token into userData.
- **Child processes** run the Electron binary itself as Node. In packaged builds the script paths point inside `app.asar`, which Electron's Node mode can read.
- **Kill semantics:** SIGTERM (POSIX) or TerminateProcess (Windows) on the `bulk_runner` PID only; neither reaches the grandchild or FFmpeg.
- **FFmpeg path:** rewritten from `app.asar` to `app.asar.unpacked`, because spawn bypasses Electron's asar file layer.
- **Updater:**
  - darwin: the `mac-arm64.dmg` asset, then `hdiutil`/`ditto`, then the bash relauncher (with App Translocation handling).
  - win32: `setup.exe` with `/S --updated`.
  - Linux and dev: the release page opens in the browser.
- **Drag region:** the topbar uses CSS `-webkit-app-region: drag` (`renderer/styles.css:49`) on a standard framed window.

### Porting notes for a native Swift macOS app

| Topic | Today | Swift equivalent | Difficulty |
|---|---|---|---|
| IPC bridge | 25 request + 13 event channels between a web page and a Node process | Not needed. Each request becomes an `async` method on a service/actor; each event becomes observable state (`@Observable`) or an `AsyncStream`. Keep the result shapes as Swift enums: ok / error(message) / cancelled. | Easy |
| Batch pipeline | JSON file + Electron-as-Node `bulk_runner` + `tidal_download` per track + stdout markers | One in-process sequential batch `Task` calling a download function directly, with typed callbacks (start, progress 0-100, done: downloaded / skipped / failed / notFound) and a log sink. Keep: one batch at a time, refuse without a folder, the end-of-batch summary counts, "exists in folder → skipped". FFmpeg (if kept) is the only external `Process`. | Medium |
| Cancellation | Kills `bulk_runner` only; global boolean for resolves | Structured concurrency: `Task.cancel()`, `try Task.checkCancellation()` in loops, cancel `URLSession` tasks, `terminate()` the FFmpeg `Process`, delete temp files. Decide whether Cancel stops the current track (today it does not). | Medium |
| Batch end and queue pruning | Page drops rows that are not failed/notFound/untouched | Make the rule explicit and fix the early-failure loss: rows that never started stay queued (or become failed). Decide whether "already in library" rows are pruned after a batch. | Easy |
| Settings and queue files | Full overwrite with `writeFileSync`; errors read as `{}` / `[]` | `FileManager` Application Support + `robogears Downloader`, `Codable` models with optional fields, `Data.write(options: .atomic)`. Keep the 400 ms queue / 300 ms volume debounces and strip transient row fields. Store `volume` as the linear slider value and apply `volume²`. | Easy |
| Migration | — | Optionally import `settings.json`, `queue.json` and `token.json` from `~/Library/Application Support/robogears Downloader/` (a sandboxed app cannot read it without user permission). Delete `extension-token.txt` and `chrome-extension/`. | Easy |
| Folder picker and access | `showOpenDialog openDirectory` + `defaultPath` | `NSOpenPanel` (`canChooseDirectories`, `!canChooseFiles`, `directoryURL`), one per folder with its own starting folder. If sandboxed: security-scoped bookmarks for both folders. | Medium |
| Open folder / URL | `shell.openPath`, `shell.openExternal` (http/https) | `NSWorkspace.shared.open(_:)` / `activateFileViewerSelecting`; open only https after a scheme check. | Easy |
| TIDAL sign-in | Node https POSTs, `setTimeout` polling, no cancel or timeout | `URLSession` POSTs with the same headers. Build the form body by hand so `+` in the scope becomes `%2B`: `URLComponents` leaves `+` unencoded, and servers read it as a space. Use an async polling loop with cancellation and an overall deadline, `NSWorkspace` to open the URL (add `https://` if the scheme is missing), `NSPasteboard` for Copy, and a sheet with a Cancel button. | Medium |
| Token storage | `token.json` array, first-entry read / append-on-sign-in mismatch | A single credential record (Keychain recommended: it holds the access and refresh tokens plus the client secret). Replace on sign-in; save a rotated `refresh_token` if TIDAL returns one. Never exit the app on "no token": return a "Sign in to TIDAL first" error. The embedded client credentials need an equivalent obfuscated store. | Medium |
| Preview fetch, peaks, playback | Full LOSSLESS download per track, sent to the page; Web Audio peaks; Blob-URL `<audio>` | `URLSession` to a temp file; peaks via `AVAudioFile`/`AVAssetReader` (or FFmpeg decoding to PCM); playback and scrubbing via `AVPlayer`/`AVAudioPlayer`. Whether AVFoundation decodes TIDAL's raw FLAC (BTS) and FLAC-in-fragmented-MP4 (DASH) is unverified (needs a run). Consider loading on demand instead of pre-downloading every queued track. | Hard |
| HTTP layer | Custom headers, idle timeouts 30 s / 60 s, manual redirects, retry/backoff | `URLSession` with per-request headers and `timeoutIntervalForRequest` (an idle timeout, matching today's values); redirects are automatic. A small retry wrapper for network errors, timeouts, 429 and 5xx at `min(1000·2^n, 8000)` ms; consider applying it to API calls too (today only `fetchBuffer` retries). | Easy |
| Worker pools | Shared index counter + N async workers (8 segments, 8 Spotify, 8 tags; page pre-loader 2) | `withThrowingTaskGroup`, capped at N in flight, results stored by index. | Easy |
| Library scan | Synchronous walk on the main thread + `music-metadata`; process-lifetime cache | `FileManager.enumerator` on a background task; tags via AVFoundation metadata (FLAC Vorbis-comment support uncertain) or TagLib/ffprobe. An actor-owned cache with a generation counter, so a path change or rescan discards stale results. Progress about every 25 files. Re-check an empty result when the volume mounts. | Medium |
| Window and lifecycle | One 980×740 window (min 720×540); macOS stays alive when it closes; closing kills the batch | SwiftUI `Window` with `defaultSize(width: 980, height: 740)` and `frame(minWidth: 720, minHeight: 540)`, reopen on Dock click. Decide explicitly whether closing the window or quitting stops a batch (consider asking for confirmation on Quit while downloading). | Easy |
| Menus | Electron default menu (Reload, DevTools) | A native menu bar with every command: Settings… (Cmd+,) under the app menu, standard Edit/Window/Help, and queue/download commands with shortcuts. | Medium |
| FFmpeg check | Spawn `-version`; warn only on spawn error, as a log line that may be lost | Bundle FFmpeg in `Contents/Helpers`, sign it with the app, run `Process` with `-version` at launch, require `terminationStatus == 0`, and show a persistent visible error. Or replace FFmpeg with native remuxing and tagging. | Medium |
| Security plumbing | CSP, `contextIsolation`, preload, `sandbox:false`, child env vars | Not applicable; drop it. If the App Sandbox is adopted: network-client and user-selected read-write entitlements plus bookmarks. Pass the token store, library index and progress callbacks as dependencies instead of environment variables. | Easy |
| Version / update check | `app.getVersion()`; GitHub compare | `Bundle.main` `CFBundleShortVersionString`, same compare; installation is covered in the updater section. | Easy |

### Open questions

1. Should Cancel stop the track that is downloading? Today it is saved anyway while its row shows `failed`.
2. Should closing the window on macOS, or quitting, stop a running batch, ask first, or let downloads continue in the background?
3. Should a batch report failure when any track fails? Today `bulk_runner` exits 0 and the success sound plays.
4. After a batch, should "already in library" rows (not included) stay in the queue? Today they are removed.
5. Which token entry is authoritative, and should sign-in replace the file? Today the first entry is read and new ones are appended.
6. Does TIDAL ever rotate the refresh token on refresh? The code never saves a new one.
7. Is it intended that refresh uses the `REQUEST_*` client pair while the device flow uses the `AUTH_*` pair? It works per the docs, but the code does not explain why.
8. Does TIDAL's `verificationUriComplete` include a scheme? It goes unmodified to `shell.openExternal` (main:630). Some third-party TIDAL clients prefix `https://` to it. If it arrives scheme-less, the browser does not open and only the Copy button helps. Unverified (needs a run).
9. Should the Swift app migrate existing `settings.json`, `queue.json` and `token.json`, and clean up `extension-token.txt` and `chrome-extension/`?
10. Is downloading the full LOSSLESS file for every queued track (waveform pre-load) wanted, or can it become on-demand?
11. Can AVFoundation decode TIDAL LOSSLESS as delivered (raw FLAC from BTS; FLAC-in-fragmented-MP4 from DASH)? Unverified (needs a run).
12. Do TIDAL DASH manifests ever use `BaseURL`-only, `r="-1"`, non-self-closing `<S>` or `$Number%0Nd$`? Unverified (needs a run).
13. Do the boot-time warnings (FFmpeg missing, extension notices) ever reach the page? Unverified (needs a run).
14. Should Reset keep the preview volume?
15. Should imported rows get the Hi-Res badge like URL and search rows?
16. Does `-webkit-app-region: drag` on the topbar have any effect on this framed window? That is, was a custom title-bar look intended? Unverified (needs a run).
