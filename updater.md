# Building an in-app updater for an Electron app

End-to-end guide to wiring up automatic update checks, in-app downloads, and self-install — *without* paying for code signing/notarization on either platform. Works for Windows portable `.exe` builds and macOS `.dmg`-distributed `.app` bundles. No reliance on `electron-updater` (which wants a fixed-install pattern and signing).

This is the architecture, not a library. You'll inline ~300 lines into your main process, ~50 into the renderer, plus a build-config tweak. The reward: users see "Download update → Restart to apply" in the app and never have to manually re-download anything again.

---

## What you get

| Feature | UX |
|---|---|
| Update detection | On every launch, app silently checks the project's GitHub Releases API. If a newer published release exists, a notice appears in the app with a **Download update** button. Silent on failure (no network, GitHub rate-limit). |
| Manual check | A **Check for updates** button in Settings runs the same check on demand. Button state reflects result: *Checking…* → *vX.Y.Z available!* / *Up to date ✓* / *Check failed* (auto-reverts after a couple seconds). |
| Self-install on Windows portable | Click **Download update** → live percentage in the button → **Restart to apply** → app swaps the `.exe` and relaunches itself. |
| Self-install on macOS | Same flow but downloads a `.dmg`, mounts it, copies the `.app` to `/Applications/`, strips quarantine, re-signs ad-hoc, and `open`s the new app. |
| Graceful fallback | Dev mode + non-portable Windows + Linux fall back to opening the release page in the user's default browser. |

---

## Architecture at a glance

```
┌─ Renderer (your existing UI) ──────────────────────────┐
│   onUpdateAvailable(cb) → insert a notice              │
│   onUpdateDownloadProgress(cb) → update button label   │
│   canSelfInstall() → branch between self-install /     │
│       openExternal flow                                │
│   downloadUpdate(url) → returns ok/error               │
│   applyUpdate() → triggers swap-and-relaunch           │
└────────────────────────────────────────────────────────┘
                         ↑ ↓ IPC
┌─ Main process ─────────────────────────────────────────┐
│   On app.whenReady:                                    │
│     fetch GitHub /releases/latest → compare → notify   │
│   IPC handlers:                                        │
│     update:check, update:can-self-install,             │
│     update:download (HTTPS stream → temp file +        │
│       per-platform extraction),                        │
│     update:apply (write detached script → app.quit)    │
└────────────────────────────────────────────────────────┘
                         ↓ spawn detached
┌─ Relauncher scripts (after app.quit) ──────────────────┐
│   Windows:  .cmd polls for file-lock release, mv,      │
│             start, self-delete                         │
│   macOS:    bash double-forks, waits for PID, strips   │
│             quarantine, mv into /Applications/,        │
│             codesign, open, self-delete                │
└────────────────────────────────────────────────────────┘
```

The relauncher scripts are the **critical** piece. They survive the parent process's death and do the actual file swap when the app can no longer hold any locks on itself.

---

## Component 1: Update detection (the launch check)

### Picking the latest release

The unauthenticated GitHub Releases API endpoint is fine for this. It's rate-limited (60 requests/hr per IP, plenty for app-launch polls). Critically, **`/releases/latest` only returns the highest *published* release** — drafts and pre-releases are invisible. That's usually what you want.

```js
// In your main process:
const https = require('https');
const { app } = require('electron');

function fetchLatestRelease() {
    return new Promise((resolve) => {
        const req = https.request({
            hostname: 'api.github.com',
            path: '/repos/<OWNER>/<REPO>/releases/latest',
            method: 'GET',
            headers: {
                'User-Agent': `<your-app>/${app.getVersion()}`,
                'Accept': 'application/vnd.github+json',
            },
            timeout: 10_000,
        }, (res) => {
            let data = '';
            res.on('data', d => data += d);
            res.on('end', () => {
                if (res.statusCode !== 200) return resolve(null);
                try { resolve(JSON.parse(data)); } catch { resolve(null); }
            });
        });
        req.on('error', () => resolve(null));
        req.on('timeout', () => { req.destroy(); resolve(null); });
        req.end();
    });
}
```

### Version comparison

Don't use string comparison — `'0.1.10'` < `'0.1.2'` lexicographically. Strip the `v` prefix and compare numeric segments:

```js
function isNewerVersion(remote, current) {
    const r = String(remote).replace(/^v/, '').split('.').map(n => parseInt(n, 10) || 0);
    const c = String(current).replace(/^v/, '').split('.').map(n => parseInt(n, 10) || 0);
    const len = Math.max(r.length, c.length);
    for (let i = 0; i < len; i++) {
        const a = r[i] || 0, b = c[i] || 0;
        if (a > b) return true;
        if (a < b) return false;
    }
    return false;
}
```

### Platform-specific asset detection

A GitHub release usually has multiple artifacts (Windows .exe, macOS .dmg, source archive, etc.). Pick the one that matches the current platform:

```js
async function getUpdateStatus() {
    const release = await fetchLatestRelease();
    if (!release || !release.tag_name) {
        return { status: 'error', message: 'Could not reach GitHub' };
    }
    if (!isNewerVersion(release.tag_name, app.getVersion())) {
        return { status: 'up-to-date', version: app.getVersion() };
    }
    // Match by substring — your asset names go here
    const wantedSubstr = process.platform === 'darwin' ? 'mac-arm64.dmg'
                       : process.platform === 'win32'  ? '.exe'
                       : null;
    let downloadUrl = release.html_url;  // fallback: open the release page
    if (wantedSubstr) {
        const asset = (release.assets || []).find(a => a.name && a.name.includes(wantedSubstr));
        if (asset && asset.browser_download_url) downloadUrl = asset.browser_download_url;
    }
    return {
        status: 'available',
        version: release.tag_name,
        downloadUrl,
        releaseUrl: release.html_url,
    };
}
```

Trigger it once on launch (silently — no UI noise on no-update / failure) and expose it as an IPC handler for the manual Settings button.

---

## Component 2: Surfacing the notice

The notice goes in whatever your app's "always-visible" surface is (activity log, header bar, status area). Don't use a modal — it's intrusive.

Two important UX details:

1. **Handle the race.** The main process might send the `update:available` event before the renderer's boot code has finished. Queue the payload if you haven't rendered the surface yet, and apply it once you have.
2. **De-duplicate.** If your app fires both an auto-check AND a manual check that hit the same available version, you want only one notice. Check the DOM before inserting.

```js
// In the renderer:
let surfaceReady = false;
let pendingUpdate = null;

api.onUpdateAvailable((payload) => {
    if (!surfaceReady) { pendingUpdate = payload; return; }
    if (document.querySelector('.update-notice')) return; // already showing
    insertUpdateNotice(payload);
});

// In your boot routine, after the surface is in place:
surfaceReady = true;
if (pendingUpdate) { insertUpdateNotice(pendingUpdate); pendingUpdate = null; }
```

The notice itself can be as simple as a flex row with a label ("New version available: vX.Y.Z") and a button that drives the state machine documented below.

---

## Component 3: The self-install button state machine

```
idle  ─[click]→  downloading (with %)  ─[done]→  ready  ─[click]→  restarting
  ↑                      │                                              │
  └── download-failed ───┘                                              │
                                                                        ↓
                                                            app.quit() + spawned script
```

Implementation:

```js
let state = 'idle';
const btn = /* your button element */;

btn.addEventListener('click', async () => {
    if (state === 'idle') {
        state = 'downloading';
        btn.disabled = true;
        btn.textContent = 'Starting…';
        const r = await api.downloadUpdate(downloadUrl);
        if (!r || !r.ok) {
            state = 'idle';
            btn.disabled = false;
            btn.textContent = 'Download failed — retry';
            return;
        }
        state = 'ready';
        btn.disabled = false;
        btn.classList.add('ready');  // highlight style
        btn.textContent = 'Restart to apply';
    } else if (state === 'ready') {
        state = 'restarting';
        btn.disabled = true;
        btn.textContent = 'Restarting…';
        api.applyUpdate();
    }
});

api.onUpdateDownloadProgress(({ downloaded, total }) => {
    if (state !== 'downloading') return;
    if (total > 0) {
        const pct = Math.floor((downloaded / total) * 100);
        btn.textContent = `Downloading ${pct}%`;
    } else {
        btn.textContent = `Downloading ${(downloaded / 1024 / 1024).toFixed(1)} MB`;
    }
});
```

If `canSelfInstall()` returns false, skip the state machine entirely and just open the release page:

```js
const selfInstall = await api.canSelfInstall().catch(() => false);
if (!selfInstall) {
    btn.addEventListener('click', () => api.openExternal(downloadUrl));
    return;
}
```

---

## Component 4: The download (streaming + progress)

Don't buffer the file in memory — stream it to disk and emit byte progress as chunks arrive. Mind redirects (GitHub release assets redirect to S3).

```js
function downloadToFile(url, destPath, onProgress) {
    return new Promise((resolve, reject) => {
        const fetch = (u, redirects = 0) => {
            const req = https.request(u, { method: 'GET', headers: { 'User-Agent': `<your-app>/${app.getVersion()}` } }, (res) => {
                if ([301, 302, 303, 307, 308].includes(res.statusCode) && res.headers.location && redirects < 5) {
                    res.resume();
                    return fetch(res.headers.location, redirects + 1);
                }
                if (res.statusCode !== 200) {
                    res.resume();
                    return reject(new Error(`HTTP ${res.statusCode} for ${u}`));
                }
                const total = parseInt(res.headers['content-length'] || '0', 10) || 0;
                let downloaded = 0;
                const out = fs.createWriteStream(destPath);
                res.on('data', (chunk) => {
                    downloaded += chunk.length;
                    if (onProgress) onProgress(downloaded, total);
                });
                res.pipe(out);
                out.on('finish', () => out.close(resolve));
                out.on('error', reject);
                res.on('error', reject);
            });
            req.on('error', reject);
            req.setTimeout(60_000, () => { req.destroy(new Error('Download timed out')); });
            req.end();
        };
        fetch(url);
    });
}
```

Use it from `update:download`:

```js
ipcMain.handle('update:download', async (_e, url) => {
    if (!canSelfInstall()) return { ok: false, error: 'Not supported' };
    if (typeof url !== 'string' || !/^https?:\/\//.test(url)) return { ok: false, error: 'Invalid URL' };

    const ext = process.platform === 'darwin' ? '.dmg' : '.exe';
    const destPath = path.join(os.tmpdir(), `app-update-${Date.now()}${ext}`);
    try {
        await downloadToFile(url, destPath, (got, total) => {
            mainWindow.webContents.send('update:download-progress', { downloaded: got, total });
        });
        // Platform-specific extraction stage — see below
        global._pendingUpdatePath = process.platform === 'darwin'
            ? await mountAndExtractMacDmg(destPath)  // returns staged .app path
            : destPath;                              // .exe used directly
        return { ok: true, path: global._pendingUpdatePath };
    } catch (e) {
        try { fs.unlinkSync(destPath); } catch {}
        return { ok: false, error: e.message };
    }
});
```

---

## Component 5: Windows portable self-install

### Key insight: `PORTABLE_EXECUTABLE_FILE` vs `process.execPath`

In an electron-builder portable build, the user double-clicks `your-app.exe`, but that's a self-extracting launcher. It extracts to `%LOCALAPPDATA%\Temp\<random>\` and launches the actual Electron binary from there. So:

- `process.execPath` = the temp-extracted copy of the Electron binary (gone when the app exits)
- `process.env.PORTABLE_EXECUTABLE_FILE` = the on-disk `.exe` the user actually has (the file you want to replace)

```js
function canSelfInstall() {
    if (!app.isPackaged) return false;
    if (process.platform === 'win32') return !!process.env.PORTABLE_EXECUTABLE_FILE;
    if (process.platform === 'darwin') return true;
    return false;
}
```

### The relauncher `.cmd`

The running `.exe` is locked while the app runs. We can't replace it from inside ourselves. The trick is to spawn a detached `.cmd` that polls until the lock releases, then swaps the file and relaunches.

```js
if (process.platform === 'win32') {
    const launcher = process.env.PORTABLE_EXECUTABLE_FILE;
    const scriptPath = path.join(os.tmpdir(), `app-update-${Date.now()}.cmd`);
    const script = [
        '@echo off',
        'setlocal',
        `set "LAUNCHER=${launcher}"`,
        `set "NEW=${global._pendingUpdatePath}"`,
        'set /a count=0',
        ':retry',
        'move /Y "%NEW%" "%LAUNCHER%" >NUL 2>&1',
        'if errorlevel 1 (',
        '    timeout /t 1 /nobreak >NUL',
        '    set /a count+=1',
        '    if %count% lss 30 goto retry',
        '    exit /b 1',
        ')',
        'start "" "%LAUNCHER%"',
        'del "%~f0"',
        '',
    ].join('\r\n');
    fs.writeFileSync(scriptPath, script);
    spawn('cmd.exe', ['/C', scriptPath], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
    }).unref();
    setTimeout(() => app.quit(), 200);
}
```

The 30-second retry loop is the magic. It tries `move /Y` once per second until the file is no longer locked (the app has quit), then runs `start ""` to launch the new binary and `del "%~f0"` to remove itself.

### Alternative: Windows NSIS installer (much simpler)

If you don't actually need portability (the app can install to disk like a normal Windows program), drop the portable target entirely and use electron-builder's `nsis` target with `oneClick: true`. The installer:
- Drops the app at `%LOCALAPPDATA%\Programs\<productName>\` per-user (no admin)
- Adds Start Menu + Desktop shortcuts
- Registers in Add or Remove Programs (clean uninstall)
- On re-run, detects the running app, closes it, replaces files, relaunches the new version

The auto-update flow becomes trivial — no `.cmd` polling-loop, no `PORTABLE_EXECUTABLE_FILE` magic:

```json
{
  "build": {
    "win": {
      "target": [{ "target": "nsis", "arch": ["x64"] }]
    },
    "nsis": {
      "oneClick": true,
      "perMachine": false,
      "createDesktopShortcut": true,
      "createStartMenuShortcut": true,
      "artifactName": "your-app-setup.exe",
      "runAfterFinish": true,
      "deleteAppDataOnUninstall": false
    }
  }
}
```

```js
function canSelfInstall() {
    if (!app.isPackaged) return false;
    return process.platform === 'win32' || process.platform === 'darwin';
}

if (process.platform === 'win32') {
    // newPath = downloaded installer .exe
    const child = spawn(newPath, ['/S', '--updated'], {
        detached: true,
        stdio: 'ignore',
        windowsHide: true,
    });
    child.unref();
    setTimeout(() => app.quit(), 200);
}
```

That's it. NSIS in silent mode (`/S`) handles the process-detection (sees the running app via its semaphore), kills it, replaces files in `%LOCALAPPDATA%\Programs\...`, and relaunches via `runAfterFinish`.

**Trade-off vs portable:** users get a "real install" experience instead of a runs-from-anywhere `.exe`. For most consumer apps that's actually preferable — Start Menu shortcut, clean uninstall, no "where did I save that .exe" issue. For tools that need to run from USB sticks or shared drives, keep portable.

**Asset substring change:** if you migrate portable → NSIS, the asset name changes from `your-app.exe` to `your-app-setup.exe`. Update the substring match in `getUpdateStatus()` accordingly. Bootstrap pain applies to anyone on the last portable version — they need a one-time manual install of the setup.exe. See the format-transition pattern below.

**Workflow gotcha:** make sure your `npm run build:win` script doesn't pass `--win portable`. The CLI flag overrides `package.json#build.win.target` silently, your NSIS config gets ignored, and the build produces a portable .exe with a name like `your-app 0.1.0.exe` — at which point `upload-artifact` fails because it's looking for `your-app-setup.exe`. Use plain `electron-builder --win` (no target) so the config takes effect.

---

## Component 6: macOS self-install

Macs are harder. Several gotchas the Windows path doesn't have:

1. **`.app` is a directory**, not a file. You need to move the whole tree.
2. **App Translocation**: a quarantined `.app` launched from outside `/Applications/` runs from a *read-only* shadow under `/var/folders/.../AppTranslocation/...`. You can't update that copy in place.
3. **Detached children can still get SIGHUP'd** by their dying parent. `detached: true` + `unref()` is not always enough.
4. **Quarantine attribute** stays on a freshly-downloaded `.app` and triggers Gatekeeper warnings.
5. **Code signature** can be invalidated by moving the `.app` between filesystems.

### DMG mount + extract

Ship your macOS build as a `.dmg`, not a `.zip`. DMG mounting via `hdiutil` plus `ditto` copy preserves the extended attributes properly (regular `unzip` mangles them):

```js
function mountAndExtractMacDmg(dmgPath) {
    return new Promise((resolve, reject) => {
        const ts = Date.now();
        const mountPoint = path.join(os.tmpdir(), `app-mount-${ts}`);
        const stagingDir = path.join(os.tmpdir(), `app-update-${ts}`);
        try { fs.mkdirSync(stagingDir, { recursive: true }); } catch {}

        const detach = () => {
            try { spawn('hdiutil', ['detach', '-quiet', mountPoint], { stdio: 'ignore' }).unref(); } catch {}
        };

        const attach = spawn('hdiutil',
            ['attach', '-nobrowse', '-quiet', '-mountpoint', mountPoint, dmgPath],
            { stdio: 'ignore' });
        attach.on('error', reject);
        attach.on('close', (code) => {
            if (code !== 0) return reject(new Error(`hdiutil attach exit ${code}`));
            let appName;
            try { appName = fs.readdirSync(mountPoint).find(n => n.endsWith('.app')); }
            catch (e) { detach(); return reject(new Error(`Read mount: ${e.message}`)); }
            if (!appName) { detach(); return reject(new Error('No .app in DMG')); }

            const sourceApp = path.join(mountPoint, appName);
            const destApp = path.join(stagingDir, appName);
            const cp = spawn('ditto', [sourceApp, destApp], { stdio: 'ignore' });
            cp.on('error', (err) => { detach(); reject(err); });
            cp.on('close', (cpCode) => {
                detach();
                if (cpCode !== 0) return reject(new Error(`ditto exit ${cpCode}`));
                resolve(destApp);
            });
        });
    });
}
```

### Detecting App Translocation

If `app.getPath('exe')` lives inside `/AppTranslocation/`, the running `.app` is a read-only shadow. Install to `/Applications/` instead:

```js
const runningAppBundle = app.getPath('exe').replace(/\/Contents\/MacOS\/[^/]+$/, '');
const isTranslocated = runningAppBundle.includes('/AppTranslocation/');
const targetAppBundle = isTranslocated
    ? path.join('/Applications', app.getName() + '.app')
    : runningAppBundle;
```

### The macOS relauncher (with double-fork daemonization)

`detached: true` + `unref()` sometimes leaves the child reachable by SIGHUP. The robust pattern is to have the script **re-exec itself** in a fully backgrounded subshell that survives `app.quit()`:

```js
const newPath = global._pendingUpdatePath;
const appBundle = targetAppBundle;
const ts = Date.now();
const scriptPath = path.join(os.tmpdir(), `app-update-${ts}.sh`);

// Logs to a predictable location so the user can diagnose if anything fails.
const logDir = path.join(os.homedir(), 'Library', 'Logs', app.getName());
try { fs.mkdirSync(logDir, { recursive: true }); } catch {}
const logPath = path.join(logDir, `update-${ts}.log`);

// Write a breadcrumb BEFORE spawn, so we can prove the IPC fired even if
// the script silently fails to launch.
const attemptLogPath = path.join(logDir, 'attempts.log');
fs.appendFileSync(attemptLogPath,
    `[${new Date().toISOString()}] applyUpdate\n  pid: ${process.pid}\n  new: ${newPath}\n  target: ${appBundle}\n  log: ${logPath}\n`);

const script = [
    '#!/bin/bash',
    `LOG="${logPath}"`,
    '# Stage 1: re-exec into a fully detached background subshell',
    'if [ "$1" != "--daemonized" ]; then',
    '    nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 &',
    '    disown',
    '    exit 0',
    'fi',
    'shift',
    'exec >>"$LOG" 2>&1',
    'set -x',
    'echo "=== update script started $(date) ==="',
    'trap "" HUP TERM  # belt and suspenders on top of nohup',
    'PID=$1',
    `NEW_APP="${newPath}"`,
    `TARGET="${appBundle}"`,
    'BACKUP="${TARGET}.bak"',
    'echo "PID=$PID NEW=$NEW_APP TARGET=$TARGET"',
    'for i in $(seq 1 30); do',
    '    if ! ps -p $PID > /dev/null 2>&1; then echo "Parent gone after ${i}s"; break; fi',
    '    sleep 1',
    'done',
    'xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true',
    'if [ -d "$TARGET" ]; then',
    '    rm -rf "$BACKUP" 2>/dev/null',
    '    if ! mv "$TARGET" "$BACKUP"; then',
    '        echo "ERROR: could not back up existing TARGET (permission?). Aborting."',
    '        rm -f "$0"',
    '        exit 1',
    '    fi',
    'fi',
    'if mv "$NEW_APP" "$TARGET"; then',
    '    codesign --force --deep --sign - "$TARGET" 2>&1 || true',
    '    rm -rf "$BACKUP" 2>/dev/null',
    '    open "$TARGET"',
    'else',
    '    echo "ERROR: mv NEW->TARGET failed. Rolling back."',
    '    [ -d "$BACKUP" ] && [ ! -d "$TARGET" ] && mv "$BACKUP" "$TARGET"',
    '    [ -d "$TARGET" ] && open "$TARGET"',
    'fi',
    'echo "=== script finished $(date) ==="',
    'rm -f "$0"',
    '',
].join('\n');
fs.writeFileSync(scriptPath, script);
fs.chmodSync(scriptPath, 0o755);

const child = spawn('/bin/bash', [scriptPath, String(process.pid)], {
    detached: true,
    stdio: 'ignore',
});
child.on('error', (err) => {
    try { fs.appendFileSync(attemptLogPath, `  SPAWN ERROR: ${err.message}\n`); } catch {}
});
child.unref();
setTimeout(() => app.quit(), 500);  // 500ms — give nohup time to reparent
```

The key pieces:

- **Stage 1** runs synchronously: `nohup "$0" --daemonized "$@" & disown` re-execs the script in the background with SIGHUP ignored, then `exit 0`. The originally-spawned shell dies cleanly.
- **Stage 2** (the daemonized branch) does the actual work: redirect output to a log file, wait for the parent PID, strip quarantine on the new `.app`, back up the existing `TARGET`, move new into place, re-sign ad-hoc, `open` it.
- **Rollback path** restores `BACKUP` if the move fails so the user is never left without a working app.
- **Attempts log** (`~/Library/Logs/<AppName>/attempts.log`) gets a line BEFORE the spawn, so if the script silently fails to even start, you have evidence the IPC ran.

---

## Component 7: Build configuration

In `electron-builder`'s config:

```json
{
  "build": {
    "publish": null,
    "win": {
      "target": [{ "target": "portable", "arch": ["x64"] }]
    },
    "portable": {
      "artifactName": "your-app.exe"
    },
    "mac": {
      "icon": "build/icon.png",
      "category": "...",
      "target": [{ "target": "dmg", "arch": ["arm64"] }],
      "artifactName": "your-app-mac-${arch}.${ext}",
      "identity": null
    },
    "dmg": {
      "title": "Install Your App",
      "background": "build/dmg-background.png",
      "iconSize": 100,
      "window": { "width": 540, "height": 400 },
      "contents": [
        { "x": 140, "y": 220, "type": "file" },
        { "x": 400, "y": 220, "type": "link", "path": "/Applications" }
      ]
    }
  }
}
```

Three things to flag:

1. **`publish: null`** is required if you're publishing via a separate CI step (e.g., `softprops/action-gh-release`). Without it, electron-builder auto-publishes on tag push and demands `GH_TOKEN`.
2. **`mac.identity: null`** skips electron-builder's signing phase. Then ad-hoc sign in an `afterPack` hook so Apple Silicon's Gatekeeper accepts the build (otherwise unsigned arm64 builds show as "damaged"):
   ```js
   // build/after-pack.js
   const { execSync } = require('child_process');
   const path = require('path');
   exports.default = async function(context) {
       if (context.electronPlatformName !== 'darwin') return;
       const appName = context.packager.appInfo.productFilename + '.app';
       const appPath = path.join(context.appOutDir, appName);
       execSync(`codesign --force --deep --sign - "${appPath}"`, { stdio: 'inherit' });
   };
   ```
3. **The DMG `background`** should be much larger than `window.width × height` (say 1920×1200, design pinned to top-left). Finder doesn't tile or scale — anywhere the user resizes past the image bounds shows Finder's default white.

---

## Component 8: IPC + preload bindings

```js
// preload.js
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('api', {
    onUpdateAvailable:        (cb)   => ipcRenderer.on('update:available', (_e, p) => cb(p)),
    onUpdateDownloadProgress: (cb)   => ipcRenderer.on('update:download-progress', (_e, p) => cb(p)),
    checkForUpdates:          ()     => ipcRenderer.invoke('update:check'),
    canSelfInstall:           ()     => ipcRenderer.invoke('update:can-self-install'),
    downloadUpdate:           (url)  => ipcRenderer.invoke('update:download', url),
    applyUpdate:              ()     => ipcRenderer.invoke('update:apply'),
    openExternal:             (url)  => ipcRenderer.invoke('shell:open-external', url),
    getAppVersion:            ()     => ipcRenderer.invoke('app:version'),
});
```

```js
// main.js (handlers)
ipcMain.handle('app:version', () => app.getVersion());
ipcMain.handle('update:check', async () => {
    const result = await getUpdateStatus();
    if (result.status === 'available' && mainWindow) {
        mainWindow.webContents.send('update:available', {
            version: result.version,
            downloadUrl: result.downloadUrl,
            releaseUrl: result.releaseUrl,
        });
    }
    return result;
});
ipcMain.handle('update:can-self-install', () => canSelfInstall());
ipcMain.handle('shell:open-external', (_e, url) => {
    if (typeof url === 'string' && /^https?:\/\//.test(url)) shell.openExternal(url);
});
// update:download and update:apply: see components 4-6 above
```

And in `app.whenReady`, fire-and-forget the launch check:

```js
app.whenReady().then(() => {
    createWindow();
    checkForUpdatesAndNotify().catch(() => {});
});

async function checkForUpdatesAndNotify() {
    const result = await getUpdateStatus();
    if (result.status === 'available' && mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('update:available', {
            version: result.version,
            downloadUrl: result.downloadUrl,
            releaseUrl: result.releaseUrl,
        });
    }
}
```

---

## Hard-learned gotchas (memorize these)

| Symptom | Cause | Fix |
|---|---|---|
| `Error: spawn <path> ENOENT` in a packaged build | `cwd: __dirname` resolves into `app.asar` virtual path; the OS can't `chdir()` into it before `exec`. | Drop the `cwd` from any `spawn()` you do in main process — the inherited cwd is a real on-disk path. |
| `Error: spawn <binary> ENOTDIR` in a packaged build | A binary from an npm package (e.g., `ffmpeg-static`) has its path inside `app.asar`. Electron's fs patches make `existsSync` return true but `spawn` goes through the raw OS exec syscall and chokes. | `asarUnpack` the package + rewrite the path: `require('foo-bin').replace('app.asar', 'app.asar.unpacked')`. |
| macOS .app shows "damaged and can't be opened" | The Apple-Silicon `.app` is completely unsigned. arm64 Gatekeeper rejects unsigned binaries entirely (not the standard "unidentified developer" warning — a harsher error). | Ad-hoc sign in an `afterPack` hook with `codesign --force --deep --sign -`. |
| CI fails with "GH_TOKEN is not set" on tag push | electron-builder auto-publishes when it sees a tag, demands a token. | `"publish": null` in `package.json#build`. Publish via a separate CI step instead. |
| GitHub release body is empty after CI completes | `softprops/action-gh-release@v2` produces an empty body on essentially *every* release in our experience — not "sometimes". Treat it as a guaranteed post-CI fix-up, not a flake. | Always verify body length post-CI: `gh release view vX.Y.Z --json body --jq '(.body \| length)'`. If 0 (it will be), `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md`, then re-verify. |
| Draft release URL contains `untagged-<hash>` instead of the tag name | Cosmetic — softprops creates drafts at a hash-based URL; GitHub moves them to `/releases/tag/vX.Y.Z` only when published. | Not a bug. The draft *has* the tag (`gh release view vX.Y.Z` resolves it fine); only the public URL changes on publish. |
| macOS "Restart to apply" closes the app but doesn't update | App is running from `/var/folders/.../AppTranslocation/...` (read-only shadow). `mv` fails with "Read-only file system". | Detect `/AppTranslocation/` in the path, install to `/Applications/<AppName>.app` instead of trying to swap in place. |
| Detached child process never runs after `app.quit()` | `detached: true` + `unref()` isn't always enough on macOS — SIGHUP can still propagate. | Wrap in `nohup`, AND have the script double-fork itself via `nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 & disown`. |
| First-launch Gatekeeper still prompts after auto-update on macOS | The newly-moved `.app` inherited the quarantine attribute from the download. | `xattr -dr com.apple.quarantine "$NEW_APP"` in the relauncher script BEFORE moving into place. |
| `/releases/latest` doesn't return your draft | By design — drafts and pre-releases are invisible to `/latest`. | Users on the current published version won't see notices for drafts you've cut but haven't clicked Publish on. This is usually what you want. |
| Update available appears but Download opens browser instead | The renderer fell through `canSelfInstall() === false` to the `openExternal` path. | Check that the user is on a version that *had* the self-install code at the time of build. Bootstrap problem: the auto-update code itself has to be installed via the OLD manual flow before it can take over. |
| Update fails for users on the version *just before* an asset rename | Old installed version's updater hardcodes a substring match for the OLD asset name (e.g., `mac-arm64.zip`); the new release ships only the new name (e.g., `mac-arm64.dmg`). No match → updater falls back to `release.html_url` → downloader streams HTML and the extractor chokes on the "archive". | Ship BOTH formats for ONE transition release, then drop the old in the next. Or accept that one cohort does a one-time manual install — document the workaround in that version's release notes. Note this is distinct from the "introducing the updater" bootstrap problem above. |
| `actions/upload-artifact` fails with "No files were found" after a successful build | The electron-builder npm script passes a CLI target flag (`--win portable`, `--mac dmg`, etc.) that overrides the targets in `package.json#build.<platform>.target`. The build succeeds with the CLI-specified target and produces a differently-named file than your workflow expects. | Don't use `--win <target>` in npm scripts. Call `electron-builder --win` (no target) so it uses the config. Verify with the build log: look for `building target=... file=...`. |
| `softprops/action-gh-release@v2` fails with "Bad credentials" on first run | Possibly transient — observed even with `permissions: contents: write` set on the release job. The default `GITHUB_TOKEN` is what gets rejected. | `gh run rerun <run-id> --failed` — re-run just the release job (builds stay cached, so it's seconds). If the second attempt also fails, fall back to creating the release manually with `gh release create` against the artifacts the build jobs uploaded. |

---

## Patterns worth borrowing

**Validation bump after a structural updater change.** When you ship a change to the updater itself — new asset format, new spawn-survival logic, new path-resolution code — also ship a *no-code-change* patch release right after it. The prior version then has something newer to update to, exercising the full end-to-end path with zero ambiguity: if a bug shows up, you know it's in the updater code or release plumbing, not in whatever feature came alongside. Same pattern as a smoke deploy after an infrastructure migration. (In this repo: v0.1.13 → v0.1.14, v0.1.17 → v0.1.18.)

**Document the bootstrap path in release notes.** Any time you make a change that orphans the previous version's auto-update — first time the updater ships, asset rename, asset path move — write the manual workaround into THAT release's notes. Don't make the affected users guess. A one-line "If you're on vX.Y, download this DMG once and drag it in; future updates auto-apply" goes a long way.

**Verify the release body every single time.** softprops leaves the body empty on every release we've shipped, full stop. Either bake `gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md` into the workflow as a post-publish step (with `${{ steps.softprops.outputs.id != '' }}` or similar guard), or make body-verification + manual fix step 5 of your ship checklist and never skip it. The empty-body failure mode is silent — users see a blank GitHub release page and panic.

**Separate "create draft" from "publish".** Let CI always produce a *draft* (`draft: true` in softprops). Then publish manually via `gh release edit vX.Y.Z --draft=false` once you've eyeballed the artifacts and notes. This catches release-notes typos, missing artifacts, and CI-side body-empty regressions before they hit users. It also lets you abandon a botched release without burning a version number (delete the draft + tag, fix, re-tag the same version).

**Re-tag safely when a CI build failed.** If the release job was skipped because a build job failed, no release exists yet — re-tagging at the same version is safe and doesn't violate the "never force-move a published tag" rule. Delete the local + remote tag, fix the underlying issue with a new commit, retag at the fix commit, push. The next CI run uses the fixed workflow / code path.

**Two update entry-points: pulse pill + activity-log notice.** Some users want one-click "just update already"; others want to review the notes before restarting. You can satisfy both with two independent surfaces of the same update event:
- A pulsing pill in the topbar (next to the version label) → single click runs download → auto-apply → restart, no second click
- A row in your activity log / notification surface → two-click: Download then Restart to apply

Both subscribe to the same `update:available` and progress events. Have them read the same backend IPCs (`canSelfInstall`, `downloadUpdate`, `applyUpdate`). Each maintains its own local state machine; they don't need to coordinate as long as both call the same idempotent-ish backend.

**Format-transition bootstrap cost is a real budget item.** Every time you change the asset distribution format (`.zip` → `.dmg` on macOS, `.exe` portable → `.exe` NSIS installer on Windows, etc.), the version *just before* the change can't auto-update to the new format — its substring-match for the old name doesn't fire on the new one, and its update mechanism (e.g., portable's `move /Y` swap) doesn't know how to handle an installer. Plan for one of:
- **Manual install once.** Document in release notes. Cheapest, fine for personal apps.
- **Ship both formats for one transition release.** Old asset name plus new. Old code finds the old, new code finds the new. Drop the old in N+1.
- **Patch the OLD version first.** Ship a tiny "just fixes the auto-update lookup" release before the format change. Now everyone's on a version that knows how to find the new format.

---

## A copy-pasteable ship-tail

Everything *after* `git push origin <tag>` in the ship process is mechanical and identical every time. Stash this as a tiny helper in any project using this pattern (PowerShell shown — trivially translatable to bash with `gh` calls):

```powershell
# Usage:  .\ship-tail.ps1 v0.1.17
param([Parameter(Mandatory)][string]$Tag)

$gh = "C:\Users\<you>\AppData\Local\Microsoft\WinGet\Links\gh.exe"  # or just "gh" if on PATH

# 1. Wait for CI to finish. Assumes the tag-push triggered a run.
$run = (& $gh run list --limit 1 --workflow release.yml --json databaseId --jq ".[0].databaseId")
& $gh run watch $run --exit-status
if ($LASTEXITCODE -ne 0) { Write-Error "CI failed for $Tag"; exit 1 }

# 2. Body verification — guaranteed-empty on softprops, fix unconditionally.
$len = & $gh release view $Tag --json body --jq "(.body | length)"
if ([int]$len -lt 50) {
    Write-Host "Body short ($len chars). Setting from RELEASE_NOTES.md."
    & $gh release edit $Tag --notes-file RELEASE_NOTES.md
    $len = & $gh release view $Tag --json body --jq "(.body | length)"
    Write-Host "Body now $len chars."
}

# 3. Show summary, leave as draft for manual publish.
& $gh release view $Tag --json url,isDraft,assets --jq "{url, isDraft, assets: [.assets[].name]}"
Write-Host "Review and publish manually: gh release edit $Tag --draft=false"
```

Key things this captures that are easy to forget:
- The CI-finished check happens inside `gh run watch --exit-status` (non-zero on failure → caller knows)
- Body length is the only reliable post-CI signal that softprops did its job (it didn't)
- Final state is *still a draft* — that's intentional. Publish is a deliberate human step.

If you want fully automated, just append `& $gh release edit $Tag --draft=false` to the end. For a personal app it's fine; for anything user-facing keep the manual review.

---

## Bonus: when to pay for signing

Everything above works without paying anyone. The trade-offs:

- **Windows**: first-launch SmartScreen warning. Survivable. Real Authenticode cert = $80–300/yr.
- **macOS**: first-launch right-click → Open dance, plus on Ventura+ a trip to System Settings → Privacy & Security. Real Apple Developer Program = $99/yr + notarization in CI.

For a personal app or small audience, skip both. For broader distribution, the Apple side is the bigger UX wound (Gatekeeper on newer macOS is harder for non-technical users than SmartScreen) — fix that first if budget is limited. Paying for macOS signing also unlocks `electron-updater` proper, which has block-level differential updates (download ~2-5 MB instead of full app size).

---

## Closing checklist

When you wire this up in a new project, walk through:

- [ ] `update:check`, `update:can-self-install`, `update:download`, `update:apply`, `shell:open-external`, `app:version` IPC handlers in main
- [ ] Matching preload bindings + `onUpdateAvailable`, `onUpdateDownloadProgress`
- [ ] Renderer notice + button state machine
- [ ] Windows: `PORTABLE_EXECUTABLE_FILE` check; `.cmd` relauncher with 30-retry polling loop
- [ ] macOS: DMG distribution; `hdiutil` mount + `ditto` extract; double-fork bash relauncher; quarantine strip; App Translocation detection; install to `/Applications/`; logs at `~/Library/Logs/<AppName>/`
- [ ] `publish: null` in build config
- [ ] `mac.identity: null` + `afterPack` ad-hoc signing hook
- [ ] Settings UI: "Check for updates" button with state feedback
- [ ] CI: workflow attaches the platform artifacts to the GitHub release; verify body post-deploy

The user clicks twice, the app updates itself, no manual file shuffling. Worth the ~400 lines of setup.
