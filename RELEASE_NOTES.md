# What's new in v0.1.7

## Self-installing updater
- Clicking **Download update** in the activity log now actually downloads the new build (live percentage in the button) and changes to **Restart to apply** when done. Click that, and the app swaps the `.exe` with the freshly downloaded one and relaunches itself — no more browsing to GitHub and replacing the file by hand.
- Active on Windows portable builds where we can find the launcher path via `PORTABLE_EXECUTABLE_FILE`. macOS keeps the existing flow (button opens the release page in your browser) until we invest in code-signing / notarization for proper auto-update.

## ffmpeg now actually runs in packaged builds
- Every download was crashing in its final remux step with `Error: spawn … ENOTDIR` on packaged builds. Cause: `ffmpeg-static` returns a path inside `app.asar` (the archive that holds the app), but the binary actually lives next to it in `app.asar.unpacked` — the OS sees the asar as a file and refuses to traverse into it for the exec syscall. The path is now rewritten to point at the real on-disk copy.
- Combined with the v0.1.6 download-spawn fix, this is the second half of getting macOS downloads working end-to-end.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.6...v0.1.7
