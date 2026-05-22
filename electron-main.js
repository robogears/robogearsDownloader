// Electron main process for the TIDAL Downloader GUI
const { app, BrowserWindow, ipcMain, dialog, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');

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
    mainWindow = new BrowserWindow({
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
    });
    mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
    // mainWindow.webContents.openDevTools({ mode: 'detach' });
}

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
ipcMain.handle('token:run-auth', () => {
    return new Promise((resolve) => {
        const child = spawn(process.execPath, [path.join(__dirname, 'tidal_auth_node.js')], {
            cwd: __dirname,
            detached: false,
            stdio: ['ignore', 'pipe', 'pipe'],
            env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
        });
        let output = '';
        child.stdout.on('data', d => {
            const s = d.toString();
            output += s;
            mainWindow.webContents.send('auth:output', s);
        });
        child.stderr.on('data', d => mainWindow.webContents.send('auth:output', d.toString()));
        child.on('close', code => resolve({ ok: code === 0, output }));
    });
});

// ─── IPC: download ────────────────────────────────────────────────────────────

ipcMain.handle('download:start', async (_e, { input, outDir }) => {
    if (activeChild) return { ok: false, error: 'Another download is already running.' };

    const args = [path.join(__dirname, 'tidal_download.js'), input];
    if (outDir) args.push(outDir);

    activeChild = spawn(process.execPath, args, {
        cwd: __dirname,
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

    activeChild = spawn(process.execPath, [path.join(__dirname, 'bulk_runner.js'), listPath], {
        cwd: __dirname,
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
