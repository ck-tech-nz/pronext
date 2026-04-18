# "squash and merge to main"

Natural-language trigger. Merges the current branch into main as a single commit. The feature branch stays **untouched**.

1. **Check working tree** — if dirty, commit all changes first.
2. **Note the current branch name** (this is the branch being merged).
3. Show what will be merged:

   ```bash
   git log main..HEAD --oneline
   ```

   Show the result to the user.
4. Switch to main and update:

   ```bash
   git checkout main && git pull origin main
   ```
5. Squash-merge:

   ```bash
   git merge --squash <branch-name>
   ```

   On conflicts: resolve, `git add`, then continue.
6. Compose a commit message — summarize all branch commits into one, using the conventional-commit format (`<type>: <summary>`).
7. Commit:

   ```bash
   git commit -m "<type>: <summary>"
   ```
8. Report the squash commit hash and confirm the feature branch is untouched.
9. Do **not** delete the branch or push unless the user asks.
