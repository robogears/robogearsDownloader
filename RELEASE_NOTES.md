# What's new in v0.1.12

## macOS update relauncher — hardened
- The **Restart to apply** flow on macOS was silently failing for some users — the app would close but the .app on disk wouldn't actually get replaced. Root cause: the detached bash relauncher was getting reaped by the parent Electron process's exit (`detached: true` + `child.unref()` isn't always enough to survive SIGHUP on macOS), so the move-swap-relaunch sequence never ran.
- Fix: wrap the relauncher in **`nohup`** so it ignores SIGHUP, and bump the parent-exit delay from 200 ms to 500 ms to give the child time to fully reparent before the parent dies.
- The relauncher script now also writes a verbose trace log to `/tmp/robogears-update-<timestamp>.log` with `set -x` enabled — if anything still goes wrong, you can `cat` that file to see exactly which step failed (parent-PID wait, quarantine strip, the rename, the move, the codesign, or the open).

## macOS dev launcher
- New `start_app.command` at the repo root — macOS equivalent of `start_app.bat`. Double-click from Finder to launch the app in dev mode, just like Windows. Marked executable in git so it's runnable immediately after a fresh clone.
- Also added a `.gitattributes` rule that pins shell scripts to LF line endings — prevents the classic `\r: command not found` bash error that can hit anyone editing the script on Windows and pushing it.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper. After this build, future updates apply themselves automatically.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.11...v0.1.12
