# TIDAL FLAC Downloader

A small set of Node.js scripts that download lossless FLAC tracks (and albums and playlists) from TIDAL using the user's TIDAL subscription. No Python, no Docker, no proxy services — talks directly to TIDAL's API.

## Location

All scripts live in `Z:\Downloads\hifi-api\`. Run them from there.

## Prerequisites

- **Node.js 20+** (`node --version`). Already installed.
- **Active TIDAL subscription** (HiFi or HiFi Plus).
- Dependencies are already installed (`node_modules\ffmpeg-static`). If they aren't, run `npm install ffmpeg-static` in `Z:\Downloads\hifi-api`. The script also falls back to a system `ffmpeg` on PATH if the bundled binary is missing.

## Scripts

| Script | Purpose |
|---|---|
| `tidal_lib.js` | Shared library (token, HTTP, TIDAL API wrappers). Not run directly. |
| `tidal_auth_node.js` | One-time login. Opens browser to `link.tidal.com`, user clicks Allow, writes `token.json`. |
| `tidal_search.js "query"` | Search TIDAL for tracks. Returns up to 10 results with IDs; flags Hi-Res tracks. |
| `tidal_download.js <input> [outDir] [flags]` | Download a track, album, or playlist as FLAC with embedded metadata + cover art. |
| `tidal_check_quality.js <id>` | Probe all quality tiers for a track. Useful for confirming Hi-Res availability. |

## First-time setup

```
node Z:\Downloads\hifi-api\tidal_auth_node.js
```

A `link.tidal.com/...` URL prints in the terminal and auto-opens. User logs in and clicks **Allow**. The script writes `token.json` and exits. The country code from the user's TIDAL profile is also saved, so non-US accounts get correct regional metadata automatically.

`token.json` is read on every subsequent run. Tokens auto-refresh — the user does not need to log in again. The cached access token's `expires_at` is now persisted, so most runs avoid an unnecessary refresh round-trip.

## Daily usage

### Search

```
node tidal_search.js "stronger kanye west"
```
Output: numbered list. Tracks available in Hi-Res are marked `[Hi-Res]`.

### Download a single track

```
node tidal_download.js 103805726 "Z:\Downloads\Music"
node tidal_download.js https://tidal.com/browse/track/103805726 "Z:\Downloads\Music"
```

### Download a full album

```
node tidal_download.js https://tidal.com/browse/album/103805725 "Z:\Downloads\Music"
```
Creates `Z:\Downloads\Music\<Album Title>\` and puts each track inside as `<Title>.flac`.

### Download a playlist

```
node tidal_download.js https://tidal.com/browse/playlist/<uuid> "Z:\Downloads\Music"
```
Or with just the UUID:
```
node tidal_download.js abcd1234-5678-90ab-cdef-1234567890ab "Z:\Downloads\Music"
```
Creates `Z:\Downloads\Music\<Playlist Title>\`.

### Flags

| Flag | Meaning |
|---|---|
| `--quality LOSSLESS` | Force CD-quality (16-bit/44.1kHz). Smaller files, broader player compatibility. |
| `--quality HI_RES_LOSSLESS` | Force Hi-Res; fails if track isn't available in Hi-Res. |
| `--concurrency N` | Parallel segment downloads. Default 8. |
| `--force` | Re-download even if `<Title>.flac` already exists. |
| `--debug` | Print manifest details, segment counts, etc. |
| `--help` | Show usage. |

Default behavior with no `--quality` flag: requests Hi-Res first, falls back to LOSSLESS automatically if TIDAL doesn't have Hi-Res for the track.

## What the downloader does

1. Loads `token.json`, refreshes the access token if expired (`expires_at` is cached).
2. Auto-detects the country code from `token.json`, or fetches it from `/v1/users/{userID}` once and caches it.
3. Calls TIDAL's `/v1/tracks/{id}` for track metadata, `/v1/albums/{id}` for accurate release date + copyright.
4. Calls `/v1/tracks/{id}/playbackinfopostpaywall` to get the stream manifest (MPEG-DASH).
5. Parses the DASH manifest — finds `BaseURL`, init segment, segment template, and the `<SegmentTimeline>` `<S>` elements (`r="N"` expands to N+1 segments).
6. **Downloads the init segment + all media segments in parallel** (default concurrency 8) using a worker pool. Retries each segment up to 3 times on 429/5xx/network errors with exponential backoff (1s → 2s → 4s).
7. Concatenates the segments into a temp `.m4a` (FLAC-in-MP4 container).
8. **Fetches the album cover in parallel with the audio download.** Cover lives only in memory — never written to disk.
9. Runs **bundled FFmpeg** to remux the FLAC stream into a proper `.flac` container with metadata (title, artist, album, album_artist, track, disc, date, copyright, isrc) and the cover piped to stdin (`-f mjpeg -i pipe:0`).
10. Runs a quick FLAC integrity check (`ffmpeg -v error -i file.flac -f null -`) to catch silent corruption.
11. Deletes the temp file.

## Quality

- TIDAL returns audio in the **highest quality the track has available** for that account.
- Check with `tidal_check_quality.js <id>` — look at `mediaMetadata.tags`. If it contains `"HIRES_LOSSLESS"`, the track is available in Hi-Res (24-bit, up to 192 kHz). Otherwise it's LOSSLESS (16-bit/44.1 kHz, CD quality).
- The downloader requests `HI_RES_LOSSLESS` first and falls back to `LOSSLESS`. If TIDAL doesn't have Hi-Res for the track, the server returns LOSSLESS automatically.
- Force a specific tier with `--quality LOSSLESS` or `--quality HI_RES_LOSSLESS`.

## Important behaviors

- **Library de-dup check**: Before any download, the script scans `Z:\Dropbox\Music` (recursive, all common audio extensions). If a track with a matching title already exists there, the download is skipped and the existing path is reported. The library is read-only — the script never writes to it. Bypass with `--force` if a re-download is genuinely needed.
- **Filename**: `<Title>.flac` only — no artist prefix. User explicitly asked for this format.
- **Album/playlist downloads** put every track directly in the chosen output dir — no per-album subfolder. Collisions are handled by the skip-if-exists check.
- **Skip-if-exists**: re-running for the same track is now an instant no-op. Pass `--force` to override.
- **Output dir**: defaults to `Z:\Downloads` (hard-coded). The user has explicitly demanded this — do not override. Pass an explicit path as the second positional arg only if the user asks for it.
- **DRM**: the DASH manifest contains a `ContentProtection` element but FLAC segments themselves are **not encrypted**. Don't reject downloads based on the presence of `ContentProtection` in the manifest.
- **Segment counting**: `<S d="..." r="62"/>` means **63** segments (the element itself plus 62 repeats). Off-by-one here is a common bug.
- **Parallel segments**: downloads are 4-6× faster than sequential. Memory cost is roughly `concurrency × segment_size`, e.g. 8 × 4 MB = 32 MB peak for a Hi-Res track. The whole file is still held in memory before writing — that's fine up to a few hundred MB.

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `token.json not found` | Run `tidal_auth_node.js` first. |
| HTTP 401 from refresh | Token revoked. Re-run `tidal_auth_node.js`. |
| File is ~1 MB for a 4-minute track | Segment parser bug — only counted `<S>` elements without expanding `r=` repeats. Fixed in `parseManifest`. |
| `Track is DRM-encrypted` thrown | Manifest type was `application/vnd.tidal.bt` with `encryptionType != "NONE"`. Rare; usually means the track is a DJ-mix or similar. |
| FFmpeg fails | Bundled `node_modules/ffmpeg-static/ffmpeg.exe` missing. Either `npm install ffmpeg-static` in the hifi-api dir or have `ffmpeg` on PATH (the script falls back automatically). |
| FLAC integrity check warning | A segment may have come down corrupt. Re-run with `--force` to redownload. |

## What this is NOT

- Not the Monochrome web app (Qobuz proxy servers are down). Monochrome's directory at `Z:\Downloads\monochrome-main\monochrome-main` is unused.
- Not the original Python `hifi-api`. The Python `main.py` is unused — our Node scripts replace it. The hifi-api directory is just convenient for hosting the scripts.

## Credentials note

The TIDAL OAuth client ID/secret are the ones from the upstream `hifi-api/tidal_auth/tidal_auth.py` — embedded as base64 in `tidal_auth_node.js`. They work for LOSSLESS and HI_RES_LOSSLESS streaming where available. If a future TIDAL change breaks them, check whether the upstream repo updated theirs.

## Architecture note

All four scripts share `tidal_lib.js` for token management, HTTP (with retry + timeout + redirects), TIDAL API wrappers, URL parsing, and filename sanitisation. Each top-level script is now ~30-300 lines and focused on its own job. The library is the single place to fix HTTP/auth bugs.
