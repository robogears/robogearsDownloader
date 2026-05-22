# What's new in v0.1.8

## Fixed "Unknown manifest type: application/vnd.tidal.bts"
- TIDAL recently started returning a new `application/vnd.tidal.bts` manifest type for some tracks. The parser only knew about the older `application/vnd.tidal.bt` (no `s`) variant and threw on the new one, killing downloads for affected tracks on both Windows and macOS.
- Same JSON shape inside — single direct URL — so the matcher now accepts any `application/vnd.tidal.*` mime type. Future-proofs against further variants too; if TIDAL ever changes the schema rather than just the suffix, you'll now get a clear error with the response prefix instead of a cryptic crash.

## Updated handoff doc (`CLAUDE.md`)
- Internal: refreshed with full v0.1.6 + v0.1.7 detail — the `cwd: __dirname` spawn fix, the `app.asar` → `app.asar.unpacked` binary-path rewrite, the self-installing updater architecture (state machine, relauncher `.cmd` script, why `PORTABLE_EXECUTABLE_FILE`), and new diagnostic + Don't entries.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.7...v0.1.8
