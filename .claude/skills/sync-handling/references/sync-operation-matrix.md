# Sync Operation Matrix — Authoritative Reference

> This document is the single source of truth for all calendar sync operations.
> Every code change to sync logic MUST be validated against this matrix.
> Tests MUST cover every path listed here.

## 1. Single Event CUD — 18 Core Paths

### Legend

- **Provider**: Google Calendar API / Outlook (Microsoft Graph) / None (own event, no external sync)
- **change_type**: ALL(1) / THIS(0) / AND_FUTURE(2)
- **Event type**: all-day (start_date/end_date) / timed (start_at/end_at)
- **Direction**: Pad → Server → Provider (two-way push-back)

### 1.1 ADD Event

| # | Provider | Flow | Details |
|---|----------|------|---------|
| A1 | Google | `options.add_event()` → `gc.add_event(**kwargs)` | Server builds Google API body via `_setup_add_or_update_body()`: timed uses `dateTime`+`timeZone`, all-day uses `date` (exclusive end = end+1day). RRULE passed with `RRULE:` prefix (Google requires it). Returns Google event ID → stored as `Event.synced_id`. |
| A2 | Outlook | `options.add_event()` → `outlook.add_event(calendar_id, ...)` | Server builds Graph body via `_build_event_body()`: timed uses `dateTime`+`timeZone`, all-day uses `dateTime=YYYY-MM-DDT00:00:00` (exclusive end = end+1day). RRULE converted to Graph recurrence via `_convert_rrule_to_graph()`. Returns Outlook event ID → `Event.synced_id`. |
| A3 | None | `options.add_event()` → DB only | No external API call. `Event.objects.create()` directly. |

**Common to all**: `create_rrule(**kwargs)` generates RRULE from `repeat_every/repeat_type/repeat_byday/repeat_until` if `repeat_every` in kwargs. Pad sends `recurrence` directly (RRULE string), so `create_rrule` is only called for legacy App requests.

**Error handling**: Google errors propagate (caller sees error). Outlook errors caught silently (`logger.error`), event still created in DB with `synced_id` from Google (if any) or empty.

---

### 1.2 UPDATE Event — change_type=ALL

| # | Provider | Flow | Details |
|---|----------|------|---------|
| U1 | Google | `gc.update_event(event_id=synced_id, **kwargs)` | Passes all kwargs to `_setup_add_or_update_body()`. Google replaces entire event. |
| U2 | Outlook | `outlook.update_event(event_id=synced_id, title, start_at, end_at, ...)` | Builds PATCH body via `_build_event_body()`. Only sends provided fields (PATCH semantics). RRULE → Graph conversion via `_convert_rrule_to_graph(recurrence, start_date, is_all_day)`. |
| U3 | None | DB only | `Event.objects.filter(...).update(**kwargs)` |

**Date alignment** (lines 297-312 in `options.py`):
When editing from a non-first occurrence with ALL, the Pad sends the occurrence's dates. Server realigns to master:
```
kwargs['start'] = (request_start - origin_start) + master_start
```
Where `origin_start` comes from `repeat_flag` (the occurrence being edited).

**Critical**: After alignment, `kwargs['start_date']` may be a `datetime` object (not string). Outlook's `_build_event_body` must normalize with `str(start_date)[:10]` for all-day events.

**Error handling**: Google errors propagate. Outlook errors caught silently. DB update always proceeds (line 334).

---

### 1.3 UPDATE Event — change_type=THIS

| # | Provider | Flow | Details |
|---|----------|------|---------|
| U4 | Google | `gc.add_event(recurringEventId=master_synced_id, originalStartTime={date/dateTime}, **kwargs)` | Google's native exception model: creates a modified instance linked to the series master. `originalStartTime` format: `{"date": "YYYY-MM-DD"}` for all-day, `{"dateTime": "ISO8601"}` for timed. Returns new synced_id for the exception. |
| U5 | Outlook | `outlook.delete_repeat_this_event(master_synced_id, origin_start)` then `outlook.add_event(calendar_id, ...)` | **Strategy differs from Google**: Outlook doesn't support in-place exceptions via API. Must delete the instance first, then create a standalone event. Two separate API calls. New synced_id from the standalone event. |
| U6 | None | DB only | Create new standalone Event + add exdate to parent. |

**DB operations** (inside `transaction.atomic()`):
1. Format exclude date: `format_time(origin_start, is_all_day)` → e.g., `"2026-04-15"` or `"2026-04-15T02:31:00+0000"`
2. Create new Event: `repeat_every=0, recurrence=None, synced_id=<new>, repeat_event_id=parent_id`
3. Append exclude to parent's `repeat_exclude` list

**Error handling**: Google/Outlook errors caught; DB transaction still commits (exdate added, exception created).

---

### 1.4 UPDATE Event — change_type=AND_FUTURE

| # | Provider | Flow | Details |
|---|----------|------|---------|
| U7 | Google | `gc.add_event(**kwargs)` (new series) then `gc.update_recurrence(master_synced_id, truncated_rrule)` | Create new series first, then truncate old. Order: create → truncate. |
| U8 | Outlook | `outlook.update_recurrence(master_synced_id, truncated_rrule, start_date, is_all_day)` then `outlook.add_event(calendar_id, ...)` | **Order reversed from Google**: truncate old first, then create new. `update_recurrence` converts RRULE to Graph format via `_convert_rrule_to_graph()`. |
| U9 | None | DB only | Truncate parent RRULE + create new series Event. |

**RRULE truncation**: `replace_rrule_until(rrule, new_until)` where `new_until = origin_start - 1 day`. This sets UNTIL on the parent to the day before the split point.

**DB operations** (inside `transaction.atomic()`):
1. Compute `new_until = origin_start.shift(days=-1)`
2. Truncate parent: `update_event_recurrence_with_consistency(queryset, new_rrule, new_until)`
3. Create new series Event with new kwargs (new rrule, new start dates)

**Error handling**: Google/Outlook errors caught (try/except per provider). DB transaction always commits. If external API fails, DB is correct but external calendar is out of sync.

---

### 1.5 DELETE Event — change_type=ALL

| # | Provider | Flow | Details |
|---|----------|------|---------|
| D1 | Google | `gc.delete_event(synced_id)` | HTTP DELETE to Google API. |
| D2 | Outlook | `outlook.delete_event(synced_id)` | HTTP DELETE to Graph API. Auto-retries on 401. |
| D3 | None | DB only | `Event.objects.filter(...).delete()` |

**Error handling**: Both Google and Outlook errors caught silently. DB delete always proceeds.

---

### 1.6 DELETE Event — change_type=THIS

| # | Provider | Flow | Details |
|---|----------|------|---------|
| D4 | Google | `gc.delete_repeat_this_event(synced_id, origin_start, is_all_day)` | Finds the specific instance and cancels it. Uses Google's native instance cancellation. |
| D5 | Outlook | `outlook.delete_repeat_this_event(synced_id, origin_start)` | Finds instance via calendarView date range query, then DELETEs it. Falls back to ±1 day search if exact match fails. |
| D6 | None | DB only | Add exdate to parent's `repeat_exclude`. |

**DB operations** (inside `transaction.atomic()`):
1. Format exclude date from `repeat_flag`
2. Append to parent's `repeat_exclude` list
3. `Event.objects.filter(...).update(repeat_exclude=updated_list)`

---

### 1.7 DELETE Event — change_type=AND_FUTURE

| # | Provider | Flow | Details |
|---|----------|------|---------|
| D7 | Google | `gc.update_recurrence(synced_id, truncated_rrule)` | Sets UNTIL to day before the delete point. Series continues up to that date. |
| D8 | Outlook | `outlook.update_recurrence(synced_id, truncated_rrule, start_date, is_all_day)` | Same concept, different API format. RRULE → Graph conversion via `_convert_rrule_to_graph()`. |
| D9 | None | DB only | Truncate parent RRULE. |

**DB operations** (inside `transaction.atomic()`):
1. `new_until = origin_start.shift(days=-1)`
2. `update_event_recurrence_with_consistency(queryset, new_rrule, new_until)`

---

## 2. Calendar-Level Sync Operations

### 2.1 Sync Triggers

| Trigger | Source | What Happens |
|---------|--------|--------------|
| **Periodic timer** | Pad CalendarSyncWorker | Every N minutes (configurable per calendar type), fetch from external source |
| **Beat flag `event=true`** | Server → Redis → Go heartbeat → Pad | Pad calls `syncEventsFromServer()` to fetch updated events from Django |
| **Beat flag `synced_cal=true`** | Server → Redis → Go heartbeat → Pad | Pad refreshes synced calendar list (metadata changes) |
| **After own CUD** | Pad CalendarRepository | For THIS/AND_FUTURE: `syncEventsFromServer()` (server creates new entities). For ALL: optimistic local update only. |
| **App opens / resumes** | Pad EventManager.initialize() | Triggers initial sync if not recently synced |
| **User adds synced calendar** | Pad Settings | Immediate first sync for the new calendar |

### 2.2 Sync Flow by Source Type

#### ICS (URL, iCloud, US Holidays)

```
Pad CalendarSyncWorker.syncIcsDirect()
  │
  ├─ HTTP GET {ics_url}
  ├─ SHA256(content) → compare with stored syncSha256
  │   └─ If same → skip (no changes)
  ├─ IcsParser.parse(content, calendarId)
  │   ├─ RFC 5545 line unfolding (\r\n + continuation)
  │   ├─ Extract VEVENT components
  │   ├─ Parse RRULE, EXDATE, RECURRENCE-ID
  │   └─ Handle cancelled instances (STATUS:CANCELLED)
  ├─ Room: replaceEventsForCalendar(calendarId, events)
  ├─ Server: POST /calendar/event/upload_synced
  │   ├─ Upsert by synced_id (stable UID from ICS)
  │   ├─ Merge repeat_exclude (union of server + uploaded)
  │   ├─ Delete stale events not in upload
  │   └─ Beat: should_refresh_event(True)
  └─ Room: updateSyncedCalendarStatus(sha256, lastSyncAt)
```

**Change detection**: SHA256 of full ICS content. Must match between Pad and Go ICS Syncer.

#### Google Calendar

```
Pad CalendarSyncWorker.syncGoogleDirect()
  │
  ├─ Token: getAccessToken(calendarId) → Token Relay via server
  │   └─ Server: GET /synced_calendar/{id}/token → refresh if expired
  ├─ GoogleCalendarClient.fetchEvents(accessToken, calendarId)
  │   ├─ API: events.list(singleEvents=false, maxResults=2500)
  │   ├─ Classify: masters / modified instances / cancelled instances
  │   ├─ RecurrenceExceptionHelper: merge exceptions into masters
  │   └─ Cancelled → add to master's exdates
  ├─ hashEvents(events) → compare with stored syncSha256
  │   └─ If same → skip
  ├─ Room: replaceEventsForCalendar(calendarId, events)
  ├─ Server: POST /calendar/event/upload_synced
  └─ Room: updateSyncedCalendarStatus(hash, lastSyncAt)
```

**Change detection**: Custom hash of concatenated event content (not Google's etag).

#### Outlook (Microsoft Graph)

```
Pad CalendarSyncWorker.syncOutlookDirect()
  │
  ├─ Token: getAccessToken(calendarId) → Token Relay via server
  ├─ OutlookCalendarClient.fetchEvents(accessToken, calendarId)
  │   ├─ API: GET /me/calendars/{id}/events (paginated, $top=999)
  │   ├─ Classify: seriesMaster / exception / occurrence / singleInstance
  │   ├─ RecurrenceExceptionHelper: merge exceptions into masters
  │   ├─ detectCancelledOccurrences():
  │   │   ├─ Outlook /events endpoint does NOT return cancelled instances
  │   │   ├─ Workaround: GET /calendarView (expanded occurrences in date range)
  │   │   ├─ Compare rrule expansion vs calendarView → compute missing = exdates
  │   │   └─ Single API call covers all recurring masters
  │   └─ Convert Outlook recurrence → RRULE via _convert_outlook_recurrence()
  ├─ hashEvents(events) → compare with stored syncSha256
  ├─ Room: replaceEventsForCalendar(calendarId, events)
  ├─ Server: POST /calendar/event/upload_synced
  └─ Room: updateSyncedCalendarStatus(hash, lastSyncAt)
```

**Change detection**: Custom hash of concatenated event content.

### 2.3 Server-Side Fallback Sync

| Component | Trigger | Purpose |
|-----------|---------|---------|
| Go ICS Syncer (Linux) | Scheduled polling | Fetches ICS URLs when Pad is offline |
| Cloudflare Workers | Google Calendar push notifications | Handles Google Calendar sync without Pad involvement |
| `options.sync_calendar()` | Called by Go Syncer / Cloudflare | Server-side upsert with same logic as `upload_synced` |

### 2.4 Conflict Resolution

- **No merge**: Last-write-wins. No CRDT or OT.
- **Own events**: Pad → Server → Provider. If Provider rejects, Server DB still updated (out of sync until next full sync).
- **Synced events**: Provider is source of truth. Each sync cycle overwrites Server + Pad with Provider's data.
- **Exdate merging**: `repeat_exclude` uses set union during `upload_synced` to prevent losing deletions from either source.
- **etag/synced_etag**: Stored but not used for conflict detection. Informational only.

---

## 3. Data Format Differences by Provider

### 3.1 Date/Time Formats

| Aspect | Google Calendar API | Outlook Graph API | Server DB | Pad Room |
|--------|--------------------|--------------------|-----------|----------|
| Timed event | `{"dateTime": "2026-03-15T10:30:00", "timeZone": "Asia/Shanghai"}` | `{"dateTime": "2026-03-15T10:30:00.0000000", "timeZone": "China Standard Time"}` | `start_at: datetime(UTC)` | `startAt: Long (epoch millis)` |
| All-day event | `{"date": "2026-03-15"}` | `{"dateTime": "2026-03-15T00:00:00", "timeZone": "UTC"}` + `isAllDay: true` | `start_date: date` | `startDate: String "yyyy-MM-dd"` |
| All-day end (exclusive) | `{"date": "2026-03-16"}` (next day) | `{"dateTime": "2026-03-16T00:00:00"}` (next day) | `end_date: 2026-03-15` (inclusive) | `endDate: "2026-03-15"` (inclusive) |
| Timezone | IANA format (`Asia/Shanghai`) | Windows format (`China Standard Time`) or IANA | UTC in DB | UTC epoch millis |

### 3.2 Recurrence Formats

| Aspect | Google Calendar API | Outlook Graph API | Server DB |
|--------|--------------------|--------------------|-----------|
| Format | RRULE string with `RRULE:` prefix | JSON recurrence object | RRULE string (with `RRULE:` prefix) |
| Example | `["RRULE:FREQ=MONTHLY;BYMONTHDAY=15;UNTIL=20260906"]` | `{"pattern": {"type": "absoluteMonthly", "dayOfMonth": 15}, "range": {"type": "endDate", "endDate": "2026-09-06"}}` | `RRULE:FREQ=MONTHLY;BYMONTHDAY=15;UNTIL=20260906` |
| Conversion | Direct (strip/add prefix) | `_convert_rrule_to_graph()` / `_convert_outlook_recurrence()` | Stored as-is |
| BYDAY position | `BYDAY=2FR` (2nd Friday) | `{"daysOfWeek": ["friday"], "index": "second"}` | `BYDAY=2FR` |
| Week start | `WKST=SU` | `"firstDayOfWeek": "sunday"` | `WKST=SU` (if present) |

### 3.3 Exception/Exclusion Handling

| Aspect | Google Calendar API | Outlook Graph API | ICS |
|--------|--------------------|--------------------|-----|
| Modified instance | `recurringEventId` links to master | `seriesMasterId` + `type: "exception"` | `RECURRENCE-ID` property |
| Cancelled instance | `status: "cancelled"` + `recurringEventId` | NOT returned by /events endpoint | `STATUS:CANCELLED` + `RECURRENCE-ID` |
| Cancelled detection | Part of events.list response | **Workaround**: calendarView endpoint + compare vs rrule expansion | Part of ICS VEVENT |
| Exdate format in DB | RFC 5545 datetime or date | Same (converted during import) | Native EXDATE property |

### 3.4 THIS-Edit Strategy Difference

| Provider | Strategy | Why |
|----------|----------|-----|
| Google | `events.insert(recurringEventId=master, originalStartTime=occurrence)` | Google natively supports modified instances as linked children |
| Outlook | `DELETE instance` + `POST new standalone event` | Graph API doesn't support creating linked exception instances. Must delete + recreate as standalone. |

### 3.5 AND_FUTURE Operation Order

| Provider | Step 1 | Step 2 | Why |
|----------|--------|--------|-----|
| Google | Create new series | Truncate old series UNTIL | Create first so new events exist if truncation fails |
| Outlook | Truncate old series UNTIL | Create new series | Outlook may reject truncation if new series overlaps |

---

## 4. Error Handling Contract

| Path | Google | Outlook | DB State |
|------|--------|---------|----------|
| Add | Propagates (`SyntaxError`) | Silent catch (`logger.error`) | DB created regardless |
| Update ALL | Propagates | Silent catch | DB updated regardless |
| Update THIS | Caught in atomic block | Caught in atomic block | DB updated (exdate + new event) |
| Update AND_FUTURE | Caught per provider | Caught per provider | DB updated (truncate + new event) |
| Delete ALL | Silent catch | Silent catch | DB deleted regardless |
| Delete THIS | Silent catch | Silent catch | DB updated (exdate added) |
| Delete AND_FUTURE | Caught per provider | Caught per provider | DB updated (rrule truncated) |

**Principle**: DB is always updated. External API failures are logged but never block the DB operation. This means external calendars can become out-of-sync, corrected on next full sync cycle.

---

## 5. Test Coverage Requirements

Every path (A1-A3, U1-U9, D1-D9) requires tests for:

1. **Happy path** — mock provider API success, verify DB state + API call params
2. **All-day variant** — same path but with all-day event (date format, exclusive end)
3. **Timed variant** — same path but with timed event (datetime format, timezone)
4. **Provider failure** — mock API error, verify DB state still correct
5. **Two-way skip** — verify no API call for ONE_WAY synced calendars

Calendar-level sync requires tests for:
1. **Change detection** — SHA256/hash match → skip
2. **Upsert logic** — new events created, existing updated, stale deleted
3. **Exdate merge** — union of server + uploaded excludes
4. **Token relay** — fresh token, expired token, credential failure
5. **Beat flag** — set after mutation, read on heartbeat

---

## 6. File Reference

| Purpose | Backend File | Key Functions |
|---------|-------------|---------------|
| Event CUD orchestration | `options.py` | `sync_calendar()`, `flush_*_token` (CUD re-exported from providers/) |
| Provider package init | `providers/__init__.py` | Re-exports CUD from providers |
| Provider base class | `providers/base.py` | Base provider interface |
| Google Calendar provider | `providers/google.py` | `GoogleCalendar` class |
| Outlook Calendar provider | `providers/outlook.py` | `OutlookCalendar` class |
| Provider CUD operations | `providers/operations.py` | `add_event()`, `update_event()`, `delete_event()` |
| Google Calendar client | `google_sync.py` | `GoogleCalendar` class (sync.py renamed) |
| Outlook Calendar client | `outlook_sync.py` | `OutlookCalendar` class |
| RRULE ↔ Graph conversion | `outlook_sync.py` | `_convert_rrule_to_graph()`, `_convert_outlook_recurrence()` |
| Token management | `services.py` | `get_access_token()`, `refresh_*_token()` |
| Upload synced events | `viewset_pad.py` | `upload_synced()` |
| Pad sync endpoint | `viewset_pad.py` | `sync()`, `token()` |

| Purpose | Pad File | Key Classes/Functions |
|---------|----------|----------------------|
| Sync orchestration | `CalendarSyncWorker.kt` | `syncIcsDirect()`, `syncGoogleDirect()`, `syncOutlookDirect()` |
| Repository CRUD | `CalendarRepository.kt` | `addEvent()`, `updateEvent()`, `deleteEvent()`, `uploadSyncedEvents()` |
| Google fetch | `GoogleCalendarClient.kt` | `fetchEvents()` (read-only) |
| Outlook fetch | `OutlookCalendarClient.kt` | `fetchEvents()`, `detectCancelledOccurrences()` (read-only) |
| ICS parse | `IcsParser.kt` | `parse()` (read-only) |
| Exception processing | `RecurrenceExceptionHelper.kt` | Shared by all three source types |
