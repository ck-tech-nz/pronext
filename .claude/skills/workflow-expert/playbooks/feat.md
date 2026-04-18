# /feat "<description>"

Start a new feature on a clean branch from latest main.

1. **identify-repo** (see `atomic-ops.md`).
2. **check-clean**.
3. **update-main**.
4. **get-gh-login** → `<user>`.
5. **compose-branch-name** with `identifier=feat`, `english_title=<description>` → `<user>/feat-<slug>`.
6. **create-branch**.
7. Begin work on the feature.
8. After the feature: run tests, commit as `feat: <description>`, report anything that needs manual testing.
