// Background service worker.
//
// Two responsibilities:
//   1. Open the options page on first install (the popup is the main UI; the
//      full options page is the "more settings" path).
//   2. Watch for a pending extension update — the desktop app bundles new
//      extension files into the managed folder on its own launch, but Chrome
//      doesn't know to reload the loaded-unpacked extension. We poll the
//      app's /ping endpoint (which returns managedExtensionVersion) and call
//      chrome.runtime.reload() when disk > memory. Triggered on browser
//      startup, on extension install/update, every minute via chrome.alarms,
//      and whenever a Spotify page loads (the content script nudges us, so
//      browsing Spotify after launching the app gives a near-instant reload).

const DEFAULT_PORT = 8273;

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

async function checkAndReloadIfPending() {
    const data = await new Promise(r => chrome.storage.local.get(['port'], r));
    const port = data.port || DEFAULT_PORT;
    try {
        const res = await fetch(`http://127.0.0.1:${port}/ping`, { cache: 'no-store' });
        if (!res.ok) return;
        const json = await res.json();
        if (json.app !== 'robogears-downloader') return;
        const diskVersion = json.managedExtensionVersion;
        const memoryVersion = chrome.runtime.getManifest().version;
        if (diskVersion && isNewerVersion(diskVersion, memoryVersion)) {
            chrome.runtime.reload();
        }
    } catch { /* app not running — try again next tick */ }
}

// Browser startup
chrome.runtime.onStartup.addListener(() => {
    checkAndReloadIfPending();
});

// Extension install / update — also open the options page on first install
chrome.runtime.onInstalled.addListener((details) => {
    if (details.reason === 'install') {
        chrome.runtime.openOptionsPage();
    }
    checkAndReloadIfPending();
});

// Periodic check — chrome.alarms wakes the service worker even if it's been
// sleeping. 1 minute is the trade-off between responsiveness and quiet.
chrome.alarms.create('check-pending-reload', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'check-pending-reload') checkAndReloadIfPending();
});

// Listen for nudges from the content script (Spotify page loaded) and the
// popup (user opened it). Both are good moments to re-check.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg && msg.action === 'check-pending-reload') {
        checkAndReloadIfPending();
        sendResponse({ ok: true });
        return true;
    }
    if (msg && msg.action === 'open-options') {
        chrome.runtime.openOptionsPage();
        sendResponse({ ok: true });
        return true;
    }
    return false;
});
