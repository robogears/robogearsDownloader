## Packaging, CI/release and the in-app updater

### Overview

The app is packaged with electron-builder 26.8.1 on Electron 33.4.11 (versions pinned in `package-lock.json`). It ships two installers:

- **Windows:** an x64 NSIS one-click installer named `robogears-downloader-setup.exe`. It installs per user with no admin rights and is unsigned.
- **macOS:** an Apple Silicon (arm64) DMG named `robogears-downloader-mac-arm64.dmg`, with a turntable-themed Finder window (drag the "record" onto the "platter").

electron-builder is told not to sign the Mac app (`mac.identity: null`). Instead, a build hook gives the `.app` an ad-hoc signature (`codesign --force --deep --sign -`), so Apple Silicon Gatekeeper reports an "unidentified developer" instead of "damaged". Nothing is notarized.

GitHub Actions (`.github/workflows/release.yml`) builds both installers whenever a `v*` tag is pushed (or the workflow is started by hand). It attaches them to a **draft** GitHub release, and the owner publishes it by hand. The release notes are meant to come from `RELEASE_NOTES.md`. The release job never checks out the repository, so that file is not on disk when the release is created. This is consistent with the documented "empty release body on every release", which the ship procedure fixes by hand with `gh release edit --notes-file`.

The in-app updater lives in the main process (`electron-main.js:101-469`), with two renderer UIs: an activity-log notice and a topbar "Update now" pill.

- **When it checks:** once at launch, and again whenever the user clicks Check for updates in Settings.
- **How it decides:** it asks GitHub's "latest release" API, compares version numbers dot by dot as integers, and picks the release asset whose name contains `mac-arm64.dmg` (macOS) or `setup.exe` (Windows).
- **How it downloads:** it streams the asset to the temp folder with live progress.
- **How it installs on Windows:** it runs the downloaded installer with `/S --updated` and quits.
- **How it installs on macOS:**
  1. Mount the DMG and copy the `.app` out.
  2. Write a self-daemonizing bash script, then quit.
  3. The script waits for the old process to exit, swaps the bundle (keeping a `.bak` for rollback), strips quarantine, re-signs ad-hoc and opens the new app.
  4. If the running copy is a Gatekeeper "translocated" shadow copy, it installs to `/Applications/robogears Downloader.app` instead.

The repo docs (`CLAUDE.md`, `updater.md`, `ship.md`) describe some older behaviour, such as the portable `.exe`, the `.cmd` swap script and a 200 ms quit delay. This section follows the code at v0.1.30.

---

### Components

#### Build configuration

**1. npm scripts** — `package.json:6-13`

| Script | Command | Notes |
|---|---|---|
| `start` | `electron .` | Dev run. |
| `auth` | `node tidal_auth_node.js` | CLI TIDAL sign-in. |
| `build` | `electron-builder` | All targets from config. |
| `build:win` | `electron-builder --win` | No target flag on purpose, so `build.win.target` (nsis) is used. A `--win <target>` flag would override the config and rename the artifact, which breaks the CI upload step. |
| `build:mac` | `electron-builder --mac --arm64` | `--arm64` is an arch filter, not a target, so the config's `dmg` target still applies. |
| `sync-ext` | `node scripts/sync-extension-version.js` | Copies `package.json` `version` into `chrome-extension/manifest.json`. Extension only, so it is dropped in the port. |

There is no `build:portable` script (it was removed on purpose).

**2. electron-builder config** — `package.json:28-104`

- **Identity**
  - `appId` `com.robogears.downloader`: CFBundleIdentifier on macOS.
  - `productName` `robogears Downloader`: the `.app` / `.exe` product name.
  - `copyright` `Copyright © 2026 robogears`.
- **`publish: null`** stops electron-builder from auto-publishing on tag builds. Without it, the build demands `GH_TOKEN` and fails.
- **`afterPack: ./build/after-pack.js`**; **`directories.output: dist`**.
- **`files`** is an allowlist packed into `app.asar`:
  - **Included:** `electron-main.js`, `electron-preload.js`, `tidal_lib.js`, `tidal_download.js`, `tidal_auth_node.js`, `tidal_search.js`, `tidal_check_quality.js`, `bulk_runner.js`, `extension-server.js`, `renderer/**/*`, `package.json`, `node_modules/**/*`.
  - **Excluded:** `!**/*.md`, `!.gitignore`, `!start_app.bat`, `!**/{.DS_Store,Thumbs.db,desktop.ini}`, `!**/{.git,.github,.vscode,.idea}`, `!**/{*.log,*.tmp,token.json}`.
  - **Not shipped:** `build/`, `scripts/`, `start_app.command` and the docs. `build/icon.png` is used at runtime only in dev (`electron-main.js:89-95`).
- **`asarUnpack: ["node_modules/ffmpeg-static/**/*"]`** puts the FFmpeg binary on real disk at `app.asar.unpacked/node_modules/ffmpeg-static/`. Code rewrites `app.asar` to `app.asar.unpacked` in the path before spawning it (`electron-main.js:533`, `tidal_download.js:32-36`). `spawn()` cannot exec a file inside an asar archive.
- **`extraResources: [{from: "chrome-extension/", to: "chrome-extension/"}]`** copies the extension folder to `<resources>/chrome-extension` (on macOS, `Contents/Resources/chrome-extension`). The `files` exclusions do not apply here. Inventory only.
- **Windows**
  - `win.icon` is `build/icon.png`.
  - `win.target` is `[{target: "nsis", arch: ["x64"]}]`.
- **NSIS:**
  - `oneClick: true`, `perMachine: false`: per-user install. electron-builder's default per-user location is `%LOCALAPPDATA%\Programs\robogears Downloader\`, as the docs state.
  - `createDesktopShortcut: true`, `createStartMenuShortcut: true`, `shortcutName: "robogears Downloader"`.
  - `artifactName: "robogears-downloader-setup.exe"`.
  - `runAfterFinish: true`, `deleteAppDataOnUninstall: false`.
- **macOS**
  - `mac.icon` is `build/icon.png`; `mac.category` is `public.app-category.music` (LSApplicationCategoryType).
  - `mac.target` is `[{target: "dmg", arch: ["arm64"]}]`.
  - `mac.artifactName` is `robogears-downloader-mac-${arch}.${ext}`, which gives `robogears-downloader-mac-arm64.dmg`.
  - `mac.identity: null` means electron-builder signs nothing. No hardened runtime, entitlements, notarization or minimum macOS version are configured. An arm64-only build implies macOS 11 or later in practice.
- **DMG:**
  - `title` is `Install robogears Downloader` (the volume and window name).
  - `background` is `build/dmg-background.png`, `iconSize` is 100, and `window` is `{width: 540, height: 400}`.
  - `contents`:
    - `{x: 140, y: 220, type: "file"}`: the `.app`.
    - `{x: 400, y: 220, type: "link", path: "/Applications"}`.
  - No DMG `format` is set (electron-builder default) and the DMG is not signed.

**3. afterPack ad-hoc signing hook** — `build/after-pack.js:13-22`

1. `exports.default = async function afterPack(context)`.
2. If `context.electronPlatformName !== 'darwin'`, return (Windows does nothing).
3. `appPath = path.join(context.appOutDir, context.packager.appInfo.productFilename + '.app')`, which is `…/robogears Downloader.app`.
4. Log `[afterPack] Ad-hoc signing <appPath>`.
5. `execSync('codesign --force --deep --sign - "<appPath>"', {stdio: 'inherit'})`. A non-zero exit throws and fails the build.
6. Log `[afterPack] Done.`

This runs after the app is packed and before the DMG is made. Its header comment still says "right-click → Open". That bypass no longer works on current macOS; the DMG footer correctly points to System Settings.

**4. Art assets**

- **`build/icon.svg` / `build/icon.png`** (1024×1024 RGBA; the PNG matches the SVG). The PNG is the single source; electron-builder converts it to `.icns` / `.ico`. Full-bleed with no macOS icon-grid margin:
  - black rounded square, `rx=ry=180`, `#000000`
  - white disc, r=380, centred at (512, 512)
  - four groove rings, r=350/310/270/230: black stroke, width 2, opacity 0.5
  - black label disc, r=200
  - white download arrow at `translate(512,512)`: shaft `rect x=-30 y=-90 w=60 h=110`, head `polygon (-90,20) (90,20) (0,130)`
- **Topbar mini logo** (`renderer/index.html:12-20`, 24×24 viewBox, drawn at 22 px): white circle r=10, black label r=5, white arrow path `M10.5 7 L13.5 7 L13.5 10 L15.5 10 L12 14 L8.5 10 L10.5 10 Z`. No background, no grooves.
- **`build/dmg-background.svg` / `.png`** (1920×1200; the PNG matches the SVG). The whole canvas is `#0a0a0a`, so resizing the Finder window shows more black instead of white. The scene sits in the top-left 540×400:
  - **Title:** "Install robogears Downloader" at (270, 55); 22 px, weight 700, white, centred, letter-spacing −0.4.
  - **Subtitle:** "Drop the needle — drag the record onto the platter" at (270, 82); 13 px, `#9a9a9a`.
  - **Platter rings** centred at (400, 220), behind the `/Applications` icon:
    - r92 `#3a3a3a`, width 2
    - r84 / 76 / 68 / 60 `#2f2f2f`, width 1
    - r52 `#2a2a2a`, width 1
  - **Tonearm at rest:**
    - pivot: circle (510, 115) r11, fill `#1f1f1f`, stroke `#5a5a5a` width 2; pin r3 `#7a7a7a`
    - shaft: (510, 121) to (510, 225), `#5a5a5a` width 4
    - headshell: rect x494 y222, 32×14, rx2, fill `#1f1f1f`, stroke `#5a5a5a` width 1.5
    - stylus: (510, 236) to (510, 244), `#9a9a9a` width 2
  - **Footer** at (270, 362), 12 px: bold white "DON'T FORGET" (letter-spacing 0.5), then grey " to allow the app in System Settings → Privacy & Security".
  - **Fonts:** `-apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif`.
  - There is no `@2x` background, so the image is 1x only.

**5. Dev launchers and line endings**

- `start_app.command:1-6`: `#!/bin/bash`, `cd "$(dirname "$0")"`, `npm start`. In this copy the file has no executable bit (`-rw-r--r--`).
- `start_app.bat:1-3`: `@echo off`, `cd /d "%~dp0"`, `start "" /B npm start`.
- `.gitattributes:4-5`: `*.command text eol=lf` and `*.sh text eol=lf`, so bash never sees CRLF. The runtime relauncher script is built with `'\n'` joins, so it is always LF.

#### CI and release

**6. Workflow `Build & draft release`** — `.github/workflows/release.yml`

- **Triggers (lines 5-9):** `push.tags: ['v*']` and `workflow_dispatch`.
- **Job `build-win` (12-26):** runs on `windows-latest`.
  1. `actions/checkout@v4`.
  2. `actions/setup-node@v4` with `node-version: '20'`, `cache: 'npm'`.
  3. `npm ci`. ffmpeg-static's postinstall downloads the FFmpeg binary for the runner's platform and arch here.
  4. `npm run build:win`.
  5. `actions/upload-artifact@v4` with `name: win-build`, `path: dist/robogears-downloader-setup.exe`, `if-no-files-found: error`.
- **Job `build-mac` (28-42):** runs on `macos-latest`. Same steps 1-3, then `npm run build:mac`, then upload with `name: mac-build`, `path: dist/robogears-downloader-mac-arm64.dmg`, `if-no-files-found: error`.
- **Job `release` (44-61):** `needs: [build-win, build-mac]`, runs on `ubuntu-latest`, `permissions: contents: write`.
  1. `actions/download-artifact@v4` with `path: artifacts` (files land in `artifacts/win-build/…` and `artifacts/mac-build/…`).
  2. `softprops/action-gh-release@v2` with:
     - `draft: true`
     - `name` and `tag_name` both set to `${{ github.ref_name }}`
     - `body_path: RELEASE_NOTES.md`
     - `files:` `artifacts/win-build/robogears-downloader-setup.exe` and `artifacts/mac-build/robogears-downloader-mac-arm64.dmg`
  - There is **no `actions/checkout` step** in this job.

**7. Ship procedure (manual, as documented)** — `ship.md`, `CLAUDE.md` "Releases", `updater.md:728-762`

1. Only on an explicit instruction from the owner ("ship it", "publish", "release", "push it", "tag vX.Y.Z"). Otherwise make code edits only.
2. Version in `package.json`. `ship.md` says to bump the patch at ship time. The owner's global rule overrides this: bump once on the first change after the last push, then hold. The sync-extension script's comment says to run `npm run sync-ext` after a bump (extension only).
3. Overwrite `RELEASE_NOTES.md` with the current version only, in four parts (format below).
4. Commit and tag:
   1. `git add <explicit files>`
   2. `git commit -m "vX.Y.Z: <summary>"` (with a Co-Authored-By line)
   3. `git push origin main`
   4. `git tag -a vX.Y.Z -m "vX.Y.Z"`
   5. `git push origin vX.Y.Z`. The tag push triggers CI.
5. `gh run watch <id> --exit-status`.
6. Check the body: `gh release view vX.Y.Z --json body --jq '(.body | length)'`.
   - If it is 0 (it is, every time), run `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md` and check again.
   - `updater.md`'s ship-tail uses a threshold of `< 50` characters instead of 0.
7. Report the run link and the draft link. The owner publishes (or runs `gh release edit vX.Y.Z --draft=false`).

Rules and recovery:
- Never change `draft: true`.
- Never force-move a published tag.
- An unpublished draft, or a tag whose release job never ran, may be deleted and re-tagged at the same version.
- On a CI flake (a 502 from the ffmpeg-static download, or "Bad credentials"), run `gh run rerun <id> --failed`.

#### Runtime pieces packaging depends on

**8. App identity, data folder, window** — `electron-main.js:8-28, 73-99`

- `app.setName('robogears Downloader')` runs before any path is used. This puts `userData` in the same place in dev and packaged builds:
  - macOS: `~/Library/Application Support/robogears Downloader/`
  - Windows: `%APPDATA%\robogears Downloader\`
- Packaged builds set `process.env.TIDAL_TOKEN_PATH = <userData>/token.json`. Dev builds use `token.json` next to the source.
- App files in `userData`:
  - `settings.json`
  - `queue.json`
  - `token.json` (packaged builds)
  - `extension-token.txt`
  - `pending-tracklist.json` (only while a batch runs)
  - `chrome-extension/` (managed copy)
- **Window:**
  - size 980×740, minimum 720×540
  - `backgroundColor: '#0a0a0a'`, `title: 'robogears Downloader'`
  - `contextIsolation: true`, `nodeIntegration: false`, `sandbox: false`, `autoHideMenuBar: true`
  - `icon` is set only when not packaged

**9. Bundled FFmpeg location and startup probe** — `electron-main.js:529-546`; `tidal_download.js:25-36`

1. `fp = require('ffmpeg-static')`; `unpacked = fp.replace('app.asar', 'app.asar.unpacked')`.
2. Use the first that exists: `unpacked`, then `fp`, then the bare name `'ffmpeg'` (PATH lookup).
3. At launch (`app.whenReady`), `spawn(ffmpegPath, ['-version'], {stdio: 'ignore'})`.
4. Only a spawn `'error'` event is handled. It sends the activity-log line `⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.` A non-zero exit code is not checked.

#### Updater: main process

**10. `isNewerVersion(remote, current)`** — `electron-main.js:103-113` (also used for the extension bundle at `:786`)

1. For each input: `String(x).replace(/^v/, '').split('.').map(n => parseInt(n, 10) || 0)`.
2. For `i` from 0 to `max(len) - 1`: let `a = r[i] || 0` and `b = c[i] || 0`. If `a > b` return `true`; if `a < b` return `false`.
3. Return `false` (equal means not newer).

What this means in practice:
- Only a lowercase leading `v` is stripped.
- Missing segments count as 0, so `0.2` equals `0.2.0`.
- `parseInt` keeps leading digits only, so `v0.1.31-rc1` compares **equal** to `0.1.31`.
- A segment with no leading digit (`V0`, `beta`) becomes 0.

**11. `fetchLatestRelease()`** — `electron-main.js:115-139`

1. `https.request` with:
   - `hostname: 'api.github.com'`
   - `path: '/repos/robogears/robogearsDownloader/releases/latest'`
   - `method: 'GET'`
   - headers `User-Agent: robogears-downloader/<app.getVersion()>` and `Accept: application/vnd.github+json`
   - `timeout: 10_000` (a socket idle timeout, not a total deadline)
2. The body is collected as a string (`data += d`).
3. Outcomes:
   - On `end`, a status other than 200 resolves `null`.
   - Otherwise it resolves `JSON.parse(data)`; a parse error resolves `null`.
   - An `error` event resolves `null`.
   - A `timeout` event calls `req.destroy()` and resolves `null`.
4. It never rejects. It sends no auth, no ETag and follows no redirects.

GitHub's `/releases/latest` returns only the release marked Latest, never a draft or a pre-release.

**12. `getUpdateStatus()`** — `electron-main.js:145-162`

1. `release = await fetchLatestRelease()`.
2. If `!release || !release.tag_name`, return `{status: 'error', message: 'Could not reach GitHub'}`. This also covers a rate-limit 403, a 404 when there are no releases, and a timeout.
3. If `!isNewerVersion(release.tag_name, app.getVersion())`, return `{status: 'up-to-date', version: app.getVersion()}`.
4. `wantedSubstr` is `'mac-arm64.dmg'` on `darwin`, `'setup.exe'` on `win32`, otherwise `null`. `process.arch` is never checked.
5. `downloadUrl = release.html_url` (the release web page). If `wantedSubstr` is set, the **first** entry of `release.assets` with `a.name && a.name.includes(wantedSubstr)` that has a `browser_download_url` replaces it.
6. Return `{status: 'available', version: release.tag_name, downloadUrl, releaseUrl: release.html_url}`. `version` keeps the tag's `v`.

**13. Launch check, manual check, notification** — `electron-main.js:164-182, 489`

- `notifyIfAvailable(result)`: if `result.status === 'available'` and `mainWindow` exists and is not destroyed, send `update:available` with `{version, downloadUrl, releaseUrl}`.
- `checkForUpdatesAndNotify()` is `notifyIfAvailable(await getUpdateStatus())`. It is called once in `app.whenReady`:
  - after `createWindow()` and the library-scan kickoff
  - before `verifyFfmpegAvailable()`
  - wrapped in `.catch(() => {})`
  - with no delay, no wait for page load, no periodic re-check and no "skip this version".
- `ipcMain.handle('update:check')` gets the status, calls `notifyIfAvailable(result)`, then returns `result`. So a manual check **also** re-sends `update:available` to every renderer listener.

**14. `app:version` and `shell:open-external`** — `electron-main.js:184-188`

- `app:version` returns `app.getVersion()` (`0.1.30`).
- `shell:open-external(url)` calls `shell.openExternal(url)` only if `url` is a string matching `/^https?:\/\//`. It returns `undefined`.

**15. `canSelfInstall()` / IPC `update:can-self-install`** — `electron-main.js:194-201`

- Returns `false` if `!app.isPackaged`.
- Returns `true` on `win32` and on `darwin`; `false` otherwise.
- There is no "portable" check, despite the comment at `:191-193`.

**16. `downloadToFile(url, destPath, onProgress)`** — `electron-main.js:204-235`

1. `fetch(u, redirects = 0)` runs `https.request(u, {method: 'GET', headers: {'User-Agent': 'robogears-downloader/<version>'}})`.
2. If the status is in `[301, 302, 303, 307, 308]`, a `location` header exists and `redirects < 5`: call `res.resume()`, then `fetch(location, redirects + 1)`. `Location` is used as given (assumed to be an absolute https URL). GitHub asset URLs redirect to a signed CDN URL.
3. If the status is not 200: call `res.resume()` and reject with `Error('HTTP <status> for <u>')`. A sixth redirect ends up here too.
4. `total = parseInt(content-length || '0', 10) || 0`; `downloaded = 0`; `out = fs.createWriteStream(destPath)`.
5. On every `res` `data` chunk: `downloaded += chunk.length`, then `onProgress(downloaded, total)`. This is unthrottled.
6. Wiring:
   - `res.pipe(out)`.
   - `out` `finish` calls `out.close(resolve)`; `out` `error` rejects.
   - `res` `error` and `req` `error` both reject.
7. `req.setTimeout(60_000, …)` destroys the request with `Error('Download timed out')`. This is an idle timeout per request (each redirect hop gets its own).
8. There is no checksum, size check or signature check.

**17. `mountAndExtractMacDmg(dmgPath)`** — `electron-main.js:241-286`

1. Set up paths:
   - `ts = Date.now()`
   - `mountPoint = <os.tmpdir()>/robogears-mount-<ts>` (not created beforehand)
   - `stagingDir = <os.tmpdir()>/robogears-update-<ts>`, created with `mkdirSync(..., {recursive: true})`, errors ignored
2. `detach()` = `spawn('hdiutil', ['detach', '-quiet', mountPoint], {stdio: 'ignore'}).unref()` inside a `try`. It is fire-and-forget: not awaited, no `-force`, no `error` listener.
3. `attach = spawn('hdiutil', ['attach', '-nobrowse', '-quiet', '-mountpoint', mountPoint, dmgPath], {stdio: 'ignore'})`. An `error` event rejects. By default `hdiutil attach` verifies images that carry checksums and aborts on a bad checksum (per `man hdiutil`).
4. On attach `close` with a non-zero code, reject `Error('hdiutil attach exit <code>')` (no detach).
5. `appName = fs.readdirSync(mountPoint).find(n => n.endsWith('.app'))`.
   - If readdir throws: detach, then reject `Error('Could not read mounted DMG: <msg>')`.
   - If nothing is found: detach, then reject `Error('No .app bundle found inside the DMG')`.
6. `spawn('ditto', [<mount>/<appName>, <staging>/<appName>], {stdio: 'ignore'})`.
   - On `error`: detach, then reject.
   - On `close`: detach. A non-zero code rejects `Error('ditto exit <code>')`; otherwise resolve `<staging>/<appName>`.

**18. IPC `update:download(url)`** — `electron-main.js:288-312`

1. If `!canSelfInstall()`, return `{ok: false, error: 'Self-install not supported on this build'}`.
2. If `url` is not a string matching `/^https?:\/\//`, return `{ok: false, error: 'Invalid URL'}`. An `http://` URL passes this check, but `https.request` then throws inside the promise, which rejects as `Protocol "http:" not supported…`.
3. `destPath = <os.tmpdir()>/robogears-downloader-<Date.now()><ext>`, where `ext` is `.dmg` on darwin and `.exe` otherwise.
4. `await downloadToFile(...)`. Each progress callback sends `update:download-progress` `{downloaded, total}` while the window is alive.
5. Platform step:
   - **darwin:** `global._pendingUpdatePath = await mountAndExtractMacDmg(destPath)`, then `fs.unlinkSync(destPath)` (errors ignored).
   - **Otherwise:** `global._pendingUpdatePath = destPath`.
6. Return `{ok: true, path: global._pendingUpdatePath}`.
7. On any throw: unlink `destPath` (errors ignored) and return `{ok: false, error: e.message}`.

Any https URL from the renderer is accepted, not just GitHub's. There is no guard against two downloads at once; the last one to finish wins `_pendingUpdatePath`. The pending path is held only in memory: quitting without applying loses it, though the files stay in the temp folder.

**19. IPC `update:apply`, Windows branch** — `electron-main.js:314-336, 465-468`

1. If `!canSelfInstall()`, return the "not supported" error.
2. `newPath = global._pendingUpdatePath`. If it is missing or `!fs.existsSync(newPath)`, return `{ok: false, error: 'No downloaded update available'}`.
3. `spawn(newPath, ['/S', '--updated'], {detached: true, stdio: 'ignore', windowsHide: true})`, then `child.unref()`. There is no `error` listener.
4. `setTimeout(() => app.quit(), 500)`; return `{ok: true}`.

`/S` is NSIS's standard silent flag; `--updated` is a flag understood by electron-builder's installer template. Closing the running app, replacing files and any relaunch are all left to the installer. That template is not in this repo, so its behaviour is unverified here (see Open questions). The downloaded installer in `%TEMP%` is never deleted.

**20. IPC `update:apply`, macOS branch (Node side)** — `electron-main.js:337-460, 465-468`

1. Find the running bundle: `runningAppBundle = app.getPath('exe').replace(/\/Contents\/MacOS\/[^/]+$/, '')`.
2. Check for translocation: `isTranslocated = runningAppBundle.includes('/AppTranslocation/')`.
3. Pick the target. `targetAppBundle` is `path.join('/Applications', app.getName() + '.app')` (`/Applications/robogears Downloader.app`) if translocated; otherwise it is `runningAppBundle`. A user-renamed or user-moved bundle is therefore updated where it is, under its current name.
4. Set up paths:
   - `logDir = ~/Library/Logs/robogears Downloader`, created with `mkdirSync(..., {recursive: true})`, errors ignored
   - `ts = Date.now()`
   - `scriptPath = <os.tmpdir()>/robogears-update-<ts>.sh`
   - `logPath = <logDir>/update-<ts>.log`
   - `attemptLogPath = <logDir>/attempts.log`
5. **Before any spawn**, append to `attempts.log` (errors ignored):
   ```
   [<ISO-8601 time>] applyUpdate fired
     parent pid: <process.pid>
     app bundle: <targetAppBundle>
     new app:    <staged .app path>
     script:     <scriptPath>
     log:        <logPath>
   ```
6. `fs.writeFileSync(scriptPath, script)` and `fs.chmodSync(scriptPath, 0o755)`. Neither is wrapped in `try`, so a failure makes the IPC call reject. The four paths are pasted raw inside double quotes with no escaping.
7. `spawn('/bin/bash', [scriptPath, String(process.pid)], {detached: true, stdio: 'ignore'})`. On `error`, append `  SPAWN ERROR: <message>` to `attempts.log`. Then `unref()`.
8. `global._lastUpdateLogPath = logPath`. This is never read.
9. `setTimeout(() => app.quit(), 500)`; return `{ok: true}`.

On any other platform, the handler returns `{ok: false, error: 'Self-install not implemented for <platform>'}`. This is unreachable, because `canSelfInstall()` is false there.

**21. macOS relauncher script** — generated at `electron-main.js:385-441`

The exact text, with Node-side values shown as `<…>`:

```bash
#!/bin/bash
LOG="<logPath>"
# Stage 1: re-exec into a fully detached background subshell.
if [ "$1" != "--daemonized" ]; then
    nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 &
    disown
    exit 0
fi
shift  # drop --daemonized
exec >>"$LOG" 2>&1
set -x
echo "=== robogears update script started at $(date) ==="
trap "" HUP TERM  # belt and suspenders on top of nohup
PID=$1
NEW_APP="<staged .app>"
TARGET="<targetAppBundle>"
RUNNING_FROM="<runningAppBundle>"
TRANSLOCATED="<1|0>"
BACKUP="${TARGET}.bak"
echo "PID=$PID NEW=$NEW_APP TARGET=$TARGET RUNNING_FROM=$RUNNING_FROM TRANSLOCATED=$TRANSLOCATED"
echo "Waiting for parent process $PID to exit..."
for i in $(seq 1 30); do
    if ! ps -p $PID > /dev/null 2>&1; then echo "Parent gone after ${i}s"; break; fi
    sleep 1
done
xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true
# If something is already at TARGET, back it up first so we can roll back.
if [ -d "$TARGET" ]; then
    echo "Backing up existing $TARGET..."
    rm -rf "$BACKUP" 2>/dev/null
    if ! mv "$TARGET" "$BACKUP"; then
        echo "ERROR: could not back up existing TARGET (permission?). Aborting."
        rm -f "$0"
        exit 1
    fi
fi
echo "Moving NEW -> TARGET..."
if mv "$NEW_APP" "$TARGET"; then
    echo "Re-signing ad-hoc..."
    codesign --force --deep --sign - "$TARGET" 2>&1 || true
    echo "Removing backup..."
    rm -rf "$BACKUP" 2>/dev/null
    echo "Opening new app at $TARGET..."
    open "$TARGET"
    echo "Done."
else
    echo "ERROR: mv NEW->TARGET failed. Rolling back."
    if [ -d "$BACKUP" ] && [ ! -d "$TARGET" ]; then
        mv "$BACKUP" "$TARGET"
    fi
    [ -d "$TARGET" ] && open "$TARGET"
fi
echo "=== script finished at $(date) ==="
rm -f "$0"
```

How it runs:

- **Stage 1** (the bash process spawned by Node, argv `<script> <pid>`) re-executes the script file under `nohup` with `--daemonized <pid>`, backgrounds it, disowns it and exits at once. This keeps it alive after the app quits.
- **Stage 2** sends all output plus a `set -x` trace to `update-<ts>.log`.
- **Wait:** it polls the parent PID once a second for up to about 30 s. After that it **carries on even if the parent is still alive**.
- **Order of work:**
  1. Strip quarantine from the new app.
  2. Back up the target to `<target>.bak`. If that fails, abort without opening anything.
  3. Move the new app into place.
  4. Re-sign ad-hoc (a failure is ignored).
  5. Delete the backup.
  6. `open` the target.
- **If the move fails:** restore the backup when the target is missing, then open whatever is at the target.
- The script deletes itself on both the normal and the abort path.
- `RUNNING_FROM` and `TRANSLOCATED` are only logged.

#### Updater: renderer

**22. Preload bindings** — `electron-preload.js:11-23`

| `window.api` method | IPC |
|---|---|
| `openExternal(url)` | invoke `shell:open-external` |
| `onUpdateAvailable(cb)` | listen `update:available` |
| `checkForUpdates()` | invoke `update:check` |
| `getAppVersion()` | invoke `app:version` |
| `canSelfInstall()` | invoke `update:can-self-install` |
| `downloadUpdate(url)` | invoke `update:download` |
| `applyUpdate()` | invoke `update:apply` |
| `onUpdateDownloadProgress(cb)` | listen `update:download-progress` |

Listeners are never removed.

**23. Activity-log update notice** — `renderer/app.js:363-435, 1990-1994`; CSS `renderer/styles.css:370-421`

Registered with `api.onUpdateAvailable(insertUpdateNotice)` (`:435`). `insertUpdateNotice({version, downloadUrl})` works as follows:

1. If `welcomeLineEl` is null or detached, save `{version, downloadUrl}` in `pendingUpdate` and return. Boot replays it once, at the end of the boot routine after the queue restore (`:1990-1994`).
2. If the activity element already contains any `.update-notice`, return. This deduplicates without comparing versions.
3. Insert `div.log-line.update-notice` right after the welcome line. It holds:
   - a span with `innerHTML` `🚀 New version available: <strong>${version}</strong>`
   - a `button.update-download-btn` labelled `Download update`
4. `selfInstall = await api.canSelfInstall().catch(() => false)`. If false, each click calls `api.openExternal(downloadUrl)` and the function stops here.
5. State machine, starting at `idle`:
   - **`idle` + click:**
     1. State becomes `downloading`; the button is disabled and shows `Starting…`.
     2. `r = await api.downloadUpdate(downloadUrl)`.
     3. On failure: state `idle`, enabled, `Download failed — retry`.
     4. On success: state `ready`, enabled, class `ready`, `Restart to apply`.
   - **`ready` + click:** state `restarting`, disabled, `Restarting…`, then `api.applyUpdate()`. The result is not awaited or checked.
6. Progress listener (only while `downloading`):
   - if `total > 0`: `Downloading ${Math.floor(downloaded/total*100)}%`
   - otherwise: `Downloading ${(downloaded/1024/1024).toFixed(1)} MB`

Styling:
- The row is a flex row: `space-between`, gap 12, background `--bg-elev`, `--border-strong` border, `--r-md` radius, padding 8×12, margin 6px 0.
- The button has a white background, black text, padding 5×12, `--r-sm` radius, 12 px weight 600.
  - hover: opacity 0.85
  - active: opacity 0.7
  - disabled: opacity 0.55
  - `.ready`: white with `0 0 0 1px rgba(255,255,255,0.5)` ring

**24. Topbar "Update now" pill** — `renderer/app.js:13, 437-489`; `renderer/index.html:23`; `renderer/styles.css:87-117`

- `#brand-update-pill` starts `hidden`. State is one of `idle | available | downloading | restarting`.
- **On every `update:available`:** `_pillUpdateUrl = downloadUrl`; state `available`; shown; enabled; text `Update now`. There is no guard for an in-flight download.
- **Click:**
  1. Ignore the click unless the state is `available` and a URL is set.
  2. If `canSelfInstall()` is false, call `openExternal(url)` and stop.
  3. Otherwise: state `downloading`, disabled, `Downloading…`, then `r = await downloadUpdate(url)`.
  4. On failure: state `available`, enabled, `Retry update`.
  5. On success: state `restarting`, `Restarting…`, then `applyUpdate()` (result not checked). This is one click, with no second confirmation.
- **Progress text:** same as the notice.
- **CSS:**
  - background `--text` (white), text `--bg` (black), padding 4×10, radius `--r-pill` (999px)
  - 11 px, weight 700, letter-spacing 0.3, margin-left 8, tabular numbers, `-webkit-app-region: no-drag`
  - pulse while enabled: `brand-update-pulse 2.4s ease-in-out infinite`, a box-shadow going from `0 0 0 0 rgba(255,255,255,0.45)` to `0 0 0 6px rgba(255,255,255,0)` at 50%
  - hover background `#e5e5e5`
  - disabled: `--bg-elev` background, `--text-muted` text, no pulse

**25. Settings → Updates tab** — `renderer/index.html:188-197`; `renderer/app.js:1649-1673, 1952-1958`

- On boot, `getAppVersion()` sets `#brand-version` to `v<ver>` and `#update-status` to `Current version: v<ver>`. The placeholder before that is `Current version: …`.
- **`#check-updates-btn` click:**
  1. Disable the button and show `Checking…`.
  2. `r = await api.checkForUpdates()`.
  3. Show the result:
     - `available`: `${r.version} available!`
     - `up-to-date`: `Up to date ✓`
     - anything else, or an exception: `Check failed`
  4. After 2500 ms, re-enable the button and restore `Check for updates`.
- Hint text: "Checks GitHub for a newer release. If one's found, a download notice appears in the activity log." Signature: "made with love by robogears :)".
- Settings has four tabs: Folders, TIDAL, Extension, Updates.

#### Inventory only (extension, dropped in the port)

- `ensureExtensionBundle()` (`electron-main.js:775-802`, packaged builds only):
  - Copies the top-level files of `<resourcesPath>/chrome-extension` into `<userData>/chrome-extension`. It does this when the user copy is missing (version `0.0.0`) or the bundled `manifest.json` version is newer by `isNewerVersion`.
  - Logs `🧩 Chrome extension files updated to v<ver> at <dir>. Reload in chrome://extensions if it's already loaded.`
- `scripts/sync-extension-version.js`.
- The `extraResources` entry.
- The extension server's port, `8273` (`extension-server.js:17`).

---

### Data formats

**GitHub release JSON (only these fields are read)** — `electron-main.js:145-162`
```
{ tag_name: string,            // e.g. "v0.1.30"
  html_url: string,            // release web page
  assets: [ { name: string, browser_download_url: string } ] }
```
The release body text is never shown in the app.

**`getUpdateStatus()` result = `update:check` return value**
```
{ status: 'available', version: <tag_name, keeps "v">, downloadUrl, releaseUrl }
{ status: 'up-to-date', version: <app.getVersion(), no "v"> }
{ status: 'error', message: 'Could not reach GitHub' }
```

**IPC surface**

| Channel | Direction | Payload | Result |
|---|---|---|---|
| `update:check` | renderer → main (invoke) | none | status object above; also emits `update:available` when available |
| `app:version` | invoke | none | `"0.1.30"` |
| `shell:open-external` | invoke | `url` | `undefined`; opens only `http(s)://` |
| `update:can-self-install` | invoke | none | `boolean` |
| `update:download` | invoke | `url` | `{ok: true, path}` or `{ok: false, error}` |
| `update:apply` | invoke | none | `{ok: true}` or `{ok: false, error: 'Self-install not supported on this build' \| 'No downloaded update available' \| 'Self-install not implemented for <platform>'}`; rejects if writing the script fails |
| `update:available` | main → renderer event | `{version, downloadUrl, releaseUrl}` | sent at launch and on every manual check that finds an update |
| `update:download-progress` | main → renderer event | `{downloaded: bytes, total: bytes or 0}` | one per network chunk |

**Temp, staging and log paths**

| What | Path |
|---|---|
| Downloaded asset | `<os.tmpdir()>/robogears-downloader-<ms>.dmg` or `.exe` |
| DMG mount point | `<os.tmpdir()>/robogears-mount-<ms>` |
| Staged app | `<os.tmpdir()>/robogears-update-<ms>/<Name>.app` |
| Relauncher script | `<os.tmpdir()>/robogears-update-<ms>.sh` (the two `<ms>` values differ; each is the `Date.now()` of its own step) |
| Backup during swap | `<TARGET>.bak` |
| Script trace log | `~/Library/Logs/robogears Downloader/update-<ms>.log` |
| Breadcrumb log | `~/Library/Logs/robogears Downloader/attempts.log` (appended forever, never rotated) |

**Asset-name contract** (`package.json:78, 88`; `release.yml:25, 41, 60-61`; `electron-main.js:153-158`)

- Windows asset: `robogears-downloader-setup.exe`. Installed clients look for the substring `setup.exe`.
- macOS asset: `robogears-downloader-mac-arm64.dmg`. Installed clients look for `mac-arm64.dmg`. The DMG root must hold the `.app` (the first entry ending in `.app` is used) plus an `/Applications` symlink.

**`RELEASE_NOTES.md`** (current version only; `ship.md:31-62`; the current file is v0.1.30)
```
# What's new in vX.Y.Z
## <subsection>
- bullets
---
# Install
- **<Platform>**: …
## Requirements
- …
---
**Full Changelog**: https://github.com/robogears/robogearsDownloader/compare/vPREV...vCURR
```

---

### External interfaces

| Interface | Detail | Where |
|---|---|---|
| GitHub REST "latest release" | `GET https://api.github.com/repos/robogears/robogearsDownloader/releases/latest`. Headers: `User-Agent: robogears-downloader/<ver>`, `Accept: application/vnd.github+json`. Unauthenticated (60 requests/hour per IP). Only a 200 is accepted. | `electron-main.js:115-139` |
| GitHub asset download | `browser_download_url` → 3xx → CDN. Max 5 hops, 60 s idle timeout, User-Agent header only. | `electron-main.js:204-235` |
| `hdiutil` | `attach -nobrowse -quiet -mountpoint <mp> <dmg>` / `detach -quiet <mp>` | `electron-main.js:250-258` |
| `ditto` | `ditto <mp>/<App>.app <staging>/<App>.app` (keeps extended attributes) | `electron-main.js:277` |
| Relauncher tools | `/bin/bash`, `nohup`, `disown`, `ps -p`, `seq`, `sleep`, `xattr -dr com.apple.quarantine`, `mv`, `rm -rf`, `codesign --force --deep --sign -`, `open` | `electron-main.js:385-441` |
| NSIS installer | `<tmp>\robogears-downloader-<ms>.exe /S --updated`, detached, hidden | `electron-main.js:331-336` |
| `codesign` at build time | `codesign --force --deep --sign - "<appOutDir>/robogears Downloader.app"` | `build/after-pack.js:20` |
| GitHub Actions | `actions/checkout@v4`, `actions/setup-node@v4` (Node `'20'`, npm cache), `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `softprops/action-gh-release@v2`. Runners: `windows-latest`, `macos-latest`, `ubuntu-latest`. Default `GITHUB_TOKEN` with `contents: write`. | `.github/workflows/release.yml` |
| `gh` CLI (manual ship) | `gh run watch/rerun`, `gh release view --json body`, `gh release edit --notes-file` / `--draft=false` | `ship.md`, `updater.md:728-762` |
| `shell.openExternal` | Fallback update path (dev builds, Linux). http(s) only. | `electron-main.js:186-188` |

---

### Constants and magic values

| Name | Value | Where |
|---|---|---|
| Update API host / path | `api.github.com` / `/repos/robogears/robogearsDownloader/releases/latest` | `electron-main.js:118-119` |
| User-Agent | `robogears-downloader/<app.getVersion()>` | `:122`, `:208` |
| Accept | `application/vnd.github+json` | `:123` |
| Release-check timeout | `10_000` ms (socket idle) | `:125` |
| Download idle timeout | `60_000` ms per request | `:230` |
| Redirect codes / max hops | `[301, 302, 303, 307, 308]` / 5 | `:209` |
| Asset substrings | darwin `mac-arm64.dmg`; win32 `setup.exe` | `:153-155` |
| Quit delay after apply | 500 ms (both platforms) | `:467` |
| Parent-exit wait | 30 × `sleep 1` (about 30 s), then proceed regardless | `:407-410` |
| NSIS arguments | `['/S', '--updated']` | `:331` |
| Exe-to-bundle regex | `/\/Contents\/MacOS\/[^/]+$/` | `:345` |
| Translocation marker / fallback target | `/AppTranslocation/` / `/Applications/robogears Downloader.app` | `:346-349` |
| Log folder | `~/Library/Logs/robogears Downloader/` | `:354` |
| Script mode | `0o755` | `:443` |
| App name / userData folder | `robogears Downloader` | `electron-main.js:13`; `package.json:30` |
| Bundle ID | `com.robogears.downloader` | `package.json:29` |
| App version | `0.1.30` (`package-lock.json` root still says `1.0.0`) | `package.json:3`; `package-lock.json:3,9` |
| Artifact names | `robogears-downloader-setup.exe`; `robogears-downloader-mac-${arch}.${ext}` | `package.json:78, 88` |
| DMG window / icons | 540×400; icon size 100; app at (140,220); `/Applications` at (400,220); background 1920×1200 | `package.json:91-103` |
| Mac category | `public.app-category.music` | `package.json:84` |
| Manual-check label revert | 2500 ms | `renderer/app.js:1669-1672` |
| Pill pulse | `brand-update-pulse 2.4s ease-in-out infinite` | `renderer/styles.css:102-117` |
| Activity-log cap | 2000 lines (`ACTIVITY_LOG_MAX`) | `renderer/app.js:54` |
| CI Node | `'20'` | `release.yml:18, 34` |
| CI trigger | tags `v*` + `workflow_dispatch` | `release.yml:5-9` |
| Locked toolchain | electron 33.4.11, electron-builder 26.8.1 (app-builder-lib / dmg-builder 26.8.1), ffmpeg-static 5.3.0, music-metadata 7.14.0 | `package-lock.json` |

---

### Rules and invariants

- **Every CI release is a draft** (`release.yml:55`); the owner publishes it. Installed apps only ever see the release GitHub marks Latest, so drafts and pre-releases are invisible to them.
- **Asset-name contract.** The Windows asset name must contain `setup.exe` and the Mac asset name `mac-arm64.dmg`. The DMG must have the `.app` at its root. Renaming or reformatting an asset strands the previous version's updater. This has happened twice: zip → dmg at v0.1.16 → v0.1.17, and portable → NSIS at v0.1.23 → v0.1.24.
- **Version comparison** is numeric per dot segment after removing a leading lowercase `v`. Equal is not newer.
- **Self-install** happens only when the app is packaged and running on win32 or darwin. Otherwise the URL opens in the browser.
- **macOS install target** is the running bundle's path, unless that path contains `/AppTranslocation/`; then it is `/Applications/robogears Downloader.app`.
- **Relauncher order** is fixed:
  1. wait for the parent (at most about 30 s)
  2. strip quarantine
  3. back up the target to `.bak` (abort if that fails)
  4. move the new app in
  5. ad-hoc re-sign (failure ignored)
  6. delete the backup
  7. `open`
  If the move fails, restore the backup and open whatever is at the target.
- **The `attempts.log` breadcrumb** is written before the relauncher is spawned.
- **The relauncher must daemonize itself** with the `nohup "$0" --daemonized "$@" … & disown` re-exec. Plain `detached` + `unref` was not enough in earlier versions (CLAUDE.md "Don'ts").
- **Windows update** = run the NSIS installer with `/S --updated`, then quit. No manual file swapping.
- **Build settings that must stay:**
  - `publish: null`
  - `mac.identity: null` together with the afterPack ad-hoc `codesign`
  - `asarUnpack` for ffmpeg-static, plus the `app.asar` → `app.asar.unpacked` path rewrite
  - no `--win <target>` flag in npm scripts that CI calls
- **The `userData` folder name** is fixed by `app.setName('robogears Downloader')`, not by the bundle ID.
- **`RELEASE_NOTES.md`** holds only the current version, in a fixed four-part structure. The published body must be checked (and fixed) after every CI run.
- **No release work without an explicit instruction.** Never ship, bump, tag or push unless the owner says so. The owner's global versioning rule overrides `ship.md`'s "bump at ship time".

---

### Edge cases and failure modes

**Checking for updates**
- **GitHub problems:** unreachable, rate-limited (403), no releases (404), a non-JSON body, or 10 s of silence. The launch check stays silent; a manual check shows `Check failed`. The message is always `Could not reach GitHub`.
- **The latest release has no matching asset:** `downloadUrl` falls back to `html_url`, the HTML release page. In self-install mode, that page is downloaded as if it were the installer:
  - **macOS:** `hdiutil attach` fails, and the UI shows `Download failed — retry` or `Retry update`.
  - **Windows:** the HTML is saved as `.exe` and "succeeds". On apply, spawning it fails with no listener, and the app quits 500 ms later without updating. See Bugs.
- **Pre-release-style tags:** `v0.1.31-rc1` compares equal to `0.1.31`. `/latest` only returns it if it was published as a full release.

**Downloading**
- **No `Content-Length`:** progress shows `Downloading N.N MB` instead of a percentage.
- **Too many redirects:** more than 5 rejects with `HTTP 30x for <url>`. A relative or `http://` `Location` makes `https.request` throw inside the response callback. That is an uncaught exception in the main process, and the download promise never settles, so the UI stays on "Downloading…".
- **A stall of more than 60 s:** rejects with `Download timed out`. The partial file is unlinked. On Windows that may fail while the write stream is still open; the error is ignored.
- **DMG problems:**
  - corrupt image: `hdiutil attach exit <code>` (hdiutil verifies checksums by default)
  - no `.app` at the root: `No .app bundle found inside the DMG`
  - copy failure: `ditto exit <code>`, which leaves a partial staging folder
- **Dev builds:** `canSelfInstall` is false, so both UIs open `downloadUrl` (the asset URL itself) in the browser.

**Applying on macOS**
- **Translocated run** (the app was opened from a quarantined location such as ~/Downloads): the update installs to `/Applications`. The original copy is left untouched and stays old.
- **Standard (non-admin) user, or a read-only location** (for example, running straight from a non-quarantined mounted DMG):
  - If the target already exists, the backup move fails. The script logs an error and exits without reopening anything, so the user is left with no running app. The old bundle is intact.
  - If the target does not exist (translocated and no `/Applications` write access), the move fails and nothing is opened.
- **The parent is still alive after 30 s:** the script still swaps the bundle out from under the running process and opens the new one.
- **The script cannot be written** (temp disk full, etc.): `writeFileSync` throws, the `update:apply` invoke rejects, nothing quits, and both UIs stay on `Restarting…`.
- **The pending file is gone** (`_pendingUpdatePath` missing or deleted): apply returns `No downloaded update available`. Both UIs ignore this and stay on `Restarting…`.

**Renderer UI**
- **Both UIs clicked:** two downloads run at once to different temp files. The last to finish sets `_pendingUpdatePath`. Progress events update whichever UI is in `downloading`.
- **Manual "Check for updates" while the pill is downloading:**
  - `update:available` resets the pill to `available` / `Update now`, enabled. Progress stops showing on it.
  - The first download still finishes and applies the update.
  - Clicking the pill again in the meantime starts a second download.
- **A newer release appears mid-session:** a manual check updates the pill's URL. The existing notice keeps its old URL, because it deduplicates on its existence alone.
- **The activity log is cleared** (`activityEl.innerHTML = ''`): the welcome line is detached, and later `update:available` events are parked in `pendingUpdate`. That is only replayed at boot, so no notice appears again this session. The pill still works.
- **The activity log passes 2000 lines:** once the welcome line is the first child, trimming removes the element right after it, which is the update notice.
- **macOS window closed and reopened from the Dock** (`activate` → `createWindow()`): the new renderer starts fresh, so the pill is hidden and there is no notice. The launch-time event is not re-sent. Only a manual check brings the update UI back.
- **Quit without applying:** the pending path is lost (it is held in memory only), and the next session downloads again.

**Packaging and CI**
- **Update applied while a download batch is running:** nothing in the UI or main process prevents it. `app.quit()` does not emit `window-all-closed` (Electron's documented behaviour), and there is no `before-quit` / `will-quit` handler, so the `bulk_runner` child is never explicitly killed. It is orphaned with broken stdout pipes. On macOS the child may be running from inside the bundle that the script moves to `.bak` and deletes. What happens to the in-flight download is unverified (needs a run).
- **`workflow_dispatch` from a branch:** `github.ref_name` is the branch name, so the draft release and its tag would be named, for example, `main`.

---

### Bugs and oddities

**Low**

1. **The release job never checks out the repo, so `body_path: RELEASE_NOTES.md` points at a missing file.** Low (cosmetic, but it costs a manual fix every release).
   - Evidence: `.github/workflows/release.yml:44-58`. The job's only steps are `download-artifact` and `softprops`.
   - This is consistent with the documented "empty body on every release" (`CLAUDE.md:698`, `ship.md:94-106,127`), which the docs blame on softprops. Draft releases do get created with their assets, so softprops evidently tolerates the missing file rather than failing; the exact behaviour of the resolved v2.x is unverified (needs a run).
   - Fix: add `actions/checkout@v4` before softprops, or use `gh release create --notes-file`.

2. **If the latest release has no asset for the user's platform, the release web page is downloaded and "installed".** Low today. It becomes a real problem for every Windows user the moment a release without a `setup.exe` asset is published as Latest, which is exactly what a macOS-only Swift release would be.
   - Evidence: `electron-main.js:156-160` (fallback to `html_url`), `:288-312` (no content check), `:331-336` (spawn with no `error` listener), `:467` (quit regardless).
   - On Windows the HTML is saved as `.exe` and spawned. Spawning fails, which is an uncaught `error` event in the main process, and the app quits 500 ms later without updating. The pill reappears on the next launch, so this repeats.

3. **A manual update check resets the topbar pill mid-download.** Low.
   - Evidence: `renderer/app.js:444-450` sets `available` / `Update now` / enabled with no state guard; `electron-main.js:178-182` re-sends `update:available` on every manual check.
   - Progress stops showing, and a second click starts a parallel download.

4. **Both UIs ignore `applyUpdate()`'s result and any rejection.** Low.
   - Evidence: `renderer/app.js:420`, `:476`; `electron-main.js:442-443` (the script write is not in a `try`).
   - On `{ok:false}` or a rejection, the button or pill stays on `Restarting…` forever with no error shown.

5. **The Windows installer spawn has no `error` listener.** Low.
   - Evidence: `electron-main.js:331-336`, compared with the macOS branch at `:452-458`.
   - A spawn failure (file missing, blocked by antivirus, not a real executable) becomes an uncaught exception in the main process; the app still schedules its quit.

6. **The relauncher proceeds after about 30 s even if the parent is still running.** Low.
   - Evidence: `electron-main.js:407-410`. The loop just ends; there is no abort.
   - Minor: the log line `Parent gone after ${i}s` reports `1s` when the first check, before any sleep, already finds the parent gone.

7. **If the backup move fails, the user is left with no running app.** Low.
   - Evidence: `electron-main.js:416-420` exits 1 without `open`, after the app has already quit.
   - Typical causes are a standard (non-admin) user with the app in `/Applications`, or a read-only location.

8. **Paths are pasted into the bash script without escaping.** Low.
   - Evidence: `electron-main.js:387, 400-403`.
   - A path containing `"`, `$` or a backtick (for example, a user-chosen install folder) breaks or changes the script. Spaces are fine.

9. **No authenticity check on the downloaded update.** Low.
   - Evidence: `electron-main.js:204-235, 288-312, 385-441`.
   - There is no hash, signature, bundle-ID or version check before the swap. `update:download` accepts any `https?://` URL the renderer passes.
   - The only integrity check is that `hdiutil attach` verifies the DMG's internal checksums by default, which catches corruption but not tampering.

10. **No concurrency guard, and temp files leak.** Low.
    - Evidence: `electron-main.js:243-246, 288-312, 361`.
    - `_pendingUpdatePath` is last-writer-wins.
    - Never cleaned up: staging folders `robogears-update-<ms>` (empty after a successful move, partial after a `ditto` failure), the Windows installer in `%TEMP%`, and `attempts.log`, which grows forever.
    - Whether the mount-point folders are removed on detach is unverified.

11. **`workflow_dispatch` can create a draft release named after a branch.** Low. Evidence: `.github/workflows/release.yml:9, 56-57`.

**Info**

12. **`hdiutil detach` is fire-and-forget.** Info.
    - Evidence: `electron-main.js:250-254`. It is not awaited, has no `-force` and no `error` listener (the `try/catch` cannot catch async spawn errors).
    - A busy volume stays mounted silently. The DMG is unlinked while the detach may still be running; this is harmless on macOS.

13. **The progress IPC is unthrottled.** Info. Evidence: `electron-main.js:220-223, 294-298`. One message is sent per socket chunk (thousands for an asset of about 90 MB), and both renderer listeners rewrite their text each time.

14. **Possible launch race.** Info.
    - Evidence: `electron-main.js:476, 489`; `renderer/app.js:435, 444`; `renderer/index.html:233`.
    - The check starts right after `loadFile()` without waiting for `did-finish-load`. `pendingUpdate` covers "listener registered, welcome line not yet created", but not "event arrives before `app.js` has registered its listeners". The comment at `:487-488` overstates the coverage. Whether events are lost in practice is unverified (needs a run).

15. **Version-compare quirks.** Info. Evidence: `electron-main.js:103-113`. `v0.1.31-rc1` equals `0.1.31`; an uppercase `V0.2.0` parses its first segment as 0.

16. **`fetchLatestRelease` mislabels failures and does not follow redirects.** Info.
    - Evidence: `electron-main.js:126-136, 147-148`.
    - Rate limits (403) and "no releases" (404) are reported as `Could not reach GitHub`. A 301 (repo renamed or transferred) counts as a failure.
    - Chunks are joined as strings, so a multi-byte character split across chunks becomes U+FFFD. This is harmless, because the release body is unused.

17. **The remote tag is inserted with `innerHTML`.** Info. Evidence: `renderer/app.js:382`. The tag comes from the owner's own repo, so the risk is low.

18. **Dead updater state.** Info. Evidence: `electron-main.js:460`, `:402-403`. `global._lastUpdateLogPath` is never read; `RUNNING_FROM` and `TRANSLOCATED` are only logged.

19. **Stale comments and text.** Info.
    - Portable-era comments: `electron-main.js:190-193` (`PORTABLE_EXECUTABLE_FILE`, "non-portable Windows … release page"), `electron-preload.js:18-19` ("Windows portable only"), `renderer/app.js:390-391` ("macOS … just open the release page").
    - `build/after-pack.js:4-5` still says "right-click → Open".
    - "Screenshot OCR" leftovers: `package.json:4` (description), `renderer/app.js:2`, `electron-main.js:984`. `electron-main.js:994` refers to a "single-track spawn above" that no longer exists.
    - `package-lock.json` root version is `1.0.0`.
    - Extension self-update code is referenced but absent: `electron-main.js:504-505, 761-763` (`onUpdateSelf`, `handleExtensionUpdateSelf`) and the Settings hint at `renderer/index.html:185`.

20. **CI toolchain age.** Info.
    - Evidence: `release.yml:15-18, 31-34, 50-53`.
    - The build uses Node `'20'`, which reached end-of-life in April 2026. All actions are Node-20-based v4/v2 releases, and `CLAUDE.md` notes GitHub's Node 20 deprecation (2 June 2026) and removal (16 September 2026).
    - Whether CI still runs today is unverified (needs a run).

21. **The bundled FFmpeg's architecture follows the CI runner, not the target.** Info.
    - Evidence: `release.yml:28-37`; `package.json:11, 57-59`.
    - ffmpeg-static's postinstall during `npm ci` downloads the binary for the runner's arch; `--arm64` only affects Electron. This is correct only while `macos-latest` is an Apple Silicon image.

22. **`extraResources` bypasses the `files` exclusions.** Info. Evidence: `package.json:50, 60-65`. `chrome-extension/README.md` and the rest of the folder ship in Resources.

23. **`start_app.command` has no executable bit in this copy.** Info. This folder is not a git checkout, so the mode tracked in the repo is unknown.

24. **The docs disagree with the code.** Info.
    - **`CLAUDE.md`:**
      - says v0.1.25; the code is 0.1.30
      - says CI builds a "mac arm64 .zip" (`:145`); it builds a DMG
      - shows a 200 ms quit (`:496, :504`); the code uses 500 ms
      - claims silent NSIS relaunches via `runAfterFinish` (see Open questions)
      - omits `extension-server.js`, `chrome-extension/` and `scripts/`
      - uses Windows paths (`Z:\`, the WinGet `gh` path)
    - **`ship.md:21-23`** bumps the version at ship time, which conflicts with the owner's rule.
    - **`updater.md`:**
      - matches `'.exe'` on Windows (`:125-127`); the code matches `'setup.exe'`
      - describes the portable `PORTABLE_EXECUTABLE_FILE` gate and the `.cmd` swap (`:15-17, 305-357, 784`)
      - uses temp names `app-mount-` / `app-update-`
      - shows a different `attempts.log` layout (`:498`)
      - uses a `< 50`-character body threshold (`:745`)

---

### Platform-specific behaviour

- **macOS packaging:**
  - arm64-only DMG
  - ad-hoc `codesign` at build time (afterPack) and again on the user's machine after every self-update
  - no notarization, hardened runtime or entitlements
  - first launch needs System Settings → Privacy & Security → Open Anyway (the DMG footer says so)
  - Apple Silicon implies macOS 11 or later
- **macOS self-update:**
  - `hdiutil` + `ditto` staging
  - translocation detected by path substring, with `/Applications` as the target when translocated
  - quarantine strip, double-forked bash relauncher
  - logs in `~/Library/Logs/robogears Downloader/`
  - standard users generally cannot update an app in `/Applications`
- **macOS app lifecycle:**
  - closing the last window does not quit (`window-all-closed` returns early on darwin, `electron-main.js:548-551`)
  - `activate` recreates the window (`:524-526`)
  - there is no custom menu (`Menu` is never imported), so Electron's default macOS menu applies
- **Windows:**
  - unsigned x64 NSIS one-click per-user installer, with desktop and Start Menu shortcuts
  - `runAfterFinish`; user data is kept on uninstall
  - self-update runs the installer with `/S --updated`
  - first run shows SmartScreen's "More info → Run anyway"
  - dev launcher `start_app.bat`
- **Linux:** no build target. `canSelfInstall` is false; the update URL opens in the browser.
- **userData:** `~/Library/Application Support/robogears Downloader/` on macOS, `%APPDATA%\robogears Downloader\` on Windows.
- **Asset selection** looks only at `process.platform`. The arch is assumed to be arm64 on macOS and x64 on Windows.

---

### Porting notes for a native Swift macOS app

| Topic | Today | Swift equivalent | Effort |
|---|---|---|---|
| Release discovery | Node https GET of `/releases/latest` with User-Agent and Accept headers, 10 s timeout, silent `null` on any failure | `URLSession` with the same headers; `Codable` for `tag_name`, `html_url`, `assets[].name`, `browser_download_url`; a three-state status enum (available / up to date / failed). Consider an `ETag` / `If-None-Match` cache and telling "rate-limited" apart from "offline". | easy |
| Version compare | `isNewerVersion` (above) | A pure function with the same rules (or real semver with pre-release ordering, if the owner wants it), compared against `CFBundleShortVersionString` | easy |
| Download + progress | Manual 3xx following, stream to temp, one IPC per chunk | `URLSessionDownloadTask` (follows redirects itself) with progress from the delegate or `Progress`; move the file out of URLSession's temp location before returning; throttle UI updates. Refuse any asset whose name does not match, and never fall back to downloading the HTML page. | easy |
| Integrity | None (only hdiutil's checksum check) | Verify a SHA-256 (published with the release) before staging; after staging, check the bundle ID and `CFBundleShortVersionString` of the new app | easy |
| DMG staging | `hdiutil attach -nobrowse -quiet -mountpoint`, first `*.app`, `ditto`, detach without waiting | `Process` running `/usr/bin/hdiutil` and `/usr/bin/ditto`; await the detach. There is no public framework API for mounting a DMG. Alternative: also ship a `.zip` and use `ditto -x -k`. | medium |
| Swap + relaunch | Generated bash script, `nohup` re-exec + `disown`, wait for the PID, `.bak` rollback, `xattr`, `codesign`, `open` | Same steps from a small script or helper launched with `Process` (the `nohup`/`disown` re-exec still works). Pass paths as **arguments**, not pasted into the script. Then `NSApp.terminate(nil)`. Abort (do not swap) if the parent has not exited; always reopen *something* on failure. | medium |
| Running bundle / translocation | `app.getPath('exe')` minus `/Contents/MacOS/<exe>`; substring `/AppTranslocation/` | `Bundle.main.bundleURL`; the same substring check (the `SecTranslocate*` functions are private SPI). Offer "Move to Applications" on first run. | easy |
| Build-time signing | electron-builder afterPack `codesign --deep --sign -` | Xcode "Sign to Run Locally" (`CODE_SIGN_IDENTITY=-`). The bundled FFmpeg (if kept) must sit in `Contents/MacOS` or `Contents/Helpers` and be signed as nested code. | easy |
| Signing identity and privacy prompts | Ad-hoc, re-signed on every update | An ad-hoc signature's only identity is its code hash. This is general macOS behaviour, not something seen in this repo: privacy (TCC) grants such as Files & Folders access, and Keychain access rules, are tied to that identity, so they may be asked again after every update. A stable certificate avoids this. Decide before choosing Keychain for the TIDAL token. | medium |
| DMG creation | electron-builder `dmg`: 540×400, background 1920×1200, icons at (140,220) and (400,220), size 100, title `Install robogears Downloader` | `hdiutil create` plus a scripted Finder layout, or `create-dmg` / `dmgbuild` in CI. Reuse the background; add a 2x version (multi-resolution TIFF) for Retina. | medium |
| App icon | `build/icon.png`, full-bleed rounded square, converted by electron-builder | An asset catalog `AppIcon` re-laid on Apple's macOS icon grid, since the current art has no margin and its own 180 px corners | easy |
| CI | Three jobs (Windows, Mac, release), Node 20, softprops with a `body_path` that is never checked out | One macOS job: checkout → `xcodebuild archive/export` (ad-hoc) → DMG → `gh release create vX.Y.Z --draft --notes-file RELEASE_NOTES.md <assets>` (or softprops **after** a checkout). Keep the draft-only rule and the asset-name contract. | medium |
| Update UI | Two independent renderer state machines that can race | One `@Observable` updater model that owns a single download. Show it in the app menu (**Check for Updates…**), a quiet toolbar or status indicator, and Settings → Updates. Block **Restart to Update** while a batch is downloading, or ask first. | easy |
| Version source | `package.json` (+ extension manifest + release-notes heading) | `MARKETING_VERSION` / `CFBundleShortVersionString` + `RELEASE_NOTES.md` + git tag, updated together under the owner's versioning rule | easy |
| Alternative | Hand-rolled updater | Sparkle 2 (an EdDSA-signed appcast, works without a Developer ID) replaces the relauncher and adds integrity checks, but needs an appcast feed produced in CI | medium |

**Moving existing Electron users to the Swift app (what v0.1.30 clients will do)**

- **What a v0.1.30 macOS client will install.** It will self-install the Swift app if all of these hold:
  - The release is **published and marked Latest**. Drafts and pre-releases are invisible to it.
  - Its tag is numerically greater than `0.1.30`. A leading `v` is optional for the updater; the CI trigger needs it.
  - It has an asset whose name contains `mac-arm64.dmg`.
  - That DMG has the Swift `.app` at its root (the first entry ending in `.app` wins) and mounts with no licence prompt.
- **How it installs it.** The old relauncher places the new bundle at the **old bundle's path and name** (the running path, or `/Applications/robogears Downloader.app` if translocated), whatever the new bundle is called. It strips quarantine, re-signs it ad-hoc with `--deep`, which would discard any Developer ID signature, and `open`s it.
- **Data the Swift app should read.** The data lives in `~/Library/Application Support/robogears Downloader/`:
  - `settings.json`, `queue.json` and `token.json` (packaged builds)
  - `extension-token.txt`, `chrome-extension/`: extension leftovers to ignore or clean up
  
  A sandboxed Swift app could not read this folder without a user grant. That is a reason to keep the app unsandboxed, or to add a one-time import.
- **Windows hazard.** A macOS-only Latest release has no `setup.exe` asset. Every Windows v0.1.30 client would then download the release HTML page as an `.exe`, fail to run it and quit (bug 2). Options:
  1. Ship a last Electron release that opens the release page instead of self-installing when no asset matches. This is the documented "patch the old version first" strategy.
  2. Keep a final Windows installer attached to the Swift releases.
  3. Accept it and tell Windows users.

---

### Open questions

1. **Windows relaunch after a silent update.** Does electron-builder's one-click NSIS installer relaunch the app when run with `/S --updated` but without `--force-run`? `CLAUDE.md` says `runAfterFinish` handles it. From memory of electron-builder's template (not checked here, because `node_modules` is absent), the auto-launch after a silent install is gated on `--force-run`, which electron-updater passes for this reason. If so, Windows updates install but do not relaunch. Unverified (needs a run).
2. **softprops and the missing notes file.** With `softprops/action-gh-release@v2` and a missing `body_path` file, does the step warn and continue with an empty body (what the docs observe) or fail? Which v2.x does the tag resolve to today? Adding a checkout step is the likely fix; it needs a CI run to confirm.
3. **CI health.** Is CI still green after GitHub's Node 20 action deprecation and removal dates, with `node-version: '20'` and the v4 actions?
4. **Runner architecture.** Is `macos-latest` still an arm64 image? The bundled FFmpeg's architecture depends on it.
5. **Signing redundancy.** With `mac.identity: null`, does electron-builder 26.8.1 add any signature of its own, or is the afterPack ad-hoc signature the only one?
6. **hdiutil and quarantine details.** Does `hdiutil detach` remove the `-mountpoint` folder it used? Does a DMG downloaded by Node's `https` carry `com.apple.quarantine`? The script strips it either way.
7. **Launch race.** Can the launch-time `update:available` be lost when GitHub answers before `app.js` has registered its listeners?
8. **Orphaned downloads.** What happens to an in-flight `bulk_runner` / `tidal_download` child when an update is applied mid-batch (orphaned, broken pipes, bundle moved away)?
9. **Swift migration path.** Should the first Swift release be delivered through the v0.1.30 updater (keep `mac-arm64.dmg`, a numeric tag above 0.1.30, the `.app` at the DMG root, and the same data folder), or will users install it by hand once? And what is the plan for Windows users (see the Windows hazard above)?
10. **Identity.** Keep the bundle ID `com.robogears.downloader` and the name `robogears Downloader` in the Swift app? They decide the `/Applications` target name used by the old updater, the data folder and the preferences domain.
11. **Signing.** Stay ad-hoc (privacy prompts possibly repeated after every update), use a free self-signed or development certificate for a stable identity, or pay for a Developer ID with notarization?
12. **Updater design.** Hand-rolled GitHub updater (with an added SHA-256 check and proper pre-release handling) or Sparkle 2?
