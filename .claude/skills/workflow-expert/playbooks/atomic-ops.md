# atomic-ops — shared subroutines for workflow-expert playbooks

Other playbooks reference these subroutines by name. They are not standalone commands.

## identify-repo

pronext is a monorepo. Valid repo targets are the **parent `pronext` repo itself** (root: `.`) **and** each sub-directory (`backend/`, `pad/`, `app/`, `h5/`, `heartbeat/`, `docs/`) — each is an independent git repo.

1. If the user has named a repo (or it is obvious from context), `cd` into it. For the parent `pronext` repo, stay at the monorepo root.
2. Otherwise, **ask the user which repo** before proceeding. Include "parent `pronext`" as an option.

## check-clean

Run:

```bash
git status
```

If the working tree is dirty, **stop and ask the user** whether to commit, stash, or discard. Do not proceed until clean.

## update-main

```bash
git checkout main && git pull origin main
```

## get-gh-login

```bash
gh api user --jq .login
```

Use this as `<user>` in branch naming. Cache per-session if useful; `gh api user` is fast.

## translate-if-chinese

If an issue title contains any non-ASCII character, **translate the meaningful parts to English** (Claude does this — do not use pinyin transliteration). Preserve technical terms, numbers, and product names as-is.

Example: `154-测试修复bug` → English title `test bug fix`.

## compose-branch-name

Inputs: `<identifier>` (either an issue number or a type like `fix` / `feat` / `hotfix`), `<english_title>`, `<user>` (from `get-gh-login`).

1. `slug=$(scripts/slug.sh "<english_title>")`
2. Branch name: `<user>/<identifier>-<slug>`
3. Do not truncate.

Examples:

| identifier | title | branch |
|---|---|---|
| `143` | "All-day events not show on device dashboard page" | `ck/143-all-day-events-not-show-on-device-dashboard-page` |
| `fix` | "login crash" | `ck/fix-login-crash` |
| `feat` | "dark mode" | `ck/feat-dark-mode` |

## create-branch

```bash
git checkout -b <branch-name>
```

Report the new branch to the user.
