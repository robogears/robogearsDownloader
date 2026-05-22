# What's new in v0.1.5

## Copy button on the TIDAL sign-in URL
- The auth modal now displays the TIDAL verification URL in a read-only input with a **Copy** button right next to it. If the auto-launched browser doesn't open (or you want to authorize on a different device), one click puts the URL on your clipboard. Button briefly shows **Copied ✓** for feedback.

## Manual "Check for updates" button in Settings
- New **Updates** section in Settings, sitting between TIDAL account and Reset config. Shows your current installed version and a one-click **Check for updates** button. Result reflects in the button itself: *Checking…* → *vX.Y.Z available!* / *Up to date ✓* / *Check failed* (auto-reverts after 2.5 s). When an update is available, the activity-log notice still appears via the existing on-launch flow.

## Version in the topbar
- The current version number now sits right next to **robogears Downloader** in the topbar (small, bold, muted). At-a-glance confirmation of what you're running without opening Settings.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.4...v0.1.5
