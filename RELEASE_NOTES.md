# What's new in v0.1.3

## In-app updater
- On launch, the app now quietly checks GitHub for newer releases. If one exists, a one-line notice with a **Download update** button appears in the activity log right under your welcome line. Clicking the button opens the right asset for your OS (`.exe` on Windows, `mac-arm64.zip` on macOS) in your default browser.
- The check is silent on failure (no internet, GitHub rate-limit, etc.) — you never see "update check failed" noise.
- The notice only appears when the published GitHub release is strictly newer than your installed version; drafts and pre-releases are ignored.

## TIDAL sign-in browser now opens reliably
- Clicking **Sign in to TIDAL** in Settings now opens the OAuth login URL via Electron's `shell.openExternal()` — cross-platform and reliable on both Windows and macOS.
- The previous build used a Windows-only shell hack (`start ""`) that silently failed on macOS and was fragile on Windows too. The TIDAL login URL is still shown in the auth modal as a fallback in case the browser doesn't launch automatically.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.2...v0.1.3
