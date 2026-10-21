## Visual design, layout, copy and interaction spec

Scope: `renderer/index.html` (235 lines), `renderer/styles.css` (1076 lines), the parts of `renderer/app.js` (1995 lines) that draw or react to the UI, the window options in `electron-main.js`, and the brand art in `build/icon.svg` and `build/dmg-background.svg`. The code is v0.1.30, running on Electron 33.4.11 (Chromium 130) per `package-lock.json:1860`. Line numbers refer to those files.

### Overview

The app is one dark page with no light mode. The palette is black and white only. The canvas is `#000000`, raised surfaces are `#0a0a0a` and `#0d0d0d`, primary text and primary buttons are white, and secondary text is `#9a9a9a` or `#5a5a5a`. Only three colours appear: red `#ff6b6b` for errors, failures, Cancel and "not found"; amber `#fcd34d` for "similar version in library"; and green `#86efac` for "done". The typeface is the system font (SF Pro on macOS). The activity log, the sign-in terminal and the library note use the system monospace font (SF Mono).

The window has a standard native frame (on macOS: a normal title bar with traffic lights) above an HTML topbar. The topbar holds a vinyl logo, the product name, the version, a pulsing "Update now" pill and a Settings gear. Below it is one column with a 28 px side margin. From top to bottom it contains: a link/search field with a white "Add to queue" button; a dashed drop zone for CSV/text tracklists; the queue panel (hidden when the queue is empty, at most 36 % of the window height); and a monospace activity log that takes the remaining height. Four overlays share one look: Search results, Settings (tabs: Folders, TIDAL, Extension, Updates), TIDAL sign-in, and a full-window blurred loading screen. The Extension tab is not part of the Swift port.

Interaction is mouse-first. The only keyboard shortcut is Enter in the link field. There is no Escape to close, no focus management and no reduced-motion handling. Each queue row has a circular play button and a 200-bar waveform. Clicking the waveform starts that track at the clicked point. Holding and dragging on the current track's waveform scrubs it. Short sounds made with Web Audio confirm a download start, a cancel, a blocked action and a finished batch. Clicking the logo plays a joke sound.

---

### Components

#### 1. Main window — `electron-main.js:73-99`, `renderer/index.html:1-9`

- Created with `new BrowserWindow({ width: 980, height: 740, minWidth: 720, minHeight: 540, backgroundColor: '#0a0a0a', title: 'robogears Downloader', webPreferences: { preload: electron-preload.js, contextIsolation: true, nodeIntegration: false, sandbox: false }, autoHideMenuBar: true })`. Only in dev builds (`!app.isPackaged`) is `icon` set to `build/icon.png`.
- No `frame`, `titleBarStyle`, `vibrancy` or `useContentSize` option is set. macOS therefore draws a standard title bar, and 980×740 is the outer window size. No `Menu` is built anywhere, so macOS shows Electron's default menu. That menu includes View → Reload / Force Reload / Toggle Developer Tools and the standard Edit menu.
- There is no `will-navigate` handler and no `setWindowOpenHandler`.
- The document `<title>` is `robogears Downloader` (index.html:6). The CSP meta tag (index.html:5) reads, verbatim: `default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;`
- The window's pre-paint colour (`#0a0a0a`) differs from the body background (`#000000`, styles.css:30).

#### 2. Base page styles — `renderer/styles.css:1-40`

- `:root` tokens: see "Data formats → CSS custom properties". Root `font-size: 14px`. `* { box-sizing: border-box }`.
- `html, body`: margin 0, padding 0, height 100 %, background `var(--bg)`, colour `var(--text)`, `font-family: -apple-system, BlinkMacSystemFont, "Segoe UI Variable Display", "Segoe UI", "Inter", system-ui, sans-serif`, weight 400, `-webkit-font-smoothing: antialiased`, `-moz-osx-font-smoothing: grayscale`, **`user-select: none`**, **`overflow: hidden`** (the page never scrolls; only inner panes do).
- `input, textarea { user-select: text }` (styles.css:40). Text can be selected only inside inputs.
- Monospace stack `ui-monospace, "SF Mono", "Cascadia Mono", Consolas, monospace` is used by the activity log (337), terminal (1058), modal `code` (944), the unused `textarea` (198) and the unused password input (1023). `.qi-libnote` uses `ui-monospace, "SF Mono", Consolas, monospace` (676). The auth URL field uses `var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace)` (1012). `--font-mono` is never defined, so the fallback list applies.

#### 3. Topbar — `index.html:10-31`, `styles.css:43-81, 119-133`, `app.js:1505-1509, 1953-1958`

- `<header class="topbar">`: flex, `justify-content: space-between`, `align-items: center`, padding `16px 28px`, background `#000`, `-webkit-app-region: drag` (the whole bar moves the window). `.topbar button`, `.brand-logo`, `.brand-name`, `.brand-version` and `.brand-update-pill` are `no-drag`. The logo, name and version also get `cursor: pointer`.
- Left cluster `.brand#brand`: flex, centre-aligned, `gap: 12px`, weight 700, letter-spacing −0.2 px. Children in order:
  1. Logo SVG, 22×22, `display: block`, `flex-shrink: 0` (see component 4).
  2. `.brand-name` "robogears Downloader", 16 px / 700, `#fff`.
  3. `.brand-version#brand-version`, 11 px / 700, `#9a9a9a`, letter-spacing 0, `margin-left: -4px` (visual gap 8 px). At boot it is filled with `v${version}` from `api.getAppVersion()` (app.js:1953-1956, not awaited; on failure it stays empty).
  4. `.brand-update-pill` (hidden until an update is found; component 5).
- Right: `#settings-btn.icon-btn`, `title` and `aria-label` "Settings". Its 20×20 gear SVG has viewBox 0 0 24 24, `fill="none"`, `stroke="currentColor"`, stroke-width 1.8, round caps and joins, a circle r=3 and the standard Feather "settings" cog path. `.icon-btn` is transparent with no border, colour `#9a9a9a`, padding 8 px, radius 6 px, `inline-flex` centred and `transition: color 0.15s`. On hover the colour is `#fff`.
- Gear click (app.js:1505-1509): `await refreshAuthStatus()` (one `token:exists` IPC), then `refreshLibraryStatus()` (not awaited), then `openModal('settings-modal')`. The dialog therefore opens only after the token check returns.
- Height by arithmetic: 16 + 36 (8 + 20 + 8 for the gear button) + 16 = about 68 px (inferred; needs a run).

#### 4. Brand marks — `index.html:12-20`, `build/icon.svg`, `build/dmg-background.svg`

- **Topbar logo** (viewBox 0 0 24 24, `aria-hidden`): `circle cx=12 cy=12 r=10 fill=#fff` (record); `circle r=5 fill=#000` (label); arrow path `M10.5 7 L13.5 7 L13.5 10 L15.5 10 L12 14 L8.5 10 L10.5 10 Z` `fill=#fff`. It has no grooves and no rounded square, by design (comment at 13-16).
- **App icon** `build/icon.svg` (1024×1024): `rect rx=ry=180 fill=#000000`; `circle r=380 fill=#ffffff`; four grooves `r=350, 310, 270, 230` (fill none, stroke `#000000`, width 2, opacity 0.5); label `circle r=200 fill=#000000`; arrow in `translate(512,512)` made of `rect x=-30 y=-90 w=60 h=110` plus `polygon -90,20 90,20 0,130`, both `#ffffff`. The PNG export `build/icon.png` is what packaging uses.
- **DMG background** (packaging reference): a 1920×1200 canvas of `#0a0a0a`, so a resized Finder window never shows white. The scene sits in the top-left 540×400 area, matching `package.json` `dmg.window`. Title "Install robogears Downloader" at (270,55), 22 px / 700, `#fff`, letter-spacing −0.4, centred. Subtitle "Drop the needle — drag the record onto the platter" at (270,82), 13 px / 400, `#9a9a9a`. Platter rings at (400,220): r=92 `#3a3a3a` 2 px; r=84/76/68/60 `#2f2f2f` 1 px; r=52 `#2a2a2a` 1 px. Tonearm: pivot (510,115) r=11 `#1f1f1f` with a `#5a5a5a` stroke, centre pin r=3 `#7a7a7a`, shaft 510,121→510,225 `#5a5a5a` 4 px, headshell rect (494,222, 32×14, rx 2), stylus to y=244 `#9a9a9a`. Footer at (270,362), 12 px: **"DON'T FORGET"** (700, `#fff`, letter-spacing 0.5) followed by " to allow the app in System Settings → Privacy & Security" (`#9a9a9a`).

#### 5. "Update now" pill — `index.html:23`, `styles.css:87-117`, `app.js:441-489`

- Style: background `#fff`, colour `#000`, no border, padding `4px 10px`, radius 999 px, 11 px / 700, letter-spacing 0.3 px, `margin-left: 8px` (plus the 12 px flex gap), `font-variant-numeric: tabular-nums`, `transition: background 0.15s, opacity 0.15s`. When enabled, `animation: brand-update-pulse 2.4s ease-in-out infinite` runs a box-shadow ring that goes from `0 0 0 0 rgba(255,255,255,0.45)` at 0 %/100 % to `0 0 0 6px rgba(255,255,255,0)` at 50 %. Hover (enabled): `#e5e5e5`. Disabled: background `#0a0a0a`, colour `#9a9a9a`, `cursor: default`, no pulse. `[hidden]` gives `display: none`.
- State `_pillUpdateState`: `'idle' | 'available' | 'downloading' | 'restarting'`, plus `_pillUpdateUrl`.
- On **every** `update:available` payload `{version, downloadUrl, releaseUrl}` (from the launch check or a manual check): store `downloadUrl`, set state `'available'`, unhide, enable, set the text to "Update now". This happens regardless of the current state.
- Click:
  1. If state ≠ `'available'` or there is no URL, return.
  2. `selfInstall = await api.canSelfInstall()` (a rejection counts as `false`). If false, call `api.openExternal(url)` and return; the state stays `'available'`.
  3. Set state `'downloading'`, disable, text "Downloading…".
  4. `r = await api.downloadUpdate(url)`. If `!r || !r.ok`: state `'available'`, enable, text "Retry update", return.
  5. Set state `'restarting'`, text "Restarting…" (still disabled), call `api.applyUpdate()` and do not read its result.
- Progress listener (acts only while `'downloading'`): if `total > 0`, text `Downloading ${Math.floor(downloaded/total*100)}%`; otherwise `Downloading ${(downloaded/1024/1024).toFixed(1)} MB`.
- In main, `canSelfInstall()` is true only for packaged win32/darwin builds (electron-main.js:193-199). After a successful `update:apply`, main quits the app after **500 ms** (electron-main.js:467).

#### 6. Brand easter egg — `app.js:495-499, 203-239`

- A click listener on `#brand`: if the target is inside `.brand-version`, call `playFart({ pitchScale: 7 })`; if it is inside `.brand-logo` or `.brand-name`, call `playFart()`. Clicks on the pill or on empty brand space do nothing.
- `playFart({pitchScale p = 1})`, with `t = ctx.currentTime + 0.02` and duration 0.42 s:
  - Sawtooth oscillator at `95·p` Hz, exponential ramp to `48·p` Hz at `t+0.42`.
  - LFO: a sine at `17·√p` Hz → gain `18·p` → oscillator frequency.
  - Lowpass filter at `480·p` Hz, Q 2.2.
  - Gain: 0.0001 at t → exponential to 0.42 at t+0.02 → linear to 0.32 at t+0.189 → exponential to 0.0001 at t+0.42.
  - Oscillator and LFO stop at t+0.47.

#### 7. Main column — `styles.css:136-162`, `index.html:33-88`

- `.main`: flex column, `gap: 22px`, padding `12px 28px 28px`, `height: calc(100vh - 60px)`, `overflow: hidden`. The 60 px subtraction is smaller than the ~68 px topbar, so about 8 px of the 28 px bottom padding is cut off by `body { overflow: hidden }` (inferred; needs a run).
- Children in order: `section.input-card`, `section.drop-zone#drop-zone`, `section.queue#queue-section` (hidden when the queue is empty; `max-height: 36vh`), `section.activity` (`flex: 1; min-height: 0`; it takes the rest). The input card, drop zone and activity section have a transparent background and no padding.
- `.label` (section captions): block, 11 px / 600, `text-transform: uppercase`, letter-spacing 1.2 px, `#5a5a5a`, `margin-bottom: 12px`. None is linked to its input with `for`/`id`.
- `.hint`: margin `12px 0 0`, `#9a9a9a`, 12.5 px, line-height 1.5.

#### 8. Button system — `styles.css:207-258, 119-133`

| Class | Look | Hover | Active | Disabled |
|---|---|---|---|---|
| shared `.primary-btn, .secondary-btn, .text-btn` | declared `font: 14px inherit` (invalid; see Bugs), weight 600, radius 8 px, padding `13px 22px`, no border, `white-space: nowrap`, `cursor: pointer`, transitions: background/colour/border-colour/opacity 0.15 s, transform 0.05 s | — | — | — |
| `.primary-btn` | background `#fff`, text `#000` | `#e5e5e5` | `translateY(1px)` | background `#0a0a0a`, text `#5a5a5a`, `not-allowed` |
| `.secondary-btn` | transparent, `#fff`, `1px solid #2a2a2a` | background `#0a0a0a` | — | no style (looks enabled) |
| `.text-btn` | transparent, `#9a9a9a`, padding `8px 14px` | `#fff` | — | no style (looks enabled) |
| `.text-btn.cancel-btn` | `#ff6b6b` | `#ff8a8a` | — | — |
| `.text-btn.retry-all-btn` | `#fff` | `#fff` on `#0a0a0a` (the same as the panel, so nothing visibly changes) | — | — |
| `.queue-actions .primary-btn` | padding `8px 16px`, `font-size: 13px` | | | |
| `.icon-btn` | transparent, `#9a9a9a`, padding 8, radius 6 | `#fff` | — | — |

Buttons keep Chromium's default focus ring; no button sets `outline: none`.

#### 9. Link/search input card — `index.html:34-41`, `styles.css:165-195`, `app.js:1276-1325`

- Markup: label "Paste a link or search for a song" (shown in uppercase); `.url-row` (flex, gap 10 px) containing `input#url-input` (`type=text`, placeholder `Spotify/TIDAL URL or song name...` with three ASCII dots, `autocomplete=off`, `spellcheck=false`) and `button#add-btn.primary-btn` "Add to queue"; then `p.hint#input-hint` "Paste a Spotify or TIDAL link to add all its tracks. Or type a song name to search."
- Text inputs (`input[type=text]`, styles.css:170-195): `flex: 1`, background `#0a0a0a`, `1px solid transparent`, radius 8 px, colour `#fff`, declared `font: 15px/1.4 inherit` (invalid), weight 500, padding `14px 18px`, `outline: none`, transitions on background and border 0.15 s. Focus: background `#0d0d0d`, border `#2a2a2a`. Placeholder: `#5a5a5a`, weight 400. `input[readonly]`: background `#0a0a0a`, `cursor: default`.
- Hint (`input` event, app.js:1278-1282): if `/^https?:\/\/|spotify\.com|tidal\.com/i` matches the trimmed value, the hint becomes "Detected a link — will resolve all tracks on add."; otherwise "Type to search TIDAL by song name (or paste a link).". The original HTML hint never comes back. When the code clears the field after a successful add, no `input` event fires, so the hint keeps its last text. This regex only drives the hint; main decides URL vs search (`lib.parseInputUrl`).
- Submit: a click on `#add-btn`, or `keydown` Enter in the field, runs `handleInput()`:
  1. Trim the value; if it is empty, return.
  2. If `!(await api.tokenExists())`, log "⚠ Sign in to TIDAL first (Settings → Sign in)." and return.
  3. `showLoading(null, { cancellable: true, onCancel: () => api.cancelResolve() })`: random funny text and a Cancel button.
  4. `r = await api.resolveInput({ input })`; `hideLoading()`.
  5. If `r.cancelled`, log "⊗ Resolve cancelled." and return. If `!r.ok`, log `✗ ${r.error}` and return.
  6. If `r.kind === 'url'`: `found` = tracks without `notFound`; `missing = total − found`; `added = addTracksToQueue(r.tracks)`; log `+ Added ${added} track${added===1?'':'s'} from link${missing ? ` (${missing} not on TIDAL)` : ''}.`. If `r.capped`, also log "⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren't included.". Clear the field.
  7. If `r.kind === 'search'`, open the Search modal with up to 10 results (main calls `searchTracksForQueue(input, token, country, 10)`). The field keeps its text until "Add selected".
  8. On an exception: `hideLoading()` and log `✗ ${e.message}`.
- `#add-btn` is disabled only while a batch is downloading (`setDownloading`). Enter is never blocked: it works during a batch and while the loading overlay is showing.

#### 10. Loading overlay — `index.html:224-230`, `styles.css:838-880`, `app.js:271-321`

- `.loading`: `position: fixed; inset: 0`, background `rgba(0,0,0,0.7)`, `backdrop-filter: blur(8px)` (plus the `-webkit-` prefix), flex centred, **z-index 100** (above modals at 50); `[hidden]` gives `display: none`. It appears and disappears instantly.
- `.loading-inner`: flex column, centred, gap 14 px. `.spinner`: 28×28 circle, border `2.5px solid #2a2a2a` with top colour `#fff`, `animation: spin 0.8s linear infinite`. `.loading-text#loading-text` (initial "Loading…"): 13 px / 500, `#9a9a9a`. `#loading-cancel.text-btn.loading-cancel-btn`: `margin-top: 4px`, `#9a9a9a`, `1px solid #2a2a2a`, transparent; hover: colour and border `#fff`; hidden by default.
- `showLoading(text, {cancellable=false, onCancel=null})`: clear any running text timer. If `text` is given, show it. Otherwise show a random `FUNNY_LOADING` entry and every **2500 ms** swap to a different random entry (re-pick while it equals the previous one). Set `_loadingOnCancel = cancellable ? onCancel : null`; Cancel is hidden when not cancellable; enable it and set its text to "Cancel"; show the overlay.
- `hideLoading()`: hide the overlay and Cancel, clear the handler and the timer.
- Cancel click: if there is no handler, return. Otherwise disable, set the text to "Cancelling…" and call the handler (exceptions are swallowed).
- The overlay blocks the pointer only. Keyboard focus and keys still reach controls behind it.

#### 11. Drop zone and tracklist import — `index.html:43-55`, `styles.css:268-314`, `app.js:1763-1939`

- Markup: `section#drop-zone.drop-zone > .drop-inner` contains:
  - A 32×32 Feather "file-text" SVG: path `M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z`, polyline `14 2 14 8 20 8`, lines y=13 and y=17 from x=8 to 16; stroke-width 1.5; no `aria-hidden`.
  - `.drop-title` "Drop a playlist CSV or paste tracks".
  - `.drop-sub` "For playlists over 100 tracks — export via **Exportify** and drop the CSV here", where "Exportify" is `a#exportify-link.drop-link href="#"`.
  - A hidden `input#file-input type=file accept=".csv,.txt,text/csv,text/plain"`.
- Style: `cursor: pointer`, `1px dashed #1a1a1a`, radius 12 px, transition border-colour/background 0.2 s, `position: relative` (no positioned child uses it). Inner: flex column centred, text centred, padding `36px 18px`, `#9a9a9a`. Icon `#5a5a5a`, `margin-bottom: 14px`, colour transition 0.2 s. Title 14 px / 600, `#fff`, letter-spacing −0.1 px. Sub 12.5 px, `#9a9a9a`, `margin-top: 6px`. Link `#fff`, underlined, `text-underline-offset: 2px`. Hover or `.dragover`: border `#fff`, background `#0a0a0a`, icon `#fff`.
- Events:
  - Click anywhere on the zone → `fileInput.click()` (native open dialog).
  - `dragover` / `dragenter` → `preventDefault()`, add `.dragover`. `dragleave` / `drop` → remove `.dragover` (it can flicker as the pointer crosses child elements).
  - `drop` → `preventDefault()`; take **only** `dataTransfer.files[0]`; `await file.text()`; `handleTracklistInput(text, file.name)`. On error, log `✗ Couldn't read ${file.name}: ${err.message}`. Drops do not check the file type (`accept` applies only to the picker).
  - File input `change` → the same, then reset `value` to `''`.
  - Document `paste` (app.js:1800-1808): ignore it if `document.activeElement.tagName` is `INPUT` or `TEXTAREA`. Read `clipboardData 'text/plain'`. Ignore it if the length is < 10, or if it has no `\n`, no `,` and does not match `/\s[-—–|]\s/`. Otherwise `preventDefault()` and `handleTracklistInput(text, 'pasted text')`. This also fires while a modal is open, as long as focus is not in an input.
  - Exportify link click → `preventDefault()` then `api.openExternal('https://exportify.net')`. It does **not** stop propagation, so the click also reaches the zone's click handler (see Bugs).
- `handleTracklistInput(text, sourceName)`:
  1. If an import is already running (`_tracklistInFlight`), return silently.
  2. `tracks = parseTracklistText(text)`. If there are none, log `✗ No tracks found in ${sourceName}.` and return.
  3. Log `📋 Parsed ${n} track${s} from ${sourceName}. Matching against TIDAL…`.
  4. Set the in-flight flag and `_tracklistTotal = n`; `showLoading(\`Matching 0 / ${n} tracks on TIDAL…\`)`. It is **not cancellable**.
  5. `r = await api.resolveTracklist({ tracks })`; `hideLoading()`. Each `tracklist:progress {done,total}` event that arrives while the flag is set changes the overlay text to `Matching ${done} / ${_tracklistTotal || total} tracks on TIDAL…`.
  6. If `!r.ok`, log `✗ ${r.error}`. Otherwise `matched` = non-`notFound` count, `missing` = the rest, `added = addTracksToQueue(r.tracks)`, and log `+ Added ${added} from import. ${matched} matched on TIDAL${missing ? `, ${missing} not found` : ''}.`.
  7. On an exception: `hideLoading()`, log `✗ ${e.message}`. Finally clear the flag and the total.
- Parser:
  - `looksLikeCsv`: the first non-empty line contains `,` **and** `text.split(/\r?\n/).length >= 2`.
  - `parseCsv`: a character state machine. A quote opens a quoted field only at the start of a field; `""` inside quotes is a literal quote; `\r` is skipped outside quotes; `\n` ends a row; a final unterminated row is flushed.
  - `parseCsvTracklist`: needs ≥ 2 rows. Header cells are lowercased and trimmed. Title column = the **first** header matching `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/`. Artist column = the first header matching `/artist/`. With no title column it returns `[]`, and the plain-text parser runs instead. Empty titles are skipped. Duplicates are dropped on `${title.toLowerCase()}|${artist.toLowerCase()}`.
  - Plain text: split into lines, trim, drop blanks. `/^(.+?)\s*[-—–|\t]\s*(.+)$/` gives `title = m[1]`, `artist = m[2]`; without a match, `title = line`, `artist = ''`. Titles shorter than 2 characters are skipped. The same dedupe applies.
- Imported tracks come back with `source: 'import'` and never carry a `hiRes` field (electron-main.js:961-973). Import rows therefore never show the Hi-Res badge.

#### 12. Queue panel header and preview volume — `index.html:58-79`, `styles.css:424-511`, `app.js:506-524, 1947-1948`

- `section#queue-section.queue`: background `#0a0a0a`, radius 12 px, padding `14px 16px 12px`, flex column, `min-height: 0`, `max-height: 36vh`; `[hidden]` gives `display: none`. It is hidden whenever `queue.length === 0` (set in `renderQueue`).
- `.queue-head`: flex, space-between, centre-aligned, `margin-bottom: 10px`.
  - Left `.queue-head-left` (flex, gap 18 px):
    - `.queue-title` "Queue" (14 px / 700, `#fff`, letter-spacing −0.2 px) containing `span#queue-count`. The count is inline-block, background `#0d0d0d`, `#9a9a9a`, 11 px / 600, padding `2px 8px`, radius 999 px, `margin-left: 6px`, and its text is `queue.length`.
    - `.queue-volume` (`title="Preview volume"`; flex, gap 8 px, `#9a9a9a`): a 14×14 Feather "volume-2" SVG (`aria-hidden`) and `input#volume-slider type=range min=0 max=100 value=50 aria-label="Preview volume"`.
  - Right `.queue-actions` (flex, gap 8 px, centred), in order: `#cancel-queue.text-btn.cancel-btn` "Cancel" (hidden unless downloading); `#retry-all.text-btn.retry-all-btn` "↻ Retry all" (hidden; its label is set by `renderQueue`); `#clear-queue.text-btn` "Clear all"; `#download-all.primary-btn` "Download all".
- Slider look: `appearance: none`; the input's own background `#1a1a1a` is the 3 px-high, 80 px-wide track (radius 999 px), with `outline: none` and no focus style. WebKit thumb: 12×12 `#fff` circle, `transition: transform 0.1s`, hover `scale(1.18)`. A `::-moz-range-thumb` rule exists but Electron never uses it.
- Volume model: `settings.volume` should hold the **slider position** 0..1, and audio volume = `clamp(v)²` (`sliderToAudioVolume`, app.js:506-509). `getPreviewVolume()` returns the **squared** value, defaulting to `v = 0.5`, which gives 0.25 (app.js:510-513).
  - `input` event: `settings.volume = value/100`; the playing preview's volume updates at once; `api.saveSettings(settings)` runs after a 300 ms debounce.
  - Boot sets `volumeSlider.value = Math.round(getPreviewVolume()*100)`, i.e. the squared value (see Bugs).

#### 13. Queue row (`renderQueue`) — `app.js:890-1022`, `styles.css:513-764`

`renderQueue()` rebuilds the whole list every time: `queueList.innerHTML = ''`, then one fresh row per item. For each item `t`:

1. `lm = t.libraryMatch`; `isExact = lm.kind === 'exact'`; `isSimilar = lm.kind === 'similar'`.
2. If `t.included === undefined`, set `t.included = !isExact`. This is written onto the item and persists.
3. `excluded = !t.included && !t.notFound`.
4. `div.queue-item` gets the classes ` notfound` if `t.notFound`, ` excluded` if excluded, and `` ` dl-${t.dlStatus}` `` if set. It also gets `data-tidal-id = t.tidalId || ''` and `data-key = t.key`.
5. Children, in order:
   - **Checkbox** `span.qi-check` (only if `dlStatus === 'failed' && tidalId`): `role="checkbox"`, `aria-checked`, `tabindex="0"`, `title="Select for batch retry"`.
   - **Play button** `button.qi-play` (only if `PREVIEW_FEATURE_ENABLED && tidalId && !notFound`).
   - `.qi-info`, containing:
     - `.qi-title-row`: `.qi-title` (escaped title) plus `canvas.qi-waveform` (same condition as the play button).
     - `.qi-artist`: `` `${escape(artist)}${duration ? ` · ${m:ss}` : ''} ${hiResBadge}${status}` `` (note the space before the badges).
     - `.qi-libnote` "Library: ${libraryTitle}" (exact or similar match with a `libraryTitle`).
     - `.qi-progress > .qi-progress-fill` (only while `dlStatus === 'downloading'`; width `${dlPercent ?? 0}%`).
   - `button.qi-add` "+ Add", `title="Add to download list"` (only if excluded).
   - `button.qi-retry` "↻ Retry", `title="Re-download this track"` (only if `dlStatus === 'failed'`).
   - `button.qi-remove` "✕", `aria-label="Remove from queue"`, no `title`.
6. After the row is appended, if peaks are cached for its `tidalId`: remove `.empty`, attach `__peaks` and paint at the current progress (if it is the playing track). If it is the playing track and not paused, put the pause icon and `.playing` on the button. During loading the rebuilt button shows the play icon, not the loading icon.
7. Footer logic: `downloadable = queue.filter(t => !t.notFound && t.included)`. `downloadAllBtn.disabled = isDownloading || downloadable.length === 0`. Label: "Downloading…" while downloading; otherwise `Download (${downloadable.length})` if the queue is non-empty and `downloadable.length !== queue.length`, else "Download all".
8. Retry header: `failed` = items with `dlStatus === 'failed' && tidalId`. If not downloading and at least 1 failed item is selected → visible, `↻ Retry selected (${n})`. Else if not downloading and at least 2 have failed → visible, `↻ Retry all (${n})`. Else hidden.
9. `renderBatchProgress()`.

Row CSS:

| Selector | Rule |
|---|---|
| `.queue-list` | `flex: 1`, `overflow-y: auto`, flex column, gap 2 px, margin `0 -4px` |
| `.queue-item` | flex, centred, gap 12 px, padding `8px 10px`, radius 8 px, `transition: background 0.1s`; hover `#0d0d0d` |
| `.qi-info` | `flex: 1; min-width: 0` (does not clip) |
| `.qi-title` | 13.5 px / 500, `#fff`, single-line ellipsis; inside `.qi-title-row` it is overridden to `flex: 0 0 auto; overflow: visible; text-overflow: clip; white-space: nowrap`, so the title is never shortened and the waveform gives way |
| `.qi-title-row` | flex, centred, gap 12 px, `min-width: 0` |
| `.qi-artist` | 12 px, `#9a9a9a`, `margin-top: 2px`, single-line ellipsis (badges can be cut off after a long artist) |
| `.qi-libnote` | 11.5 px mono, `#5a5a5a`, `margin-top: 4px`, ellipsis |
| `.qi-check` | 18×18, `1.5px solid #2a2a2a`, radius 4 px, flex centred, transition 0.15 s, `user-select: none`; hover border `#fff`; `.checked` fills background and border `#fff` with `::after "✓"` in `#000`, 12 px / 700, line-height 1 |
| `.qi-add` | `#fff` background / `#000` text, no border, declared `font: 12px inherit` (invalid), 600, radius 6 px, padding `5px 12px`, `transition: background 0.15s`, `flex-shrink: 0`, `opacity: 1`; hover `#e5e5e5` |
| `.qi-retry` | transparent, `#9a9a9a`, `1px solid #2a2a2a`, padding `5px 10px`, radius 6 px, 12 px / 600, `flex-shrink: 0`, no transition; hover colour and border `#fff` |
| `.qi-remove` | transparent, no border, `#5a5a5a`, 14 px, padding `4px 8px`, radius 6 px, transitions 0.15 s; hover `#fff` on `#0d0d0d` |
| `.notfound` | whole row `opacity: 0.55`; play and waveform `display: none` (unnecessary, since such rows never get them) |
| `.excluded` | `.qi-info` opacity 0.42, title `line-through`, `.qi-remove` opacity 0.42; `.qi-add` stays at full opacity |
| `.dl-downloading` | background `rgba(255,255,255,0.04)`; **waveform** hidden (the play button stays visible) |
| `.dl-downloaded` | `.qi-info` opacity 0.65, title `line-through` |
| `.dl-skipped` | `.qi-info` opacity 0.5 |
| `.dl-failed` | background `rgba(255,107,107,0.06)` |
| `.dl-queued`, `.dl-notFound` | no rules (a queued row shows no "queued" marker; its status falls through to the library/source badge) |

The `.dl-failed` and `.dl-downloading` backgrounds come later in the stylesheet than `.queue-item:hover` with the same specificity, so those rows show no hover change.

#### 14. Badges — `styles.css:647-663, 700-703`, `app.js:912-926, 1340`

- Base `.badge`: inline-block, 10 px / 600, uppercase, letter-spacing 0.6 px, padding `1px 7px`, radius 999 px, background `#0d0d0d`, colour `#9a9a9a`, `margin-left: 6px`, `vertical-align: middle`. All badge text shows in uppercase.
- The Hi-Res badge `.badge.hi-res` "Hi-Res" (`rgba(255,255,255,0.12)` / `#fff`) shows whenever `t.hiRes`, **before** the status badge. It also appears after the title in search results.
- Exactly one status badge appears; the first match wins:

| Condition | Text | Class | Background / colour | Tooltip |
|---|---|---|---|---|
| `dlStatus === 'downloading'` | `↓ ${dlPercent ?? 0}%` | `dl-running` | `rgba(255,255,255,0.16)` / `#fff` | — |
| `dlStatus === 'downloaded'` | `✓ done` | `dl-ok` | `rgba(34,197,94,0.18)` / `#86efac` | — |
| `dlStatus === 'skipped'` | `⏭ skipped` | `dl-skip` | `rgba(154,154,154,0.18)` / `#9a9a9a` | — |
| `dlStatus === 'failed'` | `✗ failed` | `dl-fail` | `rgba(255,107,107,0.18)` / `#ff6b6b` | — |
| `notFound` or `dlStatus === 'notFound'` | `not found` | `bad` | `rgba(255,107,107,0.12)` / `#ff6b6b` | "Not on TIDAL" |
| exact library match | `📁 already in library` | `dupe` | `rgba(154,154,154,0.18)` / `#fff` | library path |
| similar library match | `⚠ similar version in library` | `similar` | `rgba(245,158,11,0.18)` / `#fcd34d` | library path |
| `source === 'spotify'` | `Spotify` | base | base | — |
| `source === 'import'` | `Import` | base | base | — |
| `source === 'extension'` | `Spotify ext` | base | base | — (not ported) |
| `source === 'tidal'` | none | | | |

- While downloading, the `↓ N%` text and the fill width are updated in place by `updateRowPercent` (app.js:1052-1059), without a full re-render.

#### 15. Preview play button — `app.js:653-666, 769-881, 1061-1070`, `styles.css:566-600`

- `button.qi-play` (`data-tidal-id`, `title="Play preview"`, `aria-label="Play"`; the label never changes): `flex-shrink: 0`, 28×28, radius 50 %, transparent, `1px solid #2a2a2a`, `#9a9a9a`, inline-flex centred, padding 0, transitions on colour/border/background 0.15 s. Hover: `#fff` icon and border, background `#0d0d0d`. `.playing`: icon `#000`, background and border `#fff`. `.loading`: `#9a9a9a`, dashed border, and `animation: qi-play-spin 1.2s linear infinite` rotates the **whole button** 0→360°.
- Icons (injected HTML, 9×9 in viewBox 0 0 10 10, `aria-hidden`): PLAY `polygon 2,1 9,5 2,9` `fill=currentColor`; PAUSE two rects `(x2 y1.5 w2 h7)` and `(x6 y1.5 w2 h7)`; LOADING `circle cx5 cy5 r3.5`, no fill, stroke 1.2, `stroke-dasharray="4 3"`.
- `setPlayButtonState(id, state)` finds the row by `data-tidal-id`, removes `playing` and `loading`, then adds the class and icon for `'playing'` (pause icon) or `'loading'`; any other state gets the play icon.
- A click on `.qi-play` (it stops propagation) calls `togglePreview(Number(tidalId), row)`.
- `togglePreview(tidalId, row, { initialSeekRatio = 0 })`:
  1. If there is no row, return.
  2. If this track is the current one (`previewState.playingTidalId === tidalId`) and audio exists: when paused, seek to `ratio·duration` if `ratio > 0` and the duration is finite, then `play()` (errors ignored) and state `'playing'`; otherwise `pause()` and state idle. Return.
  3. `stopPreview()`: null `audio` and `playingTidalId` **first**, `pause()`, `src = ''`, reset the old button to idle, repaint the old waveform at progress 0.
  4. If the row has no canvas, return.
  5. If peaks are cached, paint them at once (progress = `initialSeekRatio`).
  6. State `'loading'`.
  7. `getPlayableEntry(tidalId)`: the audio cache is an LRU of 3 Blob URLs, revoked on eviction, and the playing entry is never evicted. The peaks cache has no limit. A cache miss fetches the **whole** lossless file over IPC (`preview:get-audio`); peaks are decoded from a copy.
  8. `new Audio(blobUrl)`, volume = squared slider value, `preload = 'auto'`; set it as current; paint.
  9. If `ratio > 0`, wait for `loadedmetadata` when the duration is not finite, then set `currentTime`.
  10. Listeners, each a no-op once the element is no longer current: `play` starts a `requestAnimationFrame` tick that repaints progress plus the live canvas's `data-hover` until paused; `pause` sets the idle icon; `ended` calls `stopPreview()`; `error` logs `✗ Preview playback failed (${audio.error?.code || '?'}).` and calls `stopPreview()`.
  11. `await audio.play()`; state `'playing'`.
  12. On an exception: idle, and log `✗ Preview: ${e.message}` (for example "preview fetch failed", "Web Audio not supported" or main's error text).
- Removing the playing row (✕) and "Clear all" both call `stopPreview()` first. Nothing stops a preview when a batch starts.

#### 16. Waveform canvas — `app.js:587-650, 730-767, 1133-1222`, `styles.css:611-635`

- Element: `<canvas class="qi-waveform empty" data-tidal-id height="22" title="Click or drag to scrub">`. CSS: `flex: 1 1 auto`, `min-width: 0` (it can shrink to nothing), `height: 22px`, pointer cursor, radius 4 px, transparent, block, `transition: background 0.12s`; hover background `rgba(255,255,255,0.03)`; `.empty` (before peaks arrive) has the default cursor and draws nothing.
- **Peaks** (`computePeaks`, 587-606): channel 0 only; `samplesPerBar = max(1, floor(len/200))`; each bar is the max |sample| in its window; then everything is divided by the global max (if it is > 0). 200 bars (`decodePeaksFromBuffer`, 686).
- **Drawing** `drawWaveform(canvas, peaks, progress=0, hover=-1)` (608-650):
  1. `dpr = devicePixelRatio || 1`; `cssWidth = clientWidth || canvas.width`; `cssHeight = clientHeight || canvas.height`. If the backing store ≠ css×dpr, resize it. Then `scale(dpr)` and clear.
  2. `n = 200`, `barWidth = cssWidth/n`, `midY = cssHeight/2`, `hoverBar = hover·n` (or −1).
  3. For each bar i: played if `(i+0.5)/n <= progress`. Spotlight: if `|i − hoverBar| < 10`, `boost = 1 + (1 − dist/10)·0.45` (up to 1.45×). `h = max(1, peak·cssHeight·0.78·boost)`. Fill `'#ffffff'` if played, else `'rgba(255, 255, 255, 0.22)'`. Draw `rect(i·barWidth, midY − h/2, max(1, barWidth − 1), h)`: bars are centred vertically with about a 1 px gap.
  4. If `hover >= 0`, draw a cursor line in `'rgba(255, 255, 255, 0.55)'` at `x = floor(hover·cssWidth)`, 1 px wide, from y=2, height `cssHeight − 4`.
- **Mouse** (all delegated on `#queue-list`):
  - `mousedown` (left button only): `rel = clamp((clientX − left)/width)`. If this is the current track (playing **or paused**): require peaks, `preventDefault()`, start a scrub session and seek at once (`currentTime = rel·duration`, redraw with progress = hover = rel, store `data-hover`). Otherwise `preventDefault()` and `togglePreview(id, row, { initialSeekRatio: rel })`: that track starts from the clicked spot, even before its peaks exist.
  - `document` `mousemove` while scrubbing: keep seeking, following the cursor even off the canvas. Audio keeps playing, which gives a "skim" sound. `document` `mouseup` ends the scrub.
  - List `mousemove` (not scrubbing, peaks present): store `data-hover` and redraw with the current progress and the hover position.
  - List `mouseout` (capture phase; not scrubbing; `relatedTarget` outside the canvas): delete `data-hover` and redraw without hover.
  - `window` `resize`: after a 120 ms debounce, redraw every canvas that has peaks.
- **Preloader** (730-767): when tracks enter the queue (add or boot restore) with a `tidalId` and not `notFound`, `enqueuePreload` pushes the id unless it is already cached or queued. A FIFO drains with **concurrency 2**. Each job fetches the full audio, decodes peaks, throws the bytes away, and paints every canvas with that id (removing `.empty`). Failures are silent.

#### 17. Per-track and batch progress — `app.js:1026-1059, 1225-1245`, `styles.css:711-722, 767-789`

- `bulk:track-start {tidalId}`: find the item by `tidalId`; `dlStatus = 'downloading'`, `dlPercent = 0`; `renderQueue()`.
- `bulk:track-progress {tidalId, percent}`: set `dlPercent`; update in place only (badge text and fill width).
- `bulk:track-done {tidalId, status}`: `dlStatus = status`; `dlPercent = 100` if `'downloaded'`, else keep the old value or 0; `renderQueue()`.
- Row bar `.qi-progress`: height 3 px, `margin-top: 6px`, track `#1a1a1a`, radius 999 px, `overflow: hidden`. Fill `#fff`, `transition: width 0.18s ease-out`.
- Batch bar (`renderBatchProgress`): shown only while `isDownloading` and there are items with `included && !notFound`.
  - **Total** = all such queue items, not only the ones sent in this batch. **Done** = those with `dlStatus` in {downloaded, skipped, failed, notFound}. `pct = floor(done/total·100)`.
  - `div.batch-progress` is created once and inserted inside `#queue-section` before `#queue-list` (under the header). It contains `.batch-progress-bar` (width pct %) and `span.batch-progress-label` (`${done} / ${total}`).
  - Styles: `.batch-progress` `position: relative`, height 5 px, margin `0 0 10px`, `#1a1a1a`, radius 999 px, `overflow: hidden`. Bar `#fff`, width 0 %, `transition: width 0.25s ease-out`. Label `position: absolute; right: 0; top: -22px`, 12 px / 600, `#9a9a9a`, tabular numbers. The label is clipped and never visible (see Bugs).
  - The element is removed when downloading stops.

#### 18. Queue actions — `app.js:1061-1125, 1247-1272, 1361-1482`

- `addTracksToQueue(tracks)`: dedupe key `id:${tidalId}`, or `na:${title}|${artist}` (case-sensitive), checked against the queue and within the batch. Push `{...t, key: Math.random().toString(36).slice(2,10)}`. Enqueue a preload for tracks with an id that are not `notFound`. `renderQueue()`, save if anything was added, and return the added count.
- **Download all** (1419-1454):
  1. If downloading or the queue is empty, return.
  2. No `downloadFolder` → warning honk and "⚠ Pick a download folder in Settings first.".
  3. `!(await tokenExists())` → honk and "⚠ Sign in to TIDAL first (Settings → Sign in).".
  4. `downloadable = !notFound && included`; if there are none → honk and "⚠ Nothing in the queue can be downloaded." (unreachable from a click, because the button is disabled in that state).
  5. Download chime; `setDownloading(true)`; `appendLine('')`; `appendLine(\`=== Starting batch (${n} tracks) ===\`)`; mark each downloadable item `dlStatus = 'queued'`, `dlPercent = 0`; `renderQueue()`; `await api.startBulk({ tracks: downloadable, outDir })` (result ignored).
- `setDownloading(state)` (1361-1372): `isDownloading = state`; disable `#add-btn` and "Clear all"; Cancel is visible iff `state`, enabled, text "Cancel"; `renderQueue()`; then force the Download label to "Downloading…" or "Download all" with `disabled = state || queue.length === 0` (the next `renderQueue` recomputes the label).
- **Cancel** (1374-1392): only while downloading. Cancel chime; disable; "Cancelling…"; `await api.cancelDownload()` (main kills the batch process at once and replies); every item with `dlStatus` `'downloading'` or `'queued'` becomes `'failed'` at 0 %; log "⊗ Download cancelled."; `renderQueue()`. `isDownloading` stays true until `download:done` arrives.
- **Retry header** (1397-1417): ignored while downloading. Targets = selected failed items, otherwise all failed items with an id; none → return. No folder → honk and the folder warning. Set the targets to queued, 0 %, unselected; download chime; `setDownloading(true)`; log `↻ Retrying ${n} track${s}…`; `startBulk(targets)`. There is no token check.
- **Row ↻ Retry** (1093-1114): needs an item with a `tidalId`. While downloading → "⚠ A batch is already running — retry once it finishes.". No folder → honk and the warning. Otherwise item queued at 0 %; render; log `↻ Retrying ${title}…`; `setDownloading(true)`; `startBulk([item])`. No chime, no token check.
- **Checkbox** click toggles `item.selected` and re-renders (not saved; there is no keyboard toggle). **+ Add** sets `included = true`, renders, saves. **✕** stops the preview if this is the playing track, removes the item, renders, saves. These work during a batch too.
- **Clear all** (1247-1253): ignored while downloading; stops the preview, empties the queue, renders, saves. No confirmation.
- `download:line` → `appendLine`. `download:done {code}` (1457-1482):
  1. `setDownloading(false)`.
  2. Code 0 → success ping and the batch-finished notice. Otherwise log `=== Exit code ${code} ===` (`code` is `null` after a kill).
  3. Keep only items where `notFound || dlStatus === 'failed' || dlStatus === 'notFound' || (!dlStatus && included)`. This removes downloaded and skipped rows, and also **excluded (not "+ Add"-ed) exact-match rows** and any rows still `'queued'`/`'downloading'`.
  4. On the items kept whose `dlStatus` is not failed/notFound, delete `dlStatus` and `dlPercent`.
  5. Render and save.
- Queue save (`saveQueueSoon`, 73-83): 400 ms debounce; strips `dlStatus`, `dlPercent` and `selected`; `api.saveQueue(...)`; failures are ignored.

#### 19. Activity log — `index.html:81-87`, `styles.css:317-369`, `app.js:330-361`

- Header `.activity-head`: flex, space-between, centred, 11 px / 600 uppercase, letter-spacing 1.2 px, `#5a5a5a`, `margin-bottom: 12px`. It shows "Activity" and `button#clear-btn.text-btn` "Clear" (`title="Clear"`).
- Log `#activity.activity-log`: `flex: 1`, `overflow-y: auto`, monospace 12.5 px, line-height 1.7, `#9a9a9a`, padding `4px 0`. When empty, `::before` shows "Nothing yet. Paste a link above to get started." in `#5a5a5a` italic. It has no `role="log"` and no `aria-live`.
- `appendLine(text)`:
  1. Create `div.log-line` with `classify(text)`, set `textContent` and append it.
  2. **Always** scroll to the bottom.
  3. While there are more than 2000 child elements, remove the first one. If the first one is the welcome line, remove its next sibling instead (usually the update notice, which therefore goes first).
  4. Return the div.
- `appendLine('')` makes an empty div only 2 px tall (padding), not a full blank line.
- `classify` (first match wins). Note the alternation in the error rule: `✗ `, `Error:` and `FFmpeg failed` match **anywhere** in the line.

| Order | Regex | Class | Style |
|---|---|---|---|
| 1 | `/^\s*✓ Saved/` | `ok` | `#fff`, 500 |
| 2 | `/^\s*✘\|✗ \|Error:\|FFmpeg failed/` | `error` | `#ff6b6b` |
| 3 | `/^\s*⚠/` | `warning` | `#fff` |
| 4 | `/^\s*⏭\|📁 Already in library/` | `skip` | `#9a9a9a` |
| 5 | `/^\s*ℹ/` | `warning` | `#fff` |
| 6 | `/^===/` | `header` | `#fff` 700, letter-spacing −0.1 px, `margin-top: 14px`, `padding-top: 10px`, `border-top: 1px solid #1a1a1a` |
| 7 | `/complete:/` | `summary` | same as header without the letter-spacing |
| 8 | `/\[debug\]/` | `muted` | `#5a5a5a` |
| — | otherwise | `''` | base: `#9a9a9a`, padding `1px 0`, `word-break: break-word` |

- Clear: `activityEl.innerHTML = ''`. This also detaches the welcome line (see Bugs).

#### 20. Update notice row in the log — `app.js:368-435, 1990-1994`, `styles.css:370-382, 399-421`

- `insertUpdateNotice({version, downloadUrl})`:
  1. If the welcome line does not exist or is detached, stash the payload in `pendingUpdate` and return. The stash is replayed only once, at the end of boot.
  2. If a `.update-notice` already exists, return.
  3. Build `div.log-line.update-notice` containing `span` with innerHTML `🚀 New version available: <strong>${version}</strong>` (`version` is GitHub's `tag_name`, e.g. `v0.1.31`, inserted unescaped) and `button.update-download-btn` "Download update". Insert it **directly after the welcome line**, which can be scrolled out of view; the view does not scroll to it.
  4. `selfInstall = await canSelfInstall()`. If false, the button calls `openExternal(downloadUrl)`.
  5. Otherwise run a state machine `idle → downloading → ready → restarting`. Click in idle: downloading, disabled, "Starting…"; on failure → idle, enabled, "Download failed — retry"; on success → ready, enabled, adds `.ready`, "Restart to apply". Click in ready: restarting, disabled, "Restarting…", `applyUpdate()` (result ignored). Progress while downloading: `Downloading ${pct}%`, or `Downloading ${MB.toFixed(1)} MB` when the total is unknown.
- Box (shared with the batch notice): flex, space-between, centred, gap 12 px, `#fff`, background `#0a0a0a`, `1px solid #2a2a2a`, radius 8 px, padding `8px 12px`, margin `6px 0`; monospace is inherited from the log.
- Button: `#fff` / `#000`, no border, padding `5px 12px`, radius 6 px, 12 px / 600, `transition: opacity 0.15s`; hover opacity 0.85, active 0.7, disabled 0.55 with the default cursor; `.ready` adds `box-shadow: 0 0 0 1px rgba(255,255,255,0.5)`.

#### 21. Batch-finished notice — `app.js:1486-1501`, `styles.css:370-398`

- On `download:done` with code 0, `div.log-line.batch-done-notice` gets span innerHTML `<strong>✓ Batch finished.</strong>`. If a download folder is set, it also gets `button.batch-open-folder-btn` "Open folder", which calls `api.openFolder(downloadFolder)`.
- Button style: transparent, `#fff`, `1px solid #2a2a2a`, padding `5px 12px`, radius 6 px, 12 px / 600, `flex-shrink: 0`, transitions border/background 0.15 s; hover border `#fff`, background `#0d0d0d`.
- The notice is appended directly (not through `appendLine`, so the 2000-row cap is not checked at that moment), then the log scrolls to the bottom.

#### 22. Modal shell — `styles.css:883-950`, `app.js:322-326`

- `.modal-backdrop`: fixed full-window, `rgba(0,0,0,0.75)`, `backdrop-filter: blur(8px)`, flex centred, **z-index 50**, `animation: fadein 0.15s` (opacity 0→1, default easing) on entry only; `[hidden]` gives `display: none`. There is no exit animation.
- `.modal`: background `#000`, `1px solid #1a1a1a`, radius 12 px, `width: min(560px, 92vw)`, `max-height: 86vh`, `overflow: hidden`, flex column, `box-shadow: 0 40px 100px rgba(0,0,0,0.8)`. Its height follows its content.
- `.modal-head`: padding `20px 26px 16px`, flex space-between; `h2` 18 px / 700, letter-spacing −0.3 px, `#fff`. The close button is `.icon-btn.close-modal` "✕" with `aria-label="Close"`.
- `.modal-body`: padding `4px 26px 18px`, `overflow-y: auto`, `flex: 1`. `.modal-foot`: padding `16px 26px 22px`, flex end-aligned, gap 12 px.
- `.modal-hint`: `#9a9a9a`, 13 px, line-height 1.5, margin `0 0 16px`. Inside it, `code` has background `#0a0a0a`, padding `2px 7px`, radius 4 px, 12 px mono; `em` is `#fff` / 600 and not italic.
- `openModal(id)` / `closeModal(id)` only toggle `hidden`. Every element with `[data-close]` closes the modal it names. There is no Escape handling, no backdrop-click close, no focus move, trap or return, and no `role="dialog"` or `aria-modal`. Tab can reach controls behind the backdrop.

#### 23. Search results modal — `index.html:91-106`, `styles.css:799-835`, `app.js:1329-1357`

- `openSearchModal(results, query)`:
  1. `pendingResults = results`.
  2. Title `Search results for "${query}"` (the HTML default is "Search results").
  3. Hint `${n} result${n===1?'':'s'}. Pick the ones to add to your queue.` (the HTML default is "Pick the tracks to add to your queue.").
  4. One `<label class="search-row">` per result, containing an **unchecked** checkbox (`data-idx`), `.sr-title` (escaped title, plus a Hi-Res badge if `hiRes`) and `.sr-meta` `${artist} · ${album || ''} · ${fmtDuration(duration)}`.
  5. Library status is not shown here, although results carry `libraryMatch`.
- Styles: list flex column, gap 2 px. Row flex, gap 12 px, padding `10px 12px`, radius 8 px, pointer, `transition: background 0.1s`, hover `#0a0a0a`. Checkbox `accent-color: #fff`. Title 13.5 px / 500, `#fff`, ellipsis. Meta 12 px, `#9a9a9a`, ellipsis, `margin-top: 2px`.
- Footer: "Cancel" (`text-btn`, `data-close`) and "Add selected" (primary). Add selected: nothing checked → nothing happens and the modal stays open. Otherwise `addTracksToQueue(picks)`, close, log `+ Added ${added} track${s} from search.`, clear the URL field.
- A pick that exactly matches the library arrives in the queue excluded (greyed, "+ Add").

#### 24. Settings modal — `index.html:109-203`, `styles.css:953-1052`, `app.js:1505-1698`

- Head "Settings" with a ✕. The body starts with `.modal-tabs` (`role="tablist"`): flex, gap 4 px, `border-bottom: 1px solid #1a1a1a`, margin `0 -26px 22px`, padding `0 22px`. Tabs are `button.modal-tab` with `role="tab"`: "Folders" (active), "TIDAL", "Extension", "Updates". The tab bar scrolls with the body.
- Tab style: transparent, `#9a9a9a`, padding `10px 16px`, declared `font: 13px inherit` (invalid), 600, `border-bottom: 2px solid transparent`, `margin-bottom: -1px`, transitions 0.15 s; hover `#fff`; `.active` is `#fff` with a `#fff` underline.
- A tab click toggles `.active` and shows only the matching `[data-pane]`. "extension" also calls `refreshExtensionInfo()`. The chosen tab stays selected when the dialog is reopened. Because the dialog height follows the visible pane, it changes height when tabs switch (inferred; needs a run).
- **Folders pane**:
  - Label "Download folder". `.folder-row` (flex, gap 10 px): readonly `#folder-input`, "Browse…" (secondary), "Open" (text, `title="Open folder"`, disabled when unset). Hint "Every download goes here directly — no subfolders."
  - Label "Music library folder (for duplicate check)" (inline `margin-top:22px`). Row: readonly `#library-input` (placeholder "(none — duplicate check disabled)"), "Browse…", "Open" (`title="Open folder"`), "Clear" (`title="Clear"`). `.library-status-row` (flex, centred, gap 12 px, `margin-top: 10px`): `#library-status.auth-status` (initial "…") and "Refresh" (text). Hint "Read-only. The app reads audio-tag metadata (title, artist, duration) as well as filenames. Re-scans automatically on each launch."
  - `.reset-section` (`margin-top: 28px`, `padding-top: 24px`, `border-top: 1px solid #1a1a1a`): "Reset config" (text) and hint "Forgets your download and library folder choices. TIDAL sign-in is kept."
- **Folders behaviour**:
  - Download Browse → `pickFolder()`. Main shows a directory dialog that defaults to the saved download folder. If a folder is chosen: set it, fill the field, `await saveSettings`, update the Open buttons.
  - Library Browse → the same picker (also opening at the **download** folder). If a folder is chosen: set, fill, save, update the buttons, log `📁 Music library folder set to: ${folder}`. Main starts a rescan if the path changed.
  - Open → `openFolder(path)` if set; errors are ignored.
  - Library Clear → blank it, save, update the buttons, log "📁 Music library folder cleared (duplicate check disabled).", `refreshLibraryStatus()`. No confirmation.
  - Refresh → status "Scanning…", disabled → `r = await libraryRescan()` → `${r.count} files indexed` (always plural) and log `📁 Library re-scanned: ${r.count} files indexed.`; on error, "Scan failed"; finally re-enable.
  - `refreshLibraryStatus()` (runs on dialog open and after Clear/Reset): "Scanning…", then `${n} file${n===1?'':'s'} indexed` if a path is set, otherwise "(no library folder set)"; on error "(scan failed)".
  - `library:scanned {count}` → `${count} file${s} indexed`. `library:scan-progress {done,total}` → `Scanning ${done} / ${total}…` (or "Scanning…" when the total is 0).
  - Reset config → native `confirm('Forget the download folder and music library folder?\n\n(Your TIDAL sign-in stays.)')`. On OK: `settings = await resetSettings()`, which returns exactly `{downloadFolder:'', libraryFolder:''}`; clear both fields; update the buttons; refresh the status; log "⚙ Config reset. Pick a download folder in Settings to continue.". The welcome line is not updated.
- **TIDAL pane**: label "TIDAL account"; `.auth-row` (flex, space-between, centred, gap 12 px) with `#auth-status` and `#auth-btn` (secondary); hint "Required once per device. Opens a browser tab where you log in to TIDAL and click *Allow*." (this `em` uses the browser's default italic, muted). `refreshAuthStatus()`: if the token file exists → "✓ Signed in" (`.auth-status.ok`, `#fff`) and the button reads "Re-authenticate"; otherwise "Not signed in" (`.bad`, `#9a9a9a`) and "Sign in to TIDAL". `.auth-status` is 14 px / 500, `#9a9a9a`. This checks only that the file exists, not that the token is valid.
- **Extension pane** (inventory only; not ported): "Chrome extension bridge", "Local URL" `http://127.0.0.1:${port}` + Copy, "Token" + Copy + "Regenerate" (with a confirm), "Managed extension folder" + Copy + Open, and hints. Copy shows "Copied ✓" for 1200 ms.
- **Updates pane** (`display: flex; flex-direction: column; min-height: 100%`): label "Updates"; `.auth-row` with `#update-status` (`Current version: v${version}`; HTML default "Current version: …") and "Check for updates" (secondary); hint "Checks GitHub for a newer release. If one's found, a download notice appears in the activity log."; `.modal-signature` "made with love by robogears :)" (11 px, `#5a5a5a`, italic, left-aligned, margin `auto 0 -8px 0`). Because the dialog is content-sized, the auto top margin has no free space to use, so the signature sits directly under the hint (inferred; needs a run).
- Check for updates: disable; "Checking…"; then:
  - available → `${r.version} available!`. Main also emits `update:available`, so the pill appears and the log notice is inserted.
  - up-to-date → "Up to date ✓".
  - otherwise, or on an exception → "Check failed".
  - After 2500 ms, re-enable and restore "Check for updates".
- Footer: "Done" (primary, `data-close`).

#### 25. TIDAL sign-in modal — `index.html:206-220`, `styles.css:1001-1014, 1054-1067`, `app.js:1716-1753`, `electron-main.js:614-641`

- Opened by `#auth-btn`:
  1. Clear the terminal and the URL field, set `authUrlRow.hidden = true` (no visible effect; see Bugs), set Copy to "Copy", and call `openModal('auth-modal')`.
  2. `r = await runAuth()`.
  3. If `r.ok`: `refreshAuthStatus()`, then close after **1200 ms**. Otherwise append `\n\n✗ Sign-in failed.` to the terminal; the modal stays open.
- Markup: head h2 "Signing in to TIDAL", with **no close button and no footer**. `.modal-hint` "A browser tab should open automatically. Log in and click *Allow*." (white semibold `em`). `#auth-url-row.auth-url-row` (flex, gap 10 px, margin `12px 0 6px`) holds the readonly `#auth-url-input` (mono, 12 px) and "Copy" (secondary). Then `pre#auth-output.terminal`: background `#0a0a0a`, radius 8 px, padding `14px 16px`, mono 12 px, line-height 1.65, `#9a9a9a`, `max-height: 260px`, scrolls, `pre-wrap`, `break-word`.
- Main calls `shell.openExternal(url)` and sends `auth:url` → the renderer fills the field and unhides the row. Each `auth:output` line (main appends `\n`) is appended to the terminal, which then scrolls to the bottom.
- Lines main sends, in order: `=== TIDAL Login ===`, `Open this URL in your browser and log in:`, ``, `  <verification URL>`, ``, `Waiting for authorization...`. On success: ``, `Authorization successful! token.json saved.`, `User ID: <id>`, `Country: <cc>` (only if present). On failure: `ERROR: <message>`, for example `Device authorization failed: <status> <body>`, `Auth error: {json}` (any 400 other than `authorization_pending`, including an expired code) or `Unexpected poll response: <status> <body>`.
- The poll loop has no timeout of its own. It ends only on success or when TIDAL returns an error. There is no cancel.
- Copy: `navigator.clipboard.writeText`; on failure, `select()` + `execCommand('copy')` + `blur()`. The label reads "Copied ✓" for 1500 ms, then "Copy". With an empty field it does nothing.

#### 26. Sound effects — `app.js:96-270`

- One lazy shared `AudioContext` (`getAudioCtx`), resumed if suspended. Preview decoding uses a separate context. Every effect is a no-op if `AudioContext` is missing.
- Sounds (each starts at `t = currentTime + 0.02`):
  - `playDownloadChime` (Download all; Retry header): two sine pairs, the second oscillator detuned ×1.005. Gain goes 0.0001 → 0.22 in 12 ms → 0.0001 at the end; stop at +0.05. C5 523.25 Hz for 0.13 s at t, then G5 783.99 Hz for 0.18 s at t+0.09.
  - `playCancelChime` (Cancel): G5 for 0.10 s at t, then C5 for 0.15 s at t+0.07.
  - `_honkPair(high, low, {lpFreq = 1800, peak = 0.35})`: sawtooth → lowpass (Q 1) → gain. Frequency starts at f×1.08 and ramps exponentially to f over half the duration. Gain goes 0.0001 → peak in 12 ms → 0.0001. High tone for 0.17 s at t, low tone for 0.22 s at t+0.22.
  - `playWarningHonk` = `_honkPair(220, 165, {lpFreq: 1100, peak: 0.3})`, played when a download or retry is blocked.
  - `playClownHorn` = `_honkPair(420, 310)` is never called.
  - `playSuccessPing` (`download:done` with code 0): sine pairs with an 8 ms attack to 0.22: G5 783.99 for 0.28 s at t, C6 1046.50 for 0.32 s at t+0.07, E6 1318.51 for 0.42 s at t+0.14.
  - `playFart`: see component 6.

#### 27. Boot sequence — `app.js:1943-1995`

1. `settings = await getSettings()`; fill the folder and library fields.
2. `volumeSlider.value = round(getPreviewVolume()·100)` (the squared value).
3. `updateOpenButtonStates()`; `await refreshAuthStatus()`.
4. `getAppVersion()` → topbar `v${v}` and `Current version: v${v}` (not awaited).
5. Welcome line, stored as `welcomeLineEl`, chosen by a second `tokenExists`: no token → "👋 Welcome! Click the ⚙ icon to sign in to TIDAL."; no download folder → "Pick a download folder in Settings to get started."; otherwise `Ready. Downloads go to: ${downloadFolder}`.
6. `saved = await getQueue()`. If it is non-empty: strip the transient fields, assign missing keys, `renderQueue()`, log `↺ Restored ${n} track${s} from your last session.`, and queue preloads for items with an id that are not `notFound`. Errors are ignored.
7. If an update payload arrived earlier, insert the notice now.

Main-process lines can arrive before the welcome line and appear above it, for example "⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.".

#### 28. Scrollbars — `styles.css:1070-1076`

`::-webkit-scrollbar` is 8×8; the track is transparent; the thumb is `#1a1a1a` with radius 4 px, and `#2a2a2a` on hover. This applies to the queue list, the activity log, the modal body and the terminal.

#### 29. Accessibility baseline (current state)

- Present:
  - `aria-label` on the gear ("Settings"), the modal ✕ buttons ("Close"), the volume slider ("Preview volume"), the play buttons ("Play") and the remove buttons ("Remove from queue").
  - `role="tablist"`/`"tab"` on the settings tabs.
  - `role="checkbox"` + `aria-checked` + `tabindex="0"` on the retry checkbox.
  - `aria-hidden` on the logo, volume, play, pause and loading icons.
  - Search rows are `<label>`s that wrap their checkboxes.
- Missing:
  1. Modals: no Escape, no backdrop close, no focus trap, initial focus or focus return, and no `role="dialog"`/`aria-modal`.
  2. Tabs: no `aria-selected`/`aria-controls`, no arrow-key movement, no `role="tabpanel"`.
  3. The retry checkbox can take focus but ignores Space and Enter.
  4. The drop zone is a clickable `<section>` with no `tabindex` and no keyboard activation.
  5. The waveform has no role, label or keyboard seeking.
  6. The play button's label stays "Play" while playing.
  7. `<label class="label">` elements are not linked to their inputs.
  8. The text inputs and the slider set `outline: none`. The only input focus cue is a `#2a2a2a` border on `#0d0d0d` (about 1.4:1). The slider has no focus cue.
  9. The log, the overlay and status-label changes are not announced.
  10. Contrast (computed from WCAG luminance): `#5a5a5a` on `#000` ≈ 3.0:1 and on `#0a0a0a` ≈ 2.9:1, below 4.5:1 for the 11 px labels, placeholders, library note, empty-log hint, ✕ glyph and signature. `#9a9a9a` on `#000` ≈ 7.5:1 passes. The dashed drop-zone border `#1a1a1a` on `#000` ≈ 1.2:1 and the `#2a2a2a` borders on `#0a0a0a` ≈ 1.4:1 are below 3:1.
  11. Secondary and text buttons look the same when disabled.
  12. `user-select: none` blocks copying log and terminal text.
  13. Emoji status glyphs are read aloud by screen readers.
  14. There is no handling for `prefers-reduced-motion`, `prefers-contrast` or light mode.

---

### Data formats

**CSS custom properties** (styles.css:1-22):

| Token | Value | Used for |
|---|---|---|
| `--bg` | `#000000` | page, topbar, modal panel, text on primary buttons, playing play-button icon |
| `--bg-elev` | `#0a0a0a` | inputs, queue panel, notices, terminal, disabled primary, secondary hover, search-row hover, disabled pill, `code` |
| `--panel` | `#050505` | **never used** |
| `--card` | `#0d0d0d` | input focus, row hover, count pill, base badge, play/remove hover, open-folder hover |
| `--border` | `#1a1a1a` | drop-zone dash, modal border, tab rule, log header rules, reset rule, progress tracks, slider track, scrollbar thumb |
| `--border-strong` | `#2a2a2a` | input focus border, secondary/notice/play/checkbox/retry borders, spinner ring, loading-cancel border, scrollbar hover |
| `--text` | `#ffffff` | primary text and fills |
| `--text-muted` | `#9a9a9a` | secondary text |
| `--text-dim` | `#5a5a5a` | captions, placeholders, tertiary |
| `--error` | `#ff6b6b` | errors, failed, cancel, not found |
| `--r-sm` / `--r-md` / `--r-lg` / `--r-pill` | 6 / 8 / 12 / 999 px | radii |
| root `font-size` | 14 px | |
| `--font-mono` | referenced (1012), never defined | |

**Hard-coded colours**: `#e5e5e5` (primary, pill and + Add hover: 106, 223, 697); `#ff8a8a` (cancel hover, 250); `#fff` (drop-link hover 281, ready update button 418); `#000` (update-button text, 401); `rgba(255,255,255,0.45→0)` (pill pulse, 115-116); `rgba(255,255,255,0.03)` (waveform hover, 624); `rgba(255,255,255,0.04)` (downloading row, 709); `rgba(255,107,107,0.06)` (failed row, 708); badge colours as in the Badges table; `rgba(0,0,0,0.7)` (loading scrim, 841); `rgba(0,0,0,0.75)` (modal scrim, 886); `rgba(0,0,0,0.8)` (modal shadow, 907); `rgba(255,255,255,0.5)` (ready ring, 420). Canvas colours: `'#ffffff'` played, `'rgba(255, 255, 255, 0.22)'` unplayed, `'rgba(255, 255, 255, 0.55)'` hover line (app.js:639, 645). Window `backgroundColor '#0a0a0a'` (electron-main.js:79).

**Type scale (as declared)**:

| Size / weight | Where |
|---|---|
| 18 / 700, −0.3 px | modal titles |
| 16 / 700 | brand name |
| 15 / 500 (invalid shorthand) | text inputs |
| 14 / 700, −0.2 px | "Queue" |
| 14 / 600 | drop title (−0.1 px); shared buttons (invalid shorthand) |
| 14 / 500 | auth/library/update status |
| 14 | ✕ remove glyph |
| 13.5 / 500 | queue and search titles |
| 13 / 600 | queue Download button; tabs (invalid shorthand) |
| 13 | modal hint; loading text (500) |
| 12.5 | hints, drop subtitle, activity log (mono, line-height 1.7) |
| 12 | artist/meta lines, retry/notice/open-folder buttons (600), terminal (mono, 1.65), auth URL (mono), batch label (600, tabular), `code`, + Add (invalid shorthand) |
| 11.5 | library note (mono) |
| 11 | captions and the Activity header (600, uppercase, 1.2 px), version (700), pill (700, 0.3 px), count pill (600), signature (italic) |
| 10 / 600 | badges (uppercase, 0.6 px) |

Where the `font: Npx inherit` shorthand is used, the size is dropped. Those controls render at Chromium's form-control default, expected to be about 13.33 px system font (unverified; needs a run). Their separate `font-weight` declarations still apply.

**Spacing and shape**: page side margin 28 px (topbar padding `16px 28px`; main `12px 28px 28px`); main gap 22 px; caption → control 12 px; hint top 12 px; field rows gap 10 px; queue panel padding 14/16/12; queue head bottom 10 px; rows padding 8×10, gap 12, list gap 2; modal head 20/26/16, body 4/26/18, foot 16/26/22, foot gap 12; tabs 10×16, gap 4, bottom margin 22; reset section 28 + 24; drop-zone inner 36×18. Radii: 4 px (waveform, checkbox, code, scrollbar), 6 px (icon and small buttons), 8 px (inputs, buttons, rows, notices, terminal), 12 px (drop zone, queue panel, modal), 999 px (pill, badges, count, progress tracks, slider), 50 % (play button, thumb, spinner). Shadows: the modal shadow, the 1 px ready ring and the pill pulse only.

**Motion inventory**:

| Effect | Spec | Where |
|---|---|---|
| Pill pulse | 2.4 s ease-in-out infinite box-shadow ring (enabled pill only) | css 103, 114-117 |
| Spinner | `spin` 0.8 s linear infinite | css 863, 865 |
| Play button loading | `qi-play-spin` 1.2 s linear infinite, whole button rotates | css 595-600 |
| Modal entry | `fadein` 0.15 s, opacity only, no exit | css 893, 896 |
| Buttons | background/colour/border/opacity 0.15 s; transform 0.05 s; primary `:active` translateY(1 px) | css 215, 224 |
| Inputs | background/border 0.15 s | css 181 |
| Drop zone | border/background 0.2 s; icon colour 0.2 s | css 272, 295 |
| Rows / search rows | background 0.1 s | css 527, 811 |
| Small controls | remove, play, checkbox, + Add, open-folder, tabs, icon-btn, pill: 0.15 s; update button opacity 0.15 s; waveform background 0.12 s; slider thumb transform 0.1 s with hover scale 1.18 | css 129, 99, 393, 409, 499-502, 558, 579, 621, 692, 750, 970 |
| Progress | row fill width 0.18 s ease-out; batch bar width 0.25 s ease-out | css 721, 779 |
| JS timing | loading text 2500 ms; "Copied ✓" 1500 ms (auth) / 1200 ms (extension); update-check label 2500 ms; auth modal closes 1200 ms after success; queue save 400 ms; volume save 300 ms; resize redraw 120 ms; preview progress per animation frame | app.js |

**Queue item (UI-relevant fields)**:

```
{
  key: string,               // 8-char base36, renderer-assigned
  tidalId: number | null,
  title: string,
  artist: string,            // comma-joined names
  duration: number,          // seconds; 0/absent → no "· m:ss"
  album?: string,            // search results only
  source: 'tidal' | 'spotify' | 'import' | 'extension',
  matchMethod?: 'direct' | 'search' | ... | null,
  hiRes?: boolean,           // absent on imports
  notFound?: boolean,
  originalTitle?, originalArtist?,  // imports
  libraryMatch?: { kind: 'exact' | 'similar', path: string, libraryTitle?: string },
  included?: boolean,        // defaulted lazily to !exact, then persisted
  dlStatus?: 'queued'|'downloading'|'downloaded'|'skipped'|'failed'|'notFound',  // transient
  dlPercent?: number,        // 0-100, transient
  selected?: boolean         // transient
}
```

Saved to `<userData>/queue.json` without `dlStatus`, `dlPercent` and `selected`. Rows are found by `data-tidal-id`, so a `tidalId` must be unique in the queue (the add-time dedupe ensures this).

**Settings (renderer view)**: `{ downloadFolder: string ('' = unset), libraryFolder: string ('' = duplicate check off), volume?: number 0..1 (slider position) }`. Main writes the whole object as given. Reset writes exactly `{downloadFolder:'', libraryFolder:''}`.

**IPC payloads the UI consumes** (producers belong to other sections):

| Channel | Shape |
|---|---|
| `update:available` (event) | `{ version: tag_name, downloadUrl, releaseUrl }` |
| `update:download-progress` (event) | `{ downloaded, total }` (total 0 if unknown) |
| `update:check` | `{ status: 'available', version, downloadUrl, releaseUrl }` / `{ status: 'up-to-date', version }` / `{ status: 'error', message }` |
| `update:download` | `{ ok: true, path }` / `{ ok: false, error }` |
| `update:apply` | `{ ok: true }` (quit after 500 ms) / `{ ok: false, error }`, ignored by the UI |
| `resolve:input` | `{ ok: true, kind: 'url', tracks, capped }` / `{ ok: true, kind: 'search', tracks }` / `{ ok: false, cancelled: true }` / `{ ok: false, error }` |
| `resolve:tracklist` | `{ ok: true, tracks }` / `{ ok: false, error }` |
| `tracklist:progress` (event) | `{ done, total }`, sent from 0 to n |
| `library:status` | `{ count, path }` |
| `library:rescan` | `{ ok: true, count }` |
| `library:scanned` / `library:scan-progress` (events) | `{ count }` / `{ done, total }` |
| `bulk:track-start` / `-progress` / `-done` (events) | `{ tidalId }` / `{ tidalId, percent }` / `{ tidalId, status }` |
| `download:line` (event) | string (blank lines dropped by main) |
| `download:done` (event) | `{ code }` (`null` after a kill) |
| `bulk:start` | resolves at batch end `{ ok: code===0, code }`, or immediately `{ ok: false, error }` |
| `auth:output` / `auth:url` (events) | `line + '\n'` / URL string |
| `token:run-auth` | `{ ok: true }` / `{ ok: false, error }` |
| `preview:get-audio` | `{ ok: true, audioBytes: Buffer, mimeType }` (mime `audio/flac` or `audio/mp4`) / `{ ok: false, error }` |

#### Copy deck: static strings (index.html)

| Line | Text |
|---|---|
| 6, 21 | robogears Downloader |
| 23 | Update now |
| 25 | (title/aria) Settings |
| 35 | Paste a link or search for a song *(shown uppercase)* |
| 37 | placeholder: Spotify/TIDAL URL or song name... |
| 38 | Add to queue |
| 40 | Paste a Spotify or TIDAL link to add all its tracks. Or type a song name to search. |
| 51 | Drop a playlist CSV or paste tracks |
| 52 | For playlists over 100 tracks — export via **Exportify** and drop the CSV here |
| 61 | Queue · count "0" |
| 62, 68 | (title/aria) Preview volume |
| 72-75 | Cancel · ↻ Retry all · Clear all · Download all |
| 83-84 | Activity · Clear (title "Clear") |
| 94, 98 | Search results · Pick the tracks to add to your queue. |
| 95, 113 | ✕ (aria "Close") |
| 102-103 | Cancel · Add selected |
| 112 | Settings |
| 117-120 | Folders · TIDAL · Extension · Updates |
| 125 | Download folder |
| 128, 136 | Browse… |
| 129, 137 | Open (title "Open folder") |
| 131 | Every download goes here directly — no subfolders. |
| 133 | Music library folder (for duplicate check) |
| 135 | placeholder: (none — duplicate check disabled) |
| 138 | Clear (title "Clear") |
| 141, 156 | … |
| 142 | Refresh |
| 144 | Read-only. The app reads audio-tag metadata (title, artist, duration) as well as filenames. Re-scans automatically on each launch. |
| 147-148 | Reset config · Forgets your download and library folder choices. TIDAL sign-in is kept. |
| 154, 157 | TIDAL account · Sign in to TIDAL |
| 159 | Required once per device. Opens a browser tab where you log in to TIDAL and click *Allow*. |
| 164-185 | Extension tab (not ported) |
| 190, 192-193 | Updates · Current version: … · Check for updates |
| 195 | Checks GitHub for a newer release. If one's found, a download notice appears in the activity log. |
| 196 | made with love by robogears :) |
| 200 | Done |
| 209 | Signing in to TIDAL |
| 212 | A browser tab should open automatically. Log in and click *Allow*. |
| 215 | Copy |
| 227-228 | Loading… · Cancel |
| css 344 | Nothing yet. Paste a link above to get started. |
| css 759 | ✓ (checkbox mark) |

#### Copy deck: dynamic labels and states (app.js)

| Line | Text |
|---|---|
| 272-281 | FUNNY_LOADING: Searching the seven seas for your music… · Digging through the record crates… · Asking TIDAL nicely… · Following the bass line… · Tracking down these bangers… · Bribing the algorithm… · Polishing the vinyl… · Listening for the drop… · Tuning the frequencies… · Whispering to the music gods… |
| 307, 319 | Cancel · Cancelling… (overlay) |
| 382, 385 | 🚀 New version available: **{version}** · Download update |
| 404, 409, 415, 419 | Starting… · Download failed — retry · Restart to apply · Restarting… |
| 428/485, 430/487 | Downloading {pct}% · Downloading {x.x} MB |
| 449, 464, 470, 475 | Update now · Downloading… · Retry update · Restarting… (pill) |
| 913-922 | ↓ {pct}% · ✓ done · ⏭ skipped · ✗ failed · not found (title "Not on TIDAL") · 📁 already in library · ⚠ similar version in library · Spotify · Import · Spotify ext |
| 926, 929 | Hi-Res · Library: {libraryTitle} |
| 933, 936 | + Add (title "Add to download list") · ↻ Retry (title "Re-download this track") |
| 946, 952, 955 | titles: Select for batch retry · Play preview (aria "Play") · Click or drag to scrub |
| 968, 974 | {artist} · {m:ss} · ✕ (aria "Remove from queue") |
| 1001, 1003 | Downloading… / Download ({n}) · Download all |
| 1014, 1017 | ↻ Retry selected ({n}) · ↻ Retry all ({n}) |
| 1047 | {done} / {total} |
| 1280, 1281 | Detected a link — will resolve all tracks on add. · Type to search TIDAL by song name (or paste a link). |
| 1331, 1332 | Search results for "{query}" · {n} result(s). Pick the ones to add to your queue. |
| 1341 | {artist} · {album} · {m:ss} |
| 1368, 1378 | Cancel · Cancelling… (queue) |
| 1490, 1495 | **✓ Batch finished.** · Open folder |
| 1556/1677, 1560, 1563 | Scanning… · {count} files indexed · Scan failed |
| 1570 | confirm: Forget the download folder and music library folder?⏎⏎(Your TIDAL sign-in stays.) |
| 1652, 1657, 1662, 1664/1667, 1651 | Checking… · {version} available! · Up to date ✓ · Check failed · Check for updates |
| 1680, 1681, 1683, 1696 | {n} file(s) indexed · (no library folder set) · (scan failed) · Scanning {done} / {total}… |
| 1706-1712 | ✓ Signed in · Re-authenticate · Not signed in · Sign in to TIDAL |
| 1720/1752, 1751 | Copy · Copied ✓ |
| 1727 | ⏎⏎✗ Sign-in failed. |
| 1827/1841 | Matching {done} / {n} tracks on TIDAL… |
| 1954, 1957 | v{version} · Current version: v{version} |

#### Copy deck: activity-log messages written by the renderer

| Line | Message |
|---|---|
| 871 | ✗ Preview playback failed ({code or ?}). |
| 879 | ✗ Preview: {message} |
| 1099 | ⚠ A batch is already running — retry once it finishes. |
| 1104, 1405, 1423 | ⚠ Pick a download folder in Settings first. |
| 1110 | ↻ Retrying {title}… |
| 1291, 1428 | ⚠ Sign in to TIDAL first (Settings → Sign in). |
| 1302 | ⊗ Resolve cancelled. |
| 1303, 1323, 1845, 1853 | ✗ {error} |
| 1309 | + Added {n} track(s) from link[ ({m} not on TIDAL)]. |
| 1314 | ⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren't included. |
| 1355 | + Added {n} track(s) from search. |
| 1390 | ⊗ Download cancelled. |
| 1415 | ↻ Retrying {n} track(s)… |
| 1437 | ⚠ Nothing in the queue can be downloaded. |
| 1443-1444 | *(2 px spacer)* · === Starting batch ({n} tracks) === |
| 1463 | === Exit code {code} === |
| 1538 | 📁 Music library folder set to: {folder} |
| 1551 | 📁 Music library folder cleared (duplicate check disabled). |
| 1561 | 📁 Library re-scanned: {count} files indexed. |
| 1576 | ⚙ Config reset. Pick a download folder in Settings to continue. |
| 1780, 1791 | ✗ Couldn't read {file}: {message} |
| 1834 | ✗ No tracks found in {source}. |
| 1837 | 📋 Parsed {n} track(s) from {source}. Matching against TIDAL… |
| 1850 | + Added {added} from import. {matched} matched on TIDAL[, {missing} not found]. |
| 1961, 1963, 1965 | 👋 Welcome! Click the ⚙ icon to sign in to TIDAL. · Pick a download folder in Settings to get started. · Ready. Downloads go to: {folder} |
| 1981 | ↺ Restored {n} track(s) from your last session. |

`{source}` is the file name or "pasted text". Plurals use a `'s'` ternary, except "=== Starting batch ({n} tracks) ===" and "{count} files indexed" (Refresh), which are always plural.

#### Copy deck: log lines produced outside the renderer (for styling reference)

- Main: "⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this."; `ERROR: {message}` (auth terminal); extension lines (🎵, 🧩, "⚠ Chrome-extension bridge couldn't start: …", "⚠ Extension match failed: …"), which are not ported.
- `bulk_runner.js`: `=== Batch download → {outDir} ===`, `{n} tracks queued.`, `[{i}/{n}] {title} — {artist}`, `    → matched (id {id}, score {s})`, `    → no good match`, `    → search error: {msg}`, `=== Batch complete: {ok} downloaded, {skipped} skipped, {failed} failed, {notFound} not found ===`, `Fatal: {msg}`. Lines `__TRACK_START__:<id>`, `__TRACK_PROGRESS__:<id>:<pct>` and `__TRACK_DONE__:<id>:<status>` are routed to events and never reach the log.
- `tidal_download.js` (per track): `  ⏭  {title}.flac already in downloads folder — skipping (use --force to overwrite)` (also `.m4a`); `  {artist} — {title} ({album})`; `  ⚠ AAC-only on TIDAL — skipped (--flac-only mode).`; `  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).`; `  ✘ FFmpeg failed: {msg}` + `     Raw file kept at: {tmp}`; `  ⚠ FLAC integrity check failed: {msg}`; `  ✓ Saved: {file} ({MB} MB)`; `Error: {msg}`. The library-check lines (`  📁 Already in music library: …`, `  ⚠ Similar version in music library: …`) appear only from the CLI, because GUI batches pass `--skip-library-check`.

---

### External interfaces

| Interface | Detail |
|---|---|
| Renderer → main invoke channels (electron-preload.js:4-66) | `settings:get`, `settings:save`, `settings:reset`, `settings:pick-folder`, `open-folder`, `shell:open-external` (main allows only `^https?://`), `update:check`, `app:version`, `update:can-self-install`, `update:download`, `update:apply`, `token:exists`, `token:run-auth`, `download:cancel`, `bulk:start`, `resolve:input`, `resolve:cancel`, `resolve:tracklist`, `preview:get-audio` (`{tidalId}`), `queue:get`, `queue:save`, `library:status`, `library:rescan`; extension-only (not ported): `extension:info`, `extension:regenerate-token` |
| Main → renderer events | `update:available`, `update:download-progress`, `auth:output`, `auth:url`, `download:line`, `download:done`, `bulk:track-start`, `bulk:track-progress`, `bulk:track-done`, `tracklist:progress`, `library:scanned`, `library:scan-progress`; extension-only: `extension:tracks-resolved` |
| Exportify | `https://exportify.net` opened in the default browser (app.js:1815) |
| Native dialogs | `window.confirm` (Reset config; Regenerate token); `dialog.showOpenDialog(mainWindow, {properties:['openDirectory'], defaultPath: saved downloadFolder})` for **both** folder pickers (electron-main.js:567-573); `<input type=file accept=".csv,.txt,text/csv,text/plain">` |
| Clipboard | `navigator.clipboard.writeText` with an `execCommand('copy')` fallback (auth URL, extension fields); a document `paste` listener reads `text/plain` |
| Finder / Explorer | `shell.openPath(path)` for the Open buttons and "Open folder" |
| CSP | see component 1 |

---

### Constants and magic values

| Name | Value | Location | Meaning |
|---|---|---|---|
| Window size / minimum | 980×740 / 720×540 | electron-main.js:75-78 | outer window size |
| Window backgroundColor | `#0a0a0a` | electron-main.js:79 | pre-paint fill |
| `ACTIVITY_LOG_MAX` | 2000 | app.js:54 | log row cap |
| `PREVIEW_FEATURE_ENABLED` | `true` | app.js:58 | play button and waveform on |
| `URL_RE` | `/^https?:\/\/\|spotify\.com\|tidal\.com/i` | app.js:66 | hint text only |
| `TRANSIENT_QUEUE_FIELDS` | `['dlStatus','dlPercent','selected']` | app.js:71 | stripped before saving |
| Queue save debounce | 400 ms | app.js:82 | |
| Volume save debounce | 300 ms | app.js:523 | |
| Default volume | slider 0.5 → audio 0.25 | app.js:511 | |
| Loading text rotation | 2500 ms | app.js:302 | |
| `MAX_AUDIO_CACHE` | 3 | app.js:549 | preview Blob URL LRU |
| Preloader concurrency | 2 | app.js:558 | |
| Waveform bars | 200 | app.js:686 | |
| Bar height factor | 0.78 × canvas height | app.js:638 | |
| Spotlight | radius 10 bars, up to +45 % | app.js:633-636 | |
| Waveform canvas height | 22 px | app.js:955; css 616 | |
| Resize redraw debounce | 120 ms | app.js:1221 | |
| "Copied ✓" | 1500 ms (auth), 1200 ms (extension) | app.js:1752, 1620 | |
| Update-check label revert | 2500 ms | app.js:1672 | |
| Auth modal auto-close | 1200 ms after success | app.js:1725 | |
| Quit after apply | 500 ms | electron-main.js:467 | |
| Paste import gate | length ≥ 10 and (`\n` or `,` or `/\s[-—–\|]\s/`) | app.js:1804-1805 | |
| CSV title header | `/\btrack name\b\|\btitle\b\|\bsong\b\|\bname\b/` | app.js:1903 | first match |
| CSV artist header | `/artist/` | app.js:1904 | first match |
| Plain-text split | `/^(.+?)\s*[-—–\|\t]\s*(.+)$/` | app.js:1928 | title, then artist |
| Minimum plain-text title | 2 characters | app.js:1932 | |
| Exportify URL | `https://exportify.net` | app.js:1815 | |
| Search result count | 10 | electron-main.js (resolve:input) | |
| Queue max height | 36vh | css 431 | |
| Modal size | `min(560px, 92vw)` × max 86vh | css 902-903 | |
| Terminal max height | 260 px | css 1062 | |
| Z-order | modal 50, overlay 100 | css 847, 892 | |
| Scrim blur | 8 px | css 842, 887 | |
| Main height | `calc(100vh - 60px)` | css 141 | |
| Sound frequencies | C5 523.25, G5 783.99, C6 1046.50, E6 1318.51 Hz; honk 220/165 Hz (warning), 420/310 Hz (unused); joke sound 95→48 Hz × pitchScale | app.js:134-269 | |

---

### Rules and invariants

1. The look is monochrome and dark only. Red, amber and green each mean one thing: error/fail, similar version, done (styles.css:1-19, 660-703).
2. White-filled buttons mark the main action of each area: "Add to queue", "Download all", "Add selected", "Done", "+ Add", the update button and the pill. Everything else is a text or outlined button.
3. Section captions are 11 px, semibold, uppercase, 1.2 px tracking, `#5a5a5a`.
4. One preview is meant to play at a time. Starting another, removing the playing row and Clear all each stop the current preview first (app.js:807, 1120, 1249). A rapid second click during loading breaks this (see Bugs).
5. A row title is never shortened. The waveform shrinks to zero width first (styles.css:611-645).
6. Rows that are not found have no preview controls. Rows that are downloading hide the waveform; their play button stays (styles.css:630-635; app.js:951-956).
7. Exact library matches start excluded (faded, struck through, "+ Add" to opt in). Similar matches start included with an amber badge. The default is written once into `included` (app.js:901).
8. The Download button reads "Download (N)" whenever any item is excluded or not found, and "Download all" otherwise. It is disabled while downloading or when nothing can be downloaded (app.js:998-1004).
9. Each row has exactly one status badge, by fixed priority: download state > not found > exact > similar > source. The Hi-Res badge is independent and comes first (app.js:912-926).
10. The Retry header button is hidden while downloading. It reads "Retry selected (M)" when at least 1 failed row is ticked, "Retry all (N)" when at least 2 have failed, and is hidden otherwise. Checkboxes appear only on failed rows that have a `tidalId` (app.js:944-947, 1010-1020).
11. When a batch ends, the queue keeps only not-found rows, failed rows, and included rows with no status. Downloaded, skipped, excluded and still-queued rows all leave (app.js:1468-1473).
12. A download needs a download folder and a token file. A blocked attempt honks and logs a ⚠ line. A resolve needs the token only. Retries check the folder but not the token (app.js:1102-1106, 1290-1293, 1403-1430).
13. The log is capped at 2000 rows, never trims the welcome line, and always jumps to the newest row (app.js:342-359).
14. The update notice sits directly under the welcome line and is inserted at most once per session, and never after the log has been cleared. The pill and the notice run separate state machines over the same IPC (app.js:371-489).
15. Transient fields never persist. The queue is saved 400 ms after any user change (app.js:71-83).
16. Preview volume = slider position squared (app.js:506-509).
17. The loading overlay always covers modals. Only the URL/search resolve can be cancelled (styles.css:847, 892; app.js:1295-1298, 1841).
18. The library folder is read-only. The UI only shows match paths, in tooltips and the "Library:" note.

---

### Edge cases and failure modes

- **Empty queue**: the queue panel is hidden and the log grows into its space (app.js:892).
- **Empty log** (at boot before the welcome line, or after Clear): the italic placeholder shows (styles.css:343-347).
- **Search with 0 results**: the modal says "0 results. Pick the ones to add to your queue." with an empty list. "Add selected" does nothing, and so does an empty selection.
- **Every track of a link already queued**: "+ Added 0 tracks from link." and the field is still cleared.
- **No duration**: the queue meta drops " · m:ss". The search meta becomes `artist · album · ` with a trailing separator. With no album it shows `artist ·  · m:ss` (app.js:968, 1341).
- **Unknown update size**: the label shows "Downloading X.X MB".
- **`canSelfInstall` false** (dev or Linux): both update controls open the asset URL in the browser.
- **Update event before the welcome line**: it is stashed and inserted at the end of boot. After the log has been cleared, it is stashed and never shown; the pill still appears.
- **Waveform click before peaks load**: playback still starts from the clicked ratio, and the canvas paints once peaks arrive.
- **Zero-width or hidden waveform**: `clientWidth` is 0, so `drawWaveform` falls back to the canvas's own backing width (`canvas.width`) instead of 0. With a pixel ratio of 2, each redraw doubles the backing store. If the canvas is `display:none` (a downloading row whose preview is playing), height doubles too, frame after frame, until allocation fails (app.js:611-616; inferred; size of the effect needs a run). Nothing is visible because the canvas is hidden or zero-width.
- **Multiple dropped files**: only the first is imported. **Non-text file dropped on the zone**: it is read as text, and every line of 2+ characters becomes a search query (no type check on drop).
- **File dropped outside the drop zone** (including onto a modal or the loading overlay): no handler calls `preventDefault`, and main has no `will-navigate` guard. Chromium's default is likely to navigate the window to the dropped file and replace the app UI (inferred; needs a run).
- **Second import while one is matching**: silently ignored.
- **Paste while a modal is open** with focus outside an input: an import starts behind the modal.
- **Overlapping operations share one overlay**: a paste import during a URL resolve replaces the overlay text and hides its Cancel; whichever finishes first hides the overlay while the other is still running.
- **Cancel during a batch**: main kills the batch process at once. That process started the per-track downloader with inherited stdout, so the downloader keeps running and keeps main's pipe open. `download:done` (code `null`, logged as "=== Exit code null ===") therefore probably arrives only when the in-flight track finishes. Until then Cancel stays "Cancelling…" and the Download button stays "Downloading…". That track's file may still be saved while its row shows "failed" (bulk_runner.js:41-44; electron-main.js:646-653, 1033-1035; inferred; needs a run).
- **Batch ends abnormally** (`Fatal:` at start, for example a token refresh failure, or a crash): rows still `queued`/`downloading` are dropped from the queue and the shorter queue is saved (see Bugs).
- **Tracks added during a batch** (Enter, search, import and paste all still work): included ones count in the batch total but never finish, so the batch bar cannot reach 100 %. Excluded ones are dropped at the end of the batch.
- **Retry of a subset**: the batch total counts every included non-not-found item in the queue, not only the retried ones.
- **Queue dedupe is case-sensitive** for items without an id: `Song|Artist` and `song|artist` are both added.
- **Hyphenated names in plain-text import**: `Re-Wind - Artist` splits into title "Re" and artist "Wind - Artist".
- **CSV header order**: if a header containing "name" (for example "Artist Name") comes before the title column, `titleIdx` picks it and title and artist are both read from that column.
- **Renderer reload** (View → Reload in the default menu) during a batch: renderer state resets while the batch keeps running. A new Download attempt then gets `{ok:false, error:'Another download is already running.'}`, which the UI ignores, and stays "Downloading…" until the old batch's `download:done` arrives.
- **Open with a deleted folder**: `shell.openPath` fails and nothing visible happens.
- **Resolve during a rebuild**: when `renderQueue` runs while a preview is loading, the rebuilt play button shows the play icon instead of the spinner until playback starts.

---

### Bugs and oddities

| # | Severity | Finding | Evidence |
|---|---|---|---|
| 1 | Medium | **The TIDAL sign-in modal cannot be dismissed.** It has no ✕, no footer, no `[data-close]` and no Escape handling. It stays open both while waiting (the poll has no timeout of its own and no cancel) and after a failure, which only appends "✗ Sign-in failed.". The only ways out are quitting, closing and reopening the window (macOS), or View → Reload. Nothing is lost, but the whole app is blocked. | index.html:206-220; app.js:1716-1729; tidal_auth_node.js:133-169 |
| 2 | Medium | **Rapid preview clicks play two tracks at once.** `togglePreview` does not check whether a newer request replaced it during the long `getPlayableEntry` fetch, and `playingTidalId` stays null until the fetch resolves. A second click (another row, or the same row's waveform) during loading starts a second request. Both create `Audio` elements and both play; the first is orphaned and cannot be paused or volume-controlled until it ends. Both buttons show pause. | app.js:792-829, 875 |
| 3 | Medium | **Queued or in-flight rows are deleted when a batch exits without final statuses.** The post-batch filter keeps only notFound / failed / notFound-status / (no status and included). Rows still `queued` or `downloading` after a `Fatal:` exit or a crash are removed and the shorter queue is saved. | app.js:1468-1481; bulk_runner.js:115-118 |
| 4 | Medium | **The volume slider is restored from the squared value.** Boot sets the slider to `round(volume² × 100)`. With the default 0.5 it shows 25 while audio plays at 0.25. The first nudge stores about 0.25, so audio drops to about 0.06, and each later launch shows a lower position. The comment's "60 %" matches neither value. | app.js:1947-1948, 510-513 |
| 5 | Medium | **The Exportify link also opens the file picker.** Its handler calls `preventDefault` but not `stopPropagation`, so the click bubbles to the drop zone, which calls `fileInput.click()`. | app.js:1763, 1813-1816; index.html:52 |
| 6 | Low | **Excluded exact-match rows disappear after any batch**, including a one-row retry or a cancelled batch, because `(!dlStatus && included)` is false for them. This is not mentioned in the code comment. | app.js:1465-1473 |
| 7 | Low | **The batch "N / M" counter is never visible.** The label is absolutely positioned at `top: -22px` inside a 5 px box with `position: relative; overflow: hidden`, so it is clipped. | styles.css:767-789; app.js:1043-1047 |
| 8 | Low | **`font: Npx inherit` is invalid CSS** (`inherit` cannot be a family name inside the shorthand), so these declarations are dropped. Text inputs (15 px), every primary/secondary/text button (14 px), `.qi-add` (12 px), tabs (13 px) and the unused password input fall back to Chromium's control default font. The rendered size needs a run. Longhands still work: `.queue-actions .primary-btn` 13 px, the auth URL input 12 px. | styles.css:177, 210, 687, 966, 1022 |
| 9 | Low | **`#auth-url-row` shows even when `hidden`.** `.auth-url-row { display: flex }` overrides the browser's `[hidden]` rule, and no `.auth-url-row[hidden]` rule exists, so an empty URL field and Copy button show before the URL arrives. | styles.css:1001-1009; index.html:213; app.js:1719 |
| 10 | Low | **Failed apply leaves the UI stuck.** `api.applyUpdate()` results are ignored. `{ok:false}` (for example "No downloaded update available") or a thrown write error leaves the pill or notice disabled at "Restarting…". | app.js:420, 476; electron-main.js:314-319 |
| 11 | Low | **Clearing the log loses later update notices.** `innerHTML = ''` detaches the welcome line; later `update:available` payloads are stashed in `pendingUpdate`, which is replayed only at boot. | app.js:361, 371-375, 1990-1994 |
| 12 | Low | **The pill resets mid-download.** Every `update:available` sets it to "Update now" and enabled, even while downloading or restarting, so a manual check allows a second download. | app.js:444-450 |
| 13 | Low | **Enter can start overlapping resolves.** The overlay blocks only the pointer, Enter has no in-flight guard, and each new resolve resets main's cancel flag. | app.js:1285-1300; electron-main.js:659 |
| 14 | Low | **Plain-text import splits at the first separator.** The lazy regex with optional spaces breaks "Jay-Z", "Re-Wind" and similar names. | app.js:1928 |
| 15 | Low | **The CSV title regex also matches "name".** A header like "Artist Name" before the title column becomes the title column. | app.js:1903 |
| 16 | Low | **Reset config forgets the preview volume.** Main writes exactly `{downloadFolder:'', libraryFolder:''}`. The slider keeps its position but audio falls back to the 0.25 default; the hint says only folders are forgotten. | electron-main.js:561-565; app.js:1571 |
| 17 | Low | **Long titles overflow the row.** The title is `flex: 0 0 auto; overflow: visible`, and nothing clips `.qi-info`. A title wider than the column paints under the transparent ↻ Retry / ✕ buttons and may add horizontal scrolling to the queue list (inferred from CSS; needs a run). | styles.css:533, 640-645, 513-520 |
| 18 | Low | **Dropping a file outside the zone** probably navigates the window to the file. No document-level drop guard and no `will-navigate` handler exist (inferred; needs a run). | app.js:1765-1782; electron-main.js:73-99 |
| 19 | Low | **The version string is inserted unescaped** into `innerHTML`. The CSP allows inline script; the source is the owner's own release feed. | app.js:382 |
| 20 | Low | **Text cannot be selected or copied** anywhere outside inputs (log errors, the sign-in terminal). | styles.css:36, 40 |
| 21 | Low | **Hidden or zero-width waveform canvases grow on every redraw** (see Edge cases). | app.js:611-616 |
| 22 | Info | Topbar height (~68 px) and `calc(100vh - 60px)` disagree, so about 8 px of the bottom padding is clipped (needs a run). | styles.css:47, 124, 141 |
| 23 | Info | Secondary and text buttons have no disabled style: "Open" with no folder, "Refresh" while scanning, "Check for updates" while checking, "Clear all" during a batch, and both "Cancelling…" states look enabled and still change colour on hover. | styles.css:231-258 |
| 24 | Info | Some hover backgrounds match their surroundings: `.retry-all-btn:hover` `#0a0a0a` on the `#0a0a0a` panel, and `.qi-remove:hover` `#0d0d0d` on a row already `#0d0d0d` on hover. Failed and downloading rows have no hover change. | styles.css:255-258, 529, 560-563, 708-709 |
| 25 | Info | The `summary` log style never applies in GUI batches: "=== Batch complete: …" matches `/^===/` (header) first. | app.js:336-337; bulk_runner.js:114 |
| 26 | Info | The `skip` rule tests "📁 Already in library", but the downloader prints "📁 Already in music library: …", and GUI batches skip the library check anyway. | app.js:334; tidal_download.js:374 |
| 27 | Info | "⚠ Nothing in the queue can be downloaded." can never fire from a click, because the button is already disabled in that state. | app.js:999, 1434-1438 |
| 28 | Info | Dead code and styles: `playClownHorn`; `searchDebounce`; `--panel`; the `textarea`, `input[type=password]`, `.cred-row`, `.auth-section` and `.updates-section` rules; `.drop-zone { position: relative }`; undefined `--font-mono`; the unreachable `dl-notFound` path (bulk_runner prints `notFound` only when `t.tidalId` is set, and such tracks never reach that branch); `.dl-queued`/`.dl-notFound` have no CSS; `.notfound` preview-hiding rules target elements that never exist. | app.js:64, 194; styles.css:5, 197-204, 273, 1002, 1012, 1016-1039; bulk_runner.js:92-97 |
| 29 | Info | Stale comments: "screenshot OCR" (app.js:2; bulk_runner.js:2; electron-main.js:984); self-install "Windows portable" only (app.js:390-391; electron-preload.js:18-19; electron-main.js:189-191); a "60 %" default volume (app.js:1947). | as listed |
| 30 | Info | Copy inconsistencies: "(1 tracks)" and "1 files indexed" never singular; "Copied ✓" lasts 1200 ms in one place and 1500 ms in the other; the placeholder uses "..." while every other string uses "…"; the TIDAL-tab *Allow* is muted italic while the sign-in modal's is white semibold (only `.modal-hint em` is styled). | app.js:1444, 1560, 1620, 1752; index.html:37, 159, 212 |
| 31 | Info | Imported rows never show Hi-Res (the tracklist resolver sets no `hiRes`). Search results do not show library status, yet a library match lands in the queue excluded. | electron-main.js:961-973; app.js:1337-1343 |

---

### Platform-specific behaviour

- Font stacks list Apple faces first. On macOS they resolve to SF Pro and SF Mono; the Windows faces (Segoe UI Variable, Cascadia Mono, Consolas) are fallbacks.
- `-webkit-font-smoothing: antialiased` affects only macOS.
- `autoHideMenuBar` affects only Windows and Linux. No menu is built, so macOS shows Electron's default menu, which includes View → Reload and Toggle Developer Tools.
- The native frame stays. On macOS a standard title bar (which follows the system appearance; needs a run to confirm the look) sits above the black page, and the HTML topbar is a second drag area.
- `::-webkit-scrollbar` styling replaces macOS overlay scrollbars with an always-styled 8 px bar. `::-moz-range-thumb` is never used.
- `backdrop-filter: blur(8px)` is used for both scrims.
- `window.confirm` appears as a native message box.
- `canSelfInstall` is true only for packaged win32 and darwin builds. In dev and on Linux both update controls open a URL.
- On macOS, closing the window does not quit the app (`window-all-closed`). The Dock icon recreates the window with fresh renderer state; the queue is restored from disk.

---

### Porting notes for a native Swift macOS app

| Topic | Now | Swift needs | Difficulty |
|---|---|---|---|
| Colour tokens | `:root` variables and literal rgba, dark only | An asset-catalog colour set with the same values; decide the Light-mode and Increase Contrast mapping (for example raise `#5a5a5a` and `#1a1a1a`) | Easy |
| Topbar | HTML header with `-webkit-app-region: drag` under a native title bar | A window toolbar or titlebar accessory for brand, version and update control; Settings moves to the app menu (Settings… ⌘,) | Easy |
| Modals | HTML overlays toggled with `hidden`, 0.15 s fade, no Escape or focus handling | Sheets for search results and sign-in (with Cancel); a separate Settings scene with Folders / TIDAL / Updates tabs (Extension dropped); standard Escape and ⌘. dismissal and focus | Easy |
| Loading overlay | Fixed blurred scrim, spinner, rotating text, optional Cancel | A progress sheet or inline `ProgressView` with label and Cancel; a 2.5 s timer for text; block keyboard input too; one owner per operation | Easy |
| Queue list | `innerHTML` rebuilt on every change, plus in-place percent updates | `List`/`Table` bound to an observable model; row subviews for checkbox, play, title + waveform, meta + badges, library note, progress, actions | Medium |
| Waveform peaks | `decodeAudioData` on fetched bytes; channel 0 max-abs per window, normalised, 200 bars | AVAudioFile/AVAssetReader to PCM off the main thread; same 200 normalised peaks. Whether AVFoundation reads TIDAL's segment-joined fragmented MP4 (FLAC in MP4) directly is unverified | Medium |
| Waveform drawing and scrub | Canvas 2D with DPR, rAF repaint, document-level drag | SwiftUI `Canvas` or `NSView draw(_:)` with the same bar math; hover via `onContinuousHover`/`NSTrackingArea`; drag gesture seeks continuously; `TimelineView` or a display link for progress; add keyboard seeking and an accessibility value | Medium |
| Preview playback | `<audio>` on a Blob URL, LRU of 3, volume = slider² | One shared `AVAudioPlayer`/`AVPlayer`; cancel or ignore stale loads (fixes bug 2); LRU of 3 payloads plus an unlimited peaks cache; v² mapping; store and restore the slider position (fixes bug 4) | Medium |
| Sounds | Web Audio oscillators, filters and envelopes | `AVAudioEngine` + `AVAudioSourceNode`, or short pre-rendered assets built from the listed parameters | Medium |
| Drop, picker, paste import | Section drop handlers, hidden file input, document paste heuristic | A drop destination for `.commaSeparatedText`/`.plainText` file URLs that rejects other types; `NSOpenPanel`; Edit → Paste (or `onPasteCommand`) with the same heuristic when no text field is first responder; window-wide drops must never replace the UI | Easy |
| Folder pickers and reveal | `showOpenDialog(openDirectory)` defaulting to the download folder; `shell.openPath` | `NSOpenPanel` (`canChooseDirectories`), with security-scoped bookmarks if sandboxed; `NSWorkspace.open`/`activateFileViewerSelecting`; show an error if the folder is gone | Easy |
| Confirm and clipboard | `window.confirm`; `navigator.clipboard` | `NSAlert`/`confirmationDialog` with a destructive "Reset" button; `NSPasteboard.general.setString` | Easy |
| Activity log | Monospace divs, regex classes, 2000 cap, forced auto-scroll | A bounded array rendered in a selectable monospace view with per-line styles; auto-scroll only when already at the bottom | Easy |
| Motion | CSS keyframes and transitions | Matching durations (0.1–0.25 s, 2.4 s pulse) that respect Reduce Motion; the system `ProgressView` replaces the custom spinner | Easy |
| Icons | Feather SVG paths plus custom play/pause/loading and logo | SF Symbols (`gearshape`, `doc.text`, `speaker.wave.2`, `play.fill`, `pause.fill`, `xmark`, `arrow.clockwise`, `plus`); a vector asset for the vinyl logo and app icon | Easy |
| Tooltips and accessibility | `title` and `aria-*` | `.help()` and `accessibilityLabel/Value/Traits`; close the gaps in component 29 | Easy |
| IPC and debounced saves | `ipcRenderer.invoke/on`; `setTimeout` debounces | In-process async calls; `AsyncStream`/Combine for progress; debounced saves (400 ms queue, 300 ms volume) | Medium |
| App menu | Electron default | Settings… (⌘,), Check for Updates…, Add to Queue, Import Tracklist… (⌘O), Download All, Cancel, Clear Queue, Clear Activity, plus standard Edit/Window/Help | Medium |
| Sign-in | Modal with no exit | A sheet with Cancel that stops polling, and a clear failure state with Close / Try Again | Easy |

---

### Open questions

1. Dark only, or Light + Dark? The app is fixed black today, and the owner's Swift rules ask for Light, Dark and Increase Contrast. How does the monochrome identity map to Light mode?
2. Keep the joke sound on the logo, name and version click, and the rotating funny loading text?
3. Keep two update controls (one-click pill, two-click log notice), or merge them into one native "Check for Updates…" flow?
4. Keep emoji prefixes in log lines and badges, or use SF Symbols?
5. Should the batch "N / M" counter be visible? It was designed in but is clipped today.
6. What font sizes were intended for inputs and buttons (declared 15/14/13/12 px but dropped)? The sizes actually rendered need a run.
7. Should the volume setting store the slider position? Today it is stored that way but restored squared.
8. Should sign-in be cancellable while waiting? Today it cannot be closed at all.
9. Should Reset config also reset the preview volume (it does today, by accident)?
10. Should excluded library-match rows and still-queued rows survive the end of a batch? Today both are removed.
11. For Exportify exports that put "Artist URI(s)" before "Artist Name(s)", the `/artist/` rule picks the URI column. This needs a real export to confirm the current column order.
12. The exact topbar height, the bottom-padding clipping, the Settings dialog changing height between tabs, and the behaviour of a file dropped outside the zone all need a run.
