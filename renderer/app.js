// Renderer — queue-based flow.
// User adds tracks via URL paste, search, or screenshot OCR.
// Then clicks "Download all" to start the batch.

const $ = sel => document.querySelector(sel);
const activityEl = $('#activity');
const urlInput = $('#url-input');
const addBtn = $('#add-btn');
const inputHint = $('#input-hint');
const dropZone = $('#drop-zone');
const fileInput = $('#file-input');
const comingSoonBadge = dropZone.querySelector('.coming-soon-badge');
const clearActivityBtn = $('#clear-btn');
const settingsBtn = $('#settings-btn');
const folderInput = $('#folder-input');
const folderBrowse = $('#folder-browse');
const folderOpen = $('#folder-open');
const libraryInput = $('#library-input');
const libraryBrowse = $('#library-browse');
const libraryOpen = $('#library-open');
const libraryClear = $('#library-clear');
const libraryStatusEl = $('#library-status');
const libraryRescanBtn = $('#library-rescan-btn');
const resetConfigBtn = $('#reset-config-btn');
const authBtn = $('#auth-btn');
const authStatus = $('#auth-status');
const authOutput = $('#auth-output');
const checkUpdatesBtn = $('#check-updates-btn');
const updateStatusEl = $('#update-status');
const authUrlRow = $('#auth-url-row');
const authUrlInput = $('#auth-url-input');
const authUrlCopy = $('#auth-url-copy');
const queueSection = $('#queue-section');
const queueList = $('#queue-list');
const queueCount = $('#queue-count');
const clearQueueBtn = $('#clear-queue');
const cancelQueueBtn = $('#cancel-queue');
const retryAllBtn = $('#retry-all');
const downloadAllBtn = $('#download-all');
const searchModalTitle = $('#search-modal-title');
const searchModalHint = $('#search-modal-hint');
const searchResultsEl = $('#search-results');
const addSelectedBtn = $('#add-selected');
const loadingEl = $('#loading');
const loadingTextEl = $('#loading-text');
const loadingCancelBtn = $('#loading-cancel');

// Cap activity-log lines so a long-running session doesn't hold the DOM
// hostage. 2000 = plenty for normal use; if the user batches more than that
// they really do want the older lines to drop off.
const ACTIVITY_LOG_MAX = 2000;

let settings = { downloadFolder: '' };
let queue = [];                  // [{ tidalId, title, artist, duration, source, notFound, key, hiRes }]
let pendingResults = [];          // search modal candidates
let isDownloading = false;
let searchDebounce = null;

const URL_RE = /^https?:\/\/|spotify\.com|tidal\.com/i;

// ─── Queue persistence ───────────────────────────────────────────────────────
// Saves the queue to userData/queue.json so it survives app restarts. Strips
// per-session state (dlStatus / dlPercent / selected) that should reset.
const TRANSIENT_QUEUE_FIELDS = ['dlStatus', 'dlPercent', 'selected'];
let _queueSaveTimer = null;
function saveQueueSoon() {
    clearTimeout(_queueSaveTimer);
    _queueSaveTimer = setTimeout(() => {
        const persisted = queue.map(t => {
            const c = { ...t };
            for (const k of TRANSIENT_QUEUE_FIELDS) delete c[k];
            return c;
        });
        api.saveQueue(persisted).catch(() => {});
    }, 400);
}

// ─── Utility ─────────────────────────────────────────────────────────────────

function uniqueKey() { return Math.random().toString(36).slice(2, 10); }
function fmtDuration(sec) {
    if (!sec) return '';
    return `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`;
}
function escapeHtml(s) {
    return (s || '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// ─── Sound effects ───────────────────────────────────────────────────────────
// Shared AudioContext — created on first use, reused after. Browsers require
// a user gesture before audio plays; since every caller is a click handler,
// we're fine.
let _audioCtx = null;
function getAudioCtx() {
    if (!_audioCtx) {
        const AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) return null;
        _audioCtx = new AC();
    }
    if (_audioCtx.state === 'suspended') _audioCtx.resume();
    return _audioCtx;
}
// Quick rising perfect-fifth (C5 → G5) chime for the download confirmation.
function playDownloadChime() {
    const ctx = getAudioCtx();
    if (!ctx) return;
    const blip = (freq, startTime, duration) => {
        const osc = ctx.createOscillator();
        const osc2 = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc2.type = 'sine';
        osc.frequency.value = freq;
        osc2.frequency.value = freq * 1.005; // very slight detune for warmth
        gain.gain.setValueAtTime(0.0001, startTime);
        gain.gain.exponentialRampToValueAtTime(0.22, startTime + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, startTime + duration);
        osc.connect(gain);
        osc2.connect(gain);
        gain.connect(ctx.destination);
        osc.start(startTime);
        osc2.start(startTime);
        osc.stop(startTime + duration + 0.05);
        osc2.stop(startTime + duration + 0.05);
    };
    const t = ctx.currentTime + 0.02;
    blip(523.25, t, 0.13);          // C5
    blip(783.99, t + 0.09, 0.18);   // G5 (overlapping for chord feel)
}
// Mirror of playDownloadChime — same sine-pair instrumentation but the
// pitches descend (G5 → C5) so it reads as the "stopping" counterpart to
// the "starting" chime. Slightly shorter so it feels decisive.
function playCancelChime() {
    const ctx = getAudioCtx();
    if (!ctx) return;
    const blip = (freq, startTime, duration) => {
        const osc = ctx.createOscillator();
        const osc2 = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc2.type = 'sine';
        osc.frequency.value = freq;
        osc2.frequency.value = freq * 1.005;
        gain.gain.setValueAtTime(0.0001, startTime);
        gain.gain.exponentialRampToValueAtTime(0.22, startTime + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, startTime + duration);
        osc.connect(gain);
        osc2.connect(gain);
        gain.connect(ctx.destination);
        osc.start(startTime);
        osc2.start(startTime);
        osc.stop(startTime + duration + 0.05);
        osc2.stop(startTime + duration + 0.05);
    };
    const t = ctx.currentTime + 0.02;
    blip(783.99, t, 0.10);          // G5
    blip(523.25, t + 0.07, 0.15);   // C5
}
// Two-tone descending honk. Shared between the "Coming soon" easter egg and
// the download-blocked warning — only frequencies and the lowpass cutoff differ.
function _honkPair(highFreq, lowFreq, opts = {}) {
    const ctx = getAudioCtx();
    if (!ctx) return;
    const lpFreq = opts.lpFreq ?? 1800;
    const peak = opts.peak ?? 0.35;
    const honk = (freq, startTime, duration) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        const lp = ctx.createBiquadFilter();
        lp.type = 'lowpass';
        lp.frequency.value = lpFreq;
        lp.Q.value = 1;
        osc.type = 'sawtooth';
        osc.frequency.setValueAtTime(freq * 1.08, startTime);
        osc.frequency.exponentialRampToValueAtTime(freq, startTime + duration * 0.5);
        gain.gain.setValueAtTime(0.0001, startTime);
        gain.gain.exponentialRampToValueAtTime(peak, startTime + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, startTime + duration);
        osc.connect(lp).connect(gain).connect(ctx.destination);
        osc.start(startTime);
        osc.stop(startTime + duration + 0.05);
    };
    const t = ctx.currentTime + 0.02;
    honk(highFreq, t, 0.17);
    honk(lowFreq, t + 0.22, 0.22);
}
function playClownHorn()   { _honkPair(420, 310); }
function playWarningHonk() { _honkPair(220, 165, { lpFreq: 1100, peak: 0.3 }); }
const FUNNY_LOADING = [
    'Searching the seven seas for your music…',
    'Digging through the record crates…',
    'Asking TIDAL nicely…',
    'Following the bass line…',
    'Tracking down these bangers…',
    'Bribing the algorithm…',
    'Polishing the vinyl…',
    'Listening for the drop…',
    'Tuning the frequencies…',
    'Whispering to the music gods…',
];
let _loadingCycler = null;

// Optional onCancel handler set by callers that support cancellation (the URL
// resolver currently). When set, the loading overlay shows a Cancel button.
let _loadingOnCancel = null;

function showLoading(text, { cancellable = false, onCancel = null } = {}) {
    if (_loadingCycler) { clearInterval(_loadingCycler); _loadingCycler = null; }
    if (text) {
        // Caller provided specific text — show as-is (e.g. OCR phases)
        loadingTextEl.textContent = text;
    } else {
        // Pick a random funny message, then cycle every 2.5s while still loading
        const pick = () => FUNNY_LOADING[Math.floor(Math.random() * FUNNY_LOADING.length)];
        let last = pick();
        loadingTextEl.textContent = last;
        _loadingCycler = setInterval(() => {
            // Avoid repeating the same line back-to-back
            let next = pick();
            while (next === last && FUNNY_LOADING.length > 1) next = pick();
            last = next;
            loadingTextEl.textContent = next;
        }, 2500);
    }
    _loadingOnCancel = cancellable ? onCancel : null;
    loadingCancelBtn.hidden = !cancellable;
    loadingCancelBtn.disabled = false;
    loadingCancelBtn.textContent = 'Cancel';
    loadingEl.hidden = false;
}
function hideLoading() {
    loadingEl.hidden = true;
    loadingCancelBtn.hidden = true;
    _loadingOnCancel = null;
    if (_loadingCycler) { clearInterval(_loadingCycler); _loadingCycler = null; }
}
loadingCancelBtn.addEventListener('click', () => {
    if (!_loadingOnCancel) return;
    loadingCancelBtn.disabled = true;
    loadingCancelBtn.textContent = 'Cancelling…';
    try { _loadingOnCancel(); } catch {}
});
function openModal(id) { $('#' + id).hidden = false; }
function closeModal(id) { $('#' + id).hidden = true; }
document.querySelectorAll('[data-close]').forEach(el => {
    el.addEventListener('click', () => closeModal(el.dataset.close));
});

// ─── Activity log ────────────────────────────────────────────────────────────

function classify(line) {
    if (/^\s*✓ Saved/.test(line)) return 'ok';
    if (/^\s*✘|✗ |Error:|FFmpeg failed/.test(line)) return 'error';
    if (/^\s*⚠/.test(line)) return 'warning';
    if (/^\s*⏭|📁 Already in library/.test(line)) return 'skip';
    if (/^\s*ℹ/.test(line)) return 'warning';
    if (/^===/.test(line)) return 'header';
    if (/complete:/.test(line)) return 'summary';
    if (/\[debug\]/.test(line)) return 'muted';
    return '';
}

function appendLine(line) {
    const div = document.createElement('div');
    div.className = 'log-line ' + classify(line);
    div.textContent = line;
    activityEl.appendChild(div);
    activityEl.scrollTop = activityEl.scrollHeight;
    // Cap activity log size. Skip the welcome line as the trim target so the
    // update-notice insertion (which anchors off welcomeLineEl) keeps working.
    while (activityEl.childElementCount > ACTIVITY_LOG_MAX) {
        const first = activityEl.firstElementChild;
        if (first === welcomeLineEl && first.nextSibling) {
            activityEl.removeChild(first.nextSibling);
        } else {
            activityEl.removeChild(first);
        }
    }
    return div;
}

clearActivityBtn.addEventListener('click', () => activityEl.innerHTML = '');

// ─── Update notice ─────────────────────────────────────────────────────────
// The main process fires `update:available` on app launch when a newer
// GitHub release exists. We insert a notice with a Download button right
// after the boot welcome line. Either order is fine — if the event arrives
// before the welcome line is appended, we stash it and apply once ready.
let welcomeLineEl = null;
let pendingUpdate = null;

async function insertUpdateNotice({ version, downloadUrl }) {
    if (!welcomeLineEl || !welcomeLineEl.parentNode) {
        pendingUpdate = { version, downloadUrl };
        return;
    }
    // Don't duplicate if we already rendered this version's notice
    if (welcomeLineEl.parentNode.querySelector('.update-notice')) return;

    const row = document.createElement('div');
    row.className = 'log-line update-notice';
    const label = document.createElement('span');
    label.innerHTML = `🚀 New version available: <strong>${version}</strong>`;
    const btn = document.createElement('button');
    btn.className = 'update-download-btn';
    btn.textContent = 'Download update';
    row.appendChild(label);
    row.appendChild(btn);
    welcomeLineEl.parentNode.insertBefore(row, welcomeLineEl.nextSibling);

    // On Windows portable builds we can swap the .exe in place. Everywhere
    // else (macOS, dev mode, non-portable) we just open the release page.
    const selfInstall = await api.canSelfInstall().catch(() => false);
    if (!selfInstall) {
        btn.addEventListener('click', () => api.openExternal(downloadUrl));
        return;
    }

    // State machine: idle → downloading (with %) → ready-to-restart → restarting
    let state = 'idle';
    btn.addEventListener('click', async () => {
        if (state === 'idle') {
            state = 'downloading';
            btn.disabled = true;
            btn.textContent = 'Starting…';
            const r = await api.downloadUpdate(downloadUrl);
            if (!r || !r.ok) {
                state = 'idle';
                btn.disabled = false;
                btn.textContent = 'Download failed — retry';
                return;
            }
            state = 'ready';
            btn.disabled = false;
            btn.classList.add('ready');
            btn.textContent = 'Restart to apply';
        } else if (state === 'ready') {
            state = 'restarting';
            btn.disabled = true;
            btn.textContent = 'Restarting…';
            api.applyUpdate();
        }
    });

    api.onUpdateDownloadProgress(({ downloaded, total }) => {
        if (state !== 'downloading') return;
        if (total > 0) {
            const pct = Math.floor((downloaded / total) * 100);
            btn.textContent = `Downloading ${pct}%`;
        } else {
            btn.textContent = `Downloading ${(downloaded / 1024 / 1024).toFixed(1)} MB`;
        }
    });
}

api.onUpdateAvailable(insertUpdateNotice);

// ─── Queue ───────────────────────────────────────────────────────────────────

// Per-track progress state lives on the queue items themselves:
//   t.dlStatus = 'queued' | 'downloading' | 'downloaded' | 'skipped' | 'failed' | 'notFound'
//   t.dlPercent = 0–100 (only meaningful while 'downloading')
// `notFound` is a *resolver-time* property already on the item; we mirror it
// into dlStatus so the row rendering goes through one path.
function renderQueue() {
    queueCount.textContent = queue.length;
    queueSection.hidden = queue.length === 0;
    queueList.innerHTML = '';
    for (const t of queue) {
        const lm = t.libraryMatch;
        const isExact = lm && lm.kind === 'exact';
        const isSimilar = lm && lm.kind === 'similar';

        // Default include state: excluded for exact, included for everything else.
        // Once the user clicks "+ Add" on an exact-match, included flips to true.
        if (t.included === undefined) t.included = !isExact;
        const excluded = !t.included && !t.notFound;

        const row = document.createElement('div');
        row.className = 'queue-item'
            + (t.notFound ? ' notfound' : '')
            + (excluded ? ' excluded' : '')
            + (t.dlStatus ? ` dl-${t.dlStatus}` : '');
        row.dataset.tidalId = t.tidalId || '';
        row.dataset.key = t.key;

        let status = '';
        if (t.dlStatus === 'downloading') status = `<span class="badge dl-running">↓ ${t.dlPercent ?? 0}%</span>`;
        else if (t.dlStatus === 'downloaded') status = '<span class="badge dl-ok">✓ done</span>';
        else if (t.dlStatus === 'skipped') status = '<span class="badge dl-skip">⏭ skipped</span>';
        else if (t.dlStatus === 'failed') status = '<span class="badge dl-fail">✗ failed</span>';
        else if (t.notFound || t.dlStatus === 'notFound') status = '<span class="badge bad" title="Not on TIDAL">not found</span>';
        else if (isExact) status = `<span class="badge dupe" title="${escapeHtml(lm.path)}">📁 already in library</span>`;
        else if (isSimilar) status = `<span class="badge similar" title="${escapeHtml(lm.path)}">⚠ similar version in library</span>`;
        else if (t.source === 'spotify') status = '<span class="badge">Spotify</span>';
        else if (t.source === 'ocr') status = '<span class="badge">OCR</span>';

        // Hi-Res badge — kept independent of status so the indication survives
        // alongside download progress / library badges.
        const hiResBadge = t.hiRes ? '<span class="badge hi-res">Hi-Res</span>' : '';

        const libNote = (isExact || isSimilar) && lm.libraryTitle
            ? `<div class="qi-libnote">Library: ${escapeHtml(lm.libraryTitle)}</div>`
            : '';

        const addButton = excluded
            ? `<button class="qi-add" data-key="${t.key}" title="Add to download list">+ Add</button>`
            : '';
        const retryButton = t.dlStatus === 'failed'
            ? `<button class="qi-retry" data-key="${t.key}" title="Re-download this track">↻ Retry</button>`
            : '';
        const progressBar = t.dlStatus === 'downloading'
            ? `<div class="qi-progress"><div class="qi-progress-fill" style="width:${t.dlPercent ?? 0}%"></div></div>`
            : '';
        // Multi-select checkbox: only on failed rows that have a tidalId (a
        // retriable failure). Pick any subset to retry as a batch via the
        // "Retry selected" header button.
        const canSelect = t.dlStatus === 'failed' && t.tidalId;
        const checkbox = canSelect
            ? `<span class="qi-check ${t.selected ? 'checked' : ''}" data-key="${t.key}" role="checkbox" aria-checked="${t.selected ? 'true' : 'false'}" tabindex="0" title="Select for batch retry"></span>`
            : '';

        row.innerHTML = `
            ${checkbox}
            <div class="qi-info">
                <div class="qi-title">${escapeHtml(t.title)}</div>
                <div class="qi-artist">${escapeHtml(t.artist)}${t.duration ? ` · ${fmtDuration(t.duration)}` : ''} ${hiResBadge}${status}</div>
                ${libNote}
                ${progressBar}
            </div>
            ${addButton}
            ${retryButton}
            <button class="qi-remove" data-key="${t.key}" aria-label="Remove from queue">✕</button>
        `;
        queueList.appendChild(row);
    }
    const downloadable = queue.filter(t => !t.notFound && t.included);
    downloadAllBtn.disabled = isDownloading || downloadable.length === 0;
    if (queue.length && downloadable.length !== queue.length) {
        downloadAllBtn.textContent = isDownloading ? 'Downloading…' : `Download (${downloadable.length})`;
    } else {
        downloadAllBtn.textContent = isDownloading ? 'Downloading…' : 'Download all';
    }
    // Retry header button — adapts to selection state:
    //   • 1+ failed tracks selected via checkbox → "↻ Retry selected (M)"
    //   • else 2+ failed tracks                  → "↻ Retry all (N)"
    //   • otherwise                              → hidden
    // Per-row retry buttons still handle the single-track immediate case.
    const failedTracks  = queue.filter(t => t.dlStatus === 'failed' && t.tidalId);
    const selectedTracks = failedTracks.filter(t => t.selected);
    if (!isDownloading && selectedTracks.length >= 1) {
        retryAllBtn.hidden = false;
        retryAllBtn.textContent = `↻ Retry selected (${selectedTracks.length})`;
    } else if (!isDownloading && failedTracks.length >= 2) {
        retryAllBtn.hidden = false;
        retryAllBtn.textContent = `↻ Retry all (${failedTracks.length})`;
    } else {
        retryAllBtn.hidden = true;
    }
    renderBatchProgress();
}

// Overall batch progress bar above the queue list. Shown while a download is
// in flight; counts items whose dlStatus has moved out of 'queued' / 'downloading'.
function renderBatchProgress() {
    let el = document.querySelector('.batch-progress');
    const inFlight = isDownloading
        ? queue.filter(t => t.included && !t.notFound)
        : [];
    if (!inFlight.length) {
        if (el) el.remove();
        return;
    }
    const done = inFlight.filter(t =>
        t.dlStatus === 'downloaded' || t.dlStatus === 'skipped'
        || t.dlStatus === 'failed' || t.dlStatus === 'notFound'
    ).length;
    const pct = Math.floor((done / inFlight.length) * 100);
    if (!el) {
        el = document.createElement('div');
        el.className = 'batch-progress';
        el.innerHTML = `<div class="batch-progress-bar"></div><span class="batch-progress-label"></span>`;
        queueSection.insertBefore(el, queueList);
    }
    el.querySelector('.batch-progress-bar').style.width = pct + '%';
    el.querySelector('.batch-progress-label').textContent = `${done} / ${inFlight.length}`;
}

// Lightweight surgical updates while a track is downloading — avoids re-rendering
// the entire queue on every percent tick.
function updateRowPercent(tidalId, percent) {
    const row = queueList.querySelector(`.queue-item[data-tidal-id="${tidalId}"]`);
    if (!row) return;
    const badge = row.querySelector('.badge.dl-running');
    if (badge) badge.textContent = `↓ ${percent}%`;
    const fill = row.querySelector('.qi-progress-fill');
    if (fill) fill.style.width = percent + '%';
}

queueList.addEventListener('click', (e) => {
    const check = e.target.closest('.qi-check');
    if (check) {
        const key = check.dataset.key;
        const item = queue.find(t => t.key === key);
        if (item) {
            item.selected = !item.selected;
            renderQueue();
        }
        return;
    }
    const addBtn = e.target.closest('.qi-add');
    if (addBtn) {
        const key = addBtn.dataset.key;
        const item = queue.find(t => t.key === key);
        if (item) {
            item.included = true;
            renderQueue();
            saveQueueSoon();
        }
        return;
    }
    const retryBtn = e.target.closest('.qi-retry');
    if (retryBtn) {
        const key = retryBtn.dataset.key;
        const item = queue.find(t => t.key === key);
        if (!item || !item.tidalId) return;
        if (isDownloading) {
            appendLine('⚠ A batch is already running — retry once it finishes.');
            return;
        }
        if (!settings.downloadFolder) {
            playWarningHonk();
            appendLine('⚠ Pick a download folder in Settings first.');
            return;
        }
        item.dlStatus = 'queued';
        item.dlPercent = 0;
        renderQueue();
        appendLine(`↻ Retrying ${item.title}…`);
        setDownloading(true);
        api.startBulk({ tracks: [item], outDir: settings.downloadFolder });
        return;
    }
    const removeBtn = e.target.closest('.qi-remove');
    if (removeBtn) {
        const key = removeBtn.dataset.key;
        queue = queue.filter(t => t.key !== key);
        renderQueue();
        saveQueueSoon();
    }
});

// Per-track events from bulk_runner → keep queue state in sync + drive the UI.
api.onTrackStart(({ tidalId }) => {
    const item = queue.find(t => t.tidalId === tidalId);
    if (!item) return;
    item.dlStatus = 'downloading';
    item.dlPercent = 0;
    renderQueue();
});
api.onTrackProgress(({ tidalId, percent }) => {
    const item = queue.find(t => t.tidalId === tidalId);
    if (!item) return;
    item.dlPercent = percent;
    // Surgical DOM update to avoid re-rendering the whole list on every tick
    updateRowPercent(tidalId, percent);
});
api.onTrackDone(({ tidalId, status }) => {
    const item = queue.find(t => t.tidalId === tidalId);
    if (!item) return;
    item.dlStatus = status;
    item.dlPercent = status === 'downloaded' ? 100 : (item.dlPercent || 0);
    renderQueue();
});

clearQueueBtn.addEventListener('click', () => {
    if (isDownloading) return;
    queue = [];
    renderQueue();
    saveQueueSoon();
});

function addTracksToQueue(tracks) {
    // De-dupe by tidalId or by title+artist
    const existing = new Set(queue.map(t => t.tidalId ? `id:${t.tidalId}` : `na:${t.title}|${t.artist}`));
    let added = 0;
    for (const t of tracks) {
        const key = t.tidalId ? `id:${t.tidalId}` : `na:${t.title}|${t.artist}`;
        if (existing.has(key)) continue;
        existing.add(key);
        queue.push({ ...t, key: uniqueKey() });
        added++;
    }
    renderQueue();
    if (added) saveQueueSoon();
    return added;
}

// ─── Input: URL vs search ────────────────────────────────────────────────────

function isUrl(s) { return URL_RE.test(s.trim()); }

urlInput.addEventListener('input', () => {
    inputHint.textContent = isUrl(urlInput.value)
        ? 'Detected a link — will resolve all tracks on add.'
        : 'Type to search TIDAL by song name (or paste a link).';
});

addBtn.addEventListener('click', () => handleInput());
urlInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') handleInput(); });

async function handleInput() {
    const input = urlInput.value.trim();
    if (!input) return;
    if (!(await api.tokenExists())) {
        appendLine('⚠ Sign in to TIDAL first (Settings → Sign in).');
        return;
    }

    showLoading(null, {
        cancellable: true,
        onCancel: () => api.cancelResolve(),
    });
    try {
        const r = await api.resolveInput({ input });
        hideLoading();
        if (r.cancelled) { appendLine('⊗ Resolve cancelled.'); return; }
        if (!r.ok) { appendLine(`✗ ${r.error}`); return; }

        if (r.kind === 'url') {
            const found = r.tracks.filter(t => !t.notFound).length;
            const missing = r.tracks.length - found;
            const added = addTracksToQueue(r.tracks);
            appendLine(`+ Added ${added} track${added === 1 ? '' : 's'} from link${missing ? ` (${missing} not on TIDAL)` : ''}.`);
            // Spotify's public embed caps playlists at 100 tracks. If the
            // resolver hit that cap, warn the user explicitly — otherwise
            // they'd never know tracks 101+ silently dropped off.
            if (r.capped) {
                appendLine('⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren\'t included.');
            }
            urlInput.value = '';
        } else {
            // Search results: show modal
            openSearchModal(r.tracks, input);
        }
    } catch (e) {
        hideLoading();
        appendLine(`✗ ${e.message}`);
    }
}

// ─── Search modal ────────────────────────────────────────────────────────────

function openSearchModal(results, query) {
    pendingResults = results;
    searchModalTitle.textContent = `Search results for "${query}"`;
    searchModalHint.textContent = `${results.length} result${results.length === 1 ? '' : 's'}. Pick the ones to add to your queue.`;
    searchResultsEl.innerHTML = '';
    results.forEach((t, i) => {
        const row = document.createElement('label');
        row.className = 'search-row';
        row.innerHTML = `
            <input type="checkbox" data-idx="${i}">
            <div class="sr-info">
                <div class="sr-title">${escapeHtml(t.title)} ${t.hiRes ? '<span class="badge hi-res">Hi-Res</span>' : ''}</div>
                <div class="sr-meta">${escapeHtml(t.artist)} · ${escapeHtml(t.album || '')} · ${fmtDuration(t.duration)}</div>
            </div>
        `;
        searchResultsEl.appendChild(row);
    });
    openModal('search-modal');
}

addSelectedBtn.addEventListener('click', () => {
    const checked = [...searchResultsEl.querySelectorAll('input:checked')];
    if (!checked.length) return;
    const picks = checked.map(c => pendingResults[+c.dataset.idx]);
    const added = addTracksToQueue(picks);
    closeModal('search-modal');
    appendLine(`+ Added ${added} track${added === 1 ? '' : 's'} from search.`);
    urlInput.value = '';
});

// ─── Download all ────────────────────────────────────────────────────────────

function setDownloading(state) {
    isDownloading = state;
    addBtn.disabled = state;
    clearQueueBtn.disabled = state;
    // Cancel button rides alongside Clear all — only visible while a batch is in flight.
    cancelQueueBtn.hidden = !state;
    cancelQueueBtn.disabled = false;
    cancelQueueBtn.textContent = 'Cancel';
    renderQueue();
    downloadAllBtn.textContent = state ? 'Downloading…' : 'Download all';
    downloadAllBtn.disabled = state || queue.length === 0;
}

cancelQueueBtn.addEventListener('click', async () => {
    if (!isDownloading) return;
    playCancelChime();
    cancelQueueBtn.disabled = true;
    cancelQueueBtn.textContent = 'Cancelling…';
    // Kill the child download process. The bulk:done event will follow, which
    // triggers our normal post-batch cleanup. Mark any not-yet-terminal items
    // as 'failed' so they show retry buttons instead of being stuck in
    // 'downloading' or 'queued' forever.
    await api.cancelDownload();
    for (const t of queue) {
        if (t.dlStatus === 'downloading' || t.dlStatus === 'queued') {
            t.dlStatus = 'failed';
            t.dlPercent = 0;
        }
    }
    appendLine('⊗ Download cancelled.');
    renderQueue();
});

// Retry all / Retry selected. Same button — if any failed tracks are
// checkbox-selected, retry just those. Otherwise retry every failed track.
// The per-row ↻ button still does immediate single-track retry.
retryAllBtn.addEventListener('click', async () => {
    if (isDownloading) return;
    const failed = queue.filter(t => t.dlStatus === 'failed' && t.tidalId);
    const selected = failed.filter(t => t.selected);
    const targets = selected.length > 0 ? selected : failed;
    if (!targets.length) return;
    if (!settings.downloadFolder) {
        playWarningHonk();
        appendLine('⚠ Pick a download folder in Settings first.');
        return;
    }
    for (const t of targets) {
        t.dlStatus = 'queued';
        t.dlPercent = 0;
        t.selected = false; // clear selection — they're being processed
    }
    playDownloadChime();
    setDownloading(true);
    appendLine(`↻ Retrying ${targets.length} track${targets.length === 1 ? '' : 's'}…`);
    await api.startBulk({ tracks: targets, outDir: settings.downloadFolder });
});

downloadAllBtn.addEventListener('click', async () => {
    if (isDownloading || !queue.length) return;
    if (!settings.downloadFolder) {
        playWarningHonk();
        appendLine('⚠ Pick a download folder in Settings first.');
        return;
    }
    if (!(await api.tokenExists())) {
        playWarningHonk();
        appendLine('⚠ Sign in to TIDAL first (Settings → Sign in).');
        return;
    }

    // Only items the user has opted to include (excludes not-found and exact-match
    // tracks the user hasn't explicitly "+ Added" back).
    const downloadable = queue.filter(t => !t.notFound && t.included);
    if (!downloadable.length) {
        playWarningHonk();
        appendLine('⚠ Nothing in the queue can be downloaded.');
        return;
    }

    playDownloadChime();
    setDownloading(true);
    appendLine('');
    appendLine(`=== Starting batch (${downloadable.length} tracks) ===`);
    // Mark each track that's about to be sent off so the row shows "queued"
    // until the bulk_runner emits its first __TRACK_START__ for it.
    for (const t of downloadable) {
        t.dlStatus = 'queued';
        t.dlPercent = 0;
    }
    renderQueue();

    await api.startBulk({ tracks: downloadable, outDir: settings.downloadFolder });
});

api.onDownloadLine(appendLine);
api.onDownloadDone(({ code }) => {
    setDownloading(false);
    if (code === 0) {
        appendBatchDoneNotice();
    } else {
        appendLine(`=== Exit code ${code} ===`);
    }
    // Drop successfully-downloaded and skipped tracks. Keep failed and
    // not-found ones so the user can retry / inspect them. Reset transient
    // state on anything that didn't get a terminal status (defensive).
    queue = queue.filter(t =>
        t.notFound
        || t.dlStatus === 'failed'
        || t.dlStatus === 'notFound'
        || (!t.dlStatus && t.included)
    );
    for (const t of queue) {
        if (t.dlStatus !== 'failed' && t.dlStatus !== 'notFound') {
            delete t.dlStatus;
            delete t.dlPercent;
        }
    }
    renderQueue();
    saveQueueSoon();
});

// Special activity-log row shown when a batch finishes successfully —
// inline "Open folder" button so the user can jump straight to the files.
function appendBatchDoneNotice() {
    const row = document.createElement('div');
    row.className = 'log-line batch-done-notice';
    const label = document.createElement('span');
    label.innerHTML = '<strong>✓ Batch finished.</strong>';
    row.appendChild(label);
    if (settings.downloadFolder) {
        const btn = document.createElement('button');
        btn.className = 'batch-open-folder-btn';
        btn.textContent = 'Open folder';
        btn.addEventListener('click', () => api.openFolder(settings.downloadFolder));
        row.appendChild(btn);
    }
    activityEl.appendChild(row);
    activityEl.scrollTop = activityEl.scrollHeight;
}

// ─── Settings ────────────────────────────────────────────────────────────────

settingsBtn.addEventListener('click', async () => {
    await refreshAuthStatus();
    refreshLibraryStatus();
    openModal('settings-modal');
});


function updateOpenButtonStates() {
    folderOpen.disabled = !settings.downloadFolder;
    libraryOpen.disabled = !settings.libraryFolder;
}

folderBrowse.addEventListener('click', async () => {
    const folder = await api.pickFolder();
    if (folder) {
        settings.downloadFolder = folder;
        folderInput.value = folder;
        await api.saveSettings(settings);
        updateOpenButtonStates();
    }
});

folderOpen.addEventListener('click', () => {
    if (settings.downloadFolder) api.openFolder(settings.downloadFolder);
});

libraryBrowse.addEventListener('click', async () => {
    const folder = await api.pickFolder();
    if (folder) {
        settings.libraryFolder = folder;
        libraryInput.value = folder;
        await api.saveSettings(settings);
        updateOpenButtonStates();
        appendLine(`📁 Music library folder set to: ${folder}`);
    }
});

libraryOpen.addEventListener('click', () => {
    if (settings.libraryFolder) api.openFolder(settings.libraryFolder);
});

libraryClear.addEventListener('click', async () => {
    settings.libraryFolder = '';
    libraryInput.value = '';
    await api.saveSettings(settings);
    updateOpenButtonStates();
    appendLine('📁 Music library folder cleared (duplicate check disabled).');
    refreshLibraryStatus();
});

libraryRescanBtn.addEventListener('click', async () => {
    libraryStatusEl.textContent = 'Scanning…';
    libraryRescanBtn.disabled = true;
    try {
        const r = await api.libraryRescan();
        libraryStatusEl.textContent = `${r.count} files indexed`;
        appendLine(`📁 Library re-scanned: ${r.count} files indexed.`);
    } catch (e) {
        libraryStatusEl.textContent = 'Scan failed';
    } finally {
        libraryRescanBtn.disabled = false;
    }
});

resetConfigBtn.addEventListener('click', async () => {
    if (!confirm('Forget the download folder and music library folder?\n\n(Your TIDAL sign-in stays.)')) return;
    settings = await api.resetSettings();
    folderInput.value = '';
    libraryInput.value = '';
    updateOpenButtonStates();
    refreshLibraryStatus();
    appendLine('⚙ Config reset. Pick a download folder in Settings to continue.');
});

// ─── Settings tabs ───────────────────────────────────────────────────────────
document.querySelectorAll('.modal-tab').forEach(tab => {
    tab.addEventListener('click', () => {
        const which = tab.dataset.tab;
        document.querySelectorAll('.modal-tab').forEach(t =>
            t.classList.toggle('active', t === tab));
        document.querySelectorAll('.modal-pane').forEach(p =>
            p.hidden = p.dataset.pane !== which);
    });
});

checkUpdatesBtn.addEventListener('click', async () => {
    checkUpdatesBtn.disabled = true;
    const originalText = 'Check for updates';
    checkUpdatesBtn.textContent = 'Checking…';
    let revertText = originalText;
    try {
        const r = await api.checkForUpdates();
        if (r.status === 'available') {
            checkUpdatesBtn.textContent = `${r.version} available!`;
            // The launch-time listener (insertUpdateNotice) will also fire from
            // the IPC event the main process sends, so the activity log notice
            // appears too — no duplicate handling needed here.
        } else if (r.status === 'up-to-date') {
            checkUpdatesBtn.textContent = 'Up to date ✓';
        } else {
            checkUpdatesBtn.textContent = 'Check failed';
        }
    } catch {
        checkUpdatesBtn.textContent = 'Check failed';
    }
    setTimeout(() => {
        checkUpdatesBtn.disabled = false;
        checkUpdatesBtn.textContent = revertText;
    }, 2500);
});

async function refreshLibraryStatus() {
    try {
        libraryStatusEl.textContent = 'Scanning…';
        const r = await api.libraryStatus();
        libraryStatusEl.textContent = r.path
            ? `${r.count} file${r.count === 1 ? '' : 's'} indexed`
            : '(no library folder set)';
    } catch {
        libraryStatusEl.textContent = '(scan failed)';
    }
}

api.onLibraryScanned(({ count }) => {
    libraryStatusEl.textContent = `${count} file${count === 1 ? '' : 's'} indexed`;
});

// Live progress while scanLibrary is running. The throttling lives in the
// scanner itself (one tick per ~25 files), so this just paints whatever
// arrives.
api.onLibraryScanProgress(({ done, total }) => {
    libraryStatusEl.textContent = total
        ? `Scanning ${done} / ${total}…`
        : 'Scanning…';
});


// ─── Auth ────────────────────────────────────────────────────────────────────

async function refreshAuthStatus() {
    const exists = await api.tokenExists();
    if (exists) {
        authStatus.textContent = '✓ Signed in';
        authStatus.className = 'auth-status ok';
        authBtn.textContent = 'Re-authenticate';
    } else {
        authStatus.textContent = 'Not signed in';
        authStatus.className = 'auth-status bad';
        authBtn.textContent = 'Sign in to TIDAL';
    }
}

authBtn.addEventListener('click', async () => {
    authOutput.textContent = '';
    authUrlInput.value = '';
    authUrlRow.hidden = true;
    authUrlCopy.textContent = 'Copy';
    openModal('auth-modal');
    const r = await api.runAuth();
    if (r.ok) {
        await refreshAuthStatus();
        setTimeout(() => closeModal('auth-modal'), 1200);
    } else {
        authOutput.textContent += '\n\n✗ Sign-in failed.';
    }
});

api.onAuthOutput(line => {
    authOutput.textContent += line;
    authOutput.scrollTop = authOutput.scrollHeight;
});

api.onAuthUrl(url => {
    authUrlInput.value = url;
    authUrlRow.hidden = false;
});

authUrlCopy.addEventListener('click', async () => {
    if (!authUrlInput.value) return;
    try {
        await navigator.clipboard.writeText(authUrlInput.value);
    } catch {
        // Fallback for older browsers / contexts without clipboard API
        authUrlInput.select();
        try { document.execCommand('copy'); } catch {}
        authUrlInput.blur();
    }
    authUrlCopy.textContent = 'Copied ✓';
    setTimeout(() => { authUrlCopy.textContent = 'Copy'; }, 1500);
});

// ─── Screenshot OCR → queue ──────────────────────────────────────────────────

// Flip to true to re-enable the screenshot drop / paste flow. While false,
// the drop-zone is greyed with a "Coming soon" badge and all OCR handlers
// are unwired (drag/drop is still preventDefault'd so the browser doesn't
// navigate to dropped files).
const OCR_FEATURE_ENABLED = false;

if (OCR_FEATURE_ENABLED) {
    dropZone.addEventListener('click', () => fileInput.click());

    ['dragover', 'dragenter'].forEach(ev =>
        dropZone.addEventListener(ev, e => { e.preventDefault(); dropZone.classList.add('dragover'); })
    );
    ['dragleave', 'drop'].forEach(ev =>
        dropZone.addEventListener(ev, () => dropZone.classList.remove('dragover'))
    );
    dropZone.addEventListener('drop', async (e) => {
        e.preventDefault();
        const file = e.dataTransfer.files[0];
        if (file && file.type.startsWith('image/')) handleImage(file);
    });
    fileInput.addEventListener('change', async (e) => {
        const file = e.target.files[0];
        if (file) handleImage(file);
        fileInput.value = '';
    });

    // Clipboard paste — only act on images, leave text paste alone
    document.addEventListener('paste', (e) => {
        if (document.activeElement === urlInput) return;
        const items = e.clipboardData?.items || [];
        for (const item of items) {
            if (item.type.startsWith('image/')) {
                const file = item.getAsFile();
                if (file) handleImage(file);
                e.preventDefault();
                return;
            }
        }
    });
} else {
    dropZone.classList.add('disabled');
    // Eat drag/drop so dropping a file doesn't navigate the window away
    ['dragover', 'dragenter', 'drop'].forEach(ev =>
        dropZone.addEventListener(ev, e => e.preventDefault())
    );
    // Easter egg: clicking the "Coming soon" badge honks a clown horn.
    comingSoonBadge.addEventListener('click', playClownHorn);
}

async function handleImage(file) {
    appendLine(`📷 Scanning screenshot (${file.name || 'pasted image'})…`);
    if (typeof Tesseract === 'undefined') {
        appendLine('   ✗ OCR library failed to load. Check internet connection (Tesseract.js loads from CDN).');
        return;
    }

    showLoading('Running OCR on screenshot…');
    let worker;
    try {
        const url = URL.createObjectURL(file);
        worker = await Tesseract.createWorker('eng');
        const { data } = await worker.recognize(url);
        await worker.terminate();
        worker = null;
        URL.revokeObjectURL(url);

        const tracks = extractTracksFromOCR(data.text);
        if (!tracks.length) {
            hideLoading();
            appendLine('   No tracks recognized. Try a clearer screenshot.');
            return;
        }
        appendLine(`   Parsed ${tracks.length} candidate tracks. Matching against TIDAL…`);

        // Match each on TIDAL (same operation as a search — use the funny text)
        showLoading();
        const r = await api.resolveOcr({ tracks });
        hideLoading();
        if (!r.ok) { appendLine(`   ✗ ${r.error}`); return; }

        const matched = r.tracks.filter(t => !t.notFound).length;
        const missing = r.tracks.length - matched;
        const added = addTracksToQueue(r.tracks);
        appendLine(`+ Added ${added} from screenshot. ${matched} matched, ${missing} not on TIDAL.`);
    } catch (e) {
        hideLoading();
        if (worker) try { await worker.terminate(); } catch {}
        appendLine(`   ✗ OCR failed: ${e.message}`);
    }
}

/**
 * Heuristic OCR parser. Spotify/TIDAL tracklists usually format each row as:
 *   <track number>
 *   <Title>
 *   <Artist>
 *
 * We anchor on the track-number line and grab the next two non-numeric lines.
 * If that doesn't yield results, fall back to "Title — Artist" line format.
 */
function extractTracksFromOCR(text) {
    const lines = text.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
    const tracks = [];
    const seenTitles = new Set();

    // Pass 1: anchor on row numbers
    for (let i = 0; i < lines.length - 2; i++) {
        if (/^\d{1,4}$/.test(lines[i])) {
            const title = lines[i + 1];
            const artist = lines[i + 2];
            if (title && artist && !/^\d+$/.test(title) && !/^\d+$/.test(artist)
                && title.length > 1 && artist.length > 1
                && !/^\d+:\d{2}$/.test(title) && !/^\d+:\d{2}$/.test(artist)) {
                const dedupe = `${title}|${artist}`;
                if (!seenTitles.has(dedupe)) {
                    seenTitles.add(dedupe);
                    tracks.push({ title, artist });
                }
                i += 2;
            }
        }
    }

    // Pass 2: fallback — look for "Title — Artist" line format
    if (!tracks.length) {
        for (const line of lines) {
            const m = line.match(/^(.+?)\s+[—–-]\s+(.+)$/);
            if (m) {
                const title = m[1].trim();
                const artist = m[2].trim();
                if (title && artist && title.length > 1 && artist.length > 1) {
                    tracks.push({ title, artist });
                }
            }
        }
    }

    return tracks;
}

// ─── Boot ────────────────────────────────────────────────────────────────────

(async () => {
    settings = await api.getSettings();
    folderInput.value = settings.downloadFolder || '';
    libraryInput.value = settings.libraryFolder || '';
    updateOpenButtonStates();
    await refreshAuthStatus();

    // Show current app version in the topbar and in Settings → Updates
    api.getAppVersion().then(v => {
        const versionLabel = `v${v}`;
        const brandVersionEl = $('#brand-version');
        if (brandVersionEl) brandVersionEl.textContent = versionLabel;
        updateStatusEl.textContent = `Current version: ${versionLabel}`;
    }).catch(() => {});

    if (!(await api.tokenExists())) {
        welcomeLineEl = appendLine('👋 Welcome! Click the ⚙ icon to sign in to TIDAL.');
    } else if (!settings.downloadFolder) {
        welcomeLineEl = appendLine('Pick a download folder in Settings to get started.');
    } else {
        welcomeLineEl = appendLine(`Ready. Downloads go to: ${settings.downloadFolder}`);
    }

    // Restore any queue from a previous session. Transient state was stripped
    // before save, so dlStatus / dlPercent / selected start clean. Defensive
    // pass anyway in case an older save shape sneaks through.
    try {
        const saved = await api.getQueue();
        if (Array.isArray(saved) && saved.length) {
            queue = saved.map(t => {
                const c = { ...t };
                for (const k of TRANSIENT_QUEUE_FIELDS) delete c[k];
                if (!c.key) c.key = uniqueKey();
                return c;
            });
            renderQueue();
            appendLine(`↺ Restored ${queue.length} track${queue.length === 1 ? '' : 's'} from your last session.`);
        }
    } catch { /* no saved queue or read error — start empty */ }

    // Apply any update notice that arrived before the welcome line existed.
    if (pendingUpdate) {
        insertUpdateNotice(pendingUpdate);
        pendingUpdate = null;
    }
})();
