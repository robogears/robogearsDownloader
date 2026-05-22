# robogears Downloader

A desktop app for downloading lossless FLAC tracks from TIDAL.

Paste a TIDAL or Spotify link (track, album, or playlist), drop a screenshot of a tracklist, or just type a song name to search. Review what's about to be downloaded in a queue, then go. Auto-skips songs you already have, falls back to `.m4a` only when no lossless master exists.

![App screenshot placeholder](docs/screenshot.png)

## Features

- 🎚️ **Highest quality TIDAL has** — Hi-Res Lossless (24-bit) when available, falls back to 16-bit FLAC, then to `.m4a` (320 kbps AAC) only when no lossless master exists
- 🔗 **Spotify URLs supported** — track, album, playlist (playlists capped at 100 tracks by Spotify's public embed; tracks/albums have no cap)
- 🔍 **Free-text search** — type a song name, pick from TIDAL results
- 📷 **Screenshot OCR** — drop a tracklist screenshot, app extracts tracks via Tesseract.js and matches each on TIDAL
- 📁 **Library deduplication** — point at your existing music folder; the app reads audio-tag metadata (title, artist, duration) and skips anything you already own. Detects exact matches vs. similar versions (remixes, live, extended mixes) with different visual cues
- ✨ **Cover art + full metadata** embedded in every download (piped from TIDAL straight to FFmpeg, no temp files)
- 🚀 **Parallel segment downloads** — typical 4-minute track in ~3 seconds, full album in under a minute
- 🛡️ **Retries on network errors**, FLAC integrity check after each download, hard timeouts so the app never hangs

## Quick start

### Prerequisites

- **Node.js 20+** ([download](https://nodejs.org/))
- **An active TIDAL HiFi or HiFi Plus subscription**
- Windows (the code is portable but only tested on Windows)

### Install

```sh
git clone https://github.com/robogears/robogearsDownloader.git
cd robogearsDownloader
npm install
```

### Launch

```sh
npm start
```

Or double-click `start_app.bat` on Windows.

### First time

1. Open **Settings** (⚙ in the top-right)
2. Click **Sign in to TIDAL** — a browser tab opens, log in to TIDAL, click *Allow*. The window closes automatically when done.
3. Set your **Download folder** (defaults to `Z:\Downloads` on the original dev's machine; you'll want to change it)
4. Optional: set your **Music library folder** to point at your existing music collection. The app reads audio-tag metadata from each file and uses it to skip duplicates before downloading

### Use

| Action | What to do |
|---|---|
| Download a single track | Paste a TIDAL or Spotify URL → **Add to queue** → **Download all** |
| Download an album/playlist | Same — paste any TIDAL/Spotify album or playlist URL |
| Find a song by name | Type a search term → pick from the results modal → adds to queue |
| Bulk-add from a screenshot | Drag a screenshot of a tracklist onto the drop zone — OCR runs, tracks are matched on TIDAL, added to queue |
| Review before downloading | The queue shows everything before any download starts. Items you already own are greyed out with an "+ Add" button to opt in. "Similar version in library" matches show a yellow badge but stay included. Remove anything with ✕. |

## How it works

Pasting a TIDAL URL hits TIDAL's API directly. Pasting a Spotify URL fetches the public embed page and matches each track against TIDAL by title + artist + duration (ISRC-based when available). Downloads use the standard MPEG-DASH segment pipeline with parallel fetches, then FFmpeg remuxes the FLAC stream into a proper `.flac` container with metadata + cover art embedded.

The library scanner reads each file's audio tags via [`music-metadata`](https://github.com/Borewit/music-metadata), so it works even when filenames are inconsistent or truncated.

For the full architecture, mandatory rules, and design history, see [`CLAUDE.md`](CLAUDE.md). It's written as an onboarding doc for the next contributor.

## CLI usage (optional)

All the scripts work standalone if you'd rather skip the GUI:

```sh
# One-time TIDAL login
node tidal_auth_node.js

# Download by TIDAL ID or URL
node tidal_download.js 103805726
node tidal_download.js https://tidal.com/browse/album/103805723 "C:\Music"

# Search TIDAL
node tidal_search.js "stronger kanye west"

# Inspect what quality TIDAL has for a track
node tidal_check_quality.js 103805726
```

See [`ONBOARDING.md`](ONBOARDING.md) for the full CLI reference.

## Limitations

- **Spotify playlists are capped at 100 tracks** because Spotify's public embed limits it. Spotify's official API restricts new dev apps from reading playlist contents (their November 2024 policy), so we can't use it. A previous attempt at scraping the Spotify Web Player via a headless browser kept hanging on lazy-load; the code was reverted but documented in `CLAUDE.md` if anyone wants to take another swing.
- **TIDAL account region matters** — some tracks aren't available everywhere. The app picks up your TIDAL country code at sign-in and passes it through.
- **DRM-locked tracks** can't be downloaded (rare — usually DJ mixes or some video content).

## Disclaimer

For personal use with a valid TIDAL subscription only. This tool is not affiliated with TIDAL. You're responsible for understanding TIDAL's Terms of Service in your jurisdiction. Don't redistribute the audio.

## Credits

Built on the foundation of [sachinsenal0x64/hifi](https://github.com/sachinsenal0x64/hifi) and [binimum/hifi-api](https://github.com/binimum/hifi-api) — the embedded TIDAL OAuth credentials come from those projects.

## License

MIT — see [`LICENSE`](LICENSE).
