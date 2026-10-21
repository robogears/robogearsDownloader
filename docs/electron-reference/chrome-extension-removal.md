## Chrome extension + local HTTP bridge: removal inventory (feature being dropped)

> **Status:** On 21 Oct 2026 the owner decided to end support for the Chrome extension. The native Swift macOS app will **not** include the extension, the local HTTP bridge, the managed extension folder, or the Settings → Extension tab. This section records exactly what exists today (code v0.1.30) so that it can be removed cleanly and so that the pieces it shares with features that stay are not lost by accident.

### Overview

The feature has two halves.

- **A Chrome extension (Manifest V3, Chromium only)** in `chrome-extension/`. Its content script adds a small round "+" button to every track row in the Spotify web player (`open.spotify.com`). Clicking it reads the row's title, artists and Spotify track id from the page, then sends that one track to the desktop app over plain HTTP on the local machine. A toolbar popup and an options page let the user paste a token and check the connection. A background service worker keeps the loaded extension up to date by reloading it when the desktop app has written newer extension files to disk.
- **A local HTTP bridge inside the desktop app** (`extension-server.js`, started by `electron-main.js`). It listens on `127.0.0.1:8273`, accepts `POST /queue/add` when the request carries the correct bearer token (a random 32-character hex string kept in `<userData>/extension-token.txt`), and replies straight away. In the background the app then matches each received `{title, artist}` against TIDAL with a free-text search, tags library duplicates, and sends the results to the window, which adds them to the queue with the badge **Spotify ext**. The app also copies its bundled extension files into `<userData>/chrome-extension/` on launch, so the user has a stable folder to pick with Chrome's **Load unpacked**.

Everything in this section is removed in the Swift port **except** the title + artist → TIDAL matcher, which the CSV/text import keeps using (a copy of the same code lives in `resolve:tracklist`), plus the shared helpers listed under **Kept: shared code**.

### Removal inventory

| Where | Lines | What it is | Action |
|---|---|---|---|
| `extension-server.js` | 1–211 (whole file) | The local HTTP bridge | Delete |
| `chrome-extension/` | 12 files: `manifest.json`, `background.js`, `content.js`, `content.css`, `popup.html`, `popup.js`, `popup.css`, `options.html`, `options.js`, `options.css`, `icon.png`, `README.md` | The extension | Delete |
| `scripts/sync-extension-version.js` | 1–25 (whole file; only file in `scripts/`) | Copies `package.json#version` into the extension manifest | Delete |
| `electron-main.js` | 24 | `const extensionServer = require('./extension-server');` | Delete |
| `electron-main.js` | 28 | `EXTENSION_TOKEN_PATH = () => path.join(app.getPath('userData'), 'extension-token.txt')` | Delete |
| `electron-main.js` | 497–500 | `ensureExtensionBundle()` call at boot | Delete |
| `electron-main.js` | 502–522 | `extensionServer.startServer({...})` at boot | Delete |
| `electron-main.js` | 691–751 | `handleExtensionTracks` (contains copy #2 of the matcher) | Delete |
| `electron-main.js` | 753–802 | `getManagedExtensionPath`, `readManifestVersion`, `ensureExtensionBundle` | Delete |
| `electron-main.js` | 804–812 | IPC `extension:info`, `extension:regenerate-token` | Delete |
| `electron-preload.js` | 52–55 | `extensionInfo`, `regenerateExtensionToken`, `onExtensionTracks` | Delete |
| `renderer/app.js` | 922 | `source === 'extension'` → badge `Spotify ext` | Delete the branch |
| `renderer/app.js` | 1587 | `if (which === 'extension') refreshExtensionInfo();` inside the shared tab handler (1580–1589) | Delete the one line only |
| `renderer/app.js` | 1591–1647 | Extension tab logic, `copyToClipboardField` (used only here), `onExtensionTracks` listener | Delete |
| `renderer/index.html` | 119 | Tab button `data-tab="extension"` | Delete |
| `renderer/index.html` | 162–186 | Pane `data-pane="extension"` | Delete |
| `renderer/styles.css` | — | No extension-only rules (the pane uses shared `.label`, `.hint`, `.folder-row`, `.text-btn`, `.modal-tab`, `.modal-pane`) | Nothing |
| `package.json` | 12 | `"sync-ext": "node scripts/sync-extension-version.js"` | Delete |
| `package.json` | 46 | `"extension-server.js"` in `build.files` | Delete |
| `package.json` | 60–65 | `build.extraResources: [{ from: 'chrome-extension/', to: 'chrome-extension/' }]` | Delete |
| `RELEASE_NOTES.md` | 3–17, 26–30, 37 | v0.1.30 notes are entirely about the extension, plus install and requirements lines for it | Rewrite at the next ship |
| `.github/workflows/release.yml`, `README.md`, `CLAUDE.md`, `BOT_PROMPT.md`, `ship.md`, `updater.md`, `ONBOARDING.md`, `.gitignore` | — | No references (CLAUDE.md predates the extension) | Nothing |

**Kept: shared code that the extension path also uses.**

- The title + artist → TIDAL matcher (normalise, score, accept, sort). Three copies exist: `electron-main.js:707–744` (extension, removed), `electron-main.js:938–976` inside `resolve:tracklist` 919–982 (CSV/text import, **kept**), and a variant in `tidal_lib.js:558–611` `spotifyTrackToTidal` (Spotify URLs, **kept**).
- `lib.loadCred`, `lib.getToken`, `lib.getCountryCode`, `lib.searchTracks`, `lib.enrichWithLibraryStatus` (`tidal_lib.js`).
- `isNewerVersion` at `electron-main.js:103–113`: used by the GitHub updater (150) and by `ensureExtensionBundle` (786). Only the 786 use goes away.
- `addTracksToQueue` (`renderer/app.js:1255–1272`), the Settings tab switcher (1580–1589), `api.openFolder` / IPC `open-folder`.

**Data left behind on users' machines** (the app never cleans it up today):

- `<userData>/extension-token.txt`
- `<userData>/chrome-extension/` (packaged builds only)
- `queue.json` items with `"source": "extension"` (ordinary downloadable items)
- `chrome.storage.local` keys `port`, `token`, `lastReloadAttempt` in the user's Chrome profile (the app cannot reach them), and the unpacked extension itself, which the user must remove in `chrome://extensions`.

### Components

#### 1. `extension-server.js`: the local HTTP bridge

Module state (20–25): `_token`, `_tokenPath`, `_server`, `_onTracksReceived`, `_getManagedExtVersion`, `_getManagedExtPath`. Constants `PORT = 8273` (17), `HOST = '127.0.0.1'` (18). Exports (211): `startServer`, `stopServer`, `getToken`, `getPort`, `regenerateToken`, `getTokenPath`.

**Token lifecycle (39–67).**

1. `generateToken()` = `crypto.randomBytes(16).toString('hex')`: 32 lowercase hex characters (40).
2. `loadOrCreateToken(tokenPath)` (43–60): stores `_tokenPath`. Reads the file as UTF-8 and trims it. If the result is non-empty and matches `/^[0-9a-f]{32}$/i`, that is the token. Otherwise, including when the read fails, it generates a new token, runs `mkdirSync(dirname, {recursive:true})` and `writeFileSync(tokenPath, token, 'utf8')` with no trailing newline. A write failure only logs `console.warn('[extension-server] could not persist token:', e.message)`. The token then lives only in memory, and a new one is made on every launch.
3. `regenerateToken()` (62–67): returns `null` if `_tokenPath` is unset. Otherwise it puts a new token in memory, then calls `writeFileSync`, swallowing any error (no `mkdir`). The old token stops working at once, because only the in-memory `_token` is compared.
4. `getToken()` / `getPort()` / `getTokenPath()` return the module values. `getTokenPath` is never called anywhere.

**`applyCors(req, res)` (72–77)** runs on every response, including 401 and 404:
`Access-Control-Allow-Origin: <request Origin header, or '*' if absent>`, `Access-Control-Allow-Methods: GET, POST, OPTIONS`, `Access-Control-Allow-Headers: Authorization, Content-Type`, `Access-Control-Max-Age: 86400`. It never sends `Vary: Origin`, `Access-Control-Allow-Credentials` or `Access-Control-Allow-Private-Network`. The Host header is never checked.

**`checkAuth(req)` (79–88):** reads `req.headers.authorization` (or `''`) and matches `/^Bearer\s+(.+)$/i`; no match → `false`. It compares `Buffer.from(captured)` against `Buffer.from(_token || '')`: a different byte length → `false`, otherwise `crypto.timingSafeEqual`. The scheme word is case-insensitive; the token comparison is exact and case-sensitive.

**`readBody(req)` (90–105):** gathers chunks. Once the running total goes over `256 * 1024` bytes it calls `req.destroy()` and rejects with `Error('Body too large')`. Otherwise it resolves the UTF-8 string on `end` and rejects on `error`.

**`startServer({ tokenPath, version, onTracksReceived, getManagedExtensionVersion, getManagedExtensionPath })` (107–202).**

1. `loadOrCreateToken(tokenPath)`, then stores the three callbacks.
2. Creates `http.createServer(async (req, res) => …)`. Routing order for every request:
   1. `applyCors`.
   2. `req.method === 'OPTIONS'` (any path) → `204`, empty body, no auth.
   3. `GET` and `req.url === '/ping'` exactly → calls each getter inside its own try/catch (a throw gives `null`) → `200`, `Content-Type: application/json`, body `{ok:true, app:'robogears-downloader', version, managedExtensionVersion, managedExtensionPath}`. A query string (`/ping?x`) is not `/ping`, so it falls through to the auth check.
   4. `checkAuth` fails → `401` `{"ok":false,"error":"Unauthorized — check token"}`. This happens before route matching, so an unknown path without a token gets 401, not 404.
   5. `POST` and `req.url === '/queue/add'` exactly:
      1. `raw = await readBody(req)`; `body = JSON.parse(raw)`.
      2. `tracks = Array.isArray(body.tracks) ? body.tracks : null`. Null or empty → `400` `{"ok":false,"error":"No tracks in body"}`.
      3. Maps each item to `{ title: String(t.title || '').trim(), artist: String(t.artist || '').trim(), spotifyId: t.spotifyId ? String(t.spotifyId).trim() : null }`, then drops items whose `title` is empty.
      4. None left → `400` `{"ok":false,"error":"No valid tracks"}`.
      5. If a callback is set: `Promise.resolve(_onTracksReceived(normalized)).catch(() => {})`. This is **not awaited** (fire-and-forget), and any error from the callback is discarded.
      6. `200` `{"ok":true,"queued":<normalized.length>}`.
      7. Any throw in 1–6 (bad JSON, a `null` body, a `null` array item, body too large) → `400` `{"ok":false,"error":<e.message>}`. In the body-too-large case the socket is already destroyed, so the client most likely sees a network error rather than the 400 (unverified, needs a run).
   6. Any other authenticated request → `404` `{"ok":false,"error":"Not found"}`.
3. Returns a promise. It attaches `_server.once('error', reject)`, then calls `_server.listen(8273, '127.0.0.1', cb)`. The callback logs `[extension-server] listening on http://127.0.0.1:8273` and resolves `{port: 8273, host: '127.0.0.1', token}`. A listen error such as `EADDRINUSE` rejects the promise.

**`stopServer()` (204–209):** closes the server and sets it to null. Nothing calls it, and there is no quit hook; the listener dies with the process.

#### 2. Boot wiring in `electron-main.js`

Inside `app.whenReady().then(async () => …)` (471–527), with no `await` before these steps, in this order: prime the library path → `createWindow()` → start the library scan (if a library folder is set) → `checkForUpdatesAndNotify()` → `verifyFfmpegAvailable()` → **`ensureExtensionBundle()` (500)** → **`extensionServer.startServer(...)` (506–522)** → register `activate`.

`startServer` receives:

- `tokenPath: EXTENSION_TOKEN_PATH()`, which is `path.join(app.getPath('userData'), 'extension-token.txt')` (28)
- `version: app.getVersion()`
- `onTracksReceived: handleExtensionTracks`
- `getManagedExtensionVersion: () => readManifestVersion(getManagedExtensionPath())`
- `getManagedExtensionPath`

On rejection, if the window is alive, it sends `download:line` with the text `⚠ Chrome-extension bridge couldn't start: <err.message> (tracks won't push from Spotify)` (517–522).

Because `loadOrCreateToken` runs synchronously in this callback, a token always exists before the renderer can make any IPC call.

#### 3. `handleExtensionTracks(tracks)`: `electron-main.js:696–751`

Input: `[{title, artist, spotifyId}]`. `spotifyId` is never read.

1. If `mainWindow` is missing or destroyed → return silently (697). The HTTP client has already received 200.
2. Sends `download:line` with the text `🎵 <n> track<s> from Spotify extension — matching on TIDAL…` ("track" when n = 1, else "tracks") (699–700).
3. `cred = lib.loadCred()`; `token = await lib.getToken(cred)`; `country = await lib.getCountryCode(cred)` (702–704). See the bug about `loadCred`.
4. **Sequentially**, for each track (707–744):
   1. `query = \`${t.title} ${t.artist}\`` (trailing space when the artist is empty).
   2. `json = await lib.searchTracks(query, token, country, 10)`; `items = json.items || []`.
   3. `normalize(s) = (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim()`.
   4. `wantT = normalize(t.title)`, `wantA = normalize(t.artist)`.
   5. For each item: `itT = normalize(it.title)`; `itA` = each `it.artists[].name` normalised, joined with `' '`.
      - `titleScore` = 100 if `itT === wantT`; else 50 if `itT.startsWith(wantT) || wantT.startsWith(itT)`; else 25 if `itT.includes(wantT) || wantT.includes(itT)`; else 0.
      - `aTokens = wantA.split(' ').filter(x => x.length > 2)`; `matched` = count of tokens where `itA.includes(token)` (a substring test, not a whole-word test).
      - `artistScore = aTokens.length ? Math.round(matched / aTokens.length * 100) : 0`.
      - `total = titleScore + artistScore`.
   6. Keep items where `titleScore === 100 || (titleScore >= 25 && artistScore >= 50)`, sort by `total` descending (stable, so ties keep TIDAL's order), `pick = first`.
   7. Push `{ title: pick?.title || t.title, artist: pick ? pick.artists.map(a => a.name).join(', ') : t.artist, duration: pick?.duration || 0, tidalId: pick?.id || null, source: 'extension', matchMethod: pick ? 'search' : null, notFound: !pick, hiRes: pick?.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') || false, originalTitle: t.title, originalArtist: t.artist }`.
   8. Any throw for this track (for example a search error) → push `{ title, artist, tidalId: null, source: 'extension', notFound: true }`.
5. `await lib.enrichWithLibraryStatus(out)`: adds `libraryMatch` where the library has a hit.
6. Sends `extension:tracks-resolved` with `{ tracks: out }` (746).
7. Outer catch: sends `download:line` with the text `⚠ Extension match failed: <e.message>` (747–750). If the window was destroyed during matching, this `send` throws too. The rejection is then swallowed by the bridge's `.catch(() => {})`.

There are no progress events, no cancel and no concurrency limit. Each POST runs its own `handleExtensionTracks`, so pushes in quick succession are matched in parallel.

The comment at 692–694 says these tracks go "through the same resolver the CSV import uses". They do not: the code is a separate copy (see Bugs).

#### 4. Managed extension folder: `electron-main.js:765–802`

- `getManagedExtensionPath()` = `path.join(app.getPath('userData'), 'chrome-extension')` (765–767).
- `readManifestVersion(dir)` = `JSON.parse(<dir>/manifest.json).version || '0.0.0'`, or `'0.0.0'` on any error (769–773).
- `ensureExtensionBundle()` (775–802), all synchronous `fs` calls:
  1. Returns if `!app.isPackaged` (dev mode).
  2. `bundledDir = path.join(process.resourcesPath, 'chrome-extension')`; returns if it does not exist.
  3. `bundledVersion = readManifestVersion(bundledDir)`, `userVersion = readManifestVersion(userDir)`.
  4. Returns if `userVersion !== '0.0.0' && !isNewerVersion(bundledVersion, userVersion)`. It copies only when the managed copy is missing or unreadable, or the bundled copy is strictly newer. It never downgrades.
  5. `mkdirSync(userDir, {recursive:true})`; for each top-level entry of `bundledDir` that `statSync().isFile()`, `copyFileSync(src, dst)` overwrites the existing file. Subfolders are skipped, files dropped in later versions are never removed, and the copy is not atomic.
  6. If the window is alive, sends `download:line` with the text `🧩 Chrome extension files updated to v<bundledVersion> at <userDir>. Reload in chrome://extensions if it's already loaded.`
  7. On error: `console.warn('[ext-bundle] sync failed:', e.message)`.

The comment at 761–763 describes a popup "Update" button and a `handleExtensionUpdateSelf` function that downloads from GitHub. Neither exists.

#### 5. IPC handlers: `electron-main.js:805–812`

- `ipcMain.handle('extension:info')` → `{ port: extensionServer.getPort(), token: extensionServer.getToken(), managedPath: getManagedExtensionPath() }`.
- `ipcMain.handle('extension:regenerate-token')` → `{ token: extensionServer.regenerateToken() }`.

Both return values even when the server failed to listen.

#### 6. Preload: `electron-preload.js:52–55`

- `extensionInfo()` → `invoke('extension:info')`
- `regenerateExtensionToken()` → `invoke('extension:regenerate-token')`
- `onExtensionTracks(cb)` → `ipcRenderer.on('extension:tracks-resolved', (_e, p) => cb(p))`

#### 7. Settings → Extension tab: `renderer/index.html:119, 162–186`; `renderer/app.js:1587, 1591–1637`

The markup is the fourth tab, in this order: Folders, TIDAL, **Extension**, Updates. The pane contains:

- the label `Chrome extension bridge` and a hint about adding tracks from open.spotify.com that says to paste the token into "the extension's options page"
- **Local URL**: `#extension-url-input` (read-only) + `#extension-url-copy`
- **Token**: `#extension-token-input` (read-only) + `#extension-token-copy` + `#extension-token-regen` (tooltip "Generate a new token — the extension will need it re-pasted"), with a hint about localhost-only auth that says the old token stops working immediately
- **Managed extension folder**: `#extension-path-input` + `#extension-path-copy` + `#extension-path-open`, with a hint naming the popup **Update** button that does not exist

Behaviour:

1. Clicking the tab runs `refreshExtensionInfo()` (1587, 1601–1610). It sets the URL field to `` `http://127.0.0.1:${r.port}` ``, the token field to `r.token || '(not generated yet — restart the app)'`, and the path field to `r.managedPath || ''`. If the call throws, the token field shows `(extension bridge unavailable)`. Neither placeholder appears in practice (see component 2).
2. `copyToClipboardField(input, btn)` (1612–1621): returns if the field is empty. Otherwise it calls `navigator.clipboard.writeText`, falling back to `select()` + `execCommand('copy')` on rejection. The button shows `Copied ✓` for 1200 ms immediately, whether or not the copy succeeded. This helper is used only by this tab.
3. **Regenerate** (1625–1629): `confirm('Regenerate the extension token?\n\nThe Chrome extension will need the new token pasted in before it can talk to the app again.')`. On OK it calls `regenerateExtensionToken()` and shows the new token if it is truthy.
4. **Open** on the path row (1633–1637): `api.openFolder(path)`, which calls `shell.openPath`. The result is ignored, so in dev mode it silently fails if the folder does not exist.

#### 8. Queue intake: `renderer/app.js:1641–1647, 922`

`api.onExtensionTracks(({tracks}) => …)`:

1. Returns if `tracks` is not a non-empty array.
2. `added = addTracksToQueue(tracks)`. This is the shared helper: it dedupes on the key `id:<tidalId>`, or `na:<title>|<artist>` when there is no id. It pushes `{...t, key: uniqueKey()}` (an 8-character base-36 key), calls `enqueuePreload(tidalId)` when there is an id and the track was found, re-renders, and calls `saveQueueSoon()` when anything was added.
3. Logs `🎵 Spotify ext: added <added> track<s> (<matched> matched on TIDAL[, <missing> not found]).` Here `matched` / `missing` count the pushed tracks, not the ones added, so a duplicate push reads "added 0 tracks (1 matched on TIDAL)".

In `renderQueue`, `included` defaults to `!isExact` (901). The status badge follows a priority chain (913–922): download status, then not found, then library exact, then library similar, then `source === 'spotify'` → `Spotify`, then `'import'` → `Import`, then **`'extension'` → `Spotify ext`**. The Hi-Res badge is independent of this chain.

#### 9. `chrome-extension/manifest.json` (1–44)

- `manifest_version: 3`
- `name: "robogears Downloader — Spotify add-to-queue"`
- `version: "0.1.30"` (kept equal to `package.json`)
- `description`: adds an "add to robogears queue" button on every open.spotify.com track row
- `permissions: ["storage", "alarms"]`
- `host_permissions: ["http://localhost/*", "http://127.0.0.1/*"]`
- `content_scripts`: matches `https://open.spotify.com/*`, `js: content.js`, `css: content.css`, `run_at: document_idle`
- `action`: `default_popup: popup.html`, `default_title: "robogears — paste token"`, `default_icon` 48 and 128 → `icon.png`
- `background.service_worker: background.js`
- `options_page: options.html`
- top-level `icons` 48 and 128 → `icon.png`

#### 10. `chrome-extension/content.js` (1–192): Spotify page script

1. `_config = {port: 8273, token: ''}`. `loadConfig()` reads `chrome.storage.local` keys `port` and `token`: `port = parseInt(port, 10) || 8273`, `token = String(token)` (15–28). `chrome.storage.onChanged` updates both live when the area is `local` (30–34).
2. `extractTrackFromRow(row)` (37–51):
   - `titleLink` = first `a[href*="/track/"]` in the row → `null` if there is none
   - `title = titleLink.textContent.trim()` → `null` if empty
   - `spotifyId` = href matched against `/\/track\/([a-zA-Z0-9]+)/`, group 1, or `null`
   - `artist` = all `a[href*="/artist/"]` in the row, `textContent.trim()`, empty ones dropped, joined with `', '`
   - Album and duration are not read.
3. `pushTracksToApp(tracks)` (54–83):
   - No token → toast `Click the robogears icon in the toolbar and paste your token.` (error), return.
   - Otherwise `fetch('http://127.0.0.1:<port>/queue/add', {method:'POST', headers:{'Content-Type':'application/json', 'Authorization':'Bearer <token>'}, body: JSON.stringify({tracks})})`.
   - Response not OK → toast `errBody.error || 'HTTP <status>'` (error). A 401 therefore shows "Unauthorized — check token".
   - OK → toast `Added <json.queued> to robogears` (ok).
   - Fetch throws → toast `App unreachable — is robogears Downloader running?` (error).
4. `showToast(text, kind)` (88–102): a single lazily created `div.robogears-toast` appended to `body`. It gets `robogears-toast-ok` or `robogears-toast-error` plus `robogears-toast-visible`, and the visible class is removed after 2200 ms.
5. `makeAddButton()` (106–119): `button.robogears-add-btn`, `type=button`, `title` and `aria-label` `Add to robogears queue`, containing an inline 14×14 SVG plus sign.
6. `injectIntoRow(row)` (125–162):
   1. Skips the row if it already contains `.robogears-add-btn`.
   2. Targets the **last** `[role="gridcell"]`; returns if there is none.
   3. Capture-phase listeners stop `mousedown`, `pointerdown` and `mouseup` from propagating (so Spotify does not start playback).
   4. A capture-phase `click` handler calls `preventDefault`, `stopPropagation` and `stopImmediatePropagation`. It then extracts the track (failure → toast `Could not parse this row`), adds `robogears-add-btn-busy` and sets `disabled`, awaits `pushTracksToApp([track])` (always exactly one track), then restores the button.
   5. The button is inserted as the first child of the last cell.
7. `scanAndInject()` runs on all `[data-testid="tracklist-row"]`. A `MutationObserver` on `document.body` (`childList`, `subtree`) schedules a scan, coalesced with `requestAnimationFrame` (164–181).
8. `init()` (183–192): `await loadConfig()` → scan → observe → `chrome.runtime.sendMessage({action: 'check-pending-reload'})`, wrapped in try/catch.

#### 11. `chrome-extension/background.js` (1–90): service worker

1. `DEFAULT_PORT = 8273`. `isNewerVersion` (17–27) is a copy of the one in `electron-main.js`.
2. `checkAndReloadIfPending()` (29–54):
   1. Reads storage `port` and `lastReloadAttempt`.
   2. `fetch('http://127.0.0.1:<port>/ping', {cache: 'no-store'})`; returns if the response is not OK or `json.app !== 'robogears-downloader'`.
   3. `disk = json.managedExtensionVersion`, `memory = chrome.runtime.getManifest().version`. Returns if `disk` is falsy or not newer.
   4. Returns if `lastReloadAttempt.version === disk && Date.now() - lastReloadAttempt.at < 300_000`.
   5. Stores `lastReloadAttempt = {at: Date.now(), version: disk}`, then calls `chrome.runtime.reload()`.
   6. Any error is swallowed.
3. Triggers:
   - `runtime.onStartup` (57–59)
   - `runtime.onInstalled`, which also calls `chrome.runtime.openOptionsPage()` when `reason === 'install'` (62–67)
   - `chrome.alarms.create('check-pending-reload', {periodInMinutes: 1})` at top level, so it is re-created each time the worker starts, plus `onAlarm` (71–74)
   - `runtime.onMessage` (78–90): `{action: 'check-pending-reload'}` runs the check and replies `{ok: true}`; `{action: 'open-options'}` opens the options page and replies `{ok: true}`. Nothing sends `open-options`.

#### 12. `chrome-extension/popup.html` + `popup.js` (+ `popup.css`): toolbar popup

The popup is 280 px wide and dark. It shows a header `robogears` plus a version label and a status dot, the hint "Paste the token from the desktop app's Settings → Extension tab.", the token input (placeholder `32-character hex token`), a **Save** button with a status line, a hidden reload section, and the link `Open full settings →`.

- `pingApp(port)` (52–60): `GET /ping` with `cache: 'no-store'`. Returns the JSON, or `null` when the response is not OK, the app name is wrong, or the fetch throws.
- `verifyToken(port, token)` (62–77): `POST /queue/add` with `{tracks: []}`. 401 → `'bad-token'`; 400 or 2xx → `'ok'`; other statuses → `'error'`; fetch throws → `'unreachable'`; empty token → `'no-token'`. This works as an auth probe because the server checks auth before validating the body, and an empty list never reaches the matcher.
- `refresh()` (91–146), which runs on open:
  1. Fills the token field and shows `v<manifest version>`.
  2. Nudges the worker with `check-pending-reload`.
  3. Sets the status to `Checking…`, the dot to idle, and hides the reload section.
  4. Ping fails → `App not running` (error), stop.
  5. No token → `Paste a token to start`. Otherwise it verifies: `Connected` (green dot), `Token rejected — paste again` (red dot), or `Check failed`.
  6. It then compares versions, even in the no-token branch. If the disk version is newer, it reads `lastReloadAttempt`; `stuck` means the same version was attempted within 300 000 ms. It then calls `showReloadSection`.
- `showReloadSection` (181–220):
  - The title is `Loaded v<local> · on disk v<disk>`.
  - **Stuck:** the sub-text is "Reload didn't update the version — Chrome's loaded from a different folder.". An `innerHTML` block follows: an ordered list (open `chrome://extensions` → remove the extension → **Load unpacked** the managed folder), the path in `<code id="managed-path">` interpolated without escaping (`'(unknown)'` if missing), and a **Copy** button (`Copied ✓` for 1500 ms). The button text is `Try reload`.
  - **Not stuck:** the sub-text is `Click Reload to apply the new version.` and the button text is `Reload`.
- `handleReloadClick` (222–234): disables the button and shows `Reloading…`. It re-pings; if a version comes back it stores `lastReloadAttempt`. Then `setTimeout(chrome.runtime.reload, 250)`.
- `save()` (148–179), run by **Save** or by Enter in the token field:
  1. Trims the token and stores it.
  2. Empty → `Cleared`.
  3. Otherwise verifies: `Saved & connected ✓` / `Saved — but token rejected` / `Saved — app not running` / `Saved — connection check failed`.
- Status dot (`popup.css`): grey `#555` by default, `.connected` green `#4ade80`, `.unauth` red `#f87171`. Dot tooltips: `Connected`, `App is running but token is wrong`, `App not running on this port`.

#### 13. `chrome-extension/options.html` + `options.js` (+ `options.css`): options page

The fields are **App URL** (default value `http://127.0.0.1:8273`) and **Token**. The hints describe a `+ robogears` button, which is stale (the button is icon-only), and say the URL can be left alone "if you didn't change anything in the desktop app" (the app has no port setting).

- `parsePort(value)` (18–24): takes the first `/:(\d{2,5})/` capture, with no range check. Failing that, `parseInt(value)` if it is between 1 and 65535. Otherwise `8273`.
- `load()` shows `http://127.0.0.1:<stored port || 8273>` and the stored token.
- **Save** stores `{port, token: trimmed}` without checking them and shows `Saved.` for 1500 ms.
- **Test connection**:
  1. Shows `Testing…`.
  2. `GET /ping`: a non-OK response throws `HTTP <n>`; the wrong app throws `not our app on that port`; either way the page shows `App not reachable: <msg>`.
  3. Zero-track POST: 401 → `App is running but token is wrong.`; 400 or OK → `Connected — extension is wired up correctly.`; anything else → `Unexpected: HTTP <n>`; a throw → `Network error: <msg>`.
- Every request targets `127.0.0.1`, even if the user typed `localhost`; only the port is parsed.

#### 14. Extension assets

- `content.css` (1–80): `.robogears-add-btn` is a 28×28 px circle with a 1 px `rgba(255,255,255,.28)` border, 70 % white icon and a 6 px right margin. Hover gives a white border and icon; active scales it to 0.92; disabled or busy sets opacity 0.5. `.robogears-toast` is fixed at right 18 px, bottom 110 px, `z-index: 2147483647`, max width 320 px, dark background, with a 150 ms fade and slide. The `-ok` border is green and the `-error` border is red.
- `popup.css` (211 lines) and `options.css` (90 lines) style only those pages.
- `icon.png` is a 1024×1024 RGBA PNG, byte-for-byte identical to `build/icon.png`.
- `README.md` (1–38) is stale; see Bugs.

#### 15. `scripts/sync-extension-version.js` (1–25)

Reads `package.json` and `chrome-extension/manifest.json`. If the versions are equal, it logs `chrome-extension/manifest.json already at <v>` and exits 0. Otherwise it sets `manifest.version`, writes `JSON.stringify(manifest, null, 2) + '\n'`, and logs `chrome-extension/manifest.json: <prev> → <new>`. It runs only when someone types `npm run sync-ext`; CI never runs it.

#### 16. Packaging (`package.json`)

- `build.files` includes `extension-server.js` (46).
- `build.extraResources` copies `chrome-extension/` to `<resources>/chrome-extension/` (60–65). On macOS that is `robogears Downloader.app/Contents/Resources/chrome-extension/`; on Windows, `<install dir>\resources\chrome-extension\`. This is the source `ensureExtensionBundle` reads.
- Whether `chrome-extension/README.md` is copied (the `!**/*.md` filter belongs to `build.files`, not `extraResources`) is unverified (needs a build).

### Data formats

**`extension-token.txt`**

- Location: `<userData>/extension-token.txt`. On macOS that is `~/Library/Application Support/robogears Downloader/extension-token.txt`; on Windows, `%APPDATA%\robogears Downloader\extension-token.txt`.
- Content: 32 lowercase hex characters (16 random bytes), UTF-8, no newline.
- On load it must match `/^[0-9a-f]{32}$/i` after trimming, or it is silently replaced.
- It is a secret: the Swift app must not read it, and it never lives in the repo.

**`GET /ping` → 200**
```json
{
  "ok": true,
  "app": "robogears-downloader",
  "version": "<app.getVersion(), e.g. 0.1.30>",
  "managedExtensionVersion": "<manifest version> | \"0.0.0\" when the managed folder or manifest is missing | null if the getter threw",
  "managedExtensionPath": "<userData>/chrome-extension | null if the getter threw"
}
```
No auth is required. In practice the getters never throw, so the version is a string; `"0.0.0"` appears in dev mode or before the first copy. Dev and packaged builds share the same userData folder (`app.setName`), so a dev run can report a managed folder that a packaged install created.

**`POST /queue/add` request**
```
Authorization: Bearer <32-hex token>
Content-Type: application/json

{ "tracks": [ { "title": "string", "artist": "string, artists joined with ', '", "spotifyId": "string | null" } ] }
```
The body is capped at 262 144 bytes. The extension always sends exactly one track per click; `{ "tracks": [] }` is the auth probe.

**`POST /queue/add` responses** (all `Content-Type: application/json`, all with the CORS headers)

| Status | Body |
|---|---|
| 200 | `{"ok":true,"queued":N}` (N = tracks left after dropping empty titles) |
| 400 | `{"ok":false,"error":"No tracks in body"}` / `"No valid tracks"` / `<exception message>` (e.g. a JSON parse error, `Body too large`) |
| 401 | `{"ok":false,"error":"Unauthorized — check token"}` |
| 404 | `{"ok":false,"error":"Not found"}` (authenticated, unknown route) |
| 204 | `OPTIONS` on any path, empty body |

**IPC**

- `extension:info` → `{ port: 8273, token: string, managedPath: string }`
- `extension:regenerate-token` → `{ token: string | null }`
- Event `extension:tracks-resolved` → `{ tracks: QueueItem[] }`

**Queue item from the extension** (also what lands in `queue.json`)
```js
{
  title, artist,                 // TIDAL's when matched, else the pushed values
  duration,                      // seconds, 0 when not matched
  tidalId,                       // number | null
  source: 'extension',
  matchMethod: 'search' | null,
  notFound: boolean,
  hiRes: boolean,                // 'HIRES_LOSSLESS' in mediaMetadata.tags
  originalTitle, originalArtist, // the pushed values
  libraryMatch?: { kind: 'exact' | 'similar', path, libraryTitle },
  // added in the renderer:
  key,                           // 8-char base-36
  included                       // set on first render: !(libraryMatch.kind === 'exact')
}
// Error-branch item: { title, artist, tidalId: null, source: 'extension', notFound: true }
```
`queue.json` is a pretty-printed (2-space) JSON array (`electron-main.js:599–606`). `dlStatus`, `dlPercent` and `selected` are stripped before saving (`renderer/app.js:71–83`). `matchMethod`, `originalTitle` and `originalArtist` are saved but never read anywhere.

**Managed folder**: `<userData>/chrome-extension/` holds a flat copy of the bundled top-level files: `manifest.json`, `background.js`, `content.js`, `content.css`, `popup.html`, `popup.js`, `popup.css`, `options.html`, `options.js`, `options.css`, `icon.png`, and possibly `README.md` (unverified). It exists only after a packaged build has launched.

**`chrome.storage.local` (Chrome profile)**: `{ port?: number, token?: string, lastReloadAttempt?: { at: <epoch ms>, version: string } }`.

**Extension runtime messages**: `{action: 'check-pending-reload'}` (sent by `content.js` init and by the popup) and `{action: 'open-options'}` (handled but never sent). Both reply `{ok: true}`.

### External interfaces

| Interface | Detail |
|---|---|
| HTTP listener | `http://127.0.0.1:8273`, IPv4 loopback only, fixed port, no setting. Routes: `OPTIONS *`, `GET /ping` (open), `POST /queue/add` (bearer). |
| CORS | Reflects any `Origin`. The content script's request comes from the Spotify page and needs a CORS preflight because of the `Authorization` header, which is why the server answers `OPTIONS` without auth and reflects the origin. The popup, options and worker requests come from the extension's own pages. Whether current Chrome private/local-network rules allow the request from `https://open.spotify.com` without extra headers or a permission prompt is unverified (needs a run). |
| Electron IPC | `extension:info` (invoke), `extension:regenerate-token` (invoke), `extension:tracks-resolved` (event). It also uses the shared `download:line` event for its log lines. |
| TIDAL search (shared) | `GET https://api.tidal.com/v1/search/tracks?query=<url-encoded>&limit=10&countryCode=<cc>`. Headers: `Authorization: Bearer <access token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. 30 000 ms timeout, no retry. Non-200 throws `Search failed: <status> <body>`. Uses `items[].id/title/duration/artists[].name/mediaMetadata.tags`. |
| TIDAL credentials (shared) | `token.json` at `TIDAL_TOKEN_PATH` or `./token.json`. `getToken` refreshes through `auth.tidal.com/v1/oauth2/token` when expired and rewrites `token.json`. `getCountryCode` uses the cached value, else `GET /v1/users/<userID>?countryCode=US`, else `'US'`. The client credentials live base64-embedded in `tidal_auth_node.js` and are not touched by this feature. |
| Filesystem | Reads `<resourcesPath>/chrome-extension/*`; writes `<userData>/chrome-extension/*` and `<userData>/extension-token.txt`. |
| Spotify web player DOM | Rows `[data-testid="tracklist-row"]`; title link `a[href*="/track/"]`; artists `a[href*="/artist/"]`; the button goes into the last `[role="gridcell"]`. |
| Chrome APIs | `chrome.storage.local` (get/set/onChanged), `chrome.alarms` (create/onAlarm), `chrome.runtime` (onStartup, onInstalled, onMessage, sendMessage, reload, getManifest, openOptionsPage), `navigator.clipboard`. |
| npm | `npm run sync-ext` |

**User-visible strings (desktop app)**

| Where | Text |
|---|---|
| Activity log, push received | `🎵 <n> track<s> from Spotify extension — matching on TIDAL…` |
| Activity log, push added | `🎵 Spotify ext: added <a> track<s> (<m> matched on TIDAL[, <k> not found]).` |
| Activity log, match failure | `⚠ Extension match failed: <msg>` |
| Activity log, listen failure | `⚠ Chrome-extension bridge couldn't start: <msg> (tracks won't push from Spotify)` |
| Activity log, folder refreshed | `🧩 Chrome extension files updated to v<ver> at <dir>. Reload in chrome://extensions if it's already loaded.` |
| Queue badge | `Spotify ext` |
| Settings tab | `Extension`, `Chrome extension bridge`, `Local URL`, `Token`, `Managed extension folder`, `Copy`, `Copied ✓`, `Regenerate`, `Open`, the confirm text above, and the placeholders `(not generated yet — restart the app)` / `(extension bridge unavailable)` |
| Console | `[extension-server] listening on http://127.0.0.1:8273`, `[extension-server] could not persist token: <msg>`, `[ext-bundle] sync failed: <msg>` |

### Constants and magic values

| Name | Value | Where |
|---|---|---|
| Bridge port | `8273` | `extension-server.js:17`; also `content.js:15/23/32`, `background.js:15`, `popup.js:23`, `options.js:23/28`, `options.html:20` |
| Bind host | `127.0.0.1` | `extension-server.js:18` |
| Token | `crypto.randomBytes(16).toString('hex')`, validated by `/^[0-9a-f]{32}$/i` | `extension-server.js:40, 47` |
| Auth header regex | `/^Bearer\s+(.+)$/i` | `extension-server.js:81` |
| Body cap | `256 * 1024` bytes | `extension-server.js:97` |
| CORS | Origin reflected or `*`; methods `GET, POST, OPTIONS`; headers `Authorization, Content-Type`; max-age `86400` | `extension-server.js:73–76` |
| App identity | `'robogears-downloader'` | `extension-server.js:136`; checked in `background.js:36`, `popup.js:57`, `options.js:52` |
| Token file | `extension-token.txt` in userData | `electron-main.js:28` |
| Managed folder | `chrome-extension` under userData and under `process.resourcesPath` | `electron-main.js:766, 779` |
| Missing-manifest version | `'0.0.0'` | `electron-main.js:771–772, 786` |
| Queue `source` | `'extension'` | `electron-main.js:734, 742`; `renderer/app.js:922` |
| Badge | `Spotify ext` | `renderer/app.js:922` |
| Search limit | `10` | `electron-main.js:710` |
| Title scores | 100 exact / 50 startsWith either way / 25 includes either way / 0 | `electron-main.js:719–721` |
| Artist token min length | `> 2` characters | `electron-main.js:722` |
| Acceptance | `titleScore === 100 \|\| (titleScore >= 25 && artistScore >= 50)` | `electron-main.js:726` |
| Hi-Res tag | `'HIRES_LOSSLESS'` | `electron-main.js:737` |
| Reload alarm | name `check-pending-reload`, `periodInMinutes: 1` | `background.js:71` |
| Reload suppression | `300_000` ms | `background.js:47`, `popup.js:143` |
| Popup reload delay | `250` ms | `popup.js:233` |
| Toast duration | `2200` ms | `content.js:99–101` |
| Copy / saved feedback | 1200 ms (app Settings), 1500 ms (popup path copy), 1500 ms (options `Saved.`) | `renderer/app.js:1620`, `popup.js:207`, `options.js:39` |
| Content-script classes | `robogears-add-btn`, `robogears-add-btn-busy`, `robogears-toast`, `robogears-toast-ok`, `robogears-toast-error`, `robogears-toast-visible` | `content.js:13, 91–97, 153` |
| Row selector | `[data-testid="tracklist-row"]` | `content.js:12` |
| Extension version | `0.1.30` (equal to `package.json` `0.1.30`) | `manifest.json:4`, `package.json:3` |
| Settings DOM ids | `extension-url-input`, `extension-url-copy`, `extension-token-input`, `extension-token-copy`, `extension-token-regen`, `extension-path-input`, `extension-path-copy`, `extension-path-open`; tab/pane `extension` | `renderer/index.html:119, 163–184` |

### Rules and invariants

- The bridge binds `127.0.0.1` only. `GET /ping` and `OPTIONS` are the only routes without auth.
- The auth check runs before route matching and before body validation. The popup and options page rely on this: a zero-track POST answered with 400 means the token is good, and such a probe never triggers TIDAL work.
- `POST /queue/add` replies before any TIDAL work. A 200 `queued: N` does not mean the tracks reached the queue.
- Extension tracks get the same library tagging (`enrichWithLibraryStatus`) and the same queue dedupe and default-include rules as every other input. Exact library matches start excluded.
- The managed copy refreshes only in packaged builds, and only when the bundled manifest version is strictly newer or the managed copy is missing. That depends on someone running `npm run sync-ext` after each version bump.
- The extension's version is meant to equal the app's. Under the owner's versioning rule, `manifest.json` is one more place the version lives; removing the extension removes that place.
- The extension path never writes to the music library folder; it only reads it through `findInLibrary`.
- Removing the tab must keep the shared tab switcher (`renderer/app.js:1580–1589`, minus line 1587) and the shared styles.

### Edge cases and failure modes

- **macOS window closed, app still running:** `window-all-closed` does not quit on darwin (`electron-main.js:548–551`). The bridge keeps answering 200, Spotify shows "Added 1 to robogears", and `handleExtensionTracks` returns at 697, so the track is dropped. `mainWindow` is never reset to `null`; once the Dock icon re-creates a window, pushes work again. On Windows, closing the window quits the app, so the extension shows "App unreachable".
- **Not signed in to TIDAL:** a push reaches `lib.loadCred()`, which calls `process.exit(1)` (see Bugs).
- **Port 8273 already taken:** the listen fails and the activity log may show the "couldn't start" line (see Bugs: it is probably lost at startup). Settings still shows the URL and token as if all were well.
- **Body over 256 KB:** the socket is destroyed; the client most likely gets a network error, not the 400.
- **Body shapes:** a missing, non-array or empty `tracks` → 400 `No tracks in body`. All titles blank → 400 `No valid tracks`. Malformed JSON, a `null` body or a `null` item → 400 with the exception text.
- **Auth:** a wrong, missing or differently-cased token → 401. An unknown path without auth → 401 (not 404). `/ping?anything` → 401 without auth, 404 with it.
- **Corrupt or hand-edited token file** (not 32 hex characters): silently replaced at launch, so the extension's saved token stops working.
- **Token file not writable:** a new token is generated every launch.
- **Matcher, empty normalised strings:** titles or artists made only of non-Latin characters normalise to `''` (see Bugs).
- **Short artist names:** artist tokens of 2 characters or fewer (e.g. "U2") are ignored, so `artistScore` is 0 and only exact-title results are accepted.
- **Substring artist test:** a token like `the` matches any TIDAL artist string containing "the".
- **Unparseable rows:** a Spotify row with no `a[href*="/track/"]` (for example a local file) still gets a button, but clicking it shows `Could not parse this row`.
- **Rapid clicks:** each POST is matched in parallel with the others, and each writes its own pair of log lines. Dedupe happens later in the renderer.
- **Push during a batch download:** no add path (URL, search, import or extension) checks `isDownloading`. Tracks added mid-batch are not part of the running batch. They have no `dlStatus`, so the end-of-batch filter (`renderer/app.js:1468–1473`) keeps them for the next run if they are `included` or `notFound`. An excluded exact-library match added mid-batch is dropped from the queue when the batch ends.
- **Dev mode:** no managed folder is created. `/ping` reports `'0.0.0'`, or the version of a folder a packaged install created in the shared userData.
- **Downgrade:** installing an older app over a newer one never downgrades the managed copy.
- **Files removed from `chrome-extension/` in a later version** stay in the managed folder.
- **Service-worker alarm:** `chrome.alarms.create` runs at the top level of the worker, so every worker start re-creates (and re-times) the alarm. The cadence stays about one minute.

### Bugs and oddities

1. **High: a bridge request can terminate the app when TIDAL is not signed in.** `handleExtensionTracks` calls `lib.loadCred()` (`electron-main.js:702`). When `token.json` is missing, or holds an empty array, `loadCred` prints an error and calls `process.exit(1)` (`tidal_lib.js:48–60`). Any authenticated push of a non-empty track triggers this from the HTTP callback inside the Electron main process, and nothing checks first. The URL/search input has a renderer-side `tokenExists()` guard (`renderer/app.js:1290`), but the CSV/text import (`handleTracklistInput`, `renderer/app.js:1830–1855`) and the preview path (`electron-main.js:875`) reach the same exit without one. The expected effect is that the whole app quits; unverified (needs a run). **For the port:** a missing credential must be an error the caller can show, never a process exit.
2. **Medium (shared matcher): empty normalised strings make wrong matches likely.** `normalize` drops every character outside `[a-z0-9 ]` (`electron-main.js:712`, `944`; `tidal_lib.js:580`).
   - When **both** titles normalise to `''` (e.g. a Japanese title and a Japanese TIDAL result), `itT === wantT` gives `titleScore` 100, which is accepted whatever the artist. The first such result in TIDAL's order wins.
   - When **either side alone** is `''`, `x.startsWith('')` is true, so `titleScore` is 50. Any result whose artist overlaps by 50 % or more is then accepted, even with an unrelated title. An exact Latin match still outranks it when one exists.
   - Diacritics also split words (`beyoncé` → `beyonc`).
   This applies to the CSV import and Spotify URLs, which stay.
3. **Medium: tracks silently dropped when the window is closed on macOS.** The bridge answers `200 {ok:true, queued:N}` before matching (`extension-server.js:175–183`). `handleExtensionTracks` then returns at `electron-main.js:697` without a log line. The user sees "Added 1 to robogears", but nothing is queued.
4. **Low: the matcher is copy-pasted three times and has drifted.**
   - `electron-main.js:707–744` (extension) and `938–976` (CSV import) are identical except for `source`, and the CSV copy does **not** set `hiRes`, so imported rows never show the Hi-Res badge.
   - Only `spotifyTrackToTidal` (`tidal_lib.js:558–611`) tries an ISRC lookup first and adds a duration score (50 if under 3 s apart, 25 if under 8 s).
   - The CSV copy emits `tracklist:progress` once with `done: 0` before the loop and then after each track (936, 975); the extension copy emits nothing.
   - Error-branch items lack `duration`, `matchMethod`, `originalTitle` and `originalArtist`.
   - The comment at `electron-main.js:692–694` claims the extension uses "the same resolver the CSV import uses".
5. **Low: unauthenticated `/ping` is readable by any origin and reveals the home path.** `Access-Control-Allow-Origin` reflects any origin (`extension-server.js:73`), and `/ping` returns `managedExtensionPath` (which contains the OS user name through the userData path) and the app version (`126–142`). Any web page that can reach `127.0.0.1` could read it and so detect the app and learn the user name. Whether current browser private-network rules block this is unverified (needs a run). `/queue/add` stays token-protected, so pages cannot inject tracks. There is no Host-header check, but no route reveals the token.
6. **Low: comments and UI text describe a GitHub "Update" feature that does not exist.** These are `electron-main.js:504–505` (`onUpdateSelf`), `761–763` (`handleExtensionUpdateSelf`) and the Settings hint at `renderer/index.html:185`. The popup only has **Reload** / **Try reload**.
7. **Low: startup log lines are probably never shown.** `ensureExtensionBundle` sends its `🧩 …` line synchronously right after `createWindow()` (`electron-main.js:476, 500, 795–798`), before the page has loaded and registered `onDownloadLine` (`renderer/app.js:1456`). The listen-failure line (517–522) arrives only a moment later. Likely lost; unverified (needs a run).
8. **Low: the reload loop is slowed, not stopped.** Suppression lasts only 300 000 ms (`background.js:46–47`). While the folders stay mismatched and the app is running, the one-minute alarm calls `chrome.runtime.reload()` again about every 5–6 minutes, indefinitely. That contradicts `RELEASE_NOTES.md:11` ("No more infinite reload loops").
9. **Low: `regenerateToken` can silently diverge from disk.** The in-memory token changes first, and a write error is swallowed (`extension-server.js:62–67`). The user copies the new token, but after a restart the old one is loaded from disk.
10. **Low: Settings looks healthy when the bridge is down.** `extension:info` never reports whether the server is listening (`electron-main.js:805–809`). The two placeholder strings (`renderer/app.js:1605, 1608`) are effectively unreachable, since a token always exists before the renderer can call. If they did appear, **Copy** would copy them, and `Copied ✓` shows even when the clipboard write fails (1612–1621).
11. **Info: the popup puts `managedPath` into `innerHTML` unescaped** (`chrome-extension/popup.js:186–197`). The value comes from whatever process answers on port 8273. MV3's default CSP blocks inline script, but markup injection inside the popup is possible.
12. **Info: server `error` events after listening.** `_server.once('error', reject)` (`extension-server.js:196`) stays attached after a successful listen. The first later `error` event (e.g. an accept failure) is therefore absorbed silently by rejecting an already-settled promise; only a second one would be unhandled.
13. **Info: dead or unused code.** `getTokenPath` and `stopServer` are exported but never called (`extension-server.js:27–29, 204–209`). `spotifyId` is normalised and passed along (`166`) but never used. The worker's `open-options` message handler (`background.js:84–88`) has no sender.
14. **Info: stale docs and comments.**
    - `extension-server.js:7` says `/ping` returns `{ ok, version, app }`; it also returns the two managed-folder fields.
    - The header of `content.js` (lines 4, 9–10) describes a `"+ robogears"` text button and data-attribute dedupe; the code uses an icon-only button and a presence check.
    - `options.html:15` also says `+ robogears`.
    - `chrome-extension/README.md` (3–15, 19, 32–38) describes the text button, says to Load unpacked from the repo folder (the app manages a userData copy), uses the options page as the setup path (the popup is primary), and lists no popup or background files.
    - The Settings hint at `renderer/index.html:165` points to "the extension's options page".
15. **Info: the port can be edited in the extension but is fixed in the app.** The options page accepts any port (`options.js:18–24`) and says the app's port may have been changed. `extension-server.js:17` is hard-coded, and the app has no setting for it.
16. **Info: `sync-ext` is manual.** It is not in `.github/workflows/release.yml`. Forgetting it leaves the manifest version behind, and `ensureExtensionBundle` then never refreshes the managed copy. Both are `0.1.30` today.
17. **Info: saved but unread queue fields.** `matchMethod`, `originalTitle` and `originalArtist` are written to `queue.json` (`electron-main.js:735, 738–739`) and never read anywhere.

### Platform-specific behaviour

- **Leftover location:** macOS `~/Library/Application Support/robogears Downloader/`; Windows `%APPDATA%\robogears Downloader\`. The name is forced by `app.setName` (`electron-main.js:13`), so dev and packaged builds share it.
- **Bundled source:** macOS `robogears Downloader.app/Contents/Resources/chrome-extension/`; Windows `<install dir>\resources\chrome-extension\`.
- **Windows uninstall:** NSIS `deleteAppDataOnUninstall: false` (`package.json:80`), so the token file and the managed folder survive an uninstall.
- **macOS:** closing the window keeps the app and the bridge running, but pushes are dropped (see Bugs).
- **Browsers:** the extension is Chromium MV3 only (Chrome, Edge, Brave, Arc). There has never been a Safari or Firefox version.
- **Loopback:** IPv4 only; nothing listens on `::1`, and every extension request targets `127.0.0.1` explicitly.

### Porting notes for a native Swift macOS app

| Topic | Today | Swift app |
|---|---|---|
| Local HTTP bridge | `extension-server.js` on `127.0.0.1:8273` | **Drop.** Open no listening socket at all. (For the record only, the equivalent would be a loopback-bound `NWListener`.) |
| Extension token | `extension-token.txt`, random bytes, constant-time compare | **Drop.** Do not read the old file. |
| Managed extension folder | `extraResources` → userData copy at launch | **Drop.** No bundle resource and no copy step. If the owner wants leftovers tidied, do a one-time check for `~/Library/Application Support/robogears Downloader/chrome-extension` and `extension-token.txt` and **move them to the Trash** (`FileManager.trashItem`), never hard-delete; this is the owner's call. |
| Extension IPC | `extension:info`, `extension:regenerate-token`, `extension:tracks-resolved` | **Drop.** Nothing replaces them. |
| Settings → Extension pane | 4th Settings tab with Copy, Regenerate, Open | **Drop.** The Settings window has no Extension pane. |
| Version sync | `scripts/sync-extension-version.js` | **Drop.** The version lives only in the Xcode target (`MARKETING_VERSION` / Info.plist). |
| Chrome extension | `chrome-extension/*` | **Not ported.** Reviving one-click adding from a browser would be a separate browser-extension product, which is out of scope under the 21 Oct 2026 decision. |
| Title + artist matcher | Three copies (above) | **Keep, once.** One pure function (normalise → score → filter → sort) used by the CSV/text import and, with ISRC + duration added, by Spotify URLs. Fix normalisation, for example Unicode case folding plus diacritic folding (`String.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)`), keep letters from every script, and treat an empty normalised title as "no title signal" rather than a match. Report per-track progress for the `Matching N / M` overlay. Use `URLSession` against `https://api.tidal.com/v1/search/tracks` with the same parameters and headers, and a 30 s timeout. |
| Missing TIDAL credentials | `loadCred` → `process.exit(1)` | Throw a typed error ("Sign in to TIDAL first"); never terminate. |
| Legacy `queue.json` | Items may carry `source: "extension"` | If the port imports the old queue, decode `source` as an open string or an enum with an `unknown(String)` fallback, so `"extension"` does not fail decoding. These items remain downloadable by `tidalId`. |

### Open questions

1. Should the Swift app tidy the Electron leftovers (`extension-token.txt`, `chrome-extension/`) in Application Support: leave them, offer once, or move them to the Trash automatically? Will the Swift app reuse the same `robogears Downloader` Application Support folder at all?
2. If the old `queue.json` is imported, how should `source: "extension"` rows be labelled: `Spotify`, no badge, or `Spotify ext`?
3. Should there be one last Electron release that removes the bridge and tells users to remove the extension in `chrome://extensions`, or does support simply stop with the Swift app? Until users remove it, their Chrome profile keeps the extension and its stored token.
4. Should the CSV/text import set the Hi-Res flag in the port (the extension's copy did; the import's copy does not)?
5. Should the port fix the matcher's normalisation (see Bugs 2), even though this changes which tracks some imports match?
6. Did the content-script POST from `https://open.spotify.com` to `127.0.0.1` keep working under Chrome's private/local-network rules, given the server sends no `Access-Control-Allow-Private-Network`? Unverified (needs a run); this only matters for explaining past user reports.
7. Does electron-builder copy `chrome-extension/README.md` into Resources? Unverified (needs a build); it only affects what sits in the leftover folder.
8. Is a non-extension replacement for "add from Spotify in one click" wanted? Today's alternatives are pasting a Spotify track, album or playlist URL (playlists capped at 100 tracks) and the CSV/text drop-zone.
