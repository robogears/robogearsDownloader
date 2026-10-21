## Gap: App lifecycle, single instance, and start-up and shut-down races

This section covers the whole life of the app process: a second copy starting, the moments around launch, closing, quitting, reloading and self-updating, and the cross-cutting topics no other section owns (window state, power, combined concurrency, logging, security boundaries, localisation, Unicode file names, and time). It describes v0.1.30 (`package.json:3`). The code was read, not run. Anything that depends on runtime behaviour is marked **unverified (needs a run)**.

Related sections hold more detail on neighbouring ground: `trace-boot-and-shutdown.md` (the step-by-step launch and quit trace), `trace-failure-paths.md` (Cancel and error paths), `library-matcher.md`, `build-updater.md` and `extension-removal.md`. This section repeats what it needs so that it stands alone.

Terms used below:
- **main**: the Electron main process (Node.js). It owns files, the network and child processes.
- **page**: the renderer, the web page that draws the UI (`renderer/`).
- **push**: a message main sends to the page with `mainWindow.webContents.send(...)`. The page receives it only if it has already registered a listener.
- **child**: a separate operating-system process the app starts (`bulk_runner.js`, `tidal_download.js`, FFmpeg, `hdiutil`, the update script).

---

### 1. Lifecycle hooks: what exists and what does not

| Hook or facility | Present? | Where |
|---|---|---|
| `app.setName('robogears Downloader')` before anything touches paths | Yes | `electron-main.js:13` |
| `app.whenReady()` launch sequence | Yes | `electron-main.js:471-527` |
| `app.on('activate')`: re-create the window when none exist (Dock click on macOS) | Yes, registered inside `whenReady` | `electron-main.js:524-526` |
| `app.on('window-all-closed')`: kill `activeChild`, quit unless macOS | Yes | `electron-main.js:548-551` |
| `app.requestSingleInstanceLock()` / `second-instance` | **No** | none |
| `before-quit` / `will-quit` / `quit` | **No** | none |
| `process.on('uncaughtException' / 'unhandledRejection')` in main | **No** | none |
| `BrowserWindow` `close` / `closed` handlers (`mainWindow` is never set back to `null`) | **No** | `electron-main.js:54, 96` |
| `webContents` `did-finish-load`, `dom-ready`, `render-process-gone`, `unresponsive`, `will-navigate`, `setWindowOpenHandler` | **No** | none |
| `Menu.setApplicationMenu` (so Electron's default menu is used) | **No** (`Menu` is not even imported, `electron-main.js:2`) | none |
| `powerSaveBlocker`, `app.dock` (badge or bounce), `win.setProgressBar`, `Notification`, `crashReporter` | **No** | none |
| Page `beforeunload` / `pagehide` / `visibilitychange` | **No** | none |
| `extensionServer.stopServer()` | Defined, never called | `extension-server.js:204-209` |
| Window bounds or maximised/full-screen persistence | **No** | `electron-main.js:73-99` |

---

### 2. Single instance (not implemented)

#### 2.1 What the code does

Nothing. There is no lock, no `second-instance` handler, no lock file and no check for a running copy. The macOS build config has no `extendInfo` and so no `LSMultipleInstancesProhibited` (`package.json:76-85`). Each running copy runs the full launch sequence (§3.1) against the same data folder.

#### 2.2 How a second copy gets started

- **Windows:** each launch of the shortcut or exe starts a new process. Electron does not de-duplicate by default (unverified for this build).
- **macOS:** a normal Finder or Dock launch of an already running bundle re-activates it (Launch Services), so a second process needs one of these:
  - `open -n`;
  - a second copy of the `.app` at another path, for example an old copy in Downloads alongside `/Applications`. Whether Launch Services allows this is unverified;
  - `npm start` from source while the installed app is running. `app.setName` (`electron-main.js:13`) points dev and packaged builds at the **same** userData folder, but dev reads `<repo>/token.json` while packaged reads `<userData>/token.json` (`electron-main.js:19-21`, `tidal_lib.js:13`).

#### 2.3 What two copies collide on

`<userData>` is `~/Library/Application Support/robogears Downloader/` on macOS and `%APPDATA%\robogears Downloader\` on Windows.

| Shared thing | Path or value | What happens with two copies | Code |
|---|---|---|---|
| Settings | `<userData>/settings.json` | Each page keeps its own `settings` object and saves the **whole** object (`api.saveSettings(settings)`). The last writer wins. Example: copy A picks a new download folder, then copy B nudges the volume slider and writes its stale object, so A's folder choice is gone from disk at the next launch. A's window still shows the new folder until restart. | `electron-main.js:38-52, 556`; `app.js:523, 1522, 1536, 1549` |
| Queue | `<userData>/queue.json` | Each page saves its full in-memory queue 400 ms after any change. The last writer wins, so rows added in one copy disappear at the next launch if the other copy saved later. | `electron-main.js:594-606`; `app.js:73-83` |
| TIDAL token | `token.json` (path above) | Each copy refreshes on its own when the access token has expired and rewrites the file in place (not atomic). The last writer wins. That is harmless as long as TIDAL does not rotate refresh tokens: the refresh code never stores a new `refresh_token` (`tidal_lib.js:86-93`). A reader in another process can catch a half-written file and fail to parse it (unverified). | `tidal_lib.js:62-68, 70-102` |
| Batch hand-off file | `<userData>/pending-tracklist.json` (fixed name) | Each `bulk:start` writes it, then starts `bulk_runner`, which reads it at start-up. If copy B writes between A's write and A's runner reading it, A downloads **B's** list while A's rows wait for events that never come. When A's batch ends, its `close` handler deletes the file (`:1037`). If B's runner has not read it yet, B fails with `Fatal: ENOENT…`, exits 1, and B's page then removes all its `queued` rows (`app.js:1468-1473`). The timing window is a child start-up (unverified size). | `electron-main.js:991-992, 996, 1037`; `bulk_runner.js:53, 115-118` |
| Download folder | user's folder | Both copies can download the same title at once. The skip-if-exists check (`tidal_download.js:359-366`) runs before the download, so both pass it. Both then write the same `<Title>.tmp.<ext>` (`:428`) and run FFmpeg with `-y` on the same final file (`:289`), so a corrupted result is possible. | as listed |
| Extension bridge (being removed) | `127.0.0.1:8273`, `<userData>/extension-token.txt`, `<userData>/chrome-extension/` | The second copy's `listen` fails with `EADDRINUSE` (port fixed at `extension-server.js:17`; `once('error', reject)` at `:196`). Main pushes `⚠ Chrome-extension bridge couldn't start: listen EADDRINUSE… (tracks won't push from Spotify)` (`electron-main.js:517-521`), which is probably lost (§3.2). That copy's Settings → Extension still shows the URL and the shared token (`app.js:1601-1610`) although it does not own the port. **Regenerate** in one copy rewrites the file while the other keeps the old token in memory. Inventory only. | as listed |
| Library scan | read-only | Both copies walk and tag-read the whole library: double disk I/O, no harm. | `electron-main.js:481-485` |
| Self-update | temp files, `/Applications/<App>.app` | Both copies check GitHub. If both apply, on macOS two relaunch scripts each wait only for their **own** parent (`electron-main.js:406-410`) and then back up, move and `rm -rf` the same `TARGET`/`.bak` (`:404, 413-427`). The result is unverified. On Windows, two silent NSIS installers run. | `electron-main.js:314-469` |
| Updater logs | `~/Library/Logs/robogears Downloader/attempts.log` | Append-only. Lines from two copies can interleave. | `electron-main.js:361-371` |

#### 2.4 Porting notes (single instance)

- A Swift app gets one instance per bundle id from Launch Services for normal launches. Still guard against `open -n` and second copies:
  - at launch, look for another process with the same bundle id (`NSRunningApplication.runningApplications(withBundleIdentifier:)`), activate it and exit;
  - and/or take an advisory lock (`flock`) on a lock file in Application Support, refusing to start or opening read-only if it is held.
- Route every write to settings, the queue and the token through one actor, so that even a single copy has one writer per file. Write atomically (`Data.write(to:options:.atomic)`).
- Do not use a fixed-name hand-off file. Pass the batch to the download engine in memory, or give the file a unique name.

---

### 3. Start-up races

#### 3.1 Launch order in main (`electron-main.js:471-527`)

1. `loadSettings()`, then `lib.setLibraryPath(s.libraryFolder)` if it is a string (`:473-474`).
2. `createWindow()` (`:476`): `new BrowserWindow(...)`, then `loadFile(renderer/index.html)` (`:96-97`). Loading is **asynchronous**: the page is not parsed yet when this returns.
3. If a library folder is set, `lib.scanLibrary(sendScanProgress)` (`:481-485`). Its directory walk is **synchronous** (`tidal_lib.js:687-700`, `readdirSync` recursion), and it pushes `library:scan-progress {done:0,total}` in the same step (`tidal_lib.js:703`).
4. `checkForUpdatesAndNotify()` (`:489`): GitHub request, 10 s timeout (`:125`).
5. `verifyFfmpegAvailable()` (`:495`): spawns `<ffmpeg> -version` (`:539`).
6. `ensureExtensionBundle()` (`:500`): packaged builds only. Synchronous file copy, then a push.
7. `extensionServer.startServer(...)` (`:506-522`).
8. Register `activate` (`:524-526`).

The page registers its listeners when `app.js` runs. That script is a plain `<script src="app.js">` at the end of `<body>` (`index.html:233`), so the listeners exist only after the HTML is parsed. Examples: `onUpdateAvailable` at `app.js:435` and `:444`, `onDownloadLine` at `:1456`, `onLibraryScanned` at `:1687`, `onLibraryScanProgress` at `:1694`. Then the boot block (`app.js:1943-1995`) asks main for settings, sign-in state and the queue.

#### 3.2 Pushes sent before the page listens are probably lost

Main has no `did-finish-load` gate, no buffer, and no "tell me the current status" request. `ipcRenderer.on` does not replay messages sent before it was registered. Each push below is therefore probably dropped (unverified, needs a run):

| Push | Exact text or payload | Sent from | When it is sent | Likely fate |
|---|---|---|---|---|
| Extension files refreshed (packaged only, and only when the bundled manifest version is newer, which means the first launch after an app update) | `🧩 Chrome extension files updated to v${bundledVersion} at ${userDir}. Reload in chrome://extensions if it's already loaded.` | `electron-main.js:795-798` | Synchronously inside `whenReady`, right after `createWindow` | Lost |
| FFmpeg missing | `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` | `electron-main.js:540-545` | On the spawn `error` event. For ENOENT/EACCES Node raises it on the next tick | Lost. The user then finds out mid-download as an FFmpeg failure, which is exactly what the comment at `:491-494` meant to prevent |
| Bridge failed to start | `⚠ Chrome-extension bridge couldn't start: ${err.message} (tracks won't push from Spotify)` | `electron-main.js:517-521` | `listen` error, within a tick or two | Lost |
| First scan tick | `library:scan-progress {done:0,total}` | `tidal_lib.js:703` via `electron-main.js:32-36` | Same synchronous step as `loadFile` | Lost (harmless). For an empty or tiny library, the final `library:scanned` can also arrive before the listener, so Settings shows `…` until it is opened, when `refreshLibraryStatus` re-asks (`app.js:1507, 1675-1685`) |
| Update available | `{version, downloadUrl, releaseUrl}` on `update:available` | `electron-main.js:164-172, 489` | After the GitHub round trip | Usually survives because the network is slower than the page load, but nothing guarantees it. The comment at `:487-488` ("Renderer handles the race…") is true only once the listener exists |

The FFmpeg probe also ignores the exit code: only a spawn `error` triggers the warning (`electron-main.js:539-545`).

#### 3.3 The page's own stash covers only the welcome line, and Clear breaks it

`insertUpdateNotice` (`app.js:371-433`) anchors the notice after `welcomeLineEl`. If that line does not exist yet, it stores the payload in `pendingUpdate` (`:372-375`). The boot block applies the stash once, at its end (`:1991-1994`).

**Activity → Clear** runs `activityEl.innerHTML = ''` (`:361`), which detaches `welcomeLineEl`. Any later `update:available` (for example from **Check for updates**) is stashed and never applied, so the activity-log notice silently never appears. The Settings hint says it will: "If one's found, a download notice appears in the activity log." (`index.html:195`). The topbar pill still appears.

#### 3.4 The first add after launch waits for the launch scan

Every resolve path ends in `enrichWithLibraryStatus`, then `findInLibrary`, then `scanLibrary()`. While the launch scan is running, `scanLibrary` returns the in-flight promise (`tidal_lib.js:676, 790`). Affected paths:
- link resolve: `tidal_lib.js:344, 403`;
- search: `:424`;
- CSV/text import: `electron-main.js:977`.

So a link pasted in the first seconds after launch sits behind the scan. The old docs say about 18 s for 500 files. The loading overlay shows its rotating text, and an import shows `Matching N / N tracks on TIDAL…` and then waits.

The directory walk itself is synchronous on main's only thread, so the page's first requests (`getSettings` at `app.js:1944`) also wait for the walk to finish (duration unverified).

#### 3.5 Changing the library folder while the launch scan runs keeps the old folder's index

This is derived from the code, not run:
1. `setLibraryPath(p)` sets the path and `_libraryCache = null`, but **not** `_libraryScanPromise` (`tidal_lib.js:28-31`).
2. `saveSettings` then calls `scanLibrary` (`electron-main.js:45-50`), which sees the old promise still in flight and returns it (`tidal_lib.js:676`).
3. When the old scan finishes, the old caller runs `_libraryCache = await _libraryScanPromise` (`:754`) and the **old folder's** entries become the cache.

This also happens with **Clear** and **Reset config**: the log says `📁 Music library folder cleared (duplicate check disabled).` (`app.js:1551`), yet rows keep matching the old library until **Refresh** or a restart. `rescanLibrary()` during a scan has a similar problem: the older scan's ending overwrites the cache and nulls the newer promise (`tidal_lib.js:754-755, 760-763`).

#### 3.6 A restored queue can quit the app at launch

The boot block queues a waveform pre-load for every restored row (`app.js:1984-1986`), which calls `preview:get-audio`, which calls `lib.loadCred()` (`electron-main.js:875`). With no `token.json`, `loadCred` calls `process.exit(1)` in **main** (`tidal_lib.js:48-52`; also `:55-57` for an empty array). That ends the app with no quit events. The `try/catch` in the handler cannot stop an exit.

Realistic triggers:
- the dev and packaged builds share `queue.json` but not `token.json` (§2.2);
- `token.json` was deleted.

The same exit happens on a CSV drop or a multi-line paste while signed out (`handleTracklistInput` has no sign-in check, `app.js:1830`), and on the ▶ button.

#### 3.7 Volume restore shows the squared value

- `settings.volume` stores the **slider position** (0–1). The slider writes `settings.volume = linear` (`app.js:516-518`).
- The audio gain is `position²` (`sliderToAudioVolume`, `:506-509`). `getPreviewVolume()` returns that **gain** (`:510-513`), defaulting the position to `0.5`.
- At launch the slider is set to `Math.round(getPreviewVolume() * 100)` (`:1948`), which is the gain, not the position. The HTML default `value="50"` (`index.html:68`) is overwritten, and the comment at `:1947` ("defaults to 60% if unset") matches neither.

Worked example:

| Step | Stored `volume` | Slider shows | Gain used for playback |
|---|---|---|---|
| First launch (unset) | — (treated as 0.5) | 25 | 0.25 |
| User nudges the slider to 26 | 0.26 | 26 | 0.0676 |
| Next launch | 0.26 | 7 (`round(6.76)`) | 0.0676 |
| User nudges to 8 | 0.08 | 8 | 0.0064 |
| Next launch | 0.08 | 1 | 0.0064 |

The first touch drops loudness sharply, and each launch-plus-touch cycle drives the level towards zero. Playback stays consistent with the stored value until the slider is touched (`app.js:826`).

#### 3.8 Things done only at launch, never for a re-created window

The update check (`:489`), the FFmpeg probe (`:495`), the extension sync (`:500`) and the scan's `library:scanned` push run once per process.

After a Dock re-open (`activate`, `:524-526`) or a **Reload**, the new page never gets:
- the Update pill or notice, until a manual check;
- the FFmpeg warning;
- the library count, until Settings is opened.

---

### 4. Shut-down, reload and close races

#### 4.1 The process tree

```
main (Electron)
 └─ bulk_runner.js          spawn(process.execPath, …) with stdio pipes, not detached   electron-main.js:996-999
     └─ tidal_download.js   spawn(process.execPath, …) with stdio:'inherit', not detached  bulk_runner.js:41-44
         └─ ffmpeg          spawn(ffmpegPath, args) with stdin/stderr pipes             tidal_download.js:260-273
```

- All three children run the app's own executable or FFmpeg. With `ELECTRON_RUN_AS_NODE=1` (`electron-main.js:64`; `bulk_runner.js:43`), the Node children are processes of the app binary itself.
- `activeChild.kill()` (`electron-main.js:549, 648`) signals **only** `bulk_runner`.
- On macOS and Linux that is SIGTERM to one PID. `tidal_download` and FFmpeg are not signalled and keep running as orphans.
- On Windows, libuv normally places non-detached children in a "kill on close" job object, so killing `bulk_runner` or quitting main may take the grandchildren down too, including FFmpeg mid-write. Unverified (needs a run). `trace-boot-and-shutdown.md` assumes no tree kill on Windows.
- Node emits a child's `close` event only after the child has exited **and** every holder of its stdout/stderr pipes has closed them. Because `tidal_download` inherits `bulk_runner`'s pipes, main's `close` for `bulk_runner` probably waits for the orphan to finish (unverified, needs a run).

#### 4.2 Ways the app ends, and what each one does

| Trigger | Window close events | `window-all-closed` | Children killed? | Pending page timers | Notes |
|---|---|---|---|---|---|
| macOS: red button, ⌘W, File → Close Window | yes | yes (`:548`) | `bulk_runner` only | lost | The app keeps running with no window (§4.3) |
| Windows/Linux: close the window | yes | yes, then `app.quit()` (`:550`) | `bulk_runner` (tree probably on Windows) | lost | — |
| ⌘Q, App menu → Quit, `app.quit()` | yes | **no** (documented Electron behaviour on an explicit quit) | **none** | lost | No `before-quit`/`will-quit` handlers (§4.4) |
| **Update now** / **Restart to apply** | via `app.quit()` 500 ms after spawning the installer or script (`:467`) | **no** | **none** | lost | Neither update button checks `isDownloading` (`app.js:400-421, 452-477`) |
| `loadCred()` without a token | none | none | none | lost | `process.exit(1)` in main (`tidal_lib.js:51, 56`) |
| Uncaught exception in main | — | — | — | — | No handler. Electron's default shows "A JavaScript error occurred in the main process" and keeps running (unverified) |
| Page crash | — | — | — | lost | No `render-process-gone` handler. The window probably goes blank; View → Reload recovers it (unverified) |

#### 4.3 Closing the window on macOS during a batch

1. The page unloads with no flush. The 400 ms queue save and 300 ms volume save timers die (§4.6).
2. `window-all-closed` (`electron-main.js:548-551`) calls `activeChild.kill()` but does **not** set `activeChild = null`. The app does not quit.
3. The orphaned `tidal_download` keeps writing lines into the inherited pipe. Each one reaches `dispatchLine` (`:1004-1019`), which calls `mainWindow.webContents.send(...)` with no `isDestroyed()` check (`:1007, 1011, 1015, 1018`). Electron throws `TypeError: Object has been destroyed` for a destroyed window. This happens inside a stream `data` handler, so it is an uncaught exception, possibly one error dialog per line. Unverified (needs a run).
4. When the child's `close` fires, `:1035` throws in the same way **before** `activeChild = null` (`:1036`) and before `pending-tracklist.json` is deleted (`:1037`).
5. If the user re-opens the window from the Dock **after** that, the new page starts with `isDownloading = false` (`app.js:63`).
   - **Download all** calls `bulk:start`, which returns `{ok:false, error:'Another download is already running.'}` (`electron-main.js:987`).
   - The page ignores the result (`app.js:1453`; also `:1112`, `:1416`), and the button stays `Downloading…` (`app.js:1361-1372`).
   - **Cancel** clears main's flag (`electron-main.js:646-653`) but never resets the page, because only `download:done` calls `setDownloading(false)` (`app.js:1457-1458`). The page stays stuck until a Reload or a restart.
6. If the window is re-opened **before** the child ends, its events reach the new page, because each send looks up `mainWindow` afresh, and the batch finishes normally.

Other sends that skip `isDestroyed()`: `electron-main.js:49, 483` (inside a promise chain whose `.catch(() => {})` swallows the throw), `:585` (inside a request handler), and `:746, 748` (extension; checked only on entry at `:697`).

#### 4.4 ⌘Q, App → Quit and **Update now** during a batch

1. Electron closes the window. `window-all-closed` is **not** emitted, so nothing is killed. No handler flushes, warns or stops the extension server.
2. Main exits. On macOS and Linux, `bulk_runner` and `tidal_download` are orphaned with a broken stdout pipe. Node ignores SIGPIPE, so the next `console.log` fails with EPIPE, and with no `error` listener on stdout the process should crash. Unverified (needs a run).
   - `tidal_download` writes `__TRACK_PROGRESS__:<id>:<pct>` on every whole-percent change (`tidal_download.js:433-442`), so it dies early in the network phase and leaves `<Title>.tmp.flac` or `<Title>.tmp.m4a` in the **download folder** (`:427-428`).
   - During the FFmpeg remux it writes nothing, so a remux already running usually completes.
   - `bulk_runner` dies at its next `__TRACK_DONE__` line. The remaining tracks are not downloaded and `pending-tracklist.json` stays behind.
3. On Windows the job object probably kills the whole tree at once, FFmpeg included (unverified). FFmpeg writes the **final** file in place (`-y … dstFlac`, `tidal_download.js:289, 307`), and skip-if-exists trusts any existing final file (`:359-366`). A remux killed mid-write therefore leaves a truncated `<Title>.flac` that every later run skips as `already in downloads folder`.
4. **Update now** during a batch is the same path, and the new version then starts with the batch cut short. On macOS the relaunch script waits only for main's PID (`electron-main.js:406-410`). It then moves the running bundle to `.bak` and deletes it (`:413-427`) while orphaned children may still be running from that bundle's binary. The effect is unverified.

#### 4.5 Reload (⌘R / View → Reload) and Dock re-open

Electron's default menu is active (§6), so ⌘R and ⌘⇧R reload the page in place.

1. Main state carries on: `activeChild`, `resolverCancelled`, `global._pendingUpdatePath`, the library cache, in-flight fetches and the extension server.
2. The new page reruns the boot block. Settings and the queue come from disk, where the queue is the pre-batch snapshot if a batch is running (batch progress never saves). Pre-loads re-download every row's audio (`app.js:1984-1986`).
3. `isDownloading` starts `false`. If the user presses **Download all** during the old batch, the refusal is ignored and the clicked rows become `queued` (`app.js:1447-1451`).
4. The old batch's `download:done` then arrives. The prune (`app.js:1468-1473`) keeps only `notFound`, `failed` and untouched-included rows, so the rows the user just queued are **removed** and that removal is saved (`:1481`).

#### 4.6 Debounced saves are lost at close, quit and reload

| What | Delay | Code | Lost when |
|---|---|---|---|
| Queue save after any change, including the post-batch prune | 400 ms trailing | `app.js:73-83`, `:1481` | Window closed, app quit, page reloaded or update applied within 400 ms of the last change |
| Volume save | 300 ms trailing | `app.js:515-524` | Same, within 300 ms |

There is no `beforeunload`/`pagehide` flush, and main writes only on request. Both files are written in place (`electron-main.js:44, 601`), so a crash mid-write can leave a damaged file. That file then reads back as `{}` or `[]` with no message (`:39-40, 594-597`), and the next save overwrites it.

#### 4.7 Files left behind by interrupted work

| File | Where | Left when | Cleaned by |
|---|---|---|---|
| `<Title>.tmp.flac` / `<Title>.tmp.m4a` | Download folder | Any interruption or failure before the remux; also kept on purpose when FFmpeg fails (`tidal_download.js:456-459`) | Nothing (the success path deletes it at `:461`) |
| Truncated `<Title>.flac` / `.m4a` | Download folder | Remux killed mid-write | Nothing, and it is then skipped forever |
| `pending-tracklist.json` | `<userData>` | Close or quit mid-batch, or §4.3 step 4 | Overwritten by the next batch |
| `robogears-downloader-<ms>.exe` (about 90 MB) | `%TEMP%` | **Every** Windows update: the installer is run but never deleted (`electron-main.js:305, 331-336`) | Nothing |
| `robogears-update-<ts>/<App>.app` | `$TMPDIR` | macOS update downloaded but never applied, or superseded by a second download (§5) | Nothing (macOS may purge old temp files; unverified) |
| `robogears-update-<ts>.sh` | `$TMPDIR` | Script never started | The script deletes itself (`rm -f "$0"`, `:418, 439`) |
| `update-<epoch-ms>.log`, `attempts.log` | `~/Library/Logs/robogears Downloader/` | Every macOS apply | Never rotated or pruned |

---

### 5. Update UI race (two front ends, one back end)

There are two independent state machines. The activity-log notice is `idle → downloading → ready → restarting` (`app.js:398-422`). The topbar pill is `idle | available | downloading | restarting` (`:441-477`). Both call the same `update:download` and `update:apply`.

1. Both subscribe to `update:available`. The notice handler returns early if a notice already exists (`:377`), but the **pill handler always resets** (`:444-450`): `_pillUpdateState = 'available'`, `disabled = false`, text `Update now`.
2. A manual **Check for updates** (`app.js:1649-1673`) makes main push `update:available` again (`electron-main.js:178-182`). If the pill is mid-download at that moment, it flips back to an enabled **Update now** while its first download continues. Its progress handler (`app.js:481-489`) then ignores progress, because it shows progress only in the `downloading` state.
3. A second pill click, or a click on the notice's **Download update**, starts **another** download. Each download writes to its own temp path (`robogears-downloader-${Date.now()}.dmg|.exe`, `electron-main.js:292`), and on macOS each extracts to its own `robogears-update-<ts>` folder (`:245`).
4. `update:download-progress {downloaded,total}` carries **no download id** (`:296`). Every listener in the `downloading` state shows whichever download reported last, so the percentage can jump between two downloads.
5. Whichever download finishes last sets `global._pendingUpdatePath` (`:302, 305`). An apply uses whatever is set at that moment. The pill applies as soon as **its** download resolves (`app.js:474-476`), and the app quits 500 ms later, possibly while the other download is still writing. The other temp file or staged `.app` is never deleted.
6. Main accepts any `http://` or `https://` URL from the page (`electron-main.js:290`). It does not check that the URL is the asset it found itself.
7. Neither front end checks `isDownloading` (§4.4).

**Porting:** keep one updater object in the app model with a single state (`idle`, `available(version, asset)`, `downloading(progress)`, `ready(stagedBundle)`, `installing`). Every UI reflects that one state. A repeat check while busy must not reset it. Download only the asset URL the updater itself discovered. Delete staged files after install or on failure, and offer to wait for, or cancel, a running batch before restarting.

---

### 6. Window state and sizing

| Property | Value | Code |
|---|---|---|
| Initial size | 980 × 740 | `electron-main.js:75-76` |
| Minimum size | 720 × 540 | `:77-78` |
| Position | Not set (Electron centres it) | `:73-88` |
| Background before paint | `#0a0a0a` (the page body is `#000000`, `styles.css:3, 30`, so the colours differ slightly) | `:79` |
| Title | `robogears Downloader` (also `<title>`, `index.html:6`) | `:80` |
| Frame | Standard frame: no `frame:false`, no `titleBarStyle` | `:73-88` |
| Shown | Immediately: no `show:false` / `ready-to-show`, so the window appears before content paints | `:96` |
| Menu bar | `autoHideMenuBar: true`, which affects only Windows and Linux (hidden until Alt is pressed; accelerators still work) | `:87` |
| Dev-mode icon | `build/icon.png` (unpackaged only) | `:93-95` |
| Saved frame, maximised or full-screen state | **None.** Every launch starts at 980 × 740, centred, windowed | — |

- **Default menu:** with no `Menu.setApplicationMenu`, Electron installs its default menu. On macOS that is the app menu (About, Hide, Quit), Edit, View (Reload ⌘R, Force Reload ⌘⇧R, Toggle Developer Tools ⌥⌘I, Actual Size ⌘0, Zoom In ⌘+/⌘=, Zoom Out ⌘−, Toggle Full Screen), Window and Help. That is Electron's documented default, but not seen in this build (unverified). Page zoom therefore works, and probably resets each launch (unverified). Reload and DevTools are live in production (§4.5, §10).
- **Drag regions:** the topbar is marked `-webkit-app-region: drag` (`styles.css:49`), with `no-drag` carve-outs for buttons (`:51`), the logo, name and version (`:63`) and the update pill (`:88`). The comment at `app.js:492-494` assumes the bar is a drag handle. Electron honours app-region only on frameless or hidden-title-bar windows, so on this framed window the rules are probably inert (unverified, needs a run).
- **No guard against navigation:** `dragover`/`drop` are cancelled only on `#drop-zone` (`app.js:1765-1782`). Dropping a file or link anywhere else probably makes Chromium navigate the window to it, replacing the app UI until Reload, because there is no `will-navigate` handler. Unverified (needs a run). See §10 for the security side.

**Porting:**
- Use one main window (SwiftUI `Window` scene, or `NSWindow` with `setFrameAutosaveName`) so the frame and full-screen state are restored automatically. Default 980 × 740, minimum 720 × 540. Standard title bar and toolbar, so no drag-region workarounds.
- No web zoom: offer the system text-size behaviours only if wanted.
- File drops are accepted only by the import area (`.onDrop` / `dropDestination`) and are otherwise ignored.

---

### 7. Power management and system integration

Not implemented. In the code:
- No `powerSaveBlocker` during a batch. Idle system sleep can suspend the network mid-batch. Segment fetches then time out after 60 s (`tidal_download.js:252`; `tidal_lib.js:222-224`) and retry up to 3 times (`tidal_lib.js:16, 174-193`) before the track fails. Whether idle sleep or App Nap actually stalls a batch is unverified (needs a run).
- No Dock or taskbar progress (`setProgressBar`), no Dock badge, no bounce.
- No system notification when a batch ends. The only signals are page sounds and a log row (`playSuccessPing`, `app.js:243-270, 1460`; `appendBatchDoneNotice`, `:1486-1501`). With the window closed on macOS there is no feedback at all, because the page that plays the sounds is gone.

**Porting:**
- During a batch, hold `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading tracks")` and end it when the batch ends. That also keeps App Nap away.
- Show batch progress on the Dock tile (`NSApp.dockTile`, a progress bar or a count badge). Optionally post a `UNUserNotificationCenter` notification when a batch ends while the app is not frontmost. Asking permission and choosing the wording is the owner's call (Open questions).

---

### 8. Concurrency limits across components

Each component has its own limit; nothing caps them together. All of them use **one** TIDAL token and one network connection, with no shared rate limiter.

| Component | Limit | Requests per unit | Code |
|---|---|---|---|
| Waveform pre-loader (page) | 2 tracks at a time | Each: `loadCred`, maybe a token refresh, `playbackinfopostpaywall` (LOSSLESS), then 1 direct fetch, or 1 init fetch plus **8** parallel segment workers. The whole track comes back over IPC | `app.js:555-559, 739-749`; `electron-main.js:857-871, 873-917` |
| Play button | **Uncapped**, on top of the pre-loader | Same as above. `getPlayableEntry` does not check for an in-flight pre-load of the same track, so pressing ▶ on a row still loading fetches the whole track twice | `app.js:705-727` |
| Batch (`bulk_runner` → `tidal_download`) | 1 track at a time | track info, album info, 1+ playback-info calls, then **8** segment workers (`CONCURRENCY_DEFAULT`) plus the cover in parallel | `bulk_runner.js:64-112`; `tidal_download.js:38, 173-207, 445-448` |
| Spotify link resolve | **8** workers | 1 TIDAL search each (ISRC is never present in embed data) | `tidal_lib.js:365-399, 558-611` |
| TIDAL album or playlist resolve | sequential pages of 100 | 1 call per page | `tidal_lib.js:248-284` |
| CSV/text import | sequential | 1 search per line | `electron-main.js:938-976` |
| Extension push (being removed) | sequential | 1 search per track | `electron-main.js:707-744` |
| Library tag reads | 8 | disk, not network | `tidal_lib.js:711-750` |

Rate-limit and failure behaviour:
- **TIDAL API calls are never retried.** `tidalGet`, then `httpsRequest` (`tidal_lib.js:129-168`), has no retry, so a 429 or 5xx becomes an error at once. In a Spotify resolve or an import, that error is caught per track and the row becomes **`notFound`** (`tidal_lib.js:387-396`; `electron-main.js:972-974`). A burst of rate limiting therefore shows as "not on TIDAL" with no hint of the real cause.
- **Only CDN downloads retry** (`fetchBuffer`): 429 or 5xx, network errors and timeouts get backoff `min(1000·2^attempt, 8000)` ms (`tidal_lib.js:186`), up to 3 retries (preview uses 2). `Retry-After` is ignored.
- **Token refresh is not coordinated.** Every request reloads `token.json` and refreshes on its own if the token has expired (`tidal_lib.js:97-102`). Two launch pre-loads plus a batch child can each refresh at the same moment and each rewrite the file.
- **The loading overlay is shared with no counter.** `showLoading` and `hideLoading` (`app.js:289-315`) are one global. A multi-line paste outside a text field during a URL resolve (possible when focus is on a button) starts an import whose overlay the first operation then hides early. Code-derived; reaching it needs unusual focus.
- `resolverCancelled` is a single global flag (`electron-main.js:58, 659, 689`). Only the URL/search resolve can be cancelled; the import has no Cancel.

**Porting:**
- One `TidalClient` actor with:
  - a single-flight token refresh (concurrent callers await the same refresh);
  - a bounded limiter for API calls and another for CDN fetches;
  - 429 handling that honours `Retry-After` and backs off;
  - errors kept distinct from "not found".
- Preview loads run at low priority (`Task(priority: .utility)`), can be cancelled when a row is removed, and should probably pause during a batch (owner decision). De-duplicate in-flight loads per track id.
- Overlays are driven by a count of operations in flight, or by per-operation state in the model.

---

### 9. Logging and diagnostics

| Topic | What the code does | Code |
|---|---|---|
| Activity log | The only diagnostic surface. DOM lines classified by regex (`ok`, `error`, `warning`, `skip`, `header`, `summary`, `muted`), capped at **2000** lines (the welcome line is protected), wiped by **Clear**, lost on reload, close and quit | `app.js:54, 330-361` |
| Copying from the log | Not possible: `html, body { user-select: none; }` and only `input, textarea` re-enable it. There is no Copy, Save or Reveal-logs action | `styles.css:36, 40` |
| Empty-log text | `Nothing yet. Paste a link above to get started.` (English text in CSS) | `styles.css:343-347` |
| Child output | `bulk_runner` and `tidal_download` stdout **and** stderr go to the log alike, with no stream marker; lines matching `__TRACK_*__` are turned into events instead | `electron-main.js:1004-1031` |
| Main-process console | `console.log/warn/error` in main reach only main's stdout, which a packaged app opened from Finder or Start shows nowhere (unverified where macOS sends it). Examples: `[extension-server] listening on http://127.0.0.1:8273` (`extension-server.js:198`), `[extension-server] could not persist token: …` (`:57`), `[ext-bundle] sync failed: …` (`electron-main.js:800`), and `token.json not found. Run tidal_auth_node.js first.` just before `process.exit(1)` (`tidal_lib.js:50`) | as listed |
| Persistent logs | macOS self-update only: `~/Library/Logs/robogears Downloader/attempts.log` (appended before the spawn; ISO UTC timestamps) and `update-<epoch-ms>.log` (a bash `set -x` trace with local `$(date)` stamps). Never rotated. Nothing on Windows | `electron-main.js:354-371, 385-398` |
| Debug output | `tidal_download.js` supports `--debug` and `DEBUG` (`:49, 59, 331, 338, 406-411, 452, 722`). `bulk_runner` never passes `--debug`, and the GUI has no toggle. Because `childEnv()` copies `process.env` (`electron-main.js:63`), starting the app from a terminal with `DEBUG=1` would pass it to the children, whose `[debug]` lines the log shows dimmed (`app.js:338`) | as listed |
| Silent failures | `shell.openPath` returns an error string that the page ignores (`electron-main.js:575`; `app.js:1496, 1528, 1543, 1635`). `settings:save` throws on a write error (`electron-main.js:44` has no try), and the page's `await api.saveSettings(...)` has no catch (`app.js:1522, 1536, 1549`; the volume save at `:523` is not even awaited), so the UI shows the new folder while disk keeps the old one. `queue:save` returns `{ok:false}`, which is ignored (`app.js:81`). Pre-load failures (`:763-766`), the launch update check (`electron-main.js:489`), scan errors (`:484`; `tidal_lib.js:689-690, 727`) and the extension copy (`electron-main.js:799-801`) are all swallowed | as listed |
| Start-up messages | Probably lost (§3.2) | — |
| Crash reporting | None (no `crashReporter`, no exception handlers) | — |

**Porting:**
- Use `Logger(subsystem: "com.robogears.downloader", category: …)` (OSLog) for diagnostics, so Console.app can show them.
- Make the in-app activity log selectable (`.textSelection(.enabled)`), and add **Copy Log** and **Save Log…** commands (menu items too).
- Keep `~/Library/Logs/robogears Downloader/` for updater traces and prune old files.
- Show every failure that changes what the user expects (save failed, folder could not be opened) in their words, with a fix.
- Keep start-up health (FFmpeg present, library status, update available) as **state** in the app model, never as one-shot messages.

---

### 10. Security model: trust boundaries

Window preferences (`electron-main.js:81-86`): `contextIsolation: true`, `nodeIntegration: false`, **`sandbox: false`**. The preload uses only `contextBridge` and `ipcRenderer` (`electron-preload.js:2`), which also work with the sandbox on, so turning it off buys nothing.

The CSP (`index.html:5`) is: `default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;`. Because `script-src` allows `'unsafe-inline'`, inline event-handler attributes injected through `innerHTML` would run.

| Boundary | Data that crosses it | Checks today | Risk shown by the code |
|---|---|---|---|
| GitHub API → page | `tag_name` | none | Inserted with `innerHTML` (`app.js:382`). Safe only because the repo owner controls the tag |
| Page → `update:download` / `update:apply` | any URL string | `/^https?:\/\//` only (`electron-main.js:290`), so plain `http` is accepted | Main downloads it and runs it. On Windows it executes the `.exe` (`:331-336`). On macOS it mounts the DMG, takes the first `*.app`, strips quarantine (`xattr -dr com.apple.quarantine`), re-signs it ad hoc and opens it (`:411, 425, 429`). No hash, signature, host or bundle-id check. Combined with the next two rows, anything that can run script in the page can install and run arbitrary code |
| Page → `open-folder` | any path | none (`electron-main.js:575`) | `shell.openPath` opens any file with its default handler, and for an `.app` or `.command` file that means running it |
| Navigation | dropped files and links | no `will-navigate` / `setWindowOpenHandler` | A link dragged onto the window outside the drop zone probably loads that web page **inside the app window**. The preload runs for every page in that window, so the remote page would get the full `window.api`. Unverified (needs a run) |
| Default menu | — | — | **Toggle Developer Tools** (⌥⌘I) and Reload are available in production (unverified for this build). That is local-only, but it opens the same `api` |
| Update script | paths interpolated into bash | none | `LOG`, `NEW_APP`, `TARGET` and `RUNNING_FROM` are pasted inside double quotes (`electron-main.js:387, 400-403`). A `$`, a backtick or a `"` in any of them would be expanded or executed by bash. `NEW_APP` contains the `.app` name read from the **downloaded** DMG (`:265, 275-276`) |
| Secrets at rest | `token.json` (access token, refresh token, user id, country, `client_ID`, `client_secret`) | plain JSON written with Node's default file mode (`tidal_auth_node.js:58`; `tidal_lib.js:67`) | Readable by anything running as the user. The TIDAL client credentials are also embedded in source as four base64 string literals (`tidal_auth_node.js:17-20`: `AUTH_CLIENT_ID`, `AUTH_CLIENT_SECRET`, `REQUEST_CLIENT_ID`, `REQUEST_CLIENT_SECRET`); their values are not reproduced here |
| Extension bridge (being removed) | HTTP on `127.0.0.1:8273` | bearer token for `POST /queue/add`; CORS reflects **any** `Origin` (`extension-server.js:72-77`) | Any web page can read the unauthenticated `GET /ping`, which reveals the app version and the managed folder path, including the macOS user name (`:126-141`). It disappears with the port |
| Code signing | — | ad-hoc `codesign --force --deep --sign -` (`build/after-pack.js:20`); `mac.identity: null` (`package.json:84`) | No hardened runtime, no entitlements, no App Sandbox |

**Porting (security):**
- A SwiftUI app has no web view, no `innerHTML` and no navigation, so the page-injection rows go away. Keep that true: render text, never HTML.
- Run tools with `Process` and an `arguments` array, never through a shell string. If a relaunch helper script is kept, pass paths as positional arguments (`"$1"`), never by text substitution.
- Store tokens in the Keychain (`kSecClassGenericPassword`, service `com.robogears.downloader`), not in a JSON file. Decide deliberately where the TIDAL client credentials live.
- Updater: download only the asset the updater found. Check a published SHA-256 (or an EdDSA signature, as Sparkle does). Check the staged bundle's `CFBundleIdentifier` before swapping. Do not strip quarantine from unverified content.
- **App Sandbox** is an owner decision (Open questions). With the sandbox on:
  - Reading and writing user-chosen folders needs `com.apple.security.files.user-selected.read-write` plus **security-scoped bookmarks** (`com.apple.security.files.bookmarks.app-scope`), saved instead of plain path strings, for both the download folder and the library folder.
  - The network needs `com.apple.security.network.client`.
  - A bundled FFmpeg must be signed as a helper with `com.apple.security.inherit`.
  - The current self-updater (`hdiutil`, writing to `/Applications`, `codesign`) will not work. Sparkle 2 with its installer XPC service is the usual route.
  - Without the sandbox, still enable the hardened runtime when signing.

---

### 11. Localisation

Not supported. In the code:
- All UI strings are hard-coded English in `index.html` (`lang="en"`, `:2`), `app.js`, main (`electron-main.js:700, 987-988`), CSS (`styles.css:344`) and the child scripts. Two native `confirm()` prompts are in English (`app.js:1570, 1626`).
- Plurals are made by hand: `` `track${n === 1 ? '' : 's'}` `` (for example `app.js:1309, 1332, 1355, 1415, 1680, 1688, 1837, 1981`; `electron-main.js:700`). That works only for English.
- Numbers are formatted with `toFixed(1)` and a `.` decimal point, regardless of locale (`app.js:430, 487`; `tidal_download.js:467`). There are no locale APIs anywhere (no `Intl` or `toLocale*`).
- CSV header detection is English-only. Title column: `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/`. Artist column: `/artist/` (`app.js:1903-1904`). A CSV with headers in another language falls back to plain-text parsing (`:1862-1868`).
- HTTP: the sign-in requests send a fixed `Accept-Language: en-US,en;q=0.9` (`tidal_auth_node.js:80`). Calls to `api.tidal.com` (`tidal_lib.js:131-136, 163-166`) and the Spotify embed request (`:480`) send no `Accept-Language`. TIDAL's `countryCode` (from the token, or the user profile, else `'US'`, `tidal_lib.js:104-118`) controls catalogue availability, not language.

**Porting:** even if the app stays English-only, put strings in a String Catalog (`Localizable.xcstrings`) from the start, so plurals and grammar come out right (`^[\(n) track](inflect: true)` or catalog plural variants). Format sizes with `.formatted(.byteCount(style: .file))` and durations with `Duration` formatting.

---

### 12. Unicode text and file names

**Output file names.** `sanitize` (`tidal_lib.js:616-618`) replaces `\ / : * ? " < > |` with `_`, collapses any whitespace run (including tabs and newlines) into one space, then trims. The file is then `<Title>.flac`, `<Title>.m4a` or `<Title>.tmp.<ext>` (`tidal_download.js:352, 355-356, 426-428`). Gaps that follow from the code:
- **A leading dot makes a hidden file** on macOS and Linux. For example `...Ready For It?` becomes `...Ready For It_.flac`, which Finder hides by default.
- **A whitespace-only title becomes `.flac`.** The `'unknown'` fallback is checked **before** trimming (`str || 'unknown'`), so `'   '` turns into an empty name plus the extension. An empty title does give `unknown.flac`.
- **No length cap.** APFS allows 255 bytes per name in UTF-8, so a 90-character CJK title (3 bytes per character) plus `.tmp.flac` is too long and fails with ENAMETOOLONG. Windows also has `MAX_PATH` for tools that do not use long paths (FFmpeg behaviour unverified).
- **Windows reserved names** (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`, even with an extension), trailing dots, and C0 control characters other than whitespace are not handled.
- **No Unicode normalisation** (NFC or NFD) is applied to names.
- **Collisions.** Names are title-only by the owner's rule 3. Two different songs with the same title (for example two `Intro`s), or titles that differ only by case on a case-insensitive volume (the APFS default), map to one file, and the second is reported `⏭ … already in downloads folder — skipping` (`tidal_download.js:359-366`).

**Matching text.** Every matcher normalises with `.toLowerCase()` then `replace(/[^a-z0-9 ]/g, ' ')` (`tidal_lib.js:580, 628, 651`; `electron-main.js:712, 944`; `bulk_runner.js:11`). Consequences:
- **Accented letters vanish**, and the result depends on the Unicode form. NFC `é` (one code point) is dropped, so `Beyoncé` becomes `beyonc`. NFD `e` + combining accent keeps the `e`, so it becomes `beyonce`. Older HFS+ volumes store file names in NFD, while TIDAL text and most tags are NFC, so **filename-based** library matches for accented titles can fail. Code-derived; the data mix is unverified.
- **Non-Latin titles normalise to `''`.**
  - `findInLibrary` returns `null` when the core title is shorter than 3 characters (`tidal_lib.js:795`), so Japanese, Cyrillic, Greek and similar titles are **never** flagged as already in the library.
  - In the TIDAL matchers, `'' === ''` scores a perfect title match (`tidal_lib.js:588`; `electron-main.js:719, 951`). Every non-Latin result is therefore accepted, and the first one in TIDAL's order (plus a duration bonus in the Spotify path, `tidal_lib.js:596-597`) wins, which risks a wrong match.

**Library walk** (`tidal_lib.js:687-700`):
- `Dirent.isDirectory()` and `isFile()` are both false for symbolic links, so **symlinked folders and files are silently skipped**.
- Hidden files are not filtered, so AppleDouble `._Song.flac` files (common on exFAT, FAT and SMB volumes) are counted. Their tag read fails, and the filename fallback normalises `._Song` to `song`, a duplicate entry. The indexed count shown in Settings is then inflated.
- Unreadable folders are skipped silently (`:689-690`).
- The extension list is `.flac .m4a .mp3 .wav .aac .ogg .opus .alac` (`:25`). `.alac` is not a real file extension (ALAC lives in `.m4a`), and `.aiff`/`.aif` are absent.
- **Cloud placeholders:** the walk calls `mm.parseFile` on every audio file (`:723`). For Dropbox or iCloud "online-only" files, that read probably makes the provider download the file, so scanning a cloud-backed library could download it all. The old docs name `Z:\Dropbox\Music` as the library. Unverified (needs a run).

**Porting:**
- Write one `FileNameRule` function with tests:
  - NFC-normalise (`precomposedStringWithCanonicalMapping`);
  - replace `/` and `:` (plus the Windows set if files travel to Windows or FAT/exFAT drives, which is the owner's call);
  - strip control characters;
  - replace a leading `.`;
  - collapse whitespace and trim;
  - use `unknown` when empty;
  - cut to fit 255 UTF-8 bytes including the longest suffix (`.tmp.flac`).
- Decide existence the way the volume compares names (`URLResourceKey.volumeSupportsCaseSensitiveNamesKey`).
- For matching, consider `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)` and keep letters from every script. This changes which tracks count as duplicates, so it needs the owner's yes.
- Walk the library with `FileManager.enumerator(at:includingPropertiesForKeys:options:)`. Skip `._*`, decide explicitly about symlinks and aliases, and avoid reading cloud-only files (check the ubiquitous-item resource keys; behaviour with the Dropbox File Provider needs a run).

---

### 13. Time and date handling

| Topic | Behaviour | Code |
|---|---|---|
| Track length display | `fmtDuration(sec)` gives `m:ss` with **no hour field** (3725 s shows as `62:05`). `0` or missing gives `''`; the search modal still prints the separator (`Artist · Album · `) | `app.js:88-91, 968, 1341` |
| Spotify lengths | `Math.round(duration_ms / 1000)` | `tidal_lib.js:380, 391` |
| Token expiry | Stored as an absolute local epoch in ms: `expires_at = Date.now() + (expires_in || 3600)·1000 − 60 000` | `tidal_lib.js:88`; `tidal_auth_node.js:153` |
| Expiry check | `Date.now() < expires_at` against the **local wall clock**. A clock set back makes an expired token look valid. There is **no refresh-and-retry after a 401**: `getPlaybackInfo` throws `Unauthorized — token may be invalid` (`tidal_lib.js:293`), and other calls throw `… failed: 401 …` until the local expiry passes. A clock set forward just refreshes early | `tidal_lib.js:97-102` |
| Release date tag | `date = releaseDate.slice(0, 4)`, **year only**. Source order: album `releaseDate`, track `album.releaseDate`, `streamStartDate` | `tidal_download.js:276, 284` |
| Updater log times | `attempts.log` uses `new Date().toISOString()` (UTC). The script log uses bash `$(date)` (local time). File names use `Date.now()` epoch ms. Three styles in one folder | `electron-main.js:356-358, 364, 397, 438` |
| Temp-file names | `Date.now()` in ms (`robogears-downloader-<ms>`, `robogears-mount-<ts>`, `robogears-update-<ts>`) | `electron-main.js:243-245, 292, 356-357` |
| History timestamps | None. Queue rows carry no "added" or "downloaded" time | — |

**Porting:**
- Format lengths with `Duration.seconds(n).formatted(.time(pattern: n >= 3600 ? .hourMinuteSecond : .minuteSecond))`.
- Treat a 401 as "refresh once, then retry once" inside the token actor, whatever the local clock says.
- Keep the year-only date tag unless the owner wants full dates (that changes file metadata, so it needs a yes).
- Write logs with ISO 8601 timestamps carrying a time-zone offset, consistently.

---

### 14. Timers, timeouts and limits (reference)

| What | Value | Code |
|---|---|---|
| Queue save debounce | 400 ms | `app.js:82` |
| Volume save debounce | 300 ms | `app.js:523` |
| Loading-text rotation | 2500 ms | `app.js:302` |
| Check-for-updates label reverts | 2500 ms | `app.js:1669-1672` |
| `Copied ✓` label (Extension tab / sign-in URL) | 1200 ms / 1500 ms | `app.js:1620, 1752` |
| Sign-in modal closes after success | 1200 ms | `app.js:1725` |
| Waveform redraw after resize | 120 ms debounce | `app.js:1221` |
| Pre-load concurrency / audio cache entries | 2 / 3 | `app.js:549, 558` |
| Activity-log cap | 2000 lines | `app.js:54` |
| Quit after an update apply | 500 ms | `electron-main.js:467` |
| GitHub latest-release timeout | 10 000 ms | `electron-main.js:125` |
| Update download: socket timeout / redirects | 60 000 ms / 5 | `electron-main.js:209, 230` |
| Relaunch script waits for the parent | up to 30 × 1 s | `electron-main.js:407-410` |
| TIDAL API timeout | 30 000 ms | `tidal_lib.js:15` |
| CDN fetch retries / backoff | 3 (preview 2) / `min(1000·2^n, 8000)` ms | `tidal_lib.js:16, 186`; `electron-main.js:858, 866, 891, 903` |
| Preview fetch timeout | 60 000 ms | `electron-main.js:858, 866, 891, 903` |
| Direct (BTS) download socket timeout | 60 000 ms | `tidal_download.js:252` |
| Segment workers (batch / preview) | 8 / 8 | `tidal_download.js:38`; `electron-main.js:869` |
| Spotify resolve workers | 8 | `tidal_lib.js:399` |
| Library tag-read workers / progress tick | 8 / every 25 files | `tidal_lib.js:744, 750` |
| Token safety margin / default lifetime | 60 000 ms / 3600 s | `tidal_lib.js:88` |
| Sign-in poll interval | TIDAL's `interval`, default 5 s; no overall timeout | `tidal_auth_node.js:99, 133-134` |
| Update-pill pulse | 2.4 s, infinite (no reduced-motion check) | `styles.css:103, 114-117` |

---

### 15. Bugs and oddities

Only items the code shows. Severity follows the owner's scale: silently losing data the user expects kept is at least Medium.

1. **Medium: no single-instance guard.** Two copies overwrite each other's `queue.json` and `settings.json` (whole-file, last writer wins), share the fixed `pending-tracklist.json` (one copy can run the other's list or delete it before it is read), and can write the same output files at the same time. §2.3; `electron-main.js:38-52, 594-606, 991-992, 1037`.
2. **Medium: closing the window on macOS during a batch.** Sends to a destroyed window throw from event handlers. `activeChild` can stay set, so **Download all** is then refused silently and the page sticks at `Downloading…`. The tail of the batch is dropped. Runtime effects unverified (needs a run). §4.3; `electron-main.js:548-551, 1004-1039, 987`; `app.js:1453`.
3. **Medium: quitting or updating never stops downloads.**
   - ⌘Q, Quit and **Update now** skip `window-all-closed`, so no child is killed and nothing warns.
   - Orphans leave `<Title>.tmp.*` in the download folder.
   - An interrupted remux leaves a truncated final file that later runs skip forever.
   - §4.4, §4.7; `electron-main.js:467, 548-551`; `tidal_download.js:289, 359-366, 427-428`.
4. **Medium: a library folder changed during an in-flight scan keeps the old folder's index**, including after **Clear** and **Reset config**. §3.5; `tidal_lib.js:28-31, 674-676, 754-755`.
5. **Medium: `loadCred()` exits the whole app** when `token.json` is missing or empty, for example at launch with a restored queue, or on a CSV drop while signed out. §3.6; `tidal_lib.js:48-60`; `app.js:1830, 1984-1986`; `electron-main.js:875, 925`.
6. **Low: the volume is restored as its square.** The first touch drops the level sharply, and repeated launches and touches drive it towards zero. §3.7; `app.js:506-524, 1948`.
7. **Low: launch warnings are probably lost**, including `⚠ FFmpeg not found…`. §3.2; `electron-main.js:476-522, 539-545, 795-798`.
8. **Low: update UI race.**
   - A manual check resets the pill mid-download, and two downloads can run at once.
   - Progress events from both downloads mix.
   - The last download to finish wins `_pendingUpdatePath`, and the others' temp files leak.
   - The Windows installer exe is never deleted after any update.
   - §5, §4.7; `app.js:444-450`; `electron-main.js:292-307`.
9. **Low: Clear stops later update notices from appearing** in the activity log. §3.3; `app.js:361, 371-375, 1991-1994`.
10. **Low: the last debounced queue or volume save is lost** on close, quit, update or reload within 300–400 ms. In-place writes can also corrupt a file, which then reads back empty with no message. §4.6.
11. **Low: Reload or a Dock re-open during a batch, then Download all, removes the newly queued rows** when the old batch ends. §4.5; `app.js:1447-1451, 1468-1473, 1481`.
12. **Low: TIDAL API 429s are not retried**, and rate-limited tracks in a Spotify resolve or an import are shown as "not found". §8; `tidal_lib.js:129-168, 387-396`; `electron-main.js:972-974`.
13. **Low: no refresh-and-retry after a 401**; the local clock alone decides expiry. §13; `tidal_lib.js:97-102, 293`.
14. **Low: file names.** A leading `.` hides the file, a whitespace-only title gives `.flac`, there is no length cap, Windows reserved names and control characters are not handled, and names collide by case and by shared title. §12; `tidal_lib.js:616-618`.
15. **Low: matching text loses non-ASCII letters.** NFC and NFD forms of a name normalise differently. Non-Latin titles are never library-matched and take the first search result. §12.
16. **Low: the activity log cannot be selected or copied**, main's console output is invisible in packaged builds, and folder-open and settings-save failures are silent. §9.
17. **Low (security, defence in depth): updates are downloaded and run with no integrity check.** The page may supply any `http(s)` URL. macOS strips quarantine. Paths are pasted unescaped into a bash script. `open-folder` accepts any path. §10; `electron-main.js:288-469, 575`.
18. **Possibly High (security; unverified, needs a run): a link dropped outside the drop zone probably loads that web page in the app window with the full `api` bridge** (see row 17's capabilities). §6, §10; `app.js:1765-1782`; no `will-navigate` handler.
19. **Info: the preview ▶ button can fetch the same track twice** alongside its pre-load. §8; `app.js:705-727`.
20. **Info:**
    - Window frame and full-screen state are not remembered.
    - The default menu exposes zoom, Reload and DevTools.
    - The drag regions are probably inert.
    - The window background (`#0a0a0a`) differs from the page (`#000000`).
    - There is no power assertion, Dock progress or completion notification.
    - §6, §7.
21. **Info: the library walk** skips symlinks, counts AppleDouble files, and may download cloud-only files (unverified). §12.

---

### 16. Porting notes for a native Swift macOS app (summary)

1. **One app-level model owns all state**: settings, the queue, sign-in state, library status, FFmpeg health, update state and batch progress. Windows only display it. That removes the lost-push class (§3.2), the forgotten status after a re-open (§3.8) and the destroyed-window sends (§4.3).
2. **Single instance:** Launch Services covers normal launches. Add a bundle-id check and a lock file for `open -n` and second copies (§2.4).
3. **Launch:**
   - Load settings and the queue synchronously (they are small).
   - Show the window with content in place.
   - Then start background tasks: the library scan off the main actor and cancellable by generation, the update check, the FFmpeg check, and waveform loads at low priority.
   - Restore the volume slider to the stored **position**.
   - Never end the process for a missing credential: show a signed-out state.
4. **Quit (`applicationShouldTerminate`):** if a batch, resolve, preview, sign-in or update download is running, ask first (`Downloads in progress — Quit anyway?` with **Quit** and **Cancel**). Then cancel tasks, `terminate()` every `Process` you started (children are not killed automatically), delete your own partial files, flush saves, and reply `.terminateNow`. The updater's restart goes through the same path.
5. **Crash-safe output:** write audio and the remux to temp files, then atomically rename to `<Title>.<ext>`. Treat only a renamed file as "already downloaded".
6. **Persistence:** atomic writes, flushed when the window closes and at termination. A file that fails to decode is moved aside and reported, never silently replaced.
7. **Window:** one main window with automatic frame restore, default 980 × 740, minimum 720 × 540, standard title bar, a proper menu bar (Settings… ⌘,; Close Window ⌘W; Quit ⌘Q), and no Reload or DevTools.
8. **Power and system:** a power activity during batches, Dock progress, and an optional completion notification (§7).
9. **Networking:** one TIDAL actor with single-flight token refresh, shared limits, 429/`Retry-After` handling and 401 refresh-and-retry (§8, §13).
10. **Diagnostics:** OSLog plus a selectable activity log with Copy and Save (§9).
11. **Security:** no web content; `Process` argument arrays; Keychain tokens; verified updates; a deliberate sandbox decision with security-scoped bookmarks if the sandbox is on (§10).
12. **Text:** a String Catalog, locale-aware formatters, a tested file-name rule, and Unicode-aware matching if the owner approves (§11–§12).
13. **Drop the extension bridge** (`extension-server.js`, port 8273, `extension-token.txt`, `<userData>/chrome-extension/`, the Settings → Extension tab), per the owner's decision of 21 Oct 2026. Leave existing files alone rather than deleting them unasked.

---

### 17. Owner decisions and items that need a run

**Owner decisions** (recommended default first):
1. Prevent idle sleep during a batch? **Yes (recommended)** / no.
2. Show batch progress on the Dock icon? **Yes (recommended)** / no. Post a notification when a batch ends while the app is in the background? Yes / **no, sounds only, as today**.
3. App Sandbox? **Not sandboxed at first (recommended)**: keeps the self-updater model and free folder access. Or sandboxed, with bookmarks and Sparkle.
4. File names safe for Windows and FAT/exFAT drives too? **Yes (recommended**, since files often move to USB drives and DJ gear) / macOS rules only.
5. Unicode-aware matching that keeps accented and non-Latin letters (this changes which tracks count as duplicates)? **Yes (recommended)** / keep today's ASCII-only behaviour.
6. Localise the UI? **English only, but strings in a String Catalog (recommended)** / translate now.

**Needs a run to settle:**
- whether each launch push in §3.2 is really dropped;
- the destroyed-window throws and the stuck `activeChild` in §4.3;
- EPIPE deaths of orphans after ⌘Q (§4.4);
- whether Windows job objects take the whole tree down (§4.1);
- `close` waiting for the orphaned grandchild (§4.1);
- link or file drops navigating the window (§6, §10);
- whether the default menu (with DevTools) is present in the packaged build;
- drag regions on a framed window;
- whether idle sleep or App Nap stalls batches;
- cloud-placeholder downloads during the library scan;
- Launch Services behaviour for a second copy at another path.
