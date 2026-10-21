# Overnight Loop Plan — 2026-10-21

<!-- run metadata — recovery reads this first; update it at the end of every turn -->
STATE: LOOPING              # LOOPING | PAUSED (<why>) | STOPPED
PROJECT_PATH: ~/Pictures/GitHub Projects/swiftRobotDownloader
SKILL_PATH: ~/.claude/skills/overnightprotocol/SKILL.md
START_EPOCH: 1792607752
LAST_TURN_EPOCH: 1792608143
CEILING_EPOCH: none         # or <int> if the user set a stop time
BASE_BRANCH: main
BRANCH: overnight-loop/2026-10-21-2235
RUNG: mission               # mission | 1-qa | 2-audit | 3-qol
CYCLE: 0                    # completed ladder cycles
LAST_AUDIT: none            # <epoch> <commit> — re-audit only after ≥5 new loop: commits
DENY_RULES: none — the repo tracks .claude/settings.local.json, so deny-rules.sh would commit them; kickoff default: run without them and rely on the skill's own rules
KEEP_AWAKE: caffeinate -dis via scripts/keep-awake.sh — pid record in <git-dir>/overnight-loop/ (private); re-checked every turn, stopped at wrap-up
TICK_PROMPT: Overnight loop tick for `~/Pictures/GitHub Projects/swiftRobotDownloader`. You are mid-run: skip Phase 0. Follow the overnightprotocol turn contract — if its instructions are not in your context, first read `~/.claude/skills/overnightprotocol/SKILL.md`. Continue from the plan: resume the `[~]` item, else the top open item, else the ladder rung in the plan header. End the turn with ScheduleWakeup using this same prompt. Only /overnightprotocol stop from the user, or the plan's CEILING, ends the loop.
EVERY TURN: re-read this header + open items → handle user messages → check the ceiling → work → update this header → ScheduleWakeup(TICK_PROMPT)
STOP: the user runs /overnightprotocol stop (or presses the Stop button)

Mission (owner, 21 Oct 2026): "the main plan for this project is to convert it completely into swift" · "i'm going to sleep build as much as you can". Decisions D1–D3 and the kickoff defaults are in docs/PORT_PLAN.md and the report's Decisions section. The Swift app lives in `macos/`; the Electron code stays at the repo root untouched as the reference (docs/electron-reference/ cites it by path).

## Mission (official items — do these first)
- [~] 1. Decision-4 document — done when: docs/D4_BEHAVIOUR_DECISIONS.md holds a one-screen summary table of every item with the recommended answer, then the five checked area sections, with the consistency checker's contradictions resolved — STARTED 1792607752 · attempt 1 · approach: five writer agents + one checker (workflow), lead assembles · active: 0m · wip: none · delegated: workflow wuxkk3e13 · writes to the session scratchpad only
- [~] 2. Design brief — done when: docs/DESIGN.md states the product, the person, each screen's single job, real facts (data shapes, limits), the identity to keep (pure-black monochrome, sounds, funny lines), Light+Dark mapping, macOS conventions (menu bar, Settings window, sheets, keyboard, VoiceOver) and what must never happen — STARTED 1792607993 · attempt 1 · approach: background agent drafts from the reference, lead reviews · active: 0m · wip: none · delegated: background agent (design brief) · writes to the session scratchpad only
- [x] 3. Swift project scaffold — done when: `macos/` holds an XcodeGen `project.yml` for the app "robogears Downloader" (bundle id com.robogears.downloader, version 0.1.31, macOS 15+) plus a local Swift package `RobogearsCore` with a test target; `swift test` passes and `xcodebuild build` succeeds; .gitignore covers Xcode output — 6m
- [~] 4. Core: input and import parsing — done when: link parsing (TIDAL/Spotify forms per D4 4.1–4.3), CSV/plain-text tracklist parsing (4.5, 4.6, 4.17), filename sanitising (2.14), version compare and the TIDAL-compatible percent-encoder exist in RobogearsCore with unit tests built from the reference's worked examples — STARTED 1792608143 · attempt 1 · approach: parallel lane, implement → review → fix · active: 0m · wip: none · delegated: workflow wbgcdb3gj · worktree ../swiftRobotDownloader-lane-input|matching|tidal-models|tidal-client|audio-spikes (items 4–8 in that order), branch loop/core-<slug>
- [~] 5. Core: matching — done when: one Unicode-aware normaliser (3.1), one TIDAL matcher (3.2) and the library matcher (3.3–3.5, 3.13) exist with unit tests covering the reference's example tables and the new rules — STARTED 1792608143 · attempt 1 · approach: parallel lane, implement → review → fix · active: 0m · wip: none · delegated: workflow wbgcdb3gj · worktree ../swiftRobotDownloader-lane-<slug>, branch loop/core-<slug>
- [~] 6. Core: TIDAL models, manifests and Spotify embed — done when: Codable models, BTS/DASH manifest parsing (startNumber, r+1 segments, $Number$, XML unescape) and Spotify __NEXT_DATA__ extraction exist with synthetic-fixture tests — STARTED 1792608143 · attempt 1 · approach: parallel lane, implement → review → fix · active: 0m · wip: none · delegated: workflow wbgcdb3gj · worktree ../swiftRobotDownloader-lane-<slug>, branch loop/core-<slug>
- [~] 7. Core: TIDAL client — done when: URLSession client with per-call headers, device-code sign-in, one token keeper actor (refresh once on 401, shared renewal), retry/backoff policy (1.4) and a Keychain/file credential store exist, tested with a mock URLProtocol (no live calls) — STARTED 1792608143 · attempt 1 · approach: parallel lane, implement → review → fix · active: 0m · wip: none · delegated: workflow wbgcdb3gj · worktree ../swiftRobotDownloader-lane-<slug>, branch loop/core-<slug>
- [~] 8. Offline spikes with generated audio — done when: docs/spikes/ answers, with evidence, (a) can AVFoundation decode and play FLAC and DASH-style FLAC-in-fragmented-MP4, (b) exactly which tag keys and picture block the old FFmpeg arguments write, (c) can a native Swift writer produce an equivalent FLAC (tags + front-cover picture type 3) — STARTED 1792608143 · attempt 1 · approach: parallel lane, implement → review → fix · active: 0m · wip: none · delegated: workflow wbgcdb3gj · worktree ../swiftRobotDownloader-lane-<slug>, branch loop/core-<slug>
- [ ] 9. Download pipeline — done when: per-track download (segments in a TaskGroup of 8 or direct stream) → temporary file → tags and cover → length check → no-replace move into the flat download folder works end to end on a synthetic stream, with tests
- [ ] 10. Library scanner — done when: background folder walk, tag reader for FLAC/Ogg/MP4/ID3 (3.10), saved index (3.7) and scan defaults (3.8) exist with tests on generated files
- [ ] 11. Native UI — done when: a Fable-led design pass from docs/DESIGN.md is recorded, and the SwiftUI app shows the main window (input, drop zone, queue rows, activity), Settings window, sign-in sheet and menu-bar commands, wired to RobogearsCore; screenshots of real pixels in Light and Dark are checked
- [ ] 12. Preview player and waveform — done when: peaks (200 bars) and AVFoundation playback with scrubbing work on a generated file, one player at a time (5.16)
- [x] 13. Sound effects — done when: every sound (download chime, cancel chime, warning honk, success ping, brand easter eggs) is synthesised natively with the exact frequencies and envelopes from the reference — 14m
- [x] 14. Updater — done when: the GitHub-releases updater (owner's github-updater recipe, SHA-256 gate, asset contract `mac-arm64.dmg`) is implemented and unit-tested without touching the network for real installs — 25m
<!-- open = [ ] or [~]; resume [~] first
     [~] N. <item> — STARTED <epoch> · attempt <n> · approach: <one line> · active: <m>m · wip: <hash|none> [· delegated: <task/run id> · <worktree/branch>] [· interrupted]
     [x] N. <item> — <active>m
     [>] N. <item> — <reason> · shelved: overnight-loop/shelved/<slug>
     [!] N. <item> — blocked by <reason> (morning command in the report) -->

## Ladder backlog (self-generated when the mission is exhausted)
- [ ] L1. Unify version comparison — done when: one compare function serves the updater and the lane-input VersionCompare (UpdateVersion vs VersionCompare duplicate after the merge)
- [ ] L2. Release packaging script — done when: a script builds the Release app, the DMG named robogears-downloader-mac-arm64.dmg (.app at the root, for the v0.1.30 updater), the zip robogears-downloader-mac-arm64.zip, and a .sha256 for each; the CI workflow gains actions/checkout in the release job

## Parked — needs direction (never build these on a guess)
- ⏸ Live TIDAL check — question: run the device sign-in, a refresh with the second client pair, and record field names (user code, lifetime, version, presentation) — options: owner signs in once in the morning | skip — unlocks: verifying 1.3, 1.9, 2.7, 2.23 and the real download path
- ⏸ D4 2.6 same-title songs and 2.7 version text in file names — question: bend the title-only file-name rule as recommended, or keep it literal — options: A (recommended) | B (literal) — unlocks: the collision and naming code (built on the literal rule until answered)
- ⏸ Signing certificate (D4 1.5 / 5.7) — question: create a free self-signed code-signing certificate, or stay ad-hoc, or pay for a Developer ID — options: self-signed | ad-hoc | Developer ID — unlocks: Keychain storage without prompts, CI signing
- ⏸ Windows copies of v0.1.30 (D4 5.8) — question: farewell Windows build, or uninstall by hand — unlocks: the first Swift release
