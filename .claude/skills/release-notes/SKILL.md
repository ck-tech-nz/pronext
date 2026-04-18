---
name: release-notes
description: Use when creating/updating a PR, preparing a release, or archiving released notes across multi-component repos (Pad, Mobile, Server, H5, Heartbeat).
---

# Release Notes Skill

## Configuration

```yaml
components:
  - name: Pad
    path: pad/
    tag_format: "v{semver}+{build}"
  - name: Mobile
    path: app/
    tag_format: "v{semver}+{build}"
  - name: Server
    path: backend/
    tag_format: "v{date}[-{suffix}]"
  - name: H5
    path: h5/
    tag_format: "v{date}[-{suffix}]"
  - name: Heartbeat
    path: heartbeat/
    tag_format: "v{date}[-{suffix}]"

release_notes_dir: docs/releases/   # relative to each component's own repo root
language: en                        # write in English; translate to zh-CN only if user asks
```

## Core Model

**Release notes live in PR bodies during development, in `{component}/docs/releases/` after release.** One PR = one release note entry. No per-commit draft files. No centralized archive — each component repo owns its own release history.

On finalize, aggregate release-note blocks from all merged PRs since the last tag and write a single `{tag}.md` into that component's `docs/releases/`. The user commits that file via their normal PR workflow.

## Block Format

Every PR body for a user-facing change must contain this block:

```markdown
<!-- RELEASE_NOTE_START -->
## Release Note

### New Features
- ...

### Improvements
- ...

### Bug Fixes
- ...
<!-- RELEASE_NOTE_END -->
```

Optional lock marker (skip auto-regen):
```markdown
<!-- RELEASE_NOTE_LOCKED -->
```

## On PR Create / Update

When the user asks to create or update a PR (e.g., `/feat`, `gh pr create`, "push and open PR", "update PR"):

1. Diff `origin/main...HEAD` to collect changes on this branch.
2. Classify each commit as user-facing (new feature / improvement / bug fix) or not (refactor, tests, CI, deps, internal docs).
3. Generate the block above with user-facing entries grouped by section. Empty sections should be omitted.
4. If the PR body already contains `<!-- RELEASE_NOTE_LOCKED -->`, **skip regeneration** (respect manual edits).
5. Otherwise:
   - On create: include the block at the top of the PR body (above the existing PR template/summary).
   - On update: **replace** the region between `<!-- RELEASE_NOTE_START -->` and `<!-- RELEASE_NOTE_END -->` entirely. Content outside the block is preserved.
6. Apply via `gh pr create --body` or `gh pr edit {N} --body`.

### What counts as user-facing

User/marketing language only. Translate backend changes into user impact (e.g., "API batch support" → "syncing is faster").

**Exclude:** refactors, test code, CI/CD, internal docs, dep upgrades (unless user-visible).

## Prepare Release

When the user says "prepare release {component}" / "准备发布":

1. **Confirm** the component and version number (e.g., `v2026-04-18`).
2. In the **component's own repo**, determine `{last_tag}` via `git describe --tags --abbrev=0`.
3. **List merged PRs** since last tag (run in the component repo):
   ```
   gh pr list --state merged --base main \
     --search "merged:>{last_tag_date}" \
     --json number,title,body,mergedAt,files
   ```
4. **Extract** the block between `<!-- RELEASE_NOTE_START -->` / `<!-- RELEASE_NOTE_END -->` from each PR body. PRs missing the block are flagged for manual review.
5. **Fallback commit scan**: `git log {last_tag}..HEAD --no-merges --oneline` in the component repo. List any commit not reachable from a merged PR in step 3 — user triages these (direct pushes / hotfixes).
6. **Flag open PRs** targeting main — warn the user this work won't ship unless merged first.
7. **Aggregate + dedupe** entries, present to user for confirmation.

If the repo has no previous tag, ask the user for scan range.

## Finalize

When the user says `finalize {component}` / "完成发布 {component}":

**Run this BEFORE merging the last PR of the release**, while checked out on that PR's feature branch. The goal: the aggregated release-notes file ships **inside the same PR** so that when it merges, release notes land on main atomically with the feature. No follow-up docs PR.

1. Re-run the Prepare Release aggregation. Sources:
   - Merged PRs to main since `{last_tag}` (extract `RELEASE_NOTE_START`/`END` blocks from their PR bodies)
   - **Current branch's own PR body** (if it has a block) — this is the in-flight PR being finalized
   - Fallback commit scan for anything not covered
2. Write the file to `{component}/docs/releases/{tag}.md` **in the component's own repo**:
   ```markdown
   # {tag}

   ## New Features
   - ...

   ## Improvements
   - ...

   ## Bug Fixes
   - ...
   ```
   Example: `h5/docs/releases/v2026-04-18.md`
3. Stop. **Do not commit, do not push, do not tag.** The user:
   - Reviews the generated file
   - Commits it to the **current feature branch** (the one whose PR is about to ship)
   - Pushes; the PR auto-updates
   - Merges the PR → release notes land on main with the feature
   - Tags the component repo with `{tag}` per its `tag_format`

**Why "before merge":** Running finalize *after* merge forces a second docs-only PR. Running it before merge lets one PR carry both feature code and its release notes.

**Scope rules:**
- The file lives **only** inside the component's own repo — never in the pronext parent repo, never cross-component.
- Multi-component release = one `finalize` invocation per component, each on its own branch/PR.
- No central archive. No cross-component aggregation file.

No draft files to delete — they don't exist under this flow.

## Edge Cases

- **Direct push to main (no PR)**: Caught by the fallback commit scan at release time.
- **Locked PR body**: Skill skips regen; user owns the content.
- **PR with no user-facing changes**: Generate no block (or an empty placeholder stating "no user-facing changes"). Don't force fake content.
- **Squash-merged PRs**: One PR body = one aggregate entry. That's the whole point.
- **Cross-component PR**: The same block ships against every component whose path is touched; at release time, path-based filtering routes it correctly. Sections may include per-component labels if needed.
- **Feature branches off other feature branches**: Diff `origin/main...HEAD` may include commits from the parent branch. Use `--base {parent}` override if needed.
