# robogears Downloader for Mac: design brief

_21 Oct 2026 · Swift 0.1.31 · written before any design work · owner review pending._

**Sources:** `docs/electron-reference/` (Electron v0.1.30), `docs/PORT_PLAN.md`, the project CLAUDE.md history, the D4 behaviour cards ("D4 x.y" = their sections), and the HIG pages in the apple-design skill, cited by page.

**Assumed:** macOS 15+, Apple Silicon; same repo at 0.1.31; fresh start; no Chrome extension; every D4 recommended option, except that file names stay `<Title>.flac` until the owner confirms D4 2.6 and 2.7. Until then a same-title clash is reported on the row, never renamed.

## 1. Product and person

**Product.** A personal Mac app that turns TIDAL links, Spotify links, searches and tracklists into lossless files from the owner's TIDAL subscription, first gathering every track in a review queue where it is checked against his read-only music library and can be previewed as a waveform. Download All then saves each track as a tagged `<Title>.flac` with front-cover art into one flat folder.

**Person.** The owner: a DJ and collector who uses Rekordbox.
- His download folder is separate from his music library, which the app must never touch. The library is likely in Dropbox.
- He queues hundreds of tracks from playlists or Exportify CSVs, presses Download All, and walks away for hours.
- He is a power user who wants a quiet app that tells the truth.

## 2. Identity to keep

| Element | Native carry-over |
|---|---|
| Pure black canvas, stark white ink | The content canvas stays pure black in Dark. Window chrome stays system (custom chrome is on the owner's avoid list). Asset-catalog colours with Light, Dark and Increase Contrast variants (HIG: Color). |
| Colour only for status | Red: failed, not found, error. Amber: similar version in library. Green: done. Always with words or a symbol (HIG: Accessibility). |
| One accent | The ink (white in Dark, black in Light), for primary buttons, selection and progress, as today's white-filled buttons (see open question 4). |
| Vinyl-with-arrow mark | App icon and disk-image install window unchanged; the in-app glyph becomes a template image that inverts in Light. |
| Waveform rows | The signature element: 200 bars, played in full ink, unplayed at 22 %. Hover is light-only: nearby bars brighten toward about 60 %, nothing grows (D4 5.4). |
| Sounds and jokes | Same recipes, triggered honestly: bells only when nothing failed, a new quiet sound when something did (D4 2.8, 5.5). One "Play sound effects" switch covers all. The joke sound stays, at least in About. |
| Funny loading lines | The ten lines verbatim, handing over to a real count once known (D4 4.21). |
| Type | SF Pro at 13 pt, the macOS default (HIG: Typography); SF Mono only for the activity log and links. |

**Light mode** is the inverse: a white canvas, black ink, and the same small steps between surfaces, mirrored.

**Increase Contrast.** All text at least 4.5:1, small text aiming for 7:1 (HIG: Dark Mode); today's dim grey on black is about 3.0:1. Drop-zone outline, field focus, unplayed bars and badges get stronger.

**Reduce Motion.** Progress jumps instead of easing; loading lines swap without a fade; spinners and sheet transitions are the system's. Nothing ever pulses: today's endless update pulse goes.

**Reduce Transparency.** Every material, including the adding cover, becomes the opaque canvas. Never a hand-made blur.

## 3. Windows, sheets and panels

### Main window: add, review, download, see what happened

The window opens at about 980×740 and can shrink to 720×540.

| Region | Must show | Must never |
|---|---|---|
| Toolbar | Add field (link or search); Download All / Stop Downloads; update control only when one exists | Hold a Settings gear (HIG: Settings) |
| Add area | A hint saying what Return will do (D4 4.2); the drop zone with its own Exportify link (D4 4.19); the whole window accepts drops, lighting the zone (D4 4.8) | Search with an unusable link |
| Empty queue | "Not signed in to TIDAL" with Sign In…, or "Choose a download folder to start downloading.", or where downloads go | Show a sheet at launch |
| Queue | Rows; header with count, preview volume, Retry, Clear Queue, batch counter ("37 of 120", this batch only) | Lose focus or scroll position on a progress tick |
| Batch summary | In-window notice: "Done: 12 downloaded, 2 already in your folder" with Open Folder, or the stop cause and fix (D4 2.1, 2.8) | Say "finished" when tracks failed |
| Activity | Selectable record of adds, results with reasons, library and update events; 2,000 entries; scrolls only when already at the bottom | Be the only place a failure shows; show signed links, raw replies or the account's name |
| Adding cover | Full-window, as chosen in v0.1.23: spinner, then "Matching 34 / 100 tracks on TIDAL…", Cancel (Escape, ⌘.); one add at a time (D4 4.9, 4.18) | Discard finished matches on Cancel |

**Row, left to right:** play button · title, with the edition in quieter text and "E" for explicit (D4 4.15) · waveform filling the free width, still shown while downloading (D4 5.14) · artist and length · quality badge, then exactly one status · the row's action · Remove. A quiet second line shows the source wording when it differs from TIDAL's ("Spotify: Intro — Placeholder Artist", D4 4.14). The title gets width first; the waveform shrinks to nothing before the title is cut (v0.1.22).

| State | Row says | Colour | Action |
|---|---|---|---|
| Waiting | No badge, or "Waiting" inside a running batch | — | — |
| Downloading | "42%" with a thin progress line | ink | ✕ removes it from the batch |
| Done | "Done · 24-bit / 96 kHz", until the batch ends | green | — |
| Skipped | "Already in your download folder" | grey | Show in Finder |
| Failed | "Failed:" and a reason, kept after a restart | red | Retry |
| Not found | "Not on TIDAL" | red | Search… |
| Couldn't check | "Couldn't check: TIDAL was busy" | grey | Match Again |
| Left out | Dimmed, title struck through: "In your library" (note "Library: Blue Lantern") or "Different artist on TIDAL" | grey | **+ Add**, unchanged |
| Similar version | "Similar version in library", with both lengths if more than 10 s apart | amber | Leave Out (menu) |
| In download folder | "In your download folder"; stays included, skips instantly | grey | Show in Finder |
| Clash or damaged file | "Not downloaded: a different song is already saved as Intro.flac" / "…looks damaged" | red | Save As… / Replace |
| Quality | "Hi-Res" or "AAC" badge; after saving, "Saved as AAC (.m4a): TIDAL has no lossless version" | neutral | — |
| Pending or no preview | "Checking library…" / "Preview unavailable" | grey | Try Again |

### Settings (⌘,)

Per HIG: Settings: panes in a toolbar, a title naming the pane, dimmed minimize and zoom. Changes apply at once, as today, so there is no Done button.

- **Folders.** Download folder ("Every download goes here directly — no subfolders.") and library folder, each with Choose… and Show in Finder; the library also has Clear, a status ("1,240 files indexed", "Scanning 120 / 500…") and Refresh. Reset Folders…. A download folder inside the library is refused (D4 2.11).
- **TIDAL.** "Signed in to TIDAL" with the country; Sign In Again… and Sign Out, both unavailable during a batch; "Your TIDAL sign-in is no longer valid." when TIDAL stops accepting it.
- **Updates.** Version, Check Now (offline and GitHub's rate limit reported differently), automatic-check switch, What's New, "made with love by robogears :)".
- **New controls.** "Play sound effects" (on by default), "Notify When Downloads Finish" (off by default), Clear Preview Cache. Placement: open question 5.
- **Never:** switch a running batch to a new folder (it says the change applies from the next batch, D4 2.17), or show a token or account email.

### Sheets and small windows (one at a time; HIG: Sheets)

- **TIDAL sign-in.** "Sign in to TIDAL in your browser and click Allow.", the link, TIDAL's short code if sent, one status line ending "Signed in." (then it closes itself); Copy Link, Open in Browser, Cancel or Escape; failures say why, with Try Again (D4 1.3). Never a terminal log, never a sheet you can't leave.
- **Sign in to continue.** "Sign in to TIDAL to add 2 tracks from pasted text." The tracks are added after sign-in; downloads never start by themselves (D4 1.1).
- **Search results.** A refine field; rows with edition, explicit mark, Hi-Res and the queue's library marks; "In Queue" rows can't be ticked. Add Selected is the default and stays dim until something is ticked; double-click adds one. Empty: "No TIDAL results for “Blue Lantern”. Check the spelling or try fewer words." A pick-one mode replaces a "Not on TIDAL" row in place (D4 4.10). Never: a silent "Added 0", or a tick that bypasses the queue's + Add rule.
- **Updates.** A toolbar control, "Update to 0.1.32": one click downloads and relaunches, with progress inside; it fades in once (about 200 ms). What's New offers Install and Relaunch, Install on Quit and Skip This Version. During a batch it asks first, defaulting to Update When Downloads Finish (D4 5.9, 5.12).
- **Quit during a batch.** "Quit while 12 tracks are still downloading?" Closing the window keeps downloading, with Dock progress (D4 2.5, 2.12).
- **First launch only.** Move to Applications (D4 5.15), then a notice about the old app's files (D4 5.11).

## 4. Real facts

- **Queue size.** From 1 row to 1,000+. Exportify imports run to 500+ lines; a huge file asks first ("Import the first 2,000?"). TIDAL playlists load 100 at a time ("Loading 300 of 1,250 tracks…"); Spotify playlists stop at 100. A progress tick must never rebuild the list.
- **Titles.** From one character ("7") to names near the 255-byte limit, in any script, including right-to-left and symbol-only ("♡"). Artist lines join several names.
- **Durations.** Sometimes unknown, in which case nothing is shown. Usually 2–8 min. DJ mixes run 60 min or more; tracks over about 20 min aren't pre-loaded.
- **Waveform.** 200 bars, about 22 pt tall, cached on disk. Left button only: a press seeks, a drag skims while playing, a press on another row starts that track there, and seeking never pauses. Loudness is the slider position squared; the slider starts at 50 %.
- **Batches.** One at a time, tracks in sequence, often for hours. Files run about 30 MB (CD quality) to 165 MB (4-minute Hi-Res).
- **Progress granularity.** Whole percents per track, a batch count, and Dock progress. The library scan reports about every 25 files.
- **States to design for.** Signed out; sign-in no longer valid; offline mid-batch ("Waiting for an internet connection…", then it resumes); offline while adding ("No internet connection", Try Again); TIDAL busy (the wait shows in the batch bar); library unavailable ("Library not available, duplicate marks from 20 Oct"); download folder missing, in the Trash or unplugged; disk full; subscription inactive.
- **100-track cap** (D4 4.4): "Spotify only shares the first 100 tracks of a playlist. If Late Ferry is longer, export it with Exportify and drop the CSV here." with Open Exportify.
- **Errors say what happened and what to do.** For example: "The download folder “TIDAL” on Music SSD isn't available. Connect the drive or choose another folder."

## 5. Commands and shortcuts

Menus follow the HIG's standard order, and unavailable items are disabled rather than hidden (HIG: The menu bar). † marks a proposed custom shortcut, to check against HIG: Keyboards.

- **robogears Downloader:** About · Settings… ⌘, · Check for Updates… · Sign In to TIDAL… / Sign Out of TIDAL · Hide ⌘H · Quit ⌘Q (asks first during a batch).
- **File:** Import Tracklist… ⌘O · Open Download Folder · Close ⌘W (downloads keep going).
- **Edit:** Undo ⌘Z / Redo ⇧⌘Z, named for the action ("Undo Clear Queue") · Paste (with no field focused, it imports; D4 4.7) · Delete ⌫ (removes the selected rows) · Select All ⌘A · Clear Activity.
- **View:** Show/Hide Toolbar ⌥⌘T · Show/Hide Activity · Enter Full Screen.
- **Queue:**
  - Add Link or Search ⌘L† · Download All ⌘↩† · Stop Downloads ⌘. · Retry ⌘R† (shown as "Retry Selected" or "Retry All Failed (N)").
  - Play/Pause Preview (Space) · Stop Preview.
  - Include in Download / Leave Out of Download · Search TIDAL… · Match Again · Show in Finder · Show Library File in Finder.
  - Remove from Queue · Clear Queue.
- **Window:** Minimize ⌘M · Zoom · robogears Downloader (reopens the main window) · Bring All to Front.
- **Help:** robogears Downloader Help (the README) · What's New · Open Exportify.

**Right-click on rows** (acts on every selected row): Play Preview, Include or Leave Out, Retry / Search… / Match Again, Save As…, Replace, Show in Finder, Copy Title and Artist, Remove from Queue.

**Keyboard.** In the queue, ↑↓ select, ⇧ extends, ⌫ removes (undoable). **Space plays or pauses the selected row's preview only when the queue has focus**, never while typing. A focused waveform is a slider: ←→ seek 5 s, and VoiceOver reads "Preview position, 1:23 of 3:45". In sheets, Return confirms and Escape cancels. Full Keyboard Access reaches every control.

## 6. Copy rules

- Use plain words that say what happens.
- Title case for buttons, menus and window titles; sentence case for labels and messages.
- Use the "…" character, never "...". Use correct plurals and thousands separators.
- Write "TIDAL" in capitals and "robogears Downloader" with a lowercase r.
- Statuses use SF Symbols with words, never emoji. VoiceOver reads counts as "34 of 100".

**Kept verbatim:**
- The ten loading lines: Searching the seven seas for your music… · Digging through the record crates… · Asking TIDAL nicely… · Following the bass line… · Tracking down these bangers… · Bribing the algorithm… · Polishing the vinyl… · Listening for the drop… · Tuning the frequencies… · Whispering to the music gods….
- Also: "+ Add", "Hi-Res", "Download (N)", "Matching N / M tracks on TIDAL…", "Scanning N / M…", "Drop a playlist CSV or paste tracks", "For playlists over 100 tracks — export via Exportify and drop the CSV here", "Every download goes here directly — no subfolders.", and "made with love by robogears :)".

**Changed.** Items marked • are rewordings that need the owner's OK.

| Today | Swift |
|---|---|
| Add to queue, Download all, Clear all | Add to Queue, Download All, Clear Queue • |
| Cancel (queue header) | Stop Downloads •, matching the menu |
| already in library, not found | In your library, Not on TIDAL • |
| done, skipped, failed | Done with quality, "Already in your download folder", "Failed:" with a reason |
| Re-authenticate, Reset config | Sign In Again… •, Reset Folders… • |
| Batch finished, Exit code N | A summary that matches the result |
| Update now pill, log-row notice | "Update to 0.1.32"; the log row goes |
| Raw error text | A plain reason; raw text only in a private debug log, signed links removed |

## 7. What must never happen

- **Writing to the library folder:** no downloads, temporary files, previews or indexes there, and no download folder inside it.
- **Silent failure:** every failure shows on its row and in the summary, with a reason and a fix.
- **Lost queue rows:** unfinished rows go back to waiting, the queue is saved after every track, Remove and Clear Queue can be undone, and library rows leave only after a complete Download All, with a log line.
- **Downloads starting by themselves:** not at launch, after sign-in or after an update. Resuming after a dropped connection is not a new start.
- **Raw server text or signed links** anywhere: window, log, copied text, VoiceOver, notifications.
- **Files moved or deleted without a click.** Replace and the old-files tidy-up use the Trash.
- **Quitting or updating mid-batch without asking**, stacked sheets, endless motion, hover that moves or grows anything, or keys taken from a text field.

## 8. Open questions for the design lead

1. **Row height.** The owner's rule is 24–28 pt rows; today's rows have two lines. Default: 28 pt single-line rows that grow only when carrying a note.
2. **Activity.** A collapsible bottom panel or its own window? Default: SF Symbols instead of today's emoji.
3. **Brand glyph and joke sound.** Toolbar, empty state, or About only?
4. **Accent.** macOS uses an app's accent only when the person's accent is Multicolor (HIG: Color, App accent colors). Should primary buttons keep their ink regardless?
5. **New switches.** A General pane (changes the owner's three tabs; his OK needed) or the existing panes?
6. **Drop zone.** The large box always, or compact once rows exist?
7. **Owner calls.** Failed-row checkboxes (v0.1.11) versus native multi-select; the moving cursor line in the light-only waveform.
8. **Escape.** D4 2.4 lets Escape stop downloads unconfirmed; a stray keypress could end an hours-long batch. Recommend ⌘. and the button only.
