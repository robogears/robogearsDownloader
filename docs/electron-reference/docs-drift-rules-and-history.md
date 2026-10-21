## Documentation vs code drift, product rules and history

### Overview

The repository carries eight prose documents: `CLAUDE.md` (the project handbook), `README.md` (public front page), `ONBOARDING.md` (the old CLI guide), `BOT_PROMPT.md` (a paste-in briefing for other AI tools), `RELEASE_NOTES.md` (body of the current draft release), `ship.md` (release process), `updater.md` (a reusable write-up of the self-updater) and `waveformplayback.md` (a reusable write-up of the waveform preview). They were last refreshed between v0.1.16 and v0.1.25. The code is at **v0.1.30** (`package.json:3`, `chrome-extension/manifest.json:4`) and is the source of truth for everything below. No document describes v0.1.26 to v0.1.29. `RELEASE_NOTES.md` describes v0.1.30, and all of it is about the Chrome extension, whose support the owner ended on 21 Oct 2026.

Most product rules still hold in the code. The GUI download folder starts blank. Output is flat, with no album or playlist subfolders. Filenames are `<Title>.flac` or `<Title>.m4a`. The music library is only ever read. An "exact" library match needs both title and artist. Quality is requested as `HI_RES_LOSSLESS`, falls back to `LOSSLESS`, and only then to `.m4a`. Cover art is piped to FFmpeg's stdin. CI releases land as drafts. Where the docs have drifted, the code differs in specific ways: the preview-volume slider shows the wrong position at startup; Reset config also erases the saved volume; CLAUDE.md lists the library-match tiers in the wrong order and the download steps in the wrong order; it names a function that no longer exists (`getManifestV2`); it says three Settings tabs (there are four), a 200 ms quit delay (it is 500 ms), "https-only" external links (http is accepted) and "retry on 429/5xx" (only some fetches retry). The `Z:\Downloads` CLI fallback exists only in `tidal_download.js`.

Several code defects must not be carried into the Swift port. (1) `loadCred()` calls `process.exit(1)` inside the Electron main process, so a CSV import or a waveform preview attempted with no `token.json` closes the whole app. (2) Re-authenticating appends the new credentials to `token.json`, but the app always reads the first entry, so the old credentials stay in use. (3) Cancel kills only the batch runner; the per-track download process it started keeps running and writes its file. (4) Changing the library folder while a scan is running can leave the old folder's results in the cache. (5) When a batch ends abnormally, rows that never got a final status are deleted from the queue. (6) A failed sign-in leaves an auth modal on screen that cannot be closed. (7) A batch with failed tracks still plays the success sound. The release workflow's `release` job never checks out the repository. That is the probable reason every GitHub release body comes out empty, but it is unverified (needs a CI run).

---

### Components

#### 1. Documentation inventory

| File | Lines | Written for | Status at v0.1.30 |
|---|---|---|---|
| `CLAUDE.md` | 833 | v0.1.25, Windows host (`Z:\robogearsDownloader\`) | Mostly right on rules; stale on version, tabs, IPC list, pipeline order, matcher tiers, timings; silent on v0.1.26 to v0.1.30 |
| `README.md` | 88 | v0.1.23 to v0.1.25 | Mostly right; overstates retries/timeouts and ISRC matching; omits the topbar update pill |
| `ONBOARDING.md` | 136 | Pre-GUI CLI era (`Z:\Downloads\hifi-api\`) | Heavily stale (subfolders, hard-coded library path, DASH-only) |
| `BOT_PROMPT.md` | 173 | v0.1.16 | Stale (portable `.exe`, OCR drop-zone, `build:portable`) |
| `RELEASE_NOTES.md` | 41 | v0.1.30 | Version matches code; content is Chrome-extension-only (support ended 21 Oct 2026) |
| `ship.md` | 139 | Release process | Process rules; conflicts with the owner's global versioning rule (see §7) |
| `updater.md` | 791 | Generic guide, Windows-portable-centric | Several constants and names differ from the code (see §8) |
| `waveformplayback.md` | 523 | Generic guide, v0.1.20 design | Cache design, volume, click behaviour and CSS differ from the code (see §9) |

#### 2. `CLAUDE.md` drift ledger

Each row is a statement in `CLAUDE.md` that is wrong or incomplete at v0.1.30.

| # | `CLAUDE.md` line(s) | What the doc says | What the code does | Evidence |
|---|---|---|---|---|
| D1 | 19, 108, 412, 743, 756-787 | Repo lives at `Z:\robogearsDownloader\`; restart with PowerShell `Get-Process electron …`; `gh` at a WinGet path | This checkout is `/Users/william/Pictures/GitHub Projects/swiftRobotDownloader` on macOS. No code depends on the repo location | — |
| D2 | 21, 562 | Current version v0.1.25 | 0.1.30 | `package.json:3`; `chrome-extension/manifest.json:4` |
| D3 | 568-691 | "Just landed" history ends at v0.1.25 | v0.1.26 to v0.1.30 (Chrome-extension bridge) are undocumented | `electron-main.js:24, 28, 497-522, 691-812`; `extension-server.js`; `RELEASE_NOTES.md` |
| D4 | 27-62 | Feature table | Omits: the extension bridge; Settings → Extension tab; the "✓ Batch finished." row with an **Open folder** button; the Hi-Res badge in the search modal | `index.html:119, 163-186`; `app.js:1486-1501, 1340` |
| D5 | 36, 515-517 | Settings has three tabs (Folders / TIDAL / Updates) | Four tabs: Folders, TIDAL, Extension, Updates | `index.html:116-121` |
| D6 | 107-161 | File tree | Omits `extension-server.js`, `chrome-extension/`, `scripts/sync-extension-version.js`, `start_app.command`, `ship.md`, `BOT_PROMPT.md`, `updater.md`, `waveformplayback.md`, `build/icon.{svg,png}`, `build/dmg-background.{svg,png}`, `package.json` `build.extraResources` and the `sync-ext` npm script | `package.json:12, 60-65` |
| D7 | 144-146, 459 | CI builds a "mac arm64 .zip"; trigger is tag push only | CI builds and uploads `dist/robogears-downloader-mac-arm64.dmg` (line 462 of the same doc agrees). The workflow also has a manual `workflow_dispatch` trigger | `release.yml:4-9, 37-41` |
| D8 | 151-154 | `token.json` lives in `%APPDATA%\Roaming\robogears Downloader\` in dev and packaged builds | Only packaged builds set `TIDAL_TOKEN_PATH` to `<userData>/token.json`; dev uses `<source dir>/token.json` (line 432 of the same doc agrees) | `electron-main.js:19-21, 611`; `tidal_lib.js:13`; `tidal_auth_node.js:15` |
| D9 | 167 | Main spawns `tidal_download.js` and `bulk_runner.js`; `childEnv()` passes `TIDAL_LIBRARY_FOLDER` / `TIDAL_TOKEN_PATH` | Main spawns only `bulk_runner.js`; `bulk_runner` spawns `tidal_download.js` once per track. `childEnv()` sets `ELECTRON_RUN_AS_NODE=1`, `FORCE_COLOR=0`, `TIDAL_LIBRARY_FOLDER`, `BULK_RUNNER_PROGRESS=1`; `TIDAL_TOKEN_PATH` arrives only via `...process.env`. The comment at `electron-main.js:994` refers to a "single-track spawn above" that no longer exists | `electron-main.js:60-71, 994-999`; `bulk_runner.js:41-44` |
| D10 | 172-216 | IPC list | Omits `extension:info`, `extension:regenerate-token`, event `extension:tracks-resolved`. `getPreviewAudio(tidalId)` invokes `preview:get-audio` with `{ tidalId }`. `resolveInput` can also return `{ ok:false, cancelled:true }` or `{ ok:false, error }` | `electron-preload.js:50-55`; `electron-main.js:658-687` |
| D11 | 178 | `openExternal` is https-only | Regex `/^https?:\/\//` also allows `http://` | `electron-main.js:186-188` |
| D12 | 215, 496-505 | App quits 200 ms after `applyUpdate` | `setTimeout(() => app.quit(), 500)` on both Windows and macOS (line 628 of the same doc records the 200 → 500 ms change) | `electron-main.js:465-467` |
| D13 | 224 | Each library entry has "four" normalized title forms | Six: `fnFull`, `fnTitleFull`, `fnCore`, `fnTitleCore`, `metaTitleFull`, `metaTitleCore`; plus `metaTitleDisplay`, `metaArtist` (normalized), `metaDuration` | `tidal_lib.js:730-741` |
| D14 | 236-240 | Match priority: 1 meta title + artist, 2 exact filename (implied exact), 3 core meta → similar, 4 core filename → similar | Four tiers, only tier 1 can be `exact` (see §14.3) | `tidal_lib.js:803-831` |
| D15 | 248-251 | `setLibraryPath()` auto-invalidates the cache | It clears `_libraryCache` but not the in-flight `_libraryScanPromise`, so a scan already running for the old folder is reused | `tidal_lib.js:28-31, 674-676` |
| D16 | 83 | `findInLibrary` runs "before any network fetch"; an exact match is skipped "silently" | Runs after `getToken`, `getCountryCode` and `GET /v1/tracks/{id}`, before the album, manifest and audio fetches. An exact match prints `  📁 Already in music library: <path>` | `tidal_download.js:347-383` |
| D17 | 298, 705 | Spotify Pathfinder approach is "documented in updater.md's patterns section" | `updater.md` contains no Spotify or Pathfinder content | `updater.md` (whole file) |
| D18 | 317 | The ISRC branch is "rarely hit" | Never hit: every embed mapper sets `external_ids: {}` | `tidal_lib.js:512, 526, 540, 560-568` |
| D19 | 296 | CSV import matches "the same way Spotify-URL resolves do" | A separate scorer with no duration term; matched rows take TIDAL's title and artist (Spotify-URL rows keep Spotify's) | `electron-main.js:944-971`; `tidal_lib.js:377-386` |
| D20 | 356-367 | Pipeline: parse → skip-if-exists → library check → track info → album → manifest → … | Actual order is in §14.5. Skip-if-exists and the library check come after the track-info fetch. The DASH init segment is fetched before the media-segment workers start | `tidal_download.js:346-469, 179` |
| D21 | 363, 377 | FLAC vs AAC decided from the manifest `codecs` attribute | Primary signal is `audioQuality ∈ {LOSSLESS, HI_RES_LOSSLESS, HI_RES}`, then `manifest.codec` contains `flac`, then `/codecs="flac"/i` on the decoded manifest (line 642 of the same doc records this) | `tidal_download.js:400-404` |
| D22 | 365 | Temp file is `.tmp.m4a` for segments, `.tmp.flac` for direct URLs | Temp extension is `m4a` if `manifest.mimeType` contains `mp4`, else `flac` | `tidal_download.js:427-428` |
| D23 | 369-371 | `getManifestV2()` exists in `tidal_lib.js`, unused | Does not exist anywhere (no `getManifestV2` or `trackManifests` in any `.js`) | grep |
| D24 | 380 | "Bulk callers collect" `AacOnlyError` | Only `tidal_download.js`'s own album/playlist loops collect it. `bulk_runner` never passes `--flac-only`, so the GUI never sees it | `tidal_download.js:515, 576, 617, 652`; `bulk_runner.js:35` |
| D25 | 57 | "Retry on 429/5xx with exponential backoff" | Only `fetchBuffer` retries (DASH segments, cover art, preview audio). TIDAL API calls, Spotify embed fetches and the streamed BTS direct download never retry | `tidal_lib.js:129-168, 174-232`; `tidal_download.js:215-256` |
| D26 | 43 | "FFmpeg presence verified at startup" | Spawns `ffmpeg -version` and warns only on a spawn `error` (binary missing). A binary that runs but exits non-zero is not detected | `electron-main.js:529-546` |
| D27 | 543 | Success ping when the batch "finishes cleanly" | Plays on `bulk_runner` exit code 0, which also happens when tracks failed | `bulk_runner.js:63-118`; `app.js:1457-1461` |
| D28 | 35, 591 | Volume defaults to 50% | Stored default is `0.5` (slider position), but at startup the slider is set to the *squared* value (25). The comment there says "defaults to 60%" | `app.js:511, 1947-1948` |
| D29 | 175, 522 | Reset config clears the two folders only | Overwrites `settings.json` with `{downloadFolder:'', libraryFolder:''}`, which also deletes `volume` | `electron-main.js:42-44, 561-565` |
| D30 | 62 | Skip messages say "in downloads folder" vs "in music library" | True in the CLI. In GUI runs the library message never appears, because `bulk_runner` always passes `--skip-library-check` | `bulk_runner.js:35`; `tidal_download.js:370` |
| D31 | 12, 32, 571 | Paste "anywhere in the app" | Ignored when focus is in an `INPUT` or `TEXTAREA`, when the text is under 10 characters, or when it has no newline, no comma and no spaced separator | `app.js:1800-1808` |
| D32 | 75 | Skip-if-exists "handles name collisions safely" | It never overwrites, but a *different* song with the same title is silently skipped as "already in downloads folder" | `tidal_download.js:355-366` |
| D33 | 230, 58 | Duration read from tags | Read and stored (`metaDuration`) but never used in matching (`_duration` parameter ignored) | `tidal_lib.js:726, 788` |
| D34 | 763 | Sanity check `findInLibrary('Stronger')` | Passes no artist, so it can never return `exact` under the strict rule | `tidal_lib.js:796-801` |
| D35 | 797 | Fix for "Resolving link… stuck forever": add a try/catch in `resolve:input` | Already present | `electron-main.js:660-686` |
| D36 | 698, 710 | Cause of empty softprops release bodies unknown | The `release` job has no `actions/checkout`, so `body_path: RELEASE_NOTES.md` points at a file not present on the runner. Probable cause, unverified (needs a CI run) | `release.yml:44-61` |
| D37 | 699, 709 | Node 20 deprecated 2 June 2026, removed 16 Sept 2026; "bump before June" | Both dates have passed; the workflow still pins `node-version: '20'` and the `@v4`/`@v2` actions. Whether CI still runs is unverified (needs a run) | `release.yml:15-19, 31-35, 50, 53` |
| D38 | 200 | Cancel "kills the active bulk_runner child" | True, but the `tidal_download.js` grandchild for the track in flight keeps running (see Bugs) | `electron-main.js:646-653`; `bulk_runner.js:41-44` |
| D39 | 608 vs 719-726, 515 | Queue persistence, Settings tabs, scan progress, FFmpeg check and log cap attributed to v0.1.17 in one place and to v0.1.20 in another | Inconsistent version attribution inside the doc; not checkable from code | — |
| D40 | 166 | Renderer "never touches files" | It reads dropped and picked files itself with `File.text()` | `app.js:1777, 1788` |

Statements in `CLAUDE.md` that still match the code: 70-71 (GUI half), 73-79, 85, 87, 89, 93-97, 99-101, 186-193, 196, 202, 207, 213, 263-274, 292, 318-322 (scoring, for the Spotify-URL path), 330-348, 379, 382, 389-401, 406-407, 416-432, 436-446, 459-463, 484-492, 507, 509, 520-532 (apart from the tab count), 538-554, 632-633, 638, and the Don'ts at 810-833.

#### 3. `README.md` drift

| Line | README says | Code |
|---|---|---|
| 5 | App "updates itself in the background" | Updates are found at launch, but downloading and applying them needs a click (activity-log button or topbar pill) |
| 5, 53 | Downloads use "MPEG-DASH parallel segment fetch" | BTS manifests (a single signed URL, streamed to disk) are also handled (`tidal_download.js:118-127, 445-447`) |
| 53 | Spotify tracks matched "by ISRC when available" | The embed never supplies an ISRC (`tidal_lib.js:512, 526, 540`) |
| 32 | "Retries on network errors … hard timeouts so it never hangs" | TIDAL API calls and BTS downloads never retry. Timeouts are socket-idle timeouts (`tidal_lib.js:149`; `tidal_download.js:252`). The FFmpeg spawn has no timeout (`tidal_download.js:260-273`). Auth requests have no timeout and the polling loop has no client-side limit (`tidal_auth_node.js:22-33, 133-170`) |
| 42 | Update via **Download update** in the activity log | Also via the topbar **Update now** pill (`index.html:23`; `app.js:437-489`) |
| 30 | "~3 seconds" per track | Not checkable from code |
| — | No mention of the Chrome extension | Fits the decision to drop it |

Still true: install artifact names and paths (13-14), quality policy (22), 100-track cap (23, 61), dedup with **+ Add** (27, 41), FLAC picture type 3 (28), first-time setup steps (46-49), DRM note (63; `tidal_download.js:120-122`), credits (84).

#### 4. `ONBOARDING.md` drift (pre-GUI CLI guide)

- Line 7: scripts in `Z:\Downloads\hifi-api\`. Wrong location.
- Lines 56, 67: album and playlist downloads create `<Album Title>\` / `<Playlist Title>\` subfolders. Wrong: all paths are flat in `outDir` (`tidal_download.js:497, 557, 595, 634`). Line 107 of the same file says so.
- Line 74: `--quality HI_RES_LOSSLESS` "fails if not available". Wrong: `getBestManifest` returns whatever tier TIDAL serves and never checks the returned `audioQuality` (`tidal_download.js:325-342`).
- Lines 71-78: flag table omits `--flac-only` and `--skip-library-check` (`tidal_download.js:60-61`).
- Lines 87-89: manifest is always MPEG-DASH, and the init segment downloads in parallel with the media segments. BTS JSON manifests are also handled, and the init segment is fetched first (`tidal_download.js:179`).
- Line 105: library is hard-coded `Z:\Dropbox\Music`, matched by title. Now configurable (Settings, or env `TIDAL_LIBRARY_FOLDER`), default `''` = check off (`tidal_lib.js:24`), with title+artist tiers.
- Line 121: only `application/vnd.tidal.bt` is named. Code accepts any `application/vnd.tidal.*` (`tidal_download.js:118`).
- Line 136: "All four scripts". There are five CLI scripts (`tidal_auth_node`, `tidal_search`, `tidal_download`, `tidal_check_quality`, `bulk_runner`) plus `electron-main`.
- Still true: `Z:\Downloads` CLI default (109; `tidal_download.js:40, 687`); skip-if-exists and `--force` (108); `r=N` means N+1 segments (111; `tidal_download.js:147-152`); backoff 1 s → 2 s → 4 s (89; `tidal_lib.js:186`); system-`ffmpeg` fallback (13; `tidal_download.js:36`); DASH audio held whole in memory before writing (112; `tidal_download.js:175, 207`); no rejection on `ContentProtection` (110).

#### 5. `BOT_PROMPT.md` drift (written at v0.1.16)

- Lines 11-13: "v0.1.16 … portable Windows .exe". The code is 0.1.30 and ships an NSIS `robogears-downloader-setup.exe` (`package.json:66-81`).
- Line 22: CLAUDE.md "~700 lines". It is 833.
- Lines 38-40: OCR drop-zone with `OCR_FEATURE_ENABLED`, "Coming soon" badge and clown horn. Replaced by CSV/text import (`index.html:43-55`; `app.js:1755-1939`). `OCR_FEATURE_ENABLED` no longer exists; `playClownHorn` (`app.js:194`) is never called.
- Lines 49-50: Windows self-install swaps the portable `.exe`. It now spawns the NSIS installer with `/S --updated` (`electron-main.js:331-336`).
- Lines 59, 85: `npm run build:portable → dist\robogears-downloader.exe`. The script was removed (`package.json:6-13`), and `CLAUDE.md:410, 828` forbid adding it back.
- Line 55: "no accent colors". Mostly true, but status colours exist: similar = `#fcd34d` on amber, done = `#86efac`, error = `#ff6b6b` (`styles.css:14, 660-663, 701-703`).
- Lines 110-111: `LOSSLESS` / `HI_RES_LOSSLESS` = FLAC. The code also treats `HI_RES` as FLAC (`tidal_download.js:401`).
- Lines 146-159 (backlog): item 4 (revive the headless scraper) and item 5 (better OCR) are abandoned; item 6 (persist queue) is done (`app.js:68-83, 1971-1988`).
- Still true: Electron 33 (`package.json:25`), `npm run auth` (`package.json:8`), the six non-negotiable rules (102-113, with the D16/D21 nuances).

#### 6. `RELEASE_NOTES.md` (v0.1.30)

- The version matches `package.json:3`. The file follows the four-part contract (`ship.md:31-62`): `# What's new in v0.1.30` with `##` groups, `# Install`, `## Requirements`, and `**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.29...v0.1.30`.
- The content is entirely Chrome-extension work: a popup **Reload** button when the loaded and on-disk versions differ, folder-mismatch detection, `/ping` returning `managedExtensionPath` (`extension-server.js:126-141`), and `chrome.storage.local.lastReloadAttempt`. Line 5 mentions "v0.1.29's silent-update flow", the only written trace of v0.1.29.
- Lines 26-30 (extension install steps) and 37 (Chromium requirement) do not apply to the Swift port.
- Line 32 (config and token per-user under `%APPDATA%\Roaming\robogears Downloader\` / `~/Library/Application Support/robogears Downloader/`) matches the packaged build (`electron-main.js:13, 19-21, 26-28`).

#### 7. `ship.md` (release process; not code)

- Never ship without an explicit instruction ("ship it", "publish", "release", "push it", "tag vX.Y.Z", or a close paraphrase) (5-17). Outside a ship, do not bump the version, edit release notes, commit, push or tag (15).
- On ship: bump the patch to the smallest unused `vX.Y.Z`. Minor bump "only for a large batch of new features", major only for breaking changes (23). Never force-move a published tag; an unpublished draft may be re-tagged with the owner's OK (25).
- Overwrite `RELEASE_NOTES.md` with the four-part body (27-62). Stage files by name, commit, `git push origin main`, `git tag -a vX.Y.Z -m "vX.Y.Z"`, push the tag (64-86). Wait for CI. Verify the body with `gh release view vX.Y.Z --json body --jq '(.body | length)'`; if 0, run `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md` and re-verify (92-106). Report the run and draft links (108-114). Keep `draft: true` (118).
- Line 127 says the empty body happens on every release, which fits the missing checkout in the release job (D36).
- **Conflict with the owner's global rule** (`~/.claude/CLAUDE.md`): bump the last number once, as soon as anything changes after the last push or publish, then hold it until the next push. The middle number moves only when the owner says so; the first version of a new project is `0.1.1`. `ship.md:15, 23` and `CLAUDE.md:746` instead say "no bump without a ship instruction" and let the agent choose a minor bump. The global file states that it overrides such guidance.

#### 8. `updater.md` drift (generic guide)

- Written mainly for the Windows **portable** target: lines 3, 15, 17, 303-357, 568-601 and 784 describe `PORTABLE_EXECUTABLE_FILE` and a `.cmd` relauncher that retries `move /Y` 30 times. NSIS appears only as an "alternative" (359-412). The repo uses NSIS.
- `getUpdateStatus` matches the asset substring `'.exe'` (126); the code matches `'setup.exe'` (`electron-main.js:154`).
- `canSelfInstall` checks `PORTABLE_EXECUTABLE_FILE` (313-318); the code returns `app.isPackaged && (win32 || darwin)` (`electron-main.js:194-200`).
- Windows quit delay 200 ms (353, 402); the code uses 500 ms on both platforms (`electron-main.js:467`). The macOS example at 556 already shows 500 ms.
- Temp names `app-update-*` / `app-mount-*`; the code uses `robogears-downloader-<ts>.dmg|.exe`, `robogears-mount-<ts>`, `robogears-update-<ts>/` and `robogears-update-<ts>.sh` (`electron-main.js:244-245, 292, 357`).
- The macOS script in the doc lacks the `RUNNING_FROM` and `TRANSLOCATED` variables (`electron-main.js:402-405`) and logs `attempts.log` with slightly different fields.
- No Spotify/Pathfinder section, despite `CLAUDE.md:298, 705`.
- Still valid: version compare (98-108, identical to `electron-main.js:103-113`), `/releases/latest` behaviour, redirect-following download, DMG mount + `ditto`, translocation check, double-fork relauncher, the gotchas table (682-699) and the patterns (703-724).

#### 9. `waveformplayback.md` drift (generic guide)

- Line 19 and §6 (345-397): one LRU map of `{peaks, blobUrl}`, max 3. The code splits it: `peaksCache` (unlimited `Map` of `Float32Array(200)`) and `audioCache` (LRU of 3 Blob URLs that never evicts the playing entry) (`app.js:543-550, 571-585`).
- Line 202: canvas `data-id`; the code uses `data-tidal-id` (`app.js:955`).
- Lines 230-231: `audio.volume = 0.6`; the code uses the squared slider curve (`app.js:506-513, 826`).
- Lines 318-326, 339: mousedown on a non-playing row's waveform does nothing. In the code it starts that track at the clicked position (`app.js:1158-1164`).
- Line 472: `min-width: 80px`; the code has `min-width: 0` so the title always wins (`styles.css:611-622`).
- Still true: `computePeaks` (200 bars, max-abs per bucket, normalized to the loudest bar; `app.js:587-606, 686`), `drawWaveform` constants (`app.js:608-650`), the three inline SVG icons (`app.js:653-655`), document-level scrub listeners (`app.js:1184-1191`), 120 ms resize debounce (`app.js:1209-1222`), `decodeAudioData(ab.slice(0))` when the bytes are also needed for the Blob (`app.js:717`).
- Line 18 ("one playing item at a time") holds for sequential clicks; two quick clicks on different rows can leave an untracked audio element playing (see Bugs).

#### 10. Release history (as recorded, plus what the code shows)

| Version | Change |
|---|---|
| v0.1.0 | Initial release: portable Windows `.exe`; blank folders on first launch; library scan only when a folder is set; `app.setName('robogears Downloader')`; Reset config; OCR drop-zone gated off with "Coming soon"; clown horn / download chime / warning honk; batch summary using exit code 2 for skips; CI workflow + `RELEASE_NOTES.md` via `body_path` |
| v0.1.1 | `publish: null` (electron-builder no longer auto-publishes) |
| v0.1.2 | macOS ad-hoc signing in the `afterPack` hook; `build/` un-ignored |
| v0.1.3 | (two tags consolidated) Launch-time update check; `shell.openExternal` for the TIDAL URL |
| v0.1.4 | TIDAL auth moved in-process (a spawned child failed with ENOENT inside asar) |
| v0.1.5 | Auth URL field + Copy; Settings → Updates with manual check; version in the topbar |
| v0.1.6 | Removed `cwd: __dirname` from all download spawns |
| v0.1.7 | Windows portable self-install via `.cmd`; ffmpeg `app.asar` → `app.asar.unpacked` rewrite; update IPCs |
| v0.1.8 | Accept any `application/vnd.tidal.*` manifest (BTS) |
| v0.1.9 | `audioQuality` as the primary FLAC signal; custom monochrome icon |
| v0.1.10 | macOS self-install; `__TRACK_*__` markers; per-row progress and batch bar; per-row Retry; streaming `downloadDirect` |
| v0.1.11 | Cancel button + cancel chime; Retry all / Retry selected; topbar logo |
| v0.1.12 | `nohup` + 500 ms quit delay on macOS; `start_app.command`; `.gitattributes` LF rule |
| v0.1.13 / v0.1.14 | Double-fork relauncher; logs in `~/Library/Logs/robogears Downloader/`; v0.1.14 is a validation bump |
| v0.1.15 | DMG target; App Translocation fix (install to `/Applications/`) |
| v0.1.16 | DMG art only |
| v0.1.17 | macOS DMG-only (asset-format bootstrap break for v0.1.16 users); FLAC picture type 3 for Rekordbox/Mixxx/Serato; quality-of-life batch (queue persistence, Settings tabs, Hi-Res badge, 100-cap warning, scan progress, FFmpeg check, log cap; the doc also credits these to v0.1.20) |
| v0.1.18 / v0.1.19 | Validation bumps, no code changes |
| v0.1.20 | Inline waveform preview; loading moved to a topbar pill (reverted in v0.1.23) |
| v0.1.21 | Volume slider; click any waveform to start there; background preloader (concurrency 2); success ping; peaks/audio cache split; stale-event guard `isCurrent()`; brand/version easter eggs; "made with love" signature |
| v0.1.22 | Title takes priority over waveform width |
| v0.1.23 | Full-screen loading overlay restored; README refresh |
| v0.1.24 | Windows NSIS installer (bootstrap break for v0.1.23 portable users); strict library matcher; `build:portable` removed |
| v0.1.25 | CSV/text import replaces the OCR placeholder; Exportify link; topbar **Update now** pill; `Matching N / M` progress; Tesseract CDN script and CSP exception removed; IPC `resolve:ocr-tracks` → `resolve:tracklist`; source `'ocr'` → `'import'` |
| v0.1.26 to v0.1.28 | No written record. The code in this range added the Chrome-extension bridge (`extension-server.js`, `chrome-extension/`, Settings → Extension, `sync-ext`). The sync script's comment uses "v0.1.27" as its example (`scripts/sync-extension-version.js:5-7`) |
| v0.1.29 | "Silent-update flow" for the extension (only mentioned at `RELEASE_NOTES.md:5`) |
| v0.1.30 | Extension popup Reload + folder-mismatch detection; `/ping` returns `managedExtensionPath` |

#### 11. Abandoned approaches (do not repeat)

1. **Monochrome web app on third-party Qobuz proxies.** The proxies went offline (`CLAUDE.md:284`; `ONBOARDING.md:127`).
2. **Spotify Client Credentials (app-only).** For new dev apps since Nov 2024, `/v1/playlists/{id}` returns 200 with no `tracks` field and `/v1/playlists/{id}/tracks` returns 403 (`CLAUDE.md:285, 810`).
3. **Spotify Authorization Code (user OAuth).** Same block in Development mode, even for the user's own playlists; lifting it needs Extended Quota Mode. Code removed (`CLAUDE.md:286, 811-812`). `.gitignore:3-4` still lists `spotify-credentials.json` and `spotify-token.json`.
4. **Hidden BrowserWindow scraping the Spotify web player with CDP.** `partition: 'persist:spotify'`; `Network.responseReceived` + `Network.getResponseBody` filtered on `pathfinder` / `api-partner.spotify`; JSON walk for `__typename: 'Track'`, deduped by URI; `executeJavaScript` auto-scroll. It hung on "Resolving link…" because the scroll-container selector never matched. The `spotify:scrape` IPC and `lib.setWebPlaylistScraper` are gone (no matches in any `.js`) (`CLAUDE.md:287, 300-311`).
5. **Anonymous web-player token from `/get_access_token`.** Returns 403 to unauthenticated callers since mid-2024 (`CLAUDE.md:288`). The CLI help text still says Spotify URLs are "resolved via Spotify's anonymous web API → ISRC match" (`tidal_download.js:83-84`), which is stale.
6. **Screenshot OCR drop-zone.** Tesseract.js from a CDN, `OCR_FEATURE_ENABLED = false`, a "Coming soon" badge and a clown horn. Replaced in v0.1.25. Leftovers: `package.json:4` description ("screenshot OCR"), comments at `app.js:2`, `app.js:166-167`, `electron-main.js:984`, `bulk_runner.js:2, 96`, and the unused `playClownHorn` (`app.js:194`).
7. **TIDAL v2 manifests (`/v2/trackManifests/`).** Returned 404 for single tracks; the function is now gone entirely (`CLAUDE.md:369-371`).
8. **Windows portable `.exe` with a `.cmd` polling swap** (`PORTABLE_EXECUTABLE_FILE`, 30 tries of `move /Y`). Replaced by the NSIS oneClick installer in v0.1.24. Leftover comments at `electron-main.js:191-193`, `electron-preload.js:18-19`, `app.js:390-391`. `build:portable` was removed because `--win portable` silently overrode the `nsis` target (`CLAUDE.md:410, 827-828`).
9. **Topbar loading pill** (v0.1.20). Reverted to the full-screen blur overlay in v0.1.23 (`index.html:222-230`).
10. **macOS `.zip` distribution.** Replaced by `.dmg` in v0.1.17.
11. **Auth as a spawned child with `cwd: __dirname`.** ENOENT inside asar; auth now runs in-process (`CLAUDE.md:168, 666-669`).
12. **`#similar-modal`.** Replaced by inline queue badges (`CLAUDE.md:818`).
13. **Lenient `artistOk` check.** Title-only matches were treated as exact; replaced by the strict rule in v0.1.24 (`CLAUDE.md:87`).
14. **Plain `detached + unref` macOS relauncher.** Killed by SIGHUP; replaced by the `nohup` double-fork (`CLAUDE.md:623, 829`).
15. **electron-updater.** Rejected because it needs a Developer ID and notarization on macOS (`CLAUDE.md:511`).
16. **Chrome-extension bridge** (v0.1.26 to v0.1.30). Support ended by the owner on 21 Oct 2026; not part of the Swift port.
17. **Never built:** Spotify Pathfinder GraphQL with a logged-in token harvest (`CLAUDE.md:298, 705`).

#### 12. Known rough edges (`CLAUDE.md:693-700`): status against the code

| # | Rough edge | Status |
|---|---|---|
| 1 | Spotify playlists over 100 tracks | Still applies: embed only (`tidal_lib.js:532-551`), warning at `app.js:1313-1315`. Workaround is the CSV / Exportify drop-zone (`app.js:1755-1858`); the extension route is being dropped |
| 2 | Library scan ~18 s for ~500 files, no disk cache | Still applies: scan cached in memory only (`tidal_lib.js:622-623, 674-757`), 8 concurrent tag reads (`tidal_lib.js:750`). No `library-cache.json` exists. Timing unverified (needs a run) |
| 3 | No macOS x64 build | Still applies (`package.json:85-87`, arm64 only) |
| 4 | softprops empty release body | Still applies; probable cause is the missing checkout (D36); unverified |
| 5 | Node 20 in CI | Both deadlines passed; workflow unchanged (D37); CI health unverified |
| 6 | `ffmpeg-static` postinstall flake in CI | Still applies (`package.json:21`; `npm ci` at `release.yml:20, 36`) |

Items 3 to 6 are Electron/CI concerns that the Swift port replaces.

#### 13. Backlog (`CLAUDE.md:702-711`; `BOT_PROMPT.md:145-159`): status

| Item | Status |
|---|---|
| Disk-cached library scan (`<userData>/library-cache.json` keyed by mtime/size) | Not built |
| Spotify Pathfinder GraphQL | Not built; its claimed write-up in `updater.md` does not exist |
| History / recent-downloads pane | Not built |
| macOS x64 / universal build | Not built |
| electron-updater | Not applicable to Swift |
| Move GitHub Actions to Node 24 | Not done |
| softprops empty-body root cause | Probably the missing checkout |
| Screenshots in `docs/` | No `docs/` folder exists |
| BOT_PROMPT extras | "Persist queue" done; "Better OCR" and "Revive headless scraper" abandoned |

#### 14. Code paths behind the product rules

##### 14.1 Input classification (link vs search)

Location: `tidal_lib.js:431-463`; `electron-main.js:658-687`; `app.js:66, 1276-1325`.

1. The renderer trims the input. If it is empty, nothing happens. If `token:exists` is false, it logs `⚠ Sign in to TIDAL first (Settings → Sign in).` and stops.
2. It shows the loading overlay with random funny text and a **Cancel** button that calls `resolve:cancel`.
3. The main process runs `parseInputUrl` in this order:
   - Spotify: `/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i`.
   - TIDAL URL: `/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i` (leftmost match wins, so `tidal.com/album/A/track/T` is album A).
   - Input made only of digits (`/^\d+$/`) → TIDAL track ID.
   - Bare UUID (`/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i`) → TIDAL playlist.
4. If parsed, resolve the link; if the cancel flag is set, return `{ok:false, cancelled:true}`; otherwise `{ok:true, kind:'url', tracks, capped}`.
5. If not parsed, run a TIDAL track search with limit 10 and return `{ok:true, kind:'search', tracks}`; the renderer opens the search modal.
6. Any exception returns `{ok:false, error: message}` and the renderer logs `✗ <message>`.
7. The renderer's `URL_RE` (`/^https?:\/\/|spotify\.com|tidal\.com/i`) only changes the hint under the input.

TIDAL artist/mix/video URLs, Spotify artist URLs, `spotify:` URIs and `spotify.link` short links are not parsed, so they become a free-text search of the URL string.

##### 14.2 Resolve results carry library status

Every resolver path (TIDAL link, Spotify link, search, CSV import, extension) calls `enrichWithLibraryStatus(tracks)` before returning. It runs `findInLibrary(title, artist, duration)` **sequentially** per track and sets `t.libraryMatch` on a hit, ignoring per-track errors (`tidal_lib.js:836-844`). Because `findInLibrary` awaits `scanLibrary()`, a resolve started while the launch-time scan is still running waits for the whole scan.

##### 14.3 Library scan and `findInLibrary` (read-only dedup)

Location: `tidal_lib.js:622-844`.

`scanLibrary(onProgress)`:
1. If `_libraryCache` is set, return it. If a scan promise is in flight, return that promise (its progress goes only to the caller that started it).
2. If `LIBRARY_PATH` is empty or missing on disk, return `{entries: []}`, which is also cached.
3. Walk the tree recursively with `readdirSync({withFileTypes:true})`; unreadable folders are skipped silently. Keep regular files whose lower-cased extension is in `{.flac, .m4a, .mp3, .wav, .aac, .ogg, .opus, .alac}`.
4. Call `onProgress(0, total)`.
5. Eight workers each take the next file:
   - `rawBase` = filename without extension; `filenameTitle` = text after the **last** `' - '` in `rawBase`, or `rawBase` if there is none.
   - `music-metadata.parseFile(path, {duration:true, skipCovers:true, skipPostHeaders:true})` → `metaTitle = common.title`, `metaArtist = common.artist || common.artists[0]`, `metaDuration = round(format.duration)`. A parse failure leaves them empty.
   - Push `{path, fnFull, fnTitleFull, fnCore, fnTitleCore, metaTitleFull, metaTitleCore, metaTitleDisplay, metaArtist, metaDuration}` (the `Full` forms use `normalizeFullForMatch`, the `Core` forms use `normalizeCoreForMatch`; `metaArtist` is full-normalized; `metaTitleDisplay` is the raw tag title).
   - Report progress when `done - lastReportedAt >= 25` or `done === total`.
6. Cache the result for the process lifetime. `rescanLibrary()` clears the cache and the in-flight promise; `setLibraryPath()` clears only the cache.

`findInLibrary(title, artist, _duration)`:
1. Empty title → `null`. Await the scan; no entries → `null`.
2. `tFull = normalizeFull(title)`, `tCore = normalizeCore(title)`. If `tCore` is empty or shorter than 3 characters → `null`.
3. `aFull = normalizeFull(artist)`. `artistsAgree(e)` = `aFull` non-empty **and** `e.metaArtist` non-empty **and** one contains the other as a substring.
4. Tier 1: first entry with `metaTitleFull === tFull` and `artistsAgree` → `{kind:'exact', path, libraryTitle: metaTitleDisplay || basename}`.
5. Tier 2: first entry with `metaTitleFull === tFull` → `similar` (same `libraryTitle` rule).
6. Tier 3: first entry with `fnTitleFull === tFull` or `fnFull === tFull` → `similar`, `libraryTitle` = basename.
7. Tier 4: one pass; for each entry, `metaTitleCore === tCore` → `similar` (meta title); else `fnTitleCore === tCore` or `fnCore === tCore` → `similar` (basename).
8. Otherwise `null`. Duration is never used.

##### 14.4 Queue include/exclude, Download all and post-batch pruning

Location: `app.js:890-1022, 1225-1272, 1361-1482`.

1. `addTracksToQueue` dedupes on `id:<tidalId>`, or `na:<title>|<artist>` when there is no ID. Each new row gets a random base36 key of up to 8 characters (`Math.random().toString(36).slice(2,10)`), is queued for waveform preloading if it has a `tidalId` and is not `notFound`, then the queue renders and saves after 400 ms.
2. On render, a row whose `included` is `undefined` gets `included = !(libraryMatch?.kind === 'exact')`, and that value is persisted. `excluded = !included && !notFound`.
3. Status badge, first match wins: `downloading` → `↓ N%`; `downloaded` → `✓ done`; `skipped` → `⏭ skipped`; `failed` → `✗ failed`; `notFound` → `not found`; exact → `📁 already in library` (tooltip = path); similar → `⚠ similar version in library` (tooltip = path); source `spotify` → `Spotify`, `import` → `Import`, `extension` → `Spotify ext`. The `Hi-Res` badge is independent. Exact/similar rows also show `Library: <libraryTitle>`.
4. Excluded rows are greyed (opacity 0.42) with a struck-through title and a bright **+ Add** button; clicking it sets `included = true`. **✕** removes the row (stopping its preview if playing).
5. Button label: `Download (N)` whenever any row is not downloadable (excluded **or** not found), otherwise `Download all`; `Downloading…` while a batch runs.
6. **Download all**: ignored if a batch is running or the queue is empty. No download folder → warning honk + `⚠ Pick a download folder in Settings first.`. No token → warning honk + `⚠ Sign in to TIDAL first (Settings → Sign in).`. `downloadable = rows with !notFound && included`; if none → warning honk + `⚠ Nothing in the queue can be downloaded.`. Otherwise: download chime, `=== Starting batch (N tracks) ===`, set each downloadable row to `dlStatus='queued'`, call `bulk:start {tracks, outDir}`.
7. Per-track events: `bulk:track-start` → `downloading`, 0%; `bulk:track-progress` → updates the badge and bar in place; `bulk:track-done` → status (`downloaded` sets 100%).
8. On `download:done {code}`: code 0 → success ping + `✓ Batch finished.` row with **Open folder** (if a download folder is set); otherwise `=== Exit code <code> ===`. Then the queue keeps only rows that are `notFound`, `dlStatus === 'failed'`, `dlStatus === 'notFound'`, or (`!dlStatus && included`). Everything else is removed: downloaded, skipped, excluded rows, and any row still `queued` or `downloading`. Remaining non-failed rows lose `dlStatus` / `dlPercent`. Render and save.
9. **Cancel** (only while a batch runs): cancel chime; button shows `Cancelling…`; `download:cancel`; then every `downloading` / `queued` row becomes `failed`; logs `⊗ Download cancelled.`.
10. **Retry**: per-row `↻ Retry` sends a one-track batch (logs `↻ Retrying <title>…`; refuses with `⚠ A batch is already running — retry once it finishes.`). The header button shows `↻ Retry selected (M)` when failed rows are ticked, else `↻ Retry all (N)` when 2 or more rows failed, else hidden. Both need a download folder.
11. A batch progress bar above the list shows `done / total` over rows with `included && !notFound` while a batch runs.

##### 14.5 `downloadTrack`: actual order of operations

Location: `tidal_download.js:346-469`.

1. `getToken` (refresh if `expires_at` passed), `getCountryCode`.
2. `GET /v1/tracks/{id}`.
3. `title = sanitize(info.title)`; candidate paths `<outDir>/<title>.flac` and `<outDir>/<title>.m4a`.
4. Unless `--force`: if the `.flac` exists, log `  ⏭  <title>.flac already in downloads folder — skipping (use --force to overwrite)` and return skipped; same for `.m4a`.
5. Unless `--force` or `--skip-library-check`: `findInLibrary(info.title, all artists joined ', ', info.duration)`. Exact → `  📁 Already in music library: <path>` + `     Skipping download (use --force to download anyway)`, skipped. Similar → `  ⚠ Similar version in music library: <libraryTitle or path>` + `     Skipping. Use --force or include via GUI to download anyway.`, skipped.
6. Log `  <first artist> — <title> (<album>)`.
7. Album info: pre-fetched (album mode) or `GET /v1/albums/{albumId}`, or `null`.
8. `getBestManifest`: try the forced tier, else `HI_RES_LOSSLESS` then `LOSSLESS`; the first request that does not throw wins; if both throw → `Could not get playback manifest at any quality.`
9. `parseManifest` (BTS JSON or DASH XML; non-`NONE` `encryptionType` → `Track is DRM-encrypted (<type>)`).
10. FLAC decision (D21). Not FLAC + `--flac-only` → log `  ⚠ AAC-only on TIDAL — skipped (--flac-only mode).` and throw `AacOnlyError`. Not FLAC otherwise → log `  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).`
11. `finalPath = <title>.flac|.m4a`; `tmpPath = <title>.tmp.m4a` if `manifest.mimeType` contains `mp4`, else `<title>.tmp.flac`.
12. If env `BULK_RUNNER_PROGRESS` is set, print `__TRACK_PROGRESS__:<id>:<pct>` whenever the integer percent changes (clamped 0-100).
13. In parallel: audio (DASH: init segment first, then `min(concurrency, segments)` workers with `fetchBuffer`, then one `writeFileSync` of the concatenation; direct: streamed write, no retry, 60 s idle timeout, follows 301/302/303/307/308 up to 5) and the cover (`fetchCover`, one retry, failure → no cover).
14. FFmpeg remux with tags and cover on stdin. On failure: `  ✘ FFmpeg failed: <msg>` + `     Raw file kept at: <tmp>`, rethrow.
15. Delete the temp file. For FLAC output run `verifyFlac`; failure only logs `  ⚠ FLAC integrity check failed: …`.
16. Log `  ✓ Saved: <file> (<MB> MB)`. Process exit code: 0 done, 2 single-track skip, 1 error.

##### 14.6 Token store and re-authentication

Location: `tidal_auth_node.js:15-171`; `tidal_lib.js:48-119`; `electron-main.js:610-642`.

1. Device flow: `POST https://auth.tidal.com/v1/oauth2/device_authorization`, form `client_id=<AUTH id>`, `scope=r_usr+w_usr+w_sub` (form-encoded, so `+` is sent as `%2B`).
2. The verification URL (`verificationUriComplete`) goes to `shell.openExternal` and to the renderer (`auth:url`), which shows it with **Copy**.
3. Poll `POST /v1/oauth2/token` every `interval` seconds (default 5; sleeps before each poll) with Basic auth from the AUTH pair, form `client_id`, `device_code`, `grant_type=urn:ietf:params:oauth:grant-type:device_code`, `scope`. 200 → save. 400 with `error: authorization_pending` → keep polling. Any other 400 or status → throw. No request timeout and no client-side attempt limit.
4. The saved entry stores the **REQUEST** pair (a different embedded pair) as `client_ID` / `client_secret`. Both pairs are base64 string literals at `tidal_auth_node.js:17-20`, decoded as `latin1`; their values are intentionally not reproduced here.
5. `saveToken` drops entries with the same `client_ID` **and** `refresh_token`, then **appends** the new entry.
6. Readers: `loadCred()` returns `entries[0]`; a missing file or an empty array calls `process.exit(1)`. `saveCred()` merges into `entries[0]`.
7. Refresh: `POST auth.tidal.com/v1/oauth2/token`, form `{client_id, refresh_token, grant_type: refresh_token, scope: r_usr+w_usr+w_sub}`, Basic auth with the stored pair, 30 s timeout. Sets `access_token`, `expires_at = now + (expires_in || 3600)·1000 − 60000`, fills `countryCode` from `json.user.countryCode` if missing. A new `refresh_token` in the response is not stored.
8. Country: cached `countryCode`, else `GET /v1/users/{userID}?countryCode=US`, else `'US'`.
9. GUI: `token:exists` only checks that the file exists. On success the auth modal closes after 1200 ms; on failure it shows `✗ Sign-in failed.` and stays open.

##### 14.7 CSV / text import parser

Location: `app.js:1755-1939`; `electron-main.js:919-982`.

1. Sources: a file dropped on `#drop-zone` (first file only); the file picker (`accept=".csv,.txt,text/csv,text/plain"`); a document paste when focus is not in an `INPUT`/`TEXTAREA`, the text is at least 10 characters, and it contains a newline, a comma or a spaced separator `/\s[-—–|]\s/`.
2. One import at a time; a second one is ignored while `_tracklistInFlight`.
3. `looksLikeCsv`: the first non-empty line contains `,` and splitting on line breaks gives at least 2 parts.
4. `parseCsv`: quoted fields (a quote opens only at the start of a field), `""` → `"`, `\r` dropped, `\n` ends a row.
5. Header lower-cased and trimmed. Title column = **first** header matching `/\btrack name\b|\btitle\b|\bsong\b|\bname\b/`; artist column = **first** header containing `artist`. No title column → fall back to plain text.
6. Rows with an empty title are dropped; rows dedupe on lower-cased `title|artist`.
7. Plain text: each trimmed non-empty line; `/^(.+?)\s*[-—–|\t]\s*(.+)$/` → Title, Artist; otherwise the whole line is the title. Titles under 2 characters are dropped; same dedupe.
8. No tracks → `✗ No tracks found in <source>.`; otherwise `📋 Parsed N track(s) from <source>. Matching against TIDAL…` and the overlay `Matching 0 / N tracks on TIDAL…` (no Cancel).
9. Main: for each track in order, search `"<title> <artist>"` (limit 10), score, take the best accepted candidate. Matched rows: TIDAL title, TIDAL artists joined `, `, TIDAL duration, `tidalId`, `source:'import'`, `matchMethod:'search'`, `notFound:false`, `originalTitle`, `originalArtist`; no `hiRes`. Unmatched: input title/artist, `tidalId:null`, `notFound:true`. Emit `tracklist:progress {done,total}` after each.
10. Renderer: `+ Added N from import. M matched on TIDAL, K not found.` (the `, K not found` part only when K > 0).

There is no token check before step 9 (see Bugs).

##### 14.8 Updater (summary for rules)

- Launch check: `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` (10 s timeout). Silent on error or no update. Newer = numeric segment compare after stripping `v`. Asset = first name containing `mac-arm64.dmg` (darwin) or `setup.exe` (win32); otherwise the release page URL (`electron-main.js:103-176`).
- Two UIs share the same backend: the activity-log row `🚀 New version available: <version>` with **Download update** → `Downloading N%` → **Restart to apply** → `Restarting…` (failure: `Download failed — retry`), and the topbar pill **Update now** → `Downloading N%` → auto-apply (failure: `Retry update`). If `canSelfInstall()` is false (dev or Linux), both open the URL in the browser.
- Apply: Windows spawns the installer with `/S --updated`; macOS writes and spawns the double-fork bash relauncher. Both quit after 500 ms (`electron-main.js:314-469`).

##### 14.9 Chrome-extension bridge (inventory only; support ended 21 Oct 2026)

`extension-server.js` (localhost HTTP server on `127.0.0.1:8273`, bearer token of 16 random bytes in hex stored in `<userData>/extension-token.txt`, unauthenticated `GET /ping`, `POST /queue/add` with a 256 KB body cap); `chrome-extension/` (`manifest.json`, `background.js`, `content.js`, `content.css`, `popup.*`, `options.*`, `icon.png`, `README.md`); `scripts/sync-extension-version.js`; `electron-main.js:24, 28, 497-522, 691-812`; `electron-preload.js:52-55`; `app.js:922, 1587-1647`; `index.html:119, 162-186`; `package.json:12, 46, 60-65`. Extension tracks are matched by title+artist search and get `source:'extension'`; the bundled extension is copied into `<userData>/chrome-extension` when its manifest version is newer. Comments at `electron-main.js:504-505, 761-763` and the hint at `index.html:185` describe a popup **Update** button and `handleExtensionUpdateSelf`; neither exists (the popup has **Save** and **Reload** only, `chrome-extension/popup.html:18, 28`). None of this is ported.

---

### Data formats

| Name | Location | Shape | Notes |
|---|---|---|---|
| `token.json` | `tidal_auth_node.js:53-59, 148-158`; `tidal_lib.js:48-68` | JSON array, 4-space indent, of `{access_token, refresh_token, userID:number, countryCode, expires_at:ms epoch (already minus 60000), client_ID, client_secret}` | Path: `$TIDAL_TOKEN_PATH`, else `<source dir>/token.json`; packaged builds use `<userData>/token.json`. Readers use `entries[0]`; re-auth appends. Holds secrets: never print, commit or open |
| `settings.json` | `electron-main.js:26, 38-52, 555-565`; `app.js:516-524` | `{downloadFolder:string, libraryFolder:string, volume:number 0..1}`, 2-space JSON | `<userData>/settings.json`. Missing or corrupt → `{}` (looks like first launch). Each save writes the whole object it is given. `volume` is the linear slider position |
| `queue.json` | `electron-main.js:27, 594-606`; `app.js:61, 71-83, 1971-1988` | Array of `{tidalId:number\|null, title, artist, duration:seconds, source:'tidal'\|'spotify'\|'import'\|'extension', matchMethod:'direct'\|'search'\|'isrc'\|null, notFound?:bool, hiRes?:bool, album?:string (search rows), libraryMatch?:{kind:'exact'\|'similar', path, libraryTitle}, originalTitle?, originalArtist?, key:string, included:bool}` | Transient `dlStatus` (`queued`\|`downloading`\|`downloaded`\|`skipped`\|`failed`\|`notFound`), `dlPercent`, `selected` are stripped before saving. `libraryMatch` is computed at resolve time and never recomputed. Spotify rows whose matching threw lack `matchMethod` and `hiRes` |
| `pending-tracklist.json` | `electron-main.js:991-992, 1037`; `bulk_runner.js:53` | `{tracks:[queue items], outDir:string}`, 2-space JSON | `<userData>/pending-tracklist.json`, deleted when the runner closes. The header comment at `bulk_runner.js:4-5` shows the old shape `[{title, artist}]` |
| Bulk stdout markers | `bulk_runner.js:97, 104, 110`; `tidal_download.js:439`; `electron-main.js:1004-1019` | `__TRACK_START__:<tidalId>`, `__TRACK_PROGRESS__:<tidalId>:<0-100>`, `__TRACK_DONE__:<tidalId>:<downloaded\|skipped\|failed\|notFound>` | Parsed with `/^__TRACK_START__:(\d+)$/`, `/^__TRACK_PROGRESS__:(\d+):(\d+)$/`, `/^__TRACK_DONE__:(\d+):(\w+)$/` into `bulk:track-start {tidalId}`, `bulk:track-progress {tidalId, percent}`, `bulk:track-done {tidalId, status}`. Other non-empty lines (stdout and stderr, split on `\r?\n`) become `download:line` |
| `RELEASE_NOTES.md` contract | `ship.md:31-62`; `CLAUDE.md:470` | `# What's new in vX.Y.Z` + `## <group>` bullets, `---`, `# Install` (per-platform bullets), optional config line, `## Requirements`, `---`, `**Full Changelog**: https://github.com/<owner>/<repo>/compare/v<PREV>...v<CURR>` | Current version only; overwritten on each ship |
| TIDAL playback manifest | `tidal_download.js:107-169`; `electron-main.js:823-853, 873-917` | `playbackinfopostpaywall` JSON `{manifestMimeType, manifest (base64), audioQuality}`. `application/vnd.tidal.*` decodes to JSON `{mimeType, codecs, encryptionType, urls[]}`. `application/dash+xml` decodes to XML with `<BaseURL>`, `SegmentTemplate initialization="…" media="…$Number$…" startNumber="…"`, `<SegmentTimeline><S d=… r=…/>` | `r=N` means N+1 segments; `startNumber` defaults to 1; XML entities `&amp; &lt; &gt; &quot; &apos;` unescaped in URLs. DASH with no `SegmentTemplate` but a `BaseURL` is a direct URL (`audio/flac`) |
| Spotify embed entity | `tidal_lib.js:474-551` | `<script id="__NEXT_DATA__">` JSON → `props.pageProps.state.data.entity` `{id, name\|title, subtitle, artists[{name}], duration (ms), trackList[{uri:'spotify:track:<id>', title, subtitle, duration}], description}` | No ISRC. `subtitle` split on commas not inside parentheses. `_embedCapped = trackList.length >= 100` |
| macOS update logs | `electron-main.js:354-371, 385-441` | `~/Library/Logs/robogears Downloader/attempts.log` (appended before the spawn: time, parent pid, app bundle, new app, script, log) and `update-<ts>.log` (bash `set -x` trace) | Script written to `os.tmpdir()/robogears-update-<ts>.sh`, mode 755, deletes itself |
| `extension-token.txt` | `electron-main.js:28`; `extension-server.js:43-60` | Hex token | Extension only; not ported. Do not open |

---

### External interfaces

| Interface | Location | Detail |
|---|---|---|
| TIDAL device flow | `tidal_auth_node.js:76-170` | `POST https://auth.tidal.com/v1/oauth2/device_authorization`; poll `POST https://auth.tidal.com/v1/oauth2/token`. Headers: `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`, `Accept-Language: en-US,en;q=0.9`, `X-Platform: android`, `Content-Type: application/x-www-form-urlencoded`; Basic auth on polls |
| TIDAL token refresh | `tidal_lib.js:70-95` | `POST auth.tidal.com/v1/oauth2/token`, Basic auth with the stored pair, 30 s timeout |
| TIDAL API | `tidal_lib.js:156-302, 562` | `https://api.tidal.com` with `Authorization: Bearer`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`. `GET /v1/tracks/{id}`, `/v1/albums/{id}`, `/v1/albums/{id}/items?limit=100&offset=`, `/v1/playlists/{uuid}`, `/v1/playlists/{uuid}/items?limit=100&offset=` (both paginate until a page returns fewer than 100), `/v1/tracks/{id}/playbackinfopostpaywall?audioquality=&playbackmode=STREAM&assetpresentation=FULL`, `/v1/search/tracks?query=&limit=10`, `/v1/tracks?isrc=` (never reached), `/v1/users/{userID}`. Every call adds `countryCode`. No retries; 30 s idle timeout |
| TIDAL media | `tidal_lib.js:174-232, 846-857`; `tidal_download.js:215-256` | Segment / direct URLs from the manifest; cover `https://resources.tidal.com/images/<coverId with '-'→'/'>/1280x1280.jpg` |
| Spotify public embed | `tidal_lib.js:472-489` | `GET https://open.spotify.com/embed/{track\|album\|playlist}/{id}` with a Chrome 120 Windows User-Agent and `Accept: text/html` |
| GitHub Releases | `electron-main.js:115-162, 204-235` | `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest` (`User-Agent: robogears-downloader/<version>`, `Accept: application/vnd.github+json`, 10 s timeout, non-200 → treated as error). Uses `tag_name`, `html_url`, `assets[].name`, `assets[].browser_download_url`. Asset download follows up to 5 redirects (301/302/303/307/308), 60 s idle timeout |
| exportify.net | `app.js:1813-1816`; `index.html:52` | Opens `https://exportify.net` in the browser |
| FFmpeg | `tidal_download.js:32-36, 260-321`; `electron-main.js:529-546` | Remux: `-y -i <tmp> [-f mjpeg -i pipe:0] -map 0:a [-map 1:v -disposition:v attached_pic] -c:a copy [-c:v copy -metadata:s:v title=Album cover -metadata:s:v comment=Cover (front)] -metadata title=… artist=… album=… album_artist=… track=… disc=… date=<YYYY> copyright=… isrc=… <dst>` (empty values omitted). Verify: `-v error -i <file> -f null -`. Startup probe: `-version` |
| macOS tools (updater) | `electron-main.js:241-286, 385-459` | `hdiutil attach -nobrowse -quiet -mountpoint <tmp> <dmg>`; `ditto <src.app> <staging>`; `hdiutil detach -quiet`; bash script with `nohup`, `ps -p`, `xattr -dr com.apple.quarantine`, `mv`, `codesign --force --deep --sign -`, `open` |
| Windows installer | `electron-main.js:321-336` | `<setup.exe> /S --updated`, detached, hidden |
| Localhost extension server | `extension-server.js:17-18, 107-201` | `127.0.0.1:8273`; dropped |

---

### Constants and magic values

| Name | Value | Location | Meaning |
|---|---|---|---|
| `USER_AGENT` | `okhttp/5.3.2` | `tidal_lib.js:14`; `tidal_download.js:220`; `tidal_auth_node.js:77` | UA for TIDAL API, auth and media |
| `DEFAULT_TIMEOUT` | 30000 ms | `tidal_lib.js:15` | Socket-idle timeout for API and `fetchBuffer` |
| `DEFAULT_RETRIES` / backoff | 3; `min(1000·2^attempt, 8000)` ms | `tidal_lib.js:16, 186` | `fetchBuffer` only; retries network errors, timeouts, 429 and 5xx; other non-200 fail at once |
| `fetchBufferOnce` redirects | 301/302/307 only, at most 5 | `tidal_lib.js:199-204` | 303/308 are treated as errors here; `downloadDirect` and the updater also follow 303/308 |
| `LIBRARY_EXTS` | `.flac .m4a .mp3 .wav .aac .ogg .opus .alac` | `tidal_lib.js:25` | Files indexed |
| Library scan concurrency / progress | 8 workers; report every 25 files and at the end | `tidal_lib.js:744, 750` | — |
| Minimum core title length | 3 | `tidal_lib.js:795` | Shorter titles are never deduped |
| `normalizeFullForMatch` | lower-case → `/[^a-z0-9 ]/g`→space → `/\s+/g`→space → trim | `tidal_lib.js:626-629` | Same norm used in all TIDAL match scorers |
| `normalizeCoreForMatch` | lower-case; cut at first `(` or `[` if its index > 0; strip `/\s+(feat\|ft\|featuring)\.?\s+.*$/i`; strip `/\s+-\s+(remix\|edit\|mix\|extended\|radio\|original\|instrumental\|acoustic\|live\|remaster(?:ed)?\|version\|club\|vip\|dub\|bootleg\|rework\|reprise\|demo\|single\|album)\b.*$/i`; then the full norm | `tidal_lib.js:635-653` | Core title |
| Match scoring | Title: exact 100, either startsWith 50, either includes 25. Artist: % of wanted-artist tokens longer than 2 characters found as substrings in the candidate's joined, normalized artist names. Duration (Spotify-URL path only): <3 s 50, <8 s 25. Accept if title = 100 **or** (title ≥ 25 **and** artist ≥ 50); highest total wins | `tidal_lib.js:580-610`; `electron-main.js:712-727, 944-959`; `bulk_runner.js:11-29, 79` | Four copies |
| Spotify resolve workers | 8 | `tidal_lib.js:399` | Parallel Spotify → TIDAL matching |
| `_embedCapped` | `trackList.length >= 100` | `tidal_lib.js:549` | Cap flag |
| `SPOTIFY_UA` | `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36` | `tidal_lib.js:472` | — |
| `sanitize` | `(str \|\| 'unknown')`, replace `/[\\/:*?"<>\|]/g` with `_`, collapse whitespace, trim | `tidal_lib.js:616-618` | Only a null/undefined/empty input becomes `unknown`; a whitespace-only title becomes `''` |
| Cover size | 1280×1280 | `tidal_lib.js:846` | — |
| `CONCURRENCY_DEFAULT` | 8 | `tidal_download.js:38` | DASH segment workers |
| `FLAC_QUALITIES` | `['HI_RES_LOSSLESS','LOSSLESS']` | `tidal_download.js:39` | Request order; also the only values `--quality` accepts |
| `FLAC_QUALITY_TIERS` | `{LOSSLESS, HI_RES_LOSSLESS, HI_RES}` | `tidal_download.js:401` | `audioQuality` values treated as FLAC |
| `DEFAULT_OUT_DIR` | `Z:\Downloads` | `tidal_download.js:40` | CLI fallback; Windows-only path |
| `downloadDirect` timeout | 60000 ms idle, no retry | `tidal_download.js:252` | BTS direct download |
| Preview fetch | quality `LOSSLESS`; `fetchBuffer` timeout 60000, retries 2; 8 DASH workers; MIME `json.mimeType \|\| 'audio/flac'` (BTS), `audio/flac` (DASH direct), `audio/mp4` (DASH segments) | `electron-main.js:858-910` | — |
| Update check | 10000 ms; asset substring `mac-arm64.dmg` / `setup.exe`; fallback `html_url` | `electron-main.js:125, 153-160` | — |
| Quit delay after apply | 500 ms | `electron-main.js:467` | Docs say 200 ms |
| Relauncher parent wait | 30 × 1 s | `electron-main.js:407-410` | — |
| Window | 980×740, min 720×540, background `#0a0a0a`, title `robogears Downloader`, `autoHideMenuBar`, `contextIsolation:true`, `nodeIntegration:false`, `sandbox:false` | `electron-main.js:74-88` | — |
| `ACTIVITY_LOG_MAX` | 2000 lines (the welcome line is never the one trimmed) | `app.js:54, 350-357` | — |
| `PREVIEW_FEATURE_ENABLED` | `true` | `app.js:58` | Feature flag |
| Timers | queue save 400 ms; volume save 300 ms; resize redraw 120 ms; loading text cycle 2500 ms; "Check for updates" label revert 2500 ms; Copy feedback 1500 ms (auth) / 1200 ms (extension); auth modal close 1200 ms after success | `app.js:82, 523, 1221, 302, 1669-1672, 1752, 1620, 1725` | — |
| Waveform | 200 bars; spotlight radius 10 bars, boost `1+(1−d/10)·0.45`; bar height `max(1, peak·h·0.78·boost)`, bar width `max(1, w/n − 1)`; played `#ffffff`, unplayed `rgba(255,255,255,0.22)`; cursor line `rgba(255,255,255,0.55)` 1 px wide, inset 2 px; canvas height 22; a bar counts as played when `(i+0.5)/n <= progress` | `app.js:608-650, 686, 955` | — |
| Preview caches | `MAX_AUDIO_CACHE` 3 (LRU, never evicts the playing entry); `peaksCache` unlimited; preloader concurrency 2 | `app.js:543-559` | — |
| Volume curve | audio = `clamp(slider,0,1)²`; default slider 0.5; HTML slider `min=0 max=100 value=50` | `app.js:506-513`; `index.html:68` | — |
| Sound effects | Download chime: sine pairs (second osc ×1.005), C5 523.25 Hz for 0.13 s then G5 783.99 Hz at +0.09 s for 0.18 s, attack 12 ms to 0.22. Cancel: G5 0.10 s then C5 at +0.07 s for 0.15 s. Success: G5 783.99, C6 1046.50, E6 1318.51 at +0/+0.07/+0.14 s for 0.28/0.32/0.42 s, attack 8 ms. Warning honk: sawtooth 220 Hz (0.17 s) then 165 Hz at +0.22 s (0.22 s), each gliding from ×1.08 to the target over half its length, lowpass 1100 Hz Q 1, peak 0.3. Clown horn (unused): 420 → 310 Hz, lowpass 1800, peak 0.35. Fart: sawtooth 95→48 Hz ×`pitchScale` over 0.42 s, LFO `17·√pitchScale` Hz, depth `18·pitchScale`, lowpass `480·pitchScale` Q 2.2, gain 0.42 → 0.32 → silence; version click `pitchScale: 7`. All start 20 ms after `currentTime` | `app.js:110-270, 495-499` | — |
| `FUNNY_LOADING` | 10 strings: "Searching the seven seas for your music…", "Digging through the record crates…", "Asking TIDAL nicely…", "Following the bass line…", "Tracking down these bangers…", "Bribing the algorithm…", "Polishing the vinyl…", "Listening for the drop…", "Tuning the frequencies…", "Whispering to the music gods…" | `app.js:271-282` | Never repeats the same line twice in a row |
| CSP | `default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; worker-src 'self' blob:;` | `index.html:5` | Renderer only |
| Theme tokens | `--bg #000000`, `--bg-elev #0a0a0a`, `--panel #050505`, `--card #0d0d0d`, `--border #1a1a1a`, `--border-strong #2a2a2a`, `--text #ffffff`, `--text-muted #9a9a9a`, `--text-dim #5a5a5a`, `--error #ff6b6b`; status: similar `#fcd34d` on `rgba(245,158,11,0.18)`, done `#86efac` on `rgba(34,197,94,0.18)` | `styles.css:1-22, 660-663, 700-703` | — |
| Extension server (dropped) | port 8273, host 127.0.0.1, token 16 bytes hex, body cap 256 KB | `extension-server.js:17-18, 39-41, 97` | — |

---

### Rules and invariants

| Rule | Status | Evidence |
|---|---|---|
| GUI download folder starts blank; no `DEFAULT_DOWNLOAD` constant | Holds | `electron-main.js:26, 38-41`; `app.js:60` |
| Download all, Retry and Retry all are blocked without a folder (warning honk + `⚠ Pick a download folder in Settings first.`); main also refuses with `No download folder configured. Pick one in Settings.` | Holds | `app.js:1102-1106, 1403-1407, 1421-1425`; `electron-main.js:988` |
| Welcome line reflects state: no token → `👋 Welcome! Click the ⚙ icon to sign in to TIDAL.`; no folder → `Pick a download folder in Settings to get started.`; else `Ready. Downloads go to: <folder>` | Holds | `app.js:1960-1966` |
| CLI fallback output folder `Z:\Downloads` | Partly: only `tidal_download.js` (40, 687); `bulk_runner` uses `outDir` from its list file and has no fallback | `bulk_runner.js:53, 105` |
| Output is flat, no album/playlist subfolders; Settings hint "Every download goes here directly — no subfolders." | Holds | `tidal_download.js:497, 557, 595, 634`; `bulk_runner.js:35`; `index.html:131` |
| Filename = `sanitize(TIDAL title)` + `.flac` / `.m4a`; no artist or track number | Holds | `tidal_download.js:352-356, 425-426` |
| Skip-if-exists checks `<Title>.flac` and `<Title>.m4a`; `--force` overrides | Holds; a different song with the same title is skipped | `tidal_download.js:358-366` |
| CLI library check skips exact **and** similar matches unless `--force` / `--skip-library-check` | Holds; runs after the track-info fetch | `tidal_download.js:370-383` |
| GUI reviews library matches inline (no modal): exact excluded by default (greyed, struck through, `📁 already in library`, **+ Add**); similar included by default with `⚠ similar version in library` | Holds | `app.js:899-934`; `styles.css:660-669` |
| Exact requires known artist on both sides with substring overlap; filename matches are never exact | Holds | `tidal_lib.js:800-822` |
| Queue is the source of truth; `bulk_runner` always passes `--skip-library-check` | Holds | `bulk_runner.js:35` |
| Library is never written to | Holds in code (scanner only reads), but nothing stops the user choosing a download folder that is the library folder or inside it | `tidal_lib.js:687-727`; `electron-main.js:42-52`; `app.js:1517-1540` |
| Quality: `HI_RES_LOSSLESS`, then `LOSSLESS` if that request throws, then `.m4a` when the result is not FLAC; `--flac-only` opt-in, never passed by the GUI | Holds | `tidal_download.js:39, 325-342, 400-426`; `bulk_runner.js:35` |
| `audioQuality` is the primary FLAC signal | Holds | `tidal_download.js:400-404` |
| Cover art is an in-memory buffer piped as `-f mjpeg -i pipe:0`; never a temp `.cover.jpg`; picture tagged `comment=Cover (front)` (FLAC picture type 3) | Holds | `tidal_lib.js:851-857`; `tidal_download.js:289-309` |
| Tags: title, artist (all artists joined `, `), album, album_artist (album artist → track album artist → first artist), track, disc, date (first 4 characters of album `releaseDate` → track album `releaseDate` → `streamStartDate`), copyright, isrc; empty values omitted | Holds | `tidal_download.js:276-306` |
| No Spotify API credentials or OAuth; public embed only; 100-track cap warning shown | Holds | `tidal_lib.js:465-551`; `app.js:1313-1315` |
| Queue persists across restarts with transient fields stripped | Holds | `app.js:71-83, 1971-1988` |
| After a batch, downloaded and skipped rows are removed; failed and not-found rows stay | Holds, but excluded rows and rows still `queued`/`downloading` are also removed | `app.js:1465-1481` |
| Preview volume: squared curve, 50% default, persisted | Drifted: startup slider shows the squared value | `app.js:1947-1948` |
| Reset config clears both folders and keeps the TIDAL sign-in; confirm text "Forget the download folder and music library folder?\n\n(Your TIDAL sign-in stays.)"; logs `⚙ Config reset. Pick a download folder in Settings to continue.` | Drifted: also deletes the saved volume | `electron-main.js:561-565`; `app.js:1569-1577` |
| One preview plays at a time; hold-to-scrub only on the playing track; clicking another row's waveform starts it at the clicked point | Holds for sequential clicks; a fast double switch can leave a stray player (see Bugs) | `app.js:769-881, 1144-1165` |
| Launch update check is silent on error/no update; two update UIs share one backend; `/releases/latest` returns published releases only | Holds | `electron-main.js:145-176, 489`; `app.js:371-489` |
| macOS self-install: translocation check, install to `/Applications/<name>.app` when translocated, quarantine strip, `.bak` backup and rollback, ad-hoc re-sign, `open`, logs in `~/Library/Logs/robogears Downloader/` | Holds | `electron-main.js:337-460` |
| Electron-only rules: no `cwd: __dirname` in spawns; asar → asar.unpacked rewrite for ffmpeg; `TIDAL_TOKEN_PATH` honoured; `publish: null`; afterPack ad-hoc signing; `draft: true`; no `build:portable` | Hold | `tidal_download.js:32-36`; `electron-main.js:529-537`; `tidal_lib.js:13`; `package.json:32-33`; `release.yml:55` |
| Library scan runs only when a library folder is set; re-scans on every launch | Holds | `electron-main.js:481-485`; `tidal_lib.js:680-682`; `index.html:144` |
| Monochrome theme except status colours; no emoji in identifiers or filenames (emoji in log strings allowed) | Holds | `styles.css:1-22, 660-708` |
| Loading text short and music-themed, cycling every 2.5 s; easter eggs (brand click = fart, version click = 7× pitch) | Holds | `app.js:271-303, 495-499` |
| Process: never auto-release; commit/push/tag/edit `RELEASE_NOTES.md` only on an explicit ship instruction; notes hold the current version only, in four parts; never force-move a published tag; always verify the release body | Process rule (not code). Versioning part conflicts with the owner's global rule (see §7), which says it overrides | `CLAUDE.md:746-747, 830-833`; `ship.md` |

#### User-visible strings tied to these rules (not listed above)

| Trigger | String |
|---|---|
| Link resolved | `+ Added N track(s) from link (M not on TIDAL).` (the parenthesis only when M > 0) |
| Resolve cancelled / failed | `⊗ Resolve cancelled.` / `✗ <error>` |
| Search picks added | `+ Added N track(s) from search.`; modal title `Search results for "<query>"`, hint `N result(s). Pick the ones to add to your queue.` |
| Queue restored | `↺ Restored N track(s) from your last session.` |
| Library folder | `📁 Music library folder set to: <folder>`; `📁 Music library folder cleared (duplicate check disabled).`; `📁 Library re-scanned: N files indexed.` |
| Library status (Settings) | `Scanning…`, `Scanning N / M…`, `N file(s) indexed`, `(no library folder set)`, `(scan failed)`, `Scan failed` |
| FFmpeg missing | `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` |
| Preview errors | `✗ Preview playback failed (<code or ?>).`; `✗ Preview: <message>` |
| Auth status | `✓ Signed in` + **Re-authenticate** / `Not signed in` + **Sign in to TIDAL** |
| Manual update check | `Checking…` → `<version> available!` / `Up to date ✓` / `Check failed`, reverting after 2.5 s |
| Batch runner | `=== Batch download → <outDir> ===`, `N tracks queued.`, `[i/N] <title> — <artist>`, `    → matched (id X, score Y)`, `    → no good match`, `    → search error: …`, `=== Batch complete: a downloaded, b skipped, c failed, d not found ===` |

---

### Edge cases and failure modes

- A search made only of digits (for example "1999" or "22") is treated as a TIDAL track ID, and a bare UUID as a playlist, so the user never sees search results for it (`tidal_lib.js:438-444`).
- Titles whose core form is under 3 characters ("Go", "22", fully non-Latin titles) are never matched against the library (`tidal_lib.js:795`).
- Non-Latin or accented titles normalize to `''` or get cut (`Beyoncé` → `beyonc`). In TIDAL match scoring an empty wanted title gives every candidate at least 50 (`startsWith('')`), and an empty candidate title scores 100, so the first non-Latin result is accepted whatever its real title (`tidal_lib.js:580-590`; `electron-main.js:944-951`).
- Two different songs with the same title in one output folder: the second is skipped as "already in downloads folder" (`tidal_download.js:359-366`).
- Library filenames with several `' - '` parts use the text after the last one, so `Artist - Song - Extended Mix` gives `Extended Mix` (`tidal_lib.js:717-718`).
- A Spotify playlist of exactly 100 tracks is flagged as capped (`tidal_lib.js:549`).
- TIDAL artist/mix/video URLs, Spotify artist URLs, `spotify:` URIs and `spotify.link` short links become free-text searches of the URL string (`tidal_lib.js:431-463`).
- `tidal.com/album/<A>/track/<T>` resolves album A (`tidal_lib.js:435`).
- Plain-text import splits on the first `-`, `—`, `–`, `|` or tab even without spaces, so `Jay-Z - Song` becomes title "Jay", artist "Z - Song". The order is always Title then Artist (`app.js:1928`).
- CSV import takes the **first** header that matches the title pattern, and `\bname\b` also matches "Artist Name" and "Album Name". A CSV whose artist or album column comes before the track-title column gets the wrong title column (`app.js:1903`). The artist column is the first header containing "artist", so an ID/URI column listed before the name column would be used (`app.js:1904`).
- A library file with no artist tag can at best be `similar`, never `exact`. `.aiff`, `.aif`, `.wma` and other extensions are not indexed (`tidal_lib.js:25`).
- A link or search started while the launch-time library scan is still running waits for the whole scan, with only the funny loading text shown (`tidal_lib.js:676, 790, 836-844`).
- A failed FLAC integrity check only logs a warning; the file is kept and the exit code is 0 (`tidal_download.js:313-321, 464`).
- If FFmpeg fails, `<Title>.tmp.<ext>` is left in the output folder. A BTS download that fails mid-stream also leaves a partial `.tmp` file (`tidal_download.js:231, 456-459`).
- CLI `--concurrency` with a non-numeric value or 0 gives zero workers; the media-segment results are all `undefined` and `Buffer.concat` throws a TypeError, so the track fails with nothing written (`tidal_download.js:63, 203-207`). The GUI never passes `--concurrency`.
- With no `token.json`, a restored queue makes the preview preloader call `loadCred`, which exits the app (`app.js:1984-1986`; `electron-main.js:875`). One concrete route: dev builds keep the token next to the source, packaged builds in userData, while `queue.json` is in userData for both, so the first packaged launch after dev use has a queue but no token.
- Changing the library folder or rescanning while a scan is running can leave the old folder's entries cached (`tidal_lib.js:28-31, 754-755, 760-763`).
- On macOS, closing the window kills the batch runner but the app keeps running; its later output and `close` event call `mainWindow.webContents.send` with no `isDestroyed()` check (`electron-main.js:548-551, 1007-1035`). The runtime effect is unverified (needs a run).
- Clicking both update UIs starts two downloads; `global._pendingUpdatePath` is overwritten by whichever finishes last, and both progress handlers see both streams (`app.js:400-477`; `electron-main.js:288-312`).
- A restored queue keeps the `libraryMatch` computed in an earlier session even if the library changed since (`app.js:1971-1988`).
- Clearing the activity log removes the welcome line; an update notice that arrives afterwards is stored as pending and never shown (the pill still appears) (`app.js:361, 371-375`).
- The tracklist import overlay has no Cancel; a long import cannot be stopped (`app.js:1841`).
- A `token.json` that exists but holds `[]` passes `token:exists` and then exits the app on the first `loadCred` (`electron-main.js:610-613`; `tidal_lib.js:55-58`).

---

### Bugs and oddities

Ordered most severe first.

1. **High: `loadCred()` exits the Electron main process.** `tidal_lib.js:48-58` calls `process.exit(1)` when `token.json` is missing or empty. Main calls it from `resolve:tracklist` (`electron-main.js:925`), `preview:get-audio` (`:875`) and the extension handler (`:702`), and the renderer checks `tokenExists` only before link/search input and Download all (`app.js:1290, 1426`). Dropping or pasting a CSV before signing in, pressing play on a row, or launching with a restored queue and no token closes the whole app. The code path is direct; the runtime effect is unverified (needs a run).
2. **High: re-authenticating does not replace the credentials in use.** `saveToken` appends the new entry after filtering only exact duplicates (`tidal_auth_node.js:53-59`), while `loadCred` and `saveCred` always use `entries[0]` (`tidal_lib.js:54-59, 62-67`). After a re-auth the old refresh token stays in use, so a revoked token cannot be fixed by signing in again, and a different account is never picked up.
3. **Medium: Cancel kills only `bulk_runner`.** `download:cancel` signals `activeChild` (the runner) and sets it to `null` (`electron-main.js:646-653`). The `tidal_download.js` child (spawned with `stdio: 'inherit'`, not detached; `bulk_runner.js:41-44`) keeps downloading and writes its file after the user cancelled. Because that child holds the runner's inherited stdout/stderr pipes, Node's `close` event for the runner probably fires only when the child exits, so `download:done` (and the end of `Cancelling…`) is likely delayed until the in-flight track finishes; unverified (needs a run). The renderer keeps its buttons disabled until `download:done`, so a second batch cannot start in the meantime.
4. **Medium: the post-batch prune deletes rows that never got a final status.** The filter at `app.js:1468-1473` keeps only `notFound`, `failed`, or (`!dlStatus && included`) rows. If `bulk_runner` dies early (for example a token refresh failure is caught at `bulk_runner.js:56-58, 115-118` and exits 1), every row still marked `queued` is removed and the shortened queue is saved (`app.js:1481`). The comment above the filter says such rows are reset, but the filter drops them first.
5. **Medium: the library scan race applies the wrong folder.** `setLibraryPath` clears `_libraryCache` but not `_libraryScanPromise` (`tidal_lib.js:28-31`). Changing the folder during the launch-time scan makes `saveSettings` (`electron-main.js:45-50`) receive the old folder's in-flight promise; when it finishes, `tidal_lib.js:754` caches the old folder's entries and `:755` clears the promise, which can also wipe a newer scan's promise. Dedup decisions then use the old folder until a manual Refresh or restart.
6. **Medium: a failed sign-in leaves an auth modal that cannot be closed.** The auth modal has no close button or `data-close` element (`index.html:206-220`), there is no Escape or backdrop handler (`app.js:322-326`), and the modal closes only on success (`app.js:1722-1728`). On failure it shows `✗ Sign-in failed.` over the whole window (`styles.css:883-893`) and the user must quit the app. A pending sign-in also cannot be cancelled.
7. **Low: a batch with failed tracks counts as success.** `bulk_runner` never sets a non-zero exit code for per-track failures (`bulk_runner.js:63-118`), so the GUI plays the success ping and shows `✓ Batch finished.` (`app.js:1457-1462`); the failed rows do keep their `✗ failed` badges. A cancelled run shows `=== Exit code null ===`.
8. **Low: two quick preview clicks can leave a stray player.** `togglePreview` stops the current track, then awaits `getPlayableEntry` with no generation check (`app.js:807, 822-829`). Clicking row A then row B before A's audio arrives lets both resolve; A's `<audio>` plays untracked (its events are ignored by `isCurrent()`), so two tracks play and A cannot be stopped from the UI. Unverified (needs a run).
9. **Low: a search made only of digits, or a bare UUID, is treated as an ID** (`tidal_lib.js:438-444`; `electron-main.js:665-683`). "1999" resolves TIDAL track 1999 or fails with `Track info failed: 404 …`.
10. **Low: the volume slider shows the squared value at startup.** `volumeSlider.value = round(getPreviewVolume()·100)` (`app.js:1948`) uses the squared audio volume, while the input handler treats the slider as linear (`app.js:516-519`). With the default 0.5 the slider shows 25; touching it drops the volume sharply. The comment says "defaults to 60%".
11. **Low: Reset config deletes the saved volume** (`electron-main.js:561-565`). The renderer's `settings` also loses `volume`; the slider keeps its old position until restart.
12. **Low: excluded exact-match rows disappear after every batch**, including a one-track Retry, even though they were never sent (`app.js:1468-1473`).
13. **Low: most network calls have no retry.** Only `fetchBuffer` retries; API calls, Spotify embed fetches and the streamed BTS download fail on the first 429/5xx (`tidal_lib.js:129-168`; `tidal_download.js:215-256`), contrary to `CLAUDE.md:57` and `README.md:32`.
14. **Low: the release job does not check out the repo.** `body_path: RELEASE_NOTES.md` is used, but the job only runs `download-artifact` (`release.yml:44-61`). Probable cause of the empty release bodies; unverified (needs a CI run). Running the workflow manually (`workflow_dispatch`) would name the draft after the branch (`github.ref_name`).
15. **Low: window sends without a destroyed check** at `electron-main.js:49, 483, 585, 1007-1018, 1035`. On macOS the app outlives its window; runtime effect unverified.
16. **Low: writes are not atomic.** `settings.json`, `queue.json`, `pending-tracklist.json` and `token.json` are written with `writeFileSync` directly (`electron-main.js:44, 601, 992`; `tidal_lib.js:67`; `tidal_auth_node.js:58`). A corrupt `settings.json` is read as `{}` (looks like first launch).
17. **Low: paths are inserted into the bash relauncher without escaping.** `NEW_APP`, `TARGET`, `RUNNING_FROM` and `LOG` are placed inside double quotes (`electron-main.js:387, 400-403`); a path containing `"`, `$` or a backtick breaks the script.
18. **Low: the `Z:\Downloads` default on macOS** is a relative path on POSIX, so `mkdirSync` creates a folder literally named `Z:\Downloads` in the current directory (`tidal_download.js:40, 687-688`).
19. **Low: `bulk_runner` never emits the `notFound` marker.** It prints it only when `t.tidalId` is truthy, but that branch is reached only when `trackId` (initialized from `t.tidalId`) is falsy (`bulk_runner.js:70, 92-100`). The GUI never sends not-found rows anyway.
20. **Info: four copies of the TIDAL match scorer differ.** Only the Spotify-URL path adds the duration term. Import rows lack `hiRes`; extension rows have it (`electron-main.js:961-971` vs `:737`). Spotify-URL rows keep Spotify's title/artist (`tidal_lib.js:377-386`); import and extension rows take TIDAL's.
21. **Info: device flow and refresh use different embedded client pairs.** The device code is obtained with the AUTH pair; refresh uses the REQUEST pair stored in `token.json` (`tidal_auth_node.js:86, 131, 154-155`; `tidal_lib.js:77-81`).
22. **Info: `openExternal` accepts http** (`electron-main.js:186-188`); `CLAUDE.md:178` says https-only.
23. **Info: activity-log classifier mismatch.** `classify()` looks for `📁 Already in library`, but the CLI prints `📁 Already in music library`, so that line never gets the skip style (`app.js:334`; `tidal_download.js:374`).
24. **Info: dead or unused code.** `normalizeForMatch` shim (`tidal_lib.js:656`, not exported or called); the `_duration` parameter and stored `metaDuration` (`tidal_lib.js:720-741, 788`); the ISRC branch (`tidal_lib.js:560-568`); `playClownHorn` (`app.js:194`); `global._lastUpdateLogPath` written but never read (`electron-main.js:460`); a per-track Spotify re-fetch "for ISRC" that can never supply one (`tidal_download.js:602-604`); `stopServer` and `getTokenPath` exported but unused (`extension-server.js:204-211`).
25. **Info: stale comments and help text.** `tidal_download.js:83-84` (anonymous Spotify web API); `electron-main.js:191-193` (portable self-install), `:503-505` and `:761-763` (non-existent `onUpdateSelf` / `handleExtensionUpdateSelf` / popup Update button), `:984` (screenshot OCR), `:994` (removed single-track spawn); `electron-preload.js:18-19` (Windows portable only); `app.js:2` (OCR), `:166-167` ("Coming soon"), `:390-391` (portable), `:1947` (60% default); `bulk_runner.js:1-5, 96` (OCR, old file shape); `tidal_lib.js:1-3` (consumer list omits electron-main and bulk_runner), `:19-23` (title-only matching); `package.json:4` (screenshot OCR); `index.html:185` (popup Update button).

---

### Platform-specific behaviour

- **Windows only (drop in the port):** NSIS installer and `/S --updated` self-update (`electron-main.js:321-336`; `package.json:66-81`); the `Z:\Downloads` CLI default (`tidal_download.js:40`); the `cmd /c start ""` browser opener in CLI auth (`tidal_auth_node.js:113`); `start_app.bat`; PowerShell/WinGet `gh` paths in `CLAUDE.md:478, 743, 786-787` and `BOT_PROMPT.md:62, 95`.
- **macOS, relevant to the port:** userData at `~/Library/Application Support/robogears Downloader/` (via `app.setName`, `electron-main.js:13`); update logs at `~/Library/Logs/robogears Downloader/`; App Translocation detection; quarantine strip and ad-hoc re-sign; DMG asset `robogears-downloader-mac-arm64.dmg` (`package.json:88`); arm64-only target; DMG window 540×400 with icon at (140,220) and Applications link at (400,220) (`package.json:91-103`); `start_app.command`.
- **Electron only (gone in Swift):** asar/asar.unpacked path rewriting; `ELECTRON_RUN_AS_NODE` children; the `contextBridge` preload; the `cwd: __dirname` ENOENT class of bugs; CSP; `sandbox:false`; the electron-builder `afterPack` hook.
- **Chrome extension (all platforms):** support ended 21 Oct 2026. Do not port `extension-server.js`, `chrome-extension/`, the Settings → Extension tab or `sync-ext`.
- **Dev vs packaged token location** differs: `<source>/token.json` in dev, `<userData>/token.json` packaged (`electron-main.js:19-21`; `tidal_lib.js:13`).

---

### Porting notes for a native Swift macOS app

| Topic | Current mechanism | What Swift needs | Difficulty |
|---|---|---|---|
| FFmpeg remux, tags, FLAC picture type 3 | `ffmpeg-static` binary (asarUnpack + path rewrite), cover piped on stdin; `verifyFlac` runs `ffmpeg -f null` | Either bundle an `ffmpeg` executable in the app (sign it with the app, run with `Process`, pipe the cover through a `Pipe` on stdin, keep the exact argument list above), or write the FLAC container yourself (`fLaC` + STREAMINFO + VORBIS_COMMENT + PICTURE type 3) from the FLAC-in-fMP4 or raw FLAC stream. Whether AVFoundation/AudioToolbox can write Vorbis comments and PICTURE blocks is unverified; assume not. The `.m4a` fallback can be remuxed with AVFoundation passthrough plus metadata | Hard |
| Library tag reading | `music-metadata`, 8 concurrent, title/artist/duration | AVFoundation metadata works for m4a/mp3/wav/aac; FLAC Vorbis comments and Ogg/Opus need a small parser or a library such as TagLib. Use a `TaskGroup` limited to 8 and report progress every 25 files. Keep the six normalized forms and the four tiers exactly | Medium |
| HTTP with retry, timeout, redirects | Node `https`, 30 s idle timeout, `fetchBuffer` 3 retries with backoff `min(1000·2ⁿ, 8000)`, ≤ 5 redirects, okhttp UA | `URLSession` with `timeoutIntervalForRequest`; one retry wrapper for 429/5xx/network errors applied to **all** TIDAL calls (fixing the current gaps); same headers; `bytes(for:)` or a download task for streamed progress | Easy |
| Per-track child processes and markers | main → `bulk_runner` → `tidal_download` per track; progress as `__TRACK_*__` stdout lines | An in-process async pipeline: sequential batch, per-track progress via an `AsyncStream` or `@Observable` model, cancellation via `Task.cancel()` (removes the orphaned-child bug). Exit-code meanings (0 done, 2 skipped, 1 failed) become an enum; a batch with failures should not count as success, and rows without a final status must not be deleted | Easy |
| IPC bridge and renderer | `contextBridge` `window.api`, `ipcMain.handle`, `webContents.send` | Direct calls between SwiftUI/AppKit views and services | Easy |
| Waveform preview | Web Audio `decodeAudioData` → 200 peaks; `<audio>` on a Blob URL; canvas + rAF; document-level scrub | Decode peaks with `AVAudioFile` / `AVAssetReader` off the main thread; play with `AVPlayer` / `AVAudioPlayer` from a temp file. Whether concatenated DASH FLAC-in-fMP4 (`audio/mp4`) plays and decodes in AVFoundation is unverified (needs a run); it may need remuxing first. Draw with SwiftUI `Canvas` or a layer; drive the playhead from a periodic time observer; `DragGesture` for scrub-while-playing; guard against stale loads with a generation token | Medium |
| Sound effects | Web Audio oscillators, envelopes, biquad lowpass | `AVAudioEngine` + `AVAudioSourceNode` with the same parameters, or pre-rendered short assets. The owner's native-design rule may favour system sounds; owner's call | Medium |
| Persistent files | `settings.json`, `queue.json`, `token.json` in `~/Library/Application Support/robogears Downloader/` | `FileManager` application-support directory with atomic writes (`Data.write(options: .atomic)`). Decide whether to read the Electron files for migration, and whether the token moves to the Keychain. Store one credential, replaced on re-auth | Easy |
| Folder picker, open folder, open link | `dialog.showOpenDialog`, `shell.openPath`, `shell.openExternal` | `NSOpenPanel` (`canChooseDirectories`), `NSWorkspace.open`; security-scoped bookmarks if sandboxed. Consider refusing a download folder inside the library folder | Easy |
| Self-updater | GitHub `/releases/latest`, asset substring, `hdiutil` + `ditto`, nohup double-fork bash relauncher, translocation check, quarantine strip, ad-hoc `codesign`, quit after 500 ms | Same steps via `Process` plus a detached helper that outlives the app (escape paths properly), or Sparkle with EdDSA-signed appcasts. Translocation check: `Bundle.main.bundlePath` contains `/AppTranslocation/`. Version compare must match `isNewerVersion` (strip `v`, compare numeric segments, missing = 0) | Hard |
| TIDAL device-code OAuth | Node `https` polling; `shell.openExternal`; append to `token.json` | `URLSession` POSTs, a polling `Task` sleeping `interval` seconds, `NSWorkspace.open`, a copyable URL field, a Cancel button and a dismissible sheet on failure; replace (not append) the stored credential; never terminate the process on a missing token | Easy |
| Spotify embed and manifest parsing | Regex over HTML for `__NEXT_DATA__`; regex over DASH XML | `URLSession` + `Regex`/`NSRegularExpression` + `JSONSerialization`/`Codable`; `XMLParser` or the same regexes for DASH; `Data(base64Encoded:)` for manifests | Easy |
| CSV/text import, drop, paste | Custom CSV parser, file drop, document paste listener | Port the parser as a pure function (fix the first-matching-header issue deliberately or keep it, owner's call); `onDrop` / `NSPasteboard`; an Edit ▸ Paste or Import menu command per the native-macOS rules; add a Cancel to the matching progress | Easy |
| Ad-hoc signing | `build/after-pack.js` runs `codesign --force --deep --sign -` | Xcode "Sign to Run Locally" (`CODE_SIGN_IDENTITY = -`), plus re-signing after update | Easy |

---

### Open questions

1. **Migration from Electron to Swift.** The v0.1.30 updater looks only at `robogears/robogearsDownloader` `/releases/latest`, needs a tag numerically newer than 0.1.30, and installs the first `.app` it finds in a DMG whose asset name contains `mac-arm64.dmg`. If the Swift app lives in a new repository or restarts at `0.1.1` (per the owner's global versioning rule), existing Electron users will never be offered it. Which repository and version series should the Swift app use?
2. Should the Swift app read the existing `settings.json`, `queue.json` and `token.json` in `~/Library/Application Support/robogears Downloader/` so the user keeps their sign-in, folders and queue, or start fresh (and move the token to the Keychain)?
3. Will the CLI tools (`tidal_download`, `tidal_search`, `tidal_check_quality`, `tidal_auth_node`) be ported? If so, what replaces the Windows-only `Z:\Downloads` default on macOS?
4. Keep the title-only filename rule even though different songs with the same title silently skip each other? Keep removing excluded exact-match rows after each batch?
5. Should a batch with failed tracks still count as success (ping and "Batch finished")? The code does; the docs imply "finishes cleanly".
6. With the Chrome extension dropped, should Spotify playlists stay embed-only (100-track cap) with CSV/Exportify as the only workaround, or should the never-built Pathfinder approach be considered?
7. What exactly changed in v0.1.26 to v0.1.29? The code and `RELEASE_NOTES.md` reveal only extension work; no document records those versions.
8. Does Exportify's current CSV list an artist ID/URI column before "Artist Name(s)"? The code takes the first header containing "artist". Unverified without a sample file.
9. Can AVFoundation play and decode the concatenated DASH FLAC-in-fMP4 stream and the BTS FLAC stream directly, or must previews be remuxed first? Unverified (needs a run).
10. Are both embedded TIDAL client pairs still valid, and is refreshing with the REQUEST pair after authorizing with the AUTH pair intentional? Unverified (needs a run with network access).
11. Is the missing `actions/checkout` in the release job the real cause of the empty release bodies, and did CI break after Node 20 was removed (16 Sept 2026)? Unverified (needs a CI run).
12. Versioning: the owner's global `~/.claude/CLAUDE.md` ("bump once after each push, then hold; `0.1.1` first; middle number only on request") overrides `CLAUDE.md:746` and `ship.md:15, 23` by its own wording. Should the owner update the project docs to match?
13. The README credits `sachinsenal0x64/hifi` and `binimum/hifi-api` for the embedded TIDAL credentials. Should the Swift port keep those credentials and that credit?
