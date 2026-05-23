# What's new in v0.1.14

## Validation build for the macOS auto-update flow
- No new user-visible features. This release exists so anyone running v0.1.13 can exercise the new macOS self-install path — the double-fork daemonization + `~/Library/Logs/robogears Downloader/` diagnostics introduced in v0.1.13 only matter if there's actually something for the in-app updater to point at.
- If you're on v0.1.13 and clicking **Restart to apply** does the right thing — the app downloads this build, swaps the `.app`, and relaunches automatically — the macOS auto-update path is finally settled. From v0.1.15 onward you should never have to manually reinstall.
- If something still goes wrong, check `~/Library/Logs/robogears Downloader/attempts.log` (and `update-<timestamp>.log` if it exists) — the diagnostic trail will tell us exactly where to look next.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.13...v0.1.14
