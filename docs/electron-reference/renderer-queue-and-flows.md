## Renderer logic: state, queue, input, import, downloads, settings, update UI

Scope: `renderer/app.js` (1995 lines) and `renderer/index.html` (235 lines), plus the parts of `electron-preload.js`, `electron-main.js`, `renderer/styles.css`, `bulk_runner.js`, `tidal_lib.js` and `tidal_download.js` they call or depend on. Code version v0.1.30. The waveform preview, the sound-effect synthesis and the Chrome extension are listed here only where this area touches them; other sections own them.

### Overview

The whole user interface is one HTML page (`renderer/index.html`) driven by one plain-JavaScript file (`renderer/app.js`), with no framework. All UI state lives in a few module-level variables: `settings`, `queue`, `pendingResults` (search candidates) and `isDownloading`. The page never touches files or the network itself. It calls the Electron main process through `window.api`, a bridge defined in `electron-preload.js`. Each bridge call is either a request with a reply ("invoke") or a subscription to events that main pushes.

Tracks reach the **queue** four ways:
1. Typing a TIDAL or Spotify link and pressing Add or Return. Every track is resolved and added at once.
2. Typing a song name. TIDAL search results open in a pick-list modal.
3. Dropping or picking a CSV or text file.
4. Pasting a tracklist while no text field has focus.

Imports are parsed into `{title, artist}` pairs in the page and then matched on TIDAL by main. Each queue row shows several things: its library-duplicate status (an exact match starts excluded, with a "+ Add" button), its source, a Hi-Res badge, an inline waveform preview, and its download progress. The queue is saved to `queue.json` 400 ms after each change and restored on launch.

**Download all** sends every included, found row to main. Main spawns `bulk_runner.js`, which spawns `tidal_download.js` once per track. Main turns the runner's stdout marker lines into per-track start, progress and done events. When the batch ends, the queue is pruned: rows that downloaded or were skipped disappear, and failed rows stay with Retry buttons. An **activity log** shows every message, capped at 2000 lines.

Two independent update interfaces sit on top of the same main-process updater:
- an activity-log notice (Download, then Restart);
- a topbar "Update now" pill (one click).

**Settings** is a modal with Folders, TIDAL, Extension and Updates tabs. It saves on every change and has no Save button. Sign-in runs in a separate modal that streams TIDAL's device-code flow.

### Components

#### 1. Page layout and static text — `renderer/index.html`

The page runs in one window. Main sets it to 980×740 with a minimum of 720×540, background `#0a0a0a`, title `robogears Downloader` (`electron-main.js:73-99`). Top to bottom:

| Region | Lines | Contents (exact text) |
|---|---|---|
| Topbar | 10-31 | `#brand`: an inline SVG vinyl-and-arrow logo (`.brand-logo`), `robogears Downloader` (`.brand-name`), `#brand-version` (empty until boot), and `#brand-update-pill` `Update now` (hidden). Gear button `#settings-btn` (title and aria-label `Settings`). |
| Input card | 34-41 | Label `Paste a link or search for a song`. `#url-input` with placeholder `Spotify/TIDAL URL or song name...`, `autocomplete=off`, `spellcheck=false`. `#add-btn` `Add to queue`. Hint `#input-hint` `Paste a Spotify or TIDAL link to add all its tracks. Or type a song name to search.` |
| Drop zone | 43-55 | `#drop-zone` with a document icon, title `Drop a playlist CSV or paste tracks`, and subtitle `For playlists over 100 tracks — export via ` + link `Exportify` (`#exportify-link`, `href="#"`) + ` and drop the CSV here`. Hidden `#file-input type=file accept=".csv,.txt,text/csv,text/plain"`. |
| Queue | 58-79 | `#queue-section`, hidden while the queue is empty. Head: `Queue` + `#queue-count` pill; `.queue-volume` (title `Preview volume`) containing a speaker icon and `#volume-slider` (range 0-100, `value=50`, aria-label `Preview volume`). Actions: `#cancel-queue` `Cancel` (hidden), `#retry-all` `↻ Retry all` (hidden), `#clear-queue` `Clear all`, `#download-all` `Download all`. Then `#queue-list`. |
| Activity | 81-87 | Header `Activity` + `#clear-btn` `Clear` (title `Clear`); `#activity` log. When empty, CSS shows `Nothing yet. Paste a link above to get started.` in italics (`styles.css:343-347`). |
| Search modal | 91-106 | `#search-modal`: title `#search-modal-title` (`Search results`), ✕ (`data-close`, aria-label `Close`), hint `#search-modal-hint`, `#search-results`. Footer: `Cancel` (`data-close`), `#add-selected` `Add selected`. |
| Settings modal | 109-203 | Title `Settings`, ✕ (`data-close`). Tabs `Folders` / `TIDAL` / `Extension` / `Updates` (`.modal-tab[data-tab]`, `role=tab`; container `role=tablist`). Panes `.modal-pane[data-pane]` (detail in component 16). Footer `Done` (`data-close`). |
| Sign-in modal | 206-220 | `#auth-modal`: title `Signing in to TIDAL` (no close control), hint `A browser tab should open automatically. Log in and click Allow.`, hidden `#auth-url-row` (readonly `#auth-url-input` + `#auth-url-copy` `Copy`), `<pre id="auth-output" class="terminal">`. |
| Loading overlay | 224-230 | `#loading`: spinner, `#loading-text` (`Loading…`), hidden `#loading-cancel` `Cancel`. |

**Content-Security-Policy meta** (line 5), verbatim: `default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;`

**Theme** (`styles.css`):
- Pure black and white. Tokens: `--bg #000`, `--bg-elev #0a0a0a`, `--card #0d0d0d`, `--border #1a1a1a`, `--border-strong #2a2a2a`, `--text #fff`, `--text-muted #9a9a9a`, `--text-dim #5a5a5a`, `--error #ff6b6b`.
- Font stack `-apple-system, BlinkMacSystemFont, "Segoe UI Variable Display", "Segoe UI", "Inter", system-ui, sans-serif`; base 14px. The log uses a monospace stack at 12.5px.
- `user-select: none` everywhere except inputs.
- The topbar is `-webkit-app-region: drag`; buttons, logo, name and version are `no-drag`.
- The queue section is capped at `max-height: 36vh` and scrolls.

#### 2. Module state and small helpers — `app.js:5-94`

- `$ = sel => document.querySelector(sel)` (5). Element references for every id above (6-49). The extension-tab elements are looked up later (1592-1599).
- Globals:
  - `settings = { downloadFolder: '' }` (60), replaced at boot by what main returns;
  - `queue = []` (61);
  - `pendingResults = []` (62);
  - `isDownloading = false` (63);
  - `searchDebounce = null` (64, never used).
- Other module state:
  - `_audioCtx` (100);
  - `_loadingCycler`, `_loadingOnCancel` (283, 287);
  - `welcomeLineEl`, `pendingUpdate` (368-369);
  - `_pillUpdateUrl`, `_pillUpdateState` (441-442);
  - `_volumeSaveTimer` (515);
  - `previewState`, `preloader` (543-559);
  - `scrubbing` (1133);
  - `_resizeRedrawTimer` (1209);
  - `_queueSaveTimer` (72);
  - `_tracklistInFlight`, `_tracklistTotal` (1820-1821).
- `uniqueKey()` returns `Math.random().toString(36).slice(2, 10)`: about 8 base-36 characters. It is not guaranteed unique (87).
- `fmtDuration(sec)` returns `''` when `sec` is falsy (so 0 gives `''`). Otherwise it returns `${Math.floor(sec/60)}:${String(sec % 60).padStart(2,'0')}`, for example 185 gives `3:05` (88-91).
- `escapeHtml(s)` replaces `& < > " '` with `&amp; &lt; &gt; &quot; &#39;` and treats null as `''` (92-94). It is used wherever user or remote text goes into `innerHTML` templates.

#### 3. Queue persistence — `app.js:71-83`; main `electron-main.js:27, 594-606`

- `TRANSIENT_QUEUE_FIELDS = ['dlStatus', 'dlPercent', 'selected']`.
- `saveQueueSoon()`:
  1. `clearTimeout`.
  2. After 400 ms, build a shallow copy of each queue item with the transient keys deleted.
  3. Call `api.saveQueue(copy).catch(() => {})`. The result is ignored.
- Main `queue:save` runs `fs.writeFileSync(<userData>/queue.json, JSON.stringify(queue || [], null, 2))` and returns `{ok:true}` or `{ok:false, error}`. The write is not atomic.
- Main `queue:get` returns the parsed file, or `[]` on any error.
- Callers of `saveQueueSoon`:
  - `addTracksToQueue` when at least one track was added (1270);
  - "+ Add" (1089);
  - Remove (1123);
  - Clear all (1252);
  - batch end (1481).
- It is not called for checkbox toggles, track events, cancel, or the boot-time assignment of `included`. Those either change only transient fields or are saved by the next real save.

#### 4. Loading overlay — `app.js:271-321`; `index.html:224-230`; `styles.css:837-881`

- `FUNNY_LOADING` (271-282), verbatim:
  - `Searching the seven seas for your music…`
  - `Digging through the record crates…`
  - `Asking TIDAL nicely…`
  - `Following the bass line…`
  - `Tracking down these bangers…`
  - `Bribing the algorithm…`
  - `Polishing the vinyl…`
  - `Listening for the drop…`
  - `Tuning the frequencies…`
  - `Whispering to the music gods…`
- `showLoading(text, {cancellable = false, onCancel = null})` (289-309):
  1. Stop any running cycler.
  2. If `text` is given, show it unchanged.
  3. Otherwise show a random message and start a 2500 ms interval. Each tick picks a new random message, re-picking until it differs from the last one.
  4. `_loadingOnCancel = cancellable ? onCancel : null`.
  5. The Cancel button gets `hidden = !cancellable`, is re-enabled, and is labelled `Cancel`.
  6. Show the overlay.
- `hideLoading()` (310-315): hide the overlay and the Cancel button, clear the handler, stop the cycler.
- Cancel click (316-321):
  1. Ignore the click if there is no handler.
  2. Disable the button and label it `Cancelling…`.
  3. Call the handler inside `try {} catch {}`.
  
  The overlay stays up until the caller calls `hideLoading`.
- Users:
  - URL or search resolve: random text, cancellable, handler `api.cancelResolve()` (1295-1298).
  - Tracklist import: fixed text `Matching 0 / ${n} tracks on TIDAL…`, not cancellable (1841), then updated by `tracklist:progress` (1823-1828).
- Style:
  - `position:fixed; inset:0`, `rgba(0,0,0,0.7)`, `backdrop-filter: blur(8px)`, `z-index:100`, above modals (`z-index:50`).
  - It blocks the mouse but not the keyboard: focus stays where it was, so Return in `#url-input` still works under the overlay.

#### 5. Modals — `app.js:322-326`; `styles.css:882-905`

- `openModal(id)` and `closeModal(id)` toggle `hidden`.
- Every element with `data-close` closes the modal it names. Those are the search ✕ and Cancel, and the settings ✕ and Done.
- The sign-in modal has no `data-close` element.
- There is no Escape-key handler and no click-on-backdrop handler anywhere.
- Modals can stack. The sign-in modal opens over Settings and wins because it comes later in the DOM at the same z-index.
- Backdrop: `rgba(0,0,0,0.75)` with blur 8px and a 0.15 s fade-in. The box is `min(560px, 92vw)` wide with a maximum height of 86vh.

#### 6. Activity log — `app.js:54, 330-361`; `styles.css:327-421`

**`classify(line)`** (330-340). Rules are tested in order; the first match gives the CSS class:

| # | Regex (verbatim) | Class |
|---|---|---|
| 1 | `/^\s*✓ Saved/` | `ok` |
| 2 | `/^\s*✘\|✗ \|Error:\|FFmpeg failed/`. This is an alternation: "starts with optional spaces then ✘", OR contains `✗ ` (with the trailing space), OR contains `Error:`, OR contains `FFmpeg failed`. | `error` |
| 3 | `/^\s*⚠/` | `warning` |
| 4 | `/^\s*⏭\|📁 Already in library/` | `skip` |
| 5 | `/^\s*ℹ/` | `warning` |
| 6 | `/^===/` | `header` |
| 7 | `/complete:/` | `summary` |
| 8 | `/\[debug\]/` | `muted` |
| — | otherwise | `''` |

Examples:

| Line | Class |
|---|---|
| `  ✓ Saved: X.flac (31.2 MB)` | `ok` |
| `  ✘ FFmpeg failed: …` | `error` |
| `✗ Preview: x` | `error` |
| `Error: boom` (from `tidal_download.js:721`) | `error` |
| `⚠ Pick a download folder in Settings first.` | `warning` |
| `  ⏭  X.flac already in downloads folder — skipping (use --force to overwrite)` | `skip` |
| `=== Batch complete: 2 downloaded, 0 skipped, 1 failed, 0 not found ===` | `header` (rule 6 wins, so this never gets `summary`) |
| `Album complete: …` (CLI only) | `summary` |
| `  [debug] codec: flac` | `muted` |
| `+ Added 3 tracks from link.` | `''` |
| `⊗ Download cancelled.` | `''` |

Styles:
- `ok`: white, weight 500.
- `error`: `#ff6b6b`.
- `warning`: white.
- `skip`: muted grey.
- `header` and `summary`: bold, with 14px top margin, 10px top padding and a 1px top border.
- `muted`: dim grey.

**`appendLine(line)`** (342-359):
1. Create `div.log-line <class>` and set `textContent` (never parsed as HTML).
2. Append it to `#activity` and always scroll to the bottom.
3. While `#activity.childElementCount > 2000` (`ACTIVITY_LOG_MAX`): if the first child is `welcomeLineEl` and has a next sibling, remove that sibling; otherwise remove the first child.
4. Return the div. Boot keeps the welcome line's div in `welcomeLineEl`.

Other log details:
- Empty strings make empty rows; `appendLine('')` is used before a batch header.
- **Clear** (361) sets `#activity.innerHTML = ''`. That also removes the welcome line and any notices, and leaves `welcomeLineEl` pointing at a detached element.
- Main's output arrives through `api.onDownloadLine(appendLine)` (1456). Main sends `download:line` for:
  - every non-marker, non-empty stdout or stderr line of the batch runner (`electron-main.js:1018`);
  - the FFmpeg-missing warning `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` (542-543);
  - extension messages (519-520, 699-700, 748-749, 796-797; extension support has ended).

**Every message the renderer writes to the log** (verbatim; `${}` marks a value):

| Where | Message |
|---|---|
| Boot, no token file | `👋 Welcome! Click the ⚙ icon to sign in to TIDAL.` |
| Boot, no download folder | `Pick a download folder in Settings to get started.` |
| Boot, ready | `Ready. Downloads go to: ${downloadFolder}` |
| Boot, queue restored | `↺ Restored ${n} track${n===1?'':'s'} from your last session.` |
| Input, no token | `⚠ Sign in to TIDAL first (Settings → Sign in).` |
| Resolve cancelled | `⊗ Resolve cancelled.` |
| Resolve error | `✗ ${error}` |
| Link added | `+ Added ${added} track${s} from link${missing ? ` (${missing} not on TIDAL)` : ''}.` |
| Spotify cap | `⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren't included.` |
| Search added | `+ Added ${added} track${s} from search.` |
| Row retry during batch | `⚠ A batch is already running — retry once it finishes.` |
| No download folder | `⚠ Pick a download folder in Settings first.` |
| Row retry | `↻ Retrying ${title}…` |
| Header retry | `↻ Retrying ${n} track${s}…` |
| Nothing downloadable | `⚠ Nothing in the queue can be downloaded.` |
| Batch start | `''` then `=== Starting batch (${n} tracks) ===` (no singular form) |
| Batch end, non-zero | `=== Exit code ${code} ===` |
| Cancel | `⊗ Download cancelled.` |
| Library folder set | `📁 Music library folder set to: ${folder}` |
| Library folder cleared | `📁 Music library folder cleared (duplicate check disabled).` |
| Library re-scan | `📁 Library re-scanned: ${count} files indexed.` |
| Reset config | `⚙ Config reset. Pick a download folder in Settings to continue.` |
| Import read error | `✗ Couldn't read ${file.name}: ${err.message}` |
| Import parsed nothing | `✗ No tracks found in ${sourceName}.` |
| Import parsed | `📋 Parsed ${n} track${s} from ${sourceName}. Matching against TIDAL…` (`sourceName` is the file name or `pasted text`) |
| Import done | `+ Added ${added} from import. ${matched} matched on TIDAL${missing ? `, ${missing} not found` : ''}.` |
| Preview errors | `✗ Preview playback failed (${code or '?'}).` / `✗ Preview: ${message}` |
| Extension (ended) | `🎵 Spotify ext: added ${added} track${s} (${matched} matched on TIDAL${…}).` |

#### 7. Update UI — `app.js:363-489, 1649-1673`; main `electron-main.js:103-201, 288-469`

**Main side** (the updater mechanics belong to the updater section):
- `getUpdateStatus()`:
  1. `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` with headers `User-Agent: robogears-downloader/<version>` and `Accept: application/vnd.github+json`, and a 10 000 ms timeout. A non-200 response or bad JSON counts as no release.
  2. `isNewerVersion` strips a leading `v`, splits on `.`, `parseInt`s each part (NaN becomes 0) and compares part by part.
  3. Asset selection: the first asset whose name contains `mac-arm64.dmg` (darwin) or `setup.exe` (win32). Otherwise `downloadUrl` is the release's `html_url`.
  4. Returns `{status:'available', version: tag_name, downloadUrl, releaseUrl}`, `{status:'up-to-date', version: app.getVersion()}` or `{status:'error', message:'Could not reach GitHub'}`.
- `update:available {version, downloadUrl, releaseUrl}` is sent once at launch and again on every manual check that finds an update.
- `update:can-self-install` is true only when packaged on darwin or win32.
- `update:download(url)`:
  - Rejects anything that isn't http(s).
  - Follows up to 5 redirects, with a 60 s idle timeout.
  - Writes `<tmp>/robogears-downloader-<ts>.dmg|.exe` and streams `update:download-progress {downloaded, total}`, where `total` is 0 when there is no Content-Length. Events are sent per network chunk, unthrottled.
  - On macOS it mounts the DMG and stages the `.app`.
  - Returns `{ok:true, path}` or `{ok:false, error}`.
- `update:apply` returns `{ok:false, error}` when there is no staged file. Otherwise it spawns the installer or relauncher and calls `app.quit()` after 500 ms.

**Activity-log notice — `insertUpdateNotice({version, downloadUrl})`** (371-433), registered at 435:
1. If `welcomeLineEl` is missing or detached, store `pendingUpdate = {version, downloadUrl}` and stop. Boot replays it once (1991-1994).
2. If the log already contains any `.update-notice`, stop. The version is not compared.
3. Build `div.log-line.update-notice`: a span set through innerHTML, `🚀 New version available: <strong>${version}</strong>` (version not escaped), plus `button.update-download-btn` `Download update`. Insert it directly after the welcome line.
4. `selfInstall = await api.canSelfInstall().catch(() => false)`. Until this resolves the button has no click handler.
5. If self-install is not available, each click calls `api.openExternal(downloadUrl)`.
6. Otherwise a state machine runs, starting at `idle`:
   - **idle → downloading**:
     1. Disable the button and label it `Starting…`.
     2. `await api.downloadUpdate(url)`.
     3. On failure: back to `idle`, enabled, labelled `Download failed — retry`.
     4. On success: `ready`, enabled, class `ready`, labelled `Restart to apply`.
   - **ready → restarting**: disable, label `Restarting…`, call `api.applyUpdate()`. The result is ignored.
   - Other states ignore clicks.
   - A progress listener (added once per notice) updates the label only in `downloading`: `Downloading ${floor(downloaded/total*100)}%`, or `Downloading ${(downloaded/1048576).toFixed(1)} MB` when `total` is 0.

**Topbar pill** (441-489). `_pillUpdateState` is one of `idle | available | downloading | restarting`.
- Every `update:available`: store the URL, set state `available`, show and enable the pill, label `Update now`. This happens even in the middle of a download.
- Click:
  1. Ignore unless the state is `available` and there is a URL.
  2. If `canSelfInstall` is false, call `openExternal(url)` and keep the state `available`.
  3. Otherwise: state `downloading`, disabled, label `Downloading…`.
  4. `await downloadUpdate(url)`.
  5. On failure: `available`, enabled, label `Retry update`.
  6. On success: `restarting`, label `Restarting…` (still disabled), call `applyUpdate()`. The result is ignored.
- Progress listener: only in `downloading`, using the same label format as the notice.
- Style: an enabled pill is white with black 11px bold text and pulses (`brand-update-pulse 2.4s ease-in-out infinite`, a white ring growing 0 to 6px and fading). Disabled: dark, muted, no pulse. Tabular numbers.

**Settings → Updates**:
- Boot sets `#update-status` to `Current version: v${version}` and `#brand-version` to `v${version}` (1953-1958).
- `Check for updates` (1649-1673):
  1. Disable the button; label `Checking…`.
  2. `r = await api.checkForUpdates()`. The label becomes `${r.version} available!` (the GitHub tag, for example `v0.1.31`), `Up to date ✓`, or `Check failed` (also used for exceptions).
  3. After 2500 ms, re-enable and restore `Check for updates`.
  
  A found update also fires `update:available`, which drives both other interfaces.
- Pane text: hint `Checks GitHub for a newer release. If one's found, a download notice appears in the activity log.` and signature `made with love by robogears :)`, pinned to the bottom-left by a flex column.

#### 8. Brand easter egg — `app.js:495-499`

Click on `#brand`:
- If the target is inside `.brand-version`, call `playFart({pitchScale: 7})`.
- Else, if it is inside `.brand-logo` or `.brand-name`, call `playFart()`.
- Clicks on the pill match neither, so no sound plays.

#### 9. Preview volume slider — `app.js:501-524, 1947-1948`

- `settings.volume` stores the slider position, linear 0–1.
- `sliderToAudioVolume(v) = clamp(v,0,1)²`.
- `getPreviewVolume()` uses `settings.volume` when it is a number, otherwise 0.5, and returns the square.
- On `input`:
  1. `settings.volume = slider/100`.
  2. If a preview is playing, set its volume to the squared value live.
  3. Debounce 300 ms, then call `api.saveSettings(settings)`. This writes the whole settings object without awaiting.
- At boot: `volumeSlider.value = Math.round(getPreviewVolume()*100)`. This sets the slider to the squared value, not the stored position (see Bugs).
- The slider is visible only while the queue section is shown.

#### 10. Queue rendering — `renderQueue()` `app.js:885-1022`; `renderBatchProgress()` 1026-1048; `updateRowPercent()` 1052-1059; CSS `styles.css:518-786`

Each call rebuilds the whole list from HTML strings.

**Header:**
1. `#queue-count = queue.length`.
2. `#queue-section.hidden = (queue.length === 0)`.
3. `#queue-list.innerHTML = ''`.

**For each item `t`, in order:**
1. `lm = t.libraryMatch`; `isExact = lm?.kind === 'exact'`; `isSimilar = lm?.kind === 'similar'`.
2. If `t.included === undefined`, set `t.included = !isExact`. This mutation during render is the only place the default is assigned.
3. `excluded = !t.included && !t.notFound`. Not-found rows are never shown as excluded.
4. Row element `div.queue-item`:
   - extra classes ` notfound` (`t.notFound`), ` excluded`, and ` dl-${t.dlStatus}` when a status is set;
   - attributes `data-tidal-id = t.tidalId || ''` and `data-key = t.key`.
5. **Status badge.** The first matching branch wins (913-922):

   | Order | Condition | Badge HTML text |
   |---|---|---|
   | 1 | `dlStatus==='downloading'` | `.badge.dl-running` `↓ ${dlPercent ?? 0}%` |
   | 2 | `'downloaded'` | `.badge.dl-ok` `✓ done` |
   | 3 | `'skipped'` | `.badge.dl-skip` `⏭ skipped` |
   | 4 | `'failed'` | `.badge.dl-fail` `✗ failed` |
   | 5 | `t.notFound` or `dlStatus==='notFound'` | `.badge.bad` (title `Not on TIDAL`) `not found` |
   | 6 | exact library match | `.badge.dupe` (title = escaped `lm.path`) `📁 already in library` |
   | 7 | similar library match | `.badge.similar` (title = path) `⚠ similar version in library` |
   | 8 | `source==='spotify'` | `.badge` `Spotify` |
   | 9 | `source==='import'` | `.badge` `Import` |
   | 10 | `source==='extension'` | `.badge` `Spotify ext` |
   | — | otherwise (for example `source==='tidal'`) | none |

   There is no "queued" badge. A row with `dlStatus==='queued'` falls through to its library or source badge, and the class `dl-queued` has no CSS, so a queued row looks the same as an idle row.
6. Hi-Res badge `.badge.hi-res` `Hi-Res` whenever `t.hiRes`, independent of the status badge.
7. `libNote` when `(isExact || isSimilar) && lm.libraryTitle`: `<div class="qi-libnote">Library: ${escaped libraryTitle}</div>`.
8. `+ Add` button (`.qi-add`, title `Add to download list`) when excluded.
9. `↻ Retry` button (`.qi-retry`, title `Re-download this track`) when `dlStatus==='failed'`.
10. Progress bar `.qi-progress > .qi-progress-fill` (width `${dlPercent ?? 0}%`) when downloading.
11. Checkbox `<span class="qi-check [checked]" role=checkbox aria-checked tabindex=0 title="Select for batch retry">` when `dlStatus==='failed' && tidalId`.
12. Preview play button (`.qi-play`, title `Play preview`, aria-label `Play`) and `<canvas class="qi-waveform empty" height=22 title="Click or drag to scrub">`, only when `PREVIEW_FEATURE_ENABLED && tidalId && !notFound`.
13. Markup order:
    1. checkbox;
    2. play button;
    3. `.qi-info`, containing:
       - `.qi-title-row`: the escaped `.qi-title`, then the waveform;
       - `.qi-artist`: escaped artist, then ` · m:ss` if there is a duration, then a space, the Hi-Res badge and the status badge;
       - libNote;
       - progress bar;
    4. `+ Add`;
    5. `↻ Retry`;
    6. `<button class="qi-remove" aria-label="Remove from queue">✕</button>`.
14. If peaks are cached for the track, repaint the waveform (with playback progress if it is playing) and restore the pause icon (981-996). Preview area.

**After the rows:**
- **Download button** (998-1004):
  - `downloadable = queue.filter(t => !t.notFound && t.included)`;
  - `disabled = isDownloading || downloadable.length === 0`;
  - label `Downloading…` while downloading; otherwise `Download (${downloadable.length})` when the queue is non-empty and `downloadable.length !== queue.length`, else `Download all`.
- **Retry header** (1010-1020):
  - `failed = dlStatus==='failed' && tidalId`;
  - if not downloading and at least 1 failed row is selected: show `↻ Retry selected (${n})`;
  - else if not downloading and at least 2 rows failed: show `↻ Retry all (${n})`;
  - otherwise hide it. A single failed row relies on its own ↻ button.
- `renderBatchProgress()`:
  1. `inFlight = isDownloading ? queue.filter(t => t.included && !t.notFound) : []`.
  2. If it is empty, remove `.batch-progress`.
  3. Otherwise `done` = the number of those with status `downloaded|skipped|failed|notFound`, and `pct = floor(done/len*100)`.
  4. Create `div.batch-progress` (bar + label) before `#queue-list` if missing.
  5. Set the width and the label `${done} / ${len}`.
  
  This only recalculates when `renderQueue` runs (track start or done), not on percent ticks.
- `updateRowPercent(tidalId, pct)`: find the row by `data-tidal-id`; set the `.badge.dl-running` text to `↓ ${pct}%` and the fill width. There is no full re-render.

**Row styles:**
- `.notfound`: opacity 0.55.
- `.excluded`: info at 0.42 opacity with the title struck through; ✕ at 0.42; `+ Add` stays bright (white background, black text).
- `.dl-downloaded`: info 0.65 with the title struck through.
- `.dl-skipped`: info 0.5.
- `.dl-failed`: faint red background.
- `.dl-downloading`: faint white background; the waveform is hidden.
- Badges: uppercase 10px pills. `similar` is amber `#fcd34d`; `dl-ok` is green `#86efac`; `bad` and `dl-fail` are red.
- The title never truncates; the waveform shrinks to 0 instead (`.qi-title-row .qi-title { flex: 0 0 auto; overflow: visible }`).

#### 11. Queue row actions — click delegation on `#queue-list`, `app.js:1061-1125`

Checked in this order:
1. **`.qi-play`**: stop propagation; `togglePreview(Number(dataset.tidalId), row)`.
2. **`.qi-check`**: find the item by key; flip `item.selected`; call `renderQueue()`. Not saved (transient).
3. **`.qi-add`**: `item.included = true`; render; `saveQueueSoon()`. There is no control to exclude the item again.
4. **`.qi-retry`**:
   1. Return if there is no item or no `tidalId`.
   2. If `isDownloading`, log `⚠ A batch is already running — retry once it finishes.` (no sound) and return.
   3. If there is no download folder: `playWarningHonk()`, log `⚠ Pick a download folder in Settings first.` and return.
   4. Set `dlStatus='queued'` and `dlPercent=0`; render.
   5. Log `↻ Retrying ${title}…`.
   6. `setDownloading(true)`.
   7. `api.startBulk({tracks:[item], outDir})`, not awaited, result ignored.
   
   There is no sign-in check and no chime, and `selected` is not cleared.
5. **`.qi-remove`**:
   1. If the item is the one being previewed, call `stopPreview()`.
   2. Remove it by key; render; `saveQueueSoon()`.
   
   This is allowed during a batch, but the running batch still downloads that track.

Waveform mouse handlers on the same list (mousedown, mousemove, capture-phase mouseout, document mousemove/mouseup, and a resize redraw debounced 120 ms; 1133-1222) belong to the preview section.

#### 12. Adding tracks — `addTracksToQueue(tracks)` `app.js:1255-1272`

1. `existing` = the set of `id:${tidalId}` for every queue item, or `na:${title}|${artist}` when it has no `tidalId`.
2. For each incoming track:
   1. Compute the same key. The comparison is exact and case-sensitive.
   2. Skip it if the key is already in the set. This also de-duplicates within the incoming list.
   3. Otherwise push `{...t, key: uniqueKey()}`, count it, and if `tidalId && !notFound`, call `enqueuePreload(tidalId)`.
3. `renderQueue()`, which assigns `included`.
4. `saveQueueSoon()` if anything was added.
5. Return the count added.

Callers:
- link resolve (1308);
- search "Add selected" (1353);
- tracklist import (1849);
- extension (1643, ended).

Boot restore does not go through this function, so restored items are not de-duplicated.

#### 13. Link and search input — `app.js:66, 1276-1325`; main `electron-main.js:658-689`; routing `tidal_lib.js:432-462`

**Hint (display only):**
- `URL_RE = /^https?:\/\/|spotify\.com|tidal\.com/i`; `isUrl(s) = URL_RE.test(s.trim())`.
- On each `input` event, the hint becomes `Detected a link — will resolve all tracks on add.` or `Type to search TIDAL by song name (or paste a link).`
- It is not reset when code clears the field.

**Actual routing (main, `lib.parseInputUrl`):**
- Spotify: `/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i`.
- TIDAL: `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i`.
- A bare all-digits string is a TIDAL **track id**.
- A bare UUID (`8-4-4-4-12` hex) is a TIDAL **playlist id**.
- Anything else is a search.

**`handleInput()`** (1287-1325) runs on an `#add-btn` click, or on `keydown` with `e.key === 'Enter'` in `#url-input` (no modifier check, no in-flight guard):
1. `input = value.trim()`; return if empty.
2. If `!(await api.tokenExists())`, log `⚠ Sign in to TIDAL first (Settings → Sign in).` (no sound) and return.
3. `showLoading(null, {cancellable:true, onCancel: () => api.cancelResolve()})`.
4. `r = await api.resolveInput({input})`; `hideLoading()`.
5. `r.cancelled`: log `⊗ Resolve cancelled.`; the input is kept.
6. `!r.ok`: log `✗ ${r.error}`; the input is kept.
7. `r.kind==='url'`:
   1. `found` = tracks without `notFound`; `missing = total - found`.
   2. `added = addTracksToQueue(r.tracks)`.
   3. Log the "+ Added … from link" line.
   4. If `r.capped`, log the Spotify-cap warning.
   5. Clear the input.
8. `r.kind==='search'`: `openSearchModal(r.tracks, input)`; the input is kept.
9. On an exception: `hideLoading()`; log `✗ ${e.message}`.

**Main `resolve:input`:**
1. `resolverCancelled = false`.
2. `loadCred()` → `getToken()` → `getCountryCode()`.
3. If `parseInputUrl` succeeds:
   1. `resolveUrlToTracks(input, token, country, {isCancelled})`.
   2. If cancelled, return `{ok:false, cancelled:true}`.
   3. Otherwise return `{ok:true, kind:'url', tracks, capped}`.
4. Otherwise: `searchTracksForQueue(input, token, country, 10)` → `{ok:true, kind:'search', tracks}` (or cancelled).
5. Exceptions → `{ok:false, error: message}`.

`resolve:cancel` sets the flag. It is checked only:
- after the TIDAL album or playlist fetch;
- after the Spotify fetch;
- between items in the 8-worker Spotify matching loop.

`capped` is true whenever the Spotify embed returned 100 or more tracks (`tidal_lib.js:549`).

#### 14. Search results modal — `app.js:1329-1357`; `styles.css:800-835`

`openSearchModal(results, query)`:
1. `pendingResults = results`.
2. Title `Search results for "${query}"`.
3. Hint `${n} result${n===1?'':'s'}. Pick the ones to add to your queue.`
4. Clear the list and build one `<label class="search-row">` per result `i`:
   - `<input type=checkbox data-idx=i>`;
   - `.sr-title`: escaped title, plus a `Hi-Res` badge if set;
   - `.sr-meta`: `${artist} · ${album||''} · ${fmtDuration(duration)}`. Both separators are always present.
   
   Clicking anywhere on the row toggles the box. Nothing is pre-checked, and library-match status is not shown here.
5. Open the modal, even with 0 results.

**Add selected:**
1. Collect the checked boxes. If there are none, do nothing and keep the modal open.
2. Map them to `pendingResults[idx]` and call `addTracksToQueue`.
3. Close the modal.
4. Log `+ Added ${added} track${s} from search.`
5. Clear the input.

Cancel and ✕ close the modal and keep the input.

Search result shape: `{tidalId, title, artist, album, duration, hiRes, source:'tidal', matchMethod:'search', libraryMatch?}` (`tidal_lib.js:412-426`).

#### 15. Downloads

**15a. `setDownloading(state)`** (1361-1372):
1. `isDownloading = state`.
2. `#add-btn.disabled = state`; `#clear-queue.disabled = state`.
3. Cancel button: `hidden = !state`, re-enabled, labelled `Cancel`.
4. `renderQueue()`.
5. Then override the Download button: label `Downloading…` or `Download all`, and `disabled = state || queue.length === 0`. This briefly overrides renderQueue's `Download (N)` label and its "0 downloadable" disable until the next render.

Return in the input, import, remove, `+ Add` and checkboxes all stay active during a batch.

**15b. Download all** (1419-1454):
1. Return if downloading or the queue is empty.
2. If there is no download folder: honk, log `⚠ Pick a download folder in Settings first.`, return.
3. If there is no token file: honk, log `⚠ Sign in to TIDAL first (Settings → Sign in).`, return.
4. `downloadable = queue.filter(t => !t.notFound && t.included)`. If it is empty: honk, log `⚠ Nothing in the queue can be downloaded.`, return.
5. `playDownloadChime()`; `setDownloading(true)`.
6. Log `''` and `=== Starting batch (${n} tracks) ===`.
7. Set `dlStatus='queued'` and `dlPercent=0` on each downloadable item. Rows that previously failed are included and retried.
8. `renderQueue()`.
9. `await api.startBulk({tracks: downloadable, outDir})`. The full queue objects are sent and the result is ignored.

**15c. Retry all / Retry selected** (1397-1417):
1. Return if downloading.
2. `failed = dlStatus==='failed' && tidalId`; `targets = selected.length ? selected : failed`. Return if empty.
3. If there is no folder: honk, log `⚠ Pick a download folder in Settings first.`, return.
4. For each target: status `queued`, percent 0, `selected=false`.
5. Chime; `setDownloading(true)`.
6. Log `↻ Retrying ${n} track${s}…`.
7. `await api.startBulk(...)`.

There is no sign-in check. The per-row retry is described in component 11.

**15d. Cancel** (1374-1392):
1. Return if not downloading.
2. `playCancelChime()`; disable the button; label `Cancelling…`.
3. `await api.cancelDownload()`. Main calls `activeChild.kill()` (SIGTERM), sets `activeChild = null` and returns `{ok:true}`, or `{ok:false}` if there is no child. The result is ignored.
4. Every item with status `downloading` or `queued` becomes `failed` with percent 0.
5. Log `⊗ Download cancelled.`; render.

`isDownloading` stays true until `download:done`, which main sends from the runner's `close` event. After a signal kill the exit code is `null`, so the log shows `=== Exit code null ===`.

**15e. Runner protocol and per-track events.** Main `bulk:start` (`electron-main.js:986-1041`):
1. If a child is running, return `{ok:false, error:'Another download is already running.'}`.
2. If there is no `outDir`, return `{ok:false, error:'No download folder configured. Pick one in Settings.'}`.
3. Write `<userData>/pending-tracklist.json` = `{tracks, outDir}` (2-space JSON).
4. Spawn `process.execPath <app>/bulk_runner.js <listPath>` with piped stdio. The environment is the parent's plus `ELECTRON_RUN_AS_NODE=1`, `FORCE_COLOR=0`, `TIDAL_LIBRARY_FOLDER=<settings.libraryFolder or ''>` and `BULK_RUNNER_PROGRESS=1`.
5. Split stdout and stderr on `/\r?\n/`, keeping a partial last line buffered. A final unterminated line is never flushed. For each line:
   - `/^__TRACK_START__:(\d+)$/` → `bulk:track-start {tidalId:Number}`;
   - `/^__TRACK_PROGRESS__:(\d+):(\d+)$/` → `bulk:track-progress {tidalId, percent}`;
   - `/^__TRACK_DONE__:(\d+):(\w+)$/` → `bulk:track-done {tidalId, status}`;
   - any other non-empty line → `download:line`.
6. On `close`: send `download:done {code}`, clear `activeChild`, delete the list file, and resolve the invoke with `{ok: code===0, code}`.

`bulk_runner.js`:
1. `loadCred`, `getToken`, `getCountryCode`. Failure prints `Fatal: …` and exits 1.
2. Print `=== Batch download → ${outDir} ===` and `${n} tracks queued.`
3. For each track:
   1. Print `[i/n] Title — Artist`.
   2. Use `t.tidalId`. If it is missing and title and artist exist, search TIDAL and score the results.
   3. Print `__TRACK_START__:<id>`.
   4. Spawn `tidal_download.js <id> <outDir> --skip-library-check` with **inherited** stdio. Its lines, including `__TRACK_PROGRESS__:<id>:<pct>` (one per integer percent change, `tidal_download.js:434-441`), go straight into main's pipe.
   5. Exit code 0 → `downloaded`, 2 → `skipped`, anything else → `failed`; print `__TRACK_DONE__:<id>:<status>`.
4. Finally print `=== Batch complete: ${ok} downloaded, ${skipped} skipped, ${failed} failed, ${notFound} not found ===` and exit 0, even if every track failed.

The `notFound` done-status cannot be emitted (see Bugs).

Renderer handlers (1225-1245). Each finds the first queue item with `t.tidalId === tidalId` (strict number match) and ignores the event if there is none:
- start: `dlStatus='downloading'`, `dlPercent=0`, full render;
- progress: `dlPercent = percent`, then `updateRowPercent`;
- done: `dlStatus = status`, `dlPercent = status==='downloaded' ? 100 : (dlPercent||0)`, full render.

**15f. Batch end — `onDownloadDone({code})`** (1457-1482):
1. `setDownloading(false)`.
2. If `code === 0`: `playSuccessPing()` and `appendBatchDoneNotice()`. Otherwise log `=== Exit code ${code} ===`.
3. Prune: `queue = queue.filter(t => t.notFound || t.dlStatus==='failed' || t.dlStatus==='notFound' || (!t.dlStatus && t.included))`.
   - Kept: not-found rows, failed rows, and included rows that were not in this batch (for example added during it).
   - Removed: `downloaded`, `skipped`, anything still `queued` or `downloading`, and every excluded row (an exact library match never "+ Add"ed).
4. On kept rows whose status is not `failed`/`notFound`, delete `dlStatus` and `dlPercent`.
5. Render; `saveQueueSoon()`.

**15g. Batch-finished notice — `appendBatchDoneNotice()`** (1486-1501):
1. Create `div.log-line.batch-done-notice` containing `<strong>✓ Batch finished.</strong>`.
2. If a download folder is set, add `button.batch-open-folder-btn` `Open folder`. Its click calls `api.openFolder(settings.downloadFolder)`, reading the folder at click time.
3. Append it directly to `#activity`, skipping `classify` and the 2000-line cap, and scroll down.

The renderer computes no counts; the counts come from the runner's `=== Batch complete … ===` line.

#### 16. Settings modal — `app.js:1505-1589, 1675-1698`; `index.html:109-203`; main `electron-main.js:38-52, 555-587`

**Opening:**
1. The gear runs `await refreshAuthStatus()`.
2. Then `refreshLibraryStatus()` (not awaited).
3. Then `openModal('settings-modal')`.

The last-selected tab is kept between openings.

**Tabs** (1580-1589): a click on a `.modal-tab` gives only that tab the `active` class and shows only the pane whose `data-pane` matches. Choosing `extension` also calls `refreshExtensionInfo()`. There is no arrow-key navigation and no `aria-selected`.

**`updateOpenButtonStates()`** (1512-1515): each `Open` button is disabled while its folder is empty. It is called at boot, after Browse, after Clear and after Reset.

**Folders pane:**
- **Download folder**: readonly `#folder-input`.
  - `Browse…`: `folder = await api.pickFolder()`. Main shows a directory dialog whose `defaultPath` is the saved download folder and returns a path or `null`. If a folder came back: set `settings.downloadFolder`, fill the field, `await api.saveSettings(settings)`, and update the buttons. No log line.
  - `Open` (title `Open folder`) calls `api.openFolder` (main `shell.openPath`; its error string is ignored).
  - Hint `Every download goes here directly — no subfolders.`
- **Music library folder (for duplicate check)**: readonly, placeholder `(none — duplicate check disabled)`.
  - `Browse…`: as above, but sets `libraryFolder` and logs `📁 Music library folder set to: ${folder}`. The dialog still opens at the download folder.
  - `Open`.
  - `Clear`:
    1. `libraryFolder=''`, clear the field.
    2. `await` save; update the buttons.
    3. Log `📁 Music library folder cleared (duplicate check disabled).`
    4. `refreshLibraryStatus()`.
- **Status row**: `#library-status` (initial `…`) and `Refresh`.
  - Refresh:
    1. Label `Scanning…`; disable the button.
    2. `r = await api.libraryRescan()`.
    3. Status `${r.count} files indexed` (no singular form); log `📁 Library re-scanned: ${r.count} files indexed.`
    4. On an exception: `Scan failed`.
    5. Re-enable.
  - Hint `Read-only. The app reads audio-tag metadata (title, artist, duration) as well as filenames. Re-scans automatically on each launch.`
- **`refreshLibraryStatus()`**:
  1. Status `Scanning…`.
  2. `await api.libraryStatus()` (main runs `scanLibrary`, cached for the process lifetime, and returns `{count, path}`).
  3. Status `${count} file${s} indexed` if a path is set, else `(no library folder set)`. On an error: `(scan failed)`.
- **Events**:
  - `library:scanned {count}` sets `${count} file${s} indexed`.
  - `library:scan-progress {done,total}` sets `Scanning ${done} / ${total}…`, or `Scanning…` when the total is 0. The scanner throttles these to about one per 25 files plus the last one.
- **Reset config**:
  1. `confirm('Forget the download folder and music library folder?\n\n(Your TIDAL sign-in stays.)')`.
  2. `settings = await api.resetSettings()`. Main writes exactly `{downloadFolder:'', libraryFolder:''}`, which drops `volume`.
  3. Clear both fields; update the buttons; `refreshLibraryStatus()`.
  4. Log `⚙ Config reset. Pick a download folder in Settings to continue.`
  
  Hint `Forgets your download and library folder choices. TIDAL sign-in is kept.`

**Main `saveSettings(s)`**: writes the whole object to `<userData>/settings.json` (pretty-printed, not atomic). If `s.libraryFolder` is a string that differs from the copy on disk, it calls `lib.setLibraryPath(...)`, starts a background `scanLibrary(sendScanProgress)` and, when that finishes, sends `library:scanned {count}`. `settings:get` returns the parsed file, or `{}` on any error.

**TIDAL pane**:
- Label `TIDAL account`, `#auth-status`, `#auth-btn`.
- Hint `Required once per device. Opens a browser tab where you log in to TIDAL and click Allow.`

**Extension pane**: inventory only; see component 21.

#### 17. TIDAL sign-in — `app.js:1703-1753`; main `electron-main.js:610-642`; flow `tidal_auth_node.js:133-170`

- `refreshAuthStatus()`: `api.tokenExists()` (main checks only `fs.existsSync(TIDAL_TOKEN_PATH || <app dir>/token.json)`).
  - If it exists: status `✓ Signed in` (class `auth-status ok`) and button `Re-authenticate`.
  - Otherwise: `Not signed in` (class `auth-status bad`) and `Sign in to TIDAL`.
- Button click:
  1. Clear the terminal; clear and hide the URL row; set Copy to `Copy`.
  2. Open `#auth-modal`.
  3. `r = await api.runAuth()`.
  4. On success: `await refreshAuthStatus()`, then close the modal after 1200 ms.
  5. On failure: append `\n\n✗ Sign-in failed.` to the terminal. The modal stays open and cannot be closed.
- `auth:output` events append the line (main adds `\n`) and scroll to the bottom. `auth:url` events fill the readonly URL field and show the row.
- Copy:
  1. Ignore the click if the field is empty.
  2. `await navigator.clipboard.writeText(url)`.
  3. If that fails: `select()` + `document.execCommand('copy')` + `blur()`.
  4. Label `Copied ✓` for 1500 ms, then `Copy`.
- Main `token:run-auth` calls `authenticate({onLog, onVerificationUrl, suppressBrowser:true})` in-process. The verification URL is opened with `shell.openExternal` and also sent as `auth:url`. It returns `{ok:true}`, or sends `ERROR: <message>` and returns `{ok:false, error}`.
- The device-code poll loop sleeps `interval` seconds (default 5) between polls and has no client-side timeout. It continues only on HTTP 400 `authorization_pending`. Any other response throws, and that includes a `slow_down` request or an expired code.
- The welcome line in the log is not updated after a successful sign-in.

#### 18. Tracklist import — `app.js:1755-1939`; main `electron-main.js:919-982`

**Entry points:**
- **Drop-zone click** (1763): `fileInput.click()`.
- **Drag highlight** (1765-1770): `dragover`/`dragenter` on the zone call `preventDefault()` and add `.dragover`; `dragleave`/`drop` remove it. Nothing outside the zone calls `preventDefault()`.
- **Drop** (1772-1782):
  1. `preventDefault()`.
  2. Take only `dataTransfer.files[0]`. Dragged text with no file is ignored, and there is no type check.
  3. `await file.text()` (UTF-8 decode, which strips a leading BOM and replaces invalid bytes).
  4. `handleTracklistInput(text, file.name)`.
  5. On an error, log `✗ Couldn't read ${name}: ${message}`.
- **File picker `change`** (1784-1795): the same, then `fileInput.value=''` so the same file can be picked again.
- **Exportify link** (1813-1816): `preventDefault()` then `api.openExternal('https://exportify.net')`. It does not stop propagation, so the zone's click handler also opens the file picker.
- **Paste anywhere** (1800-1808), a document `paste` listener:
  1. Return if `document.activeElement.tagName` is `INPUT` or `TEXTAREA`. That includes readonly fields, checkboxes and the volume range.
  2. `text = clipboardData.getData('text/plain')`.
  3. Return if `text.length < 10`.
  4. Return unless the text contains `\n`, or `,`, or matches `/\s[-—–|]\s/`.
  5. `preventDefault()`; `handleTracklistInput(text, 'pasted text')`.
  
  Examples: `Mr. Brightside - The Killers` is accepted; `Mr. Brightside` is ignored; `a\nb` is ignored (too short). The listener also fires while a modal is open if focus is on a button or the body.

**`handleTracklistInput(text, sourceName)`** (1830-1858):
1. If `_tracklistInFlight`, return silently.
2. `tracks = parseTracklistText(text)`. If empty, log `✗ No tracks found in ${sourceName}.` and return.
3. Log `📋 Parsed …`.
4. `_tracklistInFlight = true`, `_tracklistTotal = n`.
5. `showLoading('Matching 0 / ${n} tracks on TIDAL…')` (no Cancel).
6. `r = await api.resolveTracklist({tracks})`; `hideLoading()`.
7. If `!r.ok`, log `✗ ${error}` and stop.
8. `matched` = items without `notFound`; `added = addTracksToQueue(r.tracks)`; log `+ Added …`.
9. On an exception: hide the overlay and log `✗ ${message}`.
10. `finally`: clear both flags.

There is **no sign-in check** (compare component 13).

Progress listener (1823-1828): while an import is in flight, set the overlay text to `Matching ${done} / ${_tracklistTotal || total} tracks on TIDAL…`.

**`parseTracklistText`** (1862-1868): if `looksLikeCsv(text)` and `parseCsvTracklist` returns at least one track, use those. Otherwise use `parsePlainTextTracklist(text)`.

**`looksLikeCsv`** (1870-1874): the first non-blank line contains `,` AND `text.split(/\r?\n/).length >= 2`. A single line ending in a newline counts as 2 lines.

**`parseCsv`** (1878-1897) is a character-by-character state machine:
- Inside quotes:
  - `""` → a literal `"`;
  - `"` → leave the quotes;
  - everything else is appended, including `,` and newlines.
- Outside quotes:
  - `"` when the field is empty → enter quotes;
  - `,` → end the field;
  - `\r` → dropped anywhere;
  - `\n` → end the field and the row;
  - anything else is appended, including a `"` in the middle of a field and text after a closing quote.
- At the end, if the field is non-empty or the row has cells, push both. A trailing newline does not add a row, but a blank line in the middle gives the row `['']`.
- An unterminated quote swallows the rest of the file into one field.
- The delimiter is always a comma (no semicolon or tab detection).

Examples:
- `a,"b,c",d` → `['a','b,c','d']`;
- `"She said ""hi""",x` → `['She said "hi"','x']`;
- `ab"c,d` → `['ab"c','d']`;
- `"abc"def,g` → `['abcdef','g']`.

**`parseCsvTracklist`** (1899-1919):
1. Fewer than 2 rows → `[]`.
2. The header is lowercased and trimmed.
3. `titleIdx` = the first header matching `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/`.
4. `artistIdx` = the first header containing `artist`.
5. No title column → `[]`.
6. For each data row: trimmed title and artist (artist `''` when there is no artist column). Skip empty titles. De-duplicate by lowercase `title|artist`.
7. Return `{title, artist}` entries.

Examples:
- `Track Name,Artist Name(s)` → 0/1;
- `Artist,Title` → title 1, artist 0;
- `Song,Album` → artist `''` for every row;
- `Artist Name(s),Track Name` → the title column is 0, because `\bname\b` matches `artist name(s)` first, and the artist column is also 0;
- an `Artist URI(s)` column before `Artist Name(s)` would be used as the artist;
- `Album Name` before `Track Name` would be used as the title.

**`parsePlainTextTracklist`** (1923-1939):
1. Split on `/\r?\n/`, trim each line, drop blanks.
2. For each line, apply `/^(.+?)\s*[-—–|\t]\s*(.+)$/`. The separators are hyphen-minus, em dash, en dash, pipe and tab; the spaces around them are optional. A match gives title = group 1 and artist = group 2 (both trimmed). No match gives the whole line as the title and an empty artist.
3. Drop titles shorter than 2 characters.
4. De-duplicate by lowercase `title|artist`.

The order is always "Title - Artist". Examples:
- `Song — Artist`, `Song | Artist` and `Song\tArtist` all split;
- `Jay-Z - Empire State of Mind` → title `Jay`, artist `Z - Empire State of Mind`;
- `7 - Prince` is dropped;
- `1. Song - Artist` → title `1. Song`.

**Main `resolve:tracklist`** (919-982):
1. `loadCred()` → `getToken()` → `getCountryCode()`.
2. Send `tracklist:progress {done:0, total}`.
3. Then for each track, one at a time:
   1. `searchTracks('${title} ${artist}', token, country, 10)`.
   2. Normalise with `s.toLowerCase().replace(/[^a-z0-9 ]/g,' ').replace(/\s+/g,' ').trim()`.
   3. Title score: 100 when equal; 50 when either starts with the other; 25 when either contains the other; else 0.
   4. Artist score: `round(matched / tokens × 100)`, where tokens are the wanted artist's normalised words longer than 2 characters and "matched" means the token occurs as a substring of the joined TIDAL artist names. 0 when there are no tokens.
   5. Keep results with `titleScore===100 || (titleScore>=25 && artistScore>=50)`; sort by the sum, highest first; pick the first.
   6. Push `{title: pick.title || t.title, artist: pick artists joined ', ' || t.artist, duration: pick.duration || 0, tidalId: pick.id || null, source:'import', matchMethod: pick ? 'search' : null, notFound: !pick, originalTitle, originalArtist}`. On a per-track error, push `{title, artist, tidalId:null, source:'import', notFound:true}`.
   7. Send progress `i+1`.
4. `enrichWithLibraryStatus(out)` → `{ok:true, tracks}`.

No `hiRes` flag is set on imported tracks.

#### 19. Boot sequence — `app.js:1-1939` (top level), `1943-1995` (async IIFE)

1. **Synchronous top level, in file order**, registers every listener:
   1. loading Cancel, `data-close`, log Clear;
   2. update notice, pill (update, click, progress), brand;
   3. volume;
   4. queue click and the waveform mouse handlers, resize;
   5. track start, progress and done;
   6. Clear all, Add, input `input` and `keydown`;
   7. Add selected, Cancel, Retry, Download all;
   8. download line and done;
   9. Settings handlers, tabs, extension handlers, check-updates;
   10. library events;
   11. auth handlers and events;
   12. drop zone, file input, paste, Exportify link, tracklist progress.
2. **IIFE**:
   1. `settings = await api.getSettings()`.
   2. Fill both folder fields.
   3. Set the slider from `getPreviewVolume()` (squared, see Bugs).
   4. `updateOpenButtonStates()`.
   5. `await refreshAuthStatus()`.
   6. `api.getAppVersion().then(...)` (not awaited) fills `#brand-version` and `#update-status`.
   7. `await api.tokenExists()` again, then append the welcome line (one of three texts in component 6) and keep it in `welcomeLineEl`.
   8. Restore the queue, with every error swallowed:
      1. `saved = await api.getQueue()`.
      2. If it is a non-empty array, map each item to a shallow copy without transient fields, with a `key` added if missing.
      3. `renderQueue()` (assigns `included`).
      4. Log `↺ Restored …`.
      5. `enqueuePreload` every item with a `tidalId` that isn't `notFound`.
   9. If `pendingUpdate` is set, `insertUpdateNotice(pendingUpdate)` (not awaited) and clear it.
3. **Main start-up order** (`electron-main.js:471-527`):
   1. `setLibraryPath` from settings.
   2. `createWindow()`.
   3. Background `scanLibrary` if a library folder is set (sends progress and `library:scanned`).
   4. `checkForUpdatesAndNotify()`.
   5. `verifyFfmpegAvailable()`.
   6. `ensureExtensionBundle()`.
   7. Extension server start.
   
   None of these wait for the page, so events can arrive before or after the page's listeners exist.

#### 20. Keyboard, menus and focus

- The only explicit shortcut is Return (`e.key === 'Enter'`) in `#url-input`. There is no Escape handling, no ⌘ shortcuts, and no keyboard handler for `.qi-check` (it has `tabindex=0` and `role=checkbox` but Space and Return do nothing). The drop zone is a `div` and cannot be reached with the keyboard.
- Native behaviour still works: buttons activate with Space or Return, and search-row checkboxes toggle with Space.
- Every `renderQueue()` replaces all rows, so a focused row control loses focus on each track start or done.
- Main never calls `Menu.setApplicationMenu`, so Electron's default menu applies (exact items unverified (needs a run)): Edit (Cut, Copy, Paste, Select All), View (Reload, Force Reload, Toggle Developer Tools, zoom), Window, Help. Its Paste is very likely what delivers the document `paste` event for paste-anywhere import when no field has focus (unverified (needs a run)). Reload (⌘R) resets all page state while a download child keeps running.
- Labels in Settings are not linked to their inputs (`<label>` without `for`), and the log has no live region.

#### 21. Areas listed only (owned by other sections)

- **Waveform preview** (`app.js:56-58, 526-881, 1127-1222`):
  - `PREVIEW_FEATURE_ENABLED = true`;
  - `previewState` (peaks cache with no limit; audio blob-URL LRU of 3);
  - `preloader` (concurrency 2);
  - 200-bar peaks.
  
  Touch points here:
  - `renderQueue` repaint (981-996);
  - play click (1063-1070);
  - Remove and Clear call `stopPreview` (1120, 1249);
  - `addTracksToQueue` and boot call `enqueuePreload` (1267, 1984-1986).
  
  Each preload fetches the track's full LOSSLESS audio through `preview:get-audio` only to compute peaks. Peaks are kept in memory only, so every launch re-downloads full audio for every restored queue row.
- **Sound effects** (`app.js:96-270`): triggers only.
  - `playDownloadChime`: Download all (1441) and header Retry (1413). Per-row Retry plays nothing.
  - `playCancelChime`: Cancel (1376).
  - `playWarningHonk`:
    - Download all with no folder, no token, or nothing downloadable (1422, 1427, 1436);
    - row Retry with no folder (1103);
    - header Retry with no folder (1404).
  - `playSuccessPing`: batch exit 0 (1460).
  - `playFart`: brand (497-498).
  - `playClownHorn`: never called.
- **Chrome extension** (support ended 21 Oct 2026; not to be ported):
  - the Settings `Extension` tab (`index.html:162-186`) with Local URL, Token (Copy / Regenerate, confirmed with `Regenerate the extension token?…`) and the managed folder (Copy / Open);
  - `refreshExtensionInfo`, `copyToClipboardField` (`Copied ✓` for 1200 ms), `onExtensionTracks` (1592-1647);
  - the `Spotify ext` badge for `source:'extension'`.
  
  Token values are never shown in this document.

#### 22. Preload bridge — `electron-preload.js:4-66`

`contextBridge.exposeInMainWorld('api', …)`. Each `on…` call adds a listener that is never removed.

| `window.api` method | Channel | Kind |
|---|---|---|
| `getSettings()` / `saveSettings(s)` / `resetSettings()` | `settings:get` / `settings:save` / `settings:reset` | invoke |
| `pickFolder()` | `settings:pick-folder` | invoke |
| `openFolder(p)` | `open-folder` | invoke |
| `openExternal(url)` | `shell:open-external` (http/https only) | invoke |
| `checkForUpdates()` / `getAppVersion()` | `update:check` / `app:version` | invoke |
| `canSelfInstall()` / `downloadUpdate(url)` / `applyUpdate()` | `update:can-self-install` / `update:download` / `update:apply` | invoke |
| `tokenExists()` / `runAuth()` | `token:exists` / `token:run-auth` | invoke |
| `cancelDownload()` / `startBulk(p)` | `download:cancel` / `bulk:start` | invoke |
| `resolveInput(p)` / `cancelResolve()` / `resolveTracklist(p)` | `resolve:input` / `resolve:cancel` / `resolve:tracklist` | invoke |
| `getPreviewAudio(id)` | `preview:get-audio` with `{tidalId}` | invoke |
| `extensionInfo()` / `regenerateExtensionToken()` | `extension:info` / `extension:regenerate-token` | invoke (ended) |
| `getQueue()` / `saveQueue(q)` | `queue:get` / `queue:save` | invoke |
| `libraryStatus()` / `libraryRescan()` | `library:status` / `library:rescan` | invoke |
| `onUpdateAvailable` / `onUpdateDownloadProgress` | `update:available` / `update:download-progress` | event |
| `onAuthOutput` / `onAuthUrl` | `auth:output` / `auth:url` | event |
| `onDownloadLine` / `onDownloadDone` | `download:line` / `download:done` | event |
| `onTrackStart` / `onTrackProgress` / `onTrackDone` | `bulk:track-start` / `bulk:track-progress` / `bulk:track-done` | event |
| `onTracklistProgress` | `tracklist:progress` | event |
| `onExtensionTracks` | `extension:tracks-resolved` | event (ended) |
| `onLibraryScanned` / `onLibraryScanProgress` | `library:scanned` / `library:scan-progress` | event |

### Data formats

**Queue item (in memory)**:

```
{
  key:            string   // ~8 base-36 chars, renderer-assigned row id
  tidalId:        number | null
  title:          string
  artist:         string   // names joined with ', '
  duration:       number   // seconds; 0 or missing allowed
  source:         'tidal' | 'spotify' | 'import' | 'extension'
  matchMethod:    'direct' | 'search' | 'isrc' | null   // 'isrc' only from Spotify ISRC matches
  notFound?:      boolean
  hiRes?:         boolean  // TIDAL tag HIRES_LOSSLESS; never set for imports
  album?:         string   // search results only
  originalTitle?, originalArtist?: string   // import / extension
  libraryMatch?:  { kind: 'exact' | 'similar', path: string, libraryTitle: string }
  included:       boolean  // assigned by renderQueue when undefined: !isExact
  // transient (never saved):
  dlStatus?:      'queued' | 'downloading' | 'downloaded' | 'skipped' | 'failed' | 'notFound'
  dlPercent?:     number   // 0-100
  selected?:      boolean  // failed-row checkbox
}
```

- De-duplication key: `id:${tidalId}`, or `na:${title}|${artist}`.
- DOM actions use `key`; download and preview events use `tidalId`.
- Full objects, transient fields included, are sent to `bulk:start` and written to `pending-tracklist.json`.

**`queue.json`**: `<userData>/queue.json`, which on macOS is `~/Library/Application Support/robogears Downloader/queue.json` (`app.setName('robogears Downloader')`, `electron-main.js:13`).
- Content: a JSON array of queue items without `dlStatus`/`dlPercent`/`selected`, indented 2 spaces.
- `included` and `libraryMatch` are saved and reused as they are on restore.
- A missing or corrupt file reads as `[]`.

**`settings.json`** (same folder): `{ downloadFolder: string, libraryFolder?: string, volume?: number /* slider position 0..1 */ }`.
- The renderer always sends the whole object.
- Reset writes exactly `{downloadFolder:'', libraryFolder:''}`.
- A corrupt file reads as `{}`.

**`pending-tracklist.json`** (same folder): `{ tracks: QueueItem[], outDir: string }`, written per batch and deleted when the runner closes.

**IPC payloads:**

| Channel | Request | Response / payload |
|---|---|---|
| `resolve:input` | `{input}` | `{ok:true, kind:'url', tracks, capped}` \| `{ok:true, kind:'search', tracks}` (at most 10) \| `{ok:false, cancelled:true}` \| `{ok:false, error}` |
| `resolve:tracklist` | `{tracks:[{title, artist}]}` | `{ok:true, tracks: QueueItem[]}` \| `{ok:false, error}` |
| `tracklist:progress` | — | `{done, total}`: 0 first, then once per track |
| `bulk:start` | `{tracks, outDir}` | resolves at runner close with `{ok: code===0, code}`, or early with `{ok:false, error}` |
| `bulk:track-start` / `-progress` / `-done` | — | `{tidalId}` / `{tidalId, percent}` / `{tidalId, status}` |
| `download:line` | — | string |
| `download:done` | — | `{code: number \| null}` |
| `download:cancel` | — | `{ok:true}` \| `{ok:false}` |
| `update:available` | — | `{version: tag_name, downloadUrl, releaseUrl}` |
| `update:check` | — | `{status:'available', version, downloadUrl, releaseUrl}` \| `{status:'up-to-date', version}` \| `{status:'error', message}` |
| `update:download` | url | `{ok:true, path}` \| `{ok:false, error}` |
| `update:download-progress` | — | `{downloaded, total}` (`total` 0 when unknown) |
| `update:apply` | — | `{ok:true}` (quits after 500 ms) \| `{ok:false, error}` |
| `library:status` / `library:rescan` | — | `{count, path}` / `{ok:true, count}` |
| `library:scanned` / `library:scan-progress` | — | `{count}` / `{done, total}` |
| `token:exists` / `token:run-auth` | — | boolean / `{ok:true}` \| `{ok:false, error}` |
| `auth:output` / `auth:url` | — | string ending `\n` / string |
| `settings:pick-folder` | — | path string or `null` |

**Runner stdout markers**, verbatim: `__TRACK_START__:<id>`, `__TRACK_PROGRESS__:<id>:<0-100>` (only when `BULK_RUNNER_PROGRESS=1`), `__TRACK_DONE__:<id>:<downloaded|skipped|failed|notFound>`.

**Accepted import text:**
- (a) CSV with a header row: comma-delimited, double-quote quoting, `""` escapes, title and artist columns chosen as described in component 18.
- (b) One track per line: `Title<sep>Artist` with sep one of `-`, `—`, `–`, `|` or TAB (spaces optional), or a bare title.
- Each import is de-duplicated (lowercase `title|artist`) before it is sent.
- The picker accepts `.csv,.txt,text/csv,text/plain`; drops are not filtered.

### External interfaces

- **IPC to main**: every channel in the table in component 22. This is the page's only way out.
- **Browser open**: `shell.openExternal`, http/https only (`electron-main.js:186-188`). Used for `https://exportify.net`, for the update URL when self-install is unavailable, and by main for the TIDAL verification URL.
- **Finder**: `shell.openPath(path)` for Open buttons and `Open folder`; the error result is ignored.
- **Native folder dialog**: `dialog.showOpenDialog(mainWindow, {properties:['openDirectory'], defaultPath: <saved downloadFolder>})`.
- **Native file dialog**: `<input type=file>`, one file.
- **Clipboard**: writes with `navigator.clipboard.writeText`, falling back to `execCommand('copy')`. Reads happen only through the `paste` event's `text/plain`.
- **`window.confirm`**: Reset config (and extension token regeneration).
- **GitHub Releases API** (through main): see component 7.
- **Child processes** (through main): `bulk_runner.js`, which spawns `tidal_download.js <id> <outDir> --skip-library-check` per track; see component 15e.
- **Files** (through main): `settings.json`, `queue.json`, `pending-tracklist.json` in userData; the token file at `TIDAL_TOKEN_PATH` (packaged: userData `token.json`), checked for existence only.

### Constants and magic values

| Name | Value | Where | Meaning |
|---|---|---|---|
| `ACTIVITY_LOG_MAX` | 2000 | app.js:54 | Log element cap |
| `PREVIEW_FEATURE_ENABLED` | `true` | app.js:58 | Preview controls on rows |
| `URL_RE` | `/^https?:\/\/\|spotify\.com\|tidal\.com/i` | app.js:66 | Hint only |
| `TRANSIENT_QUEUE_FIELDS` | `['dlStatus','dlPercent','selected']` | app.js:71 | Not saved |
| Queue save debounce | 400 ms | app.js:82 | `saveQueueSoon` |
| Volume save debounce | 300 ms | app.js:523 | Settings write |
| Default volume | slider 0.5 (audio 0.25) | app.js:511; index.html:68 | When `settings.volume` is not a number |
| Volume curve | audio = clamp(v,0,1)² | app.js:506-509 | Loudness curve |
| Loading text rotation | 2500 ms | app.js:302 | Random, never the same twice in a row |
| `FUNNY_LOADING` | 10 strings | app.js:271-282 | Listed in component 4 |
| Sign-in modal auto-close | 1200 ms | app.js:1725 | After success |
| Auth Copy feedback | 1500 ms | app.js:1752 | `Copied ✓` |
| Check-for-updates revert | 2500 ms | app.js:1669 | Re-enable and relabel |
| Paste minimum length | 10 chars | app.js:1804 | Gate |
| Paste shape test | contains `\n` or `,` or `/\s[-—–\|]\s/` | app.js:1805 | Gate |
| Plain-text line regex | `/^(.+?)\s*[-—–\|\t]\s*(.+)$/` | app.js:1928 | Title/artist split |
| Plain-text minimum title | 2 chars | app.js:1932 | Shorter is dropped |
| CSV title header | `/\btrack name\b\|\btitle\b\|\bsong\b\|\bname\b/` | app.js:1903 | First match |
| CSV artist header | `/artist/` | app.js:1904 | First match |
| Exportify URL | `https://exportify.net` | app.js:1815 | Drop-zone link |
| Search result limit | 10 | electron-main.js:681, 942 | Per query |
| Import normaliser | `toLowerCase`, `/[^a-z0-9 ]/g`→space, collapse spaces, trim | electron-main.js:944 | Matching |
| Import accept rule | title 100, or title ≥25 and artist ≥50 | electron-main.js:958 | Matching |
| Marker regexes | `/^__TRACK_START__:(\d+)$/`, `/^__TRACK_PROGRESS__:(\d+):(\d+)$/`, `/^__TRACK_DONE__:(\d+):(\w+)$/` | electron-main.js:1006-1016 | Track events |
| Runner exit mapping | 0 downloaded, 2 skipped, else failed | bulk_runner.js:106-109 | Track status |
| Spotify cap flag | `tracks.length >= 100` | tidal_lib.js:549 | Drives the cap warning |
| Update check timeout | 10 000 ms | electron-main.js:125 | GitHub API |
| Update download | 60 000 ms idle, at most 5 redirects | electron-main.js:206-230 | Asset |
| Asset substrings | `mac-arm64.dmg` / `setup.exe` | electron-main.js:153-155 | Asset pick |
| Apply quit delay | 500 ms | electron-main.js:467 | `app.quit()` |
| Window | 980×740, min 720×540, bg `#0a0a0a` | electron-main.js:75-79 | Initial window |
| Overlay / modal z-index | 100 / 50 | styles.css:847, 892 | Stacking |
| Queue max height | 36vh | styles.css:431 | Scrolls inside |

### Rules and invariants

- Only one batch runs at a time. The page blocks Download all, header Retry and row Retry while `isDownloading`, and main refuses `bulk:start` while a child exists.
- Download all requires, in this order: a download folder, an existing token file, and at least one row with `!notFound && included`. Each failure honks and logs. Both kinds of Retry check only the folder. Link and search input checks the token file; tracklist import checks nothing.
- `included` defaults to `!(libraryMatch.kind === 'exact')` and is assigned once. `+ Add` sets it to true for good.
- A row is "excluded" only when `!included && !notFound`.
- A row shows at most one status badge, by the precedence in component 10. The Hi-Res badge is independent.
- Retry checkboxes and the Retry header consider only rows with `dlStatus==='failed'` and a `tidalId`. A selection takes priority over "all failed". The header shows only when not downloading and with ≥1 selected or ≥2 failed.
- Queue de-duplication is exact and case-sensitive. Import de-duplication before sending is case-insensitive.
- Transient fields are never saved and are removed again on restore.
- When a batch ends, only not-found rows, failed rows, and included rows with no status survive; the result is saved.
- Track events match the first row with an equal numeric `tidalId`.
- Only one tracklist import resolves at a time; others are ignored silently.
- Paste import never takes a paste aimed at an `INPUT` or `TEXTAREA`.
- After any `appendLine`, the log holds at most 2000 elements, and the welcome line is never the one trimmed.
- At most one update notice exists in the log, regardless of version. The pill and the notice run separate state machines over the same IPC.
- External URLs must be http(s); `update:download` also rejects anything else.
- The renderer only stores the library folder's path and asks main to scan or open it. It never writes there.
- Settings save immediately on every change; `Done` only closes the modal.

### Edge cases and failure modes

- **Fatal runner error drops the queue.** If `bulk_runner.js` fails before emitting markers, the batch rows are still `queued` when `download:done` arrives with code 1, so the prune removes them and the result is saved. Causes include `getToken` failing (an expired access token and a failed refresh, for example offline or a revoked session), a corrupt token file, or an unreadable list file. The user sees `Fatal: …` and `=== Exit code 1 ===`.
- **Retries prune excluded rows.** Ending a single-row retry also removes every excluded exact-match row.
- **Cancel ordering.** The cancel handler marks rows `failed` only after `await api.cancelDownload()` returns. Main replies right after `kill()`, and `close` comes later, so the marking normally happens first. If `download:done` were handled first, the still-queued rows would be pruned.
- **Cancel only kills `bulk_runner.js`.** The current `tidal_download.js` runs with inherited stdio, is not killed, and may finish saving the file. Node fires `close` only after all stdio pipes close, and the grandchild holds the inherited pipe, so `download:done` (and the end of `Cancelling…`) is expected to wait until the grandchild exits. Unverified (needs a run). The same orphaning is likely when the app quits mid-batch.
- **A signal kill reports code `null`**, so the log shows `=== Exit code null ===` and no success ping plays.
- **Exit 0 does not mean success.** The runner exits 0 even when every track failed, so the success ping and `✓ Batch finished.` appear anyway.
- **Ignored `bulk:start` errors leave the UI stuck.** An early `{ok:false, error}` (child already running, or no `outDir`) is ignored, and the page stays `Downloading…` with rows `queued` until some later `download:done`. This is reachable after a ⌘R reload while a child is running. The old child's eventual `download:done` then prunes the reloaded queue's `queued` rows.
- **Return can start a second resolve.** Return in the input still works under the overlay and during a batch (only the Add button is disabled), so a second `resolveInput` can run alongside the first. Main resets the shared `resolverCancelled` flag, the first to finish hides the overlay for both, and both results are added, de-duplicated by id.
- **URL resolve and import can overlap.** They share the overlay. The later `showLoading` replaces the text and the Cancel handler (an import removes Cancel). Import progress events keep overwriting the text while a URL resolve's random text cycles. Whichever finishes first hides the overlay.
- **The hint and the routing disagree:**
  - `1979`, `22` or `7` shows the search hint but is resolved as a TIDAL **track id**;
  - a bare UUID is resolved as a TIDAL playlist;
  - `https://example.com` shows the link hint but becomes a search;
  - text containing `spotify.com` shows the link hint.
- **Search modal gaps.** A search with 0 results still opens the modal (`0 results. Pick the ones…`). `Add selected` with nothing ticked does nothing, with no feedback. Missing album or duration renders as `Artist ·  · `.
- **Empty link result.** A link that resolves to 0 tracks logs `+ Added 0 tracks from link.` and clears the input.
- **Spotify cap false alarm.** A Spotify playlist of exactly 100 tracks shows the cap warning, because the flag is `>= 100`.
- **Unrecognised CSV header.** If the first line has a comma but no recognised title header, the whole file, header included, goes to the plain-text parser, and each line becomes one title unless it contains a separator.
- **Plain list misread as CSV.** If the first line contains a comma and a word such as `name`, `title` or `song` (for example `What's My Name? - Rihanna, Drake` followed by more lines), the text is parsed as CSV with that line as the header. The first track is lost, and every other line becomes an unsplit title with no artist.
- **CSV column order matters.** The first header containing `artist` wins, so an `Artist URI(s)` or `Artist IDs` column ahead of `Artist Name(s)` sends Spotify identifiers as artists. `Artist Name(s)` ahead of `Track Name` also becomes the title column.
- **Plain-text hyphens.** Lines split at the first hyphen, dash or pipe even without spaces (`Jay-Z - Song` → `Jay`). One-character titles are dropped. "Artist - Title" lines are imported swapped.
- **Single-line comma paste.** `Title, Artist` passes the paste gate (comma), but it is one line, so it becomes `{title:'Title, Artist', artist:''}`.
- **Non-Latin titles.** A title made only of non-Latin letters normalises to `''`. Any TIDAL result whose title also normalises to `''` then scores an exact 100 and is accepted, so the first such result wins even if it is a different song. Latin results score 50 through `startsWith('')` and are accepted if the artist tokens match.
- **Drops.** Only the first dropped file is used; a non-text file is decoded as UTF-8 garbage or yields `No tracks found`. Drops outside the drop zone, including onto the loading overlay (which covers the zone) or a modal, have no `preventDefault`, and main has no `will-navigate` guard. Chromium's default would navigate the window to the dropped file and replace the app UI. Unverified (needs a run).
- **Exportify link.** Clicking it opens exportify.net **and** the file picker.
- **Update notice after Clear.** Clearing the log detaches the welcome line, so later `update:available` events are stored in `pendingUpdate` and never shown in the log (the replay runs only at boot). Only the pill reacts.
- **Trimming hits the notice first.** After 2000+ lines with the welcome line at the top, the update notice (just after the welcome line) is the first element removed.
- **Pill reset mid-download.** A manual Check for updates during a pill download resets the pill to `Update now`, enabled. The original click still continues to `Restarting…` when its download finishes.
- **Two update downloads at once.** Both UIs can download simultaneously. Main keeps only the last finished file in `global._pendingUpdatePath`, and both labels render all progress events.
- **No platform asset.** If the release has no matching asset, `downloadUrl` is the release HTML page. On macOS self-install, that HTML is saved as `.dmg` and `hdiutil` fails, so the labels show `Download failed — retry` / `Retry update`.
- **Failed apply.** `update:apply` returning `{ok:false}` leaves the button or pill disabled on `Restarting…`.
- **Stuck sign-in modal.** If sign-in fails, the code expires, or TIDAL answers anything except `authorization_pending`, the sign-in modal stays open with no way to close it. While polling, it cannot be cancelled at all.
- **Library label races.** After Clear, `(no library folder set)` from `refreshLibraryStatus` races the `library:scanned {count:0}` event (`0 files indexed`); the final label depends on arrival order. Refresh writes `${count} files indexed` (no singular form) after the singular-aware event label. Refresh with no folder set shows `0 files indexed`.
- **Library status is frozen at add time.** `libraryMatch` is computed in main when a track is resolved and saved with it. Changing or rescanning the library never updates existing rows' badges or default inclusion.
- **Reset side effects.** Reset drops the saved volume, and the slider is not updated until the next launch. The library `Browse…` dialog starts in the download folder.
- **Remove during a batch.** Removing a row mid-batch doesn't remove it from the batch. Its later events find no row and are ignored, and the file still downloads.
- **Scrub across a re-render.** During a batch, each track start or done replaces every canvas. A scrub in progress keeps the old, detached canvas, whose width is 0, so further drags compute ±Infinity, clamp to 1 or 0, and seek to the end (which ends and stops the preview) or the start. `NaN` (which would throw) occurs only when the cursor x equals the old left edge exactly.
- **Window closed mid-batch (macOS).** Closing the window kills the runner but keeps the app running, and `activate` opens a fresh page. A queue save still inside its 400 ms window is lost. In `bulk:start`, main's line and close handlers call `mainWindow.webContents.send` without an `isDestroyed()` check, so an event arriving after the window closed may throw in main. Unverified (needs a run).
- **Early events may be lost.** Events main sends before the page's listeners exist (for example the FFmpeg warning, which fires right after `createWindow`) may be dropped. Unverified (needs a run). `pendingUpdate` only covers the case where the listener exists but the welcome line does not yet.
- **Paste with a modal open.** Paste import fires while a modal is open if focus is on a button. It does not fire when any `INPUT`, including the readonly folder fields, the search checkboxes or the volume range, has focus.
- **Early click on the notice.** Clicking the activity-log update button before `canSelfInstall` resolves does nothing.
- **Unflushed final line.** A final runner output line without a trailing newline is never shown, because main does not flush its buffer on close.

### Bugs and oddities

Most severe first. Severity uses the owner's scale: losing data the person expects to keep is at least Medium.

1. **High: a fatal runner error deletes every queued row and saves the deletion.**
   - Evidence: the prune at `renderer/app.js:1468-1473` keeps only `notFound`, `failed`, or `(!dlStatus && included)`. `bulk_runner.js:56-58, 115-118` exits 1 before any marker when `getToken`/`getCountryCode`/`loadCred` fails. `app.js:1481` then saves.
   - Scenario: an access token that has expired and cannot be refreshed (offline, or session revoked), then Download all with 500 imported rows. The rows vanish from the queue and from `queue.json`; the only trace is `Fatal: …` and `=== Exit code 1 ===`.
2. **High: tracklist import, and launch-time preview preloading, call `process.exit(1)` in the Electron main process when the token file is missing.**
   - Evidence: `handleTracklistInput` (`app.js:1830-1843`) has no `tokenExists` check, unlike `app.js:1290` and `1426`. `resolve:tracklist` (`electron-main.js:925`) and `preview:get-audio` (`electron-main.js:875`) call `lib.loadCred()`, which runs `process.exit(1)` when the file is absent or empty (`tidal_lib.js:48-58`). The exit is not an exception, so the surrounding `try` cannot catch it. Boot preloads restored rows at `app.js:1984-1986`.
   - Scenario: on first launch, the user drops an Exportify CSV before signing in. The main process ends and the app closes with no message. The exact visible effect is unverified (needs a run).
3. **Medium: the sign-in modal cannot be dismissed.**
   - Evidence: `#auth-modal` (`index.html:206-220`) has no `data-close` control; there are no Escape or backdrop handlers (`app.js:322-326`); the modal closes only after success (`app.js:1723-1728`).
   - Scenario: TIDAL returns an error, or the user gives up. `✗ Sign-in failed.` appears, and the full-window modal blocks everything until ⌘R or quitting. No data is lost.
4. **Medium: the volume slider is restored with the squared value, so the volume ratchets down.**
   - Evidence: `app.js:1948` sets `volumeSlider.value = Math.round(getPreviewVolume()*100)`, and `getPreviewVolume()` returns v² (`app.js:510-513`).
   - Scenario: the saved volume is 0.5, so the slider shows 25 while audio plays at 0.25. Touching the slider saves about 0.25, which plays at 0.0625. The comment `defaults to 60%` (`app.js:1947`) is also wrong; the default is 0.5.
5. **Medium: excluded rows are removed at the end of every batch, including a single-row retry.**
   - Evidence: `(!t.dlStatus && t.included)` is false for excluded rows (`app.js:1468-1473`). The comment above the filter speaks only of dropping downloaded and skipped tracks.
   - Scenario: a playlist with 20 "already in library" rows; the user downloads the rest. All 20 disappear without being "+ Add"ed.
6. **Medium: the plain-text separator does not require spaces.**
   - Evidence: `app.js:1928` uses `/^(.+?)\s*[-—–|\t]\s*(.+)$/`, while the comment (`app.js:1921-1922`) and the paste gate (`app.js:1805`) assume spaced separators.
   - Scenario: `Re-Wired - Kasabian` is imported as title `Re`, artist `Wired - Kasabian`. The match then fails or picks the wrong track.
7. **Medium: non-Latin titles score as exact matches during import.**
   - Evidence: the normaliser `/[^a-z0-9 ]/g` (`electron-main.js:944`) turns an all-Cyrillic, Japanese or Korean title into `''`. `itT === wantT` then gives 100 for any non-Latin result (`electron-main.js:951`), and the result is accepted (`958`).
   - Scenario: importing a Japanese song title picks the first non-Latin-titled search result, which can be a different song by the same artist.
8. **Medium (if confirmed): a file dropped outside the drop zone probably navigates the window away from the app.**
   - Evidence: only `#drop-zone` calls `preventDefault` on `dragover`/`drop` (`app.js:1765-1782`). The loading overlay covers the zone while it is up. `electron-main.js` has no `will-navigate` handler.
   - Unverified (needs a run).
9. **Low: Exportify link also opens the file picker.**
   - Evidence: `app.js:1813-1816` calls `preventDefault` but not `stopPropagation`, and the link sits inside `#drop-zone`, whose click runs `fileInput.click()` (`app.js:1763`; `index.html:43-53`).
10. **Low: numeric or UUID search text is treated as a TIDAL id.**
    - Evidence: `tidal_lib.js:437-444` maps `^\d+$` to a track and a UUID to a playlist before falling back to search. The hint says `Type to search TIDAL by song name`.
    - Scenario: searching `1979` resolves TIDAL track id 1979, either a random track added straight to the queue or an error.
11. **Low: `startBulk` early errors are ignored, so the UI sticks on `Downloading…`.**
    - Evidence: `app.js:1112, 1416, 1453` ignore the result; `electron-main.js:987-988` can return without a child.
12. **Low: a failed `applyUpdate` is ignored.**
    - Evidence: `app.js:420, 476` ignore `{ok:false}` from `electron-main.js:315-319, 462`. The button or pill stays disabled on `Restarting…`.
13. **Low: repeated `update:available` resets the pill mid-download.**
    - Evidence: `app.js:444-450` sets `available` unconditionally. A second click can start a second download.
14. **Low: the two update UIs can download at once and share one pending path.**
    - Evidence: `app.js:400-432, 452-489`; `electron-main.js:302, 305`.
15. **Low: the update notice is lost after Clear, and its de-duplication ignores the version.**
    - Evidence: `app.js:361, 372-377, 1991-1994`.
16. **Low: log trimming removes the update notice first.**
    - Evidence: `app.js:352-353` removes the welcome line's next sibling, which is where `app.js:388` inserted the notice. The comment says the rule keeps the insertion anchor (the welcome line) alive; it does nothing to protect the notice.
17. **Low: the batch progress denominator counts every included row, not the batch.**
    - Evidence: `app.js:1028-1038`.
    - Scenario: retrying 1 of 5 failed rows shows `4 / 5` straight away.
18. **Low: success ping and `✓ Batch finished.` on exit 0 even when every track failed.**
    - Evidence: `app.js:1459-1461`; `bulk_runner.js:114-118`.
19. **Low: Cancel does not stop the in-flight `tidal_download.js`.**
    - Evidence: `electron-main.js:646-653` kills only the runner; `bulk_runner.js:41-44` spawns with `stdio:'inherit'`.
    - The delayed `download:done` and the file still being saved are unverified (needs a run).
20. **Low: there is no in-flight guard on link or search input.**
    - Evidence: `app.js:1285, 1287-1298, 1363`. Concurrent resolves share main's single `resolverCancelled` flag (`electron-main.js:659, 689`).
21. **Low: the input hint is stale and differs from the routing.**
    - Evidence: `app.js:1316, 1356` clear the field without an `input` event; `URL_RE` (`app.js:66`) differs from `parseInputUrl` (`tidal_lib.js:432-462`).
22. **Low: keyboard gaps.**
    - `.qi-check` has `role=checkbox tabindex=0` but no key handler (`app.js:946, 1072-1081`).
    - The drop zone is not focusable (`index.html:43`).
    - No modal closes with Escape (`app.js:322-326`).
    - Every re-render drops focus (`app.js:893`).
23. **Low: library status labels race, and one lacks the singular.**
    - Evidence: `app.js:1546-1567, 1675-1698`; `electron-main.js:45-51, 585`.
24. **Low: the unescaped GitHub tag goes into `innerHTML` under a CSP that allows inline script.**
    - Evidence: `app.js:382`; `index.html:5`. Tag names are controlled by the repo owner.
25. **Low: Remove is allowed during a batch.**
    - Evidence: `app.js:1115-1124`. The download still happens, and its events are ignored.
26. **Low: persistence failures are silent and the writes are not atomic.**
    - Evidence: `app.js:81` swallows `saveQueue` errors; volume saves are fire-and-forget (`app.js:523`).
    - `settings:save` throws on a write error (`electron-main.js:44, 556`). In the Browse/Clear handlers that becomes an unhandled rejection after the UI has already changed (`app.js:1522, 1536, 1549`).
    - Both files use `writeFileSync` with no temp-file-then-rename (`electron-main.js:44, 601`).
27. **Low: a scrub across a re-render jumps to the end or the start.**
    - Evidence: `app.js:1133-1142, 1184-1187`, with re-renders at `app.js:1230, 1244`. Preview area.
28. **Low: main sends to a possibly destroyed window when a batch ends after the window closed.**
    - Evidence: `electron-main.js:548-551, 1004-1019, 1035`. The effect is unverified (needs a run).
29. **Low: the Spotify cap warning shows for exactly-100-track playlists.**
    - Evidence: `tidal_lib.js:549` (`>= 100`); `app.js:1313-1315`.
30. **Low: a plain list whose first line contains a comma and a header-like word is parsed as CSV.**
    - Evidence: `app.js:1863-1874, 1903`.
31. **Low: queued rows look the same as idle rows.**
    - Evidence: there is no `queued` branch in `app.js:913-922`, and there is no `.dl-queued` rule in `styles.css`.
32. **Info: the `summary` class never applies to the GUI batch summary.**
    - Evidence: `app.js:336-337`; `bulk_runner.js:114` (header wins).
33. **Info: the `skip` pattern `📁 Already in library` never matches the real `📁 Already in music library: …`.**
    - Evidence: `app.js:334`; `tidal_download.js:374`. GUI batches pass `--skip-library-check` anyway.
34. **Info: the `notFound` track status is unreachable.**
    - Evidence: `bulk_runner.js:70, 92-97` print it only `if (t.tidalId)`, inside a branch reached only when the id is falsy. So `app.js:917, 1037, 1471, 1475` handle a status that never arrives.
35. **Info: per-row Retry and header Retry behave differently.**
    - Per-row: no chime, `selected` not cleared, not awaited.
    - Header: chime, clears the selection.
    - Neither checks sign-in.
    - Evidence: `app.js:1093-1114` vs `1397-1417`.
36. **Info: `libraryMatch` is never refreshed after a library change.**
    - Evidence: `app.js:895-901`; nothing re-enriches the queue.
37. **Info: Reset drops `volume`, and library Browse opens at the download folder.**
    - Evidence: `electron-main.js:561-573`.
38. **Info: `setDownloading` overrides renderQueue's Download label until the next render.**
    - Evidence: `app.js:1369-1371` vs `998-1004`.
39. **Info: imported tracks never get a Hi-Res badge.**
    - Evidence: `electron-main.js:961-971`, unlike `737`, `tidal_lib.js:328, 385, 420`.
40. **Info: messages without singular forms.**
    - `=== Starting batch (1 tracks) ===` (`app.js:1444`).
    - `+ Added N from import.` has no noun (`app.js:1850`).
41. **Info: dead code.**
    - `searchDebounce` is never used (`app.js:64`).
    - `playClownHorn` is never called (`app.js:194`).
    - `revertText` always equals `originalText` (`app.js:1651-1653`).
    - The comment "we mirror it into dlStatus" (`app.js:888-889`) describes code that does not exist.
42. **Info: stale comments.**
    - "screenshot OCR" (`app.js:2`; `electron-main.js:984`; `bulk_runner.js:1-5`).
    - "Windows portable" self-install (`app.js:390-391`; `electron-preload.js:18-19`; `electron-main.js:191-193`).
    - The overlay "Used during URL resolution" only (`index.html:222-223`); imports use it too.
43. **Info: the topbar drag region is probably inert.**
    - Evidence: `styles.css:49` sets `-webkit-app-region: drag`, but the window keeps the standard frame (`electron-main.js:73-88`). Unverified (needs a run).
44. **Info: the preview preloader downloads every queued track's full lossless audio on each add and on every launch, just to draw peaks.**
    - Evidence: `app.js:692-700, 730-767, 1267, 1984-1986`; `electron-main.js:873-917`. Owned by the preview section.

### Platform-specific behaviour

- **Electron default menu** (no `Menu.setApplicationMenu`): ⌘R reload, DevTools and the Edit menu. The Edit menu's Paste very likely delivers the `paste` events that paste-anywhere import uses. A reload mid-batch resets page state while the runner continues.
- **`autoHideMenuBar: true`** only affects Windows and Linux.
- **`-webkit-app-region`** on the topbar is a Chromium window-drag mechanism (`styles.css:49-65, 88`).
- **macOS window lifecycle:** `window-all-closed` kills the runner and does not quit on darwin. `activate` recreates the window, which boots a fresh page (`electron-main.js:524-526, 548-551`).
- **Self-install** is available only when packaged on darwin (DMG → staged `.app` → bash relauncher) or win32 (NSIS `/S --updated`). In dev or on Linux, both update UIs open the URL in the browser instead. Assets are picked by `mac-arm64.dmg` / `setup.exe`.
- **userData** is `~/Library/Application Support/robogears Downloader/` on macOS and `%APPDATA%\robogears Downloader\` on Windows. It holds `settings.json`, `queue.json`, `pending-tracklist.json`, and in packaged builds `token.json`.
- **Fonts:** the stack prefers `-apple-system`/BlinkMacSystemFont, then Segoe UI on Windows.
- **Browser APIs:** `File.text()` is the WHATWG UTF-8 decode (strips a leading BOM, replaces invalid bytes). The clipboard uses `navigator.clipboard` with an `execCommand('copy')` fallback. Sound and preview decoding use Web Audio, and playback uses `HTMLAudioElement` on blob URLs.

### Porting notes for a native Swift macOS app

| Topic | Today | Swift needs | Difficulty |
|---|---|---|---|
| State and ordering | Module globals, mutated by IPC callbacks on one JS thread | One `@MainActor` observable store (queue, settings, isDownloading, log, update state). Cancel must mark rows before any batch-end pruning, or the pruning rule must change | Easy |
| Queue model and list | Full `innerHTML` rebuild per change; identity by `key` and `tidalId` | `Identifiable` rows keyed by `key` (keep accepting old 8-character keys), a `List`/`Table` with derived badge precedence, excluded styling, + Add, Retry, checkbox and progress. Per-row progress updates without reloading the list or losing focus | Medium |
| Persistence | `writeFileSync` JSON, not atomic; queue save debounced 400 ms, volume 300 ms | `Codable` with every field optional so existing `queue.json`/`settings.json` decode (including `source:'extension'`, missing `included`/`key`/`hiRes`). Atomic writes (`Data.write(options: .atomic)`). Debounce with a cancellable `Task`. Flush on quit. Decide whether to read the existing files in `~/Library/Application Support/robogears Downloader/` | Medium |
| Pruning rule | Keeps notFound, failed, and included-without-status rows; drops everything else, including queued and excluded rows | Re-specify. At minimum keep rows that never reached a terminal state, and decide whether excluded rows survive | Easy (decision) |
| Activity log | DOM rows with regex classes, 2000 cap, welcome-line protection, two rows with buttons | An array of entries `{text, kind, action?}` capped at 2000, scroll to bottom on append. Port `classify` precedence exactly, or replace the string matching with typed events from the native downloader | Easy |
| Regex and string semantics | JS `\b` is ASCII-only; JS `\s` and `trim()` include U+FEFF; lazy `(.+?)`; `split(/\r?\n/)` | `NSRegularExpression`, or Swift `Regex` with `.wordBoundaryKind(.simple)`. Add U+FEFF to the trim set (Foundation's whitespace set excludes it). Keep CRLF handling. Decide whether to keep or fix the unspaced-separator split | Medium |
| Import (file, drop, picker) | HTML5 drop on a `div`; `<input type=file>`; `File.text()` | A drop destination on the zone; `.fileImporter`/`NSOpenPanel` for `.commaSeparatedText` and `.plainText`; lossy UTF-8 decode plus explicit leading-BOM removal. Native drops don't navigate, so that hazard disappears | Easy |
| Paste-anywhere | Document `paste` listener, skipped when an input has focus, gated on length ≥10 and list-like shape | Handle the Paste command (`.onPasteCommand`/`pasteDestination`, or an AppKit `paste(_:)` in the responder chain) only when no text field is first responder; read `NSPasteboard` text; apply the same gate | Medium |
| Sign-in gating | Link input and Download all check the token file; import and retries don't; main can `process.exit` | A single "signed in?" check before every TIDAL call, including import, retry and preview, with a typed error instead of exiting | Easy |
| Loading overlay | Fixed blurred `div`, 2500 ms text rotation, Cancel calls a shared flag | A sheet or overlay on a system material; rotation in a `Task` loop; Cancel through `Task` cancellation; block input while shown; one in-flight resolve at a time | Easy |
| Modals | Shown/hidden `div`s, no Escape, sign-in cannot be dismissed | Sheets: a search sheet with checkboxes, and a sign-in sheet with streamed text, URL field, Copy and a Cancel that stops the poll. A Settings scene with tabs (⌘,) | Easy |
| Batch runner | Node child per batch, grandchild per track, stdout markers, exit codes, `kill()` on the child only | An in-process async loop emitting typed start, progress and done events per track id; cooperative cancellation that stops the current track; per-track result types instead of exit codes; a batch result that tells "all failed" apart from success | Medium |
| Update UI | Two state machines (log notice, pill) over shared IPC | One observable update state (idle, available, downloading %, ready, applying, failed) shown on one or both surfaces; handle apply failure; ignore repeated "available" while busy. Install mechanics belong to the updater section | Medium |
| Folder picking | `showOpenDialog` with plain paths stored | `NSOpenPanel` (directories); open at the folder being edited; store security-scoped bookmarks if the app is ever sandboxed | Medium |
| Open / external | `shell.openPath`, `shell.openExternal` (http/https only) | `NSWorkspace.shared.open(_:)` / `activateFileViewerSelecting`; keep the http(s)-only rule | Easy |
| Clipboard and confirm | `navigator.clipboard`, `window.confirm` | `NSPasteboard.general`; `.confirmationDialog`/`NSAlert` with the same text | Easy |
| Keyboard and menus | Return in the field only; Electron default menu | A real menu bar: Add/Resolve (Return), Download All, Cancel, Retry, Clear Queue, Paste tracklist (⌘V), Settings (⌘,), Open Download Folder; native checkboxes in failed rows; VoiceOver labels; no Reload equivalent | Easy |
| Sounds | Web Audio synthesis | `AVAudioEngine` or bundled short audio files at the trigger points in component 21 (sound section) | Medium |
| Waveform preview | Canvas, `decodeAudioData`, `<audio>` on blob URLs | Preview section. Avoid downloading full lossless audio just to draw peaks on every launch | Hard |
| Window | 980×740 framed window, CSS drag regions | `WindowGroup` with a minimum of 720×540 and the standard title bar | Easy |
| HTML escaping | `escapeHtml` for `innerHTML` templates | Not needed: native text views don't interpret markup | Easy |

### Open questions

1. What is the current Exportify CSV column order? If `Artist URI(s)` comes before `Artist Name(s)`, today's importer sends Spotify URIs as the artist. This cannot be checked offline.
2. Should excluded rows (exact library matches the user hasn't "+ Add"ed) survive the end of a batch? Today every batch end removes them, including a single-row retry.
3. Should rows still queued when a batch dies (non-zero exit before or during processing) be kept? Today they are removed and the removal is saved.
4. Does dropping a CSV while signed out actually close the app (`process.exit(1)` in main)? Unverified (needs a run).
5. After Cancel, does `tidal_download.js` keep running and finish the file, and does that delay `download:done`? Unverified (needs a run).
6. Does a file dropped outside the drop zone navigate the window away from the app? Unverified (needs a run).
7. Are main → page events sent before the page's listeners exist (for example the FFmpeg warning) dropped? Unverified (needs a run).
8. Keep both update surfaces (log notice with two clicks, topbar pill with one), or only one?
9. Should the Swift app read the existing `queue.json` and `settings.json`? Old queues can contain `source:'extension'` rows (`Spotify ext` badge) even though extension support has ended.
10. What is the intended default preview volume? The code uses slider 0.5 (audio 0.25), but a comment says 60%.
11. Should retries (row and header) require sign-in like Download all? Should Download all keep re-sending previously failed rows?
12. Should all-digit or UUID text in the input be searched as text rather than treated as a TIDAL id?
13. Should the easter eggs (brand-click sounds) and the unused clown horn carry over?
14. Should imported tracks get the Hi-Res flag, as link and search tracks do?
15. Is the topbar drag region effective on today's framed window? This only matters for reproducing the current feel. Unverified (needs a run).
