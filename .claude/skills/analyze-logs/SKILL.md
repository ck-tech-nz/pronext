---
name: analyze-logs
description: Triage a Django backend error log. Cluster similar errors by signature, classify into real bugs / robustness issues / log noise / user-data issues, create GitHub issues for real bugs, and write a Markdown report for the rest. Invoke when the user says /analyze-logs, mentions log triage, or asks to find bugs in a backend log file.
---

<!--
===================================================================
SAFETY: PRODUCTION SERVER ACCESS
===================================================================
The SSH host alias `pronext` in the user's ~/.ssh/config points at the
production server. This skill is the only authorized consumer of that
alias for this workflow. Access is strictly limited:

ALLOWED, exactly one command shape:
    scp pronext:~/cps/pronext/logs/pronext_server_<YYYY-MM-DD>.log ./backend/logs/

FORBIDDEN:
    - ssh pronext <anything>          — no remote command execution, not
                                        even read-only probes.
    - scp <local> pronext:<anywhere>  — uploads are banned; pull-only.
    - scp pronext:<path> where <path> is not the dated log file under
      ~/cps/pronext/logs/.
    - Shell expansions, globs, multi-file scp (e.g. *.log).

The date MUST be validated against ^\d{4}-\d{2}-\d{2}$ before being
substituted into the scp command. Reject anything else.

Any other production access needs a fresh design review, not an ad-hoc
edit of this file.
===================================================================
-->

# Analyze Backend Error Logs

Triage a Django backend daily error log: cluster similar errors, classify them, create GitHub issues for real bugs, and write a Markdown report for the rest.

## Step 1: Resolve the Log File

The user invokes one of:

| Form | Behavior |
|------|----------|
| `/analyze-logs /abs/path/file.log` | Use that file directly. Verify it exists; abort if not. |
| `/analyze-logs 2026-04-18` | Date mode (see below). |
| `/analyze-logs` | Date mode with today's date. |

**Date mode:**

1. Validate the date against `^\d{4}-\d{2}-\d{2}$`. If invalid, abort with an error.
2. Target local path: `./backend/logs/pronext_server_<date>.log`.
3. If the file exists locally, reuse it. Do not re-download.
4. Otherwise run **exactly** this command, with no other flags, globs, or expansions:

   ```bash
   scp pronext:~/cps/pronext/logs/pronext_server_<date>.log ./backend/logs/
   ```

5. On `scp` failure (SSH down, file missing on server), print the error and abort.

**Under no circumstances** run `ssh pronext ...` or any other `scp pronext:...` path. See the safety block at the top of this file.

## Step 2: Run the Clustering Script

```bash
python3 .claude/skills/analyze-logs/scripts/cluster_logs.py <logfile> > /tmp/clusters.json
```

The script reads the log, keeps only ERROR/WARNING entries, merges continuation lines for tracebacks (up to 20 lines), normalizes URLs/UUIDs/integers/quoted strings, clusters by `LEVEL:module:line:normalized_message[:80]`, and writes a JSON array sorted by count descending.

If the script exits non-zero or `/tmp/clusters.json` is empty or `[]`, report "nothing to analyze" and exit.

## Step 3: Classify Each Cluster

Load `/tmp/clusters.json` and assign every cluster to one of four categories:

| Category | Criterion |
|----------|-----------|
| 1 — Real bug | Samples contain a Python traceback OR an exception class name matching `\w+(Error\|Exception)` AND the failing frame is in our codebase. |
| 2 — Robustness | Our code handled external data poorly (e.g. parsing HTML as ICS, surfacing `error: 0`, not validating input). |
| 3 — Log noise | External-service failure flooding the log (403/429/timeouts/network errors on third-party URLs). |
| 4 — User data | User-supplied data is clearly invalid (dead URL, malformed config) and our code is not at fault. |

Tie-breakers:
- Low count category 1 (< 3): still category 1.
- High count category 1 (> 1000): still category 1, but mark the issue body with `**HIGH FREQUENCY — PRIORITY**`.
- Ambiguous: prefer the lower-commitment category (2 over 1).

Also draft for each cluster:
- A one-sentence summary of what the code was doing when the error happened.
- (Category 1 only) Suggested fix location formatted as `[module.py:LINE](backend/<path-from-module-dots>/module.py#L<line>)`.

## Step 4: Present Classification to the User

Show a table:

```
| # | Cat | Count | Signature | Proposed action |
|---|-----|-------|-----------|-----------------|
| 1 | 1   | 12    | ERROR:pronext.foo:42:KeyError on <STR> | Create issue |
| 2 | 3   | 2345  | ERROR:pronext.calendar.google_sync:306:... | Report only |
```

Ask the user to confirm the category-1 list. Accept exactly one of:
- `yes` / `all` — proceed with every category-1 cluster.
- `skip N[, N, ...]` — drop those cluster indexes from the category-1 list and proceed with the rest.
- `no` / `cancel` — skip issue creation; still write the report in Step 6.

## Step 5: Create Issues for Category 1

For each confirmed category-1 cluster, check `gh` is installed and authenticated:

```bash
gh auth status
```

If it fails, print the error and abort — the report file (Step 6) still gets written so nothing is lost.

Then create one issue per cluster:

```bash
gh issue create --repo ck-tech-nz/pronext --label bug --title "<title>" --body "$(cat <<'EOF'
## Summary
<one-sentence description of what the code was doing when it failed>

## Error Signature
`<cluster signature>`

## Count & Timespan
Occurred **N** times between `<first_seen>` and `<last_seen>`.

## Sample Log Lines
```
<up to 3 verbatim samples, each including retained continuation lines>
```

## Suggested Fix Location
[module.py:LINE](backend/<path>/module.py#L<line>)

---
Source: analyze-logs on `<logfile basename>`
EOF
)"
```

Title format: `bug: <module>.<function-or-description> — <short exception summary>`.

Collect the returned URLs. If a `gh` call fails mid-run, stop further creation and report which succeeded. Any clusters left over are still covered by the report in Step 6.

## Step 6: Write the Report

Write to `/tmp/log-triage-<date>.md` where `<date>` is the log's calendar date (extract from the log filename or from the `first_seen` of the earliest cluster).

````markdown
# Log Triage Report — <date>

Source: `<logfile basename>`
Total ERROR/WARNING clusters: <N>
Category 1 (issues created): <N> — see GitHub URLs in chat output

## Category 2 — Robustness

### Cluster: <signature>
- Count: <n>, first/last seen: <ts> / <ts>
- Samples:
  ```
  <up to 3 samples>
  ```
- Suggested action: <e.g. wrap parser in try/except, validate URL before fetch>

(one section per category-2 cluster)

## Category 3 — Log Noise

(same shape; suggested action leans toward log-level downgrade or aggregation)

## Category 4 — User Data

(same shape; suggested action leans toward UX improvement or silent skip)
````

## Step 7: Final Report to the User

Print to chat:

```
Category 1: <N> issues created
  - https://github.com/ck-tech-nz/pronext/issues/<id>
  - ...

Report written to /tmp/log-triage-<date>.md
  - Category 2 (robustness): <N> clusters
  - Category 3 (log noise): <N> clusters
  - Category 4 (user data): <N> clusters
```

## Reminders

- Never run anything on `pronext` other than the single whitelisted `scp` command. See the safety block at the top of this file.
- Do not write to the repo automatically beyond creating GitHub issues (no commits, no PRs).
- If the user has not confirmed category-1 creation, do not call `gh issue create`.
