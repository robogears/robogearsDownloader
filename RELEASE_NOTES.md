# What's new in v0.1.2

## macOS launch fix
- The arm64 `.app` is now **ad-hoc code-signed** during the build. Apple Silicon Gatekeeper refused to run the v0.1.1 build at all (showed *"robogears-downloader is damaged and can't be opened"*) because completely-unsigned binaries are blocked outright on arm64. The new ad-hoc signature gives macOS a valid (but untrusted) signature to verify, so first-launch now shows the normal "unidentified developer" warning instead — bypassable with **right-click → Open**.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).
  - If macOS still says *"damaged and can't be opened"* (this happens on v0.1.1 only), open Terminal and run `xattr -cr "/Applications/robogears Downloader.app"` to clear the quarantine attribute, then try again.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.1...v0.1.2
