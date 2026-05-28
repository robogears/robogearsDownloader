// Extension options page — collects the localhost URL + token from the user
// and persists them via chrome.storage.local. Content script reads the same
// keys (and gets reactive updates via chrome.storage.onChanged).

const portInput = document.getElementById('port-input');
const tokenInput = document.getElementById('token-input');
const saveBtn = document.getElementById('save-btn');
const testBtn = document.getElementById('test-btn');
const statusEl = document.getElementById('status');

function setStatus(text, kind) {
    statusEl.textContent = text || '';
    statusEl.className = 'status' + (kind ? ' ' + kind : '');
}

// Extract just the port from whatever the user pasted into the URL field.
// Default to 8273 if nothing looks numeric.
function parsePort(value) {
    const m = String(value || '').match(/:(\d{2,5})/);
    if (m) return parseInt(m[1], 10);
    const n = parseInt(value, 10);
    if (!isNaN(n) && n > 0 && n < 65536) return n;
    return 8273;
}

function load() {
    chrome.storage.local.get(['port', 'token'], (data) => {
        const port = data.port || 8273;
        portInput.value = `http://127.0.0.1:${port}`;
        tokenInput.value = data.token || '';
    });
}

saveBtn.addEventListener('click', () => {
    const port = parsePort(portInput.value);
    const token = (tokenInput.value || '').trim();
    chrome.storage.local.set({ port, token }, () => {
        setStatus('Saved.', 'ok');
        setTimeout(() => setStatus('', null), 1500);
    });
});

testBtn.addEventListener('click', async () => {
    const port = parsePort(portInput.value);
    const token = (tokenInput.value || '').trim();
    setStatus('Testing…');
    // /ping is unauthenticated so we can check the server's up first.
    try {
        const ping = await fetch(`http://127.0.0.1:${port}/ping`);
        if (!ping.ok) throw new Error(`HTTP ${ping.status}`);
        const pingJson = await ping.json();
        if (pingJson.app !== 'robogears-downloader') throw new Error('not our app on that port');
    } catch (e) {
        setStatus(`App not reachable: ${e.message}`, 'error');
        return;
    }
    // Then verify the token via an authenticated zero-track POST.
    try {
        const r = await fetch(`http://127.0.0.1:${port}/queue/add`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${token}`,
            },
            body: JSON.stringify({ tracks: [] }),
        });
        if (r.status === 401) {
            setStatus('App is running but token is wrong.', 'error');
            return;
        }
        // 400 ("No tracks in body") is the expected response — means auth passed.
        if (r.status === 400 || r.ok) {
            setStatus('Connected — extension is wired up correctly.', 'ok');
            return;
        }
        setStatus(`Unexpected: HTTP ${r.status}`, 'error');
    } catch (e) {
        setStatus(`Network error: ${e.message}`, 'error');
    }
});

load();
