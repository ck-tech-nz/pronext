# /hotfix "<description>"

Interrupt current work for an urgent fix. Saves in-progress changes first.

1. **identify-repo** (see `atomic-ops.md`).
2. **Save current work.** If there are uncommitted changes, commit them as a WIP:

   ```bash
   git add . && git commit -m "wip: save in-progress work before hotfix"
   ```

   Note the current branch name so the user can return later.
3. **update-main**.
4. **get-gh-login** → `<user>`.
5. **compose-branch-name** with `identifier=hotfix`, `english_title=<description>` → `<user>/hotfix-<slug>`.
6. **create-branch**.
7. Tell the user which branch their previous work is saved on, then begin work.
8. After the hotfix: run tests, commit as `hotfix: <description>`, remind the user to switch back to their prior branch.
