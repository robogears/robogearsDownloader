# What's new in v0.1.4

## TIDAL sign-in fixed in packaged builds
- Clicking **Sign in to TIDAL** in the packaged `.exe` (and `.app`) used to fail with `Error: spawn ... ENOENT`. The auth flow was running as a spawned child process with the working directory pointing inside `app.asar`'s virtual filesystem, which the OS can't chdir into — so `CreateProcess` blew up before the child even started.
- The auth flow now runs in-process in the main Electron process: no spawn, no child, no asar weirdness. Status messages still stream into the auth modal exactly like before, and `shell.openExternal()` opens the TIDAL login URL in your default browser.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.3...v0.1.4
