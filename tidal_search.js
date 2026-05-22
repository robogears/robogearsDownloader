// Quick TIDAL track search
// Usage: node tidal_search.js "stronger kanye west"

const lib = require('./tidal_lib');

(async () => {
    const query = process.argv.slice(2).join(' ');
    if (!query) {
        console.log('Usage: node tidal_search.js "<search terms>"');
        process.exit(0);
    }

    const cred = lib.loadCred();
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    const json = await lib.searchTracks(query, token, countryCode, 10);
    const items = json.items || [];
    if (!items.length) {
        console.log('No results.');
        return;
    }

    console.log(`\nTop ${items.length} results for "${query}":\n`);
    items.forEach((t, i) => {
        const artists = (t.artists || []).map(a => a.name).join(', ');
        const dur = `${Math.floor(t.duration / 60)}:${String(t.duration % 60).padStart(2, '0')}`;
        const hiRes = t.mediaMetadata?.tags?.includes('HIRES_LOSSLESS') ? ' [Hi-Res]' : '';
        console.log(`  [${i + 1}] ID ${t.id}  ${artists} — ${t.title} (${t.album?.title}) [${dur}]${hiRes}`);
    });
    console.log();
})().catch(e => {
    console.error('Error:', e.message);
    process.exit(1);
});
