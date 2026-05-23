# What's new in v0.1.17

## Cover art now displays in Rekordbox (and other strict players)
- New FLAC downloads tag the embedded cover-art as picture type **3 ("Cover (front)")** instead of type 0 ("Other"). Strict players that filter on picture type — Rekordbox, Mixxx, Serato, etc. — now show the artwork. Lenient apps like Windows Explorer were already fine either way, which is why the bug went unnoticed until tracks were imported into DJ software.
- Files already on disk won't auto-update. Re-download them, or run any FLAC tag editor to set the picture type to *Cover (front)* on what you already have.

## Quality-of-life pass
- **Queue persists across app restarts.** Close mid-review or mid-batch and the queue is still there next launch.
- **Settings split into tabs:** Folders / TIDAL / Updates. Less scrolling.
- **"Open folder" button** appears in the activity log after a successful batch finishes — one click to the files.
- **Open buttons** next to the Download and Library folder paths in Settings.
- **Hi-Res badge** now persists from search results into the queue (used to vanish once a track was added).
- **Live library-scan progress** (`Scanning 234 / 500…`) replaces the silent spinner.
- **Cancel button** on the loading overlay during slow Spotify resolves.
- **Spotify 100-track cap** is now called out explicitly when you paste a long playlist — used to silently drop tracks 101+.
- Activity log capped at 2000 lines so long sessions don't bog down the DOM.
- FFmpeg presence verified at startup; clear warning instead of a confusing mid-download failure if it's missing.

## macOS distribution
- macOS ships as `.dmg` only now (the `.zip` target is gone). The in-app updater mounts the DMG via `hdiutil` and extracts the `.app` via `ditto`, which preserves extended attributes the old unzip flow could mangle.

## Internal
- Removed the dead `download:start` IPC handler and `startDownload` preload binding — legacy single-URL flow that no UI was calling anymore (bulk handles everything).
- Removed the no-op `--allow-aac` CLI flag. AAC fallback behavior is controlled by `--flac-only` only.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.16...v0.1.17
