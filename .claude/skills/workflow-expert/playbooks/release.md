# /release "<repo> to test|prod"

Push a branch to an environment branch and — for `env/prod` only — tag it and aggregate release notes.

- **Source branch** defaults to **main**. For `env/test` only, you may release from a feature branch (pre-merge smoke test). `env/prod` is always released from main.
- **Tagging** happens only for `env/prod`. `env/test` pushes are not tagged (the env/test branch itself is enough to identify what's deployed).
- **Release-note aggregation** happens only for `env/prod`. `env/test` pushes skip this step.

## Scope — which components this applies to

`/release` is only meaningful for components that deploy by pushing to a server-side `env/*` branch:

| Component | Path | Tag format |
|---|---|---|
| Pronext (parent monorepo) | `.` | `v{date}[-{suffix}]` |
| Server | `backend/` | `v{date}[-{suffix}]` |
| H5 | `h5/` | `v{date}[-{suffix}]` |
| Heartbeat | `heartbeat/` | `v{date}[-{suffix}]` |

Release-note files live at `{component}/docs/releases/` and are organized **one file per calendar month** — `{YYYY-MM}.md` — with newest releases at the top. For the parent `pronext` repo, use `docs/releases/` at the monorepo root.

**Out of scope** — do NOT use `/release` for these:

- **`pad/`** — released through the `build-pad` skill (builds APK, uploads to R2, registers with backend, and tags). There is no `env/*` branch for Pad.
- **`app/`** — released through the `build-app` skill (builds IPA/AAB, uploads to App Store Connect / Google Play Console, and tags). There is no `env/*` branch for Mobile.

If a user types `/release app …` or `/release pad …`, refuse and redirect them to the `build-app` or `build-pad` skill.

## Flow

1. **Parse target.** Extract repo name and environment (`test` or `prod`). Ask if either is unclear.
2. `cd` into the component's directory.
3. **Pick source branch.**
   - **Default**: source = `main`. Run **update-main** (see `atomic-ops.md`).
   - **Pre-merge test push** (opt-in, `env/test` only): if the user explicitly names a non-main branch — or the current branch is non-main and the user confirms they want to release it — use that branch as source. Do **not** check out or modify it; just verify it exists locally (`git rev-parse --verify <branch>`) and is up to date with its remote (`git fetch origin <branch>` then compare).
   - **Guardrail**: if target is `env/prod` and source is not `main`, refuse and tell the user to merge to main first.
4. **Confirm with user.** Show source branch, its latest commit, and the target (`env/test` or `env/prod`). If source ≠ main, call this out explicitly as a pre-merge test push. Ask for explicit confirmation.
5. **Push to env branch:**

   ```bash
   git push origin <source-branch>:env/<environment> --force
   ```

   Force push is expected — env branches are deployment targets.
6. **Tag the release.** Skip this step entirely when environment is `test`.

   For `env/prod` (server/h5/heartbeat/parent, all `v{date}` format):

   ```bash
   tag="v$(date +%Y-%m-%d)"
   # If today's tag already exists, append -2, -3, etc. (no env prefix)
   git tag "$tag" main
   git push origin "$tag"
   ```
7. **Aggregate release notes into the month file.** Skip this step when environment is `test` OR when source ≠ main (there are no PRs to aggregate against main).

   For `env/prod`:

   1. Collect release-note blocks from PRs merged since the previous tag:

      ```bash
      gh pr list --state merged --base main --search "merged:>$(git log -1 --format=%cI <previous-tag>)" --json number,title,body
      ```

      Extract each `<!-- RELEASE_NOTE_START -->…<!-- RELEASE_NOTE_END -->` block and skip any marked `<!-- RELEASE_NOTE_LOCKED -->`.

   2. Build a **per-release entry** using the collected blocks, with `## {tag}` as its heading and `### New Features`, `### Improvements`, `### Bug Fixes` as subsections. Drop empty subsections.

   3. Locate the month file `{component}/docs/releases/{YYYY-MM}.md` where `{YYYY-MM}` is derived from the new tag's date.

      - **File does not exist**: create it starting with a `# {YYYY-MM} Releases` title, a blank line, then the new per-release entry.
      - **File exists**: **prepend** the new per-release entry immediately after the `# {YYYY-MM} Releases` title block (i.e., the new entry sits above every existing entry so newest is first). Do not touch existing entries.

   4. If the user wrote the per-release entry by hand (no PRs with release-note blocks since the previous tag), follow the same prepend rule — do not create a separate per-release file.
8. The user commits the month file via their normal PR workflow. Do **not** push the file automatically.
9. Report:

   ```
   Released: <repo> → env/<environment>
   Source: <source-branch> (pre-merge test push)         # only when source ≠ main
   Commit: <hash> <message>
   Tag: <tag>                                            # omit for env/test
   Release notes: <path to {component}/docs/releases/{YYYY-MM}.md>   # omit for env/test or pre-merge pushes
   ```
