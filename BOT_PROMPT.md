# Bot onboarding prompt

Copy-paste this entire block to any AI bot (Cowork, Claude, ChatGPT, Gemini, etc.) when you start a fresh session on this project. It will orient them immediately.

---

```
You are picking up work on **robogears Downloader**, a personal desktop app for
downloading lossless FLAC tracks from TIDAL. Source lives at
`Z:\robogearsDownloader\` (also at https://github.com/robogears/robogearsDownloader).
Currently at v0.1.0, packaged as a single portable Windows .exe.

## STEP 1: READ THIS FILE FIRST

Open and read `Z:\robogearsDownloader\CLAUDE.md` end-to-end before doing
anything else. It contains:
- Full architecture (Electron main / preload / renderer / spawned CLI children)
- Six MANDATORY rules (download folder, library dedup, file naming, FLAC
  policy, cover-art piping, no library writes)
- Detailed history of what was tried and abandoned (Monochrome, Spotify
  Client Credentials, Spotify user OAuth, headless web-player scraper) — so
  you don't waste time re-trying dead ends
- The library deduplication system (exact vs similar matching, metadata +
  filename, GUI flow with "+ Add" buttons)
- TIDAL pipeline details (segment-based MPEG-DASH download, parallel
  fetching, FFmpeg remux with stdin-piped cover art)
- Packaging notes (electron-builder config, the token.json path migration
  for packaged context via TIDAL_TOKEN_PATH env var)
- "Where the last session left off" with what just landed, what's still
  rough, and a prioritized next-steps list

Do not start coding until you've read CLAUDE.md.

## WHAT THIS APP DOES

- Inputs: paste a TIDAL/Spotify URL (track/album/playlist), type a song
  name to search, or drop a screenshot of a tracklist (OCR via Tesseract.js)
- Reviews tracks in a queue before downloading
- Scans the user's existing music library (read-only, configurable path)
  and greys out exact duplicates with a "+ Add" button to opt back in;
  flags similar versions (remixes/extended/feat./live) with a yellow badge
- Always grabs the highest-quality lossless TIDAL has (Hi-Res when
  available → CD-quality FLAC → falls back to .m4a only when no lossless
  master exists). Embeds full metadata + cover art via FFmpeg.

## TECH STACK

- Node.js + Electron 33 (no UI framework, vanilla HTML/CSS/JS for the renderer)
- Monochrome theme — pure black, white text, no accent colors
- ffmpeg-static (bundled FFmpeg, asarUnpacked in builds)
- music-metadata for library scanning
- Tesseract.js (CDN-loaded) for OCR

## USER COMMUNICATION STYLE

The user values brevity, precision, and "show don't talk":
- Lead with the answer, not the recap. Skip "Great question!" preambles.
- When you change code, summarize what changed in a brief table. When
  proposing options, list them in a table with trade-offs.
- When diagnosing bugs, write a tiny script that surfaces the actual data
  (e.g. a debug script that hits an API endpoint and dumps the response),
  then fix from evidence rather than guesses.
- Restart Electron after any change to main/renderer/preload (HMR is not
  wired up). Pattern: `Get-Process electron | Stop-Process -Force; cd
  Z:\robogearsDownloader; npm start`. Don't announce the restart — just
  do it and verify the window comes up.
- Library is READ-ONLY. Never propose writing to the library folder.

## RUN COMMANDS YOU'LL USE OFTEN

```
cd Z:\robogearsDownloader

npm start                 # launch in dev mode (Electron points at source)
npm run build:win         # build the portable .exe → dist\robogears-downloader.exe
npm run auth              # CLI TIDAL device-code login (writes ./token.json)

# Sanity checks (used after major changes):
node -e "const lib = require('./tidal_lib'); console.log('OK. exports:',
  Object.keys(lib).length);"
```

## THE 6 NON-NEGOTIABLE RULES (full detail in CLAUDE.md)

1. Default download folder is `Z:\Downloads`. Never use anything else
   unless the user explicitly provides a path.
2. Album/playlist downloads go FLAT to the chosen folder — no subfolders.
3. Filenames are `<Title>.flac` (or `.m4a` for AAC fallback). Title only,
   no artist prefix.
4. Library dedup fires before every download — `lib.findInLibrary(title,
   artist, duration)`. `kind: 'exact'` greys out the queue item;
   `kind: 'similar'` shows a yellow badge.
5. Quality policy: highest TIDAL has. Hi-Res > CD-quality FLAC > .m4a
   only as a last resort. `--flac-only` is opt-in.
6. Cover art is a Buffer piped to FFmpeg via stdin. Never write a temp
   `.cover.jpg`.

## DON'T

- Don't reintroduce the Spotify Client Credentials Flow or user OAuth.
  Both are confirmed-broken for new Spotify dev apps as of Nov 2024.
- Don't subfolder downloads.
- Don't write to the user's music library folder.
- Don't bypass `findInLibrary` without explicit user opt-in (the `--force`
  flag or "+ Add" button in the queue).
- Don't replace `process.env.TIDAL_TOKEN_PATH || path.join(__dirname,
  'token.json')` with just the local path — the env var fallback is what
  makes the packaged .exe work.
- Don't remove `asarUnpack` for `ffmpeg-static` in `package.json` —
  packaged builds will break (FFmpeg has to be a real binary on disk).

## START BY ASKING

After you've read CLAUDE.md, ask the user what they want to work on. Don't
guess. Possible options from the current next-steps list:
- Per-track progress in the queue during bulk download
- Disk-cached library scan (cuts launch time from ~18s → <1s)
- App icon
- GitHub Actions release workflow
- Cancel button for in-flight downloads
- Revive the headless Spotify scraper (removes the 100-track Spotify limit)

Don't pick one yourself. Wait for the user to direct.
```

---

## How to use this

1. Open a fresh chat with whatever AI you want to bring onto the project
2. Paste the block above (everything between the triple backticks) as the first message
3. Wait for the AI to confirm it's read `CLAUDE.md`
4. Tell it what you want to work on

If you're using Cowork or Claude Code with the project directory already open, the `CLAUDE.md` file is auto-loaded — you can shorten the prompt to just "Read CLAUDE.md and BOT_PROMPT.md, then await my direction."
