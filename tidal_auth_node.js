// TIDAL device authorization flow (OAuth device-code).
//
// Can be used two ways:
//   1. CLI: `node tidal_auth_node.js` — logs to stdout, opens the browser
//      itself, writes token.json on success.
//   2. In-process: `require('./tidal_auth_node').authenticate({ ... })` from
//      electron-main. This is the safer path for packaged builds because the
//      previous spawn-based approach failed with ENOENT — cwd resolved into
//      app.asar's virtual filesystem which CreateProcess can't chdir into.

const https = require('https');
const fs = require('fs');
const path = require('path');

const TOKEN_FILE = process.env.TIDAL_TOKEN_PATH || path.join(__dirname, 'token.json');

const AUTH_CLIENT_ID     = Buffer.from('ZlgySnhkbW50WldLMGl4VA==',     'base64').toString('latin1');
const AUTH_CLIENT_SECRET = Buffer.from('MU5tNUFmREFqeHJnSkZKYktOV0xlQXlLR1ZHbUlOdVhQUExIVlhBdnhBZz0=', 'base64').toString('latin1');
const REQUEST_CLIENT_ID  = Buffer.from('bHczdlI2R0UxdnROQnNqdg==',     'base64').toString('latin1');
const REQUEST_CLIENT_SECRET = Buffer.from('WTh0SXBxS0p4czlCRUl3WXIwSTliU2JNV0Rzb2dYSng5TGFOM21DSHdENCUzRA==', 'base64').toString('latin1');

function httpsRequest(options, body) {
    return new Promise((resolve, reject) => {
        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => resolve({ status: res.statusCode, body: data }));
        });
        req.on('error', reject);
        if (body) req.write(body);
        req.end();
    });
}

function formEncode(obj) {
    return Object.entries(obj).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
}

function sleep(ms) {
    return new Promise(r => setTimeout(r, ms));
}

function loadTokens() {
    if (fs.existsSync(TOKEN_FILE)) {
        try {
            const data = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
            return Array.isArray(data) ? data : [data];
        } catch { return []; }
    }
    return [];
}

function saveToken(entry) {
    const tokens = loadTokens().filter(t =>
        !(t.client_ID === entry.client_ID && t.refresh_token === entry.refresh_token)
    );
    tokens.push(entry);
    fs.writeFileSync(TOKEN_FILE, JSON.stringify(tokens, null, 4));
}

/**
 * Run the full TIDAL OAuth device-code flow.
 *
 * @param {Object} [opts]
 * @param {(line: string) => void} [opts.onLog] - called once per status line
 *        (defaults to console.log for CLI use).
 * @param {(url: string) => void} [opts.onVerificationUrl] - fires once with
 *        the TIDAL verification URL as soon as it's known, so callers can
 *        open it via shell.openExternal or similar.
 * @param {boolean} [opts.suppressBrowser] - when true, skip the
 *        platform-specific browser-open fallback (electron-main sets this
 *        because it handles opening via shell.openExternal).
 * @returns {Promise<Object>} the saved token entry.
 */
async function authenticate({ onLog = console.log, onVerificationUrl = null, suppressBrowser = false } = {}) {
    const headers = {
        'User-Agent': 'okhttp/5.3.2',
        'Accept': 'application/json',
        'Accept-Encoding': 'identity',
        'Accept-Language': 'en-US,en;q=0.9',
        'X-Platform': 'android',
        'Content-Type': 'application/x-www-form-urlencoded',
    };

    // Step 1: request device code
    const authBody = formEncode({ client_id: AUTH_CLIENT_ID, scope: 'r_usr+w_usr+w_sub' });
    const authRes = await httpsRequest({
        hostname: 'auth.tidal.com',
        path: '/v1/oauth2/device_authorization',
        method: 'POST',
        headers: { ...headers, 'Content-Length': Buffer.byteLength(authBody) },
    }, authBody);

    if (authRes.status !== 200) {
        throw new Error(`Device authorization failed: ${authRes.status} ${authRes.body}`);
    }

    const authJson = JSON.parse(authRes.body);
    const { verificationUriComplete, deviceCode, interval = 5 } = authJson;

    if (onVerificationUrl) onVerificationUrl(verificationUriComplete);

    onLog('=== TIDAL Login ===');
    onLog('Open this URL in your browser and log in:');
    onLog('');
    onLog('  ' + verificationUriComplete);
    onLog('');

    if (!suppressBrowser) {
        try {
            const { spawn } = require('child_process');
            const opener =
                process.platform === 'win32'  ? { cmd: 'cmd',      args: ['/c', 'start', '""', verificationUriComplete] }
              : process.platform === 'darwin' ? { cmd: 'open',     args: [verificationUriComplete] }
              :                                 { cmd: 'xdg-open', args: [verificationUriComplete] };
            spawn(opener.cmd, opener.args, { detached: true, stdio: 'ignore' }).unref();
            onLog('(Browser should have opened automatically)');
        } catch { /* user can still copy the URL manually */ }
    }

    onLog('Waiting for authorization...');

    // Step 2: poll for token
    const pollBody = formEncode({
        client_id: AUTH_CLIENT_ID,
        device_code: deviceCode,
        grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
        scope: 'r_usr+w_usr+w_sub',
    });

    const basicAuth = Buffer.from(`${AUTH_CLIENT_ID}:${AUTH_CLIENT_SECRET}`).toString('base64');

    while (true) {
        await sleep(interval * 1000);
        const pollRes = await httpsRequest({
            hostname: 'auth.tidal.com',
            path: '/v1/oauth2/token',
            method: 'POST',
            headers: {
                ...headers,
                'Authorization': `Basic ${basicAuth}`,
                'Content-Length': Buffer.byteLength(pollBody),
            },
        }, pollBody);

        if (pollRes.status === 200) {
            const tokenJson = JSON.parse(pollRes.body);
            const entry = {
                access_token:  tokenJson.access_token,
                refresh_token: tokenJson.refresh_token,
                userID:        tokenJson.user?.userId,
                countryCode:   tokenJson.user?.countryCode,
                expires_at:    Date.now() + (tokenJson.expires_in || 3600) * 1000 - 60_000,
                client_ID:     REQUEST_CLIENT_ID,
                client_secret: REQUEST_CLIENT_SECRET,
            };
            saveToken(entry);
            onLog('');
            onLog('Authorization successful! token.json saved.');
            onLog('User ID: ' + entry.userID);
            if (entry.countryCode) onLog('Country: ' + entry.countryCode);
            return entry;
        } else if (pollRes.status === 400) {
            const err = JSON.parse(pollRes.body);
            if (err.error === 'authorization_pending') continue;
            throw new Error('Auth error: ' + JSON.stringify(err));
        } else {
            throw new Error(`Unexpected poll response: ${pollRes.status} ${pollRes.body}`);
        }
    }
}

module.exports = { authenticate };

// CLI entry point — only run when executed directly, not when required as a module
if (require.main === module) {
    authenticate().catch(e => { console.error(e); process.exit(1); });
}
