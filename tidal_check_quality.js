// Check what audio quality tiers TIDAL has for a track
// Usage: node tidal_check_quality.js <track-id>

const lib = require('./tidal_lib');

(async () => {
    const id = process.argv[2];
    if (!id) {
        console.log('Usage: node tidal_check_quality.js <track-id>');
        process.exit(0);
    }

    const cred = lib.loadCred();
    const token = await lib.getToken(cred);
    const countryCode = await lib.getCountryCode(cred);

    const trk = await lib.getTrackInfo(id, token, countryCode);
    console.log(`\nTrack: ${trk.artists?.[0]?.name} — ${trk.title}`);
    console.log(`  audioQuality: ${trk.audioQuality}`);
    console.log(`  audioModes:   ${JSON.stringify(trk.audioModes)}`);
    console.log(`  mediaMetadata.tags: ${JSON.stringify(trk.mediaMetadata?.tags)}`);

    console.log('\n— Probing each quality tier —');
    for (const q of ['LOW', 'HIGH', 'LOSSLESS', 'HI_RES', 'HI_RES_LOSSLESS', 'DOLBY_ATMOS']) {
        try {
            const j = await lib.getPlaybackInfo(id, token, q, countryCode);
            let line = j.audioQuality;
            if (j.manifest) {
                const decoded = Buffer.from(j.manifest, 'base64').toString('utf8');
                const codec = (decoded.match(/codecs="([^"]+)"/) || [])[1];
                const rate = (decoded.match(/audioSamplingRate="([^"]+)"/) || [])[1];
                const repId = (decoded.match(/<Representation\s+id="([^"]+)"/) || [])[1];
                line += ` | codec=${codec} | rate=${rate} | rep=${repId}`;
            }
            console.log(`  ${q.padEnd(18)} → ${line}`);
        } catch (e) {
            console.log(`  ${q.padEnd(18)} → ${e.message}`);
        }
    }
})().catch(e => {
    console.error('Error:', e.message);
    process.exit(1);
});
