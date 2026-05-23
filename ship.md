# How to ship a release

## When you ship

Never on your own. Only when the user explicitly says one of:

- "ship it" / "publish" / "release" / "push it"
- "tag vX.Y.Z" / "do a release"
- Any close paraphrase that clearly authorizes a release

When you make code changes outside of an explicit ship instruction:

- Make the edit
- Run a syntax/build check if applicable
- Stop there. Do NOT bump version, edit release notes, commit, push, or tag.

The reason: each tag triggers a CI build (~5–10 min per platform) and produces a new draft on GitHub. The user wants to batch related changes and ship them as one cohesive release, not one tag per fix.

## When you do ship — the exact sequence

### 1. Bump the patch version

In `package.json` (or the project's version file), bump to the smallest unused `vX.Y.Z`. Patch bump by default. Minor bump only for a large batch of new features. Major bump only for genuinely breaking changes.

**Never force-move an existing published tag.** The narrow exception is unpublished drafts — if both the tag's GitHub release is still in draft state AND the user has confirmed they want to redo it, you can delete the tag (locally + on origin) and re-tag the same version. Otherwise: always bump to a new number.

### 2. Overwrite RELEASE_NOTES.md

Replace the file entirely with the new version's body. **Do not** keep older versions' sections at the bottom — previous releases stay accessible on the GitHub Releases page; repeating them here just clutters every body.

The body MUST include all four parts, in this order:

```
# What's new in vX.Y.Z

## <Short subsection heading per feature group>
- Short bullet describing the change. What it does, why it matters.
- Another bullet if needed. Keep bullets tight; no paragraphs.

## <Another subsection if there's a distinct second area>
- ...

---

# Install

- **<Platform 1>**: download `<artifact-name>`, run it. <Any platform-specific notes — SmartScreen, Gatekeeper, etc.>
- **<Platform 2>**: ...

<Optional one-line note about where config lives, if relevant.>

## Requirements

- <Subscription / API key / dependency requirements>
- <Any hard limits like rate caps>

---

**Full Changelog**: https://github.com/<owner>/<repo>/compare/v<PREV>...v<CURR>
```

The headings, ordering, and changelog link are not optional — they're the contract the workflow's `body_path` consumer expects, and they're what users scan when deciding whether to update.

### 3. Commit, push, tag, push tag

Single chained command so it either all succeeds or you can see exactly where it failed:

```bash
git add <files...>            # be explicit, not `git add -A`
git commit -m "$(cat <<'EOF'
vX.Y.Z: <one-line summary>

<2–4 short paragraphs explaining what changed and why.
Include root cause if this is a bug fix.>

Co-Authored-By: <AI name> <noreply@anthropic.com>
EOF
)"
git push origin main
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

The annotated tag (`-a`) is required — lightweight tags work but annotated ones carry metadata your CI may rely on.

Pushing the tag is what triggers the build. Don't skip it.

### 4. Wait for CI

Use the project's CI tooling (e.g., `gh run watch <run-id>`) to block until the workflow finishes. Don't move on until both build jobs and the release job have completed.

### 5. Verify the release body

**This is the step you must not skip.** Many GitHub release actions (notably `softprops/action-gh-release`) silently leave the body empty when they're updating an already-existing release for the tag. Always verify:

```bash
gh release view vX.Y.Z --json body --jq '(.body | length)'
```

If the result is `0` (or suspiciously small):

```bash
gh release edit vX.Y.Z --notes-file RELEASE_NOTES.md
```

Then re-verify the length. Don't report success until the body has the expected content.

### 6. Report back

Tell the user:

- Link to the workflow run (Actions tab)
- Link to the draft release (Releases tab)
- That the release is in **draft** state and they need to review and click **Publish** themselves when ready

## Hard rules — never violate

- **Never** change `draft: true` to `false` in the CI workflow. Every release must land as a draft so the user reviews artifacts + notes before publishing.
- **Never** force-move a published tag. Bump to a new version instead.
- **Never** skip step 5 (body verification). The empty-body quirk is silent but catastrophic — users see an empty release page and panic.
- **Never** commit `.env`, credentials, token files, build artifacts, or anything in `.gitignore`. Stage files explicitly by name.
- **Never** auto-release without explicit user instruction. If the user asked for a code change, deliver the code change and stop.
- **Never** skip a hook with `--no-verify` or bypass signing with `--no-gpg-sign` unless the user explicitly authorizes it. If a hook fails, fix the underlying issue.

## Common failure modes

- **Empty release body after CI completes.** `softprops` re-running on an existing release. Fix with `gh release edit`. Step 5 catches this.
- **CI fails with "GH_TOKEN is not set"** in an electron-builder project. Add `publish: null` to the build config so electron-builder doesn't try to auto-publish on tag push.
- **Tag pushed but no workflow runs.** Confirm the workflow has a `tags` trigger pattern matching your tag name (commonly `v*`).
- **`gh` not on PATH after install.** Use the absolute path to the binary. On Windows with winget: `C:\Users\<user>\AppData\Local\Microsoft\WinGet\Links\gh.exe`.

## Tone

When you report, lead with what shipped. One table summarizing the changes, then the URLs. No preamble. The user can read the diff if they want details. End-of-turn summary should be one or two sentences max.
