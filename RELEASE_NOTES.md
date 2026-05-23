# What's new in v0.1.20

## Experimental: inline waveform preview
- Each queue row now has a circular **play button** on the left and a dynamic **waveform** that fills the space between the title and the action buttons. Click play; the waveform paints in once the audio loads.
- **Hold the left mouse button and drag** across the waveform to scrub through the track. Audio keeps playing while you drag, so you can skim for the drop / chorus / intro.
- **Spotlight hover effect** — bars near the cursor swell up slightly with a thin tracking cursor line. Pure flair, but it makes the waveform feel alive.
- Works on both DASH and BTS TIDAL manifests. Caches the last 3 decoded tracks in memory; clicking play on a previously-previewed track is instant.
- Previews fetch at LOSSLESS quality (smaller than Hi-Res, faster). The first preview click on a track takes a few seconds — subsequent toggles are immediate.
- Tracks that are actively downloading, or have no TIDAL match (Spotify-not-found rows), hide the preview controls so they don't clash with the download UI.

## Polish
- The **loading indicator moved from a full-screen overlay to a small pill in the topbar** between the app name and the version number. Funny rotating messages still cycle, slow Spotify resolves can still be cancelled — but the rest of the UI stays usable while you wait.
- Play / pause icons are now inline SVGs instead of unicode characters, so they're crisply centered in their button.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.19...v0.1.20
