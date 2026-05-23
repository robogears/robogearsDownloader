# What's new in v0.1.11

## Cancel button
- A red **Cancel** button now appears next to **Clear all** while a download is running. Clicking it plays a descending sine chime (G5 → C5, mirror of the existing download chime), kills the in-flight child process, and flips any not-yet-finished tracks to the **failed** state so they pick up the per-row retry buttons. No more "wait it out or close the app" if you change your mind mid-batch.

## Retry: individual, all, or any subset
- **`↻ Retry`** per row (existing) — immediate single-track re-run.
- **`↻ Retry all (N)`** in the queue header — auto-appears when 2+ tracks have failed. One click reruns every failed track as a batch.
- **Multi-select checkboxes** on each failed row — click to tick a subset. The header button then switches to **`↻ Retry selected (M)`** and runs just the ones you picked. Selections clear automatically when the retry fires. Lets you cherry-pick specific failures (e.g. "retry these three, skip those two") without manually clicking ↻ per row.

## New topbar logo
- The placeholder dot in the upper-left has been replaced with a small inline-SVG version of the app icon — same vinyl-with-download-arrow mark, scaled and simplified for 22 px. Matches the `.exe` / `.app` icon you see in your taskbar or Dock.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper. After this build, future updates also apply themselves automatically.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.10...v0.1.11
