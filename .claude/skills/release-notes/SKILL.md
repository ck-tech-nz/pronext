---
name: release-notes
description: Automatically track user-facing changes during development. Appends to RELEASE_NOTES_DRAFT.md in each component repo on every commit, scans git log before release to catch missed items, and archives to docs/releases/. Use when committing code or preparing a release.
---

# Release Notes Skill

## Configuration

Adapt these settings for your project:

```yaml
components:
  - name: Pad
    path: pad/
    draft: pad/RELEASE_NOTES_DRAFT.md
    tag_format: "v{semver}+{build}"
  - name: Mobile
    path: app/
    draft: app/RELEASE_NOTES_DRAFT.md
    tag_format: "v{semver}+{build}"
  - name: Server
    path: backend/
    draft: backend/RELEASE_NOTES_DRAFT.md
    tag_format: "v{date}[-{suffix}]"
  - name: H5
    path: h5/
    draft: h5/RELEASE_NOTES_DRAFT.md
    tag_format: "v{date}[-{suffix}]"
  - name: Heartbeat
    path: heartbeat/
    draft: heartbeat/RELEASE_NOTES_DRAFT.md
    tag_format: "v{date}[-{suffix}]"

archive_path: docs/releases/
language: zh-CN
```

## On Every Commit

When the user requests a commit (e.g., `/commit`, "commit", or any commit request):

1. **Check**: Does this commit contain user-facing changes? (new feature, UI improvement, bug fix visible to users)
2. **If yes**: Append an entry to `RELEASE_NOTES_DRAFT.md` in the **same component repo** being committed
3. **If the draft file doesn't exist**: Create it with this template:

```markdown
# {Component} (Draft)
<!-- version: TBD -->

## New Features

## Improvements

## Bug Fixes
```

4. **Append** the entry under the appropriate section (New Features / Improvements / Bug Fixes)
5. **Include the draft file change in the same commit** (atomic — same repo, same commit)

### What to write

- User/marketing language only — no technical jargon
- One line per entry, concise
- Backend changes that affect user experience should be translated (e.g., "API batch support" -> "syncing is faster")
- Chinese by default (configurable via `language` setting)

### What NOT to write

- Pure refactoring / code cleanup
- Test code changes
- CI/CD configuration
- Documentation updates (unless user-visible help docs)
- Dependency upgrades (unless they bring user-facing improvements)

### Cross-component changes

- Only write in the repo being committed
- If one change spans server + pad, each gets its own entry when committed in its respective repo

## Before Release

When the user says "prepare release" / "准备发布" or similar:

1. **Confirm** which components and version numbers are included
2. **Scan git log** for each component: `git log $(git describe --tags --abbrev=0)..HEAD --oneline` in each repo
3. **Review ALL commits** (not just feat/fix prefixed) — judge whether each is user-facing
4. **Cross-reference** with the draft file, add any missed items
5. **Update version number** in the draft (replace `<!-- version: TBD -->`)
6. **Present** the final release notes to the user for confirmation

If a repo has no previous tag, ask the user for the scan starting point or scan all commits.

## After Release

Once the user confirms release:

1. **Only archive components included in this release** — other drafts stay untouched
2. **Merge** released component drafts into one archive file:

```markdown
# Release {YYYY-MM-DD}

## Pad v2.3.0

### New Features
- ...

### Improvements
- ...

### Bug Fixes
- ...

## Mobile v1.7.0
...
```

3. **Save** to `docs/releases/{year}/{MM-DD}_{component-versions}.md`
   - Example: `docs/releases/2026/03-14_pad-v2.3.0_mobile-v1.7.0.md`
   - Single component: `docs/releases/2026/03-14_pad-v2.3.0.md`
4. **Delete** `RELEASE_NOTES_DRAFT.md` from each released component repo, commit the deletion
5. **Tag** each released repo (using its tag format from configuration)
6. **Commit** the archive file to the docs repo

## Edge Cases

- **Feature branches**: Draft follows the branch; content merges naturally into main
- **Reverted commits**: Manually remove the corresponding draft entry
- **Draft merge conflicts**: Append-only format makes conflicts rare; resolve normally if they occur
- **No tag exists**: Ask user for scan range or scan all commits
