# What's new in v0.1.29

## Silent Chrome-extension updates — no more popup nags

Refactored the extension's update flow so you never have to think about it. v0.1.28 had an Update button and an "Update available" banner in the popup. Both are gone — the extension updates itself silently whenever the desktop app updates.

How it works:

- App auto-updates as usual (topbar pill or activity-log notice).
- After restart, the app writes the new extension files to the managed folder (it's done this since v0.1.28).
- The extension's background service worker polls the app's `/ping` every 60 seconds — also fires immediately on browser startup, on every Spotify page visit, and the moment you open the popup.
- When it sees the on-disk version is newer than what's loaded in Chrome's memory, it calls `chrome.runtime.reload()` itself. Silent reload, no UI.

End result: you accept an app update, then forget about it. The extension catches up within a minute (or instantly if you're browsing Spotify). No popup banner to dismiss, no `chrome://extensions` to visit.

The popup is back to its minimum: token field, Save, status dot, current version. That's it.

## For v0.1.28 users
The first time you open the popup after the app updates to v0.1.29, the v0.1.28 popup code is still loaded in Chrome's memory and it'll show **"Pending update: v0.1.29"** + an **Apply** button. Click Apply once. That's the last manual reload you'll ever do — every update after that is silent.

## Under the hood
- Removed `/extension/update-self` HTTP endpoint and `handleExtensionUpdateSelf` IPC handler from the app.
- Removed `githubJson` helper — the desktop app no longer fetches anything from GitHub for the extension. The only extension source is now whatever's bundled in the installer.
- New `chrome-extension/background.js` service worker drives the alarm-based reload loop.
- Added `alarms` permission to the extension manifest; removed the `api.github.com` host permission (no longer needed).

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click, drag the app icon onto Applications. Allow it in **System Settings → Privacy & Security** on first launch.

After install (Chrome extension):
1. Open the app → **Settings → Extension** → copy the **Managed extension folder** path.
2. In Chrome: `chrome://extensions/` → toggle **Developer mode** → **Load unpacked** → paste the path.
3. Pin the extension to the toolbar (puzzle-piece icon → pin robogears).
4. Click the icon → paste the **Token** (shown in the same Settings panel) → Save.

After that, the extension updates itself silently every time the app updates.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription (HiFi or HiFi Plus). The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- For the Chrome extension: Chrome (or any Chromium browser with extension support — Edge / Brave / Arc / etc.). Manifest V3.

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.28...v0.1.29
