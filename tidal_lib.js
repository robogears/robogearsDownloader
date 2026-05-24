// Shared TIDAL library — used by tidal_download.js, tidal_search.js,
// tidal_check_quality.js. Contains auth/token mgmt, HTTP helpers with
// retry/timeout, TIDAL API wrappers, and small utilities.

const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');

// Token path: in dev (running from source) defaults to ./token.json. In a
// packaged Electron app the source dir is read-only (inside an asar), so
// electron-main sets TIDAL_TOKEN_PATH env var to point at userData instead.
const TOKEN_FILE = process.env.TIDAL_TOKEN_PATH || path.join(__dirname, 'token.json');
const USER_AGENT = 'okhttp/5.3.2';
const DEFAULT_TIMEOUT = 30_000;
const DEFAULT_RETRIES = 3;

/**
 * Master music library — read-only check before any download. If a track with
 * a matching title already exists here, we skip the download. The path is
 * configurable via Settings; defaults to '' (no library configured), which
 * makes the library check a no-op until the user picks a folder.
 */
let LIBRARY_PATH = process.env.TIDAL_LIBRARY_FOLDER || '';
const LIBRARY_EXTS = new Set(['.flac', '.m4a', '.mp3', '.wav', '.aac', '.ogg', '.opus', '.alac']);

/** Override the library path at runtime; resets the scan cache. */
function setLibraryPath(p) {
    LIBRARY_PATH = (p || '').trim();
    _libraryCache = null;
}

/**
 * Thrown by downloadTrack when TIDAL only has the track in AAC (no lossless
 * master available). Bulk callers catch this and collect the list to ask the
 * user about at the end.
 */
class AacOnlyError extends Error {
    constructor(trackInfo) {
        super('Track is AAC-only on TIDAL');
        this.name = 'AacOnlyError';
        this.trackInfo = trackInfo;
    }
}

// ─── Token / credential management ───────────────────────────────────────────

function loadCred() {
    if (!fs.existsSync(TOKEN_FILE)) {
        console.error('token.json not found. Run tidal_auth_node.js first.');
        process.exit(1);
    }
    const data = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
    const entries = Array.isArray(data) ? data : [data];
    if (!entries.length) {
        console.error('No credentials in token.json. Run tidal_auth_node.js first.');
        process.exit(1);
    }
    return entries[0];
}

function saveCred(cred) {
    const data = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
    const entries = Array.isArray(data) ? data : [data];
    // Preserve every field on the cred so cached access_token/expires_at/countryCode survive reruns
    entries[0] = { ...entries[0], ...cred };
    fs.writeFileSync(TOKEN_FILE, JSON.stringify(entries, null, 4));
}

async function refreshToken(cred) {
    const res = await httpsRequest({
        hostname: 'auth.tidal.com',
        path: '/v1/oauth2/token',
        method: 'POST',
        timeout: DEFAULT_TIMEOUT,
    }, formEncode({
        client_id: cred.client_ID,
        refresh_token: cred.refresh_token,
        grant_type: 'refresh_token',
        scope: 'r_usr+w_usr+w_sub',
    }), { auth: [cred.client_ID, cred.client_secret] });

    if (res.status !== 200) {
        throw new Error(`Token refresh failed: ${res.status} ${res.body}`);
    }
    const json = JSON.parse(res.body);
    cred.access_token = json.access_token;
    cred.expires_at = Date.now() + (json.expires_in || 3600) * 1000 - 60_000;
    // Auth response sometimes includes user.countryCode — capture if present
    if (json.user?.countryCode && !cred.countryCode) {
        cred.countryCode = json.user.countryCode;
    }
    saveCred(cred);
    return cred.access_token;
}

async function getToken(cred) {
    if (cred.access_token && cred.expires_at && Date.now() < cred.expires_at) {
        return cred.access_token;
    }
    return refreshToken(cred);
}

async function getCountryCode(cred) {
    if (cred.countryCode) return cred.countryCode;
    const token = await getToken(cred);
    try {
        const res = await tidalGet(`/v1/users/${cred.userID}`, token, { countryCode: 'US' });
        if (res.status === 200) {
            const json = JSON.parse(res.body);
            if (json.countryCode) {
                cred.countryCode = json.countryCode;
                saveCred(cred);
                return cred.countryCode;
            }
        }
    } catch { /* fall through */ }
    return 'US';
}

// ─── HTTP helpers ────────────────────────────────────────────────────────────

function formEncode(obj) {
    return Object.entries(obj)
        .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
        .join('&');
}

function httpsRequest(opts, body = null, { auth = null } = {}) {
    return new Promise((resolve, reject) => {
        const headers = {
            'User-Agent': USER_AGENT,
            'Accept': 'application/json',
            'Accept-Encoding': 'identity',
            ...opts.headers,
        };
        if (body) {
            headers['Content-Type'] = headers['Content-Type'] || 'application/x-www-form-urlencoded';
            headers['Content-Length'] = Buffer.byteLength(body);
        }
        if (auth) headers['Authorization'] = 'Basic ' + Buffer.from(`${auth[0]}:${auth[1]}`).toString('base64');

        const req = https.request({ ...opts, headers }, res => {
            let d = '';
            res.on('data', c => d += c);
            res.on('end', () => resolve({ status: res.statusCode, body: d }));
        });
        const timeout = opts.timeout || DEFAULT_TIMEOUT;
        req.setTimeout(timeout, () => req.destroy(new Error(`Request timeout after ${timeout}ms`)));
        req.on('error', reject);
        if (body) req.write(body);
        req.end();
    });
}

function tidalGet(urlPath, token, params) {
    const qs = params ? '?' + Object.entries(params).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&') : '';
    return httpsRequest({
        hostname: 'api.tidal.com',
        path: urlPath + qs,
        method: 'GET',
        timeout: DEFAULT_TIMEOUT,
        headers: {
            'Authorization': `Bearer ${token}`,
            'X-Tidal-Platform': 'android',
        },
    });
}

/**
 * Stream-aware download to a buffer with retry/backoff/timeout.
 * Retries on network errors, timeouts, 429 and 5xx responses.
 */
function fetchBuffer(url, { timeout = DEFAULT_TIMEOUT, retries = DEFAULT_RETRIES } = {}) {
    return new Promise(async (resolve, reject) => {
        let attempt = 0;
        let lastErr = null;
        while (attempt <= retries) {
            try {
                const buf = await fetchBufferOnce(url, timeout);
                return resolve(buf);
            } catch (e) {
                lastErr = e;
                const retriable = e.retriable !== false;
                if (!retriable || attempt === retries) break;
                const backoff = Math.min(1000 * 2 ** attempt, 8000);
                await new Promise(r => setTimeout(r, backoff));
                attempt++;
            }
        }
        reject(lastErr);
    });
}

function fetchBufferOnce(url, timeout) {
    return new Promise((resolve, reject) => {
        const proto = url.startsWith('https') ? https : http;
        const doGet = (u, redirects = 0) => {
            if (redirects > 5) return reject(new Error('Too many redirects'));
            const req = proto.get(u, { headers: { 'User-Agent': USER_AGENT } }, res => {
                if (res.statusCode === 301 || res.statusCode === 302 || res.statusCode === 307) {
                    res.resume();
                    return doGet(res.headers.location, redirects + 1);
                }
                if (res.statusCode === 429 || res.statusCode >= 500) {
                    res.resume();
                    const err = new Error(`HTTP ${res.statusCode} for ${u}`);
                    err.retriable = true;
                    return reject(err);
                }
                if (res.statusCode !== 200) {
                    res.resume();
                    const err = new Error(`HTTP ${res.statusCode} for ${u}`);
                    err.retriable = false;
                    return reject(err);
                }
                const chunks = [];
                res.on('data', c => chunks.push(c));
                res.on('end', () => resolve(Buffer.concat(chunks)));
                res.on('error', reject);
            });
            req.setTimeout(timeout, () => {
                req.destroy(Object.assign(new Error(`Request timeout after ${timeout}ms`), { retriable: true }));
            });
            req.on('error', e => {
                if (!e.retriable) e.retriable = true; // network errors are retriable
                reject(e);
            });
        };
        doGet(url);
    });
}

// ─── TIDAL API wrappers ──────────────────────────────────────────────────────

async function getTrackInfo(id, token, countryCode = 'US') {
    const res = await tidalGet(`/v1/tracks/${id}`, token, { countryCode });
    if (res.status !== 200) throw new Error(`Track info failed: ${res.status} ${res.body}`);
    return JSON.parse(res.body);
}

async function getAlbumInfo(id, token, countryCode = 'US') {
    const res = await tidalGet(`/v1/albums/${id}`, token, { countryCode });
    if (res.status !== 200) return null;
    return JSON.parse(res.body);
}

async function getAlbumItems(id, token, countryCode = 'US') {
    const all = [];
    let offset = 0;
    const limit = 100;
    while (true) {
        const res = await tidalGet(`/v1/albums/${id}/items`, token, { countryCode, limit, offset });
        if (res.status !== 200) throw new Error(`Album items failed: ${res.status} ${res.body}`);
        const json = JSON.parse(res.body);
        const items = json.items || [];
        all.push(...items);
        if (items.length < limit) break;
        offset += limit;
    }
    return all;
}

async function getPlaylistInfo(uuid, token, countryCode = 'US') {
    const res = await tidalGet(`/v1/playlists/${uuid}`, token, { countryCode });
    if (res.status !== 200) return null;
    return JSON.parse(res.body);
}

async function getPlaylistItems(uuid, token, countryCode = 'US') {
    const all = [];
    let offset = 0;
    const limit = 100;
    while (true) {
        const res = await tidalGet(`/v1/playlists/${uuid}/items`, token, { countryCode, limit, offset });
        if (res.status !== 200) throw new Error(`Playlist items failed: ${res.status} ${res.body}`);
        const json = JSON.parse(res.body);
        const items = json.items || [];
        all.push(...items);
        if (items.length < limit) break;
        offset += limit;
    }
    return all;
}

async function getPlaybackInfo(id, token, quality = 'HI_RES_LOSSLESS', countryCode = 'US') {
    const res = await tidalGet(`/v1/tracks/${id}/playbackinfopostpaywall`, token, {
        countryCode,
        audioquality: quality,
        playbackmode: 'STREAM',
        assetpresentation: 'FULL',
    });
    if (res.status === 401) throw new Error('Unauthorized — token may be invalid');
    if (res.status !== 200) throw new Error(`Playback info failed: ${res.status} ${res.body}`);
    return JSON.parse(res.body);
}

async function searchTracks(query, token, countryCode = 'US', limit = 10) {
    const res = await tidalGet('/v1/search/tracks', token, { query, limit, countryCode });
    if (res.status !== 200) throw new Error(`Search failed: ${res.status} ${res.body}`);
    return JSON.parse(res.body);
}

// ─── Resolver: turn any input into a queueable track list ───────────────────

/**
 * Resolve a TIDAL or Spotify URL into a list of queue-ready track entries.
 * Each entry: { title, artist, duration, source, tidalId, matchMethod, notFound? }
 *
 * For Spotify, matches each track to TIDAL via spotifyTrackToTidal (ISRC →
 * fuzzy fallback). Spotify tracks that have no TIDAL match come back with
 * `notFound: true` so the UI can show them.
 *
 * For pure search queries (no URL), call searchTracksForQueue() instead.
 */
async function resolveUrlToTracks(input, token, countryCode = 'US', { isCancelled = null } = {}) {
    const parsed = parseInputUrl(input);
    if (!parsed) return null;
    const cancelled = () => typeof isCancelled === 'function' && isCancelled();

    const tidalEntry = (t) => ({
        tidalId: t.id,
        title: t.title,
        artist: (t.artists || []).map(a => a.name).join(', '),
        duration: t.duration,
        source: 'tidal',
        matchMethod: 'direct',
        hiRes: t.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') || false,
    });

    if (parsed.source === 'tidal') {
        let out = [];
        if (parsed.type === 'track') {
            const info = await getTrackInfo(parsed.id, token, countryCode);
            out = [tidalEntry(info)];
        } else if (parsed.type === 'album') {
            const items = await getAlbumItems(parsed.id, token, countryCode);
            out = items.map(i => i.item || i).filter(t => t?.id && t.type !== 'video').map(tidalEntry);
        } else if (parsed.type === 'playlist') {
            const items = await getPlaylistItems(parsed.id, token, countryCode);
            out = items.map(i => i.item || i).filter(t => t?.id && t.type !== 'video').map(tidalEntry);
        }
        if (cancelled()) return { tracks: [], cancelled: true };
        await enrichWithLibraryStatus(out);
        return { tracks: out, capped: false };
    }

    if (parsed.source === 'spotify') {
        let spTracks = [];
        let capped = false;
        if (parsed.type === 'track') {
            const t = await getSpotifyTrack(parsed.id);
            spTracks = t ? [t] : [];
        } else if (parsed.type === 'album') {
            const album = await getSpotifyAlbum(parsed.id);
            spTracks = (album && album.tracks && Array.isArray(album.tracks.items)) ? album.tracks.items : [];
        } else if (parsed.type === 'playlist') {
            const pl = await getSpotifyPlaylist(parsed.id);
            spTracks = (pl && Array.isArray(pl.tracks)) ? pl.tracks : [];
            capped = !!(pl && pl._embedCapped);
        }
        spTracks = spTracks.filter(Boolean);
        if (cancelled()) return { tracks: [], cancelled: true };

        // Parallel ISRC/search resolution, 8 at a time. Workers exit early on cancel.
        const results = new Array(spTracks.length);
        let next = 0;
        const worker = async () => {
            while (true) {
                if (cancelled()) return;
                const i = next++;
                if (i >= spTracks.length) return;
                const sp = spTracks[i];
                const artistStr = (sp.artists || []).map(a => a.name).join(', ');
                try {
                    const match = await spotifyTrackToTidal(sp, token, countryCode);
                    results[i] = {
                        title: sp.name,
                        artist: artistStr,
                        duration: Math.round((sp.duration_ms || 0) / 1000),
                        source: 'spotify',
                        tidalId: match?.track?.id || null,
                        matchMethod: match?.method || null,
                        notFound: !match,
                        hiRes: match?.track?.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') || false,
                    };
                } catch {
                    results[i] = {
                        title: sp.name,
                        artist: artistStr,
                        duration: Math.round((sp.duration_ms || 0) / 1000),
                        source: 'spotify',
                        tidalId: null,
                        notFound: true,
                    };
                }
            }
        };
        await Promise.all(Array.from({ length: 8 }, worker));
        if (cancelled()) return { tracks: [], cancelled: true };
        // Drop unresolved slots (cancellation can leave holes in the array)
        const filtered = results.filter(Boolean);
        await enrichWithLibraryStatus(filtered);
        return { tracks: filtered, capped };
    }
    return null;
}

/**
 * Search TIDAL by free-text query and return queue-ready entries (top N results).
 */
async function searchTracksForQueue(query, token, countryCode = 'US', limit = 10) {
    const json = await searchTracks(query, token, countryCode, limit);
    const out = (json.items || []).map(t => ({
        tidalId: t.id,
        title: t.title,
        artist: (t.artists || []).map(a => a.name).join(', '),
        album: t.album?.title || '',
        duration: t.duration,
        hiRes: t.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') || false,
        source: 'tidal',
        matchMethod: 'search',
    }));
    await enrichWithLibraryStatus(out);
    return out;
}

// ─── URL / ID parsing ────────────────────────────────────────────────────────

/** Parse a TIDAL URL or ID. Returns `{ type: 'track'|'album'|'playlist', id }` or null. */
function parseTidalUrl(input) {
    const s = input.trim();

    // Match TIDAL URLs of any subdomain
    const urlMatch = s.match(/tidal\.com\/(?:browse\/)?(track|album|playlist)\/([^/?#]+)/i);
    if (urlMatch) return { type: urlMatch[1].toLowerCase(), id: urlMatch[2] };

    // Plain numeric ID → assume track
    if (/^\d+$/.test(s)) return { type: 'track', id: s };

    // Plain UUID → assume playlist
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)) {
        return { type: 'playlist', id: s };
    }

    return null;
}

/** Parse a Spotify URL. Returns `{ type: 'track'|'album'|'playlist', id }` or null. */
function parseSpotifyUrl(input) {
    const m = input.trim().match(/open\.spotify\.com\/(?:intl-\w+\/)?(track|album|playlist)\/([a-zA-Z0-9]+)/i);
    if (m) return { type: m[1].toLowerCase(), id: m[2] };
    return null;
}

/** Unified parser. Returns `{ source: 'tidal'|'spotify', type, id }` or null. */
function parseInputUrl(input) {
    const sp = parseSpotifyUrl(input);
    if (sp) return { source: 'spotify', ...sp };
    const td = parseTidalUrl(input);
    if (td) return { source: 'tidal', ...td };
    return null;
}

// ─── Spotify: public embed scraping ─────────────────────────────────────────
//
// Spotify's Web API is heavily restricted for new dev apps (Nov 2024 policy:
// /v1/playlists/*/tracks returns 403 even with user OAuth). We use the public
// /embed/<type>/<id> pages for everything. PLAYLIST embed is capped at 100
// tracks — that's the trade-off for needing zero credentials.

const SPOTIFY_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

async function fetchSpotifyEmbed(type, id) {
    const res = await httpsRequest({
        hostname: 'open.spotify.com',
        path: `/embed/${type}/${id}`,
        method: 'GET',
        timeout: DEFAULT_TIMEOUT,
        headers: { 'User-Agent': SPOTIFY_UA, 'Accept': 'text/html' },
    });
    if (res.status !== 200) throw new Error(`Spotify ${type} embed failed: HTTP ${res.status}`);
    const m = res.body.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
    if (!m) throw new Error(`No __NEXT_DATA__ in Spotify ${type} embed`);
    const json = JSON.parse(m[1]);
    const entity = json?.props?.pageProps?.state?.data?.entity;
    if (!entity) throw new Error(`Unexpected Spotify embed shape for ${type}/${id}`);
    return entity;
}

function trackUriToId(uri) {
    if (!uri) return null;
    const m = uri.match(/spotify:track:([a-zA-Z0-9]+)/);
    return m ? m[1] : null;
}

function splitArtists(subtitle) {
    return (subtitle || '')
        .split(/,(?![^(]*\))/)         // split on comma not inside parens
        .map(s => s.trim())
        .filter(Boolean)
        .map(name => ({ name }));
}

async function getSpotifyTrack(id) {
    const e = await fetchSpotifyEmbed('track', id);
    return {
        id: e.id || id,
        name: e.name || e.title,
        artists: e.artists?.length ? e.artists.map(a => ({ name: a.name })) : splitArtists(e.subtitle),
        duration_ms: e.duration,
        external_ids: {},
        album: null,
    };
}

async function getSpotifyAlbum(id) {
    // Embed-only — Spotify API restricted for new dev apps
    const e = await fetchSpotifyEmbed('album', id);
    const albumArtists = e.artists?.length ? e.artists.map(a => ({ name: a.name })) : splitArtists(e.subtitle);
    const items = (e.trackList || []).map(t => ({
        id: trackUriToId(t.uri),
        name: t.title,
        artists: splitArtists(t.subtitle).length ? splitArtists(t.subtitle) : albumArtists,
        duration_ms: t.duration,
        external_ids: {},
        album: { name: e.name },
    }));
    return { id: e.id || id, name: e.name, artists: albumArtists, tracks: { items } };
}

async function getSpotifyPlaylist(id) {
    // Embed scrape — capped at 100 tracks
    const e = await fetchSpotifyEmbed('playlist', id);
    const tracks = (e.trackList || []).map(t => ({
        id: trackUriToId(t.uri),
        name: t.title,
        artists: splitArtists(t.subtitle),
        duration_ms: t.duration,
        external_ids: {},
        album: null,
    }));
    return {
        id: e.id || id,
        name: e.name,
        description: e.description || '',
        owner: { display_name: e.subtitle || '' },
        tracks,
        _embedCapped: tracks.length >= 100,
    };
}

/**
 * Resolve a Spotify track to a TIDAL track. Tries ISRC search first (~always
 * exact), falls back to title+artist+duration fuzzy match.
 * Returns the TIDAL track object or null.
 */
async function spotifyTrackToTidal(spTrack, tidalToken, countryCode = 'US') {
    // 1. ISRC search — most reliable cross-service identifier
    const isrc = spTrack.external_ids?.isrc;
    if (isrc) {
        const res = await tidalGet('/v1/tracks', tidalToken, { isrc, countryCode });
        if (res.status === 200) {
            const json = JSON.parse(res.body);
            const items = json.items || [];
            if (items.length) return { track: items[0], method: 'isrc' };
        }
    }

    // 2. Fall back to text search with scoring
    const title = spTrack.name || '';
    const artistList = (spTrack.artists || []).map(a => a.name);
    const artist = artistList.join(' ');
    const wantDuration = (spTrack.duration_ms || 0) / 1000;

    const json = await searchTracks(`${title} ${artist}`, tidalToken, countryCode, 10);
    const items = json.items || [];
    if (!items.length) return null;

    const norm = s => (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
    const wantT = norm(title);
    const wantA = norm(artist);

    const scored = items.map(it => {
        const itT = norm(it.title);
        const itA = (it.artists || []).map(a => norm(a.name)).join(' ');
        let titleScore = 0;
        if (itT === wantT) titleScore = 100;
        else if (itT.startsWith(wantT) || wantT.startsWith(itT)) titleScore = 50;
        else if (itT.includes(wantT) || wantT.includes(itT)) titleScore = 25;

        const aTokens = wantA.split(' ').filter(t => t.length > 2);
        const matched = aTokens.filter(t => itA.includes(t)).length;
        const artistScore = aTokens.length ? Math.round((matched / aTokens.length) * 100) : 0;

        const durDiff = Math.abs((it.duration || 0) - wantDuration);
        const durationScore = durDiff < 3 ? 50 : durDiff < 8 ? 25 : 0;

        return { it, titleScore, artistScore, durationScore, total: titleScore + artistScore + durationScore };
    });

    // Acceptance rules:
    //   - Exact title match (100) → accept regardless of artist
    //   - Partial title (25–50) → MUST have meaningful artist confirmation (>= 50)
    //   - No title match → reject
    const valid = scored
        .filter(s => s.titleScore === 100 || (s.titleScore >= 25 && s.artistScore >= 50))
        .sort((a, b) => b.total - a.total);
    if (!valid.length) return null;
    return { track: valid[0].it, method: 'search', score: valid[0].total };
}

// ─── Filesystem utilities ────────────────────────────────────────────────────

/** Strip characters illegal in Windows/macOS/Linux filenames. */
function sanitize(str) {
    return (str || 'unknown').replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim();
}

// ─── Existing library check (read-only) ─────────────────────────────────────

let _libraryCache = null;
let _libraryScanPromise = null;

/** "Full" normalize: lowercase + alphanumeric only. Preserves remix/edit suffixes. */
function normalizeFullForMatch(s) {
    if (!s) return '';
    return String(s).toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
}

/**
 * "Core" normalize: strips remix/edit/feat. suffixes and bracketed annotations.
 * Used to detect that two filenames are versions of the same song.
 */
function normalizeCoreForMatch(s) {
    if (!s) return '';
    let x = String(s).toLowerCase();

    // Strip from first "(" or "[" — but only if there's content before, so
    // titles like "(I Can't Get No) Satisfaction" are kept intact. Also handles
    // truncated filenames where the closing bracket is missing.
    const parenIdx = x.search(/[(\[]/);
    if (parenIdx > 0) x = x.slice(0, parenIdx);

    x = x.replace(/\s+(feat|ft|featuring)\.?\s+.*$/i, '');
    x = x.replace(
        /\s+-\s+(remix|edit|mix|extended|radio|original|instrumental|acoustic|live|remaster(?:ed)?|version|club|vip|dub|bootleg|rework|reprise|demo|single|album)\b.*$/i,
        ''
    );

    x = x.replace(/[^a-z0-9 ]/g, ' ');
    return x.replace(/\s+/g, ' ').trim();
}

/** Back-compat shim for any old callers. */
function normalizeForMatch(s) { return normalizeCoreForMatch(s); }

let _mmCached = null;
function loadMM() {
    if (_mmCached !== null) return _mmCached;
    try { _mmCached = require('music-metadata'); }
    catch { _mmCached = false; }
    return _mmCached;
}

/**
 * Recursively scan LIBRARY_PATH, reading both filename and audio-tag metadata
 * (title / artist / duration). Each entry exposes "full" and "core" normalized
 * forms of both filename and metadata title for two-tier matching.
 *
 * Async — metadata parsing is I/O-bound. Concurrency-limited (8 in flight).
 * Result is cached for the process lifetime; call `rescanLibrary()` to refresh.
 */
async function scanLibrary(onProgress) {
    if (_libraryCache !== null) return _libraryCache;
    if (_libraryScanPromise) return _libraryScanPromise;

    _libraryScanPromise = (async () => {
        const entries = [];
        if (!LIBRARY_PATH || !fs.existsSync(LIBRARY_PATH)) {
            return { entries };
        }
        const mm = loadMM();

        // First pass: walk the tree, collect file paths
        const files = [];
        const walk = (dir) => {
            let dirents;
            try { dirents = fs.readdirSync(dir, { withFileTypes: true }); }
            catch { return; }
            for (const ent of dirents) {
                const full = path.join(dir, ent.name);
                if (ent.isDirectory()) walk(full);
                else if (ent.isFile()) {
                    const ext = path.extname(ent.name).toLowerCase();
                    if (LIBRARY_EXTS.has(ext)) files.push({ full, name: ent.name, ext });
                }
            }
        };
        walk(LIBRARY_PATH);

        const total = files.length;
        if (typeof onProgress === 'function') onProgress(0, total);

        // Second pass: read metadata in parallel (concurrency 8). Throttle the
        // progress event to roughly one per 25 files (or the final tick) so we
        // don't flood the IPC channel.
        let nextIdx = 0;
        let done = 0;
        let lastReportedAt = 0;
        const worker = async () => {
            while (true) {
                const i = nextIdx++;
                if (i >= files.length) return;
                const { full, name, ext } = files[i];
                const rawBase = name.slice(0, name.length - ext.length);
                const sepIdx = rawBase.lastIndexOf(' - ');
                const filenameTitle = sepIdx >= 0 ? rawBase.slice(sepIdx + 3) : rawBase;

                let metaTitle = '', metaArtist = '', metaDuration = 0;
                if (mm) {
                    try {
                        const m = await mm.parseFile(full, { duration: true, skipCovers: true, skipPostHeaders: true });
                        metaTitle = m.common.title || '';
                        metaArtist = m.common.artist || (Array.isArray(m.common.artists) ? m.common.artists[0] : '') || '';
                        metaDuration = Math.round(m.format.duration || 0);
                    } catch { /* tag read failed — fall back to filename */ }
                }

                entries.push({
                    path: full,
                    fnFull: normalizeFullForMatch(rawBase),
                    fnTitleFull: normalizeFullForMatch(filenameTitle),
                    fnCore: normalizeCoreForMatch(rawBase),
                    fnTitleCore: normalizeCoreForMatch(filenameTitle),
                    metaTitleFull: normalizeFullForMatch(metaTitle),
                    metaTitleCore: normalizeCoreForMatch(metaTitle),
                    metaTitleDisplay: metaTitle,
                    metaArtist: normalizeFullForMatch(metaArtist),
                    metaDuration,
                });

                done++;
                if (typeof onProgress === 'function' && (done - lastReportedAt >= 25 || done === total)) {
                    lastReportedAt = done;
                    onProgress(done, total);
                }
            }
        };
        await Promise.all(Array.from({ length: 8 }, worker));
        return { entries };
    })();

    _libraryCache = await _libraryScanPromise;
    _libraryScanPromise = null;
    return _libraryCache;
}

/** Drop the cached scan; next call to scanLibrary will re-read everything. */
function rescanLibrary() {
    _libraryCache = null;
    _libraryScanPromise = null;
}

/**
 * Look up a track in the library. Returns one of:
 *   { kind: 'exact',   path, libraryTitle }  — same song, confirmed duplicate
 *                                              (title AND artist both agree)
 *   { kind: 'similar', path, libraryTitle }  — title matches but artist is
 *                                              uncertain or mismatched, OR
 *                                              core title matches a different
 *                                              version (remix/edit/etc)
 *   null                                       — not in library
 *
 * Why we don't trust title-only matches: sketchy MP3 dumps (SpotDownloader,
 * old YouTube rips, etc.) often have empty or wrong artist metadata, so a
 * file labeled "Monkey Wrench" might actually be a completely different song.
 * Title-only matches downgrade to `similar` so they show a yellow warning
 * badge instead of greying out the row entirely. The user can still see and
 * download them; they just aren't auto-skipped.
 *
 * Matching priority:
 *   1. metadata-title + matching artist → exact
 *   2. metadata-title alone (artist unconfirmed) → similar
 *   3. filename-title match → similar (filename has no reliable artist signal)
 *   4. core (remix-stripped) matches → similar
 */
async function findInLibrary(title, artist, _duration) {
    if (!title) return null;
    const cache = await scanLibrary();
    if (!cache.entries.length) return null;

    const tFull = normalizeFullForMatch(title);
    const tCore = normalizeCoreForMatch(title);
    if (!tCore || tCore.length < 3) return null;
    const aFull = normalizeFullForMatch(artist);

    // Strict artist match — both sides must be known AND overlap.
    // Empty-artist-on-either-side is NOT a free pass anymore.
    const artistsAgree = (e) => aFull && e.metaArtist
        && (e.metaArtist.includes(aFull) || aFull.includes(e.metaArtist));

    // 1: EXACT — title agrees AND artist explicitly agrees
    for (const e of cache.entries) {
        if (e.metaTitleFull && e.metaTitleFull === tFull && artistsAgree(e)) {
            return { kind: 'exact', path: e.path, libraryTitle: e.metaTitleDisplay || path.basename(e.path) };
        }
    }
    // 2: title-only matches (metadata title agrees but artist is unknown /
    //    different) → similar, with the file path so the user can investigate.
    for (const e of cache.entries) {
        if (e.metaTitleFull && e.metaTitleFull === tFull) {
            return { kind: 'similar', path: e.path, libraryTitle: e.metaTitleDisplay || path.basename(e.path) };
        }
    }
    // 3: filename-based title matches → similar (no reliable artist signal
    //    from a filename, even when it parses cleanly).
    for (const e of cache.entries) {
        if (e.fnTitleFull === tFull || e.fnFull === tFull) {
            return { kind: 'similar', path: e.path, libraryTitle: path.basename(e.path) };
        }
    }
    // 4: CORE matches — same song different version (remix/edit/etc)
    for (const e of cache.entries) {
        if (e.metaTitleCore && e.metaTitleCore === tCore) {
            return { kind: 'similar', path: e.path, libraryTitle: e.metaTitleDisplay || path.basename(e.path) };
        }
        if (e.fnTitleCore === tCore || e.fnCore === tCore) {
            return { kind: 'similar', path: e.path, libraryTitle: path.basename(e.path) };
        }
    }
    return null;
}

/** Tag each track in an array with its library status (mutates and returns). */
async function enrichWithLibraryStatus(tracks) {
    for (const t of tracks) {
        try {
            const m = await findInLibrary(t.title, t.artist, t.duration);
            if (m) t.libraryMatch = m;
        } catch { /* ignore per-track errors */ }
    }
    return tracks;
}

function coverUrl(coverId, size = 1280) {
    if (!coverId) return null;
    return `https://resources.tidal.com/images/${coverId.replace(/-/g, '/')}/${size}x${size}.jpg`;
}

async function fetchCover(coverId) {
    const url = coverUrl(coverId);
    if (!url) return null;
    try {
        return await fetchBuffer(url, { retries: 1 });
    } catch { return null; }
}

module.exports = {
    USER_AGENT,
    TOKEN_FILE,
    DEFAULT_TIMEOUT,
    get LIBRARY_PATH() { return LIBRARY_PATH; },
    setLibraryPath,
    scanLibrary,
    rescanLibrary,
    findInLibrary,
    enrichWithLibraryStatus,
    AacOnlyError,
    loadCred,
    saveCred,
    getToken,
    refreshToken,
    getCountryCode,
    httpsRequest,
    tidalGet,
    fetchBuffer,
    formEncode,
    getTrackInfo,
    getAlbumInfo,
    getAlbumItems,
    getPlaylistInfo,
    getPlaylistItems,
    getPlaybackInfo,
    searchTracks,
    parseTidalUrl,
    parseSpotifyUrl,
    parseInputUrl,
    resolveUrlToTracks,
    searchTracksForQueue,
    getSpotifyTrack,
    getSpotifyAlbum,
    getSpotifyPlaylist,
    spotifyTrackToTidal,
    sanitize,
    coverUrl,
    fetchCover,
};
