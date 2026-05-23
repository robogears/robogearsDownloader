# What's new in v0.1.21

## Preview improvements
- **Volume slider** in the queue header (next to the queue count). Drag to set preview volume in real time; the setting persists across restarts. Curve is squared — i.e., slider at 50% gives 25% audio volume — so the bottom of the slider gets quiet a lot faster than linear would. Default 50%.
- **Click any waveform to play that track** at the clicked position. The currently-playing track's waveform still works as a click-and-hold scrub bar; other tracks treat the click as "play from here."
- **Background pre-loading** of waveforms. When tracks land in the queue (URL paste, search add, OCR add) or are restored from a previous session, their waveforms now pre-fetch + paint in the background at concurrency 2. By the time you go to click play, the waveform is already there.
- **Success ping** when a batch finishes cleanly — a 3-bell ascending G5 → C6 → E6 arpeggio with bell-like decay. Distinct from the existing 2-note "starting" chime so you can tell starting vs done by ear.

## Bug fix
- **"Preview playback failed (code 4)" log noise** when rapidly switching between tracks. Was a stale event from the just-torn-down audio element being caught by the new track's error listener — fixed by guarding every audio listener against firing on a no-longer-current element.

## Easter eggs
- Click the **logo or app name** in the topbar for a fart noise.
- Click the **version number** for the same fart at 7× pitch (mouse-fart edition).
- "made with love by robogears :)" anchored to the bottom-left of Settings → Updates.

## Internal
- Preview cache split into two tiers: `peaksCache` (unlimited, ~800 bytes per entry) and `audioCache` (LRU 3 entries). Pre-loaded entries store peaks only and discard the audio bytes; the audio re-fetches on play but the waveform is instant.
- New `waveformplayback.md` doc in the repo — portable guide for replicating the waveform+scrub feature in other projects.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.20...v0.1.21
