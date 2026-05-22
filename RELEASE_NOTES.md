# What's new in v0.1.1

First public release of **robogears Downloader** — a desktop app for downloading lossless FLAC tracks from TIDAL.

## Inputs and the queue
- Paste a TIDAL or Spotify URL (track / album / playlist), type a song name to search TIDAL, or drop a screenshot of a tracklist (OCR coming soon).
- Review every match in a queue before downloading. Exact library duplicates are greyed out with a "+ Add" opt-in; similar-version matches (remixes, edits, live versions) are flagged with a yellow badge.

## Smart deduplication
- Reads both filenames AND audio-tag metadata (title, artist, duration) from your music library folder so songs you already own aren't re-downloaded.
- Auto-skips exact matches; warns on similar matches but still includes them by default.

## Quality policy
- Always asks TIDAL for Hi-Res Lossless first; gracefully falls back to CD-quality FLAC; last-resort `.m4a` 320 kbps AAC only when no lossless master exists.
- Cover art and full metadata embedded via bundled FFmpeg.

## Blank-on-first-launch settings
- Download folder and library folder both start empty. Pick them via Settings — no surprise default paths.
- New **Reset config** button forgets your folder choices while keeping your TIDAL sign-in.
- Library scan is skipped entirely when no library folder is configured (no phantom indexing).

## Batch download clarity
- Summary line now distinguishes **downloaded / skipped / failed / not-found** so you can see at a glance what actually happened.
- Skip messages now explicitly say whether the duplicate was found in your **downloads folder** or your **music library**.

## Sound effects
- Soft ascending chime when a download batch starts.
- Lower warning honk when an action is blocked (no folder set, not signed in, empty queue).
- And a clown horn easter egg somewhere in the UI.

## macOS support
- Apple Silicon `.app` bundle now ships alongside the Windows portable `.exe`.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app isn't code-signed).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.0...v0.1.1
