# Bot onboarding prompt

Copy-paste this entire block to any AI bot (Cowork, Claude, ChatGPT, Gemini, etc.) when you start a fresh session on this project. It will orient them immediately.

---

```
You are picking up work on **robogears Downloader**, a personal desktop app for
downloading lossless FLAC tracks from TIDAL. Source lives at
`Z:\robogearsDownloader\` (also at https://github.com/robogears/robogearsDownloader).
Currently at v0.1.16 (published) with v0.1.17 in flight. Ships as a portable
Windows `.exe` and a macOS Apple-Silicon `.dmg` with a custom turntable-themed
install window. Both auto-update in-place via the in-app updater.

## STEP 1: READ THESE FILES FIRST

Open and read in order before doing anything else:

1. `Z:\robogearsDownloader\CLAUDE.md` — full architecture, mandatory rules,
   abandoned-approach history (so you don't waste time re-trying dead ends),
   diagnostic patterns, current session state. End-to-end. ~700 lines but
   worth it.
2. `Z:\robogearsDownloader\ship.md` — release process (when + how to ship).
3. `Z:\robogearsDownloader\RELEASE_NOTES.md` — the body of the current
   draft release. Whatever's in here is what the next release ships with.

You should also know there are two memory entries:
- `feedback-no-auto-releases` — code changes only, no commit/push/tag without
  explicit ship instruction ("ship it" / "publish" / "release" / "tag X.Y.Z").
- `feedback-release-notes-format` — `RELEASE_NOTES.md` holds only the CURRENT
  version's body (overwrite, don't append). Must include description /
  install / requirements / changelog link.

## WHAT THIS APP DOES

- Paste a TIDAL or Spotify URL (track / album / playlist) or type a song name
  to search TIDAL. Adds matches to a queue you review before downloading.
- The OCR drop-zone exists but is currently feature-flagged off
  (`OCR_FEATURE_ENABLED = false` in `renderer/app.js`) — drop-zone is greyed
  with a "Coming soon" badge that plays a clown horn on click.
- Scans a read-only music library folder (configurable; blank on first launch).
  Reads ID3/Vorbis tags AND filenames. Exact dupes are greyed in the queue
  with a "+ Add" opt-in button; similar versions (remixes, edits, feat./live)
  get a yellow badge but are included by default.
- Always grabs the highest-quality lossless TIDAL has (Hi-Res →
  CD-quality FLAC → falls back to .m4a only when no lossless master exists).
  Embeds full metadata + cover art via FFmpeg.
- In-app updater checks GitHub releases on launch + manual button in
  Settings. Self-installs on both Windows (portable .exe swap) and macOS
  (DMG mount + .app to /Applications/).

## TECH STACK

- Node.js + Electron 33 (no UI framework, vanilla HTML/CSS/JS for renderer)
- Monochrome theme — pure black, white text, no accent colors
- ffmpeg-static (bundled FFmpeg; asarUnpacked + .replace asar→asar.unpacked
  for the binary path in packaged builds)
- music-metadata for library scanning
- electron-builder for packaging (portable .exe + .dmg)
- GitHub Actions for cross-platform CI
- `gh` CLI authenticated as `robogears` for release editing (path:
  `C:\Users\william\AppData\Local\Microsoft\WinGet\Links\gh.exe`)

## USER COMMUNICATION STYLE

The user values brevity, precision, and "show don't talk":
- Lead with the answer, not the recap. Skip "Great question!" preambles.
- When you change code, summarize in a brief table. When proposing options,
  list them in a table with trade-offs.
- When diagnosing bugs, write a tiny script that surfaces the actual data
  (or read a log file), then fix from evidence — not guesses.
- Restart Electron after any change to main/renderer/preload (no HMR).
  Pattern: `Get-Process electron | Stop-Process -Force; cd
  Z:\robogearsDownloader; npm start`. Don't announce it; just do it.
- Library is READ-ONLY. Never propose writing to the library folder.
- Don't auto-release. Even if you fixed a bug, hold the commit until the
  user explicitly says "ship it" or similar.

## RUN COMMANDS YOU'LL USE OFTEN

```
cd Z:\robogearsDownloader

npm start                 # launch in dev mode
npm run build:portable    # build the Windows .exe → dist\robogears-downloader.exe
npm run build:mac         # build the macOS .dmg (only works on macOS via CI;
                            local Windows builds the .exe instead)
npm run auth              # CLI TIDAL device-code login (writes token.json)

# Sanity checks:
node -e "const lib = require('./tidal_lib'); console.log('OK. exports:',
  Object.keys(lib).length);"

# Release verification (after a tag push):
$gh = "C:\Users\william\AppData\Local\Microsoft\WinGet\Links\gh.exe"
& $gh release view vX.Y.Z --json body --jq "(.body | length)"
& $gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md  # fix empty body
```

## NON-NEGOTIABLE RULES (full detail in CLAUDE.md)

1. **Download folder defaults**: CLI scripts fall back to `Z:\Downloads`.
   GUI starts BLANK on first launch — no auto-applied default.
2. Album/playlist downloads go FLAT into the chosen folder — no subfolders.
3. Filenames are `<Title>.flac` (or `.m4a` for AAC fallback). Title only.
4. Library dedup fires before every download (`lib.findInLibrary(title,
   artist, duration)`). `kind: 'exact'` greys the queue item with "+ Add";
   `kind: 'similar'` shows a yellow badge (included by default).
5. Quality policy: highest TIDAL has. Hi-Res > CD-quality FLAC > .m4a as
   last resort. Detection uses `raw.audioQuality` from the playback API
   as primary signal (`LOSSLESS` / `HI_RES_LOSSLESS` = FLAC, period).
6. Cover art is a Buffer piped to FFmpeg via stdin. Never write a temp
   `.cover.jpg`.

## TOP DON'TS

- Don't reintroduce the Spotify Client Credentials Flow or user OAuth.
  Both are broken for new Spotify dev apps since Nov 2024.
- Don't subfolder downloads.
- Don't write to the user's music library folder.
- Don't bypass `findInLibrary` without explicit user opt-in (`--force` or
  "+ Add" button).
- Don't reintroduce `cwd: __dirname` in any `spawn()` call — in packaged
  builds it resolves into an asar virtual path that `posix_spawn` /
  `CreateProcess` can't `chdir()` into.
- Don't spawn a binary from a package without rewriting `app.asar` →
  `app.asar.unpacked` in the path (ffmpeg-static's quirk; same for any
  future npm-packaged binary).
- Don't change `draft: true` to `false` in `.github/workflows/release.yml`.
  Every release lands as a draft for manual review.
- Don't force-move a PUBLISHED tag. Unpublished drafts can be redone with
  the user's OK; published releases are immutable. Bump to a new version.
- Don't auto-release. Make code changes only; wait for explicit ship word.
- Don't remove `asarUnpack` for `ffmpeg-static` from `package.json`.
- Don't remove `publish: null` from `package.json#build` (without it,
  electron-builder auto-publishes on tag push and demands GH_TOKEN).
- Don't accumulate old version sections in `RELEASE_NOTES.md`. Current
  version only; overwrite on each ship.

## START BY ASKING

After you've read CLAUDE.md + ship.md + RELEASE_NOTES.md, ask the user
what they want to work on. Don't pick from the next-steps list yourself.

Current "Possible next steps" from CLAUDE.md (in rough priority):
1. Per-track progress in queue UI ✓ DONE in v0.1.10
2. Disk-cached library scan (cuts launch time from ~18s → <1s)
3. Cancel button for in-flight downloads ✓ DONE in v0.1.11
4. Revive headless Spotify scraper (removes the 100-track limit)
5. Better OCR (currently feature-gated off entirely)
6. Persist queue across app restarts
7. History / "recent downloads" pane
8. App icon ✓ DONE in v0.1.9
9. macOS x64 build
10. macOS self-install ✓ DONE in v0.1.10–v0.1.15
11. Bump GitHub Actions to Node-24-compatible versions before June 2026
12. Investigate softprops empty-body quirk (currently we always `gh release
    edit` after a ship as a manual safety net)
13. Add screenshots to `docs/` and reference in README

Wait for the user to direct.
```

---

## How to use this

1. Open a fresh chat with whatever AI you want to bring onto the project
2. Paste the block above (everything between the triple backticks)
3. Wait for the AI to confirm it's read `CLAUDE.md` + `ship.md`
4. Tell it what you want to work on

If you're using Cowork or Claude Code with the project directory already open, the `CLAUDE.md` file is auto-loaded — you can shorten the prompt to just "Read CLAUDE.md and ship.md, then await my direction."
