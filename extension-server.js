// Tiny localhost HTTP server that lets the Chrome extension push tracks into
// the app's queue. Listens on 127.0.0.1 only (no LAN exposure). Token auth
// via Authorization: Bearer <token> header. Token is generated on first run
// and persisted to <userData>/extension-token.txt.
//
// Endpoints:
//   GET  /ping       — health check, returns { ok, version, app }
//   POST /queue/add  — body { tracks: [{ title, artist, spotifyId? }] }
//                      requires Authorization: Bearer <token>
//                      returns { ok, queued: N }

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = 8273;  // not officially assigned, low collision risk
const HOST = '127.0.0.1';

let _token = null;
let _tokenPath = null;
let _server = null;
let _onTracksReceived = null;       // callback set by electron-main: (tracks) => Promise<void>
let _getManagedExtVersion = null;   // returns the on-disk version of the managed extension folder

function getTokenPath() {
    return _tokenPath;
}

function getToken() {
    return _token;
}

function getPort() {
    return PORT;
}

function generateToken() {
    return crypto.randomBytes(16).toString('hex');
}

function loadOrCreateToken(tokenPath) {
    _tokenPath = tokenPath;
    try {
        const existing = fs.readFileSync(tokenPath, 'utf8').trim();
        if (existing && /^[0-9a-f]{32}$/i.test(existing)) {
            _token = existing;
            return _token;
        }
    } catch { /* fall through to create */ }
    _token = generateToken();
    try {
        fs.mkdirSync(path.dirname(tokenPath), { recursive: true });
        fs.writeFileSync(tokenPath, _token, 'utf8');
    } catch (e) {
        console.warn('[extension-server] could not persist token:', e.message);
    }
    return _token;
}

function regenerateToken() {
    if (!_tokenPath) return null;
    _token = generateToken();
    try { fs.writeFileSync(_tokenPath, _token, 'utf8'); } catch {}
    return _token;
}

// CORS for the Chrome extension context. chrome-extension:// origins make
// preflight requests with non-simple headers (Authorization), so we have to
// respond to OPTIONS and echo back what they need.
function applyCors(req, res) {
    res.setHeader('Access-Control-Allow-Origin', req.headers.origin || '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.setHeader('Access-Control-Max-Age', '86400');
}

function checkAuth(req) {
    const h = req.headers['authorization'] || '';
    const m = h.match(/^Bearer\s+(.+)$/i);
    if (!m) return false;
    // Constant-time compare via Buffer for paranoia
    const got = Buffer.from(m[1]);
    const want = Buffer.from(_token || '');
    if (got.length !== want.length) return false;
    return crypto.timingSafeEqual(got, want);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let total = 0;
        req.on('data', (c) => {
            chunks.push(c);
            total += c.length;
            if (total > 256 * 1024) {  // 256 KB cap — plenty for a batch of tracks
                req.destroy();
                reject(new Error('Body too large'));
            }
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

function startServer({ tokenPath, version, onTracksReceived, getManagedExtensionVersion }) {
    loadOrCreateToken(tokenPath);
    _onTracksReceived = onTracksReceived;
    _getManagedExtVersion = getManagedExtensionVersion;

    _server = http.createServer(async (req, res) => {
        applyCors(req, res);

        if (req.method === 'OPTIONS') {
            res.writeHead(204);
            res.end();
            return;
        }

        // GET /ping — unauthenticated health check. Includes the on-disk
        // version of the managed extension folder so the popup can detect
        // a pending reload (app wrote new files but the extension hasn't
        // reloaded yet to pick them up).
        if (req.method === 'GET' && req.url === '/ping') {
            let managedExtensionVersion = null;
            try { managedExtensionVersion = _getManagedExtVersion ? _getManagedExtVersion() : null; }
            catch { managedExtensionVersion = null; }
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({
                ok: true,
                app: 'robogears-downloader',
                version,
                managedExtensionVersion,
            }));
            return;
        }

        // Every other endpoint requires auth.
        if (!checkAuth(req)) {
            res.writeHead(401, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ ok: false, error: 'Unauthorized — check token' }));
            return;
        }

        if (req.method === 'POST' && req.url === '/queue/add') {
            try {
                const raw = await readBody(req);
                const body = JSON.parse(raw);
                const tracks = Array.isArray(body.tracks) ? body.tracks : null;
                if (!tracks || !tracks.length) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ ok: false, error: 'No tracks in body' }));
                    return;
                }
                // Normalize each track — ensure title is a string. Artist
                // optional. spotifyId optional (carried for future use).
                const normalized = tracks.map(t => ({
                    title: String(t.title || '').trim(),
                    artist: String(t.artist || '').trim(),
                    spotifyId: t.spotifyId ? String(t.spotifyId).trim() : null,
                })).filter(t => t.title);

                if (!normalized.length) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ ok: false, error: 'No valid tracks' }));
                    return;
                }

                // Fire-and-forget — kick off the resolve in the main process.
                // The extension doesn't wait for the TIDAL match to finish; the
                // app updates its own queue UI as the resolve completes.
                if (_onTracksReceived) {
                    Promise.resolve(_onTracksReceived(normalized)).catch(() => {});
                }

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: true, queued: normalized.length }));
            } catch (e) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: false, error: e.message }));
            }
            return;
        }

        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: 'Not found' }));
    });

    return new Promise((resolve, reject) => {
        _server.once('error', reject);
        _server.listen(PORT, HOST, () => {
            console.log(`[extension-server] listening on http://${HOST}:${PORT}`);
            resolve({ port: PORT, host: HOST, token: _token });
        });
    });
}

function stopServer() {
    if (_server) {
        try { _server.close(); } catch {}
        _server = null;
    }
}

module.exports = { startServer, stopServer, getToken, getPort, regenerateToken, getTokenPath };
