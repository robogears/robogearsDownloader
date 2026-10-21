# Decision 4: which behaviours to fix, and how

_Written 21–22 Oct 2026 for the Swift rewrite of robogears Downloader. Every item was drafted from the code, checked against it by a second agent, and edited for consistency by a third. You asked to "go in detail" on decision 4; this is that detail._

## How to answer

- **Fastest:** reply "all recommended", or "all recommended except 2.6 B, 3.8 C", using the item and option letters below.
- **Option A is always the recommendation.** Today's behaviour is the last option wherever keeping it is a real choice.
- **Items marked ★ touch one of your explicit rules or a feature you built on purpose**, so each says how. **Items marked ◐ depend on a live check** that needs your TIDAL sign-in once.
- **Two items bend your title-only file-name rule: 2.6 and 2.7.** Until you answer, the Swift app is being built on your literal rule (file name = title only), and same-title clashes are reported on the row instead of renamed.
- **23 items are plain fixes with no real alternative.** They're listed at the end of each area under "Fixed without a decision" so you know about them; no answer needed.

## Summary: 68 decisions

### 1. Sign-in, account and network

| Item | What you notice today | Recommended (A) | |
|---|---|---|---|
| 1.1 | Doing anything with TIDAL before signing in closes the app | Check sign-in locally; sheet names what's waiting; adds finish after sign-in. | ★ |
| 1.2 | Signing in again doesn't fix a broken sign-in, and there is no Sign Out | One stored sign-in, replaced on sign-in; add Sign Out; both locked during batches. | ★◐ |
| 1.3 | The sign-in window can't be cancelled and can wait forever | Native sheet with Cancel, time limit, one status line, plain failure messages. | ★◐ |
| 1.4 | A busy TIDAL turns songs into "not found" (retries and one shared pace) | Automatic retries, one shared pace, honest row reasons, Match Again on missed rows. | ★◐ |
| 1.5 | Where your TIDAL sign-in is kept on the Mac | Keychain once signed with your certificate; private 0600 file until then; no prompts. | ★◐ |
| 1.6 | TIDAL stops accepting your sign-in in the middle of a batch | Batch stops once with 2.1's in-window notice; Settings shows sign-in invalid. | ★◐ |
| 1.7 | Losing the internet in the middle of a batch | Downloads pause and resume; imports stop with Try Again; ask first on hotspots. | ◐ |

### 2. Downloads, files and batches

| Item | What you notice today | Recommended (A) | |
|---|---|---|---|
| 2.1 | Unfinished tracks vanish from the queue when a batch stops early | Unfinished rows wait (retried rows stay failed); five shared problems stop the batch. | ★ |
| 2.2 | A half-written or damaged file counts as downloaded forever | Download and tag in a temporary place, check length, then move in | ★◐ |
| 2.3 | Files from the old app are skipped without being checked | Quick check before skipping; damaged files get Show in Finder and Replace | ★◐ |
| 2.4 | Cancel doesn't stop the track that's downloading | Cancel or ⌘. stops at once; Escape never stops; rows return as 2.1. | ★ |
| 2.5 | Closing the window or quitting during downloads | Closing hides the window; Quit asks first; Update Now asks its own question. | ★ |
| 2.6 | Two different songs with the same title: the second is silently skipped | Title-only names unless songs clash; only untagged files fall back to B. | ★◐ |
| 2.7 | Versions (Radio Edit, Remaster) look identical in the title tag and file name | Version in the title tag; in file names only on a clash. | ★◐ |
| 2.8 | The success sound plays even when tracks failed | Ping only on full success; quiet sound for failures and early stops. | ★◐ |
| 2.9 | Failed tracks look untouched after a restart | Keep failed status and plain reason across restarts; never for cancelled rows | ★ |
| 2.10 | The lossy AAC fallback is easy to miss | Neutral AAC badge before download, say so after, Trash .m4a on click | ★◐ |
| 2.11 | You can pick a download folder inside your music library | Refuse a download folder inside the library, checked by folder identity | ★ |
| 2.12 | Long batches: the Mac can sleep, and nothing outside the window shows progress or the end | Stay awake, app-drawn Dock progress bar, opt-in notification when finished | ★◐ |
| 2.13 | Removing a row during a batch doesn't stop its download | ✕ removes the row from the running batch, stopping it if downloading |  |
| 2.14 | Some titles make hidden, unwritable or oddly named files | Keep today's naming; fix leading dots, long names, control characters; check old spelling | ★ |
| 2.15 | A file can be saved without its cover art or with the wrong album details | Retry cover and album lookups; save without art only when TIDAL has none | ★◐ |
| 2.16 | The queue doesn't show which songs are already in your download folder | Quiet download-folder badge, but not on an .m4a once lossless exists. | ★ |
| 2.17 | Changing the download folder during a batch | Running batch keeps its folder; Settings explains; Open Folder opens that folder |  |

### 3. Matching and the music library

| Item | What you notice today | Recommended (A) | |
|---|---|---|---|
| 3.1 | Songs with accents or non-Latin titles match the wrong song, or never match | Compare every alphabet, ignore accents, and never let two empty titles match | ★ |
| 3.2 | A song with the right title but the wrong artist is accepted, and you can't tell | Accept exact titles when artist or length agrees; flag the rest for review | ★◐ |
| 3.3 | A short artist name inside a longer one counts as the same artist | Compare whole artist names; one shared name confirms an exact match | ★◐ |
| 3.4 | An extended mix with the same plain title counts as the song you already have | Lengths over 10 seconds apart turn an exact match into similar | ★◐ |
| 3.5 | Your past downloads carry a recording code (ISRC) the library check never reads | Same ISRC counts as exact; otherwise title and artist rules decide | ★◐ |
| 3.6 | Greyed "already in library" rows disappear after any batch, even a one-row retry | After a complete Download All, clear only rows present at start; undoable. | ★ |
| 3.7 | Every launch re-reads the whole library before duplicates can be checked | Saved index in the app's Caches; re-read only new or changed files | ★◐ |
| 3.8 | How the library scan treats your Dropbox files, hidden copies and a missing drive | Read online-only Dropbox files' tags once, with your OK, and remember them | ★◐ |
| 3.9 | Queue rows keep an old library verdict after the library changes | Re-check automatically, keep your choices, never against an unreadable library | ★ |
| 3.10 | How the Swift app reads tags, so the FLAC, Ogg and Opus files you own are recognised | Apple's reader plus small own FLAC and Ogg readers; TagLib as fallback | ◐ |
| 3.11 | Versions (Radio Edit, Extended Mix, Remaster) are ignored when matching | Match on title plus version; 3-second rule only for bare-titled older files. | ★◐ |
| 3.12 | Library files are matched on the wrong part of their name | Smarter file-name parsing, keeping today's keys; name matches stay similar | ★ |
| 3.13 | Songs with very short titles are never checked against the library | Check short titles, but only as exact with the artist agreeing |  |
| 3.14 | + Add can't be undone, and a similar row can't be left out without deleting it | Leave Out/Include, Show in Finder, and Undo, including the end-of-batch clean-up. | ★ |

### 4. Adding tracks: links, search and imports

| Item | What you notice today | Recommended (A) | |
|---|---|---|---|
| 4.1 | Typing a number looks up a TIDAL track number instead of searching | Plain text always searches; TIDAL numbers only come in through links. |  |
| 4.2 | Links the app can't use are searched as song names, while the hint says "Detected a link" | Refuse unsupported links with a fix; hint matches Return; summaries name the source. | ★ |
| 4.3 | Some normal Spotify and TIDAL link forms aren't recognised | Accept every common link form; album+track links add just that track. | ★◐ |
| 4.4 | The 100-track warning says tracks were dropped even when none were | Honest wording with Open Exportify button; exact counts if Spotify's page has them. | ★◐ |
| 4.5 | CSV import can read the wrong columns | Exact known header names first; use ISRC and duration columns when present. | ★◐ |
| 4.6 | Pasted lines split at the first hyphen and are always read as Title - Artist | Spaced separators only; score every split in both orders, keep the best. | ★◐ |
| 4.7 | Pasting outside a text field starts an import, even with Settings open | Paste acts on main window only; links add, bare names go to search. | ★ |
| 4.8 | Any dropped file is read as a tracklist, and drops elsewhere aren't handled | Whole window accepts tracklists and links; other drops refused with a reason. | ★ |
| 4.9 | A long import can't be stopped | Cancel keeps finished lines; Escape and ⌘. cancel the import, never the batch. | ★ |
| 4.10 | A "not found" row can only be removed | Search… and Match Again on not-found rows; the pick replaces the row in place. | ★ |
| 4.11 | Search results don't show what you already have | Library and queue badges in search results; + Add rule unchanged. | ★ |
| 4.12 | Adding tracks during a download only half works | Adding works mid-batch; new rows wait for the next Download All. | ★ |
| 4.13 | A pasted or dropped list of links becomes a list of "not found" song names | Links inside a pasted or dropped list are added as links. |  |
| 4.14 | Spotify rows show Spotify's names, not the TIDAL track that will download | Rows show the TIDAL track to be saved; original name as second line. | ★ |
| 4.15 | Versions and explicit tracks look identical in search and the queue | Show edition and an explicit marker in search results and queue rows. | ★◐ |

### 5. Preview, sounds, updates and the switch-over

| Item | What you notice today | Recommended (A) | |
|---|---|---|---|
| 5.1 | Waveform pre-loading downloads every queued song again at every launch | Keep pre-loading, cached on disk; pauses during any batch, retries included. | ★ |
| 5.2 | Pressing play waits for the whole song to download | Lossless previews from a 1 GB disk cache, starting early where possible | ★◐ |
| 5.3 | Preview volume comes back wrong after a restart, and sound effects can't be turned off | Fix both bugs; effects follow Mac alert settings, with an on/off switch | ★◐ |
| 5.4 | The waveform swells under the pointer, against your hover rule | Light-only spotlight; you explicitly approve the moving cursor line | ★◐ |
| 5.5 | Which sounds, jokes and loading lines come along | Keep all sounds and jokes, make cues honest, drop unused clown horn | ★ |
| 5.6 | Updates are installed without being checked | Your github-updater recipe: checksum, identity and version check, rollback | ★◐ |
| 5.7 | Each update may make macOS ask for permissions again (signing identity) | Free self-signed certificate, long validity, offline backup, signed on your Mac | ★◐ |
| 5.8 | Windows copies of v0.1.30 will try to install a web page | Farewell Windows build with updates off, attached to every Swift release | ★◐ |
| 5.9 | Two update buttons that can trip over each other | One updater: toolbar control, menu, Settings, What's New with Install on Quit | ★ |
| 5.10 | Mac users on macOS 11–14 who click Update lose the app | Keep macOS 15+; warn in README, release notes and release title | ★ |
| 5.11 | Old files, including the plain-text sign-in, stay on disk after the switch | One notice with Show, Move to Trash and a separate Delete Old Sign-in | ★ |
| 5.12 | Update now restarts the app in the middle of a download batch | Ask first; Update When Downloads Finish is the default | ★ |
| 5.13 | The play/pause key and Control Center during previews | Previews appear in Now Playing; the play/pause key controls them | ★◐ |
| 5.14 | A row's waveform disappears while it downloads | Keep the waveform visible; show download progress beside it | ★ |
| 5.15 | Updates go to Applications while you keep opening an old copy | Offer Move to Applications at first launch; updater says where it installs |  |

## Summary: 23 fixes without a decision

| Item | Fix | In the Swift app |
|---|---|---|
| 1.8 | One keeper for the sign-in | One keeper owns the sign-in: shared renewals, renew-and-retry once on 401. |
| 1.9 | The built-in TIDAL client keys stay as they are | Same two key pairs and header values; pair label stored; secret used verbatim. |
| 1.10 | A lapsed TIDAL subscription looks like a broken app | One 'subscription isn't active' message if TIDAL's answer allows; else honest refusal reason. |
| 1.11 | Cancel stops requests already in flight | Cancel stops requests already under way; views close within a moment. |
| 2.18 | Every way of starting downloads behaves the same | Signed out shows the 1.1 sheet, not the honk; network renewal failures wait. |
| 2.19 | Download folder missing, moved, in the Trash or unplugged | Remembers the folder itself, checks before each track, never creates it silently |
| 2.20 | A full disk fails every remaining track | Streams to disk, checks space before each track, stops once when full |
| 2.21 | A TIDAL hiccup saves 16-bit instead of Hi-Res | Retry the Hi-Res request; step down only on a clear refusal, said on the row. |
| 2.22 | The batch counter counts tracks that aren't in the batch | Counts only this batch; waiting rows show a quiet Waiting label |
| 2.23 | A 30-second preview clip could be saved as the full track | Checks TIDAL sent the full track; fails the row if only a preview |
| 3.15 | Changing the library folder during a scan | One service owns the index; a folder change cancels the old scan |
| 3.16 | A second, simpler TIDAL search before "not found" | One simpler second search before 'not found', switched on after measuring |
| 4.16 | Imported rows get the Hi-Res badge | Imported rows carry the Hi-Res flag like every other row. |
| 4.17 | Encodings, delimiters and lists without a header | Reads common encodings, delimiters, line endings and header-less column lists. |
| 4.18 | One add at a time | One add at a time; each job has its own Cancel. |
| 4.19 | The Exportify link only opens the website | Exportify link is its own control and only opens the website. |
| 4.20 | Rows appear at once while the library scan finishes | Rows appear at once marked 'Checking library…'; Download holds unchecked rows. |
| 4.21 | Matching progress for Spotify and long TIDAL links | Funny line first, then 'Matching N / M' count for Spotify and TIDAL links. |
| 5.16 | Exactly one preview player | One preview at a time; stops when its row leaves or window closes |
| 5.17 | The switch-over checklist | Release meets v0.1.30's updater rules exactly; rehearsed by hand before publishing |
| 5.18 | Keyboard and VoiceOver for previews | Named VoiceOver labels, keyboard seeking; Space works only when the queue has focus |
| 5.19 | Plain preview errors with no private links | Plain messages that say what to do; signed links never shown or saved |
| 5.20 | The updater never quits without reopening something | The updater never quits without reopening something; Show Downloaded Update. |

---

## 1. Sign-in, account and network

This area covers signing in to TIDAL, what happens when that sign-in breaks, where it is kept on the Mac, and how the app behaves when TIDAL is busy or the internet drops. Every Swift install starts signed out (your fresh-start decision of 21 Oct), so everyone meets 1.1 and 1.3 on day one.

### 1.1 Doing anything with TIDAL before signing in closes the app

**Today.** Only Add and Download All check for a sign-in, and only by asking whether the sign-in file exists. Paste "Blue Lantern - Placeholder Artist" and "Paper Harbour - The Example Band" before signing in, and the log says "Parsed 2 tracks from pasted text. Matching against TIDAL…", then the window vanishes with no message. Dropping a CSV does the same, and with a saved queue the background waveform loader closes the app at every launch, before you can reach Settings. Retry while signed out deletes the retried rows (2.1). "✓ Signed in" in Settings only means the file exists, even when it is damaged.

**Choices**
- **A. Ask to sign in, then carry on (recommended).** Every TIDAL action (adding a list, a TIDAL or Spotify link, a search, a preview, Download All, Retry) first checks locally for a stored sign-in that isn't marked invalid, so being offline never reads as signed out. If you're signed out, a sheet (a dialog attached to the window) names what is waiting, such as "Sign in to TIDAL to add 2 tracks from pasted text.", with Sign In… and Cancel. After sign-in the add finishes by itself; Cancel discards it. Download All and Retry never start by themselves. While signed out, the empty queue shows a quiet "Not signed in to TIDAL" with Sign In… (no sheet at launch), and previews don't load. Cost: one held add, replaced by any newer one.
- **B. Ask to sign in, no carry-on.** Same check and sheet; afterwards you paste or drop again. A little friction on day one.
- **C. Grey out TIDAL actions while signed out.** The drop zone is disabled and pasting does nothing, which reads as broken.

**Why A.** It removes the crash and follows the Mac pattern: an action that needs an account asks for it, then continues. Naming what's waiting means a stray paste never reaches TIDAL unseen.

**Touches your rules.** Keeps the paste-anywhere import (v0.1.25) and the waveform pre-loader (v0.1.21): signed out, they wait instead of failing. The prompt in the empty queue replaces "👋 Welcome! Click the ⚙ icon to sign in to TIDAL."; the wording is for the design pass.

### 1.2 Signing in again doesn't fix a broken sign-in, and there is no Sign Out

**Today.** Each sign-in is added to the end of the sign-in file, but the app only ever uses the first entry. Say TIDAL stops accepting your old sign-in because you removed this Mac from your TIDAL devices: searches fail with "Search failed: 401 …" while Settings says "✓ Signed in". You click Re-authenticate and approve in the browser, the box says "Authorization successful! token.json saved.", and the next search fails the same way. Signing in with another TIDAL account doesn't switch accounts either. The only fix is deleting token.json by hand, and there is no Sign Out.

**Choices**
- **A. Replace on sign-in, add Sign Out (recommended).** The app keeps exactly one sign-in. Signing in again, with any account, replaces it once TIDAL approves; a cancelled or failed attempt leaves the old one alone. Settings shows "Signed in to TIDAL" with the account's country (and name or email if TIDAL gives one, kept out of the activity log), plus Sign In Again… and Sign Out, also in the menu bar. Sign Out removes your TIDAL sign-in from this Mac at once; your queue and folders stay, and previews stop until you sign in again. Both commands are unavailable while a batch downloads, so a batch never switches account midway. Cost: small.
- **B. Replace on sign-in, no Sign Out.** Fixes the bug, but leaving a shared Mac or starting clean means deleting the app's data by hand.

**Sub-choice.** Should "Re-authenticate" become the Mac-style "Sign In Again…", with the Settings tab still named "TIDAL" rather than "Account"? Recommended: yes to both.

**Why A.** Replacing the sign-in is the actual fix. With one stored sign-in, Sign Out is cheap, and every Mac app with an account has it.

**Touches your rules.** Keeps "Reset config keeps the TIDAL sign-in" and the Folders / TIDAL / Updates split you chose in v0.1.20.

**Needs a live check.** What TIDAL's sign-in answer says about the account (name or email), which decides what Settings can show.

### 1.3 The sign-in window can't be cancelled and can wait forever

**Today.** Sign in to TIDAL opens a box over the whole window with the link, a Copy button and a terminal-style log, and the browser opens by itself. The box has no Cancel, no close button and no Escape. If you click Deny in the browser or let the code expire, it shows "✗ Sign-in failed." under raw error text and stays; a stalled connection leaves it waiting forever. Closing the window and clicking the Dock icon escapes it, but leaves the sign-in running unseen, so a second attempt runs two at once.

**Choices**
- **A. Native sign-in sheet with Cancel and a time limit (recommended).** The sheet says "Sign in to TIDAL in your browser and click Allow.", shows the link and TIDAL's short code if it sends one, and has Copy Link, Open in Browser and Cancel (also Escape). The browser opens by itself only after the link is checked to be a secure tidal.com address; if it can't open: "Couldn't open your browser. Copy the link instead." One status line replaces the log; once it reads "Signed in." the sheet closes by itself within about a second. The time limit is the code's lifetime, or 10 minutes; network blips are retried until then, and TIDAL's "check less often" request is honoured. Failures say what to do, with Try Again: "The sign-in code expired. Click Try Again for a new one.", "You declined access in the browser.", "Can't reach TIDAL. Check your connection and try again.", "TIDAL didn't accept the sign-in request. Check for an app update." Cancel or closing the window stops the waiting, and only one sign-in runs at a time. Cost: small.
- **B. Same sheet, keep the terminal log.** Closer to today's look, but technical text where one plain line would do.

**Why A.** It removes the trap, matches how Mac apps handle a sign-in that happens in the browser, and loses nothing: the raw details still go to the activity log.

**Touches your rules.** Keeps the browser opening by itself (v0.1.3/v0.1.4), the link with Copy (v0.1.5) and the automatic close. The wording avoids naming this app, since TIDAL's approval page probably shows a different name.

**Needs a live check.** One sign-in run: TIDAL's exact fields and error names, whether the link starts with "https://", and what its approval page shows.

### 1.4 A busy TIDAL turns songs into "not found" (retries and one shared pace)

**Today.** Calls to TIDAL and to the Spotify page never retry; only some audio downloads, previews and cover art try again. You paste an 80-song Spotify playlist, the app searches 8 at a time, and around song 40 TIDAL answers "too many requests" (a 429) for a few seconds. Every song looked up then becomes a faded row with a red "not found" badge and the tooltip "Not on TIDAL", although "Blue Lantern" by Placeholder Artist is on TIDAL, and those rows can only be removed. At download time a busy TIDAL shows as "Could not get playback manifest at any quality.", the same text as a song unavailable in your country.

**Choices**
- **A. Retry automatically, share one pace, show the real reason, allow Match Again (recommended).**
  - On a 429 the app waits as long as TIDAL asks, showing the wait in the batch bar (up to about 60 s, else "TIDAL is busy"). Errors on TIDAL's side (a 5xx), timeouts and dropped connections retry after 1, 2, 4 and 8 s; a "not found" answer never does.
  - Data requests get about 60 s in total; audio gets an inactivity limit, so a large Hi-Res file on a slow line still finishes.
  - Matching, previews and downloads share one pace, with background waveform loading last (whether it pauses during a batch is 5.1); a preview you click still plays.
  - A failed lookup says "Couldn't check: TIDAL was busy" and looks different from the red "not found". Both get Match Again, also as "Match Again (N)" in the queue header.
  - Failed downloads give a short reason, such as "Not available in your country"; raw server text goes only to the activity log.
  - Cost: medium.
- **B. Retry and show reasons, no shared pace.** Simpler, but separate retries keep tripping the limit, and the waveform loader competes with downloads.
- **C. Reasons and Match Again only, no automatic retry.** A 5-second hiccup still leaves a pile of rows to click.

**Why A.** Most hiccups are short, so waiting fixes them unseen, and one shared pace stops the stampede that causes them. Match Again replaces "paste the link again and clean up".

**Touches your rules.** The red "not found" badge stays for genuinely missing songs, the library review is unchanged, and clicked previews during a batch (v0.1.20/v0.1.21) keep working. The "couldn't check" look must fit the one-accent rule. Item 4.10 adds Search… to the same rows.

**Needs a live check.** Whether a 429 says how long to wait, which answers mean "not available in your country", and how many searches at once TIDAL tolerates.

### 1.5 Where your TIDAL sign-in is kept on the Mac

**Today.** The sign-in is a plain text file, token.json, in the app's Application Support folder: any program running as you can read it, it sits in unencrypted backups, and a crash mid-write breaks it. The Keychain (macOS's encrypted password store) is safer, but lets an app read its item only while the app's signature stays the same. Today's app is ad-hoc signed (no developer identity, so every version looks new to macOS), and the v0.1.30 updater re-signs the first Swift version that way too. An ad-hoc app using the Keychain would show '"robogears Downloader" wants to use your confidential information stored in … in your keychain' after updates, probably asking for your Mac password even for Allow (needs a live check).

**Choices**
- **A. Keychain once the app carries your certificate, a private file until then (recommended).** Releases are signed with one free self-signed certificate you create (5.7). While the app is still ad-hoc signed (0.1.31, as the old updater installs it), the sign-in lives in a private file only your account can open; the first properly signed version moves it into the Keychain and deletes the file. No one sees a Keychain prompt, and if you stay ad hoc in 5.7, the app simply keeps the file. Cost: a one-time move step.
- **B. Keychain from the start, self-signed certificate.** No file stage, but everyone coming from v0.1.30, you included, sees the prompt once, at the update to 0.1.32.
- **C. Private file only.** Only your account can open it, and it is written safely. No prompts and no signing work, but today's exposure to other programs and backups stays.
- **D. Keychain, stay ad hoc.** The prompt returns after every update.

In A and B, a Keychain read that fails for another reason (a locked keychain, Deny clicked) never counts as signed out: "Can't read your TIDAL sign-in from the Keychain. Unlock your keychain, then click Try Again." A paid Developer ID ($99 a year) is your money call in 5.7, and works with A or B.

**Why A.** The Keychain is the native home for secrets, no one types a password for it, and A falls back to C whatever you choose in 5.7. B is the simpler build if one prompt is acceptable.

**Touches your rules.** Data safety: every write is atomic. You create and keep the certificate; agents never see it. The rule that the first Swift release must install through v0.1.30's updater is why A needs its file stage.

**Needs a live check.** On macOS 15, builds signed with the same free certificate share one Keychain item with no prompt, and the Swift updater keeps the signature.

### 1.6 TIDAL stops accepting your sign-in in the middle of a batch

**Today.** When TIDAL refuses to renew the sign-in, the app has no "sign-in expired" state: Settings keeps saying "✓ Signed in", and actions show raw text such as "Token refresh failed: 400 {…}". You queue "Blue Lantern", "Paper Harbour" and 40 more and click Download All just as the sign-in is due for renewal, and TIDAL refuses it: the batch dies before the first track, all 42 rows leave the queue (greyed library rows too), and the shorter queue is saved. Being offline or a TIDAL error at that moment does the same, since the renewal never retries. If the renewal is refused mid-batch, every remaining track fails one by one, and the success sound still plays with "✓ Batch finished."

**Choices**
- **A. Mark the sign-in invalid, stop cleanly, sign in, then Download All again (recommended).** Only an outright refusal from TIDAL marks the sign-in invalid. A renewal that fails for network reasons or a TIDAL error is retried (1.4), then handled as offline or busy (1.7), never as expired. The batch stops once, with 2.1's notice in the window ("Downloads stopped: your TIDAL sign-in is no longer valid…") and its Sign In… button, which opens the sign-in sheet (1.3). Settings shows "Your TIDAL sign-in is no longer valid" until you sign in again. A track whose audio is already streaming finishes; every other track goes back to waiting, and nothing leaves the queue (2.1). After signing in you click Download All, and finished files are skipped. Cost: small.
- **B. Pause, and continue by itself after sign-in.** Saves one click, but a paused batch must survive the sign-in sheet, window closes and quitting.
- **C. Report it on each track.** A 40-track batch gives 40 identical "Sign-in expired" failures. Like B, it still needs 2.1 so no rows are lost.

**Why A.** One message instead of forty, no lost rows, and a predictable restart; nothing starts by itself later.

**Touches your rules.** Protects the persistent queue you built (v0.1.17/v0.1.20): queued work is never silently lost.

**Needs a live check.** What TIDAL answers for a revoked sign-in, so a refusal can be told apart from TIDAL being down.

### 1.7 Losing the internet in the middle of a batch

**Today.** The app has no idea of "offline". The Wi-Fi drops for two minutes at track 12 of a 60-track batch: the current track fails (a single-file download leaves a partial "Blue Lantern.tmp.flac" in your download folder), then every remaining track fails in about a second each (needs a live check). The log ends "=== Batch complete: 11 downloaded, 0 skipped, 49 failed, 0 not found ===", the success sound plays, and 49 red "✗ failed" rows wait to be retried by hand. An import made while offline turns every line into "not found"; on a network that passes nothing (a hotel login page, a dead hotspot), it waits 30 s per line with no Cancel.

**Choices**
- **A. Downloads pause and resume; imports and links stop with Try Again (recommended).** When the Mac has no connection, or TIDAL's address answers with a web page instead of data (a hotel login page), the batch pauses: "Waiting for an internet connection…", the current track goes back to waiting, and nothing is marked failed. When the connection returns, the batch continues with a fresh stream link. Blips under about 15 s are absorbed by retries, and Cancel still works. The keep-awake from 2.12 is released while waiting, and quitting ends the pause instead of resuming at the next launch. Imports and link lookups stop with "No internet connection" and Try Again, keeping what you pasted or dropped. Cost: medium; it relies on 2.2.
- **B. Stop the batch and keep the rows.** You click Download All when you're back online. Consistent with 1.6, but a click after every Wi-Fi blip.
- **C. Fail each track with an honest reason.** "No internet connection" on each track, without the success sound (2.8). Still a pile of red rows after every outage.

**Sub-choice.** On Low Data Mode or a phone hotspot, should a paused batch ask "Resume downloads on this network?" before resuming? Recommended: ask, since a Hi-Res batch can use several GB.

**Why A.** Laptops lose Wi-Fi all the time, and waiting then continuing is what Music and App Store downloads do. Imports stop instead of pausing, because a blocked window for an unknown time is worse than a clear stop that keeps your input.

**Touches your rules.** Protects the persistent queue you built (v0.1.17/v0.1.20): an outage no longer turns rows red or loses them. The end-of-batch sounds follow 2.8, so an outage never ends with the success ping.

**Needs a live check.** Wi-Fi off mid-track and back on: the batch pauses, resumes with a fresh stream link, and leaves no partial file.

### Fixed without a decision

- **1.8 One keeper for the sign-in.** Today: the sign-in each request carries lasts only a short time and must be renewed (technically it is a "token", which is why the file is called token.json). The app renews it only when its own clock says it has expired, and TIDAL's "not authorised" answer (a 401) is ignored, so a 500-line CSV started minutes before expiry turns its tail into "not found"; several parts of the app also renew separately and overwrite each other. In the Swift app: one part of the app owns the sign-in and hands every request the current one; on a 401 it renews once and retries once (which also rescues a wrong Mac clock), and a second 401 is a real error, never "not found". Simultaneous renewals share one, anything new TIDAL sends with a renewal is saved, a renewal that fails for network reasons is reported as offline (1.7) rather than expired, and an assumed country shows in Settings as "Country: US (assumed)".
- **1.9 The built-in TIDAL client keys stay as they are.** Today: the app carries two pairs of TIDAL client keys (keys that identify an app, not your account), one to sign in and one to renew, and its requests imitate TIDAL's Android app; if TIDAL ever blocks those keys, sign-in breaks for everyone until new ones are copied in. In the Swift app: the same pairs stay inside the app (never in the Keychain, a file or the log), requests carry the same details as TIDAL's Android app, as today, the renewal secret is used exactly as written, and a label (not the secret) records which pair issued your sign-in, so a future key change can ask you to sign in again cleanly. The TIDAL live check confirms renewal still works from Swift; testing whether those Android request details are still needed means sending a few deliberately different requests from your own account.
- **1.10 A lapsed TIDAL subscription looks like a broken app.** Today: sign-in succeeds whether or not your plan is active, and then every download fails with the same "Could not get playback manifest at any quality." and nothing points to the plan. In the Swift app: if TIDAL's answer for an inactive plan is distinct (needs a live check), one message says "Your TIDAL subscription isn't active. Downloads need a TIDAL plan with lossless streaming." and the batch stops once (2.1), keeping every row; otherwise it shows as "TIDAL refused this stream" in 1.4's reason list.
- **1.11 Cancel stops requests already in flight.** Today: Cancel on the link and search overlay only takes effect between tracks, so on a stalled connection it sits on "Cancelling…" for 30 s or more, and a preview download can't be stopped at all. In the Swift app: Cancel stops the requests already under way, so the view closes within a moment; what a cancelled import keeps is decided in 4.9.

---

## 2. Downloads, files and batches

Everything from the moment you press Download All until the files sit in your download folder: how a batch starts, stops and ends, which name and tags each file gets, and what the queue tells you along the way. Being offline mid-batch (1.7) and a sign-in TIDAL no longer accepts (1.6) are in area 1; this area covers everything else that can stop or spoil a batch.

### 2.1 Unfinished tracks vanish from the queue when a batch stops early

**Today.** You import 300 tracks and press Download all just as your TIDAL sign-in is due for renewal, and the renewal fails (TIDAL no longer accepts it, or the Mac is offline at that moment). The batch dies before the first track: the log shows an unstyled "Fatal: Token refresh failed: …" (or a network error) and "=== Exit code 1 ===", and all 300 waiting rows are removed from the queue, together with any greyed "already in library" rows, and the shortened queue is saved. If the failure comes mid-batch instead, each remaining track turns red one by one, and pressing Retry All on them hits the same start-up failure and deletes every row it retried. Batch progress is never saved, so after a crash you get back the list from before the batch, including tracks that already downloaded.

**Choices**
- **A. Unfinished rows go back to waiting; the batch stops once on a shared problem (recommended).** Unfinished rows go back to waiting with no badge, included and ready to go, so Download All works as resume; rows that were being retried go back to their earlier failed state and reason instead. These problems stop the whole batch at once instead of failing track after track: the sign-in is no longer valid (1.6); the TIDAL subscription isn't active, or TIDAL sends only previews (1.10, 2.23); the download folder isn't available (2.19); the disk is full (2.20); or TIDAL returns errors for several tracks in a row while the Mac is online. No internet, or a login page such as a hotel's, pauses and resumes instead (1.7). One notice inside the window, not a pop-up alert, says what happened and how to fix it, for example "Downloads stopped: your TIDAL sign-in is no longer valid. 288 tracks are still in your queue.", with a Sign In… button that opens the sign-in sheet (1.3) when that's the cause. The queue is saved after every finished track, and a finished row leaves the saved copy at once, so a crash neither brings it back nor loses the rest. Cost: one clear list of batch-stopping problems; every other error stays per track.
- **B. The same single stop, but unfinished rows turn red with the reason.** Each shows "Failed: TIDAL sign-in no longer valid" with Retry, and Retry All acts as resume. Cost: a wall of 288 red rows for tracks that never started and never failed.
- **C. Like A, but a missing drive or a TIDAL outage pauses and resumes by itself,** as offline does in 1.7. A sign-in problem can never resume by itself. Cost: more paused states to test, and downloads can restart when you don't expect them.

**Why A.** Nothing you queued is lost, nothing that never failed is shown as failed, and saving after each track keeps the queue accurate through a crash.

**Touches your rules.** Strengthens the persistent queue you built in v0.1.17 and v0.1.20, and keeps the clean-up of downloaded rows at the end of a batch. Showing unfinished rows as waiting instead of failed reverses part of v0.1.11; the same question comes up for Cancel in 2.4, and the two should be answered the same way. What happens to greyed library rows after a batch is 3.6.

### 2.2 A half-written or damaged file counts as downloaded forever

**Today.** FFmpeg (the audio tool that adds the tags and cover art) writes straight into "Blue Lantern.flac" in your download folder. If that write is cut short by a full disk, a power cut, or a crash or force quit, a cut-off "Blue Lantern.flac" can stay behind (needs a live check). The next time you queue Blue Lantern, the app sees the name, logs "already in downloads folder" and the row disappears as if done; you find out when the song stops halfway in Rekordbox. The check after saving only prints a warning, probably misses a few damaged frames, and never runs on .m4a files. Raw downloads also sit in the download folder as "Blue Lantern.tmp.flac" or "Blue Lantern.tmp.m4a" and are left there when a download breaks part-way or tagging fails ("Raw file kept at…").

**Choices**
- **A. Save somewhere temporary, check, then move into place (recommended).** Each track is downloaded and tagged in macOS's hidden temporary folder on the same disk, so nothing half-done ever appears in your download folder. Two checks follow: the file must play to the end and match the length it records about itself (FLAC and .m4a both do), and then be within 2 seconds or 1%, whichever is larger, of the length TIDAL lists. Only then is it moved in as "Blue Lantern.flac", in one step and never on top of an existing file (an existing "Intro.flac" also blocks "INTRO.flac"; see 2.6). A failed check turns the row red with both lengths: "Failed: the file is 3:12 but TIDAL lists 4:05. Retry to download it again." The app keeps a list of the temporary files it made and deletes them after a failure or cancel, and any leftovers at the next launch. Old "….tmp.flac" files from the Electron app are left alone and never count as downloads. Cost: about a second of checking per track; the deliberate "Raw file kept at…" behaviour goes away.
- **B. The same, but keep the raw download when tagging fails.** The row offers Show Raw File. Cost: unusable files pile up, and one more row state to design.
- **C. Keep writing in place (today).** Cost: broken files keep blocking re-downloads silently, and stopping (2.4) or quitting (2.5) mid-track becomes unsafe.

**Why A.** Your download folder only ever holds complete, checked files, and a check that can fail finally means something. Checking the file against itself first means a track whose TIDAL length is slightly off doesn't fail on every Retry. 2.4 and 2.5 rely on this.

**Touches your rules.** Rule 2 (flat output) holds: temporary files never go into a subfolder of the download folder. It drops the deliberate "raw file kept when tagging fails" behaviour; B keeps it.

**Needs a live check.** Whether the per-disk temporary folder works on your actual download drive (external, exFAT or a network share); if not, the fallback is a hidden ".Blue Lantern.flac.part" in the download folder, which never counts as a download. Also how long the full check takes on a 24-bit/192 kHz file.

### 2.3 Files from the old app are skipped without being checked

**Today.** Your download folder already holds hundreds of files the Electron app wrote, and you decided on 21 Oct that they still count for skip-if-exists (a file already named "<Title>.flac" or "<Title>.m4a" means the song is skipped). When you queue "Blue Lantern" again, the app skips it because "Blue Lantern.flac" exists, without ever opening the file. If that old file was cut short (see 2.2), it stays broken and blocks a fresh download for good.

**Choices**
- **A. A quick check of files about to be skipped (recommended).** Before skipping, the app reads the start and the last few seconds of the existing file to confirm it is a real FLAC or M4A that ends where it should and is about as long as TIDAL says. It judges the file's structure, not its tags, so files you put there by hand are judged fairly, and it checks whichever file causes the skip, including an old-spelling match (2.14) or a renamed copy (2.6). Healthy: skipped as today, and the row says "Already in your download folder". Damaged: the file stays exactly where it is, and the row says "Blue Lantern.flac in your download folder looks damaged" with Show in Finder and Replace. Replace moves the old file to the Trash and downloads a fresh copy. In a folder with no Trash (some network shares), Replace asks first: "This folder has no Trash. Delete "Blue Lantern.flac" permanently and download it again?" Nothing is ever deleted silently. Cost: close to instant per file; it catches cut-off and empty files, the likely failure, but misses damage in the middle of a file.
- **B. A full check of files about to be skipped.** The app silently plays through the whole existing file before deciding. Cost: about a second per file, so re-queueing 450 already-downloaded tracks could spend several minutes checking.
- **C. Trust by name (today).** Cost: a broken old file blocks that song until you delete it in Finder.

**Why A.** A cut-off write leaves the file short, which the quick check catches at almost no cost even on big imports. Replace keeps the decision with you, and the Trash means nothing is lost by mistake.

**Touches your rules.** Keeps your 21 Oct decision that old files count for skip-if-exists (2.10 narrows it for old .m4a files): a file that looks damaged is replaced only when you click Replace.

**Needs a live check.** Whether the quick check can be done without FFmpeg for FLAC and M4A, and how fast it is. Optionally, a read-only look at your download folder to see whether any cut-off files exist today.

### 2.4 Cancel doesn't stop the track that's downloading

**Today.** In a 40-track batch, "Copper Sky" by Placeholder Artist is at 60% when you click Cancel. The cancel chime plays, the button says "Cancelling…", and every unfinished row turns red "✗ failed" with Retry. But only the batch was stopped: Copper Sky keeps downloading in the background, saves "Copper Sky.flac" anyway, and the log ends with "=== Exit code null ===" instead of a summary; the button probably stays on "Cancelling…" until then (needs a live check). Press that row's Retry and it reports skipped, because the file is now there, and tracks that never started also show failed although nothing went wrong.

**Choices**
- **A. Stop now; unfinished rows go back to waiting (recommended).** Cancel stops the current track at once, download and tagging, and deletes its temporary file. This needs 2.2's temporary-file saving; with in-place writing, stopping during tagging could leave a cut-off file that counts as downloaded. Unfinished rows go back as in 2.1 (waiting, or their earlier failed state if they were being retried), never newly red, and Download All picks up where you left off. Tracks already saved stay done. The cancel chime stays, and the button is back to Download All within a second. There is no confirmation, because the Cancel button and ⌘. are deliberate, while ⌘Q and Update Now are easy to press by accident and also close the app (2.5, 5.12). Stop Downloads is also in the menu bar with ⌘. (Command-period, the Mac's standard "stop" shortcut). Escape never stops downloads, because it also leaves the search field and closes search results. Cost: the interrupted track starts from zero next time, and cancelled rows lose their Retry buttons.
- **B. Stop now, but keep v0.1.11's Retry buttons.** The same immediate stop, but unfinished rows show a red "Cancelled" with Retry, and Retry All resumes them. Cost: up to 39 rows that never failed look failed after every Cancel.
- **C. A, plus Stop After Current Track as a pause.** A second menu command lets Copper Sky finish and save, then pauses the batch; Download All continues it. Cost: one more command to design, place and test.

**Why A.** It does what the word says: what's on screen matches what's on disk, and no row is marked failed when nothing failed.

**Touches your rules.** Keeps the Cancel button and the descending cancel chime (v0.1.11). A reverses something you built on purpose in v0.1.11, when cancelled and unfinished rows became failed "so they get retry buttons"; B keeps that. Answer this and 2.1 the same way.

### 2.5 Closing the window or quitting during downloads

**Today.** Closing the window mid-batch (the red button or ⌘W) keeps the app running without a window and stops the batch, but the track in progress carries on unseen and saves its file. Clicking the Dock icon opens a fresh window showing the queue from before the batch, including tracks that have since downloaded; pressing Download all there may be silently refused and stick on "Downloading…", or the old track's end report may delete the rows you just started (needs a live check). ⌘Q, Quit and Update now stop nothing and save nothing, so a queue edit from the last moment is lost. What the background download does once the app has gone is unknown: it may stop and leave a partial "Blue Lantern.tmp.flac", or quietly finish the rest of the batch (needs a live check).

**Choices**
- **A. Closing the window keeps downloading; Quit asks first (recommended).** Closing the window only hides it. The batch keeps going, the Dock icon shows progress (2.12), and clicking the Dock icon or choosing the window in the Window menu brings it back with live progress. Pressing ⌘Q, choosing Quit, or logging out during a batch asks "Quit while 12 tracks are still downloading?" with "The track in progress is discarded. The others stay in your queue for next time." and the buttons Cancel and Quit. Quitting stops cleanly, deletes temporary files and saves the queue before the app closes. Update Now asks its own question, with an option to wait for the batch (5.12). Cost: the app keeps running after its window closes, which some people don't expect; the Dock dot and progress bar make it visible.
- **B. Closing the window quits, asking first during downloads.** This works like System Settings. Cost: you can't put the window away and keep downloading; you can only minimize it.
- **C. Quit without asking, but stop safely.** ⌘Q stops cleanly and saves the queue, and unfinished rows wait for next time. Cost: an accidental ⌘Q costs the track in progress and a second press of Download All.

**Why A.** Long batches are this app's main job, and this is how download apps on the Mac behave. The question appears only when something would actually be interrupted, and quitting never leaves half-files or a stale queue.

**Touches your rules.** The one-click Update now you built in v0.1.25 gets a question only while downloads run (see 5.12).

### 2.6 Two different songs with the same title: the second is silently skipped

**Today.** Your queue has "Intro" by Placeholder Artist and, later, "Intro" by Second Example. The first saves as "Intro.flac". For the second, the app sees "Intro.flac" exists, logs "⏭ Intro.flac already in downloads folder — skipping" and removes the row at the end of the batch, so you never get the second Intro and nothing says it was a different song. The same happens with "Intro" and "INTRO" (Mac disks ignore upper and lower case by default) and with titles that become identical once unsafe characters are replaced ("Night/Day" and "Night:Day" both become "Night_Day.flac").

**Choices**
- **A. Title only, unless it would hide a different song (recommended; you to confirm, because it bends your title-only rule).** The app opens the existing "Intro.flac" and reads the tags it wrote: first the ISRC (the industry code for one specific recording), otherwise title and artist. Same recording: skipped, and the row says "Already in your download folder". Different song: saved under the first free name in a fixed order, adding TIDAL's version text, then the artist, then the album, for example "Intro (Second Example).flac". The row and the summary say "Saved as Intro (Second Example).flac — another song is already named Intro". Each existing candidate name is checked by its tags before a free one is chosen, so re-queueing the second Intro later finds its file and skips it. If an existing file's title and artist can't be read (a file you added by hand without tags, for example), that row behaves as in B. Every other file stays "<Title>.flac", and 2.16 shows the clash in the queue before you press Download All. Cost: a narrow exception to title-only names.
- **B. Title only, always; tell me and let me choose.** This is the literal reading of rule 3 and the plan's earlier default. The second Intro isn't downloaded, but its row stays: "Not downloaded: a different song is already saved as Intro.flac" (or "Not downloaded: Intro.flac already exists and can't be identified"), with a Save as… button offering "Intro (Second Example).flac". Cost: you act on every clash, and a 500-track import may have several.
- **C. Always "<Title> - <Artist>.flac".** Cost: breaks rule 3 for every file, and every song already downloaded would download again unless the old names are also checked.

**Why A.** You get every song you asked for, names stay title-only in the normal case, and big imports need no babysitting. The ISRC in every FLAC this app has saved makes the same-song test reliable; its .m4a files probably have none, so title and artist decide for those.

**Touches your rules.** Rule 3 (the file name is the title only, which you asked for). A keeps it for every file except the second of two different songs that would share a name; B keeps it strictly; C breaks it.

**Needs a live check.** The one in 3.5: which tag the old app used for the ISRC, so its files can be compared.

### 2.7 Versions (Radio Edit, Remaster) look identical in the title tag and file name

**Today.** TIDAL appears to keep a track's version, text such as "Radio Edit", "2011 Remaster" or "Extended Mix", in a field separate from the title (the live check is listed in 3.11), and the app never reads it; this document calls it the "version" throughout. Queue the album track "Blue Lantern" and its Radio Edit, and both would be saved as "Blue Lantern.flac": the second is skipped (2.6), and the title tag says only "Blue Lantern", so Rekordbox can't tell the edit from the album track. How versions show in the queue and in search is 4.15; how they affect matching and the library check is 3.11.

**Choices**
- **A. Version in the title tag; in the file name only on a clash (recommended).** The title tag reads "Blue Lantern (Radio Edit)", never doubled when the title already contains it. The file stays "Blue Lantern.flac" unless another version already holds that name; then 2.6 adds the version: "Blue Lantern (Radio Edit).flac". Almost every file stays "<Title>.flac". Cost: the file name and the title tag can differ.
- **B. Version in the title tag and every file name.** Title tag and file name both read "Blue Lantern (Radio Edit)". Cost: electronic releases on TIDAL may label nearly every track "Original Mix" or "Extended Mix", so this renames most new files ("Blue Lantern (Original Mix).flac"), a big visible change to your DJ library. Files you already downloaded as "Blue Lantern.flac" would download again under the new name, unless B also checks the ISRC of the file with the bare title, which it would have to add.
- **C. Version in the title tag only.** File names never carry it; when two versions clash, 2.6 names the second by its artist, then its album. Cost: that second file's name doesn't say which version it is, for example "Blue Lantern (Placeholder Artist).flac".
- **D. Title only (today).** Cost: versions clash, and Rekordbox can't tell them apart.

**Why A.** It fixes the DJ-software problem, while nearly every file keeps the title-only name you asked for.

**Touches your rules.** Rule 3: A changes a file name only to avoid a clash (through 2.6); B puts the version into most electronic-release names; C never puts it in a name. Under A, B and C, title tags for versioned tracks differ from what the old app wrote.

### 2.8 The success sound plays even when tracks failed

**Today.** You download 15 tracks while the internet is down. Every one fails, yet you hear the bright three-bell success ping and see "✓ Batch finished." with Open folder. The real result is only in a plain log line: "=== Batch complete: 0 downloaded, 0 skipped, 15 failed, 0 not found ===".

**Choices**
- **A. An ending that matches the result (recommended).** Everything worked: the ping as today, plus "Done: 12 downloaded, 2 already in your folder" with Open Folder. Something failed: no ping, a quieter, lower two-note sound (new, for you to approve by ear), and "12 downloaded, 2 already in your folder, 1 failed", with the failed rows keeping Retry. Nothing downloaded: the quiet sound and "Nothing downloaded: 15 failed", plus the most common reason. A batch that stops early (2.1) plays the quiet sound beside its notice. The summary also counts what other items add: saved as AAC (2.10), saved under another name (2.6), saved without cover art or with limited tags (2.15), and saved below the Hi-Res quality the row showed (2.21). The text always carries the result and is read out by VoiceOver (the Mac's built-in screen reader), because a sound alone isn't accessible. A cancelled batch plays only the cancel chime. Cost: one new sound to design.
- **B. The existing warning honk when something failed.** Same summaries; a batch with failures plays the low "wronnng" honk. Cost: the honk means "that action was refused" today, so it would mean two things.
- **C. Ping only when everything worked; otherwise silence.** Cost: a failed batch ends silently, which is easy to miss while you're in another app (2.12 helps).
- **D. Keep the ping always; fix only the text.** Cost: the sound keeps saying success when it isn't.

**Why A.** You can tell success from trouble by ear, which is what the sounds are for, and the text keeps your downloaded / skipped / failed / not-found breakdown and Open Folder.

**Touches your rules.** Keeps the success ping (v0.1.21), the batch summary breakdown (v0.1.0) and the Open folder notice, and adds one sound. The full list of sounds is in 5.5.

**Needs a live check.** The new sound, by ear.

### 2.9 Failed tracks look untouched after a restart

**Today.** "Copper Sky" fails because TIDAL timed out. The row shows a red "✗ failed" with Retry, but the reason appears only in the activity log, never on the row. Quit and reopen the app, and the row comes back plain, with no badge and no Retry, as if it had never been tried; the reason is gone. This is by design: download status is removed from the saved queue on purpose, so each session starts clean.

**Choices**
- **A. Keep failed status and the reason across restarts (recommended).** The row says what went wrong in plain words, for example "Failed: TIDAL didn't respond in time", with Retry, and still does after a restart. It clears when a retry succeeds or you remove the row. Only real failures are kept: rows stopped by Cancel (2.4) and rows left waiting by a stopped batch (2.1) are never saved as failed. Cost: reverses your "fresh each session" choice.
- **B. Status clears at restart, but the reason stays in the row's tooltip.** Today's clean start, with the reason still there when you hover. Cost: the row no longer looks failed, so you have to hover over each one to find out.
- **C. Today.** Status and reason vanish at a restart. Cost: the only record of what went wrong is lost.

**Why A.** The reason tells you whether Retry will help, and losing it at a restart helps nobody.

**Touches your rules.** Reverses a deliberate choice: download status was stripped from the saved queue on purpose. Strengthens the persistent queue, and keeps the Retry buttons (v0.1.10) and the checkbox multi-select (v0.1.11).

### 2.10 The lossy AAC fallback is easy to miss

**Today.** TIDAL has no lossless version of "Paper Harbour" by Placeholder Artist. Following the quality rule, the app saves "Paper Harbour.m4a" (320 kbps AAC, a lossy format that throws away some detail), and the only sign is the log line "ℹ No FLAC master on TIDAL — falling back to .m4a". The row says "✓ done" and disappears, and nothing in the queue warned you beforehand. If TIDAL later adds a lossless master, the old "Paper Harbour.m4a" makes the app skip the FLAC forever.

**Choices**
- **A. Mark it before and after (recommended).** In the queue, a quiet "AAC" badge, styled like the Hi-Res badge, appears when TIDAL's track details show no lossless version, on rows from every source, imports included (4.16), so you can remove the row before downloading. After saving, the row and the summary say "Saved as AAC (.m4a): TIDAL has no lossless version", and the row's saved-quality line (2.21) reads "AAC". An existing .m4a no longer blocks a lossless copy TIDAL adds later: the FLAC is saved next to it, and the row says so and offers Move "Paper Harbour.m4a" to Trash, on your click only, never automatically. Cost: the badge before downloading is only as reliable as TIDAL's track details.
- **B. Mark it after only.** Only the row and the summary say it's AAC. Cost: you find out after downloading.
- **C. Log line only (today).** Cost: lossy files go unnoticed.

**Why A.** The quality rule allows AAC only when nothing better exists, and you should know when that happened; seeing it in the queue lets you decide while reviewing.

**Touches your rules.** The quality rule (Hi-Res, then lossless, then .m4a only when there's no lossless master) is unchanged. Narrows your 21 Oct skip-if-exists decision: an old .m4a no longer blocks a lossless copy. The badge is neutral, because amber already means "similar version in library". Until you move the .m4a to the Trash, both copies sit in the flat folder and DJ software will import both.

**Needs a live check.** Whether TIDAL's track details reliably mark AAC-only tracks before download, and whether TIDAL answers a Hi-Res request for such a track with AAC or with an error.

### 2.11 You can pick a download folder inside your music library

**Today.** Settings lets you choose "Music Library/New", a folder inside your library folder, or the library folder itself, as the download folder, and nothing warns you. Every download, temporary file and half-written file then lands in the library the app promises never to touch, and a half-written "Blue Lantern.flac" there would be picked up by the next library scan and mark Blue Lantern as already in your library. The folder picker also always opens at the download folder, even when you're choosing the library.

**Choices**
- **A. Refuse it (recommended).** If the download folder is the library folder or inside it, Settings says "This folder is inside your music library. The app never writes to your library, so choose a folder outside it." with Choose Another Folder…. The same applies when you pick a library folder that contains the download folder. The app asks macOS whether one folder is inside the other instead of comparing folder paths as text, so links, alternative paths and upper or lower case can't slip past. The check runs again whenever either folder changes and when a batch starts, since folders can be moved in Finder. A library folder inside the download folder is fine, because downloads land flat at its top level. Each picker opens at its own current folder. Cost: downloads can never land straight in the library.
- **B. Warn, then allow if you confirm.** "Downloads will go into your music library." with Cancel and Use This Folder. Cost: bends the read-only rule with your consent, and the next scan marks those downloads as already in the library.
- **C. Nothing (today).** Cost: the library can be written to by mistake.

**Why A.** Your rule is that the library is strictly read-only, and refusing is the only option that guarantees it.

**Touches your rules.** "Never write to the library folder": A enforces it; B lets you override it in Settings.

### 2.12 Long batches: the Mac can sleep, and nothing outside the window shows progress or the end

**Today.** You start 300 tracks and walk away. Nothing stops the Mac from going to sleep when idle; downloads then stall and tracks can time out and fail (how often needs a live check). There's no progress on the Dock icon and no notification when the batch ends; the only signals are sounds and a log row inside the window. If the window is behind other apps, minimized or closed, nothing tells you the batch is done, and once 2.8 drops the ping after failures, a failed batch would end in silence.

**Choices**
- **A. Stay awake, Dock progress, and a notification you can turn on (recommended).** During a batch the Mac doesn't go to sleep when idle (the display still can, and closing a MacBook lid still sleeps it). This ends when the batch ends, stops, is cancelled or is quit, and while a batch waits for the internet (1.7), so a laptop isn't kept awake on battery. The Dock icon shows a thin progress bar that the app draws itself (macOS has none built in), so it must be checked in Light and Dark. A Settings switch, Notify When Downloads Finish, is off by default; turning it on brings up macOS's permission question. When it's on and a batch ends while the window isn't in front, one notification says "Downloaded 47 tracks. 2 failed." with Show in Finder; clicking it brings the window forward, and Focus modes are respected. No number badge on the Dock icon: Apple's guidance keeps badges for things that need attention, such as unread items, and asks for them to be used sparingly. Cost: the Dock bar is custom drawing.
- **B. The same, with notifications on by default.** Cost: macOS asks for permission when the first batch starts, at a moment you didn't ask for one.
- **C. A, plus a Dock badge with the failed count until you look.** Cost: a badge that stays until you look, where Apple's guidance asks for badges to be used sparingly.
- **D. Stay awake and Dock progress only.** Cost: the end of a batch is easy to miss when you're elsewhere.

**Why A.** Batches finish reliably and you can see progress from anywhere, while the app stays quiet unless you ask for more.

**Touches your rules.** Your design rule (quiet and native): nothing new speaks up unless you turn it on, and the sounds stay.

**Needs a live check.** Whether macOS keeps the notification permission for an app that is re-signed on every update (see 5.7), and whether the notifications arrive.

### 2.13 Removing a row during a batch doesn't stop its download

**Today.** Mid-batch you spot "Wrong Song" by Placeholder Artist in the queue and click its ✕. The row disappears, but the batch still downloads it a few minutes later; only the activity log shows it ("[12/40] Wrong Song — Placeholder Artist", then "✓ Saved: Wrong Song.flac"). Clicking ✕ on the row that is downloading right now doesn't stop it either.

**Choices**
- **A. Removing a row takes it out of the batch (recommended).** ✕ on a waiting row removes it, and it won't download. ✕ on the row that is downloading stops that track, deletes its temporary file (2.2), and the batch moves on to the next. The counter (2.22) shrinks to match. Cost: none notable.
- **B. Lock rows that are in the batch.** ✕ is disabled on rows in the running batch until it ends. Cost: to drop one track you have to cancel the whole batch.

**Why A.** ✕ should do what it shows: if a row is gone, its file shouldn't appear later.

**Touches your rules.** None.

### 2.14 Some titles make hidden, unwritable or oddly named files

**Today.** File names are TIDAL's title with \ / : * ? " < > | replaced by "_" and runs of spaces collapsed to one. A title starting with a dot ("...Ready") makes a hidden file Finder doesn't show, and a title of only spaces makes a hidden ".flac". A very long title (a long classical name, or a Japanese title at three bytes per character) breaks macOS's 255-byte limit on file names, so the save fails, sometimes after the whole track has downloaded. Zero-width spaces and invisible control codes stay in the name.

**Choices**
- **A. Fix the edge cases, keep everything else identical (recommended).** The character replacements stay exactly as today, so normal names match the old app's files. In addition: leading dots are removed ("...Ready" becomes "Ready.flac"); empty or spaces-only titles become "unknown.flac", as empty titles already do; invisible control characters are removed; and accented letters are stored in their standard single-character form (é as one character, not "e" plus a separate accent). Names that are too long are shortened at a whole character, leaving room for the extension and the temporary-file suffix, so the temporary file never fails where the final name would fit. Two long titles that shorten to the same name count as a clash and go through 2.6. When checking whether a song is already downloaded, the app also looks for the old app's spelling, so "...Ready.flac" is still found and not downloaded twice. Cost: a handful of rare files get slightly different names from the old app's.
- **B. An exact copy of today's naming.** Cost: rare files stay hidden or fail to save.

**Why A.** No downloaded file should be invisible or fail because of its name, and the old-spelling check means no duplicates.

**Touches your rules.** Rule 3 (title only): names remain the title; only unusable edge cases change.

### 2.15 A file can be saved without its cover art or with the wrong album details

**Today.** TIDAL's image server hiccups twice while "Blue Lantern.flac" is being saved: the file is saved without artwork, the row says "✓ done", and the log is silent. You notice later as a blank square in Rekordbox, and skip-if-exists keeps that copy for good. The album lookup that supplies the year, album artist and copyright fails just as silently on any error reply: a 1985 album added to TIDAL in 2014 is tagged 2014, and a compilation's album artist becomes the first track artist, so its tracks no longer group as "Various Artists" in Rekordbox or Music. When an album truly has no cover, the result looks the same and nothing says so.

**Choices**
- **A. Retry, and fail only when a temporary problem outlasts the retries (recommended).** Cover and album lookups are retried like the audio, waiting as long as TIDAL asks. If the large cover isn't there, smaller sizes are tried. If TIDAL definitely has no cover (none listed, or "not found" at every size), the file is saved and the row says "Saved without cover art: TIDAL has none for this album"; a genuinely missing album is saved with the track's own details and "Saved with limited tags". Only when timeouts, server errors or "too many requests" answers outlast the retries does the track fail: "Failed: TIDAL didn't send the cover art. Retry to try again." (or "Failed: TIDAL didn't return the album details. Retry to try again."). Cost: in that rare case, Retry downloads the audio again.
- **B. Retry, then save anyway and say so.** The same retries, but the file is saved with "Saved without cover art" or "Saved with limited tags" on the row and in the summary. Cost: fixing it later means deleting the file in Finder and downloading again, because skip-if-exists keeps the incomplete copy.
- **C. Silent (today).** Cost: missing artwork and wrong years go unnoticed.

**Why A.** Every saved file has its cover and correct album details whenever TIDAL has them, and the existing Retry fixes the rare failure. Cover art matters for your DJ software, which is why you fixed its picture type in v0.1.17.

**Touches your rules.** Rule 6 (cover art held in memory, written as the front cover, never a temporary .cover.jpg) is unchanged and now holds for every saved file.

**Needs a live check.** Which smaller cover sizes TIDAL serves, and whether the large size can be missing when an album lists a cover.

### 2.16 The queue doesn't show which songs are already in your download folder

**Today.** The queue shows library matches (greyed or yellow), but not whether "Blue Lantern.flac" already sits in your download folder; that's discovered only during the batch, after a TIDAL request for each track. Re-import a 500-track playlist where 450 songs are already downloaded and all 500 rows look new; Download All then spends a request on each of the 450 just to skip it, and when you're offline or TIDAL errors, those turn red "failed" instead of skipped. A different song with the same title is skipped and vanishes the same way (2.6). For Spotify rows you can't check by eye, because the row shows Spotify's title while the file is named from TIDAL's (4.14).

**Choices**
- **A. A quiet "In your download folder" badge; the row stays included and skips instantly (recommended).** When rows are added, and again before a batch, the app looks in the download folder using TIDAL's title (kept on every row) and runs 2.3's quick check. A match shows a quiet "In your download folder" badge with Show in Finder. The row stays included, and the batch skips it without asking TIDAL anything, so being offline can't turn it into a failure. If the file there is a different song with the same title, the row says so before you press Download All: "A different song is already saved as Intro.flac" (what happens next is 2.6). An .m4a doesn't earn the badge when TIDAL now lists a lossless version (2.10). Cost: one more quiet badge to design.
- **B. Such rows start greyed with + Add, like exact library matches.** Cost: a second review rule, and more grey rows to read for no gain, because these rows are skipped anyway (grey means left out, with the reason written on the row; see the start of area 3).
- **C. Found only at download time (today).** Cost: re-imports look all new, waste requests, and same-title clashes stay hidden.

**Why A.** There's no new review rule, re-imports skip in seconds, and a same-title clash shows up before Download All instead of after.

**Touches your rules.** Rule 4's library review in the queue is unchanged; this is a separate, quieter mark. Your 21 Oct decision that old files count for skip-if-exists holds, apart from 2.10's exception for old .m4a files.

### 2.17 Changing the download folder during a batch

**Today.** Settings stays usable during a batch. If you pick a new download folder mid-batch, the running batch keeps saving into the old folder. When it ends, the "✓ Batch finished." notice's Open folder button opens the new folder, which doesn't have the files you just downloaded.

**Choices**
- **A. The batch keeps its folder, and says so (recommended).** The running batch keeps saving to the folder it started with, and its summary's Open Folder opens that folder. While a batch runs, Settings shows under the folder: "Downloads in progress are saved to "TIDAL". The new folder is used from the next batch." Nothing is moved between folders. Cost: none notable.
- **B. Lock the download folder during a batch.** The setting is greyed out until the batch ends. Cost: to change it you have to stop the batch.
- **C. Switch the running batch to the new folder from the next track.** Cost: one batch's files end up split across two folders, and the already-downloaded check looks only in the new one.

**Why A.** Nothing changes under a running batch, and Open Folder always shows the files that batch saved.

**Touches your rules.** None.

### Fixed without a decision

- **2.18 Every way of starting downloads behaves the same.** Today: Download all checks only that a sign-in file exists, Retry All and the row's ↻ Retry don't check even that, and the row's Retry plays no start chime and doesn't wait to see whether the batch started, so a refused start leaves "Downloading…" stuck. In the Swift app: Download All, Retry, Retry All and Retry Selected run the same checks (download folder chosen and available, not inside the library, TIDAL sign-in working), play the same warning honk with a plain message when blocked, and play the same start chime only once a batch has really started, a single row's Retry included; no sound plays before its action. When the only problem is being signed out, the 1.1 sign-in sheet appears instead of the honk. The sign-in check reads the stored expiry and renews in the background instead of holding up the click; if TIDAL refuses the renewal, the batch stops once (1.6, 2.1), and a renewal that fails for network reasons waits as in 1.7.
- **2.19 Download folder missing, moved, in the Trash or unplugged.** Today: with the drive "Music SSD" unplugged, Download all still starts and every track fails before the success ping; rename the folder in Finder and the app silently creates a new, empty folder under the old name and downloads songs you already have into it. In the Swift app: it remembers the folder itself (a macOS bookmark, a saved reference that follows a folder when it is renamed or moved on the same disk), checks it before a batch and before each track, never creates it silently, and says what to do: "The download folder "TIDAL" on Music SSD isn't available. Connect the drive or choose another folder.", "The download folder "TIDAL" no longer exists." (with Create Folder and Choose Folder…), or "The download folder "TIDAL" is in the Trash. Put it back or choose another folder." Settings' Open button shows the same message instead of doing nothing, an unplugged network share never triggers a login prompt, and a drive that disappears mid-batch stops the batch once (2.1); whether the bookmark still works after the drive is unplugged and plugged back in needs a live check.
- **2.20 A full disk fails every remaining track.** Today: with 100 MB free on the download drive, each track downloads, fails to save with "no space left on device", and the batch moves on to the next before playing the success ping; if the Mac's startup disk is full, the batch can't start, the button sticks on "Downloading…", and queue and settings saves fail without a message. In the Swift app: each track is written to disk as it arrives instead of being held whole in memory, the app checks for room before each track (about twice the track's estimated size to cover the temporary copy, roughly 330 MB for a 4-minute Hi-Res track) and checks the startup disk before a batch, because the queue is saved there. When space runs out the batch stops once with "The disk with your download folder is full (about 330 MB more needed). Free up space, then choose Download All."; unfinished rows wait and temporary files are deleted.
- **2.21 A TIDAL hiccup saves 16-bit instead of Hi-Res.** Today: if the Hi-Res request fails for any reason (a momentary server error, a "too many requests" answer, a timeout), the app quietly asks for CD quality and saves a 16-bit "Blue Lantern.flac" though a Hi-Res master exists; the row keeps its Hi-Res badge, skip-if-exists keeps that copy for good, and when both requests fail all you see is "Could not get playback manifest at any quality." In the Swift app: temporary errors on the Hi-Res request are retried under the shared pace (1.4) and never cause a step down; CD quality is used only when TIDAL clearly answers that the track has no Hi-Res, and a sign-in rejection is never a reason to step down (one that repeats after one renewal stops the batch once, 1.6). The "Saved" line states the quality actually saved ("Saved Blue Lantern.flac, 24-bit / 96 kHz", "16-bit", or "AAC" for 2.10's fallback) and flags a step down on a row that showed Hi-Res; per-track failures say why ("Not available in your country", "TIDAL is busy. Try again in a few minutes."). What TIDAL actually answers in each case needs a live check.
- **2.22 The batch counter counts tracks that aren't in the batch.** Today: five tracks failed, you tick one and choose Retry Selected, and the counter reads "4 / 5" at once, because the other failed rows (and any other untouched rows) count toward the total; rows added mid-batch inflate it so it never reaches the end, and rows waiting their turn look exactly like idle rows. In the Swift app: the counter counts only this batch ("1 of 1" for that retry, "37 of 120" in a big batch), rows waiting in the batch show a quiet "Waiting" label, and rows added mid-batch count only if they join the batch (4.12). The overall bar and per-row progress you built in v0.1.10 stay.
- **2.23 A 30-second preview clip could be saved as the full track.** Today: the app asks TIDAL for the full track but never checks what came back, so if TIDAL sends a preview clip instead (for example when a subscription has lapsed; needs a live check), the clip is tagged and saved as "Blue Lantern.flac", the row says done, and skip-if-exists treats it as the song forever. In the Swift app: the app reads TIDAL's answer for whether it is the full track and, if not, fails the row with "TIDAL sent only a preview. Check that your TIDAL subscription is active, then Retry."; 2.2's length check is the backstop, and if the first track of a batch fails this way the batch stops once (2.1, 1.10).

---

## 3. Matching and the music library

This area covers how the app decides which TIDAL track a Spotify link or an imported line means, and whether you already own a song, which sets the greyed "📁 already in library" and yellow "⚠ similar version in library" marks in the queue. Most items change which rows start greyed, so each one says which way it errs when it is wrong. One rule holds throughout the document: a greyed row is left out of Download All, whatever the reason, and the reason is written on the row (already in library, a different artist on TIDAL in 3.2, or left out by you in 3.14).

### 3.1 Songs with accents or non-Latin titles match the wrong song, or never match

**Today.** Before comparing titles or artists, the app turns every character that isn't a plain English letter or digit into a space. A title written only in another script becomes empty: import "青い灯籠 - Placeholder Artist" and every non-Latin TIDAL result counts as the same title, accepted with no artist check, while Latin-titled results count as partial titles, so another song by Placeholder Artist can win. Accents are cut, not simplified: "Café Étoile" becomes "caf toile", so a CSV line typed "Cafe Etoile" comes back "not found". In the library, non-Latin songs you own are never flagged, and "Blue Lantern (Синий)" counts as plain "Blue Lantern" and can be greyed by mistake.

**Choices**
- **A. Every alphabet, accents ignored, no empty titles (recommended).** The app keeps letters and digits from every script, ignores accents ("é" counts as "e") and letter width, and treats the two ways a Mac can store "é" alike. A title made only of symbols or emoji ("♡", "!!!") is compared on its raw text, and two empty titles never match. "Cafe Etoile" finds "Café Étoile"; a Japanese title gives the right song or an honest "not found", also when the two services write it in different scripts. Cost: rare accent-only pairs ("Pena", "Peña") now compare equal; "ø" stays distinct, so "Lø" and "Lo" still differ.
- **B. Every alphabet, accents kept.** Cost: "Cafe Etoile" still won't find "Café Étoile", for no real saving.
- **C. Exactly today's results.** Cost: keeps the wrong picks, and needs a careful copy of the old rules just to keep their bugs.

**Why A.** An empty title accepted with no artist check is how the app confidently picks a wrong song today; A closes that path and finds duplicates you already own. A library "exact" still needs the artist to agree. Two-character titles such as "東京" are covered by 3.13.

**Touches your rules.** Rule 4's two looks are unchanged, but more songs you own, with accents or in other scripts, will start greyed: this is the matching change you were asked to approve.

### 3.2 A song with the right title but the wrong artist is accepted, and you can't tell

**Today.** For a Spotify track or an imported line, the app searches TIDAL for title plus artist and scores the top 10 results. An exact title is accepted whatever its artist. Example: your playlist has "Intro" by Placeholder Artist; if only Another Band's "Intro" is in the top 10, that song is saved as "Intro.flac" and later blocks the right one as already in the download folder. Spotify rows keep showing Placeholder Artist (4.14), so the swap is invisible; import rows show TIDAL's artist, but nothing marks the difference. The artist test is loose too: the "the" of "The Placeholders" is found inside "Another Band". Imports never use song length.

**Choices**
- **A. Artist or length confirms; anything else is flagged (recommended).** One matcher serves links and imports. Free-text artist lines (Spotify's, a CSV's) are split at commas, "&", "/", "feat." and " x ", with the whole line kept too; a piece counts only by equalling a whole name in TIDAL's artist list, which is never split, and "the" never counts. An exact title is accepted when an artist agrees or the lengths agree within about 3 seconds, which rescues one act written in Japanese script on one service and Latin letters on the other, "&" against a list, or a renamed band. A partial title still needs the artist, and a line with no artist at all accepts an exact title, as today. Otherwise the best exact-title result is queued left out (greyed, with + Add) with the note "Different artist on TIDAL". Cost: a different same-titled song of nearly the same length still slips through, mostly short titles like "Intro"; its row shows TIDAL's artist (4.14).
- **B. Only the artist confirms; anything else flagged.** Cost: every differently spelled artist becomes a row to approve by hand.
- **C. Artist or length confirms; anything else is "not found".** Cost: right songs with oddly spelled artists need a manual search.
- **D. Today's rule, in one shared matcher.** Cost: keeps the silent wrong-artist picks.

**Why A.** Length is independent evidence: A accepts real matches that differ only in spelling, which B and C turn into clicks or misses, and stops silent wrong picks without losing the row.

**Touches your rules.** Your notes record today's rule (exact title, or a partial title with enough artist agreement) as the fix for earlier false matches; A keeps the partial-title half and narrows the exact-title half. Left-out rows reuse your + Add look; their note, not the amber colour, gives the reason, and 3.6 never clears them.

**Needs a live check.** Compare old and new picks on a real Exportify CSV and a Spotify playlist; confirm the CSV has a length column (4.5).

### 3.3 A short artist name inside a longer one counts as the same artist

**Today.** A library file counts as an exact duplicate when its title tag (the title stored inside the file) equals the incoming title and one artist line contains the other as plain text, so a short name matches any longer name that contains it. Example: your library has "Blue Lantern" tagged "Ox"; you add "Blue Lantern" by Boxer Collective, a different song. "ox" sits inside "boxer", so the row turns grey and is left out of Download all unless you click + Add. The opposite also happens: a file tagged "Second Guest; Placeholder Artist" fails against "Placeholder Artist, Second Guest" because the order differs, shows as similar, and downloads again. Whether a file with several artist tags gives all of them to the check is unknown (needs a live check).

**Choices**
- **A. Whole names, at least one shared (recommended).** The library's artist line is split into names at commas, semicolons, slashes, "&", "feat." and " x ", and the whole line is kept as well; TIDAL's artists arrive as a list and are never split. Exact needs one library name to equal one whole TIDAL artist name, using every artist tag in the file. "Ox" against Boxer Collective becomes similar; the reordered pair becomes exact. Cost: a band name containing a separator ("Salt, Wind & Lantern") is split too, so "Lantern" could equal an unrelated act called Lantern and grey out a same-titled song (rare). A shortened tag ("Placeholder") drops to similar, which downloads rather than skipping.
- **B. Whole names, all must match.** Cost: tags often leave out featured artists, so many real duplicates download again.
- **C. Today: plain text containment.** Cost: false "already in library" for short names, and reordered artist lists missed.

**Why A.** It keeps your v0.1.24 rule (exact means title AND artist agree) but makes "artist agrees" mean a real name match, and when it errs it errs toward downloading.

**Touches your rules.** Strengthens the v0.1.24 strict-match rule; no conflict.

**Needs a live check.** That the tag reader chosen in 3.10 returns every artist value of a file with several artists.

### 3.4 An extended mix with the same plain title counts as the song you already have

**Today.** The scan reads each library file's length, but the duplicate check never uses it. Example: your library has "Blue Lantern" by Placeholder Artist, 3:58; you add a 7:41 extended mix whose title is also plain "Blue Lantern", which happens when TIDAL keeps "Extended Mix" in its separate version field (2.7, 3.11). Title and artist agree, so the row is greyed and left out, and you keep only the short version. It also works the other way: files this app downloaded carry only the bare title, so an Extended Mix you downloaded last month greys out the radio edit you add today.

**Choices**
- **A. Lengths more than 10 seconds apart make it similar (recommended).** When both lengths are known and differ by more than 10 seconds, an exact match becomes similar: yellow badge, included, and a note with both lengths ("Library: Blue Lantern, 3:58; this one 7:41"). A length of 0 or one that can't be read counts as unknown and changes nothing; the same ISRC (3.5) stays exact whatever the lengths. Cost: a trimmed copy or one with a cut fade may download again, and some MP3s report wrong lengths, which errs the same safe way.
- **B. Show both lengths, keep the verdict.** Cost: relies on you reading the note on every grey row.
- **C. Today: length ignored.** Cost: different mixes with the same plain title are silently left out.

**Why A.** Two copies of one recording almost never differ by 10 seconds, and a wrong call gives a visible download, not a silent skip. It also covers the app's own past downloads, whose tags lack the version.

**Touches your rules.** Adds one condition to your v0.1.24 "exact" (title AND artist agree): the lengths must not clearly differ. It only ever moves rows from greyed to included.

**Needs a live check.** On about 20 of your files, the Swift app's length is within a second or two of TIDAL's for the same recording.

### 3.5 Your past downloads carry a recording code (ISRC) the library check never reads

**Today.** An ISRC is the industry code for one specific recording. Every FLAC this app has saved carries its ISRC in the tags (its .m4a files probably have none), and TIDAL's track details carry it, but queue rows don't keep it and the library scan reads only title, artist and length. So the strongest proof that you own a recording is never used. Example: last month you downloaded "Blue Lantern", the Extended Mix, tagged with the bare title; if 3.4 or 3.11 tighten the title rules, it could drop to similar and download again. Spotify's public page gives no ISRCs, and a CSV's ISRC column is thrown away.

**Choices**
- **A. Same ISRC is exact; anything else falls back to title and artist (recommended).** Each queue row keeps TIDAL's ISRC, and the saved index (3.7) keeps each library file's. The same ISRC counts as exact (greyed, with + Add) whatever the title or version text says. A different or missing ISRC proves nothing, because one recording can carry different codes on different releases, so the other rules in this area decide. A CSV's ISRC column is looked up on TIDAL first (4.5). Cost: it only helps files that carry an ISRC, mostly the ones this app saved.
- **B. ISRC decides both ways.** Cost: a song re-released under a new code (a compilation, a reissue) stops counting as owned and downloads again.
- **C. Today: ISRC never read.** Cost: your past downloads depend on title text, which this area makes stricter.

**Why A.** It turns the app's own downloads into certain matches, and it is the safety net that lets 3.4 and 3.11 be stricter without re-downloading what you have.

**Touches your rules.** Adds a second way to reach "exact" besides v0.1.24's title AND artist: the same recording code, which is stronger proof than names.

**Needs a live check.** That TIDAL's search results and album and playlist items include the ISRC; that TIDAL's ISRC lookup works with this app's sign-in; and which tag the old app wrote it under (its .m4a files may have none).

### 3.6 Greyed "already in library" rows disappear after any batch, even a one-row retry

**Today.** When a batch ends, the queue keeps only rows that failed, weren't found, or were included but not in the batch. Greyed rows you didn't + Add are none of these, so they are removed and the shorter queue is saved, with nothing in the log. This happens after Download all, a single Retry, Retry all or Retry selected, and Cancel. Example: a 20-row playlist with three greyed rows and one failed row; you retry the failed row, and when it finishes the three greyed rows are gone too, before you decided about them. The code's own comment mentions only downloaded and skipped rows, so this looks accidental.

**Choices**
- **A. Clear them only after a complete Download All, and say so (recommended).** Complete means not cancelled and not stopped early (1.6, 2.1); a batch that paused for the internet (1.7) and then finished counts as complete. Only rows that were greyed as already in your library when you pressed Download All are cleared; rows added during the batch stay for you to review (4.12). The log says "Cleared 3 tracks already in your library." Rows left out for another reason (a different artist on TIDAL, 3.2, or left out by you, 3.14) stay. Retry and Cancel leave every greyed row alone, and Edit › Undo (3.14) brings cleared rows back. Cost: rows left out for those other reasons wait until you remove them.
- **B. Keep them until you remove them.** An Edit menu command, "Remove Tracks Already in Library", clears them in one go. Cost: grey rows pile up across sessions.
- **C. Today: gone after any batch, silently.** Cost: unreviewed rows vanish after an unrelated retry.

**Why A.** It keeps the tidy empty queue you are used to after downloading a whole list, stops a small retry or a mid-batch paste from wiping rows you haven't looked at, and the log line makes the clean-up visible.

**Touches your rules.** Rule 4 (library review happens in the queue) is kept; a retry no longer cuts the review short, and rows added during a batch are never cleared unseen. A departs from the port plan's earlier default that greyed rows always stay (B).

### 3.7 Every launch re-reads the whole library before duplicates can be checked

**Today.** Nothing is saved between launches: each launch walks the whole library folder and opens every audio file to read its tags. CLAUDE.md records about 18 seconds for about 500 files; bigger libraries take longer. A link, search or import that finishes during the scan waits for all of it (4.20). Example: you open the app and paste a playlist link; TIDAL answers in seconds, but the loading cover stays up until the scan ends.

**Choices**
- **A. Saved index; re-read only what changed (recommended).** The app keeps its index (its list of what is in your library) in its own Caches folder: each file's size, modification date and change time (a date the disk sets itself, which tag editors can't hold back), plus its tags (title, every artist, length, ISRC), tied to one library folder. On launch it lists the folder, which is fast, and re-reads only new or changed files; Settings shows "Checking 12 changed files…". It runs in the background, Refresh still forces a full re-read, nothing is written into the library, and a lost index costs one full scan. Cost: a tag edit by a tool that keeps the old date is caught by the change time on the Mac's own disk, but on some external or network drives only after Refresh.
- **B. Saved index plus live watching.** New files in the library are picked up within seconds. Cost: more moving parts, and unreliable on external and network drives, so Refresh must stay.
- **C. No saved index; measure first.** Cost: the cold scan stays the slowest thing at launch, and online-only Dropbox files (3.8) would be read again every launch.

**Why A.** It is your own backlog item 1 and removes the launch wait; live watching can be added on top later.

**Touches your rules.** Implements your backlog item "disk-cached library scan" (keyed by modification time and size); the library stays read-only because the index lives in the app's own folder.

**Needs a live check.** Time a cold and a cached launch on your real library, and confirm that Dropbox freeing a file's space doesn't change its size or dates.

### 3.8 How the library scan treats your Dropbox files, hidden copies and a missing drive

**Today.** This matters most for your own setup. Your library was "Z:\Dropbox\Music" on Windows, so on this Mac it most likely lives in Dropbox, where files are often online-only: a placeholder until something opens it. The scan opens every file to read its tags, which probably makes Dropbox download each one (needs a live check). Also: hidden "._" companion files on exFAT and network drives are indexed as songs, so a leftover one keeps flagging a song you deleted; links, Finder aliases and .aif and .aiff files are skipped silently; and a missing drive or refused access shows "0 files indexed", so every row looks new.

**Choices**
- **A. Read online-only files once, with your OK, and remember their tags (recommended).** The first scan that finds them asks once: "412 library files are online-only in Dropbox. Reading their tags makes Dropbox download them (about 9.8 GB)." with Read Tags and Match by Name Only. Tags go into the saved index (3.7), so each file is read only once; where Spotlight (the Mac's search index) already knows a file's title and artist, nothing downloads. Hidden files are skipped, links and aliases followed, .aif and .aiff added. A missing folder says "The library folder "Library" on Music Drive isn't available. Connect the drive or choose another folder.", keeps the last index and rescans when the drive returns; refused access points to System Settings › Privacy & Security › Files and Folders. Cost: the first scan may download your library onto this Mac once.
- **B. Same, but online-only files matched by name only.** Cost: a name match is never exact, so nearly every song you own shows yellow, stays included, and Download All downloads your library again.
- **C. As B, plus an "Artist - Title" name with both halves matching counts as exact.** Cost: revises your v0.1.24 decision, and can't help this app's "<Title>.flac" files.
- **D. Today.** Cost: silent mass downloads are possible, and there is no duplicate check while the drive is missing.

**Why A.** It is the only choice that avoids silent mass downloads and still stops your library being downloaded again. If your Dropbox music is kept available offline, the question never appears.

**Touches your rules.** Library is read-only: A never changes a library file, but reading makes Dropbox fetch files, so it asks first. C would revise your v0.1.24 decision that a file name alone is no proof.

**Needs a live check.** Whether your Dropbox music is online-only; spotting a placeholder without downloading it (your check-for-dupes skill does this); whether Spotlight knows their tags.

### 3.9 Queue rows keep an old library verdict after the library changes

**Today.** A row's library mark is decided once, when the row is added, and saved with the queue. It is never re-checked: not after a restart, not after Refresh, not after you change or clear the library folder, and not when you add the same track again. Example: on Monday you queue a playlist and "Blue Lantern" looks new; that evening you copy "Blue Lantern.flac" into your library; on Tuesday the restored row still looks new and Download all downloads it again. The other way round, a song you deleted from the library stays greyed.

**Choices**
- **A. Re-check automatically, keep your choices (recommended).** The queue is re-checked after the launch scan, after Refresh, and when the library folder changes or is cleared. Rows follow the new result unless you made a choice on them (+ Add, or Leave Out from 3.14), which is kept. It never re-checks against an empty or incomplete index: if the library can't be read (missing drive, refused access, failed scan), rows keep their last mark and the queue header says "Library not available, duplicate marks from 20 Oct". Download All waits for a running scan, as 4.20 describes, so nothing slips through. Spotify rows are re-checked with the title they show (4.14). Cost: a row may change its look while you review, such as turning grey a few seconds after launch.
- **B. Re-check only on command.** A menu command, "Check Queue Against Library". Cost: easy to forget, so the stale cases stay the default.
- **C. Today: fixed when the row is added.** Cost: duplicates download, and deleted songs stay greyed.

**Why A.** The mark should describe your library as it is now, never override your own choice, and never un-grey everything because a drive is missing.

**Touches your rules.** Rule 4 is kept, and a re-check never undoes your + Add.

### 3.10 How the Swift app reads tags, so the FLAC, Ogg and Opus files you own are recognised

**Today.** The Electron app reads tags with music-metadata, a JavaScript library that handles FLAC, MP3, M4A, WAV, Ogg and Opus. Apple's built-in audio framework (AVFoundation) reads MP3, M4A, WAV and AIFF tags, but its FLAC support is weak or missing and it doesn't read Ogg or Opus. Without a replacement, FLAC files, the very format this app downloads, would be matched by name only, which can never be exact: your "Blue Lantern.flac" tagged Placeholder Artist would give an incoming "Blue Lantern" only a yellow badge, and it would download again. Today a file whose tags can't be read fails the same way, silently.

**Choices**
- **A. Apple's reader plus two small readers of our own (recommended).** AVFoundation reads MP3, M4A, WAV and AIFF; two small, tested Swift readers handle FLAC and Ogg or Opus, including every artist value and the ISRC. All sit behind one interface, so TagLib can be swapped in if testing finds gaps. Settings counts files whose tags couldn't be read ("312 files matched by name only"). Cost: we own edge cases such as damaged files; the formats are stable and well documented.
- **B. TagLib.** The widely used open-source C++ tag library reads every format here and more. Cost: a C++ build bridged into Swift, a dependency to keep updated, and a licence (LGPL or MPL) worth recording next to it as good practice.
- **C. SFBAudioEngine.** A mature Mac audio framework that reads these tags and can also play FLAC. Cost: many bundled codec libraries, some needing a licence review; far more than this needs unless the preview uses it too.
- **D. Spotlight only.** Cost: missing on many external and network drives, and possibly for FLAC.

**Why A.** Native first with no dependency; FLAC, the main format, is the simplest to read, and the shared interface keeps TagLib as a fallback.

**Touches your rules.** None; every option only reads your library files.

**Needs a live check.** On a sample of your library: title, every artist and length against Finder's Get Info; MP3s with only old-style tags; ISRC; a full scan's time; and whether AVFoundation reads FLAC tags at all.

### 3.11 Versions (Radio Edit, Extended Mix, Remaster) are ignored when matching

**Today.** TIDAL is believed to keep a track's version in its separate field (2.7): title "Blue Lantern", version "Extended Mix". The app reads only the title. So the library check treats the Extended Mix as the same song as your "Blue Lantern" by the same artist and greys it out, unless 3.4 catches the length. For a Spotify "Blue Lantern - Extended Mix" or a CSV line, the original and the extended mix score the same, so TIDAL's search order decides. And every file this app saved carries only the bare title tag, even the Extended Mixes. Versions in the queue and in search are 4.15; in the file name and title tag, 2.7.

**Choices**
- **A. Match on title plus version, with a rule for older files (recommended).** Comparisons use "Blue Lantern (Extended Mix)", without doubling a version already in TIDAL's title, and the matcher prefers the version the Spotify or CSV title asks for. A library file is exact when its ISRC matches (3.5, checked first), or, with the artist agreeing, when its title tag equals title plus version or carries the bare title with lengths within about 3 seconds; that last case covers every Extended Mix you downloaded before. This 3-second rule applies only when the incoming track has a version and the library file has the bare title; otherwise 3.4's 10-second rule applies. Anything else is similar and downloads. Cost: an older bare-titled file with no ISRC and an unreadable length drops to similar and downloads again.
- **B. Use the version only to break ties on TIDAL.** Cost: the library check still greys out a different mix unless 3.4 catches it.
- **C. Today: the version is never read.** Cost: wrong versions are picked and greyed out as duplicates.

**Why A.** You get the version you asked for, and a different mix is no longer called a duplicate. Without the older-file rule, every Extended Mix you downloaded before would stop matching and download again.

**Touches your rules.** Rule 3 (the file name is the title): no file names change here; 2.7 decides whether the version joins the name and the title tag.

**Needs a live check.** On a few real TIDAL tracks: that the version field exists, how often the title already contains the version, and what typical values look like. 2.7, 3.4 and 4.15 rely on this same check.

### 3.12 Library files are matched on the wrong part of their name

**Today.** The app compares every library file's name as well as its tags; for files without a usable title tag, the name is all it has. It takes the text after the last " - " as the title and knows only a few version spellings. So "Placeholder Artist - Blue Lantern - Radio Edit.mp3" is read as a song called "Radio Edit"; "01. Blue Lantern.flac" never matches; a name with a long dash ("–") isn't split; "Blue Lantern - 2011 Remaster" isn't seen as a version; and "Seven Ft Harbour" is cut to "Seven", because "Ft" looks like "featuring".

**Choices**
- **A. Smarter name parsing, keeping today's whole-name keys (recommended).** Names are split at the first " - ", " – " or " — ", and the unsplit name is kept as an extra key, so "Blue Lantern - Radio Edit.flac" with no artist prefix still matches "Blue Lantern". A leading track number is removed only when followed by "." or "-", or zero-padded ("01 "), and only if three or more characters remain; the unstripped name is kept too, so "22 Harbour Lights" and "7 Lanterns" still match themselves. A dash tail containing a version word anywhere (remaster, remix, edit, mix, live, demo) counts as a version; "ft" counts only with a dot, in brackets, or spelled out. Every name match stays similar, never exact. Cost: reversed "Title - Artist" names still parse wrongly, and a real title with a version word after a dash may count as a version; both only add a yellow badge.
- **B. Today's parsing.** Cost: untagged files mostly can't be found by their real title, and some give false yellow badges.

**Why A.** Your library includes MP3 dumps with thin tags; this makes files without a usable title tag findable while keeping name matches at similar, so nothing is silently skipped.

**Touches your rules.** Keeps your v0.1.24 decision that a file name alone is never proof of identity.

### 3.13 Songs with very short titles are never checked against the library

**Today.** The library check first strips version text from a title ("Go (Placeholder Remix)" becomes "Go"); if what remains is shorter than three characters, it gives up. Example: your library has "Go" by Placeholder Artist; you add "Go" by Placeholder Artist, it shows no badge, and it downloads again. The same goes for "XO", "22" or "7". Because only the stripped title is tested, "Go (Placeholder Remix)" is never checked either, even against an identical library file. With 3.1, two-character titles in other scripts ("東京") would fall into the same gap.

**Choices**
- **A. Check short titles, but only as exact with the artist (recommended).** A full title of three or more characters is always checked normally, so "Go (Placeholder Remix)" finds its twin. A short title can only give exact: title and artist agree (and the lengths, under 3.4). No yellow badge comes from a short title alone, because short titles collide too easily. Cost: a short-titled remix in your library won't show as similar to an incoming "Go".
- **B. Today: short titles are never checked.** Cost: duplicates of short-titled songs download again.

**Why A.** It catches real duplicates without the noisy title-only matches the three-character guard was protecting against.

**Touches your rules.** Follows your v0.1.24 rule: a short title can only be exact when the artist agrees too.

### 3.14 + Add can't be undone, and a similar row can't be left out without deleting it

**Today.** Clicking + Add on a grey row includes it, and the only way back is to delete the row. A yellow "similar version" row is always included; to skip it you must delete it. The matched library file appears only as a path in a tooltip, and you can't open it. Example: you click + Add on "Blue Lantern" by mistake; the only fix is to delete the row, and to get it back you paste the whole playlist link again.

**Choices**
- **A. Leave Out and Include, Show in Finder, and Undo (recommended).** The bright + Add button stays exactly as today. Every row gains "Leave Out of Download" and "Include in Download" in its right-click menu and the menu bar, with a keyboard shortcut; a similar row you leave out turns grey like an exact one, with "Left out by you" on the row. Rows with a library mark gain "Show Library File in Finder". Edit › Undo (⌘Z) and Redo (⇧⌘Z) reverse + Add, Leave Out, Include, Remove from Queue and the end-of-batch clean-up of library rows (3.6). Cost: a few more commands to design and test; nothing visible changes unless you use them.
- **B. Undo only.** Fixes accidents. Cost: a similar row can still only be deleted, and the library copy can't be opened from the app.
- **C. Today.** Cost: a mistake costs a re-import.

**Why A.** It keeps your + Add look intact and adds the reverse, a Finder shortcut and Undo through native menus, which a Mac app is expected to have anyway.

**Touches your rules.** Rule 4 and your + Add button stay the visible control; this only adds the reverse action, a Finder shortcut and Undo.

### Fixed without a decision

- **3.15 Changing the library folder during a scan.** Today: switching folders, Clear or Reset config mid-scan doesn't stop the scan, so the old folder's list becomes the index, Settings shows its count under the new path, and rows can still turn grey after Clear ("duplicate check disabled"). In the Swift app: one library service owns the index; changing, clearing or refreshing the folder cancels the running scan and ignores older results, Clear and Reset empty the index at once, and Settings always shows the count for the folder it names.
- **3.16 A second, simpler TIDAL search before "not found".** Today: each Spotify track or imported line gets one TIDAL search with the full title and every artist, so "Blue Lantern - 2011 Remaster (feat. Second Guest)" by three artists can miss the top 10 and come back "not found". In the Swift app: when nothing passes, one more search uses the plain title and the first artist under 3.2's rules. It is switched on only after 3.2's live check shows it helps; a busy TIDAL is retried under 1.4, not counted as a miss.

---

## 4. Adding tracks: links, search and imports

This area covers every way a song gets into the queue: typing a name, pasting or dragging a TIDAL or Spotify link, and importing a CSV file (a spreadsheet saved as plain text) or a pasted list. It decides what each kind of input does, what you see while it runs, and how you fix a row that didn't match.

### 4.1 Typing a number looks up a TIDAL track number instead of searching

**Today.** You want the song "2041" by Placeholder Artist, so you type 2041 and press Return. The hint promises a search ("Type to search TIDAL by song name (or paste a link)."), but text made only of digits is treated as TIDAL's internal track number. Either whichever track has number 2041 goes straight into the queue with no results to pick from, or the log shows "✗ Track info failed: 404 …" and TIDAL's raw reply. Text shaped like a TIDAL playlist code (the long letters-and-digits code inside a playlist link) is loaded as a playlist the same way. "2041 Placeholder Artist" searches normally.

**Choices**
- **A. Plain text always searches (recommended).** Anything that isn't a link opens search results, numbers included. TIDAL numbers only arrive through links. When a digits-only or playlist-code search finds nothing, the message says "Looking for a TIDAL track or playlist by its ID? Paste its link instead." Cost: typing a bare number no longer opens a track by its TIDAL number; nothing needs it (only the old command-line tools took numbers, and they aren't being ported).
- **B. Search, plus an "open by number" row.** Digits search as in A; if a TIDAL track with that number exists, it also appears on top as "TIDAL track #2041: <title> — <artist>". One extra TIDAL request per numeric search, and an odd extra row when you just wanted the song.
- **C. Keep today.** Digits stay a track number. Songs titled with only a number can't be searched, and the hint keeps promising a search.

**Why A.** The hint already promises a search, and links cover every real way a TIDAL number reaches the app. It is the smallest rule with no surprises.

**Touches your rules.** None.

### 4.2 Links the app can't use are searched as song names, while the hint says "Detected a link"

**Today.** You paste a YouTube link to "Blue Lantern". The hint says "Detected a link — will resolve all tracks on add.", but Return sends the web address to TIDAL search and opens "Search results for “https://…”", usually empty or unrelated (needs a live check). The same happens with Apple Music links and with TIDAL or Spotify artist pages. The hint follows a different rule from Return and keeps its old text after the field clears. Results are vague: "+ Added 0 tracks from link." for an empty playlist, silent skips for tracks already queued, no album or playlist name, and a technical message ("✗ Spotify playlist embed failed: HTTP …") for a private Spotify playlist.

**Choices**
- **A. Name what's supported, and say what Return will do (recommended).** TIDAL and Spotify track, album and playlist links work as today. Any other link is refused with how to fix it, and nothing is searched: "YouTube links aren't supported. Paste a TIDAL or Spotify link, or type the song's name." The hint follows Return's rule, says what will happen ("Spotify playlist: adds up to 100 tracks") and resets when the field clears. Summaries name the source and add up: "Added 12 tracks from Glass Orchard.", "All 12 tracks are already in the queue.", "2 matched the same TIDAL track as another row.", "Spotify won't share this playlist. Make it public in Spotify, or export it with Exportify." Cost: naming a TIDAL album or playlist takes one extra TIDAL request per link; Spotify's name is already fetched today and thrown away.
- **B. One generic refusal.** Unsupported links get "This link isn't supported.", with no live hint or source names. Stops the pointless search but explains less.
- **C. Read song names from other services' pages.** Apple Music and YouTube links are read from their public pages, as Spotify links are. A new feature that depends on pages that change without notice; each service needs a trial run.

**Why A.** It follows your copy rule, the hint and the action can no longer disagree, and other services can still be added later as their own feature.

**Touches your rules.** Global copy rule (plain words; errors say what went wrong and how to fix it): A applies it. No option uses Spotify credentials.

### 4.3 Some normal Spotify and TIDAL link forms aren't recognised

**Today.** Most forms already work: listen.tidal.com, tidal.com with or without /browse, TIDAL share links, and words before any link or after a Spotify link. These are searched as text instead (see 4.2): "spotify:track:…" codes from Spotify's "Copy Spotify URI", open.spotify.com/embed/… links from websites, spotify.link short links from some phone share sheets, and old …/user/<name>/playlist/… links. Words after a TIDAL link ("…/track/123 great one") become part of the track number, and the log shows a technical error (needs a live check). A TIDAL link shaped …/album/A/track/T adds the whole album A rather than the one track.

**Choices**
- **A. Accept every common form; an album+track link adds just the track (recommended).** Codes, embed links, regional /intl-…/ addresses and old playlist links are recognised from the text alone, and words after a TIDAL link are ignored. A spotify.link short link is opened once to see where it forwards to (one request to Spotify's public link service, no sign-in), then handled like the full link; if it turns out to be a web page rather than a plain forward, B's message appears instead. An album+track link adds only track T. Cost: one extra request per short link, and how short links behave still needs the live check below.
- **B. Same, without short links.** A short link shows "Short links can't be opened here. Open it in your browser, then copy the open.spotify.com link." No extra network call, but one more step for links shared from a phone.
- **C. Same as A, but an album+track link adds the whole album.** Keeps today's behaviour for that form, including songs you didn't point at.

**Why A.** Everything except short links is pure text reading that can be fully tested, and the last part of an album+track link names the song you were looking at.

**Touches your rules.** "No Spotify API credentials": following a public short link uses none, so the rule holds.

**Needs a live check.** Open a real spotify.link link: a plain forward keeps A as written; a web page means short links get B's message. Also check whether TIDAL ever makes album+track links.

### 4.4 The 100-track warning says tracks were dropped even when none were

**Today.** You paste the Spotify playlist "Late Ferry", which has exactly 100 songs. All 100 arrive, but the log still says "⚠ Spotify caps playlists at 100 tracks via the public embed. Tracks past #100 weren't included." A 250-song playlist gets the same sentence, with no count and no pointer to the fix: the Exportify hint appears only on the drop zone. The app can't tell 100 from 250 today, because Spotify's public page stops at 100.

**Choices**
- **A. Honest wording with a way forward, and exact counts if Spotify's page has them (recommended).** When exactly 100 tracks come back: "Spotify only shares the first 100 tracks of a playlist. If Late Ferry is longer, export it with Exportify and drop the CSV here. Songs matched to the same TIDAL track aren't added twice.", with an Open Exportify button. If Spotify's page carries the real length, the message appears only for longer playlists, with numbers: "Added the first 100 of 250 tracks. To get the other 150, export the playlist with Exportify and drop the CSV here." The stronger "Tracks already in the queue aren't added twice" is promised only once links and imports share one matcher (3.2). With 4.13, the message can also suggest copying all the songs in Spotify's app and pasting them here, if that works. Cost: small; exact numbers appear only if Spotify's page carries the real length.
- **B. Honest wording only.** A's first message and button, with no check for a real count. Still vague for long playlists.
- **C. Keep today's sentence.** A false alarm on exactly 100 tracks, and no pointer to the fix.

**Why A.** It never claims something the app doesn't know, and it puts the fix one click away at the moment you need it.

**Touches your rules.** Product rule "public embed only, with the 100-track cap warning": the warning stays; only its wording and button change. It points to the Exportify import you built in v0.1.25.

**Needs a live check.** Whether Spotify's playlist page carries a total track count, whether album pages also stop at 100, and whether Spotify's desktop app copies one link per selected song.

### 4.5 CSV import can read the wrong columns

**Today.** You drop an Exportify CSV (Exportify is a website that saves a Spotify playlist as a spreadsheet file). The app takes the first column whose header contains "artist" as the artist, and the first containing "track name", "title", "song" or "name" as the title. If an artist code column ("Artist URI(s)") comes before "Artist Name(s)", every artist becomes a code like "spotify:artist:4Z8W…". Because an exact title is accepted with any artist (3.2), this shows up as occasional wrong-artist picks and extra "not found" rows, so not noticing a problem doesn't prove your exports are safe; a widely used Exportify layout is believed to have this order (needs a live check). "Artist Name, Track Name" searches the artist as the title, and a blank first line turns the file into junk rows. Duration and ISRC columns (ISRC = the industry code for one specific recording) are ignored.

**Choices**
- **A. Exact header names first, plus ISRC and duration when present (recommended).** Headers are compared whole (ignoring capitals, outer spaces and "(s)") before any looser "contains" rule. Title: "Track Name", "Title", "Song", "Track", "Name"; artist: "Artist Name(s)", "Artist Name", "Artists", "Artist", "Album Artist". A title column never mentions artist, album, URI, ID, number, count, duration, time, date, disc or year, so Music's "Track Number" can't become titles. An ISRC column is looked up on TIDAL first, choosing among releases of that recording by length and album; a duration column (milliseconds, seconds or m:ss, read from the header) helps ranking. The summary shows "Columns: Track Name → title, Artist Name(s) → artist". Cost: TIDAL's ISRC lookup has never been tried with this app's sign-in; if it doesn't work, A becomes B plus duration.
- **B. Exact header names only.** A's column rules; matching stays on title and artist. Simplest, but misses the certain matches ISRC gives big imports.
- **C. Keep first-match.** One Exportify layout change silently spoils every import.

**Why A.** Exportify is the documented way past Spotify's 100-track limit, so it is the import that matters most; exact header names make it robust, and ISRC turns guessed matches into certain ones. Files with no header are covered in 4.17.

**Touches your rules.** The Exportify CSV import was built deliberately in v0.1.25; A keeps it and makes it more reliable.

**Needs a live check.** One current Exportify CSV (headers, order, ISRC and duration columns) and one TIDAL lookup by ISRC with this app's sign-in, which has never been tried.

### 4.6 Pasted lines split at the first hyphen and are always read as Title - Artist

**Today.** You paste "Paper-Thin Harbour - Placeholder Artist". The app splits at the first hyphen, even one without spaces, so the title becomes "Paper" and the row comes back "not found". A DJ-style list in Artist - Title order ("Placeholder Artist - Blue Lantern") is scored as if the artist were the title, so most lines fail too. A list number stays in the title ("1. Blue Lantern"), and a one-character title like "7" is dropped.

**Choices**
- **A. Spaced separators only; every split tried in both orders (recommended).** A line splits only at " - ", " – ", " — ", " | " or a tab. Each line is searched once with all its words, and the results are scored against every possible split of the line in both orders; the best wins, and ties go to Title - Artist. So "Placeholder Artist - Blue Lantern - Radio Edit" is also tried as artist "Placeholder Artist" with title "Blue Lantern - Radio Edit", which a fixed "split at the last separator" rule would miss. List numbers ("1. ", "01) ", a number and a tab) are removed, one-character titles are kept when an artist is given, and " by " counts as a separator when there is no other. Cost: no extra requests, but a rare wrong pick needs Search… on the row (4.10).
- **B. Fixed Title - Artist order, with a Swap command.** After an import, "Swap Title and Artist" re-matches that import's rows the other way round. An extra step for every Artist - Title list, and the app must remember which rows came from which import.
- **C. Fixed Title - Artist order only.** Fixes hyphenated names; Artist - Title lists still come back mostly "not found".

**Why A.** It fixes both failures with no extra requests and no new controls, and it copes with lists that mix both orders or end with a version. Comma-separated lines are covered in 4.17.

**Touches your rules.** The documented import format is "Title - Artist"; A still accepts it and also accepts the reverse.

**Needs a live check.** On a few real lists, check that TIDAL search still finds the song when the words come in Artist - Title order.

### 4.7 Pasting outside a text field starts an import, even with Settings open

**Today.** With Settings open and focus on its Done button, you press ⌘V with two song lines copied from a note. An import starts, and the cover appears on top of Settings reading "Matching 0 / 2 tracks on TIDAL…", with no Cancel; the same happens during a download or with search results open. After you click the volume slider or a checkbox, ⌘V does nothing. A single pasted link is ignored without a sign. A single line with a spaced dash or pipe ("Blue Lantern - Placeholder Artist") is imported straight away as one track; a line with a comma instead is imported with the whole text as the title and usually comes back "not found".

**Choices**
- **A. Paste only on the main window, doing the obvious thing (recommended).** ⌘V outside a text field acts only when the main window is in front with no sheet, alert or Settings open. Several lines or a CSV import at once, as today, now with Cancel (4.9). One link is added as if typed into the field. One line with a separator ("Blue Lantern - Placeholder Artist", or a comma) is matched and added directly: as today for dashes and bars, and now also for a comma. One line without a separator goes into the search field, ready for Return. Paste inside text fields always works. Cost: ⌘V outside a text field does nothing while Settings, a sheet or an alert is open.
- **B. Same, but every single line goes to the search field.** A pasted "Blue Lantern - Placeholder Artist" opens search results instead of being added. You see what you add, but today's direct one-line import changes.
- **C. Same as A, with a check before matching.** A list first opens "Import 37 tracks from the clipboard?", showing the first rows as Title | Artist, with a Swap button and Match on TIDAL as the default button. One extra keypress every time, but misread lists are caught.
- **D. Explicit command only.** No paste-anywhere; you use File › Import from Clipboard or the drop zone. Removes a feature built on purpose.

**Why A.** It keeps the one-step paste you built and today's direct match for a single "Title - Artist" line, removes the surprise import behind Settings, and turns ignored pastes (a link, a song name) into something useful.

**Touches your rules.** Paste-anywhere was built deliberately in v0.1.25. A, B and C keep it (B changes how one pasted line behaves); D removes it.

### 4.8 Any dropped file is read as a tracklist, and drops elsewhere aren't handled

**Today.** You drag "Blue Lantern.mp3" onto the drop zone, perhaps hoping to upgrade it. The app reads the audio as text, so a few-megabyte MP3 can become thousands of junk "tracks", searched one at a time behind a cover with no Cancel, possibly for hours, and saved as "not found" rows (an estimate; needs a live check). Dropping two CSVs uses only the first, silently, and a link dragged from Safari does nothing. A file dropped elsewhere in the window isn't handled (in the Electron app it probably replaces the app's page; a native Mac window never does that).

**Choices**
- **A. The whole window accepts tracklists and links; anything else is refused with a reason (recommended).** Dragging over the window lights up the drop zone (light only; nothing moves or grows). Accepted: .csv, .txt and .tsv files (several at once become one import) and TIDAL or Spotify links dragged from a browser; text dropped on the search field fills it. Refused, with nothing read: audio, images, folders, other links, and large or binary files, for example "Blue Lantern.mp3 is an audio file. Drop a CSV or text tracklist, or a TIDAL or Spotify link." A huge text file asks first: "This file has 12,000 lines. Import the first 2,000?" File › Import Tracklist… (⌘O) opens the same file types. Cost: the whole-window highlight and the refusal messages are more to design and test than today's single drop zone.
- **B. Only the drop zone accepts, with the same checks.** Elsewhere the dragged item slides back. A smaller target, and dropping on the queue does nothing, without explanation.
- **C. As A, plus dropped audio files are looked up on TIDAL.** An MP3 or AAC file is matched by its tags so you can upgrade it to lossless by dragging it in; the file is only read. A new feature that gives dropping a second meaning.

**Why A.** The window can't be dropped on "wrong", every refusal explains itself, links come straight from a browser, and a huge file can't start hours of matching. The audio upgrade is a new feature and can be decided on its own.

**Touches your rules.** The drop zone (v0.1.25) stays the visible place to drop. "Nothing tilts, zooms or drifts on hover": the highlight changes light only. In C, dropped files and the library stay read-only.

### 4.9 A long import can't be stopped

**Today.** You drop a 500-song Exportify CSV. A full-window cover reads "Matching 1 / 500 tracks on TIDAL…" and counts up one search at a time for several minutes (exact time needs a live check), with no Cancel; Escape does nothing. On a stalled connection (Wi-Fi joined, no internet) each line can wait 30 seconds, so 300 lines could block the window for over two hours. If your sign-in needs renewing partway (1.8), every remaining line becomes "not found". The cover can sit at "Matching 500 / 500" while the library check runs, and the summary ("+ Added 430 from import. 470 matched on TIDAL, 30 not found.") doesn't add up.

**Choices**
- **A. Cancel keeps what's done (recommended).** The centred progress gains Cancel; Escape and ⌘. cancel too. While the import progress is showing, Escape and ⌘. cancel the import only, never a running batch. Cancel stops at once, including the request already sent (1.11). Lines already processed go into the queue, found or not, and the rest are dropped: "Stopped after 120 of 500. Added 112 tracks, 8 not found. The other 380 lines weren't added." The library check shows as its own step, and the summary adds up: "Added 460 tracks: 430 found on TIDAL, 30 not found. 40 were already in the queue." A sign-in due for renewal is renewed and the search retried (1.8), busy answers are retried (1.4), and a lost connection stops with "No internet connection" and Try Again, keeping your list (1.7), so the end of a long import never turns into false "not found" rows. Cost: lines not yet processed when you cancel are dropped, so you import them again.
- **B. Rows stream into the queue while matching.** No cover: rows appear as they are matched, with progress and Cancel above the queue, and you can keep previewing meanwhile. It replaces the full-window progress you chose in v0.1.23, and the queue shifts while you look at it.
- **C. Cancel discards everything.** As A, but Cancel adds nothing. Throws away minutes of matching.

**Why A.** It keeps the prominent progress you prefer, never wastes finished work, and gives a summary that adds up.

**Touches your rules.** The full-window loading cover was restored in v0.1.23 because the topbar pill "read as too understated"; A and C keep it, B moves away from it.

### 4.10 A "not found" row can only be removed

**Today.** Your import includes "Glass Orchard" by Northbound Choir, and it comes back as a faded "not found" row. You know it is on TIDAL under a slightly different name, but the row has no play button, no Retry and no search; its only control is remove (✕), so you remove it, type the name, search, tick the result and add it. A row whose lookup failed because TIDAL was busy or your sign-in expired looks exactly the same, tooltip "Not on TIDAL" included. If your library has a song with the same title, the faded row still shows "Library: <title>", so it can read as if you already own it.

**Choices**
- **A. Search… on the row, replacing it in place (recommended).** Each "not found" row gets Search… and also Match Again (1.4), both also in its right-click menu. Search… opens the search sheet filled in with the original title and artist; the one result you pick replaces the row in the same place, with the usual library check. Rows whose lookup failed, rather than found nothing, get 1.4's separate "couldn't check" state, with the same two commands. Once 3.16 is switched on, its simpler second search runs before any row is marked "not found". Cost: the search sheet needs a pick-one mode.
- **B. Search… only, result added at the end.** Your pick is added at the end of the queue like any search result, and you remove the old row yourself. Simpler, but leaves the dead row and loses its place.
- **C. Keep remove-only.** Every miss costs five steps.

**Sub-choice.** On a "not found" row, should the "Library: …" note be hidden, or reworded as "You may already have this: <file>"? Recommended: reword it, since the file may be the song you were looking for.

**Why A.** Fixing a miss becomes one click and one pick, the list keeps its order, and temporary TIDAL trouble no longer passes for "not on TIDAL".

**Touches your rules.** Rule 4 (library check before every download): the replacement row goes through the same check, so an exact library match arrives greyed with + Add.

### 4.11 Search results don't show what you already have

**Today.** You search "Blue Lantern". The results show title, Hi-Res, artist, album and length, but not that one of them is already in your music library, although the app has already checked. You tick it, press Add selected, and it lands greyed as "already in library", so you click + Add. A result already in the queue is skipped silently ("+ Added 0 tracks from search."). A search with no results still opens the window ("0 results. Pick the ones to add to your queue."), Add selected with nothing ticked does nothing, Return and Escape do nothing, and adding one result takes a tick plus a button.

**Choices**
- **A. Same badges in search; queue rules unchanged (recommended).** Results carry the queue's own library badges, "already in library" and "similar version in library", in the same wording and colours, with the file's location on hover, plus the version and explicit marker from 4.15. Results already queued say "In queue" and can't be ticked. A ticked library match still arrives greyed with + Add. With no results: "No TIDAL results for “Blue Lantern”. Check the spelling or try fewer words." Add Selected is greyed until something is ticked and is the default button (Return); Escape closes; double-clicking a result adds just that one; Space ticks the highlighted row; a search field at the top refines the search without closing. Cost: small; each result row needs room for a badge.
- **B. Same display, but ticking an "In library" result counts as + Add.** A library match you tick on purpose arrives already included. Faster for deliberate re-downloads, but those rows skip the queue's + Add step.
- **C. Keep today.** Surprise greyed rows and a silent "Added 0".

**Why A.** You see what you have before you pick, and the queue's library rules stay exactly as you set them.

**Touches your rules.** Rule 4: an exact library match starts greyed and is included only after an explicit + Add. A keeps that; B makes the tick count as the opt-in, which is your call.

### 4.12 Adding tracks during a download only half works

**Today.** A batch of 10 is downloading. The Add button is greyed out, yet Return in the field, search, drop and paste all still add. You paste the album "Glass Orchard" (12 tracks, 2 already in your library). The rows appear outside the running batch, but the counter counts them: it reads "4 / 20", never reaches the end, and disappears when the batch finishes. Each new row's waveform starts downloading the full track alongside the batch. When the batch ends, every greyed "already in library" row is removed without you deciding, including the 2 you just pasted, and the 10 new rows wait for the next Download all.

**Choices**
- **A. Every way of adding works; new rows wait for the next Download All (recommended).** Typing, the Add button, search, paste and drop all work during a download, and all behave the same. New rows look like any other waiting row, and the counter counts only the running batch ("4 of 10", see 2.22). When the batch ends, Download All offers the new rows, and greyed library rows added during the batch stay for you to review (3.6 clears only those that were there when the batch started). Whether previews load during a batch is decided in 5.1. Cost: rows added during a batch wait until it ends.
- **B. New rows can join the running batch, with a click.** During a batch, the Download button reads "Add 10 to Downloads"; clicking it appends the new rows to the running batch, and Retry on a failed row joins it too. Nothing downloads without your click, but the counter and summary must handle a batch that grows. (Joining without the click was dropped: a link pasted just to check something would start downloading.)
- **C. Block adding during a batch.** Everything that adds is disabled while downloading, with "Wait for the download to finish, or Cancel it." A long batch locks you out of building the next list.

**Why A.** It keeps one clear moment to review the whole list before anything downloads, matches what mostly happens today, and keeps each batch fixed so its counter and summary stay exact. B can come later if waiting for a batch to end proves annoying.

**Touches your rules.** The queue is where you review tracks before downloading: A keeps one review-then-download step, B keeps review through its extra click, and C by blocking.

### 4.13 A pasted or dropped list of links becomes a list of "not found" song names

**Today.** You copy three Spotify links from a chat, one per line, and press ⌘V outside the field, or drop them as a .txt file. The import treats each link as a song title, searches TIDAL for "https://open.spotify.com/track/…", and every row comes back "not found"; TIDAL playlist links and regional Spotify links are also split at a hyphen inside them. Pasting the same lines into the field doesn't work either. The field holds one line and probably joins the lines with spaces (needs a live check), so only the first Spotify link is added and the rest are ignored without a word, while TIDAL links run together and fail with a technical error.

**Choices**
- **A. Links inside a list are added as links (recommended).** When pasted or dropped text contains supported links, each link line is resolved as a link (track, album or playlist, as in the field) and every other line is matched as a song name (4.6). A multi-line paste into the field is handled the same way instead of being squashed into one line. There is one progress for the whole list, with the same count and Cancel as 4.9, and one summary; unsupported links are listed as skipped, with the reason (4.2). Requests run a few at a time under the shared pace (1.4), so Spotify and TIDAL don't start refusing them. Cost: a pasted list of several playlists can add thousands of tracks at once; the summary says how many.
- **B. Lists of links are refused.** "Paste one link at a time into the field." Clear, but slower.

**Why A.** It does what you obviously meant, reusing the link handling that already exists. If Spotify's desktop app copies one link per selected song (believed to; needs a live check), selecting a whole playlist and pasting it here would also get past the 100-track limit without Exportify (see 4.4).

**Touches your rules.** Keeps paste-anywhere (v0.1.25) and extends it to lists of links.

### 4.14 Spotify rows show Spotify's names, not the TIDAL track that will download

**Today.** You paste a Spotify playlist containing "Intro" by Placeholder Artist. That artist's Intro isn't in TIDAL's top 10 results, so "Intro" by Another Band is accepted on title alone (3.2). The row still reads "Intro — Placeholder Artist · Spotify", and you download Another Band's song as Intro.flac without a warning. In a milder case, Spotify's "Blue Lantern - 2011 Remaster" matches TIDAL's "Blue Lantern"; the row and the library check use Spotify's text, which doesn't match the "Blue Lantern" in your library, so you download a duplicate. Imported rows already show TIDAL's names, but never show which line of your list they came from.

**Choices**
- **A. Show and check the TIDAL track, with the original as a second line when different (recommended).** Rows show TIDAL's title, version (4.15), artists and length: the same text the file and its tags get, and the text the library check uses. When the source differs, a quiet second line shows it: "Spotify: Intro — Placeholder Artist", or for imports "From your list: Intro — Placeholder Artist", with Spotify's length so a big gap hints at a different version. Rows not found on TIDAL keep the original text. Cost: rows may not read exactly like your Spotify playlist where TIDAL spells things differently.
- **B. Show Spotify's text, check TIDAL's.** The display is unchanged; the library check uses TIDAL's names. The row and the saved file still disagree, and wrong-artist picks stay hidden.
- **C. Keep Spotify's names, warn when the artist differs.** A "Different artist on TIDAL" badge appears when the artists don't overlap. The row still doesn't show what the file will be called, and the library check still uses Spotify's names.

**Why A.** The queue is where you review before downloading, so it should show and check what will actually land on disk. Links and imports then behave the same, and the original wording stays on screen.

**Touches your rules.** Rule 3 (file name from TIDAL's title) is unchanged; A makes the row match it. Rule 4's library check now runs on what will be saved.

### 4.15 Versions and explicit tracks look identical in search and the queue

**Today.** You search "Blue Lantern". TIDAL has the album track, a radio edit and a clean (non-explicit) copy, but the results show three nearly identical rows reading "Blue Lantern — Placeholder Artist · Glass Orchard · 3:41", and you can't tell which is which before adding. Queue rows are just as ambiguous. The app never reads TIDAL's version field (2.7) or its explicit-lyrics flag.

**Choices**
- **A. Show the version and an explicit marker wherever a track is listed (recommended).** Search results and queue rows, from every source, show the version as quieter text after the title ("Blue Lantern  Radio Edit"), without repeating it when the title already contains it, and a small "E" for explicit tracks. Display only: whether matching prefers the version you asked for is 3.11, and whether the version joins the file name and title tag is 2.7. Cost: rows read slightly longer.
- **B. Version in the tooltip only.** Rows stay as short as today, but you hover each one to tell versions apart, and clean and explicit copies still look the same.
- **C. Keep today.** Versions stay invisible until you play the file.

**Why A.** You see which version you are adding before you add it, for a few extra words per row.

**Touches your rules.** Rule 3 (file name is <Title>.flac) is not changed here; 2.7 decides it.

**Needs a live check.** With a few real TIDAL track replies, confirm the explicit flag exists; the version field is checked in 3.11.

### Fixed without a decision

- **4.16 Imported rows get the Hi-Res badge.** Today: a song added from a CSV or pasted list never shows "Hi-Res", even when the same track added by link or search does; download quality is unaffected. In the Swift app: every way of adding builds the same row from the matched TIDAL track, Hi-Res flag included, with no extra request.
- **4.17 Encodings, delimiters and lists without a header.** Today: every file is read as UTF-8 text split at commas, so a playlist exported from Music (believed to be UTF-16 with tabs; needs a live check), an Excel CSV with accents ("Café" becomes "Caf�") or semicolons, and header-less lines such as "Blue Lantern, Placeholder Artist" import as junk or "not found" rows. In the Swift app: the text encoding (how letters are stored in the file) is recognised, with older Windows and Mac encodings as fallbacks; comma, semicolon or tab is picked from the first line, and any line ending works. A header-less file whose lines share 2-4 fields is read as columns, skipping a numbers-only column and choosing the order per line as in 4.6.
- **4.18 One add at a time.** Today: while a link is resolving, Return can start a second copy that runs on unseen and logs "+ Added 0 tracks from link.", a paste-import meanwhile removes the link's Cancel, and a second import is ignored silently. In the Swift app: while a link, search or import runs, the full-window progress you prefer blocks the keyboard as well as the mouse (Escape and ⌘. still cancel, but only that link, search or import, never a running batch), each job has its own Cancel, and a drop meanwhile (drags from other apps still arrive) gets "Already adding tracks from Late Ferry. Wait for it to finish or click Cancel."
- **4.19 The Exportify link only opens the website.** Today: clicking the Exportify link on the drop zone opens exportify.net and, at the same moment, the app's Open panel, because the click also reaches the drop zone. In the Swift app: the link you built in v0.1.25 becomes its own control beside the drop area, reachable by keyboard and VoiceOver (the Mac's built-in screen reader), and only opens the website.
- **4.20 Rows appear at once while the library scan finishes.** Today: right after launch, or after changing the library folder or pressing Refresh, a search, link or import shows only rotating funny lines until the whole library scan ends (about 18 seconds for 500 files), and nothing says the wait is the library. In the Swift app: results and rows appear as soon as TIDAL answers, with a quiet "Checking library…" badge until the scan finishes. Download All holds unchecked rows and says so ("Download All waits for the library check: 120 of 500 files"), so no row is ever sent unchecked and rule 4 holds; the saved library index (3.7) keeps the wait short.
- **4.21 Matching progress for Spotify and long TIDAL links.** Today: a 100-song Spotify playlist shows only rotating funny lines ("Digging through the record crates…") while it is matched, whereas a CSV of the same songs shows "Matching 34 / 100 tracks on TIDAL…", the count you added in v0.1.25; long TIDAL playlists give no count while their pages load. In the Swift app: the funny line stays for the first moments, then becomes "Matching 34 of 100 tracks on TIDAL…" once the Spotify list is loaded, and long TIDAL playlists show "Loading 300 of 1,250 tracks…"; Cancel stays as today.

---

## 5. Preview, sounds, updates and the switch-over

This area covers the waveform preview on each queue row, the app's sounds and jokes, how the app updates itself, and what happens to people and their files when v0.1.30 (the Electron app) hands over to the Swift 0.1.31. Items 5.8, 5.10, 5.11 and 5.17 matter once, at the switch; the rest is everyday use.

### 5.1 Waveform pre-loading downloads every queued song again at every launch

**Today.** To draw a row's 200-bar waveform, the app quietly downloads the whole CD-quality song (about 30 MB for four minutes), keeps only the bars in memory and discards the audio. It does this for every added track and, at every launch or window reopen, for the whole saved queue. Example: you import 40 tracks and about 1.2 GB downloads, greyed "already in library" rows included; reopen the app and it all downloads again; play "Blue Lantern" by Placeholder Artist and it downloads a second time; Download All fetches it a third. These downloads carry on for removed rows and slow a running batch, and if you're signed out with a saved queue the first one quits the app at launch (see 1.1).

**Choices**
- **A. Keep pre-loading, make it cheap (recommended).** Bars still appear before you press play, and are saved on disk (under 1 KB a track), so a reopened app paints the queue with no download. The pre-loader (the background fetcher) takes only rows on screen plus the next screenful, skips greyed rows until you click + Add, pauses during any batch, Download All or a retry (previews you click still play, see 1.4), forgets removed rows, waits for sign-in, stops when the window closes, and leaves tracks over about 20 minutes until you play them. What it fetched stays in 5.2's preview cache, so play starts at once. Cost: that cache (up to about 1 GB) fills with songs you haven't played, and in a big import the earliest drop out and download again when played.
- **B. Draw the bars from TIDAL's low-quality stream.** As A, but the bars come from TIDAL's lowest AAC tier (about 3 MB a song instead of 30), and the lossless file is fetched only when you press play. Cost: play is instant only if 5.2's early start works, and it needs a check that the low tier works and gives the same-looking bars.
- **C. On demand only.** Nothing downloads in the background; a row's bars appear the first time you play it, then stay saved. Cost: the least data, but it removes the waveform-before-play you built in v0.1.21.

**Why A.** It keeps what you built the pre-loader for, with no downloads at launch and one per track while the cache has room. Greyed rows show blank bars until you play or add them.

**Touches your rules.** The v0.1.21 pre-loader (built deliberately) is kept by A and B and removed by C, which was the port plan's earlier default. Greyed rows can still be previewed, so the library review is unchanged. Preview audio lives in the app's own Caches folder, never in your download folder (where a stray "<Title>.flac" would count as already downloaded) or your read-only library.

### 5.2 Pressing play waits for the whole song to download

**Today.** Previews never stream. Press play on "Night Ferry", a 6-minute track, and the button spins while the app downloads the whole CD-quality file (about 40 MB) into memory, then decodes all of it first if the bars aren't drawn yet: several seconds on a fast connection, much longer on a slow one (needs a live check). A song the pre-loader fetched a minute ago downloads again, and only the last 3 songs you played are kept, in memory, until you restart. Previews always use CD quality, even for tracks with a Hi-Res master.

**Choices**
- **A. Lossless preview, instant from a disk cache, earlier start where possible (recommended).** Previews stay CD quality. A song already fetched plays at once from a disk cache of about 1 GB in the app's Caches folder, which drops the oldest songs first and survives restarts; Settings gets Clear Preview Cache. Other songs start as soon as enough has arrived if macOS can play TIDAL's file while it downloads, otherwise right after the download, as today. Cost: up to 1 GB of disk, filled by pre-loaded songs with 5.1's A, or only by songs you played with 5.1's B; if macOS can't decode one of TIDAL's lossless formats, the bundled FFmpeg (the audio tool the app ships today) repackages the file first.
- **B. Stream a 320 kbps AAC preview.** Previews use TIDAL's high-quality AAC tier (lossy, like a good MP3), which macOS's standard player streams: sound within about a second on any row, a third of the data, and bars drawn from the same stream. Downloads are unaffected. Cost: what you hear in the preview is lossy, and it needs a check that TIDAL returns one streamable file at that tier.
- **C. Download, then play (today's behaviour).** Cost: a slow first play, and repeat downloads.

**Sub-choice.** When TIDAL has no Hi-Res master, should Download All reuse a complete cached preview, checked first as in 2.2, instead of downloading the song again? Recommended: no for now; one download path is simpler to trust, and this can be added later.

**Why A.** It keeps lossless listening, removes the second download and makes the common case, a pre-loaded row, instant. B is the fallback if the check shows lossless can't start early or decode reliably.

**Touches your rules.** Your quality rule (Hi-Res, then lossless, then .m4a) covers downloads, not previews. A keeps previews lossless at CD quality, as today; B would make them lossy, which is your call.

**Needs a live check.** Whether macOS's audio framework (AVFoundation) decodes TIDAL's plain FLAC files and its FLAC-inside-MP4 pieces, and can start a FLAC before the download finishes; for B, whether TIDAL's AAC tier returns one streamable file.

### 5.3 Preview volume comes back wrong after a restart, and sound effects can't be turned off

**Today.** The slider saves your position but shows its square at the next launch. Example: you set it to 50 and quit; it reopens showing 25 though you still hear the level you chose, and your first nudge treats 25 as the setting, so the sound drops to about a quarter (a fresh install shows 25 too). Reset Config, which says it only forgets your two folders, also resets the volume while the slider keeps its old position, and a change made in the last 0.3 seconds before quitting isn't saved. The chimes and honks ignore the slider, play at one fixed level and can't be turned off.

**Choices**
- **A. Fix both bugs; sound effects follow the Mac's sound settings, with a switch (recommended).** The slider shows exactly where you left it, with the same squared loudness curve, and Reset Config forgets only the two folders. The app's sound effects behave the way Mac feedback sounds usually do, following the alert volume and the "Play sound effects through" device in System Settings › Sound. Settings gets a "Play sound effects" switch, on by default. If the check below fails, the effects keep today's fixed level, still with the switch. Cost: one new switch.
- **B. Fix both bugs; fixed level, with the switch.** Cost: the effects ignore your Mac's alert volume and output device.
- **C. Fix both bugs; no switch.** Cost: the only way to silence the chimes is to mute the Mac.
- **D. Fix both bugs; one slider for previews and effects.** Cost: turning previews down quiets the cues too, and at 0 the effects vanish with no sign.

**Why A.** The two fixes are plain bugs. A switch is the usual Mac way to silence an app's own sounds, following the alert settings matches other Mac apps, and the sounds you built stay on by default.

**Touches your rules.** Keeps the sound effects you built deliberately, on by default. The new control is a plain native Settings switch, and it covers the easter eggs too (5.5).

**Needs a live check.** Whether the app's own sounds, played through macOS's sound-effect path, really follow the alert volume and output device.

### 5.4 The waveform swells under the pointer, against your hover rule

**Today.** Move the pointer over the waveform of "Paper Harbour": the 20 bars nearest it grow up to 45% taller (the loudest get cut off at the edges), and a thin light line follows the pointer. Only waveforms already drawn react. Three other things move: the volume knob grows 18% on hover, the round play button spins as a whole while a preview loads, and primary buttons shift down a pixel while pressed.

**Choices**
- **A. Light-only spotlight (recommended).** Bars keep their height. Unplayed bars near the pointer brighten (from 22% white toward about 60%, fading out over 10 bars), always staying clearly dimmer than played bars (100%) so progress stays readable. The thin line still follows the pointer as a seek marker, showing where a click will jump, as standard scrubbers do (see the first sub-choice). The volume knob stays still like a standard Mac slider; loading shows the system spinner (5.18) inside a button that doesn't move; and pressed buttons behave like native ones. Cost: the swell goes, and the reaction is subtler.
- **B. Keep the swell.** Cost: breaks your global rule; it would be recorded once as a deliberate exception.
- **C. Drop the spotlight.** Only the thin line follows the pointer. Cost: loses the playful reaction you built.

**Sub-choice.** The seek line moves with the pointer, which your rule "position may not" allows only with your OK: keep it? Recommended: keep it, because it shows where a click will land.

**Sub-choice.** Should every drawn waveform brighten under the pointer, or only the playing row's? Recommended: every drawn waveform, as today.

**Sub-choice.** Should the bars be drawn from the louder of the two stereo channels instead of the left one only? Recommended: yes; it looks the same for almost every song.

**Why A.** The waveform still answers the pointer, it follows "light may react, position may not", and the cut-off bars are gone.

**Touches your rules.** The v0.1.20 spotlight (built deliberately) conflicts with your global rule "nothing tilts, zooms or drifts on hover (light may react, position may not)". The seek line is the one piece of movement A keeps, which is why the first sub-choice asks for your OK.

**Needs a live check.** A side-by-side look at the light-only version and today's swell, seek line included, before you decide. This is a taste call that needs your eyes.

### 5.5 Which sounds, jokes and loading lines come along

**Today.** A rising two-note chime plays when Download All, Retry All or Retry Selected starts (a single row's Retry is silent), a falling chime on Cancel, three bells when the batch process ends normally, and a low "wronnng" honk when a download is refused (no download folder, not signed in, or nothing to download). Clicking the logo or name plays a joke fart, seven times higher on the version number; a clown horn exists but is never used; and ten music-themed loading lines rotate every 2.5 seconds while a link or search resolves. Sounds play before their action starts, and the bells ring even when tracks failed. Example: your Wi-Fi drops just after you start 12 tracks, all 12 fail, and you hear the success bells beside "Batch finished.", with only the summary line above it saying "12 failed".

**Choices**
- **A. Keep them all, make them honest, drop the clown horn (recommended).** Same notes and timing. 2.18 fixes when the start chime and the honk play; the end-of-batch sound follows 2.8 (bells only when nothing failed, and a cancelled batch plays only the cancel chime); every sound, the fart included, follows the "Play sound effects" switch (5.3); the fart moves to wherever the logo and version end up in the native window, at least the About window; and the ten loading lines stay. The unused clown horn isn't ported, but its exact recipe stays in the reference notes in case you want it back. Cost: small.
- **B. As A, but port the clown horn too, unused, for later.** Cost: a sound in the app that nothing plays.
- **C. Keep the useful cues, drop the jokes.** The chimes, bells and honk stay; the fart and the funny lines go, and loading reads "Looking up tracks…". Cost: removes personality you built on purpose.

**Why A.** These sounds are part of the app's identity and you built them on purpose; only the cues that mislead are defects.

**Touches your rules.** Keeps deliberately built features: the honk and start chime (v0.1.0), the cancel chime (v0.1.11), the bells and easter eggs (v0.1.21) and the loading lines. Your project CLAUDE.md keeps the clown horn "in case we want to repurpose", so dropping it (A) or keeping it (B) is your call. Where the easter egg lives is settled in the design pass.

### 5.6 Updates are installed without being checked

**Today.** At launch, or on Check for Updates in Settings, the app asks GitHub for the latest published release and takes the first file whose name contains "mac-arm64.dmg". Update now installs it with no checksum (a fingerprint proving a file is exactly the one published) and no check of the new app's name or version; macOS only catches a damaged download, not a swapped one. With no Mac file in a release, it downloads the release's web page and fails every time ("Download failed — retry" in the log, "Retry update" on the pill). The background script swaps the app after at most 30 seconds even if the old one hasn't quit, and a failed last step leaves the button on "Restarting…" forever. A new release shows only after a restart, and GitHub's limit of 60 checks an hour reads "Check failed", the same as being offline.

**Choices**
- **A. Your github-updater recipe, adapted to this repo (recommended).** It checks at launch, every 12 hours and after sleep, and tells "rate-limited" and "offline" apart from real errors. It downloads only the file it found itself, only from GitHub; checks its SHA-256 checksum; confirms the new app is robogears Downloader with a higher version; refuses an update it can't install and says why (5.20); keeps a backup, so a failed swap leaves you the working app and a message; and with no Mac file opens the release page in your browser. Logs stay in ~/Library/Logs/robogears Downloader/. Releases add a .zip for the updater, with checksums for the .zip only or in a SHA256SUMS.txt, never in a file whose name contains "mac-arm64.dmg" (5.17). Cost: a few hundred lines you own. A checksum next to the file proves it's undamaged, not genuine; tamper protection comes from 5.7's certificate, and only if you sign releases on your Mac.
- **B. Recipe plus a signature file.** Each release also carries a signature from a private key only you hold, which the app checks. It stops someone who takes over your GitHub account only if you sign on your Mac, not on GitHub's build service. Cost: a key to guard; lose it and installed copies refuse every update until people reinstall by hand. Redundant if 5.7's certificate is used and signed on your Mac.
- **C. Sparkle 2 (the standard Mac update framework).** A signed update feed, its own update window and partial downloads. Cost: a framework and a key to guard, with the same loss risk; its window replaces your one-click pill unless customised; and it needs a check that it works without a paid certificate.

**Why A.** It's your standard pattern for self-signed Swift apps, needs nothing beyond GitHub, keeps the one-click flow and closes every hole above.

**Touches your rules.** Keeps the v0.1.30 contract: the DMG's name never changes, so the recipe's versioned file names aren't used, and with a 5.7 certificate its ad-hoc re-sign after the swap is dropped. The never-auto-release rule is unaffected.

**Needs a live check.** Your updater test checklist on a Release build before the first public update: damaged file, missing file, rollback, staged app gone, and a launch from a translocated copy (see 5.15).

### 5.7 Each update may make macOS ask for permissions again (signing identity)

**Today.** The Mac app has no certificate. It's "ad-hoc" signed, meaning its only identity is a fingerprint of its own code, which changes with every version, and the updater re-signs each new version the same way. A first install from a downloaded DMG needs Open Anyway in System Settings › Privacy & Security; in-place updates don't. After an update macOS may treat the app as a new one and ask again for folder access (general macOS behaviour, not yet seen with this app): you update to 0.1.33 and the library scan shows a "would like to access files managed by Dropbox" prompt you allowed last week. Nothing is kept in the Keychain (macOS's encrypted password store) today; it would be if 1.5 puts the sign-in there.

**Choices**
- **A. Free self-signed certificate (recommended).** You create a code-signing certificate in Keychain Access, choosing "Let me override defaults" to set a long validity (the default is one year), plus an offline backup certificate the updater also accepts. Updates keep one identity, so folder permissions and Keychain access survive, and the updater refuses anything not signed with it (5.6) and never re-signs ad hoc. First installs still need Open Anyway. v0.1.30's updater re-signs the switch ad hoc, so the identity settles from 0.1.32 after one more round of prompts (with 1.5's A there is no Keychain prompt; with 1.5's B there is one). Sign releases on your Mac to be safe from a GitHub account takeover; signing on GitHub's build service is easier but loses that. Cost: free, but you guard the private key (exported, with its password in your password manager); lose both certificates and every user reinstalls once by hand.
- **B. Stay ad-hoc.** Cost: prompts may repeat on every update, the updater can only check checksums, and a sign-in kept in the Keychain would ask for your password after updates.
- **C. Paid Developer ID with notarization ($99 a year).** Apple's certificate plus its malware check: no Open Anyway, one identity, no Keychain prompts. Cost: $99 a year, secrets on the build service and a few minutes per release; stop paying and new releases can't be notarized.

**Why A.** It removes the repeated prompts and gives the updater a real authenticity check, for free. Whichever you pick, the switch itself causes one round of prompts.

**Touches your rules.** Money is your call: you have avoided the yearly fee so far ("works without paying $99/yr for Apple Developer"). It's the same certificate 1.5 relies on.

**Needs a live check.** On this Mac: the certificate signs the app and it opens after Open Anyway; a folder permission given to one build survives to the next; signing works on GitHub's Mac build machines, or you sign locally; the app still runs after the old updater's ad-hoc re-sign (true for every option); and what happens when the certificate expires.

### 5.8 Windows copies of v0.1.30 will try to install a web page

**Today.** Once a release with no Windows installer is published as Latest, every Windows copy of v0.1.30, and very likely of v0.1.24 to v0.1.29, finds no file containing "setup.exe" and takes the release's web page instead. The pulsing Update now pill and a "New version available: v0.1.31" log row appear; clicking either saves the web page as an .exe and tries to run it. Windows can't, and most likely the app stays open stuck on "Restarting…" until you quit it (needs a live check). Nothing installs, a stray file stays in the temp folder each time, and every launch offers the update again. Cached release data on this Mac shows the v0.1.30 Windows installer downloaded once.

**Choices**
- **A. A farewell Windows build, attached to every Swift release (recommended).** One last Electron installer built from v0.1.30's code, with update checks turned off and a line at launch saying Windows support has ended and this version keeps working. It's attached as robogears-downloader-setup.exe to v0.1.31 and every later release (one step in the ship checklist), so a Windows user who skips versions still gets it. The old app installs it silently; whether it reopens by itself is unverified. Windows settings, queue and sign-in are left alone, and the README and notes say support has ended, linking v0.1.30's installer. Cost: one build from the old Electron workflow, which runs on Node 20 (a JavaScript runtime GitHub retired on 16 Sep 2026) and may need updating first; one extra file per release, numbered 0.1.31 but not the Swift app.
- **B. Do nothing; remove your own Windows copy.** Releases are Mac-only. You uninstall the app and delete %APPDATA%\robogears Downloader\, which still holds your TIDAL sign-in. Reasonable if the download counts show the only Windows download was yours. Cost: anyone else loops on every Update click.
- **C. Re-attach the old v0.1.30 installer.** Cost: Windows copies reinstall v0.1.30 over itself and offer the update again, forever.

**Why A.** The repo is public and its README offers the Windows installer, so you can't be sure you're the only Windows user; one build ends the loop for everyone.

**Touches your rules.** Keeps your 21 Oct decision that Windows support ends; the farewell build only stops the old app misbehaving, and it reuses the Swift release's version number.

**Needs a live check.** First, read-only: how often the Windows installer was downloaded on each release from v0.1.24 to v0.1.30. For A, on a Windows PC: it installs silently over v0.1.30, and whether the app reopens. Copies from v0.1.23 and earlier pick up any file whose name contains ".exe"; what they do with the farewell file, or with a release that has none, is unchecked.

### 5.9 Two update buttons that can trip over each other

**Today.** When v0.1.32 is out, a white "Update now" pill next to the version pulses every 2.4 seconds while it can be clicked, and the activity log shows "🚀 New version available: v0.1.32" with "Download update". The pill downloads and restarts in one click; the log row takes two (Download update, then Restart to apply): the log notice dates from v0.1.3, and its two-click install from v0.1.7, for people who want to review before restarting. Clicking both downloads the update twice, and Check for updates in Settings resets a downloading pill, so a second click downloads again. Clearing the log, or passing 2000 log lines, removes the row; reopening the window from the Dock hides both controls until a restart; and neither shows what's new.

**Choices**
- **A. One updater in three places, with Install on Quit (recommended).** One update engine appears as a quiet toolbar control, only when an update exists ("Update to 0.1.32"), that downloads and restarts in one click with progress inside it and fades in once (about 200 ms) instead of pulsing; as Check for Updates… in the app menu; and in Settings › Updates, with the version, Check Now and an "Automatically check" switch. Check for Updates… and a What's New link open a small window with the release notes, Install and Relaunch, and Install on Quit (download now, install the next time you quit: the Mac version of your two-click flow). Update state lives in the app, not the window, so a reopened window still shows it. The log row goes, and restarting during downloads asks first (5.12). Cost: reviewing before restarting moves from the log into the What's New window.
- **B. Keep both styles on one engine.** The toolbar control plus the two-click log row; they can no longer download twice. Cost: two controls for one job, and the endless pulse.
- **C. Menu and Settings only.** No indicator in the window; once per new version, a standard "A new version is available" window. Cost: loses your one-click pill.

**Sub-choice.** Should the What's New window also offer Skip This Version? Recommended: no; the update control is quiet anyway, and skipping a version would also skip its fixes.

**Why A.** It keeps both the one-click flow and review-before-restart, adds the places Mac users look, and removes the races. Final placement is settled in the design pass.

**Touches your rules.** You built both controls deliberately: the log notice (v0.1.3) with its two-click install (v0.1.7, for reviewing before restarting), and the pill (v0.1.25, "for impatient users"); A keeps both flows in native form. The endless pulse conflicts with "motion is brief (about 150–300 ms)". The rocket emoji is allowed in log output by the project's CLAUDE.md, so dropping it with the row is a design choice, not a rule.

### 5.10 Mac users on macOS 11–14 who click Update lose the app

**Today.** v0.1.30 runs on any Apple Silicon Mac with macOS 11 or later (the installed copy declares 11.0 as its minimum); the Swift app is planned for macOS 15. The old updater doesn't check: it installs v0.1.31, deletes the old app and opens the new one. Example: a friend on macOS 14 clicks Update now, the app quits, and macOS says this version can't be used on this Mac (exact wording needs a live check). The old app is gone; their settings and queue are still on disk, so reinstalling v0.1.30 by hand brings it back, but it then offers the update at every launch.

**Choices**
- **A. Keep macOS 15+, and warn in the README, the notes and the release title (recommended).** Nothing changes in the app. The README and release notes say "Requires macOS 15 or later. On an older Mac, stay on v0.1.30 and don't click Update", with a link to v0.1.30's DMG, and the release title adds "Requires macOS 15", since people browsing GitHub see titles before notes. Cost: someone on an older Mac only sees the warning on GitHub; the in-app button gives none.
- **B. Lower the minimum to macOS 14.** Cost: rules out macOS 15 features that the design must then avoid, and macOS 11–13 users are still stranded.
- **C. Ship a bridge release first.** A last Electron v0.1.31 for Mac that offers no update below macOS 15, then the Swift app as v0.1.32. Cost: conflicts with your decision that the Swift app is 0.1.31, and needs one more Electron build.

**Why A.** It's a personal app on a current Mac, and the group at risk looks tiny (cached release data on this Mac shows the v0.1.30 DMG downloaded three times) and can recover by reinstalling. Revisit if the download counts suggest others use it.

**Touches your rules.** Your 21 Oct decisions: macOS only, and the Swift app at 0.1.31 (C conflicts). The macOS 15 minimum is the plan's default under "macOS only" and hasn't been confirmed separately: A confirms it, B changes it.

### 5.11 Old files, including the plain-text sign-in, stay on disk after the switch

**Today.** You decided the Swift app starts from scratch, so someone who clicks Update in v0.1.30 opens it to an empty queue, no folders and no TIDAL sign-in, with no explanation, because the old updater never shows release notes: the 23 songs you had queued are simply not there. The old files stay in ~/Library/Application Support/robogears Downloader/: settings.json, queue.json, token.json, the Chrome-extension leftovers, Electron's caches and cookies, and an update-cache.json written on 6 Oct by some build other than the installed v0.1.30. token.json holds every past TIDAL sign-in in plain text, including the part that renews it (1.8); any program running as you can read it, it lands in unencrypted backups, and nothing will ever remove it.

**Choices**
- **A. Explain once, with Show, Trash and a separate Delete Old Sign-in (recommended).** Only when the old folder exists, first launch says: "This is the new Mac app. Your old queue, folders and TIDAL sign-in weren't carried over. Sign in and choose your folders in Settings." Its buttons are Show Old Files; Move Old Files to Trash (only the known old files, by exact name, recoverable); and Delete Old Sign-in, which deletes token.json for good, because in the Trash it stays readable until you empty it (signing in again is all it costs). Nothing is touched without a click. The app's preferences file, which both apps share because they have the same identity on the Mac, and the unexplained update-cache.json are left alone; the Swift app uses its own setting names inside that shared file and keeps its own files in a separate folder, so it never reads or overwrites the old ones. Cost: one notice at first launch.
- **B. Delete only the old sign-in, automatically.** First launch deletes token.json, with the same notice and a log line saying so; everything else stays. Cost: deletes a file without asking, though it's a credential, not your data.
- **C. Tidy up automatically.** The old files go to the Trash at first launch, and the notice says so. Cost: moves files you didn't ask to move, and the sign-in stays readable in the Trash.
- **D. Offer to bring the old queue across.** "Add the 23 songs you had queued?" Cost: breaks your no-import decision.

**Why A.** It respects the fresh start, never moves or deletes anything without a click, and lets you remove the plain-text sign-in for good in one step.

**Touches your rules.** Your 21 Oct decision "start from scratch: no import" is kept by A, B and C; D breaks it. Data safety: settings and queue only ever go to the Trash, and only on your click; Delete Old Sign-in is a permanent delete you choose, of a credential that signing in recreates. Show Old Files and the Trash button assume the app isn't sandboxed (the plan's default). Pairs with 1.5, which decides where the new sign-in lives.

### 5.12 Update now restarts the app in the middle of a download batch

**Today.** Neither update control checks for a running batch. Example: 30 of 80 tracks are done and you click Update now; the batch keeps going while the update downloads, and half a second after the update is ready the app quits without stopping its download helper. What the helper does then is unverified: it may stop at its next progress line, leaving a temp file or, in the final step, a half-written "<Title>.flac" that later counts as downloaded (see 2.2). Finished rows come back in the queue at the next launch and are then skipped. In the Swift app downloads run inside the app itself, so quitting would cut the current track off mid-file.

**Choices**
- **A. Ask, with Update When Downloads Finish as the default (recommended).** If a batch is running, a sheet worded and laid out like 2.5's quit question asks "Update while 12 tracks are still downloading?" with "Updating now discards the track in progress. The others stay in your queue for next time." and the buttons Update When Downloads Finish (the default), Stop Downloads and Update, and Cancel. Waiting downloads the update now and restarts when the batch ends, also if you cancel it or it ends with failures; meanwhile the update control reads "Updates after downloads". Cost: one sheet.
- **B. Wait silently.** The control reads "Update after downloads" and stays disabled until the batch ends. Cost: you can't choose to stop the batch for the update.
- **C. Update at once, stopping cleanly.** No question; the track in progress is discarded and the rest stay queued. Cost: an accidental click costs that track and a second Download All.

**Why A.** Nothing is lost, and if you want the update right away you can still have it.

**Touches your rules.** Your one-click Update now pill (v0.1.25) stays one click whenever no batch is running; it asks only when downloads would be interrupted.

### 5.13 The play/pause key and Control Center during previews

**Today.** The preview plays through a hidden audio player inside Electron's built-in browser. Nobody knows whether the keyboard's play/pause key or Control Center's Now Playing panel (the media controls in the menu bar) controls it today; that browser sometimes registers itself there (needs a live check). A Swift app won't unless it's built in, so pressing play/pause while "Paper Harbour" previews would most likely leave the preview playing and start Apple Music as well.

**Choices**
- **A. Previews show in Now Playing (recommended).** While a preview plays, Control Center shows its title, artist and a small cover (fetched only while it plays), and the play/pause key pauses and resumes it. When the preview stops, the app steps back and the key goes to Music again. Because Control Center can stop it, a preview may keep playing after you close the window (5.16). Cost: small; the app briefly takes over the key, and each preview fetches one small cover.
- **B. Stay out of Now Playing.** The key always goes to Music, and the preview stops when the window closes. Cost: pressing the key to stop a loud preview starts Music instead.

**Why A.** It's the standard Mac behaviour for anything that plays audio, and the hardware key does what you expect.

**Touches your rules.** Follows your global rule on native macOS behaviour and keyboard support.

**Needs a live check.** What v0.1.30 does today, so the Swift app keeps or changes it on purpose, and whether macOS hands the key back to Music once the preview stops.

### 5.14 A row's waveform disappears while it downloads

**Today.** While a track downloads, its row hides the waveform and shows a thin progress bar, but the play button stays. Example: you press play on "Copper Sky" while it downloads and hear it with no position shown and no way to scrub. The waveform comes back when that track finishes, and the row is removed when the whole batch ends.

**Choices**
- **A. Keep the waveform, show progress beside it (recommended).** The bars stay visible and scrubbable while the row downloads, and download progress shows in the row's status text or a thin line that doesn't replace them. Cost: the row has to fit both; exact placement is a design-pass call.
- **B. Disable the preview while the row downloads.** The play button greys out until the track is saved. Cost: you can't listen to a track while it downloads, which you can today.
- **C. Today's behaviour.** Bars hidden, play still works. Cost: a preview you can't see or scrub.

**Why A.** It matches 1.4, where a preview you click still plays during a batch, and it hides nothing. Either way the preview stops when the row leaves the queue (5.16).

**Touches your rules.** Keeps the per-row progress bar (v0.1.10) and the inline waveform (v0.1.20), both built deliberately; only their arrangement changes.

### 5.15 Updates go to Applications while you keep opening an old copy

**Today.** If you open the app straight from Downloads or from the disk image, macOS runs it from a hidden read-only copy (App Translocation, a Gatekeeper safety measure). Update then installs the new version to /Applications/robogears Downloader.app and leaves the copy you opened untouched. If your Dock icon or habit points at the copy in Downloads, you keep opening the old version, which offers the same update at every launch and reinstalls it each time you click. v0.1.30 copies run from Downloads behave the same way at the switch, and that can't be changed.

**Choices**
- **A. Offer to move the app, and say where updates go (recommended).** At first launch from anywhere other than /Applications or ~/Applications, a sheet asks "Move robogears Downloader to the Applications folder?" with Move to Applications and Not Now, a common Mac pattern. The updater updates the copy that's running; when it must install somewhere else, it says where and shows the new copy in Finder. The README tells people to drag the app to Applications. Cost: one sheet for people who skipped the DMG's drag step.
- **B. No offer; only say where updates go.** Cost: people keep opening the old copy unless they read the message.
- **C. Today's behaviour.** A silent install to Applications. Cost: the loop above.

**Why A.** The DMG's install window already asks for the drag; the offer catches people who skip it, and the updater never silently leaves you on an old copy.

**Touches your rules.** None. The DMG's turntable install window (v0.1.15) is unchanged, and the move offer is a standard Mac pattern.

### Fixed without a decision

- **5.16 Exactly one preview player.** Today: two quick clicks (on two rows, or a double-click on one) start two downloads and both songs play at once; one then ignores the volume slider and no button can stop it, and a preview also keeps playing unseen after its row is removed or cleared while loading, or taken away by a finished batch. In the Swift app: there is only ever one preview, and pressing play elsewhere, or pressing the spinning button again, cancels the previous one's playback and its download at once, while the volume slider always controls what you hear. The preview stops when its row leaves the queue, when you sign out and when the main window closes, unless 5.13's Now Playing is chosen, in which case it may keep playing and Control Center stops it.
- **5.17 The switch-over checklist.** Today: every Mac copy of v0.1.30 (presumably every DMG-era copy since v0.1.17) takes the latest published release above 0.1.30, downloads the first file whose name contains "mac-arm64.dmg", copies out the first app inside, re-signs it ad hoc (stripping any certificate and entitlements, the extra permissions written into a signature) and opens it without showing release notes; today's release workflow would also rebuild the Electron app and leave the notes empty. In the Swift app: v0.1.31 is published by you as Latest, not as a pre-release; its robogears-downloader-mac-arm64.dmg (the same name in every later release) holds the app at the top level with no licence prompt; it keeps the name robogears Downloader and the bundle ID (the app's unique identifier) com.robogears.downloader and runs correctly after that ad-hoc re-sign; while old copies exist, no release carries any extra file whose name contains "mac-arm64.dmg", such as a checksum file named after the DMG; and a new Mac-only workflow puts the notes in. Steps that apply only if you choose them: attach the farewell Windows installer to every release (5.8); add "Requires macOS 15" to the release title, plus the warning in the README and notes (5.10); and add the README line about dragging the app to Applications (5.15). Before publishing, the old updater's steps are rehearsed by hand on a test copy, also as a standard (non-admin) user and from a copy in ~/Downloads, and afterwards we confirm v0.1.31 shows as Latest and that no unreleased build with a different updater (the one that wrote update-cache.json, see 5.11) is installed anywhere.
- **5.18 Keyboard and VoiceOver for previews.** Today: VoiceOver (macOS's screen reader) announces every row's play button as just "Play", even while it plays; the waveform can't be reached from the keyboard, so seeking needs a mouse; and the loading spin ignores Reduce Motion (the macOS setting that cuts animation). In the Swift app: buttons say "Play Preview of Blue Lantern" or "Pause Preview of Blue Lantern", and the waveform is an adjustable control that VoiceOver reads as "Preview position, 1:23 of 3:45", moved 5 seconds with Left and Right only when it has focus (Up and Down still move the selection) or with VoiceOver's adjust gestures. Space plays or pauses only when the queue has focus, never while you type in a field; Stop Preview is in the menu bar with a shortcut; and loading uses the system spinner, which respects Reduce Motion, with the exact keys settled in the design pass.
- **5.19 Plain preview errors with no private links.** Today: a failed preview puts the raw error in the activity log, such as "Preview: HTTP 403 for https://…" with the full signed TIDAL file link (a link that grants temporary access to the file) or TIDAL's raw reply, and nothing says what to do; a failed pre-load shows nothing, and the waveform just stays empty. In the Swift app: messages say what happened and what to do ("Couldn't load a preview of “Blue Lantern”: TIDAL didn't respond. Check your connection and try again.", "Sign in to TIDAL to preview tracks.", "TIDAL doesn't offer a preview of this track."), and a row whose waveform failed shows a quiet "Preview unavailable" with Try Again. Links and raw replies go only to a private debug log, which keeps just the site and path of each link, never its signed part, and the same applies to TIDAL's replies when your sign-in is renewed.
- **5.20 The updater never quits without reopening something.** Today: on a standard (non-admin) account with the app in /Applications, or with the app in any folder you can't change, Update now downloads the update and quits, then the background script fails to move the old app aside and stops without reopening anything, so the app vanishes with no message (a translocated copy with no access to /Applications installs nothing at all) and the next launch offers the update again. In the Swift app: the updater checks it can write to the app's folder before quitting and, if it can't, stays open with "robogears Downloader can't update itself because you don't have permission to change the Applications folder. Drag the downloaded new version to Applications, or ask an administrator." and a Show Downloaded Update button; once it does quit, it always reopens something, the new app or the restored old one. At the switch, which v0.1.30's code can't fix, the README and release notes get a line for standard-account users and the 5.17 rehearsal covers this case.
