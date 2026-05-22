// Reads a tracklist JSON file and downloads each entry. Used by the Electron
// app for OCR'd screenshots and any other bulk-download flow.
//
// Tracklist file shape:
//   { tracks: [{ title, artist }, ...], outDir: "Z:\\Downloads" }

const path = require('path');
const { spawn } = require('child_process');
const lib = require('./tidal_lib');

const normalize = s => (s || '').toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();

function scoreMatch(item, wantTitle, wantArtist) {
    const itemTitle = normalize(item.title);
    const itemArtists = (item.artists || []).map(a => normalize(a.name)).join(' ');
    const wt = normalize(wantTitle);
    const wa = normalize(wantArtist);

    let titleScore = 0;
    if (itemTitle === wt) titleScore = 100;
    else if (itemTitle.startsWith(wt) || wt.startsWith(itemTitle)) titleScore = 50;
    else if (itemTitle.includes(wt) || wt.includes(itemTitle)) titleScore = 25;

    const waTokens = wa.split(' ').filter(t => t.length > 2);
    const matchedTokens = waTokens.filter(t => itemArtists.includes(t)).length;
    const artistScore = waTokens.length ? Math.round((matchedTokens / waTokens.length) * 100) : 0;

    return { titleScore, artistScore, total: titleScore + artistScore };
}

// Returns the child's exit code so the caller can distinguish:
//   0 → downloaded, 2 → skipped, anything else → failed.
function runDownload(trackId, outDir) {
    return new Promise((resolve) => {
        const args = [path.join(__dirname, 'tidal_download.js'), String(trackId), outDir, '--skip-library-check'];
        const p = spawn(process.execPath, args, {
            cwd: __dirname,
            stdio: 'inherit',
            env: { ...process.env, ELECTRON_RUN_AS_NODE: '1', FORCE_COLOR: '0' },
        });
        p.on('close', code => resolve(code));
    });
}

(async () => {
    const listPath = process.argv[2];
    if (!listPath) { console.error('Usage: node bulk_runner.js <tracklist.json>'); process.exit(1); }

    const { tracks, outDir } = JSON.parse(require('fs').readFileSync(listPath, 'utf8'));
    if (!tracks?.length) { console.error('No tracks in list.'); process.exit(1); }

    const cred = lib.loadCred();
    const token = await lib.getToken(cred);
    const country = await lib.getCountryCode(cred);

    console.log(`\n=== Batch download → ${outDir} ===\n`);
    console.log(`${tracks.length} tracks queued.\n`);

    let ok = 0, skipped = 0, failed = 0, notFound = 0;
    for (let i = 0; i < tracks.length; i++) {
        const t = tracks[i];
        const label = `${t.title || '?'} — ${t.artist || '?'}`;
        console.log(`[${i + 1}/${tracks.length}] ${label}`);

        // Direct TIDAL ID — skip search
        let trackId = t.tidalId;

        // Otherwise: search by title + artist
        if (!trackId && t.title && t.artist) {
            try {
                const json = await lib.searchTracks(`${t.title} ${t.artist}`, token, country, 10);
                const items = json.items || [];
                const scored = items
                    .map(it => ({ it, ...scoreMatch(it, t.title, t.artist) }))
                    .filter(s => s.titleScore === 100 || (s.titleScore >= 25 && s.artistScore >= 50))
                    .sort((a, b) => b.total - a.total);
                if (scored.length) {
                    trackId = scored[0].it.id;
                    console.log(`    → matched (id ${trackId}, score ${scored[0].total})`);
                } else {
                    console.log('    → no good match');
                }
            } catch (e) {
                console.log(`    → search error: ${e.message}`);
            }
        }

        if (!trackId) { notFound++; console.log(''); continue; }

        const code = await runDownload(trackId, outDir);
        if (code === 0) ok++;
        else if (code === 2) skipped++;
        else failed++;
        console.log('');
    }

    console.log(`\n=== Batch complete: ${ok} downloaded, ${skipped} skipped, ${failed} failed, ${notFound} not found ===`);
})().catch(e => {
    console.error('Fatal:', e.message);
    process.exit(1);
});
