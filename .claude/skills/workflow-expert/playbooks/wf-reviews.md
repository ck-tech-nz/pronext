# /wf-reviews [<pr#>]

Address reviewer comments on your own PR.

## Flow

1. **Determine the PR number.** If `<pr#>` was not given, infer it from the current branch:

   ```bash
   branch=$(git branch --show-current)
   pr=$(gh pr list --head "$branch" --json number --jq '.[0].number')
   ```

   If no PR is found, stop and tell the user to create one first (`/wf-pr`).

2. **Fetch reviews and comments:**

   ```bash
   gh pr view "$pr" --json reviews,comments
   ```

3. **Group by thread.** Comments on the same `{path, line}` belong to one thread. Collapse older comments and keep only the latest state per thread. Filter out threads that are already `resolved`.

4. **Decide strategy by volume.**
   - If unresolved threads ≥ 5, **dispatch parallel subagents** (one per thread) using the `superpowers:dispatching-parallel-agents` skill. Each subagent reads the file at the relevant line, classifies, and proposes an action.
   - Otherwise, analyze inline.

5. **Classify each thread** into one of:
   - **bug** — must fix in code
   - **nit** — small stylistic preference; usually fix
   - **question** — reviewer is asking; need to reply
   - **out-of-scope** — decline with a rationale

6. **Propose per thread:** location, classification, and action (edit code / reply / both / dismiss). Present all proposals in one batch.

7. **User approval per thread.** Accept any subset.

8. **Apply approved edits.** Commit:

   ```bash
   git add <changed files>
   git commit -m "review: address comments on PR #<pr>"
   git push
   ```

9. **Optionally post a summary comment:**

   ```bash
   gh pr comment "$pr" --body "Addressed: threads #<ids>. Replied: #<ids>. Deferred: #<ids>."
   ```

   Ask the user before posting.
