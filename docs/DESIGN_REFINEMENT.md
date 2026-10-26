# robogears Downloader for Mac: refinement pass

_26 Oct 2026 · design lead pass after the owner's Debug build ("its looking good but lets also allow song preview on search and fix up the ui make it cleaner") · owner review pending._

**Authority, in order:** the owner's words → `docs/DESIGN.md` → `docs/DESIGN_DIRECTION.md` (21 Oct) → this document → the HIG pages cited here (read from the apple-design skill) → any skill default.

**What I looked at:** all 192 renders in `macos/build/snapshots-merged` (every row state at 980×740 and 720×540, empty states, adding, batch, summaries, sheets, alerts, Settings, About, Dock tile; Light, Dark, `-ic`), plus 2× crops of the row regions; `Design/`, `Views/Queue/TrackRow.swift`, `RowLineLayout.swift`, `Views/Waveform/WaveformView.swift`, `Views/Toolbar/MainToolbar.swift`, `Views/Sheets/SheetHost.swift`, `Views/Settings/SettingsWindow.swift`, `Model/RowPresentation.swift`, `AppModel*.swift`, `BatchSummary.swift`, `AlertContent.swift`, `DockProgress.swift`, `Snapshot/*`; `D4_BEHAVIOUR_DECISIONS.md` 2.16, 3.14, 4.10, 4.11, 4.15, 5.2, 5.4, 5.13, 5.14, 5.16, 5.18, 5.19. HIG pages read: accessibility, typography, color, layout, designing-for-macos, lists-and-tables, buttons, toolbars, sheets, alerts, settings, search-fields, focus-and-selection, pointing-devices, progress-indicators, branding, sf-symbols, dark-mode, context-menus, writing, labels, keyboards.

**One limit of the renders:** the harness window is never key (`SnapshotHarness.swift` line 108), so every render shows the inactive look: prominent buttons draw unfilled and the selected row is grey. "Download All" and "+ Add" are ink-filled in the running app. Checks on those stay live checks.

**What "cleaner" means here.** The identity stays: the pure black/white canvas, the waveform queue, 28 pt rows, the play circle, the owner's words. What goes is everything on a row that competes with the waveform for no information gained: outlined pills, icons beside grey words, buttons that only open Finder, a band of instruction text, and right-hand columns that end at a different x on every row.

---

## 1. Verdict

What already works and must stay untouched:

- **The canvas and the type.** Pure black / pure white content, system chrome above it, SF Pro 13 pt titles in medium, 12 pt secondary. `queue-ready-dark-980x740.png` is the app at its best: nothing but titles, waveforms and quiet meta. Don't touch the tokens in `Palette.swift` beyond the three changes below.
- **The waveform itself.** 200 square bars, played in full ink, unplayed at 22 %, light-only hover with the 1 pt cursor line, 2 pt progress line under a downloading row (`L-rows-top.png`: the Intro row is exactly right). The 26 Oct fix for narrow widths holds.
- **Row metrics.** 28 pt rows on a 30 pt pitch, 44 pt with a second line, 20 pt play circle in a 24 pt hit area. Measured on the crops, all correct.
- **The system parts.** Toolbar (field, update control, one primary action), `List` selection and context menus, sheets with Cancel and a default, alerts with one default and Cancel never default, Settings as a grouped Form with the pane name as the title, About as a plain window. All native, no custom chrome.
- **The copy.** Statuses say what happened and what to do; the summary never says "finished" when something failed; title case on controls, sentence case on messages. Keep every string unless named below.
- **Dark Settings and sheets** (`settings-folders-dark.png`, `sheet-search-results-dark.png`): system backgrounds, no black canvas leaking into chrome. Correct.

Overall: Good. The thesis (a quiet Mac list whose signature is the waveform) is there; what remains is restraint on the right-hand half of every row and a few places where a decoration survived the port.

---

## 2. Critique

Each item names the render and what is wrong in it.

**Main window rows**

1. **Nothing lines up on the right.** `queue-every-state-light-980x740.png`: the artist · length text ends at x≈1643 (Intro), 1504 (Blue Lantern), 1688 (Seven), 1412 (Northern Lights), 1094 (Late Ferry). The status column starts at 1535, 1716, 1548, 1230, 1619. Every waveform therefore ends somewhere different. The eye can't scan a column; the list reads as a pile of sentences. `layout.md › Visual hierarchy`: "Align elements to make them easier to scan … People assume that aligned items are related to each other." This is the single biggest reason the window reads as busy.
2. **Pill soup.** Same render, 2× crop `L-rows-top.png`: a hairline capsule around "Hi-Res" or "AAC" on 7 of 13 rows, each a 1 pt outlined shape at 10 pt tertiary text (4.5:1, the floor). Most tracks are Hi-Res, so the pill marks the common case with the loudest shape on the row. `typography.md › Ensuring legibility` puts 10 pt at the macOS minimum; there is no reason to spend the minimum on a word that could sit in the 12 pt meta line at 7:1.
3. **Icon beside every grey word.** `L-rows-top.png`, `L-rows-leftout.png`: clock + "Waiting", folder + "Already in your download folder", books + "In your library", person-with-badge + "Different artist on TIDAL", triangle + "Couldn't check…", minus-circle + "Left out by you". These are neutral grey statuses; the symbol adds nothing the words don't say, and nine different glyphs appear on one screen. `sf-symbols.md › Design variants` recommends symbols "alongside text" where they carry meaning; the coloured statuses (failed red, similar amber, done green) need theirs because colour must never be the only signal (`color.md › Inclusive color`). The grey ones don't.
4. **A button on every informational row.** `L-rows-leftout.png`: "Show in Finder" as a visible bordered button on "Already in your download folder" and "In your download folder". On a re-import of a 500-track playlist where 450 are already downloaded, that is 450 buttons. `pointing-devices.md › Best practices`: "Let people use the pointer to reveal and hide controls." The Remove × already follows that rule; Show in Finder should too. (Buttons that fix a problem — Retry, Search…, Match Again, Save As…, Replace, Try Again, + Add — are different: they sit on rare rows that need a decision and should stay visible.)
5. **The explicit mark is the heaviest thing on the row.** `L-rows-top.png` Intro and Glass Houses: a solid ink square with a white E, darker than the title. Apple Music draws this mark in the secondary grey. Judgement, not a guideline.
6. **Second lines turn the list ragged.** `queue-every-state-light-980x740.png`: 6 of 13 rows are 44 pt. Failure reasons and library notes earn the line; "Spotify: Satellite — Placeholder Artist" (D4 4.14) on a row whose artist already matches does not, and on a 120-track Spotify import it would appear wherever a title differs by "(feat. …)" or punctuation, which is most rows.
7. **At 720 the waveform becomes a smudge.** `queue-every-state-light-720x540.png`: Late Ferry's waveform is about 40 pt wide, Northern Lights' about 120; under ~100 pt the 1 pt columns merge into a grey blob that no longer reads as a waveform. The 26 Oct overlap fix is right; the remaining fix is to stop drawing below a useful width.
8. **Prominence rendered as colour, forty times.** `queue-every-state-light-980x740.png` shows "+ Add" unfilled only because the window isn't key; in the running app each left-out row carries an ink-filled button. `buttons.md › Style`: "Keep the number of prominent buttons to one or two per view." See open question 3.

**Queue header, add area, batch area**

9. **Two sentences of instructions above the content, always.** `L-header.png`: "Paste a Spotify or TIDAL link, or type a song name." on the left and "Drop a playlist CSV or paste tracks · Exportify" on the right, 28 pt tall, present whenever the queue has rows. The left one repeats the toolbar field's placeholder; the right one repeats the empty state. `writing.md › Getting started`: "Check each word to be sure it needs to be there." At rest, neither does.
10. **The header is right.** "Queue 24", the volume slider, Retry All Failed (N), Clear Queue, "37 of 120": one line, nothing extra. The batch bar beneath it is the system bar. Keep.
11. **Summary notices are right.** `summary-some-failed-dark-980x740.png`, `summary-stopped-cause-light-980x740.png`: one Surface box, symbol + sentence + buttons + ×, and the same "Retry All Failed (2)" name as the header. Keep. The Spotify cap notice using the same slot (`notice-spotify-cap-light-980x740.png`) is correct: one place for notices.

**Toolbar**

12. Correct as built: field, "Update to 0.1.32", one primary action; no gear, no glyph, no title (`toolbars.md › Titles`, `› Actions`). Nothing to change except the accent question (section 5).

**Empty states, adding cover**

13. `empty-ready-light-980x740.png`, `empty-signed-out-dark-720x540.png`, `empty-no-folder-light-720x540.png`: centred, 56 pt glyph, one title, one line, one button or the drop box. Quiet and right. The glyph as a solid InkTertiary disc is slightly heavy in Light; leave it, it is the one place the mark lives.
14. `adding-line-light-980x740.png`, `adding-count-dark-980x740.png`, `adding-reduce-transparency-light-980x740.png`: system material (opaque under Reduce Transparency), spinner, line, Cancel. Right.

**Search sheet**

15. `sheet-search-results-light.png`, crop `S-rows.png`: the first row's meta reads "Placeholder…" because the long library mark takes the width first; the mark column has no shared edge ("In Queue" ends at one x, "In your library" at another, "4:56" at a third). Same alignment problem as the queue, plus a checkbox per row that the queue doesn't have, and no way to hear a result before adding it (the owner's request).
16. `sheet-search-empty-dark.png`: fine. `sheet-pick-one-light.png`: fine apart from the same column problem.

**Sign-in sheet, What's New, old-files sheet, alerts**

17. `sheet-sign-in-waiting-light.png`, `sheet-sign-in-failed-dark.png`, `sheet-sign-in-signed-in-dark.png`: right. The 22 pt code is big on purpose (people type it).
18. `sheet-whats-new-light.png`: icon, headline, notes in a GroupBox, Skip leading, two install buttons trailing. Right.
19. `sheet-old-files-dark.png`: four buttons and three paragraphs; it runs once, and alerts hold only three buttons, so the sheet form is justified. The body could lose one clause (see 3.26).
20. Alerts (`alert-quit-during-batch-light.png`, `alert-update-during-batch-light.png`, `alert-reset-folders-dark.png`, `alert-sign-in-to-continue-dark.png`, `alert-large-import-light.png`): one default each, Cancel never default, titles that say what happens (`alerts.md › Buttons`, `› Content`). Right. `alert-check-up-to-date-light.png` is informational with OK, which `alerts.md` allows for that case.

**Settings**

21. `settings-folders-dark.png`, `settings-folders-not-chosen-light.png`: each folder is a path label plus two or three bordered buttons on their own line (Choose…, Show in Finder, Clear): seven buttons on one pane. Apple's own pattern for "which folder" (Safari › General › File download location) is one pop-up button showing the folder's icon and name, with Choose… inside it. Judgement; `settings.md › Best practices` asks only to "minimize the number of settings" and keep them approachable.
22. `settings-updates-light.png`: "made with love by robogears :)" at 10 pt tertiary (1.8:1) floats under the form in a colour no other text in Settings uses. See open question 2.
23. `settings-general-light.png`, `settings-tidal-light.png`, `settings-tidal-invalid-light.png`, `settings-updates-offline-dark.png`: right. The red problem lines use the app's one failure red with a symbol and words. Keep.

**About**

24. `about-light.png`: right; the signature is tertiary at 1.8:1 again (same fix as 22).

**Dock tile**

25. `dock-tile-42-percent-light.png`, `dock-tile-3-percent-light.png`: the track is black at 70 % on a black icon body, so it is invisible; at 3 % the tile shows a lone white dot. The bar's position (on the body, clear of the corners) is right since 26 Oct. See open question 4.

---

## 3. Refinement plan

Numbered; each gives the exact change, the file, the guideline, and what "done" looks like. Items marked **(owner to confirm)** restyle something the owner built or chose; each is one switch away from undoing.

### Main window rows

**3.1 Shared columns on the right (the big one).**
- *Change.* `RowLineLayout` stops giving artist and status their natural widths per row and instead reads two shared widths from the environment, `RowColumns(artist:status:)`, computed once per queue change in `AppModel` (in `queueDidChange()` and on batch `.started`/`.finished`/`.stopped`, never on a progress tick):
  - `artist` = widest artist line among the rows ("Coastline · 4:57 · Hi-Res", see 3.2), measured with `NSAttributedString.size()` at the row's callout font, clamped 80…240 pt. The text is **right-aligned** in that column, so lengths align on their last digit (`monospacedDigit` already).
  - `status` = widest (status text + 8 pt + action button) among the rows, clamped 0…260 pt; 0 when no row has a status. Status text is **leading-aligned** at the column's left edge; the action button sits at the column's right end; the × follows as today.
  - The waveform takes what is left between the title and the artist column; title-first truncation rule unchanged. Under 96 pt the waveform draws nothing and keeps its slot (3.7).
  - Measurement cache keyed by string; a 1,000-row queue measures a few hundred distinct strings in well under a millisecond.
- *Guideline.* `layout.md › Visual hierarchy` (alignment, grouping); `lists-and-tables.md › Content` (middle ellipsis for the title stays).
- *Done.* In `queue-every-state-light-980x740.png` every waveform's right edge is the same x (±1 px); every status text starts at the same x; every artist line ends at the same x; a queue of plain rows (`queue-ready-*`) has the artist line at the far right as today, because the status column is 0.

**3.2 Hi-Res / AAC as a word, not a pill (owner to confirm).**
- *Change.* Remove the capsule from queue rows: the quality joins the meta line as its last part, "Placeholder Artist · 4:09 · Hi-Res", in the same `.callout` InkSecondary (7.0:1 Light, 7.5:1 Dark). `QualityBadge` keeps a `style: .inline | .capsule` so the capsule returns with one line. Typography table: the badge row becomes the artist row.
- *Why.* Removes 7–10 outlined shapes per screen and raises the word from 10 pt at 4.5:1 to 12 pt at 7:1 (`accessibility.md › Vision`; `dark-mode.md › Dark Mode colors` asks for 7:1 on small custom text). The owner's words "Hi-Res" and "AAC" stay verbatim.
- *Done.* No capsule outline anywhere in `queue-*` renders; "· Hi-Res" visible at the end of the meta line on the Northern Lights row.

**3.3 Symbols only where colour needs them.**
- *Change.* In `RowPresentation.make`, statuses with `tone: .secondary` get `symbol: nil` (Waiting, Already in your download folder, In your download folder, In your library, Different artist on TIDAL, Couldn't check…, Left out by you, Preview unavailable). The spinner for "Checking library…" stays. Coloured statuses keep theirs: `exclamationmark.circle.fill` failed, `questionmark.circle` Not on TIDAL, `exclamationmark.triangle.fill` similar, `checkmark.circle.fill` done. Switch: `RowPresentation.neutralStatusesShowSymbols` (default false).
- *Guideline.* `color.md › Inclusive color` (colour never alone: the coloured ones keep words and symbol); `sf-symbols.md › Design variants` (symbols where they carry meaning).
- *Done.* The Seven row reads "Waiting" with no clock; the Glass Houses row still shows the red circle before "Failed".

**3.4 Show in Finder appears on hover and selection; fix-it buttons stay.**
- *Change.* In `TrackRow.actionButton`, `.showInFinder` follows the Remove button's rule (`opacity` + `allowsHitTesting`, 120 ms, instant under Reduce Motion) and is visible when `hovering || isSelected`. Its width is still reserved in the status column (3.1), so nothing moves on hover. All other actions stay visible at rest. It remains in the context menu, the Queue menu and the VoiceOver actions.
- *Guideline.* `pointing-devices.md › Best practices` ("reveal and hide controls"); `context-menus.md › Best practices` ("Always make context menu items available in the main interface, too": the selected row shows it).
- *Done.* Late Ferry and Afterglow rows show no button at rest; the hovered Blue Lantern row would show it if it had one; a selected "In your download folder" row shows it.

**3.5 Explicit mark in grey.**
- *Change.* `ExplicitMark` default fill `Palette.inkTertiary` (selected rows keep the selection text colour at 75 %, already there). Canvas-coloured E unchanged: white on #767676 is 4.5:1 at 9 pt bold (bold needs 3:1, `accessibility.md › Vision`).
- *Done.* The E on Intro and Glass Houses is lighter than the title, as in Music.

**3.6 Second lines only when they change a decision (owner to confirm, D4 4.14).**
- *Change.* `RowPresentation.sourceWording` returns a line only when the source artist differs from TIDAL's (case and diacritics folded) or the row is `differentArtist`; when only the title differs (feat., brackets, punctuation) the wording moves to the title's tooltip (`help`) and the VoiceOver label. Failure, clash, damaged, AAC and library lines are unchanged. Switch: `RowPresentation.sourceWordingInline`.
- *Done.* The Lanterns row in `queue-more-states-light-980x740.png` is 28 pt with "Spotify: Lanterns (feat. Sample Choir) — Sample Choir" in its tooltip; the Satellite row keeps its second line (different artist).

**3.7 No smudge: a minimum useful waveform width.**
- *Change.* `WaveformBars.layout` returns no bars when `size.width < 96`; the slot keeps its width so columns hold. Pressing the play button still plays.
- *Done.* At 720×540 no row shows a waveform narrower than 96 pt; a row either has a readable waveform or an empty slot.

**3.8 "+ Add" as a bordered small button at full strength on the dimmed row (owner to confirm; open question 3).**
- *Change.* `TrackRow.actionButton`: `.include` uses `.bordered` like the other row buttons; the row's 50 % dimming (title, waveform, meta) makes the full-strength button the brightest thing on that row without a fill. `inkProminent()` stays available behind a `Palette.prominentAdd` flag.
- *Guideline.* `buttons.md › Style`: one or two prominent buttons per view; `buttons.md › Style` also: "Use style — not size — to visually distinguish the preferred choice" — the contrast between a dimmed row and a crisp button is that style.
- *Done.* `queue-ready-light-980x740.png`: Slow Motion's "+ Add" has the same bezel as "Show in Finder" elsewhere, at full strength, on a 50 % row; Download All is the only prominent control in the window.

**3.9 VoiceOver names the track in preview controls.**
- *Change.* `PlayButton` label and tooltip: "Play Preview of Intro — Extended Mix" / "Pause Preview of …" / "Loading preview of …" (D4 5.18 asked for this; the code says "Play preview"). The row's custom action keeps "Play Preview".
- *Done.* Accessibility Inspector reads the title in the button's label.

### Queue header and batch area

**3.10 Nothing changes** in `QueueHeader`, `BatchSlot`, `SummaryNotice`. (The counter already carries "· waiting for TIDAL…", the summary and header already share the Retry name.)

### Add area

**3.11 The hint band appears only while it says something (owner to confirm; revises Q6).**
- *Change.* `AddArea` is 0 pt and absent at rest. It appears (28 pt, 150 ms ease-out; instant under Reduce Motion) while the Add field has focus **and** text, showing only the Return hint ("Press Return to add every track from this link." / "Press Return to search TIDAL for “blue lantern”."). The compact drop line goes; the owner's drop-zone words stay verbatim in the empty state, Exportify stays in Help › Open Exportify and in the Spotify cap notice, and the whole window still accepts drops with the 2 pt ink outline. Fallback switch: `AddArea.reservesHeightAtRest` keeps the 28 pt band empty at rest so nothing ever moves.
- *Guideline.* `writing.md › Getting started` (fewer words); `search-fields.md › Best practices` (placeholder text already tells people what they can enter).
- *Done.* `queue-ready-*`: the first row starts 28 pt higher, directly under the header; a new render `queue-typing-link-light-980x740.png` shows the hint while the field holds a link.

### Toolbar

**3.12 Prominent buttons use the system accent** (open question 1): remove `.tint(Palette.ink)` and `inkProminentLabel()`; plain `.borderedProminent`. Details in section 5.

### Empty states, adding cover, summary notices, alerts, sign-in sheet, What's New

**3.13 No change**, apart from the About and Settings signature (3.21, 3.22) and one copy trim in the old-files sheet (3.26).

### Search sheet

**3.14 Preview in search**: section 4 is the full design. In short: the sheet opens at 760×480 (min 640×360); rows get the queue's play circle and waveform; the list's own selection replaces the checkboxes; Space plays; the meta and mark columns share edges like the queue (3.1).

### Settings panes

**3.15 Folders: one pop-up button per folder (owner to confirm).**
- *Change.* `FolderRow` becomes `LabeledContent("Download folder") { Menu { Button("Show in Finder"); Divider(); Button("Choose…") } label: { Label { Text("TIDAL") } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile:)) } } }` with `.menuStyle(.button)` and `.fixedSize()`, the full path in the tooltip; "Not chosen" shows "Choose…" as the label. The library's pop-up adds "None" (what Clear did) under a divider. The "Library index" row with Refresh, the footers, the problem line and Reset Folders… stay. The separate Choose…/Show in Finder/Clear buttons go.
- *Why.* Safari › General › "File download location" is the Mac's own pattern; seven buttons become two controls. Judgement with a system precedent; `settings.md › General settings` ("general, infrequently changed settings").
- *Done.* `settings-folders-light.png`: two rows with a pop-up each, no button row; `settings-folders-not-chosen-light.png`: both pop-ups read "Choose…".

**3.16 General, TIDAL, Updates: unchanged** except 3.22.

### About and the signature

**3.21 About:** "made with love by robogears :)" in `.caption` `.secondary` (≈3.9:1, the same level as every secondary label Apple ships) instead of `.tertiary` (1.8:1). Everything else stays.

**3.22 Settings › Updates:** the signature becomes the footer of the Updates section (`Section { … } footer: { Text("made with love by robogears :)") }`), so it is set exactly like "Every download goes here directly — no subfolders." and "Read-only. The app reads audio tags and file names." Details in section 5, question 2.

### Dock tile

**3.23 Track white at 35 %** (open question 4): `DockProgressView.draw`: `NSColor.white.withAlphaComponent(0.35)` for the track; fill white; geometry unchanged.

### Activity panel (optional, taste call)

**3.24 Colour on the symbol only.** In `ActivityTextView.line(for:)`, the symbol keeps the kind's colour; the sentence uses Ink for results and InkSecondary otherwise. Today two full red monospaced lines dominate `L-activity.png`. The owner's rule "colour only for status" is satisfied by the symbol. Switch: `ActivityTextView.coloursWholeLine`. Not required for this pass.

### Copy

**3.25** Row tooltips for the moved source wording (3.6): "Spotify: Lanterns (feat. Sample Choir) — Sample Choir" verbatim.

**3.26** Old-files sheet body: "They aren't used: this version starts fresh, so your old queue, folders and TIDAL sign-in weren't carried over. You can move the old files to the Trash." (drops "Sign in and choose your folders in Settings.", which the empty state already says). Optional.

### Build order (bounded passes)

1. Pass A, rows: 3.1, 3.2, 3.3, 3.5, 3.7 (one lane: `RowLineLayout`, `TrackRow`, `RowPresentation`, `WaveformView`, `AppModel+Queue`). Re-render, check section 7 items 1–5.
2. Pass B, reveal and prominence: 3.4, 3.8, 3.9, 3.12, 3.11. Re-render, check 6–8.
3. Pass C, search preview: section 4. New renders, check 9–11.
4. Pass D, chrome: 3.15, 3.21, 3.22, 3.23, (3.6, 3.24 if confirmed). Check 12–14.

Each pass ends with a build, the renders, and one owner look; no polishing loops.

---

## 4. Song preview in search

**Where it lives.** `SearchResultsSheet` and `SearchResultRow` in `SheetHost.swift`; `AppModel+Preview.swift` for the player; `WaveformView` and `PlayButton` reused unchanged in look.

**The row** (28 pt, 30 pt pitch, same metrics as the queue):

```
◯  Blue Lantern — Radio Edit  E   ▂▃▅▇▆▃▂▁▂▄▆▇▅▃▂▁▂▃▅   Another Artist · Stand-in Sessions · 4:57 · Hi-Res   In your library
```

| # | Part | Rule |
|---|---|---|
| 1 | Play | The queue's `PlayButton` (20 pt ring, 24 pt hit), driven by a `PreviewTarget.result(tidalID)`. Loading: the mini spinner. Failed: dimmed to 40 % with the reason as tooltip and a log line; no status text in the sheet. |
| 2 | Title | Title medium + edition secondary + explicit mark (grey, 3.5). Fixed size, truncates in the middle last, as in the queue. |
| 3 | Waveform | The queue's `WaveformView`, 22 pt, flexible, nothing drawn under 96 pt. Same hover, press-to-seek, drag-to-skim, keyboard seeking. |
| 4 | Meta | "Artist · Album · 4:57 · Hi-Res", secondary, right-aligned in a shared column (widest among the results, 120…300 pt), tail truncation, full text in the tooltip. |
| 5 | Mark | Shared column (widest present): "In your library" (secondary, words only per 3.3), "Similar version in library" (amber, triangle + words), "In Queue" (secondary). Absent when none. |

**Sheet size.** Default 760×480, minimum 640×360, resizable (`sheets.md › Desktop (macOS)`: "Present a sheet in a reasonable default size … support resizing"). At 760 the waveform gets about 180 pt beside a typical title and meta; at 640 about 96, or the slot stays empty.

**Selection is the tick (owner to confirm; changes D4 4.11's "Space ticks the highlighted row").** The checkboxes go. The list is `List(selection:)` with multi-select in results mode (⇧ extends, ⌘ toggles, ⌘A selects every selectable row) and single select in pick-one mode, exactly like the queue. Rows "In Queue" are `selectionDisabled` at 60 % opacity. The footer reads "N selected"; **Add Selected** is the default (Return) and stays unavailable until a selectable row is selected; double-click adds that one row; Cancel (Escape, ⌘.) closes. This removes one control per row and frees Space for the preview, so the two lists behave the same way (`focus-and-selection.md › Best practices`: "use a highlight in a list or collection"). Fallback if the owner keeps checkboxes: Space keeps ticking; play is reached by clicking the circle, by Tab under Full Keyboard Access (row: play → waveform), and by Queue › Play Preview, which acts on the highlighted result while the sheet is key.

**Keyboard.** ↑↓ move the highlight; Space plays or pauses the highlighted result (`.onKeyPress(.space)` on the list, never bound as a menu key equivalent, so the Refine field keeps Space); ← → seek 5 s and ⇧← ⇧→ 30 s when the waveform has focus; Home/End; Return = Add Selected (or Use This Track); Escape and ⌘. = Cancel. Queue › Play Preview / Pause Preview / Stop Preview are enabled while the sheet is key and act on the highlighted result (`keyboards.md › Standard keyboard shortcuts`: Return and Escape keep their standard meanings).

**One player across queue and search.** `AppModel.nowPlaying` becomes `PreviewTarget?` with `.row(UUID)` and `.result(Int64)`; `startPreview`, `seekPreview`, `togglePreview` take a target; the existing generation counter and `stopPreview()` guarantee that starting a result stops a queue row and vice versa (D4 5.16). "Current" is compared by `tidalID`, so an "In Queue" result and its queue row show the same playhead and pause together.

**Peaks and loading.** On sheet open, `cachedPeaks(for:)` fills bars instantly for anything previously heard or queued; the rest pre-load through the existing pre-loader at the front of its queue (concurrency 2, paused during a batch like every pre-load; a clicked play still loads). Peaks go to the shared disk cache, so a result later added to the queue arrives with its bars. Closing the sheet cancels pending result pre-loads.

**What happens on close.** Cancel, Escape, ⌘.: the preview stops. Add Selected or Use This Track: if the playing result is among the added or chosen tracks, playback hands over to its new or replaced queue row (`nowPlaying = .row(newID)`) and keeps playing; otherwise it stops. Volume is the queue header's slider (one player, one volume); the sheet has no slider.

**Library and queue hits with a preview.**
- *In your library (exact):* full-strength row (the 50 % dimming is a queue state, not a result state), the mark in secondary words, preview available so the person can confirm it is the same recording; a pick still lands in the queue left out with "+ Add" (D4 4.11, rule unchanged).
- *Similar version in library:* amber mark with the triangle; preview available.
- *In Queue:* 60 % row, not selectable, preview live and mirrored with the queue row.

**VoiceOver.** Row: one element, label "Blue Lantern — Radio Edit, explicit, Another Artist, Stand-in Sessions, 4 minutes 57 seconds, Hi-Res, In your library", value "selected" when selected, "In Queue, unavailable" for queued results; custom actions Play Preview / Pause Preview, Add This Track (Use This Track in pick-one). Play button: "Play Preview of Blue Lantern — Radio Edit" / "Pause Preview of …" / "Loading preview of …". Waveform: label "Preview position", value "1 minute 23 seconds of 3 minutes 45 seconds", adjustable (increment and decrement seek 5 s), "Not playing" when it isn't the current track. Space and Return are announced by the system's own list and default-button semantics.

**Pick-one mode.** Same row, single selection, "Use This Track" default; the chosen track replaces the row in place and inherits the running preview.

---

## 5. The four open questions

**Q1. Download All and "+ Add" force the ink under any system accent.** *Recommendation: let the person's accent win; remove `.tint(Palette.ink)` and `inkProminentLabel()`, use plain `.borderedProminent`.* Why: `color.md › App accent colors`: when the person has chosen an accent, "the system applies their chosen color to the relevant items throughout your app, replacing your accent color." The list's selection highlight already follows that rule and cannot sensibly be forced to ink, so a forced ink button next to a purple selection puts two accents in one window, which breaks the owner's one-accent rule harder than the contrast figure does. Under Multicolor (the owner's Debug build, most likely) `AccentColor` is the ink and the button is black on white or white on black at 21:1, as designed. Under a chosen blue the label is white on #007AFF at 4.02:1, the same value as every default button on every Mac; the Increase Contrast setting switches system accents to their accessible variants automatically (`color.md › Best practices`), which the forced ink would have to reproduce by hand. It also removes a custom modifier on a standard control. One switch: `Palette.forcesInkProminence` (default false) re-applies `inkProminent()`. With 3.8 there is no second prominent control to worry about either way.

**Q2. The signature at 10 pt tertiary (1.8:1 Light).** *Recommendation: set it like a footer, not a watermark.* In Settings › Updates it becomes the section's footer (system secondary, the same style as "Every download goes here directly — no subfolders."); in About it becomes `.caption` `.secondary`. Numbers: macOS `tertiaryLabelColor` on white ≈ #BDBDBD, 1.8:1; `secondaryLabelColor` ≈ #808080, 3.9:1, which is the level of every footer and subtitle Apple ships in Settings and the level the system raises under Increase Contrast (`labels.md › Best practices`: "Use system-provided label colors to communicate relative importance"; `accessibility.md › Vision` sets 4.5:1 for information, and this line is decoration that should read like Apple's own secondary text, not disappear). The words stay verbatim, in both places. One switch: `Typography.signatureIsTertiary`.

**Q3. Every left-out row's "+ Add" is a prominent button.** *Recommendation: bordered small at full strength on the dimmed row (3.8), owner to confirm because he built the bright button.* `buttons.md › Style`: "Keep the number of prominent buttons to one or two per view"; a 500-track import can carry forty left-out rows. The dimming already does the work: a crisp bezel on a 50 % row is the brightest element there, and Download All stays the window's one prominent control. If the owner wants it filled, flip `Palette.prominentAdd` and record the exception once under 2.5 of the manual; note that under Q1's system accent a filled "+ Add" would be blue under a blue accent, forty times.

**Q4. The Dock progress track colour.** *Recommendation: white at 35 %, fill white, geometry as fixed on 26 Oct.* The icon's body is black, so a black 70 % track vanishes (`dock-tile-42-percent-light.png`) and 3 % reads as a stray dot. White at 35 % (#595959 over black) is 3.0:1 against the body, the non-text floor in `accessibility.md › Vision`, and the white fill on it is 8.5:1. `progress-indicators.md › Best practices`: a determinate bar needs a visible track to read as progress. One line in `DockProgressView.draw`.

---

## 6. DESIGN_DIRECTION.md updates

Quote → replacement. The first seven are the corrections handed back by the last fix round; the rest follow from this plan.

1. **3.3**, "Dock tile: the real icon with a determinate bar 10 pt tall, inset 14 pt from the sides and bottom of the 128 pt tile, track black at 70 %, fill white, radius 5." → "Dock tile: the real icon with a determinate bar 10 pt tall, inset 24 pt from the sides and 22 pt from the bottom of the 128 pt tile (on the icon's body, clear of its rounded corners), track white at 35 %, fill white, radius 5."
2. **4.10 table, Some failed row**, "Retry Failed (2) · Open Folder" → "Retry All Failed (2) · Open Folder".
3. **4.12 Folders row**, "[Reset Folders…] (asks: "Forget the download and library folders?" "Your TIDAL sign-in stays." [Cancel] [Reset])" → "[Reset Folders…] (asks: "Forget the download and library folders?" "Your TIDAL sign-in stays. Nothing in either folder is changed." [Cancel] [Reset]; Reset is the default and not styled destructive, because the person chose Reset Folders… on purpose and nothing on disk changes; Cancel answers Escape, `alerts.md › Buttons`)".
4. **4.9**, "`alerts.md › Buttons`: the default is the safe one; Esc = Keep Downloading." → "`alerts.md › Buttons`: the default is the safe one; Return = Keep Downloading; Quit has no key (Escape: live check)."
5. **4.12 General row**, "Notify When Downloads Finish (off)" → "Notify when downloads finish (off)". **4.11 Dock paragraph**, "plus a user notification only if "Notify When Downloads Finish" is on" → "plus a user notification only if "Notify when downloads finish" is on". **DESIGN.md line 80**, ""Notify When Downloads Finish" (off by default)" → ""Notify when downloads finish" (off by default)".
6. **Section 5, Stop Downloads row**, "⌘. is the standard cancel key; precedence: a sheet › the adding cover › the batch (only the frontmost cancellable thing responds)" → "⌘. is the standard cancel key; precedence: an alert › a sheet › the adding cover › the batch; the item is unavailable while a sheet or alert is up (their own ⌘. answers) and reads Stop Adding Tracks while an add runs".
7. **3.4**, "Geometry for a view of width W and height 22: bar pitch `p = W / 200`; bar width `max(1, p − 1)` (a 1 pt gap at W ≥ 400; at narrower widths bars touch, never overlap on whole-pixel grids: round the x origin of each bar to the backing pixel)." → "Geometry for a view of width W and height 22. From 200 pt up: one bar per peak, pitch `p = W / 200`, width `max(1, p − 1)` (a 1 pt gap at W ≥ 400), each x origin rounded to the backing pixel. Under 200 pt: one 1 pt bar per point, each drawing the loudest of its peaks, so bars touch and never overlap (overlapping alpha made an unplayed waveform look played). Under 96 pt: nothing is drawn; the slot keeps its width."

From this plan:

8. **2, Q4 row**, append: "Primary buttons carry no `.tint`: the system accent reaches the button and the list selection together, so the window never shows two accents; under Multicolor that accent is the ink."
9. **3.2**, "| Hi-Res / AAC badge | `.caption2.weight(.medium)` | 10 / medium | InkTertiary, Hairline capsule |" → "| Hi-Res / AAC | `.callout.monospacedDigit()` | 12 / regular | InkSecondary, the last part of the artist line ("Coastline · 4:57 · Hi-Res"); no capsule |".
10. **3.2**, "| Explicit mark | 9 pt bold "E" in a 12×12 pt, 2 pt-radius Ink square | 9 / bold | Canvas on Ink |" → "… InkTertiary square | 9 / bold | Canvas on InkTertiary |".
11. **3.2**, "| About: name / version / signature | `.title2` / `.body` / `.caption` | 17 / 13 / 10 | system label / secondary / tertiary |" → "… | system label / secondary / secondary |".
12. **3.3**, "Hi-Res / AAC capsule: padding 1 pt vertical, 5 pt horizontal, 1 pt Hairline stroke, full-round." → "Hi-Res / AAC: a word at the end of the artist line; no capsule."
13. **3.3**, "Row action button: system `.bordered`, `.controlSize(.small)` (about 20 pt tall); "+ Add" is `.borderedProminent` small." → "Row action button: system `.bordered`, `.controlSize(.small)` (about 20 pt tall), "+ Add" included, at full strength on its dimmed row. Show in Finder is visible on hover and on selected rows; every other action is visible at rest."
14. **3.3**, after the Row bullet, add: "Columns: the artist line and the status zone take one shared width each, measured across the queue (artist 80–240 pt, right-aligned; status 0–260 pt, leading-aligned, including room for the row's action button), recomputed when rows or states change and never on a progress tick; the waveform takes the remainder."
15. **3.4**, "Width rule: title first (`layoutPriority(2)`, fixed size), artist and status next (`layoutPriority(1)`, minimum 80 pt for the artist slot, then tail-truncate), waveform last (`minWidth: 0`, shrinks to nothing)." → "Width rule: title first (fixed size); the shared artist and status columns next (3.3); the waveform last, taking the remainder and drawing nothing under 96 pt. Only once the waveform is at 0 and the artist column at 80 pt does the title truncate, in the middle."
16. **4.3 AddArea paragraph**, replace with: "**AddArea.** Absent at rest (0 pt). While the Add field has focus and text, a 28 pt line appears (150 ms, instant under Reduce Motion) with the Return hint only: a link → "Press Return to add every track from this link."; text → "Press Return to search TIDAL for “blue lantern”." The drop-zone words live in the empty state; Exportify stays in Help › Open Exportify and the Spotify cap notice; the whole window still accepts drops and lights the outline."
17. **4.4 row 4**, "min 80, max 220, tail truncation, `layoutPriority(1)`" → "the shared artist column (3.3), right-aligned, tail truncation; ends with "· Hi-Res" or "· AAC" when known".
18. **4.4 row 5** (Quality badge) → remove; the quality is part of row 4.
19. **4.4 row 6**, "`Label` (symbol small + callout text) | max 200, tail truncation; full text in `help()` | Exactly one, from 4.5. The row's status line colour; never colour alone." → "callout text, with a small symbol only on coloured statuses and the spinner | leading-aligned in the shared status column; tail truncation; full text in `help()` | Exactly one, from 4.5. Coloured statuses always carry symbol and words; neutral statuses are words only."
20. **4.4 row 7**, "`.bordered` small (or `.borderedProminent` small for "+ Add") | natural | From 4.5. Absent when none." → "`.bordered` small, "+ Add" included | natural, reserved in the status column | From 4.5. Show in Finder on hover and selection; the rest at rest."
21. **4.4 second-line paragraph**, "… › source wording ("Spotify: Intro — Placeholder Artist")." → "… › source wording ("Spotify: Intro — Placeholder Artist"), shown only when the source artist differs from TIDAL's or the row is Different artist on TIDAL; otherwise it is the title's tooltip and part of the VoiceOver label."
22. **4.5 lead sentence**, "Symbol size `.small` beside 12 pt text; all symbols monochrome (`sf-symbols.md › Rendering modes`), coloured with the row's status colour." → "Symbols only on coloured statuses (Failed, Not downloaded, Not on TIDAL, Similar version, Done) and the Checking spinner; neutral grey statuses are words only. Symbol size `.small`, monochrome, in the status colour." In the table, the SF Symbol cell becomes "—" for Waiting, Already in your download folder, Couldn't check, In your library, Different artist on TIDAL, In your download folder, Left out by you.
23. **4.7**, replace the block with: "`.sheet`, 760×480, resizable (min 640×360). Title "Results for “Blue Lantern”"; a Refine search field; a `List(selection:)` of result rows: play circle · title with edition and explicit mark · waveform (22 pt, nothing under 96 pt) · "Artist · Album · 4:57 · Hi-Res" right-aligned in a shared column · library or queue mark in a shared column. Selection is the choice: ⇧ and ⌘ extend, ⌘A selects all; "In Queue" rows are unselectable at 60 %; "N selected" leads the footer; [Cancel] [Add Selected] (default; unavailable until a row is selected); double-click adds one. Space plays or pauses the highlighted result; Return never starts a preview. One player with the queue: starting a result stops a queue preview; Cancel stops the preview; Add Selected hands a playing result's preview to its new row. Pick-one mode: single selection, "Pick the TIDAL track for “…”", [Use This Track]; the chosen track replaces the row in place and inherits the preview."
24. **4.12 Folders row**, "Download folder: path, [Choose…] [Show in Finder]; … Music library folder: path, [Choose…] [Show in Finder] [Clear];" → "Download folder: a pop-up button showing the folder's icon and name (full path in the tooltip) with Show in Finder and Choose… ("Choose…" as the label when none); … Music library folder: the same pop-up, plus None;".
25. **4.12 Updates row**, "bottom-left, `.caption` tertiary: "made with love by robogears :)"" → "the section's footer, in the form's own footer style: "made with love by robogears :)"".
26. **4.13**, "“made with love by robogears :)” (caption, tertiary)" → "(caption, secondary)".
27. **Section 5, Play Preview row**, "a row is selected" → "a row is selected, or a result is highlighted in the search sheet"; the **Flag** text gains: "In the search sheet Space plays the highlighted result; selection is the choice, so Space has no second job there."
28. **Section 5, Keyboard in the queue paragraph**, append: "In the search sheet: ↑↓ highlight, ⇧↑↓ extend, ⌘A select all, Space preview, Return Add Selected, Escape Cancel; the Refine field keeps Space."
29. **Section 6, VoiceOver**, "The play button: label "Play preview" / "Pause preview"; loading: "Loading preview"." → "The play button: label "Play Preview of <Title>" / "Pause Preview of <Title>"; loading: "Loading preview of <Title>"."
30. **Section 7**, append the checks in section 7 below.

`DESIGN.md` row table, "Left out … **+ Add**, unchanged": the words and the control stay; add "(bordered, full strength on the dimmed row; owner's call whether it is filled)".

---

## 7. Pixel checks and taste calls

Re-render with `--snapshots` after each pass and compare these; "fail" means fix before the next pass. Items 1, 2 and 12 need the running app (key window).

| # | Render | Compare |
|---|---|---|
| 1 | `queue-every-state-light-980x740.png`, `-dark-` | Every waveform's right edge at one x (±1 px); every status text's left edge at one x; every artist line's right edge at one x; the Intro row's "42%" at that same left edge. |
| 2 | `queue-ready-light-980x740.png` | Status column 0 wide: artist lines end at the content's right edge exactly as in the 26 Oct render; "· Hi-Res" at the end of the Northern Lights line; no capsule anywhere. |
| 3 | `L-rows-top.png` crop (re-cut) | Explicit mark #767676 (Light) / #767676 (Dark); E white; 12×12 pt. |
| 4 | `queue-every-state-light-980x740.png` | Seven: "Waiting" with no clock. Late Ferry, Afterglow: no Show in Finder at rest; a selected Afterglow (new scenario `queue-selected-in-folder`) shows it. Glass Houses: red circle + "Failed" + Retry still visible. |
| 5 | `queue-every-state-light-720x540.png` | No waveform under 96 pt; empty slots instead; the Longest-Title row truncates in the middle only after the artist column is at 80 pt. |
| 6 | `queue-more-states-light-980x740.png` | Lanterns is 28 pt (source wording in its tooltip); Satellite keeps its second line. |
| 7 | `queue-ready-*` | No AddArea band: the header sits where the band was; new `queue-typing-link-light-980x740.png` shows the Return hint with a link in the field. |
| 8 | `queue-ready-light-980x740.png` (and live) | "+ Add" bordered, full strength on a 50 % row; under `-ic` no dimming, strikethrough only. Live: Download All is the only filled control; under a chosen blue accent the selection highlight and Download All are the same blue; under Multicolor both are ink. |
| 9 | `sheet-search-results-light.png`, `-dark-`, `-light-ic-` | 760×480; play circles; one result at 40 % with the pause glyph; hover pinned on another at 40 % with the cursor line; meta column one right edge; mark column one right edge; no checkbox; no "Placeholder…" truncation on row 1; "In Queue" row at 60 % and unselectable; footer "1 selected". |
| 10 | `sheet-search-narrow-light.png` (new, 640×360) | Waveforms ≥ 96 pt or empty slots; Add Selected still in view. |
| 11 | `sheet-pick-one-light.png` | Same row anatomy, single highlight, Use This Track. |
| 12 | Live, Accessibility Inspector | Play button reads "Play Preview of Blue Lantern — Radio Edit"; waveform "Preview position", adjustable; Space in the Refine field types a space; Space in the list plays. |
| 13 | `settings-folders-light.png`, `-not-chosen-`, `-dark-` | Two pop-up buttons with folder icons; no button row; "Choose…" as the label when none; Library index row and footers unchanged. |
| 14 | `settings-updates-light.png`, `about-light.png`, `-dark-`, `-ic-` | Signature set like the other footers; contrast ≥ 3.9:1 Light measured from the pixels; stronger under `-ic`. |
| 15 | `dock-tile-3-percent-light.png`, `-42-` | Track visible as a lighter bar on the black body (≈3:1); fill white; bar still inside the body's corners. |
| 16 | `adding-*`, `summary-*`, `alert-*`, `sheet-sign-in-*`, `sheet-whats-new-*` | Unchanged pixel-for-pixel apart from row changes behind them. |

**Taste calls that need the owner's eyes** (each is one switch, listed with its default):

1. "+ Add" bordered (recommended) vs ink-filled (`Palette.prominentAdd`).
2. "Hi-Res" as a word in the meta line (recommended) vs the hairline capsule (`QualityBadge.style`).
3. The hint band gone at rest (recommended) vs an always-reserved 28 pt band (`AddArea.reservesHeightAtRest`).
4. Show in Finder on hover and selection (recommended) vs always visible.
5. Neutral statuses without symbols (recommended) vs with (`RowPresentation.neutralStatusesShowSymbols`).
6. Source wording in the tooltip unless the artist differs (recommended) vs always a second line (`RowPresentation.sourceWordingInline`).
7. Search results chosen by selection with Space for play (recommended) vs checkboxes with Space ticking.
8. The system accent on prominent buttons (recommended) vs forced ink (`Palette.forcesInkProminence`).
9. Folders as pop-up buttons (recommended) vs the button rows.
10. Activity lines coloured on the symbol only (optional) vs whole-line colour.
11. The black selection bar in Light under Multicolor: keep (it is the ink accent) or soften; a live look, no code change proposed.

Nothing in this plan adds a screen or a top-level concept; the search sheet gains the queue's own preview, and every other change removes or aligns something that is already there.
