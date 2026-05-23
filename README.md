# robogears Downloader

A desktop app for downloading lossless FLAC tracks from TIDAL.

Paste a TIDAL or Spotify link — track, album, or playlist — or type a song name to search. Review the queue, click play on any track to preview it inline with a scrubbable waveform, then download. Auto-skips songs you already have, embeds proper metadata + cover art (DJ-software friendly), updates itself in the background.

## Install

Grab the latest release from [the releases page](https://github.com/robogears/robogearsDownloader/releases/latest):

- **Windows**: `robogears-downloader.exe`. Portable — runs from anywhere, no installer. First launch shows a SmartScreen warning (**More info → Run anyway**).
- **macOS** (Apple Silicon): `robogears-downloader-mac-arm64.dmg`. Drag the app onto the Applications shortcut in the installer window. Allow it in **System Settings → Privacy & Security** on first launch.

Future updates apply themselves through the in-app updater — no re-downloading.

Requires an active **TIDAL HiFi or HiFi Plus subscription**.

## Features

- **Highest quality TIDAL has** — Hi-Res Lossless (24-bit) when available, falls back to 16-bit FLAC, and to 320 kbps AAC `.m4a` only when no lossless master exists
- **Spotify URLs** — track, album, playlist (playlists capped at 100 tracks by Spotify's public embed)
- **Free-text search** — type a song name, pick from the TIDAL results modal
- **Inline waveform preview** — click play on any queue row to hear it. The waveform is scrubbable: click-and-hold to drag through the audio while it plays
- **Volume slider** for previews (squared curve so the low end gets quiet fast)
- **Library deduplication** — point at your music folder; the app reads audio-tag metadata and filenames, skips exact duplicates with a "+ Add" opt-in, flags similar versions (remixes/live/extended) with a warning badge
- **Cover art tagged properly** — FLAC PICTURE block type 3 ("Cover (front)"), so Rekordbox / Mixxx / Serato actually display it
- **Persistent queue** — close mid-review or mid-batch, your queue is still there next launch
- **Parallel segment downloads** — typical 4-minute track in ~3 seconds, full album under a minute
- **In-app updater** with manual `Check for updates` button in Settings
- **Retries on network errors**, FLAC integrity check after each download, hard timeouts so it never hangs

## Quick use

| Action | What to do |
|---|---|
| Download a single track or album | Paste any TIDAL/Spotify URL → **Add to queue** → **Download all** |
| Find a song by name | Type a search term → pick from the results modal |
| Preview before downloading | Click ▶ on any queue row. Drag along the waveform to scrub |
| Review before downloading | Items you already own are greyed with **+ Add** to opt in. Similar versions show a yellow badge but stay included. Remove anything with ✕ |
| Update the app | Hit **Download update** in the activity log when a new version appears, or check manually in Settings → Updates |

## First-time setup

1. Open **Settings** (⚙ icon)
2. **Sign in to TIDAL** — a browser tab opens, log in, click *Allow*
3. Set your **Download folder** (starts blank on first launch)
4. *Optional*: set your **Music library folder** so the dedup check has something to compare against

## How it works

TIDAL URLs hit TIDAL's API directly. Spotify URLs are resolved through Spotify's public embed page, then each track is matched to TIDAL by ISRC when available, otherwise by title + artist + duration scoring. Downloads use MPEG-DASH parallel segment fetch + FFmpeg remux into a proper `.flac` (or `.m4a` fallback) with embedded metadata and cover art piped through stdin.

Library dedup reads each existing file's audio tags via [`music-metadata`](https://github.com/Borewit/music-metadata) so it works even when filenames are inconsistent or truncated.

Full architecture and design notes live in [`CLAUDE.md`](CLAUDE.md). The waveform-preview feature has its own portable write-up in [`waveformplayback.md`](waveformplayback.md), and the in-app updater pattern is documented in [`updater.md`](updater.md) if you're building something similar.

## Limitations

- **Spotify playlists are capped at 100 tracks** by their public embed. Their official API blocks new dev apps from reading playlist contents (Nov 2024 policy), so the embed is the workable path.
- **TIDAL region matters** — some tracks aren't available everywhere. The app picks up your country code at sign-in.
- **DRM-locked tracks** can't be downloaded (rare — usually DJ mixes or video content).

## Development

If you want to run from source:

```sh
git clone https://github.com/robogears/robogearsDownloader.git
cd robogearsDownloader
npm install
npm start
```

Requires Node.js 20+.

## Disclaimer

For personal use with a valid TIDAL subscription only. This tool is not affiliated with TIDAL. You're responsible for understanding TIDAL's Terms of Service in your jurisdiction. Don't redistribute the audio.

## Credits

Built on the foundation of [sachinsenal0x64/hifi](https://github.com/sachinsenal0x64/hifi) and [binimum/hifi-api](https://github.com/binimum/hifi-api) — the embedded TIDAL OAuth credentials come from those projects.

## License

MIT — see [`LICENSE`](LICENSE).
