# What's new in v0.1.28

## Chrome extension — toolbar popup, bundled install, self-update

The companion Chrome extension grew up. Three big upgrades, no more "dig through chrome://extensions":

- **One-click token paste from the toolbar.** Click the robogears icon in your toolbar (pin it from the puzzle-piece menu if it isn't already there) → tiny popup → paste the token → done. A status dot turns green when the popup confirms the app's listening and the token's right. No more right-clicking → Options → finding the form.
- **Extension ships with the installer.** `chrome-extension/` is now bundled into the desktop installer. On first launch, the app drops it at a stable per-user path and **Settings → Extension** shows you exactly where. Point Chrome's *Load unpacked* at that path once; future app updates refresh the extension files in place — just click reload at `chrome://extensions` to pick them up.
- **Update button inside the popup.** The popup checks GitHub on open and shows an **Update** button when a newer extension version exists. Click it → the app fetches the latest files and overwrites the managed folder → you click reload in Chrome. Faster than a full app update if there's an extension-only fix.

The extension's version now mirrors the desktop app's 1:1 (both at v0.1.28 here, no separate version trail).

## Other fixes
- The content script's "set a token first" message used to try opening the options page silently — but the service worker that handled the message wasn't declared in the manifest, so the call dropped on the floor. Now the toast explicitly tells you to click the toolbar icon. Service worker is also properly declared.

## If you're on v0.1.27
Auto-update works normally — the app will detect v0.1.28 and offer it via the topbar pill or activity-log notice. No manual install needed (unlike the v0.1.26 → v0.1.27 hotfix).

After the desktop app updates, point Chrome's *Load unpacked* at the new bundled extension folder once (path shown in Settings → Extension → **Managed extension folder**). After that, all extension updates ride along with app updates.

---

# Install

- **Windows**: download `robogears-downloader-setup.exe`, double-click. SmartScreen will warn the first time — click **More info → Run anyway**. The installer drops the app at `%LOCALAPPDATA%\Programs\robogears Downloader\` and runs it.
- **macOS** (Apple Silicon): download `robogears-downloader-mac-arm64.dmg`, double-click, drag the app icon onto Applications. Allow it in **System Settings → Privacy & Security** on first launch.

After install (Chrome extension):
1. Open the app → **Settings → Extension** → copy the **Managed extension folder** path.
2. In Chrome: `chrome://extensions/` → toggle **Developer mode** → **Load unpacked** → paste the path.
3. Pin the extension (puzzle-piece icon → pin robogears) so the popup is one click away.
4. Click the icon → paste the **Token** (shown in the same Settings panel) → Save.

Config and TIDAL token are stored per-user (`%APPDATA%\Roaming\robogears Downloader\` on Windows, `~/Library/Application Support/robogears Downloader/` on macOS).

## Requirements

- A TIDAL subscription (HiFi or HiFi Plus). The app uses TIDAL's official OAuth device-code flow — sign in once via Settings; tokens cache locally and auto-refresh.
- For the Chrome extension: Chrome (or any Chromium browser with extension support — Edge / Brave / Arc / etc.). Manifest V3.

---

**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/v0.1.27...v0.1.28
