---
description: Fetch user feedback issues from backend API, analyze and cluster similar ones, then create combined GitHub issues.
---

# Analyze Feedback Issues

Fetch feedback from the Django backend open API, analyze them, group similar issues, and create GitHub issues.

## Step 1: Read API Key

Read `OPEN_API_KEY` from `backend/.env`. This is the `X-API-Key` header value.

## Step 2: Fetch Feedback

Call the open API to get feedback issues:

```
GET https://api.pronextusa.com/app-api/open/feedback/list/
Header: X-API-Key: <key from step 1>
```

**Query params** (all optional):
- `ids=1,23,101` — specific feedback IDs (comma-separated)
- `status=0` — 0=new, 1=in_progress, 2=resolved, 3=closed, 4=need_more_info
- `type=0` — 0=bug, 1=feature, 2=perf, 3=sync, 4=other
- `date_from=2026-01-01` / `date_to=2026-04-14`
- `limit=200` — max results (cap 200)

Default filter if user doesn't specify: `status=0` (new issues only).

Use `curl` with the API key header. Parse the JSON response — it's wrapped in `{"list": [...]}`.

## Step 3: Analyze & Cluster

For each feedback item, extract:
- `id`, `sn`, `type_display`, `description`, `device_info`, `user_comments`, `admin_comments`

**Cluster similar issues** by:
1. Same `type` (bug, feature request, etc.)
2. Similar description content (same feature area, same error, same device model)
3. Related device info patterns (same OS version, same app version)

Present the clusters to the user in a table:

```
| Cluster | Type | Count | Feedback SNs | Summary |
|---------|------|-------|-------------|---------|
| 1       | Bug  | 3     | 001, 005, 012 | Calendar sync fails on Android 14 |
| 2       | Feature | 2  | 003, 008    | Request for dark mode support |
```

Ask the user which clusters to create as GitHub issues (or all).

## Step 4: Create GitHub Issues

For each approved cluster, create a GitHub issue using `gh`:

```bash
gh issue create --repo ck-tech-nz/pronext \
  --title "<type>: <summary>" \
  --label "<type-label>" \
  --body "$(cat <<'EOF'
## Summary
<1-2 sentence summary of the clustered feedback>

## User Reports
| SN | Description | Device | Date |
|----|-------------|--------|------|
| <sn> | <description excerpt> | <device model + OS> | <created_at> |

## User Comments
<Notable comments from users, if any>

## Admin Notes
<Any admin comments already made, if any>

---
Source: Feedback SNs $FEEDBACK_SNS
EOF
)"
```

**Label mapping:**
- Bug → `bug`
- Feature Request → `enhancement`
- Performance Issue → `performance`
- Sync Problem → `sync`
- Other → `feedback`

After creating each issue, report the issue URL back to the user.

## Step 5: Update Feedback Status + Link to GitHub Issue (optional)

After the GitHub issue is created, offer to update the processed feedback items via the open API write endpoints. Ask the user which target status to use:

- `1` (in_progress) — investigation started, no fix yet
- `2` (resolved) — root cause fixed, users can retry
- `3` (closed) — not actionable / duplicate / invalid
- `4` (need_more_info) — waiting on the reporter

For each feedback id in the cluster, run the two calls below. `$KEY` is the `OPEN_API_KEY` from Step 1. `$ISSUE_URL` is the GitHub issue URL returned by Step 4.

**Status + final conclusion update** — `PATCH /app-api/open/feedback/{id}/update/`. The body accepts `status` and/or `final_conclusion` (at least one required). Use `final_conclusion` when resolving/closing to record the official resolution summary visible in admin.

```bash
# Status only
curl -s -X PATCH -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"status": 1}' \
  "https://api.pronextusa.com/app-api/open/feedback/$ID/update/"

# Status + final conclusion (typical on resolve / close)
curl -s -X PATCH -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"status": 2, "final_conclusion": "Fixed in backend commit d920419."}' \
  "https://api.pronextusa.com/app-api/open/feedback/$ID/update/"
```

**Developer comment for traceability** — `POST /app-api/open/feedback/{id}/developer-comments/`. Developer comments are internal-only (not visible to the reporting user), so they are the right place to link the GitHub issue:

```bash
curl -s -X POST -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d "{\"content\": \"Tracked in $ISSUE_URL\"}" \
  "https://api.pronextusa.com/app-api/open/feedback/$ID/developer-comments/"
```

**Do NOT** post admin comments from this skill — those are user-visible and should be written by hand with context appropriate for the reporting user.

If the user wants to edit or remove a developer comment posted earlier:

```bash
# Update
curl -s -X PATCH -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"content": "updated note"}' \
  "https://api.pronextusa.com/app-api/open/feedback/developer-comments/$COMMENT_ID/"
# Delete
curl -s -X DELETE -H "X-API-Key: $KEY" \
  "https://api.pronextusa.com/app-api/open/feedback/developer-comments/$COMMENT_ID/"
```

The developer comment `id` is returned in the create response under `data.id`.
