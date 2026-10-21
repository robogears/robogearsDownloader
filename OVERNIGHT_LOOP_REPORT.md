# Overnight Loop Report — 2026-10-21

STATUS: LOOPING · cycle 0 · 16 done · build+tests GREEN · running: UI lane, 4 download lanes, resolver lane

## Run
- Started: 22:35 · Branch: overnight-loop/2026-10-21-2235 from main · Ceiling: none
- Commits: `git log --oneline --grep='^loop' main..overnight-loop/2026-10-21-2235`

## Questions for you (parked forks and end-of-rope questions — answer any to unpark)
- ❓ Live TIDAL check: can you sign in once in the morning so the TIDAL calls can be verified? — options: yes | later — parked item: Live TIDAL check
- ❓ Signing: you chose the free self-signed certificate (D4 5.7). When convenient, create it in Keychain Access (Certificate Assistant › Create a Certificate…, type Code Signing) and tell me its name — parked item: Signing certificate
- ❓ Windows: the farewell build is ready on branch loop/windows-farewell. Its installer has to be built by the old Electron CI (which may need its Node 20 actions bumped first) and attached as robogears-downloader-setup.exe to the first Swift release — say when — parked item: Windows copies

## Recommendations (things the loop chose not to do unattended)
- 💡 Replace the Electron CI with a macOS-only Swift build — why: the workflow still builds Electron for Windows and Mac, its release job has no actions/checkout (the likely cause of every empty release body) and it pins Node 20 actions — how: one macos-latest job running macos/scripts/package-release.sh, uploading the dmg, zip and both .sha256 files to a draft release, with actions/checkout in the release job. Left for you because the loop doesn't change CI or release config unattended.

## Progress log (last 20; older lines roll into the tally)
- 01:10 Download pipeline started (item 9): the shared shapes are committed (a79f82c) and four lanes are building in parallel — the per-track downloader, the download-folder checks and naming (includes D4 2.6/2.7), a native AAC (.m4a) writer and the batch runner. Resolver and shared TIDAL pace started as its own lane. Done here meanwhile: one version rule for the app (L1), the library index joined to the matcher (L5), and preview part 1 — 200-bar waveform peaks and a 1 GB preview cache with Clear Preview Cache (12 new tests; two checked by breaking the code). 740 tests pass.
- 00:25 Core lanes merged (items 4–8), each built, independently reviewed and fixed: input and import parsing (170 tests incl. 30 mutation checks), one Unicode-aware matcher and the library matcher (112), TIDAL models, manifests and the Spotify embed (110), the TIDAL client with sign-in, token keeper, retries and credential stores (186), and the offline audio spikes with a native FLAC writer (80; findings in docs/spikes/audio-and-tagging.md). Merged tree: 726 tests pass, no warnings, app builds. Lane worktrees and the temporary Pictures link removed.
- 23:50 Library scanner: own FLAC and Ogg Vorbis/Opus tag parsers (title, every ARTIST, ISRC, exact length) plus Apple's reader for MP3/M4A/WAV/AIFF; folder walk skips hidden, AppleDouble "._" files and links; online-only Dropbox/iCloud files detected without downloading and read only once allowed; saved index re-reads only new or changed files; an unreachable library keeps the last index; the newest scan request always wins. 16 new tests on generated audio (78 total).
- 23:35 Windows farewell (D4 5.8) on its own branch loop/windows-farewell, based on v0.1.30: on Windows the Electron app stops checking for updates, says once at launch that Windows support has ended and this version keeps working, and Settings › Updates reads \"Final Windows version\"; version 0.1.31. Its setup.exe still has to be built by CI at ship time.
- 23:20 Design direction (docs/DESIGN_DIRECTION.md, Fable design lead): the waveform queue is the one hand-drawn element; pure-black/white canvas only in the content layer, system chrome everywhere else; ink as AccentColor; 13 colour tokens with measured contrast incl. Increase Contrast; exact waveform, row and motion specs; full menu-bar map; accessibility; 17 real-pixel checks. Eight brief questions answered (owner to confirm).
- 23:10 Project moved to ~/Developer/swiftRobotDownloader (owner); git worktrees re-pointed; D4 set to all recommended (owner).
- 00:00 Decision-4 document (docs/D4_BEHAVIOUR_DECISIONS.md): 68 decisions and 23 plain fixes across five areas, each drafted from the code, checked by a second agent, made consistent by a third (23 contradictions, 9 duplicates and 8 factual doubts resolved); one-screen summary at the top so you can answer "all recommended except …".
- 23:55 App state: atomic JSON store that keeps a damaged file aside; settings (blank folders, volume stored as the slider position, Reset Folders keeps the volume); folder bookmarks that follow a rename and detect unplugged / missing / in-the-Trash / not writable, with plain messages; download folder inside the library refused by folder identity; queue rows (failed keeps its reason, in-flight rows come back waiting, exact library matches start left out) with a debounced, flushable store. 18 new tests (62 total); restore rule proven to fail when broken.
- 23:40 Release packaging script (macos/scripts/package-release.sh): Release build, ad-hoc signed, robogears-downloader-mac-arm64.dmg (app at the root for the v0.1.30 updater) + .zip for the new updater + .sha256 for each; ran it, mounted the DMG read-only and verified layout and signature.
- 23:35 Design brief (docs/DESIGN.md): product and person, identity carried into native Light/Dark, every window and sheet with its one job, all 13 queue-row states, real facts, the full menu-bar and shortcut map, copy rules, the never-list, 8 questions for the design lead.
- 23:30 Updater (core): GitHub check with ETag cache, arm64 zip + SHA-256 sidecar contract (no wrong-arch fallback), host-pinned capped download, ditto unpack + identity + codesign check, the shared rollback relauncher, translocation-aware destination, @Observable state machine; 32 new tests (44 total), wrong-arch test proven to fail on a bad fallback.
- 23:05 Sound effects: all 8 sounds rendered natively from the Electron Web Audio graphs (same notes, envelopes, filters); new quieter "finished with problems" sound for you to approve by ear; 12 tests pass, note tests proven to fail on a wrong note.
- 22:40 Swift project scaffold: XcodeGen app target (robogears Downloader, 0.1.31, macOS 15) + RobogearsCore package with Swift Testing; app builds, 2 tests pass.
- 22:35 Kickoff. Folder linked to GitHub `main` (b60576d, v0.1.30) without changing any file; loop branch created; Mac kept awake.

## Cycle log

## Completed
- Total: 14 · recent: ✅ Core lanes 4–8 merged · ✅ Library scanner — 25m · ✅ Windows farewell branch · ✅ Decision-4 document — 20m · ✅ App state — 18m · ✅ Release packaging script — 8m · ✅ Design brief — 13m · ✅ Updater core — 25m · ✅ Sound effects — 14m · ✅ Swift project scaffold — 6m

## Blocked (environment)

## Skipped / shelved

## Excluded from commits (secret-shaped or too big — commit them yourself if they're fine)

## Decisions & assumptions (last 20 + tally)
- Owner, 21 Oct 23:05: "just go with all of the recommended stuff for now" — every D4 item uses option A, including 2.6 and 2.7 (file names bend only for a clash with a different song; versions go in the title tag).
- Owner, 21 Oct 23:05: "move the project file to /Users/william/Developer" and "update git and everything to the new path" — moved the whole project folder to ~/Developer/swiftRobotDownloader (moving only the Xcode project would break it), pointed every git worktree at the new location, cleared my own build caches (they hold absolute paths), updated the plan and docs. A temporary link at the old path keeps background agents working; it is removed once they finish (L3).
- Kickoff questions went unanswered; these defaults are the direction:
  - Assumed git setup is fine: `git init`, remote `origin` = robogears/robogearsDownloader, `main` pointed at origin/main (b60576d) with a mixed reset, no file changed. Undo: delete the `.git` folder.
  - Assumed no deny rules: the repo tracks `.claude/settings.local.json`, so adding them would commit them. The loop relies on its own rules (branch-only pushes, stage-safe, no force-push).
  - Assumed decision 4 = my recommended answers, except 2.6 and 2.7, which stay on your literal title-only rule until you confirm.
  - Assumed Light + Dark appearance, with today's pure-black look as the signature.
  - Assumed FFmpeg vs native tagging is decided by tonight's experiment (prefer native if it reproduces the old files' tags exactly).
- Assumed the Swift app lives in `macos/` and the Electron code stays at the repo root untouched, because the reference documents cite it by path.

## Test status
- Baseline: Electron JS files pass `node --check` (11/11); no test suite exists; `node_modules` absent, so the Electron app can't be built or run here; Xcode 27.1 and Swift 6.4 available; no Swift project yet. Full output in .overnight-loop/baseline.txt
- Latest: RobogearsCore 726/726 tests pass (43 suites), no warnings; app builds (Debug)

## Usage-limit waits

## Morning merge — for YOU (the loop never runs these)
```sh
git log --oneline main..overnight-loop/2026-10-21-2235          # review
git checkout main && git merge --no-ff overnight-loop/2026-10-21-2235
# with a remote, review as a PR instead:  gh pr create --base main --head overnight-loop/2026-10-21-2235
# if the branch tip is an unverified WIP commit (its message ends "(unverified)"), merge the newest verified one instead:
#   git merge --no-ff "$(git log -1 --format=%h --invert-grep --grep='(unverified)' overnight-loop/2026-10-21-2235)"
# to discard a loop-created branch:  git branch -D overnight-loop/2026-10-21-2235
```

<!-- machine-readable footer -->
```json
{"date": "2026-10-21", "branch": "overnight-loop/2026-10-21-2235", "base": "main",
 "cycles": 0, "done": 14, "shelved": 0, "blocked": 0,
 "state": "looping", "build": "green"}
```
