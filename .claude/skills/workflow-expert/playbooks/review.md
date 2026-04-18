# /review "<branch-name>"

Review a branch against main, then squash-merge if approved.

1. **identify-repo** (see `atomic-ops.md`).
2. **update-main**.
3. Diff against main:

   ```bash
   git diff main..<branch-name>
   git log main..<branch-name> --oneline
   ```
4. Review the changes for:
   - Correctness and bugs
   - Security issues
   - Performance
   - Style consistency
   - Test coverage
   - Whether changes look intentional (do not flag deliberate design choices)
5. Report:

   ```
   ## Review: <branch-name>
   ### Changes — <summary>
   ### Issues Found — <list or "None">
   ### Verdict — APPROVE / CHANGES REQUESTED
   ```

   - If issues: list them, do NOT merge, ask how to proceed.
   - If clean: tell the user and **ask for confirmation** before merging.
6. Squash-merge (only after user confirms):

   ```bash
   git checkout main
   git merge --squash <branch-name>
   git commit -m "<type>: <summary>"
   ```
7. Ask if the user wants to delete the merged branch.
