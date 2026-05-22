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
        lib.scanLibrary().then(c => {
            if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
        }).catch(() => {});
    }
}

let mainWindow = null;
let activeChild = null;

function childEnv() {
    const s = loadSettings();
    return {
        ...process.env,
        ELECTRON_RUN_AS_NODE: '1',
        FORCE_COLOR: '0',
        TIDAL_LIBRARY_FOLDER: s.libraryFolder || '',
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
    const wantedSubstr = process.platform === 'darwin' ? 'mac-arm64.zip'
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

// ─── Self-install (Windows portable only) ─────────────────────────────────────
// process.env.PORTABLE_EXECUTABLE_FILE is set by electron-builder's portable
// launcher to the absolute path of the .exe the user double-clicked (which
// is what we need to replace — process.execPath inside the running app
// points to a temp extracted copy of the Electron binary, not the file
// the user actually has on disk).
function canSelfInstall() {
    return process.platform === 'win32' && !!process.env.PORTABLE_EXECUTABLE_FILE;
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

ipcMain.handle('update:download', async (_e, url) => {
    if (!canSelfInstall()) return { ok: false, error: 'Self-install not supported on this build' };
    if (typeof url !== 'string' || !/^https?:\/\//.test(url)) return { ok: false, error: 'Invalid URL' };
    const destPath = path.join(os.tmpdir(), `robogears-downloader-${Date.now()}.exe`);
    try {
        await downloadToFile(url, destPath, (got, total) => {
            if (mainWindow && !mainWindow.isDestroyed()) {
                mainWindow.webContents.send('update:download-progress', { downloaded: got, total });
            }
        });
        // Remember the path for the apply step
        global._pendingUpdatePath = destPath;
        return { ok: true, path: destPath };
    } catch (e) {
        try { fs.unlinkSync(destPath); } catch {}
        return { ok: false, error: e.message };
    }
});

ipcMain.handle('update:apply', () => {
    if (!canSelfInstall()) return { ok: false, error: 'Self-install not supported on this build' };
    const launcher = process.env.PORTABLE_EXECUTABLE_FILE;
    const newExe = global._pendingUpdatePath;
    if (!launcher || !newExe || !fs.existsSync(newExe)) {
        return { ok: false, error: 'No downloaded update available' };
    }
    // Detached .cmd that polls until the locked .exe can be overwritten, then
    // swaps it and relaunches. Self-deletes when done. Up to 30 retries (~30s).
    const scriptPath = path.join(os.tmpdir(), `robogears-update-${Date.now()}.cmd`);
    const script = [
        '@echo off',
        'setlocal',
        `set "LAUNCHER=${launcher}"`,
        `set "NEW=${newExe}"`,
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
    // Give the spawn a beat to take hold before the parent dies
    setTimeout(() => app.quit(), 200);
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
        lib.scanLibrary().then(c => {
            if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
        }).catch(() => {});
    }

    // Check GitHub releases for a newer version and surface it in the activity
    // log. Renderer handles the race if it isn't ready yet (queues the payload).
    checkForUpdatesAndNotify().catch(() => {});

    app.on('activate', () => {
        if (BrowserWindow.getAllWindows().length === 0) createWindow();
    });
});

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
    const c = await lib.scanLibrary();
    return { count: c.entries.length, path: lib.LIBRARY_PATH };
});

ipcMain.handle('library:rescan', async () => {
    lib.rescanLibrary();
    const c = await lib.scanLibrary();
    if (mainWindow) mainWindow.webContents.send('library:scanned', { count: c.entries.length });
    return { ok: true, count: c.entries.length };
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

ipcMain.handle('download:start', async (_e, { input, outDir }) => {
    if (activeChild) return { ok: false, error: 'Another download is already running.' };

    const args = [path.join(__dirname, 'tidal_download.js'), input];
    if (outDir) args.push(outDir);

    // No cwd: in packaged builds __dirname is an asar virtual path, and
    // posix_spawn/CreateProcess can't chdir into it (same ENOENT issue we hit
    // with the auth flow). Default cwd is fine — scripts use __dirname or
    // absolute paths, never cwd-relative.
    activeChild = spawn(process.execPath, args, {
        stdio: ['pipe', 'pipe', 'pipe'],
        env: childEnv(),
    });

    // Stream output line-by-line to the renderer
    const forward = (stream) => {
        let buf = '';
        stream.on('data', d => {
            buf += d.toString();
            const lines = buf.split(/\r?\n/);
            buf = lines.pop();
            for (const line of lines) {
                if (line.length) mainWindow.webContents.send('download:line', line);
            }
        });
        stream.on('end', () => {
            if (buf.length) mainWindow.webContents.send('download:line', buf);
        });
    };
    forward(activeChild.stdout);
    forward(activeChild.stderr);

    return new Promise((resolve) => {
        activeChild.on('close', code => {
            mainWindow.webContents.send('download:done', { code });
            activeChild = null;
            resolve({ ok: code === 0, code });
        });
        activeChild.on('error', err => {
            mainWindow.webContents.send('download:done', { code: -1, error: err.message });
            activeChild = null;
            resolve({ ok: false, error: err.message });
        });
    });
});

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
    try {
        const cred = lib.loadCred();
        const token = await lib.getToken(cred);
        const country = await lib.getCountryCode(cred);

        const parsed = lib.parseInputUrl(input);
        if (parsed) {
            const tracks = await lib.resolveUrlToTracks(input, token, country);
            return { ok: true, kind: 'url', tracks: tracks || [] };
        }
        // Not a URL — treat as search query
        const tracks = await lib.searchTracksForQueue(input, token, country, 10);
        return { ok: true, kind: 'search', tracks };
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

    const forward = (stream) => {
        let buf = '';
        stream.on('data', d => {
            buf += d.toString();
            const lines = buf.split(/\r?\n/);
            buf = lines.pop();
            for (const line of lines) {
                if (line.length) mainWindow.webContents.send('download:line', line);
            }
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
