// Quick-access popup — paste the token from the toolbar without digging into
// chrome://extensions. Shows the current extension version + a status dot
// for the localhost bridge.
//
// Extension updates are handled entirely by the desktop app: bundled via
// electron-builder, written to the managed folder on app launch, and
// auto-reloaded by background.js when it notices the on-disk version doesn't
// match what's loaded in memory. Nothing in the popup needs to surface
// "update available" — by the time the user opens the popup, the reload has
// already happened (or will happen within ~1 minute via the alarm).

const tokenInput   = document.getElementById('token-input');
const saveBtn      = document.getElementById('save-btn');
const statusEl     = document.getElementById('status');
const statusDot    = document.getElementById('status-dot');
const openOptions  = document.getElementById('open-options');
const extVersionEl = document.getElementById('ext-version');

const DEFAULT_PORT = 8273;

function setStatus(text, kind) {
    statusEl.textContent = text || '';
    statusEl.className = 'status' + (kind ? ' ' + kind : '');
}

function setDot(state) {
    statusDot.classList.remove('connected', 'unauth');
    if (state === 'connected') {
        statusDot.classList.add('connected');
        statusDot.title = 'Connected';
    } else if (state === 'unauth') {
        statusDot.classList.add('unauth');
        statusDot.title = 'App is running but token is wrong';
    } else {
        statusDot.title = 'App not running on this port';
    }
}

function getStored() {
    return new Promise(r => chrome.storage.local.get(['port', 'token'], r));
}
function saveStored(patch) {
    return new Promise(r => chrome.storage.local.set(patch, r));
}

async function pingApp(port) {
    try {
        const res = await fetch(`http://127.0.0.1:${port}/ping`, { cache: 'no-store' });
        if (!res.ok) return false;
        const json = await res.json();
        return json.app === 'robogears-downloader';
    } catch { return false; }
}

async function verifyToken(port, token) {
    if (!token) return 'no-token';
    try {
        const res = await fetch(`http://127.0.0.1:${port}/queue/add`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${token}`,
            },
            body: JSON.stringify({ tracks: [] }),
        });
        if (res.status === 401) return 'bad-token';
        if (res.status === 400 || res.ok) return 'ok';
        return 'error';
    } catch { return 'unreachable'; }
}

async function refresh() {
    const data = await getStored();
    const port = data.port || DEFAULT_PORT;
    tokenInput.value = data.token || '';
    extVersionEl.textContent = `v${chrome.runtime.getManifest().version}`;

    // Nudge the background worker to check — gives a faster reload if the
    // app already wrote new ext files but the alarm hasn't fired yet.
    try { chrome.runtime.sendMessage({ action: 'check-pending-reload' }); } catch {}

    setStatus('Checking…');
    setDot('idle');

    const reachable = await pingApp(port);
    if (!reachable) {
        setDot('idle');
        setStatus('App not running', 'error');
        return;
    }

    if (!data.token) {
        setDot('idle');
        setStatus('Paste a token to start');
        tokenInput.focus();
        return;
    }

    const result = await verifyToken(port, data.token);
    if (result === 'ok') {
        setDot('connected');
        setStatus('Connected', 'ok');
    } else if (result === 'bad-token') {
        setDot('unauth');
        setStatus('Token rejected — paste again', 'error');
        tokenInput.focus();
        tokenInput.select();
    } else {
        setDot('idle');
        setStatus('Check failed', 'error');
    }
}

async function save() {
    const token = tokenInput.value.trim();
    const data = await getStored();
    const port = data.port || DEFAULT_PORT;

    saveBtn.disabled = true;
    setStatus('Saving…');
    await saveStored({ token });

    if (!token) {
        setDot('idle');
        setStatus('Cleared');
        saveBtn.disabled = false;
        return;
    }

    const result = await verifyToken(port, token);
    if (result === 'ok') {
        setDot('connected');
        setStatus('Saved & connected ✓', 'ok');
    } else if (result === 'bad-token') {
        setDot('unauth');
        setStatus('Saved — but token rejected', 'error');
    } else if (result === 'unreachable') {
        setDot('idle');
        setStatus('Saved — app not running', 'error');
    } else {
        setDot('idle');
        setStatus('Saved — connection check failed', 'error');
    }
    saveBtn.disabled = false;
}

// ─── Wire-up ─────────────────────────────────────────────────────────────────

saveBtn.addEventListener('click', save);
tokenInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') save();
});

openOptions.addEventListener('click', (e) => {
    e.preventDefault();
    chrome.runtime.openOptionsPage();
});

refresh();
