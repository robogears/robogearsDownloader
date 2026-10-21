# Overnight Loop Plan — 2026-10-21

<!-- run metadata — recovery reads this first; update it at the end of every turn -->
STATE: LOOPING              # LOOPING | PAUSED (<why>) | STOPPED
PROJECT_PATH: ~/Developer/swiftRobotDownloader
SKILL_PATH: ~/.claude/skills/overnightprotocol/SKILL.md
START_EPOCH: 1792607752
LAST_TURN_EPOCH: 1792615091
CEILING_EPOCH: none         # or <int> if the user set a stop time
BASE_BRANCH: main
BRANCH: overnight-loop/2026-10-21-2235
RUNG: mission               # mission | 1-qa | 2-audit | 3-qol
CYCLE: 0                    # completed ladder cycles
LAST_AUDIT: none            # <epoch> <commit> — re-audit only after ≥5 new loop: commits
DENY_RULES: none — the repo tracks .claude/settings.local.json, so deny-rules.sh would commit them; kickoff default: run without them and rely on the skill's own rules
KEEP_AWAKE: caffeinate -dis via scripts/keep-awake.sh — pid record in <git-dir>/overnight-loop/ (private); re-checked every turn, stopped at wrap-up
TICK_PROMPT: Overnight loop tick for `~/Developer/swiftRobotDownloader`. You are mid-run: skip Phase 0. Follow the overnightprotocol turn contract — if its instructions are not in your context, first read `~/.claude/skills/overnightprotocol/SKILL.md`. Continue from the plan: resume the `[~]` item, else the top open item, else the ladder rung in the plan header. End the turn with ScheduleWakeup using this same prompt. Only /overnightprotocol stop from the user, or the plan's CEILING, ends the loop.
EVERY TURN: re-read this header + open items → handle user messages → check the ceiling → work → update this header → ScheduleWakeup(TICK_PROMPT)
STOP: the user runs /overnightprotocol stop (or presses the Stop button)

Mission (owner, 21 Oct 2026): "the main plan for this project is to convert it completely into swift" · "i'm going to sleep build as much as you can". Decisions D1–D3 and the kickoff defaults are in docs/PORT_PLAN.md and the report's Decisions section. The Swift app lives in `macos/`; the Electron code stays at the repo root untouched as the reference (docs/electron-reference/ cites it by path).

## Mission (official items — do these first)
- [x] 1. Decision-4 document — done when: docs/D4_BEHAVIOUR_DECISIONS.md holds a one-screen summary table of every item with the recommended answer, then the five checked area sections, with the consistency checker's contradictions resolved — 20m (lead time; writing delegated)
- [x] 2. Design brief — done when: docs/DESIGN.md states the product, the person, each screen's single job, real facts (data shapes, limits), the identity to keep (pure-black monochrome, sounds, funny lines), Light+Dark mapping, macOS conventions (menu bar, Settings window, sheets, keyboard, VoiceOver) and what must never happen — 13m
- [x] 3. Swift project scaffold — done when: `macos/` holds an XcodeGen `project.yml` for the app "robogears Downloader" (bundle id com.robogears.downloader, version 0.1.31, macOS 15+) plus a local Swift package `RobogearsCore` with a test target; `swift test` passes and `xcodebuild build` succeeds; .gitignore covers Xcode output — 6m
- [x] 4. Core: input and import parsing — done when: link parsing (TIDAL/Spotify forms per D4 4.1–4.3), CSV/plain-text tracklist parsing (4.5, 4.6, 4.17), filename sanitising (2.14), version compare and the TIDAL-compatible percent-encoder exist in RobogearsCore with unit tests built from the reference's worked examples — delegated lane, merged (implement → review → fix)
- [x] 5. Core: matching — done when: one Unicode-aware normaliser (3.1), one TIDAL matcher (3.2) and the library matcher (3.3–3.5, 3.13) exist with unit tests covering the reference's example tables and the new rules — delegated lane, merged (implement → review → fix)
- [x] 6. Core: TIDAL models, manifests and Spotify embed — done when: Codable models, BTS/DASH manifest parsing (startNumber, r+1 segments, $Number$, XML unescape) and Spotify __NEXT_DATA__ extraction exist with synthetic-fixture tests — delegated lane, merged (implement → review → fix)
- [x] 7. Core: TIDAL client — done when: URLSession client with per-call headers, device-code sign-in, one token keeper actor (refresh once on 401, shared renewal), retry/backoff policy (1.4) and a Keychain/file credential store exist, tested with a mock URLProtocol (no live calls) — delegated lane, merged (implement → review → fix)
- [x] 8. Offline spikes with generated audio — done when: docs/spikes/ answers, with evidence, (a) can AVFoundation decode and play FLAC and DASH-style FLAC-in-fragmented-MP4, (b) exactly which tag keys and picture block the old FFmpeg arguments write, (c) can a native Swift writer produce an equivalent FLAC (tags + front-cover picture type 3) — delegated lane, merged (implement → review → fix)
- [~] 9. Download pipeline — done when: per-track download (segments in a TaskGroup of 8 or direct stream) → temporary file → tags and cover → length check → no-replace move into the flat download folder works end to end on a synthetic stream, with tests — STARTED 1792614220 · attempt 1 · approach: contracts committed (a79f82c), then four lanes in parallel: track, folder (incl. L4 naming 2.6/2.7), m4a writer, batch runner; implement → review → fix · active: 0m · wip: none · delegated: workflow wc5tyv5c2 (run wf_5ac1dad9-927) · worktrees ~/Developer/swiftRobotDownloader-lane-{track,folder,m4a,batch}, branches loop/dl-*
- [x] 10. Library scanner — done when: background folder walk, tag reader for FLAC/Ogg/MP4/ID3 (3.10), saved index (3.7) and scan defaults (3.8) exist with tests on generated files — 25m (mapping LibraryFile → LibraryMatcher.Entry happens at the matching-lane merge)
- [~] 11. Native UI — done when: a Fable-led design pass from docs/DESIGN.md is recorded, and the SwiftUI app shows the main window (input, drop zone, queue rows, activity), Settings window, sign-in sheet and menu-bar commands, wired to RobogearsCore; screenshots of real pixels in Light and Dark are checked — STARTED 1792609791 · attempt 1 · approach: workflow — model+main window, then sheets+Settings, then code review + Fable pixel review, then fixes; stand-in data until core is wired · active: 0m · wip: none · delegated: workflow wy0jgeb07 (run wf_489a441f-2b7) · worktree ~/Developer/swiftRobotDownloader-lane-ui, branch loop/ui
- [~] 12. Preview player and waveform — done when: peaks (200 bars) and AVFoundation playback with scrubbing work on a generated file, one player at a time (5.16) — STARTED 1792614627 · attempt 1 · approach: part 1 done here (7844196: WaveformPeaks + PreviewCache, 12 tests, two mutation checks; 6ec6cda: Now Playing bridge 5.13); part 2 (preview loader using the track lane's audio fetcher, Now Playing 5.13, one-player rule 5.16) after item 9 merges · active: 20m · wip: none
- [x] 13. Sound effects — done when: every sound (download chime, cancel chime, warning honk, success ping, brand easter eggs) is synthesised natively with the exact frequencies and envelopes from the reference — 14m
- [x] 14. Updater — done when: the GitHub-releases updater (owner's github-updater recipe, SHA-256 gate, asset contract `mac-arm64.dmg`) is implemented and unit-tested without touching the network for real installs — 25m
- [x] 15. App state — done when: settings, the two folders (bookmarks that follow a rename; unavailable, missing and in-the-Trash detected; a download folder inside the library refused) and the queue (atomic saves, a damaged file kept aside, failed rows keep their reason, unfinished rows come back waiting) live in RobogearsCore/State with tests — 18m
- [~] 16. Resolver and shared TIDAL pace (self-generated: item 11 needs it to be wired) — done when: links, Spotify, tracklists, search and Match Again turn into queue rows per D4 area 4, through one shared pace (1.4), cancellable (1.11), tested on the mock URLProtocol — STARTED 1792614627 · attempt 1 · approach: one lane, implement → review → fix · delegated: workflow w7631wviv (run wf_91130b23-6a1) · worktree ~/Developer/swiftRobotDownloader-lane-resolve, branch loop/resolve
- [x] L6. The app's own data folder (found while checking D4 5.11) — done 1127d5e: settings, queue and sign-in moved to Application Support/com.robogears.downloader; LegacyElectronFiles helper (exact-name trash, permanent Delete Old Sign-in) + settings flag; 6 tests
<!-- open = [ ] or [~]; resume [~] first
     [~] N. <item> — STARTED <epoch> · attempt <n> · approach: <one line> · active: <m>m · wip: <hash|none> [· delegated: <task/run id> · <worktree/branch>] [· interrupted]
     [x] N. <item> — <active>m
     [>] N. <item> — <reason> · shelved: overnight-loop/shelved/<slug>
     [!] N. <item> — blocked by <reason> (morning command in the report) -->

## Ladder backlog (self-generated when the mission is exhausted)
- [x] L5. Merge notes for the core lanes — done fc53b39 (LibraryLookup.swift: LibraryFile → Entry, cached matcher index on LibraryIndexService, QueueItem.LibraryMatch(_:)); fixtures were already merged; FLAC reader unification left as a leftover (TagReader's FLACCommentReader vs FLACMetadataReader.summary)
- [x] L3. Remove the temporary link `~/Pictures/GitHub Projects/swiftRobotDownloader` → `~/Developer/swiftRobotDownloader` — done when: the core-lane workflow and the design lead have finished, the lane worktrees are merged and removed, and the link is deleted (only the link, never the target) — done 22 Oct 00:25 (link removed, target untouched)
- [~] L4. Apply D4 2.6 and 2.7 (in item 9's folder lane) (owner chose all recommended, 21 Oct 2026) — done when: file naming keeps title-only names except a clash with a different song ("<Title> (<Artist>).flac", deterministic order version → artist → album), the version goes in the title tag, and untagged existing files fall back to keeping the row with Save As…
- [x] L1. Unify version comparison — done fc53b39 (UpdateVersion.isNewer uses VersionNumber; rc ordering test)
- [x] L2. Release packaging script — done when: a script builds the Release app, the DMG named robogears-downloader-mac-arm64.dmg (.app at the root, for the v0.1.30 updater), the zip robogears-downloader-mac-arm64.zip, and a .sha256 for each; the CI workflow gains actions/checkout in the release job — 8m (the CI part is a recommendation; the loop doesn't edit CI unattended)

## Parked — needs direction (never build these on a guess)
- ⏸ Live TIDAL check — question: run the device sign-in, a refresh with the second client pair, and record field names (user code, lifetime, version, presentation) — options: owner signs in once in the morning | skip — unlocks: verifying 1.3, 1.9, 2.7, 2.23 and the real download path
- ⏸ Signing certificate (D4 1.5 / 5.7: owner chose the recommended free self-signed certificate) — needs the owner to create it in Keychain Access and name it; until then builds stay ad hoc and the sign-in uses the private 0600 file — unlocks: Keychain storage without prompts
- ⏸ Windows copies of v0.1.30 (D4 5.8: owner chose the farewell Windows build) — the Electron change is DONE on branch loop/windows-farewell (eadd4fa, pushed: Windows update checks off, farewell line at launch, version 0.1.31); building its setup.exe is a CI/ship step the loop doesn't run unattended — unlocks: the first Swift release
