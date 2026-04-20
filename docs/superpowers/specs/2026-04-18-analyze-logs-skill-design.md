# Analyze-Logs Skill + Analyze-Feedback Skill Migration — Design

**Date**: 2026-04-18
**Author**: ck (via Claude brainstorm)
**Status**: Draft

## Summary

Introduce a new `analyze-logs` skill that ingests Django backend error logs, clusters similar entries, classifies them into four actionable categories, creates GitHub issues for real bugs, and writes a Markdown report for the rest. As part of the same change, migrate the existing `/analyze-feedback` slash command into a proper skill directory structure so both analysis workflows live under `.claude/skills/` with room for supporting scripts.

## Motivation

The backend produces a daily error log on the order of ~10,000 lines (e.g. `pronext_server_2026-04-18.log` is 9,556 lines / 1.7 MB). Most of it is dominated by external-service noise (ICS 403/429 responses to user-provided URLs), which drowns out genuine backend bugs. Reading the log by hand wastes time and misses signal. We want a repeatable triage path that:

1. Separates signal from noise via signature-based clustering.
2. Classifies each cluster into one of four categories with a clear next action.
3. Creates GitHub issues automatically for category-1 (real bugs) and produces a review report for the rest.

At the same time the existing `/analyze-feedback` command is effectively "a skill without a directory" — upgrading it to a real skill keeps both analysis workflows structured the same way and gives `analyze-feedback` room to grow its own `scripts/`.

## Non-Goals

- No unit tests for the clustering script. It is a scrappy internal tool; manual verification against a real log is sufficient.
- No unification of `analyze-feedback` and `analyze-logs` into a meta-`triage` skill. The two workflows share only ~10 lines of `gh issue create` shell; a shared abstraction is premature.
- No scheduled / recurring execution. Both skills are invoked on demand.
- No change to the logging configuration in `backend/pronext_server/settings.py`. Log-noise reduction (category 3) is a downstream action, tracked via the report, not done by the skill itself.

## File Layout

```
.claude/
├── commands/
│   └── analyze-feedback.md            ← DELETED
└── skills/
    ├── analyze-feedback/
    │   └── SKILL.md                   ← migrated from the old command, content unchanged
    └── analyze-logs/                  ← new
        ├── SKILL.md
        └── scripts/
            └── cluster_logs.py
```

`.claude/skills/analyze-feedback/scripts/` is not created yet — it can be added later when that skill needs a helper.

### `SKILL.md` frontmatter

Both skills use Claude Code's skill frontmatter:

```yaml
---
name: <analyze-feedback | analyze-logs>
description: <when-to-use sentence, used by the skill picker>
---
```

`analyze-feedback` description is preserved verbatim from the current command. `analyze-logs` description:

> Triage a Django backend error log. Cluster similar errors by signature, classify into real bugs / robustness issues / log noise / user-data issues, create GitHub issues for real bugs, and write a Markdown report for the rest. Invoke when the user says /analyze-logs, mentions log triage, or asks to find bugs in a backend log file.

## `analyze-logs` Workflow

Invocation forms:

| Form | Behavior |
|------|----------|
| `/analyze-logs /abs/path/file.log` | Use the file directly |
| `/analyze-logs 2026-04-18` | `scp pronext:~/cps/pronext/logs/pronext_server_2026-04-18.log ./backend/logs/`, then analyze |
| `/analyze-logs` | Default to today's date, go through the `scp` path |

Steps:

1. **Resolve log path.** If the argument looks like a date (`YYYY-MM-DD`) or is empty, check whether `./backend/logs/pronext_server_<date>.log` already exists locally. If it does, reuse it without re-downloading. Otherwise `scp pronext:~/cps/pronext/logs/pronext_server_<date>.log ./backend/logs/`. On `scp` failure, abort with the error shown to the user. If the argument is an explicit path, verify the file exists.
2. **Run clustering script.** `python3 .claude/skills/analyze-logs/scripts/cluster_logs.py <logfile>` writes JSON to stdout. Capture it.
3. **Classify clusters.** Claude reads the JSON, assigns each cluster to category 1/2/3/4, and drafts a one-line summary plus (for category 1) a suggested fix location.
4. **Present classification to the user.** A table of clusters with category, count, signature, and proposed action. The user responds with one of:
   - `yes` / `all` — create issues for every category-1 cluster as listed.
   - `skip N[, N, ...]` — drop those cluster indexes from the category-1 list and create the rest.
   - `no` / `cancel` — create no issues; still write the report.
5. **Create issues for category 1.** One `gh issue create --repo ck-tech-nz/pronext` call per confirmed cluster. Collect returned URLs.
6. **Write report for categories 2/3/4.** Markdown file at `/tmp/log-triage-<YYYY-MM-DD>.md` using the log's date.
7. **Report to user.** Summary of issues created + path to the report file.

## Clustering Script (`cluster_logs.py`)

- **Input**: path to a log file (argv[1]).
- **Output**: JSON array on stdout, sorted by `count` descending.
- **Log line format** (from `backend/pronext_server/settings.py:230`):
  `[LEVEL][YYYY-MM-DD HH:MM:SS,ms]module.py LINE: message`
- **Level filter**: keep only `ERROR` and `WARNING`. Drop `INFO`/`DEBUG`.
- **Multi-line handling**: a line that does not start with `[LEVEL][` is treated as a continuation of the previous entry (e.g. Python tracebacks). At most 20 continuation lines are retained per entry to cap memory.
- **Signature**: `LEVEL:module:line:normalized_message[:80]` where the message is normalized by replacing:
  - URLs (http/https) → `<URL>`
  - 32-char hex strings / UUIDs → `<UUID>`
  - Standalone integers → `<N>`
  - Single-quoted strings → `<STR>`
- **Per-cluster output**:

```json
{
  "signature": "ERROR:pronext.calendar.google_sync:306:get_link_events error: <N>, <URL>",
  "level": "ERROR",
  "module": "pronext.calendar.google_sync",
  "line": 306,
  "count": 2345,
  "first_seen": "2026-04-18 00:00:03",
  "last_seen": "2026-04-18 23:59:58",
  "samples": ["<verbatim first 3 entries including any continuation lines>"]
}
```

No dependencies beyond the Python 3.12 standard library.

## Classification Rubric

Applied by Claude to each cluster:

| Category | Criterion | Action |
|----------|-----------|--------|
| 1 — Real bug | Entry contains a Python traceback OR an exception class name matching `\w+(Error\|Exception)` **and** the failing frame is in our codebase | Create a GitHub issue, label `bug` |
| 2 — Robustness | Our code handled external data poorly: parsed HTML as ICS, `error: 0` surfaced as-is, invalid input not gracefully rejected | Add to report, suggest `try/except` or validation |
| 3 — Log noise | External-service failure flooding the log (403/429/timeouts/network errors on third-party URLs) | Add to report, suggest downgrading level or aggregating |
| 4 — User data | User-supplied data is clearly invalid (dead URL, malformed config) and our code is not at fault | Add to report, suggest UX improvement or silent skip |

Edge cases:
- **Low count category 1 (count < 3)**: still create an issue. Low-frequency crashes are still crashes.
- **High count category 1 (count > 1000)**: create the issue with a visible "HIGH FREQUENCY — PRIORITY" marker in the body so it is not buried.
- **Ambiguous clusters**: default to the lower-commitment category (prefer 2 over 1). User sees the full table before anything is created.

## GitHub Issue Body Template (category 1)

```markdown
## Summary
<one-sentence description of what the code was doing when it failed>

## Error Signature
`<cluster signature>`

## Count & Timespan
Occurred **N** times between `<first_seen>` and `<last_seen>`.

## Sample Log Lines
\`\`\`
<up to 3 verbatim samples, each including its retained continuation lines>
\`\`\`

## Suggested Fix Location
[module.py:LINE](backend/path/to/module.py#L<line>)

---
Source: analyze-logs on `<logfile basename>`
```

All category-1 issues go to `ck-tech-nz/pronext` (the central issue tracker for the project going forward). Label: `bug`.

## Report File Format (categories 2/3/4)

Path: `/tmp/log-triage-<date>.md` where `<date>` is the log's calendar date.

```markdown
# Log Triage Report — <date>

Source: `<logfile basename>`
Total ERROR/WARNING clusters: <N>
Category 1 (issues created): <N> — see GitHub URLs in chat output

## Category 2 — Robustness

### Cluster: <signature>
- Count: <n>, first/last seen
- Samples (up to 3)
- Suggested action

... (one section per cluster)

## Category 3 — Log Noise

...

## Category 4 — User Data

...
```

## Edge Cases

| Case | Behavior |
|------|----------|
| `scp` fails (SSH down, date missing on server) | Print the error, abort. Do not fall back silently. |
| Log file is empty / no ERROR or WARNING lines | Report "nothing to analyze" and exit without writing a report. |
| Very long traceback (>20 continuation lines) | Truncate in the cluster output. Note the truncation in samples. |
| `gh issue create` fails partway | Stop further creation, report which succeeded, leave the remainder in the report file so nothing is lost. |
| Running without `gh` installed or authed | Detect up front, instruct the user to install/auth, exit. |

## Migration of `analyze-feedback`

The existing file `.claude/commands/analyze-feedback.md` is moved verbatim to `.claude/skills/analyze-feedback/SKILL.md`. The frontmatter is adjusted from the slash-command form to the skill form (`name:` added, `description:` retained). The old command file is deleted in the same commit.

No behavioral change — existing `/analyze-feedback` invocations continue to work because Claude Code exposes skills to the `/<name>` invocation surface.

## Testing

Manual verification, in order:

1. **Script smoke test.** Run `python3 cluster_logs.py backend/logs/pronext_server_2026-04-18.log` against the already-downloaded log. Check:
   - Output is valid JSON.
   - `sum(cluster.count for cluster in output)` equals the number of ERROR+WARNING entries (after merging continuation lines).
   - Top 5 clusters by count are visually coherent (same root cause).
   - Signature field does not leak unique URLs, UUIDs, or numeric IDs.
2. **End-to-end skill run.** Invoke `/analyze-logs 2026-04-18` and walk through:
   - `scp` is skipped because the file already exists locally (verify by deleting the local copy and re-running to confirm `scp` fires).
   - Classification table is readable and the noise (category 3 ICS 403s) is not misclassified as category 1.
   - Category 1 issues are created with the correct template and URLs are returned.
   - Report file exists at `/tmp/log-triage-2026-04-18.md` and covers categories 2/3/4.
3. **Negative case.** Invoke `/analyze-logs 2020-01-01` (date that almost certainly does not exist on the server). Verify that `scp` failure is reported cleanly and the skill exits.

No automated tests. If the script misbehaves later, add a fixture-based pytest at that point.

## Safety Constraints (Production Access)

The SSH host alias `pronext` points at the production server. This skill is the only authorized consumer of that alias for this workflow, and its access is strictly limited:

- **Allowed**: exactly one command shape —
  `scp pronext:~/cps/pronext/logs/pronext_server_<YYYY-MM-DD>.log ./backend/logs/`
- **Forbidden**:
  - `ssh pronext <anything>` — no remote command execution, not even read-only probes like `ls`, `cat`, `df`, `uptime`.
  - `scp <local> pronext:<anywhere>` — no uploads. The data direction is pull-only.
  - Any `scp pronext:<path>` where `<path>` is not the dated log file under `~/cps/pronext/logs/`.
  - Shell expansions, globs, or multi-file `scp` (e.g. `*.log`) — only the single dated file.

The date placeholder `<YYYY-MM-DD>` must be validated (regex `^\d{4}-\d{2}-\d{2}$`) before being substituted into the `scp` command. Reject anything else to avoid command injection through the argument.

Any future need for broader production access must go through a fresh design review, not an ad-hoc edit of this skill. Codify this in a prominent comment block at the top of `SKILL.md`.

## Open Questions

- **Local cache of scp'd logs**: they land in `./backend/logs/` which is gitignored — OK for now, no cleanup logic. Revisit if disk use grows.
- **Default scp target**: uses the host alias `pronext` from `~/.ssh/config`. Implementation should verify this alias resolves before attempting the copy.
