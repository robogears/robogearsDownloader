#!/usr/bin/env bash
# Makes the small synthetic audio fixtures used by the FLAC writer tests.
#
# Everything is generated: tones plus seeded noise, and a test-pattern cover.
# No real music, no TIDAL downloads. Re-run it only when the fixtures need to
# change; the tests read the committed outputs and never need FFmpeg.
#
# The ffmpeg-*.flac / ffmpeg-aac.m4a files are made with the exact argument
# list the Electron app used (tidal_download.js remuxToFlac, documented in
# docs/electron-reference/download-pipeline.md B11), so the tests can compare
# the native writer with what FFmpeg wrote. Findings: docs/spikes/audio-and-tagging.md.
#
# Usage: Scripts/make-audio-fixtures.sh   (from macos/Packages/RobogearsCore)
#        FFMPEG=/path/to/ffmpeg Scripts/make-audio-fixtures.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/Tests/RobogearsCoreTests/Fixtures/audio"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)}"
[ -x "$FFMPEG" ] || { echo "ffmpeg not found; set FFMPEG=/path/to/ffmpeg" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
ff() { "$FFMPEG" -hide_banner -loglevel error -y "$@"; }

# Joins a DASH output the way the Electron app did: the init segment, then
# every media segment in number order (download-pipeline.md B8).
dash_join() { # <source> <codec args…> -- <joined output>
    local src="$1"; shift
    local args=()
    while [ "$1" != "--" ]; do args+=("$1"); shift; done
    local dest="$2" dir="$tmp/dash-$RANDOM"
    mkdir "$dir"
    ff -i "$src" -map 0:a "${args[@]}" -f dash -seg_duration 0.25 -use_template 1 -use_timeline 1 \
        -init_seg_name 'init-$RepresentationID$.m4s' -media_seg_name 'seg-$RepresentationID$-$Number$.m4s' \
        "$dir/stream.mpd"
    cat "$dir/init-0.m4s" > "$dest"
    local n=1
    while [ -f "$dir/seg-0-$n.m4s" ]; do cat "$dir/seg-0-$n.m4s" >> "$dest"; n=$((n + 1)); done
}

# The Electron app's remux, argument for argument. The cover goes in on stdin.
electron_remux() { # <source> <destination>
    "$FFMPEG" -hide_banner -loglevel error -y -i "$1" -f mjpeg -i pipe:0 -map 0:a -map 1:v \
        -disposition:v attached_pic -c:a copy -c:v copy \
        -metadata:s:v "title=Album cover" -metadata:s:v "comment=Cover (front)" \
        -metadata "title=Blue Lantern – Café 東京" \
        -metadata "artist=Placeholder Artist, Second Example" \
        -metadata "album=Paper Harbour" \
        -metadata "album_artist=Placeholder Artist" \
        -metadata "track=7" \
        -metadata "disc=1" \
        -metadata "date=2011" \
        -metadata "copyright=℗ 2011 Example Records" \
        -metadata "isrc=ZZXX12600001" \
        "$2" < "$out/cover.jpg"
}

# Cover: a 48×40 test pattern (not square, so width and height can't be swapped unnoticed).
ff -f lavfi -i "testsrc2=size=48x40:rate=1" -frames:v 1 -q:v 6 "$out/cover.jpg"

# BTS-like native FLAC: 1.0 s at 16-bit/44.1 kHz and 0.6 s at 24-bit/96 kHz.
# Neither length is a whole number of 4608-sample frames, so the last frame is short.
ff -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=1.0" \
   -f lavfi -i "anoisesrc=color=pink:sample_rate=44100:duration=1.0:amplitude=0.05:seed=7" \
   -filter_complex "[0][1]amerge=inputs=2[a]" -map "[a]" -c:a flac -sample_fmt s16 "$out/bts-16-44100.flac"
ff -f lavfi -i "sine=frequency=440:sample_rate=96000:duration=0.6" \
   -f lavfi -i "anoisesrc=color=pink:sample_rate=96000:duration=0.6:amplitude=0.01:seed=7" \
   -filter_complex "[0][1]amerge=inputs=2[a]" -map "[a]" -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 \
   "$out/bts-24-96000.flac"

# DASH-like FLAC in fragmented MP4, joined.
#  - dash-24-96000.mp4: the 24-bit FLAC packaged without re-encoding, so dfLa
#    carries the full STREAMINFO (as a packager working from a finished file would).
#  - dash-live-16-44100.mp4: encoded while packaging, so dfLa's sample count,
#    minimum frame size and MD5 are 0 ("unknown").
dash_join "$out/bts-24-96000.flac" -c:a copy -- "$out/dash-24-96000.mp4"
dash_join "$out/bts-16-44100.flac" -c:a flac -- "$out/dash-live-16-44100.mp4"

# AAC: a plain .m4a (BTS-like) and a joined DASH fragmented MP4.
ff -i "$out/bts-16-44100.flac" -c:a aac -b:a 320k "$out/aac-320.m4a"
dash_join "$out/aac-320.m4a" -c:a copy -- "$out/dash-aac.mp4"

# What the Electron app's FFmpeg step wrote for each kind of download.
electron_remux "$out/bts-16-44100.flac" "$out/ffmpeg-bts-16-44100.flac"
electron_remux "$out/dash-24-96000.mp4" "$out/ffmpeg-dash-24-96000.flac"
electron_remux "$out/dash-live-16-44100.mp4" "$out/ffmpeg-dash-live-16-44100.flac"
electron_remux "$out/aac-320.m4a" "$out/ffmpeg-aac.m4a"

"$FFMPEG" -version | head -1 > "$out/ffmpeg-version.txt"
ls -l "$out"
du -sh "$out"
