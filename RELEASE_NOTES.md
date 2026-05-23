# What's new in v0.1.16

## Polished install window
- The DMG installer's background scene got three improvements:
  - **No more white when you resize.** The backdrop is now a 1920×1200 canvas (same dark black as the rest), so dragging the window larger just reveals more black instead of macOS's default white-area-beyond-image.
  - **Tonearm now sits vertically off to the side** of the platter, in the natural at-rest position. Doesn't cross the groove rings anymore.
  - **Footer reads `DON'T FORGET to allow the app in System Settings → Privacy & Security`** in bold-white. The old "right-click → Open" hint isn't enough on newer macOS (Ventura+) — Gatekeeper now sends users to System Settings and the **DON'T FORGET** wording makes that step harder to miss.

No code changes. Pure DMG-art polish.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.15...v0.1.16
