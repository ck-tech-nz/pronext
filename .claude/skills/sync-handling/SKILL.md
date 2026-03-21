---
name: sync-handling
description: >
  Calendar sync patterns for handling external calendar data sources (ICS, Google Calendar, Outlook).
  Covers initialization, lazy loading, incremental sync, version conflicts, data parsing, exclusive
  end dates, line unfolding, recurring event filtering, and synced calendar lifecycle.
  Use when modifying any calendar sync logic to avoid reintroducing known bugs.
---

# Calendar Sync Handling Patterns (Pronext Standard)

> **RFC 5545 definitions**: See [rfc5545-reference](../rfc5545-reference/skill.md) for supported
> RRULE properties, EXDATE formats, date conventions, and deliberate deviations from the standard.

This skill documents **proven patterns and known pitfalls** for syncing external calendar data
into Pronext's Room database. Three data sources share a common pipeline with source-specific parsing.

## Architecture Overview

```
External Source           Pad Parser                  Room DB              Server
┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐    ┌──────────────┐
│ ICS URL      │───>│ IcsParser.kt     │───>│ CalendarEventEntity │──>│ upload_synced│
│ Google API   │───>│ GoogleCalClient  │───>│ (Room DB)         │──>│ → beat.event │
│ Outlook API  │───>│ OutlookCalClient │───>│                   │   │              │
└──────────────┘    └──────────────────┘    └──────────────────┘    └──────────────┘
                           │                        │
                    Source-specific          Shared entity format
                    parsing logic           (CalendarEventEntity)
```

**Key principle**: Each source has its own parser/client that converts to a shared
`CalendarEventEntity`. Common issues (exclusive end dates, rrule format) are handled
identically in all parsers.

### Two-Tier Architecture: Pad as Primary Syncer + Server as Fallback

Pad acts as a **distributed sync worker**, reducing server load. Server-side syncers are fallback
for when no Pad device is online.

```
                    Pad online (primary path)                  Server-side (fallback, when Pad offline)
                    ────────────────────────                   ─────────────────────────────────────────
ICS (iCloud/URL)    IcsParser.kt → Room DB → upload_synced     ics_syncer: SHA256 → Django parse
Google Calendar     GoogleCalClient → Room DB → upload_synced   Cloudflare Workers → Django
Outlook             OutlookCalClient → Room DB → upload_synced  outlook_syncer: Delta Query → Django
```

- **Pad parsers** are the primary sync path: fetch from external source → process (including
  recurring event exceptions) → store in Room → upload processed data to server
- **Server Go syncers / Cloudflare Workers** are fallback for when Pad is offline
- Server stores what Pad uploads as-is; it's a relay for the Mobile app and other Pad devices
- When Pad comes back online, its own direct sync re-fetches full data and corrects any gaps

### Pad-Primary Coordination via Device Online Status (`skip_online`)

Pad and server-side Go syncers coordinate through **device online status** in Redis.
When a Pad is online, Go syncers automatically skip that device's calendars.

```
Pad (every ~1 min)          Heartbeat (every 5s)           Go syncer (every ~30s)
─────────────────           ──────────────────             ─────────────────────
sync from external          → Redis SET device:online:{sn}
                              TTL = 2 min                  GET /get_sync_calendars/?skip_online=true
                                                           ← device online → SKIP ✓
                                                           (Pad handles sync)

Pad offline > 2 min         → Redis key expires            GET /get_sync_calendars/?skip_online=true
                                                           ← device offline → SYNC ✓
                                                           (Go takes over as fallback)
```

**How it works:**

1. **Pad heartbeat** (every 5s) → sets `device:online:{sn}` in Redis with **2 minute TTL**
2. **Go syncers** call `GET /get_sync_calendars/?calendar_type=...&skip_online=true`
3. **Django** reads `device:online_devices` Redis SET → maps SNs to device_ids via PadDevice
   → excludes calendars where `user_id` (= device_id) has an online Pad
4. **Result**: While Pad is online, its calendars are never returned to Go syncers
5. **Pad goes offline** → Redis key expires after 2 min → Go syncers pick up the work

**Online status TTL = 2 minutes** (not 1 hour). With heartbeat every 5s, this means
24 heartbeat opportunities before expiry. Brief network blips won't cause false "offline".

**`synced_at` also updated** — both paths set it as a secondary record:
- Pad: `upload_synced` action in `viewset_pad.py` → `calendar.synced_at = tz.now()`
- Go: `sync_outlook_calendar` in `views.py` → `synced.synced_at = timezone.now()`

### Unified Syncer Endpoint (`get_sync_calendars`)

Both Go syncers (ICS and Outlook) call the **same Django endpoint** with different params:

| Syncer | URL |
|--------|-----|
| **ICS** | `GET /get_sync_calendars/?calendar_type=3,6,7&skip_online=true&size=10` |
| **Outlook** | `GET /get_sync_calendars/?calendar_type=2&skip_online=true` |

The endpoint handles all calendar types from one place:
- Common: queryset filtering, `skip_online`, ordering by `synced_at ASC NULLS FIRST`, rel_user_ids
- ICS types: returns `link`, `sha256` fields; skips calendars without `link`
- OAuth types (Google/Outlook): returns `access_token`, `calendar_id`, `delta_link`; auto-refreshes
  Outlook tokens if about to expire; skips calendars without valid credentials
- After returning: bulk-updates `synced_at = now()` for all returned calendars

**Deprecated endpoints** (kept for backward compatibility):
- `/check_need_sync/` → replaced by `/get_sync_calendars/`
- `/get_outlook_calendars/` → replaced by `/get_sync_calendars/?calendar_type=2`
- `/get_sync_link_calendars/` → replaced by `/get_sync_calendars/`

### Recurring Event Exception Handling (Master + Exceptions Model)

External calendar services (Google, Outlook, CalDAV/ICS) all use the **RFC 5545 instance model**:
a master event with RRULE, plus separate modified/cancelled instance objects linked to the master.

Pronext uses a **single-table Model A** approach in Room DB:

```
CalendarEventEntity
├── id: Long
├── parentEventId: Long?     ← null = master/standalone, non-null = exception linked to master
├── recurrence: String?      ← master has rrule, exception has null
├── exdates: String?         ← master accumulates excluded dates
├── syncedId: String?        ← external source ID (for deduplication)
├── ... other fields
```

**Why single table**: Server Django already uses this pattern (`Event.repeat_event_id`). Exceptions
are just events with a parent link — same display logic, same DAO queries, no joins needed.

**How parsers convert external data to this model:**

| External Source | Modified Instance | Cancelled Instance |
|-----------------|-------------------|--------------------|
| **Google API** | `recurringEventId != null`, `status != "cancelled"` | `recurringEventId != null`, `status == "cancelled"` |
| **Outlook API** | `type == "exception"`, `seriesMasterId` present | `type == "exception"` with cancelled flag |
| **ICS** | VEVENT with `RECURRENCE-ID` property | VEVENT with `RECURRENCE-ID` + `STATUS:CANCELLED`, or EXDATE on master |

**Parser conversion logic** (shared helper, used by all three parsers):

```
Input:  list of raw events from external source
Output: list of CalendarEventEntity (masters with exdates + standalone exceptions with parentEventId)

1. Separate events into:
   - masters: have recurrence/rrule, no recurringEventId/RECURRENCE-ID
   - modified instances: have recurringEventId/RECURRENCE-ID, not cancelled
   - cancelled instances: have recurringEventId/RECURRENCE-ID, cancelled status

2. For each modified instance:
   a. Find its master (by recurringEventId / RECURRENCE-ID UID match)
   b. Extract the original occurrence date from the instance
   c. Add that date to master's exdates (so rrule expansion skips it)
   d. Convert instance to standalone CalendarEventEntity:
      - parentEventId = master's ID
      - recurrence = null (not recurring)
      - All other fields (title, time, etc.) from the modified instance

3. For each cancelled instance:
   a. Find its master
   b. Add the original occurrence date to master's exdates
   c. Do NOT create a standalone event (it's deleted)

4. Return: masters (with accumulated exdates) + standalone exceptions (with parentEventId)
```

**After conversion**, the data in Room is identical in structure to what Pad's own "Edit This" /
"Delete This" operations produce. The existing `expandAndUpdateEvents()` logic works unchanged:
- RRuleParser expands master rrule, filters exdates → occurrences
- Standalone exceptions (parentEventId != null) are regular events, displayed normally
- No special rendering logic needed

**Upload to server**: `uploadEventsToServer()` sends the processed data (masters + exceptions).
Server stores as-is via `upload_synced` endpoint. No server-side parsing of exceptions needed.

### parentEventId Lifecycle

| Operation | parentEventId usage |
|-----------|-------------------|
| **Sync from external** | Parser sets parentEventId when converting modified instances |
| **Sync own events from server** | Map server's `repeat_event_id` → `parentEventId` |
| **"Edit This" on Pad** | Server creates exception with `repeat_event_id`; next sync sets parentEventId |
| **"Delete All"** | Also delete events where `parentEventId == deletedId` (cascade) |
| **Display** | Not used — all events rendered the same regardless of parentEventId |
| **Full re-sync** | `replaceEventsForCalendar()` replaces all; parentEventId rebuilt from source |

---

## 0. Initialization, Lazy Loading & Sync Lifecycle

### Initialization Triggers

All these scenarios follow the same path: `MainActivity.onCreate → EventManager.initialize(context)`:

| Scenario | What Happens |
|----------|-------------|
| **App start** | `initialize()` → if authenticated: `performInitialSync()` + start CalendarSyncWorker |
| **App reinstall** | Room DB gone → fresh `initialize()` → full sync from server + external sources |
| **Device restart** | Same as app start (no WorkManager persistence; worker lives in-process) |
| **Logout / Reset** | `deInitialize()` → stop worker → destroy Room DB → clear in-memory list |
| **Re-login** | `AuthDidLogin` signal → `initialize()` from scratch |

**`performInitialSync()` sequence** (CalendarRepository):
1. `syncCategoriesFromServer()` — GET `/calendar/category/list`
2. `syncSyncedCalendarsFromServer()` — GET `/calendar/synced_calendar/sync` (triggers worker reschedule)
3. `syncEventsFromServer()` — GET `/calendar/event/sync` (own events, not synced calendar events)

**CalendarSyncWorker startup:**
- Created in `initialize()`, monitors `getSyncedCalendars()` Flow from Room
- When active calendar set changes → `rescheduleAll()` → first sync runs immediately
- Then enters periodic loop per calendar, interval from server-controlled DeviceConfig

### Lazy Loading (Date-Range Queries)

Events are NOT all loaded into memory. `EventManager.observeEvents()` queries Room by **date range**:

- Month view: visible range ± 8 days padding
- Week view: visible range ± 1 day
- Day/Schedule: exact range

Raw entities from Room → `expandAndUpdateEvents()` → local RRuleParser expansion within range → UI list.
Scrolling to a new range triggers a new Room query automatically (Flow-based).

### Reset & Recovery

**Logout** (`deInitialize`):
```
syncWorker.stop() → cancel DB observer → CalendarDatabase.destroyInstance() → clear list
```

**Database corruption / device mismatch** (403 DEVICE_MISMATCH from server):
```
destroyDatabase(fireSignal=true) → CalendarDatabaseDestroyed signal
  → EventManager re-initializes with full sync from scratch
```

---

## 0.1 Version Conflicts & CRUD Upload

### How Pad CRUD reaches the server

Pad uses **optimistic local updates** for simple operations, conservative re-sync for complex ones:

| Operation | Local Update | Server Call | On Failure |
|-----------|-------------|------------|------------|
| **Add** | Insert with local negative ID | `api.addEvent()` → replace local ID with server ID | Mark `PENDING_CREATE` |
| **Edit "All"** | Update Room optimistically | `api.updateEvent(changeType=1)` | Mark `PENDING_UPDATE` |
| **Edit "This"/"Future"** | NO local update (unpredictable result) | `api.updateEvent(changeType)` | `syncEventsFromServer()` to restore |
| **Delete "All"** | Delete from Room immediately | `api.deleteEvent(changeType=1)` | Restore with `PENDING_DELETE` |
| **Delete "This"** | Append to `exdates` locally | `api.deleteEvent(changeType=0)` | Revert exdate |
| **Delete "Future"** | NO local update | `api.deleteEvent(changeType=2)` | `syncEventsFromServer()` |

### Conflict Resolution

- **Last write wins** — no client-side conflict detection
- Synced calendar events are **read-only** on Pad (no conflict possible)
- Complex edits (this/future) always re-sync from server to ensure consistency

### Beat-Driven Server → Pad Sync

When server data changes (from Mobile app, another Pad, or external sync):
1. Server sets `beat.event = true` in Redis
2. Pad receives flag in next heartbeat (every 5s)
3. Pad calls `syncEventsFromServer()` → merges server state into Room

### Exdate Format: Server vs Pad (CRITICAL)

**RFC 5545 standard**: EXDATE value type must match DTSTART — DATE for all-day, DATE-TIME for timed.

**Server** (`format_time()` in `calendar/utils.py`) follows RFC 5545 correctly:
- All-day events: `repeat_exclude` stores date strings → `"2026-03-14"`
- Timed events: `repeat_exclude` stores datetime strings → `"2026-03-14T10:00:00+00:00"`

**Pad** expands all rrules into **date-only** occurrence strings (`"2026-03-14"`) because the
architecture separates "which day" (date string) from "what time" (startAt epoch millis).

**This creates a format mismatch for timed events after heartbeat sync:**
```
1. Pad deletes "This" → local exdate = "2026-03-14" (date-only, via .take(10)) → occurrence hidden ✓
2. Server stores repeat_exclude = ["2026-03-14T10:00:00+00:00"] (datetime, per RFC 5545)
3. Heartbeat → syncEventsFromServer → entity.exdates = "2026-03-14T10:00:00+00:00"
4. RRuleParser compares "2026-03-14" ∉ {"2026-03-14T10:00:00+00:00"} → occurrence reappears ✗
```

**Rule**: Pad MUST normalize exdates to date-only (`.take(10)`) at the point of rrule expansion.
This is not a hack — each recurring event has at most one occurrence per day, so date matching
is always sufficient. Normalization is done in `expandAndUpdateEvents()`:

```kotlin
// In EventManager.expandAndUpdateEvents():
val exdatesList = entity.exdates?.split(",")
    ?.filter { it.isNotBlank() }
    ?.map { it.take(10) }  // Normalize datetime → date-only for RRuleParser comparison
```

**This normalization applies to Calendar events only.** Task and Meal modules store exdates as
date-only strings natively (server sends date format for these modules). If this changes in the
future, apply the same `.take(10)` normalization pattern.

### Own Event Two-Way Sync (Pad → Server → Google/Outlook)

Own events created/modified on Pad reach Google/Outlook through the server:

```
Pad CRUD → Server API (options.py) → Server DB
                                   → _get_gc() / _get_outlook() → Google/Outlook API
                                   → Beat notification → other Pad devices
```

**Recurring event operations on server side** (`calendar/options.py`):

| Operation | Server-side Google/Outlook action |
|-----------|----------------------------------|
| **Edit "This"** | Create standalone exception + add to `repeat_exclude` + sync exception to Google/Outlook |
| **Edit "All"** | Update parent event + sync update to Google/Outlook |
| **Edit "This and Future"** | Truncate parent rrule + create new event + sync both to Google/Outlook |
| **Delete "This"** | Add to `repeat_exclude` + `gc.delete_repeat_this_event()` / `outlook.delete_repeat_this_event()` |
| **Delete "All"** | Delete event + `gc.delete_event()` / `outlook.delete_event()` |
| **Delete "This and Future"** | Truncate parent rrule (set UNTIL to day before) + sync to Google/Outlook |

**Important**: The server handles all Google/Outlook API calls within `transaction.atomic()` for
THIS and AND_FUTURE operations. Pad does NOT call Google/Outlook directly for own events.

---

## 0.2 Incremental Sync & Change Detection

Each source has its own strategy to avoid unnecessary work on every sync cycle:

### ICS: SHA256 Content Hash

**Pad** (`CalendarSyncWorker.kt`):
```kotlin
val newSha256 = IcsParser.sha256(icsContent)
if (newSha256 == cal.syncSha256) {
    // Content unchanged — skip parsing and Room write
    return
}
// Changed: parse → replace events in Room → upload to server → update syncSha256
```

**Server Go** (`ics_syncer/syncer.go`):
```go
statusCode, sha256sum, icsContent, err := DownloadICS(cal.Link, isOutlookType)
if sha256sum == cal.SHA256 {
    stats.Skipped++  // Skip — no changes
    return
}
// Changed: POST content to Django for parsing
```

DTSTAMP normalization: Outlook ICS URLs change `DTSTAMP` on every fetch even when content
is unchanged. The Go syncer normalizes DTSTAMP to `19700101T000000Z` before hashing.

### Outlook: Delta Query (Server Go Syncer)

The server-side Go syncer uses Microsoft Graph Delta Query for true incremental sync:

```go
// First sync: deltaLink="" → fetches ALL events via /events endpoint (full data)
// Subsequent syncs: deltaLink="..." → fetches only changes since last sync
result, statusCode, err := FetchOutlookEvents(accessToken, calendarID, cal.DeltaLink)
```

**Delta response contains:**
- New/modified events (minimal fields only → `FetchFullEvent()` to enrich each one)
- Deleted events (`@removed` marker) → tracked in `removed[]` list
- New `deltaLink` for next sync → saved in Django DB

**Fallback:** On 401, refreshes access token via Django and retries.

**Pad-side Outlook** does NOT use delta (no deltaLink storage in Room). It fetches all
non-cancelled events every cycle, relying on server-controlled interval
(`DeviceConfig.calendarSyncIntervals.outlook`, typically ~1 min) to limit load.
The `replaceEventsForCalendar()` call does a full replace in Room.
When Pad is online, its heartbeat keeps `device:online:{sn}` alive in Redis (2 min TTL),
so the Go syncer's `skip_online` filter automatically excludes this device's calendars.
See "Pad-Primary Coordination" section above.

### Google Calendar: Full Fetch (No Sync Token Yet)

Both Pad and server currently fetch **all events** every cycle:
- Pad: `singleEvents=false` + filter `recurringEventId == null`
- Server: Cloudflare Workers handle Google OAuth + sync to Django

**Future improvement**: Google API supports `syncToken` (similar to Outlook deltaLink).
The `etag` field is already stored as `syncedEtag` in preparation.

### Summary of Change Detection

| Source | Pad Strategy | Server Go Strategy |
|--------|-------------|-------------------|
| **ICS** | SHA256 hash comparison | SHA256 hash comparison (+ DTSTAMP normalization) |
| **Google** | Full fetch every cycle | Cloudflare Workers (full fetch) |
| **Outlook** | Full fetch every cycle | Delta Query with deltaLink persistence |

### Sync Intervals (Server-Controlled)

Intervals are read from `SettingManager.shared.calendarSyncIntervals` (DeviceConfig from server):

| Calendar Type | Typical Interval |
|--------------|-----------------|
| Google (1) | `intervals.google` |
| Outlook (2) | `intervals.outlook` |
| iCloud (3) / URL (6) | `intervals.ics` |
| US Holidays (7) | `intervals.holidays` |

---

## 1. Exclusive End Date Conversion (CRITICAL)

**All three calendar standards use exclusive end dates for all-day events.**
Pad's UI treats `endDate` as **inclusive**. This mismatch caused duplicate display bugs.

### The Rule

> When an all-day event spans March 9 only, the source reports `end = March 10` (exclusive).
> We MUST subtract 1 day to store `endDate = March 9` (inclusive) in Room.

### Implementation in Each Parser

**ICS** (`IcsParser.kt`):
```kotlin
if (isAllDay) {
    startDate = formatDate(startTemporal)
    // RFC 5545: DTEND with VALUE=DATE is exclusive — subtract 1 day
    endDate = if (endTemporal is LocalDate) {
        endTemporal.minusDays(1).toString()
    } else {
        endTemporal?.let { formatDate(it) } ?: startDate
    }
}
```

**Google** (`GoogleCalendarClient.kt`):
```kotlin
if (isAllDay) {
    startDate = event.start?.date
    // Google uses exclusive end dates (Mar 9 event → end=Mar 10)
    endDate = event.end?.date?.let { exclusiveEnd ->
        java.time.LocalDate.parse(exclusiveEnd).minusDays(1).toString()
    }
}
```

**Outlook** (`OutlookCalendarClient.kt`):
```kotlin
if (isAllDay) {
    startDate = event.start?.dateTime?.substring(0, 10)
    // Outlook uses exclusive end dates — subtract 1 day
    endDate = event.end?.dateTime?.substring(0, 10)?.let { exclusiveEnd ->
        java.time.LocalDate.parse(exclusiveEnd).minusDays(1).toString()
    }
}
```

### Why This Matters

Without this conversion, `toEventOccurrence()` calculates `durationDays` as 1 for a single-day
event, making it span 2 days in the UI. The date filter then shows each occurrence on both its
start day AND end day — appearing as duplicates.

---

## 2. ICS Parsing Pitfalls

### Line Unfolding (RFC 5545 §3.1)

ICS files wrap long lines by inserting a line break followed by a space or tab.
Both `\r\n` and bare `\n` must be handled:

```kotlin
val normalized = icsContent.replace("\r\n", "\n")
val unfolded = normalized.replace("\n ", "").replace("\n\t", "")
```

**Bug example**: `SUMMARY;LANGUAGE=en:Daylight Saving Time` was split across lines.
Without unfolding bare `\n`, the continuation was treated as a separate line and the
title was lost.

### Property Parameters (RFC 5545 §3.2)

ICS property names can have parameters before the colon:
```
SUMMARY;LANGUAGE=en:Daylight Saving Time
UID;VALUE=TEXT:unique-id-123
RECURRENCE-ID;TZID=America/New_York:20260315T100000
```

**DO NOT** use exact key matching (`key == "SUMMARY"`).
**DO** use prefix matching (`key.startsWith("SUMMARY")`).

This applies to: `SUMMARY`, `UID`, `RECURRENCE-ID`, `DTSTART`, `DTEND`.

### RECURRENCE-ID — Exception Processing (NOT Filtering)

Events with `RECURRENCE-ID` are modified instances of a recurring event. They MUST be
processed (not skipped) using the shared exception helper:

- `RECURRENCE-ID` value = original occurrence date being replaced
- Modified instance (no `STATUS:CANCELLED`) → standalone exception + exdate on master
- Cancelled instance (`STATUS:CANCELLED`) → exdate on master only

**Previous bug**: Events with RECURRENCE-ID were skipped entirely, making third-party
modifications invisible on Pad.

---

## 3. Google Calendar API Specifics

> **Full API reference**: See [references/google-calendar-api.md](references/google-calendar-api.md)
> for complete response format, field descriptions, and code examples.

### singleEvents=false

| Codepath | Endpoint | Key Params |
|----------|----------|------------|
| **Pad (Kotlin)** | `GET /calendars/{id}/events` | `singleEvents=false`, `maxResults=2500` |
| **Django (sync.py)** | `GET /calendars/{id}/events` | `maxResults=800`, `orderBy=updated` |
| **Django (google_api.py)** | `GET /calendars/{id}/events` | `singleEvents=true`, `orderBy=startTime`, `timeMin/timeMax` |
| **Cloudflare Worker** | `GET /calendars/{id}/events` | `maxResults=2500`, `orderBy=updated`, `timeMin` (6mo ago) |

Pad uses `singleEvents=false` to get **master recurring events** (with `recurrence` field)
plus **modified/cancelled instances** (with `recurringEventId`). Pad does local rrule expansion
and needs both to correctly handle exceptions.

### recurringEventId — Exception Processing (NOT Filtering)

Google returns three types of events:

| Type | Characteristics | Handling |
|------|----------------|----------|
| **Master** | Has `recurrence`, no `recurringEventId` | Keep as-is |
| **Modified instance** | Has `recurringEventId`, `status != "cancelled"` | Convert to standalone exception + add exdate to master |
| **Cancelled instance** | Has `recurringEventId`, `status == "cancelled"` | Add exdate to master only |

**Previous bug**: All instances with `recurringEventId != null` were filtered out, making
third-party edits/deletions to individual occurrences invisible on Pad.

### EXDATE Parsing

Google provides EXDATE in recurrence list:
```json
{ "recurrence": ["RRULE:FREQ=DAILY", "EXDATE;VALUE=DATE:20260115,20260120"] }
```

Parse with `parseExdatesFromLine()` — handles `VALUE=DATE`, `TZID=...`, and UTC formats.
Dates in ICS format (`20260115`) must be converted to `yyyy-MM-dd` format (`2026-01-15`).

---

## 4. Outlook Calendar API Specifics

> **Full API reference**: See [references/outlook-graph-api.md](references/outlook-graph-api.md)
> for complete response format, timezone handling, delta query flow, and known issues.

### DateTime & Timezone (CRITICAL)

Outlook returns `start.dateTime` in the timezone specified by `start.timeZone`.
The `Prefer: outlook.timezone="UTC"` header converts returned times to UTC.

**Timezone varies by sync path** — this is the root cause of the BYDAY display bug:

| Path | Prefer Header | timeZone Value |
|------|--------------|---------------|
| **Pad** | `outlook.timezone="UTC"` | `"UTC"` |
| **Django** | None | MS timezone name (e.g., `"China Standard Time"`) |
| **Go syncer** | None | MS timezone name |

**Known bug (2026-03-15)**: Pad's `Prefer: outlook.timezone="UTC"` causes `timezone='UTC'`
to be stored. Server `get_repeats()` has a fallback: when `timezone='UTC'` + `synced_calendar_id`
set + `device_timezone` differs → use device_timezone for rrule expansion.

### Cancelled Occurrences (FIXED on Pad, server fallback TODO)

**Pad** (`OutlookCalendarClient.kt`): Fixed — cancelled exceptions (`isCancelled=true`,
`type=exception`) are now processed via `RecurrenceExceptionHelper` with `isCancelled=true`,
which adds their `originalDate` to the master's exdates without creating standalone events.
This matches the Google and ICS parser patterns.

**Server fallback** (`outlook_sync.py`): Still skips all `isCancelled` events. TODO: cancelled
exceptions should add their date to the master's `repeat_exclude`. Low priority since Pad is
the primary syncer.

**Note**: The Outlook `/events` endpoint may not return simply-deleted occurrences at all in
some cases; `cancelledOccurrences` property exists only in the **beta** Graph API.

See [references/outlook-graph-api.md § Known Issues](references/outlook-graph-api.md) for
additional details.

### Recurrence to RRULE

Outlook uses its own recurrence format (not RFC 5545). Convert with `recurrenceToRrule()`:

| Outlook Pattern Type | RRULE FREQ |
|---------------------|------------|
| `daily` | `DAILY` |
| `weekly` | `WEEKLY` |
| `absoluteMonthly` | `MONTHLY` + `BYMONTHDAY` |
| `relativeMonthly` | `MONTHLY` + `BYDAY` with position prefix |
| `absoluteYearly` | `YEARLY` + `BYMONTH` + `BYMONTHDAY` |
| `relativeYearly` | `YEARLY` + `BYMONTH` + `BYDAY` with position prefix |

Position mapping: `first=1`, `second=2`, `third=3`, `fourth=4`, `last=-1`
Day mapping: `sunday=SU`, `monday=MO`, etc.

---

## 5. Synced Calendar Lifecycle

### Adding a Synced Calendar

```
1. User adds via Mobile app → server creates SyncedCalendar record
2. Server fires beat.synced_cal for all device's Pad devices
3. Pad receives synced_cal=true in heartbeat response
4. Pad calls syncSyncedCalendarsFromServer() → gets updated calendar list
5. CalendarSyncWorker runs → fetches events from external source → stores in Room
6. Events uploaded to server → server fires beat.event
```

### Deleting a Synced Calendar

```
1. User deletes via Mobile app → server deletes SyncedCalendar record
2. Server fires beat.synced_cal
3. Pad receives synced_cal=true → calls syncSyncedCalendarsFromServer()
4. syncSyncedCalendarsFromServer() detects removed calendar:
   a. Deletes orphaned events: eventDao.deleteByCalendarId(removedId)
   b. Removes calendar from syncedCalendarDao
```

### syncSyncedCalendarsFromServer() — Critical Logic

```kotlin
suspend fun syncSyncedCalendarsFromServer() {
    val newEntities = api.syncSyncedCalendars().list?.map { it.toEntity() } ?: return
    val newIds = newEntities.map { it.id }.toSet()
    val oldCalendars = syncedCalendarDao.getAllOnce()

    // 1. Delete orphaned events for removed calendars
    for (old in oldCalendars) {
        if (old.id !in newIds) {
            eventDao.deleteByCalendarId(old.id)
        }
    }

    // 2. Preserve local-only fields when merging
    val oldMap = oldCalendars.associateBy { it.id }
    val merged = newEntities.map { entity ->
        oldMap[entity.id]?.let { old ->
            entity.copy(
                lastSyncAt = old.lastSyncAt,
                syncSha256 = old.syncSha256,
                syncError = old.syncError,
                accessToken = old.accessToken,
                tokenExpiresAt = old.tokenExpiresAt,
            )
        } ?: entity
    }
    syncedCalendarDao.replaceAll(merged)
}
```

**Key**: Must delete events BEFORE replacing calendar records, otherwise orphaned events
remain in Room with no parent calendar reference.

---

## 6. Beat System Integration

### synced_cal Beat Flag

The `synced_cal` flag notifies Pad that the synced calendar list changed (add/remove).

**Go heartbeat** (`beat.go`): The `SyncedCal` field MUST be included in:
1. `GetBeat()` — when copying the Beat struct to return
2. `SetBeat()` — in the field name switch statement

**Bug history**: Missing `SyncedCal` in Beat copy caused Pad to never receive the flag,
so synced calendar additions/deletions were not reflected in real-time.

### Event Data Flow After Sync

```
CalendarSyncWorker stores events in Room
  → CalendarRepository.uploadEventsToServer() sends events to server
    → Server stores and fires beat.event for all devices
      → Other Pad devices sync via regular event sync
```

---

## 7. Common Pitfalls & Rules

### DO NOT:
- Use exact key matching for ICS properties (`key == "SUMMARY"` fails for `SUMMARY;LANGUAGE=en`)
- Forget to handle bare `\n` in ICS line unfolding (not just `\r\n`)
- Store exclusive end dates directly — always convert to inclusive
- Filter out modified/cancelled instances from Google API (`recurringEventId != null`) — process them as exceptions
- Skip ICS events with RECURRENCE-ID — process them as exceptions
- Delete calendar records without first deleting their events (orphaned data)
- Omit new Beat fields when copying Beat structs in Go heartbeat
- Compare exdates against occurrence dates without normalizing to date-only first
- Delete a recurring master without cascading to its exceptions (`parentEventId == master.id`)
- Send recurrence strings to Google Calendar API without `RRULE:` prefix (causes "Invalid recurrence rule" 400 error)
- Let Google/Outlook API failures in AND_FUTURE update crash the transaction (wrap in try/except like delete does)

### MUST:
- Subtract 1 day from all-day event end dates in ALL three parsers
- Use `startsWith` for ICS property key matching
- Normalize line endings before ICS line unfolding
- Process Google modified instances (`recurringEventId != null`) via shared exception helper
- Process ICS modified instances (`RECURRENCE-ID`) via shared exception helper
- Set `parentEventId` on exception events linking back to their master
- Preserve local-only fields (lastSyncAt, tokens) when syncing calendars from server
- Include ALL Beat struct fields in `GetBeat()` copy and `SetBeat()` switch
- Normalize exdates to date-only (`.take(10)`) in rrule expansion (server stores datetime for timed events per RFC 5545)
- Upload processed events (masters + exceptions) to server via `upload_synced`
- Ensure `RRULE:` prefix on all recurrence strings sent to Google Calendar API — use `GoogleCalendar._ensure_rrule_prefix()` in `sync.py` (defense-in-depth for DB data that may lack the prefix)

### ID Generation:
All three sources use `IcsParser.generateIdFromUid(sourceId, syncedCalendarId)` —
a SHA-256 hash of `"$syncedCalendarId:$sourceId"` truncated to 7 bytes (Long).

---

## 8. File Reference

### Pad (Kotlin)

| Purpose | Path |
|---------|------|
| ICS parser | `pad/.../modules/calendar/IcsParser.kt` |
| Google client | `pad/.../modules/calendar/GoogleCalendarClient.kt` |
| Outlook client | `pad/.../modules/calendar/OutlookCalendarClient.kt` |
| Calendar sync worker | `pad/.../modules/calendar/CalendarSyncWorker.kt` |
| Calendar repository | `pad/.../database/repository/CalendarRepository.kt` |
| Event entity | `pad/.../database/entities/CalendarEventEntity.kt` |
| Event DAO | `pad/.../database/dao/CalendarEventDao.kt` |
| Synced calendar entity | `pad/.../database/entities/SyncedCalendarEntity.kt` |
| Synced calendar DAO | `pad/.../database/dao/SyncedCalendarDao.kt` |
| Event manager | `pad/.../modules/calendar/Managers.kt` |
| Models / toEventOccurrence | `pad/.../modules/calendar/Models.kt` |

(All Pad paths under `pad/app/src/main/java/it/expendables/pronext/`)

### Server-side Go Syncers

| Purpose | Path |
|---------|------|
| ICS syncer main | `backend/scripts/go/ics_syncer/main.go` |
| ICS syncer logic | `backend/scripts/go/ics_syncer/syncer.go` |
| ICS HTTP (download + SHA256) | `backend/scripts/go/ics_syncer/http.go` |
| Outlook syncer main | `backend/scripts/go/outlook_syncer/main.go` |
| Outlook syncer logic | `backend/scripts/go/outlook_syncer/syncer.go` |
| Outlook Graph API | `backend/scripts/go/outlook_syncer/outlook.go` |
| Outlook HTTP (Django calls) | `backend/scripts/go/outlook_syncer/http.go` |
| Outlook tests | `backend/scripts/go/outlook_syncer/syncer_test.go` |

### Server (Django) & Heartbeat

| Purpose | Path |
|---------|------|
| Go heartbeat | `heartbeat/beat.go` |
| Unified syncer endpoint | `backend/pronext/calendar/views.py` → `get_sync_calendars` |
| Server upload endpoint | `backend/pronext/calendar/viewset_pad.py` → `upload_synced` |
| Server sync endpoint | `backend/pronext/calendar/viewset_pad.py` → `sync` |
| Online status helpers | `backend/pronext/common/viewset_pad.py` → `ONLINE_STATUS_*`, `get_device_online_status` |
| Server calendar options | `backend/pronext/calendar/options.py` → `sync_calendar()`, `flush_*_token` (CUD re-exported from providers/) |
| Google/Outlook CUD providers | `backend/pronext/calendar/providers/__init__.py` |
| Provider base class | `backend/pronext/calendar/providers/base.py` |
| Google Calendar provider | `backend/pronext/calendar/providers/google.py` |
| Outlook Calendar provider | `backend/pronext/calendar/providers/outlook.py` |
| Provider CUD operations | `backend/pronext/calendar/providers/operations.py` |
| Google Calendar client (sync.py renamed) | `backend/pronext/calendar/google_sync.py` |
