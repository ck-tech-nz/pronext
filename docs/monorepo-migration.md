# Pronext Monorepo Consolidation Plan

## Context

You're the sole developer of Pronext (6 separate git repos under `/Users/ck/Git/pronext/`). Merging into a single monorepo will simplify development, enable cross-component AI exploration, and allow atomic commits that span the full stack. CI will use branch naming (`env/{component}/{env}`) to route builds — replacing the current `env/test` and `env/prod` branches that each repo uses independently.

## Branch Naming Convention

**Pattern: `env/{component}/{environment}`**

| Branch | Triggers |
|---|---|
| `env/server/test` | Django test + Docker build (test) |
| `env/server/prod` | Django test + Docker build (prod) |
| `env/heartbeat/test` | Go test + Docker build (test) |
| `env/heartbeat/prod` | Go test + Docker build (prod) |
| `env/h5/test` | (future) H5 build |
| `env/pad/test` | (future) Pad APK build |

Feature branches: `ck/{issue}-{description}` (unchanged).
Main branch: `main` (development trunk).

**Deploy workflow:** merge `main` → `env/server/test` → push → CI triggers automatically.

## Step-by-Step Implementation

### Phase 1: Preparation

1. **Ensure all 6 repos have clean working trees** — commit or stash any WIP
2. **Create `ck-tech-nz/pronext` on GitHub** — empty repo, no README/license
3. **Copy the `ARTIFACT_REGISTRY_PRIVATE_KEY` secret** to the new repo's Settings > Secrets

### Phase 2: Create Monorepo with Full History

Use `git subtree add` — preserves all commit history, each repo's files appear under their subdirectory.

```bash
# Initialize
cd /Users/ck/Git
mkdir pronext-mono && cd pronext-mono
git init && git checkout -b main

# Copy root-level files from existing structure
cp /Users/ck/Git/pronext/CLAUDE.md .
cp /Users/ck/Git/pronext/pronext.code-workspace .
cp -r /Users/ck/Git/pronext/.claude .
cp -r /Users/ck/Git/pronext/.vscode .
# Create root .gitignore (see below)

git add . && git commit -m "chore: initialize monorepo with root config files"

# Merge each repo (preserves full git history)
git remote add pronext-server git@github.com:ck-tech-nz/pronext-server.git
git fetch pronext-server
git subtree add --prefix=server pronext-server/main

git remote add pronext-heartbeat git@github.com:ck-tech-nz/pronext-heartbeat.git
git fetch pronext-heartbeat
git subtree add --prefix=heartbeat pronext-heartbeat/main

git remote add pronext-vue git@github.com:ck-tech-nz/pronext-vue.git
git fetch pronext-vue
git subtree add --prefix=h5 pronext-vue/main

git remote add pronext-flutter git@github.com:ck-tech-nz/pronext-flutter.git
git fetch pronext-flutter
git subtree add --prefix=mobile pronext-flutter/master  # uses master

git remote add pronext-pad git@github.com:ck-tech-nz/pronext-pad.git
git fetch pronext-pad
git subtree add --prefix=pad pronext-pad/master  # uses master

git remote add pronext-docs git@github.com:ck-tech-nz/pronext-calendar-docs.git
git fetch pronext-docs
git subtree add --prefix=docs pronext-docs/main

# Clean up temporary remotes
git remote remove pronext-server
git remote remove pronext-heartbeat
git remote remove pronext-vue
git remote remove pronext-flutter
git remote remove pronext-pad
git remote remove pronext-docs
```

### Phase 3: Post-Merge Adjustments

All changes in a single commit: `chore: adapt CI and configs for monorepo structure`

#### 3a. Root `.gitignore` (new file)

```gitignore
# OS
.DS_Store

# Local artifacts
UI/
logs/

# Environment
.env
.env.local
```

Each sub-project keeps its own `.gitignore` for tech-specific patterns (already preserved by subtree merge).

#### 3b. Move CI workflows to root `.github/workflows/`

GitHub only reads workflows from the root `.github/workflows/`. Create two adapted workflows:

**`.github/workflows/build-server.yml`** — adapted from `server/.github/workflows/build-django.yml`:
- Trigger: `env/server/test`, `env/server/prod`
- Add `defaults.run.working-directory: server` to the `test` job
- Add `cache-dependency-path: server/requirements.txt` to Python setup
- Change Docker `context: .` → `context: ./server`
- Change `cut -d'/' -f2` → `cut -d'/' -f3` in notification ENV_NAME extraction

**`.github/workflows/build-heartbeat.yml`** — adapted from `heartbeat/.github/workflows/build-go-heartbeat.yml`:
- Trigger: `env/heartbeat/test`, `env/heartbeat/prod`
- Add `defaults.run.working-directory: heartbeat` to the build job
- Fix existing bug: `cache-dependency-path: go-heartbeat/go.sum` → `heartbeat/go.sum`
- Change Docker `context: .` → `context: ./heartbeat`
- Change `cut -d'/' -f2` → `cut -d'/' -f3` in notification ENV_NAME extraction

#### 3c. Consolidate `.github/` non-workflow files

- Merge issue templates from sub-repos into root `.github/ISSUE_TEMPLATE/`
- Move copilot instructions to root `.github/copilot-instructions.md` (combine if needed)
- Delete sub-repo `.github/` directories (their workflows, templates, etc. won't function from subdirectories anyway)

#### 3d. Move pre-commit config to root

Move `server/.pre-commit-config.yaml` → root, add `files: ^server/` to every hook:

```yaml
exclude: ^server/legacy/
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: end-of-file-fixer
        files: ^server/
      - id: trailing-whitespace
        files: ^server/
        exclude: '/migrations/'
  - repo: https://github.com/PyCQA/flake8
    rev: 7.3.0
    hooks:
      - id: flake8
        files: ^server/
        exclude: '/migrations/'
  - repo: https://github.com/psf/black
    rev: 25.1.0
    hooks:
      - id: black
        args: ['--skip-string-normalization', '--line-length', '120']
        files: ^server/
        exclude: '/migrations/'
  - repo: https://github.com/rtts/djhtml
    rev: 3.0.9
    hooks:
      - id: djhtml
        files: ^server/
  - repo: https://github.com/pycqa/isort
    rev: 6.0.1
    hooks:
      - id: isort
        files: ^server/
        exclude: '/migrations/'
```

### Phase 4: Create Deployment Branches & Push

```bash
git remote add origin git@github.com:ck-tech-nz/pronext.git
git push -u origin main

# Create deployment branches
git checkout -b env/server/test && git push -u origin env/server/test
git checkout main
git checkout -b env/server/prod && git push -u origin env/server/prod
git checkout main
git checkout -b env/heartbeat/test && git push -u origin env/heartbeat/test
git checkout main
git checkout -b env/heartbeat/prod && git push -u origin env/heartbeat/prod
git checkout main
```

### Phase 5: Verify & Switch Over

1. **Test CI** — push a trivial change to `env/server/test`, verify: tests run → Docker image builds → Bark notification arrives
2. **Test heartbeat CI** — same for `env/heartbeat/test`
3. **Switch local dev:**
   - Rename `/Users/ck/Git/pronext` → `/Users/ck/Git/pronext-old`
   - Rename `/Users/ck/Git/pronext-mono` → `/Users/ck/Git/pronext`
   - Run `pre-commit install` in the new root
   - Verify VS Code workspace, venv activation, Django/Go/Vue dev servers
4. **Archive old repos** on GitHub (Settings > Danger Zone > Archive)

## Files to Create/Modify

| File | Action |
|---|---|
| `.gitignore` (root) | Create |
| `.github/workflows/build-server.yml` | Create (adapt from `server/.github/workflows/build-django.yml`) |
| `.github/workflows/build-heartbeat.yml` | Create (adapt from `heartbeat/.github/workflows/build-go-heartbeat.yml`) |
| `.github/ISSUE_TEMPLATE/*` | Consolidate from sub-repos |
| `.pre-commit-config.yaml` (root) | Create (adapt from `server/.pre-commit-config.yaml`) |
| `server/.github/` | Delete entire directory |
| `heartbeat/.github/` | Delete entire directory |
| `h5/.github/` | Delete entire directory |
| `pad/.github/` | Delete entire directory |
| `server/.pre-commit-config.yaml` | Delete (moved to root) |

## Verification

1. `git log -- server/` shows full Django commit history
2. `git log -- heartbeat/` shows full Go commit history
3. Push to `env/server/test` → Django CI passes, Docker image at `registry.cktech.co.nz/pronext/pronext-test`
4. Push to `env/heartbeat/prod` → Go CI passes, Docker image at `registry.cktech.co.nz/pronext/go-heartbeat`
5. `pre-commit run --all-files` only lints Python files under `server/`
6. VS Code workspace opens correctly with debug configs working
