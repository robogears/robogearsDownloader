## TIDAL/Spotify networking, resolver and matching (tidal_lib.js)

Scope: `tidal_lib.js` (898 lines, app v0.1.30) except its library scanner, plus the places that call it for networking, resolving and matching: the `resolve:input`, `resolve:cancel`, `resolve:tracklist` and `preview:get-audio` IPC handlers in `electron-main.js`; `tidal_download.js`, `bulk_runner.js`, `tidal_search.js` and `tidal_check_quality.js`; and the renderer code that triggers them (`renderer/app.js`). The library scanner in the same file (`tidal_lib.js:18-31, 620-844`) is a separate subsystem and is only referenced here.

### Overview

`tidal_lib.js` is the shared "brain" module. The Electron main process loads it directly, and every command-line or child script (`tidal_download.js`, `bulk_runner.js`, `tidal_search.js`, `tidal_check_quality.js`) loads it too. It has six jobs:

1. **Credentials.** It reads the TIDAL sign-in (OAuth) token from `token.json`, refreshes the short-lived access token when it has expired, and works out the account's country code, which every TIDAL call needs.
2. **HTTP.** Three helpers: one plain request (no retry, no redirects), one authenticated GET for `api.tidal.com`, and one byte downloader for TIDAL's content servers (CDN) that retries and follows a few redirects.
3. **TIDAL API.** Thin wrappers around eight TIDAL v1 endpoints (track, album, album items, playlist, playlist items, playback info, track search, lookup by ISRC).
4. **Input → queue entries.** It decides whether the text the user typed is a Spotify link, a TIDAL link, a bare TIDAL id, or a search, and turns links into a list of queue-ready track entries. Spotify data comes only from Spotify's public "embed" web pages, which cap playlists at 100 tracks.
5. **Matching.** Every Spotify track is matched to a TIDAL track by searching TIDAL for "title artist" and scoring the top 10 results on title, artist and duration. The same scoring (without duration) is copy-pasted into the CSV/text-import handler, the bulk downloader and the (discontinued) Chrome-extension handler.
6. **Small utilities.** A filename cleaner (`sanitize`), cover-art URL and download, and the `AacOnlyError` class.

There is no shared state between calls except the token file on disk and one global "cancel" flag in `electron-main.js`. Every IPC call reads `token.json` from disk again.

### Components

#### A. Credentials

**`TOKEN_FILE`** — `tidal_lib.js:13`
- `process.env.TIDAL_TOKEN_PATH || path.join(__dirname, 'token.json')`, evaluated once when the module loads.
- `electron-main.js:19-21` sets `TIDAL_TOKEN_PATH = <userData>/token.json` only when the app is packaged, and does it before `require('./tidal_lib')` (line 23). Child processes inherit it because `childEnv()` (`electron-main.js:60-71`) spreads `process.env`.
- In dev mode the file is `token.json` next to the source files. `userData` is the same folder in dev and packaged builds (`app.setName('robogears Downloader')`, line 13), so `queue.json` and `settings.json` are shared between dev and packaged runs, but `token.json` is not.
- `token:exists` (`electron-main.js:610-613`) recomputes the same path and only checks that the file exists.

**`loadCred()`** — `tidal_lib.js:48-60`
1. If the file does not exist: print `token.json not found. Run tidal_auth_node.js first.` to stderr and call `process.exit(1)`.
2. `JSON.parse(readFileSync(TOKEN_FILE, 'utf8'))`. A corrupt file throws a `SyntaxError`.
3. Normalise: an array is used as-is; any other value is wrapped as `[value]`.
4. If the array is empty: print `No credentials in token.json. Run tidal_auth_node.js first.` and `process.exit(1)`.
5. Return `entries[0]`. Later entries are never used.
- Called synchronously at the start of every operation: `resolve:input` (`electron-main.js:661`), `preview:get-audio` (875), `resolve:tracklist` (925), the extension handler (702), `bulk_runner.js:56`, `tidal_download.js:690`, `tidal_search.js:13`, `tidal_check_quality.js:13`.
- `process.exit(1)` terminates whichever process calls it. In the Electron main process that is the whole app; the handlers' `try/catch` cannot catch it.

**`saveCred(cred)`** — `tidal_lib.js:62-68`
- Re-reads the file, normalises to an array, sets `entries[0] = { ...entries[0], ...cred }` (merge, so unknown fields survive), and writes `JSON.stringify(entries, null, 4)` with `fs.writeFileSync`. Not atomic (no temp file + rename). Throws if the file is missing or corrupt.

**`refreshToken(cred)`** — `tidal_lib.js:70-95`
1. `POST https://auth.tidal.com/v1/oauth2/token` through `httpsRequest`, timeout 30 000 ms.
2. Form body, in this order: `client_id=<cred.client_ID>`, `refresh_token=<cred.refresh_token>`, `grant_type=refresh_token`, `scope=r_usr+w_usr+w_sub`. Values are percent-encoded with JavaScript's `encodeURIComponent`, so the scope goes on the wire as `scope=r_usr%2Bw_usr%2Bw_sub`.
3. Headers: `Authorization: Basic base64("<client_ID>:<client_secret>")` (both from the stored credential), plus the `httpsRequest` defaults (`User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, `Content-Type: application/x-www-form-urlencoded`, `Content-Length`). No `X-Tidal-Platform` header on this call.
4. If the status is not 200: throw `Token refresh failed: <status> <raw body>`.
5. Parse JSON. Set `cred.access_token = json.access_token` and `cred.expires_at = Date.now() + (json.expires_in || 3600) * 1000 - 60000` (refresh 60 s early; assume 1 hour if `expires_in` is missing).
6. If `json.user?.countryCode` is present and `cred.countryCode` is empty, copy it.
7. `saveCred(cred)` and return the new access token. A `refresh_token` in the response, if TIDAL ever sends one, is ignored.

**`getToken(cred)`** — `tidal_lib.js:97-102`
- If `cred.access_token && cred.expires_at && Date.now() < cred.expires_at`, return the stored token; otherwise `refreshToken(cred)`.
- No lock: two callers holding separate copies of an expired credential both refresh. Each operation fetches the token once and reuses it; nothing re-checks expiry or reacts to HTTP 401 mid-operation.

**`getCountryCode(cred)`** — `tidal_lib.js:104-119`
1. If `cred.countryCode` is set, return it (normally true: the sign-in flow stores it).
2. `token = await getToken(cred)` — outside the `try`, so refresh errors propagate.
3. `GET /v1/users/<cred.userID>?countryCode=US`. On 200 with `json.countryCode`: store it in `cred`, `saveCred`, return it.
4. Any exception, non-200 status or missing field: return `'US'`. This fallback is not saved, so the lookup repeats on every operation. A missing `userID` becomes the literal path `/v1/users/undefined`.

#### B. HTTP helpers

**`formEncode(obj)`** — `tidal_lib.js:123-127`
- `encodeURIComponent(key) + '=' + encodeURIComponent(value)`, joined with `&`, in insertion order. Spaces become `%20` (not `+`); `+` becomes `%2B`.

**`httpsRequest(opts, body = null, { auth = null })`** — `tidal_lib.js:129-154`
1. Headers, in this order: `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, then `...opts.headers` (which may override any of the three).
2. If `body` is truthy: `Content-Type` defaults to `application/x-www-form-urlencoded`; `Content-Length = Buffer.byteLength(body)`.
3. If `auth` is given: `Authorization: Basic base64("<auth[0]>:<auth[1]>")`.
4. `https.request({...opts, headers})`. The body is accumulated as a string with `d += chunk` (each Buffer chunk decoded separately) and the promise resolves on `'end'` with `{ status, body }` for **any** status code.
5. `req.setTimeout(opts.timeout || 30000)` destroys the request with `Request timeout after <ms>ms`. This is a socket **inactivity** timeout, not a total deadline.
6. `req` `'error'` rejects. There is no `'error'` listener on the response stream.
7. No redirect following, no retry, no status check.

**`tidalGet(urlPath, token, params)`** — `tidal_lib.js:156-168`
- Query string: `'?' + entries.map(k + '=' + encodeURIComponent(v)).join('&')`. Keys are not encoded; order is insertion order; omitted only if `params` is falsy (every caller passes params).
- `hostname: 'api.tidal.com'`, `method: 'GET'`, timeout 30 000 ms, headers `Authorization: Bearer <token>` and `X-Tidal-Platform: android` on top of the defaults above.
- Returns `{status, body}`; callers check the status. No retry or backoff on 429/5xx, no 401 handling.

**`fetchBuffer(url, { timeout = 30000, retries = 3 })`** — `tidal_lib.js:174-193`
- Loop with `attempt = 0 … retries`: call `fetchBufferOnce(url, timeout)`; on success return the Buffer.
- On error: `retriable = (e.retriable !== false)`. Stop if not retriable or `attempt === retries`. Otherwise sleep `min(1000 * 2^attempt, 8000)` ms and try again.
- Result: `retries + 1` attempts. With 3 retries the sleeps are 1000, 2000, 4000 ms; with 2: 1000, 2000; with 1: 1000. After the loop it rejects with the last error.

**`fetchBufferOnce(url, timeout)`** — `tidal_lib.js:195-232` (not exported)
- `proto` is chosen **once** from the original URL: `url.startsWith('https') ? https : http`.
- `doGet(u, redirects = 0)`: if `redirects > 5`, reject `Too many redirects` (no `retriable` flag, so `fetchBuffer` retries it). Otherwise `proto.get(u, { headers: { 'User-Agent': 'okhttp/5.3.2' } })` — no Accept, no Authorization.
  - Status 301, 302 or 307: drain and `doGet(res.headers.location, redirects + 1)` — at most 5 redirects followed.
  - Status 429 or ≥ 500: reject `HTTP <code> for <url>` with `retriable = true`.
  - Any other status ≠ 200 (including 206, 303, 308, 204, 404): same message, `retriable = false`.
  - 200: collect chunks, resolve `Buffer.concat` on `'end'`; response `'error'` rejects.
- Timeout: `req.setTimeout(timeout)` destroys with `Request timeout after <ms>ms` and `retriable: true`. Request `'error'` sets `retriable = true` if not already set (network errors are retriable) and rejects.
- Redirect failure modes, all inside the previous response's callback, so none of them becomes a clean rejection:
  - relative `Location` (`/x`): `proto.get` throws `Invalid URL` synchronously → uncaught exception, and the promise never settles;
  - scheme change (https → http or back): `proto.get` throws `Protocol "http:" not supported` synchronously → same result;
  - missing `Location`: `proto.get(undefined, …)` does not throw; Node treats the first argument as absent and sends the next request to its default host (localhost:443 for https). Usually that fails with a connection error, which is rejected as retriable and the original URL is retried. Unverified (needs a run).

#### C. TIDAL API wrappers (all through `tidalGet`)

| Function | Lines | Request | Non-200 behaviour | Returns |
|---|---|---|---|---|
| `getTrackInfo(id, token, cc='US')` | 236-240 | `GET /v1/tracks/{id}?countryCode=` | throws `Track info failed: <status> <body>` | parsed track |
| `getAlbumInfo(id, token, cc='US')` | 242-246 | `GET /v1/albums/{id}?countryCode=` | returns `null` | parsed album |
| `getAlbumItems(id, token, cc='US')` | 248-262 | `GET /v1/albums/{id}/items?countryCode=&limit=100&offset=N` (paged) | throws `Album items failed: <status> <body>` | array of raw items |
| `getPlaylistInfo(uuid, token, cc='US')` | 264-268 | `GET /v1/playlists/{uuid}?countryCode=` | returns `null` | parsed playlist |
| `getPlaylistItems(uuid, token, cc='US')` | 270-284 | `GET /v1/playlists/{uuid}/items?countryCode=&limit=100&offset=N` (paged) | throws `Playlist items failed: <status> <body>` | array of raw items |
| `getPlaybackInfo(id, token, quality='HI_RES_LOSSLESS', cc='US')` | 286-296 | `GET /v1/tracks/{id}/playbackinfopostpaywall?countryCode=&audioquality=<q>&playbackmode=STREAM&assetpresentation=FULL` | 401 → throws `Unauthorized — token may be invalid`; other → `Playback info failed: <status> <body>` | parsed playback info |
| `searchTracks(query, token, cc='US', limit=10)` | 298-302 | `GET /v1/search/tracks?query=<enc>&limit=<n>&countryCode=` | throws `Search failed: <status> <body>` | parsed `{items}` |
| (inline in `spotifyTrackToTidal`) | 562 | `GET /v1/tracks?isrc=<isrc>&countryCode=` | falls through silently | — |

- Paging (both item functions): start `offset = 0`, `limit = 100`; append `json.items || []`; stop when a page has fewer than 100 items, else `offset += 100`. No page cap, no cancel check. A list whose size is an exact multiple of 100 costs one extra empty request.
- Who uses what: `getAlbumInfo` — `tidal_download.js:387, 494`. `getPlaylistInfo` — only the CLI `downloadPlaylist` (`tidal_download.js:631`); the GUI resolver does not call it. `getPlaybackInfo` — `tidal_download.js` `getBestManifest` (325-342: tiers `['HI_RES_LOSSLESS','LOSSLESS']` in order, each error swallowed, then `Could not get playback manifest at any quality.`), the preview handler (`electron-main.js:878`, quality `'LOSSLESS'`) and `tidal_check_quality.js:24-26`.

#### D. Input parsing

**`parseTidalUrl(input)`** — `tidal_lib.js:431-447`
1. `s = input.trim()` (throws if `input` is not a string).
2. Regex `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i`, unanchored, no host boundary. Match → `{ type: group1.toLowerCase(), id: group2 }`. The id is not validated (non-numeric ids pass and fail later at the API).
   - `https://tidal.com/browse/track/103805726` → track `103805726`
   - `https://listen.tidal.com/album/103805725` → album
   - `https://tidal.com/track/123?u` → track `123`
   - `https://listen.tidal.com/album/A/track/T` → **album A** (first match wins)
3. `/^\d+$/` → `{ type: 'track', id: s }` (any bare number is a TIDAL track id).
4. `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i` → `{ type: 'playlist', id: s }`.
5. Otherwise `null` (artist, mix and video links return `null`).

**`parseSpotifyUrl(input)`** — `tidal_lib.js:450-454`
- `input.trim().match(/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i)` → `{ type: lowercased, id }`, else `null`.
- Accepts `https://open.spotify.com/track/<id>?si=…`, `open.spotify.com/intl-de/album/<id>`, `open.spotify.com/playlist/<id>`.
- Rejects `spotify:track:<id>` URIs, `/embed/<type>/<id>` links, `spotify.link` short links, legacy `/user/<u>/playlist/<id>` paths, artist/episode/show links, and intl segments with a second hyphen (`\w` excludes `-`).

**`parseInputUrl(input)`** — `tidal_lib.js:457-463`
- Spotify first, then TIDAL; returns `{ source: 'spotify'|'tidal', type, id }` or `null`. Callers treat `null` as "free-text search".

#### E. Spotify embed scraping

**`SPOTIFY_UA`** — `tidal_lib.js:472`: `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36`.

**`fetchSpotifyEmbed(type, id)`** — `tidal_lib.js:474-489` (not exported)
1. `httpsRequest` `GET https://open.spotify.com/embed/<type>/<id>`, timeout 30 000 ms, headers `User-Agent: SPOTIFY_UA`, `Accept: text/html` (plus the default `Accept-Encoding: identity`). No cookies, no auth, redirects not followed.
2. Status ≠ 200 → throw `Spotify <type> embed failed: HTTP <status>`.
3. Regex `/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/` (requires `id` to be the first attribute, double-quoted). No match → `No __NEXT_DATA__ in Spotify <type> embed`.
4. `JSON.parse(match)`; `entity = json?.props?.pageProps?.state?.data?.entity`; missing → `Unexpected Spotify embed shape for <type>/<id>`. Returns `entity`.

**`trackUriToId(uri)`** — 491-495: `null` if falsy, else `/spotify:track:([a-zA-Z0-9]+)/` group 1 or `null` (episodes and local files give `null`). The id is informational only.

**`splitArtists(subtitle)`** — 497-503: `(subtitle||'').split(/,(?![^(]*\))/)` (comma not inside parentheses) → trim → drop empty → `[{name}]`.

**`getSpotifyTrack(id)`** — 505-515: returns `{ id: e.id || id, name: e.name || e.title, artists: e.artists?.length ? e.artists.map(a => ({name: a.name})) : splitArtists(e.subtitle), duration_ms: e.duration, external_ids: {}, album: null }`. Never returns `null`.

**`getSpotifyAlbum(id)`** — 517-530: `albumArtists` as above; each `e.trackList[]` item → `{ id: trackUriToId(t.uri), name: t.title, artists: splitArtists(t.subtitle) if non-empty else albumArtists, duration_ms: t.duration, external_ids: {}, album: { name: e.name } }`. Returns `{ id, name, artists: albumArtists, tracks: { items } }`. No cap detection for albums.

**`getSpotifyPlaylist(id)`** — 532-551: each `trackList[]` item → `{ id: trackUriToId(t.uri), name: t.title, artists: splitArtists(t.subtitle) /* may be [] */, duration_ms: t.duration, external_ids: {}, album: null }`. Returns `{ id, name, description: e.description || '', owner: { display_name: e.subtitle || '' }, tracks, _embedCapped: tracks.length >= 100 }`.

#### F. Resolver

**`resolveUrlToTracks(input, token, cc='US', { isCancelled = null })`** — `tidal_lib.js:316-407`
1. `parsed = parseInputUrl(input)`; `null` → return `null`. `cancelled()` = `typeof isCancelled === 'function' && isCancelled()`.
2. `tidalEntry(t)` (321-329) = `{ tidalId: t.id, title: t.title, artist: (t.artists||[]).map(a => a.name).join(', '), duration: t.duration, source: 'tidal', matchMethod: 'direct', hiRes: t.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') || false }`.
3. **TIDAL** (331-346):
   - track → `[tidalEntry(await getTrackInfo(id))]`
   - album → `getAlbumItems` → `items.map(i => i.item || i).filter(t => t?.id && t.type !== 'video').map(tidalEntry)`
   - playlist → same with `getPlaylistItems`
   - then `if (cancelled()) return { tracks: [], cancelled: true }` (the only check, after all paging)
   - `await enrichWithLibraryStatus(out)` (adds `libraryMatch`), return `{ tracks: out, capped: false }`.
4. **Spotify** (348-405):
   - track → `[getSpotifyTrack(id)]`; album → `getSpotifyAlbum(id).tracks.items` (or `[]` if not an array); playlist → `getSpotifyPlaylist(id).tracks`, `capped = !!pl._embedCapped`.
   - `spTracks = spTracks.filter(Boolean)`; `if (cancelled()) return { tracks: [], cancelled: true }`.
   - Worker pool: `results = new Array(n)`, shared index `next = 0`, 8 workers via `Promise.all(Array.from({length: 8}, worker))`. Each loop: if `cancelled()` return; `i = next++`; if `i >= n` return; `artistStr` = Spotify artist names joined `', '`; then:
     - success: `results[i] = { title: sp.name, artist: artistStr, duration: Math.round((sp.duration_ms||0)/1000), source: 'spotify', tidalId: match?.track?.id || null, matchMethod: match?.method || null, notFound: !match, hiRes: match?.track?.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') || false }`
     - any thrown error (TIDAL 429/5xx/401, bad JSON, timeout): `results[i] = { title, artist, duration, source: 'spotify', tidalId: null, notFound: true }` (no `matchMethod`, no `hiRes`).
   - After the pool: `if (cancelled()) return { tracks: [], cancelled: true }`; `filtered = results.filter(Boolean)`; `await enrichWithLibraryStatus(filtered)`; return `{ tracks: filtered, capped }`.
   - Spotify entries keep **Spotify's** title, artist and duration even when matched; only `tidalId`, `matchMethod` and `hiRes` come from TIDAL. Order follows the Spotify source order.
5. Any other source → `null` (unreachable).
- In-flight HTTP requests are never aborted on cancel.

**`searchTracksForQueue(query, token, cc='US', limit=10)`** — `tidal_lib.js:412-426`
- `searchTracks(query, …, limit)`; map each item to `{ tidalId: t.id, title: t.title, artist: artists joined ', ', album: t.album?.title || '', duration: t.duration, hiRes: tags includes 'HIRES_LOSSLESS' || false, source: 'tidal', matchMethod: 'search' }`; `enrichWithLibraryStatus`; return the array. No scoring, no filtering; TIDAL's order is kept.

#### G. Matching

**`spotifyTrackToTidal(spTrack, token, cc='US')`** — `tidal_lib.js:558-611`
1. **ISRC branch** (559-568): if `spTrack.external_ids?.isrc`: `GET /v1/tracks?isrc=<isrc>&countryCode=<cc>`; on 200 with non-empty `items` return `{ track: items[0], method: 'isrc' }`; a non-200 falls through. **Never runs today**: every Spotify object is built with `external_ids: {}`.
2. `title = spTrack.name || ''`; `artist` = artist names joined with a **space**; `wantDuration = (duration_ms || 0) / 1000` (not rounded).
3. `json = await searchTracks(title + ' ' + artist, token, cc, 10)` (throws on non-200). No items → return `null`.
4. Score each item with the algorithm below, including the duration term.
5. Keep items passing the acceptance rule; sort by `total` descending (stable, so ties keep TIDAL's order). None → `null`; else `{ track: best.it, method: 'search', score: best.total }`.
- The JSDoc at 553-557 says it returns "the TIDAL track object"; it actually returns the wrapper above.

**Scoring algorithm (identical in all four copies except where noted)**

```
norm(s)  = lowercase(s or "")                    // JS toLowerCase: full Unicode mapping
           → replace every UTF-16 code unit not in [a-z0-9 ] with " "
           → collapse runs of spaces to one " " // only ASCII spaces are left at this point
           → trim
wantT = norm(wantedTitle)
wantA = norm(wantedArtistString)
for each search item `it`:
  itT = norm(it.title)
  itA = join(" ", it.artists[].name mapped through norm)
  titleScore = 100 if itT == wantT
             else 50 if itT.startsWith(wantT) or wantT.startsWith(itT)
             else 25 if itT.contains(wantT) or wantT.contains(itT)
             else 0
  aTokens = wantA.split(" ").filter(len > 2)
  matched = count of aTokens t where itA.contains(t)        // substring test
  artistScore = aTokens.isEmpty ? 0 : round(matched / aTokens.count * 100)
  durationScore (Spotify matcher only):
     d = |(it.duration or 0) - wantDuration|
     50 if d < 3, 25 if d < 8, else 0
  total = titleScore + artistScore (+ durationScore)
accepted = titleScore == 100 or (titleScore >= 25 and artistScore >= 50)
pick = accepted sorted by total desc, stable (ties keep search order) → first
```

Copies and their differences:

| Copy | Location | Query | Duration term | Entry built from pick |
|---|---|---|---|---|
| Spotify resolver | `tidal_lib.js:558-611` | `"<title> <artists joined by space>"` | yes | Spotify title/artist/duration; TIDAL id, `hiRes` |
| CSV/text import | `electron-main.js:938-974` | `"<title> <artist string as given>"` | no | TIDAL title, artists, duration; no `hiRes` |
| Bulk fallback | `bulk_runner.js:11-29, 73-90` | `"<title> <artist>"`, only if both non-empty | no | id only |
| Chrome extension (not ported) | `electron-main.js:707-743` | as import | no | as import, plus `hiRes` |

Duration only affects ranking, never acceptance. An exact normalised title is accepted with **no** artist check at all (deliberate, per the comment at `tidal_lib.js:602-605`); artist and duration then only rank the candidates.

Worked examples (Spotify matcher, `wantDuration` = 200 s):

| Wanted (title / artist) | TIDAL result (title / artists / duration) | title | artist | dur | total | Accepted? |
|---|---|---|---|---|---|---|
| `Stronger` / `Kanye West` | `Stronger` / `Kanye West` / 201 | 100 | 100 | 50 | 250 | yes |
| `Stronger` / `Kanye West` | `Stronger` / `Another Band` / 222 | 100 | 0 | 0 | 100 | yes (exact title), ranks below the row above |
| `Stronger` / `Kanye West` | `Stronger (Remix)` → `stronger remix` / `Kanye West` / 240 | 50 | 100 | 0 | 150 | yes |
| `Free Your Mind` / `En Vogue` | `Mind` / `Other Artist` / 200 | 25 | 0 | 50 | 75 | no (partial title needs artist ≥ 50) |
| `Song` / `The Weeknd` | `Song Two` / `The Beatles` / 200 | 50 | 50 (`the` matches) | 50 | 150 | yes — wrong artist passes |

#### H. Utilities

- **`sanitize(str)`** — `tidal_lib.js:616-618`: `(str || 'unknown').replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim()`. Replaces `\ / : * ? " < > |` with `_`, collapses whitespace, trims. Does not handle leading/trailing dots, control characters, reserved Windows names or length; a whitespace-only string becomes `''`. Used by `tidal_download.js:351-353`; the output filename is `<sanitized title>.flac` or `.m4a`.
- **`coverUrl(coverId, size = 1280)`** — 846-849: `null` if falsy, else `https://resources.tidal.com/images/<coverId with every '-' replaced by '/'>/<size>x<size>.jpg`.
- **`fetchCover(coverId)`** — 851-857: `fetchBuffer(coverUrl(coverId), { retries: 1 })` (2 attempts, 1000 ms backoff, 30 s timeout); any failure → `null`, never throws. Called by `tidal_download.js:448` with `info.album?.cover`, in parallel with the audio download.
- **`AacOnlyError`** — 38-44: `Error` subclass, `name = 'AacOnlyError'`, message `Track is AAC-only on TIDAL`, property `trackInfo`. Thrown by `tidal_download.js:420` in `--flac-only` mode.
- **`module.exports`** — 859-898, 38 entries: `USER_AGENT, TOKEN_FILE, DEFAULT_TIMEOUT, LIBRARY_PATH` (live getter), `setLibraryPath, scanLibrary, rescanLibrary, findInLibrary, enrichWithLibraryStatus, AacOnlyError, loadCred, saveCred, getToken, refreshToken, getCountryCode, httpsRequest, tidalGet, fetchBuffer, formEncode, getTrackInfo, getAlbumInfo, getAlbumItems, getPlaylistInfo, getPlaylistItems, getPlaybackInfo, searchTracks, parseTidalUrl, parseSpotifyUrl, parseInputUrl, resolveUrlToTracks, searchTracksForQueue, getSpotifyTrack, getSpotifyAlbum, getSpotifyPlaylist, spotifyTrackToTidal, sanitize, coverUrl, fetchCover`. Not exported: `DEFAULT_RETRIES, LIBRARY_EXTS, SPOTIFY_UA, fetchBufferOnce, fetchSpotifyEmbed, trackUriToId, splitArtists, normalize*` helpers, `loadMM`. No other file uses `USER_AGENT, TOKEN_FILE, DEFAULT_TIMEOUT, saveCred, refreshToken, httpsRequest, tidalGet, formEncode, parseTidalUrl, parseSpotifyUrl, coverUrl`.
- **Library scanner** (separate subsystem): `LIBRARY_PATH` from env `TIDAL_LIBRARY_FOLDER` (24), `setLibraryPath` (28-31), `scanLibrary` (674-757), `rescanLibrary` (760-763), `findInLibrary` (788-833), `enrichWithLibraryStatus` (836-844). The resolver calls `enrichWithLibraryStatus` at `tidal_lib.js:344, 403, 424` and `electron-main.js:745, 977`; it awaits `findInLibrary(t.title, t.artist, t.duration)` for each track one after another, swallows per-track errors, and sets `t.libraryMatch` when there is a match. The first call may trigger a full library scan.

#### I. Callers

**IPC `resolve:input`** — `electron-main.js:658-687`; preload `resolveInput` (`electron-preload.js:44`)
1. `resolverCancelled = false`.
2. `cred = loadCred()`; `token = await getToken(cred)`; `country = await getCountryCode(cred)` — before parsing, even for searches.
3. `parsed = parseInputUrl(input)`. If set: `result = resolveUrlToTracks(input, token, country, { isCancelled: () => resolverCancelled })`; if `resolverCancelled || result?.cancelled` → `{ ok: false, cancelled: true }`; else `{ ok: true, kind: 'url', tracks: result?.tracks || [], capped: !!result?.capped }`.
4. Else `tracks = searchTracksForQueue(input, token, country, 10)`; if `resolverCancelled` → `{ ok: false, cancelled: true }`; else `{ ok: true, kind: 'search', tracks }`.
5. `catch` → `{ ok: false, error: e.message }` (messages often contain the raw TIDAL body).
- Renderer (`renderer/app.js:1287-1323`): trims the input; returns early if empty; checks `api.tokenExists()` (else logs `⚠ Sign in to TIDAL first (Settings → Sign in).`); shows the full-screen loading overlay with a Cancel button; then handles `r.cancelled` (`⊗ Resolve cancelled.`), `!r.ok` (`✗ <error>`), `kind === 'url'` (adds tracks, logs `+ Added N track(s) from link (M not on TIDAL).`, and if `r.capped` logs `⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren't included.`), or `kind === 'search'` (opens the search modal titled `Search results for "<query>"` with hint `N result(s). Pick the ones to add to your queue.`; only ticked rows are added). `handleInput` has no in-flight guard.
- Input hint (`renderer/app.js:66, 1276-1282`): `URL_RE = /^https?:\/\/|spotify\.com|tidal\.com/i` decides between `Detected a link — will resolve all tracks on add.` and `Type to search TIDAL by song name (or paste a link).` This is cosmetic; routing is decided by `parseInputUrl`.

**IPC `resolve:cancel`** — `electron-main.js:56-58, 689`; renderer `296-321`
- Sets the single module-level `resolverCancelled = true` and returns `{ ok: true }`. Every new `resolve:input` resets it to `false`. Checked only at the points listed in F, plus after `searchTracksForQueue`. The renderer's button turns into `Cancelling…` (disabled) and the overlay stays until the IPC returns. `resolve:tracklist` ignores the flag.

**IPC `resolve:tracklist`** — `electron-main.js:919-982`; preload `resolveTracklist`, `onTracklistProgress` (46-47)
1. Input `{ tracks: [{ title, artist }] }` (artist is always a string, possibly `''`; built by the renderer's CSV and plain-text parsers, `renderer/app.js:1899-1937`).
2. `loadCred`, `getToken`, `getCountryCode`; send `tracklist:progress {done: 0, total}`.
3. **Sequentially** for each track: `searchTracks(title + ' ' + artist, …, 10)`, score without the duration term, accept, sort, `pick = first`. Entry = `{ title: pick?.title || t.title, artist: pick ? pick artists joined ', ' : t.artist, duration: pick?.duration || 0, tidalId: pick?.id || null, source: 'import', matchMethod: pick ? 'search' : null, notFound: !pick, originalTitle: t.title, originalArtist: t.artist }`. On error: `{ title, artist, tidalId: null, source: 'import', notFound: true }`. Send progress `i + 1` after each track.
4. `enrichWithLibraryStatus(out)`; return `{ ok: true, tracks: out }`; setup errors → `{ ok: false, error }`. Not cancellable.
- Renderer (`renderer/app.js:1813-1857`): entry points are the drop-zone drop (1772), the file picker (1784) and a document-level paste (1800; ignored when an input/textarea has focus, when shorter than 10 characters, or when it has no newline, comma or ` - `/` — `/` | ` separator). A second import while one runs is ignored. Log lines: `📋 Parsed N track(s) from <source>. Matching against TIDAL…`, overlay `Matching D / N tracks on TIDAL…`, then `+ Added N from import. M matched on TIDAL, K not found.` or `✗ No tracks found in <source>.` **This path does not check `tokenExists()`.**

**IPC `preview:get-audio`** — `electron-main.js:814-917`; preload `getPreviewAudio` (50)
- `loadCred` → `getToken` → `getCountryCode` → `getPlaybackInfo(id, token, 'LOSSLESS', country)` → base64-decode the manifest.
  - `manifestMimeType` starts with `application/vnd.tidal.`: parse JSON; `encryptionType` other than `NONE` → `{ok:false, error:'Track is DRM-encrypted'}`; no `urls` → `No stream URL in manifest`; else `fetchBuffer(urls[0], {timeout: 60000, retries: 2})`, `mimeType = json.mimeType || 'audio/flac'`.
  - `application/dash+xml`: `_parseDashForPreview` (823-853). Direct `BaseURL` with no `SegmentTemplate` → `fetchBuffer(url, {60000, 2})`, `audio/flac`. Otherwise `_fetchDashAudioBuffer` (857-871): init segment, then every `$Number$` segment with 8 workers, each `fetchBuffer {timeout: 60000, retries: 2}`, concatenated, `mimeType 'audio/mp4'`.
  - Anything else → `Unknown manifest type: <type>`.
- The renderer pre-loader (`renderer/app.js:730-749`, concurrency 2) calls it for every queue row with a `tidalId` when tracks are added (1267) and for every restored row at boot (1983-1986). The boot path does **not** check `tokenExists()`.

**`tidal_download.js`** (download pipeline; FFmpeg/file side belongs to the downloader section)
- Per track: `getToken`, `getCountryCode`, `getTrackInfo`, `sanitize`, `getAlbumInfo` (or pre-fetched), `getBestManifest` (HI_RES_LOSSLESS then LOSSLESS), DASH segments with `lib.fetchBuffer` defaults (30 s, 3 retries; workers = `min(concurrency, segments)`), cover via `fetchCover`.
- Direct (BTS) URLs use its own `downloadDirect` (`tidal_download.js:215-256`): UA `okhttp/5.3.2` hard-coded, follows 301/302/303/307/308 (only when `Location` is present) up to 5, picks http/https for **each** hop, 60 000 ms inactivity timeout (`Download timed out`), **no retry**, streams to disk with byte progress.
- CLI Spotify wrappers (`downloadSpotifyTrack/Playlist/Album`, 526-623) call `getSpotifyTrack/Playlist/Album` and `spotifyTrackToTidal`. `downloadSpotifyAlbum` re-fetches every track's embed "for ISRC" (602-604), which never yields one. The CLI help text (83-84) still says Spotify is resolved via an "anonymous web API → ISRC match".
- Argument parsing: `<url|id> [outDir] [--quality LOSSLESS|HI_RES_LOSSLESS] [--concurrency N] [--force] [--debug] [--flac-only] [--skip-library-check] [--help|-h]`; `DEFAULT_OUT_DIR = 'Z:\Downloads'` (40). Exit code 2 = single track skipped.

**`bulk_runner.js`** — calls `loadCred/getToken/getCountryCode` once (56-58). For entries without `tidalId` but with both `title` and `artist` it searches and scores (73-90, third copy, no duration). The GUI sends only `!notFound && included` entries, so in practice every entry already has a `tidalId`. Spawns `tidal_download.js <id> <outDir> --skip-library-check` per track and prints `__TRACK_START__:<id>` / `__TRACK_DONE__:<id>:<downloaded|skipped|failed|notFound>`.

**`tidal_search.js`** — joins argv into the query; no query → usage, exit 0; `searchTracks(…, 10)`; prints `No results.` or lines `  [i] ID <id>  <artists> — <title> (<album>) [m:ss] [Hi-Res]`; errors → `Error: <msg>`, exit 1.

**`tidal_check_quality.js`** — `getTrackInfo`, prints `audioQuality`, `audioModes`, `mediaMetadata.tags`; then for `LOW, HIGH, LOSSLESS, HI_RES, HI_RES_LOSSLESS, DOLBY_ATMOS` calls `getPlaybackInfo` and prints `audioQuality` plus `codecs="…"`, `audioSamplingRate="…"` and `<Representation id="…">` from the decoded manifest; each tier's error message is printed in place.

#### J. Inventory only — Chrome extension bridge (support ended 21 Oct 2026; not ported)

`electron-main.js:24` (require `extension-server`), 28 (`<userData>/extension-token.txt`), 497-522 (server start at boot), 696-751 (`handleExtensionTracks`: a fourth copy of the matcher, `source: 'extension'`, event `extension:tracks-resolved`), 753-802 (bundle copy/version helpers), 804-812 (IPC `extension:info`, `extension:regenerate-token`); `electron-preload.js:52-55`; `extension-server.js`; `chrome-extension/`; `scripts/sync-extension-version.js`; the renderer's `Spotify ext` badge (`renderer/app.js:922`). Drop all of it from the port.

### Data formats

**`token.json`** (written by `tidal_auth_node.js:53-59, 148-156`; read and merged by `tidal_lib.js:48-68`)

```json
[
  {
    "access_token":  "<string>",
    "refresh_token": "<string>",
    "userID":        12345,
    "countryCode":   "US",
    "expires_at":    1234567890000,
    "client_ID":     "<string>",
    "client_secret": "<string>"
  }
]
```

- JSON array, 4-space indent; a bare object is also accepted on read. `expires_at` is epoch milliseconds already reduced by 60 000. `userID` comes from the token response's `user.userId`; `countryCode` from `user.countryCode` (may be absent).
- The sign-in flow removes entries with the same `client_ID` **and** `refresh_token`, then **appends** the new entry; the lib always uses `entries[0]`.
- `client_ID`/`client_secret` stored here are the second ("REQUEST") client pair hard-coded in `tidal_auth_node.js:19-20`; the device sign-in itself uses the first ("AUTH") pair (`tidal_auth_node.js:17-18`). All four are base64 string literals decoded with `Buffer.from(…, 'base64').toString('latin1')`. Values are not reproduced here.

**Queue entries produced by this subsystem** (the renderer later adds `key`, `included`, `dlStatus`, `dlPercent`, `selected`)

| Source | Shape |
|---|---|
| TIDAL link (`tidal_lib.js:321-329`) | `{ tidalId: number, title, artist: "A, B", duration: seconds, source: 'tidal', matchMethod: 'direct', hiRes: bool, libraryMatch? }` |
| Spotify link, matched/unmatched (377-386) | `{ title: Spotify, artist: Spotify "A, B", duration: round(ms/1000), source: 'spotify', tidalId: number\|null, matchMethod: 'isrc'\|'search'\|null, notFound: bool, hiRes: bool, libraryMatch? }` |
| Spotify link, match threw (388-395) | `{ title, artist, duration, source: 'spotify', tidalId: null, notFound: true, libraryMatch? }` |
| Search result (414-423) | `{ tidalId, title, artist, album: string, duration, hiRes, source: 'tidal', matchMethod: 'search', libraryMatch? }` |
| CSV/text import (`electron-main.js:961-973`) | `{ title: TIDAL's if matched, artist: TIDAL's "A, B" if matched else input, duration: pick.duration \|\| 0, tidalId: number\|null, source: 'import', matchMethod: 'search'\|null, notFound: bool, originalTitle, originalArtist, libraryMatch? }`; on error `{ title, artist, tidalId: null, source: 'import', notFound: true }`. No `hiRes`. |

`libraryMatch` = `{ kind: 'exact'|'similar', path, libraryTitle }` (library section).

**Return and message shapes**

- `resolveUrlToTracks`: `null` (not a link) | `{ tracks, capped: false }` (TIDAL) | `{ tracks, capped: bool }` (Spotify) | `{ tracks: [], cancelled: true }`.
- `resolve:input` reply: `{ ok: true, kind: 'url', tracks, capped }` | `{ ok: true, kind: 'search', tracks }` | `{ ok: false, cancelled: true }` | `{ ok: false, error: string }`.
- `resolve:tracklist` reply: `{ ok: true, tracks }` | `{ ok: false, error }`; event `tracklist:progress` = `{ done, total }`.
- `preview:get-audio` reply: `{ ok: true, audioBytes: Buffer, mimeType }` | `{ ok: false, error }`.
- `spotifyTrackToTidal`: `{ track, method: 'isrc' }` | `{ track, method: 'search', score: 0-250 }` | `null`. `score` is only printed by the CLI (`tidal_download.js:572`).
- `httpsRequest`: `{ status: number, body: string }`. `fetchBuffer` errors: `Error` with message `HTTP <code> for <url>` | `Request timeout after <ms>ms` | `Too many redirects` | Node network error, and a boolean `.retriable`. The URL in the message can be a signed CDN URL.

**Internal Spotify track object (Web-API look-alike)** — `{ id: string|null, name, artists: [{name}], duration_ms: number|undefined, external_ids: {} (always empty), album: null | {name} }`.

**Spotify embed `__NEXT_DATA__`** — root `props.pageProps.state.data.entity`.
- Track entity: `id`, `name` or `title`, `artists[].name`, `subtitle` (comma-separated artists), `duration` (assumed milliseconds).
- Album entity: `id`, `name`, `artists[].name`, `subtitle`, `trackList[]` of `{ uri: 'spotify:track:<id>', title, subtitle, duration }`.
- Playlist entity: `id`, `name`, `description`, `subtitle` (owner), `trackList[]` as above (at most 100).

**TIDAL fields read**
- Track: `id` (number), `title`, `artists[].name`, `artist.name`, `duration` (seconds), `mediaMetadata.tags[]` (contains `HIRES_LOSSLESS` for hi-res), `album.{id, title, cover (UUID), releaseDate, artist.name}`, `trackNumber`, `volumeNumber`, `copyright`, `isrc`, `streamStartDate`, `audioQuality`, `audioModes`, `type`. Availability fields (for example `allowStreaming`, `streamReady`) are not read.
- Album/playlist item page: `{ items: [ { item: Track, type, … } | Track ] }` — code uses `i.item || i`.
- Search and ISRC lookup: `{ items: Track[] }`. User: `{ countryCode }`.
- Playback info: `{ manifestMimeType: 'application/vnd.tidal.bt' | 'application/vnd.tidal.bts' | 'application/dash+xml' | …, manifest: base64 string, audioQuality }`.
- Token refresh: `{ access_token, expires_in (seconds), user?.countryCode }`.

### External interfaces

| Interface | Detail |
|---|---|
| TIDAL token refresh | `POST https://auth.tidal.com/v1/oauth2/token`, form body `client_id, refresh_token, grant_type=refresh_token, scope=r_usr%2Bw_usr%2Bw_sub`, `Authorization: Basic base64(client_ID:client_secret)`, UA `okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. Success only on 200. |
| TIDAL REST API | `https://api.tidal.com/v1/…` — `users/{userID}`, `tracks/{id}`, `tracks?isrc=`, `albums/{id}`, `albums/{id}/items`, `playlists/{uuid}`, `playlists/{uuid}/items`, `tracks/{id}/playbackinfopostpaywall`, `search/tracks`. Headers on every call: `Authorization: Bearer <token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. 30 s inactivity timeout, no retry, no redirects. Every call carries `countryCode`. |
| TIDAL cover CDN | `https://resources.tidal.com/images/<uuid with '/' for '-'>/1280x1280.jpg`, UA only, 1 retry. |
| TIDAL stream CDN | Signed URLs from manifests, fetched with `fetchBuffer` (UA only, no auth; retries on network errors, timeouts, 429, 5xx) or `downloadDirect` (CLI downloads; no retry). |
| Spotify embed pages | `https://open.spotify.com/embed/{track|album|playlist}/{id}`, desktop Chrome 120 UA, `Accept: text/html`, `Accept-Encoding: identity`, no cookies, no redirects, 30 s inactivity timeout. |
| File | `token.json` at `TIDAL_TOKEN_PATH` (packaged macOS: `~/Library/Application Support/robogears Downloader/token.json`) or `<source dir>/token.json`; read synchronously on every operation; written non-atomically. |
| Environment | `TIDAL_TOKEN_PATH`, `TIDAL_LIBRARY_FOLDER`, `BULK_RUNNER_PROGRESS` (`'1'` → `__TRACK_PROGRESS__` lines), `DEBUG`, `ELECTRON_RUN_AS_NODE='1'`, `FORCE_COLOR='0'` for children. |
| IPC | invoke `resolve:input {input}`, `resolve:cancel`, `resolve:tracklist {tracks}`, `preview:get-audio {tidalId}`; event `tracklist:progress {done,total}`. |
| CLI | `node tidal_search.js <terms…>`; `node tidal_check_quality.js <track-id>`; `node tidal_download.js <url|id> [outDir] [flags]` (exit 0 ok, 1 error, 2 skipped single track). |

### Constants and magic values

| Name | Value | Where | Meaning |
|---|---|---|---|
| `USER_AGENT` | `okhttp/5.3.2` | `tidal_lib.js:14` (also hard-coded `tidal_download.js:220`, `tidal_auth_node.js`) | Presents as TIDAL's Android client on all TIDAL and CDN calls |
| `X-Tidal-Platform` | `android` | 165 | Header on every `api.tidal.com` call |
| `Accept-Encoding` | `identity` | 134 | No compression on `httpsRequest` traffic |
| `DEFAULT_TIMEOUT` | 30 000 ms | 15 | Socket inactivity timeout |
| `DEFAULT_RETRIES` | 3 | 16 | `fetchBuffer` → 4 attempts |
| Backoff | `min(1000·2^attempt, 8000)` ms | 186 | 1 s, 2 s, 4 s (cap needs ≥ 4 retries) |
| Redirects (`fetchBufferOnce`) | follows 301/302/307, max 5 | 199-204 | 303/308 are fatal |
| Retriable | 429, ≥ 500, network errors, timeouts, `Too many redirects` | 184, 205-227 | `fetchBuffer` only |
| OAuth scope | `r_usr+w_usr+w_sub` (wire: `r_usr%2Bw_usr%2Bw_sub`) | 80 | Refresh scope |
| Token margin | `expires_in` (default 3600 s) − 60 s | 88 | Early refresh |
| Default country | `US` | 108, 118, defaults | Lookup param and fallback |
| Page size | 100 | 251, 273 | Album/playlist item paging |
| Search limit | 10 | 298, 412, 576; `electron-main.js:681, 942`; `bulk_runner.js:75`; `tidal_search.js:17` | Results per query |
| Default playback quality | `HI_RES_LOSSLESS` | 286 | Preview uses `LOSSLESS`; downloader tries `HI_RES_LOSSLESS` then `LOSSLESS` |
| Playback params | `playbackmode=STREAM`, `assetpresentation=FULL` | 290-291 | Fixed |
| Hi-res tag | `HIRES_LOSSLESS` in `mediaMetadata.tags` | 328, 385, 420 | Sets `hiRes: true` |
| Spotify match workers | 8 | 399 | Parallel matching |
| `SPOTIFY_UA` | Windows Chrome 120 desktop UA | 472 | Embed scrape |
| Embed cap flag | `trackList.length >= 100` | 549 | Playlists only |
| Title scores | 100 / 50 / 25 / 0 | 587-590 | Exact / prefix either way / substring either way / none |
| Artist score | `round(matched/tokens·100)`, tokens longer than 2 chars, substring test | 592-594 | 0 when no tokens |
| Duration scores | < 3 s → 50; < 8 s → 25; else 0 | 596-597 | Spotify matcher only |
| Acceptance | `title == 100 || (title >= 25 && artist >= 50)` | 607 | Gate before ranking |
| Cover size | 1280 | 846 | `1280x1280.jpg` |
| Cover retries | 1 | 855 | 2 attempts |
| Preview fetch | timeout 60 000 ms, retries 2, DASH workers 8 | `electron-main.js:858-903` | Preview downloads |
| `downloadDirect` | 60 000 ms, 301/302/303/307/308 up to 5, no retry | `tidal_download.js:215-256` | CLI/child direct downloads |
| Quality probe tiers | `LOW, HIGH, LOSSLESS, HI_RES, HI_RES_LOSSLESS, DOLBY_ATMOS` | `tidal_check_quality.js:24` | Diagnostic |
| FLAC tiers | `LOSSLESS, HI_RES_LOSSLESS, HI_RES` | `tidal_download.js:401` | `audioQuality` in this set → FLAC output |
| Preloader concurrency | 2 | `renderer/app.js` preloader | Preview prefetch |

### Rules and invariants

- Every TIDAL API call carries `countryCode`: stored value → `/v1/users/{userID}` → `US`.
- Exactly one credential is used: `token.json` `entries[0]`. `saveCred` merges into `entries[0]` and keeps everything else.
- A token is valid while `Date.now() < expires_at`; `expires_at` already includes the 60 s margin.
- API calls (`httpsRequest`/`tidalGet`) never retry and never follow redirects. Only CDN byte downloads (`fetchBuffer`) retry, and only on network errors, timeouts, 429 and 5xx.
- Timeouts are inactivity timeouts, not total deadlines.
- Routing order: Spotify regex → TIDAL URL regex → bare number (TIDAL track) → bare UUID (TIDAL playlist) → free-text search.
- Album/playlist items are unwrapped with `i.item || i` and kept only if they have an `id` and `type !== 'video'`.
- Paging stops at the first page shorter than 100.
- Spotify data comes only from public embed pages: no credentials, no cookies.
- `capped` is only ever true for Spotify playlists with 100 or more embed entries.
- Spotify-sourced entries show Spotify's title/artist/duration; import entries show TIDAL's when matched.
- A Spotify track that fails to match, or whose matching throws, still becomes an entry with `notFound: true` and `tidalId: null`; order follows the source.
- Acceptance: title 100, or title ≥ 25 with artist ≥ 50; highest total wins; ties keep TIDAL's search order.
- Duration influences ranking only in the Spotify matcher.
- Search query is `"<title> <artist>"`; Spotify joins multiple artists with a space; imports use the raw artist string (possibly empty, giving a trailing space).
- Library enrichment runs after resolution and before returning, on every resolver path.
- Cancellation is cooperative: a flag polled at fixed points; in-flight requests are never aborted.
- Resolver results never contain `included`; the renderer sets it from `libraryMatch`. The renderer de-duplicates added entries by `tidalId`, or by `title|artist` when there is no id (`renderer/app.js:1255-1263`), so two source tracks matched to the same TIDAL id collapse into one queue row.
- Filenames come from `sanitize(title)` only.

### Edge cases and failure modes

- **Number-only input** (`1999`, `22`, `7`) is treated as a TIDAL track id: the app fetches `/v1/tracks/1999` instead of searching, and either queues an unrelated track or shows `Track info failed: 404 …`.
- **Unsupported links** (TIDAL artist/mix/video, Spotify artist/episode/show, `spotify:` URIs, `spotify.link`, `/embed/` links) are not parsed; the whole URL string is sent to TIDAL search, while the input hint says `Detected a link`.
- `listen.tidal.com/album/A/track/T` resolves to the whole album A.
- A TIDAL URL with a non-numeric id parses, then fails with `Track info failed: 4xx <body>`.
- A Spotify playlist with exactly 100 tracks shows the cap warning even though nothing was dropped.
- Spotify embed non-200 (private, deleted, region-blocked) or any 3xx: `Spotify playlist embed failed: HTTP <code>` and the whole resolve fails.
- Spotify playlist entries with an empty subtitle get `artists: []`: the query is `"<title> "`, artist score is 0, and only exact-title matches are accepted.
- Episodes/local files in a playlist get `id: null` but are still matched by text.
- **Titles that normalise to an empty string** — non-Latin scripts (CJK, Cyrillic, Greek, Arabic…), punctuation-only titles, or a missing title — see Bugs.
- **Result titles that normalise to an empty string** score 50 against any wanted title (`wantT.startsWith('')`), so they pass the gate whenever the artist score is ≥ 50.
- Artists whose tokens are all ≤ 2 characters (`U2` → `u2`, `MØ` → `m`) give artist score 0: only exact titles are accepted.
- Accented letters are replaced by a space, not folded (`Beyoncé` → `beyonc`, `Café del Mar` → `caf del mar`, `Sigur Rós` → `sigur r s`, whose only artist token is `sigur`). Matching works when both sides spell it the same way, and fails when one side writes `Beyonce`.
- Artist tokens are substring tests on the joined artist string: `ill` matches `illenium`, and common words like `the` count (wanted `The Weeknd` vs result `The Beatles` = 50).
- Missing Spotify `duration_ms` → `wantDuration` 0 → duration score effectively 0.
- TIDAL 429/5xx during the 8-way Spotify matching or the sequential import: the search throws, the entry becomes `notFound: true`, and the user sees "not on TIDAL".
- The access token expiring during a long import or a big playlist: nothing refreshes it on 401, so later tracks become `notFound`.
- Cancel during TIDAL album/playlist paging takes effect only after all pages load; cancel during a search only after the search and library enrichment finish.
- **Missing `token.json` (or an empty array) on any main-process path** → `process.exit(1)`, the app quits without a message. Reachable (a) on first launch by dropping, choosing or pasting a tracklist before signing in (no token check in `handleTracklistInput`), and (b) at boot when a restored queue starts preview pre-loading without a token — for example after deleting the token, or when switching between dev and packaged builds (shared `queue.json`, different `token.json` locations).
- `token.json` containing `[]` passes `tokenExists()` but still hits `process.exit(1)`.
- Corrupt `token.json`: `JSON.parse` throws, the IPC returns `{ok:false, error:'Unexpected token …'}`.
- A CDN redirect with a relative `Location` or to the other scheme throws inside the response callback (uncaught exception; the download promise never settles). A missing `Location` sends the next request to Node's default host instead (unverified).
- CDN 206, 303 or 308 is a permanent failure in `fetchBuffer`.
- Multi-byte UTF-8 characters split across response chunks decode as U+FFFD (most likely in large Spotify embed HTML and 100-item pages).
- A connection dropped after the response headers arrive in `httpsRequest` has no response-stream error listener; the promise may never settle and the loading overlay would stay up (unverified, needs a run).
- A server that ignores `offset` and always returns 100 items would make paging loop forever.
- Two titles that sanitise to the same filename: the second is skipped as "already in downloads folder".
- A title like `...Baby One More Time` produces a hidden file on macOS (leading dot); a whitespace-only title produces `.flac`.
- Availability fields (`allowStreaming`, `streamReady`) are never read, so a track TIDAL lists but will not stream would be queued and fail later at download time (whether TIDAL returns such items in these lists is unverified).
- **A TIDAL link followed by more text** (`https://tidal.com/browse/track/123 great song`): the id group `[^/?#]+` captures `123 great song`; Node refuses the request path (`Request path contains unescaped characters`) and that message is shown. Ids containing characters above U+00FF fail the same way; other odd characters (`%`, `"`) are sent raw to `api.tidal.com`.
- **Generic exact titles** (`Intro`, `Home`, `Stay`): when the right artist's version is not in TIDAL's top 10, another artist's song with the same title is accepted (exact title needs no artist check). In the Spotify path the row still shows the Spotify artist, so the mismatch is invisible until the file is downloaded.
- For Spotify rows the library duplicate check runs on Spotify's title and artist, while the downloaded file is named from TIDAL's title. When the two spellings differ (for example `Song - 2011 Remaster` vs `Song (2011 Remaster)`), the library and skip-if-exists checks can disagree.
- Two Spotify tracks that match the same TIDAL id collapse into one queue row (renderer de-duplication), so `+ Added N` can be lower than the number of source tracks.

### Bugs and oddities

| # | Severity | Issue | Evidence |
|---|---|---|---|
| 1 | High | `loadCred` calls `process.exit(1)` inside the Electron main process, quitting the app when `token.json` is missing or empty. Two UI paths reach it without a `tokenExists()` check: the CSV/text import (drop, file picker, paste) and the boot-time preview pre-load of a restored queue. `try/catch` in the handlers cannot catch it. The visible quit was not observed in a run. | `tidal_lib.js:48-58`; `electron-main.js:875, 925`; `renderer/app.js:1772-1807, 1830-1843, 1983-1986` |
| 2 | Medium | Re-authenticating does not replace the credential in use. Sign-in appends the new entry (old entries are only removed when `client_ID` **and** `refresh_token` match, which a fresh login never does); the lib always reads and writes `entries[0]`, i.e. the oldest credential. If that one is revoked, every operation fails with `Token refresh failed: …` and signing in again cannot fix it. | `tidal_auth_node.js:53-59`; `tidal_lib.js:59, 66` |
| 3 | Medium | TIDAL API calls never retry; rate limiting or a server error is reported as "not on TIDAL". The Spotify resolver runs 8 searches at once; a 429/5xx throws and the worker records `notFound: true`. Same in the sequential import. ("Retry on 429/5xx" is true only for CDN byte downloads.) | `tidal_lib.js:156-168, 298-301, 387-395`; `electron-main.js:972-974` |
| 4 | Medium | ASCII-only normalisation causes wrong matches. Any title that normalises to `''` (non-Latin script, punctuation-only, missing) makes every exact-`''` result score 100 (accepted without artist) and every other result 50. Conversely, any TIDAL result titled in a non-Latin script scores 50 against any wanted title, so a different song by the same artist passes the gate when no better candidate exists. In the Spotify path the queue shows Spotify's title, so the user cannot see the mismatch before downloading. | `tidal_lib.js:580-590, 607`; same in `electron-main.js:944-958`, `bulk_runner.js:11-22, 79` |
| 5 | Low | No token refresh on 401 or on expiry during long operations: the token is fetched once per operation. | `tidal_lib.js:97-102`; `electron-main.js:661-663, 925-927`; `bulk_runner.js:56-58` |
| 6 | Low | UTF-8 corruption: response chunks are converted to strings one at a time (`d += c`), so a multi-byte character split across chunks becomes U+FFFD, corrupting titles/artists used for matching and display. | `tidal_lib.js:144-146` |
| 7 | Low | An exact normalised title is accepted with no artist check, by design. For generic titles (`Intro`, `Home`, `Stay`) a different artist's song wins whenever the right one is missing from TIDAL's top 10; in the Spotify path the row keeps showing the Spotify artist. Separately, short common words count as artist tokens (`the`), so `The Weeknd` scores 50 against `The Beatles`, enough to pass the partial-title gate. | `tidal_lib.js:592-594, 602-607` (same in `electron-main.js:954-958`, `bulk_runner.js:24-26, 79`) |
| 8 | Low | `fetchBufferOnce` redirect handling: the protocol is chosen once from the original URL. A relative `Location` or a scheme change throws synchronously inside the response callback (uncaught exception, promise never settles); a missing `Location` silently sends the next request to Node's default host (unverified); 303/308 are not followed. `downloadDirect` in `tidal_download.js` follows 301/302/303/307/308 only when `Location` is present and picks the protocol per hop. | `tidal_lib.js:197-204`; `tidal_download.js:219-224` |
| 9 | Low | One global cancel flag. Each `resolve:input` resets it, and `handleInput` has no in-flight guard, so a second resolve started while one is pending (for example Enter pressed again in the still-focused input; whether the overlay blocks this is unverified) un-cancels the first. In that case workers that already exited leave holes, which `filter(Boolean)` (line 402) silently drops and returns as a partial list; otherwise the line-400 check returns first. Paging, search and enrichment are not cancellable. | `electron-main.js:56-58, 659, 689`; `tidal_lib.js:370, 400-402`; `renderer/app.js:1284-1298` |
| 10 | Low | Exactly-100-track playlists are flagged as capped (`>= 100`). | `tidal_lib.js:549`; `renderer/app.js:1313-1315` |
| 11 | Low | Bare numeric input is always a TIDAL track id; songs named `1999` or `22` cannot be searched. | `tidal_lib.js:439` |
| 12 | Low | Unsupported links are silently searched as text while the hint says `Detected a link`. | `tidal_lib.js:457-463`; `electron-main.js:665-683`; `renderer/app.js:66, 1278-1282` |
| 13 | Low | Non-atomic token writes, potentially from several processes (main-process previews at concurrency 2, each with its own freshly loaded credential, plus each download child). Can cause duplicate refresh calls and racing writes; a crash mid-write leaves a corrupt file. | `tidal_lib.js:62-68` |
| 14 | Low | `httpsRequest` has no response-stream `'error'` listener; a connection dropped mid-body may leave the promise pending forever (unverified, needs a run). | `tidal_lib.js:143-150` |
| 15 | Info | The ISRC branch is dead code (`external_ids` is always `{}`); `method: 'isrc'` never occurs. The CLI's Spotify-album path still re-fetches every track's embed "for ISRC", and the CLI help text still promises ISRC matching. | `tidal_lib.js:559-568, 512, 526, 540`; `tidal_download.js:83-84, 602-604` |
| 16 | Info | Matcher copy-pasted four times with diverging rules (duration term, which metadata is kept, `hiRes` presence). | Table in Components G |
| 17 | Info | `refreshToken` ignores a rotated `refresh_token` (whether TIDAL rotates is unverified). | `tidal_lib.js:86-93` |
| 18 | Info | `getCountryCode` fallback `US` is not cached; a missing `userID` requests `/v1/users/undefined`. | `tidal_lib.js:104-119` |
| 19 | Info | The video filter checks the unwrapped inner item, not the page wrapper. Whether inner objects ever carry `type: 'video'` is unverified (needs a run); if not, music videos on albums/playlists would be queued. | `tidal_lib.js:338, 341`; `tidal_download.js:503, 640` |
| 20 | Info | Raw HTTP response bodies (JSON or HTML) are put into error messages and shown in the activity log. | `tidal_lib.js:84, 238, 254, 276, 294, 300`; `renderer/app.js:1304` |
| 21 | Info | Unused exports and duplicated helpers: 11 exports unused elsewhere; `tidal_download.js` hard-codes the UA; `tidal_auth_node.js` has its own `httpsRequest` (no timeout) and `formEncode`; `getSpotifyAlbum` calls `splitArtists(t.subtitle)` twice per track; `spotifyTrackToTidal`'s JSDoc describes the wrong return type. | `tidal_lib.js:524, 553-557, 859-898` |
| 22 | Info | `sanitize` is incomplete for macOS/Windows filenames (leading/trailing dots, control characters, reserved names, length; whitespace-only → `''`). | `tidal_lib.js:616-618` |
| 23 | Info | The Spotify embed scrape is brittle: fixed attribute order in the regex, fixed JSON path, no redirects. Any markup change breaks every Spotify input at once. | `tidal_lib.js:483-488` |
| 24 | Info | `Too many redirects` has no `retriable` flag, so `fetchBuffer` retries a redirect loop with backoff (a few wasted seconds). | `tidal_lib.js:184, 199` |
| 25 | Info | TIDAL ids from links are not validated or percent-encoded before going into the API path. `[^/?#]+` also captures spaces, so a link followed by more text fails with Node's `Request path contains unescaped characters`. | `tidal_lib.js:435-436, 237, 253, 275` |

### Platform-specific behaviour

- Request identity imitates other clients on every OS: TIDAL calls present as the Android app (`okhttp/5.3.2`, `X-Tidal-Platform: android`); Spotify calls present as Chrome 120 on Windows.
- Token location depends on packaging: dev → `<source>/token.json`; packaged → `<userData>/token.json` (`~/Library/Application Support/robogears Downloader/` on macOS, `%APPDATA%\robogears Downloader\` on Windows), passed via `TIDAL_TOKEN_PATH`. `queue.json`/`settings.json` are shared between dev and packaged runs; the token is not.
- State crosses process boundaries through environment variables and files because downloads run as `ELECTRON_RUN_AS_NODE` child processes.
- `sanitize` uses the Windows reserved-character set even on macOS, where only `/` and `:` are problematic.
- The CLI default output folder `Z:\Downloads` is Windows-only and unused by the GUI.
- Node's `req.setTimeout` is an idle timeout.
- `Accept-Encoding: identity` disables gzip on all `httpsRequest` traffic.

### Porting notes for a native Swift macOS app

| Topic | Today | Swift approach | Difficulty |
|---|---|---|---|
| TIDAL API client | Node `https.request`, manual headers, status returned for any code, string body, no redirects, 30 s idle timeout, no retry | `URLSession` data tasks with the same headers set per request; `timeoutIntervalForRequest = 30` (also an idle timeout). To keep "no redirects", return `nil` from `urlSession(_:task:willPerformHTTPRedirection:…)`. Decode UTF-8 from the complete `Data` (fixes bug 6). Consider adding retry with backoff for 429/5xx and one refresh-and-retry on 401 (fixes bugs 3 and 5) — a behaviour change for the owner to approve. Whether TIDAL requires the exact UA/platform header is unverified. | Easy |
| Query and form encoding | `encodeURIComponent` (unreserved: `A-Z a-z 0-9 - _ . ! ~ * ' ( )`), keys raw in `tidalGet`, order preserved | Write a small percent-encoder with exactly that unreserved set. `URLQueryItem` leaves `+` unescaped, which servers read as a space (breaks searches like `Mumford + Sons`) and changes the refresh body. Keep parameter order. | Easy |
| CDN downloads | `fetchBuffer`: retry on network errors/timeouts/429/5xx, backoff `min(1000·2^n, 8000)` ms, follows 301/302/307 up to 5, whole body in memory | `async` retry loop with `Task.sleep`; check `HTTPURLResponse.statusCode` yourself (URLSession does not throw on HTTP errors). URLSession follows all redirect codes automatically — accept that (fixes bug 8) or filter in the delegate. Classify `URLError` codes as retriable. Use download tasks for large previews. | Easy |
| Credentials | Plain JSON file, read synchronously on every operation, `entries[0]`, non-atomic writes, separate processes may refresh concurrently, `process.exit` on missing file | One in-process credential store (an `actor`) that throws instead of exiting, keeps a single refresh in flight, writes atomically, and preferably stores secrets in the Keychain. If importing an existing `token.json`, accept array and bare-object forms and choose an entry deliberately (bug 2: the newest entry is the most recent sign-in). Build the Basic header by hand from the stored client id/secret. | Medium |
| JSON decoding | `JSON.parse` + optional chaining (`i.item || i`, `e.name || e.title`, `json.items || []`) | `Codable` models with every field optional, or `JSONSerialization`. Track ids are numbers (`Int64`), playlist ids are UUID strings. Handle the `{item, type}` wrapper vs bare track. Default missing arrays to empty. | Medium |
| Spotify embed scrape | Regex for `<script id="__NEXT_DATA__" …>…</script>`, JSON path `props.pageProps.state.data.entity` | Swift `Regex`/`NSRegularExpression` (lazy, dot matches newlines), then walk the same path; same headers; same `>= 100` cap rule (or `> 99`; see open questions). | Easy |
| Parallel matching + cancel | 8 async workers sharing an index, results stored by position, polled boolean, no request abort | `withTaskGroup` capped at 8 in flight, results stored by index to keep order; per-track errors become `notFound` entries instead of failing the group. Structured cancellation also cancels in-flight URLSession requests (an improvement). Use one cancel token per resolve, not a global flag. | Medium |
| Normalisation | JS `toLowerCase()` (Unicode-aware), `[^a-z0-9 ]` → space over UTF-16 units, collapse `\s+`, trim | Exact reproduction: `lowercased()`, then walk `unicodeScalars` (not `Character`s) and map every scalar outside ASCII `a-z`, `0-9`, space to a space, collapse runs of spaces, trim. Iterating `Character`s would differ from JS for decomposed accents: `e` + U+0301 is one Swift `Character` (→ one space) but two JS code units (JS keeps the `e`). Surrogate pairs and multi-scalar emoji only add extra spaces, which the collapse removes. Because the output is ASCII, Swift `hasPrefix`/`contains`/`==` then match JS. An exact copy also copies bugs 4 and 7; folding diacritics (`.folding(options: .diacriticInsensitive, …)`) and keeping non-Latin letters would fix it but change match results — owner decision. | Easy |
| Stable ranking | `Array.prototype.sort` (stable) | Sort by `(total desc, original index asc)` explicitly; Swift's `sort` is not documented as stable. | Easy |
| One matcher | Four copies with different rules | One function with a `useDuration` option and an explicit choice of which metadata goes into the entry. | Easy |
| Manifest base64 | `Buffer.from(m, 'base64').toString('utf8')` | `Data(base64Encoded:)` + `String(decoding:as: UTF8.self)`. | Easy |
| Process boundaries | Env vars and stdout markers between Node processes | In-memory configuration and typed progress callbacks / `AsyncStream`. | Easy |
| Filenames | `sanitize()` | Same character set so existing files are still detected by skip-if-exists; consider handling leading dots and length. | Easy |
| Cover art | Parallel fetch, 1 retry, `nil` on failure | `async let` alongside the audio download; `Data?`. | Easy |
| Input routing | Spotify → TIDAL URL → bare number → bare UUID → search | Same order for compatibility; consider not treating short numbers as ids, and supporting `spotify:` URIs and `/embed/` links (owner decision). Validate TIDAL ids (digits for track/album, UUID for playlist) and percent-encode path segments instead of passing the captured text through (bug 25). | Easy |
| Sign-in headers | The device sign-in (`tidal_auth_node.js`) sends `X-Platform: android` and `Accept-Language: en-US,en;q=0.9`; the refresh call here sends neither, and API calls send `X-Tidal-Platform: android` instead | Reproduce each call's header set exactly as it is today until a run shows which headers TIDAL actually needs. | Easy |
| Gate on sign-in | Several UI paths reach the token loader without checking sign-in first (bug 1) | Every resolver, import and preview entry point should check for a credential and show "Sign in to TIDAL first" instead of failing. | Easy |

### Open questions

1. Is the Spotify embed `duration` always milliseconds? The code assumes so.
2. Do Spotify album embeds also cap `trackList` (at 100 or another number)? Only playlists are checked.
3. Does Spotify use intl path segments with more than one hyphen? The regex rejects them.
4. In TIDAL v1 item pages, does the inner `item` carry `type: 'video'` for music videos, or only the wrapper? Unverified (needs a run); it decides whether the video filter works.
5. Does refreshing with the stored "REQUEST" client pair work for tokens issued to the device-flow "AUTH" pair? The code relies on it.
6. Does TIDAL rotate refresh tokens? The code discards any new one.
7. What is TIDAL's typical `expires_in`, and how often do long imports outlive it?
8. Does TIDAL require the `okhttp` UA, `X-Tidal-Platform: android` and `Accept-Encoding: identity`, or were they copied from the original hifi-api project?
9. Is `/v1/search/tracks` ordered by relevance? Ties fall back to that order.
10. Should the port keep two matching variants (with/without duration) and keep Spotify's metadata in the queue while imports show TIDAL's? The code is inconsistent and the owner's intent is not recorded.
11. Does `/v1/tracks?isrc=` work with these credentials? It has never been reached.
12. Is 8-way concurrency safe against TIDAL rate limits? There is no 429 handling to show what limit exists.
13. Should a Spotify playlist of exactly 100 tracks show the cap warning? (Today it does.)
14. Does TIDAL's CDN ever answer with redirects (and if so, relative ones or ones without `Location`)? That decides whether bug 8 is ever hit; unverified (needs a run).
15. Should an exact title alone keep being enough to accept a match (bug 7), or should the port require some artist agreement for very short or generic titles? Owner decision.
