## Gap: Logging, diagnostics and silent error surfacing

Scope: how v0.1.30 reports what happened, where those reports go, and which failures reach the user as nothing at all. Files: `renderer/styles.css`, `renderer/app.js`, `electron-main.js`, `tidal_download.js`, `bulk_runner.js`, plus the `console.*` sites in `tidal_lib.js` and (inventory only, being dropped) `extension-server.js`. All six items in the brief exist in the code; two small corrections are noted where they apply (the `.activity-log` line range, and stdout/stderr being two line-buffered streams, not one merged stream).

Related sections that already cover neighbouring ground (not repeated here): the `classify()` rules and log cap (`renderer-flows.md`), the per-track CLI log catalogue (`download-pipeline.md`), lost boot-time pushes and sends to a destroyed window (`trace-boot-and-shutdown.md`), `loadCred()` quitting the app (`trace-failure-paths.md`), and the updater state machines (`build-updater.md`).

### In plain words

- The app has one user-facing log: the **Activity** panel. It lives only in memory. Quitting, reloading or pressing **Clear** loses it, and its text cannot be selected or copied.
- The only diagnostics written to disk are the macOS self-updater's two log files in `~/Library/Logs/robogears Downloader/`.
- Debug output exists in the per-track downloader but cannot be turned on from the app.
- Several failures produce no message at all: opening a missing folder, a failed settings or queue save, and any uncaught error in the page.
- A multi-line FFmpeg error is split into separate log rows. Only the first row is coloured as an error, and the same text is printed twice.

---

### 1. Inventory: every diagnostic channel

| Channel | Who writes to it | Where it ends up | Kept after quit? | Can the user read it? |
|---|---|---|---|---|
| Activity log `#activity` (`index.html:86`) | Renderer `appendLine()` (`app.js:342-359`); main `download:line` pushes (child output at `electron-main.js:1018`, FFmpeg-missing warning `:542-543`, extension notices `:519-520, 699-700, 748-749, 796-797`) | DOM `<div class="log-line …">` rows, at most 2000 (`app.js:54`) | No | Yes, but not selectable or copyable (section 2) |
| Sign-in terminal `#auth-output` (`index.html:217`, a `<pre class="terminal">`) | `auth:output` pushes (`electron-main.js:621-625`, each line + `'\n'`); failure line `'ERROR: ' + e.message` (`:639`); renderer adds `'\n\n✗ Sign-in failed.'` (`app.js:1727`) | `textContent +=` (`app.js:1731-1734`); wiped on every **Sign in** click (`app.js:1717`) | No | Yes, not selectable; the modal has no close control after a failure (see `auth.md`) |
| Transient button and status labels | `Check failed` (`app.js:1664, 1667`), `Download failed — retry` (`:409`), `Retry update` (`:470`), `Scan failed` (`:1563`), `(scan failed)` (`:1683`) | The control's own text, reverting after 2.5 s for the update check (`:1669-1672`) | No | Briefly; never says why |
| macOS updater breadcrumb `attempts.log` | `update:apply` (`electron-main.js:361-371`, `:452-458`) | `~/Library/Logs/robogears Downloader/attempts.log`, appended, never rotated | Yes | Only by finding the file |
| macOS relauncher trace `update-<ts>.log` | The bash relauncher (`electron-main.js:387, 395-397, 438`) | Same folder, one file per attempt, never deleted | Yes | Only by finding the file |
| Main-process `console.*` | `electron-main.js:800`; `extension-server.js:57, 198` (inventory); `tidal_lib.js:50, 56` when `loadCred()` runs in main | Main process stdout/stderr | No | Not in a packaged app launched from Finder or the Dock; only if the executable is started from a terminal (unverified (needs a run)) |
| Renderer DevTools console | Unhandled promise rejections and Chromium errors (the page itself has no `console.*` calls: `grep` finds none in `app.js`) | DevTools | No | Only via Electron's default menu (View → Toggle Developer Tools), since no `Menu` is set and `openDevTools` is commented out (`electron-main.js:98`); presence in the packaged build is unverified (needs a run) |

No line in the activity log or the sign-in terminal carries a timestamp.

---

### 2. The activity log and sign-in terminal cannot be selected or copied

**Evidence (verbatim CSS):**

- `styles.css:25-38`, the `html, body` rule, includes `user-select: none;` at line 36.
- `styles.css:40`: `input, textarea { user-select: text; }` is the only rule that turns selection back on.
- `.activity-log` (`styles.css:334-342`, plus its `:empty::before` placeholder at `343-347`) has no `user-select` property. Neither do `.log-line` and its variants (`349-382`).
- `.terminal` (`styles.css:1054-1067`) has no `user-select` property either.
- The only other `user-select` in the file is `user-select: none;` on `.qi-check` (`styles.css:751`).

**Behaviour:**

1. Dragging across a log row selects nothing, so ⌘A then ⌘C copies nothing. The whole page inherits `none` from `body`, and only `<input>`/`<textarea>` opt back in. (Standard Chromium behaviour; the exact Edit-menu result is unverified (needs a run).)
2. No context menu: there is no `contextmenu` handler and Electron shows none by default.
3. No **Copy log**, **Save log…** or **Reveal logs** action exists anywhere in `index.html` or `app.js`. The Activity header holds only `Clear` (`index.html:84`).
4. **Clear** runs `activityEl.innerHTML = ''` (`app.js:361`). It removes every row, including the welcome line and any update notice, with no undo.
5. The URL field in the sign-in modal is an `<input>` (`index.html:214`), so it stays selectable and has its own **Copy** button (`app.js:1741-1753`). The terminal text under it does not.

**Consequence:** the most useful diagnostic text the app produces cannot be copied into a bug report: TIDAL's error bodies, the FFmpeg stderr tail, `Error: …` lines and sign-in errors. The user can only retype them or take a screenshot.

---

### 3. Nothing persists except the macOS updater logs

The only diagnostics written to disk come from `update:apply` on macOS. The other files the app writes (`settings.json`, `queue.json`, `pending-tracklist.json`, `token.json`) hold state, not logs.

**`attempts.log`** (`electron-main.js:354-371`):

1. `logDir = ~/Library/Logs/robogears Downloader` (`:354`); `mkdirSync(..., {recursive:true})` with errors ignored (`:355`).
2. `ts = Date.now()` (`:356`). The script goes to `os.tmpdir()/robogears-update-<ts>.sh` (`:357`), the trace to `<logDir>/update-<ts>.log` (`:358`).
3. Before anything is spawned, it appends this record, verbatim (`:363-370`); any error is ignored (`:371`):

   ```
   [<new Date().toISOString()>] applyUpdate fired
     parent pid: <process.pid>
     app bundle: <target .app path>
     new app:    <staged .app path>
     script:     <script path>
     log:        <update-<ts>.log path>
   ```

   The "app bundle" line holds `targetAppBundle` (`:350`), which is `/Applications/<name>.app` when the app runs translocated, not the bundle actually running.
4. If spawning `/bin/bash` emits `error`, it appends `  SPAWN ERROR: <err.message>` with no timestamp (`:452-458`).

**`update-<ts>.log`**: the script's stage 2 runs `exec >>"$LOG" 2>&1` then `set -x` (`:395-396`). Every command is traced as a `+ …` line with no time, between two marker lines: `=== robogears update script started at $(date) ===` (`:397`) and `=== script finished at $(date) ===` (`:438`). Its `echo` messages are `PID=… NEW=… TARGET=… RUNNING_FROM=… TRANSLOCATED=…`, `Waiting for parent process $PID to exit...`, `Parent gone after ${i}s`, `Backing up existing $TARGET...`, `ERROR: could not back up existing TARGET (permission?). Aborting.`, `Moving NEW -> TARGET...`, `Re-signing ad-hoc...`, `Removing backup...`, `Opening new app at $TARGET...`, `Done.` and `ERROR: mv NEW->TARGET failed. Rolling back.`

**Mixed time formats (verified):** `attempts.log` stamps UTC ISO-8601 with milliseconds and a `Z` (`:364`, for example `2026-10-21T19:03:12.345Z`). The script log uses bash `$(date)`: local time in `date`'s default, locale-dependent format (for example `Tue Oct 21 20:03:12 BST 2026`; exact format unverified (needs a run)). The file name `update-<ts>.log` uses epoch milliseconds. Matching an `attempts.log` entry to its trace file therefore means converting between three time forms.

**Other facts:**

- `global._lastUpdateLogPath = logPath` (`:460`) is written and never read. The app never tells the user where these logs are.
- Neither file is ever rotated or deleted. The script deletes only itself (`rm -f "$0"`).
- The Windows branch (`:321-336`) writes no log at all and has no `error` listener on its spawn (inventory; the port is macOS-only).
- Main-process `console.*` output goes to a stdout nobody sees in a packaged build: `console.warn('[ext-bundle] sync failed:', e.message)` (`electron-main.js:800`), `console.warn('[extension-server] could not persist token:', e.message)` (`extension-server.js:57`) and ``console.log(`[extension-server] listening on http://${HOST}:${PORT}`)`` (`extension-server.js:198`). All three are extension code (inventory, being dropped). `tidal_lib.js:50` `token.json not found. Run tidal_auth_node.js first.` and `:56` `No credentials in token.json. Run tidal_auth_node.js first.` also go there when `loadCred()` runs inside main, right before `process.exit(1)`.
- The activity log is only DOM nodes. A page reload (⌘R from the default menu), a window close or quitting loses it, and nothing is flushed anywhere first.

---

### 4. Debug output cannot be turned on from the app

**How debug is switched on in the downloader (`tidal_download.js`):**

- `parseArgs` starts with `debug: !!process.env.DEBUG` (`:49`) and sets it to `true` on `--debug` (`:59`). Any non-empty `DEBUG` value turns it on, including `DEBUG=0` and `DEBUG=false`, because a non-empty string is truthy.
- The fatal handler also prints the stack when `process.env.DEBUG` is set (`:720-724`): `console.error('\nError:', e.message); if (process.env.DEBUG) console.error(e.stack); process.exit(1);`.

**Why the GUI can never turn it on:**

1. `bulk_runner.js:35` builds the per-track argument list verbatim: `[path.join(__dirname, 'tidal_download.js'), String(trackId), outDir, '--skip-library-check']`. It never passes `--debug`.
2. `DEBUG` can only arrive through the environment. Main's `childEnv()` (`electron-main.js:59-70`) returns `{...process.env, ELECTRON_RUN_AS_NODE: '1', FORCE_COLOR: '0', TIDAL_LIBRARY_FOLDER: s.libraryFolder || '', BULK_RUNNER_PROGRESS: '1'}`. The spread at `:62` passes `DEBUG` through only if the Electron process itself was started with it. `bulk_runner.js:43` passes it on again with `{ ...process.env, ELECTRON_RUN_AS_NODE: '1', FORCE_COLOR: '0' }`.
3. Settings has no debug switch, and nothing in main sets `DEBUG`. The only route is to start the app's executable from a shell with `DEBUG` set (unverified (needs a run)).

**What debug prints** (all two-space indented):

| Line | Stream | Source |
|---|---|---|
| `  [debug] Got <audioQuality> at request tier <quality>` | stdout | `:331` |
| `  [debug] <quality> unavailable: <message>` | **stderr** (`console.warn`) | `:338` |
| `  [debug] manifest type: <manifestMimeType>` | stdout | `:407` |
| `  [debug] audioQuality: <audioQuality>` | stdout | `:408` |
| `  [debug] codec: <codec>, mimeType: <mimeType>` | stdout | `:409` |
| `  [debug] segments: <count or 'direct'>` | stdout | `:410` |
| `  [debug] isFlacOutput: <bool>` | stdout | `:411` |
| `  [debug] cover: <KB, 0 decimals> KB` | stdout | `:452` |
| `e.stack` after the fatal `Error:` line | stderr | `:722` |

In the activity log, rows containing `[debug]` get class `muted` (`app.js:338`, colour `--text-dim #5a5a5a`, `styles.css:369`). The `\[debug\]` rule comes last, so a debug line that also matches an earlier rule takes that rule's class instead. For example, `[debug] HI_RES_LOSSLESS unavailable: …` with `Error:` in the message is coloured as an error. Stack frames (`    at …`) match no rule and are unstyled.

**Help text promises more than the code does:** the header comment (`:8`, `Verbose output (DASH manifest etc.)`) and `printHelp` (`:91`, `Verbose output (manifest dump, etc.)`) both promise a manifest dump. No code prints the decoded manifest; only the eight lines above exist. `bulk_runner.js` and `electron-main.js` have no debug output of their own.

---

### 5. Failures that show nothing

| # | Trigger | Code path | What the user sees | What actually happened |
|---|---|---|---|---|
| a | **Open** (download folder), **Open** (library folder), or **Open folder** on the `✓ Batch finished.` row, when the folder was deleted, renamed or is on an unmounted drive | `app.js:1527-1529`, `1542-1544`, `1496` → `api.openFolder(p)` (`electron-preload.js:10`) → `ipcMain.handle('open-folder', (_e, p) => shell.openPath(p))` (`electron-main.js:575`) | Nothing | `shell.openPath` resolves to an error string (empty string on success). Main returns it, and all three call sites drop it without awaiting. The exact error text is unverified (needs a run). |
| b | `queue.json` cannot be written (disk full, permissions, read-only volume) | `saveQueueSoon()` → `api.saveQueue(persisted).catch(() => {})` (`app.js:81`) → `queue:save` (`electron-main.js:599-606`) | Nothing | Main catches the write error and **resolves** `{ok:false, error}`. The renderer's `.catch` only handles rejections and never looks at the resolved value. Because `writeFileSync` truncates before writing, a failed write can leave a partial file. At the next launch `queue:get` fails to parse it and returns `[]` (`:594-597`, the renderer's `catch {}` at `app.js:1988`), so the queue silently starts empty (truncation behaviour unverified (needs a run)). |
| c | `settings.json` cannot be written | `saveSettings(s)` (`electron-main.js:42-52`): `fs.writeFileSync(SETTINGS_PATH(), JSON.stringify(s, null, 2))` at `:44` is **not** in a `try` | Nothing, and the UI shows a value that was never saved (details below) | The throw rejects the `settings:save` invoke (`:556`); the renderer gets a rejection (Electron formats it as `Error invoking remote method 'settings:save': …`, unverified). No caller catches it. |
| d | Any uncaught exception or unhandled rejection in the page | No `window.onerror`, no `addEventListener('error'…)` on `window`, no `unhandledrejection` handler (`grep` finds only the `<audio>` element's `error` listener at `app.js:869`). Main has no `process.on('uncaughtException'…)` either. | Nothing in the UI | Goes to the DevTools console only. |

**Detail for (c): the four renderer callers and what each leaves behind**

1. Volume slider (`app.js:515-524`): `setTimeout(() => api.saveSettings(settings), 300)`. The rejection is unhandled. The volume works for this session and reverts at the next launch.
2. Download folder **Browse…** (`app.js:1517-1525`): `settings.downloadFolder` and the field are updated **before** `await api.saveSettings(settings)` (`:1520-1522`). The throw skips `updateOpenButtonStates()`. This session's downloads use the new folder, because the renderer passes `settings.downloadFolder` as `outDir`. After a restart the old folder returns, with no explanation.
3. Library folder **Browse…** (`app.js:1531-1540`): same pattern at `:1534-1536`. The `📁 Music library folder set to: …` line is not logged. Because `writeFileSync` throws before `lib.setLibraryPath()` (`electron-main.js:45-51`), main keeps scanning and matching against the **old** library while Settings shows the new path.
4. Library **Clear** (`app.js:1546-1553`): the field is blanked, but main keeps the old library path and the duplicate check stays on. `📁 Music library folder cleared (duplicate check disabled).` is not logged, and `refreshLibraryStatus()` does not run.
5. Not in the brief but on the same path: **Reset config** (`app.js:1569-1577`) → `settings:reset` (`electron-main.js:561-565`) calls the same `saveSettings`. On a throw, `settings = await api.resetSettings()` rejects, so nothing is cleared and nothing is logged, after the user has already confirmed the `confirm()` dialog.

**Other silent or reason-less failures on these paths (verified, short):**

- Update download failure: main returns `{ok:false, error}` (`electron-main.js:308-311`), but both UIs show only `Download failed — retry` (`app.js:409`) or `Retry update` (`:470`). The reason is dropped.
- Update check failure: every GitHub problem becomes `{status:'error', message:'Could not reach GitHub'}` (`electron-main.js:146-148`). The launch check shows nothing (`:489`); the manual check shows `Check failed` for 2.5 s and never shows the message (`app.js:1663-1672`).
- `api.applyUpdate()` is called without `await` or a result check (`app.js:420, 476`). A `{ok:false, error:'No downloaded update available'}` (`electron-main.js:316-319`), or a throw from the unguarded `fs.writeFileSync(scriptPath…)` / `fs.chmodSync` (`:442-443`), leaves the button on `Restarting…`, disabled, with the app still running. If the relauncher itself fails after the app quits (`ERROR: could not back up …`), the app is gone and does not reopen; the reason is only in `update-<ts>.log`.
- FFmpeg probe (`electron-main.js:529-546`) listens only for `error` (the program cannot be started). A binary that starts but exits non-zero produces no warning. The warning that does exist may arrive before the page listens (see `trace-boot-and-shutdown.md`).
- Library scan errors: the boot and settings-change scans end in `.catch(() => {})` (`electron-main.js:50, 484`). Manual failures show `Scan failed` / `(scan failed)` with no reason (`app.js:1563, 1683`).
- Waveform preload errors are swallowed on purpose (`app.js:763-766`); the reason appears only when the user presses play (`✗ Preview: <message>`, `app.js:879`).
- `api.startBulk(...)`'s result is never read (`app.js:1416, 1453`). A `{ok:false, error}` from `bulk:start` (`electron-main.js:987-988`) or a throw from its unguarded `fs.writeFileSync(listPath…)` (`:992`) leaves the UI in the downloading state with rows `queued` and no message.

---

### 6. Child output is split per line, so multi-line errors break apart

**How a line travels (step by step):**

1. `tidal_download.js` is spawned by `bulk_runner` with `stdio: 'inherit'` (`bulk_runner.js:41-44`). Its stdout and stderr are therefore bulk_runner's own stdout and stderr pipes.
2. Main spawns bulk_runner with `stdio: ['pipe','pipe','pipe']` (`electron-main.js:996-999`).
3. `forward(stream)` (`:1021-1029`) runs once for stdout (`:1030`) and once for stderr (`:1031`). **Each stream has its own buffer `buf`**. On every `data` chunk it appends `d.toString()`, splits on `/\r?\n/`, keeps the last (incomplete) piece in `buf`, and calls `dispatchLine` for each complete line. Correction to the brief: the two streams are not merged into one before splitting. They feed the same `download:line` channel through two independent line splitters, so the order of a stdout line relative to a stderr line is not guaranteed (unverified (needs a run)).
4. There is no `end` handler, so a final line without a trailing newline is never sent.
5. `dispatchLine` (`:1004-1019`) routes `__TRACK_START__:<id>`, `__TRACK_PROGRESS__:<id>:<pct>` and `__TRACK_DONE__:<id>:<word>` to typed events. It drops empty lines (`if (line.length)`, `:1018`) and sends everything else as one `download:line` per line.
6. The renderer appends each line as its own row and colours it on its own with `classify()` (`app.js:330-340`, `1456`). There is no notion of "this row continues the previous one".

**The FFmpeg case (verbatim sources):**

- `runFfmpeg` rejects with `` new Error(`ffmpeg exited ${code}: ${stderr.slice(-500)}`) `` (`tidal_download.js:267`). That is the **last 500 characters** of all FFmpeg stderr. The remux call passes no `-v`/`-hide_banner` (`:289-307`), so stderr holds the banner and stream info too. The tail usually spans several lines and can start mid-line. `code` is `null` if FFmpeg was killed by a signal.
- `remuxToFlac`'s caller prints `` console.error(`  ✘ FFmpeg failed: ${e.message}`) `` then `` console.log(`     Raw file kept at: ${tmpPath}`) `` and rethrows (`:454-460`).
- For a single track (the only GUI case), `singleTrackCatcher` rethrows (`:694-700`, `:710`), and the fatal handler prints `console.error('\nError:', e.message)` (`:721`).

**What the activity log shows** for one failed remux (tail of *k* lines, ending in a newline):

| Row | Stream | Text | Class (`app.js:330-340`) |
|---|---|---|---|
| 1 | stderr | `  ✘ FFmpeg failed: ffmpeg exited 1: <tail line 1, possibly a fragment>` | `error` |
| 2…k | stderr | `<tail line 2>` … `<tail line k>` | none (default `--text-muted`), unless the line happens to start with `✘` or contain `✗ `, `Error:` or `FFmpeg failed` |
| — | stderr | empty line | dropped by main |
| k+1 | stdout | `     Raw file kept at: <outDir>/<Title>.tmp.<m4a|flac>` | none |
| — | stderr | empty line (the leading `\n` of `'\nError:'`) | dropped |
| k+2 | stderr | `Error: ffmpeg exited 1: <tail line 1>` | `error` |
| k+3… | stderr | tail lines 2…k **again** | none |
| (DEBUG only) | stderr | `e.stack`: the same `Error: …` header and tail a third time, then `    at …` frames | first line `error`, rest none |

The row then shows `✗ failed` from the `__TRACK_DONE__:<id>:failed` marker, which bulk_runner prints on stdout (`bulk_runner.js:110`). That marker can be handled before the stderr rows arrive. The whole sequence is built from the code; the exact interleaving is unverified (needs a run).

The same split hits any multi-line message: TIDAL error bodies inside `Error:` lines, and `e.stack`. A neighbouring case is the integrity check, which takes only the **last** line of the same message (`tidal_download.js:318`). That line is often empty, so `  ⚠ FLAC integrity check failed: ` shows no reason (see `download-pipeline.md`).

---

### 7. Rows added outside `appendLine` skip the 2000-row cap

- `appendLine` (`app.js:342-359`) is the only place the cap is enforced: while `childElementCount > 2000`, remove the first child, or the welcome line's next sibling if the first child is the welcome line.
- `appendBatchDoneNotice()` (`app.js:1486-1501`) builds a `log-line batch-done-notice` row (`<strong>✓ Batch finished.</strong>` plus an `Open folder` button when a download folder is set) and adds it with `activityEl.appendChild(row)` (`:1499`), skipping the cap. The update notice is inserted the same way, with `insertBefore` (`app.js:388`).
- Effect: the log can sit at 2001 rows (one per such insert) until the next `appendLine` call trims it back. The overshoot is bounded and fixes itself; the bug is that the cap is enforced in one helper, not by the log as a whole.
- Related (verified): **Clear** (`app.js:361`) detaches the welcome line, but `welcomeLineEl` still points at it. From then on, `insertUpdateNotice` sees `!welcomeLineEl.parentNode` and stores the payload in `pendingUpdate` (`:372-375`). `pendingUpdate` is replayed only once, at the end of boot (`:1990-1994`). So after Clear, an update found by **Check for updates** never gets its activity-log notice; only the topbar pill appears (`:444-450`).

---

### Bugs (shown by the code)

1. **Medium — Diagnostic text cannot be copied or exported.** `styles.css:36, 40, 334-347, 1054-1067`; no copy or save action in `index.html`/`app.js`. Error text has to be retyped or screenshotted for a bug report.
2. **Medium — A failed settings save is silent and leaves the UI out of step with disk and with main.** `electron-main.js:42-52` (unguarded `writeFileSync` at `:44`), `:556`, `:561-565`; callers `app.js:523, 1522, 1536, 1549, 1571`. A library path the UI shows may not be the one main is matching against.
3. **Low — Open / Open folder do nothing for a missing folder.** `electron-main.js:575`; `app.js:1496, 1527-1529, 1542-1544`.
4. **Low — Queue save failures are swallowed.** `app.js:81`; `electron-main.js:599-606`. A partial write may make the next launch start with an empty queue (unverified (needs a run)).
5. **Low — No global error capture in the page or main.** No `error`/`unhandledrejection` listeners on `window`, no `uncaughtException` handler in main.
6. **Low — Multi-line errors are split into unstyled rows and printed twice.** `tidal_download.js:267, 457, 721`; `electron-main.js:1021-1031`; `app.js:330-340`. A final unterminated line is lost (no `end` handler).
7. **Low — Debug output is unreachable from the GUI, and `DEBUG=0` turns it on.** `bulk_runner.js:35`; `electron-main.js:59-70`; `tidal_download.js:49`. The help text promises a manifest dump that does not exist (`:8, 91`).
8. **Low — Updater logs mix UTC ISO, local `date` and epoch-ms file names, and are never rotated; the app never tells the user where they are.** `electron-main.js:356-371, 395-397, 438, 460`.
9. **Low — After Clear, update notices from a manual check are stashed and never shown.** `app.js:361, 371-375, 1990-1994`.
10. **Info — Batch-done and update notices skip the row cap.** `app.js:388, 1499`. The overshoot is bounded and fixes itself.
11. **Low — Update and start-batch results are ignored.** `app.js:409, 420, 470, 476, 1416, 1453`. Failures show a generic label, a stuck `Restarting…`, or a stuck downloading state, with no reason.

---

### Porting notes (native Swift, macOS)

1. **One event log in the model, not text in a view.** Keep a capped ring buffer (2000 entries) of typed entries on the app model: `struct LogEntry { date: Date; level: .info/.success/.skip/.warning/.error/.debug; message: String; detail: String?; trackID: Int? }`. The cap belongs to the buffer, so every way of adding an entry obeys it. Decide each entry's level when it is created (where the event happens), not by matching text with regexes afterwards. That removes `classify()`, the split-line styling and the `📁 Already in library` mismatch.
2. **Multi-line errors are one entry.** Put the summary in `message` and the FFmpeg stderr tail (or the TIDAL body) in `detail`, shown with a disclosure triangle. Capture FFmpeg's stderr with a `Pipe` on `Process` and keep the whole thing, or at least its last 4–8 KB, cut on a line boundary. Print it once.
3. **Selectable and exportable.** Render the log with `.textSelection(.enabled)` (or an `NSTextView`) so drag-select, ⌘A and ⌘C work. Add menu commands with clear names: **Copy Log**, **Save Log…** (`NSSavePanel`, plain text with ISO-8601 timestamps that include the offset) and **Show Logs in Finder**. Give each entry a context menu with **Copy** (and **Copy Details** when there are details). The sign-in sheet's log must be selectable too, and closable after a failure.
4. **Persistent logging.** Use `os.Logger(subsystem: "com.robogears.downloader", category: …)` with categories such as `download`, `ffmpeg`, `library`, `update`, `auth` and `settings`, so Console.app shows everything with consistent timestamps. Mark tokens and personal paths `privacy: .private` and never log credential values. If a plain-text file is also wanted, write `~/Library/Logs/robogears Downloader/robogears.log` with ISO-8601 local time plus offset, and rotate it by size (for example keep 3 × 1 MB). Use the same timestamp format in the updater's records so one clock runs through every file.
5. **Debug switch.** Use `Logger.debug` for what `[debug]` prints today (manifest MIME type, audio quality, codec, segment count, FLAC decision, cover size), plus the real manifest summary the help text promised. Debug messages are not stored by default, so this costs nothing until someone streams them (`log stream --level debug --predicate 'subsystem == "com.robogears.downloader"'`). For the in-app log, add a hidden **Show debug messages** setting (or a `UserDefaults` key). Never decide it with a truthy-string check.
6. **Every failure reaches the user, with a reason and a fix.**
   - Open folder: check `FileManager.default.fileExists(atPath:isDirectory:)` first. If it is missing, show an alert such as "The folder “Downloads” can't be found. It may have been moved, renamed, or be on a disconnected drive." with **Choose Folder…** and **Cancel**. Otherwise call `NSWorkspace.shared.open(url)` and check the `Bool` it returns.
   - Settings: store them in `UserDefaults` (atomic, no failure path to handle). Store folder choices as security-scoped bookmarks if the app is sandboxed.
   - Queue: write with `Data.write(to:options: .atomic)` inside `do/catch`. On failure, log an `.error` entry ("Couldn't save the queue: <reason>. It will be lost when you quit.") and retry on the next change. Keep a corrupt file aside (`queue.corrupt-<date>.json`) instead of treating it as empty.
   - Updates: show the real reason ("GitHub rate limit reached, try again in an hour", "No internet connection") and put the updater's log path behind a **Show Log** button when an update fails.
7. **No "unhandled" bucket.** Swift `throws` and `Task` results must be handled at each call site. Route every caught error into the model's log (`LogEntry(level: .error, …)`) instead of `try?`. Where a background `Task` result is ignored, use a small helper that logs the error. Crash reports come from the system (`~/Library/Logs/DiagnosticReports`), so no global handler is needed.
8. **Batch outcome comes from per-track results, not an exit code** (see `trace-failure-paths.md`). The batch-finished entry should read, for example, "12 downloaded, 3 failed", with **Show in Finder**.
9. **Things to drop:** `classify()`'s regex table, the `__TRACK_*__` text markers (use typed events or an `AsyncStream`), the `FORCE_COLOR`/`BULK_RUNNER_PROGRESS`/`DEBUG` environment plumbing, `global._lastUpdateLogPath`, and the extension's `console.*` lines.
