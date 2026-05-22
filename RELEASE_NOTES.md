# What's new in v0.1.1

- Fix CI release workflow — disable electron-builder's implicit publisher (was demanding `GH_TOKEN` on tag push and failing the mac build). Releases now flow through `softprops/action-gh-release` exclusively.

This is the **first public binary release**. Features listed under v0.1.0 below describe what's in this build — v0.1.0 itself never shipped because the release workflow broke.

# What's new in v0.1.0

First public release. Highlights:

- **Inputs**: paste a TIDAL or Spotify URL (track / album / playlist), type a song name to search, or drop a screenshot of a tracklist for OCR.
- **Queue review** before downloading — exact library matches are greyed with a "+ Add" opt-in; similar matches are flagged with a yellow badge.
- **Library deduplication** reads filename + ID3/Vorbis tags from your music folder so songs you already own aren't re-downloaded.
- **Quality policy**: requests TIDAL's Hi-Res lossless, gracefully falls back to CD-quality FLAC, and last-resort .m4a 320 kbps when no lossless master exists. Cover art + full metadata embedded.
- **Settings start blank on first launch** — pick your download folder and (optionally) your music library folder before downloading. "Reset config" button forgets both while keeping your TIDAL sign-in.
- **Batch summary** distinguishes downloaded / skipped / failed / not-found so you can tell at a glance what happened.
- **Skip messages** clarify whether a track was already in your downloads folder or your music library.
- **Sound effects**: a chime on confirmed download, a lower warning honk on blocked actions (no folder, no auth, empty queue), and a clown horn easter egg.
- **Screenshot OCR drop-zone is greyed with "Coming soon"** — feature-flagged off for this release; coming in a future build.

---

## Install

### Windows

Download `robogears-downloader.exe`, double-click to run. Windows will show a blue "Windows protected your PC" SmartScreen dialog the first time — click **More info → Run anyway**. Normal for unsigned apps; the build is not malicious.

The app stores its config at `%APPDATA%\Roaming\robogears Downloader\`. It doesn't install anything else; the .exe is fully portable.

### macOS (Apple Silicon)

Download `robogears-downloader-mac-arm64.zip`, unzip, drag `robogears Downloader.app` to `Applications`. On first launch, **right-click the app → Open** (don't double-click), then click **Open** on the Gatekeeper dialog. macOS doesn't trust the unsigned build until you authorise it once.

The app stores its config at `~/Library/Application Support/robogears Downloader/`.

---

## Requirements

- A TIDAL subscription. The app uses TIDAL's official OAuth device flow — sign in once via the Settings panel; tokens are cached locally and auto-refresh.
- Spotify playlist support uses the public embed page and is capped at **100 tracks** per playlist (Spotify-side limit).
