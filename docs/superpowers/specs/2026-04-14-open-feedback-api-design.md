# Open Feedback API

Read-only API for scripts and agents (e.g. Claude Code) to query feedback data from the Django backend. Enables local AI analysis of user-reported issues without adding complexity to the server.

## Motivation

Feedback issues are managed in Django Admin. To let Claude Code analyze and cluster issues (then create GitHub issues via `gh`), we need a machine-readable endpoint. The server's role is limited to serving data — all analysis and GitHub integration happens client-side.

## Auth

Reuse existing `ManagementAPIKeyPermission` from `pronext/common/permissions.py`. No new model or migration.

- Header: `X-API-Key: <MANAGEMENT_API_KEY>`
- Key is stored in `.env` / `settings.MANAGEMENT_API_KEY`

## Endpoint

```
GET /app-api/open/feedback/
```

### Query Parameters

| Param       | Type   | Example          | Description                                |
|-------------|--------|------------------|--------------------------------------------|
| `ids`       | string | `1,23,101,205`   | Comma-separated feedback IDs (typical use) |
| `status`    | int    | `0`              | 0=new, 1=in_progress, 2=resolved, 3=closed, 4=need_more_info |
| `type`      | int    | `0`              | 0=bug, 1=feature, 2=perf, 3=sync, 4=other |
| `date_from` | date   | `2026-01-01`     | Created at >=                              |
| `date_to`   | date   | `2026-04-14`     | Created at <=                              |
| `limit`     | int    | `50`             | Max results returned (default & cap: 200)  |

All parameters are optional. When `ids` is provided, other filters still apply (intersection).

### Response

Flat JSON list. No pagination wrapper.

```json
[
  {
    "id": 42,
    "sn": "20260410-003",
    "type": 0,
    "type_display": "Bug",
    "status": 1,
    "status_display": "In Progress",
    "description": "Calendar sync fails after updating to v2.3",
    "email": "user@example.com",
    "device_info": {"model": "Pad Pro", "os_version": "14.2"},
    "app_log": "...",
    "final_conclusion": "",
    "created_at": "2026-04-10T08:30:00Z",
    "updated_at": "2026-04-11T14:00:00Z",
    "attachments": [
      {"id": 1, "file_url": "https://...", "file_type": "image/png"}
    ],
    "user_comments": [
      {"id": 5, "content": "Still happening", "user_username": "john", "created_at": "..."}
    ],
    "admin_comments": [
      {"id": 3, "content": "We're investigating", "user_username": "Admin", "created_at": "..."}
    ]
  }
]
```

Developer comments are excluded (internal only).

### Limit

Single constant: `MAX_LIMIT = 200`. Serves as both default and cap. If the caller passes `limit=50`, they get 50. If they pass nothing or exceed 200, they get 200.

## Files

| Action | File | What |
|--------|------|------|
| Create | `pronext/support/viewset_open.py` | `OpenFeedbackViewSet` — list action with filtering |
| Create | `pronext/support/open_serializers.py` | `OpenFeedbackSerializer` — full feedback with comments |
| Modify | `pronext/core/api.py` | Add `open_router` + `register_open_route` decorator |
| Modify | `pronext_server/urls.py` | Wire `open_router` at `/app-api/open/` |

## Routing

Follows the existing pattern: `register_open_route("feedback")` on the viewset, auto-discovered via `open_router`. Mounted at `/app-api/open/` in the main URL config.

## Not In Scope

- GitHub issue creation (handled by Claude Code locally via `gh`)
- Write operations (this API is read-only)
- Developer comments exposure
- Pagination
- New auth model or migration
