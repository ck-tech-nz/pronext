# /wf-start "<input>"

Start work from a requirement. The single entry point for issue-driven development.

## Input forms

| Pattern | Interpretation |
|---|---|
| `i<N>` / `issue#<N>` / `issue <N>` / bare `<N>` (digits only) | GitHub issue #N |
| `s<N>` / `sentry#<N>` / `sentry <N>` | Sentry issue N |
| `d<N>` / `devtrakr#<N>` / `devtrakr <N>` | DevTrakr ticket N |
| anything else (free text) | Create a new GitHub issue with this as title/body, then continue |

## Flow

1. **identify-repo** (see `atomic-ops.md`).
2. **Parse input** via `scripts/parse_source.sh "<input>"` → `"<source> <id_or_text>"`.
3. **Fetch or create** depending on source:
   - **github**: call `sources/github.sh <id>`. Record the JSON. `gh_issue_num=<id>`.
   - **sentry / devtrakr**: call `sources/<source>.sh <id>`.
     - If exit code is 2, tell the user the source is not configured and point them at `config.env.example`. Stop.
     - On success, mirror into a new GH issue:

       ```bash
       gh issue create \
         --title "<title from adapter>" \
         --body  "From <source> #<id>: <url>\n\n<body from adapter>"
       ```

       Record the new GH issue number as `gh_issue_num`.
   - **new**: derive a concise title from the free text, then:

     ```bash
     gh issue create --title "<concise title>" --body "<original input>"
     ```

     Record the new GH issue number as `gh_issue_num`.
4. **Determine the English title** from the fetched/created issue. If the title contains non-ASCII characters, **translate-if-chinese** (see `atomic-ops.md`) and keep the English form for naming only — do not modify the GH issue.
5. **check-clean**.
6. **update-main**.
7. **get-gh-login** → `<user>`.
8. **compose-branch-name** with `identifier=<gh_issue_num>`, `english_title=<translated english title>` → `<user>/<num>-<slug>`.
9. **create-branch**.
10. Show the user: issue URL, title, labels, body excerpt, and the new branch name. They are ready to code.

## Examples

| Input | Result |
|---|---|
| `i143` | `ck/143-all-day-events-not-show-on-device-dashboard-page` |
| `s501` | mirror to new GH issue `#NNN`, branch `ck/NNN-null-pointer-in-calendar-sync` |
| `154` | `ck/154-test-bug-fix` (if GH issue #154 has a Chinese title that translates to "test bug fix") |
| `"add dark mode"` | create new GH issue `#MMM`, branch `ck/MMM-add-dark-mode` |
