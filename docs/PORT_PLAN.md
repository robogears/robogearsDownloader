# Swift port: plan

**State:** overnight build running (branch overnight-loop/2026-10-21-2235); D4 waiting for the owner · **Phase:** 1 of 4 (understand → decide → spike → build) · **Last checkpoint:** 21 Oct 2026, full reference written to [`electron-reference/`](electron-reference/README.md).

**Standing rules:**
- The owner's global `~/.claude/CLAUDE.md` and the Agent Operating Manual apply.
- Nothing is built until the owner picks a direction.
- No commits, pushes or releases without an explicit ship instruction.
- The Electron code in this folder stays untouched as the reference.

## Owner's requests

| # | Request (owner's words, date) | Done when | State |
|---|---|---|---|
| 1 | "deep research one of my old projects, originally called robogearsDownloader … completely understand all of the code first … the main plan for this project is to convert it completely into swift, before you do anything make sure you fully understand the code" (21 Oct 2026) | Every file and behaviour is mapped and checked against the code, with a written reference that a Swift build can follow without opening the JS. | **Research done**: [electron-reference/README.md](electron-reference/README.md) plus 19 sections, 1,945 claims checked. The conversion itself is **queued**, waiting on decisions D1–D4. |
| 2 | "bot prompt may be outdated" (21 Oct 2026) | The stale docs are identified. | **Done.** BOT_PROMPT.md is at v0.1.16 and CLAUDE.md at v0.1.25; the drift ledger is in [docs-drift-rules-and-history.md](electron-reference/docs-drift-rules-and-history.md). The code is treated as the source of truth. |
| 3 | "lets end support for the chrome extension" (21 Oct 2026) | The Swift app has no extension, localhost bridge, managed folder or Extension tab, and keeps the shared matcher. | **Decided.** Removal inventory in [chrome-extension-removal.md](electron-reference/chrome-extension-removal.md). Assumption: the Electron code is not edited now; the extension simply isn't ported. |

## Decisions made

Owner's answer, 21 Oct 2026: "yes macos only, same githubrepo, 3 lets start from scratch, go in detail for 4".

| # | Decision | Effect |
|---|---|---|
| D1 | **macOS only** (owner, 21 Oct 2026) | The Windows build ends. Target is Apple Silicon, macOS 15 or later (recommended default, not separately confirmed). |
| D2 | **Same GitHub repo**, `robogears/robogearsDownloader` (owner, 21 Oct 2026) | The Swift app continues the version series. GitHub has v0.1.30, so the next version is **0.1.31**; it will be set in the Xcode project when that exists. The Electron `package.json` stays as the untouched reference. The first Swift release must keep the old updater's contract: a tag above 0.1.30, an asset containing `mac-arm64.dmg`, and the `.app` at the DMG root. |
| D3 | **Start from scratch** (owner, 21 Oct 2026) | No import of the Electron app's `settings.json`, `queue.json` or `token.json`; the user signs in and picks folders again. Files already in the download folder are still there and still count for skip-if-exists. |
| D4 | Owner asked to "go in detail" | [D4_BEHAVIOUR_DECISIONS.md](D4_BEHAVIOUR_DECISIONS.md): 68 decisions with a recommended option each, plus 23 plain fixes. Waiting for the owner; the overnight build uses the recommended options except 2.6 and 2.7, which stay on the literal title-only rule. |

## Decisions waiting on the owner (they change what gets built)

| # | Question | Recommended default |
|---|---|---|
| D1 | **Platforms.** Should the Swift app be macOS only? That ends the Windows build, which currently ships as an NSIS installer. | macOS only, Apple Silicon, macOS 15 or later. |
| D2 | **Repository and version series.** Should the Swift app ship from `robogears/robogearsDownloader` and continue the numbering at **0.1.31**, so today's Mac users get it through the v0.1.30 updater? The alternative is a new repository starting at **0.1.1** (the owner's rule for a new project), where existing users must install it by hand. | Same repository, continue at 0.1.31, keep the `robogears Downloader` name and the `com.robogears.downloader` bundle ID. |
| D3 | **Carry-over data.** Should the Swift app import the existing sign-in, folders and queue from `~/Library/Application Support/robogears Downloader/`? | Import once on first launch and move the TIDAL token into the Keychain. Leave the old files where they are. |
| D4 | **Fix or reproduce.** The defects in the reference (H1–H3, M1–M11) are fixed by default. A few fixes change behaviour the owner may rely on: Unicode-aware matching changes which tracks count as duplicates; greyed library rows would stay after a batch; Cancel would stop the current track and delete its partial file. | Fix all of them and keep every product rule. Title-only filenames stay (owner's rule 3), with a visible "skipped: same title" reason instead of a silent skip. |

**Smaller choices.** These have defaults and won't block the spikes:
- Keychain vs file for tokens
- App Sandbox (default: off)
- Sparkle 2 vs the hand-rolled updater
- Keep the sound effects and easter eggs (default: keep)
- Light mode (default: dark only, as today, pending the design brief)
- Whether to port the CLI tools (default: no)
- Waveform pre-loading (default: on demand, peaks cached on disk)

## Next phases (after D1–D4)

1. **Spikes** (each needs a live run; listed in the reference README):
   - TIDAL auth from Swift
   - AVFoundation decoding of TIDAL FLAC and fMP4
   - FFmpeg tag keys vs a native FLAC writer
   - library tag reader and scan speed
   - updater migration contract
2. **Design brief** in `docs/DESIGN.md`, then a Fable-led design pass (`apple-design` skill), keeping the monochrome identity.
3. **Build** in small, revertible units, each through the review pipeline in the manual.

## Versioning note

The Electron `package.json` stays at 0.1.30 (identical to GitHub); only documents were added to this folder. Where the Swift app's version starts depends on D2.

## Leftovers / observations

- CI: the release job lacks `actions/checkout`, which is the likely cause of empty release bodies. It is also pinned to Node 20, whose deadline has passed. This matters only if the Electron CI is ever run again.
