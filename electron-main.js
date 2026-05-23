// Electron main process for the TIDAL Downloader GUI
const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const https = require('https');
const { spawn } = require('child_process');

// Force userData to %APPDATA%\Roaming\robogears Downloader\ on both dev and
// packaged builds. Without setName, dev mode uses package.json `name`
// (robogears-downloader, hyphen) while packaged builds use productName
// (robogears Downloader, space) — diverging on disk. Explicit setName
// keeps both pointing at the same folder.
app.setName('robogears Downloader');

// In a packaged build, the source folder is read-only (inside an asar archive),
// so we route token.json + settings to the user-writable userData dir. The
// env var is also propagated to spawned children via `childEnv()` so they
// read/write the same file.
if (app.isPackaged) {
    process.env.TIDAL_TOKEN_PATH = path.join(app.getPath('userData'), 'token.json');
}

const lib = require('./tidal_lib');

const SETTINGS_PATH = () => path.join(app.getPath('userData'), 'settings.json');
const QUEUE_PATH = () => path.join(app.getPath('userData'), 'queue.json');

// Forward library-scan progress events to the renderer, throttled inside
// scanLibrary itself (one tick per ~25 files).
function sendScanProgress(done, total) {
    if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('library:scan-progress', { done, total });
    }
}

function loadSettings() {
    try { return JSON.parse(fs.readFileSync(SETTINGS_PATH(), 'utf8')); }
    catch { return {}; }
}
function saveSettings(s) {
    const prev = loadSettings();
    fs.writeFileSync(SETTINGS_PATH(), JSON.stringify(s, null, 2));
    if (typeof s.libraryFolder === 'string' && s.libraryFolder !== prev.libraryFolder) {
        lib.setLibraryPath(s.libraryFolder);
        // Kick off a fresh background scan with the new path
        lib.scanLibrary(sendScanProgress).then(c => {
            if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
        }).catch(() => {});
    }
}

let mainWindow = null;
let activeChild = null;
// Set by resolve:input at the start of each call, flipped to true by
// resolve:cancel so the resolver workers can bail out at iteration boundaries.
let resolverCancelled = false;

function childEnv() {
    const s = loadSettings();
    return {
        ...process.env,
        ELECTRON_RUN_AS_NODE: '1',
        FORCE_COLOR: '0',
        TIDAL_LIBRARY_FOLDER: s.libraryFolder || '',
        // Tells tidal_download.js to emit __TRACK_PROGRESS__ markers so the
        // renderer can show per-track progress bars in the queue.
        BULK_RUNNER_PROGRESS: '1',
    };
}

function createWindow() {
    const opts = {
        width: 980,
        height: 740,
        minWidth: 720,
        minHeight: 540,
        backgroundColor: '#0a0a0a',
        title: 'robogears Downloader',
        webPreferences: {
            preload: path.join(__dirname, 'electron-preload.js'),
            contextIsolation: true,
            nodeIntegration: false,
            sandbox: false,
        },
        autoHideMenuBar: true,
    };
    // Dev-mode only: set the BrowserWindow icon so the taskbar/Dock shows our
    // custom mark instead of the default Electron gem. In packaged builds the
    // icon is already embedded into the .exe/.app via the build config, so
    // there's no need (and `build/icon.png` isn't shipped into the asar).
    if (!app.isPackaged) {
        opts.icon = path.join(__dirname, 'build', 'icon.png');
    }
    mainWindow = new BrowserWindow(opts);
    mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
    // mainWindow.webContents.openDevTools({ mode: 'detach' });
}

// ─── Update check ─────────────────────────────────────────────────────────────

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

function fetchLatestRelease() {
    return new Promise((resolve) => {
        const req = https.request({
            hostname: 'api.github.com',
            path: '/repos/robogears/robogearsDownloader/releases/latest',
            method: 'GET',
            headers: {
                'User-Agent': `robogears-downloader/${app.getVersion()}`,
                'Accept': 'application/vnd.github+json',
            },
            timeout: 10_000,
        }, (res) => {
            let data = '';
            res.on('data', d => data += d);
            res.on('end', () => {
                if (res.statusCode !== 200) return resolve(null);
                try { resolve(JSON.parse(data)); }
                catch { resolve(null); }
            });
        });
        req.on('error', () => resolve(null));
        req.on('timeout', () => { req.destroy(); resolve(null); });
        req.end();
    });
}

// Returns one of:
//   { status: 'available', version, downloadUrl, releaseUrl }
//   { status: 'up-to-date', version }
//   { status: 'error', message }
async function getUpdateStatus() {
    const release = await fetchLatestRelease();
    if (!release || !release.tag_name) {
        return { status: 'error', message: 'Could not reach GitHub' };
    }
    if (!isNewerVersion(release.tag_name, app.getVersion())) {
        return { status: 'up-to-date', version: app.getVersion() };
    }
    const wantedSubstr = process.platform === 'darwin' ? 'mac-arm64.dmg'
                       : process.platform === 'win32'  ? '.exe'
                       : null;
    let downloadUrl = release.html_url;
    if (wantedSubstr) {
        const asset = (release.assets || []).find(a => a.name && a.name.includes(wantedSubstr));
        if (asset && asset.browser_download_url) downloadUrl = asset.browser_download_url;
    }
    return { status: 'available', version: release.tag_name, downloadUrl, releaseUrl: release.html_url };
}

function notifyIfAvailable(result) {
    if (result.status === 'available' && mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('update:available', {
            version: result.version,
            downloadUrl: result.downloadUrl,
            releaseUrl: result.releaseUrl,
        });
    }
}

async function checkForUpdatesAndNotify() {
    notifyIfAvailable(await getUpdateStatus());
}

ipcMain.handle('update:check', async () => {
    const result = await getUpdateStatus();
    notifyIfAvailable(result);
    return result;
});

ipcMain.handle('app:version', () => app.getVersion());

ipcMain.handle('shell:open-external', (_e, url) => {
    if (typeof url === 'string' && /^https?:\/\//.test(url)) shell.openExternal(url);
});

// ─── Self-install ─────────────────────────────────────────────────────────────
// Windows portable: replace the launcher .exe (path from PORTABLE_EXECUTABLE_FILE).
// macOS: replace the .app bundle (path derived from process.execPath).
// Dev / non-portable Windows / Linux: falls back to opening the release page.
function canSelfInstall() {
    if (!app.isPackaged) return false;
    if (process.platform === 'win32') return !!process.env.PORTABLE_EXECUTABLE_FILE;
    if (process.platform === 'darwin') return true;
    return false;
}
ipcMain.handle('update:can-self-install', () => canSelfInstall());

const os = require('os');
function downloadToFile(url, destPath, onProgress) {
    return new Promise((resolve, reject) => {
        // Follow up to 5 redirects (GitHub release assets redirect to S3)
        const fetch = (u, redirects = 0) => {
            const req = https.request(u, { method: 'GET', headers: { 'User-Agent': `robogears-downloader/${app.getVersion()}` } }, (res) => {
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

// Mount a macOS .dmg via hdiutil, copy the .app out via ditto (preserves
// extended attributes that hdiutil's read-only mount and plain cp would lose),
// and unmount. Returns the path to the staged .app bundle the relauncher
// script will move into /Applications/.
function mountAndExtractMacDmg(dmgPath) {
    return new Promise((resolve, reject) => {
        const ts = Date.now();
        const mountPoint = path.join(os.tmpdir(), `robogears-mount-${ts}`);
        const stagingDir = path.join(os.tmpdir(), `robogears-update-${ts}`);
        try { fs.mkdirSync(stagingDir, { recursive: true }); } catch {}

        // Always try to detach the mount point on the way out — even on failure
        // — so we don't leave phantom Finder volumes lying around.
        const detach = () => {
            try {
                spawn('hdiutil', ['detach', '-quiet', mountPoint], { stdio: 'ignore' }).unref();
            } catch {}
        };

        const attach = spawn('hdiutil',
            ['attach', '-nobrowse', '-quiet', '-mountpoint', mountPoint, dmgPath],
            { stdio: 'ignore' });
        attach.on('error', reject);
        attach.on('close', (code) => {
            if (code !== 0) return reject(new Error(`hdiutil attach exit ${code}`));

            let appName;
            try {
                appName = fs.readdirSync(mountPoint).find(n => n.endsWith('.app'));
            } catch (e) {
                detach();
                return reject(new Error(`Could not read mounted DMG: ${e.message}`));
            }
            if (!appName) {
                detach();
                return reject(new Error('No .app bundle found inside the DMG'));
            }

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

ipcMain.handle('update:download', async (_e, url) => {
    if (!canSelfInstall()) return { ok: false, error: 'Self-install not supported on this build' };
    if (typeof url !== 'string' || !/^https?:\/\//.test(url)) return { ok: false, error: 'Invalid URL' };
    const ext = process.platform === 'darwin' ? '.dmg' : '.exe';
    const destPath = path.join(os.tmpdir(), `robogears-downloader-${Date.now()}${ext}`);
    try {
        await downloadToFile(url, destPath, (got, total) => {
            if (mainWindow && !mainWindow.isDestroyed()) {
                mainWindow.webContents.send('update:download-progress', { downloaded: got, total });
            }
        });
        if (process.platform === 'darwin') {
            // Mount the .dmg, copy the .app to a staging dir, unmount.
            const extractedApp = await mountAndExtractMacDmg(destPath);
            global._pendingUpdatePath = extractedApp;
            try { fs.unlinkSync(destPath); } catch {} // dmg no longer needed
        } else {
            global._pendingUpdatePath = destPath;
        }
        return { ok: true, path: global._pendingUpdatePath };
    } catch (e) {
        try { fs.unlinkSync(destPath); } catch {}
        return { ok: false, error: e.message };
    }
});

ipcMain.handle('update:apply', () => {
    if (!canSelfInstall()) return { ok: false, error: 'Self-install not supported on this build' };
    const newPath = global._pendingUpdatePath;
    if (!newPath || !fs.existsSync(newPath)) {
        return { ok: false, error: 'No downloaded update available' };
    }

    if (process.platform === 'win32') {
        // ─── Windows portable ───────────────────────────────────────
        const launcher = process.env.PORTABLE_EXECUTABLE_FILE;
        const scriptPath = path.join(os.tmpdir(), `robogears-update-${Date.now()}.cmd`);
        // Detached .cmd that polls until the locked .exe can be overwritten,
        // then swaps it and relaunches. Self-deletes when done. ~30s retries.
        const script = [
            '@echo off',
            'setlocal',
            `set "LAUNCHER=${launcher}"`,
            `set "NEW=${newPath}"`,
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
        const child = spawn('cmd.exe', ['/C', scriptPath], {
            detached: true,
            stdio: 'ignore',
            windowsHide: true,
        });
        child.unref();
    } else if (process.platform === 'darwin') {
        // ─── macOS ──────────────────────────────────────────────────
        // process.execPath is .../<App>.app/Contents/MacOS/<exe>. Strip the
        // last three segments to get the .app bundle the OS is running from.
        // NOTE: if Gatekeeper has translocated us (i.e., we were launched from
        // outside /Applications/ with quarantine still set), this path is a
        // READ-ONLY shadow copy at /var/folders/.../AppTranslocation/... — we
        // can't modify it. In that case we install to /Applications/ instead.
        const runningAppBundle = app.getPath('exe').replace(/\/Contents\/MacOS\/[^/]+$/, '');
        const isTranslocated = runningAppBundle.includes('/AppTranslocation/');
        const targetAppBundle = isTranslocated
            ? path.join('/Applications', app.getName() + '.app')
            : runningAppBundle;
        const appBundle = targetAppBundle;
        // Put logs in ~/Library/Logs/robogears Downloader/ — a predictable,
        // standard macOS log location. Previously we used os.tmpdir() but
        // that's /var/folders/... on macOS which is hard to find.
        const logDir = path.join(os.homedir(), 'Library', 'Logs', 'robogears Downloader');
        try { fs.mkdirSync(logDir, { recursive: true }); } catch {}
        const ts = Date.now();
        const scriptPath = path.join(os.tmpdir(), `robogears-update-${ts}.sh`);
        const logPath = path.join(logDir, `update-${ts}.log`);
        // Write a "this IPC fired" breadcrumb BEFORE we spawn anything, so even
        // if the spawn silently fails we can prove the apply was reached.
        const attemptLogPath = path.join(logDir, 'attempts.log');
        try {
            fs.appendFileSync(attemptLogPath,
                `[${new Date().toISOString()}] applyUpdate fired\n` +
                `  parent pid: ${process.pid}\n` +
                `  app bundle: ${appBundle}\n` +
                `  new app:    ${newPath}\n` +
                `  script:     ${scriptPath}\n` +
                `  log:        ${logPath}\n`
            );
        } catch {}

        // The script daemonizes itself via a double-fork so it survives the
        // parent's death. Stage 1 backgrounds itself with nohup + disown +
        // </dev/null >/dev/null 2>&1; stage 2 (with --daemonized) does the
        // actual work.
        //
        // The work itself installs the new .app at $TARGET — which is either
        // (a) the same path the user is running from (in-place update on a
        // properly installed .app) or (b) /Applications/<App>.app if the
        // running copy was Gatekeeper-translocated to a read-only shadow.
        // Either way, we back up any existing copy at $TARGET, move the new
        // .app in, re-sign ad-hoc, and `open` it. Roll back from .bak if any
        // step fails so the user is never left without a working app.
        const script = [
            '#!/bin/bash',
            `LOG="${logPath}"`,
            '# Stage 1: re-exec into a fully detached background subshell.',
            'if [ "$1" != "--daemonized" ]; then',
            '    nohup "$0" --daemonized "$@" </dev/null >/dev/null 2>&1 &',
            '    disown',
            '    exit 0',
            'fi',
            'shift  # drop --daemonized',
            'exec >>"$LOG" 2>&1',
            'set -x',
            'echo "=== robogears update script started at $(date) ==="',
            'trap "" HUP TERM  # belt and suspenders on top of nohup',
            'PID=$1',
            `NEW_APP="${newPath}"`,
            `TARGET="${targetAppBundle}"`,
            `RUNNING_FROM="${runningAppBundle}"`,
            `TRANSLOCATED="${isTranslocated ? '1' : '0'}"`,
            'BACKUP="${TARGET}.bak"',
            'echo "PID=$PID NEW=$NEW_APP TARGET=$TARGET RUNNING_FROM=$RUNNING_FROM TRANSLOCATED=$TRANSLOCATED"',
            'echo "Waiting for parent process $PID to exit..."',
            'for i in $(seq 1 30); do',
            '    if ! ps -p $PID > /dev/null 2>&1; then echo "Parent gone after ${i}s"; break; fi',
            '    sleep 1',
            'done',
            'xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null || true',
            '# If something is already at TARGET, back it up first so we can roll back.',
            'if [ -d "$TARGET" ]; then',
            '    echo "Backing up existing $TARGET..."',
            '    rm -rf "$BACKUP" 2>/dev/null',
            '    if ! mv "$TARGET" "$BACKUP"; then',
            '        echo "ERROR: could not back up existing TARGET (permission?). Aborting."',
            '        rm -f "$0"',
            '        exit 1',
            '    fi',
            'fi',
            'echo "Moving NEW -> TARGET..."',
            'if mv "$NEW_APP" "$TARGET"; then',
            '    echo "Re-signing ad-hoc..."',
            '    codesign --force --deep --sign - "$TARGET" 2>&1 || true',
            '    echo "Removing backup..."',
            '    rm -rf "$BACKUP" 2>/dev/null',
            '    echo "Opening new app at $TARGET..."',
            '    open "$TARGET"',
            '    echo "Done."',
            'else',
            '    echo "ERROR: mv NEW->TARGET failed. Rolling back."',
            '    if [ -d "$BACKUP" ] && [ ! -d "$TARGET" ]; then',
            '        mv "$BACKUP" "$TARGET"',
            '    fi',
            '    [ -d "$TARGET" ] && open "$TARGET"',
            'fi',
            'echo "=== script finished at $(date) ==="',
            'rm -f "$0"',
            '',
        ].join('\n');
        fs.writeFileSync(scriptPath, script);
        fs.chmodSync(scriptPath, 0o755);

        // Spawn the script. The stage-1 branch above runs synchronously,
        // immediately backgrounds the real work, and exits — so even if the
        // parent kills the spawned shell, the actual update runs on.
        const child = spawn('/bin/bash', [scriptPath, String(process.pid)], {
            detached: true,
            stdio: 'ignore',
        });
        child.on('error', (err) => {
            try {
                fs.appendFileSync(attemptLogPath,
                    `  SPAWN ERROR: ${err.message}\n`
                );
            } catch {}
        });
        child.unref();
        global._lastUpdateLogPath = logPath;
    } else {
        return { ok: false, error: `Self-install not implemented for ${process.platform}` };
    }

    // Give the spawn a beat to fully reparent (especially through nohup on
    // macOS) before the parent dies. 200ms was sometimes too tight.
    setTimeout(() => app.quit(), 500);
    return { ok: true };
});

app.whenReady().then(async () => {
    // Prime the lib's library-check path from saved settings
    const s = loadSettings();
    if (typeof s.libraryFolder === 'string') lib.setLibraryPath(s.libraryFolder);

    createWindow();

    // Warm the library scan in the background — but only if the user has
    // configured a library folder. On first launch (no settings) we skip
    // entirely so the app doesn't index a phantom path.
    if (s.libraryFolder) {
        lib.scanLibrary(sendScanProgress).then(c => {
            if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
        }).catch(() => {});
    }

    // Check GitHub releases for a newer version and surface it in the activity
    // log. Renderer handles the race if it isn't ready yet (queues the payload).
    checkForUpdatesAndNotify().catch(() => {});

    // Confirm bundled ffmpeg is actually invokable. If neither the asar-unpacked
    // path nor a system 'ffmpeg' on PATH responds to `-version`, surface a clear
    // warning to the activity log instead of letting the user discover it
    // mid-download as a confusing "ffmpeg exited 1".
    verifyFfmpegAvailable();

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
});

function verifyFfmpegAvailable() {
    let ffmpegPath;
    try {
        const fp = require('ffmpeg-static');
        const unpacked = fp && fp.replace('app.asar', 'app.asar.unpacked');
        ffmpegPath = (unpacked && fs.existsSync(unpacked)) ? unpacked
                   : (fp && fs.existsSync(fp)) ? fp
                   : 'ffmpeg';
    } catch { ffmpegPath = 'ffmpeg'; }

    const probe = spawn(ffmpegPath, ['-version'], { stdio: 'ignore' });
    probe.on('error', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.webContents.send('download:line',
                '⚠ FFmpeg not found — downloads will not work. Reinstall the app or report this.');
        }
    });
}

app.on('window-all-closed', () => {
    if (activeChild) try { activeChild.kill(); } catch {}
    if (process.platform !== 'darwin') app.quit();
});

// ─── IPC: settings ────────────────────────────────────────────────────────────

ipcMain.handle('settings:get', () => loadSettings());
ipcMain.handle('settings:save', (_e, s) => { saveSettings(s); return s; });

// "Forget" the download and library folders. TIDAL token is preserved.
// saveSettings clears the library scan cache because libraryFolder changes
// from "Y" to "" — its existing diff check handles that path.
ipcMain.handle('settings:reset', () => {
    const blanked = { downloadFolder: '', libraryFolder: '' };
    saveSettings(blanked);
    return blanked;
});

ipcMain.handle('settings:pick-folder', async () => {
    const opts = { properties: ['openDirectory'] };
    const saved = loadSettings().downloadFolder;
    if (saved) opts.defaultPath = saved;
    const result = await dialog.showOpenDialog(mainWindow, opts);
    return result.canceled ? null : result.filePaths[0];
});

ipcMain.handle('open-folder', (_e, p) => shell.openPath(p));

ipcMain.handle('library:status', async () => {
    const c = await lib.scanLibrary(sendScanProgress);
    return { count: c.entries.length, path: lib.LIBRARY_PATH };
});

ipcMain.handle('library:rescan', async () => {
    lib.rescanLibrary();
    const c = await lib.scanLibrary(sendScanProgress);
    if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
    return { ok: true, count: c.entries.length };
});

// ─── IPC: queue persistence ──────────────────────────────────────────────────
// Renderer reads on boot, writes on every user-driven queue mutation.
// Transient per-track state (dlStatus, dlPercent, selected) is stripped by
// the renderer before saving — those reset on each session.

ipcMain.handle('queue:get', () => {
    try { return JSON.parse(fs.readFileSync(QUEUE_PATH(), 'utf8')); }
    catch { return []; }
});

ipcMain.handle('queue:save', (_e, queue) => {
    try {
        fs.writeFileSync(QUEUE_PATH(), JSON.stringify(queue || [], null, 2));
        return { ok: true };
    } catch (e) {
        return { ok: false, error: e.message };
    }
});

// ─── IPC: token check (so the UI knows if auth is needed) ─────────────────────

ipcMain.handle('token:exists', () => {
    const tokenPath = process.env.TIDAL_TOKEN_PATH || path.join(__dirname, 'token.json');
    return fs.existsSync(tokenPath);
});
ipcMain.handle('token:run-auth', async () => {
    // Run the auth flow in-process. The old version spawned a child Electron
    // process with `cwd: __dirname`, but in a packaged build __dirname points
    // inside app.asar (a virtual filesystem) which CreateProcess can't chdir
    // into — spawn failed with ENOENT. Doing it in-process avoids the whole
    // class of spawn/asar issues.
    const { authenticate } = require('./tidal_auth_node');
    const send = (line) => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.webContents.send('auth:output', line + '\n');
        }
    };
    try {
        await authenticate({
            onLog: send,
            onVerificationUrl: (url) => {
                shell.openExternal(url);
                if (mainWindow && !mainWindow.isDestroyed()) {
                    mainWindow.webContents.send('auth:url', url);
                }
            },
            suppressBrowser: true,
        });
        return { ok: true };
    } catch (e) {
        send('ERROR: ' + e.message);
        return { ok: false, error: e.message };
    }
});

// ─── IPC: download ────────────────────────────────────────────────────────────

ipcMain.handle('download:cancel', () => {
    if (activeChild) {
        try { activeChild.kill(); } catch {}
        activeChild = null;
        return { ok: true };
    }
    return { ok: false };
});


// ─── IPC: resolve URL or search query → queue-ready tracks ──────────────────

ipcMain.handle('resolve:input', async (_e, { input }) => {
    resolverCancelled = false;
    try {
        const cred = lib.loadCred();
        const token = await lib.getToken(cred);
        const country = await lib.getCountryCode(cred);

        const parsed = lib.parseInputUrl(input);
        if (parsed) {
            const result = await lib.resolveUrlToTracks(input, token, country, {
                isCancelled: () => resolverCancelled,
            });
            if (resolverCancelled || result?.cancelled) {
                return { ok: false, cancelled: true };
            }
            return {
                ok: true,
                kind: 'url',
                tracks: result?.tracks || [],
                capped: !!result?.capped,
            };
        }
        // Not a URL — treat as search query
        const tracks = await lib.searchTracksForQueue(input, token, country, 10);
        if (resolverCancelled) return { ok: false, cancelled: true };
        return { ok: true, kind: 'search', tracks };
    } catch (e) {
        return { ok: false, error: e.message };
    }
});

ipcMain.handle('resolve:cancel', () => { resolverCancelled = true; return { ok: true }; });

// ─── IPC: preview audio (experimental waveform feature) ─────────────────────
// Fetches the raw audio bytes for a TIDAL track so the renderer can decode
// for waveform peaks + play via a blob-backed <audio> element. LOSSLESS
// quality (smaller than HI_RES) for faster fetch on preview. Supports both
// BTS (single direct URL) and DASH (parallel segment fetch + concat).

// Inline DASH manifest parser — sibling of tidal_download.js#parseManifest's
// DASH branch. Kept local rather than imported because tidal_download.js has
// a side-effecting main() at module scope that would run on require().
function _parseDashForPreview(decodedXml) {
    const xmlUnescape = s => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'");
    const baseUrlMatch = decodedXml.match(/<BaseURL[^>]*>(.*?)<\/BaseURL>/s);
    const baseUrl = baseUrlMatch ? xmlUnescape(baseUrlMatch[1].trim()) : '';

    if (!decodedXml.includes('SegmentTemplate') && baseUrl) {
        return { type: 'direct', url: baseUrl };
    }
    const initMatch = decodedXml.match(/initialization="([^"]+)"/);
    const mediaMatch = decodedXml.match(/media="([^"]+)"/);
    if (!initMatch || !mediaMatch) throw new Error('Could not parse DASH manifest');

    const segments = [];
    const startNumberMatch = decodedXml.match(/startNumber="(\d+)"/);
    let segNum = startNumberMatch ? parseInt(startNumberMatch[1], 10) : 1;
    const sElements = decodedXml.match(/<S\b[^>]*\/>/g) || [];
    for (const el of sElements) {
        const rMatch = el.match(/\br="(\d+)"/);
        const repeat = rMatch ? parseInt(rMatch[1], 10) : 0;
        for (let i = 0; i <= repeat; i++) segments.push(segNum++);
    }
    if (!segments.length) throw new Error('No segments found in DASH manifest');

    return {
        type: 'dash_segments',
        baseUrl,
        initTemplate: xmlUnescape(initMatch[1]),
        mediaTemplate: xmlUnescape(mediaMatch[1]),
        segments,
    };
}

// Download all DASH segments in parallel (concurrency 8) and concat into one
// fragmented-MP4 buffer the browser can play and decode via Web Audio.
async function _fetchDashAudioBuffer(parsed) {
    const initBuf = await lib.fetchBuffer(parsed.baseUrl + parsed.initTemplate, { timeout: 60_000, retries: 2 });
    const buffers = new Array(parsed.segments.length);
    let nextIdx = 0;
    const worker = async () => {
        while (true) {
            const i = nextIdx++;
            if (i >= parsed.segments.length) return;
            const segUrl = parsed.baseUrl + parsed.mediaTemplate.replace('$Number$', parsed.segments[i]);
            buffers[i] = await lib.fetchBuffer(segUrl, { timeout: 60_000, retries: 2 });
        }
    };
    await Promise.all(Array.from({ length: 8 }, worker));
    return Buffer.concat([initBuf, ...buffers]);
}

ipcMain.handle('preview:get-audio', async (_e, { tidalId }) => {
    try {
        const cred = lib.loadCred();
        const token = await lib.getToken(cred);
        const country = await lib.getCountryCode(cred);
        const playback = await lib.getPlaybackInfo(tidalId, token, 'LOSSLESS', country);
        const { manifestMimeType, manifest } = playback;
        const decoded = Buffer.from(manifest, 'base64').toString('utf8');

        // BTS / direct — JSON blob with a single signed URL
        if (manifestMimeType && manifestMimeType.startsWith('application/vnd.tidal.')) {
            const json = JSON.parse(decoded);
            if (json.encryptionType && json.encryptionType !== 'NONE') {
                return { ok: false, error: 'Track is DRM-encrypted' };
            }
            if (!json.urls || !json.urls.length) {
                return { ok: false, error: 'No stream URL in manifest' };
            }
            const audioBytes = await lib.fetchBuffer(json.urls[0], { timeout: 60_000, retries: 2 });
            return {
                ok: true,
                audioBytes,
                mimeType: json.mimeType || 'audio/flac',
            };
        }

        // DASH — segmented MPEG-DASH manifest (XML)
        if (manifestMimeType === 'application/dash+xml') {
            const parsed = _parseDashForPreview(decoded);
            if (parsed.type === 'direct') {
                const audioBytes = await lib.fetchBuffer(parsed.url, { timeout: 60_000, retries: 2 });
                return { ok: true, audioBytes, mimeType: 'audio/flac' };
            }
            const audioBytes = await _fetchDashAudioBuffer(parsed);
            // Segments concat'd form a fragmented MP4 (typically FLAC-in-MP4
            // for LOSSLESS, AAC-in-MP4 for non-lossless). Chromium plays both
            // via blob-URL on the <audio> element.
            return { ok: true, audioBytes, mimeType: 'audio/mp4' };
        }

        return { ok: false, error: `Unknown manifest type: ${manifestMimeType}` };
    } catch (e) {
        return { ok: false, error: e.message };
    }
});

ipcMain.handle('resolve:ocr-tracks', async (_e, { tracks }) => {
    // tracks: [{ title, artist }] from OCR — resolve each to a TIDAL match
    try {
        const cred = lib.loadCred();
        const token = await lib.getToken(cred);
        const country = await lib.getCountryCode(cred);

        const out = [];
        for (const t of tracks) {
            const query = `${t.title} ${t.artist}`;
            try {
                const json = await lib.searchTracks(query, token, country, 10);
                const items = json.items || [];
                const normalize = s => (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
                const wantT = normalize(t.title);
                const wantA = normalize(t.artist);
                const scored = items.map(it => {
                    const itT = normalize(it.title);
                    const itA = (it.artists || []).map(a => normalize(a.name)).join(' ');
                    let titleScore = 0;
                    if (itT === wantT) titleScore = 100;
                    else if (itT.startsWith(wantT) || wantT.startsWith(itT)) titleScore = 50;
                    else if (itT.includes(wantT) || wantT.includes(itT)) titleScore = 25;
                    const aTokens = wantA.split(' ').filter(x => x.length > 2);
                    const matched = aTokens.filter(x => itA.includes(x)).length;
                    const artistScore = aTokens.length ? Math.round((matched / aTokens.length) * 100) : 0;
                    return { it, titleScore, artistScore, total: titleScore + artistScore };
                }).filter(s => s.titleScore === 100 || (s.titleScore >= 25 && s.artistScore >= 50))
                  .sort((a, b) => b.total - a.total);
                const pick = scored[0]?.it;
                out.push({
                    title: pick?.title || t.title,
                    artist: pick ? (pick.artists || []).map(a => a.name).join(', ') : t.artist,
                    duration: pick?.duration || 0,
                    tidalId: pick?.id || null,
                    source: 'ocr',
                    matchMethod: pick ? 'search' : null,
                    notFound: !pick,
                    originalTitle: t.title,
                    originalArtist: t.artist,
                });
            } catch {
                out.push({ title: t.title, artist: t.artist, tidalId: null, source: 'ocr', notFound: true });
            }
        }
        await lib.enrichWithLibraryStatus(out);
        return { ok: true, tracks: out };
    } catch (e) {
        return { ok: false, error: e.message };
    }
});

// ─── IPC: bulk from a parsed tracklist (used by screenshot OCR) ──────────────

ipcMain.handle('bulk:start', async (_e, { tracks, outDir }) => {
    if (activeChild) return { ok: false, error: 'Another download is already running.' };
    if (!outDir) return { ok: false, error: 'No download folder configured. Pick one in Settings.' };

    // Write a temp tracklist json the helper script reads
    const listPath = path.join(app.getPath('userData'), 'pending-tracklist.json');
    fs.writeFileSync(listPath, JSON.stringify({ tracks, outDir }, null, 2));

    // No cwd — see note on the single-track spawn above; same asar path issue
    // would otherwise break this on packaged macOS builds.
    activeChild = spawn(process.execPath, [path.join(__dirname, 'bulk_runner.js'), listPath], {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: childEnv(),
    });

    // Intercept the `__TRACK_*__:` marker lines that bulk_runner + tidal_download
    // emit so we can route them to typed per-track IPC events. Everything else
    // gets forwarded into the activity log as before.
    const dispatchLine = (line) => {
        let m;
        if ((m = line.match(/^__TRACK_START__:(\d+)$/))) {
            mainWindow.webContents.send('bulk:track-start', { tidalId: Number(m[1]) });
            return;
        }
        if ((m = line.match(/^__TRACK_PROGRESS__:(\d+):(\d+)$/))) {
            mainWindow.webContents.send('bulk:track-progress', { tidalId: Number(m[1]), percent: Number(m[2]) });
            return;
        }
        if ((m = line.match(/^__TRACK_DONE__:(\d+):(\w+)$/))) {
            mainWindow.webContents.send('bulk:track-done', { tidalId: Number(m[1]), status: m[2] });
            return;
        }
        if (line.length) mainWindow.webContents.send('download:line', line);
    };

    const forward = (stream) => {
        let buf = '';
        stream.on('data', d => {
            buf += d.toString();
            const lines = buf.split(/\r?\n/);
            buf = lines.pop();
            for (const line of lines) dispatchLine(line);
        });
    };
    forward(activeChild.stdout);
    forward(activeChild.stderr);

    return new Promise((resolve) => {
        activeChild.on('close', code => {
            mainWindow.webContents.send('download:done', { code });
            activeChild = null;
            try { fs.unlinkSync(listPath); } catch {}
            resolve({ ok: code === 0, code });
        });
    });
});
