// Keeps chrome-extension/manifest.json#version in sync with package.json#version.
// Run via `npm run sync-ext` after bumping package.json's version field.
//
// The extension is loaded unpacked from the user's managed folder; Chrome
// shows whatever version is in the manifest. Keeping it aligned with the app
// version means "the v0.1.27 extension goes with the v0.1.27 app" — no
// separate version trail to track.

const fs = require('fs');
const path = require('path');

const repoRoot = path.join(__dirname, '..');
const pkg = JSON.parse(fs.readFileSync(path.join(repoRoot, 'package.json'), 'utf8'));
const manifestPath = path.join(repoRoot, 'chrome-extension', 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

if (manifest.version === pkg.version) {
    console.log(`chrome-extension/manifest.json already at ${pkg.version}`);
    process.exit(0);
}

const prev = manifest.version;
manifest.version = pkg.version;
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
console.log(`chrome-extension/manifest.json: ${prev} → ${pkg.version}`);
