# What's new in v0.1.27

## Hotfix for v0.1.26 launch crash
The v0.1.26 build was missing `extension-server.js` from its packaged file list. On launch, `electron-main.js` tried to `require('./extension-server')` and crashed immediately with `Cannot find module './extension-server'` — before the GitHub update check could run.

This release adds the file to the package allowlist. No other changes — every v0.1.26 feature (Chrome-extension bridge, Spotify `+` buttons, etc.) is unchanged.

## If you're stuck on v0.1.26
Because v0.1.26 crashes before the auto-updater fires, the app can't pull this release down on its own. **One-time manual install needed** — grab the setup.exe / DMG below and run it. After that, future updates resume working normally.

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**. The installer drops the app at `%LOCALAPPDATA%\Programs\robogears Downloader\` and runs it.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click, drag the app icon onto the Applications folder shortcut. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

The Chrome extension itself is **not** part of the desktop app install — load it unpacked from the [`chrome-extension/`](https://github.com/robogears/robogearsDownloader/tree/main/chrome-extension) folder in the repo if you want the Spotify integration.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- For the Chrome extension: Chrome (or any Chromium browser with extension support — Edge / Brave / Arc / etc.). Manifest V3.

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.26...v0.1.27
