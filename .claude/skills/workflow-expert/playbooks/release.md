# /release "<repo> to test|prod"

Push main to an environment branch, tag it, and aggregate release notes.

## Component map

| Component | Path | Tag format |
|---|---|---|
| Pad | `pad/` | `v{semver}+{build}` |
| Mobile | `app/` | `v{semver}+{build}` |
| Server | `backend/` | `v{date}[-{suffix}]` |
| H5 | `h5/` | `v{date}[-{suffix}]` |
| Heartbeat | `heartbeat/` | `v{date}[-{suffix}]` |

Release-note files live at `{component}/docs/releases/`.

## Flow

1. **Parse target.** Extract repo name and environment (`test` or `prod`). Ask if either is unclear.
2. `cd` into the component's directory.
3. **update-main** (see `atomic-ops.md`).
4. **Confirm with user.** Show the latest commit on main and the target (`env/test` or `env/prod`). Ask for explicit confirmation.
5. **Push to env branch:**

   ```bash
   git push origin main:env/<environment> --force
   ```

   Force push is expected — env branches are deployment targets.
6. **Tag the release.** For server/h5/heartbeat (`v{date}` format):

   ```bash
   tag="env/<environment>/$(date +%Y-%m-%d)"
   # If today's tag already exists, append .2, .3, etc.
   git tag "$tag"
   git push origin "$tag"
   ```

   For pad/mobile (`v{semver}+{build}` format), use the semver+build computed from the component's version file; ask the user if unclear.
7. **Aggregate release notes.** Collect every PR merged since the previous tag and extract each `<!-- RELEASE_NOTE_START -->…<!-- RELEASE_NOTE_END -->` block (skipping any marked `<!-- RELEASE_NOTE_LOCKED -->`).

   ```bash
   gh pr list --state merged --base main --search "merged:>$(git log -1 --format=%cI <previous-tag>)" --json number,title,body
   ```

   Merge the blocks into a single `{component}/docs/releases/{tag}.md` with sections **New Features**, **Improvements**, **Bug Fixes**. Drop empty sections.
8. The user commits the release-note file via their normal PR workflow. Do **not** push the file automatically.
9. Report:

   ```
   Released: <repo> → env/<environment>
   Commit: <hash> <message>
   Tag: <tag>
   Release notes: <path to {component}/docs/releases/{tag}.md>
   ```
