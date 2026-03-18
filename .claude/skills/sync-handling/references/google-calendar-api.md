# Google Calendar API Reference

> Used by: Pad (Kotlin), Server (Django sync.py), Cloudflare Worker

## Official Documentation

| Resource | URL |
|----------|-----|
| Events: list | https://developers.google.com/calendar/api/v3/reference/events/list |
| Events: get | https://developers.google.com/calendar/api/v3/reference/events/get |
| Events: insert | https://developers.google.com/calendar/api/v3/reference/events/insert |
| Events: update | https://developers.google.com/calendar/api/v3/reference/events/update |
| Events: delete | https://developers.google.com/calendar/api/v3/reference/events/delete |
| Events: instances | https://developers.google.com/calendar/api/v3/reference/events/instances |
| Event resource | https://developers.google.com/calendar/api/v3/reference/events#resource |
| Recurring events | https://developers.google.com/calendar/api/guides/recurringevents |
| Sync guide (incremental) | https://developers.google.com/calendar/api/guides/sync |
| Push notifications | https://developers.google.com/calendar/api/guides/push |
| API changelog | https://developers.google.com/calendar/api/support |

> **Review reminder**: Check the official docs monthly (around the 1st) for deprecations,
> new fields, quota changes, or breaking updates. Last reviewed: 2026-03-17.

## Endpoints & Parameters

| Codepath | Endpoint | Key Params |
|----------|----------|------------|
| **Pad (Kotlin)** | `GET /calendars/{id}/events` | `singleEvents=false`, `maxResults=2500` |
| **Django (sync.py)** | `GET /calendars/{id}/events` | `maxResults=800`, `orderBy=updated` |
| **Django (google_api.py)** | `GET /calendars/{id}/events` | `singleEvents=true`, `orderBy=startTime`, `timeMin/timeMax` |
| **Cloudflare Worker** | `GET /calendars/{id}/events` | `maxResults=2500`, `orderBy=updated`, `timeMin` (6mo ago) |

Pad uses `singleEvents=false` to get master recurring events (with `recurrence` field) plus
modified/cancelled instances (with `recurringEventId`). Pad does local rrule expansion.

## Response Format

```json
{
  "items": [
    {
      "id": "event_id_string",
      "summary": "Event title",
      "status": "confirmed | cancelled",
      "etag": "\"hash_value\"",
      "colorId": "1",
      "start": {
        "date": "2026-03-15",
        "dateTime": "2026-03-15T14:00:00-04:00",
        "timeZone": "America/New_York"
      },
      "end": { "...same structure..." },
      "recurrence": [
        "RRULE:FREQ=DAILY;UNTIL=20250630T235959Z",
        "EXDATE;TZID=America/New_York:20250615T140000,20250620T140000"
      ],
      "recurringEventId": "parent_event_id_if_instance",
      "originalStartTime": { "...same as start..." }
    }
  ],
  "updated": "2025-03-15T12:34:56Z",
  "etag": "collection_etag"
}
```

## Field Format Rules

- **`start.date`** (all-day): `yyyy-MM-dd`, no timezone. **End date is EXCLUSIVE.**
- **`start.dateTime`** (timed): RFC 3339 with timezone offset (e.g., `2026-03-15T14:00:00-04:00`)
- **`start.timeZone`**: IANA timezone name (e.g., `"America/New_York"`)
- **`colorId`**: String `"1"`–`"11"` or `"undefined"` (not int). Maps via `enums.py:google_color_hex`.
- **`recurrence`**: Array containing RRULE and optionally EXDATE lines (iCalendar format)

## Event Types

| Type | Characteristics | `recurringEventId` | `status` |
|------|----------------|-------------------|----------|
| **Master** | Has `recurrence` | null | `"confirmed"` |
| **Modified instance** | Modified occurrence | set (→ master id) | `"confirmed"` |
| **Cancelled instance** | Deleted occurrence | set (→ master id) | `"cancelled"` |
| **Single event** | No `recurrence` | null | `"confirmed"` |

### Exception Processing (Pad)

```kotlin
// GoogleCalendarClient.kt — classify and process via shared helper:
for (event in allEvents) {
    if (event.recurringEventId != null) {
        exceptions.add(ExceptionInstance(
            entity = toEntity(event, syncedCalendarId),
            masterSyncedId = event.recurringEventId,
            originalDate = extractOriginalDate(event),
            isCancelled = event.status == "cancelled",
        ))
    } else if (event.status != "cancelled") {
        masters.add(toEntity(event, syncedCalendarId))
    }
}
return RecurrenceExceptionHelper.process(masters, exceptions)
```

### Exception Processing (Server Django)

```python
# sync.py — Cancelled occurrences collected into repeat_exclude:
for item in items:
    recurring_id = item.get('recurringEventId')
    if recurring_id is not None:
        cancel_date = item.get('originalStartTime', {}).get('date')
        cancel_at = item.get('originalStartTime', {}).get('dateTime')
        flag = format_time(cancel_date or cancel_at, cancel_date is not None)
        cancelled_events.setdefault(recurring_id, []).append(flag)
# Later: master.repeat_exclude = list(set(existing + cancelled_dates))
```

## EXDATE Formats

Google provides EXDATE in the `recurrence` array:

| Format | Example |
|--------|---------|
| All-day (VALUE=DATE) | `EXDATE;VALUE=DATE:20260115,20260120` |
| Timed with timezone | `EXDATE;TZID=America/New_York:20260115T140000` |
| Timed UTC | `EXDATE:20260115T140000Z` |

Parse with `parseExdatesFromLine()`. ICS date `20260115` → `2026-01-15`.
Server (sync_event.py) also handles TZID conversion: parse naive datetime, attach tzinfo, convert to UTC.

## Change Detection

- **Collection-level**: `response.etag` or `response.updated` compared to stored value
- **Event-level**: `etag` per event stored as `syncedEtag`
- **Cloudflare**: Compares `result.updated` with `synced.google_calendar_updated`

## File Paths

| Component | Path |
|-----------|------|
| Pad client | `pad/.../modules/calendar/GoogleCalendarClient.kt` |
| Django sync | `backend/pronext/calendar/sync.py` |
| Django API helper | `backend/pronext/calendar/google_api.py` |
| Event conversion | `backend/pronext/calendar/sync_event.py` |
| Color mappings | `backend/pronext/calendar/enums.py` |
| Cloudflare Worker | `backend/cloudflare/pronext-sync/pronext-sync.js` |
