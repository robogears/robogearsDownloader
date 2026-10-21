## Music library scanner and duplicate matcher

_Source of truth: code at v0.1.30. Primary file `tidal_lib.js` (lines 18–31 and 620–844). Callers: `electron-main.js`, `renderer/app.js`, `renderer/index.html`, `electron-preload.js`, `tidal_download.js`, `bulk_runner.js`. All worked examples below use invented titles. They were derived by hand from the code and were not executed._

### Overview

The library check is an optional feature. It compares incoming tracks against the user's own music folder (the "library") so the app does not download songs the user already owns. The library folder is **read-only**: the app only lists folders and reads audio tags, and it never writes, moves or renames anything there. If no folder is set, the check is off.

`scanLibrary()` builds an **in-memory index** of the folder once per process. It walks every subfolder, keeps files with one of 8 audio extensions, and stores several normalised forms of each file's title, taken from both the filename and the audio tags (title, artist, duration). The index is never saved to disk and nothing watches the folder for changes. It is rebuilt only when the folder setting changes, when the user clicks **Refresh**, or when the app restarts. `findInLibrary(title, artist)` compares one incoming track against the index in four passes and returns `exact`, `similar` or `null`. The comparison is ASCII-only, exact-string (no fuzzy matching) and ignores duration.

In the GUI, every resolver (TIDAL link, Spotify link, search, CSV/text import) attaches a `libraryMatch` to each track before it reaches the queue. That queue is the only gate:
- `exact` rows start **excluded**: greyed out, title struck through, with a **+ Add** button.
- `similar` rows stay **included** and show a yellow warning badge.

At download time the GUI does **not** check the library again, because `bulk_runner.js` always passes `--skip-library-check`. In the command-line tool (`tidal_download.js` run directly), both `exact` and `similar` matches skip the download unless `--force` or `--skip-library-check` is given.

---

### Components

#### 1. Library path state — `tidal_lib.js:18-31`, export at `:863-864`
1. When the module loads: `let LIBRARY_PATH = process.env.TIDAL_LIBRARY_FOLDER || ''` (`:24`). The environment value is **not** trimmed. There is no default folder in code.
2. `setLibraryPath(p)` (`:28-31`): `LIBRARY_PATH = (p || '').trim(); _libraryCache = null;`
   - It does **not** clear `_libraryScanPromise`, does not start a scan and does not check that the path exists.
3. An empty string means "no library": `scanLibrary` then caches `{ entries: [] }`.
4. Exported as a live getter `get LIBRARY_PATH()` plus `setLibraryPath`.
5. The doc comment at `:18-23` ("If a track with a matching title already exists here, we skip the download") describes CLI behaviour only and is stale for the GUI.

#### 2. Normalisers — `tidal_lib.js:625-656` (not exported)
- **`normalizeFullForMatch(s)`** (`:626-629`). The "full" key keeps version suffixes.
  1. `if (!s) return ''`
  2. `String(s).toLowerCase()`
  3. Replace every character outside ASCII `a-z`, `0-9` and space with a space: regex `/[^a-z0-9 ]/g`, no `u` flag, so it works per UTF-16 code unit. This catches accented letters, combining marks, non-Latin scripts and all punctuation.
  4. Collapse whitespace runs (`/\s+/g` → one space), then `trim()`.
- **`normalizeCoreForMatch(s)`** (`:635-653`). The "core" key strips version and featuring annotations so different versions of a song compare equal. Steps, in order:
  1. `if (!s) return ''`; `x = String(s).toLowerCase()`.
  2. `parenIdx = x.search(/[(\[]/)`. If `parenIdx > 0`, `x = x.slice(0, parenIdx)`. This cuts at the **first** ASCII `(` or `[` only when it is not at index 0, and it also works when the closing bracket is missing. Index 0 is checked on the raw lowercased string, so leading spaces count: `"  (A) B"` has its bracket at index 2 and is cut to nothing.
  3. `x = x.replace(/\s+(feat|ft|featuring)\.?\s+.*$/i, '')` removes the featuring part and everything after it.
  4. `x = x.replace(<VERSION_RE>, '')` removes ` - <keyword>` and everything after it (regex in Constants).
  5. `x = x.replace(/[^a-z0-9 ]/g, ' ')`, then collapse whitespace and trim.
  - The `i` flags are redundant because the text is already lowercased. `\s` in steps 3 and 4 matches JavaScript's whitespace set, which includes NBSP, U+FEFF, U+2000–U+200A, U+3000 and others. `\b` is the ASCII word boundary.
- **`normalizeForMatch(s)`** (`:655-656`) returns `normalizeCoreForMatch(s)`. It is dead code: not exported and called nowhere.

#### 3. `loadMM()` — `tidal_lib.js:658-664`
- Loads the tag reader once, using the tri-state cache `_mmCached` (`null` = not tried yet, the module = loaded, `false` = failed).
- `try { _mmCached = require('music-metadata') } catch { _mmCached = false }`. There is no ESM `import()` fallback.
- It works because `package.json:22` pins `"music-metadata": "^7.14.0"`, `package-lock.json:3137-3138` locks 7.14.0, and the 7.x line is CommonJS. Later majors are ESM-only (general knowledge; `node_modules` is not present to check).
- A failed load is silent and never retried. The scan then indexes **filenames only**, so `exact` becomes impossible.

#### 4. `scanLibrary(onProgress?)` — `tidal_lib.js:674-757` (cache variables `:622-623`)
Returns `Promise<{ entries: Entry[] }>`. While the result is cached, every call returns the same object reference.
1. If `_libraryCache !== null`, return it at once. No progress events are sent.
2. If `_libraryScanPromise` is set (a scan is running), return **that promise**. This caller's `onProgress` is ignored; only the caller that started the scan gets progress ticks.
3. Otherwise set `_libraryScanPromise` to an async IIFE (an immediately invoked async function):
   1. `entries = []`. If `!LIBRARY_PATH || !fs.existsSync(LIBRARY_PATH)`, return `{ entries }` with no progress events.
   2. `mm = loadMM()`.
   3. **Walk (synchronous, recursive, depth-first):** `walk(dir)` calls `fs.readdirSync(dir, { withFileTypes: true })`. If that throws, the folder is skipped silently. A `LIBRARY_PATH` that is a file gives 0 files. For each entry, `full = path.join(dir, ent.name)`:
      - If `ent.isDirectory()`, recurse into it.
      - Else if `ent.isFile()`, compute `ext = path.extname(ent.name).toLowerCase()`, and if `LIBRARY_EXTS` contains it, push `{ full, name, ext }`.
      - Symlinks are neither followed nor indexed, because a symlink entry reports neither `isDirectory` nor `isFile`.
      - There is no hidden-file filter and no depth limit. Order follows `readdirSync`.
   4. `total = files.length`. If `onProgress` is a function, call `onProgress(0, total)`. This first tick comes **after** the whole walk has finished.
   5. **Tag pass:** start 8 workers with `Promise.all(Array.from({ length: 8 }, worker))`. Each worker repeatedly takes `i = nextIdx++` until `i >= files.length`. For each file:
      - `rawBase = name.slice(0, name.length - ext.length)` (original case, extension removed)
      - `sepIdx = rawBase.lastIndexOf(' - ')`; `filenameTitle = sepIdx >= 0 ? rawBase.slice(sepIdx + 3) : rawBase`. The **last** ` - ` wins.
      - Defaults: `metaTitle = ''`, `metaArtist = ''`, `metaDuration = 0`. If `mm` loaded: `m = await mm.parseFile(full, { duration: true, skipCovers: true, skipPostHeaders: true })`; `metaTitle = m.common.title || ''`; `metaArtist = m.common.artist || (Array.isArray(m.common.artists) ? m.common.artists[0] : '') || ''`; `metaDuration = Math.round(m.format.duration || 0)`. Any error is swallowed and the defaults stay.
      - Push the Entry (see Data formats).
      - `done++`. If `onProgress` is a function and (`done - lastReportedAt >= 25` or `done === total`), set `lastReportedAt = done` and call `onProgress(done, total)`.
   6. Return `{ entries }`. Entries are in **parse-completion order**, which is non-deterministic.
4. `_libraryCache = await _libraryScanPromise; _libraryScanPromise = null; return _libraryCache;` (`:754-756`). Only the caller that started the scan runs this.
- **Threading:** the walk runs synchronously inside the Electron main process, so all IPC and window events wait until it finishes. If `music-metadata` failed to load, the workers never `await`, so the **whole** scan runs synchronously.

#### 5. `rescanLibrary()` — `tidal_lib.js:759-763`
`_libraryCache = null; _libraryScanPromise = null;`. It does not start a scan and does not cancel one already running. The earlier scan's caller continuation at `:754-755` still runs later. It overwrites `_libraryCache` and nulls `_libraryScanPromise`, even if a newer scan is in flight.

#### 6. `findInLibrary(title, artist, _duration)` — `tidal_lib.js:788-833` (doc comment `:765-787`)
Returns `Promise<{ kind: 'exact'|'similar', path, libraryTitle } | null>`.
1. `if (!title) return null`. This happens before any scan.
2. `cache = await scanLibrary()`, with no progress callback. This may start a full scan or wait for one already running.
3. `if (!cache.entries.length) return null`.
4. `tFull = normalizeFullForMatch(title)`; `tCore = normalizeCoreForMatch(title)`. If `!tCore || tCore.length < 3`, return `null`. The scan has already run by this point.
5. `aFull = normalizeFullForMatch(artist)`. TIDAL and Spotify callers pass artist names joined with `', '`.
6. `artistsAgree(e)` is `aFull && e.metaArtist && (e.metaArtist.includes(aFull) || aFull.includes(e.metaArtist))`. This is plain **substring containment** on the whole normalised strings, in either direction. There is no tokenising and no handling of artist order.
7. **Pass 1 (exact)**, over all entries in array order: if `e.metaTitleFull && e.metaTitleFull === tFull && artistsAgree(e)`, return `{ kind: 'exact', path: e.path, libraryTitle: e.metaTitleDisplay || basename }`.
8. **Pass 2 (similar, tag title matches but the artist is unknown or different):** if `e.metaTitleFull && e.metaTitleFull === tFull`, return `similar` with `libraryTitle = e.metaTitleDisplay || basename`.
9. **Pass 3 (similar, filename):** if `e.fnTitleFull === tFull || e.fnFull === tFull`, return `similar` with `libraryTitle = path.basename(e.path)`, the filename **with** its extension. The artist half of an `Artist - Title` filename is never compared.
10. **Pass 4 (similar, core):** a single loop that checks each entry in two ways:
    - if `e.metaTitleCore && e.metaTitleCore === tCore`, return `similar` with `libraryTitle = metaTitleDisplay || basename`;
    - else if `e.fnTitleCore === tCore || e.fnCore === tCore`, return `similar` with `libraryTitle = basename`.
11. Return `null`.
- The kind returned **never depends on entry order**: each pass scans every entry before the next pass starts, so an `exact` anywhere beats any `similar`. Order only decides **which file** is reported (`path`, `libraryTitle`).
- In passes 1, 2 and the tag branch of pass 4, the `|| path.basename(...)` fallback can never run. A non-empty normalised tag title implies a non-empty raw tag title, so `libraryTitle` is always the raw tag title there.
- `_duration` is unused, and `metaDuration` is never read.

#### 7. `enrichWithLibraryStatus(tracks)` — `tidal_lib.js:835-844`
For each track **in sequence** (no concurrency): `try { m = await findInLibrary(t.title, t.artist, t.duration); if (m) t.libraryMatch = m } catch {}`. It mutates the array and returns it. A `null` result leaves no `libraryMatch` key, and an existing `libraryMatch` is never deleted. `notFound` tracks are enriched too. Cost is O(tracks × entries × up to 4 passes).

#### 8. Where enrichment runs (which title and artist get compared)
| Call site | Title / artist checked |
|---|---|
| TIDAL URL (track/album/playlist), `tidal_lib.js:343-345` | TIDAL `title`, TIDAL artist names joined `', '`. Runs after the cancel check, then returns `{ tracks, capped: false }`. |
| Spotify URL, `tidal_lib.js:400-404` | **Spotify** title (`sp.name`) and Spotify artists joined `', '`, not the matched TIDAL title (`:377-386`). Runs after the 8-worker match pool, the cancel check and `results.filter(Boolean)`. |
| Free-text search, `tidal_lib.js:424` (`searchTracksForQueue`) | TIDAL title/artists for up to 10 results. The search modal (`renderer/app.js:1329-1347`) does not show library status, but picked rows keep their `libraryMatch`. |
| CSV/text import, `electron-main.js:977` (`resolve:tracklist`) | The picked TIDAL title and artists joined `', '` when matched; otherwise the CSV/text title and artist. |
| Chrome extension, `electron-main.js:745` | Same as import (inventory only; extension support ends with the Swift port). |

Enrichment has no cancel checks and waits for any library scan already running. During an import, the loading overlay already reads `Matching M / M tracks…` while enrichment (and any scan wait) runs, because the final `tracklist:progress` tick is sent before `enrichWithLibraryStatus` (`electron-main.js:972-977`).

#### 9. Electron main wiring — `electron-main.js`
- `sendScanProgress(done, total)` (`:32-36`): if `mainWindow && !mainWindow.isDestroyed()`, send `'library:scan-progress'` `{ done, total }`.
- **Boot** (`:471-485`): `s = loadSettings()`. If `typeof s.libraryFolder === 'string'`, call `lib.setLibraryPath(s.libraryFolder)`. Then `createWindow()`. If `s.libraryFolder` is truthy, run `lib.scanLibrary(sendScanProgress).then(c => mainWindow && send('library:scanned', { count: c.entries.length })).catch(() => {})`.
- **`saveSettings(s)`** (`:42-52`, called by `settings:save` at `:556`): `prev = loadSettings()`; write `settings.json` as 2-space-indented JSON. If `typeof s.libraryFolder === 'string' && s.libraryFolder !== prev.libraryFolder`, call `setLibraryPath` and start the same background scan, which ends with `'library:scanned'`. Saving the same folder again does **not** rescan.
- **`settings:reset`** (`:561-565`): `saveSettings({ downloadFolder: '', libraryFolder: '' })`. This replaces the whole file with only those two keys, so other keys such as `volume` are lost. Because the library value changed (or was missing), it also starts an empty "scan".
- **`settings:pick-folder`** (`:567-573`): native `openDirectory` dialog. `defaultPath` is always the saved **download** folder, even when picking the library folder.
- **`library:status`** (`:577-580`): `c = await lib.scanLibrary(sendScanProgress)`, then return `{ count: c.entries.length, path: lib.LIBRARY_PATH }`.
- **`library:rescan`** (`:582-587`): `lib.rescanLibrary()`; `c = await lib.scanLibrary(sendScanProgress)`; `if (mainWindow)` send `'library:scanned'` `{ count }`; return `{ ok: true, count }`.
- **`childEnv()`** (`:60-71`): spawned children get `TIDAL_LIBRARY_FOLDER: s.libraryFolder || ''`.
- `mainWindow` is never set back to `null` after the window closes (`:54`).

#### 10. Renderer: Settings → Folders tab — `renderer/index.html:133-145`, `renderer/app.js`
- Markup:
  - Label: "Music library folder (for duplicate check)".
  - `#library-input` (readonly, placeholder "(none — duplicate check disabled)"), with buttons `#library-browse` "Browse…", `#library-open` "Open" and `#library-clear` "Clear".
  - Status `#library-status` (initial text "…") and `#library-rescan-btn` "Refresh".
  - Hint: "Read-only. The app reads audio-tag metadata (title, artist, duration) as well as filenames. Re-scans automatically on each launch." (Only true when a folder is set.)
- **Open settings** (`:1505-1509`): runs `refreshLibraryStatus()`.
- **Browse** (`:1531-1540`): `pickFolder()`; if a folder was chosen, set `settings.libraryFolder`, save, enable Open, and log `📁 Music library folder set to: <folder>`. Main rescans in the background only if the value changed.
- **Open** (`:1542-1544`): `openFolder(settings.libraryFolder)`. The button is disabled when no folder is set (`:1512-1515`).
- **Clear** (`:1546-1553`): `libraryFolder = ''`, save, log `📁 Music library folder cleared (duplicate check disabled).`, then `refreshLibraryStatus()`.
- **Refresh** (`:1555-1567`): text `Scanning…`, button disabled, `r = await libraryRescan()`, text `${r.count} files indexed` (always plural), log `📁 Library re-scanned: ${r.count} files indexed.`. On error the text is `Scan failed`. The button is re-enabled in `finally`.
- **Reset config** (`:1569-1577`): `confirm('Forget the download folder and music library folder?\n\n(Your TIDAL sign-in stays.)')`, then `settings = await resetSettings()`, clear both inputs, `refreshLibraryStatus()`, and log `⚙ Config reset. Pick a download folder in Settings to continue.`
- **`refreshLibraryStatus()`** (`:1675-1685`): text `Scanning…`, then `r = await libraryStatus()`. If `r.path` is set, show `${count} file(s) indexed` (singular when the count is 1), else `(no library folder set)`. On error show `(scan failed)`.
- **`onLibraryScanned`** (`:1687-1689`): `${count} file${count===1?'':'s'} indexed`.
- **`onLibraryScanProgress`** (`:1694-1698`): `total ? \`Scanning ${done} / ${total}…\` : 'Scanning…'`.

#### 11. Renderer: queue — `renderer/app.js`
1. **`renderQueue`** (`:890-1022`):
   - `isExact = lm?.kind === 'exact'`, `isSimilar = lm?.kind === 'similar'`.
   - If `t.included === undefined`, set `t.included = !isExact`. This happens lazily at the first render and is saved afterwards.
   - `excluded = !t.included && !t.notFound` adds the row class `excluded`. CSS `styles.css:667-669`: `.qi-info` at opacity 0.42, title struck through, the ✕ button at 0.42, and **+ Add** kept fully bright.
2. **Status badge priority** (`:913-922`):
   1. download states (`↓ N%`, `✓ done`, `⏭ skipped`, `✗ failed`)
   2. `not found`
   3. exact: `<span class="badge dupe" title="<path>">📁 already in library</span>`
   4. similar: `<span class="badge similar" title="<path>">⚠ similar version in library</span>` (amber, `styles.css:663`)
   5. source badges
3. **Library note** (`:928-930`): for exact or similar rows with a `libraryTitle`, show `<div class="qi-libnote">Library: <libraryTitle></div>` (monospace, ellipsised). This note shows even on `notFound` rows and during download states.
4. **+ Add** (`:932-934`, click `:1082-1092`): shown only on excluded rows (`title="Add to download list"`). A click sets `included = true`, re-renders and calls `saveQueueSoon()`. The library badge stays. There is no way to exclude a row again (or exclude a similar row) except removing it with ✕.
5. **Download all** (`:1419-1452`): sends `queue.filter(t => !t.notFound && t.included)`. The button reads `Download (N)` when N differs from the queue length, else `Download all` (`:998-1004`).
6. **After any batch finishes** (`:1457-1482`), the queue keeps only `t.notFound || failed || notFound || (!t.dlStatus && t.included)`. Excluded `exact` rows that were never added back are **removed from the queue** at that point, including after a Retry batch.
7. **Persistence:** `libraryMatch` and `included` are saved in `<userData>/queue.json` (`saveQueueSoon`, 400 ms debounce, `:69-83`; only `dlStatus`, `dlPercent` and `selected` are stripped) and restored at boot (`:1967-1984`) **without a new library check**.
8. **`addTracksToQueue`** (`:1255-1272`): de-duplicates by `id:<tidalId>`, or `na:<title>|<artist>` when there is no TIDAL ID. A track already in the queue is skipped, not refreshed.
9. Activity-log classifier (`:334`): `/^\s*⏭|📁 Already in library/` styles a line as "skip". The CLI prints `📁 Already in music library: …`, which this pattern does not match (see Bugs).

#### 12. CLI download gate — `tidal_download.js:346-383`
In `downloadTrack`, after `getTrackInfo` (one network call):
1. **Destination check:** unless `--force`, skip if `<outDir>/<sanitize(title)>.flac` or `.m4a` already exists.
2. If `!flags.force && !flags.skipLibraryCheck`: `artistStr = info.artists names joined ', '`; `existing = await lib.findInLibrary(info.title, artistStr, info.duration)`, using the raw (unsanitised) TIDAL title.
3. If the kind is `exact`, log `  📁 Already in music library: <path>` and `     Skipping download (use --force to download anyway)`, then return `{ path: existing.path, skipped: true }`.
4. If the kind is `similar`, log `  ⚠ Similar version in music library: <libraryTitle || path>` and `     Skipping. Use --force or include via GUI to download anyway.`, then return `{ path, skipped: true }`.
- Flags (`:44-67`):
  - `--force` skips **both** checks.
  - `--skip-library-check` skips only the library check. It is not listed in `printHelp()` (`:69-102`).
- A single-track run sets `process.exitCode = 2` when the result has `skipped` set (`:715`).
- Album mode counts skips (`:513`). TIDAL playlist mode (`:649-650`) and Spotify album and playlist modes (`:573-574`, `:614-615`) count a library skip as `downloaded`.
- The library path comes only from the `TIDAL_LIBRARY_FOLDER` environment variable, read when `tidal_lib` loads. One process scans once and reuses the cache for every track.

#### 13. `bulk_runner.js`
- `runDownload` (`:33-47`) spawns `tidal_download.js <trackId> <outDir> --skip-library-check` for every queued track, so **no library check runs during GUI downloads**.
- Child exit code 2 maps to the `skipped` status (`:108`). In the GUI this can only come from the destination-exists check.
- `bulk_runner` loads `tidal_lib` but never scans.

#### 14. Chrome-extension enrichment (inventory only)
`electron-main.js:696-751` (`handleExtensionTracks`) calls `enrichWithLibraryStatus` at `:745`. The renderer adds the result through `addTracksToQueue` (`renderer/app.js:1640-1647`). This will not be ported.

---

### Data formats

**Entry (one row of the in-memory index)** — `tidal_lib.js:730-741`
```text
{
  path:             string   // absolute, from path.join(dir, name)
  fnFull:           string   // normalizeFull(rawBase)        rawBase = filename without extension, original case
  fnTitleFull:      string   // normalizeFull(filenameTitle)  filenameTitle = text after LAST ' - ', else rawBase
  fnCore:           string   // normalizeCore(rawBase)
  fnTitleCore:      string   // normalizeCore(filenameTitle)
  metaTitleFull:    string   // normalizeFull(tag title)      '' if no tag or read failed
  metaTitleCore:    string   // normalizeCore(tag title)
  metaTitleDisplay: string   // raw tag title, or ''
  metaArtist:       string   // normalizeFull(common.artist || common.artists[0] || '')
  metaDuration:     number   // Math.round(format.duration seconds), 0 if unknown; never read
}
```

**Scan cache** — `tidal_lib.js:622-623`
```text
_libraryCache:       null | { entries: Entry[] }
_libraryScanPromise: null | Promise<{ entries: Entry[] }>
```
This lives in process memory only. Each CLI child process has its own cache.

**Match result / queue `libraryMatch`**
```text
null | { kind: 'exact' | 'similar', path: string, libraryTitle: string }
```
`libraryTitle` is the raw tag title for passes 1, 2 and the tag branch of pass 4. It is `path.basename(path)` (filename with its extension) for pass 3 and the filename branch of pass 4.

**Queue item fields used by this feature** (saved in `<userData>/queue.json`, a JSON array, 2-space indented)
```text
{ ..., title, artist, duration, tidalId, notFound?, libraryMatch?: <match result>, included: boolean, key }
```

**settings.json** (`<userData>/settings.json`)
```text
{ downloadFolder?: string, libraryFolder?: string, volume?: number, ... }
```
`libraryFolder` set to `''` or missing means the check is off. `settings:reset` writes exactly `{"downloadFolder":"","libraryFolder":""}`.

**IPC payloads**
| Channel | Direction | Payload / result |
|---|---|---|
| `library:scan-progress` | main → renderer event | `{ done: number, total: number }` |
| `library:scanned` | main → renderer event | `{ count: number }` |
| `library:status` | invoke | → `{ count: number, path: string }` |
| `library:rescan` | invoke | → `{ ok: true, count: number }` |
| `settings:get` / `settings:save` / `settings:reset` / `settings:pick-folder` | invoke | settings object / settings object / `{downloadFolder:'',libraryFolder:''}` / `string \| null` |

Preload bindings (`electron-preload.js:5-9, 61-65`): `getSettings`, `saveSettings`, `resetSettings`, `pickFolder`, `openFolder`, `libraryStatus`, `libraryRescan`, `onLibraryScanned`, `onLibraryScanProgress`.

Progress tick pattern: `(0, total)` once after the walk, then whenever `done - lastReportedAt >= 25`, then `(total, total)`. When the folder is empty or missing, no ticks are sent. An existing folder with no audio sends only `(0, 0)`.

---

### External interfaces

| Interface | Where | Detail |
|---|---|---|
| `music-metadata` 7.14.0 `parseFile` | `tidal_lib.js:661, 723` | Options `{ duration: true, skipCovers: true, skipPostHeaders: true }`. Reads `common.title`, `common.artist`, `common.artists[0]` (fallback) and `format.duration` (seconds, float). |
| Filesystem, read-only | `tidal_lib.js:680, 689, 723` | `fs.existsSync`, recursive `fs.readdirSync(withFileTypes)`; files are opened only by `parseFile`. Nothing is ever written to the library. |
| Env `TIDAL_LIBRARY_FOLDER` | `tidal_lib.js:24`; `electron-main.js:66` | Read once at module load. Main passes `settings.libraryFolder \|\| ''` to children. |
| CLI flags | `tidal_download.js:58, 61, 370`; `bulk_runner.js:35` | `--force`: skips both checks. `--skip-library-check`: skips the library check only. Exit code `2` means a single track was skipped. |
| Exports | `tidal_lib.js:863-868` | `LIBRARY_PATH` (getter), `setLibraryPath`, `scanLibrary`, `rescanLibrary`, `findInLibrary`, `enrichWithLibraryStatus`. The normalisers are not exported. |
| Persisted files | `electron-main.js:26-27` | `settings.json`, `queue.json` in userData (`app.setName('robogears Downloader')`, `:13`). |

---

### Constants and magic values

| Name | Value | Location | Meaning |
|---|---|---|---|
| `LIBRARY_EXTS` | `.flac .m4a .mp3 .wav .aac .ogg .opus .alac` (a Set) | `tidal_lib.js:25` | Indexed extensions, compared after lowercasing `path.extname`. |
| `LIBRARY_PATH` default | `process.env.TIDAL_LIBRARY_FOLDER \|\| ''` | `:24` | No library unless the environment or Settings provides one. |
| Tag-read concurrency | `8` (literal) | `:750` | Number of parallel `parseFile` calls. |
| Progress throttle | `25` files, plus `(0,total)` and the final tick | `:703, :744` | Limits IPC traffic. |
| `parseFile` options | `{ duration: true, skipCovers: true, skipPostHeaders: true }` | `:723` | Tag-read options. |
| Filename separator | `' - '` (space, ASCII hyphen, space), `lastIndexOf`, title = `slice(sepIdx + 3)` | `:717-718` | `Artist - Title` split; the last occurrence wins. |
| Minimum core length | `3` | `:795` | A shorter (or empty) core title never matches. |
| Match kinds | `'exact'`, `'similar'` | `:806-829` | |
| Queue save debounce | `400` ms | `renderer/app.js:82` | |
| Skip exit code | `2` | `tidal_download.js:715`; `bulk_runner.js:108` | |
| DOM ids | `library-input`, `library-browse`, `library-open`, `library-clear`, `library-status`, `library-rescan-btn` | `renderer/index.html:135-142` | |
| Queue classes | `badge dupe`, `badge similar`, `qi-libnote`, `qi-add`, row `excluded` | `renderer/app.js:906, 918-934` | |

Regexes, verbatim:
```text
FULL_STRIP   /[^a-z0-9 ]/g          then /\s+/g -> ' ', trim          (tidal_lib.js:628, 651-652)
BRACKET      /[(\[]/                cut only if index > 0             (tidal_lib.js:642-643)
FEAT         /\s+(feat|ft|featuring)\.?\s+.*$/i                       (tidal_lib.js:645)
VERSION_RE   /\s+-\s+(remix|edit|mix|extended|radio|original|instrumental|acoustic|live|remaster(?:ed)?|version|club|vip|dub|bootleg|rework|reprise|demo|single|album)\b.*$/i
                                                                       (tidal_lib.js:646-649)
LOG_SKIP     /^\s*⏭|📁 Already in library/                            (renderer/app.js:334)
```

User-visible strings:
- Queue badges and notes: `📁 already in library`, `⚠ similar version in library`, `Library: <libraryTitle>`, `+ Add` (tooltip `Add to download list`).
- CLI lines: `  📁 Already in music library: <path>`, `     Skipping download (use --force to download anyway)`, `  ⚠ Similar version in music library: <libraryTitle|path>`, `     Skipping. Use --force or include via GUI to download anyway.`
- Settings status: `…`, `Scanning…`, `Scanning <done> / <total>…`, `<n> file(s) indexed` (singular when n is 1), `<n> files indexed` (after Refresh), `(no library folder set)`, `(scan failed)`, `Scan failed`.
- Activity log: `📁 Music library folder set to: <folder>`, `📁 Music library folder cleared (duplicate check disabled).`, `📁 Library re-scanned: <n> files indexed.`, `⚙ Config reset. Pick a download folder in Settings to continue.`

---

### Rules and invariants

1. The library folder is read-only. Only `existsSync`, `readdirSync` and `parseFile` touch it.
2. `exact` requires all of the following:
   - a non-empty normalised **tag** title equal to the incoming normalised full title;
   - a non-empty incoming artist **and** a non-empty tag artist;
   - one normalised artist string containing the other.
3. A filename-only match is never `exact`. A library with no readable tags never produces `exact`.
4. Pass precedence across **all** entries: exact > tag-title similar > filename similar > core similar. The kind returned never depends on entry order; the reported file does.
5. Duration is never used.
6. If the incoming core title is empty or shorter than 3 characters, the result is `null`.
7. `findInLibrary` returns `null` without scanning when the title is falsy, and after scanning when the index is empty.
8. The cache lasts for the whole process. It is invalidated only by `setLibraryPath` (cache only), `rescanLibrary` (cache and in-flight promise) or a restart. There is no file watching and no on-disk cache.
9. Only one scan should run at a time (`_libraryScanPromise`). Callers that join share its result; only the caller that started it gets progress callbacks.
10. GUI: `included` defaults to `!isExact` on first render. GUI downloads send only `!notFound && included` rows, and the library is never checked again at download time.
11. CLI: without `--force` or `--skip-library-check`, both `exact` and `similar` skip the download.
12. Main rescans automatically only when the saved `libraryFolder` string changes, and at boot only when it is truthy.
13. `libraryMatch` is computed once, at resolve time. It is never recomputed for rows already queued or restored from `queue.json`.

---

### Edge cases and failure modes

**Folder and scan**
- Empty or missing `LIBRARY_PATH`: `{ entries: [] }` is cached, no progress is sent, every lookup returns `null`, and `library:status` returns `{ count: 0, path: '' }`, shown as `(no library folder set)`.
- Path set but the folder is absent, for example an unmounted external or network drive at launch: the empty index is **cached** and stays empty after the drive appears, until Refresh, a folder change or a restart. The status shows `0 files indexed` with no error.
- Path is a file, or permission is denied (including a macOS privacy/TCC refusal): `readdirSync` throws, the error is swallowed, and the status shows `0 files indexed`.
- Folder names ending in a space: `setLibraryPath` trims them, so the path no longer exists and the index is empty.
- Unreadable subfolders are skipped silently. Untaggable files are still indexed by filename.
- Symlinks are skipped (neither followed nor indexed). Windows junctions are probably skipped too (unverified, needs a run).
- Hidden folders are walked, and dotfiles with audio extensions (for example AppleDouble `._x.flac` sidecars on exFAT or SMB volumes) are indexed as filename-only entries, which inflates the count. A file named exactly `.flac` has `extname ''` and is skipped. Upper-case extensions are accepted.
- Files added to the library (including files the user moves in from the download folder) are not seen until the next scan.
- A resolve or import that starts during a scan waits for the whole scan to finish. A short title (core under 3 characters) still waits for, or starts, a full scan before returning `null`.
- When the environment variable `TIDAL_LIBRARY_FOLDER` is set for the Electron process and `settings.json` has no `libraryFolder` key: main uses the environment path, boot does not scan, the first lookup scans it, and `library:status` reports that path while Settings shows none. Download children get `''` from `childEnv`.

**Matching weaknesses** (current behaviour; any change for the port is an owner decision)
- Substring artist test: a very short tag artist (for example `ox`) "agrees" with any incoming artist containing those letters (`boxer collective`), giving a false `exact`.
- Multi-artist strings in a different order or with different separators (`A, B` vs `B; A`) fail the artist test and drop to `similar`.
- Duration is ignored: another recording with the same title by the same artist, tagged without a version suffix, is `exact`.
- Accents: `é` becomes a space. `Café Étoile` does not match `Cafe Etoile`, and NFC and NFD spellings of the same title normalise differently.
- Titles written only in a non-Latin script normalise to `''` and are never matched. Non-Latin annotations disappear from the full key, so `Blue Lantern (Синий)` is `exact` against `Blue Lantern`.
- Version suffixes after an en/em dash, with no space after the hyphen, or not starting with a keyword (`- 2011 Remaster`, a common Spotify style, or `- Remixed by X`) are not stripped. Fullwidth brackets `（ ）` are not cut.
- A title that starts with a bracket keeps all later annotations.
- A plain-word `ft`/`feat`, or a mid-title bracket, truncates the core (`Seven Ft Harbor` → `seven`), causing loose `similar` matches.
- `Artist - Title - Version.ext` filenames take the **version** as the title.
- Track-number prefixes without ` - ` (`01. Title`) stay in the filename title.
- No fuzzy matching: `&` vs `and`, plurals and typos all miss.
- Formats outside `LIBRARY_EXTS` (`.aiff`, `.aif`, `.wma`, `.ape`, `.wv`, `.dsf`, `.mp4`) are invisible.

**GUI flow**
- A `notFound` row that has an `exact` match is not excluded (no + Add) and shows `not found`, but still shows `Library: …`.
- Clearing or changing the library leaves existing queue rows with their old `libraryMatch` and `included` values. When the next batch finishes, rows still excluded are removed from the queue.

**Normaliser worked examples** (input → full | core)
| # | Input | Full | Core |
|---|---|---|---|
| 1 | `Blue Lantern` | `blue lantern` | `blue lantern` |
| 2 | `(Paper) Harbor` | `paper harbor` | `paper harbor` (bracket at index 0, no cut) |
| 3 | `Blue Lantern - Radio Edit` | `blue lantern radio edit` | `blue lantern` |
| 4 | `Blue Lantern (feat. Placeholder Artist)` | `blue lantern feat placeholder artist` | `blue lantern` |
| 5 | `Blue Lantern [Remastered 2011]` | `blue lantern remastered 2011` | `blue lantern` |
| 6 | `Blue Lantern - 2011 Remaster` | `blue lantern 2011 remaster` | same (keyword must follow ` - ` directly) |
| 7 | `Café Étoile` (NFC) | `caf toile` | `caf toile` |
| 8 | `Café Étoile` (NFD, e + U+0301) | `cafe e toile` | `cafe e toile` |
| 9 | `Синий фонарь` / `青い灯籠` | `` | `` |
| 10 | `Blue Lantern ft. Placeholder Artist` | `blue lantern ft placeholder artist` | `blue lantern` |
| 11 | `Blue Lantern – Radio Edit` (en dash) | `blue lantern radio edit` | same (not stripped) |
| 12 | `(Paper) Harbor (Live)` | `paper harbor live` | `paper harbor live` |
| 13 | `Seven Ft Harbor` | `seven ft harbor` | `seven` |
| 14 | `Blue Lantern - Remixed by Placeholder` | `blue lantern remixed by placeholder` | same (`remix\b` fails before `ed`) |
| 15 | `Blue Lantern -Radio Edit` | `blue lantern radio edit` | same |
| 16 | `Go (Placeholder Remix)` | `go placeholder remix` | `go` (lookup returns `null`: shorter than 3) |
| 17 | `Blue Lantern (Синий)` | `blue lantern` | `blue lantern` |
| 18 | `Blue Lantern - Live at Placeholder Hall` | `blue lantern live at placeholder hall` | `blue lantern` |
| 19 | `Blue Lantern (Extended` (no closing bracket) | `blue lantern extended` | `blue lantern` |
| 20 | `Salt & Lantern` vs `Salt and Lantern` | `salt lantern` vs `salt and lantern` | not equal |
| 21 | `␣␣(Paper) Harbor` (two leading spaces) | `paper harbor` | `` (bracket index 2 > 0, so everything is cut) |

**Filename parsing examples**
| File | filenameTitle | fnFull / fnTitleFull / fnCore / fnTitleCore |
|---|---|---|
| `Placeholder Artist - Blue Lantern.flac` | `Blue Lantern` | `placeholder artist blue lantern` / `blue lantern` / `placeholder artist blue lantern` / `blue lantern` |
| `Blue Lantern.flac` | `Blue Lantern` | all `blue lantern` |
| `Placeholder Artist - Blue Lantern - Radio Edit.mp3` | `Radio Edit` | `placeholder artist blue lantern radio edit` / `radio edit` / `placeholder artist blue lantern` / `radio edit` |
| `01 - Blue Lantern.flac` | `Blue Lantern` | fnTitleFull `blue lantern` |
| `01. Blue Lantern.flac` | `01. Blue Lantern` | fnTitleFull `01 blue lantern` |
| `Placeholder Artist – Blue Lantern.flac` (en dash) | whole name | fnTitleFull `placeholder artist blue lantern` |
| `Blue Lantern.FLAC` / `Blue Lantern.aiff` | indexed / not indexed | |

**Match outcome examples.** Library entries used below:
- L1: `Blue Lantern.flac`, tags title `Blue Lantern`, artist `Placeholder Artist`
- L2: `Placeholder Artist - Blue Lantern.mp3`, no readable tags
- L3: tags title `Blue Lantern`, artist empty
- L4: tags title `Blue Lantern`, artist `Ox`
- L5: `Blue Lantern (Live).flac`, title `Blue Lantern (Live)`, artist `Placeholder Artist`
- L6: title `Café Étoile` (NFC), artist `Placeholder Duo`
- L7: title `Синий фонарь`, artist `Placeholder Artist`
- L8: `Placeholder Artist - Blue Lantern - Radio Edit.flac`, no tags
- L9: `Seven.flac`, title `Seven`, artist `Placeholder Artist`
- L10: title `Go`, artist `Placeholder Artist`
- L12: title `Blue Lantern`, artist `Second Guest; Placeholder Artist`
- L13: `01. Blue Lantern.flac`, no tags

| # | Library | Incoming (title, artist) | Result [pass] |
|---|---|---|---|
| 1 | L1 | `Blue Lantern`, `Placeholder Artist` | exact [1] |
| 2 | L1 | `Blue Lantern`, `Placeholder Artist, Second Guest` | exact [1] (incoming contains tag artist) |
| 3 | L1 | `Blue Lantern`, `Other Band` | similar [2] |
| 4 | L1 | `Blue Lantern`, `` | similar [2] |
| 5 | L1 | `Blue Lantern - Radio Edit`, `Placeholder Artist` | similar [4] |
| 6 | L1 | `Blue Lantern - 2011 Remaster`, any | null |
| 7 | L1 | `Blue Lanterns`, any | null |
| 8 | L1 | `Blue Lantern (Синий)`, `Placeholder Artist` | exact [1] |
| 9 | L2 | `Blue Lantern`, any | similar [3], libraryTitle `Placeholder Artist - Blue Lantern.mp3` |
| 10 | L3 | `Blue Lantern`, `Placeholder Artist` | similar [2] |
| 11 | L4 | `Blue Lantern`, `Boxer Collective` | **exact [1], false positive** |
| 12 | L5 | `Blue Lantern`, `Placeholder Artist` | similar [4] |
| 13 | L5 | `Blue Lantern (Live)`, `Placeholder Artist` | exact [1] |
| 14 | L6 | `Cafe Etoile`, `Placeholder Duo` | null |
| 15 | L7 | `Синий фонарь`, any | null (empty core) |
| 16 | L8 | `Blue Lantern`, any | null |
| 17 | L8 | `Radio Edit`, `Anyone Else` | **similar [3], false positive** |
| 18 | L9 | `Seven Ft Harbor`, `Different Artist` | **similar [4], false positive** |
| 19 | L10 | `Go`, `Placeholder Artist` | null (core shorter than 3) |
| 20 | L12 | `Blue Lantern`, `Placeholder Artist` | exact [1] |
| 21 | L12 | `Blue Lantern`, `Placeholder Artist, Second Guest` | similar [2] |
| 22 | L13 | `Blue Lantern`, any | null |
| 23 | L1 + L2 | `Blue Lantern`, `Placeholder Artist` | exact, L1's path |
| 24 | L1 + L3 | `Blue Lantern`, `Other Band` | similar; the path is whichever finished parsing first |
| 25 | any | title `''` / `null` | null, no scan |

---

### Bugs and oddities

| Severity | Issue | Evidence |
|---|---|---|
| **Medium** | **Changing, clearing or resetting the library folder while a scan is running leaves the old folder's results in the cache.** `setLibraryPath` nulls `_libraryCache` but not `_libraryScanPromise`, so `saveSettings`' new `scanLibrary()` call joins the old scan. When the old scan finishes, its starting caller stores the **old** folder's entries, and `library:scanned` reports the old count. `library:status` then returns the old count with the new path. Rows are judged against the old (or cleared) folder until Refresh or a restart. Wrongly excluded rows are then dropped from the queue when the next batch finishes. | `tidal_lib.js:28-31, 676, 754-755`; `electron-main.js:42-52, 471-485, 561-565` |
| Low | **A rescan during a running scan lets the older scan overwrite the cache and clear the newer scan's promise.** After `rescanLibrary`, scan B starts. When the older scan A ends, its continuation sets the cache to A and `_libraryScanPromise = null` while B runs, so callers get A until B ends. A further invalidation in that window can start a third concurrent scan. Everything is consistent again once the last scan finishes. | `tidal_lib.js:754-755, 760-763`; `electron-main.js:582-587` |
| Low | **Excluded "already in library" rows silently leave the queue after any batch** (Download all or Retry). The post-batch filter keeps only `(!t.dlStatus && t.included)` among untouched rows, and its comment does not mention excluded rows. | `renderer/app.js:1467-1473` |
| Low | **Saved `libraryMatch` goes stale.** It is restored from `queue.json` and never re-checked after a rescan or a folder change. Adding the same track again does not refresh it. | `renderer/app.js:69-83, 901, 1255-1263, 1967-1984` |
| Low | **The main process blocks during the synchronous walk** (and during the whole scan if `music-metadata` failed to load). Tag parsing also runs on the main process. | `tidal_lib.js:687-700, 721-750` |
| Low | **Non-deterministic reported file.** Entries are stored in parse-completion order, so `path` and `libraryTitle` can differ between scans when several files qualify. The kind is unaffected. | `tidal_lib.js:711-750, 804-831` |
| Low | **Hidden files and AppleDouble `._*` sidecars are indexed** and counted. | `tidal_lib.js:691-697` |
| Low | **Questionable extension list:** `.alac` is listed although ALAC normally lives in `.m4a`, while `.aiff`, `.aif`, `.wma`, `.ape`, `.wv` and `.dsf` are missing. | `tidal_lib.js:25` |
| Low | **Duration is parsed but never used.** `duration: true` may make `music-metadata` read more of some files (per its documentation; not checked against installed source), and `_duration` is ignored. | `tidal_lib.js:723, 726, 740, 788` |
| Low (theoretical) | **A rejected scan promise sticks.** If the scan function rejected, `:754` would throw before `:755`, and every later call would reject until `rescanLibrary()`; `setLibraryPath` does not clear it. In practice every inner error is caught. | `tidal_lib.js:754-755, 28-31` |
| Info | **CLI and GUI treat `similar` differently:** the CLI skips it, the GUI includes it by default. | `tidal_download.js:378-382` vs `renderer/app.js:901` |
| Info | **CLI summaries count library skips as downloaded** in TIDAL playlist and Spotify album/playlist modes. | `tidal_download.js:573-574, 614-615, 649-650` |
| Info | **`--skip-library-check` is missing from `--help`.** | `tidal_download.js:61` vs `:69-102` |
| Info | **The log "skip" styling pattern `📁 Already in library` never matches** the CLI text `📁 Already in music library:`. In the GUI that line is never printed anyway. | `renderer/app.js:334` vs `tidal_download.js:374` |
| Info | **The folder picker always opens at the download folder**, even when choosing the library. | `electron-main.js:567-573` |
| Info | **Reset config drops every other settings key** (for example the preview `volume`). | `electron-main.js:561-565` |
| Info | **Dead code:** `normalizeForMatch` (not exported, never called). The basename fallbacks in passes 1, 2 and the tag branch of pass 4 can never run. | `tidal_lib.js:655-656, 806, 813, 826` |
| Info | **Environment path not trimmed; Settings path trimmed** (this trim breaks folder names ending in a space). | `tidal_lib.js:24` vs `:29` |
| Info | **Stale comments and docs.** `tidal_lib.js:18-23` says a matching title skips the download (CLI only). CLAUDE.md describes "four normalized title forms" (six exist) and a match order without the tag-title-only `similar` pass. | `tidal_lib.js:18-23`; CLAUDE.md "Library deduplication system" |

---

### Platform-specific behaviour

- **Unicode forms:** macOS HFS+ stores filenames decomposed (NFD). APFS keeps the form the name was created with, and NTFS is usually NFC. Because the normaliser works per UTF-16 code unit, an NFD filename and an NFC tag or TIDAL title normalise differently.
- **AppleDouble sidecars** (`._name.ext`) on exFAT, FAT and SMB volumes are indexed.
- **macOS privacy (TCC):** reading `~/Music`, `~/Documents`, `~/Desktop`, `~/Downloads`, removable or network volumes can trigger a permission prompt. A refusal makes `readdirSync` fail silently, leaving 0 files.
- **Symlinks** (macOS/Linux) are skipped. Windows junctions are probably skipped (unverified).
- **Paths:** `path.join` and `path.basename` follow the host platform. CLAUDE.md mentions a Windows `Z:\…` library path.
- **userData:** `%APPDATA%\robogears Downloader` (Windows) or `~/Library/Application Support/robogears Downloader` (macOS) holds `settings.json` and `queue.json`.
- **Cloud folders** (Dropbox, iCloud): `parseFile` opens every file. Whether this downloads cloud-only placeholders is unverified (needs a run).

---

### Porting notes for a native Swift macOS app

| Topic | Today | Swift approach | Difficulty |
|---|---|---|---|
| Folder walk | Sync recursive `readdirSync`; keeps directory and regular-file entries only (symlinks skipped); no hidden filter; unreadable folders skipped; lowercased `extname` in an 8-item set | `FileManager.enumerator(at:includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey], options: [])` (no `.skipsHiddenFiles` if today's behaviour is kept), an `errorHandler` returning `true`, skip symlinks. Match Node's `extname` rules: `.flac` → no extension, `._x.flac` → `.flac`. Run off the main actor. | Easy |
| Tag reading | `music-metadata` 7.14.0: `common.title`, `common.artist` → `common.artists[0]`, `format.duration`; FLAC Vorbis comments, MP4 atoms, ID3v2, WAV, Ogg, Opus | AVFoundation covers M4A/MP3/WAV/AAC, but FLAC Vorbis comments and Ogg/Opus are weak or missing. Full parity likely needs TagLib (C++ bridge), SFBAudioEngine, or small hand-written FLAC and Ogg parsers. Decide whether trailing ID3v1 tags count; `skipPostHeaders: true` reportedly ignores them. Duration can be skipped unless the matcher starts using it. | Hard |
| Normaliser parity | JS `toLowerCase()`, then regexes without the `u` flag over UTF-16 code units; JS `\s` set; ASCII `\b` | Lowercase with `lowercased()`, then map over `unicodeScalars` (not `Character`s: a decomposed `é` is one Character and would vanish whole, unlike today). Compare the produced ASCII keys byte for byte; Swift `==` uses canonical equivalence and JS `===` does not. Use an explicit whitespace class equal to JS `\s` (ICU `\s` differs, for example on U+FEFF and U+0085). Use an ASCII-only boundary such as `(?![a-z0-9_])` instead of ICU's Unicode `\b`. Turn the worked-example tables above into unit tests. | Medium |
| Core regexes | Bracket search (cut only if index > 0), FEAT, VERSION_RE | Swift `Regex` or `NSRegularExpression`; keep left-most-match semantics and the "index > 0" rule on the raw lowercased string. | Easy |
| Cache and invalidation | Module globals plus a single in-flight promise; has the races above | An `actor LibraryIndex` holding the entries, the current `Task`, and a generation counter or folder stamp. A folder change cancels the old task and drops any result whose generation is stale. | Easy |
| Parallel parse and progress | 8 workers; ticks at 0, every 25, and the end | `TaskGroup` capped at 8 children. Progress through an `AsyncStream` or a `@MainActor` callback using the same pattern. Sorting entries by path would make the reported file deterministic (an owner decision). | Easy |
| Lookup speed | 4 linear passes per track; enrichment is sequential | Optional: build dictionaries from each normalised key to an ordered list of entries, keeping pass precedence and "first entry wins". | Easy |
| Settings and folder access | Plain path string; `openDirectory` dialog; rescan only when the value changes | `NSOpenPanel` (`canChooseDirectories`). If sandboxed, store a security-scoped bookmark and wrap each scan in `startAccessingSecurityScopedResource`. Keep "clear means the check is off". Consider rescanning when a volume mounts, or offering a rescan when the folder is missing. | Medium |
| GUI/CLI gate | GUI: queue is the only gate (`--skip-library-check`). CLI: exact or similar means skip, exit code 2 | In-process downloads; pass a `skipLibraryCheck` flag as a parameter. Decide whether any "skip on similar" path is still needed. | Easy |
| Queue persistence | `queue.json` holds `libraryMatch` and `included`; never re-checked | `Codable` queue item with an optional `libraryMatch` and `included`. Re-matching after restore or a library change, and keeping excluded rows after a batch, are behaviour changes for the owner to approve. | Easy |
| UI state | IPC `library:status`, `library:rescan`, `library:scanned`, `library:scan-progress` | An `@Observable` library service (count, scanning progress, path, last error) bound directly to Settings. | Easy |
| Cloud placeholders | Every file is opened | If the folder is a File Provider location, check `URLResourceValues` (for example `ubiquitousItemDownloadingStatus`) and decide whether to index placeholders by filename only. | Medium |

---

### Open questions

1. What does `music-metadata` 7.14.0 put in `common.artist` when a file has several artist tags (joined with `/` or `, `, or only the first)? This affects the substring artist test. Unverified (needs a run; `node_modules` is not present).
2. Does `skipPostHeaders: true` leave MP3s that have only ID3v1 tags with no title or artist, so they can only match by filename? Unverified (needs a run).
3. How much scan time does `duration: true` add for MP3s without a VBR header? The documented figure of about 18 s for about 500 files is unverified.
4. Which Unicode form (NFC or NFD) do the owner's library filenames and tags use? This decides whether accented titles match today.
5. Does reading tags in a Dropbox or iCloud library force cloud-only files to download? Unverified (needs a run).
6. Does TIDAL's track object carry version text (for example a remix or edit label) in a field separate from `title`? The code reads only `title`, so a TIDAL "Radio Edit" might compare as the bare title and match the original as `exact`. This needs a sample API response.
7. Owner decisions for the port:
   - CLI rule (skip `similar`) or GUI rule (include `similar`)?
   - Should duration count towards `exact`?
   - Should the artist test become token-based?
   - Should accents be folded (`é` → `e`)?
   - Should hidden and AppleDouble files and the extra formats be indexed?
   - Should excluded rows survive a batch?
8. Are the boot `library:scan-progress` and `library:scanned` events ever sent before the renderer registers its listeners? This is not user-visible, because opening Settings refreshes the status. Unverified (needs a run).
