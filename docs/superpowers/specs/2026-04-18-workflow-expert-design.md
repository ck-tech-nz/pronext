# workflow-expert Skill — Design

**Date:** 2026-04-18
**Status:** Approved design, pending implementation plan
**Author:** ck

## 1. Purpose

A single project-level Claude Code skill that owns the entire issue-to-deploy developer workflow for the pronext monorepo. It unifies branch creation, PR authoring, review handling, merge, and deploy-time notification under one directory, shareable with the team via git.

The skill replaces the user-level `~/.claude/skills/github/` for this project and absorbs the PR release-note block format from the existing `release-notes` skill.

## 2. Goals

- **End-to-end orchestration.** A user can go from an issue reference (or free-text description) to a merged, deployed, team-notified change with a small set of explicit commands.
- **Team-shareable.** Everything lives under the project repo, in `.claude/skills/workflow-expert/`. Cloning the repo is sufficient onboarding; each developer fills in personal API tokens once.
- **Pluggable requirement sources.** GitHub issues work now; Sentry and DevTrakr have stub adapters ready to light up when API keys are configured.
- **Single-source-of-truth in GitHub.** Tickets from Sentry / DevTrakr are mirrored to GitHub issues so every PR can `Closes #N` against a real GH issue.
- **Non-intrusive notifications.** A hook fires at two events (PR merge to main; deploy to env/prod) and calls a stub script. Future wiring to Slack / Feishu / email replaces only that one file.

## 3. Non-Goals

- **Not** a replacement for normal coding — step 3 of the user's workflow (writing code, committing) is ordinary conversation with Claude, not a scripted flow.
- **Not** an automation layer for the `/release` archiving pass that aggregates PR release notes into `{component}/docs/releases/{tag}.md`. That logic stays in the `release` playbook (migrated from the existing github skill), because it is not part of the issue-to-merge flow.
- **Not** supporting multiple notification channels at launch. One stub, one future-wiring point.
- **Not** automating step 3 commits or forcing commit message conventions beyond what the github skill already enforces.

## 4. Decisions (summary of brainstorm outcomes)

| # | Decision | Notes |
|---|---|---|
| 1 | **Compose, not replace** the github skill — but physically move its content into workflow-expert as playbooks. | User-level `~/.claude/skills/github/` stays untouched for other projects. |
| 2 | Requirement sources: **GitHub only for now**, Sentry/DevTrakr as stubs. | `sources/*.sh` adapter pattern, uniform JSON contract. |
| 3 | Notification: **stub only**, triggered at PR merge and deploy-to-prod. | Single file `scripts/notify.sh` — future integrators edit only this. |
| 4 | Scope of new logic: **4 things** — fetch issue, self-review + PR, address reviews, notify. The other 4 steps of the 7-step flow are either normal coding or covered by migrated playbooks. | |
| 5 | PR review scope: **self-review before PR** (quality gate) **+ address reviewer comments** (loop back). | Reviewing *others'* PRs stays in the `review` playbook. |
| 6 | Trigger mechanism: **3 new slash commands** `/wf-start /wf-pr /wf-reviews` + 5 migrated `/fix /feat /hotfix /review /release` + 1 natural-language phrase "squash and merge to main". All registered by one SKILL.md. | |
| 7 | Input syntax for `/wf-start`: **prefixed source IDs** `i99 / s99 / d99` (aliases `issue#99 / sentry#99 / devtrakr#99`) **+ free text** that creates a new GitHub issue first. | |
| 8 | Release-note block: **inlined** into workflow-expert's SKILL.md (M1). The `<!-- RELEASE_NOTE_START -->` markers are preserved for compatibility with the `release` playbook that scans PRs at release time. | |
| 9 | Hooks live inside the skill directory at `hooks/`, registered from `settings.json`. | Skill stays self-contained; copying the directory = copying the entire capability. |
| 10 | **Skill, not agent.** Agents can be dispatched *inside* `/wf-reviews` for parallel comment analysis, but the skill itself is interactive. | |
| 11 | Branch naming: **unified** format `<gh_login>/<identifier>-<english_slug>`. `identifier` is either the issue number (when one exists) or the command type (`fix / feat / hotfix`). | Chinese titles are translated to English by Claude before slugifying. |
| 12 | Username source: **`gh api user --jq .login`**, not git config. | |
| 13 | Slug length: **no truncation** — mirror GitHub's generated length. | |

## 5. Directory Structure

```
.claude/
├── skills/
│   └── workflow-expert/
│       ├── SKILL.md                       # Entry point: command registry + top-level dispatch
│       ├── README.md                      # Onboarding: clone → cp config.env.example config.env
│       ├── playbooks/
│       │   ├── feat.md                    # /feat
│       │   ├── fix.md                     # /fix
│       │   ├── hotfix.md                  # /hotfix
│       │   ├── review.md                  # /review (reviewing others' PRs)
│       │   ├── release.md                 # /release (env/test | env/prod)
│       │   ├── squash-merge.md            # "squash and merge to main"
│       │   ├── wf-start.md                # /wf-start <input>
│       │   ├── wf-pr.md                   # /wf-pr
│       │   ├── wf-reviews.md              # /wf-reviews [pr#]
│       │   └── atomic-ops.md              # shared: check-clean, update-main, branch-slug, etc.
│       ├── sources/
│       │   ├── github.sh                  # gh issue view <id>  → JSON
│       │   ├── sentry.sh                  # stub: exit 2 "not configured"
│       │   └── devtrakr.sh                # stub: exit 2 "not configured"
│       ├── scripts/
│       │   ├── parse_source.sh            # "i99"/"s99"/"99"/free text → {source, id|text}
│       │   ├── slug.sh                    # english title → kebab-case
│       │   └── notify.sh                  # stub; edit this file to wire real channel
│       ├── hooks/
│       │   └── post-merge-notify.sh       # PostToolUse matcher → dispatch notify.sh
│       ├── config.env.example             # committed: SENTRY_TOKEN= DEVTRAKR_TOKEN= ...
│       └── config.env                     # gitignored: personal tokens
└── settings.json                          # registers the hook
```

User-level `~/.claude/skills/github/` is **left untouched** (decision 1A). It still works in other projects; in pronext it is shadowed by workflow-expert because project-level skills take precedence.

## 6. Commands

### 6.1 `/wf-start <input>`

The single entry point for starting work from a requirement.

**Input grammar** (parsed by `scripts/parse_source.sh`):

| Pattern | Interpretation |
|---|---|
| `i<N>` / `issue#<N>` / `issue <N>` / bare `<N>` (digits only) | GitHub issue #N |
| `s<N>` / `sentry#<N>` / `sentry <N>` | Sentry issue N |
| `d<N>` / `devtrakr#<N>` / `devtrakr <N>` | DevTrakr ticket N |
| anything else (free text) | Create a new GitHub issue with this as title/body |

**Flow:**

1. Parse input → `{source, id}` or `{source=new, text}`.
2. Branch on source (all three call through the uniform adapter contract in section 7):
   - **github**: `sources/github.sh <id>` (thin wrapper around `gh issue view <id> --json title,body,labels,url`). Use the returned issue number for the rest of the flow.
   - **sentry / devtrakr**: `sources/<source>.sh <id>`. If exit 2 (not configured), report to user and abort; if success, extract `{title, body, url}` and **mirror into a new GH issue** via `gh issue create --title "<title>" --body "From <source> #<id>: <url>\n\n<body>"`. Use the returned GH issue number for the rest of the flow.
   - **new**: derive a concise title from `text` (Claude), then `gh issue create --title "<title>" --body "<text>"`. Use the new issue number.
3. After step 2 there is always a GitHub issue number + title + labels.
4. **Translate title to English** if non-ASCII, then slugify (`scripts/slug.sh`). Example: `154-测试修复bug` → `ck/154-test-bug-fix`.
5. Get `<gh_login>` via `gh api user --jq .login`.
6. Compose branch name: `<gh_login>/<issue#>-<slug>`. No truncation.
7. Atomic-ops (from `playbooks/atomic-ops.md`): verify repo, check clean tree, `git checkout main && git pull`, `git checkout -b <branch>`.
8. Output issue summary + branch state; user is ready to code.

**Branch examples:**

| Input | Issue title | Branch |
|---|---|---|
| `i143` | "All-day events not show on device dashboard page" | `ck/143-all-day-events-not-show-on-device-dashboard-page` |
| `s501` | (from Sentry) "Null pointer in CalendarSync" | `ck/<mirrored#>-null-pointer-in-calendar-sync` |
| `154` | "测试修复bug" | `ck/154-test-bug-fix` |
| `"add dark mode"` | (new GH issue) | `ck/<new#>-add-dark-mode` |

### 6.2 `/wf-pr`

Turn the current branch into a PR with a release-note block.

**Flow:**

1. Determine current branch. Extract `<issue#>` from branch name (first segment after `<user>/`); abort with a prompt if the branch does not follow the convention.
2. **Self-review pass:** read `git diff main..HEAD`. Claude flags: absent tests for changed logic, hardcoded values that should be config, leftover `TODO`/`console.log`/`print`, scope creep. Present findings.
3. If concerns found, ask: `continue` / `fix now` / `ignore specific items`. On `fix now`, loop back to the self-review after changes.
4. Generate release-note block using the inlined format (section 8).
5. Compose PR body:
   ```
   Closes #<issue#>
   
   <release-note block>
   
   ## Test Plan
   - [ ] ...
   ```
   Test plan items are inferred from the diff; Claude proposes, user edits.
6. Infer PR title: `<type>: <summary>`. `<type>` from issue labels (`bug`→fix, `enhancement`→feat) or from branch type-identifier (for no-issue branches).
7. `gh pr create --title "..." --body "..." --base main`.
8. Report the PR URL.

### 6.3 `/wf-reviews [pr#]`

Address reviewer comments on your own PR.

**Flow:**

1. If `pr#` omitted, infer from current branch: `gh pr list --head $(git branch --show-current) --json number --jq '.[0].number'`.
2. `gh pr view <pr#> --json reviews,comments` → collect all review threads. Filter out resolved.
3. Group comments by file:line. Within each group, read the latest state.
4. If the count of unresolved threads is ≥ 5, **dispatch parallel subagents** (one per thread) to analyze in isolation; otherwise analyze inline.
5. For each thread emit: location, classification (bug / nit / question / out-of-scope), proposed action (edit code / reply / dismiss).
6. Present all proposals in one batch. User approves / rejects per thread.
7. Apply approved edits. Commit: `review: address comments on PR #<pr#>`. Push.
8. Optional: `gh pr comment <pr#> --body "Addressed threads: ..."`.

### 6.4 Migrated commands (playbook-only, behavior unchanged)

These are lifted verbatim from the current `~/.claude/skills/github/SKILL.md` into `playbooks/*.md`:

| Command | Playbook | Behavior |
|---|---|---|
| `/fix <desc>` | `fix.md` | Clean branch from main, named `<gh_login>/fix-<slug>` |
| `/feat <desc>` | `feat.md` | Same, named `<gh_login>/feat-<slug>` |
| `/hotfix <desc>` | `hotfix.md` | Save WIP commit, then `<gh_login>/hotfix-<slug>` |
| `/review <branch>` | `review.md` | Review against main, squash-merge after approval |
| `/release <repo> to test\|prod` | `release.md` | Force-push main to env branch, tag, archive release notes (only here) |
| "squash and merge to main" | `squash-merge.md` | Squash merge current branch to main |

The only behavioral change vs. the current github skill is the **unified branch naming** (decision 11): `/fix /feat /hotfix` now prepend the GH login and use the type as the identifier slot (e.g., `ck/fix-login-crash` instead of `fix/login-crash`).

## 7. Source Adapter Contract

Every `sources/<name>.sh` must satisfy:

- **Input:** single argument, the source-native ID (string).
- **Output on success:** JSON on stdout of shape
  ```json
  { "title": "...", "body": "...", "url": "...", "labels": ["..."] }
  ```
- **Exit codes:** `0` success, `2` not configured (skill will instruct user how to enable), any other non-zero is a runtime error (network, 404, etc.), reported as-is.
- **Secrets:** loaded via `source "$(dirname "$0")/../config.env" 2>/dev/null || true`.

Adding Linear / Jira / Asana later means dropping a new `sources/linear.sh` that meets this contract and adding one parsing rule to `parse_source.sh`. No changes to SKILL.md or any other script.

## 8. Release-Note Block Format (inlined from release-notes skill)

Every PR body for a user-facing change contains:

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

Optional lock marker to prevent regeneration on PR edits:

```markdown
<!-- RELEASE_NOTE_LOCKED -->
```

The `release` playbook scans merged PRs for these markers at release time to aggregate `{component}/docs/releases/{tag}.md`. That scanner does not change.

## 9. Notification Hook

### Trigger

Registered in `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Bash",
      "hooks": [{
        "type": "command",
        "command": ".claude/skills/workflow-expert/hooks/post-merge-notify.sh"
      }]
    }]
  }
}
```

### Dispatch

`hooks/post-merge-notify.sh` receives the PostToolUse payload via stdin and selects events:

```bash
#!/bin/bash
set -e
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

case "$CMD" in
  *"gh pr merge"*|*"git merge --squash"*) EVENT="pr-merged" ;;
  *"git push origin main:env/prod"*)       EVENT="deployed-prod" ;;
  *) exit 0 ;;
esac

"$(dirname "$0")/../scripts/notify.sh" "$EVENT" "$CMD"
```

`env/test` pushes do **not** fire (explicit user decision 3c).

### Stub

`scripts/notify.sh` — the single file to edit when wiring a real channel:

```bash
#!/bin/bash
# Args: $1=event name, $2=originating command
# Future: source config.env and send to Slack / Feishu / email.
# Keep this exit-0 until wired so hook never blocks.
echo "[notify stub] event=$1" >&2
exit 0
```

## 10. Config & Team Sharing

### What is in git

```
.claude/skills/workflow-expert/**        # everything except config.env
.claude/settings.json                    # hook registration
```

### What is per-developer (gitignored)

```
.claude/skills/workflow-expert/config.env
```

### Onboarding (one-time per developer)

```bash
cd .claude/skills/workflow-expert
cp config.env.example config.env
# edit config.env, fill in personal SENTRY_TOKEN etc. as they are enabled
```

`config.env.example` is committed with keys but empty values, so the team knows what secrets to request.

### `.gitignore` addition

```
.claude/skills/*/config.env
```

## 11. Migration From Current Setup

1. Copy `~/.claude/skills/github/SKILL.md` sections into the corresponding `.claude/skills/workflow-expert/playbooks/*.md` files. Adjust branch-naming references to use the new unified convention (section 6.4).
2. Write `workflow-expert/SKILL.md` as the command registry + dispatch to playbooks.
3. Delete `.claude/skills/release-notes/` (its block format is inlined into SKILL.md; archiving lives in `release.md` playbook).
4. Add the hook registration to `.claude/settings.json`.
5. Add `config.env` line to `.gitignore`.
6. Write `README.md` with the onboarding snippet.
7. Keep `~/.claude/skills/github/` as-is for other projects.

No existing branches need renaming; new branches created after this skill ships use the new convention.

## 12. How to Validate the Skill

- **Smoke on fresh branch:** `/wf-start i<known-issue>` in a throwaway working directory; verify branch name, clean tree, and main-update behavior.
- **Non-ASCII:** `/wf-start` on an issue with a Chinese title; verify the branch is English.
- **Free text:** `/wf-start "test dummy feature"`; verify a new GH issue is created.
- **Stub sources:** `/wf-start s1`; verify a clear "not configured" message with instructions.
- **PR flow:** make a small diff, `/wf-pr`; verify self-review runs, release-note block is present, PR body links the issue.
- **Review loop:** simulate a reviewer comment on a test PR; `/wf-reviews`; verify thread grouping and batch approval.
- **Hook:** run `git merge --squash` on a scratch branch; verify `[notify stub] event=pr-merged` appears.
- **No env/test fire:** run `git push origin main:env/test` on a throwaway; verify no notify invocation.

## 13. Future Extensions (out of scope now)

- Sentry / DevTrakr adapter implementations (fill in `sources/sentry.sh`, `sources/devtrakr.sh`).
- Real notification wiring (edit `scripts/notify.sh`).
- Linear / Jira adapters (drop in new `sources/*.sh`, add a rule to `parse_source.sh`).
- CI integration — automatic `/wf-reviews` trigger when a PR receives a new review.
- Cross-repo awareness for the monorepo sub-repos (currently each sub-repo is a separate git repo; the skill runs per-repo).
