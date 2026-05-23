# What's new in v0.1.15

## macOS now ships as a proper DMG installer
- First-time install on macOS is now the standard drag-to-Applications experience: double-click `robogears-downloader-mac-arm64.dmg`, a window opens with a custom turntable-themed backdrop — the app icon on the left as a record, the Applications folder on the right as a platter, a tonearm sweeping across in between. Drag the record onto the platter.
- The `.zip` is still produced (and is what the in-app updater downloads — smaller, no mount step), but humans installing for the first time get the better window.

## App Translocation fix — auto-update now actually swaps the .app
- macOS Gatekeeper's "Path Randomization" was silently running the app from a **read-only** `/var/folders/.../AppTranslocation/...` shadow whenever it was launched from outside `/Applications/`. The in-app updater dutifully ran but `mv` failed with "Read-only file system" — the app closed, didn't update. This was the bug the diagnostic logs in v0.1.13 finally uncovered.
- The updater now detects a translocated install path and treats `/Applications/<App>.app` as the install destination instead. Combined with the new DMG flow (which puts the app in `/Applications/` properly), translocation should be a non-issue from this build forward.

## Tidying
- The duplicate copies macOS auto-named for you during testing — `robogears Downloader 2.app`, `… 3.app`, `… 4.app` — can be safely dragged to Trash after this install lands. The single canonical copy will be at `/Applications/robogears Downloader.app`.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.14...v0.1.15
