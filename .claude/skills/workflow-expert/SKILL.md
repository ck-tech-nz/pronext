---
name: workflow-expert
description: "Pronext issue-to-deploy developer workflow. Invoked by: /fix, /feat, /hotfix, /review, /release, /wf-start, /wf-pr, /wf-reviews, 'squash and merge to main', or any issue-triage / PR / merge / release / notification task. ASK which repo if ambiguous."
user-invokable: true
argument-hint: "wf-start i99 | wf-pr | wf-reviews 45 | fix 'login crash' | feat 'dark mode' | review 'branch' | release 'server to prod'"
---

# workflow-expert

Single project-level skill that owns the entire issue-to-deploy developer workflow for pronext. Everything lives under this directory; copying it is sufficient to reproduce the workflow elsewhere.

**IMPORTANT — monorepo:** pronext is a monorepo. Valid repo targets are the **parent `pronext` repo itself** (root: `.`) **and** each sub-directory (`backend/`, `pad/`, `app/`, `h5/`, `heartbeat/`, `docs/`) — each is an independent git repo. If the user has not named a repo and it is not obvious from context, **ASK before proceeding**.

**Prerequisite:** `gh auth status` must pass. For Sentry / DevTrakr sources, the developer must copy `config.env.example` → `config.env` and fill in tokens (see `README.md`).

## Command registry

| Command | Playbook | Purpose |
|---|---|---|
| `/fix "<desc>"` | `playbooks/fix.md` | Start a bug-fix branch from main |
| `/feat "<desc>"` | `playbooks/feat.md` | Start a feature branch from main |
| `/hotfix "<desc>"` | `playbooks/hotfix.md` | Interrupt current work for an urgent fix |
| `/review "<branch>"` | `playbooks/review.md` | Review another branch against main, then squash-merge |
| `/release "<repo> to test\|prod"` | `playbooks/release.md` | Deploy main to env branch + tag + aggregate release notes |
| `/wf-start "<input>"` | `playbooks/wf-start.md` | Start work from a requirement (issue#, sentry#, devtrakr#, or free text) |
| `/wf-pr` | `playbooks/wf-pr.md` | Self-review + create PR with release-note block |
| `/wf-reviews [<pr#>]` | `playbooks/wf-reviews.md` | Address reviewer comments on your own PR |
| "squash and merge to main" | `playbooks/squash-merge.md` | Natural-language trigger for single-commit merge |

## Dispatch

When one of the triggers above fires, **load the referenced playbook file and follow it exactly**, step by step. The playbooks reference shared subroutines in `playbooks/atomic-ops.md`. Do not skip or reorder steps.

## Branch-naming convention (unified)

All branches created by this skill use the format:

```
<gh_login>/<identifier>-<english_slug>
```

- `<gh_login>` = `gh api user --jq .login`
- `<identifier>` = issue number (when starting from an issue) OR command type (`fix`/`feat`/`hotfix`)
- `<english_slug>` = `scripts/slug.sh "<english title>"`; no truncation
- Chinese titles are translated to English before slugifying (Claude does this)

Examples:

- `ck/143-all-day-events-not-show-on-device-dashboard-page`
- `ck/fix-login-crash`
- `ck/feat-dark-mode`

## Release-note block format

Every user-facing PR body contains:

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

Add `<!-- RELEASE_NOTE_LOCKED -->` to prevent regeneration. The `release` playbook scans these markers at release time to aggregate `{component}/docs/releases/{tag}.md`.

## Non-goals

- Automating step 3 (writing code and committing). That is ordinary conversation.
- Archiving release notes outside of `/release`.
- Notification wiring beyond the stub in `scripts/notify.sh`.
- Discovering or using skills for languages/frameworks — this skill is workflow-only.

## Related files

- `playbooks/` — step-by-step for each trigger
- `scripts/slug.sh`, `scripts/parse_source.sh`, `scripts/notify.sh`
- `sources/github.sh` (live), `sources/sentry.sh` + `sources/devtrakr.sh` (stubs)
- `hooks/post-merge-notify.sh` — PostToolUse hook, registered in `.claude/settings.json`
- `tests/run_all.sh` — umbrella test runner
- `README.md` — onboarding
- Spec: `docs/superpowers/specs/2026-04-18-workflow-expert-design.md`
