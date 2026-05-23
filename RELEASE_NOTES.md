# What's new in v0.1.10

## macOS self-installing updater
- When the **Download update** notice appears in the activity log on macOS, clicking it now does the same thing it's been doing on Windows: downloads the new `.app` (with live percentage in the button), changes to **Restart to apply**, swaps the running `.app` in place, and relaunches itself — no more drag-to-Applications dance, no more Gatekeeper re-warnings on every update.
- Under the hood: `ditto -x -k` to extract the new `.app` while preserving extended attributes; `xattr -dr com.apple.quarantine` to strip the download quarantine so Gatekeeper trusts the relaunched build; `codesign --sign -` to re-apply the ad-hoc signature after the move; a backup-and-rollback so you're never left with no app if anything in the chain fails.
- This is the **last manual reinstall** for Mac. From v0.1.11 onward, the auto-update path activates.

## Per-track download progress and Retry
- Each track in the queue now shows its own state during a batch: a thin progress bar under the title that fills as the track downloads, plus a badge that ticks from `↓ 0%` through `↓ 100%` to `✓ done` (or `⏭ skipped`, or `✗ failed`).
- An overall batch progress bar sits above the queue with a `5 / 47`-style counter, so you can see how much further the whole job has to go at a glance.
- Failed tracks now stay in the queue with a `↻ Retry` button that re-runs just that one track. No more re-pasting URLs to recover from a single transient error.

## Smaller polish
- Direct-URL (BTS-manifest) downloads now **stream straight to disk** with byte-level progress instead of buffering the whole file in memory. FLACs no longer briefly inflate RAM during their final-second download.
- The activity log is now noise-free during downloads — internal progress markers no longer leak into it; only meaningful per-track lines show up.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper (the app uses an ad-hoc signature, not a paid Apple Developer cert). After this build, future updates are automatic.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.9...v0.1.10
