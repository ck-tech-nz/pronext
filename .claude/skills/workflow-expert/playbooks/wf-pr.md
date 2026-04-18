# /wf-pr

Turn the current branch into a PR with a release-note block.

## Flow

1. Determine the current branch and extract `<issue#>`:

   ```bash
   branch=$(git branch --show-current)
   # branch format: <user>/<identifier>-<slug>
   # <identifier> is the first hyphen-separated token after "<user>/".
   identifier=$(echo "$branch" | cut -d/ -f2- | cut -d- -f1)
   ```

   If `<identifier>` is purely digits, it is an issue number. Otherwise, it is a type (`fix`/`feat`/`hotfix`) and there is no issue to link; proceed without a `Closes #N` line.

2. **Self-review:**

   ```bash
   git diff main..HEAD
   git log main..HEAD --oneline
   ```

   Read the diff. Flag:
   - logic changes that lack tests
   - hardcoded values that should be config
   - leftover `TODO` / `console.log` / `print` / `debugger`
   - scope creep (files touched beyond the ticket)

   Present findings.

3. **If concerns found,** ask the user: `continue` / `fix now` / `ignore <items>`. On `fix now`, loop back to step 2 after changes.

4. **Generate the release-note block.** Classify the diff into three buckets:
   - **New Features** — user-visible capabilities that did not exist.
   - **Improvements** — enhancements to existing features.
   - **Bug Fixes** — user-visible bug fixes.

   Emit each bucket as a bullet list, using the exact format below. Drop empty sections.

   ```markdown
   <!-- RELEASE_NOTE_START -->
   ## Release Note

   ### New Features
   - …

   ### Improvements
   - …

   ### Bug Fixes
   - …
   <!-- RELEASE_NOTE_END -->
   ```

   If the change is purely internal (refactor, chore, test-only), either:
   - omit the whole block, OR
   - include an empty locked block:

     ```markdown
     <!-- RELEASE_NOTE_LOCKED -->
     ```

   Locking prevents `/wf-pr` or a future re-run from overwriting the block.

5. **Compose the PR body:**

   ```markdown
   Closes #<issue#>

   <release-note block>

   ## Test Plan
   - [ ] <inferred item 1>
   - [ ] <inferred item 2>
   ```

   Infer test-plan items from the diff: touched modules, affected flows, edge cases in new logic. Ask the user to edit if needed.

   If there is no issue to close (type-identifier branch), omit the `Closes` line.

6. **Compose the PR title:** `<type>: <summary>`.
   - `<type>` from the GH issue's `bug` label → `fix`, `enhancement` label → `feat`; else derive from the branch type-identifier (`fix`/`feat`/`hotfix`).
   - `<summary>` from the issue title or the branch slug, trimmed to ≤60 chars.

7. **Create the PR:**

   ```bash
   gh pr create --title "<title>" --body "<body>" --base main
   ```

8. Report the PR URL.
