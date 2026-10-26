Synthetic audio for the FLAC writer tests. Made by Scripts/make-audio-fixtures.sh
(tones plus seeded noise and a test-pattern cover; no real music). The script
regenerates every file byte for byte with the FFmpeg named in ffmpeg-version.txt.

cover.jpg                        48x40 JPEG (4:2:0), the cover passed to FFmpeg and the writer
bts-16-44100.flac                native FLAC like a TIDAL BTS stream: 1.0 s, 16-bit, 44.1 kHz
bts-24-96000.flac                native FLAC: 0.6 s, 24-bit, 96 kHz
dash-24-96000.mp4                DASH FLAC-in-fMP4, init + segments joined; dfLa has the full STREAMINFO
dash-live-16-44100.mp4           DASH FLAC-in-fMP4 encoded while packaging; dfLa sample count is 0
aac-320.m4a                      plain AAC .m4a (BTS-like)
dash-aac.mp4                     DASH AAC fMP4, joined
ffmpeg-bts-16-44100.flac         the Electron app's FFmpeg arguments applied to bts-16-44100.flac
ffmpeg-dash-24-96000.flac        ... applied to dash-24-96000.mp4
ffmpeg-dash-live-16-44100.flac   ... applied to dash-live-16-44100.mp4
ffmpeg-aac.m4a                   ... applied to aac-320.m4a
ffmpeg-version.txt               the FFmpeg that made them
