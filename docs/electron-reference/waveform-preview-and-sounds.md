## Waveform preview player and sound effects

### Overview

All audio in the app window is produced by `renderer/app.js`. It has two parts, and they share nothing except the audio output device.

**Sound effects** (`renderer/app.js:96-270`) are short cues synthesized on the fly with the Web Audio API (oscillators, gain envelopes and a lowpass filter). No audio files ship with the app. There are five live cues and one unused one:
- a rising two-note chime when a download batch starts;
- a falling chime when a batch is cancelled;
- a three-note bell arpeggio when the batch process exits with code 0;
- a low two-tone "wrong" honk when a download action is blocked;
- an easter-egg "fart" when the topbar logo or name is clicked, pitched up 7× when the version label is clicked.

All cues play at a fixed loudness. The preview volume slider does not affect them.

**Inline preview** (`renderer/app.js:501-881`, `949-996`, `1061-1222`, `1247-1270`, `1941-1995`, plus IPC `preview:get-audio` in `electron-main.js:814-917`). Every queue row that has a TIDAL track id gets a round play button and a 22 px tall waveform.
- **Fetch.** The main process downloads the *entire* track at TIDAL's `LOSSLESS` tier and returns the bytes to the renderer.
- **Decode and play.** The renderer decodes the bytes once to compute 200 waveform bars. It plays the same bytes through a detached HTML `<audio>` element (one not inserted into the page) that points at a Blob URL. Only one preview plays at a time.
- **Waveform.** Played bars are solid white and unplayed bars are 22 % white. Under the mouse, nearby bars swell ("spotlight") and a thin cursor line follows the pointer.
- **Seeking.** Pressing on the current track's waveform seeks. Holding and dragging keeps seeking while the audio plays (a "skim"). Pressing on another row's waveform starts that track at the clicked point.
- **Preloading.** A background preloader fetches waveforms, two at a time, for every track added to the queue, so a waveform is usually painted before the user presses play.
- **Volume.** A slider sits in the queue header. The stored value is the slider position; the playback gain is its square.

The defects that matter most for the port are listed under Bugs and oddities:
- a missing `token.json` makes the preview fetch end the whole app;
- a second click during loading leaves an audio element playing that no control can stop;
- the saved volume is restored to the wrong slider position;
- on Retina screens a hidden waveform canvas doubles its bitmap size on every animation frame.

### Components

#### A. Sound effects

**A1. `getAudioCtx()`: shared context for sound effects** (`renderer/app.js:96-109`)
1. If the module variable `_audioCtx` is null, take `window.AudioContext || window.webkitAudioContext`. If neither exists, return `null`. Otherwise create a context with default options (hardware output sample rate) and keep it.
2. If its `state` is `'suspended'`, call `resume()`. The call is not awaited and a rejection is not handled.
3. Return the context. It is never closed, and it is a different context from the one the preview uses for decoding (C3).
- Every sound function returns silently when it gets `null`.
- The comment at `app.js:97-99` says every caller is a click handler. `playSuccessPing` is in fact called from the `download:done` IPC event (`app.js:1457-1461`).
- No sound call is wrapped in try/catch, and every call site plays the sound *before* the action it accompanies. For example, `playCancelChime()` runs before `api.cancelDownload()` (`app.js:1376-1383`), and `playDownloadChime()` runs before `setDownloading(true)` / `api.startBulk` (`app.js:1441-1453`). If creating or using the context ever threw, the action would not run. Whether `new AudioContext()` can throw in Electron is unverified (needs a run).

**A2. The two-sine "blip/bell" voice shared by three sounds** (`app.js:114-132`, `143-161`, `246-264`)
- **Graph.** One note is two `OscillatorNode`s of type `sine`, one at `f` and one at `f × 1.005` (about +8.6 cents, which gives a slow beat). Both feed one `GainNode`, which feeds `ctx.destination`.
- **Gain automation.** With `start` = note start and `dur` = note length:
  1. `setValueAtTime(0.0001, start)`
  2. `exponentialRampToValueAtTime(0.22, start + attack)`. Attack is 0.012 s for the chimes and 0.008 s for the success bells.
  3. `exponentialRampToValueAtTime(0.0001, start + dur)`
- **Timing.** Both oscillators `start(start)` and `stop(start + dur + 0.05)`.
- **Level.** One note peaks at about 0.44 (two unit sines × 0.22). Where two notes overlap, the sum can reach about 0.88.

**A3. `playDownloadChime()`: "starting"** (`app.js:110-136`). `t = ctx.currentTime + 0.02`. Notes: 523.25 Hz (C5) at `t` for 0.13 s, then 783.99 Hz (G5) at `t + 0.09` for 0.18 s, overlapping the C5. Audible until `t + 0.27`; the oscillators stop at `t + 0.32`.

**A4. `playCancelChime()`: "stopping", the mirror of A3** (`app.js:137-165`). G5 at `t` for 0.10 s, then C5 at `t + 0.07` for 0.15 s. Audible until `t + 0.22`.

**A5. `playSuccessPing()`: "batch finished"** (`app.js:240-270`). Three bells with the A2 voice and a 0.008 s attack: 783.99 Hz (G5) at `t` for 0.28 s, 1046.50 Hz (C6) at `t + 0.07` for 0.32 s, and 1318.51 Hz (E6) at `t + 0.14` for 0.42 s. Audible until `t + 0.56`, about 560 ms.

**A6. `_honkPair(highFreq, lowFreq, opts)`, `playWarningHonk()`, `playClownHorn()`** (`app.js:166-195`)
- **Options.** `lpFreq = opts.lpFreq ?? 1800` and `peak = opts.peak ?? 0.35`.
- **Graph of one honk.** A `sawtooth` `OscillatorNode` feeds a `BiquadFilterNode` of type `lowpass` (`frequency = lpFreq`, `Q = 1`; Web Audio's lowpass Q is in dB). That feeds a `GainNode`, which feeds the destination.
- **Pitch.** `setValueAtTime(freq × 1.08, start)`, then `exponentialRampToValueAtTime(freq, start + dur × 0.5)`, then held.
- **Gain.** `0.0001` at `start`, exponential to `peak` at `start + 0.012`, exponential to `0.0001` at `start + dur`. The oscillator stops at `start + dur + 0.05`.
- **Sequence.** `t = currentTime + 0.02`, then `honk(highFreq, t, 0.17)` and `honk(lowFreq, t + 0.22, 0.22)`. That leaves a 50 ms gap between the honks; the pair is audible until `t + 0.44`.
- **`playWarningHonk()`** is `_honkPair(220, 165, { lpFreq: 1100, peak: 0.3 })`. Its pitch glides 237.6 → 220 Hz over 85 ms, then 178.2 → 165 Hz over 110 ms.
- **`playClownHorn()`** is `_honkPair(420, 310)`: 453.6 → 420 Hz, then 334.8 → 310 Hz, lowpass 1800 Hz, peak 0.35. It is never called anywhere (dead code). The comment on `_honkPair` still refers to the removed "Coming soon" easter egg.

**A7. `playFart({ pitchScale = 1 })`: easter egg** (`app.js:196-239`). Let `ps = pitchScale`, `t = currentTime + 0.02` and `duration = 0.42`.
- **Main oscillator.** `sawtooth`, with `frequency.setValueAtTime(95 × ps, t)` and `exponentialRampToValueAtTime(48 × ps, t + 0.42)`.
- **LFO (wobble).** A `sine` oscillator at `17 × √ps` Hz feeds a `GainNode` with `gain = 18 × ps`, which is connected to the main oscillator's `frequency` AudioParam. Web Audio sums connected signals into a parameter, so the instantaneous frequency is the ramp ± `18·ps` Hz.
- **Filter.** `BiquadFilterNode` lowpass, `frequency = 480 × ps`, `Q = 2.2` (dB).
- **Output gain.** `0.0001` at `t`, exponential to `0.42` at `t + 0.02`, *linear* to `0.32` at `t + 0.189` (0.42 × 0.45), exponential to `0.0001` at `t + 0.42`.
- **Graph and timing.** osc → lowpass → gain → destination. Both oscillators start at `t` and stop at `t + 0.47`.
- **Resulting values.** At `ps = 1`: 95 → 48 Hz, LFO 17 Hz ±18 Hz, cutoff 480 Hz. At `ps = 7`: 665 → 336 Hz, LFO about 44.98 Hz ±126 Hz, cutoff 3360 Hz.

**A8. Brand click router** (`app.js:491-499`; markup `index.html:11-24`; CSS `styles.css:43-63`). A `click` listener on `#brand` checks the target:
- inside `.brand-version` → `playFart({ pitchScale: 7 })`;
- inside `.brand-logo` (the 22 px SVG) or `.brand-name` → `playFart()`;
- anything else → nothing.

The topbar is a window drag region (`-webkit-app-region: drag`). Only `.brand-logo`, `.brand-name`, `.brand-version` and `<button>`s are marked `no-drag`, so only those receive clicks. The `#brand-update-pill` button sits inside `#brand` but matches none of the selectors, so it never plays the sound.

**A9. Where each sound fires**

| Sound | Trigger | Location | Condition |
|---|---|---|---|
| Download chime | "Download all" | `app.js:1441` | Plays after the checks pass (folder set, token exists, at least 1 downloadable item) and before `setDownloading(true)` and `api.startBulk`. The `startBulk` result is never checked. |
| Download chime | "↻ Retry all (N)" / "↻ Retry selected (M)" | `app.js:1413` | Not downloading, at least 1 target, folder set |
| (no sound) | Per-row "↻ Retry" | `app.js:1093-1113` | Starts a one-track batch silently |
| Cancel chime | Queue-header "Cancel" | `app.js:1376` | Only while `isDownloading`; plays before `api.cancelDownload()` |
| Success ping | `download:done` with `code === 0` | `app.js:1459-1461` | The batch child exits with code 0, which `bulk_runner.js` does even when every track failed (`bulk_runner.js:63-114`) |
| Warning honk | Download all with no download folder | `app.js:1422` | |
| Warning honk | Download all with no TIDAL token | `app.js:1427` | |
| Warning honk | Download all with nothing downloadable | `app.js:1436` | |
| Warning honk | Retry all/selected with no folder | `app.js:1404` | |
| Warning honk | Per-row Retry with no folder | `app.js:1103` | |
| (log line only) | Per-row Retry while a batch runs; "Add to queue" with no token | `app.js:1098-1100`, `1290-1292` | |
| Fart ×1 / ×7 | Click the logo or name / the version label | `app.js:495-499` | |
| Clown horn | Never | `app.js:194` | Dead code |

A cancelled batch ends with exit code `null` on macOS, because the child is killed with `activeChild.kill()` (`electron-main.js:646-653`, `1034-1038`). So a cancel gets no ping, and the log shows `=== Exit code null ===` (`app.js:1463`).

#### B. Preview volume

**B1. Curve** (`app.js:501-513`)
- `sliderToAudioVolume(linear)` returns `clamp(linear, 0, 1)²`.
- `getPreviewVolume()` returns `sliderToAudioVolume(settings.volume)` when `settings.volume` is a number, otherwise `sliderToAudioVolume(0.5)` = 0.25.
- Examples: slider 50 % → gain 0.25; 10 % → 0.01; 100 % → 1.

**B2. Slider control** (markup `index.html:62-69`; handler `app.js:515-524`; boot restore `app.js:1947-1948`; CSS `styles.css:467-511`)
- **Markup.** `<input id="volume-slider" type="range" min="0" max="100" value="50" aria-label="Preview volume">` inside `.queue-volume`, which has the title "Preview volume" and a 14 px speaker SVG. It sits to the right of the "Queue N" heading. The whole queue section, including the slider, is hidden while the queue is empty (`app.js:892`).
- **On every `input` event:**
  1. `linear = slider.value / 100` and `settings.volume = linear`.
  2. If a preview element exists, set `audio.volume = linear²` immediately.
  3. Restart a 300 ms timer. When it fires, `api.saveSettings(settings)` sends the **entire** settings object over IPC `settings:save`, and main writes it to `<userData>/settings.json` as JSON with 2-space indentation (`electron-main.js:26`, `42-52`, `556`). The promise is neither awaited nor caught, and a change made less than 300 ms before quitting is lost.
- **New preview elements** get `audio.volume = getPreviewVolume()` (`app.js:826`).
- **Boot.** `volumeSlider.value = Math.round(getPreviewVolume() * 100)`. This puts the *squared gain* on the slider instead of the stored position (see Bugs). The comment above it says the default is 60 %; the code default is 0.5.
- **CSS.** The track is 80 × 3 px, background `#1a1a1a` (`--border`), fully rounded. The thumb is a 12 px white circle that scales to 1.18× on hover with a 0.1 s transition.
- The sound effects ignore this slider.

#### C. Preview player (renderer)

**C1. Feature flag** `PREVIEW_FEATURE_ENABLED = true` (`app.js:56-58`). When it is false:
- rows get no play button or canvas (`app.js:951-956`);
- the cached-waveform repaint after a re-render is skipped (`app.js:981`);
- `enqueuePreload` returns immediately (`app.js:731`).

Nothing else checks the flag.

**C2. State** (`app.js:526-559`)
```
previewState = {
  playingTidalId: number | null,                // track of the current element
  audio: HTMLAudioElement | null,               // the single current element, never in the DOM
  audioCtx: AudioContext | null,                // used only for decodeAudioData
  peaksCache: Map<number, Float32Array(200)>,   // never evicted or cleared
  audioCache: Map<number, { blobUrl: string }>, // LRU using Map insertion order
  MAX_AUDIO_CACHE: 3,
}
preloader = { queue: number[] /* FIFO */, inFlight: number, CONCURRENCY: 2 }
```
The comment at `app.js:532-534` still describes an older single cache that held peaks and a Blob URL together. The two-tier comment at `536-542` matches the code. It estimates about 30 MB pinned per `audioCache` entry.

**C3. `getPreviewCtx()`** (`app.js:561-569`) follows the same lazy pattern as A1 but stores the context in `previewState.audioCtx`. It is used only for `decodeAudioData`, which resamples to this context's sample rate. Playback never goes through Web Audio. The context is never closed. It is first created by the preloader, usually at boot, with no user gesture.

**C4. `fetchAudioBytesIpc(tidalId)`** (`app.js:668-678`)
1. `r = await api.getPreviewAudio(tidalId)`, which is an IPC invoke of `preview:get-audio` with `{ tidalId }` (`electron-preload.js:50`).
2. If `!r.ok`, `throw new Error(r.error || 'preview fetch failed')`.
3. `r.audioBytes` arrives as a `Uint8Array`, because Electron's IPC copies the main-process `Buffer` (structured clone). Copy exactly its range into a new `ArrayBuffer` with `bytes.buffer.slice(byteOffset, byteOffset + byteLength)`.
4. Return `{ ab, mimeType: r.mimeType || 'audio/flac' }`. Nothing is cached here.

**C5. Peaks** (`app.js:587-606`, `680-687`)
- `decodePeaksFromBuffer(ab)`:
  1. Get the C3 context, or throw `'Web Audio not supported'` if it is null.
  2. `audioBuffer = await ctx.decodeAudioData(ab)`. This **detaches** `ab`, so it cannot be used afterwards.
  3. Return `computePeaks(audioBuffer, 200)`. The decoded `AudioBuffer` is then dropped.
- `computePeaks(buf, numBars)`:
  1. `x = buf.getChannelData(0)`: the first channel only, with no downmix.
  2. `spb = max(1, floor(x.length / numBars))`.
  3. For each `i` in `0..numBars-1`: `start = i·spb`, `end = min(start + spb, x.length)`, and `peaks[i]` = the maximum of `|x[j]|` over `[start, end)`, or 0 if that range is empty. Samples beyond `numBars·spb` are ignored.
  4. `m = max(peaks)`. If `m > 0`, divide every value by `m`.
  - Result: a `Float32Array(200)` in `[0, 1]` whose loudest bar is exactly 1. Silent audio stays all zeros. Audio shorter than 200 samples gives trailing zero bars.

**C6. Caches** (`app.js:571-585`, `689-727`)
- **`getPeaks(id)`** (preloader path). Return the cached peaks if present. Otherwise fetch (C4), decode the buffer **without copying it** (the bytes are thrown away), store the result in `peaksCache` and return it. Concurrent calls for the same id do not share one fetch.
- **`getPlayableEntry(id)`** (play path):
  1. If `audioCache` has `id`, move it to the newest position (delete, then set) and do not run eviction.
  2. Otherwise fetch (C4). If `peaksCache` lacks `id`, decode a **copy** (`ab.slice(0)`) and store the peaks. Then create `blob = new Blob([ab], { type: mimeType })` and `blobUrl = URL.createObjectURL(blob)`, call `audioCache.set(id, { blobUrl })`, then `evictAudioCache()`.
  3. Return `{ peaks: peaksCache.get(id), blobUrl }`.
  - A track that was only preloaded is downloaded a second time when it is first played, because the preloader discarded its bytes.
- **`evictAudioCache()`.** While `audioCache.size > 3`, take the oldest key:
  - If it equals `playingTidalId`, move it to the newest position and continue.
  - Otherwise call `URL.revokeObjectURL(blobUrl)` (errors ignored) and delete the entry.
  - `peaksCache` is never touched. In normal flow `playingTidalId` is already `null` when eviction runs (C8 step 3 clears it), so the "keep the playing entry" branch only matters in the load race (Bugs).

**C7. Background preloader** (`app.js:729-767`)
- **Triggers:**
  - `addTracksToQueue`, for each *newly added* track that has a `tidalId` and is not `notFound` (`app.js:1265-1267`). This covers URL/Spotify resolves, search-modal picks, CSV/text imports and pushes from the discontinued Chrome extension (`app.js:1641-1647`).
  - Boot, for every restored queue item with a `tidalId` that is not `notFound` (`app.js:1982-1986`).
  - Nothing else: re-render, retry and play do not trigger it. Excluded rows (exact library matches) are preloaded too.
- **`enqueuePreload(id)`.** Return if the flag is off, `id` is falsy, `peaksCache` already has it, or the pending queue already contains it. Otherwise push it and drain.
- **`drainPreloader()`.** While `inFlight < 2` and the queue is not empty:
  1. Shift an id, and skip it if `peaksCache` now has it.
  2. `inFlight++`, then run `preloadOne(id)`.
  3. When that settles, `inFlight--` and drain again.
- **`preloadOne(id)`.** `peaks = await getPeaks(id)`. Then, for every `.qi-waveform[data-tidal-id="<id>"]` in the queue list:
  1. Remove the class `empty`.
  2. Set `canvas.__peaks = peaks`.
  3. Draw with progress = `currentTime / duration` if this id is the current, loaded element, otherwise 0, and with no hover.
  - Any error is swallowed silently.
- **No cancellation or tracking.** Ids of removed rows, or of a cleared queue, stay queued and are still downloaded. Ids currently being fetched are not tracked, so the same id can be fetched twice: if it is re-added during its fetch, or played during its preload.

**C8. `togglePreview(tidalId, row, { initialSeekRatio = 0 })`: the player state machine** (`app.js:788-881`). Callers: the play-button click (`app.js:1061-1070`, no ratio) and a mousedown on a waveform that is not the current track (`app.js:1158-1164`, ratio = the click position).
1. If `row` is falsy, return.
2. **Same track** (`playingTidalId === tidalId` and `audio` is set):
   - If paused: seek if `initialSeekRatio > 0` and the duration is finite (unreachable from today's callers); `await audio.play()` with any rejection swallowed; set the button to `playing`. The button is set even if `play()` failed.
   - If playing: `audio.pause()`, then set the button to `idle`.
   - Return.
3. **Switch track:** call `stopPreview()` (C9).
4. `canvas = row.querySelector('.qi-waveform')`. If there is none, return.
5. If `peaksCache` has the id, remove `empty`, set `canvas.__peaks` and draw with progress `initialSeekRatio || 0`. This gives instant visual feedback.
6. Set the button to `loading`.
7. `try`:
   1. `{ peaks, blobUrl } = await getPlayableEntry(id)`. **During this await, `playingTidalId` and `audio` are both `null`.**
   2. `audio = new Audio(blobUrl)`, never inserted into the DOM. Set `audio.volume = getPreviewVolume()` and `audio.preload = 'auto'`.
   3. Set `previewState.audio = audio` and `previewState.playingTidalId = id`.
   4. On the canvas captured in step 4, which a re-render may have replaced in the meantime: remove `empty`, set `__peaks`, and draw with progress `initialSeekRatio || 0`.
   5. If `initialSeekRatio > 0`: if `duration` is not finite or is ≤ 0, wait for one `loadedmetadata` event. There is no timeout and no way out on error or abort. Then set `audio.currentTime = ratio × duration`.
   6. Define `isCurrent = () => previewState.audio === audio`.
   7. Define `tick()`:
      - return unless current;
      - `progress = duration ? currentTime / duration : 0`;
      - look the live canvas `.qi-waveform[data-tidal-id="<id>"]` up again on every frame, so it survives re-renders;
      - if it exists, draw it with the closure's `peaks`, `progress`, and hover = `parseFloat(canvas.dataset.hover)` if finite, else −1;
      - if `!audio.paused`, call `requestAnimationFrame(tick)`.
   8. Attach listeners, each a no-op unless the element is current:
      - `play` → `requestAnimationFrame(tick)`;
      - `pause` → set the button to `idle`;
      - `ended` → `stopPreview()`;
      - `error` → append `✗ Preview playback failed (<audio.error.code or ?>).`, then `stopPreview()`.
      - These listeners are attached only after step 5 has finished.
   9. `await audio.play()`, then set the button to `playing`.
8. `catch (e)`: set the button to `idle` and append `✗ Preview: <e.message>`. `previewState` is **not** reset, so if the failure came after step 7.3, the failed element remains "current".
- **Natural end of a track.** The element fires `pause` (the button goes idle) and then `ended` (C9 resets the waveform to unplayed).

**C9. `stopPreview()`** (`app.js:769-786`). Callers: C8 step 3, the `ended` and `error` listeners, removing the current track's row (`app.js:1120`), and "Clear all" (`app.js:1249`).
1. Remember `oldId` and `oldAudio`. Set `previewState.audio = null` and `playingTidalId = null` **first**, so any event from the old element is ignored.
2. If `oldAudio` exists, call `pause()` and set `src = ''`, each inside its own try/catch. Clearing `src` makes the element fire a late `error` event, which the `isCurrent` guard ignores.
3. If `oldId` exists, set its button to `idle`. If its row's canvas has `__peaks`, redraw it with progress 0 and no hover.
- It does not revoke the Blob URL (the LRU owns it) and does not touch either cache.

**C10. `drawWaveform(canvas, peaks, progress = 0, hover = -1)`** (`app.js:608-650`)
1. `dpr = devicePixelRatio || 1`, `W = canvas.clientWidth || canvas.width`, `H = canvas.clientHeight || canvas.height`. These are CSS pixels. When the canvas is `display: none` or detached from the page, `clientWidth` is 0 and the code falls back to the bitmap size.
2. If the bitmap is not `W·dpr × H·dpr`, set it to that size. Assigning the width or height clears the canvas, and non-integer values are truncated.
3. `save()`, `scale(dpr, dpr)`, `clearRect(0, 0, W, H)`.
4. `n = peaks.length` (200), `bw = W / n`, `midY = H / 2`, `hb = hover ≥ 0 ? hover·n : −1`.
5. For each bar `i`:
   - `x = i·bw`;
   - the bar counts as played if `(i + 0.5)/n ≤ progress`;
   - `boost = 1`, or, if `hb ≥ 0` and `d = |i − hb| < 10`, `boost = 1 + (1 − d/10)·0.45`;
   - height `h = max(1, peaks[i]·H·0.78·boost)`;
   - fill `#ffffff` if played, otherwise `rgba(255,255,255,0.22)`;
   - draw `fillRect(x, midY − h/2, max(1, bw − 1), h)`.
6. If `hover ≥ 0`, fill `rgba(255,255,255,0.55)` and draw `fillRect(floor(hover·W), 2, 1, H − 4)`: a 1 px cursor line, inset 2 px top and bottom.
7. `restore()`.

Details of the result:
- Bars are vertically centred and have square corners.
- The gap between bars is a full 1 CSS px only when `bw ≥ 2` (canvas at least 400 CSS px wide). It shrinks below 1 px under that width, and below 200 CSS px the 1 px bars overlap.
- There is no playhead line and no separate progress fill; progress shows only through the bar colour.
- The spotlight is centred on the fractional bar index `hover·n`, which is half a bar to the left of the bar under the cursor.
- At full boost a loud bar is 1.131 × `H` tall and is clipped at the canvas edges.

**C11. Play button** (`app.js:652-666`; CSS `styles.css:565-600`)
- **`setPlayButtonState(id, state)`** finds the first `.queue-item[data-tidal-id="<id>"]` and its `.qi-play`, returning if either is missing. It removes the classes `playing` and `loading`, then:
  - `'playing'` → adds `playing` and the pause icon;
  - `'loading'` → adds `loading` and the loading icon;
  - anything else → the play icon.
- **Icons.** Inline SVG, 9 × 9 px, viewBox `0 0 10 10`, `aria-hidden`, coloured with `currentColor`:
  - play: polygon `2,1 9,5 2,9`;
  - pause: two rects, at (2, 1.5) and (6, 1.5), each 2 × 7;
  - loading: a circle at (5, 5) with r 3.5, no fill, stroke width 1.2, `stroke-dasharray="4 3"`.
- **CSS:**
  - Base: 28 × 28 px circle, transparent background, 1 px border `#2a2a2a` (`--border-strong`), icon colour `#9a9a9a` (`--text-muted`). Colour, border and background transition over 0.15 s.
  - Hover: white icon, white border, background `#0d0d0d`.
  - `.playing`: black icon on a white fill, white border.
  - `.loading`: muted colour, dashed border, and the **whole button rotates** (`qi-play-spin`, 1.2 s linear, infinite).
  - There is no `prefers-reduced-motion` handling.
- `title="Play preview"` and `aria-label="Play"` are set when the row is rendered and never updated.

**C12. Row integration in `renderQueue()`** (`app.js:890-997`)
- **Full rebuild.** The whole list is rebuilt (`innerHTML = ''`) on every render. That happens on most queue changes and on every `bulk:track-start` and `bulk:track-done` event.
- **Controls.** When the flag is on and the item has a `tidalId` and is not `notFound`:
  - a `<button class="qi-play" data-tidal-id="<id>" title="Play preview" aria-label="Play">` goes after the optional retry checkbox and before `.qi-info`;
  - a `<canvas class="qi-waveform empty" data-tidal-id="<id>" height="22" title="Click or drag to scrub">` goes inside `.qi-title-row`, right after `.qi-title`. It has no width attribute, so its bitmap starts at the 300 px default.
  - The row itself carries `data-tidal-id` (empty string if none) and `data-key`.
- **Restore after append.** If `peaksCache` has the id:
  - remove `empty`, set `__peaks`, and draw with the current progress if this is the current track, otherwise 0;
  - if this is the current track and it is **not paused**, give the button the class `playing` and the pause icon.
  - A `loading` state is **not** restored. A row re-rendered during a load shows the play icon until the load finishes.
- **Layout** (`styles.css:602-645`):
  - `.qi-title-row` is a flex row with a 12 px gap. The title never shrinks (`flex: 0 0 auto`, no ellipsis) and the waveform takes whatever width is left.
  - The canvas is `flex: 1 1 auto; min-width: 0; height: 22px; border-radius: 4px; cursor: pointer`. On hover its background is `rgba(255,255,255,0.03)` (0.12 s transition). While it has the class `empty`, the cursor is `default`.
  - The canvas is hidden (`display: none`) on `.dl-downloading` rows; the play button stays visible. The `.notfound` hiding rules are redundant, because those rows never get the controls.
  - The canvas sits inside `.qi-info`, so it is dimmed along with it: opacity 0.42 on excluded rows, 0.65 on `dl-downloaded` and 0.5 on `dl-skipped` (`styles.css:667`, `705-707`). The play button is not dimmed.

**C13. Mouse interaction** (`app.js:1061-1070`, `1127-1205`)
- **Play button `click`** (delegated on the queue list): `stopPropagation()`, then `togglePreview(Number(btn.dataset.tidalId), btn.closest('.queue-item'))`. Because it is a `<button>`, Tab + Space/Enter also works.
- **Click position.** For every mouse event, `rel = clamp((clientX − rect.left) / rect.width, 0, 1)`, using the canvas's `getBoundingClientRect()`.
- **`mousedown`** on the queue list, left button only (`e.button === 0`), inside a `.qi-waveform`:
  - If the canvas's id equals `playingTidalId` (playing **or** paused): return if the canvas has no `__peaks`. Otherwise `preventDefault()`, start a scrub session `scrubbing = { canvas }`, and seek immediately with `seekFromMouseEvent`. A plain click is therefore a one-shot seek, and a paused track stays paused.
  - Otherwise (another track, nothing current, or this same track still loading): `preventDefault()` and `togglePreview(id, row, { initialSeekRatio: rel })`, which starts that track from the clicked point. This works even on an `empty` canvas, whose cursor suggests it is not clickable.
- **`seekFromMouseEvent(canvas, e)`:**
  1. Return if there is no current element or its `duration` is falsy (it is `NaN` before metadata loads).
  2. Set `currentTime = rel × duration`.
  3. If the canvas has `__peaks`, draw with progress = `rel` and hover = `rel`.
  4. Set `canvas.dataset.hover = String(rel)`.
- **`mousemove` on `document`.** While scrubbing, call `seekFromMouseEvent(scrubbing.canvas, e)`. The drag follows the pointer anywhere on screen and the audio keeps playing (the "skim").
- **`mouseup` on `document`.** End the session (`scrubbing = null`). Nothing is redrawn and the hover value is not cleared.
- **`mousemove` on the queue list** (hover; ignored while scrubbing). Inside a canvas that has `__peaks`: store `dataset.hover = rel`, then draw with the current progress (if it is the current track) and hover = `rel`.
- **`mouseout` on the queue list** (capture phase; ignored while scrubbing). When the pointer leaves a canvas that has `__peaks` for something outside it: delete `dataset.hover` and redraw with the current progress and no hover.
- **Limits.** Mouse events only: no pointer capture, `e.buttons` is never checked, there is no keyboard seeking, and the canvas is not focusable. The right and middle buttons do nothing, and there is no context menu.

**C14. Resize redraw** (`app.js:1207-1222`). On `window` `resize`, debounced 120 ms, every `.qi-waveform` that has `__peaks` is redrawn with its current progress and no hover. Hidden canvases are included.

**C15. What stops a playing preview**

| Event | Stops the preview? |
|---|---|
| Playing another track | Yes (`stopPreview`) |
| ✕ on the current track's row | Yes (`app.js:1120`), but the check compares against `playingTidalId`, which is `null` while loading |
| "Clear all" (ignored during a batch) | Yes, unconditionally (`app.js:1249`) |
| Track ends, or a media error | Yes |
| A batch finishing and removing downloaded/skipped rows | **No** (`app.js:1468-1473`) |
| Settings reset | No. The volume reverts only for the next element |

#### D. Main-process fetch: IPC `preview:get-audio` (`electron-main.js:814-917`)

**D1. Handler steps** for a request `{ tidalId }`:
1. `cred = lib.loadCred()` reads `token.json` from `TIDAL_TOKEN_PATH`, or `./token.json` next to the source when that variable is unset (dev mode). If the file is missing or holds no entries, it calls `process.exit(1)` (`tidal_lib.js:48-60`). That is not an exception, so the handler's try/catch cannot intercept it, and the app ends.
2. `token = await lib.getToken(cred)` refreshes the token and rewrites `token.json` if it has expired. `country = await lib.getCountryCode(cred)` uses the cached field, else `GET /v1/users/<userID>`, else `'US'`.
3. `playback = await lib.getPlaybackInfo(tidalId, token, 'LOSSLESS', country)`:
   - request: `GET https://api.tidal.com/v1/tracks/<id>/playbackinfopostpaywall?countryCode=<cc>&audioquality=LOSSLESS&playbackmode=STREAM&assetpresentation=FULL`;
   - headers: `Authorization: Bearer <token>`, `X-Tidal-Platform: android`, `User-Agent: okhttp/5.3.2`, `Accept: application/json`, `Accept-Encoding: identity`;
   - a 30 s socket-idle timeout and no retry;
   - a 401 becomes the error `Unauthorized — token may be invalid`; any other non-200 becomes `Playback info failed: <status> <body>`.
4. `decoded` = `playback.manifest` base64-decoded and read as UTF-8.
5. If `manifestMimeType` starts with `application/vnd.tidal.` (BT/BTS JSON), `JSON.parse` the manifest, then:
   - if `encryptionType` is set and is not `'NONE'` → return `{ ok: false, error: 'Track is DRM-encrypted' }`;
   - if `urls` is missing or empty → return the error `'No stream URL in manifest'`;
   - otherwise `audioBytes = fetchBuffer(urls[0], { timeout: 60000, retries: 2 })` and `mimeType = json.mimeType || 'audio/flac'`.
6. Else, if `manifestMimeType === 'application/dash+xml'`, parse it (D2):
   - `direct` → fetch the single URL, with `mimeType 'audio/flac'`;
   - segments → fetch them (D3), with `mimeType 'audio/mp4'` (fragmented MP4).
7. Otherwise return `{ ok: false, error: 'Unknown manifest type: <type>' }`.
8. Any thrown error is returned as `{ ok: false, error: e.message }`.

The whole file is held in memory in main and then copied across IPC. There are no range requests and no streaming. Previews use `LOSSLESS` (16-bit), whereas downloads ask for `HI_RES_LOSSLESS`.

**D2. `_parseDashForPreview(xml)`** (`electron-main.js:823-853`)
- `xmlUnescape` replaces `&amp; &lt; &gt; &quot; &apos;`, in that order.
- `baseUrl` is the trimmed, unescaped content of the first `/<BaseURL[^>]*>(.*?)<\/BaseURL>/s` match, or `''`.
- If the text contains no `SegmentTemplate` and `baseUrl` is not empty, return `{ type: 'direct', url: baseUrl }`.
- The first `initialization="…"` and `media="…"` matches are required. Without them it throws `Could not parse DASH manifest`.
- `startNumber="(\d+)"` defaults to 1. For each self-closing `<S …/>` element (`/<S\b[^>]*\/>/g`), `r="(\d+)"` defaults to 0, and `r + 1` consecutive segment numbers are appended. The `d` and `t` durations are ignored. If no segments are found, it throws `No segments found in DASH manifest`.
- It returns `{ type: 'dash_segments', baseUrl, initTemplate, mediaTemplate, segments: number[] }`.

**D3. `_fetchDashAudioBuffer(parsed)`** (`electron-main.js:857-871`)
1. Fetch `baseUrl + initTemplate` first, on its own.
2. Start 8 workers. Each pulls the next index and fetches `baseUrl + mediaTemplate.replace('$Number$', n)` with `{ timeout: 60000, retries: 2 }`. The URL is built by plain string concatenation, and only the first `$Number$` is replaced.
3. Return `Buffer.concat([init, ...segments])`.
- If one segment fails, `Promise.all` rejects at once, but the other workers keep downloading the remaining segments in the background.

**D4. `fetchBuffer(url, { timeout, retries })`** (`tidal_lib.js:174-232`)
- **Attempts.** Up to `retries + 1` (3 here), waiting `min(1000·2^attempt, 8000)` ms between them: 1 s, then 2 s.
- **One attempt** is a `GET` sending only `User-Agent: okhttp/5.3.2`:
  - it follows 301/302/307 up to 5 times (then `Too many redirects`), using the original URL's protocol module;
  - 429 and ≥ 500 → retriable `HTTP <code> for <url>`;
  - any other non-200 → non-retriable `HTTP <code> for <url>`;
  - a socket idle for `timeout` ms → retriable `Request timeout after <ms>ms`;
  - network errors are retriable;
  - the body is buffered in full.
- `timeout` is an **idle** timeout, not a deadline for the whole download.
- These error texts contain the full signed CDN URL, so they reach the activity log as `✗ Preview: HTTP 403 for https://…`.

### Data formats

| Name | Where | Shape | Notes |
|---|---|---|---|
| Saved volume | `<userData>/settings.json` (`electron-main.js:26`, `42-44`) | `{ …, "volume": number }` | The linear **slider position** 0..1, not the gain. Missing means 0.5. The whole renderer settings object is written with 2-space indentation. `settings:reset` writes `{ downloadFolder: '', libraryFolder: '' }`, which drops the volume (`electron-main.js:561-565`). |
| IPC request | `electron-preload.js:50` | `invoke('preview:get-audio', { tidalId: number })` | `tidalId` is TIDAL's numeric track id; the renderer converts `data-tidal-id` with `Number()`. |
| IPC response | `electron-main.js:873-917` | `{ ok: true, audioBytes: Buffer (Uint8Array in renderer), mimeType: string }` or `{ ok: false, error: string }` | `mimeType` is the BTS `json.mimeType` or `'audio/flac'`; DASH direct gives `'audio/flac'`; DASH segments give `'audio/mp4'`. |
| TIDAL playback info (fields used) | `electron-main.js:879-911` | `{ manifestMimeType, manifest /* base64 */ }`. BTS JSON: `{ mimeType?, encryptionType?, urls: string[] }`. DASH XML: `<BaseURL>`, `SegmentTemplate` with `initialization`, `media` (containing `$Number$`) and `startNumber`, and `<S … r="R"/>` | Only the segment count is taken from the `S` elements. |
| Peaks | `app.js:587-606`, `686` | `Float32Array(200)`, values 0..1 | Channel 0 only, normalised to its own maximum; 800 bytes; keyed by numeric tidalId; in memory only, never persisted. |
| Canvas and button DOM state | `app.js:951-956`, `1141`, `1174`, `1199` | `canvas.qi-waveform[data-tidal-id]` with the expando property `__peaks` and `dataset.hover` (a float as a string); class `empty` until painted. `button.qi-play[data-tidal-id]` with class `playing` or `loading`. | Lost on every re-render and rebuilt from `peaksCache`. |
| Activity-log lines | `app.js:871`, `879` | `✗ Preview playback failed (<code or ?>).` and `✗ Preview: <message>` | Both are styled as errors by `classify` (`app.js:332`). Preload failures log nothing. |

Possible `<message>` values:
- any error string from D1–D4, for example `Track is DRM-encrypted`, `No stream URL in manifest`, `Unknown manifest type: …`, `Could not parse DASH manifest`, `No segments found in DASH manifest`, `Unauthorized — token may be invalid`, `Playback info failed: …`, `Token refresh failed: …`, `HTTP <code> for <url>`, `Request timeout after 60000ms`;
- `preview fetch failed`;
- `Web Audio not supported`;
- browser decode and playback errors (Chromium's exact wording unverified).

### External interfaces

| Interface | Kind | Location | Detail |
|---|---|---|---|
| `preview:get-audio` | Electron `ipcRenderer.invoke` / `ipcMain.handle` | `electron-preload.js:50`; `electron-main.js:873` | `api.getPreviewAudio(tidalId)` |
| `settings:get` / `settings:save` | Electron invoke | `electron-preload.js:6-7`; `electron-main.js:555-556` | Volume persistence (the whole settings object) |
| `settings:reset` | Electron invoke | `electron-main.js:561-565` | Drops `volume` |
| `download:done` | Electron event | `electron-main.js:1034-1035`; `app.js:1457-1461` | `{ code }` from the batch child's `close` event; `code === 0` plays the success ping |
| TIDAL `playbackinfopostpaywall` | HTTPS API | `tidal_lib.js:286-296` via `electron-main.js:878` | See D1 step 3 |
| TIDAL CDN stream/segment URLs | HTTPS GET | `tidal_lib.js:174-232`; `electron-main.js:857-871`, `891`, `903` | Signed URLs from the manifest; see D4 |
| `token.json` | File read (plus a write on refresh) | `tidal_lib.js:48-68` | Location is `TIDAL_TOKEN_PATH` (packaged: `<userData>/token.json`) or `./token.json` next to the source in dev. Contents are secret and not reproduced here. |
| Web platform | Runtime APIs | `app.js:100-270`, `561-881`, `1127-1222` | `AudioContext` (`OscillatorNode` sine/sawtooth, `GainNode`, `BiquadFilterNode` lowpass, `setValueAtTime` / `exponentialRampToValueAtTime` / `linearRampToValueAtTime`, `decodeAudioData`); `HTMLAudioElement` (`volume`, `preload`, `play`, `pause`, `currentTime`, `duration`, events `play`/`pause`/`ended`/`error`/`loadedmetadata`); `Blob` and `URL.createObjectURL` / `revokeObjectURL`; Canvas 2D; `devicePixelRatio`; `requestAnimationFrame`; mouse and resize events. The CSP allows `media-src 'self' blob:` (`index.html:5`). |

### Constants and magic values

| Name | Value | Location | Meaning |
|---|---|---|---|
| SFX lead time | `currentTime + 0.02` s | `app.js:133`, `162`, `190`, `206`, `265` | Scheduling offset before each sound's first event |
| Detune ratio | ×1.005 (≈ +8.6 cents) | `app.js:121`, `150`, `253` | Frequency of the second sine in the chimes and bells |
| Chime/bell peak gain | 0.22 | `app.js:123`, `152`, `255` | |
| Attack | 0.012 s (chimes, honks); 0.008 s (success bells) | `app.js:123`, `152`, `184`, `255` | |
| Envelope floor | 0.0001 | throughout | Start and end of every exponential ramp |
| Oscillator tail | +0.05 s | `app.js:130-131`, `159-160`, `188`, `237-238`, `262-263` | Stop time = envelope end + 0.05 s |
| Download chime | C5 523.25 Hz at +0 for 0.13 s; G5 783.99 Hz at +0.09 for 0.18 s | `app.js:134-135` | |
| Cancel chime | G5 at +0 for 0.10 s; C5 at +0.07 for 0.15 s | `app.js:163-164` | |
| Success ping | G5 at +0 for 0.28 s; C6 1046.50 Hz at +0.07 for 0.32 s; E6 1318.51 Hz at +0.14 for 0.42 s | `app.js:267-269` | |
| Honk defaults | lowpass 1800 Hz, Q 1 dB, peak 0.35, start pitch ×1.08 gliding to target by 0.5·dur, durations 0.17 s / 0.22 s, second honk at +0.22 s | `app.js:171-192` | |
| Warning honk | `_honkPair(220, 165, { lpFreq: 1100, peak: 0.3 })` | `app.js:195` | |
| Clown horn | `_honkPair(420, 310)` | `app.js:194` | Unused |
| Fart | duration 0.42 s; saw 95·ps → 48·ps Hz (exp); LFO 17·√ps Hz, depth 18·ps Hz; lowpass 480·ps Hz, Q 2.2 dB; gain 0.0001 → 0.42 (exp, +0.02 s) → 0.32 (linear, +0.189 s) → 0.0001 (exp, +0.42 s) | `app.js:203-239` | |
| Version-click pitch scale | 7 | `app.js:497` | |
| `PREVIEW_FEATURE_ENABLED` | `true` | `app.js:58` | |
| Bars per waveform | 200 | `app.js:686` | |
| `MAX_AUDIO_CACHE` | 3 | `app.js:549` | Blob-URL LRU size |
| Preloader concurrency | 2 | `app.js:558` | |
| Default slider position | 0.5 (gain 0.25) | `app.js:511` | |
| Volume curve | gain = position² | `app.js:506-509` | |
| Volume save debounce | 300 ms | `app.js:523` | |
| Resize redraw debounce | 120 ms | `app.js:1221` | |
| Bar height | `max(1, peak × H × 0.78 × boost)` | `app.js:638` | |
| Spotlight | radius 10 bars (`d < 10`), up to +45 %, linear falloff | `app.js:633-636` | |
| Bar width | `max(1, W/200 − 1)` | `app.js:640` | |
| Waveform colours | played `#ffffff`; unplayed `rgba(255,255,255,0.22)`; cursor `rgba(255,255,255,0.55)` | `app.js:639`, `645` | |
| Cursor line | x = `floor(hover × W)`, from y 2 to H − 2, 1 px wide | `app.js:646-647` | |
| Canvas height | 22 (attribute and CSS px) | `app.js:955`; `styles.css:616` | |
| Canvas initial bitmap width | 300 (HTML default; no width attribute) | `app.js:955` | |
| Play button | 28 × 28 px; icons 9 × 9 px; spin 1.2 s; transitions 0.15 s | `styles.css:566-600`; `app.js:653-655` | |
| Waveform hover background | `rgba(255,255,255,0.03)`, 0.12 s | `styles.css:621-625` | |
| Slider | range 0–100, initial attribute 50; 80 × 3 px track; 12 px thumb, 1.18× on hover | `index.html:68`; `styles.css:478-511` | |
| Default MIME | `'audio/flac'` | `app.js:677`; `electron-main.js:895`, `904` | |
| DASH MIME | `'audio/mp4'` | `electron-main.js:910` | |
| Preview quality | `'LOSSLESS'` | `electron-main.js:878` | Not `HI_RES_LOSSLESS` |
| CDN timeout / retries | 60 000 ms idle / 2 (3 attempts) | `electron-main.js:858`, `866`, `891`, `903` | |
| DASH workers | 8 | `electron-main.js:869` | |
| Retry backoff | `min(1000 × 2^attempt, 8000)` ms | `tidal_lib.js:186` | |
| API timeout | 30 000 ms idle, no retry | `tidal_lib.js:15`, `162` | |
| User-Agent | `okhttp/5.3.2` | `tidal_lib.js:14` | |
| Maximum redirects | 5 | `tidal_lib.js:199` | |

### Rules and invariants

1. At most one preview element is meant to be current. Switching calls `stopPreview()` first (`app.js:806-807`). The load race (Bugs) breaks this.
2. Preview controls exist only when `PREVIEW_FEATURE_ENABLED && t.tidalId && !t.notFound` (`app.js:951-956`).
3. Previews always request TIDAL `LOSSLESS` and refuse a BTS manifest whose `encryptionType` is set and is not `'NONE'` (`electron-main.js:878`, `885-887`). DASH manifests are not checked for encryption.
4. The stored volume is the slider position. The applied gain is its square, and a slider change is applied to the current element at once (`app.js:502-519`).
5. Sound effects play at fixed gain straight to the destination, independent of the preview volume (`app.js:127`, `156`, `186`, `235`, `259`).
6. Sound effects and preview decoding use two separate `AudioContext`s (`app.js:100`, `546`, `561`).
7. `peaksCache` is never evicted. `audioCache` holds at most 3 Blob URLs, revokes the oldest, and never evicts the entry whose id equals `playingTidalId` (`app.js:571-585`).
8. Preloading keeps peaks only and discards the bytes. Playing a preloaded track fetches it again (`app.js:692-700`, `712-725`).
9. Preload errors are silent; errors on the play path go to the activity log (`app.js:763-766`, `871`, `879`).
10. Every media listener does nothing unless its element is still `previewState.audio`. `stopPreview` clears that state *before* tearing the element down (`app.js:772-779`, `853-873`).
11. Hold-to-scrub works only on the track whose id equals `playingTidalId`, playing or paused. Pressing on any other waveform starts that track at the pressed position (`app.js:1152-1164`).
12. Only the left mouse button seeks, scrubs or starts a preview (`app.js:1145`).
13. Seeking never pauses. Scrubbing a playing track skims; scrubbing a paused track only moves the playhead (`app.js:1135-1142`).
14. A bar counts as played when its centre `(i + 0.5)/n` is at or before the progress (`app.js:628-629`).
15. During an active download of a row, its waveform is hidden but its play button stays usable (`styles.css:630-635`).
16. After every full re-render, cached waveforms are repainted and the current, non-paused track's pause icon is restored (`app.js:981-996`).
17. The success ping requires the batch child to exit with code 0. The warning honk plays only on the five blocked paths in A9. The download chime plays only for Download all and Retry all/selected.

### Edge cases and failure modes

- **Second click while loading.** During `await getPlayableEntry`, `playingTidalId` is `null` (`app.js:807-829`). A second click on the same row's play button or waveform therefore starts a second load instead of pausing or cancelling. See Bugs.
- **Clicking another track's waveform.** Playback starts at the clicked ratio. If the duration is not known yet, the code waits for `loadedmetadata` before seeking (`app.js:839-846`). This works on a canvas that is still `empty`.
- **Dragging to or past the right edge.** `rel` clamps to 1 and `currentTime = duration`. A playing track then ends, which calls `stopPreview` and resets the waveform; further dragging does nothing because there is no current element (`app.js:1136-1139`, `868`). Whether `ended` fires for a *paused* element seeked to its end is unverified (needs a run).
- **Releasing the button outside the canvas** after a scrub leaves `dataset.hover` set, and the tick keeps drawing the spotlight at that stale spot (Bugs).
- **A re-render during a scrub** (for example a `bulk:track-start` event) detaches `scrubbing.canvas` (Bugs).
- **A re-render during a load**, before peaks are cached:
  - the new canvas has no `__peaks` and keeps the class `empty`;
  - the loader paints the *old*, detached canvas it captured (`app.js:809`, `832-834`);
  - the tick still paints the live canvas from its closure, but hover and scrub need `__peaks` (`app.js:1154`, `1171`), so they do nothing on that row until the next re-render;
  - the button also shows the play icon instead of the spinner during that window.
- **Previewing a track while it is being downloaded.** Its canvas is `display: none`, but the tick keeps redrawing it every frame (Bugs: bitmap growth on HiDPI).
- **Fewer samples than 200.** `spb = 1`, so the trailing bars are 0 and drawn 1 px tall. An all-silent track is drawn as 200 one-pixel bars.
- **Canvas narrower than 400 CSS px.** The bar gap falls below 1 px. Below 200 CSS px, the 1 px bars overlap.
- **Non-integer `W × dpr`** (Windows scaling such as 125 %/150 %, or an odd width at 1.5×). The truncated bitmap width never equals `W·dpr`, so the bitmap is reallocated on every draw. It still renders correctly, but costs more.
- **Infinite or unknown duration** (possible with a concatenated fragmented-MP4 Blob; unverified):
  - `progress` stays 0;
  - `seekFromMouseEvent` would assign `Infinity`, and the initial-seek path assigns `ratio × Infinity`. Setting `currentTime` to a non-finite value throws. On the initial-seek path the catch logs `✗ Preview: …`, but the element stays current with **none of its four listeners attached**. A later play then has no progress drawing and no end handling.
- **Unplayable Blob.** The `error` listener logs `✗ Preview playback failed (4).` and stops. The rejected `play()` may also log `✗ Preview: <message>`, which would give two lines (unverified).
- **Boot with a saved queue.** The preloader issues preview IPCs immediately, whether or not a token exists (Bugs: `process.exit`).
- **Hidden or minimised window.** `requestAnimationFrame` is throttled or paused while audio continues, and the waveform catches up when the window is visible again (Chromium behaviour; unverified here).
- **Concurrent token refresh.** With an expired token, two preloads plus a play can each refresh it and rewrite `token.json` at the same time (`tidal_lib.js:97-102`).
- **Memory per previewed track** (estimates; unverified). With compressed size `S` (a 4-minute 16-bit FLAC is roughly 20–35 MB):
  - main holds `S`, or `2S` briefly while concatenating DASH segments;
  - IPC delivers a copy, and `fetchAudioBytesIpc` copies it again;
  - the play path makes one more copy for decoding (`ab.slice(0)`), and the Blob is another.
  - Decoding allocates `duration × contextSampleRate × channels × 4` bytes: about 92 MB for 4 minutes of stereo at 48 kHz, about 1.4 GB for a 1-hour mix.
  - Long tracks (DJ mixes, live sets) could exhaust renderer memory. The preloader would do this unprompted at boot.
- **Error messages expose URLs.** Fetch errors contain the full signed CDN URL (`tidal_lib.js:207`, `213`), which ends up on screen in the activity log (`app.js:879`).
- **Reset config.** It replaces the settings without a `volume` key, but the slider is not updated (`app.js:1569-1577`).
- **Re-adding an id that is still preloading** (remove, then re-add) fetches it twice (`app.js:733-734`).
- **Clicking the play button of a not-yet-painted row** works normally. The waveform paints once the play fetch decodes the peaks.

### Bugs and oddities

1. **High: a preview fetch ends the whole app when `token.json` is missing or empty.**
   - **Code path.** `electron-main.js:875` calls `lib.loadCred()`, which calls `process.exit(1)` at `tidal_lib.js:49-52` (no file) or `55-58` (empty array). `process.exit` is not an exception, so the handler's try/catch (`electron-main.js:914`) cannot intercept it.
   - **Trigger.** The boot preloader sends a preview IPC for every restored queue item without checking for a token (`app.js:1982-1986`), and `addTracksToQueue` does the same (`app.js:1265-1267`). So a non-empty `queue.json` combined with a missing token ends the app moments after every launch, before the user can clear the queue or sign in.
   - **Realistic causes.** `queue.json` always lives in `<userData>`, while the token is in `<userData>` for packaged builds but next to the source in dev builds. Running a dev build after using the packaged app is enough. Deleting the token file to "sign out" (there is no sign-out button) is another cause.
   - **Same root cause elsewhere.** `resolve:tracklist` (`electron-main.js:925`) shares it, and the renderer's CSV/text import path never checks `tokenExists` (`app.js:1830-1843`).
   - The exact Electron shutdown behaviour is unverified (needs a run).
2. **Medium: the load race leaves an audio element playing that no control can stop.**
   - **Code path.** `playingTidalId` and `audio` stay `null` for the whole `await getPlayableEntry` (`app.js:807-829`). There is no generation token and no cancellation.
   - **Trigger.** A double-click on a play button, or a click on another row or waveform while a track loads. Each click runs a no-op `stopPreview()` and starts its own load.
   - **What happens.** Each load later sets `previewState.audio` to its own element and calls `play()`. The overwritten element is never paused, and its listeners are muted by `isCurrent`, so it plays to the end:
     - it does not respond to the volume slider;
     - its button may stay on the pause icon, and two rows can both show "playing";
     - the whole track is downloaded twice.
   - **Same id twice.** The second load overwrites `audioCache[id]` (`app.js:723`), so the first Blob URL is never revoked and its bytes stay pinned until the page closes.
3. **Medium: the volume slider is restored from the squared gain instead of the stored position** (`app.js:1947-1948` versus `510-519`).
   - A saved 0.5 is displayed as 25, although the effective gain is still 0.25 (which corresponds to position 50).
   - The first touch treats the displayed 25 as position 0.25, giving gain 0.0625: an audible drop. Each save-and-restart cycle sinks it further.
   - On a fresh install the slider shows 25, not 50. The comment there says the default is 60 %.
4. **Medium: on HiDPI screens a hidden waveform canvas grows exponentially** (`app.js:611-616`, with the tick at `855-865`).
   - For a `display: none` canvas, `clientWidth` and `clientHeight` are 0, so the code falls back to the bitmap size. At dpr 2 every draw doubles both dimensions.
   - The rAF tick redraws the current track's canvas every frame. If that row is downloading (`.dl-downloading` hides the waveform but not the play button), the bitmap doubles every frame and reaches Chromium's canvas size limits within a handful of frames.
   - Resize (`1213-1220`), preload paint (`756-762`) and re-render paint (`990`) cause one-off doublings on hidden canvases.
   - Memory and rendering impact are unverified (needs a run); the code path itself is certain.
5. **Low: a preview keeps playing with no visible control after its row disappears.**
   - After a batch, `onDownloadDone` drops downloaded and skipped rows without calling `stopPreview` (`app.js:1468-1473`).
   - ✕ on a row, or "Clear all", *while that row is still loading* does not cancel the load, because `playingTidalId` is still `null` (`app.js:1120`, `1249`). The load then finishes and starts playing a row that no longer exists.
   - If the queue is now empty, the whole queue section is hidden (`app.js:892`). The audio then plays to the end unless the user adds and plays another track.
6. **Low: the initial-seek path can hang with a spinning button** (`app.js:839-846`, `866-873`).
   - The `loadedmetadata` wait has no timeout and no error or abort exit, and the `error` listener is attached only after it. An undecodable Blob therefore leaves `togglePreview` pending forever, with the button on `loading`.
   - Because `audio` and `playingTidalId` are already set, the next click takes the same-track branch. There `play()` is rejected and swallowed, and the button is set to "playing" anyway.
   - If the seek assignment throws instead (non-finite duration), the element stays current with no listeners attached.
7. **Low: resuming shows "playing" even when `play()` fails** (`app.js:797-798`). The rejection is swallowed and `setPlayButtonState(…, 'playing')` runs unconditionally. Likewise, the catch at `877-880` never clears a failed element from `previewState`.
8. **Low: the hover spotlight goes stale after a scrub ends off the canvas** (`app.js:1141`, `1188-1195`, `861-862`). `seekFromMouseEvent` writes `dataset.hover`, `mouseup` does not clear it, and the `mouseout` during the scrub was ignored. The tick keeps drawing the spotlight and cursor line at the last scrub position until the pointer re-enters and leaves the canvas, or the row re-renders.
9. **Low: scrubbing goes wrong after a re-render detaches the canvas** (`app.js:1135-1142`, `1184-1187`).
   - `scrubbing.canvas` is the element captured at mousedown, and a re-render replaces it. `getBoundingClientRect()` on a detached node is all zeros.
   - `rel` then becomes 1 for `clientX > 0`, which seeks to the end and stops a playing track. It becomes 0 for `clientX < 0`, and `NaN` for `clientX = 0`, which makes the `currentTime` assignment throw inside the document `mousemove` handler.
   - Runtime behaviour is unverified (needs a run).
10. **Low: a spurious `✗ Preview:` log line when stopping or switching during a pending `play()`** (`app.js:875-880`, `777-778`, `800`). Pausing or clearing `src` rejects the pending `play()` promise with an `AbortError`, and the catch logs it and resets that row to idle. The window is short for a local Blob. The exact message is unverified.
11. **Low: the preloader is neither cancelled nor deduplicated** (`app.js:730-749`; `electron-main.js:861-869`).
    - Removed rows and a cleared queue keep their ids in `preloader.queue`, so their full lossless files are still downloaded.
    - In-flight ids are not tracked, so a play click during a preload of the same id fetches the file twice.
    - Excluded (already-in-library) rows are preloaded too, and preloads compete with batch downloads for bandwidth.
    - When one DASH segment fails, the other workers keep downloading the rest.
12. **Low: the success ping and "✓ Batch finished." appear even when every track failed** (`app.js:1459-1461`; `bulk_runner.js:63-114`). The ping is tied to exit code 0, and `bulk_runner` exits 0 regardless of per-track failures.
13. **Low: Reset config drops the saved volume and leaves the slider stale** (`electron-main.js:561-565`; `app.js:1569-1577`). The gain goes back to 0.25 for the next element, but the slider still shows the old position.
14. **Low: the whole-file design multiplies memory use** (see Edge cases). A long track could exhaust renderer memory during decode, and the preloader would trigger this without any user action. The impact is unverified (needs a run).
15. **Low (privacy): signed CDN URLs appear in the activity log** through `HTTP <code> for <url>` errors (`tidal_lib.js:207`, `213`; `app.js:879`).
16. **Info: sound calls are unguarded and run before the action they accompany** (`app.js:1376`, `1413`, `1441`). An exception from Web Audio would cancel the download or cancel action.
17. **Info: sound triggers are inconsistent.**
    - The per-row Retry plays no chime (`app.js:1093-1113`).
    - "Batch already running" and the "Add to queue" no-token check only log a line, with no honk (`app.js:1098-1100`, `1290-1292`).
    - The download chime plays before `startBulk`, whose `{ ok: false }` result is never checked.
18. **Info: dead code.** `playClownHorn` is never called (`app.js:194`), and the `_honkPair` comment refers to a removed feature (`app.js:166-167`).
19. **Info: wrong comment.** It claims every sound caller is a click handler (`app.js:97-99`).
20. **Info: stale comment.** It describes a single peaks + Blob URL cache (`app.js:532-534`).
21. **Info: unreachable branch.** The seek in `togglePreview`'s same-track branch (`app.js:794-796`) can never run with today's callers. The eviction guard (`app.js:574-579`) only matters in the load race.
22. **Info: waveform geometry quirks** (`app.js:588`, `624-638`):
    - the waveform uses the left channel only, with no downmix;
    - boosted bars are clipped;
    - the spotlight is centred half a bar to the left;
    - an `empty` canvas shows the default cursor, yet clicking it starts playback.
23. **Info: accessibility gaps** (`app.js:952`, `657-666`, `955`; `styles.css:592-600`):
    - the button's `aria-label` stays "Play" while playing;
    - the waveform is not focusable and has no accessible value or keyboard seeking;
    - the spinner ignores reduced motion.
24. **Info: housekeeping.**
    - The two `AudioContext`s are never closed (`app.js:100-109`, `561-569`).
    - The CSS that hides `.notfound` preview controls is redundant (`styles.css:631-632`).
    - Re-renders drop the `loading` spinner (`app.js:992-995`).

### Documentation that disagrees with the code

`waveformplayback.md` and the sound section of `CLAUDE.md` predate several changes. The code is authoritative.

- `waveformplayback.md:231` hard-codes `audio.volume = 0.6`. The code uses the squared slider position, default gain 0.25 (`app.js:510-513`, `826`).
- `waveformplayback.md:227` says to use "one shared HTMLAudioElement, swap its src". The code, like the doc's own snippet at `:230`, creates a new `Audio` per track (`app.js:825`).
- `waveformplayback.md:345-393` describes one LRU of `{ peaks, blobUrl }`, size 3. The code has two tiers: unbounded `peaksCache` plus an LRU of 3 Blob URLs (`app.js:543-550`, `702-727`).
- `waveformplayback.md:321-322`, `339` say a mousedown returns without `__peaks` or on a non-playing track. The code checks `__peaks` only in the scrub branch and starts a non-current track at the clicked point (`app.js:1152-1164`).
- The doc has no preloader. The code preloads at concurrency 2 (`app.js:729-767`).
- `waveformplayback.md:251-254` lists listeners with no stale-element guard and no error log. The code guards with `isCurrent()` and logs (`app.js:853-873`).
- `waveformplayback.md:202`, `410` use `data-id`. The code uses `data-tidal-id`.
- `waveformplayback.md:452-481` CSS gives `min-width: 80px`, `.qi-play` border `var(--border)` and keyframes `spin`. The code has `min-width: 0`, `var(--border-strong)`, a hover background, keyframes `qi-play-spin`, and a muted colour while loading (`styles.css:565-645`).
- `waveformplayback.md:509` says to hide preview controls on downloading rows. The code hides only the waveform.
- `waveformplayback.md:106` says "mono down-mix is fine", but both the doc and the code read channel 0 only.
- `waveformplayback.md:367` always decodes a copy. The preloader path decodes without copying (`app.js:694-697`).
- `CLAUDE.md` says the success ping is "~400ms total". It is about 560 ms (`app.js:267-269`).
- `CLAUDE.md` says the volume "defaults 50%". The slider displays 25 at boot (`app.js:1948`).
- `CLAUDE.md` lists the download chime only for "Download all". It also plays for Retry all/selected.

### Platform-specific behaviour

- **Web Audio semantics the sounds depend on:**
  - built-in `sine`/`sawtooth` oscillators are band-limited;
  - the `BiquadFilterNode` lowpass `Q` is a resonance in dB (linear Q = 10^(Q/20): Q 1 ≈ 1.122, Q 2.2 ≈ 1.288);
  - an exponential ramp follows `v(t) = V0·(V1/V0)^((t−T0)/(T1−T0))` from the previous event; a linear ramp interpolates linearly;
  - a node connected to an `AudioParam` is added to that parameter's automated value at audio rate;
  - a `GainNode`'s default gain is 1, but that is irrelevant here because the oscillators start at the first automation event.
- `decodeAudioData` resamples to the context's hardware sample rate and detaches its input `ArrayBuffer`.
- Electron's IPC structured-clones a Node `Buffer` into a renderer `Uint8Array`. A whole track is copied each time.
- `webPreferences` sets no `autoplayPolicy` (`electron-main.js:81-86`). Electron documents the default as `no-user-gesture-required`, so the IPC-triggered success ping and the boot-time decode context should not need a gesture (not confirmed by a run).
- Chromium plays FLAC Blobs and fragmented-MP4 Blobs (FLAC or AAC inside) through `HTMLAudioElement`, according to the code comment at `electron-main.js:907-909` (unverified here).
- `devicePixelRatio` is 2 on Retina Macs (integer), which exposes bug 4. Fractional values on Windows display scaling cause a reallocation on every draw.
- `requestAnimationFrame` is throttled in hidden windows (Electron's default background throttling).
- The topbar uses `-webkit-app-region: drag`, so only the no-drag brand parts receive easter-egg clicks.
- The `window.webkitAudioContext` fallback is a legacy Safari path that Electron never uses.
- A batch child killed by Cancel reports exit code `null` on macOS.

### Porting notes for a native Swift macOS app

| Topic | Today | Swift approach | Difficulty |
|---|---|---|---|
| Sound effects | Web Audio graphs built per call: sine and sawtooth oscillators, gain envelopes with exponential and linear ramps, a biquad lowpass with Q in dB, and an LFO added to the frequency (`app.js:96-270`) | Only seven fixed variants exist (download, cancel, success, warning, clown, fart ×1, fart ×7). Pre-render each into an `AVAudioPCMBuffer` at the output sample rate with a small offline synth that ports the formulas exactly, then play it on a dedicated `AVAudioEngine` + `AVAudioPlayerNode`. The synth needs: a band-limited sawtooth (PolyBLEP or additive up to Nyquist; a naive saw aliases audibly in the ×7 fart); the Web Audio/RBJ lowpass biquad with Q converted from dB, implemented directly, because `AVAudioUnitEQ`'s `.resonantLowPass` uses a bandwidth in octaves and will not match exactly; phase-integrated frequency for the LFO and the glides; and envelope curves per the ramp formulas above. Keep these sounds off the preview volume. Never let a sound failure block the action it accompanies. | Medium |
| Audio engine lifecycle | Lazy contexts, `resume()` if suspended, never closed | Start an `AVAudioEngine` on demand, and restart it on `AVAudioEngineConfigurationChange` (output device changes). There is no autoplay restriction natively. | Easy |
| Preview fetch | IPC to main: token, playback info at `LOSSLESS`, then BTS single URL or 8-way DASH segments, then the Buffer copied to the renderer (`electron-main.js:814-917`) | An in-process `async` function on `URLSession` with the same request, headers, idle timeout, retry and backoff, and a `TaskGroup` of width 8 for segments. Write to a temporary file instead of copying through memory several times. Use a single in-flight token refresh. A missing token must produce an error ("Sign in to TIDAL to preview"), never terminate the process. Cancel the remaining segment tasks on the first failure. | Medium |
| Decoding for peaks | `decodeAudioData` of a full FLAC file (BTS) or fragmented MP4 (DASH), channel 0, 200 max-abs buckets, normalised | `AVAudioFile` reads FLAC on macOS. Read in chunks and compute bucket maxima on the fly (`vDSP_maxmgv`) so the whole PCM is never held in memory. Whether AVFoundation/Core Audio can read TIDAL's FLAC-in-fragmented-MP4 is unverified (needs a run). The app already bundles FFmpeg, which can remux that to a plain `.flac` (`-c copy`) for preview, or decode it to PCM. Decide whether to keep channel 0 only (today's look) or take the maximum across channels. | Hard (format risk) |
| Playback | A detached `Audio` element on a Blob URL; `volume`, `currentTime`, `play`/`pause`; events `play`/`pause`/`ended`/`error`/`loadedmetadata` | `AVAudioPlayer(contentsOf:)` on the temporary file (simple, with an accurate settable `currentTime`, a linear `volume` and delegate callbacks for finish and decode error), or `AVPlayer` with `seek(to:toleranceBefore:.zero, toleranceAfter:.zero)`. The squared volume curve carries over unchanged. Give every load a generation token (or cancel the previous `Task`) so only the newest request can become current. This closes bugs 2, 5, 6 and 10. | Medium |
| Caches | Unbounded peaks map; LRU of 3 Blob URLs with `revokeObjectURL` | A peaks dictionary (optionally saved to disk keyed by track id, which would make waveforms instant across launches; owner's choice), plus an LRU of 3 temporary audio files deleted on eviction and on quit. | Easy |
| Waveform view | Canvas 2D bars scaled by `devicePixelRatio`; redrawn on hover, scrub, every animation frame and resize | An `NSView` `draw(_:)` (or a SwiftUI `Canvas`) filling rects. AppKit handles the backing scale, which removes bug 4. Colours: white, white at 22 %, white at 55 %. Same bar and spotlight maths. Redraw on bounds change. | Easy |
| Animation tick | `requestAnimationFrame` loop while playing, re-querying the live canvas | `NSView.displayLink(target:selector:)` (macOS 14+), a SwiftUI `TimelineView(.animation)`, or a 30–60 Hz timer bound to the one current player; stop it when paused or when the row goes away. | Easy |
| Hover and scrub | Mouse events on the list, plus document-level `mousemove`/`mouseup` | `mouseDown`/`mouseDragged`/`mouseUp`. AppKit keeps sending drag and up events to the view that received the mouse-down, even outside its bounds, so the session cannot latch. Use an `NSTrackingArea` for `mouseMoved`/`mouseExited`, and clear the hover on mouse-up when the pointer is outside (bug 8). Keep the rules: left button only; scrub only the current track; a press on another track starts it at that point; seeking does not pause. | Easy |
| Preloader | FIFO array with an in-flight counter at concurrency 2; never cancelled | An actor with a bounded queue (2) that deduplicates in-flight ids, cancels on row removal and Clear all, and does nothing without a token. Whether to skip excluded rows, or pause preloading during batch downloads, is for the owner. | Easy |
| Volume | `settings.volume` (slider position) in `settings.json`, debounced 300 ms | Store the position in `UserDefaults` (or the settings file), apply position² live to the current player, and restore the slider from the **position** (bug 3). Use a native `NSSlider`. | Easy |
| Play button and spinner | CSS classes plus SVG icons; the whole button rotates while loading | A small round button with SF Symbols (`play.fill` / `pause.fill`) and a `ProgressView` while loading. Respect Reduce Motion. Switch the accessibility label between "Play preview" and "Pause preview". Make the waveform an accessible slider-like element (value = position) with keyboard seeking. These are suggestions, not today's behaviour. | Easy |
| Post-batch and removal teardown | Not handled (bug 5) | Stop the preview when its row leaves the queue for any reason. | Easy |
| Easter eggs | Fart on logo/name, ×7 on the version label | A click on the app icon or name in the native UI (for example the About window or a toolbar item) is the nearest equivalent; placement is for the owner. | Easy |

### Open questions

1. Does Chromium report a finite `duration` for the concatenated DASH fragmented-MP4 Blob? If not, seeking and progress break for DASH previews. Unverified (needs a run).
2. Can AVFoundation or Core Audio decode and play TIDAL's FLAC-in-fragmented-MP4, or does the port need FFmpeg (remux or decode) for previews? Unverified (needs a run).
3. Is `mouseup` delivered to the document when the button is released outside the window, or after a Cmd-Tab mid-drag? If not, scrubbing stays latched, because `e.buttons` is never checked. Unverified (needs a run).
4. Does the detached `<audio>` element show up in macOS Now Playing or respond to the media keys through Chromium's media-session support? Should the Swift port integrate with `MPNowPlayingInfoCenter` or deliberately not?
5. What happens to an orphaned element (bug 2) when the LRU later revokes its Blob URL? Unverified (needs a run).
6. Does setting `currentTime = duration` on a **paused** element fire `ended`, and therefore `stopPreview`? Unverified (needs a run).
7. Is downloading the *full* lossless track for every queued item, including excluded ones, intended? Would the owner accept a shorter or lower-bitrate preview, or persisted peaks, in the port?
8. `waveformplayback.md` and `CLAUDE.md` differ from the code: ping length, slider default, cache design, and click-to-start on another track. Which behaviour should the port preserve? These notes assume the code's behaviour.
9. Should the volume slider also control the sound effects in the port? Today it does not, and nothing says whether that is intentional.
10. The hover spotlight (bars swell up to 1.45× under the cursor) and the slider thumb's 1.18× hover scale are "zoom on hover" effects, which the owner's global design rules discourage. The spotlight is also a feature the owner deliberately built (v0.1.20). Should the port keep it, tone it down (for example a brightness change only), or drop it?
11. Should the waveform keep showing the first channel only, or the maximum across both channels?
