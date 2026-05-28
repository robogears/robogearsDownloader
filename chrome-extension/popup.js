// Quick-access popup — paste the token from the toolbar without digging into
// chrome://extensions. Shows the current extension version + a status dot,
// and surfaces a "Reload" button when the on-disk extension version (managed
// by the desktop app) is newer than what's loaded in Chrome's memory.
//
// If the user has clicked Reload but the version still doesn't advance, the
// popup detects that (via chrome.storage.local.lastReloadAttempt — shared
// with background.js) and shows instructions for switching Load Unpacked
// to the managed folder.

const tokenInput    = document.getElementById('token-input');
const saveBtn       = document.getElementById('save-btn');
const statusEl      = document.getElementById('status');
const statusDot     = document.getElementById('status-dot');
const openOptions   = document.getElementById('open-options');
const extVersionEl  = document.getElementById('ext-version');
const reloadSection = document.getElementById('reload-section');
const reloadTitleEl = document.getElementById('reload-title');
const reloadSubEl   = document.getElementById('reload-sub');
const reloadBtn     = document.getElementById('reload-btn');
const reloadHintEl  = document.getElementById('reload-hint');

const DEFAULT_PORT = 8273;

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
        if (!res.ok) return null;
        const json = await res.json();
        if (json.app !== 'robogears-downloader') return null;
        return json;
    } catch { return null; }
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
    reloadSection.hidden = true;

    const ping = await pingApp(port);
    if (!ping) {
        setDot('idle');
        setStatus('App not running', 'error');
        return;
    }

    if (!data.token) {
        setDot('idle');
        setStatus('Paste a token to start');
        tokenInput.focus();
    } else {
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

    // Version mismatch detection — shown when on-disk is newer than memory.
    const localVersion = chrome.runtime.getManifest().version;
    const diskVersion = ping.managedExtensionVersion;
    const managedPath = ping.managedExtensionPath;
    if (!diskVersion || !isNewerVersion(diskVersion, localVersion)) return;

    // Did we recently try to reload to this version and not advance? If so,
    // Chrome's loaded from a folder that doesn't have the new files, and
    // chrome.runtime.reload() won't help — surface the fix.
    const stored = await new Promise(r => chrome.storage.local.get(['lastReloadAttempt'], r));
    const last = stored.lastReloadAttempt;
    const stuck = !!(last && last.version === diskVersion && Date.now() - last.at < 300_000);

    showReloadSection(localVersion, diskVersion, managedPath, stuck);
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

function showReloadSection(localVersion, diskVersion, managedPath, stuck) {
    reloadTitleEl.textContent = `Loaded v${localVersion} · on disk v${diskVersion}`;

    if (stuck) {
        reloadSubEl.textContent = "Reload didn't update the version — Chrome's loaded from a different folder.";
        reloadHintEl.innerHTML = `
            <strong>To fix:</strong>
            <ol>
                <li>Open <code>chrome://extensions</code></li>
                <li>Remove the robogears extension</li>
                <li>Click <strong>Load unpacked</strong> and pick the managed folder:</li>
            </ol>
            <div class="path-row">
                <code id="managed-path">${managedPath || '(unknown)'}</code>
                <button id="copy-path-btn">Copy</button>
            </div>
        `;
        reloadHintEl.hidden = false;
        reloadBtn.textContent = 'Try reload';

        const copyBtn = reloadHintEl.querySelector('#copy-path-btn');
        if (copyBtn && managedPath) {
            copyBtn.addEventListener('click', async () => {
                try {
                    await navigator.clipboard.writeText(managedPath);
                    copyBtn.textContent = 'Copied ✓';
                    setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1500);
                } catch {}
            });
        }
    } else {
        reloadSubEl.textContent = 'Click Reload to apply the new version.';
        reloadHintEl.hidden = true;
        reloadBtn.textContent = 'Reload';
    }

    reloadBtn.disabled = false;
    reloadBtn.onclick = handleReloadClick;
    reloadSection.hidden = false;
}

async function handleReloadClick() {
    reloadBtn.disabled = true;
    reloadBtn.textContent = 'Reloading…';
    const data = await getStored();
    const port = data.port || DEFAULT_PORT;
    const ping = await pingApp(port);
    if (ping?.managedExtensionVersion) {
        await new Promise(r => chrome.storage.local.set({
            lastReloadAttempt: { at: Date.now(), version: ping.managedExtensionVersion }
        }, r));
    }
    setTimeout(() => chrome.runtime.reload(), 250);
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
