# What's new in v0.1.9

## FLAC tracks now actually land as `.flac` on macOS
- Lossless tracks were saving as `.m4a` (the AAC fallback) even when TIDAL was serving FLAC content. Cause: the codec detector only matched a literal lowercase `'flac'` in the manifest's codec field — but the newer `application/vnd.tidal.bts` manifests (introduced for some tracks recently) sometimes report the codec under a different label.
- The detector now uses `audioQuality` from the playback response as the primary signal: `LOSSLESS` and `HI_RES_LOSSLESS` mean FLAC, period, regardless of what the manifest's codec field says. Codec/regex checks remain as fallbacks for older manifest formats.
- Combined with the v0.1.8 BTS manifest fix, end-to-end FLAC downloads should now work properly on both platforms.

## New app icon
- The default Electron gem is gone. Replaced with a custom monochrome mark: a vinyl record with subtle grooves and a download arrow on the label, on a macOS-style rounded black background. Matches the app's pure-black / stark-white theme.
- macOS `.app` and Windows `.exe` both pick it up automatically — electron-builder generates the `.icns` for macOS and embeds the `.ico` into the Windows binary at build time.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert).

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.8...v0.1.9
