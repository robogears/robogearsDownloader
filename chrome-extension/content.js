// robogears Downloader — Spotify integration content script.
//
// Walks the DOM looking for tracklist rows on open.spotify.com pages and
// injects an "+ robogears" button into each one. Click sends title + artist +
// Spotify track ID to the desktop app's localhost HTTP server, which resolves
// the track on TIDAL and adds it to the queue.
//
// The Spotify web player virtual-scrolls rows in and out, so we run a
// MutationObserver against the page body and re-scan on changes. De-dupes
// via a data attribute we stamp onto each row we've processed.

const ROW_SELECTOR = '[data-testid="tracklist-row"]';
const BTN_CLASS = 'robogears-add-btn';

let _config = { port: 8273, token: '' };

// Load saved config (port + token) from extension storage. The user pastes
// these in via the options page; if missing, the button still appears but
// surfaces a "set token first" message instead of trying to fetch.
function loadConfig() {
    return new Promise((resolve) => {
        chrome.storage.local.get(['port', 'token'], (data) => {
            if (data.port) _config.port = parseInt(data.port, 10) || 8273;
            if (data.token) _config.token = String(data.token);
            resolve(_config);
        });
    });
}

chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    if (changes.port?.newValue) _config.port = parseInt(changes.port.newValue, 10) || 8273;
    if ('token' in changes) _config.token = String(changes.token.newValue || '');
});

// Pull title, artist(s), and Spotify track ID out of a row element.
function extractTrackFromRow(row) {
    // Title: the first link inside the row that points at /track/<id>
    const titleLink = row.querySelector('a[href*="/track/"]');
    if (!titleLink) return null;
    const title = titleLink.textContent.trim();
    if (!title) return null;
    const m = titleLink.getAttribute('href').match(/\/track\/([a-zA-Z0-9]+)/);
    const spotifyId = m ? m[1] : null;

    // Artist(s): all links inside the row that point at /artist/<id>
    const artistLinks = row.querySelectorAll('a[href*="/artist/"]');
    const artist = Array.from(artistLinks).map(a => a.textContent.trim()).filter(Boolean).join(', ');

    return { title, artist, spotifyId };
}

// Post a track (or batch) to the local app server.
async function pushTracksToApp(tracks) {
    if (!_config.token) {
        // Tell the user where the popup lives — clicking the toolbar icon
        // opens it. (We can't programmatically open a popup from a content
        // script in MV3, so a clear instruction is the best we can do.)
        showToast('Click the robogears icon in the toolbar and paste your token.', 'error');
        return false;
    }
    try {
        const res = await fetch(`http://127.0.0.1:${_config.port}/queue/add`, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${_config.token}`,
            },
            body: JSON.stringify({ tracks }),
        });
        if (!res.ok) {
            const errBody = await res.json().catch(() => ({}));
            showToast(errBody.error || `HTTP ${res.status}`, 'error');
            return false;
        }
        const json = await res.json();
        showToast(`Added ${json.queued} to robogears`, 'ok');
        return true;
    } catch (e) {
        showToast(`App unreachable — is robogears Downloader running?`, 'error');
        return false;
    }
}

// Tiny toast at the bottom-right of the page.
let _toastEl = null;
let _toastTimer = null;
function showToast(text, kind = 'ok') {
    if (!_toastEl) {
        _toastEl = document.createElement('div');
        _toastEl.className = 'robogears-toast';
        document.body.appendChild(_toastEl);
    }
    _toastEl.textContent = text;
    _toastEl.classList.remove('robogears-toast-ok', 'robogears-toast-error');
    _toastEl.classList.add(kind === 'error' ? 'robogears-toast-error' : 'robogears-toast-ok');
    _toastEl.classList.add('robogears-toast-visible');
    clearTimeout(_toastTimer);
    _toastTimer = setTimeout(() => {
        _toastEl.classList.remove('robogears-toast-visible');
    }, 2200);
}

// Build the button we inject into each row. Icon-only — Spotify's actions
// cell is too tight to fit a text label without breaking their layout.
function makeAddButton() {
    const btn = document.createElement('button');
    btn.className = BTN_CLASS;
    btn.title = 'Add to robogears queue';
    btn.setAttribute('aria-label', 'Add to robogears queue');
    btn.type = 'button';
    btn.innerHTML = `
        <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
            <line x1="12" y1="5" x2="12" y2="19"></line>
            <line x1="5" y1="12" x2="19" y2="12"></line>
        </svg>
    `;
    return btn;
}

// Inject our button into a single row, if it doesn't already have one.
// Targets the row's LAST grid cell (the one with duration + save + more) and
// prepends — so we sit next to Spotify's own row actions instead of becoming
// a new auto-placed grid cell at column 1.
function injectIntoRow(row) {
    // Presence check (more robust than a data-attribute — Spotify sometimes
    // re-renders the row's contents and would wipe our marker)
    if (row.querySelector('.' + BTN_CLASS)) return;

    const cells = row.querySelectorAll('[role="gridcell"]');
    const lastCell = cells[cells.length - 1];
    if (!lastCell) return;

    const btn = makeAddButton();

    // Stop ALL pointer events from bubbling up — Spotify's row has
    // mousedown/pointerdown handlers that play the track or open the
    // context menu. We don't want any of that firing on our click.
    const swallow = (e) => e.stopPropagation();
    btn.addEventListener('mousedown',   swallow, true);
    btn.addEventListener('pointerdown', swallow, true);
    btn.addEventListener('mouseup',     swallow, true);

    btn.addEventListener('click', async (e) => {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        const track = extractTrackFromRow(row);
        if (!track) {
            showToast('Could not parse this row', 'error');
            return;
        }
        btn.classList.add('robogears-add-btn-busy');
        btn.disabled = true;
        await pushTracksToApp([track]);
        btn.classList.remove('robogears-add-btn-busy');
        btn.disabled = false;
    }, true);

    // Prepend so we sit before the existing controls (heart / duration / ⋯)
    lastCell.insertBefore(btn, lastCell.firstChild);
}

function scanAndInject() {
    const rows = document.querySelectorAll(ROW_SELECTOR);
    rows.forEach(injectIntoRow);
}

// MutationObserver — Spotify virtual-scrolls rows in/out and re-renders on
// navigation. Re-scan whenever the DOM changes meaningfully.
let _scanScheduled = false;
function scheduleScan() {
    if (_scanScheduled) return;
    _scanScheduled = true;
    requestAnimationFrame(() => {
        _scanScheduled = false;
        scanAndInject();
    });
}

const observer = new MutationObserver(scheduleScan);

(async function init() {
    await loadConfig();
    scanAndInject();
    observer.observe(document.body, { childList: true, subtree: true });
})();
