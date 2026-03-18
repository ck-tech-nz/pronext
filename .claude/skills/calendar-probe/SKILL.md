---
name: calendar-probe
description: >
  Diagnose calendar sync issues by probing local databases (PostgreSQL, Redis) and
  third-party calendar APIs (Google Calendar, Outlook/MS Graph) using tokens stored
  in SyncedCalendar. Use when debugging sync failures, verifying token health,
  inspecting beat flags, or testing API calls against Google/Outlook.
---

# Calendar Probe — Local DB & Third-Party API Diagnostic Tool

This skill provides patterns for inspecting the Pronext calendar sync pipeline
end-to-end: from local database state to third-party API responses.

## 1. Environment Setup

### 1.1 Reading .env

Connection credentials live in `backend/.env`. Key variables:

```
DJANGO_PG=pg://postgres:postgres@127.0.0.1:25432/pronext_backup_...
DJANGO_REDIS=redis://127.0.0.1:6379/8
SIGNING_KEY=...
OUTLOOK_CLIENT_ID=...
OUTLOOK_CLIENT_SECRET=...
```

Parse `DJANGO_PG` format: `pg://<user>:<password>@<host>:<port>/<dbname>`

### 1.2 Activating Django Environment

All Django shell / ORM commands require the venv:

```bash
cd server && source .venv/bin/activate
```

## 2. Database Probing

### 2.1 PostgreSQL via Django Shell

The fastest way to query the DB with full ORM support:

```bash
cd server && source .venv/bin/activate && python3 manage.py shell
```

Inside the shell:

```python
from pronext.calendar.models import SyncedCalendar, Event

# List all synced calendars (with type labels)
for sc in SyncedCalendar.objects.all():
    print(f"id={sc.id} type={sc.get_calendar_type_display()} name={sc.name} "
          f"user={sc.user_id} active={sc.is_active} style={sc.get_synced_style_display()} "
          f"res_code={sc.res_code}")

# Filter by type
google_cals = SyncedCalendar.objects.filter(calendar_type=1)  # GOOGLE=1
outlook_cals = SyncedCalendar.objects.filter(calendar_type=2)  # OUTLOOK=2

# Check credential health for a specific calendar
sc = SyncedCalendar.objects.get(id=<ID>)
credit = sc.credit or {}
print(f"has access_token: {bool(credit.get('access_token'))}")
print(f"has refresh_token: {bool(credit.get('refresh_token'))}")
print(f"credit_expired_at: {sc.credit_expired_at}")
print(f"calendar_id (Outlook): {sc.calendar_id}")
print(f"email (Google): {sc.email}")
print(f"last synced: {sc.synced_at}")
print(f"sync_state: {sc.sync_state[:100] if sc.sync_state else 'empty'}")

# Count events for a synced calendar
Event.objects.filter(synced_calendar_id=<ID>).count()

# Check events with recurrence
Event.objects.filter(synced_calendar_id=<ID>, recurrence__isnull=False).exclude(recurrence='').count()
```

### 2.2 PostgreSQL via psql (Direct SQL)

Parse connection from `DJANGO_PG` in `.env`:

```bash
# Extract from .env: pg://postgres:postgres@127.0.0.1:25432/dbname
psql -h 127.0.0.1 -p 25432 -U postgres -d <dbname>
```

Useful queries:

```sql
-- All synced calendars overview
SELECT id, calendar_type, name, user_id, is_active, res_code, res_text,
       credit IS NOT NULL AS has_credit, credit_expired_at, synced_at
FROM calendar_syncedcalendar
ORDER BY id;

-- Calendar type reference: 0=NONE, 1=GOOGLE, 2=OUTLOOK, 3=ICLOUD, 4=COZI, 5=YAHOO, 6=URL, 7=US_HOLIDAYS

-- Check token presence (without exposing full tokens)
SELECT id, calendar_type, name,
       credit->>'access_token' IS NOT NULL AS has_access_token,
       credit->>'refresh_token' IS NOT NULL AS has_refresh_token,
       credit_expired_at
FROM calendar_syncedcalendar
WHERE calendar_type IN (1, 2) AND is_active = true;

-- Events per synced calendar
SELECT synced_calendar_id, COUNT(*) AS event_count
FROM calendar_event
WHERE synced_calendar_id IS NOT NULL
GROUP BY synced_calendar_id
ORDER BY event_count DESC;

-- Sync errors
SELECT id, calendar_type, name, res_code, LEFT(res_text, 200) AS error
FROM calendar_syncedcalendar
WHERE res_code != 0;
```

### 2.3 Redis Probing

Redis DB 8 is shared between Django and Go heartbeat service. All Django cache keys have `:1:` prefix.

```bash
redis-cli -h 127.0.0.1 -p 6379 -n 8
```

Key patterns:

```redis
# Beat flags for a device (15s TTL)
GET :1:beat1:<device_id>
# Returns JSON: {"event": true, "event_cate": false, "chore": false, ...}

# Synced calendar beat flag (15s TTL)
GET :1:beat:synced_calendar:<device_id>__<rel_user_id>
# Returns: "1" if device should re-sync calendars

# Device online status (1h TTL)
GET device:online_status:<device_sn>

# List all beat keys
KEYS :1:beat*

# List all sync calendar flags
KEYS :1:beat:synced_calendar:*

# Check TTL
TTL :1:beat1:<device_id>

# Manually set a beat flag (for testing)
SETEX :1:beat:synced_calendar:<device_id>__<rel_user_id> 15 1
```

## 3. Third-Party API Probing

### 3.1 Token Acquisition

Get a valid access_token from Django (handles refresh automatically):

```bash
cd server && source .venv/bin/activate && python3 manage.py shell
```

```python
from pronext.calendar.services import get_access_token
from pronext.calendar.models import SyncedCalendar

sc = SyncedCalendar.objects.get(id=<ID>)
access_token, expires_in = get_access_token(sc)
print(f"Token (first 20): {access_token[:20]}...")
print(f"Expires in: {expires_in}s")
```

If the token is expired and refresh fails, `CredentialExpiredError` is raised — meaning
the user needs to re-authenticate via OAuth flow.

### 3.2 Manual Token Refresh (if get_access_token is unavailable)

**Google:**
```python
from pronext.calendar.services import refresh_google_token
sc = SyncedCalendar.objects.get(id=<ID>)
result = refresh_google_token(sc.credit['refresh_token'])
# result = {'access_token': '...', 'expires_in': 3600}
```

**Outlook:**
```python
from pronext.calendar.services import refresh_outlook_token
sc = SyncedCalendar.objects.get(id=<ID>)
result = refresh_outlook_token(sc.credit['refresh_token'])
# result = {'access_token': '...', 'expires_in': 3600, 'refresh_token': '...(maybe)'}
```

### 3.3 Google Calendar API Calls

#### Via GoogleCalendar class (recommended — handles auth, proxy, token refresh):

```python
from pronext.calendar.options import _get_gc
from pronext.calendar.models import SyncedCalendar

sc = SyncedCalendar.objects.get(id=<ID>)
gc = _get_gc(sc, need_two_way=False)  # False = read-only ok

# List calendars
calendars = gc.get_calendar_list()
for c in calendars:
    print(c)

# Get events (returns parsed dict with 'events' and 'etag')
result = gc.get_events()
print(f"Event count: {len(result.get('events', []))}")
for e in result.get('events', [])[:5]:
    print(f"  {e.get('synced_id')}: {e.get('title')} | {e.get('start_at') or e.get('start_date')}")
```

#### Via raw HTTP (with access_token from step 3.1):

```bash
# List calendars
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "https://www.googleapis.com/calendar/v3/users/me/calendarList" | python3 -m json.tool

# List events (singleEvents=false to get masters + instances)
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "https://www.googleapis.com/calendar/v3/calendars/<CALENDAR_EMAIL>/events?maxResults=10&orderBy=updated" \
  | python3 -m json.tool

# Get single event
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "https://www.googleapis.com/calendar/v3/calendars/<CALENDAR_EMAIL>/events/<EVENT_ID>" \
  | python3 -m json.tool
```

**Key Google params:**
- `singleEvents=false` — returns master recurring events (with `recurrence` field) + exceptions
- `singleEvents=true` — returns expanded occurrences (no `recurrence`, useful for date-range queries)
- `orderBy=updated` — most recently modified first (requires `singleEvents=false`)
- `orderBy=startTime` — chronological (requires `singleEvents=true`)
- `timeMin`, `timeMax` — ISO 8601 date filter (e.g. `2026-03-01T00:00:00Z`)
- `maxResults` — default 250, max 2500

### 3.4 Outlook (Microsoft Graph) API Calls

#### Via OutlookCalendar class (recommended):

```python
from pronext.calendar.options import _get_outlook
from pronext.calendar.models import SyncedCalendar

sc = SyncedCalendar.objects.get(id=<ID>)
outlook = _get_outlook(sc, need_two_way=False)

# List calendars
calendars = outlook.get_calendar_list()
for c in calendars:
    print(f"  {c['id'][:30]}... name={c['name']} default={c['isDefaultCalendar']}")

# Get events
result = outlook.get_events(calendar_id=sc.calendar_id)
print(f"Event count: {len(result.get('events', []))}")
for e in result.get('events', [])[:5]:
    print(f"  {e.get('synced_id')}: {e.get('title')} | {e.get('start_at') or e.get('start_date')}")
```

#### Via raw HTTP (with access_token from step 3.1):

```bash
# List calendars
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "https://graph.microsoft.com/v1.0/me/calendars" | python3 -m json.tool

# List events from specific calendar
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  -H "Prefer: outlook.timezone=\"UTC\"" \
  "https://graph.microsoft.com/v1.0/me/calendars/<CALENDAR_ID>/events?\$top=10&\$select=id,subject,start,end,isAllDay,recurrence,isCancelled,type,seriesMasterId" \
  | python3 -m json.tool

# Get single event
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "https://graph.microsoft.com/v1.0/me/events/<EVENT_ID>" \
  | python3 -m json.tool

# Calendar view (expanded occurrences in date range — useful for cancelled occurrence detection)
curl -s -H "Authorization: Bearer <ACCESS_TOKEN>" \
  -H "Prefer: outlook.timezone=\"UTC\"" \
  "https://graph.microsoft.com/v1.0/me/calendars/<CALENDAR_ID>/calendarView?\$top=999&startDateTime=2026-03-01T00:00:00Z&endDateTime=2026-04-01T00:00:00Z&\$select=id,subject,start,end,seriesMasterId,isCancelled" \
  | python3 -m json.tool
```

**Key Outlook params:**
- `$top` — max results per page (default 10, max 1000)
- `$select` — field list (comma-separated)
- `$orderby` — e.g. `lastModifiedDateTime desc`
- `$filter` — OData filter (e.g. `type eq 'seriesMaster'`)
- `Prefer: outlook.timezone="UTC"` — return all times in UTC (Pad uses this; Django does NOT)

**Outlook event types** (from `type` field):
- `singleInstance` — non-recurring event
- `seriesMaster` — master recurring event (has `recurrence` object)
- `occurrence` — unmodified instance of a series
- `exception` — modified instance of a series

### 3.5 Token Relay (Simulating Pad → Server → API)

Test the same endpoint Pad devices use:

```python
from pronext.calendar.services import get_access_token
from pronext.calendar.models import SyncedCalendar

# Simulate what /synced_calendar/{id}/token returns to Pad
sc = SyncedCalendar.objects.get(id=<ID>)
token, expires = get_access_token(sc)
print(f'{{"access_token": "{token[:20]}...", "expires_in": {expires}}}')
```

## 4. Common Diagnostic Scenarios

### 4.1 "Sync not working" — Full Pipeline Check

```python
from pronext.calendar.models import SyncedCalendar

sc = SyncedCalendar.objects.get(id=<ID>)

# 1. Is it active?
print(f"Active: {sc.is_active}")

# 2. Does it have credentials?
credit = sc.credit or {}
print(f"Has tokens: access={bool(credit.get('access_token'))}, refresh={bool(credit.get('refresh_token'))}")

# 3. Last sync status
print(f"res_code: {sc.res_code} res_text: {sc.res_text[:200]}")
print(f"Last synced: {sc.synced_at}")

# 4. Can we get a fresh token?
from pronext.calendar.services import get_access_token, CredentialExpiredError
try:
    token, exp = get_access_token(sc)
    print(f"Token OK, expires in {exp}s")
except CredentialExpiredError as e:
    print(f"EXPIRED: {e} — user must re-authorize")

# 5. Can we hit the API?
if sc.calendar_type == 1:
    from pronext.calendar.options import _get_gc
    gc = _get_gc(sc, need_two_way=False)
    if gc:
        result = gc.get_events()
        print(f"API returned {len(result.get('events', []))} events")
elif sc.calendar_type == 2:
    from pronext.calendar.options import _get_outlook
    outlook = _get_outlook(sc, need_two_way=False)
    if outlook:
        result = outlook.get_events(calendar_id=sc.calendar_id)
        print(f"API returned {len(result.get('events', []))} events")
```

### 4.2 "Events missing after sync"

```python
from pronext.calendar.models import Event, SyncedCalendar

sc = SyncedCalendar.objects.get(id=<ID>)

# Compare DB events vs API events
db_events = Event.objects.filter(synced_calendar_id=sc.id)
db_synced_ids = set(db_events.values_list('synced_id', flat=True))
print(f"DB events: {db_events.count()}")

# Fetch from API
# (use gc.get_events() or outlook.get_events() as in 4.1 step 5)
# api_synced_ids = {e['synced_id'] for e in result['events']}
# missing = api_synced_ids - db_synced_ids
# extra = db_synced_ids - api_synced_ids
# print(f"Missing from DB: {len(missing)}")
# print(f"Extra in DB (deleted upstream): {len(extra)}")
```

### 4.3 "Beat flags not reaching device"

```bash
# 1. Check device is online
redis-cli -h 127.0.0.1 -p 6379 -n 8 GET device:online_status:<device_sn>

# 2. Manually fire a beat and check Redis
python3 manage.py shell -c "
from pronext.common.models import Beat
b = Beat(<device_id>, <rel_user_id>)
b.should_refresh_event(True)
print('Beat set')
"

# 3. Check Redis immediately (within 15s TTL)
redis-cli -h 127.0.0.1 -p 6379 -n 8 GET :1:beat1:<device_id>

# 4. Check synced_calendar flag
redis-cli -h 127.0.0.1 -p 6379 -n 8 GET :1:beat:synced_calendar:<device_id>__<rel_user_id>
```

### 4.4 Quick Token Flush (Force Refresh)

```python
from pronext.calendar.options import flush_google_token, flush_outlook_token

# Force refresh specific calendar's token
flush_google_token(id=<SYNCED_CALENDAR_ID>)   # for Google
flush_outlook_token(id=<SYNCED_CALENDAR_ID>)   # for Outlook
```

## 5. SyncedCalendar Model Quick Reference

| Field | Type | Description |
|-------|------|-------------|
| `calendar_type` | int | 0=NONE, 1=GOOGLE, 2=OUTLOOK, 3=ICLOUD, 4=COZI, 5=YAHOO, 6=URL, 7=US_HOLIDAYS |
| `synced_style` | int | 1=ONE_WAY, 2=TWO_WAY |
| `email` | str | Google Calendar email |
| `calendar_id` | str | Outlook/iCloud calendar ID |
| `link` | str | ICS subscription URL |
| `credit` | JSON | `{access_token, refresh_token, expires_at, ...}` |
| `credit_expired_at` | datetime | When current token expires |
| `sync_state` | text | Outlook deltaLink / CalDAV sync-token |
| `etag` | str | Google collection etag (change detection) |
| `sha256` | str | ICS content hash (change detection) |
| `res_code` | int | 0=OK, 401=auth failed, etc. |
| `res_text` | text | Error message from last sync |
| `is_active` | bool | Whether to sync this calendar |
| `is_public` | bool | Whether shared across devices |
| `synced_at` | datetime | Last successful sync time |
| `profile_ids` | int[] | Default category IDs for events |

## 6. File Reference

| Purpose | File |
|---------|------|
| SyncedCalendar model | `backend/pronext/calendar/models.py` |
| Token management (get/refresh) | `backend/pronext/calendar/services.py` |
| GoogleCalendar class | `backend/pronext/calendar/sync.py` |
| OutlookCalendar class | `backend/pronext/calendar/outlook_sync.py` |
| `_get_gc()`, `_get_outlook()`, flush, sync | `backend/pronext/calendar/options.py` |
| Token relay endpoint | `backend/pronext/calendar/viewset_pad.py` → `token()` action |
| Beat model | `backend/pronext/common/models.py` |
| Environment variables | `backend/.env` |
| Google API reference | `.claude/skills/sync-handling/references/google-calendar-api.md` |
| Outlook API reference | `.claude/skills/sync-handling/references/outlook-graph-api.md` |
