// TIDAL lossless FLAC downloader
// Usage:
//   node tidal_download.js <track-or-album-or-playlist-url-or-id> [outDir] [flags]
//   Flags:
//     --quality LOSSLESS | HI_RES_LOSSLESS    Force a quality tier (default: highest available)
//     --concurrency N                          Parallel segment downloads (default: 8)
//     --force                                  Re-download even if file exists
//     --debug                                  Verbose output (DASH manifest etc.)
//     --help                                   Show this help
//
// Examples:
//   node tidal_download.js 103805726
//   node tidal_download.js https://tidal.com/browse/track/103805726 "Z:\Music"
//   node tidal_download.js https://tidal.com/browse/album/103805725 "Z:\Music"
//   node tidal_download.js https://tidal.com/browse/playlist/abcd1234-... "Z:\Music"
//   node tidal_download.js 103805726 --quality LOSSLESS

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const lib = require('./tidal_lib');

// ffmpeg-static returns a path inside `app.asar` in packaged builds, but the
// binary actually lives in `app.asar.unpacked` (our asarUnpack config moves
// it on disk). spawn() goes through the OS exec syscall — which treats the
// asar archive as a file and fails with ENOTDIR when trying to traverse
// into it. Rewriting `.asar` → `.asar.unpacked` makes the path point at
// the real on-disk binary. In dev mode there's no `.asar` in the path so
// the replace is a no-op.
const _ffmpegStatic = (() => { try { return require('ffmpeg-static'); } catch { return null; } })();
const _ffmpegUnpacked = _ffmpegStatic && _ffmpegStatic.replace('app.asar', 'app.asar.unpacked');
const ffmpegPath = (_ffmpegUnpacked && fs.existsSync(_ffmpegUnpacked))
    ? _ffmpegUnpacked
    : (_ffmpegStatic && fs.existsSync(_ffmpegStatic) ? _ffmpegStatic : 'ffmpeg');

const CONCURRENCY_DEFAULT = 8;
const FLAC_QUALITIES = ['HI_RES_LOSSLESS', 'LOSSLESS'];
const DEFAULT_OUT_DIR = 'Z:\\Downloads';

// ─── CLI arg parsing ─────────────────────────────────────────────────────────

function parseArgs(argv) {
    const flags = {
        quality: null,
        concurrency: CONCURRENCY_DEFAULT,
        force: false,
        debug: !!process.env.DEBUG,
        help: false,
        allowAac: true,
        flacOnly: false,
        skipLibraryCheck: false,   // bulk_runner sets this — queue already vetted
    };
    const positional = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--help' || a === '-h') flags.help = true;
        else if (a === '--force') flags.force = true;
        else if (a === '--debug') flags.debug = true;
        else if (a === '--allow-aac') flags.allowAac = true;
        else if (a === '--flac-only') { flags.flacOnly = true; flags.allowAac = false; }
        else if (a === '--skip-library-check') flags.skipLibraryCheck = true;
        else if (a === '--quality') flags.quality = argv[++i];
        else if (a === '--concurrency') flags.concurrency = parseInt(argv[++i], 10);
        else positional.push(a);
    }
    return { flags, positional };
}

function printHelp() {
    console.log(`TIDAL FLAC downloader
Usage:
  node tidal_download.js <track-or-album-or-playlist-url-or-id> [outDir] [flags]

Accepted inputs:
  - TIDAL track ID:           103805726
  - TIDAL track URL:          https://tidal.com/browse/track/103805726
  - TIDAL album URL:          https://tidal.com/browse/album/103805725
  - TIDAL playlist URL/UUID:  https://tidal.com/browse/playlist/aaaa-bbbb-...
  - Spotify track URL:        https://open.spotify.com/track/0Pf6NzB4o9...
  - Spotify album URL:        https://open.spotify.com/album/<id>
  - Spotify playlist URL:     https://open.spotify.com/playlist/<id>

Spotify URLs are resolved via Spotify's anonymous web API → ISRC match on
TIDAL (perfect track match) → fall back to title+artist+duration search.

Flags:
  --quality LOSSLESS | HI_RES_LOSSLESS   Force a quality tier (default: highest available)
  --concurrency N                         Parallel segment downloads (default: ${CONCURRENCY_DEFAULT})
  --force                                 Re-download even if file already exists
  --flac-only                             Skip tracks that aren't in lossless (no .m4a fallback)
  --debug                                 Verbose output (manifest dump, etc.)
  --help, -h                              Show this help

Default quality behavior:
  Always tries Hi-Res FLAC first (24-bit) → falls back to CD-quality FLAC
  (16-bit/44.1kHz) → if no lossless master exists, automatically saves as
  .m4a (320 kbps AAC) with full metadata. Use --flac-only to never accept
  AAC fallback.

First-time setup:
  node tidal_auth_node.js
`);
}

// ─── Manifest parsing ────────────────────────────────────────────────────────

function parseManifest(playback) {
    const { manifestMimeType, manifest } = playback;
    if (!manifest) throw new Error('No manifest in playback response');
    const decoded = Buffer.from(manifest, 'base64').toString('utf8');

    // TIDAL ships BT-family manifests with a JSON blob containing a single
    // direct URL. The original was `application/vnd.tidal.bt`; they later
    // started returning `application/vnd.tidal.bts`. Same shape inside, so
    // accept anything in the family — if a future variant ships with a
    // different schema, the JSON.parse / urls[0] access will throw and we'll
    // see a useful error.
    if (manifestMimeType && manifestMimeType.startsWith('application/vnd.tidal.')) {
        const json = JSON.parse(decoded);
        if (json.encryptionType && json.encryptionType !== 'NONE') {
            throw new Error(`Track is DRM-encrypted (${json.encryptionType})`);
        }
        if (!json.urls || !json.urls.length) {
            throw new Error(`BT-family manifest (${manifestMimeType}) had no urls field: ${decoded.slice(0, 200)}`);
        }
        return { type: 'direct', mimeType: json.mimeType, url: json.urls[0], codec: json.codecs, raw: decoded };
    }

    if (manifestMimeType === 'application/dash+xml') {
        const baseUrlMatch = decoded.match(/<BaseURL[^>]*>(.*?)<\/BaseURL>/s);
        const baseUrl = baseUrlMatch ? baseUrlMatch[1].trim() : '';

        if (!decoded.includes('SegmentTemplate') && baseUrl) {
            return { type: 'direct', url: baseUrl, mimeType: 'audio/flac', raw: decoded };
        }

        const initMatch = decoded.match(/initialization="([^"]+)"/);
        const mediaMatch = decoded.match(/media="([^"]+)"/);
        const mimeMatch = decoded.match(/mimeType="([^"]+)"/);
        const codecMatch = decoded.match(/codecs="([^"]+)"/);

        if (!initMatch || !mediaMatch) throw new Error('Could not parse MPEG-DASH segment template.');

        const segments = [];
        const startNumberMatch = decoded.match(/startNumber="(\d+)"/);
        let segNum = startNumberMatch ? parseInt(startNumberMatch[1], 10) : 1;
        const sElements = decoded.match(/<S\b[^>]*\/>/g) || [];
        for (const el of sElements) {
            const rMatch = el.match(/\br="(\d+)"/);
            const repeat = rMatch ? parseInt(rMatch[1], 10) : 0;
            for (let i = 0; i <= repeat; i++) segments.push(segNum++);
        }
        if (!segments.length) throw new Error('No segments found in MPEG-DASH manifest.');

        const xmlUnescape = s => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'");
        return {
            type: 'dash_segments',
            baseUrl: xmlUnescape(baseUrl),
            initTemplate: xmlUnescape(initMatch[1]),
            mediaTemplate: xmlUnescape(mediaMatch[1]),
            mimeType: mimeMatch ? mimeMatch[1] : 'audio/flac',
            codec: codecMatch ? codecMatch[1] : '',
            segments,
            raw: decoded,
        };
    }

    throw new Error(`Unknown manifest type: ${manifestMimeType}`);
}

// ─── Parallel segment downloads ─────────────────────────────────────────────

async function downloadSegmentsParallel(manifest, dest, concurrency) {
    const { baseUrl, initTemplate, mediaTemplate, segments } = manifest;
    const results = new Array(segments.length);
    let nextIdx = 0;
    let completed = 0;

    const initBuf = await lib.fetchBuffer(baseUrl + initTemplate);

    const worker = async () => {
        while (true) {
            const i = nextIdx++;
            if (i >= segments.length) return;
            const segUrl = baseUrl + mediaTemplate.replace('$Number$', segments[i]);
            results[i] = await lib.fetchBuffer(segUrl);
            completed++;
            process.stdout.write(`\r    Downloaded ${completed}/${segments.length} segments...`);
        }
    };

    const workerCount = Math.min(concurrency, segments.length);
    await Promise.all(Array.from({ length: workerCount }, worker));

    process.stdout.write('\n');
    fs.writeFileSync(dest, Buffer.concat([initBuf, ...results]));
}

async function downloadDirect(url, dest) {
    const buf = await lib.fetchBuffer(url);
    fs.writeFileSync(dest, buf);
}

// ─── FFmpeg remux/tag ────────────────────────────────────────────────────────

function runFfmpeg(args, stdinBuffer = null) {
    return new Promise((resolve, reject) => {
        const stdio = stdinBuffer ? ['pipe', 'ignore', 'pipe'] : ['ignore', 'ignore', 'pipe'];
        const p = spawn(ffmpegPath, args, { stdio });
        let stderr = '';
        p.stderr.on('data', d => stderr += d.toString());
        p.on('error', reject);
        p.on('close', code => code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}: ${stderr.slice(-500)}`)));
        if (stdinBuffer) {
            p.stdin.on('error', () => {});
            p.stdin.end(stdinBuffer);
        }
    });
}

async function remuxToFlac(srcM4a, dstFlac, info, albumInfo, coverBuf) {
    const releaseDate = albumInfo?.releaseDate || info.album?.releaseDate || info.streamStartDate || '';
    const tags = {
        title: info.title || '',
        artist: (info.artists || []).map(a => a.name).join(', ') || info.artist?.name || '',
        album: info.album?.title || '',
        album_artist: albumInfo?.artist?.name || info.album?.artist?.name || info.artists?.[0]?.name || '',
        track: info.trackNumber ? String(info.trackNumber) : '',
        disc: info.volumeNumber ? String(info.volumeNumber) : '',
        date: releaseDate.slice(0, 4),
        copyright: albumInfo?.copyright || info.copyright || '',
        isrc: info.isrc || '',
    };

    const args = ['-y', '-i', srcM4a];
    if (coverBuf) args.push('-f', 'mjpeg', '-i', 'pipe:0');
    args.push('-map', '0:a');
    if (coverBuf) args.push('-map', '1:v', '-disposition:v', 'attached_pic');
    args.push('-c:a', 'copy');
    if (coverBuf) args.push('-c:v', 'copy');
    for (const [k, v] of Object.entries(tags)) {
        if (v) args.push('-metadata', `${k}=${v}`);
    }
    args.push(dstFlac);

    await runFfmpeg(args, coverBuf);
}

/** Run a fast structural check on the output FLAC. Returns true if it parses cleanly. */
async function verifyFlac(filePath) {
    try {
        await runFfmpeg(['-v', 'error', '-i', filePath, '-f', 'null', '-']);
        return true;
    } catch (e) {
        console.warn(`  ⚠ FLAC integrity check failed: ${e.message.split('\n').pop()}`);
        return false;
    }
}

// ─── Quality / manifest selection ────────────────────────────────────────────

async function getBestManifest(trackId, token, countryCode, forceQuality, debug) {
    const tiers = forceQuality ? [forceQuality] : FLAC_QUALITIES;

    for (const quality of tiers) {
        try {
            const playback = await lib.getPlaybackInfo(trackId, token, quality, countryCode);
            if (debug) console.log(`  [debug] Got ${playback.audioQuality} at request tier ${quality}`);
            return {
                manifest: playback.manifest,
                manifestMimeType: playback.manifestMimeType,
                audioQuality: playback.audioQuality,
            };
        } catch (e) {
            if (debug) console.warn(`  [debug] ${quality} unavailable: ${e.message}`);
        }
    }
    throw new Error('Could not get playback manifest at any quality.');
}

// ─── Single-track download ───────────────────────────────────────────────────

async function downloadTrack(trackId, outDir, cred, flags, { albumPreFetched = null } = {}) {
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    const info = await lib.getTrackInfo(trackId, token, countryCode);
    const artist = lib.sanitize(info.artists?.[0]?.name || info.artist?.name);
    const title = lib.sanitize(info.title);
    const album = lib.sanitize(info.album?.title);

    const flacPath = path.join(outDir, `${title}.flac`);
    const m4aPath = path.join(outDir, `${title}.m4a`);

    // Skip-if-exists (destination folder) — check both .flac and .m4a
    if (!flags.force && fs.existsSync(flacPath)) {
        console.log(`  ⏭  ${title}.flac already in downloads folder — skipping (use --force to overwrite)`);
        return { path: flacPath, skipped: true };
    }
    if (!flags.force && fs.existsSync(m4aPath)) {
        console.log(`  ⏭  ${title}.m4a already in downloads folder — skipping (use --force to overwrite)`);
        return { path: m4aPath, skipped: true };
    }

    // Skip if already in master library (auto for `exact` matches, ASK-skipped for `similar`).
    // bulk_runner passes --skip-library-check after the GUI has reviewed similar matches.
    if (!flags.force && !flags.skipLibraryCheck) {
        const artistStr = (info.artists || []).map(a => a.name).join(', ');
        const existing = await lib.findInLibrary(info.title, artistStr, info.duration);
        if (existing && existing.kind === 'exact') {
            console.log(`  📁 Already in music library: ${existing.path}`);
            console.log(`     Skipping download (use --force to download anyway)`);
            return { path: existing.path, skipped: true };
        }
        if (existing && existing.kind === 'similar') {
            console.log(`  ⚠ Similar version in music library: ${existing.libraryTitle || existing.path}`);
            console.log(`     Skipping. Use --force or include via GUI to download anyway.`);
            return { path: existing.path, skipped: true };
        }
    }

    console.log(`  ${artist} — ${title} (${album})`);

    const albumInfo = albumPreFetched ?? (info.album?.id ? await lib.getAlbumInfo(info.album.id, token, countryCode) : null);

    const raw = await getBestManifest(trackId, token, countryCode, flags.quality, flags.debug);
    const manifest = parseManifest(raw);

    // Decide output format from the manifest's codec attribute.
    // FLAC → .flac. AAC (mp4a.40.x) → .m4a (only with --allow-aac).
    const decodedManifest = Buffer.from(raw.manifest, 'base64').toString('utf8');
    const isFlacOutput = (manifest.codec || '').includes('flac')
        || /codecs="flac"/.test(decodedManifest);

    if (flags.debug) {
        console.log(`  [debug] manifest type: ${raw.manifestMimeType}`);
        console.log(`  [debug] audioQuality: ${raw.audioQuality}`);
        console.log(`  [debug] codec: ${manifest.codec}, mimeType: ${manifest.mimeType}`);
        console.log(`  [debug] segments: ${manifest.segments?.length || 'direct'}`);
        console.log(`  [debug] isFlacOutput: ${isFlacOutput}`);
    }

    // If TIDAL has no lossless master, behavior depends on --flac-only:
    //   default: auto-fallback to .m4a (with full metadata + cover)
    //   --flac-only: throw AacOnlyError so bulk callers can list it as skipped
    if (!isFlacOutput) {
        if (flags.flacOnly) {
            console.log(`  ⚠ AAC-only on TIDAL — skipped (--flac-only mode).`);
            throw new lib.AacOnlyError(info);
        }
        console.log(`  ℹ No FLAC master on TIDAL — falling back to .m4a (320 kbps AAC).`);
    }

    const finalExt = isFlacOutput ? 'flac' : 'm4a';
    const finalPath = path.join(outDir, `${title}.${finalExt}`);
    const tmpExt = manifest.mimeType?.includes('mp4') ? 'm4a' : 'flac';
    const tmpPath = path.join(outDir, `${title}.tmp.${tmpExt}`);

    // Audio + cover in parallel
    const audioPromise = (manifest.type === 'dash_segments')
        ? downloadSegmentsParallel(manifest, tmpPath, flags.concurrency)
        : downloadDirect(manifest.url, tmpPath);
    const coverPromise = lib.fetchCover(info.album?.cover);

    await audioPromise;
    const coverBuf = await coverPromise;
    if (flags.debug && coverBuf) console.log(`  [debug] cover: ${(coverBuf.length / 1024).toFixed(0)} KB`);

    try {
        await remuxToFlac(tmpPath, finalPath, info, albumInfo, coverBuf);
    } catch (e) {
        console.error(`  ✘ FFmpeg failed: ${e.message}`);
        console.log(`     Raw file kept at: ${tmpPath}`);
        throw e;
    }
    try { fs.unlinkSync(tmpPath); } catch {}

    // Quick integrity check (catches segment-corruption issues) — FLAC only.
    if (isFlacOutput) await verifyFlac(finalPath);

    const stat = fs.statSync(finalPath);
    console.log(`  ✓ Saved: ${path.basename(finalPath)} (${(stat.size / 1024 / 1024).toFixed(1)} MB)`);
    return { path: finalPath, skipped: false };
}

// ─── AAC-only summary (only fires in --flac-only mode) ──────────────────────

/**
 * In default mode, AAC tracks are downloaded automatically as .m4a — no
 * summary needed. In --flac-only mode, AacOnlyError is thrown and bulk runners
 * collect the list. This function reports those skips.
 */
function handleAacSummary(aacOnly) {
    if (!aacOnly.length) return;
    console.log(`\n⚠ ${aacOnly.length} track${aacOnly.length === 1 ? '' : 's'} skipped (--flac-only): TIDAL has no FLAC master for them:`);
    for (const info of aacOnly) {
        const a = info.artists?.[0]?.name || info.artist?.name || '?';
        console.log(`    - ${a} — ${info.title}`);
    }
    console.log(`Re-run without --flac-only to grab them as .m4a (320 kbps AAC).`);
}

// ─── Album / playlist download ───────────────────────────────────────────────

async function downloadAlbum(albumId, outDir, cred, flags) {
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    const albumInfo = await lib.getAlbumInfo(albumId, token, countryCode);
    if (!albumInfo) throw new Error(`Album ${albumId} not found`);

    const albumDir = outDir;

    console.log(`\n=== Album: ${albumInfo.artist?.name} — ${albumInfo.title} ===`);
    console.log(`    Released: ${albumInfo.releaseDate || 'unknown'} | Output: ${albumDir}\n`);

    const items = await lib.getAlbumItems(albumId, token, countryCode);
    const tracks = items.map(it => it.item || it).filter(t => t && t.id && t.type !== 'video');
    console.log(`Found ${tracks.length} tracks.\n`);

    let ok = 0, failed = 0, skipped = 0;
    const aacOnly = [];
    for (let i = 0; i < tracks.length; i++) {
        const t = tracks[i];
        console.log(`[${i + 1}/${tracks.length}]`);
        try {
            const result = await downloadTrack(t.id, albumDir, cred, flags, { albumPreFetched: albumInfo });
            if (result.skipped) skipped++; else ok++;
        } catch (e) {
            if (e instanceof lib.AacOnlyError) { aacOnly.push(e.trackInfo); continue; }
            console.error(`  ✘ ${t.title}: ${e.message}`);
            failed++;
        }
    }
    console.log(`\nAlbum complete: ${ok} downloaded, ${failed} failed, ${aacOnly.length} AAC-only, ${tracks.length - ok - failed - aacOnly.length} skipped.`);
    handleAacSummary(aacOnly);
}

// ─── Spotify → TIDAL ─────────────────────────────────────────────────────────

async function downloadSpotifyTrack(spotifyId, outDir, cred, flags) {
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    console.log(`Fetching Spotify track ${spotifyId}...`);
    const sp = await lib.getSpotifyTrack(spotifyId);
    console.log(`  Spotify: ${sp.artists.map(a => a.name).join(', ')} — ${sp.name}`);

    const match = await lib.spotifyTrackToTidal(sp, token, countryCode);
    if (!match) {
        console.log('  ✗ No TIDAL match found.');
        return null;
    }
    console.log(`  → TIDAL match (${match.method}): id ${match.track.id}`);
    return await downloadTrack(match.track.id, outDir, cred, flags);
}

async function downloadSpotifyPlaylist(spotifyId, outDir, cred, flags) {
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    console.log(`Fetching Spotify playlist ${spotifyId}...`);
    const sp = await lib.getSpotifyPlaylist(spotifyId);
    console.log(`\n=== Spotify playlist: ${sp.name} ===`);
    console.log(`    Tracks: ${sp.tracks.length} | Owner: ${sp.owner?.display_name || '?'}`);
    if (sp._embedCapped) {
        console.log(`    ⚠ Spotify embed caps at 100 tracks. If this playlist has more,`);
        console.log(`      the rest won't be downloaded by this run.`);
    }
    console.log('');

    const plDir = outDir;
    console.log(`    Output: ${plDir}\n`);

    let ok = 0, failed = 0, notFound = 0;
    const aacOnly = [];
    for (let i = 0; i < sp.tracks.length; i++) {
        const t = sp.tracks[i];
        console.log(`[${i + 1}/${sp.tracks.length}] ${t.artists.map(a => a.name).join(', ')} — ${t.name}`);
        try {
            const match = await lib.spotifyTrackToTidal(t, token, countryCode);
            if (!match) {
                console.log('    ✗ No TIDAL match');
                notFound++;
                continue;
            }
            console.log(`    → TIDAL (${match.method}${match.score ? ', score ' + match.score : ''}): id ${match.track.id}`);
            await downloadTrack(match.track.id, plDir, cred, flags);
            ok++;
        } catch (e) {
            if (e instanceof lib.AacOnlyError) { aacOnly.push(e.trackInfo); continue; }
            console.error(`    ✘ ${e.message}`);
            failed++;
        }
        console.log('');
    }
    console.log(`\nPlaylist complete: ${ok} downloaded, ${notFound} not on TIDAL, ${aacOnly.length} AAC-only, ${failed} errored.`);
    handleAacSummary(aacOnly);
}

async function downloadSpotifyAlbum(spotifyId, outDir, cred, flags) {
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    console.log(`Fetching Spotify album ${spotifyId}...`);
    const sp = await lib.getSpotifyAlbum(spotifyId);
    console.log(`\n=== Spotify album: ${sp.artists.map(a => a.name).join(', ')} — ${sp.name} ===`);
    console.log(`    Tracks: ${sp.tracks.items.length}\n`);

    const albumDir = outDir;
    console.log(`    Output: ${albumDir}\n`);

    let ok = 0, failed = 0, notFound = 0;
    const aacOnly = [];
    for (let i = 0; i < sp.tracks.items.length; i++) {
        const t = sp.tracks.items[i];
        // Album tracks endpoint omits external_ids — fetch full track for ISRC
        let full = t;
        try { full = await lib.getSpotifyTrack(t.id); } catch {}
        console.log(`[${i + 1}/${sp.tracks.items.length}] ${full.artists.map(a => a.name).join(', ')} — ${full.name}`);
        try {
            const match = await lib.spotifyTrackToTidal(full, token, countryCode);
            if (!match) {
                console.log('    ✗ No TIDAL match');
                notFound++;
                continue;
            }
            console.log(`    → TIDAL (${match.method}): id ${match.track.id}`);
            await downloadTrack(match.track.id, albumDir, cred, flags);
            ok++;
        } catch (e) {
            if (e instanceof lib.AacOnlyError) { aacOnly.push(e.trackInfo); continue; }
            console.error(`    ✘ ${e.message}`);
            failed++;
        }
        console.log('');
    }
    console.log(`\nAlbum complete: ${ok} downloaded, ${notFound} not on TIDAL, ${aacOnly.length} AAC-only, ${failed} errored.`);
    handleAacSummary(aacOnly);
}

async function downloadPlaylist(uuid, outDir, cred, flags) {
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    const playlistInfo = await lib.getPlaylistInfo(uuid, token, countryCode);
    if (!playlistInfo) throw new Error(`Playlist ${uuid} not found`);

    const plDir = outDir;

    console.log(`\n=== Playlist: ${playlistInfo.title} ===`);
    console.log(`    Output: ${plDir}\n`);

    const items = await lib.getPlaylistItems(uuid, token, countryCode);
    const tracks = items.map(it => it.item || it).filter(t => t && t.id && t.type !== 'video');
    console.log(`Found ${tracks.length} tracks.\n`);

    let ok = 0, failed = 0;
    const aacOnly = [];
    for (let i = 0; i < tracks.length; i++) {
        const t = tracks[i];
        console.log(`[${i + 1}/${tracks.length}]`);
        try {
            await downloadTrack(t.id, plDir, cred, flags);
            ok++;
        } catch (e) {
            if (e instanceof lib.AacOnlyError) { aacOnly.push(e.trackInfo); continue; }
            console.error(`  ✘ ${t.title}: ${e.message}`);
            failed++;
        }
    }
    console.log(`\nPlaylist complete: ${ok} downloaded, ${failed} failed, ${aacOnly.length} AAC-only, ${tracks.length - ok - failed - aacOnly.length} skipped.`);
    handleAacSummary(aacOnly);
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
    const { flags, positional } = parseArgs(process.argv.slice(2));

    if (flags.help) {
        printHelp();
        process.exit(0);
    }
    if (!positional.length) {
        printHelp();
        process.exit(1);
    }

    if (flags.quality && !FLAC_QUALITIES.includes(flags.quality)) {
        console.error(`Invalid --quality. Must be one of: ${FLAC_QUALITIES.join(', ')}`);
        process.exit(1);
    }

    const parsed = lib.parseInputUrl(positional[0]);
    if (!parsed) {
        console.error(`Cannot parse input: "${positional[0]}"`);
        console.error('Provide a TIDAL or Spotify track/album/playlist URL, or a numeric TIDAL track ID.');
        process.exit(1);
    }

    const outDir = positional[1] ? path.resolve(positional[1]) : DEFAULT_OUT_DIR;
    if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });

    const cred = lib.loadCred();

    // Single-track wrappers catch AacOnlyError to offer the prompt inline
    const aacOnly = [];
    const singleTrackCatcher = async (fn) => {
        try { return await fn(); }
        catch (e) {
            if (e instanceof lib.AacOnlyError) { aacOnly.push(e.trackInfo); return null; }
            else throw e;
        }
    };

    // Capture the single-track result so we can signal "skipped" back to
    // bulk callers via exit code 2 (album/playlist exits stay 0).
    let trackResult = null;
    if (parsed.source === 'spotify') {
        if (parsed.type === 'track')    trackResult = await singleTrackCatcher(() => downloadSpotifyTrack(parsed.id, outDir, cred, flags));
        else if (parsed.type === 'album')   await downloadSpotifyAlbum(parsed.id, outDir, cred, flags);
        else if (parsed.type === 'playlist') await downloadSpotifyPlaylist(parsed.id, outDir, cred, flags);
    } else {
        if (parsed.type === 'track')    trackResult = await singleTrackCatcher(() => downloadTrack(parsed.id, outDir, cred, flags));
        else if (parsed.type === 'album')   await downloadAlbum(parsed.id, outDir, cred, flags);
        else if (parsed.type === 'playlist') await downloadPlaylist(parsed.id, outDir, cred, flags);
    }

    if (trackResult?.skipped) process.exitCode = 2;

    handleAacSummary(aacOnly);
}

main().catch(e => {
    console.error('\nError:', e.message);
    if (process.env.DEBUG) console.error(e.stack);
    process.exit(1);
});
