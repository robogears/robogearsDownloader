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
const exportifyLink = $('#exportify-link');
const brandUpdatePill = $('#brand-update-pill');
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
const volumeSlider = $('#volume-slider');
const brandEl = $('#brand');
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

// Experimental — flip to false to disable the play-button + waveform preview
// on queue rows entirely.
const PREVIEW_FEATURE_ENABLED = true;

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
// Easter egg — click anywhere on the topbar brand. Sub-bass sawtooth with a
// wobble LFO and a lowpass for that signature "brapppp" character. Kept short
// (~400ms) so it doesn't outstay its welcome.
//
// pitchScale > 1 yields a high-pitched "tiny fart" — used when the user
// clicks the version number for a comedic contrast with the full-pitch
// logo/name click.
function playFart({ pitchScale = 1 } = {}) {
    const ctx = getAudioCtx();
    if (!ctx) return;
    const t = ctx.currentTime + 0.02;
    const duration = 0.42;

    const osc = ctx.createOscillator();
    osc.type = 'sawtooth';
    osc.frequency.setValueAtTime(95 * pitchScale, t);
    osc.frequency.exponentialRampToValueAtTime(48 * pitchScale, t + duration);

    // LFO for the wobble — modulates the osc frequency. Scale the LFO rate
    // modestly so high-pitched variants still have audible wobble character.
    const lfo = ctx.createOscillator();
    lfo.type = 'sine';
    lfo.frequency.value = 17 * Math.sqrt(pitchScale);
    const lfoGain = ctx.createGain();
    lfoGain.gain.value = 18 * pitchScale;
    lfo.connect(lfoGain).connect(osc.frequency);

    const lp = ctx.createBiquadFilter();
    lp.type = 'lowpass';
    // Cutoff scales with pitch so we don't filter out the new fundamental.
    lp.frequency.value = 480 * pitchScale;
    lp.Q.value = 2.2;

    const gain = ctx.createGain();
    gain.gain.setValueAtTime(0.0001, t);
    gain.gain.exponentialRampToValueAtTime(0.42, t + 0.02);
    gain.gain.linearRampToValueAtTime(0.32, t + duration * 0.45);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + duration);

    osc.connect(lp).connect(gain).connect(ctx.destination);
    osc.start(t); lfo.start(t);
    osc.stop(t + duration + 0.05);
    lfo.stop(t + duration + 0.05);
}
// Ascending major triad with bell-like decay — fires once the batch finishes
// cleanly. Distinct from the "starting" chime (which is a two-note rising
// fifth) so the user can tell starting vs done by ear alone.
function playSuccessPing() {
    const ctx = getAudioCtx();
    if (!ctx) return;
    const bell = (freq, startTime, duration) => {
        const osc = ctx.createOscillator();
        const osc2 = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc2.type = 'sine';
        osc.frequency.value = freq;
        osc2.frequency.value = freq * 1.005;          // slight detune for warmth
        gain.gain.setValueAtTime(0.0001, startTime);
        gain.gain.exponentialRampToValueAtTime(0.22, startTime + 0.008);  // fast attack
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
    // G5 → C6 → E6, overlapping for a chord-arpeggio feel
    bell(783.99,  t,         0.28);
    bell(1046.50, t + 0.07,  0.32);
    bell(1318.51, t + 0.14,  0.42);
}
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
        loadingTextEl.textContent = text;
    } else {
        const pick = () => FUNNY_LOADING[Math.floor(Math.random() * FUNNY_LOADING.length)];
        let last = pick();
        loadingTextEl.textContent = last;
        _loadingCycler = setInterval(() => {
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

// ─── Topbar "Update now" pill — single-click download + auto-apply ──────────
// Keeps the activity-log notice flow (two-click: Download then Restart) for
// users who want to review. The pill is for the impatient: one click does
// everything and restarts the app.
let _pillUpdateUrl = null;
let _pillUpdateState = 'idle';  // 'idle' | 'available' | 'downloading' | 'restarting'

api.onUpdateAvailable((payload) => {
    _pillUpdateUrl = payload.downloadUrl;
    _pillUpdateState = 'available';
    brandUpdatePill.hidden = false;
    brandUpdatePill.disabled = false;
    brandUpdatePill.textContent = 'Update now';
});

brandUpdatePill.addEventListener('click', async () => {
    if (_pillUpdateState !== 'available' || !_pillUpdateUrl) return;

    const selfInstall = await api.canSelfInstall().catch(() => false);
    if (!selfInstall) {
        // Dev / unsupported platform — fall back to the browser
        api.openExternal(_pillUpdateUrl);
        return;
    }

    _pillUpdateState = 'downloading';
    brandUpdatePill.disabled = true;
    brandUpdatePill.textContent = 'Downloading…';

    const r = await api.downloadUpdate(_pillUpdateUrl);
    if (!r || !r.ok) {
        _pillUpdateState = 'available';
        brandUpdatePill.disabled = false;
        brandUpdatePill.textContent = 'Retry update';
        return;
    }

    _pillUpdateState = 'restarting';
    brandUpdatePill.textContent = 'Restarting…';
    api.applyUpdate();
});

// Pill listens to the same progress events as the activity-log button — both
// stay accurate if either one is in flight.
api.onUpdateDownloadProgress(({ downloaded, total }) => {
    if (_pillUpdateState !== 'downloading') return;
    if (total > 0) {
        const pct = Math.floor((downloaded / total) * 100);
        brandUpdatePill.textContent = `Downloading ${pct}%`;
    } else {
        brandUpdatePill.textContent = `Downloading ${(downloaded / 1024 / 1024).toFixed(1)} MB`;
    }
});

// ─── Easter egg: click the brand for a fart ─────────────────────────────────
// Only the logo, name, and version accept clicks (the rest of the topbar row
// stays a drag handle via -webkit-app-region: drag). The version gets a
// pitched-up "tiny fart" for comedic contrast with the full-pitch one.
brandEl.addEventListener('click', (e) => {
    const t = e.target;
    if (t.closest('.brand-version')) playFart({ pitchScale: 7 });
    else if (t.closest('.brand-logo') || t.closest('.brand-name')) playFart();
});

// ─── Preview volume ──────────────────────────────────────────────────────────
// `settings.volume` stores the SLIDER position (0-1, linear). The audio's
// actual volume is the squared curve of that — so the low end of the slider
// drops off much faster than linear, matching how human hearing perceives
// loudness. At slider 50%, audio is 25%. At slider 10%, audio is 1%.
function sliderToAudioVolume(linear) {
    const v = Math.min(1, Math.max(0, linear));
    return v * v;
}
function getPreviewVolume() {
    const v = typeof settings.volume === 'number' ? settings.volume : 0.5;
    return sliderToAudioVolume(v);
}

let _volumeSaveTimer = null;
volumeSlider.addEventListener('input', () => {
    const linear = volumeSlider.value / 100;
    settings.volume = linear;
    if (previewState.audio) previewState.audio.volume = sliderToAudioVolume(linear);
    // Persist after the user stops dragging — debounced so the slider stays
    // snappy and disk IO doesn't fire on every pixel of drag.
    clearTimeout(_volumeSaveTimer);
    _volumeSaveTimer = setTimeout(() => api.saveSettings(settings), 300);
});

// ─── Audio preview / waveform (experimental) ────────────────────────────────
// One playing track at a time. Click play on any queue row to fetch the audio
// via main process, decode for peaks, and play through a blob-backed <audio>
// element. The waveform canvas doubles as a scrub bar (click anywhere to seek)
// and reacts under the cursor (bars near the mouse swell up slightly).
//
// Cache: per-tidalId entry holds the peaks Float32Array + the Blob URL the
// <audio> element points at. LRU-evicted at 3 entries — keeps memory bounded
// even after long preview sessions.

// Two-tier cache:
//   peaksCache — unlimited (each entry is ~800 bytes of Float32Array). Survives
//                aggressively so any track that's ever been previewed paints
//                its waveform instantly on re-render.
//   audioCache — LRU MAX_AUDIO_CACHE entries. Holds the Blob URL backing the
//                <audio> element. Each entry pins ~30 MB of audio bytes in
//                memory, so we keep this tight and evict with revokeObjectURL.
const previewState = {
    playingTidalId: null,
    audio: null,
    audioCtx: null,
    peaksCache: new Map(),
    audioCache: new Map(),
    MAX_AUDIO_CACHE: 3,
};

// Background pre-loader. When tracks land in the queue we enqueue them for
// peaks fetch + decode at concurrency 2 — slow enough not to saturate the
// network, fast enough that small queues finish in a few seconds.
const preloader = {
    queue: [],
    inFlight: 0,
    CONCURRENCY: 2,
};

function getPreviewCtx() {
    if (!previewState.audioCtx) {
        const AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) return null;
        previewState.audioCtx = new AC();
    }
    if (previewState.audioCtx.state === 'suspended') previewState.audioCtx.resume();
    return previewState.audioCtx;
}

function evictAudioCache() {
    while (previewState.audioCache.size > previewState.MAX_AUDIO_CACHE) {
        const oldestKey = previewState.audioCache.keys().next().value;
        if (oldestKey === previewState.playingTidalId) {
            // Don't evict the currently-playing entry; bump it to the end.
            const entry = previewState.audioCache.get(oldestKey);
            previewState.audioCache.delete(oldestKey);
            previewState.audioCache.set(oldestKey, entry);
            continue;
        }
        const old = previewState.audioCache.get(oldestKey);
        try { URL.revokeObjectURL(old.blobUrl); } catch {}
        previewState.audioCache.delete(oldestKey);
    }
}

function computePeaks(audioBuffer, numBars) {
    const channelData = audioBuffer.getChannelData(0);
    const samplesPerBar = Math.max(1, Math.floor(channelData.length / numBars));
    const peaks = new Float32Array(numBars);
    for (let i = 0; i < numBars; i++) {
        let max = 0;
        const start = i * samplesPerBar;
        const end = Math.min(start + samplesPerBar, channelData.length);
        for (let j = start; j < end; j++) {
            const v = Math.abs(channelData[j]);
            if (v > max) max = v;
        }
        peaks[i] = max;
    }
    // Normalize to [0..1] in case the source isn't peak-normalized
    let maxPeak = 0;
    for (let i = 0; i < peaks.length; i++) if (peaks[i] > maxPeak) maxPeak = peaks[i];
    if (maxPeak > 0) for (let i = 0; i < peaks.length; i++) peaks[i] /= maxPeak;
    return peaks;
}

function drawWaveform(canvas, peaks, progress = 0, hover = -1) {
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const cssWidth = canvas.clientWidth || canvas.width;
    const cssHeight = canvas.clientHeight || canvas.height;
    if (canvas.width !== cssWidth * dpr || canvas.height !== cssHeight * dpr) {
        canvas.width = cssWidth * dpr;
        canvas.height = cssHeight * dpr;
    }
    ctx.save();
    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, cssWidth, cssHeight);

    const n = peaks.length;
    const barWidth = cssWidth / n;
    const midY = cssHeight / 2;
    const hoverBar = hover >= 0 ? hover * n : -1;

    for (let i = 0; i < n; i++) {
        const x = i * barWidth;
        const playedProgress = (i + 0.5) / n;
        const isPlayed = playedProgress <= progress;

        // Spotlight effect: bars within range of the mouse swell up slightly.
        let boost = 1;
        if (hoverBar >= 0) {
            const dist = Math.abs(i - hoverBar);
            if (dist < 10) boost = 1 + (1 - dist / 10) * 0.45;
        }

        const h = Math.max(1, peaks[i] * cssHeight * 0.78 * boost);
        ctx.fillStyle = isPlayed ? '#ffffff' : 'rgba(255, 255, 255, 0.22)';
        ctx.fillRect(x, midY - h / 2, Math.max(1, barWidth - 1), h);
    }

    // Hover cursor line — vertical thread following the mouse
    if (hover >= 0) {
        ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
        const cx = Math.floor(hover * cssWidth);
        ctx.fillRect(cx, 2, 1, cssHeight - 4);
    }
    ctx.restore();
}

// Inline SVG icons — precise centering, no unicode whitespace quirks.
const PLAY_ICON_HTML  = '<svg viewBox="0 0 10 10" width="9" height="9" aria-hidden="true"><polygon points="2,1 9,5 2,9" fill="currentColor"/></svg>';
const PAUSE_ICON_HTML = '<svg viewBox="0 0 10 10" width="9" height="9" aria-hidden="true"><rect x="2" y="1.5" width="2" height="7" fill="currentColor"/><rect x="6" y="1.5" width="2" height="7" fill="currentColor"/></svg>';
const LOADING_ICON_HTML = '<svg viewBox="0 0 10 10" width="9" height="9" aria-hidden="true"><circle cx="5" cy="5" r="3.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-dasharray="4 3"/></svg>';

function setPlayButtonState(tidalId, state) {
    const row = queueList.querySelector(`.queue-item[data-tidal-id="${tidalId}"]`);
    if (!row) return;
    const btn = row.querySelector('.qi-play');
    if (!btn) return;
    btn.classList.remove('playing', 'loading');
    if (state === 'playing')      { btn.classList.add('playing'); btn.innerHTML = PAUSE_ICON_HTML; }
    else if (state === 'loading') { btn.classList.add('loading'); btn.innerHTML = LOADING_ICON_HTML; }
    else                          { btn.innerHTML = PLAY_ICON_HTML; }
}

// Fetch raw audio bytes for a track. Cheap-ish to call (one IPC, returns a
// Buffer) but the actual download is the big cost. No caching here — callers
// decide whether to keep the bytes around (via the Blob) or drop them after
// peak extraction (pre-loader does this to save memory).
async function fetchAudioBytesIpc(tidalId) {
    const r = await api.getPreviewAudio(tidalId);
    if (!r.ok) throw new Error(r.error || 'preview fetch failed');
    const bytes = r.audioBytes;
    const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    return { ab, mimeType: r.mimeType || 'audio/flac' };
}

// Decode an ArrayBuffer and extract waveform peaks. decodeAudioData detaches
// its input; caller is responsible for slicing if they need the bytes after.
async function decodePeaksFromBuffer(ab) {
    const ctx = getPreviewCtx();
    if (!ctx) throw new Error('Web Audio not supported');
    const audioBuffer = await ctx.decodeAudioData(ab);
    return computePeaks(audioBuffer, 200);
}

// Returns peaks, fetching + decoding if not cached. Used by the pre-loader
// and by the play path (which then additionally creates a Blob URL for the
// <audio> element).
async function getPeaks(tidalId) {
    if (previewState.peaksCache.has(tidalId)) return previewState.peaksCache.get(tidalId);
    const { ab } = await fetchAudioBytesIpc(tidalId);
    // decodeAudioData consumes its input; since this branch isn't producing a
    // Blob we don't need to slice — let the buffer be detached and freed.
    const peaks = await decodePeaksFromBuffer(ab);
    previewState.peaksCache.set(tidalId, peaks);
    return peaks;
}

// Returns { peaks, blobUrl } — both needed for playback. Goes through the
// audio cache to keep the Blob URL pinned (and evictable). Re-fetches audio
// if we previously only cached the peaks (preloaded but not played).
async function getPlayableEntry(tidalId) {
    // Audio side
    let audioEntry = previewState.audioCache.get(tidalId);
    if (audioEntry) {
        // LRU bump
        previewState.audioCache.delete(tidalId);
        previewState.audioCache.set(tidalId, audioEntry);
    } else {
        const { ab, mimeType } = await fetchAudioBytesIpc(tidalId);
        // If peaks already cached (pre-loaded), skip decode. Otherwise decode
        // a copy and stash peaks for free.
        if (!previewState.peaksCache.has(tidalId)) {
            const peaks = await decodePeaksFromBuffer(ab.slice(0));
            previewState.peaksCache.set(tidalId, peaks);
        }
        const blob = new Blob([ab], { type: mimeType });
        const blobUrl = URL.createObjectURL(blob);
        audioEntry = { blobUrl };
        previewState.audioCache.set(tidalId, audioEntry);
        evictAudioCache();
    }
    return { peaks: previewState.peaksCache.get(tidalId), blobUrl: audioEntry.blobUrl };
}

// ─── Background pre-loader ──────────────────────────────────────────────────
function enqueuePreload(tidalId) {
    if (!PREVIEW_FEATURE_ENABLED) return;
    if (!tidalId) return;
    if (previewState.peaksCache.has(tidalId)) return;
    if (preloader.queue.includes(tidalId)) return;
    preloader.queue.push(tidalId);
    drainPreloader();
}

function drainPreloader() {
    while (preloader.inFlight < preloader.CONCURRENCY && preloader.queue.length) {
        const tidalId = preloader.queue.shift();
        if (previewState.peaksCache.has(tidalId)) continue;  // race check
        preloader.inFlight++;
        preloadOne(tidalId).finally(() => {
            preloader.inFlight--;
            drainPreloader();
        });
    }
}

async function preloadOne(tidalId) {
    try {
        const peaks = await getPeaks(tidalId);
        // Paint any visible canvas(es) for this track — the user added the row
        // before the peaks were ready, so the canvas is sitting in `empty` state.
        queueList.querySelectorAll(`.qi-waveform[data-tidal-id="${tidalId}"]`).forEach(canvas => {
            canvas.classList.remove('empty');
            canvas.__peaks = peaks;
            const progress = (previewState.playingTidalId === tidalId && previewState.audio && previewState.audio.duration)
                ? previewState.audio.currentTime / previewState.audio.duration : 0;
            drawWaveform(canvas, peaks, progress);
        });
    } catch {
        // Silent — if the user clicks play they'll see the actual error from
        // getPlayableEntry. Pre-load failures shouldn't yell.
    }
}

function stopPreview() {
    const oldId = previewState.playingTidalId;
    const oldAudio = previewState.audio;
    // Null these out FIRST so any stale events fired by the teardown of the
    // old audio element find previewState.audio === null and bail.
    previewState.audio = null;
    previewState.playingTidalId = null;
    if (oldAudio) {
        try { oldAudio.pause(); } catch {}
        try { oldAudio.src = ''; } catch {}  // fires a delayed error event — guarded below
    }
    if (oldId) {
        setPlayButtonState(oldId, 'idle');
        const oldRow = queueList.querySelector(`.queue-item[data-tidal-id="${oldId}"]`);
        const canvas = oldRow?.querySelector('.qi-waveform');
        if (canvas && canvas.__peaks) drawWaveform(canvas, canvas.__peaks, 0);
    }
}

async function togglePreview(tidalId, row, { initialSeekRatio = 0 } = {}) {
    if (!row) return;

    // Same track currently playing/paused → toggle pause state.
    if (previewState.playingTidalId === tidalId && previewState.audio) {
        if (previewState.audio.paused) {
            if (initialSeekRatio > 0 && isFinite(previewState.audio.duration)) {
                previewState.audio.currentTime = initialSeekRatio * previewState.audio.duration;
            }
            await previewState.audio.play().catch(() => {});
            setPlayButtonState(tidalId, 'playing');
        } else {
            previewState.audio.pause();
            setPlayButtonState(tidalId, 'idle');
        }
        return;
    }

    // Switch tracks — stop current first.
    stopPreview();

    const canvas = row.querySelector('.qi-waveform');
    if (!canvas) return;

    // If peaks are pre-loaded, paint immediately so the user has visual
    // feedback while the audio fetch finishes.
    if (previewState.peaksCache.has(tidalId)) {
        canvas.classList.remove('empty');
        canvas.__peaks = previewState.peaksCache.get(tidalId);
        drawWaveform(canvas, canvas.__peaks, initialSeekRatio || 0);
    }

    setPlayButtonState(tidalId, 'loading');
    try {
        const { peaks, blobUrl } = await getPlayableEntry(tidalId);

        // Audio element
        const audio = new Audio(blobUrl);
        audio.volume = getPreviewVolume();
        audio.preload = 'auto';
        previewState.audio = audio;
        previewState.playingTidalId = tidalId;

        // Paint full waveform now that we have peaks
        canvas.classList.remove('empty');
        canvas.__peaks = peaks;
        drawWaveform(canvas, peaks, initialSeekRatio || 0);

        // Apply initial seek before play — wait for metadata if necessary so
        // duration is finite. Without this, `currentTime = N` is silently
        // ignored before the audio is loaded enough.
        if (initialSeekRatio > 0) {
            if (!isFinite(audio.duration) || audio.duration <= 0) {
                await new Promise(resolve => {
                    audio.addEventListener('loadedmetadata', resolve, { once: true });
                });
            }
            audio.currentTime = initialSeekRatio * audio.duration;
        }

        // Helper: every event listener below should be a no-op if the audio
        // it fires on isn't the currently-tracked one (i.e., we've moved on
        // to another track and this is a stale event from the torn-down
        // element). The most common offender is the delayed `error` event
        // that fires after we set `audio.src = ''` during stopPreview.
        const isCurrent = () => previewState.audio === audio;

        const tick = () => {
            if (!isCurrent()) return;
            const a = previewState.audio;
            const progress = a.duration ? a.currentTime / a.duration : 0;
            const liveCanvas = queueList.querySelector(`.qi-waveform[data-tidal-id="${tidalId}"]`);
            if (liveCanvas) {
                const hover = parseFloat(liveCanvas.dataset.hover);
                drawWaveform(liveCanvas, peaks, progress, isFinite(hover) ? hover : -1);
            }
            if (!a.paused) requestAnimationFrame(tick);
        };
        audio.addEventListener('play',  () => { if (isCurrent()) requestAnimationFrame(tick); });
        audio.addEventListener('pause', () => { if (isCurrent()) setPlayButtonState(tidalId, 'idle'); });
        audio.addEventListener('ended', () => { if (isCurrent()) stopPreview(); });
        audio.addEventListener('error', () => {
            if (!isCurrent()) return;  // stale error from a previously-torn-down element
            appendLine(`✗ Preview playback failed (${audio.error?.code || '?'}).`);
            stopPreview();
        });

        await audio.play();
        setPlayButtonState(tidalId, 'playing');
    } catch (e) {
        setPlayButtonState(tidalId, 'idle');
        appendLine(`✗ Preview: ${e.message}`);
    }
}

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
        else if (t.source === 'import') status = '<span class="badge">Import</span>';
        else if (t.source === 'extension') status = '<span class="badge">Spotify ext</span>';

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

        // Preview controls (experimental). Only show when we have a tidalId
        // to look up — notFound rows have no source to preview.
        const previewPlay = (PREVIEW_FEATURE_ENABLED && t.tidalId && !t.notFound)
            ? `<button class="qi-play" data-tidal-id="${t.tidalId}" title="Play preview" aria-label="Play">${PLAY_ICON_HTML}</button>`
            : '';
        const previewWave = (PREVIEW_FEATURE_ENABLED && t.tidalId && !t.notFound)
            ? `<canvas class="qi-waveform empty" data-tidal-id="${t.tidalId}" height="22" title="Click or drag to scrub"></canvas>`
            : '';

        // Title + waveform share a row so the waveform expands to fill the
        // space between the end of the title and the action buttons.
        row.innerHTML = `
            ${checkbox}
            ${previewPlay}
            <div class="qi-info">
                <div class="qi-title-row">
                    <div class="qi-title">${escapeHtml(t.title)}</div>
                    ${previewWave}
                </div>
                <div class="qi-artist">${escapeHtml(t.artist)}${t.duration ? ` · ${fmtDuration(t.duration)}` : ''} ${hiResBadge}${status}</div>
                ${libNote}
                ${progressBar}
            </div>
            ${addButton}
            ${retryButton}
            <button class="qi-remove" data-key="${t.key}" aria-label="Remove from queue">✕</button>
        `;
        queueList.appendChild(row);

        // If we have cached peaks for this track (already previewed or
        // pre-loaded), repaint the waveform so it doesn't reset to a blank
        // canvas after re-render.
        if (PREVIEW_FEATURE_ENABLED && t.tidalId && previewState.peaksCache.has(t.tidalId)) {
            const canvas = row.querySelector('.qi-waveform');
            const playBtn = row.querySelector('.qi-play');
            if (canvas) {
                canvas.classList.remove('empty');
                canvas.__peaks = previewState.peaksCache.get(t.tidalId);
                const progress = (previewState.playingTidalId === t.tidalId && previewState.audio)
                    ? (previewState.audio.duration ? previewState.audio.currentTime / previewState.audio.duration : 0)
                    : 0;
                drawWaveform(canvas, canvas.__peaks, progress);
            }
            if (playBtn && previewState.playingTidalId === t.tidalId && previewState.audio && !previewState.audio.paused) {
                playBtn.classList.add('playing');
                playBtn.innerHTML = PAUSE_ICON_HTML;
            }
        }
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
    // Preview play button
    const playBtn = e.target.closest('.qi-play');
    if (playBtn) {
        e.stopPropagation();
        const tidalId = Number(playBtn.dataset.tidalId);
        const row = playBtn.closest('.queue-item');
        togglePreview(tidalId, row);
        return;
    }

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
        // If we're previewing the track we're about to remove, stop first.
        const removed = queue.find(t => t.key === key);
        if (removed && removed.tidalId === previewState.playingTidalId) stopPreview();
        queue = queue.filter(t => t.key !== key);
        renderQueue();
        saveQueueSoon();
    }
});

// ─── Waveform hover + click-and-hold scrubbing ──────────────────────────────
// Hover paints the spotlight + cursor line. Mousedown starts a scrub session
// bound to that canvas; document-level mousemove/mouseup drive it until
// release. A single click without drag is just a one-shot seek (mousedown
// already moves the playhead immediately).

let scrubbing = null;  // { canvas } while held down

function seekFromMouseEvent(canvas, e) {
    if (!previewState.audio || !previewState.audio.duration) return;
    const rect = canvas.getBoundingClientRect();
    const rel = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    previewState.audio.currentTime = rel * previewState.audio.duration;
    if (canvas.__peaks) drawWaveform(canvas, canvas.__peaks, rel, rel);
    canvas.dataset.hover = String(rel);
}

queueList.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;  // left button only
    const wf = e.target.closest('.qi-waveform');
    if (!wf) return;
    const tidalId = Number(wf.dataset.tidalId);
    const rect = wf.getBoundingClientRect();
    const rel = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));

    if (previewState.playingTidalId === tidalId) {
        // Currently playing — start a scrub session.
        if (!wf.__peaks) return;
        e.preventDefault();
        scrubbing = { canvas: wf };
        seekFromMouseEvent(wf, e);
    } else {
        // Different track (or nothing playing) — start this one from the
        // clicked position. Stops anything that was playing.
        e.preventDefault();
        const row = wf.closest('.queue-item');
        togglePreview(tidalId, row, { initialSeekRatio: rel });
    }
});

// Hover or active scrub drives the same redraw path.
queueList.addEventListener('mousemove', (e) => {
    if (scrubbing) return;  // scrubbing handled by document-level listener below
    const wf = e.target.closest?.('.qi-waveform');
    if (!wf || !wf.__peaks) return;
    const rect = wf.getBoundingClientRect();
    const rel = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    wf.dataset.hover = String(rel);
    const tidalId = Number(wf.dataset.tidalId);
    const progress = (previewState.playingTidalId === tidalId && previewState.audio && previewState.audio.duration)
        ? previewState.audio.currentTime / previewState.audio.duration
        : 0;
    drawWaveform(wf, wf.__peaks, progress, rel);
});

// While the button is held, follow the cursor anywhere on screen (so the user
// can drag off the canvas and still scrub). End on mouseup.
document.addEventListener('mousemove', (e) => {
    if (!scrubbing) return;
    seekFromMouseEvent(scrubbing.canvas, e);
});
document.addEventListener('mouseup', () => {
    if (!scrubbing) return;
    scrubbing = null;
});

// Use capture phase so we catch leaves off individual canvases reliably.
queueList.addEventListener('mouseout', (e) => {
    if (scrubbing) return;  // don't clear hover state while actively scrubbing
    const wf = e.target.closest?.('.qi-waveform');
    if (!wf || !wf.__peaks) return;
    if (wf.contains(e.relatedTarget)) return;
    delete wf.dataset.hover;
    const tidalId = Number(wf.dataset.tidalId);
    const progress = (previewState.playingTidalId === tidalId && previewState.audio && previewState.audio.duration)
        ? previewState.audio.currentTime / previewState.audio.duration
        : 0;
    drawWaveform(wf, wf.__peaks, progress, -1);
}, true);

// Window resize → the waveform's CSS width changes (flex: 1). Redraw any
// canvas that has cached peaks so it doesn't end up stretched. Debounced.
let _resizeRedrawTimer = null;
window.addEventListener('resize', () => {
    clearTimeout(_resizeRedrawTimer);
    _resizeRedrawTimer = setTimeout(() => {
        queueList.querySelectorAll('.qi-waveform').forEach(wf => {
            if (!wf.__peaks) return;
            const tidalId = Number(wf.dataset.tidalId);
            const progress = (previewState.playingTidalId === tidalId && previewState.audio && previewState.audio.duration)
                ? previewState.audio.currentTime / previewState.audio.duration
                : 0;
            drawWaveform(wf, wf.__peaks, progress);
        });
    }, 120);
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
    stopPreview();
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
        // Kick off waveform pre-loading for any track with a tidalId — peaks
        // paint in as they're ready, without requiring a play click.
        if (t.tidalId && !t.notFound) enqueuePreload(t.tidalId);
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
        playSuccessPing();
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
        if (which === 'extension') refreshExtensionInfo();
    });
});

// ─── Extension tab ──────────────────────────────────────────────────────────
const extensionUrlInput   = $('#extension-url-input');
const extensionTokenInput = $('#extension-token-input');
const extensionUrlCopy    = $('#extension-url-copy');
const extensionTokenCopy  = $('#extension-token-copy');
const extensionTokenRegen = $('#extension-token-regen');
const extensionPathInput  = $('#extension-path-input');
const extensionPathCopy   = $('#extension-path-copy');
const extensionPathOpen   = $('#extension-path-open');

async function refreshExtensionInfo() {
    try {
        const r = await api.extensionInfo();
        extensionUrlInput.value = `http://127.0.0.1:${r.port}`;
        extensionTokenInput.value = r.token || '(not generated yet — restart the app)';
        if (extensionPathInput) extensionPathInput.value = r.managedPath || '';
    } catch {
        extensionTokenInput.value = '(extension bridge unavailable)';
    }
}

function copyToClipboardField(inputEl, btnEl) {
    if (!inputEl.value) return;
    navigator.clipboard.writeText(inputEl.value).catch(() => {
        inputEl.select();
        try { document.execCommand('copy'); } catch {}
    });
    const orig = btnEl.textContent;
    btnEl.textContent = 'Copied ✓';
    setTimeout(() => { btnEl.textContent = orig; }, 1200);
}

extensionUrlCopy.addEventListener('click',   () => copyToClipboardField(extensionUrlInput, extensionUrlCopy));
extensionTokenCopy.addEventListener('click', () => copyToClipboardField(extensionTokenInput, extensionTokenCopy));
extensionTokenRegen.addEventListener('click', async () => {
    if (!confirm('Regenerate the extension token?\n\nThe Chrome extension will need the new token pasted in before it can talk to the app again.')) return;
    const r = await api.regenerateExtensionToken();
    if (r?.token) extensionTokenInput.value = r.token;
});
if (extensionPathCopy) {
    extensionPathCopy.addEventListener('click', () => copyToClipboardField(extensionPathInput, extensionPathCopy));
}
if (extensionPathOpen) {
    extensionPathOpen.addEventListener('click', () => {
        if (extensionPathInput.value) api.openFolder(extensionPathInput.value);
    });
}

// Tracks pushed from the Chrome extension arrive resolved (matched on TIDAL).
// Drop them into the queue via the standard add path.
api.onExtensionTracks(({ tracks }) => {
    if (!Array.isArray(tracks) || !tracks.length) return;
    const added = addTracksToQueue(tracks);
    const matched = tracks.filter(t => !t.notFound).length;
    const missing = tracks.length - matched;
    appendLine(`🎵 Spotify ext: added ${added} track${added === 1 ? '' : 's'} (${matched} matched on TIDAL${missing ? `, ${missing} not found` : ''}).`);
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

// ─── Tracklist import (CSV or pasted text) → queue ──────────────────────────
//
// Accepts:
//   • CSV files (Exportify or any tool that has Track Name + Artist columns)
//   • Plain-text files (one track per line, "Title - Artist")
//   • Pasted text from clipboard (anywhere not in an input)
// Bypasses the Spotify 100-track embed cap when the user has a full export.

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
    if (!file) return;
    try {
        const text = await file.text();
        await handleTracklistInput(text, file.name);
    } catch (err) {
        appendLine(`✗ Couldn't read ${file.name}: ${err.message}`);
    }
});

fileInput.addEventListener('change', async (e) => {
    const file = e.target.files[0];
    if (!file) return;
    try {
        const text = await file.text();
        await handleTracklistInput(text, file.name);
    } catch (err) {
        appendLine(`✗ Couldn't read ${file.name}: ${err.message}`);
    } finally {
        fileInput.value = '';
    }
});

// Clipboard paste — when no input is focused. Heuristic skips tiny / single-
// line pastes so a casual paste into the activity area doesn't trigger
// tracklist parsing.
document.addEventListener('paste', async (e) => {
    const tag = document.activeElement?.tagName;
    if (tag === 'INPUT' || tag === 'TEXTAREA') return;
    const text = e.clipboardData?.getData('text/plain') || '';
    if (text.length < 10) return;
    if (!text.includes('\n') && !text.includes(',') && !/\s[-—–|]\s/.test(text)) return;
    e.preventDefault();
    await handleTracklistInput(text, 'pasted text');
});

// Exportify shortcut: opens https://exportify.net in the user's browser.
// They log into Spotify there, pick the playlist, click Export, and drop
// the resulting CSV onto our drop-zone. Two clicks.
exportifyLink.addEventListener('click', (e) => {
    e.preventDefault();
    api.openExternal('https://exportify.net');
});

// Tracks the active tracklist resolve so progress events know whether to
// paint, and a duplicate paste while one is in flight gets ignored.
let _tracklistInFlight = false;
let _tracklistTotal = 0;

api.onTracklistProgress(({ done, total }) => {
    if (!_tracklistInFlight) return;
    // Trust the renderer's stored total in case the main-process value drifts.
    const n = _tracklistTotal || total;
    loadingTextEl.textContent = `Matching ${done} / ${n} tracks on TIDAL…`;
});

async function handleTracklistInput(text, sourceName) {
    if (_tracklistInFlight) return;  // another paste already resolving
    const tracks = parseTracklistText(text);
    if (!tracks.length) {
        appendLine(`✗ No tracks found in ${sourceName}.`);
        return;
    }
    appendLine(`📋 Parsed ${tracks.length} track${tracks.length === 1 ? '' : 's'} from ${sourceName}. Matching against TIDAL…`);

    _tracklistInFlight = true;
    _tracklistTotal = tracks.length;
    showLoading(`Matching 0 / ${tracks.length} tracks on TIDAL…`);
    try {
        const r = await api.resolveTracklist({ tracks });
        hideLoading();
        if (!r.ok) { appendLine(`✗ ${r.error}`); return; }

        const matched = r.tracks.filter(t => !t.notFound).length;
        const missing = r.tracks.length - matched;
        const added = addTracksToQueue(r.tracks);
        appendLine(`+ Added ${added} from import. ${matched} matched on TIDAL${missing ? `, ${missing} not found` : ''}.`);
    } catch (e) {
        hideLoading();
        appendLine(`✗ ${e.message}`);
    } finally {
        _tracklistInFlight = false;
        _tracklistTotal = 0;
    }
}

// Detects CSV vs plain-text automatically. CSV requires a header row that
// contains a recognizable "title" column.
function parseTracklistText(text) {
    if (looksLikeCsv(text)) {
        const fromCsv = parseCsvTracklist(text);
        if (fromCsv.length) return fromCsv;
    }
    return parsePlainTextTracklist(text);
}

function looksLikeCsv(text) {
    // First non-empty line has commas, and the file has multiple lines.
    const firstLine = (text.split(/\r?\n/).find(l => l.trim().length) || '');
    return firstLine.includes(',') && text.split(/\r?\n/).length >= 2;
}

// Small CSV parser with quoted-field support — handles fields with commas
// inside quotes, and "" as an escaped quote. Returns an array of row arrays.
function parseCsv(text) {
    const rows = [];
    let cur = []; let field = ''; let i = 0; let inQuote = false;
    while (i < text.length) {
        const c = text[i];
        if (inQuote) {
            if (c === '"' && text[i + 1] === '"') { field += '"'; i += 2; }
            else if (c === '"') { inQuote = false; i++; }
            else { field += c; i++; }
        } else {
            if (c === '"' && field === '') { inQuote = true; i++; }
            else if (c === ',') { cur.push(field); field = ''; i++; }
            else if (c === '\r') { i++; }
            else if (c === '\n') { cur.push(field); rows.push(cur); cur = []; field = ''; i++; }
            else { field += c; i++; }
        }
    }
    if (field !== '' || cur.length) { cur.push(field); rows.push(cur); }
    return rows;
}

function parseCsvTracklist(text) {
    const rows = parseCsv(text);
    if (rows.length < 2) return [];
    const header = rows[0].map(h => (h || '').toLowerCase().trim());
    const titleIdx = header.findIndex(h => /\btrack name\b|\btitle\b|\bsong\b|\bname\b/.test(h));
    const artistIdx = header.findIndex(h => /artist/.test(h));
    if (titleIdx < 0) return [];
    const out = [];
    const seen = new Set();
    for (let i = 1; i < rows.length; i++) {
        const r = rows[i];
        const title = (r[titleIdx] || '').trim();
        const artist = artistIdx >= 0 ? (r[artistIdx] || '').trim() : '';
        if (!title) continue;
        const key = `${title.toLowerCase()}|${artist.toLowerCase()}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ title, artist });
    }
    return out;
}

// Plain-text fallback. Each line is one track, separated by " - ", " — ",
// " | ", or a tab.
function parsePlainTextTracklist(text) {
    const lines = text.split(/\r?\n/).map(l => l.trim()).filter(Boolean);
    const out = [];
    const seen = new Set();
    for (const line of lines) {
        const m = line.match(/^(.+?)\s*[-—–|\t]\s*(.+)$/);
        let title, artist;
        if (m) { title = m[1].trim(); artist = m[2].trim(); }
        else   { title = line; artist = ''; }
        if (!title || title.length < 2) continue;
        const key = `${title.toLowerCase()}|${artist.toLowerCase()}`;
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ title, artist });
    }
    return out;
}

// ─── Boot ────────────────────────────────────────────────────────────────────

(async () => {
    settings = await api.getSettings();
    folderInput.value = settings.downloadFolder || '';
    libraryInput.value = settings.libraryFolder || '';
    // Restore saved preview volume (defaults to 60% if unset)
    volumeSlider.value = Math.round(getPreviewVolume() * 100);
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
            // Pre-load waveforms for the restored queue (concurrency-2, so a
            // long queue trickles in without blasting the network at once).
            for (const t of queue) {
                if (t.tidalId && !t.notFound) enqueuePreload(t.tidalId);
            }
        }
    } catch { /* no saved queue or read error — start empty */ }

    // Apply any update notice that arrived before the welcome line existed.
    if (pendingUpdate) {
        insertUpdateNotice(pendingUpdate);
        pendingUpdate = null;
    }
})();
