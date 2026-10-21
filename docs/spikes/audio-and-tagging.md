# Spike: audio decoding, FFmpeg's tags, and a native FLAC writer

_Item 8 of the overnight plan. Run on 21 Oct 2026, branch `loop/core-audio-spikes`. Everything used generated audio (tones plus seeded noise and a test-pattern cover). No TIDAL, Spotify or GitHub requests were made. Machine: Apple M1 (8 cores), macOS 27.0.1, Swift 6.4, FFmpeg 8.1.2 from Homebrew. Other work kept the machine very busy during the run (load average 100 to 150), so every timing below is an upper bound._

## The short version

**Recommendation: write FLAC files natively and don't bundle FFmpeg for them.** The native writer built here produces files whose audio is byte-for-byte the same as what the Electron app's FFmpeg step produced, with the same tags and the same cover block. It is also better in two ways that matter: the files always open in Apple's own audio frameworks, and no stray container tags leak in.

What was found, in plain words:

1. **macOS can play and decode TIDAL-style audio on its own.** Native FLAC (the kind TIDAL's single-file "BTS" streams deliver) decodes completely at 16-bit/44.1 kHz and 24-bit/96 kHz, and plays in both of Apple's players. The segmented "DASH" download, saved the way the Electron app saved it, also plays and decodes, with one quirk (it reports a slightly longer length than it has). AAC `.m4a` works too. Decoding a whole 4-minute 24-bit/96 kHz FLAC with `AVAudioFile` took 2.5 to 3.2 s for typical audio and 4.4 to 7.9 s for worst-case noise, on a heavily loaded machine (single runs went as high as 21 s with `AVAssetReader` under that load).
2. **One trap: a FLAC that doesn't state its length can't be decoded by Apple's frameworks at all.** A FLAC file's header (STREAMINFO) normally says how many samples it holds. A packager that encodes on the fly leaves that number at 0, meaning "unknown". FFmpeg copies the 0 into the finished file, and then Apple's decoders see a zero-length file. If TIDAL's Hi-Res segments carry a 0 there (needs a live check), the Electron app's Hi-Res files have this problem today. The native writer counts the samples and fills the number in.
3. **FFmpeg's exact output is now recorded.** Block order, every tag key with its exact upper and lower case, the vendor string, the cover block's fields, and the padding. FFmpeg also did two things nobody asked for: it **carried over any tags already in the downloaded file**, and for DASH (Hi-Res) tracks it **copied the MP4 container's brand names into the song's tags** (`major_brand=iso5` and two more). For `.m4a`, it wrote the iTunes title, artist, album artist, album, year, copyright, track, disc and cover, and **no ISRC**.
4. **The native writer matches FFmpeg where it should.** Identical audio frames and decoded audio (MD5 of the samples), identical STREAMINFO, a byte-identical cover block, and the same tag keys and values. The only differences are deliberate: it names itself instead of FFmpeg, it doesn't carry over the download's own tags or the MP4 brand names, and it fills in an unknown sample count. 78 unit tests in this lane cover it and run without FFmpeg. It reads two layouts only, native FLAC and fragmented MP4; FFmpeg read any container (see the recommendation).
5. **The Electron app's "FLAC integrity check" passes broken files.** A FLAC cut off at 60% passed it (FFmpeg exits 0 without `-xerror`). Apple's `AVAssetReader` also reports "completed" for the cut file. The check that works is comparing the decoded frame count with the length the file declares, which the new `AudioProbe` does. It only works when the file declares its length: for a FLAC that declares 0 samples it answers "length unknown", never "damaged".
6. **AAC (`.m4a`) can also be done without FFmpeg, if TIDAL sends a plain MP4.** Apple's passthrough export kept every AAC packet from a plain `.m4a` and wrote the tags and cover. From a joined DASH AAC download it kept only 43 of 45 packets, so that case would need a small native remuxer instead. Which container TIDAL uses for AAC needs a live check.

## Words used here

- **BTS / DASH**: TIDAL's two kinds of stream description. BTS gives one URL for the whole file (a native `.flac` for lossless). DASH gives an "init segment" plus numbered media segments; the Electron app downloaded them all and joined them into `<Title>.tmp.m4a` (download-pipeline.md B8).
- **Fragmented MP4 (fMP4)**: the container DASH uses. The init part holds the track description; each segment is a `moof` box (where the samples are and how big) followed by an `mdat` box (the samples). For FLAC, every sample is exactly one FLAC frame, and the track description carries FLAC's STREAMINFO in a `dfLa` box.
- **STREAMINFO**: the first FLAC header block: sample rate, channels, bit depth, total samples, MD5 of the audio. Zero means "unknown" for several fields.
- **VORBIS_COMMENT**: FLAC's tag block, a list of `KEY=value` lines plus a "vendor" string naming the program that wrote it.
- **PICTURE**: FLAC's artwork block. Picture type 3 is "front cover", the only type Rekordbox shows (CLAUDE.md, v0.1.17).

## (a) Can AVFoundation decode and play TIDAL-style audio?

**Answer: yes, with two caveats.** Native FLAC and AAC work completely. The joined DASH file works for playback and for `AVAssetReader`, but `AVAudioFile` overstates its length. And no Apple decoder handles a FLAC whose STREAMINFO says "length unknown".

### How it was tested

`docs/spikes/tools/avprobe.swift` opens a file with `AVAudioFile`, `AVURLAsset` + `AVAssetReader`, `AVAudioPlayer` and `AVPlayer`. It decodes the whole file twice, plays it silently (volume 0) for 0.4 s, and lists the tags Apple exposes.

```sh
swiftc -O docs/spikes/tools/avprobe.swift -o /tmp/avprobe
/tmp/avprobe src16.flac src24.flac dash16-copy.mp4 dash16-copy.tmp.m4a dash16-encoded.mp4 aac-src.m4a dash-aac.mp4
```

Inputs, made with FFmpeg in a scratch folder: `src16.flac` is 1.5 s at 16-bit/44.1 kHz. `src24.flac` is 1.0 s at 24-bit/96 kHz. `dash16-copy.mp4` is `src16.flac` packaged into DASH segments without re-encoding, with the init segment and three media segments joined in order (`cat init-0.m4s seg-0-1.m4s seg-0-2.m4s seg-0-3.m4s`). `dash16-encoded.mp4` is the same but encoded while packaging, so its `dfLa` sample count is 0. The AAC files are 320 kbps AAC, plain and as a joined DASH file.

### Results

| File | AVAudioFile | AVAssetReader | AVAudioPlayer | AVPlayer |
|---|---|---|---|---|
| Native FLAC 16/44.1 | flac, 44100 Hz, 2 ch, 16-bit; length 66150; decoded 66150 of 66150 | 66150 frames, completed | plays; duration 1.500 s | ready, plays |
| Native FLAC 24/96 | flac, 96000 Hz, 24-bit; decoded 96000 of 96000 | 96000, completed | plays; 1.000 s | ready, plays |
| Joined DASH FLAC (`.mp4` or `.tmp.m4a`) | length **69120** (rounded up to whole 4608-sample frames); decoded 66150, then error −39 (end of file) | **66150, completed** | plays; reports **1.567 s** | ready, plays |
| Joined DASH FLAC, `dfLa` count 0 | same as above: decoded 66150 of 69120, then −39 | 66150, completed | plays; 1.567 s | ready, plays |
| AAC `.m4a` | aac; decoded 66150 of 66150 | 65536 (priming trimmed) | plays | plays |
| Joined DASH AAC | decoded 65472 of 65472 | 64038 | plays | plays |

The decoded samples of the joined DASH file hash the same as the native FLAC's (`AVAudioFile` float PCM SHA-256 `fe73b43f08818b84…` for both), so nothing is lost; only the stated length is off.

### The "length unknown" trap

When FFmpeg copies a DASH file whose `dfLa` says 0 samples (the Electron app's exact arguments, see part b), the resulting FLAC keeps the 0:

```
$ /tmp/avprobe ff-dash16-encoded.flac
  AVAudioFile: opened. format=flac rate=44100.0 Hz channels=2 sourceBits=16 (from flags) length=0 frames (0.000 s)
  AVAudioFile: decoded 0 of 0 frames
  AVURLAsset: duration=0.000 s playable=true
  AVAssetReader: FAILED to start … AVFoundationErrorDomain Code=-11800 … NSOSStatusErrorDomain Code=-12780
  AVAudioPlayer: prepared=true play=true duration=1.567 s
```

`ffprobe` reports `duration=N/A` for the same file. The native writer's version of it reads `length=44100 frames (1.000 s)`, decodes all 44100, and `ffprobe` reports `duration=1.000000`. The unit test "FFmpeg's FLAC with an unknown sample count can't be decoded; the native file can" pins this.

Inside the MP4 the 0 does no harm, because the container keeps its own timing (the table above). It only bites once FFmpeg copies it into a native FLAC. Whether real TIDAL DASH streams carry a 0 here is the first live check below. With a full count (as `dash16-copy` has), FFmpeg's output decodes fine.

### Timing a 4-minute 24-bit/96 kHz file

Two 240-second stereo files were generated in the scratch folder (not committed). `long24-96.flac` is a tone plus pink noise (40 MB, close to how real music compresses at the low end). `dense24-96.flac` is loud white noise (135 MB, about the size of a real Hi-Res track, and the hardest case to decode). Each was also packaged as a joined DASH file. Five full runs per file (three for the native writer's output):

| File | AVAudioFile full decode | AVAssetReader full decode |
|---|---|---|
| long24-96.flac (40 MB) | 2.47, 2.50, 3.16, 2.82, 2.67 s | 1.96, 3.42, 4.35, 5.09, 2.19 s |
| dense24-96.flac (135 MB) | 7.92, 4.45, 6.83, 5.66, 5.14 s | 5.89, 3.62, 6.80, 20.9, 6.14 s |
| dense, joined DASH | 2.83, 3.25, 5.59, 5.06, 9.92 s (then error −39) | 1.54, 1.40, 2.32, 2.33, 3.33 s |
| dense, native writer's output | 5.35, 5.63, 5.49 s | 21.6, 9.41, 12.1 s |

The `AVAudioFile` column includes hashing every sample. For comparison, FFmpeg's own decode (`ffmpeg -threads 1 -i f -f null -`) took 1.1 to 1.7 s at the same time. The load average was 100 to 151 throughout, on 8 cores, so the spread says more about the machine than the decoders. Read these as "a few seconds per track, worst case". **Re-measure on an idle Mac** before designing around them (live check 6).

### What this means for other parts of the app

- **Preview (decision cards G5-1, G5-3):** AVFoundation can do it. For a DASH download, use `AVAssetReader` (exact length), or run the bytes through `FLACAudio` + `FLACWriter` into a temporary `.flac` first (about 0.15 s for a 40 MB track, below), which gives one code path with exact lengths for both stream kinds. Don't trust `AVAudioFile.length` on a joined DASH file.
- **Checking finished files (decision card G2-2):** the Electron check doesn't work. A FLAC cut off at 60% passes it:

  ```
  $ head -c $((75259*6/10)) ffmpeg-bts-16-44100.flac > cutoff.flac
  $ ffmpeg -v error -i cutoff.flac -f null - ; echo "exit=$?"
  [flac @ …] invalid residual … Decoding error: Invalid data found when processing input
  exit=0
  $ ffmpeg -v error -xerror -i cutoff.flac -f null - ; echo "exit=$?"
  exit=183
  $ /tmp/avprobe cutoff.flac
    AVAudioFile: … length=44100 frames … decoded 23040 of 44100 frames …; then FAILED NSOSStatusErrorDomain -39
    AVAssetReader: decoded 23040 frames …, completed
  ```

  `AVAssetReader` says "completed" for a file missing 40% of its audio. What catches it is comparing decoded frames with the declared length: `AudioProbe.inspect(url).verdict` is `.short` here (test "a cut-off FLAC is caught: it decodes fewer frames than it declares").

  That comparison only works when the file declares its length, which matters for card G2-2b (checking the old app's files before trusting them). With `-c:a copy`, FFmpeg wrote the source's STREAMINFO unchanged (identical bytes, part b). So a cut-off Electron-era file whose source declared its full length declares it too and is simply short, which the probe catches; the skeptic's hint that a half-written file carries a placeholder count doesn't apply to those. But a source that declared 0, which Hi-Res DASH streams may do (live checks 1 and 4), gave a file that declares 0, and AVFoundation decodes nothing from such a file, whole or cut off. The probe reports those as `.lengthUnknown`, meaning "can't judge", never "damaged": the healthy fixture `ffmpeg-dash-live-16-44100.flac` lands there (FFmpeg decodes it with `-xerror`, and its PCM matches the original's, table in part c). Test "a FLAC that doesn't state its length is 'length unknown', never short" pins this. **G2-2b must not label `.lengthUnknown` files damaged.** Judging them needs a native frame walk, not built yet: find each frame by its sync code and header CRC-8, check its CRC-16 footer, sum the block sizes, and compare the total with TIDAL's duration. A file that ends inside a frame, or whose last frame fails its CRC, is cut off.
- **Library tags (decision card G3-10):** on this macOS, AVFoundation does read FLAC tags, but only through the `org.xiph.vorbis-comment` metadata format, never through `commonMetadata`, which stays empty for FLAC. Keys come back upper-cased (`vorb/TITLE`, `vorb/ALBUMARTIST`), and the cover appears as `vorb/METADATA_BLOCK_PICTURE` holding just the JPEG bytes. The library lane can use the Swift reader built here, but not `FLACMetadataReader.read(_:)`: it needs every metadata block in memory, and both FFmpeg and the native writer put the cover (a 1280×1280 JPEG from TIDAL, usually hundreds of KB) before the tags, so the head of a file never reaches them. `FLACMetadataReader.summary(of:)` is the scanner's reader: it reads from the file one block header at a time, loads only STREAMINFO and VORBIS_COMMENT, and seeks past the cover and the padding, recording where each cover is so it can be read later. A VORBIS_COMMENT or PICTURE that doesn't decode is listed in `unreadableBlocks` instead of failing the file (both readers), so one bad cover from some tagger no longer costs the title and artist, and the scanner can count unreadable tags as G3-10's skeptic asks.

## (b) What the Electron app's FFmpeg step wrote

**Answer:** the table below, measured by running the exact argument list from `tidal_download.js` `remuxToFlac` and reading the result with the new Swift reader.

```sh
electron_remux() { # the exact Electron arguments; the cover goes in on stdin
  ffmpeg -y -i "$1" -f mjpeg -i pipe:0 -map 0:a -map 1:v -disposition:v attached_pic -c:a copy -c:v copy \
    -metadata:s:v "title=Album cover" -metadata:s:v "comment=Cover (front)" \
    -metadata "title=Blue Lantern – Café 東京" -metadata "artist=Placeholder Artist, Second Example" \
    -metadata "album=Paper Harbour" -metadata "album_artist=Placeholder Artist" -metadata "track=7" \
    -metadata "disc=1" -metadata "date=2011" -metadata "copyright=℗ 2011 Example Records" \
    -metadata "isrc=ZZXX12600001" "$2" < cover.jpg; }
```

The same function is in `macos/Packages/RobogearsCore/Scripts/make-audio-fixtures.sh`, which made the committed `ffmpeg-*.flac` and `ffmpeg-aac.m4a` fixtures.

### FLAC output

`flactool dump` (built from the package's own reader, see Reproduce):

```
file: ffmpeg-bts-16-44100.flac  bytes: 75259  leading tag: 0
block 0: streamInfo, 34 bytes
  44100 Hz, 2 ch, 16 bit, 44100 samples, blocks 4608-4608, frames 3967-6873 bytes, md5 bf88eb27d710aacb4cc0ea6450ec6ee6
block 1: picture, 1011 bytes
  type 3, image/jpeg, "Album cover", 48x40, depth 12, colors 0, 958 bytes of image
block 2: vorbisComment, 292 bytes
  vendor: Lavf62.12.102
  isrc=ZZXX12600001
  title=Blue Lantern – Café 東京
  artist=Placeholder Artist, Second Example
  album=Paper Harbour
  ALBUMARTIST=Placeholder Artist
  TRACKNUMBER=7
  DISCNUMBER=1
  date=2011
  copyright=℗ 2011 Example Records
  encoder=Lavf62.12.102
block 3: padding, 8192 bytes  (last)
  all zero: true
audio frames: start at byte 9549, 65710 bytes
```

| What | Exactly |
|---|---|
| Block order | STREAMINFO, PICTURE, VORBIS_COMMENT, PADDING. Only the last block has the "last" flag. |
| STREAMINFO | Copied byte for byte from the source (the source's own header, or the `dfLa` box for DASH). Not recomputed: a 0 sample count stays 0. |
| Vendor string | `Lavf62.12.102` (FFmpeg's container library and its version) |
| `-metadata title` | `title` (lower case) |
| `artist` | `artist` |
| `album` | `album` |
| `album_artist` | **`ALBUMARTIST`** (renamed, upper case) |
| `track` | **`TRACKNUMBER`** |
| `disc` | **`DISCNUMBER`** |
| `date` | `date` |
| `copyright` | `copyright` |
| `isrc` | `isrc` (lower case). This answers card G2-5's question: an Electron-era FLAC's ISRC is under `isrc`, and FLAC tag names ignore case, so look it up case-insensitively. |
| Added by FFmpeg | `encoder=Lavf62.12.102`, always last |
| Order | `isrc` first, then the others in argument order. It's a side effect of FFmpeg's option handling; readers don't care about order. |
| PICTURE | type **3** (front cover), MIME `image/jpeg`, description `Album cover` (from `-metadata:s:v title=`), the JPEG's width and height, colour depth **12** (FFmpeg's bits per pixel for a 4:2:0 JPEG), 0 colours, the JPEG bytes unchanged |
| PADDING | 8192 zero bytes, last |
| Audio | Frames copied unchanged: the frames after FFmpeg's metadata equal the source's (unit test "frames come out byte for byte as FFmpeg copied them", and `cmp` on the 4-minute files) |

**FFmpeg carries over tags already in the download.** Its default copies the first input's tags. A source FLAC tagged `TITLE=Source Title`, `comment=from the source file` and `LYRICS=la la` came out with `LYRICS=la la` and `DESCRIPTION=from the source file` added; `title` replaced `TITLE` because FFmpeg matches keys without regard to case. A cover already inside the source is dropped (`-map 0:a` takes audio only; the output had exactly one PICTURE).

**FFmpeg copies MP4 brand names into DASH tracks' tags.** From a joined DASH file, the Vorbis comment starts with three extra lines that describe the MP4 container, not the song:

```
  major_brand=iso5
  minor_version=512
  compatible_brands=iso5iso6mp41
```

So every Hi-Res (DASH) file the Electron app saved probably carries these three tags, with TIDAL's actual brand values (live check 4).

**Unknown sample count is kept.** From `dash16-encoded.mp4` (`dfLa` sample count 0), FFmpeg's FLAC has `12001200000000004a580ac442f00000000000…`: minimum frame size 0, total samples 0, MD5 all zeros. This is the file Apple's frameworks can't decode (part a).

### AAC `.m4a` output

`ffprobe -show_format` lists `title, artist, album_artist, album, date, encoder, copyright, track, disc`. The iTunes atoms, read directly from the file's `ilst` box (with a short Python box reader in the scratch folder; the AVFoundation test below pins the same ten keys):

```
  ©nam type=1 'Blue Lantern – Café 東京'
  ©ART type=1 'Placeholder Artist, Second Example'
  aART type=1 'Placeholder Artist'
  ©alb type=1 'Paper Harbour'
  ©day type=1 '2011'
  ©too type=1 'Lavf62.12.102'
  cprt type=1 '℗ 2011 Example Records'
  covr type=13 <jpeg 958 bytes, starts ffd8ff>
  trkn type=0 0000000700000000
  disk type=0 0000000100000000
```

There is **no ISRC** in the `.m4a` (no `-movflags use_metadata_tags`). The cover is a `covr` JPEG; the picture-type and description settings have no effect in MP4. The `moov` box sits at the end of the file. A joined DASH AAC input gives the same atoms, and FFmpeg turns it into an ordinary (unfragmented) MP4. AVFoundation sees exactly these ten `itsk/…` items (test "FFmpeg's .m4a has the iTunes title, artist, album, year, copyright, cover, track and disc, but no ISRC").

### FFmpeg version caveat

The Electron app shipped `ffmpeg-static` 5.3.0 (`package-lock.json`, licence GPL-3.0-or-later), not FFmpeg 8.1.2. The key renames, picture-type mapping, `encoder` tag and tag carry-over are long-standing FFmpeg behaviour, but the vendor version and the comment order may differ. Live check 4 confirms this on real Electron-era files (read-only).

## (c) The native FLAC writer

**Answer: built and proven.** The code is in `macos/Packages/RobogearsCore/Sources/RobogearsCore/Download/`:

| File | What it does |
|---|---|
| `FLACMetadata.swift` | The block formats: STREAMINFO, VORBIS_COMMENT, PICTURE (decode and encode), the JPEG size reader, the error cases |
| `FLACMetadataReader.swift` | Reads a FLAC file's blocks from memory (`read`) or from disk without the cover (`summary(of:)`), skips a leading ID3v2 tag, lists tag and picture blocks that don't decode, and checks FLAC frame headers (sync code, fields, CRC-8) |
| `FMP4FLACExtractor.swift` | Takes STREAMINFO from `dfLa` and the frames from each `moof`/`mdat`, in order. Every sample must lie inside its `mdat` (checked as each run is listed) and start with a valid frame header; its samples are counted. `FLACAudio(downloaded:)` picks native FLAC or fragmented MP4 from the first bytes; a progressive MP4 is refused. |
| `FLACWriter.swift` | `FLACTags` (the nine Electron tags), and `FLACWriter.data(…)` / `FLACWriter.write(…, to:)` |
| `../Audio/AudioProbe.swift` | Decodes a finished file with `AVAudioFile`, reports declared versus decoded frames, and gives a verdict: complete, short, or length unknown (can't judge) |

What it writes, and where it deliberately differs from FFmpeg:

| | FFmpeg (Electron) | Native |
|---|---|---|
| Audio frames | copied | copied, byte for byte |
| STREAMINFO | copied | copied; a 0 sample count is filled in from the frames (FLAC in MP4 only, where every frame is counted). Other "unknown" fields (minimum frame size, MD5) stay as they were. **Owner to confirm** (departs from reference B11): the literal behaviour keeps the 0, and then Apple's frameworks can't decode the file (part a). |
| Block order, padding | STREAMINFO, PICTURE, VORBIS_COMMENT, 8192 padding | the same |
| PICTURE | type 3, `image/jpeg`, `Album cover`, size, depth 12, 0 colours | byte-identical; bits per pixel is computed from the JPEG's sampling factors, which gives FFmpeg's 12 / 16 / 24 / 8 for 4:2:0 / 4:2:2 / 4:4:4 / grey |
| Tag keys | `title artist album ALBUMARTIST TRACKNUMBER DISCNUMBER date copyright isrc encoder` | the same keys and spelling, in the Electron app's order (`isrc` 9th rather than 1st) |
| Vendor and `encoder` | `Lavf62.12.102` | `robogears Downloader 0.1.31`. **Owner to confirm** (departs from reference B11): the literal behaviour names FFmpeg's container library and its version in both places. The writer's `toolName:` argument sets both, so the literal string is one argument away. |
| Tags already in the download | carried over: FFmpeg copies the input's tags, and the app's own keys replace same-named ones without regard to case | not written. **Owner to confirm** (departs from reference B11): the literal behaviour keeps whatever the download carried, such as a `LYRICS` tag (live check 2 shows whether TIDAL's files carry any). Keeping them would mean passing the source's Vorbis comment through to the writer. |
| MP4 brand names (DASH) | written as tags | not written. **Owner to confirm**, with the row above: the literal behaviour adds `major_brand`, `minor_version` and `compatible_brands` to every Hi-Res file. |
| Empty values | left out (`if (v)`) | left out; a track or disc number of 0 is left out too, as in JavaScript |
| Cover that isn't JPEG | FFmpeg fails (`-f mjpeg`) | throws `coverIsNotJPEG` (or `coverUnreadable` for a JPEG with no frame header); the download pipeline decides what to do (card G2-X7) |
| Existing output file | overwritten (`-y`) | refused; a failed write removes its own partial file (card G2-2) |

File names are not part of this lane. The writer takes a URL; the naming rule (`<Title>.flac` from TIDAL's title only, cards G2-5 and G2-6 pending) belongs to the download pipeline.

### Proof

**Unit tests (no FFmpeg needed):** `cd macos/Packages/RobogearsCore && swift test` runs 80 tests, all passing, with no build warnings (clean build). 78 of them are this lane's, in four suites: "FLAC metadata reader" (25), "FLAC in fragmented MP4" (24), "Native FLAC writer" (18) and "AVFoundation on TIDAL-style audio" (11). The fragment rules that no FFmpeg fixture reaches (every fixture has the same `tfhd` and `trun` flags and no `trex` default size) are tested on small MP4 files the tests build box by box (`SyntheticFMP4`). They compare the native output with the committed FFmpeg outputs (frames, STREAMINFO, the picture block, the tag set), and they check AVFoundation decodes and reads the native files.

Each key test was checked to fail when its rule is broken. In turn, I removed the sample-count fill-in, respelled `ALBUMARTIST`, dropped the `encoder` tag, removed the frame-header check, removed the "sample inside its `mdat`" check, allowed overwriting, and changed the bits-per-pixel formula. Each change made the named tests fail, and each source file was restored with `git checkout` afterwards. The tests also caught a real bug during the build: a track run that lists no per-sample sizes (FFmpeg writes one for a segment's single last frame) was rejected. It now has its own test. The fixes from the review of this spike were checked the same way: 15 rule breaks (the "length unknown" verdict, the `mdat` checks, the base-data-offset, `enca` and `dfLa` refusals, the no-fragments guard, the `trex` and `tfhd` default sizes, the following-`mdat` and cursor rules, the ID3 sniff, and both readers' per-block tolerance and cover skipping), each of which made its named test fail, with the sources restored from a copy afterwards.

Checked by source only: when a write fails part-way through the audio (a full disk, say), `FLACWriter.write` removes the file it created. No test can make the disk fail mid-write. The tests do cover the two cases around it: an existing file is never touched, and a failure before the file is created leaves nothing.

Known limits, left for later: a native FLAC's frames aren't walked one by one (its encoder-written STREAMINFO is trusted, so `countedSampleCount` is nil; live check 2 asks whether TIDAL's count is always there); a trailing ID3v1 tag on a native FLAC would be copied along with the frames; the source's SEEKTABLE is dropped, as FFmpeg dropped it; and a progressive (unfragmented) MP4 is refused (recommendation, below).

**Decoded audio is identical.** Commands run on the 4-minute files and on the fixtures:

```sh
pcm() { ffmpeg -loglevel error -i "$1" -map 0:a -c:a pcm_s32le -f md5 - ; }
```

| Input | Original FLAC | FFmpeg (Electron args) | Native |
|---|---|---|---|
| long24-96.flac (BTS-like, 40 MB) | `cbfc1f5d4f342125065371613a734f05` | the same | the same |
| long24-96, joined DASH | `cbfc1f5d4f342125065371613a734f05` | the same | the same |
| dense24-96, joined DASH (135 MB) | `d6cb542297f87686c387edbcd7726b8f` | the same | the same |
| bts-16-44100 fixture | | `f17d6f3823ffc75db1d6e3af40dadd3b` | the same |
| dash-24-96000 fixture | | `fce0c7539e91edaafcced29936155e39` | the same |
| dash-live-16-44100 fixture | | `f17d6f3823ffc75db1d6e3af40dadd3b` | the same |

(FLAC is lossless, so the live fixture, re-encoded from `bts-16-44100.flac`, decodes to the same samples and the same hash.)

The raw frames were also compared with `cmp` after each file's metadata: identical for all three large files (39,740,105 / 39,740,105 / 134,698,569 bytes). `ffmpeg -v error -xerror -i native.flac -f null -` exits 0 for each.

**Tags compare as intended** (`ffprobe -show_entries format_tags`, sorted, FFmpeg's file then native):

```
bts-16:   < TAG:encoder=Lavf62.12.102
          > TAG:encoder=robogears Downloader 0.1.31
dash-24:  < TAG:compatible_brands=iso5iso6mp41
          < TAG:encoder=Lavf62.12.102
          > TAG:encoder=robogears Downloader 0.1.31
          < TAG:major_brand=iso5
          < TAG:minor_version=512
```

Nothing else differs.

**ffprobe and AVFoundation read the native file and its cover:**

```
$ ffprobe … native-dash-24-96000.flac
index=0 codec_name=flac sample_rate=96000 bits_per_raw_sample=24
index=1 codec_name=mjpeg width=48 height=40 DISPOSITION:attached_pic=1 TAG:comment=Cover (front) TAG:title=Album cover
duration=0.600000

$ /tmp/avprobe native-dash-24-96000.flac
  AVAudioFile: … 96000.0 Hz … sourceBits=24 … decoded 57600 of 57600 frames
  AVURLAsset: org.xiph.vorbis-comment items [vorb/VENDOR=robogears Downloader 0.1.31 | vorb/TITLE=Blue Lantern – Café 東京 | …
              vorb/ISRC=ZZXX12600001 | vorb/ENCODER=robogears Downloader 0.1.31 | vorb/METADATA_BLOCK_PICTURE=<958 bytes>]
  AVAssetReader: decoded 57600 frames …, completed
  AVAudioPlayer: prepared=true play=true duration=0.600 s
  AVPlayer: readyToPlay
```

ffprobe reads the PICTURE block back as an attached picture with `comment=Cover (front)`, which is FFmpeg's name for type 3, exactly as for FFmpeg's own file.

**Speed:** writing the 135 MB DASH track took 0.51 s (0.15 s for the 40 MB ones), including the final flush to disk. FFmpeg's remux of the same files took 0.29 to 1.45 s under the same load. The source is memory-mapped and the frames are written in 4 MB pieces, so memory use stays flat.

## Recommendation: native writer, not a bundled FFmpeg

| | Native writer | Bundled FFmpeg |
|---|---|---|
| Same audio and tags as today | yes: frames and samples identical; same keys; cover block byte-identical | yes, by definition |
| Files Apple's frameworks can always decode | yes: fills in an unknown sample count | no: copies a 0 count (part a) |
| Stray tags | none | carries over download tags; MP4 brand names on DASH tracks |
| Licence | the repo's own code (MIT) | `ffmpeg-static` 5.3.0 is GPL-3.0-or-later; bundling means meeting the GPL, or building and maintaining an LGPL FFmpeg ourselves |
| Packaging | nothing extra | a signed helper binary in `Contents/Helpers`, signed for the hardened runtime, and found by path at run time (the Electron app needed its asar path rewrite for the same reason) |
| Failure modes | Swift errors with named causes (`notFLACInMP4(codec:)`, `invalidFrame(offset:)`, …) | exit code and a stderr tail; the Electron check ignored decode errors |
| Work left | AAC `.m4a` path; progressive FLAC-in-MP4, if TIDAL ever sends one (both below) | none for tags |

**For the AAC fallback** (rare: tracks with no lossless master), `docs/spikes/tools/m4aexport.swift` tried Apple's passthrough export with the same tags and cover:

- From a plain `.m4a`: all 45 AAC packets identical to the source and to FFmpeg's output (packet MD5 `a2f0cffc…`), the tags and the JPEG `covr` written, plus Apple's gapless-playback atom (`iTunSMPB`). Usable as is.
- From a joined DASH AAC file: only **43 of 45** packets survived. Apple applied the init segment's edit list (`media_time=1024`), so the audio is not a faithful copy. FFmpeg kept all 45.

So: if TIDAL's AAC arrives as a plain MP4 (live check 3), use `AVAssetExportSession` passthrough. If it arrives fragmented, add a small native defragmenter. It would reuse this lane's box reader, since AAC samples are byte ranges just like FLAC frames. Neither case needs FFmpeg.

**Lossless containers the native reader doesn't take.** It reads native FLAC (starts with `fLaC`) and fragmented MP4 (`moof`/`mdat` pairs). The Electron app gave FFmpeg whatever TIDAL sent, and FFmpeg reads any container, so two lossless cases are unproven until live check 8:

- **A progressive (unfragmented) MP4.** The Electron app expected single-file streams whose MIME type contains `mp4` (`tmpExt = manifest.mimeType?.includes('mp4') ? 'm4a' : 'flac'`, download-pipeline.md B7). FLAC in a progressive MP4 is refused today with `unsupportedMP4("no movie fragments")` (test "a progressive (unfragmented) MP4 is refused as having no movie fragments"). Reading it needs a sample-table reader: `stsz` for the sample sizes, `stsc` and `stco`/`co64` for where each chunk sits. That is about the size of the fragment reader.
- **A DASH manifest with a `BaseURL` and no `SegmentTemplate`.** The Electron app downloaded that one URL as a "direct" file named `.tmp.flac` (B7), whatever its container. `FLACAudio(downloaded:)` sniffs the bytes, so it takes the file if it's native FLAC or fragmented MP4 and refuses anything else by name.

These and the AAC fallback are the places the native plan isn't proven end to end.

## Needs a live TIDAL check

Real streams may differ from synthetic ones. Each check uses the owner's own account, changes nothing in it, and writes only to a scratch folder.

1. **Hi-Res DASH stream, inside the joined download.** For the declared-count question alone, live check 4 is enough: an Electron-era Hi-Res file's STREAMINFO is a byte copy of the stream's `dfLa`, so `/tmp/flactool dump` on one shows whether TIDAL declares 0. The rest needs a joined download, which the Electron app deletes after tagging (`tidal_download.js:461`) and has no flag to keep. To capture one:
   1. In a scratch clone of the last Electron release (`git clone --branch v0.1.30 https://github.com/robogears/robogearsDownloader tidal-capture && cd tidal-capture && npm ci`), delete line 461 of `tidal_download.js`, `try { fs.unlinkSync(tmpPath); } catch {}`.
   2. Run `TIDAL_TOKEN_PATH="$HOME/Library/Application Support/robogears Downloader/token.json" node tidal_download.js <Hi-Res track URL> ~/Desktop/tidal-capture-out --force --skip-library-check --debug`. The temp file (`<Title>.tmp.m4a` for DASH, `<Title>.tmp.flac` for a single-file stream) stays next to the finished `.flac`, and `--debug` prints what live check 8 records.
   3. Run `/tmp/flactool write "<Title>.tmp.m4a" cover.jpg out.flac` (built as in Reproduce; any JPEG will do for the cover). It prints the sample count `dfLa` declares and the count found in the frames.

   Expected: it succeeds, and the declared count is either 0 or the same as the counted one. Success also confirms what the reader assumes: `tfhd` counts offsets from the `moof`, every sample is one frame, the sound track is FLAC and not encrypted. A refusal names the layout it doesn't handle (`tfhd base data offset`, `encrypted audio`, `no movie fragments`, …).
2. **CD-quality BTS stream:** does TIDAL's `.flac` declare its full sample count in STREAMINFO? The native writer trusts that count (it doesn't walk native FLAC frames). If it were 0, every new CD-quality file would declare 0 too: Apple's frameworks couldn't decode it, and `AudioProbe` would answer "length unknown" for all of them, so the G2-2 check would be blind. Check with `/tmp/flactool dump` on a `.tmp.flac` captured as in live check 1 (with a CD-quality track), or on any Electron-era CD-quality file (FFmpeg copied the STREAMINFO). Also: does it already carry tags, a picture or a SEEKTABLE? FFmpeg kept its tags; the native writer drops all of them and the SEEKTABLE (as FFmpeg did). If TIDAL ships something worth keeping (ReplayGain, lyrics), decide then.
3. **AAC-only track:** which container does TIDAL send for AAC (plain MP4 or fragmented), and does it have an edit list? This picks the AAC path above.
4. **Existing Electron-era files:** dump one CD-quality and one Hi-Res file the old app saved (read-only). Confirm the keys match this record under `ffmpeg-static` 5.3.0, and see TIDAL's real `major_brand` values and whether any Hi-Res file has a 0 sample count (these would be the files that don't open in Apple's frameworks).
5. **macOS 15:** this ran on macOS 27.0.1. The app's minimum is macOS 15. Re-run `avprobe` there, especially FLAC decoding and the `org.xiph.vorbis-comment` tag format.
6. **Timing on an idle Mac:** re-run the 4-minute decode timings with nothing else running.
7. **Rekordbox (and Serato):** import a native file and confirm the cover and tags show. The PICTURE block is byte-identical to the Electron app's, so this is expected to work, but only the DJ software can confirm it.
8. **Which container each lossless stream really uses.** For one CD-quality and one Hi-Res track, run the capture in live check 1 and record from the `--debug` lines: `manifest type` (TIDAL's `manifestMimeType`), `codec` and `mimeType` (for a BTS stream, the manifest JSON's `codecs` and `mimeType`), and `segments` (a number for DASH, `direct` otherwise). Then record the temp file's first 16 bytes (`xxd -l 16 <file>`) and whether `/tmp/flactool write` takes it. Also note whether any DASH manifest has a `BaseURL` but no `SegmentTemplate` (`segments: direct` with a DASH manifest type). Expected: lossless BTS is `audio/flac` with codecs `flac` and starts with `fLaC`; DASH has a `SegmentTemplate` and the joined file is fragmented MP4. A lossless stream in a progressive MP4 (`/tmp/flactool write` says `no movie fragments`) means the native path needs the sample-table reader (recommendation) before it can replace FFmpeg.

## Reproduce

```sh
# Fixtures (only to regenerate; the tests use the committed files):
cd macos/Packages/RobogearsCore && Scripts/make-audio-fixtures.sh
# Tests:
swift build 2>&1 | grep -E "warning:|error:" ; swift test
# Tools (from the repository root):
swiftc -O docs/spikes/tools/avprobe.swift -o /tmp/avprobe
swiftc -O docs/spikes/tools/m4aexport.swift -o /tmp/m4aexport
P=macos/Packages/RobogearsCore/Sources/RobogearsCore
swiftc -O -module-name flactool $P/RobogearsCore.swift $P/Download/FLACMetadata.swift \
  $P/Download/FLACMetadataReader.swift $P/Download/FMP4FLACExtractor.swift \
  $P/Download/FLACWriter.swift docs/spikes/tools/flactool/main.swift -o /tmp/flactool
/tmp/flactool dump some.flac
/tmp/flactool write download.tmp.m4a cover.jpg "Out.flac" title="…" artist="…" album_artist="…" track=7
```

The fixture script runs the same FFmpeg steps every time and produced byte-identical files on a second run (`shasum -a 256` before and after). The scratch experiments used the same commands on longer generated files; the 4-minute files were generated with:

```sh
ffmpeg -f lavfi -i "sine=frequency=220:sample_rate=96000:duration=240" \
       -f lavfi -i "anoisesrc=color=pink:sample_rate=96000:duration=240:amplitude=0.2:seed=3" \
       -filter_complex "[0][1]amerge=inputs=2[a]" -map "[a]" -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 long24-96.flac
ffmpeg -f lavfi -i "anoisesrc=color=white:sample_rate=96000:duration=240:amplitude=0.5:seed=5" \
       -f lavfi -i "anoisesrc=color=white:sample_rate=96000:duration=240:amplitude=0.5:seed=6" \
       -filter_complex "[0][1]amerge=inputs=2[a]" -map "[a]" -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 dense24-96.flac
```
