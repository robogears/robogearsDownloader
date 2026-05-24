# What's new in v0.1.25

## Playlist CSV / text import — bypass the 100-track Spotify cap
- The drop-zone (where the "Coming soon" OCR placeholder used to live) now accepts **CSV files** and **pasted text**. Click it to pick a file, drop a file onto it, or just paste lines of `Title - Artist` anywhere in the app.
- Works out of the box with **Exportify** CSVs (just export your Spotify playlist there, drop the file). Also reads any CSV that has columns for "title" / "track name" / "song" and "artist".
- One-click shortcut: the drop-zone has a clickable **Exportify** link that opens [exportify.net](https://exportify.net) in your browser — log into Spotify there, pick the playlist, export, drop the CSV back here.
- Plain text fallback handles separators: `-`, `—`, `–`, `|`, or tab.

## One-click "Update now" pill
- A small pulsing pill appears next to the version number in the topbar when a new release is detected. **Click once** → it downloads (with live `Downloading 42%` feedback) → auto-applies → restarts. No second click needed.
- The existing activity-log notice flow (two-click: Download then Restart to apply) is still there for anyone who wants to review before restarting.

## Live progress when importing
- The loading overlay now shows `Matching 234 / 500 tracks on TIDAL…` while a pasted/dropped tracklist is being resolved, instead of a generic spinner. No more wondering whether it's stuck.

## Internal
- Removed the Tesseract.js CDN script entirely (it was being fetched on every launch even though OCR was feature-gated off). CSP tightened — `cdn.jsdelivr.net` removed from `script-src` / `connect-src` / `worker-src`.
- IPC rename: `resolve:ocr-tracks` → `resolve:tracklist`. Track source field `'ocr'` → `'import'`. Queue badge shows `Import` instead of `OCR`.

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**. The installer drops the app at `%LOCALAPPDATA%\Programs\robogears Downloader\` and runs it. Future updates self-apply.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- For playlists >100 tracks via Spotify: export to CSV via [Exportify](https://exportify.net) (or any tool with title/artist columns) and drop the file onto the import drop-zone.

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.24...v0.1.25
