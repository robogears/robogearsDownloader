## TIDAL authentication and credentials

Scope: `tidal_auth_node.js` (whole file, 178 lines), the credential half of `tidal_lib.js` (lines 10-15, 46-168, 286-296, 859-875), the auth wiring in `electron-main.js`, the auth bridge in `electron-preload.js`, and the sign-in UI in `renderer/app.js` / `renderer/index.html`. Code version v0.1.30. No secret values are reproduced anywhere in this section.

### Overview

The app signs in to TIDAL with the OAuth 2.0 **device-code flow** (RFC 8628): it asks TIDAL for a device code, shows the person a TIDAL link to open in a browser, then polls TIDAL every few seconds until the person has logged in and clicked Allow. On success it writes the resulting access token, refresh token, TIDAL user id and country code to a plain JSON file, `token.json`. Every later TIDAL API call reads that file, uses the stored access token while it is still within its lifetime, and refreshes it with the stored refresh token when it is not.

The same `authenticate()` function runs in two places: in-process inside the Electron main process (IPC `token:run-auth`, triggered by the **Sign in to TIDAL** / **Re-authenticate** button) and as a command-line tool (`node tidal_auth_node.js`, npm script `auth`). The app embeds two TIDAL OAuth client pairs as base64 literals: an **AUTH** pair used only to obtain tokens, and a **REQUEST** pair that is written into `token.json` and later used to refresh them.

There is no sign-out, no cancel, no validation of the stored token beyond "the file exists", and only the first entry of the token file is ever used. These gaps produce the two most serious defects in this area: **Re-authenticate does not actually replace the credential in use**, and a missing or empty `token.json` makes the Electron main process call `process.exit(1)`.

### Components

#### 1. Embedded client credentials — `tidal_auth_node.js:17-20`

- Four module-level constants: `AUTH_CLIENT_ID`, `AUTH_CLIENT_SECRET`, `REQUEST_CLIENT_ID`, `REQUEST_CLIENT_SECRET`.
- Each one is a base64 string literal decoded at module load with `Buffer.from(<literal>, 'base64').toString('latin1')`.
- The decoded strings are used byte-for-byte. Nothing trims, URL-decodes or validates them.
- Once decoded, the REQUEST secret contains a literal `%`-escape sequence. It is stored in `token.json` and fed into the Basic header exactly as decoded, never URL-decoded. A port must not "clean it up".
- Provenance (README.md:84, ONBOARDING.md:132): the values come from the upstream `sachinsenal0x64/hifi` / `binimum/hifi-api` projects. CLAUDE.md says they unlock LOSSLESS and HI_RES_LOSSLESS streaming.
- Roles:
  - AUTH pair: `client_id` in the device-authorization and poll bodies, and the HTTP Basic credentials on the poll.
  - REQUEST pair: written into every new `token.json` entry as `client_ID` / `client_secret`. `tidal_lib.refreshToken` then uses it for the refresh body `client_id` and the Basic header.

#### 2. Token file path — three copies of the same expression

| Location | Expression | When evaluated |
|---|---|---|
| `tidal_auth_node.js:15` | `process.env.TIDAL_TOKEN_PATH \|\| path.join(__dirname, 'token.json')` | Once, at first `require` |
| `tidal_lib.js:13` (exported as `TOKEN_FILE`, line 861) | same | Once, at first `require` |
| `electron-main.js:611` (inside `token:exists`) | same | On every call |

- `electron-main.js:13` calls `app.setName('robogears Downloader')`.
- `electron-main.js:19-21`: **only when `app.isPackaged`**, it sets `process.env.TIDAL_TOKEN_PATH = path.join(app.getPath('userData'), 'token.json')`. This happens before `require('./tidal_lib')` at line 23. `tidal_auth_node` is required lazily inside the `token:run-auth` handler (line 620), so it also sees the variable.
- Resulting paths:
  - Packaged on macOS: `~/Library/Application Support/robogears Downloader/token.json`.
  - Packaged on Windows: `%APPDATA%\robogears Downloader\token.json`.
  - Dev (`npm start`), with the variable unset: `<repo>/token.json`.
  - CLI (`npm run auth`): `<repo>/token.json`, unless the shell sets `TIDAL_TOKEN_PATH`. A CLI sign-in therefore does not sign in the packaged app.
- Child processes inherit the variable. `childEnv()` (`electron-main.js:60-71`) spreads `process.env` into the `bulk_runner.js` environment, and `bulk_runner.js:41-44` spreads it again into each `tidal_download.js` child.

#### 3. `httpsRequest` (auth module) — `tidal_auth_node.js:22-33`

- Wraps `https.request(options, cb)`. It concatenates response chunks into a string and resolves `{ status: res.statusCode, body }` on `end`.
- Writes the body if one is given, then ends the request.
- It rejects only on the request's `error` event. An HTTP error status never causes a rejection.
- **No timeout**, no retry, no redirect following. (The `tidal_lib` helper has a 30 s timeout. This one does not.)

#### 4. `formEncode` — `tidal_auth_node.js:35-37` (identical copy at `tidal_lib.js:123-127`)

- `Object.entries(obj).map(([k,v]) => encodeURIComponent(k) + '=' + encodeURIComponent(v)).join('&')`.
- Keys are emitted in insertion order.
- `encodeURIComponent` leaves only `A-Z a-z 0-9 - _ . ! ~ * ' ( )` unescaped. So `+` becomes `%2B`, `:` becomes `%3A`, a space becomes `%20` and `=` becomes `%3D`.

#### 5. `sleep(ms)` — `tidal_auth_node.js:39-41`

A promise wrapper around `setTimeout`.

#### 6. `loadTokens()` — `tidal_auth_node.js:43-51`

1. If `TOKEN_FILE` does not exist, return `[]`.
2. Otherwise `JSON.parse` the file (UTF-8). An array is returned as-is; any other value is wrapped as `[data]`.
3. Any read or parse error is swallowed and returns `[]`, so a corrupt file counts as empty.

#### 7. `saveToken(entry)` — `tidal_auth_node.js:53-59`

1. `tokens = loadTokens().filter(t => !(t.client_ID === entry.client_ID && t.refresh_token === entry.refresh_token))`. This drops only an entry with the same client id **and** the same refresh token.
2. `tokens.push(entry)` appends the new entry at the **end** of the array.
3. `fs.writeFileSync(TOKEN_FILE, JSON.stringify(tokens, null, 4))`.
   - The write overwrites the file in place: no temp file, no rename.
   - The file mode comes from the umask (Node's default 0o666, typically 0644 after the umask).
   - The parent directory is not created.
4. Write errors propagate out of `authenticate()`.

#### 8. `authenticate({ onLog = console.log, onVerificationUrl = null, suppressBrowser = false } = {})` — `tidal_auth_node.js:75-171`, exported at 173

**Setup.** Shared headers (lines 76-83):

| Header | Value |
|---|---|
| `User-Agent` | `okhttp/5.3.2` |
| `Accept` | `application/json` |
| `Accept-Encoding` | `identity` |
| `Accept-Language` | `en-US,en;q=0.9` |
| `X-Platform` | `android` |
| `Content-Type` | `application/x-www-form-urlencoded` |

**Step 1 — request a device code (lines 85-96).**

1. Body: `formEncode({ client_id: AUTH_CLIENT_ID, scope: 'r_usr+w_usr+w_sub' })`. On the wire that is `client_id=<AUTH id, percent-encoded>&scope=r_usr%2Bw_usr%2Bw_sub`.
2. Send `POST https://auth.tidal.com/v1/oauth2/device_authorization` with the shared headers plus `Content-Length` (byte length). There is **no Authorization header**.
3. If the status is not 200, throw `Device authorization failed: <status> <body>`.
4. `JSON.parse` the body (a non-JSON body throws `SyntaxError`). Destructure `{ verificationUriComplete, deviceCode, interval = 5 }`. Every other field is ignored: user code, plain verification URI, device-code lifetime.

**Step 2 — show the link (lines 101-121).**

1. If `onVerificationUrl` is set, call it with `verificationUriComplete`. This happens **before** any log line.
2. Log, in order: `=== TIDAL Login ===`, `Open this URL in your browser and log in:`, `` (empty), `  <verificationUriComplete>` (two leading spaces), `` (empty).
3. If `!suppressBrowser` (CLI only):
   - Spawn an opener with `{ detached: true, stdio: 'ignore' }` and call `.unref()`:
     - win32: `cmd /c start "" <url>` (the third argument is the two-character literal `""`).
     - darwin: `open <url>`.
     - Anything else: `xdg-open <url>`.
   - Then log `(Browser should have opened automatically)`.
   - The `try/catch` around it catches only synchronous throws.
4. Log `Waiting for authorization...`.

**Step 3 — poll for the token (lines 123-170).**

1. Poll body, built once: `formEncode({ client_id: AUTH_CLIENT_ID, device_code: deviceCode, grant_type: 'urn:ietf:params:oauth:grant-type:device_code', scope: 'r_usr+w_usr+w_sub' })`. On the wire: `client_id=<AUTH id>&device_code=<deviceCode>&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&scope=r_usr%2Bw_usr%2Bw_sub`.
2. Basic credential: `Buffer.from(AUTH_CLIENT_ID + ':' + AUTH_CLIENT_SECRET).toString('base64')`. The string is UTF-8-encoded before base64.
3. `while (true)`:
   1. `await sleep(interval * 1000)`. The wait comes **before** every poll, including the first.
   2. Send `POST https://auth.tidal.com/v1/oauth2/token` with the shared headers, `Authorization: Basic <credential>` and `Content-Length`.
   3. **200:** parse JSON and build the entry below. Then `saveToken(entry)`, log `` (empty), `Authorization successful! token.json saved.` and `User ID: <entry.userID>` (prints `undefined` if absent). Log `Country: <countryCode>` only if it is truthy. Return the entry.
      ```js
      { access_token:  tokenJson.access_token,
        refresh_token: tokenJson.refresh_token,
        userID:        tokenJson.user?.userId,
        countryCode:   tokenJson.user?.countryCode,
        expires_at:    Date.now() + (tokenJson.expires_in || 3600) * 1000 - 60000,
        client_ID:     REQUEST_CLIENT_ID,
        client_secret: REQUEST_CLIENT_SECRET }
      ```
   4. **400:** parse the JSON body. If `error === 'authorization_pending'`, keep polling. Any other error code (including `slow_down`) throws `Auth error: <JSON.stringify(body)>`.
   5. **Any other status:** throw `Unexpected poll response: <status> <body>`.
4. The interval never changes, and the code sets no deadline of its own. The loop ends only on 200 or a thrown error. It is bounded in practice only if TIDAL answers with a non-pending error once the device code expires (presumably `expired_token`; unverified, needs a run). A stalled TCP connection hangs it forever, because these requests have no timeout. There is no cancellation hook.

#### 9. CLI entry — `tidal_auth_node.js:175-178`, `package.json:8` (`"auth": "node tidal_auth_node.js"`)

- `if (require.main === module) authenticate().catch(e => { console.error(e); process.exit(1); })`.
- It uses the defaults: `console.log` logging, no URL callback, browser opener on.
- On failure it prints the whole Error object (with stack) and exits 1. On success the process exits 0 once nothing is pending.

#### 10. `loadCred()` — `tidal_lib.js:48-60` (exported)

1. If `TOKEN_FILE` does not exist: `console.error('token.json not found. Run tidal_auth_node.js first.')`, then `process.exit(1)`.
2. `JSON.parse(readFileSync(TOKEN_FILE,'utf8'))`. A non-array value is wrapped in an array. A corrupt file throws `SyntaxError`, which is not caught here.
3. If the array is empty: `console.error('No credentials in token.json. Run tidal_auth_node.js first.')`, then `process.exit(1)`.
4. Return `entries[0]`. Only the **first** entry is ever used, and each call returns a fresh object.

#### 11. `saveCred(cred)` — `tidal_lib.js:62-68` (exported)

1. Re-read and parse the file, wrapping it as an array.
2. `entries[0] = { ...entries[0], ...cred }`. A field set to `undefined` on `cred` overwrites the stored one and then disappears from the JSON.
3. `writeFileSync(TOKEN_FILE, JSON.stringify(entries, null, 4))`. Entries after index 0 are kept untouched.
4. The write is not atomic and takes no lock. It throws on a missing file (`ENOENT`), a corrupt file (`SyntaxError`) or an unwritable path.

#### 12. `refreshToken(cred)` — `tidal_lib.js:70-95` (exported)

1. Send `POST https://auth.tidal.com/v1/oauth2/token` through the `tidal_lib` `httpsRequest`, with a 30 000 ms timeout.
   - Body: `formEncode({ client_id: cred.client_ID, refresh_token: cred.refresh_token, grant_type: 'refresh_token', scope: 'r_usr+w_usr+w_sub' })`, i.e. `client_id=<..>&refresh_token=<..>&grant_type=refresh_token&scope=r_usr%2Bw_usr%2Bw_sub`.
   - `Authorization: Basic base64(cred.client_ID + ':' + cred.client_secret)`, built from whatever pair is stored in the file (normally the REQUEST pair).
2. If the status is not 200, throw `Token refresh failed: <status> <body>`. There is no retry, and nothing clears the token or prompts a new sign-in.
3. Parse JSON. Set `cred.access_token = json.access_token` and `cred.expires_at = Date.now() + (json.expires_in || 3600) * 1000 - 60000`.
4. If `json.user?.countryCode` is present and `cred.countryCode` is falsy, set `cred.countryCode`. An existing country code is never overwritten.
5. A `refresh_token` in the response is **ignored**, and `userID` is never updated.
6. `saveCred(cred)`, then return `cred.access_token`. The passed-in object is mutated, so later `getToken(cred)` calls in the same process use the cached value.

#### 13. `getToken(cred)` — `tidal_lib.js:97-102` (exported)

- Returns `cred.access_token` if `cred.access_token && cred.expires_at && Date.now() < cred.expires_at`. Otherwise it returns `refreshToken(cred)`.
- The stored `expires_at` already has 60 s subtracted.
- Concurrent callers each start their own refresh; nothing de-duplicates them.

#### 14. `getCountryCode(cred)` — `tidal_lib.js:104-119` (exported)

1. If `cred.countryCode` is truthy, return it.
2. `token = await getToken(cred)`. This runs outside the `try`, so refresh errors propagate.
3. Inside a `try`: `GET https://api.tidal.com/v1/users/<cred.userID>?countryCode=US`. On 200 with `json.countryCode`, set `cred.countryCode`, call `saveCred(cred)` and return it.
4. Any thrown error (network, parse, or `saveCred`) and any non-200 response falls through to `return 'US'`. The `'US'` fallback is **not** persisted, so the lookup repeats on every call.

#### 15. `httpsRequest` (lib) — `tidal_lib.js:129-154`, and `tidalGet` — `tidal_lib.js:156-168`

- Default headers: `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, then any `opts.headers`.
  - With a body it adds `Content-Type` (default `application/x-www-form-urlencoded`) and `Content-Length`.
  - With `auth: [user, pass]` it sets `Authorization: Basic base64(user:pass)`.
- Timeout: `opts.timeout || 30000` through `req.setTimeout`, which destroys the request with `Request timeout after <n>ms`. No retries.
- `tidalGet(path, token, params)`: builds the query as `key=encodeURIComponent(value)` (keys are not encoded) and GETs from `api.tidal.com` with a 30 s timeout. It adds `Authorization: Bearer <token>` and `X-Tidal-Platform: android`.
- 401 handling: no code anywhere refreshes and retries on a 401. Only `getPlaybackInfo` (`tidal_lib.js:293`) maps 401 to `Unauthorized — token may be invalid`. The other wrappers throw `<Thing> failed: <status> <body>`.

#### 16. IPC `token:exists` — `electron-main.js:610-613`; preload `tokenExists` (`electron-preload.js:26`)

- Returns `fs.existsSync(<token path>)`.
- It does not look at the contents: `[]`, corrupt JSON or a revoked token all count as signed in.

#### 17. IPC `token:run-auth` — `electron-main.js:614-642`; preload `runAuth`, `onAuthOutput`, `onAuthUrl` (`electron-preload.js:27-29`)

1. `const { authenticate } = require('./tidal_auth_node')`.
2. `send(line)`: if `mainWindow` exists and is not destroyed, send `webContents.send('auth:output', line + '\n')`.
3. `await authenticate({ onLog: send, onVerificationUrl, suppressBrowser: true })`. The `onVerificationUrl` callback:
   - calls `shell.openExternal(url)`, which is not awaited, not scheme-checked, and has no rejection handler;
   - then sends `webContents.send('auth:url', url)` if the window is alive.
4. On success it returns `{ ok: true }`. The returned entry is discarded.
5. On error it calls `send('ERROR: ' + e.message)` and returns `{ ok: false, error: e.message }`.
6. There is no in-flight guard (two invocations would run two independent flows), no cancel IPC and no timeout.

#### 18. Main-process token consumers — `electron-main.js`

Each handler below calls `lib.loadCred()` (a fresh disk read), `await lib.getToken(cred)`, then `await lib.getCountryCode(cred)` once at the start, and reuses that single token for the whole operation. Errors are caught and returned as `{ ok: false, error: e.message }`. The `process.exit(1)` inside `loadCred` cannot be caught.

| Handler | Lines | Notes |
|---|---|---|
| `resolve:input` | 658-687 | URL or search resolve. The renderer guards it with `tokenExists`. |
| `preview:get-audio` | 873-917 | Waveform preview. The renderer pre-loader runs up to 2 at once (`renderer/app.js:555-559, 739-749`), so two refreshes can race. **Not guarded.** |
| `resolve:tracklist` | 919-982 | CSV/text import. Per-track search errors (including a 401 from an expired token) are swallowed and the track is marked `notFound`. **Not guarded.** |
| `handleExtensionTracks` | 696-751 | Chrome extension (support ended; inventory only). Logs `⚠ Extension match failed: <msg>`. |

#### 19. Child-process and CLI token consumers

- `bulk_runner.js:56-58` calls `loadCred`, `getToken` and `getCountryCode` once, **before** the loop, even when every track already has a TIDAL id. The token is used only to search for tracks without one.
  - A refresh failure fails the whole batch with `Fatal: Token refresh failed: …` and exit 1 (`bulk_runner.js:115-118`).
  - Children run one at a time (`await runDownload`, line 105).
- `tidal_download.js:690` calls `loadCred` once per process. `downloadTrack` (346-348) and the album, playlist and Spotify wrappers (491-492, 527-528, 544-545, 587-588, 628-629) call `getToken` and `getCountryCode` at their start. A long album re-checks expiry per track and refreshes as needed; the mutated `cred` is shared within the process.
- `tidal_search.js:13-15` and `tidal_check_quality.js:13-15`: one `loadCred` / `getToken` / `getCountryCode` each.
- In a child or CLI, a missing or empty token file prints the `loadCred` message and exits 1. Inside the GUI that output reaches the activity log, followed by `=== Exit code 1 ===` (`renderer/app.js:1463`).

#### 20. Renderer auth status — `renderer/app.js:1703-1714`

`refreshAuthStatus()` calls `api.tokenExists()`. It runs at boot (`1950`) and whenever Settings opens (`1506`).

| `tokenExists` | `#auth-status` text | `#auth-status` class | `#auth-btn` label |
|---|---|---|---|
| true | `✓ Signed in` | `auth-status ok` | `Re-authenticate` |
| false | `Not signed in` | `auth-status bad` | `Sign in to TIDAL` |

#### 21. Sign-in button and auth modal — `renderer/app.js:1716-1753`; markup `renderer/index.html:152-160` (TIDAL tab), `205-220` (`#auth-modal`)

1. Clicking `#auth-btn`:
   - clears `#auth-output` and `#auth-url-input`;
   - hides `#auth-url-row` and resets the `#auth-url-copy` label to `Copy`;
   - calls `openModal('auth-modal')`, which sets `hidden = false`. Both modals use z-index 50, and the auth modal comes later in the DOM, so it covers Settings;
   - then `await api.runAuth()`.
2. `r.ok`: `await refreshAuthStatus()`, then `setTimeout(() => closeModal('auth-modal'), 1200)`.
3. Otherwise: append `\n\n✗ Sign-in failed.` to `#auth-output`. The modal **stays open**. It has no `[data-close]` element, there is no Escape-key handler and there is no backdrop-click handler (`renderer/app.js:322-326`). The only way out is to quit the app.
4. `onAuthOutput`: append the line (it already ends in `\n`) to `#auth-output` and scroll to the bottom.
5. `onAuthUrl`: set `#auth-url-input.value = url` and show `#auth-url-row`.
6. Copy button: does nothing if the field is empty. Otherwise it tries `navigator.clipboard.writeText`, falling back to `select()` + `document.execCommand('copy')` + `blur()`. The label becomes `Copied ✓`, then `Copy` again after 1500 ms.
7. Static copy:
   - TIDAL tab label: `TIDAL account`.
   - TIDAL tab hint: `Required once per device. Opens a browser tab where you log in to TIDAL and click Allow.` (*Allow* is italic).
   - Modal title: `Signing in to TIDAL`.
   - Modal hint: `A browser tab should open automatically. Log in and click Allow.`
   - Reset hint (`index.html:148`): `Forgets your download and library folder choices. TIDAL sign-in is kept.`

#### 22. Sign-in guards in the renderer

`api.tokenExists()` is called in exactly four places: 1290, 1426, 1704 and 1960.

| Action | Guarded? | What happens without a token |
|---|---|---|
| Add to queue / Enter (`handleInput`, 1287-1293) | Yes | Logs `⚠ Sign in to TIDAL first (Settings → Sign in).` and returns |
| Download all (1419-1430) | Yes | Plays `playWarningHonk()`, logs the same line |
| Boot welcome (1960-1961) | — | Logs `👋 Welcome! Click the ⚙ icon to sign in to TIDAL.` |
| Tracklist drop, file pick or paste (`handleTracklistInput`, 1830-1858; callers 1778, 1789, 1807) | **No** | Main process `resolve:tracklist`, then `loadCred`, then `process.exit(1)` |
| Preview play/scrub (1063-1068, 1163) and background pre-loader (`enqueuePreload` 730-737; called at 1267 and at boot 1984-1986) | **No** | Main process `preview:get-audio`, then `process.exit(1)` |
| Retry all / per-row retry (1397-1417, ~1112) | **No** | `bulk_runner` child exits 1 (log line + `=== Exit code 1 ===`) |

#### 23. Secret exclusion

- `.gitignore:2` ignores `token.json`.
- `package.json:55` (`"!**/{*.log,*.tmp,token.json}"` in `build.files`) keeps it out of the packaged app.

#### Inventory only (not ported)

- `extension-server.js:3-4, 20-66` and `electron-main.js:28, 805-812`: a separate localhost bearer token for the Chrome extension bridge, stored at `<userData>/extension-token.txt` (32 hex characters from `crypto.randomBytes(16)`). It is not a TIDAL credential, and the Swift port drops the extension.

### Data formats

#### `token.json`

```jsonc
[                       // JSON array, pretty-printed with 4-space indent, UTF-8
  {
    "access_token":  "<string>",
    "refresh_token": "<string>",
    "userID":        12345,          // number, from token response user.userId
    "countryCode":   "US",           // from token response user.countryCode
    "expires_at":    1234567890000,  // ms since Unix epoch, ALREADY minus 60 000
    "client_ID":     "<REQUEST client id>",
    "client_secret": "<REQUEST client secret>"
  }
  // re-auth appends further entries here; only index 0 is ever used
]
```

- Key order as first written: `access_token, refresh_token, userID, countryCode, expires_at, client_ID, client_secret`.
- Keys whose value is `undefined` are omitted. For example, `userID` and `countryCode` are missing if the token response had no `user`.
- Readers also accept a bare object (legacy) and wrap it; the next save rewrites it as an array.
- The file is plain text with umask-default permissions, and every write is a non-atomic in-place overwrite.

#### Requests

| Call | Method + URL | Body (`application/x-www-form-urlencoded`, exact key order) | Auth |
|---|---|---|---|
| Device authorization | `POST https://auth.tidal.com/v1/oauth2/device_authorization` | `client_id=<AUTH id>&scope=r_usr%2Bw_usr%2Bw_sub` | none |
| Device-code poll | `POST https://auth.tidal.com/v1/oauth2/token` | `client_id=<AUTH id>&device_code=<deviceCode>&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&scope=r_usr%2Bw_usr%2Bw_sub` | `Basic base64("<AUTH id>:<AUTH secret>")` |
| Refresh | `POST https://auth.tidal.com/v1/oauth2/token` | `client_id=<stored client_ID>&refresh_token=<stored refresh_token>&grant_type=refresh_token&scope=r_usr%2Bw_usr%2Bw_sub` | `Basic base64("<stored client_ID>:<stored client_secret>")` |
| Country lookup | `GET https://api.tidal.com/v1/users/<userID>?countryCode=US` | — | `Bearer <access_token>` |
| Any API call | `GET https://api.tidal.com/<path>?<params>` | — | `Bearer <access_token>` |

Headers per call:

| Header | Device auth | Poll | Refresh | api.tidal.com |
|---|---|---|---|---|
| `User-Agent: okhttp/5.3.2` | yes | yes | yes | yes |
| `Accept: application/json` | yes | yes | yes | yes |
| `Accept-Encoding: identity` | yes | yes | yes | yes |
| `Accept-Language: en-US,en;q=0.9` | yes | yes | **no** | no |
| `X-Platform: android` | yes | yes | **no** | no |
| `X-Tidal-Platform: android` | no | no | no | yes |
| `Content-Type: application/x-www-form-urlencoded` | yes | yes | yes | no |
| `Content-Length` | yes | yes | yes | no |
| Request timeout | **none** | **none** | 30 s | 30 s |

#### Responses consumed

- Device authorization 200: `{ verificationUriComplete: string, deviceCode: string, interval?: number /* seconds, default 5 */ }`. Everything else is ignored. Whether `verificationUriComplete` includes the `https://` scheme is unverified (needs a run); ONBOARDING.md describes it as a `link.tidal.com/...` URL.
- Poll 200: `{ access_token, refresh_token, expires_in?: seconds /* default 3600 */, user?: { userId, countryCode } }`.
- Poll 400: `{ error: 'authorization_pending' | <anything else>, ... }`. Only `authorization_pending` continues.
- Refresh 200: fields read are `access_token`, `expires_in` (default 3600) and `user.countryCode` (used only if none is stored).
- User 200: field read is `countryCode`.

#### IPC payloads

| Channel | Direction | Payload |
|---|---|---|
| `token:exists` | invoke | → `boolean` |
| `token:run-auth` | invoke | → `{ ok: true }` or `{ ok: false, error: string }` |
| `auth:output` | main → renderer | `string`: one log line plus `\n` (blank log lines arrive as `\n`) |
| `auth:url` | main → renderer | `string`: `verificationUriComplete`, sent before the first `auth:output` line |

### External interfaces

| Interface | Kind | Where | Detail |
|---|---|---|---|
| TIDAL device authorization | HTTPS POST | `tidal_auth_node.js:87-92` | Expects 200 JSON |
| TIDAL token endpoint, device-code grant | HTTPS POST | `tidal_auth_node.js:135-144` | Polled every `interval` s; Basic auth with the AUTH pair |
| TIDAL token endpoint, refresh grant | HTTPS POST | `tidal_lib.js:71-81` | Basic auth with the stored pair; 30 s timeout; no retry |
| TIDAL user profile | HTTPS GET | `tidal_lib.js:108` | Country discovery only |
| Bearer use on `api.tidal.com` | header contract | `tidal_lib.js:156-168` | Every API call |
| Default browser | OS | `electron-main.js:630` (GUI, `shell.openExternal`); `tidal_auth_node.js:109-119` (CLI opener) | Opens `verificationUriComplete` |
| `TIDAL_TOKEN_PATH` | env var | `electron-main.js:19-21, 611`; `tidal_lib.js:13`; `tidal_auth_node.js:15` | Overrides the token file location; set only when packaged |
| IPC | Electron | `electron-main.js:610, 614, 623, 632`; `electron-preload.js:26-29` | `token:exists`, `token:run-auth`, `auth:output`, `auth:url` |
| npm script | CLI | `package.json:8` | `npm run auth` |
| Clipboard | browser API | `renderer/app.js:1741-1753` | Copies the verification URL |
| Filesystem | file | the `token.json` path | Read on every operation; written on sign-in, refresh and country discovery |

### Constants and magic values

| Name | Value | Location | Meaning |
|---|---|---|---|
| `AUTH_CLIENT_ID`, `AUTH_CLIENT_SECRET` | withheld; base64 literals decoded as latin1 | `tidal_auth_node.js:17-18` | Client for device authorization and polling |
| `REQUEST_CLIENT_ID`, `REQUEST_CLIENT_SECRET` | withheld; base64 literals decoded as latin1 (the secret contains a literal `%`-escape) | `tidal_auth_node.js:19-20` | Stored in `token.json`; used for refresh |
| Scope | `r_usr+w_usr+w_sub` (sent as `r_usr%2Bw_usr%2Bw_sub`) | `tidal_auth_node.js:86, 128`; `tidal_lib.js:80` | Same string on all three token calls |
| Device grant | `urn:ietf:params:oauth:grant-type:device_code` | `tidal_auth_node.js:127` | RFC 8628 |
| Refresh grant | `refresh_token` | `tidal_lib.js:79` | |
| Auth host and paths | `auth.tidal.com`, `/v1/oauth2/device_authorization`, `/v1/oauth2/token` | `tidal_auth_node.js:88-89, 136-137`; `tidal_lib.js:72-73` | |
| API host and user path | `api.tidal.com`, `/v1/users/{userID}` with `countryCode=US` | `tidal_lib.js:108, 159` | |
| User-Agent | `okhttp/5.3.2` | `tidal_auth_node.js:77`; `tidal_lib.js:14` | Imitates the Android client |
| Platform headers | `X-Platform: android` (auth flow); `X-Tidal-Platform: android` (API) | `tidal_auth_node.js:81`; `tidal_lib.js:165` | Different header names |
| Accept-Language | `en-US,en;q=0.9` | `tidal_auth_node.js:80` | Device flow only |
| Accept-Encoding | `identity` | `tidal_auth_node.js:79`; `tidal_lib.js:134` | No compression |
| Poll interval default | 5 s | `tidal_auth_node.js:99, 134` | Sleep comes before each poll |
| `expires_in` default | 3600 s | `tidal_auth_node.js:153`; `tidal_lib.js:88` | |
| Expiry safety margin | 60 000 ms | `tidal_auth_node.js:153`; `tidal_lib.js:88` | Subtracted when storing `expires_at` |
| `DEFAULT_TIMEOUT` | 30 000 ms | `tidal_lib.js:15, 75, 148, 162` | Refresh and API only |
| Country fallback | `US` | `tidal_lib.js:108, 118` | |
| JSON indent | 4 spaces | `tidal_auth_node.js:58`; `tidal_lib.js:67` | |
| Token file name | `token.json` | `tidal_auth_node.js:15`; `tidal_lib.js:13`; `electron-main.js:20, 611` | |
| App name / userData folder | `robogears Downloader` | `electron-main.js:13` | |
| Modal auto-close | 1200 ms | `renderer/app.js:1725` | After success |
| Copy label revert | 1500 ms | `renderer/app.js:1752` | |
| Preview pre-loader concurrency | 2 | `renderer/app.js:558` | Parallel `preview:get-audio` calls, each able to refresh |
| DOM ids | `#auth-btn`, `#auth-status`, `#auth-output`, `#auth-modal`, `#auth-url-row`, `#auth-url-input`, `#auth-url-copy`, `#settings-modal` | `renderer/index.html:155-157, 206-217`; `renderer/app.js:26-33` | |

User-visible strings (exact):

- From `tidal_auth_node.js`:
  - `=== TIDAL Login ===`
  - `Open this URL in your browser and log in:`
  - `(Browser should have opened automatically)`
  - `Waiting for authorization...`
  - `Authorization successful! token.json saved.`
  - `User ID: <id>`
  - `Country: <cc>`
  - `Device authorization failed: <status> <body>`
  - `Auth error: <json>`
  - `Unexpected poll response: <status> <body>`
- From `electron-main.js:639`: `ERROR: <message>`.
- From `tidal_lib.js:50, 56, 84, 293`:
  - `token.json not found. Run tidal_auth_node.js first.`
  - `No credentials in token.json. Run tidal_auth_node.js first.`
  - `Token refresh failed: <status> <body>`
  - `Unauthorized — token may be invalid`
- From `renderer/app.js`:
  - `✓ Signed in`
  - `Not signed in`
  - `Re-authenticate`
  - `Sign in to TIDAL`
  - `✗ Sign-in failed.`
  - `Copy`
  - `Copied ✓`
  - `⚠ Sign in to TIDAL first (Settings → Sign in).`
  - `👋 Welcome! Click the ⚙ icon to sign in to TIDAL.`

### Rules and invariants

- Tokens are always obtained with the AUTH client pair. The entry saved to `token.json` always carries the REQUEST pair, and every refresh uses whatever `client_ID` / `client_secret` is stored (`tidal_auth_node.js:131, 154-155`; `tidal_lib.js:77, 81`).
- Only `entries[0]` of `token.json` is used for API access, refresh and country persistence (`tidal_lib.js:59, 66`).
- `expires_at` is wall-clock milliseconds since the epoch with a 60 s margin already subtracted. A token counts as valid while `Date.now() < expires_at`.
- Once stored, `countryCode` is never overwritten. The stored `refresh_token` and `userID` never change after sign-in.
- The packaged app stores the token in userData. Dev and CLI store it next to the source unless `TIDAL_TOKEN_PATH` is set.
- Children must see the same file. `TIDAL_TOKEN_PATH` travels through `process.env` into `bulk_runner` and `tidal_download`.
- In the UI, "Signed in" means only that the token file exists.
- **Reset config** never touches the token (`electron-main.js:558-565`). There is no sign-out anywhere.
- `token.json` is never committed or packaged.
- The in-process flow never spawns its own browser opener (`suppressBrowser: true`). Electron's `shell.openExternal` is used instead.
- Polling waits first and then polls, at a fixed interval.
- Form bodies use `encodeURIComponent` semantics for keys and values. The `+` characters in the scope travel as `%2B`.

### Edge cases and failure modes

- **`token.json` missing.**
  - In a child or CLI: the `loadCred` message, then exit 1.
  - In the Electron main process (`resolve:input`, `resolve:tracklist`, `preview:get-audio`, extension handler): `process.exit(1)` terminates the app. That the whole app quits immediately is unverified (needs a run).
- **`token.json` is `[]`.** The same exit path (`No credentials in token.json…`), while `token:exists` reports signed in. This also bypasses the two renderer guards.
- **`token.json` is corrupt or empty bytes.** `loadCred` throws `SyntaxError`; IPC handlers return `{ ok:false, error:'Unexpected end of JSON input' }` or similar, and `token:exists` still says signed in. Signing in again recovers, because `loadTokens` treats the file as `[]` and rewrites it as `[newEntry]`.
- **`token.json` is a bare object.** Both readers wrap it; the next save writes an array.
- **`token.json` holds JSON `null`.** It becomes `[null]`. `saveToken`'s filter and `getToken` then hit a `TypeError` on `null`, so both sign-in and API calls fail until the file is deleted.
- **Legacy entry without `client_ID` / `client_secret`.** Refresh sends `client_id=undefined` and a Basic header built from `undefined:undefined`.
- **Re-authenticate with an existing entry.** The new entry is appended and index 0 stays active (see Bugs).
- **Token response without `user`.**
  - `userID` and `countryCode` are omitted, and the auth log prints `User ID: undefined`.
  - `getCountryCode` then calls `/v1/users/undefined` on every operation and returns `US` without saving it.
- **Missing `expires_in`.** 3600 s is assumed.
- **Refresh response without `access_token`.** The key disappears from the file and calls go out with `Bearer undefined`; the next call refreshes again.
- **Refresh rejected** (for example a revoked refresh token). `Token refresh failed: <status> <body>` becomes the error of whatever operation was running. In a batch it is fatal before any track starts. Nothing prompts the person to sign in again, and Re-authenticate does not help (see Bugs).
- **Access token revoked before `expires_at`.** Calls fail until local expiry, because nothing refreshes on a 401.
- **Token expires during a long resolve.**
  - `resolve:tracklist` and the extension import fetch one token at the start. The margin is only 60 s, so a resolve that starts near expiry outlives its token.
  - Later searches then fail and those tracks are silently marked `notFound` (`electron-main.js:941-974`).
- **Parallel refreshes.**
  - Two pre-loader fetches, or main plus `bulk_runner` plus `tidal_download`, each POST their own refresh and rewrite the file; the last writer wins.
  - Within the main process, writes are synchronous, so nothing there reads a half-written file.
  - Across processes, a reader can catch the file mid-write and fail with `SyntaxError`.
- **File deleted between `loadCred` and `saveCred`.**
  - `refreshToken` succeeds on the network, then throws `ENOENT`, so the operation fails.
  - `getCountryCode` swallows the same error and returns `US` even though it just fetched the real code.
- **Device code expires before approval.**
  - The code assumes TIDAL then answers 400 with a non-pending error; `Auth error: {...}` follows.
  - The modal shows `✗ Sign-in failed.` and cannot be dismissed.
- **`slow_down`.** Fatal (throws).
- **Network stall during the device flow.** No timeout: the promise and the modal hang until the app quits.
- **Device-authorization response missing `verificationUriComplete` or `deviceCode`.**
  - `shell.openExternal(undefined)` is called first. Whether it throws synchronously, which would abort with `{ok:false}` before any log line, is unverified (needs a run).
  - If it does not throw, polling sends `device_code=undefined`.
- **Schemeless `verificationUriComplete`.**
  - `shell.openExternal` would most likely reject (unhandled), and the browser does not open.
  - The CLI's macOS `open` would treat the value as a file path.
  - Both are unverified (needs a run). The URL is still shown with a Copy button.
- **Main window closed during sign-in (macOS keeps the app running, `electron-main.js:548-551`).**
  - `send()` skips the destroyed window, but polling continues and the token is still saved.
  - A window re-created through `activate` shows a stale `Not signed in` until Settings is opened.
- **Two sign-ins at once.** Not reachable from the UI (the modal covers the button). A second `token:run-auth` invoke would run a second device flow, and both would append entries.
- **CLI on Linux without `xdg-open`.** The asynchronous spawn `error` event has no listener, so the CLI crashes with an uncaught exception. It still prints `(Browser should have opened automatically)` first.
- **Clock changes.** Expiry uses `Date.now()`. A clock set backwards keeps a dead token "valid"; a clock set forwards forces early refreshes.
- **Dev and packaged builds side by side.** They read different token files (`<repo>/token.json` vs `<userData>/token.json`) but share `settings.json` and `queue.json` in userData.

### Bugs and oddities

1. **Re-authenticate does not replace the active credential.** Severity: **high**.
   - Evidence: `tidal_auth_node.js:53-59` removes only an entry with the same `client_ID` **and** the same `refresh_token`, then `push()`es the new one to the end. `client_ID` is always the REQUEST id, and a new sign-in almost certainly yields a new refresh token (unverified, needs a run). `tidal_lib.js:59` (`loadCred` returns `entries[0]`) and `:66` (`saveCred` merges into `entries[0]`) keep using the old entry.
   - Effect: after a successful Re-authenticate the app keeps the old token. A revoked refresh token or a change of TIDAL account cannot be fixed from the UI; the only fix is deleting `token.json` by hand. The file grows by one entry per sign-in, and the success log prints the new user id, which misleads.

2. **`process.exit(1)` inside the Electron main process.** Severity: **high**.
   - Evidence: `tidal_lib.js:49-58` (written for command-line use) is reached in main from `electron-main.js:661, 702, 875, 925`.
   - The renderer guards only Add-to-queue and Download all, and only against a missing file, not against `[]`.
   - Unguarded paths: tracklist drop, pick or paste (`renderer/app.js:1830-1843` → `resolve:tracklist`); preview play and scrub; and the background pre-loader, which runs **at boot** for every restored queue row with a TIDAL id (`renderer/app.js:1984-1986` → `preview:get-audio`).
   - Effect:
     - Pasting a tracklist before signing in quits the app.
     - Worse, if `queue.json` holds tracks while `token.json` is missing or `[]`, the app quits a moment after **every** launch, before the person can sign in. Ways to get there: deleting the token file (the only "sign-out" there is), or running dev and packaged builds, which share `queue.json` but not `token.json`.
   - The `console.error` text goes to the main process's stdout, which the person never sees.
   - The exact shutdown behaviour (whether quit handlers run) is unverified (needs a run).

3. **The auth modal cannot be dismissed; there is no cancel and no timeout.** Severity: **medium**.
   - Evidence: `renderer/index.html:205-220` has no `[data-close]` control, and `renderer/app.js:322-326, 1716-1729` add no Escape or backdrop handler. The modal closes only 1200 ms after success. `tidal_auth_node.js:22-33` sets no request timeout, the loop at `133-170` has no deadline of its own and ignores the device-code lifetime, and `electron-main.js:614-642` offers no cancel IPC.
   - Effect: after any failure, or a stalled connection, the person must quit the app.

4. **`slow_down` and every other non-pending error are fatal; the device-code lifetime is ignored.** Severity: low.
   - Evidence: `tidal_auth_node.js:99, 163-166`.
   - RFC 8628 says `slow_down` should add 5 s to the interval and keep polling. Here it ends the sign-in with `Auth error: …`.

5. **A rotated refresh token is discarded.** Severity: low.
   - Evidence: `tidal_lib.js:86-93` writes only `access_token`, `expires_at` and, if absent, `countryCode`.
   - Effect: if TIDAL ever rotates refresh tokens (unverified), the stored one goes stale and every refresh fails until the person signs in again, which bug 1 blocks.

6. **Refreshes are not synchronised and token writes are not atomic.** Severity: low.
   - Evidence: `tidal_lib.js:62-68, 97-102`; `tidal_auth_node.js:58`; the concurrency-2 pre-loader at `renderer/app.js:555-559`; separate `loadCred` calls in `bulk_runner` and `tidal_download`.
   - Effect: duplicate refresh requests, last writer wins, and across processes an occasional `SyntaxError` from reading a half-written file.

7. **Long resolves reuse one token, so expiry shows up as silent "not found".** Severity: low.
   - Evidence: `electron-main.js:924-976` (and 701-744 for the extension).
   - The token is fetched once. The per-track `catch` turns an auth failure into `notFound` and reports no auth error.

8. **Nothing refreshes and retries on a 401.** Severity: low.
   - Evidence: `tidal_lib.js:156-168`. Only `getPlaybackInfo` (line 293) gives a 401 its own message.

9. **`token:exists` reports "Signed in" for any existing file.** Severity: low.
   - Evidence: `electron-main.js:610-613`; `renderer/app.js:1703-1714`.
   - `[]`, corrupt JSON and revoked tokens all show `✓ Signed in`.

10. **The verification URL is opened unchecked and unawaited.** Severity: low.
    - Evidence: `electron-main.js:629-631` passes TIDAL's value straight to `shell.openExternal` without awaiting it. The generic `shell:open-external` IPC (`electron-main.js:186-188`) does enforce `/^https?:\/\//`.
    - A rejection, for example from a schemeless URL, goes unhandled; what that does in Electron main is unverified.

11. **Secrets are stored as plain text with default permissions.** Severity: low.
    - Evidence: `tidal_auth_node.js:58`; `tidal_lib.js:67`.
    - The access token, refresh token and REQUEST client secret are written with umask-default mode (typically 0644). There is no chmod and no Keychain.

12. **The CLI browser opener's asynchronous spawn error is unhandled.** Severity: low (CLI only).
    - Evidence: `tidal_auth_node.js:110-118`. The `try/catch` cannot catch the `error` event emitted when the opener binary is missing.

13. **`getCountryCode` can return `US` after finding the real code, and repeats a doomed lookup.** Severity: low.
    - Evidence: `tidal_lib.js:107-118`. `saveCred` sits inside the `try`, so its failure is swallowed and `US` is returned. When `userID` is missing, `/v1/users/undefined` is queried on every call.

14. **No in-flight guard on `token:run-auth`.** Severity: info (latent).
    - Evidence: `electron-main.js:614-642`. Not reachable from the UI today.

15. **The CLI sign-in writes a different file from the packaged app.** Severity: info.
    - Evidence: `tidal_auth_node.js:15` and `electron-main.js:19-21`. Without `TIDAL_TOKEN_PATH`, `npm run auth` writes `<repo>/token.json`, which the packaged app never reads.

16. **Tokens are issued to one client and refreshed with another.** Severity: info.
    - Evidence: `tidal_auth_node.js:86-131` vs `154-155`; `tidal_lib.js:77-81`.
    - It reportedly works; a port must reproduce it exactly. Whether TIDAL validates the REQUEST secret at all is unknown.

17. **The REQUEST secret contains a literal `%`-escape.** Severity: info.
    - Evidence: `tidal_auth_node.js:20`. It is used verbatim in the Basic header and stored verbatim. Do not URL-decode it.

18. **The scope travels as one plus-joined token.** Severity: info.
    - Evidence: `tidal_auth_node.js:86, 128`; `tidal_lib.js:80`.
    - `r_usr+w_usr+w_sub` is sent as `r_usr%2Bw_usr%2Bw_sub`, not as space-separated scopes. A default form encoder (which leaves `+` alone or turns spaces into `+`) would change what TIDAL receives.

19. **Request headers differ between the auth calls.** Severity: info.
    - Evidence: `tidal_auth_node.js:76-83`; `tidal_lib.js:131-141, 163-166`. See the header table.

20. **The token-path expression is written out three times.** Severity: info.
    - Evidence: `tidal_auth_node.js:15`; `tidal_lib.js:13`; `electron-main.js:611`. `lib.TOKEN_FILE` is exported (`tidal_lib.js:861`) but not reused.

21. **CLAUDE.md's file tree is stale about the dev token location.** Severity: info.
    - It says `token.json` lives in userData in both dev and packaged builds. The code sets the variable only when `app.isPackaged`, as CLAUDE.md's later "token.json path" section correctly says.

22. **Logs echo raw TIDAL error bodies.** Severity: info.
    - Evidence: `tidal_auth_node.js:95, 166, 168`; `tidal_lib.js:84`.
    - These are error JSON, not tokens. No code logs `access_token` or `refresh_token`.
    - What is logged: the verification URL (with its short-lived user code), the user id and the country.

### Platform-specific behaviour

- Token location:
  - Packaged macOS: `~/Library/Application Support/robogears Downloader/token.json`.
  - Packaged Windows: `%APPDATA%\robogears Downloader\token.json`.
  - Dev and CLI: `<repo>/token.json`.
- CLI browser opener: win32 `cmd /c start "" <url>` (how Node quotes the `""` argument on Windows is unverified); darwin `open <url>`; others `xdg-open <url>`. The GUI uses `shell.openExternal` on every platform.
- macOS keeps the app running when its window closes, so a sign-in in progress continues without a window.
- The credentials are decoded as latin1, and the Basic header re-encodes `id:secret` as UTF-8. The result is identical as long as the decoded bytes are ASCII, which is likely but was not checked, because the values were deliberately not decoded.
- Children run through `process.execPath` with `ELECTRON_RUN_AS_NODE=1` and inherit `TIDAL_TOKEN_PATH`.

### Porting notes for a native Swift macOS app

| Topic | Today | Swift needs | Difficulty |
|---|---|---|---|
| Requests | Node `https.request` with hand-built headers; the device flow has no timeout | `URLSession` requests carrying the exact header set for each call type (table above). Set `Accept-Encoding: identity` explicitly if byte-for-byte parity matters (URLSession adds gzip and decompresses on its own). Give every auth request a timeout. URLSession follows redirects; Node here did not. | easy |
| Form encoding | `encodeURIComponent` on keys and values | A custom percent-encoder whose allowed set is exactly `A-Z a-z 0-9 - _ . ! ~ * ' ( )`. `URLComponents.queryItems` would leave `+`, `:` and `=` unescaped and change what TIDAL receives. | easy |
| Embedded credentials | Four base64 literals decoded as latin1 | `Data(base64Encoded:)` then `String(data:, encoding: .isoLatin1)`, used verbatim. Keep both pairs distinct: AUTH for the device flow, REQUEST stored and used for refresh. Never URL-decode the REQUEST secret. A compiled binary is no harder to extract from than the JS; base64 is obfuscation, not protection. | easy |
| Basic header | `'Basic ' + base64(utf8('id:secret'))` | `"Basic " + Data("\(id):\(secret)".utf8).base64EncodedString()` | easy |
| Device-code loop | `while(true)`: sleep, then poll; 200 saves; 400 `authorization_pending` continues; anything else fails | A `Task` with `Task.sleep`, cancellable from a Cancel button. Parity requires that order and branching. Handling `slow_down` (+5 s) and a deadline from the response's device-code lifetime are improvements for the owner to accept or not. | easy |
| Verification URL | `shell.openExternal(value)`, unchecked | `NSWorkspace.shared.open(url)`. If the value has no scheme, prepend `https://` (whether TIDAL includes one is unverified). Always show the URL with a Copy button (`NSPasteboard`) as a fallback, and report a failure to open. | easy |
| Credential store | Plain JSON array, `entries[0]` active, non-atomic writes, umask permissions | One credential record, kept in the Keychain or in a file written atomically (`Data.write(options: .atomic)`) with 0600 permissions; the choice is the owner's. The field names to read for migration are `access_token`, `refresh_token`, `userID`, `countryCode`, `expires_at` (ms), `client_ID`, `client_secret`. | medium |
| Migration from the Electron app | `~/Library/Application Support/robogears Downloader/token.json` | Accept a bare object or an array. Choosing an entry needs an owner decision: `entries[0]` is the one the current app uses and keeps refreshed; the **last** entry is the newest sign-in. A sandboxed Swift app cannot read this path without a user-granted file access. | medium |
| Concurrency | Each IPC call or process loads its own copy and refreshes on its own | A single in-process token manager (an `actor`) that caches the credential and shares one in-flight refresh `Task` among search, preview and download. The env-var hand-off disappears because there are no child processes. | medium |
| Expiry policy | `expires_at = now + expires_in*1000 - 60000` (default 3600 s); refresh when `now >= expires_at`; never overwrite `countryCode`; ignore a rotated `refresh_token`; no retry on 401 | Same 60 s margin. Keeping or fixing the last two quirks is an owner decision; saving a rotated refresh token and doing one refresh-and-retry on a 401 are cheap. | easy |
| Country | `user.countryCode` from the token response, else `GET /v1/users/{id}?countryCode=US`, else `US` | Same chain, but persist the result once it is found. | easy |
| Not signed in | `process.exit(1)` | A typed "not signed in" error that the UI turns into a sign-in prompt. Never terminate the app. Gate every TIDAL action (import, preview, retry, pre-load) on a real credential check, not just "a file exists". | easy |
| UI | Modal with a `<pre>` log, a read-only URL field and Copy; no close control | A sheet with status text, the URL, Copy, **Cancel**, and Close after a failure. Signed-in state comes from a successfully loaded credential, not from a file existing. Re-authenticate must replace the stored credential. | easy |
| Sign-out | None | Optional; an owner decision. Today the only sign-out is deleting the file. | easy |
| CLI sign-in | `npm run auth` | Not needed for the GUI. A command-line target is optional. | easy |

### Open questions

1. Does `verificationUriComplete` include the `https://` scheme? (Unverified, needs a run. ONBOARDING.md calls it a `link.tidal.com/...` URL.) If it does not, today's automatic browser open may silently fail and people rely on the Copy button.
2. Does TIDAL return a new refresh token on every sign-in, and does it rotate refresh tokens on refresh? This decides how often bugs 1 and 5 bite. (Unverified.)
3. Does TIDAL actually check the REQUEST client secret on refresh, and will it keep accepting tokens issued to the AUTH client when they are refreshed with the REQUEST client? (Documented as working; unverified here.)
4. Which HTTP status and `error` codes does TIDAL return for `slow_down`, `expired_token` and `access_denied`? The code assumes HTTP 400 with a JSON body containing `error`.
5. What are the typical `expires_in` (access token) and device-code lifetime values, and is `user { userId, countryCode }` always present in the device-token response?
6. In Electron main, does `process.exit(1)` close the app immediately and skip quit handlers? (Unverified, needs a run.)
7. For the Swift port, owner decisions:
   - Keychain, or a 0600 JSON file?
   - When migrating a multi-entry `token.json`, use `entries[0]` or the newest entry?
   - Offer a Sign Out command?
   - Keep or fix the quirks: ignored `slow_down`, ignored rotated refresh token, no retry on 401?
8. Will the Swift app be sandboxed? That changes its Application Support path and decides whether it can read the Electron app's `token.json` for migration.
9. Is the plus-joined scope `r_usr+w_usr+w_sub` intended, or would the space-separated `r_usr w_usr w_sub` behave the same? Keep the current wire form until this is tested.
