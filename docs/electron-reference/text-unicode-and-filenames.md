## Gap: Cross-platform text, Unicode, filesystem and localisation semantics

Source of truth: the code at v0.1.30. Read in full: `tidal_lib.js`, `tidal_download.js`, `tidal_search.js`, `renderer/app.js`, `renderer/index.html` and `bulk_runner.js`. Also read: the relevant parts of `electron-main.js` and `renderer/styles.css`. Nothing was run. **"Unverified (needs a run)"** marks any claim that depends on runtime, OS or library behaviour the source cannot settle. `node_modules/` is not present in this checkout, so library internals (music-metadata, Node's HTTP client) are described from their documented behaviour and marked unverified.

Other sections cover some of this in more depth. This section stands alone, but these give more detail: `library-matcher.md` (normaliser worked examples), `tidal-api.md` (TIDAL match scorer), `renderer-flows.md` (import flow) and `download-pipeline.md` (download path).

All items in the coverage brief were checked against the code and all exist. One correction: `URL_RE` does **not** label `spotify:` URIs as links (see §9). Several items found while reading were added: §5 (per-chunk UTF-8 decoding), the bare-number search bug in §9, the CSV column-order bug in §6, the token expiry during long imports in §8, the unused duration read in §3, and §10 (the CLI default folder on macOS).

---

### 1. Output filenames: `sanitize`

**Code** (`tidal_lib.js:615-618`), verbatim:

```js
/** Strip characters illegal in Windows/macOS/Linux filenames. */
function sanitize(str) {
    return (str || 'unknown').replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim();
}
```

**Steps**
1. If `str` is falsy (`undefined`, `null`, `''`), use `'unknown'`. A whitespace-only string is truthy, so it is **not** replaced.
2. Replace each of the nine characters `\ / : * ? " < > |` with `_`.
3. Replace each run of JavaScript `\s` with one ASCII space. In JS, `\s` covers U+0009–U+000D, U+0020, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF. Tabs, newlines, no-break spaces and the ideographic space U+3000 (common in Japanese titles) therefore become a plain space. U+0085 (NEL), U+200B (zero-width space) and the other C0/C1 controls are not in `\s` and are kept.
4. Trim the same `\s` set from both ends.

**Where the result goes** (`tidal_download.js`)
- `:351-353`: `artist`, `title` and `album` are each passed through `sanitize`. Only `title` reaches the filesystem. `artist` and `album` appear only in the log line at `:385`.
- `:355-356`: ``flacPath = path.join(outDir, `${title}.flac`)`` and ``m4aPath = path.join(outDir, `${title}.m4a`)``.
- `:426-428`: ``finalPath = path.join(outDir, `${title}.${finalExt}`)`` and ``tmpPath = path.join(outDir, `${title}.tmp.${tmpExt}`)``.

**What it does not handle** (verified by reading; no other filename code exists):

| Case | Example title | File produced | Effect |
|---|---|---|---|
| Leading dot | `...Baby One More Time` | `...Baby One More Time.flac` | A hidden file on macOS (Finder and `ls` hide it) |
| Whitespace-only | `"   "` | `.flac` (temp file `.tmp.flac`) | A hidden file named only by its extension |
| Control characters outside `\s` | U+0001, U+001F, U+007F, U+0085 | Kept in the name | Legal on APFS but odd in Finder. A U+0000 makes Node refuse the path (unverified, needs a run) |
| Windows reserved device names | `Con`, `NUL`, `COM1` | `Con.flac` | A problem on Windows only. Irrelevant to a macOS-only port, except perhaps when writing to an SMB share served by Windows (unverified) |
| Length | A long classical title, or a CJK title (3 UTF-8 bytes per character) | No cap | macOS limits a name to about 255 bytes (APFS counts UTF-8 bytes; check `pathconf(_PC_NAME_MAX)`, unverified). The temp name is 4 characters longer (`.tmp`). An over-long name makes the write fail (`ENAMETOOLONG`), so the track fails |
| Titles that sanitise to the same name | `AC/DC`, `AC:DC`, `AC_DC` | All become `AC_DC.flac` | Collision, see §2 |
| Unicode normalisation | `Beyoncé` as NFC vs NFD | Written in whatever form TIDAL's JSON carries | No `String.prototype.normalize` call exists in any file. A grep finds only local helper functions named `normalize` (`bulk_runner.js:11`, `electron-main.js:712, 944`) |

On macOS the `/` and `:` replacements matter too: `/` is the POSIX path separator, and Finder shows `:` in a name as `/`.

**Porting notes**
- Put this in one pure function (for example `fileName(title:ext:)`) and turn the table into unit tests.
- For exact parity: replace the same nine characters; collapse and trim an **explicitly defined** set equal to JS `\s`; fall back to `unknown` only for an empty or missing title. Swift's `CharacterSet.whitespacesAndNewlines` is not the same set: it includes U+0085 and excludes U+FEFF.
- Owner decisions: strip a leading `.`; turn a whitespace-only title into `unknown`; drop control characters; cap the name below 255 UTF-8 bytes minus the longest suffix, cutting on a grapheme boundary; normalise to NFC.
- APFS keeps names in the form they were written and, on macOS 10.13+ volumes, treats NFC and NFD spellings as the same name. This is unverified for exFAT and SMB. Foundation may also convert names to decomposed form when it writes them (unverified on current macOS, needs a run). Pick one form explicitly so files written by the Electron app and by the Swift app agree.

---

### 2. Name collisions in the download folder

Mandatory rule 3 makes the filename the title alone. Any two tracks whose sanitised titles collide therefore share one file, whoever the artist is. The existence check is at `tidal_download.js:358-366`:

```js
if (!flags.force && fs.existsSync(flacPath)) {
    console.log(`  ⏭  ${title}.flac already in downloads folder — skipping (use --force to overwrite)`);
    return { path: flacPath, skipped: true };
}
if (!flags.force && fs.existsSync(m4aPath)) {
    console.log(`  ⏭  ${title}.m4a already in downloads folder — skipping (use --force to overwrite)`);
    return { path: m4aPath, skipped: true };
}
```

**What happens to the second of two colliding tracks** (for example `Intro`, then `INTRO`):
1. `fs.existsSync` asks the filesystem. On case-insensitive volumes (the APFS and HFS+ defaults, and NTFS), `INTRO.flac` finds `Intro.flac`. On a case-sensitive APFS volume it does not, so both files are written.
2. The log line reads `⏭  INTRO.flac already in downloads folder — skipping (use --force to overwrite)`. It prints the **new** title, not the name of the file that was found.
3. `downloadTrack` returns `{ skipped: true }`, and `main()` sets `process.exitCode = 2` (`tidal_download.js:715`).
4. `bulk_runner` maps exit code 2 to `skipped` and prints `__TRACK_DONE__:<id>:skipped` (`bulk_runner.js:105-110`).
5. The row shows the `⏭ skipped` badge (`app.js:915`). When the batch ends, `onDownloadDone` keeps only not-found, failed and untouched rows (`app.js:1468-1473`). The skipped track leaves the queue even though nothing was downloaded for it.

**Other ways two tracks collide:** a `.flac` and a `.m4a` with the same title (each check looks at both extensions); different songs with the same title by different artists; titles made equal by `sanitize` (§1); and NFC and NFD spellings of the same title on volumes that ignore normalisation.

**Bug (Medium):** a requested track is silently not downloaded. The log calls it "already in downloads folder" even when it is a different recording, and its row disappears when the batch ends (`tidal_download.js:355-366`, `app.js:1468-1473`).

**Porting notes**
- Keep the check before any network call, as today.
- Make the collision policy explicit. Today it is "skip". Alternatives are suffixing ` (2)` or naming files `Title - Artist`. Both change rule 3, so ask the owner first.
- Don't assume case sensitivity. Either keep asking the filesystem (`FileManager.fileExists(atPath:)`), or read `URLResourceValues.volumeSupportsCaseSensitiveNames` for the folder and compare names the same way.
- In the skip message, name the existing file that caused the skip.

---

### 3. Library folder walk: links, aliases, sidecars, hidden folders, cloud placeholders

**Code** (`tidal_lib.js:686-700`), verbatim:

```js
const files = [];
const walk = (dir) => {
    let dirents;
    try { dirents = fs.readdirSync(dir, { withFileTypes: true }); }
    catch { return; }
    for (const ent of dirents) {
        const full = path.join(dir, ent.name);
        if (ent.isDirectory()) walk(full);
        else if (ent.isFile()) {
            const ext = path.extname(ent.name).toLowerCase();
            if (LIBRARY_EXTS.has(ext)) files.push({ full, name: ent.name, ext });
        }
    }
};
walk(LIBRARY_PATH);
```

`LIBRARY_EXTS` (`tidal_lib.js:25`) is `.flac .m4a .mp3 .wav .aac .ogg .opus .alac`.

**Behaviour**
- A `Dirent` from `readdir(..., {withFileTypes: true})` describes the entry itself, not its target (lstat semantics). A symlink reports `isSymbolicLink()`, and both `isDirectory()` and `isFile()` return false. Symlinked folders and files are therefore skipped silently: they are not counted and nothing is logged. Because links are never followed, no cycle protection is needed today.
- **Finder aliases** are regular files holding bookmark data. The default alias name is `<name> alias`, whose `extname` (`.flac alias`) is not in the set, so aliases are skipped. An alias renamed to end in `.flac` would be indexed as a filename-only entry, because its tag read fails.
- **Unreadable folders** make `readdirSync` throw and are skipped silently. Examples: `.Spotlight-V100`, `.fseventsd`, and `.Trashes` at a volume root (whose permissions deny listing).
- **There is no hidden-file filter.** Folders whose names start with a dot are walked. Examples: `~/.Trash` if the library folder is the home folder, or `.dropbox.cache` if it is a Dropbox root (unverified whether that folder still exists in the File Provider era). Audio files inside such folders count as library contents and can mark a queue track as `exact` or `similar`.
- **Packages and bundles** (such as `.musiclibrary` or `.band`) are ordinary directories to Node, so the walk goes inside them.
- Extension matching ignores case (`.FLAC` matches). `path.extname('.flac')` is `''`, so a file named exactly `.flac` is skipped. `path.extname('._Song.flac')` is `.flac`, so AppleDouble files pass the filter.
- The walk is synchronous and runs on the Electron main process.

**AppleDouble sidecars** (`._Name.flac`). macOS writes these on exFAT, FAT and many SMB volumes to hold extended attributes.
1. They pass the extension filter.
2. `mm.parseFile` on the small AppleDouble blob is expected to throw (unverified). The `catch` at `:727` leaves `metaTitle` and `metaArtist` as `''` and `metaDuration` as `0`.
3. Filename keys: `rawBase` is `._Name` (`:716`). There is no `' - '`, so `filenameTitle` is also `._Name` (`:717-718`). `normalizeFullForMatch('._Name')` gives `name`, because dots become spaces and are trimmed. The sidecar therefore has the same filename keys as the real `Name.flac`.
4. Effects:
   - The `N files indexed` count (`app.js:1680, 1688`) roughly doubles on such volumes.
   - Filename matches (steps 3 and 4 of `findInLibrary`) may report the sidecar's path. Entries are pushed in the order their metadata reads finish (`tidal_lib.js:730`), so whichever finished first wins. That path appears in the badge tooltip and the `Library:` note (`app.js:918-919, 928-930`).
   - An orphaned sidecar, left behind when the real file was deleted on another OS, keeps producing `similar` matches for a song no longer in the library.
   - When the real file exists and has tags, its tag match (steps 1–2, run over all entries first) wins, so the sidecar does not change the match kind.

**Metadata read** (`tidal_lib.js:723`), verbatim: `await mm.parseFile(full, { duration: true, skipCovers: true, skipPostHeaders: true })`, run by 8 workers (`:750`). Dependency: `"music-metadata": "^7.14.0"` (`package.json`).
- **Wasted work (code-shown):** `metaDuration` is stored (`:726, 740`) but never read. `findInLibrary(title, artist, _duration)` ignores its third argument (`:788`), and a grep finds no other reader. Asking for `duration: true` costs I/O for nothing.
- Unverified (needs a run): with `duration: true`, MP3 files that lack a Xing/VBRI/LAME header may be read to the end to count frames (per music-metadata's documented behaviour).
- Unverified (needs a run): opening a Dropbox or iCloud "online-only" (dataless) file to read its tags is expected to make the File Provider download it. A full scan of an online-only library could download the whole library.

**Porting notes**
- `FileManager.enumerator(at:includingPropertiesForKeys:options:errorHandler:)` does not descend into symlinked folders and reports links through `.isSymbolicLinkKey`. With no options it includes hidden files and descends into packages, which matches today's behaviour. `.skipsHiddenFiles` (which drops AppleDouble files and dot-folders) and `.skipsPackageDescendants` would be fixes; that is an owner decision, also raised in `library-matcher.md`. Return `true` from `errorHandler` to keep walking past unreadable folders.
- Before opening a file for tags, check whether it is dataless and treat it as filename-only (or skip it). Possible signals: the `SF_DATALESS` bit in `stat.st_flags` (check the constant in `<sys/stat.h>`) and `URLResourceKey.ubiquitousItemDownloadingStatusKey`. Which signal Dropbox exposes is unverified. The owner's `check-for-dupes` and `teedaa` skills already detect placeholders without downloading them; reuse that approach.
- Don't request the duration until something uses it. Read title and artist only (AVFoundation metadata, or a FLAC/ID3 tag reader), off the main actor.

---

### 4. Text normalisation for matching (ASCII-only) and its Unicode effects

Every matcher lowercases the text, then replaces each UTF-16 code unit outside `[a-z0-9 ]` with a space, collapses whitespace and trims:
- `normalizeFullForMatch` (`tidal_lib.js:626-629`) and `normalizeCoreForMatch` (`:635-653`, which first strips suffixes): the library matcher.
- `norm` in `spotifyTrackToTidal` (`tidal_lib.js:580`): Spotify-to-TIDAL matching.
- `normalize` in `resolve:tracklist` (`electron-main.js:944`): CSV and text import. Also at `:712` (extension bridge, being removed).
- `normalize` in `bulk_runner.js:11`: matching of id-less items.

JS `toLowerCase()` uses the locale-independent Unicode case mapping, and so does Swift `lowercased()`. Up to that step the two agree.

| Input | Form | Normalised result |
|---|---|---|
| `Beyoncé` | NFC (`é` = U+00E9) | `beyonc` |
| `Beyoncé` | NFD (`e` + U+0301) | `beyonce` |
| `Björk` | NFC | `bj rk` |
| `Björk` | NFD | `bjo rk` |
| `Mötley Crüe` | NFC | `m tley cr e` |
| `東京` | — | `''` |

**Consequences** (code-shown):
- The same title in NFC and in NFD does not compare equal. macOS HFS+ stored names in NFD, while APFS keeps the form the name was written in. A filename-based library match can therefore fail where a tag-based match succeeds, or the other way round.
- The library matcher refuses titles whose core form is shorter than 3 characters (`tidal_lib.js:795`). A fully non-Latin title normalises to `''` and is never matched against the library.
- TIDAL scorers (`tidal_lib.js:587-594`, `electron-main.js:951-956`, `bulk_runner.js:20-26`): an empty wanted title scores 100 against any TIDAL result whose title also normalises to `''`. That result is accepted without any artist check, so the first such result wins even if it is a different song.
- Artist tokens shorter than 3 characters are dropped (`:592`, `:954`). `Björk` (NFC) gives the tokens `bj` and `rk`, both dropped, so the artist score is always 0. Only an exact title match can then be accepted.

**Porting notes**
- For exact parity, walk `unicodeScalars`, not `Character`s. A decomposed `é` is one Swift `Character` but two JS code units, and JS keeps the `e`. Compare the resulting ASCII keys byte for byte. `library-matcher.md` and `tidal-api.md` give the full parity recipe.
- Raw-string comparisons differ between the languages. JS `===` compares UTF-16 code units; Swift `==` and `Set<String>` use canonical equivalence, so NFC `é` == NFD `é` in Swift. This affects the import de-duplication key ``${title.toLowerCase()}|${artist.toLowerCase()}`` (`app.js:1913, 1933`) and the queue de-duplication key ``na:${title}|${artist}`` (`app.js:1257-1260`): Swift would merge strings that JS keeps apart. For parity, compare `Array(s.utf16)`.
- Length checks also differ. These count UTF-16 code units in JS: `text.length < 10` (paste, `app.js:1804`), `title.length < 2` (`app.js:1932`), `tCore.length < 3` (`tidal_lib.js:795`) and `t.length > 2` (`:592`, `electron-main.js:954`, `bulk_runner.js:24`). A one-emoji title such as `🔥` has JS length 2 (kept) but Swift `count` 1 (dropped). Use `utf16.count` for parity.
- Folding diacritics (`folding(options: .diacriticInsensitive, locale: nil)`) and keeping non-Latin letters would fix most of the above, but would change match results. That is an owner decision.

---

### 5. Bytes to text: per-chunk UTF-8 decoding of network and child-process streams

**Code-shown bug (Low; how often it bites is unverified):** several places turn each incoming `Buffer` chunk into a string separately. A multi-byte UTF-8 character split across two chunks then decodes as U+FFFD replacement characters on both sides of the split.

| Site | Code (verbatim) | What it carries |
|---|---|---|
| `tidal_lib.js:144-146` | `let d = ''; res.on('data', c => d += c); res.on('end', () => resolve({ status: res.statusCode, body: d }));` | **Every** TIDAL API response (`tidalGet`), the token refresh, and the Spotify embed HTML (`fetchSpotifyEmbed`, `:474-481`) |
| `electron-main.js:1022-1027` | `let buf = ''; stream.on('data', d => { buf += d.toString(); const lines = buf.split(/\r?\n/); buf = lines.pop(); ... })` | Download child stdout and stderr, which become activity-log lines |
| `electron-main.js:127-128` | `let data = ''; res.on('data', d => data += d);` | GitHub release JSON (only the tag and asset names are used, so harmless; see `build-updater.md`) |
| `tidal_download.js:265` | `p.stderr.on('data', d => stderr += d.toString());` | FFmpeg error text; `stderr.slice(-500)` (`:267`) can also cut a UTF-16 surrogate pair in half |

`string + Buffer` calls `Buffer.toString()`, which decodes UTF-8 one chunk at a time. `JSON.parse` still succeeds, because multi-byte characters only occur inside string values. The damage lands in titles and artist names.
- **Most exposed:** large bodies split into several chunks, namely 100-item album and playlist pages, search results, and the Spotify embed HTML. A single-track info response is probably one chunk (unverified, needs a run).
- **Effects:** corrupted titles and artists in the queue and in matching. If the per-track `getTrackInfo` response (`tidal_download.js:350`) is hit, the corruption reaches the tags and the filename.
- **Log lines:** the `__TRACK_*__` markers are pure ASCII, so they parse correctly. The log's colour classes key off leading multi-byte glyphs (`✓`, `⏭`, `⚠`, `ℹ`, `app.js:330-340`), so a split glyph loses the line's colour.

**Not affected:** `fetchBuffer` (it concatenates whole Buffers, `tidal_lib.js:217-219`), manifest decoding (whole buffer, `tidal_download.js:110`), and JSON files read whole with `'utf8'`.

**Porting notes:** `URLSession` hands back complete `Data`; decode JSON from the whole `Data` with `JSONDecoder`. If any line-based child-process output survives the port, split the bytes on 0x0A before decoding (or use `FileHandle.bytes.lines`).

---

### 6. Imported tracklist text: decoding, line endings, delimiters, headers

**Decoding.** File drop: `const text = await file.text();` (`app.js:1777`). File picker: the same call (`app.js:1788`). The picker is restricted by `accept=".csv,.txt,text/csv,text/plain"` (`index.html:53`). Drag-and-drop has no type or size check, so any dropped file is decoded as text. Paste: `e.clipboardData?.getData('text/plain')` (`app.js:1803`) arrives as a string, so no decoding happens.
- `Blob.text()` always decodes as UTF-8 (WHATWG "UTF-8 decode"). It strips a leading UTF-8 BOM and replaces invalid bytes with U+FFFD. It does **not** detect UTF-16 BOMs.
  - **Windows-1252** files (for example Excel's "CSV (Comma delimited)" on a Western-locale Windows; general knowledge, unverified here): every byte ≥ 0x80, such as `é` = 0xE9, becomes U+FFFD.
  - **UTF-16LE** files: the BOM becomes `U+FFFD U+FFFD`, and every ASCII character is followed by U+0000. Header detection then fails, and the plain-text fallback produces titles full of NULs. Music.app's "Unicode Text" playlist export is believed to be UTF-16 and tab-separated (general knowledge, unverified), which matters for a Mac user.
- JS `String.prototype.trim()` and regex `\s` both include U+FEFF. A stray BOM is therefore removed by the per-line `trim()` (`app.js:1924`) and the per-header and per-field `trim()` (`:1902, 1910-1911`).

**Line endings.** `looksLikeCsv` and the plain-text parser split on `/\r?\n/` (`app.js:1872-1873, 1924`). `parseCsv` drops every `\r` outside quotes and breaks rows only on `\n` (`:1890-1891`). Inside quotes it keeps every character, including `\r\n`. A classic-Mac file with CR-only line endings becomes one line and one CSV row. It therefore fails CSV detection and turns into a single junk "track" (JS `.` stops at `\r`, so the separator regex fails).

**CSV detection** (`app.js:1870-1874`): the first non-empty line must contain `,`, and `text.split(/\r?\n/).length >= 2`.
- Excel writes semicolon-separated CSVs in locales whose decimal separator is a comma (de, fr, nl…; general knowledge, unverified). Those files fail this test and go to the plain-text parser, where `;` is not a separator. Each whole line becomes a title.

**Header detection** (`app.js:1899-1905`), verbatim:

```js
const header = rows[0].map(h => (h || '').toLowerCase().trim());
const titleIdx = header.findIndex(h => /\btrack name\b|\btitle\b|\bsong\b|\bname\b/.test(h));
const artistIdx = header.findIndex(h => /artist/.test(h));
if (titleIdx < 0) return [];
```

- **The patterns are English only**, and `\b` is an ASCII word boundary. `titel`, `titre`, `título` and `曲名` don't match. A header such as `Titel,Künstler` gets `titleIdx = -1`, so the CSV parser returns `[]` and the **whole file, header line included,** goes through the plain-text parser. `Titel,Künstler` itself becomes a "track".
  - Oddly, `/artist/` matches French `artiste` and Spanish/Italian/Portuguese `artista` as substrings. That doesn't help, because title detection has already failed.
- **Column-order bug (Low, code-shown):** `findIndex` returns the *first* header that matches any title pattern, and `\bname\b` also matches `artist name`, `album name` and `playlist name`. A header `Artist Name,Track Name` gives `titleIdx = 0` and `artistIdx = 0`, so every row's title and artist are both the artist. Exportify works only because `Track Name` comes before the other `… Name` columns (column order from general knowledge, unverified).
- **A CSV with no header row:** the first data row is read as the header. With no title column found, the file falls to the plain-text path. A line such as `Bohemian Rhapsody,Queen` has no separator character, so it becomes the title `Bohemian Rhapsody,Queen` with an empty artist. The import scorer (`electron-main.js:944-958`) then gives a title score of 50 (`wantT.startsWith(itT)`) and an artist score of 0, so the row is rejected as **not found**.

**Plain-text parser** (`app.js:1923-1939`). Each line is trimmed and empty lines are dropped. Then, verbatim: `const m = line.match(/^(.+?)\s*[-—–|\t]\s*(.+)$/);`. The separator class is `-` (U+002D), `—` (U+2014), `–` (U+2013), `|` and tab. Spaces around it are optional (`\s*`), and the lazy `(.+?)` splits at the **first** separator after at least one character. Without a match, the whole line is the title and the artist is `''`. Lines whose title is shorter than 2 characters are dropped (`:1932`). Duplicates are removed on ``${title.toLowerCase()}|${artist.toLowerCase()}`` (`:1933`).

| Line | title | artist |
|---|---|---|
| `Empire State of Mind - Jay-Z` | `Empire State of Mind` | `Jay-Z` (correct: the split happens before the artist's hyphen) |
| `Ob-La-Di, Ob-La-Da - The Beatles` | `Ob` | `La-Di, Ob-La-Da - The Beatles` |
| `Jay-Z - Empire State of Mind` (Artist - Title order) | `Jay` | `Z - Empire State of Mind` |
| `Queen - Bohemian Rhapsody` (Artist - Title order) | `Queen` | `Bohemian Rhapsody` (swapped) |
| `7 - Prince` | `7` → line dropped (shorter than 2) | — |
| `1. Song - Artist` | `1. Song` (track numbering kept) | `Artist` |
| `Song;Artist;Album` | `Song;Artist;Album` | `''` |
| `Song⇥Artist⇥Album` (tabs) | `Song` | `Artist⇥Album` |

- The order is always Title then Artist. "Artist - Title" lists are imported swapped. The scorer then compares the artist name against TIDAL titles, so most swapped rows come back as **not found**.
- **Paste heuristic mismatch** (`app.js:1800-1808`). A paste is ignored when an input or textarea has focus, or when it is shorter than 10 UTF-16 code units. A single-line paste is accepted only if it contains `\n`, `,` or the pattern `/\s[-—–|]\s/`, which requires whitespace on both sides. The parser itself needs no spaces, and tab is a parser separator but not a heuristic one.

**Porting notes**
- **Choose an encoding policy explicitly** (owner decision). Suggested order:
  1. Check for BOMs: UTF-8 `EF BB BF`, UTF-16LE `FF FE`, UTF-16BE `FE FF`.
  2. Try strict UTF-8.
  3. Fall back to Windows-1252, or use `NSString.stringEncoding(for:encodingOptions:convertedString:usedLossyConversion:)`.
- **Always strip a leading U+FEFF yourself.** Swift's `trimmingCharacters(in: .whitespacesAndNewlines)` does not remove it, and whether a given Foundation decoder keeps it is not something to rely on.
- **Parse CSV over `unicodeScalars` or UTF-8 bytes, never over `Character`s.** In Swift, `"\r\n"` is a single `Character`, so a character loop that tests `c == "\n"` never sees the line break.
- Swift's `components(separatedBy: .newlines)` also splits on lone `\r`, U+0085 and U+2028. That fixes CR-only files but differs from today's behaviour; decide on purpose.
- Define the plain-text separator class and the whitespace class explicitly. ICU `\s` differs from JS `\s`: ICU lacks U+FEFF and U+000B.
- Owner decisions: detect `;` and tab delimiters; accept localised headers; pick the title column by best match rather than first match (or exclude `artist`/`album`/`playlist` columns from the title search); split plain text only on a *spaced* separator (` - `); detect Artist-Title order.
- On a native drop target, restrict to `.commaSeparatedText` and `.plainText` and cap the file size.

---

### 7. Localisation of UI and logs

**Every user-facing string is hard-coded English.** That covers the markup in `index.html` (`<html lang="en">` at `:2`), template literals in `app.js`, and main-process log text in `tidal_download.js`, `bulk_runner.js` and `electron-main.js`. There is no i18n layer: a grep finds no `Intl.`, `toLocaleString`, `toLocale…` or `localeCompare` anywhere.

**Plurals** are hand-written as ``${n} track${n === 1 ? '' : 's'}``:
- In the renderer: `app.js:1309, 1332, 1355, 1415, 1680, 1688, 1837, 1981`, plus `1646` (extension).
- In the main process: `electron-main.js:700` (extension) and `tidal_download.js:480`.

Strings with **no plural form at all**:

| Where | Text |
|---|---|
| `app.js:1444` | `=== Starting batch (${n} tracks) ===` (prints "1 tracks") |
| `app.js:1560-1561` | `${r.count} files indexed`, `📁 Library re-scanned: ${r.count} files indexed.` |
| `app.js:1827, 1841` | `Matching ${done} / ${n} tracks on TIDAL…` |
| `app.js:1850` | `+ Added ${added} from import. ${matched} matched on TIDAL…` (no noun) |
| `bulk_runner.js:61` | `${tracks.length} tracks queued.` |
| `tidal_download.js:504, 641` | `Found ${tracks.length} tracks.` (CLI album and playlist) |

**Numbers.** `toFixed` always uses `.` as the decimal separator:
- `tidal_download.js:467`: `(${(stat.size / 1024 / 1024).toFixed(1)} MB)`
- `tidal_download.js:452`: cover size, `toFixed(0)` with `KB`
- `app.js:430, 487`: update progress, `toFixed(1)` with `MB`

These divide by 1024², so the unit is really MiB but labelled `MB`. Finder uses decimal MB, so the numbers disagree: a 45,000,000-byte file is logged as `42.9 MB`, while Finder shows 45 MB. Percentages are written as `${pct}%` (`app.js:428, 485, 913, 1056`). The search modal title uses straight quotes: `Search results for "${query}"` (`app.js:1331`).

**Status is derived from English text.** The activity-log colour class comes from text and glyph patterns such as `complete:`, `Error:`, `FFmpeg failed` and `📁 Already in library` (`app.js:330-340`). One pattern is already stale: the real line is `📁 Already in music library: …` (`tidal_download.js:374`). That line only prints from the CLI, because the GUI passes `--skip-library-check` (`bulk_runner.js:35`).

**Layout**
- `text-transform: uppercase` on `.label`, `.activity-head` and `.badge` (`styles.css:158, 329, 651`). These follow English casing rules because the page is `lang="en"`.
- No `dir` attributes exist, so right-to-left titles render inside left-to-right containers. Where the ` · ` separator and the duration end up next to RTL text was not checked visually (unverified).
- Queue titles never truncate: `.qi-title-row .qi-title { flex: 0 0 auto; overflow: visible; text-overflow: clip; white-space: nowrap; }` (`styles.css:640-645`). Long titles, including CJK titles, overflow the row.

**IME.** `urlInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') handleInput(); });` (`app.js:1285`) has no `e.isComposing` check. Whether the Enter that confirms a Japanese or Chinese input-method candidate triggers a search with half-typed text in Chromium is unverified (needs a run).

**Requests carry no locale**
- Default headers for TIDAL and Spotify (`tidal_lib.js:131-136`): `'User-Agent': 'okhttp/5.3.2'`, `'Accept': 'application/json'`, `'Accept-Encoding': 'identity'`.
- `tidalGet` adds `Authorization: Bearer …` and `X-Tidal-Platform: android` (`:163-166`).
- The Spotify embed request sends only `{ 'User-Agent': SPOTIFY_UA, 'Accept': 'text/html' }` (`:480`), where `SPOTIFY_UA` is the desktop Chrome 120 string at `:472`.
- No `Accept-Language` header and no `locale` query parameter is sent to `api.tidal.com` or `open.spotify.com`. The server chooses the language and script of any localised metadata (whether TIDAL or Spotify localise any, unverified). Only the device sign-in sends `'Accept-Language': 'en-US,en;q=0.9'` (`tidal_auth_node.js:80`).
- The catalogue region is `cred.countryCode`. If that is missing, the code fetches `GET /v1/users/{userID}?countryCode=US`; if that fails too, it uses `'US'` (`tidal_lib.js:104-119`).

**Porting notes**
- Use a String Catalog with plural variants (or `^[\(n) track](inflect: true)`).
- Format numbers and sizes with `FormatStyle`. `ByteCountFormatter` uses decimal units by default, which matches Finder; that is a behaviour change from today.
- Format percentages with `.percent`, and use locale-aware quotes.
- Drive log styling from typed events, never from text.
- Use native text fields, which are expected not to submit while input-method text is still being composed (standard AppKit behaviour, unverified here).
- `URLSession` adds an `Accept-Language` header automatically and has its own `Accept-Encoding` default (unverified, needs a run). For parity, set `Accept-Encoding: identity` explicitly as today, and decide whether to send `Accept-Language` from the user's locale (owner decision).

---

### 8. Time, durations, dates

**Duration display** (`app.js:88-91`), verbatim:

```js
function fmtDuration(sec) {
    if (!sec) return '';
    return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
}
```

| Input (seconds) | Output |
|---|---|
| `undefined`, `0` | `''` |
| `7` | `0:07` |
| `245` | `4:05` |
| `3600` | `60:00` |
| `4500` (75-minute mix) | `75:00` (no hour field) |

- Non-integer input would print the raw remainder (`245.4` → `4:5.399999999999977`). Current sources pass whole seconds: Spotify durations are rounded at `tidal_lib.js:380, 391`, import uses `pick.duration || 0`, and TIDAL durations are assumed to be integers (unverified).
- Used at `app.js:968` (queue row, guarded by `t.duration ?`) and `app.js:1341` (search modal, unguarded). With a missing duration the search modal shows `Artist · Album · ` with an empty tail.
- The CLI copy at `tidal_search.js:27` has no guard: ``const dur = `${Math.floor(t.duration / 60)}:${String(t.duration % 60).padStart(2, '0')}`;``. A missing duration prints `NaN:NaN`.

**Token expiry** uses the wall clock:
- `tidal_lib.js:88`: `cred.expires_at = Date.now() + (json.expires_in || 3600) * 1000 - 60_000;`
- `tidal_lib.js:98`: `if (cred.access_token && cred.expires_at && Date.now() < cred.expires_at) return cred.access_token;`

`expires_at` is epoch **milliseconds**, saved to `token.json` (`:62-68`). The 60 s margin is taken off once, at refresh time. If the Mac's clock is set back, an expired token looks valid and calls fail with 401. If it jumps forward, every call refreshes.

**Nothing refreshes and retries after a 401.** Only `getPlaybackInfo` checks for 401 by name: `if (res.status === 401) throw new Error('Unauthorized — token may be invalid');` (`tidal_lib.js:293`). The other wrappers throw `<X> failed: 401 <body>` (`:238, 254, 276, 300`). Where a 401 surfaces:
- In `downloadTrack`, `getTrackInfo` runs first (`tidal_download.js:350`), so a dead token shows as `Track info failed: 401 …` and the row fails.
- `getBestManifest` (`tidal_download.js:325-342`) catches the 401 for each quality tier and logs it only with `--debug` (`:338`). The user sees only `Could not get playback manifest at any quality.` (`:341`).
- **Long imports (code-shown, Low):** `resolve:tracklist` fetches the token once (`electron-main.js:926`) and searches track by track (`:938-976`). If the token expires partway through, each later `searchTracks` throws `Search failed: 401 …`. The per-track `catch` (`:972-974`) swallows that error, so every remaining track is marked **not found** and no error is shown. How likely this is depends on the token lifetime TIDAL returns in `expires_in`; the code assumes 3600 s when it is absent, and the real value is unverified.

**Date tag**
- `tidal_download.js:276`: `const releaseDate = albumInfo?.releaseDate || info.album?.releaseDate || info.streamStartDate || '';`
- `tidal_download.js:284`: `date: releaseDate.slice(0, 4),` — written as `-metadata date=YYYY` only when non-empty (`:304-306`).
- Only the year is written. When the album has no `releaseDate`, the year comes from `streamStartDate`, the date the track started streaming on TIDAL, which can be later than the original release.
- The `streamStartDate` format is assumed to be ISO-8601 starting with the year (unverified). `slice(0, 4)` would write junk otherwise.
- The UI shows no dates at all.

**Porting notes**
- `Duration.formatted(.time(pattern: .minuteSecond))` reproduces `75:00`. Adding an hour field (`.hourMinuteSecond` for long tracks) is an owner decision.
- Store the expiry as a `Date` with the same 60 s margin. Fetch the token per request, not once per batch or import.
- Refreshing once and retrying once after a 401 is an owner decision; today nothing retries.

---

### 9. Input forms: URLs, URIs and bare IDs

**Regexes** (all unanchored, so they match anywhere in the trimmed input):
- `URL_RE` (`app.js:66`): `/^https?:\/\/|spotify\.com|tidal\.com/i`. Used **only** for the hint under the input box (`app.js:1276-1282`: `Detected a link — will resolve all tracks on add.` versus `Type to search TIDAL by song name (or paste a link).`). The real decision is made in the main process.
- `parseSpotifyUrl` (`tidal_lib.js:450-454`): `/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i`. The type is lowercased; the ID keeps its case.
- `parseTidalUrl` (`tidal_lib.js:431-447`):
  - `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i`
  - otherwise `/^\d+$/` means a track ID
  - otherwise the UUID pattern `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i` means a playlist
- `parseInputUrl` (`tidal_lib.js:457-463`) tries Spotify first, then TIDAL. If both return `null`, `resolve:input` treats the whole input as a TIDAL text search (`electron-main.js:665-684`). A search opens the results modal, which can show `0 results`.

| Input | Hint (`URL_RE`) | Parsed as | What happens |
|---|---|---|---|
| `https://open.spotify.com/track/<id>?si=x` | link | Spotify track | resolves |
| `https://open.spotify.com/intl-de/album/<id>` | link | Spotify album | resolves |
| `spotify:track:<id>` | search | `null` | text search for the literal URI |
| `https://spotify.link/<code>` | link | `null` | text search for the URL |
| `https://open.spotify.com/artist/<id>` (also `/episode/`, `/show/`, `/embed/track/<id>`) | link | `null` | text search for the URL |
| `https://tidal.com/browse/track/123` | link | TIDAL track `123` | resolves |
| `https://listen.tidal.com/album/<A>/track/<T>` | link | TIDAL **album** `<A>` (first match wins) | the whole album is queued; whether TIDAL issues such links is unverified |
| `https://tidal.com/browse/artist/1`, `/mix/<id>`, `/video/1` | link | `null` | text search for the URL |
| `1999` | search | TIDAL track ID `1999` | see bug below |
| `see https://tidal.com/browse/track/123 now` | link | TIDAL track ID `123 now` | see bug below |

**Bugs**
- **Bare-number searches become track IDs (Medium, code-shown).** The hint promises a search (`app.js:1281`), but `/^\d+$/` (`tidal_lib.js:439`) makes the input a track ID. Searching for a song titled `1999`, `22` or `7` either fails with `✗ Track info failed: 404 …` or adds whatever track has that ID. Which IDs exist is unverified.
- **Unencoded IDs (Low, code-shown).** The TIDAL ID pattern `[^/?#]+` accepts spaces and any Unicode. The ID is then placed in the request path without encoding (`tidal_lib.js:237, 243, 253, 265, 275, 287`). Node's HTTP client rejects such paths, with an expected message like `Request path contains unescaped characters` (unverified, needs a run). This happens when text follows a pasted link.

**Porting notes**
- Parse with `URLComponents`: match the host (`open.spotify.com`, `tidal.com`, `*.tidal.com`), then the path components. Percent-encode IDs when building API paths.
- Owner decisions:
  - accept `spotify:` URIs;
  - resolve `spotify.link` short links by following one redirect (a network call);
  - keep bare numbers as searches unless clearly an ID;
  - handle album-context track links;
  - show "Unsupported link" instead of searching for a URL.

---

### 10. CLI default folder on macOS

`tidal_download.js:40`: `const DEFAULT_OUT_DIR = 'Z:\\Downloads';`

`tidal_download.js:687-688`: `const outDir = positional[1] ? path.resolve(positional[1]) : DEFAULT_OUT_DIR;` then `if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });`

On macOS, `Z:\Downloads` is a single relative name, because backslash and colon are legal in POSIX names. Running the CLI without an output folder therefore creates a folder literally named `Z:\Downloads` in the current directory. Finder shows the `:` as `/`. The GUI never reaches this path, because it always passes `outDir` (`bulk_runner.js:35`). Mandatory rule 1 encodes this Windows default. The Swift port is not expected to keep the CLI. If it does, default to the user's Downloads folder (`FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)`).

---

### Bug summary (this section only)

| Severity | Finding | Where |
|---|---|---|
| Medium | A second track with the same (case-folded, sanitised, or NFC/NFD-equivalent) title is reported "already in downloads folder", marked skipped, and removed from the queue without being downloaded | `tidal_download.js:355-366`; `app.js:1468-1473` |
| Medium | A bare-number search (`1999`, `22`) is treated as a TIDAL track ID | `tidal_lib.js:439`; `electron-main.js:665` |
| Low | Response chunks are decoded to text one at a time; split multi-byte characters become U+FFFD in titles, artists, tags and log lines | `tidal_lib.js:144-146`; `electron-main.js:1022-1027`; `tidal_download.js:265` |
| Low | A token that expires mid-import silently turns every remaining track into "not found" | `electron-main.js:926, 942, 972-974` |
| Low | The CSV title column is the first header matching `\bname\b`, so `Artist Name` before `Track Name` uses the artist column for the title | `app.js:1903` |
| Low | The plain-text import splits at the first hyphen, dash or pipe even without spaces; Title-then-Artist order is assumed; 1-character titles are dropped | `app.js:1928-1932` |
| Low | Imported files are decoded as UTF-8 only (Windows-1252 and UTF-16 exports become garbage); `;` and localised headers are not detected | `app.js:1777, 1788, 1870-1874, 1903-1904` |
| Low | `sanitize` allows hidden names (`.`-leading, whitespace-only → `.flac`), control characters and over-long names | `tidal_lib.js:616-618` |
| Low | The library walk indexes AppleDouble `._*` sidecars and hidden folders (inflated counts, orphan matches, sidecar paths in badges) and may download cloud-only files (unverified) | `tidal_lib.js:687-700, 723` |
| Low | Unencoded TIDAL IDs containing spaces or Unicode reach the HTTP path | `tidal_lib.js:435, 237` |
| Low | `fmtDuration` has no hour field; `tidal_search.js` prints `NaN:NaN` for a missing duration | `app.js:88-91`; `tidal_search.js:27` |
| Suggestion | `duration: true` is requested for every library file, but the value is never used | `tidal_lib.js:723, 726, 788` |
| Suggestion | Sizes are computed in MiB but labelled MB; plurals are English-only and some are missing; log colour depends on English text | `tidal_download.js:452, 467`; `app.js:330-340, 430, 487, 1444, 1560` |

### Owner questions

1. Filename collisions: keep "skip", or suffix ` (2)` / use `Title - Artist`? The latter two change rule 3.
2. Should filenames be normalised to NFC, have leading dots stripped, and be capped at 255 bytes?
3. Library walk: skip hidden files, AppleDouble files and package contents? Skip cloud-only placeholders rather than download them?
4. Import: which encodings to accept, and should `;` delimiters, tabs, localised headers and Artist-Title order be detected?
5. Inputs: should bare numbers stay searches, should `spotify:` URIs and `spotify.link` short links be accepted, and should unsupported links show an error instead of a search?
6. Ship the Swift app English-only first (with a String Catalog ready), or localise from day one? Should requests send `Accept-Language` from the user's locale?

### Live checks owed (need a run)

- Paste `1999` into the input box: confirm it hits the track-ID path, and what it shows.
- Import a UTF-16LE tab-separated playlist export from Music.app, and a Windows-1252 CSV: record what the queue shows.
- Download two tracks titled `Intro` and `INTRO` into one folder on a default (case-insensitive) APFS volume: confirm the second shows `⏭ skipped` and leaves the queue.
- Point the library at an exFAT drive containing `._*` files: compare the "files indexed" count with the real file count.
- Point the library at a Dropbox or iCloud folder with online-only files: watch whether the scan downloads them.
- Resolve a 100-track playlist full of non-ASCII titles several times: look for U+FFFD in queue titles.
