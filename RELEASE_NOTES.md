# What's new in v0.1.19

## Validation bump
- No code changes from v0.1.18. Continues exercising the DMG-only auto-update path on macOS (and the portable-exe swap on Windows). If you're already on v0.1.17 or v0.1.18, hitting **Download update** should land you here automatically.
- Pure release-plumbing test — no user-facing functionality change.

If you're still on v0.1.16 or earlier on macOS, you'll need to install the latest DMG manually once — older builds look for a `mac-arm64.zip` asset that no longer exists. After that one-time install, all future updates auto-apply.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.18...v0.1.19
