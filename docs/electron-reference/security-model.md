## Gap: Security model and privilege boundary

**Scope.** This section covers who is trusted with what in the Electron app (v0.1.30): the window settings, the content security policy, every place remote or saved text becomes HTML, what the main process does on the page's say-so, the update chain, the macOS relauncher script, secrets and personal data on disk, and what a native Swift macOS app must do in their place. Files read in full or in the relevant parts: `electron-main.js`, `electron-preload.js`, `renderer/index.html`, `renderer/app.js`, `tidal_lib.js`, `tidal_auth_node.js`, plus `bulk_runner.js`, `tidal_download.js`, `extension-server.js`, `package.json` and `.gitignore` where they touch the boundary. Nothing was run. Claims about Electron, Node or macOS defaults that the repo cannot show are marked **unverified (needs a run)**. No secret values appear here, and no `token.json` or `extension-token.txt` was opened.

**In one paragraph.** The page (the "renderer") is isolated from Node.js, but the main process believes everything the page asks for. It will fetch any `https` URL the page names and later run the result as the new app, open any path with the OS, write any settings object, and write downloads into any folder the page names. The page itself is mostly careful: almost all text is escaped or set as plain text. Two HTML sinks are not escaped, though: the GitHub release tag, and the queue row key and track ID read back from `queue.json`. The CSP still allows inline script, so markup injected through those sinks could reach the whole `window.api`. In practice both sinks are hard to reach. The update payload has no hash or signature check. On macOS the relauncher also strips quarantine and re-signs the new app, so Gatekeeper never looks at it. The trust root for code is therefore TLS plus whoever can publish a release on `robogears/robogearsDownloader`. TIDAL credentials sit in a plain JSON file. In a Swift app the renderer/main split disappears. The lessons that carry over are: only verified updates run, URLs and paths come from the app's own state and never from UI strings, secrets go in the Keychain, and folders are kept as security-scoped bookmarks.

Terms used below: **IPC** = the message channel between the page and the main process. **Preload** = the small script that builds `window.api` for the page. **CSP** (content security policy) = the page's rule list for which scripts, images and connections are allowed. **TCC** = macOS privacy permissions (the "would like to access files in your Downloads folder" prompts). **Security-scoped bookmark** = a saved, sandbox-safe reference to a folder the user picked.

---

### 1. Trust zones

| Zone | Code | Runs with | Can do | Takes input from |
|---|---|---|---|---|
| Main process | `electron-main.js` (+ `tidal_lib.js`, `tidal_auth_node.js`, `extension-server.js` loaded in-process) | Full user privileges, Node.js | Files, child processes, network, `shell.openPath`, `shell.openExternal`, dialogs | The page (25 `ipcMain.handle` channels), GitHub, TIDAL, Spotify, its own JSON files, the extension HTTP server |
| Preload | `electron-preload.js` | Node available (because `sandbox: false`), but uses only `contextBridge` + `ipcRenderer` (`:2`) | Exposes `window.api` (`:4-66`) | — |
| Page | `renderer/index.html`, `renderer/app.js` | Chromium renderer; `contextIsolation: true`, `nodeIntegration: false` | DOM, Web Audio, Blob URLs, `window.api` only | User typing, clipboard paste, dropped/picked files, IPC events from main |
| Download children | `bulk_runner.js` → `tidal_download.js` | `process.execPath` with `ELECTRON_RUN_AS_NODE=1` (`electron-main.js:64, 996-999`; `bulk_runner.js:41-44`), full user privileges | Read `token.json` themselves, write audio into `outDir`, run FFmpeg | A temp tracklist JSON written by main (`electron-main.js:991-992`), argv |
| Extension bridge (inventory only, being dropped) | `extension-server.js` | Inside main | Accepts tracks over HTTP on `127.0.0.1:8273` (`:17-18`) | Any local HTTP client with the bearer token; `/ping` needs none |

Inbound surfaces that do **not** exist: no custom URL scheme (`setAsDefaultProtocolClient` absent), no `open-url`/`open-file` handlers, no `process.argv` parsing in main, no web workers. All confirmed by search.

**What never reaches the page:** the TIDAL access token, refresh token and client secrets. No IPC channel carries them. `token:exists` returns only a boolean (`electron-main.js:610-613`), and the auth modal shows the user ID and country (`tidal_auth_node.js:160-161`). Children get the token's *path* through the environment (`TIDAL_TOKEN_PATH`, inherited via `childEnv()` at `electron-main.js:60-71`), not the token itself.

---

### 2. Window and page hardening

`createWindow()` (`electron-main.js:73-99`) passes, verbatim:

```js
webPreferences: {
    preload: path.join(__dirname, 'electron-preload.js'),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: false,
},
autoHideMenuBar: true,
```

- `contextIsolation: true` and `nodeIntegration: false` mean page scripts cannot touch Node or the preload's own scope. They see only the frozen `window.api` object.
- `sandbox: false` (`:85`) turns off Chromium's OS-level process sandbox for this renderer and gives the preload full Node. Electron 33 (`package.json` devDependency `^33.0.0`) sandboxes renderers by default, so this is a deliberate opt-out. The preload needs only `require('electron')` for `contextBridge` and `ipcRenderer` (`electron-preload.js:2`), and both are available to sandboxed preloads. `sandbox: true` should therefore work unchanged. **Unverified (needs a run).**
- The preload exposes fixed, named methods only. There is no generic `invoke(channel, …)`. Event wrappers forward the payload and drop the IPC event object (for example `(_e, payload) => cb(payload)` at `:14`), so `event.sender` never leaks to the page. No method removes a listener. (That is a leak, not a security issue: `insertUpdateNotice` adds a new progress listener each time it runs, `app.js:424`.)
- `webSecurity`, `allowRunningInsecureContent`, `webviewTag` and `devTools` are not set, so Electron's defaults apply.
- `autoHideMenuBar: true` (`:87`) only affects Windows and Linux.
- `loadFile(renderer/index.html)` (`:97`). `openDevTools` is commented out (`:98`).

Absent (confirmed by search across main, preload, renderer, lib, auth, extension server, bulk runner and downloader):

- **`will-navigate` guard and `setWindowOpenHandler`.** Nothing stops the window navigating away from `index.html`. The preload runs on every page load in that window, so a page it navigates to would also get `window.api`. **Unverified (needs a run).** The code has only one realistic trigger. Drag-over and drop are cancelled only on `#drop-zone` (`app.js:1765-1782`), with no document-level `dragover`/`drop` handler. Chromium's default for a file dropped anywhere else is to open that file in the window. **Unverified (needs a run).** The page has no `target="_blank"` links, and its one `<a>` is `href="#"` with `preventDefault()` (`index.html:52`, `app.js:1813-1816`).
- **`session.setPermissionRequestHandler` / `setPermissionCheckHandler`.** Electron's documented default is to grant every permission request. The page asks for none.
- **`app.on('web-contents-created')`.**
- **`requestSingleInstanceLock`.**
- **`Menu.setApplicationMenu`.** `Menu` is not even imported (`electron-main.js:2` imports `app, BrowserWindow, ipcMain, dialog, shell`). Electron therefore installs its default application menu. Per Electron's documented default menu, it includes **View → Reload / Force Reload / Toggle Developer Tools** (Cmd+Option+I), in packaged builds too. The DevTools console runs in the page's context and can call every `window.api` method. **Unverified (needs a run).**
- **Electron fuses.** `package.json#build` configures none. The app *depends* on the `RunAsNode` fuse, because its children are started with `ELECTRON_RUN_AS_NODE=1`. Electron's documented fuse defaults leave `RunAsNode`, `NODE_OPTIONS` and `--inspect` honoured, and asar integrity unchecked. Any local process could therefore start the app's binary as plain Node under the app's code identity, and macOS may attribute that process's file access to the app's privacy (TCC) grants. **Unverified (needs a run).** This disappears in a Swift app.

---

### 3. Content Security Policy

Set only by a meta tag (`renderer/index.html:5`). Main sets no CSP header. Verbatim:

```
default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;
```

| Directive | Needed by the code? | Evidence |
|---|---|---|
| `script-src 'self' 'unsafe-inline'` | `'unsafe-inline'` is **not** needed | The only script is `<script src="app.js">` (`index.html:233`). A search finds no `on…=` attributes and no `javascript:` URLs in `index.html` or `app.js`. It also finds no `eval`, `new Function` or string `setTimeout` in `app.js`. |
| `style-src 'self' 'unsafe-inline'` | Needed | Inline `style=` in `index.html:133, 165, 166, 171, 179` and in the queue template `app.js:939` (`style="width:${t.dlPercent ?? 0}%"`). |
| `img-src … data: blob:`, `worker-src … blob:` | Not obviously used | No `new Worker`. Waveforms are drawn on `<canvas>`. |
| `media-src 'self' blob:` | Needed | Preview audio plays from a `URL.createObjectURL(blob)` (`app.js:720-721`). |
| `connect-src 'self'` | Fine | The page makes no network calls itself; main does them all. |

Why `'unsafe-inline'` matters: with it, a string that reaches `innerHTML` and carries an event handler (for example an `<img>` with an `onerror` attribute) runs as script. `connect-src 'self'` does not contain such a script. It can still call `window.api.openExternal('https://…?data')` to leak data, or `window.api.downloadUpdate(url)` followed by `window.api.applyUpdate()` to run code (section 5).

---

### 4. HTML sinks in the page

The escaper (`app.js:92-94`), verbatim:

```js
function escapeHtml(s) {
    return (s || '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
```

It is safe for text and for double-quoted attributes. The activity log uses `textContent` (`appendLine`, `app.js:342-346`), so every `download:line` message is inert, including remote track titles and error bodies. So are the auth output (`app.js:1731-1734`), the auth URL (an input's `.value`, `:1737`) and the search modal title and hint (`:1331-1332`).

Every `innerHTML` write and what it interpolates:

| Line | Interpolated values | Escaped? | Source of the values |
|---|---|---|---|
| `app.js:382` | `${version}` | **No** | `release.tag_name` from `api.github.com/repos/robogears/robogearsDownloader/releases/latest` (`electron-main.js:115-139, 161`) |
| `app.js:913` | `t.dlPercent` | No, safe in practice | Set from `Number(m[2])` of a progress marker (`electron-main.js:1010-1011`). It is a transient field, deleted before saving (`app.js:71, 78`) and on restore (`:1976`) |
| `app.js:918-919, 929` | `lm.path`, `lm.libraryTitle` | Yes | Library scan |
| `app.js:933, 936, 946, 974` | `data-key="${t.key}"` | **No** | See below |
| `app.js:939` | `t.dlPercent` | No, safe (transient numeric) | As above |
| `app.js:946` | `t.selected` | n/a (ternary on a boolean) | — |
| `app.js:952, 955` | `data-tidal-id="${t.tidalId}"` | **No** | See below |
| `app.js:965, 968` | `t.title`, `t.artist` | Yes | Resolver / import |
| `app.js:968`, `1341` | `fmtDuration(t.duration)` | No, safe | `fmtDuration` (`:88-91`) does arithmetic, so a non-number becomes `NaN:NaN`, never markup |
| `app.js:1337-1343` | `data-idx="${i}"`, title/artist/album | Index is a loop counter; strings escaped | — |
| `app.js:361, 893, 1333` | `''` | n/a | Clears |
| `app.js:663-665, 994, 1043, 1490` | Constant strings / SVG (`PLAY_ICON_HTML` etc., `:653-655`) | n/a | — |

**Where `t.key` and `t.tidalId` come from:**

1. **New items.** `addTracksToQueue` pushes `{ ...t, key: uniqueKey() }` (`app.js:1263`), so `key` is always the app's own 8-character base-36 string (`:87`). `tidalId` comes from TIDAL JSON (`it.id`) in every resolver path: `electron-main.js:733, 965` and `tidal_lib` resolvers.
2. **Restored items.** At boot, `api.getQueue()` returns `queue.json` parsed with no shape check (`electron-main.js:594-597`). Each item is shallow-copied, transient fields are deleted, and `key` is **kept if present**: `if (!c.key) c.key = uniqueKey();` (`app.js:1972-1979`). `tidalId` is kept as-is. Both then go into `renderQueue()` unescaped.

**Likelihood is low.** To use the queue sink, someone must already be able to write to `~/Library/Application Support/robogears Downloader/queue.json` as the user, and that person can already do anything the user can. To use the tag sink, someone must publish a release on the owner's repo, and that already controls the update channel. The tag must also pass `isNewerVersion` (`electron-main.js:103-113`), which reads leading digits leniently (`parseInt('9<…', 10)` is `9`). The chain still matters for defence in depth: injected markup, then an inline handler, then `window.api.downloadUpdate(<any https URL>)`, then `applyUpdate()`, is code execution with quarantine stripped (section 6).

The click handlers read `dataset.key` and compare it with `===` (`app.js:1074-1124`), and turn `dataset.tidalId` into a number with `Number(...)` (`:1066, 1148, 1175, 1200, 1215`). The background pre-loader is the exception: it passes the raw `t.tidalId` (`:730-737`, called at `:1267` and `:1985`).

---

### 5. Privileged verbs: what main does on the page's word

None of the 25 handlers looks at the IPC event (`_e.sender`, `_e.senderFrame`). Any frame or page loaded in the window can call any of them.

| Channel (line) | Page controls | Main does | Checks | Notes |
|---|---|---|---|---|
| `shell:open-external` (`electron-main.js:186-188`) | `url` | `shell.openExternal(url)` (not awaited) | `typeof url === 'string' && /^https?:\/\//.test(url)` | Allows `http`. No host allow-list. Callers: `downloadUrl` from GitHub (`app.js:394, 458`) and `'https://exportify.net'` (`:1815`) |
| `token:run-auth` (`:614-642`) | nothing | Runs the device flow; `onVerificationUrl` calls `shell.openExternal(url)` (`:630`) | **None**: no scheme or host check | The URL is TIDAL's `verificationUriComplete` (`tidal_auth_node.js:99-101`) |
| `update:download` (`:288-312`) | `url` | Downloads to `os.tmpdir()/robogears-downloader-<Date.now()>.dmg\|.exe` (`:291-292`). On macOS it also mounts the DMG and copies out the `.app` (`:299-303`). Stores the result in `global._pendingUpdatePath` | `canSelfInstall()` (packaged + win32/darwin, `:194-200`) and `/^https?:\/\//` (`:290`). **No host allow-list** | An `http://` URL passes the regex but `https.request` rejects a non-`https:` protocol (Node's `ERR_INVALID_PROTOCOL`; **unverified (needs a run)**), so in effect any `https` host. Up to 5 redirects to any host (`:207-212`). A redirect to `http:` or a relative `Location` throws inside the response callback, uncaught (see the updater section). No size cap. Timeout 60 s of socket inactivity (`:230`) |
| `update:apply` (`:314-469`) | nothing directly; runs whatever the last `update:download` fetched | Windows: `spawn(newPath, ['/S', '--updated'], { detached: true, stdio: 'ignore', windowsHide: true })` (`:331-336`). macOS: writes and runs the relauncher (`:345-459`). Then `app.quit()` after 500 ms (`:467`) | `canSelfInstall()`, `fs.existsSync(newPath)` | **No hash, signature, bundle-ID or version check** |
| `open-folder` (`:575`) | `p` | `shell.openPath(p)` | **None** (a non-string makes Electron throw, so the invoke rejects) | `openPath` opens *anything* in its default app: it launches `.app` bundles and runs `.command` files in Terminal (general macOS behaviour). Callers pass `settings.downloadFolder`, `settings.libraryFolder` or the managed extension path (`app.js:1496, 1528, 1543, 1635`) |
| `settings:save` (`:556`, `saveSettings` `:42-52`) | whole object `s` | `writeFileSync(settings.json, JSON.stringify(s, null, 2))`, replacing the file (no merge). If `s.libraryFolder` is a string that changed, it calls `lib.setLibraryPath` and starts a recursive scan | **None** | The page can point the "read-only" library scan at any folder (read-only, but it recurses) |
| `settings:pick-folder` (`:567-573`) | nothing | `dialog.showOpenDialog(mainWindow, { properties: ['openDirectory'], defaultPath? })`, returns the path | — | Main does not remember what the user picked. The page saves whatever string it likes afterwards (`app.js:1517-1540`) |
| `bulk:start` (`:986-1041`) | `tracks[]`, `outDir` | Writes `{tracks, outDir}` to `<userData>/pending-tracklist.json`, then spawns `process.execPath bulk_runner.js <list>` | Only `!outDir` and "another batch running" | **`outDir` comes from the page, not from settings.** `tidal_download.js:687-688` resolves it and runs `mkdirSync(..., { recursive: true })`. Each `tidalId` becomes argv `String(trackId)` (`bulk_runner.js:35`), with no shell. `parseTidalUrl` accepts URLs and UUIDs as well as numbers (`tidal_lib.js:431-447`), so a `tidalId` holding an album URL would download the whole album |
| `preview:get-audio` (`:873-917`) | `tidalId` | `getPlaybackInfo(tidalId, …)` calls `GET api.tidal.com/v1/tracks/${id}/playbackinfopostpaywall` **with the Bearer token** (`tidal_lib.js:286-292`), then fetches the manifest URLs | **None**: `id` goes into the path unencoded | On failure the response body comes back to the page (`tidal_lib.js:294`: `Playback info failed: ${res.status} ${res.body}`). Media URLs may be `http:` (`tidal_lib.js:197` picks `http` unless the URL starts with `https`) |
| `queue:save` (`:599-606`), `queue:get` (`:594-597`) | whole array | Writes/reads `queue.json` | None | Feeds the sinks in section 4 |
| `resolve:input` (`:658-687`), `resolve:tracklist` (`:919-982`) | query strings | TIDAL search / Spotify embed fetch | Parsing only | Network only. All of these call `lib.loadCred()`, which calls `process.exit(1)` when the token file is missing or `[]` (see the auth section) |
| `settings:reset` (`:561-565`) | nothing | Writes `{downloadFolder:'', libraryFolder:''}` | — | — |
| `extension:info` / `extension:regenerate-token` (`:805-812`) | nothing | Returns or rotates the extension bearer token **to the page** | — | Inventory only |
| Read-only / no input: `update:check`, `app:version`, `update:can-self-install`, `settings:get`, `token:exists`, `library:status`, `library:rescan`, `download:cancel`, `resolve:cancel` | — | — | — | `library:status` runs a scan if none is cached |

Main → page events (13): `auth:output`, `auth:url`, `bulk:track-done`, `bulk:track-progress`, `bulk:track-start`, `download:done`, `download:line`, `extension:tracks-resolved`, `library:scan-progress`, `library:scanned`, `tracklist:progress`, `update:available`, `update:download-progress`.

---

### 6. The update trust chain, end to end

1. `fetchLatestRelease` (`electron-main.js:115-139`): HTTPS GET `api.github.com` `/repos/robogears/robogearsDownloader/releases/latest`, unauthenticated, headers `User-Agent: robogears-downloader/<version>` and `Accept: application/vnd.github+json`, 10 s timeout. Any non-200 response, parse error or timeout gives `null`.
2. `getUpdateStatus` (`:145-162`): newer `tag_name` → the asset whose `name` *contains* `'mac-arm64.dmg'` (darwin) or `'setup.exe'` (win32), else `html_url`.
3. `update:available` sends `{version, downloadUrl, releaseUrl}` to the page (`:164-172`). The page keeps `downloadUrl` (`app.js:373, 445`) and **hands it back** to `update:download` (`app.js:405, 466`). Main never checks that the URL it gets back is the one it sent.
4. Download (`:204-235`): no checksum, no expected size. `content-length` drives progress only.
5. macOS staging (`:241-286`):
   - `hdiutil attach -nobrowse -quiet -mountpoint <tmp>/robogears-mount-<ts> <dmg>`.
   - Take the first directory entry whose name ends in `.app` (`:265`).
   - `ditto <mount>/<name>.app <tmp>/robogears-update-<ts>/<name>.app` (`:277`), then `hdiutil detach -quiet`.
   - The only integrity check anywhere is whatever `hdiutil` checks on attach (general macOS behaviour; **unverified (needs a run)**).
6. Apply. On Windows, the unsigned NSIS installer runs silently. On macOS, the relauncher (section 7):
   - `xattr -dr com.apple.quarantine "$NEW_APP"` (`:411`)
   - `mv` into `$TARGET`, keeping a `.bak` (`:413-423`)
   - `codesign --force --deep --sign - "$TARGET"` (`:425`)
   - `open "$TARGET"` (`:429`)

   Stripping quarantine means Gatekeeper never assesses the new bundle. Re-signing ad hoc replaces any signature the payload carried, so even a properly signed payload could not be told apart from a tampered one afterwards.

**Trust root:** TLS to `api.github.com` and to the asset host, plus every person or token able to publish a release on the owner's GitHub account. `/releases/latest` returns published releases only, never drafts. **Severity: Medium.** It is by design for an updater, but nothing stops a bad payload once the channel is compromised, and the page can redirect the download anywhere (section 5).

---

### 7. The macOS relauncher script: paths pasted into bash

The script is built as a JavaScript array of lines (`electron-main.js:385-441`), written to `os.tmpdir()/robogears-update-<ts>.sh`, given `chmod 0o755` (`:442-443`) and run as `/bin/bash <script> <pid>` (`:448-451`). Four lines paste paths inside double quotes with no escaping:

| Line | Verbatim template | Value comes from |
|---|---|---|
| `:387` | `` `LOG="${logPath}"` `` | `~/Library/Logs/robogears Downloader/update-<ts>.log` (`:354, 358`) |
| `:400` | `` `NEW_APP="${newPath}"` `` | `os.tmpdir()/robogears-update-<ts>/<name>.app`, where **`<name>` is whatever `.app` name the downloaded DMG contains** (`:265, 276`) |
| `:401` | `` `TARGET="${targetAppBundle}"` `` | The running bundle path, or `/Applications/robogears Downloader.app` if translocated (`:345-349`) |
| `:402` | `` `RUNNING_FROM="${runningAppBundle}"` `` | `app.getPath('exe')` with `/Contents/MacOS/<exe>` cut off (`:345`), i.e. **wherever the user put the app** |

`TRANSLOCATED` is a fixed `'1'`/`'0'` (`:403`). `PID` is `String(process.pid)` (`:448`). After these assignments the script quotes every use (`"$TARGET"`, `"$NEW_APP"`, `"$BACKUP"`), so these four lines are the only injection points.

Inside bash double quotes, `"` ends the string and `$…`, `` `…` `` and `\` are interpreted. If a path contains `"`, the script breaks. If it contains `$(…)` or backticks, that text runs as a command when the script starts. The home folder and `$TMPDIR` normally contain only safe characters on macOS (general macOS behaviour, not checked here). The realistic carriers are therefore **a folder name the user chose for the app** (`TARGET`/`RUNNING_FROM`) and **the bundle name inside the downloaded DMG** (`NEW_APP`). The DMG case adds no new power, because a hostile DMG already gets installed and opened. **Severity: Low.** The breakage case (a `"` or `$` in an install folder name) is the likelier problem.

Side files: `~/Library/Logs/robogears Downloader/attempts.log` (appended, `:361-371`) and `update-<ts>.log` (`set -x` trace, `:395-396`). They record the PID and paths, but no secrets.

---

### 8. Secrets and personal data at rest

| File | Where | Holds | Written by | Format, permissions, safety |
|---|---|---|---|---|
| `token.json` | Packaged: `<userData>/token.json` (`electron-main.js:19-21`), i.e. `~/Library/Application Support/robogears Downloader/token.json`. Dev: `<repo>/token.json` (`tidal_lib.js:13`, `tidal_auth_node.js:15`, `electron-main.js:611`) | A JSON array of `{access_token, refresh_token, userID, countryCode, expires_at, client_ID, client_secret}` (`tidal_auth_node.js:148-156`) | `saveToken` (`tidal_auth_node.js:53-59`), `saveCred` (`tidal_lib.js:62-68`) | Plain JSON, 4-space indent. `fs.writeFileSync` with no mode, so the permissions come from the umask (typically 0644). No `chmod`. Not atomic, no lock. Main and every download child can refresh and rewrite it at about the same time (children read the same path via `TIDAL_TOKEN_PATH`). Ignored by git (`.gitignore`: `token.json`) and excluded from packages (`package.json` `files`: `!**/{*.log,*.tmp,token.json}`) |
| `extension-token.txt` (inventory) | `<userData>/extension-token.txt` (`electron-main.js:28`) | 32 hex characters from `crypto.randomBytes(16)` (`extension-server.js:39-41`) | `extension-server.js:55, 65` | Plain text, umask permissions |
| `settings.json` | `<userData>` (`electron-main.js:26`) | `downloadFolder`, `libraryFolder` (plain absolute path strings), `volume` | `:44` | Not secret, but the paths include the username. Not atomic |
| `queue.json` | `<userData>` (`:27`) | The queue (titles, artists, TIDAL IDs, library-match paths) | `:601` | Personal listening data. Not atomic. Read back into HTML sinks |
| `pending-tracklist.json` | `<userData>` (`:991`) | `{tracks, outDir}` for the current batch | `:992`, deleted on close (`:1037`) | Not atomic |

On this machine `~/Library` and `~/Library/Application Support` are `drwx------` (seen with `ls -ld`; the files inside were not opened). Other local accounts therefore cannot read the packaged `token.json` despite its 0644 mode. A dev-mode token next to the source has only whatever protection the repo folder has, and it travels with any copy or sync of that folder.

Behaviours that touch secrets (details in the auth section):

- **A corrupt token file is silently replaced.** If `token.json` will not parse, `loadTokens()` returns `[]` (`tidal_auth_node.js:43-51`), and the next sign-in rewrites the file with only the new entry. `loadCred()` throws `SyntaxError` on the same file (`tidal_lib.js:53`), and handlers turn that into an error message.
- **Credentials pile up.** `saveToken` removes only an entry with the same `client_ID` *and* `refresh_token`, then appends (`tidal_auth_node.js:54-57`). Each re-sign-in adds another live refresh token to the file, and nothing ever prunes them. Meanwhile `loadCred()` keeps using `entries[0]` (`tidal_lib.js:59`).
- **Embedded client credentials.** `tidal_auth_node.js:17-20` holds four base64 string literals, decoded with `Buffer.from(<literal>, 'base64').toString('latin1')`:
  - `AUTH_CLIENT_ID` and `AUTH_CLIENT_SECRET` are used for the device-code request and the token poll's `Authorization: Basic` header (`:86, 131, 141`).
  - `REQUEST_CLIENT_ID` and `REQUEST_CLIENT_SECRET` are copied into every `token.json` entry (`:154-155`). `refreshToken` later sends them as Basic auth (`tidal_lib.js:76-81`, header built at `:141`).

  Base64 is an encoding, not protection. `app.asar` is not encrypted, so anyone holding the app can read them. These are third-party app credentials, not the user's. The values are deliberately not reproduced here.
- **Error text reaches the page.** Messages such as `Token refresh failed: ${res.status} ${res.body}` (`tidal_lib.js:84`) and `Device authorization failed: …` (`tidal_auth_node.js:95`) include TIDAL's response body. They are shown as plain text. Error bodies are not expected to contain tokens.

---

### 9. Other privacy-relevant behaviour shown by the code

- **Pasting sends clipboard text to TIDAL.** A paste anywhere outside an `<input>`/`<textarea>` triggers an import (`app.js:1800-1808`) when the text is at least 10 characters and contains a newline, a comma, or a spaced `-—–|` separator. The plain-text parser accepts any line of 2 or more characters as a title (`:1923-1938`). Every line is then sent as a TIDAL search query (`electron-main.js:938-942`), with no confirmation and no size cap. If someone pastes notes or an address while the page body has focus, that text goes to `api.tidal.com`. **Low.**
- **Extension `/ping` (inventory; the extension is being dropped).** `GET /ping` needs no token (`extension-server.js:126-143`). CORS reflects any `Origin` (`:73`), and the reply includes `managedExtensionPath`, a path inside the user's home folder (and so the username). Any web page the user visits could read it, unless Chrome's private-network rules block the request. **Unverified (needs a run).** The other route checks a bearer token with `timingSafeEqual` (`:79-88`) and caps request bodies at 256 KB (`:90-104`, cap at `:97`).

---

### 10. Findings, most severe first

| # | Severity | Finding | Evidence |
|---|---|---|---|
| 1 | Medium | The update payload runs with no hash or signature check. On macOS quarantine is stripped and the bundle re-signed ad hoc, so Gatekeeper never assesses it | `electron-main.js:204-235, 288-312, 331-336, 411, 425, 429` |
| 2 | Low | `update:download` fetches any `https` URL the page passes (main does not keep the URL it advertised). With finding 1, a page compromise means code execution | `:288-290`, `app.js:405, 466` |
| 3 | Low | The CSP allows inline script, which the page does not need. Two unescaped sink families: the GitHub tag, and `t.key`/`t.tidalId` restored from `queue.json` | `index.html:5`; `app.js:382, 933, 936, 946, 952, 955, 974, 1977` |
| 4 | Low | The relauncher pastes four paths into bash double quotes without escaping | `electron-main.js:387, 400-402` |
| 5 | Low | Hardening gaps: `sandbox: false`, no navigation or window-open guard, no permission handler, default menu with DevTools, Electron fuses at defaults | `:83-87`; search results in section 2 |
| 6 | Low | `token.json`: plain text, umask permissions, not atomic, corrupt files silently replaced, refresh tokens accumulate | `tidal_auth_node.js:43-59`; `tidal_lib.js:62-68` |
| 7 | Low | `open-folder` passes any path to `shell.openPath` (which launches apps). `openExternal` allows `http`. The auth URL is opened with no check | `electron-main.js:575, 186-188, 630` |
| 8 | Low | `preview:get-audio` puts an unvalidated `tidalId` into an authenticated TIDAL path and returns the error body to the page | `:873-878`; `tidal_lib.js:287, 294` |
| 9 | Low (privacy) | A paste outside inputs sends every line to TIDAL search without asking | `app.js:1800-1808, 1923-1938` |
| 10 | Info | Extension `/ping` reveals a home-folder path to any origin (being dropped) | `extension-server.js:73, 126-143` |

---

### 11. Porting notes for a native Swift macOS app

**The boundary itself goes away.** There is no page, preload, IPC or CSP. Keep the same discipline inside one process:

- **The updater never takes a URL from the UI.** The "Update now" action calls `updater.installLatest()`, which uses the release it discovered itself.
- **Verify before staging.** Either use Sparkle 2 with an EdDSA (ed25519) key (`SUPublicEDKey` in Info.plist, archives signed with `sign_update`), or hand-roll it: publish a SHA-256 or EdDSA signature with each release and check it before touching `/Applications`. After staging, also check the new bundle's `CFBundleIdentifier` (`com.robogears.downloader`, from `package.json#build.appId`) and that its version is higher.
- **Strip quarantine only from a verified bundle.** Never re-sign over a payload you have not verified.
- **No shell strings.** Swap bundles with `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)`, or a helper started with `Process` and an `arguments` array (`executableURL` + `[String]`), never `/bin/bash -c` or a generated script. The same goes for FFmpeg.
- **Show remote strings with `Text(verbatim:)`.** Pass a `String` variable, never a literal, which SwiftUI treats as a `LocalizedStringKey` and parses Markdown from. Do not feed remote text to `AttributedString(markdown:)` or a `WKWebView`. Release tags, titles, artists, file paths and error bodies are all data.
- **Opening links:** `NSWorkspace.shared.open(url)` only after `url.scheme == "https"` and a host allow-list (`*.tidal.com`, `exportify.net`, `github.com`). If TIDAL's verification URL comes without a scheme, add `https://` first (see the auth section).
- **Opening folders:** `NSWorkspace.shared.activateFileViewerSelecting([url])`, or `open(url)` only after confirming `isDirectory`. Never pass arbitrary paths.
- **Type-check IDs at the edge.** TIDAL track and album IDs are `Int`, playlist IDs are `UUID`, Spotify IDs match `[A-Za-z0-9]+`. Build request URLs with `URLComponents`, not string interpolation. Decode `queue.json` with `Codable` and `tidalId: Int?`, so a garbage value fails to decode instead of reaching a request path.
- **Keep the filename rule** (`tidal_lib.js:616-618`): replace any of `\ / : * ? " < > |` with `_`, collapse whitespace, trim. The extension is always appended, so a title of `..` cannot climb out of the folder. Also strip leading dots (no hidden files) and cap names at 255 UTF-8 bytes.
- **Paste import:** parse only when the import drop area or sheet is active, or show the parsed list for confirmation before any TIDAL search.
- **Logging:** `os.Logger` with `privacy: .private` for paths and IDs. Never log tokens or the client secrets.

**Secrets.**

- Store `{access_token, refresh_token, expires_at, userID, countryCode}` as one Keychain generic-password item (`kSecClassGenericPassword`, a fixed `kSecAttrService` such as `"robogears Downloader TIDAL"`, `kSecAttrAccount` = userID). Replace it on sign-in, so credentials never pile up. Delete it on sign-out.
- The four client credentials are app constants. They cannot be hidden in a binary, so keep them out of logs and out of the Keychain record.
- **Ad-hoc signing caveat (general macOS behaviour, unverified for this app):**
  - The data-protection keychain needs a keychain-access-group entitlement, which requires a Team ID, so an ad-hoc-signed app falls back to the legacy login keychain.
  - That keychain trusts the creating app by its code requirement, which for an ad-hoc signature is the code hash. After each update, macOS may ask the user to allow access again.
  - A Developer ID signature removes this. Without one, the alternative is a file in Application Support created with mode 0600 and written atomically (`Data.write(to:options: .atomic)`, then `FileManager.setAttributes([.posixPermissions: 0o600], …)`).

**Folders, sandbox and privacy prompts.** Today both folders are stored as plain path strings (`settings.json` `downloadFolder`, `libraryFolder`; written at `app.js:1520, 1534`).

- **If the Swift app is sandboxed:**
  - Entitlements:
    - `com.apple.security.app-sandbox`
    - `com.apple.security.network.client` (GitHub, TIDAL auth/API/CDN/`resources.tidal.com`, `open.spotify.com`)
    - `com.apple.security.files.user-selected.read-write` (download folder)
    - `com.apple.security.files.bookmarks.app-scope`
    - No `network.server`, because the extension bridge is dropped.
  - Bookmarks:
    - Store the downloads folder as `url.bookmarkData(options: [.withSecurityScope])`.
    - Store the library folder as `[.withSecurityScope, .securityScopeAllowOnlyReadAccess]`, which keeps the library read-only at the OS level as well as by policy.
    - Resolve them at launch with `URL(resolvingBookmarkData:options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)`. Recreate when `stale` is set.
    - Wrap every access in `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
  - Existing plain paths from the Electron `settings.json` cannot be turned into bookmarks without the user picking the folder again in `NSOpenPanel`. Ask once.
  - An FFmpeg helper must be signed with `com.apple.security.app-sandbox` + `com.apple.security.inherit`. Whether the child can use the parent's security-scoped folder access is **unverified (needs a run)**; passing open file handles, or remuxing in-process, avoids the question.
  - A sandboxed app cannot replace itself in `/Applications` or strip quarantine, so self-update would need Sparkle 2's sandbox-aware installer.
  - It also cannot read the Electron app's `~/Library/Application Support/robogears Downloader/` for migration without a user grant.
- **Sandboxed or not:** reading or writing in `~/Downloads`, `~/Desktop`, `~/Documents`, removable volumes and network volumes triggers TCC "Files and Folders" prompts (general macOS behaviour since 10.15). A folder the user just picked in `NSOpenPanel` counts as user intent. Ad-hoc identities can lose these grants on every update (see the updater section). A music library on an external or network drive (the docs mention `Z:\Dropbox\Music` on Windows) will hit the removable/network-volume prompt on the first scan.
- **Network:** App Transport Security blocks plain `http`. Today media URLs from TIDAL manifests may be `http` (`tidal_lib.js:197`). Whether TIDAL ever serves `http` is **unverified (needs a run)**. If it does, add a narrow ATS exception rather than a global one.
- **Hardened runtime** (`codesign -o runtime`) works with an ad-hoc signature. A Swift app needs no JIT or unsigned-memory exceptions.

| Electron today | Swift replacement |
|---|---|
| `contextIsolation` / preload / 25 IPC channels | Typed `async` methods on actors/services; no string channels |
| CSP meta tag + `escapeHtml` | SwiftUI `Text(verbatim:)`; no HTML rendering of remote data |
| `shell.openExternal` with `/^https?:\/\//` | `NSWorkspace.open` after an https scheme + host allow-list |
| `shell.openPath(p)` for any `p` | `activateFileViewerSelecting` on bookmarked directories only |
| `update:download(url)` from the page + no verification | Updater-owned URL; EdDSA/SHA-256 verify; bundle-ID/version check (or Sparkle 2) |
| Generated bash relauncher | `FileManager.replaceItemAt` or a helper with an argument array |
| `token.json` plain array, umask mode, non-atomic | One Keychain item (or a 0600 atomic file if Keychain prompts are unacceptable) |
| `settings.json` path strings | Security-scoped bookmark `Data` (plus a display path) |
| `ELECTRON_RUN_AS_NODE` children, default fuses | `Process` with argument arrays; no embedded interpreter |

### 12. Open questions for the owner

1. **Sandbox?**
   - (a) Not sandboxed, hardened runtime on, bookmarks stored anyway so the sandbox can be turned on later. **(Recommended)** This keeps FFmpeg as a plain child process and allows a self-installing updater.
   - (b) Sandboxed from day one, with the entitlements above and Sparkle 2.

   If no answer: (a).
2. **Where do TIDAL tokens live?**
   - (a) Keychain, accepting a possible "allow access" prompt after each ad-hoc-signed update. **(Recommended)**
   - (b) A 0600 file in Application Support.

   If no answer: (a).
3. **Updater verification?**
   - (a) Sparkle 2 with EdDSA. **(Recommended)**
   - (b) Hand-rolled GitHub updater plus a published SHA-256 or EdDSA signature.

   If no answer: (a).
4. **Developer ID ($99/yr)?** It would remove the Keychain and TCC re-prompts and allow notarization. This is a money decision for the owner. If no answer: stay ad hoc.
