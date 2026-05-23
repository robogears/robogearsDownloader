# Building a scrubbable inline waveform preview

End-to-end guide to wiring a per-item audio preview with a dynamic, click-and-hold-scrubbable waveform display. Designed for an Electron app (or any browser-based UI) that already has a way to fetch raw audio bytes — could be a backend you control, a CDN, a local file, anything that produces a `Buffer` / `Uint8Array` of an audio container the browser can decode (FLAC, MP3, AAC-in-MP4, OGG, etc.).

The reward: each row in your list grows a small play button on the left and a waveform on the right. Click play, hear the audio, watch the waveform paint in. Hover and bars near the cursor swell up with a tracking line. Hold the left mouse button and drag to scrub through the audio in real time while it keeps playing — the "skim" effect.

---

## What you get

| Feature | UX |
|---|---|
| Per-item play button | Circular button on the left of each row. ▶ when idle, ⏸ when that row is playing, ◌ (spinning) while audio loads |
| Waveform display | Canvas-rendered bars showing the audio's amplitude envelope, scaled to the row width. Played portion bright; unplayed dim |
| Spotlight hover | Bars within ~10 of the cursor swell up to ~1.45×. A thin vertical cursor line tracks the mouse |
| Click to seek | Anywhere on the waveform → audio jumps to that point |
| Hold + drag to scrub | Mousedown anywhere + drag continuously updates `audio.currentTime`. Audio keeps playing during the drag. Release anywhere on screen ends the scrub |
| One playing item at a time | Clicking play on row B stops row A. The previous row's waveform resets to "unplayed" |
| Cached previews | Decoded peaks + Blob URL kept in an LRU map. Re-clicking a previously-previewed item is instant |

---

## Architecture

```
┌─ Audio source (your problem) ─────────────────────────────┐
│   Returns raw audio bytes + MIME type for a given item ID │
│   (Buffer / Uint8Array / ArrayBuffer)                     │
└────────────────────────────────────────────────────────────┘
                            │
                            ▼ (Buffer)
┌─ Renderer-side: decode + play ────────────────────────────┐
│                                                            │
│   For waveform:                                            │
│     audioContext.decodeAudioData(arrayBuffer)              │
│       → AudioBuffer                                        │
│       → channelData.getChannelData(0)                      │
│       → downsample to N peaks (max abs per bucket)         │
│       → discard AudioBuffer, keep Float32Array peaks       │
│                                                            │
│   For playback:                                            │
│     new Blob([bytes], { type: mimeType })                  │
│       → URL.createObjectURL(blob)                          │
│       → new Audio(blobUrl)                                 │
│                                                            │
│   Canvas paints peaks + animates playhead via              │
│   requestAnimationFrame while audio is playing.            │
└────────────────────────────────────────────────────────────┘
```

The key architectural choice: **decode for peaks AND play via blob URL — two independent paths through the same byte buffer**.

- `decodeAudioData` gives you the amplitude data you need to draw the waveform — but it doesn't give you a clean way to seek mid-playback (you'd have to restart a BufferSource with an offset).
- The HTML5 `<audio>` element handles play / pause / seek beautifully, but doesn't expose the underlying samples.

So you do both. The bytes are decoded once for peaks (cheap to keep — a few hundred bytes per track after downsampling), and stored in a blob that the `<audio>` element streams from.

---

## Component 1: Source the audio bytes

This is the part you have to write yourself. You need a way to go from "the user clicked play on item X" to "I have the raw audio bytes for item X."

Options:
- **Electron main-process IPC** — main fetches the audio (auth, signed URLs, whatever) and ships a `Buffer` back to the renderer via `ipcMain.handle`. Buffers go through Electron IPC cleanly via structured clone.
- **Plain `fetch()` in renderer** — if the audio source allows CORS, just fetch it directly.
- **Pre-bundled local audio** — `fetch('/path/to/file.mp3')` from your app's assets.

```js
// Renderer side, after sourcing bytes:
const bytes = await fetchAudioBytesSomehow(itemId);   // Uint8Array / Buffer
const mimeType = 'audio/mpeg';                         // or audio/flac, audio/mp4, etc.
```

**MIME matters.** The `<audio>` element decides whether it can play based on the blob's `type`. Common values:
- MP3: `audio/mpeg`
- FLAC standalone: `audio/flac`
- FLAC or AAC in MP4 container (fragmented MP4, MPEG-DASH segments concatenated): `audio/mp4`
- AAC raw: `audio/aac`
- OGG Vorbis: `audio/ogg`

If you're unsure of the codec inside an MP4 container, just `audio/mp4` works for Chromium-based engines (Electron, Chrome). The browser will sniff and decide.

**Don't preview DRM-encrypted streams** — `decodeAudioData` will reject and the `<audio>` element will silently refuse to play. Detect encryption upstream and skip those rows.

---

## Component 2: Decode for peaks

This is the part most people get wrong. Two non-obvious things:

**(a) `decodeAudioData` detaches its input ArrayBuffer.** If you hand it the same buffer you want to put in the Blob, you'll get a `DataCloneError` later. Slice it:

```js
const audioBuffer = await audioCtx.decodeAudioData(rawArrayBuffer.slice(0));
```

The `.slice(0)` makes a fresh copy; the original stays available for the Blob.

**(b) Don't keep the AudioBuffer around.** A decoded 4-minute stereo track at 44.1 kHz is ~84 MB of Float32 PCM data. Hold N of those in a cache and you'll OOM the renderer. Extract peaks immediately, then drop the AudioBuffer.

Full extractor:

```js
function computePeaks(audioBuffer, numBars) {
    const channelData = audioBuffer.getChannelData(0);  // mono down-mix is fine for waveform
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
    // Normalize to [0..1] so quiet tracks aren't invisible
    let maxPeak = 0;
    for (let i = 0; i < peaks.length; i++) if (peaks[i] > maxPeak) maxPeak = peaks[i];
    if (maxPeak > 0) for (let i = 0; i < peaks.length; i++) peaks[i] /= maxPeak;
    return peaks;
}
```

`numBars` choice: 200 is a good default. Means each bar represents ~1.2 seconds of a 4-minute track. Enough resolution to see drops and breakdowns; small enough to render in under a millisecond.

Storage: a `Float32Array(200)` is 800 bytes. Cache thousands of these without worrying.

**Use max-abs, not RMS, for the bucket value.** Max-abs gives you peaks that look like the visual waveform you'd see in Audacity. RMS would give you a smoother but visually-flatter envelope. Max is what users expect.

---

## Component 3: Canvas rendering

The canvas needs to handle three states overlaid:
1. The base waveform bars (peaks)
2. A "played" coloring up to the current playback progress
3. A spotlight effect under the cursor (when hovering)

Plus the boilerplate of high-DPI display handling (otherwise the bars look fuzzy on retina screens).

```js
function drawWaveform(canvas, peaks, progress = 0, hover = -1) {
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const cssWidth = canvas.clientWidth || canvas.width;
    const cssHeight = canvas.clientHeight || canvas.height;

    // Resize the canvas bitmap to match physical pixels (sharp on retina)
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

        // Spotlight: bars within ~10 of the cursor swell up.
        let boost = 1;
        if (hoverBar >= 0) {
            const dist = Math.abs(i - hoverBar);
            if (dist < 10) boost = 1 + (1 - dist / 10) * 0.45;  // up to 1.45x
        }

        const h = Math.max(1, peaks[i] * cssHeight * 0.78 * boost);
        ctx.fillStyle = isPlayed ? '#ffffff' : 'rgba(255, 255, 255, 0.22)';
        ctx.fillRect(x, midY - h / 2, Math.max(1, barWidth - 1), h);
    }

    // Cursor line — thin vertical thread tracking the mouse
    if (hover >= 0) {
        ctx.fillStyle = 'rgba(255, 255, 255, 0.55)';
        const cx = Math.floor(hover * cssWidth);
        ctx.fillRect(cx, 2, 1, cssHeight - 4);
    }
    ctx.restore();
}
```

Notes:
- `progress` is in `[0, 1]` — `audio.currentTime / audio.duration`
- `hover` is also `[0, 1]` — the mouse's relative X position within the canvas, or `-1` if not hovering
- Played bars are pure white; unplayed are 22% white. Tune for your theme — this assumes a dark background
- `boost` curve: linear falloff over 10 bars. Tweak the `0.45` to make the spotlight more or less pronounced
- Bar heights have a `Math.max(1, ...)` floor so even silent sections show a 1-px line, not nothing

**HTML for the canvas:**

```html
<canvas class="qi-waveform" data-id="${itemId}" height="22" title="Click or drag to scrub"></canvas>
```

Notable: no `width` attribute. The canvas's CSS width comes from your layout (e.g., `flex: 1 1 auto; min-width: 80px;`), and `drawWaveform` adapts the bitmap to whatever the layout gave it. Set `height="22"` though — without it, the canvas defaults to 150 px tall, which is too much.

**Redraw on window resize.** Flex-sized canvases get stretched when the window changes width. Debounce a resize listener:

```js
let _resizeTimer;
window.addEventListener('resize', () => {
    clearTimeout(_resizeTimer);
    _resizeTimer = setTimeout(() => {
        document.querySelectorAll('.qi-waveform').forEach(wf => {
            if (wf.__peaks) drawWaveform(wf, wf.__peaks, currentProgressFor(wf));
        });
    }, 120);
});
```

Stash the peaks reference on the canvas itself (`canvas.__peaks = peaks`) so the redraw loop doesn't need to consult the cache.

---

## Component 4: Audio playback + animation sync

The simplest possible thing works: one shared `HTMLAudioElement`, swap its `src` between Blob URLs.

```js
const audio = new Audio(blobUrl);
audio.volume = 0.6;     // not full-blast on first click
audio.preload = 'auto';
await audio.play();
```

To animate the playhead, run a `requestAnimationFrame` loop while the audio is playing:

```js
function tick() {
    if (!currentlyPlaying) return;
    const a = currentlyPlaying.audio;
    const progress = a.duration ? a.currentTime / a.duration : 0;
    const canvas = canvasFor(currentlyPlaying.itemId);
    if (canvas) {
        const hover = parseFloat(canvas.dataset.hover);
        drawWaveform(canvas, canvas.__peaks, progress, isFinite(hover) ? hover : -1);
    }
    if (!a.paused) requestAnimationFrame(tick);
}

audio.addEventListener('play', () => requestAnimationFrame(tick));
audio.addEventListener('pause', () => updatePlayButton('idle'));
audio.addEventListener('ended', () => stopPlayback());
audio.addEventListener('error', () => stopPlayback());
```

**One playing thing at a time.** When the user clicks play on a different row, stop the current audio before starting the new one. Otherwise you'll have multiple `tick` loops running and competing audio.

```js
function stopPlayback() {
    if (currentlyPlaying?.audio) {
        try { currentlyPlaying.audio.pause(); } catch {}
        try { currentlyPlaying.audio.src = ''; } catch {}  // releases the blob URL ref
    }
    currentlyPlaying = null;
    // Repaint the previous track's waveform with progress=0
}
```

---

## Component 5: Click, hover, and hold-to-scrub

Three interactions on the waveform, in increasing order of complexity:

**Hover** — paint the spotlight + cursor line. Pure cosmetic.

```js
queueList.addEventListener('mousemove', (e) => {
    if (scrubbing) return;  // scrubbing handled separately
    const wf = e.target.closest('.qi-waveform');
    if (!wf?.__peaks) return;
    const rect = wf.getBoundingClientRect();
    const rel = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    wf.dataset.hover = String(rel);
    drawWaveform(wf, wf.__peaks, progressFor(wf), rel);
});
queueList.addEventListener('mouseout', (e) => {
    if (scrubbing) return;
    const wf = e.target.closest('.qi-waveform');
    if (!wf?.__peaks) return;
    if (wf.contains(e.relatedTarget)) return;  // moving WITHIN the canvas, not leaving
    delete wf.dataset.hover;
    drawWaveform(wf, wf.__peaks, progressFor(wf), -1);
}, true);
```

**Click + hold-to-scrub** — this is the part that makes the whole thing feel premium. The pattern:

1. **`mousedown` on the canvas** → start a scrub session (record which canvas)
2. **`mousemove` on the document** (not the canvas) → if scrubbing, update audio.currentTime continuously
3. **`mouseup` on the document** → end the scrub

Why document-level for mousemove and mouseup? Because the user might drag *off* the canvas (off the queue list entirely) and you still want the scrub to follow the cursor. They release the button when they're done, wherever they are.

```js
let scrubbing = null;  // { canvas } while held down

function seekFromMouseEvent(canvas, e) {
    if (!currentlyPlaying?.audio?.duration) return;
    const rect = canvas.getBoundingClientRect();
    const rel = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    currentlyPlaying.audio.currentTime = rel * currentlyPlaying.audio.duration;
    if (canvas.__peaks) drawWaveform(canvas, canvas.__peaks, rel, rel);
    canvas.dataset.hover = String(rel);
}

queueList.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;  // left button only
    const wf = e.target.closest('.qi-waveform');
    if (!wf?.__peaks) return;
    if (currentlyPlaying?.itemId !== Number(wf.dataset.id)) return;  // only scrub the playing track
    e.preventDefault();  // suppress text selection
    scrubbing = { canvas: wf };
    seekFromMouseEvent(wf, e);  // immediate seek on initial click
});

document.addEventListener('mousemove', (e) => {
    if (!scrubbing) return;
    seekFromMouseEvent(scrubbing.canvas, e);
});

document.addEventListener('mouseup', () => {
    if (!scrubbing) return;
    scrubbing = null;
});
```

**Critical detail: only scrub the currently-playing track.** If the user mousedowns on a different row's waveform, do nothing (or treat it as a click that starts that row playing — your choice). Otherwise you'd be modifying `currentTime` on the wrong audio element.

**Audio doesn't pause during scrub.** Setting `audio.currentTime = N` while `audio.paused === false` makes the playhead jump and keep playing from the new position. That's the "skim" effect — drag across and hear bits of the song flying by.

---

## Component 6: Cache strategy

Decoding takes a few hundred milliseconds for a 4-minute track. Don't repeat it. Cache the decoded peaks + the Blob URL keyed by item ID.

Use a `Map` (ordered iteration) for LRU eviction:

```js
const cache = new Map();
const MAX_CACHE = 3;

async function loadPreview(itemId) {
    if (cache.has(itemId)) {
        // LRU bump: re-insert moves to end of iteration order
        const entry = cache.get(itemId);
        cache.delete(itemId);
        cache.set(itemId, entry);
        return entry;
    }

    const { bytes, mimeType } = await fetchAudioBytesSomehow(itemId);
    const ab = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);

    const audioBuffer = await audioCtx.decodeAudioData(ab.slice(0));  // detaches input
    const peaks = computePeaks(audioBuffer, 200);

    const blob = new Blob([ab], { type: mimeType });
    const blobUrl = URL.createObjectURL(blob);

    const entry = { peaks, blobUrl };
    cache.set(itemId, entry);
    evictOldEntries();
    return entry;
}

function evictOldEntries() {
    while (cache.size > MAX_CACHE) {
        const oldest = cache.keys().next().value;
        if (oldest === currentlyPlaying?.itemId) {
            // Don't evict what's playing — bump it instead
            const entry = cache.get(oldest);
            cache.delete(oldest);
            cache.set(oldest, entry);
            continue;
        }
        URL.revokeObjectURL(cache.get(oldest).blobUrl);
        cache.delete(oldest);
    }
}
```

**`URL.revokeObjectURL` matters.** Each `URL.createObjectURL` allocates browser memory until you revoke it. Forget this and you'll leak the Blob (and the audio bytes inside it) for the lifetime of the page.

**`MAX_CACHE = 3`** is a reasonable default. Each entry: ~800 bytes of peaks + the Blob URL holding the original bytes (which the Blob keeps alive — call it ~30 MB for a lossless track). Tune based on your audio source bitrate.

---

## Component 7: Persistence across DOM re-renders

If your row list re-renders (e.g., on every state change), the canvas elements get destroyed and recreated. The `canvas.__peaks` reference is gone with them — but the cache survives.

After each row is created, check the cache and repaint:

```js
function renderRow(item) {
    const row = document.createElement('div');
    row.innerHTML = `<canvas class="qi-waveform" data-id="${item.id}" height="22"></canvas>`;
    list.appendChild(row);

    if (cache.has(item.id)) {
        const canvas = row.querySelector('.qi-waveform');
        canvas.__peaks = cache.get(item.id).peaks;
        const progress = currentlyPlaying?.itemId === item.id
            ? currentlyPlaying.audio.currentTime / currentlyPlaying.audio.duration
            : 0;
        drawWaveform(canvas, canvas.__peaks, progress);
    }
}
```

If a re-render kills the canvas of the currently-playing track, you also want to restore the play button state to ⏸. Same pattern: check `currentlyPlaying.itemId` against the new row's ID.

---

## Hard-learned gotchas

| Symptom | Cause | Fix |
|---|---|---|
| `DataCloneError` from `decodeAudioData` | The ArrayBuffer was already consumed (it gets detached on decode). | Pass `arrayBuffer.slice(0)` to `decodeAudioData` so the original is preserved for the Blob. |
| Waveform looks fuzzy on retina screens | Canvas bitmap is at CSS pixel size, not device pixel size. | Multiply `canvas.width/height` by `window.devicePixelRatio`, then `ctx.scale(dpr, dpr)` before drawing. |
| Quiet tracks show a flat line | Peaks aren't normalized — max value in the track is, say, 0.2 instead of 1.0. | Find the max peak, divide all peaks by it. Loud-quiet differences still preserved, just rescaled. |
| Waveform stretches weirdly when window resizes | Canvas bitmap stays at old size while CSS width grew. | Resize listener that calls `drawWaveform` (which checks `clientWidth` and re-allocates the bitmap). Debounce ~100ms. |
| Multiple audio streams play at once | Each play click creates a new `<audio>` but doesn't stop the previous. | Single shared `currentlyPlaying` state. Stop before starting a new one. |
| Memory grows unboundedly during a session | Each play creates a Blob URL; nothing revokes them. | `URL.revokeObjectURL` in the cache eviction path. Don't forget the currently-playing entry when shutting down. |
| Hold-to-scrub stops working when user drags off the canvas | `mousemove` listener is on the canvas, which only fires when the cursor is *over* it. | Put `mousemove`/`mouseup` listeners on `document`, not the canvas. Start the scrub session on canvas `mousedown`. |
| `audio.currentTime = N` makes the audio briefly stutter | Seeking forces a decode-flush; on slow systems this is audible. | Acceptable for an MVP. If you really need smooth scrub-while-playing, decode the *whole* track into an AudioBuffer and use a `BufferSource` you restart with offsets — but that's much more code for marginal UX. |
| First click on a new track shows a long delay before any sound | Full audio file is being fetched + decoded synchronously. | Show a loading state on the play button (spinner). Cache aggressively so repeat clicks are instant. Consider fetching at a lower-bitrate quality if your source offers one. |
| `<audio>` element silently does nothing | MIME type on the Blob doesn't match the actual codec, OR the codec isn't supported in your runtime. | Verify with `audio.error` after the load — code 4 means "format not supported." Make sure the Blob's `type` matches the bytes (e.g., `audio/mp4` for fragmented MP4, even if FLAC is inside). |
| Spotlight effect looks bad with very few bars | If `peaks.length < 20`, the hover distance check (within 10 bars) covers half the waveform. | Either increase `numBars` to at least 100, or scale the spotlight range as a fraction of `peaks.length`. |
| Click-and-release at the same point doesn't seek | Sometimes the click handler fires before the mousedown's seek is committed. | Don't use a `click` handler for seek — let the `mousedown` handler do the seek immediately. A click is just a mousedown + immediate mouseup, which is naturally a one-shot seek. |

---

## CSS sketch

Bare minimum to make it look right. Adapt to your theme.

```css
.qi-play {
    width: 28px; height: 28px;
    border-radius: 50%;
    background: transparent;
    border: 1px solid var(--border);
    color: var(--text-muted);
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0;
    transition: color 0.15s, border-color 0.15s, background 0.15s;
}
.qi-play svg { display: block; }
.qi-play:hover { color: var(--text); border-color: var(--text); }
.qi-play.playing { color: var(--bg); background: var(--text); border-color: var(--text); }
.qi-play.loading { border-style: dashed; animation: spin 1.2s linear infinite; }

.qi-waveform {
    flex: 1 1 auto;
    min-width: 80px;
    height: 22px;
    cursor: pointer;
    display: block;
    border-radius: 4px;
    transition: background 0.12s;
}
.qi-waveform:hover { background: rgba(255, 255, 255, 0.03); }

@keyframes spin { to { transform: rotate(360deg); } }
```

Inline SVG icons for play / pause (precise centering, no unicode whitespace surprises):

```js
const PLAY_ICON  = '<svg viewBox="0 0 10 10" width="9" height="9"><polygon points="2,1 9,5 2,9" fill="currentColor"/></svg>';
const PAUSE_ICON = '<svg viewBox="0 0 10 10" width="9" height="9"><rect x="2" y="1.5" width="2" height="7" fill="currentColor"/><rect x="6" y="1.5" width="2" height="7" fill="currentColor"/></svg>';
const LOADING_ICON = '<svg viewBox="0 0 10 10" width="9" height="9"><circle cx="5" cy="5" r="3.5" fill="none" stroke="currentColor" stroke-width="1.2" stroke-dasharray="4 3"/></svg>';
```

---

## Integration checklist

For an agent dropping this into a new project, in order:

- [ ] Get raw audio bytes for an item ID. Backend IPC if Electron + need auth; plain `fetch()` otherwise. Return `{ bytes, mimeType }`.
- [ ] Add a play button + canvas to each row's HTML. Wire the play button to call `togglePreview(itemId, row)`.
- [ ] Implement `togglePreview`: if same track → pause/resume. If different track → `stopPlayback()` then `loadPreview()` then `new Audio(blobUrl).play()`.
- [ ] Implement `loadPreview`: cache lookup → on miss, fetch bytes, `decodeAudioData(ab.slice(0))`, `computePeaks(buf, 200)`, build Blob URL, cache, evict.
- [ ] Implement `drawWaveform` with DPR scaling, played/unplayed coloring, spotlight, cursor line.
- [ ] Wire `requestAnimationFrame` tick: redraw the playing track's canvas with current progress.
- [ ] Wire hover: `mousemove` on the container, repaint with hover position. `mouseout` clears hover.
- [ ] Wire hold-to-scrub: `mousedown` on canvas (only for the playing track) starts session. `mousemove` on **document** continuously seeks. `mouseup` on **document** ends.
- [ ] Wire resize: window resize debounced redraw of all visible canvases.
- [ ] Wire re-render persistence: after each row is rendered, check the cache and repaint immediately if peaks exist.
- [ ] Add LRU eviction with `URL.revokeObjectURL`.
- [ ] Hide preview controls on rows where preview doesn't make sense (currently downloading, no source, DRM-locked).

About 250–400 lines of JS depending on how much you factor out. Pure rendering and event wiring — no external libraries needed (no wavesurfer.js, no howler.js, none of that). Web Audio + Canvas2D + the HTML5 `<audio>` element are everything you need.

---

## When to NOT build it this way

If you need any of:
- **Multi-track mixing** — Web Audio's full graph is more appropriate; use `AudioBufferSourceNode` and route through the AudioContext destination
- **Real-time DSP** (filters, EQ, effects) during scrub — same; route through AnalyserNode + filters
- **Spectrogram display** instead of waveform — FFT via `AnalyserNode.getByteFrequencyData` and render frequency bins, not amplitude peaks
- **Streaming playback** without downloading the full track — Media Source Extensions (MSE) territory; you'd append chunks to a `SourceBuffer` and the `<audio>` element plays the partial stream. Much more code, useful when the track is huge or the source is segmented (DASH / HLS)

But for the common case — short to medium-length audio clips, one-at-a-time playback, simple amplitude visualization, click-to-seek + hold-to-scrub — Web Audio decode + Canvas + `<audio>` blob playback is the sweet spot. Simple to reason about, fast to ship, no library lock-in.
