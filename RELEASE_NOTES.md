# What's new in v0.1.24

## Windows now installs like a proper program
- Switched from portable single-`.exe` to an NSIS installer. Downloading and running `robogears-downloader-setup.exe` installs the app to `%LOCALAPPDATA%\Programs\robogears Downloader\` (per-user, no admin required), adds Start Menu + Desktop shortcuts, registers in **Add or Remove Programs**, and launches the app.
- Future updates apply themselves via the installer's silent-update mode — NSIS detects the running app, closes it, replaces files, and relaunches.

**If you're already on Windows v0.1.23 or earlier:** the in-app updater will fetch the new installer, but the portable swap-mechanism inside that older build can't run an installer correctly. **One-time manual step:** download `robogears-downloader-setup.exe` from this release and run it. The old portable `.exe` will be replaced by the properly installed version. After that, auto-updates work normally going forward.

## Library matcher — fewer false-positive duplicates
- Tightened the "already in library" check so it requires both **title AND artist** to confidently agree before marking a track as a hard duplicate. Files with empty/missing/wrong artist metadata (common in sketchy MP3 dumps from SpotDownloader-style sites) used to pass an over-lenient artist check and get greyed out as "exact" matches based on title alone.
- Now those uncertain matches show the yellow `⚠ similar version in library` badge and **stay included** in the queue by default — the user sees the warning and the file path, but the track downloads normally instead of being silently skipped.

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**. The installer drops the app at `%LOCALAPPDATA%\Programs\robogears Downloader\` and runs it. Future updates self-apply.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.23...v0.1.24
