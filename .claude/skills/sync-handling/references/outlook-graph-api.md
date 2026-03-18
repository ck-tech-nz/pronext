# Outlook (Microsoft Graph) Calendar API Reference

> Used by: Pad (Kotlin), Server (Django outlook_sync.py), Server (Go outlook_syncer)

## Official Documentation

| Resource | URL |
|----------|-----|
| Event resource type | https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0 |
| List events | https://learn.microsoft.com/en-us/graph/api/user-list-events?view=graph-rest-1.0 |
| List calendarView | https://learn.microsoft.com/en-us/graph/api/calendar-list-calendarview?view=graph-rest-1.0 |
| Get event | https://learn.microsoft.com/en-us/graph/api/event-get?view=graph-rest-1.0 |
| Create event | https://learn.microsoft.com/en-us/graph/api/user-post-events?view=graph-rest-1.0 |
| Update event | https://learn.microsoft.com/en-us/graph/api/event-update?view=graph-rest-1.0 |
| Delete event | https://learn.microsoft.com/en-us/graph/api/event-delete?view=graph-rest-1.0 |
| List instances | https://learn.microsoft.com/en-us/graph/api/event-list-instances?view=graph-rest-1.0 |
| Recurrence patterns | https://learn.microsoft.com/en-us/graph/api/resources/recurrencepattern?view=graph-rest-1.0 |
| Recurrence range | https://learn.microsoft.com/en-us/graph/api/resources/recurrencerange?view=graph-rest-1.0 |
| Delta query (events) | https://learn.microsoft.com/en-us/graph/api/event-delta?view=graph-rest-1.0 |
| Delta query guide | https://learn.microsoft.com/en-us/graph/delta-query-events |
| Prefer headers | https://learn.microsoft.com/en-us/graph/api/user-list-events?view=graph-rest-1.0#request-headers |
| Graph API changelog | https://developer.microsoft.com/en-us/graph/changelog |
| Beta API (event) | https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-beta |

> **Review reminder**: Check the official docs monthly (around the 1st) for updates. Key items to watch:
> - `cancelledOccurrences` property promotion from beta → v1.0 GA (eliminates calendarView workaround)
> - Delta query field coverage changes
> - Timezone handling or `Prefer` header behavior changes
> - Breaking changes in the Graph API changelog
>
> Last reviewed: 2026-03-17.

## Endpoints & Parameters

| Codepath | Endpoint | Key Params / Headers |
|----------|----------|---------------------|
| **Pad (Kotlin)** | `GET /me/calendars/{id}/events` | `$top=1000`, `$select=id,subject,start,end,isAllDay,isCancelled,recurrence,type,seriesMasterId,originalStart`, **`Prefer: outlook.timezone="UTC"`** |
| **Pad calendarView** | `GET /me/calendars/{id}/calendarView` | `$top=999`, `$select=start,seriesMasterId`, `startDateTime`, `endDateTime`, **`Prefer: outlook.timezone="UTC"`** — for cancelled occurrence detection |
| **Django** | `GET /me/calendars/{id}/events` | `$top=800`, `$select=id,subject,start,end,isAllDay,recurrence,isCancelled,seriesMasterId,type,lastModifiedDateTime`, `$orderby=lastModifiedDateTime desc` — **NO Prefer timezone header** |
| **Go syncer (initial)** | `GET /me/calendars/{id}/events` | `$select=id,subject,start,end,isAllDay,isCancelled,type,seriesMasterId,recurrence,lastModifiedDateTime,body,location`, `$top=200` — **NO Prefer timezone header** |
| **Go syncer (delta)** | `GET /me/calendars/{id}/events/delta` | Returns **minimal fields only** (id, type, start, end, @odata.etag, @removed) |
| **Go syncer (enrich)** | `GET /me/events/{id}` | Same `$select` as initial — fetches full data per delta item |

## Response Format

```json
{
  "value": [
    {
      "id": "AAMkAGI2...",
      "subject": "Weekly Review",
      "type": "seriesMaster",
      "isAllDay": false,
      "isCancelled": false,
      "seriesMasterId": null,
      "start": {
        "dateTime": "2026-03-13T01:00:00.0000000",
        "timeZone": "China Standard Time"
      },
      "end": {
        "dateTime": "2026-03-13T01:30:00.0000000",
        "timeZone": "China Standard Time"
      },
      "recurrence": {
        "pattern": {
          "type": "weekly",
          "interval": 1,
          "daysOfWeek": ["monday", "friday"],
          "firstDayOfWeek": "sunday",
          "dayOfMonth": 0,
          "month": 0,
          "index": "first"
        },
        "range": {
          "type": "noEnd",
          "startDate": "2026-03-13",
          "endDate": "0001-01-01",
          "numberOfOccurrences": 0,
          "recurrenceTimeZone": "China Standard Time"
        }
      },
      "lastModifiedDateTime": "2026-03-13T12:00:00Z",
      "@odata.etag": "W/\"abc123\""
    }
  ],
  "@odata.nextLink": "...pagination...",
  "@odata.deltaLink": "...for incremental sync..."
}
```

## DateTime & Timezone (CRITICAL DIFFERENCE FROM GOOGLE)

### `start.dateTime` / `start.timeZone`

- **`dateTime`**: ISO 8601 **in the timezone specified by `timeZone`** (NOT UTC by default)
- **`timeZone`**: **Microsoft timezone names** (NOT IANA!), e.g., `"China Standard Time"`
- Convert with `convert_tz()` in `utils.py` (100+ mappings)

### Prefer Header Changes Response Timezone

The `Prefer: outlook.timezone="UTC"` header tells the API to return ALL datetimes converted to UTC:

| Path | Prefer Header | dateTime In | timeZone Value |
|------|--------------|-------------|---------------|
| **Pad** | `outlook.timezone="UTC"` | UTC | `"UTC"` |
| **Django** | None | Calendar's configured tz | MS timezone name (e.g., `"China Standard Time"`) |
| **Go syncer** | None | Calendar's configured tz | MS timezone name |

**Known bug**: Pad's `Prefer: outlook.timezone="UTC"` causes `timezone='UTC'` to be stored,
but RRULE BYDAY rules are semantically in local time. Server `get_repeats()` has a fallback:
when `timezone='UTC'` + `synced_calendar_id` set + `device_timezone` differs → use device_timezone.
This fixes BYDAY display but creates EXDATE consistency issues (see Known Issues below).

### Microsoft → IANA Timezone Conversion

Key mappings in `utils.py:convert_tz()`:

| Microsoft Name | IANA Name |
|---------------|-----------|
| `China Standard Time` | `Asia/Shanghai` |
| `Eastern Standard Time` | `America/New_York` |
| `Pacific Standard Time` | `America/Tijuana` |
| `Central Standard Time` | `America/Chicago` |
| `Mountain Standard Time` | `America/Denver` |
| `Tokyo Standard Time` | `Asia/Tokyo` |
| `Singapore Standard Time` | `Asia/Singapore` |
| `W. Europe Standard Time` | `Europe/Vienna` |
| `GMT Standard Time` | `Europe/London` |
| `UTC` | *(not in mapping — passes through as-is)* |

Full list: 100+ entries in `backend/pronext/calendar/utils.py:convert_tz()`.

### All-Day Events

- `start.dateTime = "2026-03-15T00:00:00.0000000"` (midnight in event tz)
- `end.dateTime = "2026-03-16T00:00:00.0000000"` (**exclusive**, same as Google/ICS)
- Extract date: `substring(0, 10)` → `"2026-03-15"`, subtract 1 day from end for inclusive

## Event Types

| `type` Value | Description | `seriesMasterId` | `isCancelled` |
|-------------|-------------|------------------|--------------|
| `singleInstance` | Non-recurring event | null | false |
| `seriesMaster` | Recurring series master | null | false |
| `occurrence` | Regular occurrence of series | set | false |
| `exception` | Modified occurrence of series | set | false |
| *(cancelled)* | Cancelled occurrence | set | **true** |

**Critical**: The `/events` endpoint does **NOT** return cancelled/deleted occurrences at all.
Neither as `isCancelled=true` items nor as exception objects — they are simply absent from
the response. Verified via live API testing (2026-03-16): deleting individual occurrences of
a weekly event produces no trace in the `/events` response. The `cancelledOccurrences` property
exists only in the **beta** Graph API, not v1.0, and is unreliable even there.

### Detecting Cancelled Occurrences — Endpoint Comparison

| Approach | API Calls | Works? | Notes |
|----------|-----------|--------|-------|
| `/events` with `isCancelled` filter | 1 | **NO** | Cancelled occurrences simply absent from response |
| `/events/{id}/instances` per master | 1 per recurring event | YES | Correct but **O(N)** calls — avoid |
| `/calendarView` for date range | **1 total** | **YES** | Returns expanded instances; cancelled ones absent. **Recommended.** |
| `cancelledOccurrences` on master | 1 | Unreliable | Beta API only, not always populated |
| Delta Query `@removed` markers | incremental | Partial | Only works for incremental sync, not initial |

**Current implementation (Pad)**: Hybrid approach using 2 API calls total:
1. `/events` → get masters (with recurrence pattern) + single instances
2. `/calendarView` → get actual expanded instances for a date range
3. For each master, compare local rrule expansion against calendarView dates → missing = exdates

**Future improvement**: When Microsoft promotes `cancelledOccurrences` to v1.0 GA, switch to
reading it directly from the series master (single `/events` call, no calendarView needed).
Monitor: [Graph API event resource type](https://learn.microsoft.com/en-us/graph/api/resources/event?view=graph-rest-1.0)

## Recurrence Object Format

Outlook uses its own recurrence model (NOT RFC 5545 RRULE). Must convert with `recurrenceToRrule()`.

### Pattern Types

| `pattern.type` | RRULE FREQ | Extra Fields |
|----------------|------------|-------------|
| `daily` | `DAILY` | `interval` |
| `weekly` | `WEEKLY` | `daysOfWeek`, `firstDayOfWeek`, `interval` |
| `absoluteMonthly` | `MONTHLY` | `dayOfMonth`, `interval` |
| `relativeMonthly` | `MONTHLY` | `daysOfWeek`, `index`, `interval` |
| `absoluteYearly` | `YEARLY` | `month`, `dayOfMonth` |
| `relativeYearly` | `YEARLY` | `month`, `daysOfWeek`, `index` |

### Mappings

**Day names** (lowercase): `sunday→SU`, `monday→MO`, `tuesday→TU`, `wednesday→WE`,
`thursday→TH`, `friday→FR`, `saturday→SA`

**Index (ordinal position)**: `first→1`, `second→2`, `third→3`, `fourth→4`, `last→-1`

**Range types**: `noEnd` → no UNTIL/COUNT, `endDate` → `UNTIL`, `numbered` → `COUNT`

## Delta Query (Go Syncer Only)

### Initial Sync (deltaLink == "")

1. Call delta endpoint → get `@odata.deltaLink` only
2. Call `FetchAllEvents()` → **full event data** (subject, recurrence, isCancelled, etc.)
3. Send all events + deltaLink to Django

### Incremental Sync (deltaLink != "")

1. Call delta endpoint → **minimal data** only (id, type, @odata.etag, @removed)
2. Items with `@removed` → add to `removed[]` list for deletion
3. Other items → `FetchFullEvent()` per item for complete data
4. Send events + removed + new deltaLink to Django

**Key**: Delta responses lack `isCancelled` and `seriesMasterId`. Must call `FetchFullEvent()`
to get these fields. Events deleted between delta fetch and full fetch return 404 → treat as removed.

### Delta Response Special Fields

```json
{
  "@removed": { "reason": "deleted" },
  "@odata.deltaLink": "https://graph.microsoft.com/v1.0/.../delta?$deltatoken=..."
}
```

## Known Issues

### Cancelled Occurrences Detection

**Status**: FIXED (2026-03-16) — using calendarView hybrid approach

**Root cause**: Outlook `/events` endpoint does NOT return cancelled/deleted occurrences at all.
They are simply absent from the response — no `isCancelled=true` items, no exception objects.
This is a fundamental API limitation (verified via live API testing 2026-03-16).

**Solution**: Pad uses a hybrid approach with 2 API calls total:

1. `GET /events` → masters (with recurrence) + single instances (existing call)
2. `GET /calendarView?startDateTime=...&endDateTime=...` → expanded instances (1 extra call)
3. For each recurring master: compare local rrule expansion vs calendarView dates → diff = exdates

**Server fallback** (`outlook_sync.py`): Not yet implemented. The Go syncer could use the same
approach, but it's low priority since Pad is the primary syncer.

**Known timezone complication**: Pad uses `Prefer: outlook.timezone="UTC"`, so calendarView
returns dates in UTC. A timed event at China 01:00 AM shows as previous day 17:00 UTC.
The rrule expansion also uses date-only floating dates. Current implementation compares
`.substring(0, 10)` dates — this works because the Pad requests everything in UTC consistently.

**Future improvement**: When Microsoft promotes `cancelledOccurrences` to v1.0 GA, the
calendarView call can be eliminated. Monitor the event resource type docs for changes.

## File Paths

| Component | Path |
|-----------|------|
| Pad client | `pad/.../modules/calendar/OutlookCalendarClient.kt` |
| Django sync | `backend/pronext/calendar/outlook_sync.py` |
| Go syncer main | `backend/scripts/go/outlook_syncer/main.go` |
| Go syncer logic | `backend/scripts/go/outlook_syncer/syncer.go` |
| Go Graph API | `backend/scripts/go/outlook_syncer/outlook.go` |
| Go HTTP (Django calls) | `backend/scripts/go/outlook_syncer/http.go` |
| Go types | `backend/scripts/go/outlook_syncer/types.go` |
| Timezone mapping | `backend/pronext/calendar/utils.py:convert_tz()` |
