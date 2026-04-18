# /fix "<description>"

Start a bug fix on a clean branch from latest main.

1. **identify-repo** (see `atomic-ops.md`).
2. **check-clean**.
3. **update-main**.
4. **get-gh-login** → `<user>`.
5. **compose-branch-name** with `identifier=fix`, `english_title=<description>` → `<user>/fix-<slug>`.
6. **create-branch**.
7. Begin work on the fix.
8. After the fix: run tests, commit as `fix: <description>`, report anything that needs manual testing.
