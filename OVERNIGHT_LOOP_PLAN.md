# Overnight Loop Plan — 2026-10-26

<!-- run metadata — recovery reads this first; update it at the end of every turn -->
STATE: LOOPING
PROJECT_PATH: ~/Developer/swiftRobotDownloader
SKILL_PATH: ~/.claude/skills/overnightprotocol/SKILL.md
START_EPOCH: 1793004557
LAST_TURN_EPOCH: 1793016747
CEILING_EPOCH: none         # or <int> if the user set a stop time
BASE_BRANCH: main
BRANCH: overnight-loop/2026-10-21-2235   # the existing branch the owner works on (kickoff default: stay)
RUNG: mission               # mission | 1-qa | 2-audit | 3-qol
CYCLE: 0                    # completed ladder cycles
LAST_AUDIT: none            # <epoch> <commit> — re-audit only after ≥5 new loop: commits
DENY_RULES: none — the repo tracks .claude/settings.local.json, so deny-rules.sh would commit them; kickoff default: run without them and rely on the skill's own rules
KEEP_AWAKE: caffeinate -dis via scripts/keep-awake.sh — pid record in <git-dir>/overnight-loop/ (private); re-checked every turn, stopped at wrap-up
TICK_PROMPT: Overnight loop tick for `~/Developer/swiftRobotDownloader`. You are mid-run: skip Phase 0. Follow the overnightprotocol turn contract — if its instructions are not in your context, first read `~/.claude/skills/overnightprotocol/SKILL.md`. Continue from the plan: resume the `[~]` item, else the top open item, else the ladder rung in the plan header. End the turn with ScheduleWakeup using this same prompt. Only /overnightprotocol stop from the user, or the plan's CEILING, ends the loop.
EVERY TURN: re-read this header + open items → handle user messages → check the ceiling → work → update this header → ScheduleWakeup(TICK_PROMPT)
STOP: the user runs /overnightprotocol stop (or presses the Stop button)

Mission (owner, 26 Oct 2026): "finish the shelved branches and merge them" · "run /overnightprotocol, its looking good but lets also allow song preview on search and fix up the ui make it cleaner". The previous run (21–26 Oct) is archived in .overnight-loop/archive/2026-10-21/. Lane briefs: .overnight-loop/briefs/. Behaviour spec: docs/D4_BEHAVIOUR_DECISIONS.md (every option A). Design: docs/DESIGN.md, docs/DESIGN_DIRECTION.md.

## Mission (official items — do these first)
- [~] 1. Finish the six shelved lanes and merge them (owner, 26 Oct) — done when: each lane (m4a, folder, track, batch, resolver, native UI) is finished, independently reviewed and fixed; they are merged into the loop branch one at a time (m4a → folder → track → batch → resolver → UI), each merge passing the full core suite, the app build and the app's self-checks; an integration review of the merged pieces has had its upheld findings fixed; the lane worktrees are removed — STARTED 1793004897 · attempt 1 · approach: one workflow finishes → reviews (UI: code + design, Opus) → fixes each lane in its own worktree; then sequential merges here, each behind a gate (clean working copy, no mutation-check leftovers in the diff, lane tests green; the plan's risk list in docs/INTEGRATION_PLAN.md §6) · merged so far: folder fb0517b, track 3c38681, batch 999a533, resolver b1b6d56 (QueueItem conflict: both lanes' fields kept; withID copies them; new rows set losslessOnTIDAL; pending library checks held from Download All), m4a a24fbfe — 1181 tests pass · UI fix round cut off by the usage limit (WIP 92a7f8b), resumed · active: 40m · wip: b1b6d56 (verified since) · delegated: workflow wgmm53b0r (run wf_182fdab8-6fd resumed) · worktrees ~/Developer/swiftRobotDownloader-lane-{m4a,folder,track,batch,resolve,ui}, branches loop/dl-*, loop/resolve, loop/ui
- [ ] 2. A cleaner UI (owner, 26 Oct: "fix up the ui make it cleaner") — done when: a single design lead's critique of the real screens (snapshots, Light/Dark/Increase Contrast) against the owner's rules and DESIGN_DIRECTION is recorded in docs/, the refinements are built after item 1's UI merge, and checked in fresh snapshots; the black monochrome waveform identity is kept
- [ ] 3. Song preview in search (owner, 26 Oct: "allow song preview on search") — done when: every search result row has the same play button and scrubbable waveform as queue rows; one preview at a time across queue and search (D4 5.16); keyboard and VoiceOver labels per 5.18; shown in snapshots; works with the stand-ins and with the real preview service once item 4 lands
- [~] 4. Wire the real services into the app (kickoff default) — done when: the app's service protocols are backed by RobogearsCore (TIDAL sign-in via DeviceSignIn and TokenKeeper with the file credential store, the resolver, the library index and matcher, the download folder + track downloader + batch runner, previews via the audio fetcher + PreviewCache + WaveformPeaks + Now Playing, the updater); stand-ins remain only for snapshots and self-checks; everything tested against mocks; a live check for the first real sign-in and download is written down for the owner — STARTED 1793004945 · attempt 1 · approach: integration plan written (docs/INTEGRATION_PLAN.md: protocol-by-protocol mapping, object graph, previews incl. search preview, sign-in, 13-step build order, merge risks); build its steps after item 1's merges · active: 6m · wip: none
<!-- open = [ ] or [~]; resume [~] first
     [~] N. <item> — STARTED <epoch> · attempt <n> · approach: <one line> · active: <m>m · wip: <hash|none> [· delegated: <task/run id> · <worktree/branch>] [· interrupted]
     [x] N. <item> — <active>m
     [>] N. <item> — <reason> · shelved: overnight-loop/shelved/<slug>
     [!] N. <item> — blocked by <reason> (morning command in the report) -->

## Ladder backlog (self-generated when the mission is exhausted)
- [ ] L1. One FLAC tag reader — done when: the library's FLACCommentReader and the spikes' FLACMetadataReader.summary are one code path (carried over from the last run)

## Parked — needs direction (never build these on a guess)
- ⏸ Live TIDAL check — question: run the device sign-in, a refresh with the second client pair, and one real download, recording the field names (user code, lifetime, version, presentation) — options: owner signs in once | skip — unlocks: verifying D4 1.3, 1.9, 2.7, 2.21, 2.23 against real TIDAL answers
- ⏸ Signing certificate (D4 1.5 / 5.7: owner chose the free self-signed certificate) — needs the owner to create it in Keychain Access and name it; until then builds stay ad hoc and the sign-in uses the private 0600 file
- ⏸ Windows copies of v0.1.30 (D4 5.8: the farewell Windows build) — the Electron change is done on branch loop/windows-farewell (eadd4fa, pushed); its setup.exe needs the old Electron CI (Node 20 actions may need a bump) at ship time
