---
name: worktree-setup
description: Use when starting parallel work on a second pronext submodule branch without disturbing the current checkout — creates a git worktree, shares .venv, copies .env with a bumped PORT, and documents run/teardown. Triggers include "worktree", "parallel branch", "hotfix while feature in progress", multi-AI parallel sessions, "run two dev servers side by side".
---

# Worktree Setup (pronext)

Parallel branch work on the same submodule needs an isolated working tree plus a provisioned dev env. The git worktree is cheap; the pain is `.venv`, `.env`, and port collisions.

## When to use

- Testing a hotfix branch while a feature branch is mid-flight in the main checkout.
- Multiple agents (humans or AIs) editing different branches of the same submodule concurrently.
- Wanting two Django dev servers (or h5 vite servers) running at once.

## When NOT to use

- Just flipping branches briefly — plain `git checkout` is faster and doesn't leave stragglers.
- Trying to isolate DB state — worktrees share Postgres/Redis unless you override in the copied `.env`.

## Canonical paths

| Role | Path |
| --- | --- |
| Main monorepo | `/Users/ck/Git/pronext/pronext/` |
| Main submodule checkout | `/Users/ck/Git/pronext/pronext/<module>` (e.g. `backend`) |
| Worktrees root | `/Users/ck/Git/pronext/pronext.worktrees/` |
| Worktree dir | `pronext.worktrees/<module>-<slug>/` |

`<slug>` is a short human tag derived from the branch (`fix-fanout`, `feat-stats`). Keep it readable; you'll reuse it.

## Create a worktree (backend)

```bash
MODULE=backend
SLUG=fix-fanout
BRANCH=fix/calendar-event-fanout-duplication

MAIN=/Users/ck/Git/pronext/pronext/$MODULE
WT=/Users/ck/Git/pronext/pronext.worktrees/$MODULE-$SLUG

git -C "$MAIN" worktree add "$WT" "$BRANCH"

# Share deps — venv absolute paths still resolve via the symlink
ln -s "$MAIN/.venv" "$WT/.venv"

# Copy secrets, then bump PORT so dev servers don't collide
cp "$MAIN/.env" "$WT/.env"
# manually edit $WT/.env: PORT=8080 → PORT=8081 (or any free port)
```

## Run from the worktree

```bash
cd "$WT"
source .venv/bin/activate
python3 manage.py runserver 0.0.0.0:8001    # pick a port distinct from main
python3 manage.py test pronext.calendar      # tests build throwaway DB — safe
```

Postgres / Redis are docker-hosted services shared with the main checkout. That's fine for read-only or orthogonal work; see "Common mistakes" for when to split them.

## Teardown

```bash
git -C "$MAIN" worktree remove "$WT"
```

Refuses if the worktree has uncommitted changes or a locked `.venv` — commit/stash in the worktree first, then retry. For a hard abandon: `git worktree remove --force`.

## Extending to other submodules

Same shape, different provisioning step:

| Module | Share deps via | Copy from main |
| --- | --- | --- |
| `backend` | `ln -s .venv` | `.env` |
| `h5` | `ln -s node_modules` | `.env` (if present) |
| `heartbeat` | (Go — nothing to share) | `.env` |
| `app` | (Flutter — `flutter pub get` in worktree) | none |
| `pad` | (Gradle — first build warms `~/.gradle` cache) | none |

## Common mistakes

- **Running `pip install` in the worktree after symlinking `.venv`** mutates the main checkout too. If you need isolation: `uv venv .venv && uv pip install -r requirements.txt` inside the worktree and drop the symlink.
- **Forgetting to bump `PORT`** → `runserver` silently binds in only one of the two checkouts; the other gets `Address already in use`.
- **Two checkouts writing to the same Postgres dev DB** → data corruption on concurrent migrations / fixtures. For isolated DB work, edit `DJANGO_PG` in the worktree `.env` to point at a separate database (`createdb pronext_dev_$SLUG` first).
- **Committing on the wrong branch** — always `git -C "$WT" branch --show-current` before committing inside a worktree.
- **Leaking secrets** — `.env` contains prod keys in this repo. Never commit a copied `.env` from a worktree; `.gitignore` covers it but double-check before `git add -A`.
- **Orphan stashes after teardown** — stashes are per-repo, not per-worktree. `git -C "$MAIN" stash list` after you're done to confirm nothing got left behind.
