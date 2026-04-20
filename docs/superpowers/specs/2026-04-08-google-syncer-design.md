# Google Calendar Go Syncer

Replace Cloudflare Workers (JS) with a Go microservice for Google Calendar (type=1) synchronization. Mirror the JS sync logic as closely as possible, reuse existing Django endpoints, minimize backend changes.

## Context

Current flow: Cloudflare Worker `pronext-syncder` triggers `pronext-sync` on cron → fetches Google Calendar API → POSTs raw response to Django `sync_link_calendar` → Django `sync_calendar()` processes events.

New flow: Go `google_syncer` daemon replaces both Workers. Same data format, same Django endpoint.

## Scope

### In scope
- Go service: `scripts/go/google_syncer/`
- Django endpoint: `refresh_google_token` (new, mirrors `refresh_outlook_token`)
- Django fix: `_refresh_oauth_token` handles Google (type=1) in addition to Outlook (type=2)

### Out of scope
- ICS syncer changes (already handled by `ics_syncer`)
- Outlook syncer changes (already handled by `outlook_syncer`)
- Merging syncers into a unified service (future work)
- Removing Cloudflare Workers code (done manually after Go syncer is verified)

## Part 1: Django Changes

### 1a. `refresh_google_token` endpoint

New view in `calendar/views.py`, registered in URLs. Mirrors `refresh_outlook_token` (views.py:552).

```
GET /refresh_google_token/?id=<synced_calendar_id>
Header: Authorization: <SYNC_AUTH_HEADER>

Success 200: {"access_token": "ya29.xxx"}
Error 400:   {"detail": "missing id"} | {"detail": "no credentials"}
Error 404:   {"detail": "not found"}
Error 500:   {"detail": "refresh failed"} | {"detail": "<error message>"}
```

Implementation:
1. Auth check (same `AUTHORIZATION` constant)
2. Load `SyncedCalendar` by id
3. Extract `refresh_token` from `synced.credit`
4. Call `services.refresh_google_token(refresh_token)` (already exists at services.py:289)
5. Update `synced.credit['access_token']` and `synced.credit_expired_at`
6. Return new access_token

### 1b. `_refresh_oauth_token` — add Google support

Current code at views.py:81-106 only refreshes Outlook (type=2). Add Google (type=1):

```python
if synced.calendar_type == 1:  # Google
    refresh_token = synced.credit.get('refresh_token')
    if refresh_token:
        result = services.refresh_google_token(refresh_token)
        synced.credit['access_token'] = result['access_token']
        synced.credit_expired_at = timezone.now() + timedelta(seconds=result['expires_in'])
        synced.save(update_fields=['credit', 'credit_expired_at'])
        access_token = result['access_token']
```

This means `get_sync_calendars` will auto-refresh Google tokens before returning them, same as Outlook.

## Part 2: Go google_syncer

### File structure

```
scripts/go/google_syncer/
  main.go                  # Entry point, graceful shutdown
  config.go                # Env vars + CLI flags
  types.go                 # Google Calendar API response structs
  http.go                  # Django API communication
  google.go                # Google Calendar API v3 calls
  syncer.go                # Core sync loop + concurrency
  syncer_test.go           # Tests
  google_syncer.service    # systemd unit file
  go.mod
```

### Config (env vars)

| Variable | Default | Description |
|----------|---------|-------------|
| `API_DOMAIN` | `https://api.pronextusa.com` | Django backend URL |
| `SYNC_AUTH_HEADER` | (required) | Authorization header value |
| `SYNC_INTERVAL` | `5m` | Polling interval |

CLI flags: `-c` (concurrency, default 5), `-i` (interval override)

### Data flow

```
Run() loop
  │
  ├─ FetchGoogleCalendars()
  │    GET /get_sync_calendars/?calendar_type=1&skip_online=true
  │    Response: { "calendars": [{ id, email, access_token, calendar_id, ... }] }
  │
  └─ For each calendar (goroutine pool, semaphore):
       │
       ├─ FetchGoogleEvents(access_token, email)
       │    GET https://www.googleapis.com/calendar/v3/calendars/{email}/events
       │      ?maxResults=2500&orderBy=updated&timeMin={6_months_ago}
       │    → 200: JSON response with items[]
       │    → 401/403/404: error code only
       │
       ├─ On 401: RefreshGoogleToken(calendar_id)
       │    GET /refresh_google_token/?id={calendar_id}
       │    → retry FetchGoogleEvents once with new token
       │
       └─ SyncToBackend()
            POST /sync_link_calendar/
            Body: { "id": X, "rel_user_ids": [...], "link_res": { "code": 200, "items": [...], "updated": "..." } }
            (same format as Cloudflare Worker)
```

### Google Calendar API call — match JS exactly

The JS Worker (pronext-sync.js) calls:
```
GET https://www.googleapis.com/calendar/v3/calendars/{email}/events
  ?maxResults=2500&orderBy=updated&timeMin={6_months_ago}
Headers: Authorization: Bearer {token}, Content-Type: application/json, Accept: application/json
Timeout: 5s
```

Go implementation must use identical parameters. The `timeMin` is calculated as 6 months before current UTC time, formatted as `YYYY-MM-DDT00:00:00Z`.

### SyncToBackend payload

Django `sync_link_calendar` (views.py:276) only uses three fields from the body: `id`, `rel_user_ids`, `link_res`. Everything else is ignored.

Success case:
```json
{
  "id": 123,
  "rel_user_ids": [776, 777],
  "link_res": {
    "code": 200,
    "items": [...],        // Google Calendar API items array
    "updated": "...",      // Google Calendar API updated timestamp
    "etag": "...",         // Google Calendar API etag
    ...                    // All other Google Calendar API response fields
  }
}
```

Error case (401/403/404):
```json
{
  "id": 123,
  "rel_user_ids": [776, 777],
  "link_res": { "code": 401 }
}
```

**Important**: `link_res` must contain the full Google Calendar API JSON response with a `code` field added. Django's `sync_calendar()` (options.py:252) passes `link_res` to `get_google_events(synced.email, link_res)` which reads `items`, `updated`, `etag` etc. from it.

### Change detection — `google_calendar_updated`

The JS Worker checks:
```javascript
if (synced.google_calendar_updated != "" && synced.google_calendar_updated == result.updated) {
  return { code: 400, msg: "google no need sync" };
}
```

The Go syncer should replicate this: compare the `updated` field from the Google API response against the value stored in Django. However, the new `get_sync_calendars` endpoint does NOT return `google_calendar_updated`. Two options:

1. Skip this optimization in Go (Django `sync_calendar()` already checks etag at line 274)
2. Add the field to `get_sync_calendars` response

**Decision**: Skip for now. Django's etag check is the authoritative dedup, and this was just an early-exit optimization in the Worker. Can be added later if needed.

### Concurrency model

Same as outlook_syncer: semaphore channel + WaitGroup.

```go
sem := make(chan struct{}, config.Concurrency)
var wg sync.WaitGroup
for _, cal := range calendars {
    wg.Add(1)
    go func(cal GoogleCalendar) {
        defer wg.Done()
        sem <- struct{}{}
        defer func() { <-sem }()
        processCalendar(cal)
    }(cal)
}
wg.Wait()
```

### Error handling

| Scenario | Action |
|----------|--------|
| Google API 200 | Forward full response to Django |
| Google API 401 | Call `refresh_google_token`, retry once |
| Google API 403/404 | Forward `{ "code": 403 }` to Django (Django marks calendar) |
| Google API other error | Log, increment failed count |
| Django API error | Log, increment failed count |
| Network timeout | Log, increment failed count |

### Stats & logging

Same pattern as outlook_syncer: per-round summary with total/success/skipped/failed.

### systemd service

```ini
[Unit]
Description=Pronext Google Calendar Syncer
After=network.target

[Service]
Type=simple
User=nobody
WorkingDirectory=/opt/pronext
ExecStart=/opt/pronext/google_syncer
Environment=API_DOMAIN=https://api.pronextusa.com
Environment=SYNC_AUTH_HEADER=<token>
Environment=SYNC_INTERVAL=5m
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Testing

### Django
- Test `refresh_google_token`: success, missing id, no credentials, refresh failure
- Test `_refresh_oauth_token` handles Google type

### Go
- Test `FetchGoogleCalendars`: calendar list parsing, auth validation
- Test `FetchGoogleEvents`: 200 response parsing, 401/403/404 handling
- Test `SyncToBackend`: payload structure matches JS Worker format
- Test `RefreshGoogleToken`: new token returned, error handling
- Test 401 retry flow: fetch → 401 → refresh → retry → success

## Migration plan

1. Deploy Django changes (refresh endpoint + _refresh_oauth_token fix)
2. Deploy google_syncer on same Linux server as ics_syncer / outlook_syncer
3. Verify sync works for a few calendars (`synced_ids` filter)
4. Disable Cloudflare Worker cron schedule
5. Monitor for 1-2 days
6. Remove Cloudflare Worker code (future cleanup)
