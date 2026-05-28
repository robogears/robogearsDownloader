// Quick-access popup — paste the token from the toolbar without digging into
// chrome://extensions. Also surfaces the current extension version and
// detects newer versions on GitHub; the "Update" button triggers the desktop
// app to download fresh files into the managed extension folder.

const tokenInput     = document.getElementById('token-input');
const saveBtn        = document.getElementById('save-btn');
const statusEl       = document.getElementById('status');
const statusDot      = document.getElementById('status-dot');
const openOptions    = document.getElementById('open-options');
const extVersionEl   = document.getElementById('ext-version');
const updateSection  = document.getElementById('update-section');
const updateLabelEl  = document.getElementById('update-label');
const updateBtn      = document.getElementById('update-btn');
const updateHintEl   = document.getElementById('update-hint');

const DEFAULT_PORT = 8273;
const REPO_PATH = 'robogears/robogearsDownloader';

// ─── Token / app connection ─────────────────────────────────────────────────

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

// Verify by sending an empty-tracks POST — the server returns 400 "No tracks
// in body" when auth passes, which proves the token is right without actually
// queueing anything. 401 means token rejected.
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

// ─── Version + update detection ─────────────────────────────────────────────

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

async function checkForExtensionUpdate() {
    const localVersion = chrome.runtime.getManifest().version;
    extVersionEl.textContent = `v${localVersion}`;
    try {
        const r = await fetch(
            `https://api.github.com/repos/${REPO_PATH}/contents/chrome-extension/manifest.json?ref=main`,
            { headers: { 'Accept': 'application/vnd.github+json' }, cache: 'no-store' }
        );
        if (!r.ok) return;
        const j = await r.json();
        const remoteManifest = JSON.parse(atob(j.content));
        const remoteVersion = remoteManifest.version;
        if (isNewerVersion(remoteVersion, localVersion)) {
            updateLabelEl.innerHTML = `Update available: <strong>v${remoteVersion}</strong>`;
            updateSection.hidden = false;
        }
    } catch {
        // Silent — no nag if GitHub's unreachable (rate-limit, offline, etc.)
    }
}

async function triggerExtensionUpdate() {
    const data = await getStored();
    const port = data.port || DEFAULT_PORT;
    if (!data.token) {
        updateHintEl.textContent = 'Save your token first.';
        updateHintEl.hidden = false;
        return;
    }
    updateBtn.disabled = true;
    updateBtn.textContent = 'Updating…';
    updateHintEl.hidden = true;

    try {
        const r = await fetch(`http://127.0.0.1:${port}/extension/update-self`, {
            method: 'POST',
            headers: { 'Authorization': `Bearer ${data.token}` },
        });
        const json = await r.json().catch(() => ({}));
        if (!r.ok || !json.ok) {
            updateBtn.disabled = false;
            updateBtn.textContent = 'Retry update';
            updateHintEl.textContent = json.error || `HTTP ${r.status}`;
            updateHintEl.hidden = false;
            return;
        }
        updateBtn.textContent = `v${json.version} downloaded`;
        updateBtn.classList.add('done');
        updateHintEl.innerHTML = `Files written. <strong>Click reload at chrome://extensions</strong> to apply.`;
        updateHintEl.hidden = false;
    } catch (e) {
        updateBtn.disabled = false;
        updateBtn.textContent = 'Retry update';
        updateHintEl.textContent = `App unreachable: ${e.message}`;
        updateHintEl.hidden = false;
    }
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

updateBtn.addEventListener('click', triggerExtensionUpdate);

refresh();
checkForExtensionUpdate();
