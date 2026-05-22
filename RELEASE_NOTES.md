# What's new in v0.1.6

## Downloads now work on macOS
- Same class of bug as the v0.1.4 TIDAL sign-in fix: in a packaged build, the spawn that ran the download script used `cwd: __dirname`, which resolves to a virtual path inside `app.asar`. macOS's `posix_spawn` can't `chdir` into a virtual asar path before exec, so the child crashed with `Error: spawn … ENOENT` before any download work could happen.
- Fixed in three places — the single-track download spawn and the bulk download spawn in the main process, plus the nested `tidal_download.js` spawn inside `bulk_runner.js`. Child processes now inherit the parent's real on-disk cwd. The scripts themselves only use absolute paths and `__dirname`-relative requires, so cwd never mattered functionally.

## Updated handoff doc (`CLAUDE.md`)
- Internal: refreshed the project doc with everything that's landed since v0.1.0 — releases workflow, in-app updater, in-process auth, macOS ad-hoc signing, settings UI sections, sound effects, the spawn-cwd diagnostic pattern, and the new release-process rules (current-version-only notes, no auto-releases).

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.5...v0.1.6
