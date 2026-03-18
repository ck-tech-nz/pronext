---
name: rfc5545-reference
description: >
  Pronext's working subset of RFC 5545 (iCalendar). Defines the exact RRULE properties,
  EXDATE formats, date conventions, and deliberate deviations used across all recurring
  modules. Referenced by rrule-handling and sync-handling skills.
---

# RFC 5545 Reference — Pronext Working Subset

This is **not** the full RFC 5545 spec. It documents only the parts Pronext uses,
plus our deliberate deviations. Authoritative source: [RFC 5545](https://datatracker.ietf.org/doc/html/rfc5545)

---

## 1. RRULE Properties

### Supported

| Property | Values | Example | Notes |
|----------|--------|---------|-------|
| **FREQ** | DAILY, WEEKLY, MONTHLY, YEARLY | `FREQ=WEEKLY` | Required. Always uppercase. |
| **INTERVAL** | Integer >= 1 | `INTERVAL=2` | Omitted when = 1 (implicit default). |
| **UNTIL** | YYYYMMDD (8 digits) | `UNTIL=20260331` | **Always date-only** — see Deviation #2. |
| **BYDAY** | MO,TU,WE,TH,FR,SA,SU | `BYDAY=MO,WE,FR` | Two-letter codes. Bysetpos embedded as prefix — see Deviation #1. |
| **BYMONTHDAY** | 1–31 | `BYMONTHDAY=15` | Months with fewer days skip (RFC 5545 standard, not a bug). |
| **BYMONTH** | 1–12 | `BYMONTH=3` | Auto-added by server for YEARLY + BYMONTHDAY (dateutil bug workaround). |

### NOT Supported

COUNT, BYHOUR, BYMINUTE, BYSECOND, BYWEEKNO, BYYEARDAY, WKST, BYSETPOS (as separate param).

---

## 2. EXDATE (Exception Dates)

### RFC 5545 Rule
EXDATE value type **must match DTSTART**: DATE for all-day events, DATE-TIME for timed events.

### Server Behavior
Server follows RFC 5545 correctly via `format_time()`:

| Event Type | EXDATE Format | Example |
|------------|---------------|---------|
| All-day | DATE (yyyy-MM-dd) | `"2026-03-14"` |
| Timed | DATE-TIME (ISO 8601) | `"2026-03-14T10:00:00+00:00"` |

Stored in `repeat_exclude` (Calendar) or `exdates` (Task/Meal) as a list of strings.

### Pad Normalization Rule
Pad expands rrules into **date-only** occurrence strings (architecture separates "which day"
from "what time"). Therefore:

> **Pad MUST normalize all exdates to date-only (`.take(10)`) before comparing against occurrences.**

This is safe because each recurring event has **at most one occurrence per day**.

Applies to Calendar events (server sends datetime for timed events).
Task/Meal exdates are already date-only from server.

---

## 3. DTSTART / DTEND

### All-Day Events

| Property | RFC 5545 Format | Pad Storage |
|----------|----------------|-------------|
| DTSTART | `DTSTART;VALUE=DATE:20260315` | `startDate = "2026-03-15"` (yyyy-MM-dd) |
| DTEND | `DTEND;VALUE=DATE:20260316` | `endDate = "2026-03-15"` (yyyy-MM-dd) |

**Exclusive End Date**: RFC 5545 DTEND is the day **after** the last day. Pad stores **inclusive**.
All three parsers (ICS, Google, Outlook) subtract 1 day on import — see Deviation #4.

### Timed Events

| Property | RFC 5545 Format | Pad Storage |
|----------|----------------|-------------|
| DTSTART | `DTSTART;TZID=America/New_York:20260315T100000` or `DTSTART:20260315T100000Z` | `startAt` (epoch millis) |
| DTEND | Same pattern | `endAt` (epoch millis) |

Timezone stored separately in `timezone` field (IANA string). Server sends UTC with `Z` suffix.

### Pad DateTime Parsing Priority
1. Has `TZID=` parameter → `ZoneId.of(tzid)`
2. Ends with `Z` → UTC
3. Neither → UTC fallback

---

## 4. VEVENT Properties Parsed from ICS

| Property | Usage | Notes |
|----------|-------|-------|
| **UID** | Deduplication (`syncedId`) | Required |
| **SUMMARY** | Event title | |
| **DTSTART** | Start date/time | With TZID extraction |
| **DTEND** | End date/time | Exclusive for all-day |
| **RRULE** | Recurrence rule | Stored as-is |
| **EXDATE** | Exception dates | Multiple allowed; combined into comma-separated list |
| **RECURRENCE-ID** | Exception instances | **Skipped** — Pad expands locally from rrule |
| **PRODID** | Calendar source detection | Apple calendar color handling |
| **X-APPLE-CALENDAR-COLOR** | iCloud calendar color | Format: `#RRGGBBAA` (8-digit hex) |

### Line Unfolding (RFC 5545 Section 3.1)
Long lines are wrapped with CRLF + space/tab continuation. Must normalize before parsing:
```
.replace("\r\n", "\n").replace("\n ", "").replace("\n\t", "")
```

---

## 5. Deliberate Deviations from RFC 5545

### Deviation #1: BYSETPOS Embedded in BYDAY

| Standard | Pronext |
|----------|---------|
| `FREQ=MONTHLY;BYDAY=FR;BYSETPOS=2` | `FREQ=MONTHLY;BYDAY=2FR` |
| `FREQ=MONTHLY;BYDAY=SA;BYSETPOS=-1` | `FREQ=MONTHLY;BYDAY=-1SA` |

**Why**: Simpler parsing. Position prefix directly before day code.
Consistent across server (`rrule_utils.py`) and Pad (`RRuleParser.kt`).

### Deviation #2: UNTIL Always Date-Only

RFC 5545 says UNTIL type must match DTSTART. We always use YYYYMMDD (no time), even for timed events.
Both server and Pad normalize: strip `T235959Z` or any time suffix.

**Why**: Simplifies comparison logic. Timed event's "last day" is unambiguous as a date.

### Deviation #3: No COUNT Support

We use UNTIL for finite recurrences, never COUNT.

**Why**: UNTIL is more intuitive for end-users ("repeat until March 31") and simpler for
AND_FUTURE truncation (just set UNTIL to day before split point).

### Deviation #4: Exclusive End → Inclusive Storage

All-day DTEND is exclusive per RFC 5545. We subtract 1 day and store inclusive.

**Why**: Display logic is simpler with inclusive dates. A single-day event has
`startDate == endDate`, not `endDate = startDate + 1`.

Applied in all three parsers (ICS, Google, Outlook). **Must never double-subtract.**

### Deviation #5: RECURRENCE-ID → EXDATE + Standalone (Converted, Not Native)

RFC 5545 uses RECURRENCE-ID on override VEVENTs (same UID) to define modified instances.
Pronext converts these to its own model during import:

- **Modified instance** → EXDATE on master + standalone event with `parentEventId`
- **Cancelled instance** → EXDATE on master only

**Why**: Pad expands rrules locally via RRuleParser which works with EXDATE, not RECURRENCE-ID.
The conversion happens in the parser layer (GoogleCalendarClient, OutlookCalendarClient, IcsParser)
using a shared helper function. After conversion, the data is structurally identical to what
Pad's own "Edit This" / "Delete This" operations produce.

**Storage model**: Single table with `parentEventId: Long?` (null = master/standalone,
non-null = exception linked to master). Same pattern as server's `Event.repeat_event_id`.

---

## 6. Format Quick Reference

| Concept | Format | Example |
|---------|--------|---------|
| RRULE string | `FREQ=...;INTERVAL=...;...` | `FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE` |
| UNTIL in rrule | YYYYMMDD | `UNTIL=20260331` |
| All-day date | yyyy-MM-dd | `2026-03-15` |
| Timed datetime (server) | ISO 8601 UTC | `2026-03-15T10:00:00+00:00` |
| Timed datetime (Pad) | epoch millis | `1742036400000` |
| Exdate (all-day) | yyyy-MM-dd | `2026-03-14` |
| Exdate (timed, server) | ISO 8601 | `2026-03-14T10:00:00+00:00` |
| Exdate (timed, Pad after normalize) | yyyy-MM-dd | `2026-03-14` |
| RRULE prefix | Optional `RRULE:` | Strip before parsing |
| Exdate separator (Pad entity) | Comma | `2026-03-14,2026-03-20` |

---

## 7. Cross-References

- **Implementation patterns**: See [rrule-handling](../rrule-handling/SKILL.md) skill
  (RRULE CRUD, change types, expansion, form integration)
- **Sync patterns**: See [sync-handling](../sync-handling/SKILL.md) skill
  (ICS/Google/Outlook parsing, incremental sync, version conflicts)
