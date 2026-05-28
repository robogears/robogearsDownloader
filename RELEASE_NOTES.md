# What's new in v0.1.30

## Force-reload + folder-mismatch fix for the Chrome extension

A polish pass on v0.1.29's silent-update flow. If your extension version isn't catching up to the app version, the popup now diagnoses the cause and walks you through the fix.

What changed:

- **Reload button when versions don't match.** Opening the popup compares the version loaded in Chrome's memory against the on-disk version the app manages. If they differ, the popup surfaces "Loaded v0.1.X · on disk v0.1.Y" with a **Reload** button — one click and the extension reloads itself. No more waiting for the 60-second alarm tick.
- **Folder-mismatch detection.** If you click Reload but the version *still* doesn't advance, that means Chrome's loading from a different folder than the app's managed one. The popup detects this (via tracked reload attempts) and shows step-by-step instructions: `chrome://extensions` → Remove → Load unpacked from the path the popup hands you (with a Copy button for the path).
- **No more infinite reload loops.** The background worker now skips its auto-reload check if it sees a recent attempt to reach the same version that didn't actually advance. Before, a wrong loaded folder meant `chrome.runtime.reload()` would fire every minute forever with no progress.

The popup itself is still minimal — token + status dot + version. The reload section only appears when there's a mismatch to fix.

## Under the hood
- `/ping` endpoint now returns `managedExtensionPath` alongside the existing `managedExtensionVersion`, so the popup can show users exactly where to point Load Unpacked.
- `chrome.storage.local.lastReloadAttempt` tracks the most recent disk-version target across both the background worker and the popup, letting each detect "I tried this but it didn't advance."

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click, drag the app icon onto Applications. Allow it in **System Settings → Privacy & Security** on first launch.

For the Chrome extension:
1. Open the app → **Settings → Extension** → copy the **Managed extension folder** path.
2. In Chrome: `chrome://extensions/` → toggle **Developer mode** → **Load unpacked** → paste the path.
3. Pin the extension to the toolbar.
4. Click the icon → paste the **Token** → Save.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription (HiFi or HiFi Plus). The app uses TIDAL's official OAuth device-code flow.
- For the Chrome extension: Chrome (or any Chromium browser — Edge / Brave / Arc / etc.). Manifest V3.

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.29...v0.1.30
