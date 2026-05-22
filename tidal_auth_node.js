// TIDAL device authorization flow (OAuth device-code).
// Usage: node tidal_auth_node.js
// Opens a browser, user logs in + clicks Allow, token.json is written.

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

async function main() {
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
        console.error('Device authorization failed:', authRes.status, authRes.body);
        process.exit(1);
    }

    const authJson = JSON.parse(authRes.body);
    const { verificationUriComplete, deviceCode, interval = 5 } = authJson;

    // Marker line so electron-main can intercept and open via shell.openExternal
    // (the most reliable cross-platform browser-open API available to us).
    // Plain CLI usage falls through to the platform-specific fallback below.
    console.log('__OPEN_BROWSER__:' + verificationUriComplete);

    console.log('\n=== TIDAL Login ===');
    console.log('Open this URL in your browser and log in:');
    console.log('\n  ' + verificationUriComplete + '\n');

    // Fallback browser-open for CLI users. Skipped when spawned by electron-main
    // (it sets TIDAL_AUTH_SUPPRESS_BROWSER=1 because it already opened the URL),
    // so the user doesn't end up with two browser tabs.
    if (!process.env.TIDAL_AUTH_SUPPRESS_BROWSER) {
        try {
            const { spawn } = require('child_process');
            const opener =
                process.platform === 'win32'  ? { cmd: 'cmd',      args: ['/c', 'start', '""', verificationUriComplete] }
              : process.platform === 'darwin' ? { cmd: 'open',     args: [verificationUriComplete] }
              :                                 { cmd: 'xdg-open', args: [verificationUriComplete] };
            spawn(opener.cmd, opener.args, { detached: true, stdio: 'ignore' }).unref();
            console.log('(Browser should have opened automatically)');
        } catch { /* user can still copy the URL manually */ }
    }

    console.log('Waiting for authorization...');

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
            console.log('\nAuthorization successful! token.json saved.');
            console.log('User ID:', entry.userID);
            if (entry.countryCode) console.log('Country:', entry.countryCode);
            break;
        } else if (pollRes.status === 400) {
            const err = JSON.parse(pollRes.body);
            if (err.error === 'authorization_pending') continue;
            console.error('Auth error:', err);
            process.exit(1);
        } else {
            console.error('Unexpected poll response:', pollRes.status, pollRes.body);
            process.exit(1);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
