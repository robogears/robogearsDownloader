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
const libraryInput = $('#library-input');
const libraryBrowse = $('#library-browse');
const libraryClear = $('#library-clear');
const libraryStatusEl = $('#library-status');
const libraryRescanBtn = $('#library-rescan-btn');
const resetConfigBtn = $('#reset-config-btn');
const authBtn = $('#auth-btn');
const authStatus = $('#auth-status');
const authOutput = $('#auth-output');
const queueSection = $('#queue-section');
const queueList = $('#queue-list');
const queueCount = $('#queue-count');
const clearQueueBtn = $('#clear-queue');
const downloadAllBtn = $('#download-all');
const searchModalTitle = $('#search-modal-title');
const searchModalHint = $('#search-modal-hint');
const searchResultsEl = $('#search-results');
const addSelectedBtn = $('#add-selected');
const loadingEl = $('#loading');
const loadingTextEl = $('#loading-text');

let settings = { downloadFolder: '' };
let queue = [];                  // [{ tidalId, title, artist, duration, source, notFound, key }]
let pendingResults = [];          // search modal candidates
let isDownloading = false;
let searchDebounce = null;

const URL_RE = /^https?:\/\/|spotify\.com|tidal\.com/i;

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

function showLoading(text) {
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
    loadingEl.hidden = false;
}
function hideLoading() {
    loadingEl.hidden = true;
    if (_loadingCycler) { clearInterval(_loadingCycler); _loadingCycler = null; }
}
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
}

clearActivityBtn.addEventListener('click', () => activityEl.innerHTML = '');

// ─── Queue ───────────────────────────────────────────────────────────────────

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
            + (excluded ? ' excluded' : '');

        let status = '';
        if (t.notFound) status = '<span class="badge bad" title="Not on TIDAL">not found</span>';
        else if (isExact) status = `<span class="badge dupe" title="${escapeHtml(lm.path)}">📁 already in library</span>`;
        else if (isSimilar) status = `<span class="badge similar" title="${escapeHtml(lm.path)}">⚠ similar version in library</span>`;
        else if (t.source === 'spotify') status = '<span class="badge">Spotify</span>';
        else if (t.source === 'ocr') status = '<span class="badge">OCR</span>';

        const libNote = (isExact || isSimilar) && lm.libraryTitle
            ? `<div class="qi-libnote">Library: ${escapeHtml(lm.libraryTitle)}</div>`
            : '';

        // Show "+ Add" only on currently-excluded items
        const addButton = excluded
            ? `<button class="qi-add" data-key="${t.key}" title="Add to download list">+ Add</button>`
            : '';

        row.innerHTML = `
            <div class="qi-info">
                <div class="qi-title">${escapeHtml(t.title)}</div>
                <div class="qi-artist">${escapeHtml(t.artist)}${t.duration ? ` · ${fmtDuration(t.duration)}` : ''} ${status}</div>
                ${libNote}
            </div>
            ${addButton}
            <button class="qi-remove" data-key="${t.key}" aria-label="Remove from queue">✕</button>
        `;
        queueList.appendChild(row);
    }
    const downloadable = queue.filter(t => !t.notFound && t.included);
    downloadAllBtn.disabled = isDownloading || downloadable.length === 0;
    // Show count of items that will download vs. total
    if (queue.length && downloadable.length !== queue.length) {
        downloadAllBtn.textContent = isDownloading ? 'Downloading…' : `Download (${downloadable.length})`;
    } else {
        downloadAllBtn.textContent = isDownloading ? 'Downloading…' : 'Download all';
    }
}

queueList.addEventListener('click', (e) => {
    const addBtn = e.target.closest('.qi-add');
    if (addBtn) {
        const key = addBtn.dataset.key;
        const item = queue.find(t => t.key === key);
        if (item) {
            item.included = true;
            renderQueue();
        }
        return;
    }
    const removeBtn = e.target.closest('.qi-remove');
    if (removeBtn) {
        const key = removeBtn.dataset.key;
        queue = queue.filter(t => t.key !== key);
        renderQueue();
    }
});

clearQueueBtn.addEventListener('click', () => {
    if (isDownloading) return;
    queue = [];
    renderQueue();
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

    showLoading();   // random funny message, cycles every 2.5s
    try {
        const r = await api.resolveInput({ input });
        hideLoading();
        if (!r.ok) { appendLine(`✗ ${r.error}`); return; }

        if (r.kind === 'url') {
            const found = r.tracks.filter(t => !t.notFound).length;
            const missing = r.tracks.length - found;
            const added = addTracksToQueue(r.tracks);
            appendLine(`+ Added ${added} track${added === 1 ? '' : 's'} from link${missing ? ` (${missing} not on TIDAL)` : ''}.`);
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
    renderQueue();
    downloadAllBtn.textContent = state ? 'Downloading…' : 'Download all';
    downloadAllBtn.disabled = state || queue.length === 0;
}

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

    await api.startBulk({ tracks: downloadable, outDir: settings.downloadFolder });
});

api.onDownloadLine(appendLine);
api.onDownloadDone(({ code }) => {
    setDownloading(false);
    if (code === 0) appendLine('=== ✓ Batch finished ===');
    else appendLine(`=== Exit code ${code} ===`);
    // Remove downloaded items from queue (keep not-found ones)
    queue = queue.filter(t => t.notFound);
    renderQueue();
});

// ─── Settings ────────────────────────────────────────────────────────────────

settingsBtn.addEventListener('click', async () => {
    await refreshAuthStatus();
    refreshLibraryStatus();
    openModal('settings-modal');
});


folderBrowse.addEventListener('click', async () => {
    const folder = await api.pickFolder();
    if (folder) {
        settings.downloadFolder = folder;
        folderInput.value = folder;
        await api.saveSettings(settings);
    }
});

libraryBrowse.addEventListener('click', async () => {
    const folder = await api.pickFolder();
    if (folder) {
        settings.libraryFolder = folder;
        libraryInput.value = folder;
        await api.saveSettings(settings);
        appendLine(`📁 Music library folder set to: ${folder}`);
    }
});

libraryClear.addEventListener('click', async () => {
    settings.libraryFolder = '';
    libraryInput.value = '';
    await api.saveSettings(settings);
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
    refreshLibraryStatus();
    appendLine('⚙ Config reset. Pick a download folder in Settings to continue.');
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
    await refreshAuthStatus();

    if (!(await api.tokenExists())) {
        appendLine('👋 Welcome! Click the ⚙ icon to sign in to TIDAL.');
    } else if (!settings.downloadFolder) {
        appendLine('Pick a download folder in Settings to get started.');
    } else {
        appendLine(`Ready. Downloads go to: ${settings.downloadFolder}`);
    }
})();
