## App launch and quit

Scope: everything that happens from the moment the Electron main process starts until the first screen is settled, plus every way the app or its window can close (closing the window, ⌘Q / menu Quit, `app.quit()` after "Update now", re-opening from the Dock, View → Reload). Code version 0.1.30 (`package.json:3`), Electron `^33.0.0` (`package.json:25`). Chrome-extension code is listed only as inventory; the Swift port drops it (owner decision, 21 Oct 2026).

### Overview

**Launch.** The main process gives itself the name `robogears Downloader` so that its data folder is `~/Library/Application Support/robogears Downloader/` in both dev and packaged builds. In a packaged build it then points the TIDAL token file at that folder. Only after that does it load `tidal_lib.js`, because that module fixes the token path the moment it loads. Every request handler the page can call is registered while the module loads, before any window exists. When Electron is ready, main reads `settings.json`, sets the music-library path, and opens one 980×740 window straight away (no hidden-until-ready step). In the same synchronous step it then starts the library scan, if a library folder is set. The scan's directory walk runs on the main thread and blocks it until the walk finishes. Only after the walk does main start, without waiting for any of them, the GitHub "is there a newer release" check, an FFmpeg presence probe, and two extension jobs (inventory only). Last, it registers the Dock "reopen" handler.

The page (renderer) paints static HTML. It then registers all of its listeners for messages pushed from main, and runs one boot routine in a fixed order: load settings → fill the folder fields and volume slider → check sign-in → show the version (not awaited) → check sign-in again and write one of three welcome lines → restore the saved queue → start background waveform loading for every restored row (each one downloads the full lossless track through main) → show any update notice that arrived early. Messages that main pushes before the page has registered its listeners are lost, and nothing is ever re-sent.

**Quit.** There is exactly one shutdown hook: `window-all-closed`. It kills the running batch-download process (`bulk_runner`) but not the per-track downloader it spawned. On Windows and Linux it then quits; on macOS the app stays running with no window. ⌘Q, menu Quit and the updater's `app.quit()` do **not** fire that hook, so nothing is killed at all. There is no "downloads in progress, quit anyway?" prompt, the 400 ms queue-save delay is never flushed, and files are written in place (not atomically). One defect matters more than the rest. The token loader calls `process.exit(1)` when `token.json` is missing, and the boot routine's waveform preloader triggers it. So a saved queue with no token makes the whole app quit within moments of every launch.

---

### Steps

#### A. Main process, module load (before Electron is ready)

1. **Requires** — `electron-main.js:2-6`: `app, BrowserWindow, ipcMain, dialog, shell` from electron; `path`, `fs`, `https`, `child_process.spawn`. (`os` is required mid-file at `:203`.)
2. **Name the app** — `electron-main.js:13`: `app.setName('robogears Downloader')`. This must come before any `app.getPath()`. Without it, dev mode would use the package name `robogears-downloader` (hyphen) and packaged mode the product name `robogears Downloader` (space), giving two different data folders.
   - userData = `~/Library/Application Support/robogears Downloader/` (macOS), `%APPDATA%\robogears Downloader\` (Windows).
3. **Token path (packaged only)** — `electron-main.js:19-21`: if `app.isPackaged`, set `process.env.TIDAL_TOKEN_PATH = <userData>/token.json`. In dev it stays unset, unless the developer's shell already exports it.
4. **Load the TIDAL library** — `electron-main.js:23` → `tidal_lib.js`. Module-level values are fixed now:
   - `TOKEN_FILE = process.env.TIDAL_TOKEN_PATH || <source dir>/token.json` (`tidal_lib.js:13`). Dev therefore uses `<repo>/token.json` and packaged uses `<userData>/token.json`. `queue.json` and `settings.json` live in userData in **both** modes.
   - `USER_AGENT = 'okhttp/5.3.2'`, `DEFAULT_TIMEOUT = 30000`, `DEFAULT_RETRIES = 3` (`:14-16`).
   - `LIBRARY_PATH = process.env.TIDAL_LIBRARY_FOLDER || ''` (`:24`). Normally unset in main; only spawned children get that variable.
   - `LIBRARY_EXTS = {.flac .m4a .mp3 .wav .aac .ogg .opus .alac}` (`:25`).
   - `_libraryCache = null`, `_libraryScanPromise = null` (`:622-623`), `_mmCached = null` (`:658`).
   - `tidal_auth_node.js` is **not** loaded here. It is required lazily inside `token:run-auth` (`electron-main.js:620`), and it fixes its own `TOKEN_FILE` the same way when it loads (`tidal_auth_node.js:15`).
5. **Load the extension server** — `electron-main.js:24` → `extension-server.js`. No side effects at load (`PORT = 8273`, `HOST = '127.0.0.1'`, `extension-server.js:17-18`). *Inventory only.*
6. **Path helpers** — `electron-main.js:26-28`: `settings.json`, `queue.json`, `extension-token.txt`, all in userData. `bulk:start` also writes `<userData>/pending-tracklist.json` (`:991`).
7. **Module state** — `electron-main.js:54-58`: `mainWindow = null`, `activeChild = null` (the one running `bulk_runner` process), `resolverCancelled = false`. `mainWindow` is reassigned by every `createWindow()` and is **never** set back to `null`.
8. **Register every request handler synchronously**, before the window exists, so a page request can never arrive before its handler. The 25 invoke channels, with the line of each `ipcMain.handle`:
   `update:check` 178 · `app:version` 184 · `shell:open-external` 186 · `update:can-self-install` 201 · `update:download` 288 · `update:apply` 314 · `settings:get` 555 · `settings:save` 556 · `settings:reset` 561 · `settings:pick-folder` 567 · `open-folder` 575 · `library:status` 577 · `library:rescan` 582 · `queue:get` 594 · `queue:save` 599 · `token:exists` 610 · `token:run-auth` 614 · `download:cancel` 646 · `resolve:input` 658 · `resolve:cancel` 689 · `extension:info` 805 · `extension:regenerate-token` 810 · `preview:get-audio` 873 · `resolve:tracklist` 919 · `bulk:start` 986.
9. **The only lifecycle hook** — `electron-main.js:548-551`, registered at module scope:
   ```js
   app.on('window-all-closed', () => {
       if (activeChild) try { activeChild.kill(); } catch {}
       if (process.platform !== 'darwin') app.quit();
   });
   ```
   The code has none of the following: `before-quit`, `will-quit` or `quit` handlers; BrowserWindow `close`/`closed` handlers; `process.on('SIGTERM'|'uncaughtException'|…)`; `app.requestSingleInstanceLock()`; `Menu.setApplicationMenu()`; `open-file` or `open-url` handlers. `extensionServer.stopServer()` exists (`extension-server.js:204-209`) but is never called.

#### B. Main process, `app.whenReady()` (`electron-main.js:471-527`)

Everything in this callback runs in one synchronous step, up to the end of the library walk in step B4. Steps B5–B9 therefore start only after the walk finishes.

1. **Read settings** — `:473` → `loadSettings()` (`:38-41`): `JSON.parse(fs.readFileSync(settings.json,'utf8'))`, or `{}` on any error (file missing, empty or corrupt). The read is synchronous.
2. **Set the library path** — `:474`: if `typeof s.libraryFolder === 'string'`, call `lib.setLibraryPath(s.libraryFolder)` (`tidal_lib.js:28-31`). That trims the string and sets `_libraryCache = null`. It does **not** clear `_libraryScanPromise`.
3. **Open the window** — `:476` → `createWindow()` (`:73-99`):
   ```text
   new BrowserWindow({
     width: 980, height: 740, minWidth: 720, minHeight: 540,
     backgroundColor: '#0a0a0a', title: 'robogears Downloader',
     webPreferences: { preload: <app>/electron-preload.js,
                       contextIsolation: true, nodeIntegration: false, sandbox: false },
     autoHideMenuBar: true,
     icon: <app>/build/icon.png        // dev only (!app.isPackaged)
   })
   mainWindow.loadFile(<app>/renderer/index.html)   // not awaited
   // openDevTools is commented out (:98)
   ```
   - No `show:false` or `ready-to-show`: the window appears immediately, filled with `#0a0a0a`. The page's own background is `#000000` (`styles.css:3,30`), so the colour shifts slightly when the page paints.
   - No `titleBarStyle`: on macOS this is a standard title-bar window. The page's top bar is also a drag region (`styles.css:49`).
   - `autoHideMenuBar` has no effect on macOS.
   - Without `Menu.setApplicationMenu`, Electron installs its built-in default menu. On macOS that includes App → Quit (⌘Q), Close Window (⌘W), Edit, View → Reload (⌘R) / Force Reload / Toggle Developer Tools, Window, and a Help menu with Electron links. This is Electron's default; not checked in a run.
4. **Library scan, only if `s.libraryFolder` is truthy** — `:481-485`:
   ```js
   lib.scanLibrary(sendScanProgress).then(c => {
       if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
   }).catch(() => {});
   ```
   `scanLibrary` (`tidal_lib.js:674-757`):
   - If `_libraryCache !== null`, return it. If `_libraryScanPromise` is set, return that.
   - Otherwise start an async function that runs **synchronously up to its first `await`**, on the main thread:
     a. If `LIBRARY_PATH` is empty or `!fs.existsSync(LIBRARY_PATH)`, resolve `{entries: []}` with no progress event. That empty result is then cached for the process lifetime.
     b. `loadMM()`: lazy synchronous `require('music-metadata')` (v7.x, CommonJS). If that fails, remember `false`; tags are then never read, and the whole scan runs synchronously because the workers never await.
     c. Recursive `fs.readdirSync(dir, {withFileTypes:true})` walk from `LIBRARY_PATH`. Unreadable directories are skipped silently. Files are kept if `path.extname(name).toLowerCase()` is in `LIBRARY_EXTS`. Symlinks are neither followed nor listed (`isDirectory()`/`isFile()` are false for them).
     d. `onProgress(0, total)` → `sendScanProgress` (`electron-main.js:32-36`, guarded with `isDestroyed()`) → push `library:scan-progress {done:0,total}`.
     e. Start 8 workers. Each calls `mm.parseFile(file, {duration:true, skipCovers:true, skipPostHeaders:true})` (its synchronous prefix runs now), then awaits.
   - Main cannot answer any page request until a–e finish.
   - Async part: each file becomes one index entry `{path, fnFull, fnTitleFull, fnCore, fnTitleCore, metaTitleFull, metaTitleCore, metaTitleDisplay, metaArtist (normalised), metaDuration (rounded seconds)}`. The filename title is the part after the last `' - '` of the base name. A tag-read error falls back to filename-only data.
   - Progress is pushed when `done - lastReportedAt >= 25` or `done === total`.
   - At the end: `_libraryCache = result; _libraryScanPromise = null`.
   - On first launch (no `libraryFolder`) the scan is skipped entirely.
   - The `library:scanned` send has no `isDestroyed()` check. A throw from sending to a destroyed window is swallowed by `.catch(() => {})`.
5. **Update check** — `:489` `checkForUpdatesAndNotify().catch(() => {})` (`:174-176`). Runs once per process.
   - `fetchLatestRelease()` (`:115-139`): `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` with headers `User-Agent: robogears-downloader/<version>` and `Accept: application/vnd.github+json`, and a socket `timeout: 10000`.
   - Status ≠ 200, invalid JSON, a request error or a timeout all resolve `null`. An error on the response stream itself has no handler, so the promise would never settle (silent).
   - `getUpdateStatus()` (`:145-162`):
     - no release, or no `tag_name` → `{status:'error', message:'Could not reach GitHub'}`;
     - `!isNewerVersion(tag_name, app.getVersion())` → `{status:'up-to-date', version}`;
     - otherwise `{status:'available', version: tag_name, downloadUrl, releaseUrl: html_url}`. `downloadUrl` is the `browser_download_url` of the first asset whose `name` contains `'mac-arm64.dmg'` (darwin) or `'setup.exe'` (win32); other platforms, or no matching asset, fall back to `html_url`.
   - `isNewerVersion` (`:103-113`): strip one leading `v`, split on `.`, `parseInt(x,10) || 0` per part, compare left to right, treating missing parts as 0. Equal means "not newer".
   - `notifyIfAvailable` (`:164-172`): only when the status is `available` and the window is alive, push `update:available {version, downloadUrl, releaseUrl}`. `error` and `up-to-date` are silent at launch.
6. **FFmpeg probe** — `:495` → `verifyFfmpegAvailable()` (`:529-546`).
   - Path: `require('ffmpeg-static')`. If the path with `app.asar` replaced by `app.asar.unpacked` exists, use that; else the raw path if it exists; else `'ffmpeg'` (resolved on `PATH`). This is the same rule the downloader child uses (`tidal_download.js:32-36`).
   - `spawn(path, ['-version'], {stdio:'ignore'})`, listening **only** for `'error'` (spawn failure such as ENOENT or EACCES).
   - On error: push `download:line` `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.`
   - A non-zero exit is ignored, and success prints nothing.
7. **Extension bundle copy** — `:500` → `ensureExtensionBundle()` (`:775-802`). *Inventory:* packaged builds only. Synchronously copies `<resources>/chrome-extension/*` into `<userData>/chrome-extension/` when the user copy is missing or older, then pushes a `🧩 …` line.
8. **Extension server** — `:506-522` → `startServer()`. *Inventory:* synchronously loads or creates `<userData>/extension-token.txt` (32 hex characters) and listens on `127.0.0.1:8273`. A listen error (for example `EADDRINUSE` from a second running copy) pushes `⚠ Chrome-extension bridge couldn't start: <msg> (tracks won't push from Spotify)`. The socket is released only when the process exits.
9. **Dock reopen** — `:524-526`: `app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); })`. It is registered only here, after the walk.

#### C. Page load and boot (renderer)

1. **Static HTML** — `renderer/index.html`.
   - CSP (`:5`): `default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;`
   - Top bar: vinyl logo SVG, `robogears Downloader`, empty `#brand-version`, hidden `#brand-update-pill` "Update now", settings gear.
   - Input card: label "Paste a link or search for a song", placeholder "Spotify/TIDAL URL or song name...", hint "Paste a Spotify or TIDAL link to add all its tracks. Or type a song name to search."
   - Drop zone: "Drop a playlist CSV or paste tracks", with an Exportify link.
   - Queue section hidden (`hidden`); volume slider `value="50"`.
   - Empty Activity log.
   - Hidden modals: search, Settings (tabs Folders / TIDAL / Extension / Updates), auth, loading overlay. `#auth-status` and `#library-status` show `…` and `#update-status` shows `Current version: …`; all three sit inside the hidden Settings modal.
   - `[hidden]` is made `display:none` for the pill, queue, loading overlay, modal backdrop and modal panes (`styles.css:113,433,849,895,977,990`).
   - `<script src="app.js">` sits at the end of `<body>`, so the DOM exists when it runs.
2. **Preload bridge** — `electron-preload.js:4-66`: `contextBridge.exposeInMainWorld('api', …)`. Invoke wrappers call `ipcRenderer.invoke(channel, arg)`. `on…(cb)` wrappers call `ipcRenderer.on(channel, (_e, p) => cb(p))`. Listeners can never be removed, and nothing buffers a push that arrives before its `on…` has been called.
3. **Top-level `app.js` evaluation** (`renderer/app.js:5-1939`), all synchronous:
   - State: `settings = {downloadFolder:''}`, `queue = []`, `isDownloading = false`, `welcomeLineEl = null`, `pendingUpdate = null`, `previewState = {playingTidalId:null, audio:null, audioCtx:null, peaksCache: Map, audioCache: Map, MAX_AUDIO_CACHE: 3}`, `preloader = {queue: [], inFlight: 0, CONCURRENCY: 2}`.
   - Push listeners are registered in this order:
     - `onUpdateAvailable(insertUpdateNotice)` :435
     - `onUpdateAvailable(pill handler)` :444
     - `onUpdateDownloadProgress(pill)` :481
     - `onTrackStart` / `onTrackProgress` / `onTrackDone` :1225 / :1232 / :1239
     - `onDownloadLine(appendLine)` :1456
     - `onDownloadDone` :1457
     - `onExtensionTracks` :1641
     - `onLibraryScanned` :1687
     - `onLibraryScanProgress` :1694
     - `onAuthOutput` :1731
     - `onAuthUrl` :1736
     - `onTracklistProgress` :1823
     
     `insertUpdateNotice` adds one more `onUpdateDownloadProgress` listener (:424) when it renders a notice and self-install is supported.
   - All DOM listeners are wired here too, including a document-level `paste` listener (:1800-1808) that can start a tracklist import.
4. **Boot routine** — `renderer/app.js:1943-1995`. It runs strictly in order and has no try/catch except around the queue restore:
   1. `settings = await api.getSettings()` → main re-reads `settings.json` (`electron-main.js:555`). This waits if main is still in the B4 walk.
   2. `#folder-input` ← `settings.downloadFolder || ''`, and `#library-input` ← `settings.libraryFolder || ''`.
   3. `volumeSlider.value = Math.round(getPreviewVolume() * 100)`. `getPreviewVolume()` returns the **squared** value (`v = typeof settings.volume === 'number' ? settings.volume : 0.5`, then `clamp(v)²`, `:506-513`), so an unset or 0.5 volume shows the slider at **25**. See Bugs.
   4. `updateOpenButtonStates()` (`:1512-1515`): `#folder-open.disabled = !downloadFolder`, `#library-open.disabled = !libraryFolder`.
   5. `await refreshAuthStatus()` (`:1703-1714`) → `token:exists` → main runs `fs.existsSync(process.env.TIDAL_TOKEN_PATH || <__dirname>/token.json)` (`electron-main.js:610-613`). Result `true` → `#auth-status` "✓ Signed in" (class `auth-status ok`), and the button reads "Re-authenticate". Result `false` → "Not signed in" (class `auth-status bad`), and the button reads "Sign in to TIDAL". This checks existence only; contents are not validated.
   6. `api.getAppVersion()`, **not awaited** → `#brand-version` = `v0.1.30` and `#update-status` = `Current version: v0.1.30`. It may land after the welcome line.
   7. `await api.tokenExists()` again, then append the welcome line and keep the element in `welcomeLineEl`. The first rule that matches wins:
      - no token → `👋 Welcome! Click the ⚙ icon to sign in to TIDAL.`
      - no `downloadFolder` → `Pick a download folder in Settings to get started.`
      - otherwise → `Ready. Downloads go to: <downloadFolder>`
   8. **Queue restore** (try/catch):
      - `await api.getQueue()`. Main returns `JSON.parse(readFileSync(queue.json))`, or `[]` on any error (`electron-main.js:594-597`).
      - If the result is a non-empty array: copy each row, delete `dlStatus`, `dlPercent` and `selected`, and give any row without a `key` one from `uniqueKey()` (`Math.random().toString(36).slice(2,10)`).
      - `renderQueue()` unhides the queue section, sets `included = !(libraryMatch?.kind === 'exact')` on any row where it is `undefined`, and sets the Download button: disabled if `isDownloading` or nothing is downloadable; text `Download (N)` when N downloadable ≠ queue length, else `Download all`.
      - Append `↺ Restored N track(s) from your last session.` (singular "track" when N = 1).
      - `libraryMatch` and `included` are restored **as saved**; the boot library scan never re-checks them.
   9. **Waveform preloading**: `enqueuePreload(t.tidalId)` for every restored row with `tidalId && !notFound` (`:730-767`).
      - Rows already in `peaksCache` or already queued are skipped.
      - `drainPreloader` keeps at most 2 running. `preloadOne` → `getPeaks` → `fetchAudioBytesIpc` → `api.getPreviewAudio(tidalId)` (step E1).
      - The returned bytes are copied to an ArrayBuffer and decoded with `AudioContext.decodeAudioData`; the AudioContext is created lazily and is separate from the sound-effects context.
      - `computePeaks(buffer, 200)`: channel 0 only; `samplesPerBar = max(1, floor(len/200))`; peak = max |sample| per bar; then all peaks are divided by the largest one.
      - Peaks are stored in `peaksCache` (memory only, no limit) and painted into every matching `.qi-waveform[data-tidal-id]` canvas. The audio bytes are discarded.
      - Failures are silent and never retried automatically.
      - Boot does **not** check sign-in first. See Bugs, item 1.
   10. If `pendingUpdate` is set, call `insertUpdateNotice(pendingUpdate)` and clear it.

#### D. Arrivals after boot, in any order

- **`update:available {version, downloadUrl, releaseUrl}`** goes to two listeners.
  - **Pill** (`:444-450`): store the URL, set state `available`, unhide and enable the pill, text `Update now`.
  - **Activity notice** (`insertUpdateNotice`, `:371-433`):
    - If `welcomeLineEl` is missing or detached, stash it in `pendingUpdate`.
    - Else, if an `.update-notice` row already exists, do nothing.
    - Else insert, right after the welcome line, a row whose label is set with `innerHTML` to `🚀 New version available: <strong>{version}</strong>`, plus a button `Download update`.
    - Then `await canSelfInstall()` (true only for packaged darwin or win32, `electron-main.js:194-200`). If false, the button opens `downloadUrl` in the browser.
    - If true, the button runs a small state machine: `idle` → click → `Starting…` (disabled) → `downloadUpdate(url)`. Failure gives `Download failed — retry` and back to idle. Success gives `Restart to apply` (class `ready`); click → `Restarting…` → `applyUpdate()`.
    - Download progress text: `Downloading N%` when the size is known, else `Downloading X.X MB`.
  - **Pill click** (`:452-477`):
    - Only acts in state `available`.
    - If self-install is not supported, open the URL in the browser and stay `available`.
    - Otherwise `Downloading…` (disabled) → `downloadUpdate`. Failure gives `Retry update` (state `available`). Success gives `Restarting…` → `applyUpdate()`.
    - Neither UI checks whether a batch is downloading.
- **`library:scan-progress {done,total}`** → `#library-status` = `Scanning d / t…`, or `Scanning…` when `total` is 0.
- **`library:scanned {count}`** → `#library-status` = `N file(s) indexed`.
- **`download:line <text>`** → `appendLine`. Each line is classified for styling. The log is capped at `ACTIVITY_LOG_MAX = 2000` children; the oldest is removed, but if the oldest is `welcomeLineEl`, the element after it is removed instead.
- **Opening Settings later** (`:1505-1509`): `await refreshAuthStatus()`, then `refreshLibraryStatus()` (not awaited), then open the modal.
  - `refreshLibraryStatus` sets `Scanning…` and invokes `library:status` (`electron-main.js:577-580`), which awaits `scanLibrary()`: the in-flight scan, the cached result, or (cache empty and nothing running) a fresh scan.
  - It returns `{count, path: lib.LIBRARY_PATH}`. A blank `path` shows `(no library folder set)`; otherwise `N file(s) indexed`; a failure shows `(scan failed)`.
  - This makes the library status correct again if the earlier pushes were lost.

#### E. Work that boot triggers in main, and steady-state persistence that matters at quit

1. **`preview:get-audio {tidalId}`** (`electron-main.js:873-917`):
   - `lib.loadCred()` (`tidal_lib.js:48-60`) reads `token.json` fresh from disk each call. **If the file is missing, or holds an empty array, it calls `process.exit(1)`.** A bare object is treated as a one-element array, and the first entry is returned.
   - `getToken(cred)` (`:97-102`): uses the cached token while `Date.now() < expires_at`; otherwise refreshes it and rewrites `token.json` (`:62-95`).
   - `getCountryCode(cred)` (`:104-119`): `cred.countryCode`, else `GET /v1/users/{userID}?countryCode=US` and save the result, else `'US'`.
   - `getPlaybackInfo(id, token, 'LOSSLESS', country)` (`:286-296`).
   - Manifest handling:
     - `manifestMimeType` starts with `application/vnd.tidal.` → decode base64 to JSON. `encryptionType` other than `NONE` → `{ok:false, error:'Track is DRM-encrypted'}`. No `urls` → `{ok:false, error:'No stream URL in manifest'}`. Otherwise `fetchBuffer(urls[0], {timeout:60000, retries:2})` → `{ok:true, audioBytes, mimeType: json.mimeType || 'audio/flac'}`.
     - `application/dash+xml` → `_parseDashForPreview`. With no `SegmentTemplate` and a `BaseURL`, it is a direct fetch → `mimeType:'audio/flac'`. Otherwise fetch the init segment, then all segments with 8 parallel workers (`timeout:60000, retries:2` each), concatenated in order → `mimeType:'audio/mp4'`.
     - Anything else → `{ok:false, error:'Unknown manifest type: …'}`.
   - Any other exception → `{ok:false, error}`.
   - Nothing is written to disk, and the fetch cannot be cancelled. The whole track is held in memory and then sent over IPC (it arrives in the page as a `Uint8Array`).
2. **Queue saves** — `saveQueueSoon()` (`app.js:73-83`): a 400 ms trailing debounce. When it fires it copies the queue without `dlStatus`, `dlPercent` and `selected`, and invokes `queue:save`. Main runs `fs.writeFileSync(queue.json, JSON.stringify(queue || [], null, 2))` straight to the final path (not atomic) and returns `{ok}` / `{ok:false,error}`.
   - Triggers: + Add, ✕ remove, Clear all, adding tracks, and the end of a batch (`download:done`, `:1481`).
   - Batch progress events never save, so during a batch `queue.json` holds the pre-batch snapshot plus any edits the user made meanwhile (✕ remove, + Add and CSV import still work during a batch).
3. **Settings saves** — the volume slider saves after a 300 ms debounce (`:516-524`). It sends the renderer's whole `settings` object, with `volume` = slider position 0–1.
   - The folder pickers and Clear save at once. `saveSettings` (`electron-main.js:42-52`) writes the file directly (not atomic).
   - If `libraryFolder` is a string that differs from the stored one, it calls `setLibraryPath` and starts a new scan, which pushes `library:scanned` (no `isDestroyed()` check; the error is swallowed).
   - `settings:reset` writes exactly `{downloadFolder:'', libraryFolder:''}`, which also drops `volume`.

#### F. Close and quit paths

**F1. Closing the window on macOS (red button, ⌘W, File → Close Window)**
1. The page unloads. There is no `beforeunload`/`pagehide` handler, so pending timers die with it: the 400 ms queue save, the 300 ms volume save, the preloader queue, the loading-text cycler and the scrub/resize timers. The AudioContexts and blob URLs go too. Requests already sent keep running in main, and their replies are dropped.
2. `window-all-closed` fires (`electron-main.js:548-551`). If `activeChild` is set, `activeChild.kill()` sends SIGTERM to `bulk_runner` only. `activeChild` is **not** cleared. On macOS the app does not quit.
3. `bulk_runner` has no SIGTERM handler and exits. Its current `tidal_download` child was spawned with `stdio:'inherit'` (`bulk_runner.js:41-44`), so it holds the same stdout/stderr pipes to main. It is not signalled and carries on: segments, FFmpeg remux, integrity check. Main's ChildProcess `close` event (process exited **and** all stdio closed) therefore waits until that child exits as well. Process-tree behaviour derived from the code; unverified (needs a run).
4. While no window exists, each output line reaches `dispatchLine` (`:1004-1019`), which calls `mainWindow.webContents.send` on the destroyed window with no `isDestroyed()` guard. Electron throws "Object has been destroyed" for that, which is why every other send site guards it. These throws happen inside stream and child-process event handlers, so they are uncaught main-process exceptions. Electron's default response is a "A JavaScript error occurred in the main process" dialog for each one, possibly many in a row. Unverified (needs a run).
5. When the child's `close` fires with no window, line 1035 throws **before** `activeChild = null` and before `pending-tracklist.json` is deleted, so neither happens. Every later `bulk:start` then returns `{ok:false, error:'Another download is already running.'}` (`:987`).
6. Everything else in main keeps running: an in-flight library scan, resolves (`resolverCancelled` is not set), preview fetches, sign-in polling (which writes `token.json` if the user approves in the browser), an update download, and the extension server.

**F2. Closing the window on Windows or Linux** — steps 1–3 as in F1, then `app.quit()`. Output arriving between the window closing and the process exiting hits the same unguarded sends (possibly an error dialog during quit; unverified). After main exits, the orphaned `tidal_download` should crash with EPIPE on its next stdout write. See F3.

**F3. `app.quit()`** — ⌘Q, App → Quit, or `update:apply` (`setTimeout(() => app.quit(), 500)`, `electron-main.js:467`).
1. Electron closes all windows (renderer losses as in F1 step 1). As documented by Electron, `window-all-closed` is **not** emitted on this path, so **no child is killed**. There are no `before-quit`/`will-quit` handlers, nothing is flushed, and the extension server is not stopped. The main process exits.
2. Orphaned `bulk_runner` and `tidal_download`: the read end of their stdout/stderr pipe is gone. Node ignores SIGPIPE, so the next `console.log` gets EPIPE; with no `'error'` listener on stdout, the process crashes. Unverified (needs a run).
   - `tidal_download` writes `__TRACK_PROGRESS__:<id>:<pct>` whenever the whole-number percent changes during the network phase (`tidal_download.js:433-442`). It therefore dies quickly mid-download and leaves `<Title>.tmp.flac` or `<Title>.tmp.m4a` in the **download** folder.
   - During the FFmpeg remux it writes nothing. A remux already under way therefore usually finishes, and the process crashes on its next line, `✓ Saved…`.
   - `bulk_runner` writes nothing while waiting for its child, so it crashes on its next `__TRACK_DONE__`. The remaining tracks are not downloaded.
   - `<userData>/pending-tracklist.json` is left behind.
3. FFmpeg writes straight to the final `<Title>.flac` / `<Title>.m4a`, and `tidal_download` treats any existing final file as done (`tidal_download.js:359-366`). If the remux process is ever killed mid-write, the truncated file is skipped as "already in downloads folder" on every later run. The normal quit path above rarely causes this, but nothing prevents it.

**F4. Dock click on macOS with no window (`activate`)** → `createWindow()` reassigns `mainWindow` and a fresh page runs the whole of C.
- Settings are re-read. The queue comes from the last saved `queue.json`, which is the pre-batch snapshot if a batch was running. The preloader downloads full audio for every row again, while any older fetches may still be running.
- Main does **not** redo the scan (the cached result is kept and `library:scanned` is not re-sent), the update check (the pill and notice will not appear even if an update was found), or the FFmpeg probe.
- If the boot scan is still running, its later progress and `library:scanned` pushes go to the new window, because they look up `mainWindow` each time.
- `activeChild`, `resolverCancelled`, `global._pendingUpdatePath` and the extension server carry over.
- If the old batch's child is still running when the window re-opens, its events now reach the new page: rows update by `tidalId`, and `download:done` arrives and clears `activeChild` normally. The "stuck" state in F1 step 5 happens only if the child finished while no window existed.
- The new page always starts with `isDownloading = false`, because there is no request for "is a batch running?".

**F5. View → Reload (⌘R) from Electron's default menu** — the same page reset as F4 inside the same window. Main state and any running batch continue, and the batch's events and final `download:done` reach the reloaded page. If the user presses Download all on the reloaded page during that batch, `bulk:start` refuses. The refusal is ignored (`app.js:1453`), the UI shows `Downloading…`, and when the old batch's `download:done` arrives, the rows the user just set to `queued` are **removed from the queue** (see Bugs).

**F6. Forced exit through `loadCred()`** — `process.exit(1)` inside the Electron main process ends the app; Electron is generally understood to route `process.exit` to `app.exit`, so windows close immediately and no quit events fire (mechanism unverified, needs a run). Triggers in main: `preview:get-audio` (boot preloader, play button), `resolve:tracklist` (CSV drop, file pick, multi-line paste), `resolve:input` (guarded by a sign-in check first), and the extension handler (inventory).

---

### Data formats

**userData folder** (`~/Library/Application Support/robogears Downloader/`)

| File | Written by | Read by | Format |
|---|---|---|---|
| `settings.json` | `saveSettings` (`electron-main.js:42-52`) | `loadSettings` at ready, `settings:get`, `childEnv()`, `pick-folder` | `JSON.stringify(obj, null, 2)` |
| `queue.json` | `queue:save` (`:599-606`) | `queue:get` (`:594-597`) at every page boot | `JSON.stringify(array, null, 2)` |
| `token.json` | auth flow, token refresh, country-code save | `loadCred` in main and in every child; `token:exists` | `JSON.stringify(array, null, 4)`. **In dev mode this file is `<repo>/token.json`, not userData.** |
| `pending-tracklist.json` | `bulk:start` (`:991-992`) | `bulk_runner` at start | `{tracks, outDir}`, 2-space; deleted on child `close` |
| `extension-token.txt`, `chrome-extension/` | extension code | extension code | *inventory, dropped* |

Electron/Chromium also keep their own profile data in this folder (cache, local storage and similar). That is general Electron behaviour, not checked on this machine; a Swift app should ignore it.

**settings.json** — whatever object the page last sent. Keys used:
```json
{ "downloadFolder": "/abs/path", "libraryFolder": "/abs/path or empty", "volume": 0.5 }
```
- `downloadFolder`: blank on first launch; downloads are refused until it is set.
- `libraryFolder`: `''` or missing means no duplicate check.
- `volume`: the **slider position** 0–1, linear. Playback gain = `volume²`. Default when missing: 0.5.
- The file does not exist until the first save. Reset writes only the two folder keys.

**queue.json** — an array of rows. All fields except `title` and `artist` are optional:
```text
{
  tidalId: number | null,
  title: string, artist: string,
  duration: number (seconds; 0 or missing allowed),
  album?: string,                         // search results only
  source: 'tidal' | 'spotify' | 'import' | 'extension',
  matchMethod?: 'direct' | 'search' | 'isrc' | null,
  hiRes?: boolean,
  notFound?: boolean,
  originalTitle?: string, originalArtist?: string,   // import / extension
  libraryMatch?: { kind: 'exact' | 'similar', path: string, libraryTitle: string },
  included: boolean,                      // set on first render if missing
  key: string                             // 8-char base-36, unique per row
}
```
`dlStatus` (`'queued'|'downloading'|'downloaded'|'skipped'|'failed'|'notFound'`), `dlPercent` and `selected` exist only in memory and are stripped on every save and on restore.

**token.json** — an array of credential objects with the field names `access_token`, `refresh_token`, `userID`, `countryCode`, `expires_at` (ms epoch, set 60 s early), `client_ID`, `client_secret`. Values are secret and are not reproduced here. A bare object is accepted as a one-element array. Every reader uses **entry 0**; token refresh updates entry 0; signing in again **appends** a new entry (see Bugs). The TIDAL app credentials used for sign-in are four base64 string literals decoded with `Buffer.from(…,'base64')` at `tidal_auth_node.js:17-20` (`AUTH_CLIENT_ID`, `AUTH_CLIENT_SECRET`, `REQUEST_CLIENT_ID`, `REQUEST_CLIENT_SECRET`). The `REQUEST_*` pair is what gets stored in `token.json`.

**Requests and pushes used during launch**

| Channel | Direction | Payload → reply |
|---|---|---|
| `settings:get` | page → main | none → settings object or `{}` |
| `token:exists` | page → main | none → `boolean` (file exists) |
| `app:version` | page → main | none → `'0.1.30'` |
| `queue:get` | page → main | none → array or `[]` |
| `preview:get-audio` | page → main | `{tidalId}` → `{ok:true, audioBytes, mimeType}` or `{ok:false, error}` |
| `library:status` | page → main | none → `{count, path}` |
| `update:can-self-install` | page → main | none → `boolean` |
| `library:scan-progress` | main → page | `{done, total}` |
| `library:scanned` | main → page | `{count}` |
| `update:available` | main → page | `{version, downloadUrl, releaseUrl}` |
| `download:line` | main → page | string |

---

### External interfaces

- **GitHub** (once per launch): `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest`, unauthenticated (60 requests/hour per IP). Headers `User-Agent: robogears-downloader/<version>`, `Accept: application/vnd.github+json`; 10 s socket timeout. Fields used: `tag_name`, `html_url`, `assets[].name`, `assets[].browser_download_url`. This endpoint returns only the newest **published** release; drafts and prereleases are invisible to it.
- **TIDAL API** (every restored row, at launch):
  - `GET https://api.tidal.com/v1/tracks/{id}/playbackinfopostpaywall?countryCode=<cc>&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`
  - Headers: `Authorization: Bearer <token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`.
  - 30 s timeout. HTTP 401 → `Unauthorized — token may be invalid`.
- **TIDAL token refresh**, when the access token has expired: `POST https://auth.tidal.com/v1/oauth2/token`, form body `client_id`, `refresh_token`, `grant_type=refresh_token`, `scope=r_usr+w_usr+w_sub` (form-encoded), HTTP Basic auth with `client_ID:client_secret` from `token.json`.
- **TIDAL country lookup**, only when the token has no country: `GET /v1/users/{userID}?countryCode=US`.
- **TIDAL CDN** (`fetchBuffer`, `tidal_lib.js:174-232`):
  - `User-Agent: okhttp/5.3.2`; follows 301/302/307 up to 5 times.
  - Retries 429, 5xx, network errors and timeouts with back-off `min(1000·2^attempt, 8000)` ms. Other non-200 statuses fail at once.
- **FFmpeg**: `<ffmpeg> -version` with all stdio ignored; only a spawn failure is detected.
- **Filesystem**: the userData files above; a read-only recursive walk of the music library; tag reads through `music-metadata` v7.
- **Inventory (dropped)**: an HTTP server on `127.0.0.1:8273`.

---

### Constants and magic values

| Name / place | Value | Meaning |
|---|---|---|
| App name, `electron-main.js:13` | `robogears Downloader` | userData folder name and Dock name |
| Window, `:75-80` | 980 × 740, min 720 × 540, bg `#0a0a0a` | first window |
| Page background, `styles.css:3` | `#000000` | differs from the window background |
| Update host and path, `:118-119` | `api.github.com` `/repos/robogears/robogearsDownloader/releases/latest` | launch update check |
| Update timeout, `:125` | 10 000 ms | socket timeout |
| Asset match, `:153-155` | `mac-arm64.dmg` / `setup.exe` | platform asset substring |
| Quit delay after apply, `:467` | 500 ms | `setTimeout(app.quit, 500)` |
| Update download timeout, `:230` | 60 000 ms, ≤5 redirects | `downloadToFile` |
| FFmpeg warning, `:543` | `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` | activity line |
| Busy refusal, `:987` | `Another download is already running.` | `bulk:start` while `activeChild` is set |
| Library extensions, `tidal_lib.js:25` | `.flac .m4a .mp3 .wav .aac .ogg .opus .alac` | scanned files |
| Scan workers / progress step, `:750,744` | 8 / every 25 files (+ final) | tag reading |
| `parseFile` options, `:723` | `{duration:true, skipCovers:true, skipPostHeaders:true}` | tag read |
| HTTP defaults, `tidal_lib.js:14-16` | UA `okhttp/5.3.2`, 30 000 ms, 3 retries | TIDAL requests |
| Back-off, `:186` | `min(1000·2^n, 8000)` ms | `fetchBuffer` retries |
| Token expiry margin, `:88` | `expires_in` (default 3600 s) − 60 s | `expires_at` |
| Country fallback, `:118` | `US` | when the lookup fails |
| Preview fetch, `electron-main.js:858,866,891,903` | 60 000 ms, retries 2; DASH workers 8 | `preview:get-audio` |
| Preloader, `app.js:558` | concurrency 2 | background waveforms |
| Peaks, `app.js:686` | 200 bars, channel 0, normalised | waveform |
| Audio cache, `app.js:549` | 3 entries (LRU, blob URLs) | playback cache |
| Activity cap, `app.js:54` | 2000 lines | log trim |
| Queue save debounce, `app.js:82` | 400 ms | `saveQueueSoon` |
| Volume save debounce, `app.js:523` | 300 ms | slider |
| Default volume, `app.js:511`; HTML `index.html:68` | 0.5 (gain 0.25); slider HTML default 50 | volume |
| Transient row fields, `app.js:71` | `dlStatus`, `dlPercent`, `selected` | never persisted |
| Row key, `app.js:87` | `Math.random().toString(36).slice(2,10)` | stable row id |
| Welcome lines, `app.js:1961-1965` | see C4.7 | boot |
| Restore line, `app.js:1981` | `↺ Restored N track(s) from your last session.` | boot |
| Extension port (inventory), `extension-server.js:17` | 8273 on 127.0.0.1 | dropped |

---

### Rules and invariants

1. `setName` runs before any `getPath`, and `TIDAL_TOKEN_PATH` is set before `tidal_lib` loads. Breaking either splits the data folder or makes main and the children read different token files.
2. All request handlers exist before the window, so page requests never race their registration. Pushes from main, however, are only delivered if the page's listener already exists. Nothing is queued or replayed, except that one `update:available` arriving before the welcome line exists is stashed.
3. The library folder is read-only: the scan only walks and reads tags. The scan runs at launch only if `libraryFolder` is set. Its result is cached for the whole process lifetime, an empty result included.
4. The update check runs exactly once per process, at launch, plus whenever the user presses **Check for updates**.
5. At most one batch process at a time (`activeChild`). The only automatic cleanup is in `window-all-closed`.
6. Page boot order is fixed (C4). The welcome line always exists before the queue-restore line, and the update notice is inserted directly under the welcome line.
7. Transient download state is never saved. A restored row always starts idle, so a queue saved mid-batch comes back as "not yet downloaded".
8. On macOS, closing the last window keeps the process alive. On Windows and Linux it quits.

---

### Edge cases and failure modes

| Situation | What happens | What the user sees | Left on disk |
|---|---|---|---|
| Saved queue with ≥1 row that has a `tidalId`, but `token.json` is missing or `[]` | The first preload calls `loadCred` → `process.exit(1)` in main | The window appears, then the app vanishes, on every launch | `queue.json` stays, so it repeats; fixed only by deleting `queue.json` or restoring the token |
| First launch (no settings, no queue) | No scan; welcome line depends on the token | Welcome line only | Nothing (files appear on the first save) |
| `settings.json` corrupt or empty | `{}` | Looks like a first launch (folders blank) | Overwritten on the next save |
| `settings.json` is valid JSON but not an object (e.g. `null`) | `s.libraryFolder` throws inside `whenReady` before `createWindow()` | No window opens (edge case; the app never writes this) | n/a |
| `queue.json` corrupt | `[]`, silently | Queue gone | Overwritten on the next queue save |
| Library folder missing or unmounted | `{entries:[]}` cached; no progress | `0 files indexed` in Settings; duplicate check silently off for the session | Nothing |
| Large or network library | Synchronous walk blocks main's thread | Window appears but stays blank or unresponsive, and the welcome line and queue restore wait; the update check, FFmpeg probe and Dock handler all start late | Nothing |
| Paste or drop a CSV right after launch | Matching waits for the whole in-flight scan (`findInLibrary` → `scanLibrary`) | Loading overlay for the length of the scan | Nothing |
| FFmpeg missing | The probe's `error` fires within milliseconds, before the page has listeners | Very likely **no warning at all** (unverified, needs a run); downloads later fail | Nothing |
| GitHub slow or unreachable | Silent | No pill or notice | Nothing |
| Update found before the page is ready | The push may be dropped (unverified) | No pill or notice until Settings → Check for updates | Nothing |
| Library scan running at quit | ⌘Q: process ends. macOS window close: scan continues; its final send to the dead window is swallowed | Re-opened window shows `…` until Settings is opened | Nothing |
| Resolve running at window close (macOS) | Runs to the end; reply dropped | Nothing | `token.json` may be refreshed |
| Preview fetch running at close (macOS) | Full download continues and is dropped; a re-opened window starts all preloads again | Extra network use | Nothing |
| Sign-in polling at window close (macOS) | Continues; writes `token.json` if approved | Re-opened window shows signed in | `token.json` |
| Update download at quit | Partial temp files | Nothing; the next launch checks again | `$TMPDIR/robogears-downloader-<ts>.dmg` (partial); possibly `$TMPDIR/robogears-mount-<ts>` still mounted and `$TMPDIR/robogears-update-<ts>/<App>.app` |
| Batch running, window closed (macOS) | F1 | Possible main-process error dialogs; the remaining tracks never download; downloads refused for the rest of the session if the child ended while no window existed | `pending-tracklist.json`; current track usually finishes; `queue.json` = pre-batch snapshot |
| Batch running, window closed (Windows/Linux) | F2 | App closes, maybe after an error dialog | Partial `<Title>.tmp.*`; `pending-tracklist.json` |
| Batch running, ⌘Q / Update now | F3; no prompt | App quits at once | Partial `<Title>.tmp.*`; `pending-tracklist.json`; tracks already downloaded come back in the queue next launch and will report "skipped" |
| Queue or volume edit < 400 ms / 300 ms before close or reload | Debounce timer discarded | The change is undone next launch | Stale JSON |
| Crash or power loss during a save | Half-written JSON | Queue silently empty, or settings back to first-launch | Truncated file until the next save |
| Two copies running (dev and packaged side by side, `open -n`, Windows double launch) | Both use the same `settings.json`, `queue.json` and (packaged) `token.json`; the second cannot bind port 8273 | Last writer wins on the queue | Mixed files |

---

### Bugs and oddities

1. **High — `loadCred()` calls `process.exit(1)` inside the Electron main process; a saved queue with no token quits the app at every launch.**
   - Where: `tidal_lib.js:48-60` (exits at `:51` and `:56`). Callers in main: `electron-main.js:661` (`resolve:input`), `:702` (extension), `:875` (`preview:get-audio`), `:925` (`resolve:tracklist`). Launch trigger: `app.js:1984-1986`. The `try/catch` in each handler cannot stop an exit.
   - Realistic ways in: dev mode uses `<repo>/token.json` while packaged mode uses `<userData>/token.json`, yet both share `<userData>/queue.json`; or `token.json` deleted or holding `[]`.
   - The same exit happens without a restored queue if, while signed out, the user drops or picks a CSV (`handleTracklistInput`, `app.js:1830`, has no sign-in check), pastes multi-line text outside an input field (`app.js:1800-1808`), or presses ▶ on a row.
2. **Medium — Closing the window on macOS during a batch: sends to a destroyed window, a batch-busy flag that may never clear, and the batch silently cut short.**
   - Where: `electron-main.js:549` (kill without clearing), `:1007/1011/1015/1018/1035` (sends with no `isDestroyed()` check), `:987` (busy guard); `app.js:1112, 1416, 1453` (the `startBulk` result is ignored).
   - Effect: only `bulk_runner` is killed, so the remaining tracks are dropped while the current one usually finishes.
   - Each later output line throws "Object has been destroyed", likely shown as Electron error dialogs (unverified, needs a run).
   - If the child's `close` fires while no window exists, `activeChild = null` and the deletion of `pending-tracklist.json` are skipped. From then on **Download all** silently does nothing: the UI sticks at `Downloading…` and no `download:done` ever comes. **Cancel** clears main's flag but leaves the page in the downloading state until a reload.
   - Re-opening the window before the child ends avoids the stuck state (F4).
3. **Medium — Quitting never stops the download processes, and no quit path warns.**
   - Where: `electron-main.js:548-551` (the only hook; not emitted on `app.quit()`), `:467` (Update now quits), `bulk_runner.js:41-44` (`stdio:'inherit'`); the Update UIs do not check `isDownloading` (`app.js:400-421, 452-477`).
   - ⌘Q and Update now kill nothing. Closing the window kills `bulk_runner` but never `tidal_download` or its FFmpeg.
   - The orphans die later on a broken pipe (unverified, needs a run), leaving `<Title>.tmp.*` files in the user's download folder and `pending-tracklist.json` in userData.
   - FFmpeg writes the final file in place, and skip-if-exists (`tidal_download.js:359-366`) trusts any existing final file, so a remux interrupted for any reason leaves a truncated `<Title>.flac` that later runs skip forever.
4. **Medium — The library index can belong to the wrong folder after a folder change during a scan.**
   - Where: `tidal_lib.js:28-31` (`setLibraryPath` does not clear `_libraryScanPromise`), `:674-676`, `:754-755`; `electron-main.js:45-51`.
   - Changing, clearing or resetting the folder while a scan runs makes the next `scanLibrary()` return the **old** scan's promise, and its entries become the cache.
   - After **Clear**, the log says "duplicate check disabled" but rows keep matching the old library: "exact" rows are greyed out and excluded by default, and "similar" rows are flagged. This lasts until Refresh or a restart.
   - `rescanLibrary()` during a scan lets the older scan's ending overwrite the cache. That is permanent if the older scan finishes last.
5. **Medium — Signing in again appends a new credential, but everything keeps using the first one.**
   - Where: `tidal_auth_node.js:53-59` (`saveToken` removes only entries with an identical `client_ID` + `refresh_token`, then pushes); `tidal_lib.js:59` (`entries[0]`) and `:66` (refresh updates `entries[0]`).
   - After **Re-authenticate**, `token.json` holds `[old, new]`, and main and every child keep using the old credential. Signing in again therefore cannot repair a revoked refresh token. This is part of the sign-in flow, but it decides which credential every launch uses.
6. **Medium (owner's data-safety scale: silent loss of the saved queue) — Queue and settings saves are not atomic and are never flushed at close.**
   - Where: `electron-main.js:42-44, 599-606` (`writeFileSync` straight to the final path), `:594-597` (corrupt read becomes `[]` silently); `app.js:73-83, 523` (debounces with no flush).
   - The windows are small (a sub-second debounce, a tiny file), but loss is silent: a damaged file is read back as empty and then overwritten.
7. **Medium (download flow, found while tracing reload and re-open) — When a batch ends with rows still `queued` (or stuck at `downloading`), those rows are removed from the queue and the queue is saved.**
   - Where: `app.js:1468-1473` keeps only `notFound`, `failed`, `notFound`-status, or `(!dlStatus && included)` rows, so `queued` and `downloading` rows are dropped; then `saveQueueSoon()` at `:1481`.
   - Happens when (a) `bulk_runner` dies before reaching some tracks, for example a token-refresh or network failure at start (`bulk_runner.js:56-58, 115-118`), which wipes every row of that batch; or (b) after a Reload or re-open during a running batch, the user presses Download all (refused, F5), and the old batch's `download:done` then drops all the newly queued rows.
8. **Low — Pushes sent before the page listens are lost, and nothing is re-sent to a new or reloaded window.**
   - Where: `electron-main.js:482, 489, 495, 500, 506-522` versus listener registration at `app.js:435-1823`; `:524-526`.
   - Very likely affected: the scan's `0 / total` tick (sent in the same synchronous step as `loadFile`), the FFmpeg-missing warning (the spawn `error` fires on the next tick) and the extension messages. `update:available` races the page load.
   - The comment at `electron-main.js:487-488` ("Renderer handles the race…") is only true once the listener exists; the page's stash covers a missing welcome line, not a missing listener.
   - After a Dock re-open or Reload, the Update pill and notice, the library count and the FFmpeg warning are never re-sent. Runtime loss is unverified (needs a run).
9. **Low — The volume slider is restored to the squared value.** `app.js:1948` vs `:506-513`. A saved 0.5 shows as 25 while the gain is still 0.25. The first nudge (to 26) drops the gain to about 0.068, and each launch after a change shows the square again. The comment says "defaults to 60%"; the actual default is position 0.5, shown as 25.
10. **Low — Synchronous directory walk on the main thread at launch.** `tidal_lib.js:687-700`, called from `electron-main.js:482` (also `:48, 578, 584`). It blocks all requests and window work for the length of the walk, and delays every later launch job (B5–B9).
11. **Low — The restored queue keeps old library-match state.** `app.js:1971-1980`. `libraryMatch` and `included` are never re-checked against the new scan, so songs added to or removed from the library since last session show the wrong badge and default.
12. **Low — Every launch re-downloads full lossless audio for every restored row.** `app.js:1984-1986, 692-700`; `electron-main.js:873-917`. Peaks are kept only in memory and the bytes are thrown away. 100 rows means about 100 full-track downloads per launch, again after every re-open or Reload, and they continue in main after the window closes. Failures are never retried.
13. **Low — Clearing the activity log stops later update notices from appearing.** `app.js:361, 371-375`. Clear detaches `welcomeLineEl`; a later `update:available` (for example from Check for updates) is stashed in `pendingUpdate`, which is applied only at boot. The pill still works.
14. **Low — No single-instance lock, and Electron's default menu.** No `requestSingleInstanceLock` or `Menu.setApplicationMenu` anywhere. A second copy shares the data files. The menu exposes Reload and Toggle Developer Tools; Reload resets the page while a batch keeps running in main (F5).
15. **Low — Token refreshes are not coordinated.** `tidal_lib.js:62-102`. Each caller re-reads the file and refreshes on its own when the token has expired: the 2 launch preloads, plus `bulk_runner`. Writes are not atomic, so a reader in another process can catch a half-written file and fail to parse it (unverified, needs a run).
16. **Low — Reset config also forgets the preview volume.** `electron-main.js:561-565` writes only the two folder keys.
17. **Info** — the update label is built with `innerHTML` from GitHub's `tag_name` (`app.js:382`), trusted only because the repo owner controls it. The window background `#0a0a0a` differs from the page's `#000000`.
18. **Info — stale comments**: `electron-preload.js:18-19` and `electron-main.js:191-193` ("Windows portable"); `app.js:390-391` (same); `electron-main.js:984` ("screenshot OCR") and `:994` (a "single-track spawn above" that no longer exists); `app.js:2` and `bulk_runner.js:1-5` (OCR, and an old tracklist shape); `app.js:1947` ("60%"); `electron-main.js:487-488` (see 8); `package.json:4` (OCR). The code is the source of truth.

---

### Platform-specific behaviour

| Topic | macOS | Windows | Linux |
|---|---|---|---|
| userData | `~/Library/Application Support/robogears Downloader/` | `%APPDATA%\robogears Downloader\` | `~/.config/robogears Downloader/` (Electron default) |
| Last window closed | App keeps running; batch process killed; Dock click re-creates the window | Batch process killed, then quit | Same as Windows |
| `kill()` | SIGTERM to `bulk_runner` only | TerminateProcess on `bulk_runner` only (no tree kill) | SIGTERM, `bulk_runner` only |
| Menu | Electron default app menu (Quit, Close Window, Reload, DevTools…) | Default menu, auto-hidden (`autoHideMenuBar`) | Same as Windows |
| Self-install | Packaged: yes (DMG mount + relaunch script, then quit after 500 ms) | Packaged: yes (NSIS `/S --updated`, then quit after 500 ms) | No; opens the release page |
| Update asset | `mac-arm64.dmg` | `setup.exe` | none (release page) |
| Dev-mode icon | `build/icon.png` set on the window | same | same |
| Updater logs | `~/Library/Logs/robogears Downloader/` (`attempts.log`, `update-<ts>.log`) | n/a | n/a |

---

### Porting notes for a native Swift macOS app

1. **One app-level model, not window-level state.** Keep settings, the queue, sign-in state, the library index and its status, update availability, FFmpeg health and batch progress in one `@Observable` model (or an actor-backed store) owned by the `App` / `NSApplicationDelegate`. Windows only display it. That removes three Electron problems at once: events lost before listeners exist, a re-opened window forgetting the update pill or library count, and sends to a destroyed window. A re-opened window must show a running batch and its progress.
2. **Launch order to reproduce.**
   1. Resolve Application Support.
   2. Load `settings.json` (`downloadFolder`, `libraryFolder`, `volume` = slider position with gain `v²`, default 0.5) and the queue (strip `dlStatus`/`dlPercent`/`selected`; give rows without a key a stable id). Load synchronously; both are small.
   3. Read sign-in state.
   4. Show the window with content already filled in (980 × 740 default, 720 × 540 minimum, dark background).
   5. Start background tasks: library scan, one GitHub update check, FFmpeg check, waveform loads.
   
   Show the slider at the stored position, not its square.
3. **Welcome and status copy** (first match wins): no token → `Welcome! Click the ⚙ icon to sign in to TIDAL.` (adapt the wording to a native Settings window, for example "Open Settings (⌘,) to sign in to TIDAL."); no download folder → `Pick a download folder in Settings to get started.`; otherwise `Ready. Downloads go to: <folder>`. Then, if rows were restored, `Restored N track(s) from your last session.` Show `v<CFBundleShortVersionString>` where the topbar version was.
4. **Never end the process because credentials are missing.** Model a signed-out state, and gate preview, link resolving, CSV/paste import and downloads on it with a clear message. Use one token-manager actor that serialises refreshes and saves atomically (or in the Keychain). Store a single current credential, which fixes the append-versus-`entries[0]` mismatch. The TIDAL app credentials (base64 literals at `tidal_auth_node.js:17-20`) need a deliberate storage decision; do not paste them into source without one.
5. **Library scan.** Walk off the main actor (`FileManager.enumerator` in a detached task). Read title, artist and duration with AVFoundation or a tag library. Report progress (every 25 files today). Tag each scan with a generation number so that a folder change cancels the old scan and its result can never become the cache. Report a missing or unmounted folder instead of silently caching zero entries, and re-scan when the volume mounts. After the scan, re-check the restored queue's library matches. Consider the planned disk cache keyed by path, modification date and size.
6. **Update check.** `GET api.github.com/repos/robogears/robogearsDownloader/releases/latest` with a 10 s timeout. Version compare: strip one leading `v`, compare dot-separated integers (non-numbers count as 0, missing parts as 0). Asset substring `mac-arm64.dmg`. Silent on failure at launch. Keep the result in the model so any window shows the Update control, and refuse or confirm "Update now" while a batch is running.
7. **FFmpeg.** Ship it inside the bundle (for example `Contents/Helpers/ffmpeg`), signed with the app; the `app.asar` rewrite is not needed. Check at launch with `Process` running `-version`, test **both** launch failure and a non-zero exit status, and hold the result in the model so the warning cannot be lost. Or use AVFoundation for remuxing and tagging where it can do the job.
8. **Quit.** Implement `applicationShouldTerminate(_:)`. If a batch, resolve, preview, sign-in or update download is running, ask first (the Electron app never asks), for example "Downloads in progress — Quit anyway?" with **Quit** and **Cancel**. Then cancel every task, terminate every `Process` you started (child processes are not killed automatically when the parent exits), remove partial temp files, flush pending queue and settings saves, and return `.terminateNow`. Do not save mid-batch status as "done".
9. **Crash-safe downloads.** Write audio to a temp file, remux into a temp output, then atomically rename to `<Title>.flac` / `<Title>.m4a`. Treat only a renamed, complete file as "already downloaded". Clean stale `*.tmp.*` leftovers you created, never anything else in the user's folder.
10. **macOS window lifecycle.** Pick one model explicitly:
    - (a) quit when the last window closes (`applicationShouldTerminateAfterLastWindowClosed` → `true`), going through the quit confirmation;
    - (b) keep running with downloads continuing, and re-create the window on Dock click (`applicationShouldHandleReopen` or a single SwiftUI `Window` scene).
    
    The Electron app's mix (stay running but kill the batch) gives the benefit of neither.
11. **Persistence.** Write the queue with `Data.write(to:options:.atomic)` after each change. A short debounce is fine, but flush in `applicationWillTerminate` and when the window closes. If a file fails to decode, move it aside (for example `queue.json.unreadable-<date>`) and tell the user; never silently replace it with an empty queue. Never drop rows that are still `queued` when a batch ends early; return them to idle instead.
12. **Waveforms.** Limit concurrency (2 today), make loads cancellable (on row removal and at quit), and save peaks to disk (for example `Caches/<tidalId>.peaks`, 200 floats) so launches don't re-download whole lossless tracks. Consider loading only visible rows. Retry failures when sign-in state changes.
13. **Menus and windows.**
    - A standard menu bar: App menu with About, **Settings… (⌘,)** and Quit (⌘Q); File → Close Window (⌘W); Edit with standard commands; Window.
    - No Reload or Developer Tools, so the "page reset while a batch runs" problem disappears.
    - Normal Launch Services launches already give one instance; still guard the data files against a second copy launched with `open -n`.
14. **Data continuity.** Electron's data lives in `~/Library/Application Support/robogears Downloader/`. A Swift app with bundle id `com.robogears.downloader` (`package.json:29`) may choose a different folder; decide whether to import `settings.json`, `queue.json` and `token.json` from there on first launch. In dev builds the token is in the repo folder instead. Ignore Chromium's own profile files in that folder.
15. **Drop the extension.** Do not port `extension-server.js` (`127.0.0.1:8273`), `ensureExtensionBundle`, `<userData>/chrome-extension/`, `extension-token.txt` or the Settings → Extension tab. Leave any existing `extension-token.txt` alone rather than deleting it unasked.
16. **Logs.** Keep `~/Library/Logs/robogears Downloader/` for file logs or OSLog exports so older updater diagnostics stay findable.

---

### Open questions

1. On macOS, should closing the last window quit the Swift app (after confirming if downloads are running), or keep it running with downloads continuing until ⌘Q? Recommended default: keep running and show progress in the Dock icon. The Electron app currently keeps running but cuts the batch short.
2. When the user confirms a quit during a download, should the current track finish first, or be stopped and its temp file removed? Recommended default: stop and clean up, keeping the row queued for next launch.
3. Should the Swift app import the Electron data (`settings.json`, `queue.json`, `token.json`) from `~/Library/Application Support/robogears Downloader/` so folders, queue and TIDAL sign-in carry over, or start fresh?
4. Where should the TIDAL token live: the Keychain (recommended) or a `token.json` file? Should there be an explicit **Sign Out**, which the Electron app lacks?
5. Should a restored queue be re-checked against the fresh library scan at launch? That could change which rows are greyed out or included.
6. Is downloading full lossless audio for every queued row at every launch acceptable, or should waveforms be cached on disk and/or loaded only for visible or played rows?
7. Should the update check also run on a timer or when the window re-opens, or only once per launch as today?
