# robogears Downloader for Mac: design direction and build plan

_21 Oct 2026 · design lead pass over `docs/DESIGN.md` (21 Oct) · owner review pending._

**Authority, in order:** the owner's words → `docs/DESIGN.md` (the brief) → this document → the HIG pages cited here (read from the apple-design skill, cited as `file.md › Heading`) → any skill default. Where the brief or the owner's taste beats a guideline, it says so and the owner's choice stands.

**Sources read:** the brief; `docs/electron-reference/visual-design-and-copy.md` and `waveform-preview-and-sounds.md` in full; `renderer/index.html`; `build/icon.svg`; `docs/PORT_PLAN.md`; HIG: accessibility, layout, typography, color, dark-mode, designing-for-macos, windows, toolbars, the-menu-bar, keyboards, settings, lists-and-tables, sheets, alerts, menus, context-menus, buttons, sliders, search-fields, progress-indicators, loading, feedback, motion, sf-symbols, materials, branding, drag-and-drop, focus-and-selection, pointing-devices, undo-and-redo.

**Unverified by a run:** every pixel claim below is computed or drawn from the reference, not seen in a running Swift app. Section 7 is the list of what to look at.

---

## 1. Direction

The signature is the waveform queue: 200 ink bars in every row, played in full ink, unplayed at 22 percent, nothing else in the window drawn by hand. Everything around it is the Mac's own: a system title bar and toolbar, a system list with system selection, system sheets, alerts and Settings, SF Pro at 13 pt, SF Symbols where today there are emoji. The one thing the owner's identity keeps that the platform would not choose for us is the canvas: the content area under the toolbar is pure black in Dark and pure white in Light, with the ink the exact inverse. That is the only departure from the system palette, and it is confined to the content layer: chrome, Settings, sheets and alerts use the system's own backgrounds, exactly as a dark artwork area sits under Music's system toolbar.

Colour means one thing each: red is failed, not found or an error; amber is a similar version in the library; green is done. The ink is the accent, applied through the asset-catalog `AccentColor`, so the one prominent button, selection, progress and the focus ring are ink when the person's accent is Multicolor, and the person's own accent when it is not (`color.md › App accent colors`). Hover is light only: a row's background rises one step, bars near the pointer brighten, nothing grows or moves. Motion is 120 to 200 ms, rare, and absent under Reduce Motion.

Deliberately not done: no sidebar, tabs or inspector (the app has one job); no panel, card or rounded "queue box" around the list (the rows sit on the canvas); no tinted badge pills, no uppercase tracked captions, no dashed drop box, no pulse on the update control, no spinning play button, no home-made blur, no red Stop button, no Settings gear in the toolbar, no logo in the toolbar, no second update notice in the log, no 44 pt targets, no app-level appearance switch, no custom window chrome, no checkboxes inside rows.

## 2. Answers to the brief's eight open questions

Each is a recommendation; the owner confirms. "Default" means what gets built if he says nothing.

| # | Question | Recommendation | Why (one line) |
|---|---|---|---|
| 1 | Row height | **28 pt rows, 30 pt pitch (1 pt inset top and bottom), growing to 44 pt only when the row carries a second line** (failure sentence, library note or source wording). | The owner's 24–28 pt rule; today's two-line rows spend height on information that fits one line at Mac widths. |
| 2 | Activity | **A collapsible bottom panel** (resizable split, default 160 pt, View › Show/Hide Activity), with SF Symbols instead of emoji. Not a window, not an inspector. | Log lines are wide monospace sentences; a 300 pt inspector wraps them and a separate window loses the glance-down habit. The HIG's warning about bottom bars (`windows.md › Desktop (macOS)`: "Avoid putting critical information or actions in a bottom bar") is met because nothing critical lives only there: failures show on rows and in the summary. |
| 3 | Brand glyph and joke sound | **About window and the empty queue only.** The glyph is a template image (ink) at 56 pt above the empty-state message; clicking it plays the joke, clicking the version string in About plays the 7× one. Never in the toolbar. | `branding.md › Best practices`: "Resist the temptation to display your logo throughout your app"; the empty state is the one screen with no content to defer to, and About is where a version lives. |
| 4 | Accent | **`AccentColor` = the ink (black in Light, white in Dark). Let the person's own accent win when they have chosen one.** Primary buttons use `.borderedProminent`, never a custom style. | Under Multicolor the system reproduces today's white-filled buttons with standard controls; forcing ink under a chosen accent would need custom buttons (on the owner's avoid list) and overrides a choice the person made. First item on the pixel list: the selected row and the prominent label must stay legible with an ink accent in both appearances. |
| 5 | New switches | **Add a General pane first: General · Folders · TIDAL · Updates.** General holds Play sound effects, Notify When Downloads Finish, Clear Preview Cache (with its size). Needs the owner's OK because it changes his three tabs. Fallback if he declines: the three controls go to the bottom of Folders under a "Downloads" group. | Three unrelated switches have no home in Folders, TIDAL or Updates; `settings.md › Desktop (macOS)` wants panes that group related settings, and General is where Mac users look first. |
| 6 | Drop zone | **Full-size only while the queue is empty; one compact line once rows exist.** The whole window is the drop target either way; a drag over the window lights the content area with a 2 pt inset ink outline. | The queue is the signature and needs the height; the zone's words stay verbatim, so nothing the owner loves is lost. |
| 7a | Failed-row checkboxes vs native multi-select | **Native multi-select.** ⇧ and ⌘ clicks in the list; the header button reads "Retry Selected" when any selected row has failed, otherwise "Retry All Failed (N)". | A Mac list already has selection; two selection models in one list confuse keyboard and VoiceOver users (`focus-and-selection.md › Best practices`: "use a highlight in a list or collection"). |
| 7b | The moving cursor line | **Keep the 1 pt cursor line; drop the bar swell.** Bars within ten of the pointer brighten from 22 % toward 60 %; no bar changes height. | The owner's rule: light may react, position may not; the line is light, the swell was growth. |
| 8 | Escape | **⌘. and the Stop Downloads button only.** Escape still closes sheets and the adding cover. | Escape is a reflex key; an hours-long batch deserves a deliberate one. `keyboards.md › Standard keyboard shortcuts` lists both Esc and ⌘. as "Cancel", so the owner's choice is within the guideline. |

Two more calls the brief left implicit, decided here, owner to confirm:

- **Stop Downloads is a plain bordered button, ink label, no red.** The brief's rule "colour only for status" wins over today's red Cancel; a control is not a status.
- **The log's update notice goes.** One update control (toolbar) plus the menu item, as the brief's table says.

## 3. Tokens

### 3.1 Colours (asset catalog, each with Light, Dark and High Contrast variants)

Contrast is WCAG, computed from the hex, against the canvas of the same appearance. Targets: text 4.5:1, small text aiming at 7:1 under Increase Contrast, non-text 3:1 (`accessibility.md › Vision`; `dark-mode.md › Dark Mode colors`).

| Asset name | Role | Light | Dark | Light + Increase Contrast | Dark + Increase Contrast | System colour that fits | Contrast (L / D / L-IC / D-IC) |
|---|---|---|---|---|---|---|---|
| `Canvas` | Content background of the main window only | `#FFFFFF` | `#000000` | `#FFFFFF` | `#000000` | Light equals `controlBackgroundColor`; Dark deliberately departs from it (owner's identity, recorded under 2.5 of the manual) | — |
| `Ink` | Titles, bars (played), the glyph, primary text | `#000000` | `#FFFFFF` | same | same | Not `labelColor` (that is 85 % alpha in Dark; the brief wants stark white) | 21 / 21 |
| `InkSecondary` | Artist, length, hints, neutral statuses, counts | `#595959` | `#9A9A9A` | `#3D3D3D` | `#C8C8C8` | Plays the role of `secondaryLabelColor` on the custom canvas | 7.0 / 7.5 / 10.9 / 12.5 |
| `InkTertiary` | Second lines, placeholders, idle play glyph, Remove glyph, badge outlines | `#767676` | `#767676` | `#595959` | `#9A9A9A` | Plays the role of `tertiaryLabelColor` | 4.5 / 4.6 / 7.0 / 7.5 |
| `Hairline` | Row-hover separators, badge capsule stroke, empty-state drop outline, play-button ring | `#D9D9D9` | `#262626` | `#8A8A8A` | `#5E5E5E` | Plays the role of `separatorColor` | 1.4 / 1.4 / 3.5 / 3.2 |
| `Surface` | Row hover, notice background | `#F2F2F2` | `#111111` | `#EBEBEB` | `#1A1A1A` | — | — |
| `Surface2` | Progress track, pressed state of custom hit areas | `#E0E0E0` | `#1F1F1F` | `#D6D6D6` | `#2E2E2E` | — | — |
| `AccentColor` | The app accent (prominent buttons, selection, progress, focus ring when the person's accent is Multicolor) | `#000000` | `#FFFFFF` | same | same | `controlAccentColor` is derived from this by the system | — |
| `StatusFailed` | Failed, Not on TIDAL, clash, damaged, error lines in the log | `#C62828` | `#FF6B6B` | `#9B1C1C` | `#FF8A8A` | The system red family at accessible strength; not `.red` because system red on white is about 3.6:1 at 12 pt | 5.6 / 7.6 / 8.1 / 9.3 |
| `StatusSimilar` | Similar version in library, warning lines | `#9A6700` | `#FCD34D` | `#7A5200` | `#FCD34D` | Amber family; Dark keeps today's value | 4.9 / 14.5 / 6.9 / 14.5 |
| `StatusDone` | Done, saved lines | `#1A7F37` | `#86EFAC` | `#0F5E27` | `#86EFAC` | Green family; Dark keeps today's value | 5.1 / 15 / 7.9 / 15 |
| `WaveUnplayed` | Unplayed bars | `Ink` at 22 % | `Ink` at 22 % | `Ink` at 45 % | `Ink` at 45 % | — | 1.7 / 1.8 / 3.4 / 4.4 |
| `WaveHoverMax` | Bar under the pointer | `Ink` at 60 % | `Ink` at 60 % | `Ink` at 80 % | `Ink` at 80 % | — | — |
| `WaveCursor` | 1 pt pointer line | `Ink` at 55 % | `Ink` at 55 % | `Ink` at 80 % | `Ink` at 80 % | — | — |

Everything outside the main window's content area (title bar, toolbar, Settings, sheets, alerts, popovers, the About window, menus) uses system colours untouched. Status colours are always paired with a symbol and words (`color.md › Inclusive color`). Nothing else in the app is coloured.

### 3.2 Type

SF Pro throughout; SF Mono only in the activity panel, the sign-in link and the short code (`typography.md › Platform considerations › Desktop (macOS)`; built-in text styles table). No light weights, nothing below 10 pt.

| Use | Style | Size / weight | Colour |
|---|---|---|---|
| Row title | `.body.weight(.medium)` | 13 / medium | Ink |
| Edition suffix ("— Extended Mix") | `.body` | 13 / regular | InkSecondary |
| Artist · length | `.callout.monospacedDigit()` | 12 / regular | InkSecondary |
| Status text | `.callout`; symbol `.imageScale(.small)` | 12 / regular | status colour or InkSecondary |
| Second line | `.subheadline` | 11 / regular | InkTertiary |
| Hi-Res / AAC badge | `.caption2.weight(.medium)` | 10 / medium | InkTertiary, Hairline capsule |
| Explicit mark | 9 pt bold "E" in a 12×12 pt, 2 pt-radius Ink square | 9 / bold | Canvas on Ink |
| Queue header "Queue" | `.headline` | 13 / bold | Ink; the count beside it `.body` InkSecondary |
| Batch counter "37 of 120" | `.callout.monospacedDigit()` | 12 | InkSecondary |
| Add-area hint | `.callout` | 12 | InkSecondary |
| Empty-state title | `.title3.weight(.semibold)` | 15 / semibold | Ink |
| Empty-state body, drop hint | `.body` | 13 | InkSecondary; the Exportify link underlined Ink |
| Notice text | `.body` | 13 | Ink |
| Activity lines | `.system(size: 12, design: .monospaced)` | 12 | InkSecondary; results Ink; errors StatusFailed; warnings StatusSimilar; debug InkTertiary |
| Activity header | `.subheadline` | 11 | InkSecondary |
| Sheet title | `.headline` | 13 / bold | system label |
| Sheet body, Settings | `.body`, `Form` defaults | 13 | system label |
| Short code in the sign-in sheet | `.system(size: 22, weight: .medium, design: .monospaced)` | 22 | system label |
| About: name / version / signature | `.title2` / `.body` / `.caption` | 17 / 13 / 10 | system label / secondary / tertiary |
| Tooltips, toolbar, buttons, menus | system defaults | 13 | system |

### 3.3 Spacing, radii, sizes

- Window: opens 980×740, minimum 720×540 (brief). Content side inset 20 pt; vertical gap between stacked regions 12 pt.
- Row: 28 pt tall; `listRowInsets` top 1, bottom 1, leading 8, trailing 8 (pitch 30 pt). Inner gaps: 8 pt after the play button, 10 pt around the waveform, 10 pt between artist and badge, 8 pt between status and action, 8 pt before Remove. Two-line rows: 44 pt; the second line starts under the title's leading edge.
- Waveform: 22 pt tall, vertically centred in the row.
- Play button: 20×20 pt visible (1 pt Hairline ring; `play.fill` at 10 pt), 24×24 pt hit area. Remove: `xmark` at 11 pt, 20×20 pt hit area. Minimum control size on macOS is 20×20 pt (`accessibility.md › Mobility`).
- Row action button: system `.bordered`, `.controlSize(.small)` (about 20 pt tall); "+ Add" is `.borderedProminent` small.
- Hi-Res / AAC capsule: padding 1 pt vertical, 5 pt horizontal, 1 pt Hairline stroke, full-round.
- Toolbar Add field: 320 pt minimum, 560 pt maximum, system `.roundedBorder`.
- Queue header: 28 pt tall; volume slider 80 pt wide, `.controlSize(.small)`.
- Batch slot (under the header): a system linear `ProgressView` (default height) during a batch; the summary notice (44 pt, Surface fill, 1 pt Hairline border, 6 pt radius) after it; empty otherwise.
- Activity panel: default 160 pt, minimum 72 pt, collapsible to 0 via the divider or the View menu; header 24 pt.
- Empty state: content centred, maximum width 420 pt; glyph 56 pt; drop hint box 1 pt Hairline, 8 pt radius, 16 pt padding (never dashed).
- Drag-over highlight: 2 pt inset Ink outline on the content area, 6 pt radius.
- Progress line on a downloading row: 2 pt tall across the row's full width at its bottom edge, Ink on Surface2.
- Radii: system for every system control; 6 pt notices and drag outline; 8 pt empty-state box; 2 pt explicit mark; bars square-cornered.
- Dock tile: the real icon with a determinate bar 10 pt tall, inset 14 pt from the sides and bottom of the 128 pt tile, track black at 70 %, fill white, radius 5.

### 3.4 Waveform drawing spec

- Input: 200 peaks in [0, 1], loudest bar exactly 1 (today's normalisation). Channel 0 only, as today (owner may change; see the reference's open question 11).
- Geometry for a view of width W and height 22: bar pitch `p = W / 200`; bar width `max(1, p − 1)` (a 1 pt gap at W ≥ 400; at narrower widths bars touch, never overlap on whole-pixel grids: round the x origin of each bar to the backing pixel). Bar height `max(1, peak × 22 × 0.78)` (so 1 to 17.2 pt), centred on y = 11. Square corners.
- Played test: bar i is played when `(i + 0.5) / 200 ≤ progress`. Played bars are Ink at 100 %; unplayed are `WaveUnplayed`.
- Hover (pointer inside the view, not scrubbing): bars with `|i − hoverBar| < 10` take alpha `0.22 + (0.60 − 0.22) × (1 − d / 10)` (linear falloff from 60 % under the pointer to 22 % at ten bars), where `hoverBar = hoverFraction × 200 − 0.5` (centred on the bar under the pointer, correcting today's half-bar offset). Played bars never dim. A 1 pt `WaveCursor` line at `floor(hoverFraction × W) + 0.5`, from y = 2 to y = 20. No bar changes height. Hover state changes paint immediately (0 ms).
- Selected row: bars and cursor use the row's selection text colour instead of Ink, same alphas.
- Downloading row: the waveform stays and keeps playing (brief D4 5.14). Rows that cannot preview (Not on TIDAL, Couldn't check) draw nothing in the waveform slot; the slot keeps its width so columns stay aligned.
- Before peaks arrive: nothing is drawn (no placeholder bars, no shimmer). Pressing starts playback anyway.
- Width rule: title first (`layoutPriority(2)`, fixed size), artist and status next (`layoutPriority(1)`, minimum 80 pt for the artist slot, then tail-truncate), waveform last (`minWidth: 0`, shrinks to nothing). Only once the waveform is at 0 and the artist slot at 80 pt does the title truncate, in the middle (`lists-and-tables.md › Content`: a middle ellipsis keeps both ends of an item recognisable).
- Pointer: left button only. Press on the current track (playing or paused) seeks; drag skims while audio keeps playing; press on another row starts that track at the pressed fraction; seeking never pauses; the fraction clamps to 0…1; release outside the view clears the hover state. AppKit keeps delivering the drag to the view that got the mouse-down, so the session cannot latch. Right-click opens the row's context menu and never seeks.
- Keyboard (view focused under Full Keyboard Access or after a click): ← → seek 5 s, ⇧← ⇧→ seek 30 s, Home and End to 0 and the end, Space toggles play. VoiceOver: an adjustable element, label "Preview position", value "1:23 of 3:45", increment and decrement seek 5 s.
- Playhead refresh: `TimelineView(.animation)` on the one playing row only, at the display rate; stops when paused or when the row leaves. The repaint touches only that row's view; the list is never rebuilt on a tick (brief, Real facts).
- Peaks cache: `~/Library/Caches/com.robogears.downloader/peaks/<tidalId>.bin` (200 × Float32 = 800 B); audio LRU of 3 temporary files; tracks over 20 min are not pre-loaded (brief).

### 3.5 Motion

All durations are the whole animation; curves are `easeOut` unless stated. Under Reduce Motion (`accessibilityReduceMotion`), the "RM" column applies; system components adapt themselves (`motion.md › Best practices`: "Make motion optional").

| Moment | Spec | RM |
|---|---|---|
| Row hover background, play and Remove glyph colour | 120 ms colour only | instant |
| Waveform hover brightening and cursor line | 0 ms (follows the pointer) | same |
| Row removal (Remove, Clear Queue, rows leaving after a batch) | 150 ms fade and collapse (List default with `withAnimation`) | instant |
| Row insertion | none | none |
| Per-row progress line, batch progress bar | width 150 ms linear per update | jumps |
| Batch counter and "Download (47)" numbers | `.contentTransition(.numericText())`, 200 ms | swap |
| Update control appearing | one 200 ms fade in, never repeated, no pulse | appears |
| Adding cover in and out | 150 ms fade of the material | appears |
| Loading lines | swap every 2.5 s with a 150 ms crossfade | hard swap |
| Status change on a row (Waiting → Downloading → Done) | symbol `.contentTransition(.symbolEffect(.replace))`, 200 ms | swap |
| Play button loading | the glyph is replaced by a small system spinner; the button does not rotate | spinner obeys the system |
| Sheets, alerts, Settings, menus, focus ring, selection | system | system |
| Anything on hover that scales, tilts, lifts or drifts | never | never |
| Anything endless (pulse, breathe, glow) | never | never |

## 4. Structure

### 4.1 Scenes and view hierarchy

```
@main struct DownloaderApp: App
├── Window("robogears Downloader", id: "main")        // one instance; Window, not WindowGroup
│   ├── .defaultSize(980, 740) .windowResizability(.contentMinSize) (min 720×540 via frame(minWidth:minHeight:))
│   ├── .commands { … }                                 // section 5
│   └── MainWindow
│       ├── .navigationTitle("robogears Downloader") .toolbar(removing: .title)   // title lives in the Window menu and Mission Control, not in the toolbar (toolbars.md › Titles)
│       ├── .toolbar { AddField (.principal) · fixed space · UpdateControl · DownloadAllButton (.primaryAction) }
│       ├── .background(Color.canvas)                   // the only custom background in the app
│       ├── .dropDestination(for: FileURL / String)     // whole content area; lights the outline
│       ├── .onPasteCommand(of: [.plainText, .commaSeparatedText, .fileURL]) // import when no field is first responder
│       ├── .focusedSceneValue(\.queueActions, …)       // enables menu items
│       ├── .sheet(item: $sheet)                        // one at a time: signIn · signInToContinue · searchResults · pickOne · whatsNew
│       ├── .alert(…)                                   // quitDuringBatch · updateDuringBatch · firstLaunchMoveToApplications · oldFilesNotice · resetFolders
│       ├── .overlay { AddingCover }                    // when an add is in flight
│       └── VSplitView
│           ├── QueueArea
│           │   ├── AddArea (28 pt; hidden while the queue is empty)
│           │   ├── QueueHeader (28 pt)
│           │   ├── BatchSlot (ProgressView during a batch · SummaryNotice after · nothing otherwise)
│           │   └── QueueList  = List(selection:) of TrackRow        // or EmptyState when there are no rows
│           └── ActivityPanel (collapsible; header + NSTextView via NSViewRepresentable)
├── Settings { SettingsWindow }                          // TabView → General · Folders · TIDAL · Updates
└── Window("About robogears Downloader", id: "about")   // fixed 300×340, no resize, minimize dimmed; opened by the About command
```

Window chrome is system (`windows.md › Best practices`: "Avoid creating custom window UI"). The Dark toolbar is the system's dark toolbar material above the black canvas; nothing paints it.

### 4.2 Toolbar

Three items, two groups, as `toolbars.md › Item groupings` and `› Desktop (macOS)` ask; every item also exists in the menu bar.

| Position | Item | Control | States |
|---|---|---|---|
| Principal (centre) | Add field | `TextField` (`.roundedBorder`), placeholder "Paste a link or search TIDAL", 320–560 pt, `.onSubmit` adds, ⌘L focuses it | Disabled during an add (the cover is up). Never disabled during a batch (adding is allowed; downloading is not restarted). |
| Trailing, before the primary action, with a fixed space after it (`toolbars.md › Item groupings`: "Keep actions with text labels separate") | Update control | `.bordered` text button "Update to 0.1.32"; hidden until an update exists; fades in once | Click: "Downloading 42%" (tabular, disabled) → "Relaunching…". During a batch, click asks first (alert, 4.9). Failure: the label returns to "Update to 0.1.32" and the reason goes to the activity panel. |
| Trailing (`.primaryAction`) | The primary action | `.borderedProminent` "Download All" (`toolbars.md › Actions`: one `.prominent` item, trailing) | Label "Download (47)" when rows are left out or not found; "Stop Downloads" (`.bordered`, not prominent, not red) during a batch; disabled when the queue is empty or when every row is left out. Return does not trigger it (⌘↩ does). |

No Settings gear (`settings.md › Desktop (macOS)`: "Avoid adding settings buttons to a window's toolbar"). No brand glyph (`branding.md › Best practices`). No overflow by default at 720 pt: at that width the field is 320 pt and the two buttons fit.

### 4.3 Main window layout

```
┌ title bar + toolbar (system) ──────────────────────────────────────────────────────┐
│                     [ Paste a link or search TIDAL            ]   Update to 0.1.32   [Download All] │
├ content (Canvas) ───────────────────────────────────────────────────────────────────┤
│ Press Return to add every track from this link.        Drop a playlist CSV or paste tracks · Exportify │  AddArea 28
│ Queue  120        (speaker) ━━━━●━━━     [Retry All Failed (3)] [Clear Queue]        37 of 120 │  QueueHeader 28
│ ▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱ │  BatchSlot
│ ◯ Intro — Extended Mix E ▂▃▅▇▆▃▂▁▂▄▆▇▅▃▂▁▂▃▅▆▇▅▃▂ Placeholder Artist · 3:58  Hi-Res  42% ×  │  rows 28 / 44
│ ◯ Blue Lantern          ▁▂▃▅▆▇▅▃▂▁▂▃▅▇▆▅▃▂▁▂▃▅▆▇  Another Artist · 4:12  (triangle) Similar version in library │
│   Library: Blue Lantern (Remix) · 4:12 vs 3:58                                                    │
│ ◯ Seven                 ▂▃▅▆▇▅▃▂▁▂▃▅▇▆▅▃▂▁▂▃▅▆▇▅ The Band · 2:40   (clock) Waiting               │
│ …                                                                                                 │
├ divider (drag) ─────────────────────────────────────────────────────────────────────┤
│ Activity                                                                    Clear  │  ActivityPanel 160
│ (plus)  Added 120 tracks from link (3 not on TIDAL).                                  │
│ (check) Saved Intro.flac (24-bit / 96 kHz, 61 MB)                                     │
└────────────────────────────────────────────────────────────────────────────────────┘
```

(The glyphs in the sketch stand for SF Symbols named in 4.5; the symbol column in the activity panel is 1.5 em wide.)

**AddArea (28 pt).** Leading: the Return hint in InkSecondary, driven by the field's text: empty → "Paste a Spotify or TIDAL link, or type a song name."; a link → "Press Return to add every track from this link."; text → "Press Return to search TIDAL for “blue lantern”." Trailing: the compact drop hint "Drop a playlist CSV or paste tracks · Exportify" (Exportify underlined Ink; clicking it opens exportify.net and nothing else; `help("For playlists over 100 tracks — export via Exportify and drop the CSV here")`). Hidden while the queue is empty, because the empty state carries the full version.

**QueueHeader (28 pt).** Leading: "Queue" + count ("120"). Then the volume: `speaker.wave.2` (InkSecondary) + `Slider` 80 pt small, tooltip "Preview volume", VoiceOver value in percent; the stored value is the slider position, loudness is its square, default 50 (`sliders.md › Desktop (macOS)`: live feedback; the preview's volume updates on every change). Trailing: Retry button (`.bordered` small; "Retry Selected" / "Retry All Failed (N)"; hidden when nothing failed), "Clear Queue" (`.bordered` small; disabled during a batch), batch counter "37 of 120" (this batch only; visible during a batch).

**BatchSlot.** During a batch: a system determinate `ProgressView(value: done, total: total)` across the width, no label (the counter is in the header). Progress "keeps moving" per `progress-indicators.md › Best practices`: while TIDAL is busy the bar stays and the header counter gains the wait: "37 of 120 · waiting for TIDAL…". After a batch: the summary notice (4.10). Nothing otherwise.

**QueueList.** `List(selection: $selection)` of `TrackRow`, `.listStyle(.plain)`, `.scrollContentBackground(.hidden)`, `.listRowSeparator(.hidden)`, `.contextMenu(forSelectionType: Track.ID.self)`, `.onDeleteCommand` (⌫ removes, undoable), `.onKeyPress(.space)` (toggle preview of the selected row only when the list has focus). `List` over `Table`: rows need a flexible waveform column with the title-first rule and an optional second line; `Table` rows are fixed-height columns. `List` over a `LazyVStack`: free selection, keyboard navigation, VoiceOver, drag and context menus. Rows are backed by an `@Observable` per-track model so a progress tick re-renders one row, never the list; the header reads an aggregate. Multi-select: ⇧ extends, ⌘ toggles, ⌘A selects all (`focus-and-selection.md › Best practices`: list highlight). Drag and drop: rows reorder by drag (undoable); file or text drops anywhere on the content import; drops of anything else show the operation-not-allowed pointer (`drag-and-drop.md › Providing feedback`).

**EmptyState** (replaces the list when the queue has no rows; centred; priority top to bottom):

| Condition | Glyph | Title (title3 semibold) | Body (body, secondary) | Control |
|---|---|---|---|---|
| Signed out | vinyl template 56 pt, InkTertiary | Not signed in to TIDAL | Sign in to add tracks from links, searches and tracklists. | `.bordered` "Sign In…" (opens 4.6) |
| No download folder | same | Choose a download folder to start downloading. | Every download goes here directly — no subfolders. | `.bordered` "Choose Folder…" (NSOpenPanel) |
| Ready | same | Downloads go to ~/Music/TIDAL | — | the drop-hint box: "Drop a playlist CSV or paste tracks" (body, Ink) / "For playlists over 100 tracks — export via Exportify and drop the CSV here" (body, secondary, Exportify a link) |

Clicking the glyph plays the joke sound (Q3). No sheet opens at launch (`alerts.md › Best practices`: "Avoid showing an alert when your app starts"; the first-launch alerts in 4.11 are the brief's exception).

**ActivityPanel.** Header: "Activity" (subheadline, secondary) leading; "Clear" (`.bordered` small) trailing. Body: an `NSTextView` (read-only, selectable, monospaced 12 pt, 2,000 lines, oldest trimmed), each line a symbol column then text; auto-scroll only when the view was already at the bottom; `role` log for accessibility but no live announcements. Lines never contain signed links, raw replies or the account name (brief). Symbol per line kind: `plus` added · `checkmark` saved · `xmark.circle` failed · `exclamationmark.triangle` warning · `arrow.clockwise` retry · `books.vertical` library · `arrow.down.circle` update · `info.circle` notice · `magnifyingglass` search · `doc.text` import · `stop.circle` stopped.

### 4.4 Queue row anatomy (28 pt, left to right)

| # | Part | Backing control | Metrics | Behaviour |
|---|---|---|---|---|
| 1 | Play | `Button` `.buttonStyle(.plain)` with a 20 pt circle: 1 pt Hairline ring, `play.fill` 10 pt InkTertiary | 20 visible, 24 hit, leading inset 8 | Hover: ring and glyph Ink, 120 ms. Playing: Ink fill, `pause.fill` in Canvas. Loading: a `.controlSize(.small)` `ProgressView()` replaces the glyph. Absent on rows that cannot preview; dimmed with status "Preview unavailable" when a load failed. Label "Play preview" / "Pause preview". Tooltip "Play preview". |
| 2 | Title | `Text` body medium Ink + edition `Text` body regular InkSecondary + explicit mark (12×12) | fixed size, `layoutPriority(2)`, 8 pt after the play button | Never shrinks before the waveform is gone and the artist slot is at 80 pt; then truncates in the middle. Left-out rows: strikethrough and 50 % opacity (no dimming under Increase Contrast; the strikethrough and words carry the state). |
| 3 | Waveform | `WaveformView` (NSView `draw(_:)` or `Canvas`) 22 pt tall | `minWidth 0, maxWidth .infinity`, 10 pt each side | 3.4. Keeps its slot (blank) on rows that cannot preview. |
| 4 | Artist · length | `Text` callout secondary, `monospacedDigit` | min 80, max 220, tail truncation, `layoutPriority(1)` | Several artists joined with ", "; no length shown when unknown. |
| 5 | Quality badge | capsule `Text` caption2 | natural | "Hi-Res" or "AAC"; at most one; absent otherwise (imports carry no quality until matched). |
| 6 | Status | `Label` (symbol small + callout text) | max 200, tail truncation; full text in `help()` | Exactly one, from 4.5. The row's status line colour; never colour alone. |
| 7 | Action | `.bordered` small (or `.borderedProminent` small for "+ Add") | natural | From 4.5. Absent when none. The same action is in the context menu and the Queue menu. |
| 8 | Remove | `Button` `.plain`, `xmark` 11 pt InkTertiary | 20 hit, trailing inset 8 | Visible on hover and on selected rows; always in the context menu, Edit › Delete and ⌫; always a VoiceOver action. Hover Ink. During a batch on a downloading row it removes the track from the batch (brief). |

Second line (row grows to 44 pt; `.subheadline` InkTertiary, indented to the title's leading edge; at most one, highest wins): failure or clash sentence › library note ("Library: Blue Lantern", with both lengths "· 4:12 vs 3:58" when more than 10 s apart) › source wording ("Spotify: Intro — Placeholder Artist").

Row background: none at rest; Surface on hover (120 ms); system selection when selected (`focus-and-selection.md › Best practices`: "use a highlight in a list"); Surface2 never used for rows. No tinted backgrounds for failed or downloading rows.

Downloading row extra: a 2 pt progress line at the row's bottom edge, Ink on Surface2, width = percent of the row width.

### 4.5 Row states

Symbol size `.small` beside 12 pt text; all symbols monochrome (`sf-symbols.md › Rendering modes`), coloured with the row's status colour.

| State | SF Symbol | Status text | Colour | Row treatment | Action (button) | Also in context menu |
|---|---|---|---|---|---|---|
| Waiting, no batch | — | (none) | — | — | — | Play Preview, Leave Out, Remove |
| Waiting, in a batch | `clock` | Waiting | InkSecondary | — | — | Remove (from batch) |
| Downloading | — | 42% (tabular) | Ink | 2 pt progress line; waveform stays | Remove (xmark) removes it from the batch | — |
| Done | `checkmark.circle.fill` | Done · 24-bit / 96 kHz (or Done · AAC) | StatusDone | title stays Ink; row leaves when the batch ends (log line) | — | Show in Finder |
| Skipped: already in your download folder | `folder` | Already in your download folder | InkSecondary | — | Show in Finder | Show in Finder |
| Failed | `exclamationmark.circle.fill` | Failed | StatusFailed | second line: the reason sentence, kept after a restart | Retry | Retry, Copy Title and Artist |
| Not on TIDAL | `questionmark.circle` | Not on TIDAL | StatusFailed | no play, blank waveform slot | Search… (pick-one sheet) | Search TIDAL…, Remove |
| Couldn't check | `exclamationmark.triangle` | Couldn't check: TIDAL was busy | InkSecondary | no play, blank slot | Match Again | Match Again |
| Left out: in your library | `books.vertical` | In your library | InkSecondary | dimmed 50 %, strikethrough title; second line "Library: Blue Lantern" | + Add (prominent small, full strength) | Include in Download, Show Library File in Finder |
| Left out: different artist on TIDAL | `person.crop.circle.badge.questionmark` | Different artist on TIDAL | InkSecondary | dimmed, strikethrough | + Add | Include in Download, Search TIDAL… |
| Similar version in library | `exclamationmark.triangle.fill` | Similar version in library | StatusSimilar | second line with both lengths when > 10 s apart; stays included | — | Leave Out of Download, Show Library File in Finder |
| In your download folder (before a batch) | `folder` | In your download folder | InkSecondary | stays included; skips instantly | Show in Finder | Show in Finder |
| Clash | `exclamationmark.circle.fill` | Not downloaded | StatusFailed | second line "A different song is already saved as Intro.flac" | Save As… | Save As…, Replace |
| Damaged file | `exclamationmark.circle.fill` | Not downloaded | StatusFailed | second line "Intro.flac looks damaged" | Replace | Replace, Show in Finder |
| Saved as AAC | `checkmark.circle.fill` | Done · AAC | StatusDone | second line "Saved as AAC (.m4a): TIDAL has no lossless version" | — | Show in Finder |
| Checking library | small system spinner | Checking library… | InkSecondary | — | — | — |
| Preview unavailable | — (play button dimmed) | Preview unavailable | InkSecondary | — | Try Again | Try Again |
| Quality badge | — | Hi-Res / AAC capsule | InkTertiary | independent of the status | — | — |

Priority when several apply: download result › clash or damaged › Not on TIDAL › Couldn't check › left out › similar › in download folder › checking › preview unavailable.

### 4.6 TIDAL sign-in sheet

`.sheet`, 440 pt wide, content-sized, not resizable (`sheets.md › Desktop (macOS)`: "Present a sheet in a reasonable default size").

```
Sign in to TIDAL                                   (headline)
Sign in to TIDAL in your browser and click Allow.  (body)
[ https://link.tidal.com/ABCDE            ] [Copy Link]    (read-only, selectable text field; Copy Link shows "Copied" for 1.5 s then returns)
ABCDE                                              (short code, 22 pt mono; only when TIDAL sends one)
Waiting for TIDAL…                                 (status line, callout, secondary; one line only)
                                   [Cancel]  [Open in Browser]   (Open in Browser is the default; Cancel = Esc, ⌘.)
```

Success: the status line reads "Signed in." and the sheet closes itself 600 ms later (the task is complete; `accessibility.md › Cognitive` cautions against timers, so the close is also immediate on any click). Failure: the status line turns StatusFailed with the reason ("TIDAL didn't accept the sign-in. Try again."), and the default becomes [Try Again]. Cancel stops polling. No terminal log, no sheet without a way out.

**Sign in to continue** (`.alert`): "Sign in to TIDAL to add 2 tracks from pasted text." [Cancel] [Sign In…] (default). After sign-in the add resumes; nothing downloads by itself.

### 4.7 Search results sheet

`.sheet`, 600×480, resizable (min 520×360).

```
Results for “Blue Lantern”                                         (headline)
[ Refine                                                    ]      (search field; filters the 10 results as typed)
[ ]  Blue Lantern — Extended Mix  E  Hi-Res   Artist · Album · 4:12   (triangle) Similar version in library
[x]  Blue Lantern                           Artist · Album · 3:58
[ ]  Blue Lantern (Live)                    Artist · Album · 5:03     In Queue          (checkbox disabled)
3 selected                                             [Cancel]  [Add Selected]      (default; dim until something is ticked)
```

Rows: a `Toggle(.checkbox)`, the same title/edition/explicit/quality parts as the queue row, artist · album · length (secondary), the queue's library mark (same symbol and colour). Double-click a row adds that one track and closes. Empty: "No TIDAL results for “Blue Lantern”. Check the spelling or try fewer words." centred, secondary. A library-exact pick lands in the queue left out, as the queue rule says. "Added 0" never happens: Add Selected is unavailable until a row is ticked.

**Pick-one mode** (from a Not on TIDAL row's Search…): title "Pick the TIDAL track for “Intro — Placeholder Artist”", radio selection, default [Use This Track]; the chosen track replaces the row in place.

### 4.8 Update control, What's New, update during a batch

- Toolbar control: 4.2. Menu: robogears Downloader › Check for Updates…. Offline and GitHub's rate limit report differently in Settings › Updates ("No internet connection" / "GitHub is limiting checks; try again in an hour").
- What's New (`.sheet`, 520×440, scrollable release notes rendered as attributed text): [Skip This Version] (leading, `.bordered`) · [Install on Quit] · [Install and Relaunch] (default).
- During a batch, Update click → `.alert` "Update now or when downloads finish?" with "12 tracks are still downloading." [Cancel] [Update Now] [Update When Downloads Finish] (default).
- The update fades in once; under Reduce Motion it appears.

### 4.9 Quit during a batch

`applicationShouldTerminate` → `.alert` "Quit while 12 tracks are still downloading?" "Downloads stop. Finished tracks stay in your folder; the rest go back to Waiting." [Quit] (not default) [Keep Downloading] (default). `alerts.md › Buttons`: the default is the safe one; Esc = Keep Downloading. Closing the window (⌘W) keeps downloading; the Dock tile shows progress; Window › robogears Downloader reopens it.

### 4.10 Batch summary notice

Lives in the BatchSlot after a batch; 44 pt; Surface fill, 1 pt Hairline, 6 pt radius; symbol + sentence + buttons + an `xmark` dismiss. Dismissed by the ×, by the next batch, or by Clear Queue. VoiceOver announces it once.

| Outcome | Symbol | Sentence | Buttons |
|---|---|---|---|
| All good | `checkmark.circle.fill` StatusDone | Done: 12 downloaded, 2 already in your folder. | Open Folder |
| Some failed | `exclamationmark.circle.fill` StatusFailed | Finished with problems: 10 downloaded, 2 failed. | Retry Failed (2) · Open Folder |
| Stopped by the person | `stop.circle` InkSecondary | Stopped: 5 downloaded, 115 waiting. | Open Folder |
| Stopped by a cause | `exclamationmark.circle.fill` StatusFailed | Stopped: the download folder “TIDAL” on Music SSD isn't available. Connect the drive or choose another folder. | Choose Folder… |
| No folder (Download All clicked without one) | `folder.badge.questionmark` InkSecondary | Choose a download folder to start downloading. | Choose Folder… |

Never says "finished" when anything failed (brief). Sounds: the bells only on "All good"; the quiet failure sound on the other outcomes; both only when "Play sound effects" is on; every sound has this visual double (`feedback.md › Best practices`: feedback in more than one channel).

### 4.11 Adding cover, first launch, Dock tile

**Adding cover.** `.overlay` on the content area (toolbar stays, its field disabled): `Material.regular` (`materials.md › Standard materials`), under Reduce Transparency the opaque Canvas. Centred: system `ProgressView()` (regular size), then the text (body, secondary): a random loading line swapping every 2.5 s until a count is known, then "Matching 34 / 100 tracks on TIDAL…" (tabular); then `.bordered` [Cancel] (Esc, ⌘.). Focus moves to Cancel; everything behind is `.disabled` and `.accessibilityHidden`. Cancel keeps the matches made so far and adds them; the log says "Stopped matching after 34 of 100." One add at a time: a second link, paste or drop while the cover is up is refused with a log line, not queued.

**First launch only.** (1) "Move robogears Downloader to Applications?" [Not Now] [Move] (default), then (2) "Files from the previous version are in ~/Library/Application Support/robogears Downloader." "They aren't used. You can move them to the Trash." [Keep] (default) [Move to Trash]. One after the other, never together (`sheets.md › Best practices`: one at a time), never again. `alerts.md › Best practices` advises against launch alerts; the brief requires these two, so the brief wins and this is the only exception.

**Dock tile.** During a batch: the real icon with the determinate bar from 3.3; removed when the batch ends. No badge text. When the batch ends while the window is not key: one informational attention request (a single bounce), plus a user notification only if "Notify When Downloads Finish" is on. Dock menu (Control-click): Download All / Stop Downloads, Open Download Folder.

### 4.12 Settings window

`Settings` scene; `TabView` renders as the fixed, non-customisable toolbar pane switcher; the window title is the pane name; minimize and zoom dimmed (`settings.md › Desktop (macOS)`). Each pane is a `Form` with `.formStyle(.grouped)`, 480 pt wide, content-sized. Changes apply at once; no Done. System colours only (the black canvas is content, not chrome). Last pane restored on reopen.

| Pane (symbol) | Contents |
|---|---|
| General (`gearshape`) | Play sound effects (on) · Notify When Downloads Finish (off) · Preview cache: "84 MB" with [Clear Preview Cache] |
| Folders (`folder`) | Download folder: path, [Choose…] [Show in Finder]; footer "Every download goes here directly — no subfolders." · Music library folder: path, [Choose…] [Show in Finder] [Clear]; status "1,240 files indexed" / "Scanning 120 / 500…" with [Refresh]; footer "Read-only. The app reads audio tags and file names." · [Reset Folders…] (asks: "Forget the download and library folders?" "Your TIDAL sign-in stays." [Cancel] [Reset]) · A download folder inside the library is refused: "The download folder can't be inside your music library. Choose another folder." |
| TIDAL (`waveform`) | "Signed in to TIDAL · United States" or "Not signed in" / "Your TIDAL sign-in is no longer valid." · [Sign In…] or [Sign In Again…] [Sign Out] (both unavailable during a batch, with the footer "Unavailable while downloads are running.") |
| Updates (`arrow.down.circle`) | "Version 0.1.31" · [Check Now] with its result inline ("Up to date", "0.1.32 available" + [What's New…], "No internet connection", "GitHub is limiting checks; try again in an hour") · Check for updates automatically (on) · bottom-left, `.caption` tertiary: "made with love by robogears :)" |

A folder change during a batch applies from the next batch and says so beneath the field (brief). No token, email or account name anywhere.

### 4.13 About window

Fixed 300×340: the real app icon at 128 pt (click: joke sound), "robogears Downloader" (title2), "Version 0.1.31 (build)" (body, secondary; click: 7× joke), "made with love by robogears :)" (caption, tertiary), a "GitHub" link. System background. Opened by the app menu's About item.

## 5. Menu bar

SwiftUI `.commands`. Standard order and groups per `the-menu-bar.md › Anatomy`; unavailable items are disabled, never hidden (`the-menu-bar.md › Best practices`). Custom shortcuts are few and marked †; conflicts are flagged (`keyboards.md › Custom keyboard shortcuts`).

| Menu | Placement | Item | Shortcut | Enabled when | Notes |
|---|---|---|---|---|---|
| robogears Downloader | `CommandGroup(replacing: .appInfo)` | About robogears Downloader | — | always | opens the About window |
| | automatic (`Settings` scene) | Settings… | ⌘, | always | |
| | `CommandGroup(after: .appSettings)` | Check for Updates… | — | not already checking | |
| | same group | Sign In to TIDAL… / Sign Out of TIDAL | — | no batch running | toggled label (`menus.md › Toggled items`) |
| | automatic | Hide, Hide Others, Show All, Quit | ⌘H, ⌥⌘H, ⌘Q | | Quit asks during a batch (4.9) |
| File | `CommandGroup(replacing: .newItem)` | Import Tracklist… | ⌘O | no add in flight | replaces New; no New Window |
| | same group | Open Download Folder | ⇧⌘O † | folder set | |
| | automatic | Close | ⌘W | | downloads keep going |
| Edit | automatic + `UndoManager` | Undo Clear Queue / Redo Remove from Queue | ⌘Z, ⇧⌘Z | | named for the action (`undo-and-redo.md › Desktop (macOS)`) |
| | automatic | Cut, Copy, Paste, Select All | ⌘X ⌘C ⌘V ⌘A | | Paste with no field focused imports (`.onPasteCommand`); a single pasted link goes through the link resolver; ⌘A selects all rows when the list has focus |
| | `CommandGroup(after: .pasteboard)` | Delete | ⌫ | rows selected | removes selected rows, undoable; same implementation as Remove from Queue |
| | `CommandGroup(after: .textEditing)` | Clear Activity | ⌘K † | log not empty | Terminal and Xcode use ⌘K to clear; not system-reserved |
| View | `CommandGroup(after: .toolbar)` | Show/Hide Toolbar | ⌥⌘T | | system item |
| | same | Show/Hide Activity | ⇧⌘L † | always | toggled label |
| | automatic | Enter Full Screen | ⌃⌘F | | system |
| Queue (`CommandMenu("Queue")`, between View and Window) | group 1 | Add Link or Search | ⌘L † | always | focuses the toolbar field; ⌘L is "Open Location" in browsers, not system-reserved |
| | | Download All / Download (47) | ⌘↩ † | rows downloadable, no batch, no sheet | disabled whenever a sheet is up so Return in a sheet can never start a batch |
| | | Stop Downloads | ⌘. | batch running | ⌘. is the standard cancel key; precedence: a sheet › the adding cover › the batch (only the frontmost cancellable thing responds) |
| | | Retry Selected / Retry All Failed (N) | ⌘R † | failed rows exist | ⌘R is Reload in browsers; not system-reserved |
| | group 2 | Play Preview / Pause Preview | Space (shown) | a row is selected | **Flag:** do not bind Space as a menu key equivalent; implement it in the list's key handling so a text field keeps Space. Show the glyph in the menu only if a run confirms the field editor keeps the key; otherwise show no shortcut. |
| | | Stop Preview | — | a preview is loaded | |
| | group 3 | Include in Download / Leave Out of Download | — | one or more rows selected | toggled label; acts on all selected rows |
| | | Search TIDAL… | — | a Not on TIDAL or left-out row is selected | |
| | | Match Again | — | a Couldn't check row is selected | |
| | | Show in Finder | — | a saved or skipped row is selected | |
| | | Show Library File in Finder | — | a library-matched row is selected | |
| | group 4 | Remove from Queue | ⌫ | rows selected | same item as Edit › Delete, listed here too for discovery |
| | | Clear Queue | ⇧⌘⌫ † | queue not empty, no batch | **Flag:** Finder uses ⇧⌘⌫ for Empty Trash; acceptable inside this app, but the owner may prefer no shortcut |
| Window | automatic | Minimize, Zoom, Bring All to Front, robogears Downloader | ⌘M | | the window list reopens the main window after ⌘W |
| Help | `CommandGroup(replacing: .help)` | robogears Downloader Help | ⌘? | | opens the README |
| | after a separator | What's New | — | | |
| | | Open Exportify | — | | |

Not used, deliberately: Escape for Stop Downloads (Q8); any Control-modifier shortcut (`keyboards.md › Custom keyboard shortcuts`: avoid Control); ⇧⌘A (that is Deselect All in the standard table).

**Context menu on rows** (acts on every selected row; unavailable items hidden, `context-menus.md › Best practices`; no shortcuts shown; three groups): Play Preview · Include in Download / Leave Out of Download | Retry · Search TIDAL… · Match Again · Save As… · Replace · Show in Finder · Show Library File in Finder · Copy Title and Artist | Remove from Queue.

**Keyboard in the queue:** ↑↓ select, ⇧↑↓ extend, ⌘A all, ⌫ remove, Space preview (list focus only), ⌘↑/⌘↓ first and last. Held keys repeat only for movement; ⌫ and Space act once per press. In sheets Return confirms and Escape cancels. The toolbar field never loses Space, ⌫ or arrows.

## 6. Accessibility

**VoiceOver.**
- A row is one element: label "Intro — Extended Mix, explicit, Placeholder Artist, 3 minutes 58 seconds, Hi-Res, downloading 42 percent" (title, explicit, artist, length, quality, status, second line, in that order); custom actions: Play Preview / Pause Preview, Remove from Queue, and the row's action (Retry, Search TIDAL, Match Again, Add to Download, Leave Out of Download, Show in Finder, Try Again, Save As, Replace). The left-out state reads "left out" after the status.
- The waveform is a child element: label "Preview position", value "1 minute 23 seconds of 3 minutes 45 seconds", adjustable (increment and decrement seek 5 s), `.allowsDirectInteraction` off. Rows that cannot preview expose no waveform element.
- The play button: label "Play preview" / "Pause preview"; loading: "Loading preview". Remove: "Remove from Queue". The explicit mark: "Explicit". Badges read as their text.
- Counts read as words: "34 of 100", "37 of 120 downloaded". Never "34 slash 100".
- Announcements (`AccessibilityNotification.Announcement`): the result of every add ("Added 47 tracks from link, 3 not on TIDAL"), batch start and end (the summary sentence), sign-in success, an update becoming available. The activity panel is never announced line by line.
- The summary notice and the adding-cover text are live regions; the Dock bar needs none (the announcement covers it).
- Every symbol is paired with words; no status is colour alone (`accessibility.md › Vision`).

**Focus order (Tab, Full Keyboard Access on):** toolbar: Add field → Update → Download All; content: volume slider → Retry → Clear Queue → the list (one tab stop; ↑↓ moves rows; inside a row with Full Keyboard Access: play → waveform → action → remove) → notice buttons → activity Clear → activity text. Sheets trap focus; the adding cover moves focus to Cancel and hides the rest. Focus never moves on its own (`focus-and-selection.md › Best practices`), except to the nearest row when a focused row is removed.

**Full Keyboard Access:** every control is a standard control or `.focusable()`; the waveform shows the system focus ring; rows highlight with the system list highlight; ⌃F5 reaches the toolbar; the Settings panes are reachable by ⌘, then Tab.

**Increase Contrast:** the IC colour variants in 3.1 (secondary 10.9:1 and 12.5:1, tertiary 7.0:1 and 7.5:1, hairlines 3.5:1 and 3.2:1, unplayed bars 45 %); the drag outline stays 2 pt; left-out rows are not dimmed (strikethrough and words only); badges use the IC hairline; system controls adapt themselves.

**Reduce Motion:** the RM column in 3.5; no crossfades, numeric transitions or symbol-replace effects; the progress line and batch bar jump; loading lines hard-swap; system spinners and sheets follow the system.

**Reduce Transparency:** the adding cover is the opaque Canvas; there is no other material in the content layer; chrome follows the system.

**Hearing:** every sound has a visual double (notice, row state, Dock bar); "Play sound effects" turns all sounds off at once.

**Mobility:** the smallest hit area is 20×20 pt (Remove), the play button 24×24, with 8 to 10 pt between bezel-less targets; nothing requires a drag (seek by keyboard, reorder by Cut and Paste of rows as a later addition if the owner wants it).

## 7. Check the real pixels

Capture the running app's window with `screencapture -l <windowID>` at 980×740 and 720×540, in Light and Dark, with Increase Contrast off and on, with a queue of about 120 rows that includes every state in 4.5. Judge each item; "fail" means fix before the finishing pass.

1. **Selection with the ink accent (first).** Select a row that is playing, in Dark (white accent) and Light (black accent), key and inactive window. Fail: text or bars invisible against the selection fill; the system did not pick a contrasting selection text colour. Fallback if it fails: `.listRowBackground` of Ink on selected rows with Canvas foreground passed through the environment, keeping `List` selection otherwise standard.
2. **Prominent button.** Download All under Multicolor and under a chosen blue accent, both appearances. Fail: label under 4.5:1; more than one prominent control visible; Stop Downloads prominent or red.
3. **Row metrics.** Measure a plain row (28 pt), a row with a second line (44 pt), the pitch (30 pt), the waveform (22 pt), the play button (20 pt visible). Fail: any other height; the waveform taller than 22; a title truncated while the waveform still has width.
4. **Hover.** Pointer over a row at 40 % of the waveform; capture. Fail: any bar taller than at rest; anything moved, scaled or lifted; brightness above 60 % at the pointer; cursor line missing or thicker than 1 pt; row background other than Surface.
5. **Downloading row.** At 42 %: progress line 2 pt, full row width, Ink on Surface2, waveform still drawn, "42%" tabular. Fail: a system bar inside the row; a tinted row background; animation under Reduce Motion.
6. **Left-out row.** "In your library" and "+ Add" at full strength, title struck through at 50 %; under Increase Contrast, no dimming. Fail: the status or button dimmed; dimming present under IC.
7. **Contrast, measured from the capture:** InkSecondary and InkTertiary on Canvas in both appearances (expect 7.5/7.0 and 4.6/4.5); StatusFailed, StatusSimilar, StatusDone on Canvas (expect at least 4.9 in Light, 7.6 in Dark); under IC at least 7:1 for every text colour. Fail: any text under 4.5:1, any IC text under 7:1.
8. **Toolbar.** Field 320 pt at 720 wide and 560 pt at 980; a visible gap between "Update to 0.1.32" and "Download All"; no window title text; no gear; no glyph. Fail: labels run together; an overflow menu at 720.
9. **Empty states, all three, at 720×540.** Fail: clipping; glyph larger than 56 pt; a dashed box; a sheet at launch.
10. **Adding cover with Reduce Transparency on.** Fail: any blur; a control behind the cover reachable by Tab; Escape not cancelling.
11. **Settings, each pane, both appearances.** Fail: a black canvas inside Settings; minimize or zoom enabled; the title not the pane name; a Done button.
12. **Sheets (sign-in, search, pick-one).** Fail: no Cancel; Escape or ⌘. not closing; Return not firing the default; Add Selected enabled with nothing ticked; a second sheet stacking.
13. **Dock tile during a batch.** Fail: no bar; badge text; the bar remaining after the batch.
14. **VoiceOver, one row and its waveform.** Fail: the waveform not adjustable; counts read with "slash"; a status read as a colour name or an emoji; the Remove action missing.
15. **Keyboard only.** Tab through the window per section 6; press Space in the Add field (must type a space), in the list (must play); press Escape during a batch (must do nothing); ⌘. during a batch (must stop). Fail: any of those reversed; ⌘↩ firing from inside a sheet.
16. **Long content.** A 200-character title and a ten-artist line at 720 wide: the waveform reaches 0, the artist slot 80 pt, then the title truncates in the middle. Fail: a horizontal scroll; an action button pushed out of the row.
17. **Nothing endless.** Leave the window idle for 60 s with an update available and a batch running; record. Fail: anything pulsing, breathing or rotating other than the system spinner and the progress updates.
