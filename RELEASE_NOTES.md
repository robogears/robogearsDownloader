# What's new in v0.1.26

## Chrome extension — add tracks straight from Spotify
A companion Chrome extension is now bundled in the repo at [`chrome-extension/`](https://github.com/robogears/robogearsDownloader/tree/main/chrome-extension). Once loaded:

- Every track row on **open.spotify.com** (playlists, albums, artist pages, search results, Discover Weekly, anywhere) gets a small circular `+` button next to Spotify's own row controls.
- Click it → the track lands in the desktop app's queue, matched on TIDAL automatically.
- A toast confirms `Added 1 to robogears` (or the error if anything's off).

Bypasses the Spotify embed's 100-track playlist cap without needing the Exportify CSV detour. Cherry-pick tracks one at a time from anywhere you browse Spotify.

### Install the extension
1. Open the desktop app, go to **Settings → Extension**, copy the token.
2. In Chrome: `chrome://extensions/` → toggle **Developer mode** → **Load unpacked** → pick the `chrome-extension` folder from this repo (clone or download the source).
3. Right-click the extension → **Options** (or the options page will pop up automatically on first install) → paste the token → **Save** → **Test connection** (should say "Connected").
4. Visit any Spotify page and start clicking `+` buttons.

The app's local bridge listens on `http://127.0.0.1:8273` (localhost only — no LAN exposure). Token is generated on first launch and can be regenerated from the same Settings panel if it ever leaks.

## Under the hood
- New module `extension-server.js`: tiny HTTP server with `Bearer`-token auth and CORS for `chrome-extension://*` origins. `/ping` (unauthenticated health check) + `/queue/add` (authed, takes a tracks array).
- Track flow: extension scrapes title + artist + Spotify track ID from each `[data-testid="tracklist-row"]` → POSTs to localhost → main process runs the same TIDAL search + scoring as the CSV importer → matched tracks land in the queue with a "Spotify ext" badge.
- The extension's content script uses a `MutationObserver` so it picks up newly-rendered rows as you scroll Spotify's virtualized lists; presence-based de-dup so rows survive Spotify's own re-renders.

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**. The installer drops the app at `%LOCALAPPDATA%\Programs\robogears Downloader\` and runs it. Future updates self-apply.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click it, then drag the app icon onto the Applications folder shortcut in the window that opens. **Don't forget** to allow the app in System Settings → Privacy & Security on first launch.

The Chrome extension is **not** auto-installed with the desktop app — load it unpacked from the GitHub repo (see "Install the extension" above) if you want the Spotify integration.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- For the Chrome extension: Chrome (or any Chromium browser with extension support — Edge / Brave / Arc / etc.). Manifest V3.

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.25...v0.1.26
