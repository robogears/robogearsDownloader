# What's new in v0.1.13

## macOS update relauncher — second pass
- The `nohup` wrapping in v0.1.12 wasn't enough on some macOS setups — the relauncher script was still being reaped along with the parent Electron process, so **Restart to apply** closed the app without actually swapping the `.app`. This release moves the daemonization *into* the script itself: a classic Unix double-fork (`nohup "$0" --daemonized "$@" & disown`) so the actual work runs in a process with no parent that can drag it down. Plus an explicit `trap "" HUP TERM` for double safety.
- If anything still goes sideways, you can now find the diagnostic trail in **`~/Library/Logs/robogears Downloader/`** (was `os.tmpdir()` before, which is `/var/folders/<random>/` on macOS — basically un-findable). Two files now:
  - `attempts.log` — appended **before** any spawn happens. If this file doesn't exist after a failed update, the apply IPC itself didn't run. If it exists but the script log doesn't, the spawn failed and the error is captured here.
  - `update-<timestamp>.log` — full `set -x` trace of the script if it actually ran, showing exactly which step (`mv`, `codesign`, `open`, etc.) failed or succeeded.

If you've been hitting the "app closes but doesn't update" issue on macOS, install this build manually one more time and the next update click will either work or leave a real diagnostic trail.

---

# Install

- **Windows**: download `robogears-downloader.exe`, double-click. Windows SmartScreen will warn the first time — click **More info → Run anyway**. Portable; runs from anywhere with no installer. Future updates apply themselves via the in-app updater.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `/Applications`. On first launch **right-click → Open** to bypass Gatekeeper.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.12...v0.1.13
