---
name: rrule-handling
description: >
  Standard patterns for handling iCal-style recurring objects (rrule) in Pronext.
  Covers rrule creation, expansion, editing (this/all/future), deletion, completion,
  and sync across Server (Django) and Pad (Kotlin/Room). Use when modifying any
  recurring object logic (Task, Meal, Calendar Event) to avoid breaking existing patterns.
---

# RRule Handling Patterns (Pronext Standard)

> **RFC 5545 definitions**: See [rfc5545-reference](../rfc5545-reference/skill.md) for supported
> RRULE properties, EXDATE formats, date conventions, and deliberate deviations from the standard.

All three recurring modules (Task, Meal, Calendar Event) share the same architecture:
Room DB + local rrule expansion + optimistic sync. Task is the reference implementation.

## Architecture Overview

```
Server (Django)                          Pad (Kotlin)
+-----------------------+                +---------------------------+
| BaseRecurrableModel   |  sync API      | Room Entity: rrule field  |
|   rrule (string)      | ----------->   | (compact string)          |
|   exdates (list)      |  NO expansion  |                           |
|   version             |                | Manager:                  |
|                       |                |  Room Flow observation    |
| options.py:           |                |  local rrule expansion    |
|  change_type logic    |                |  via RRuleParser          |
|  exdates management   |                |                           |
|  series splitting     |                | Form -> RepeatCard (UI)   |
|                       |                |  -> RepeatData <-> rrule  |
| rrule_utils.py:       |                |                           |
|  repeat <-> rrule     |                | Repository:               |
+-----------------------+                |  optimistic CRUD + sync   |
                                         +---------------------------+
```

**Key principle**: Server stores compact rrule strings. Pad expands locally via RRuleParser.

---

## 1. RFC 5545 Recurrence Patterns We Support

| Pattern | RRULE Example | Notes |
|---------|---------------|-------|
| Every day | `RRULE:FREQ=DAILY;INTERVAL=1` | |
| Every N days | `RRULE:FREQ=DAILY;INTERVAL=3` | |
| Every week on specific days | `RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR` | |
| Every N weeks | `RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU,TH` | |
| Monthly by date | `RRULE:FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=15` | 31st skips short months (expected) |
| Monthly by day position | `RRULE:FREQ=MONTHLY;BYDAY=2FR` | 2nd Friday; bysetpos embedded in BYDAY prefix |
| Monthly last day of kind | `RRULE:FREQ=MONTHLY;BYDAY=-1SA` | Last Saturday |
| Every year | `RRULE:FREQ=YEARLY;INTERVAL=1` | |
| With end date | `RRULE:...;UNTIL=20260331` | YYYYMMDD format (no time) |

**bysetpos convention**: Embedded as BYDAY prefix, NOT as separate BYSETPOS parameter.
- 2nd Friday -> `BYDAY=2FR` (not `BYDAY=FR;BYSETPOS=2`)
- Last Saturday -> `BYDAY=-1SA`
- Consistent across server (`rrule_utils.py`) and Pad (`RRuleParser.kt`)

These patterns match Google Calendar, Outlook, and iCloud standards.

---

## 2. Three Change Types for Edit/Delete

All recurring modules support 3 change types:

| Value | Name | Edit Behavior | Delete Behavior |
|-------|------|---------------|-----------------|
| 0 | THIS | Create standalone exception + add exdate to parent | Add exdate to parent (hide occurrence) |
| 1 | ALL | Update parent entity directly | Delete parent entity |
| 2 | AND_FUTURE | Truncate parent (set UNTIL) + create new series | Truncate parent (set UNTIL to day before) |

### Change Type Menu Rules (`availableChangeTypes()`)

File: `pad/.../components/ChangeConfirm.kt`

| Scenario | Save Menu | Delete Menu | Reason |
|----------|-----------|-------------|--------|
| Non-recurring | Execute immediately | Execute immediately | No choice needed |
| First occurrence | THIS, ALL | THIS, ALL | AND_FUTURE = ALL for first |
| Later occurrence, repeat unchanged | THIS, AND_FUTURE, ALL | THIS, AND_FUTURE, ALL | Full options |
| Later occurrence, repeat changed | AND_FUTURE, ALL | THIS, AND_FUTURE, ALL | Can't change repeat for just one |

```kotlin
// ALWAYS use this function. Never manually compute change type availability.
val changeTypes = availableChangeTypes(
    occurrenceDate = expandedItem.occurrenceDate,  // null = first occurrence
    originalStartDate = entity.dueDate,             // or entity.startDate for Calendar
    repeatChanged = originalRepeatData != currentRepeatData  // save only
)
```

### Repeat Item Update/Delete Menu Options — Display Priority (high to low)

Decision tree for showing change type options, ordered by priority:

1. **Non-recurring item** → Execute immediately (no menu)
2. **Recurring item, first occurrence** (`occurrenceDate == null || occurrenceDate == originalStartDate`)
   - Save: `[THIS, ALL]` — "This and future" ≡ "All" for first occurrence
   - Delete: `[THIS, ALL]`
3. **Recurring item, later occurrence, repeat changed** (save only)
   - Save: `[THIS_AND_FUTURE, ALL]` — "This" hidden (changing repeat for one occurrence is nonsensical)
4. **Recurring item, later occurrence, repeat unchanged**
   - Save: `[THIS, THIS_AND_FUTURE, ALL]` — full options
   - Delete: `[THIS, THIS_AND_FUTURE, ALL]` — full options

**Critical for Calendar events**: `originalStartDate` must come from the entity's original start date
(before occurrence expansion shifts it). Use `Event.seriesStartDate` (set by `toEventOccurrence`)
rather than the shifted `event.start_at`/`event.start_date`. Without this, every occurrence looks
like the first occurrence and "This and future" never appears.

### Date handling during edit

- **Edit This**: form date = `occurrenceDate` (the specific occurrence)
- **Edit All**: preserve master entity's original `startDate/dueDate` unless user explicitly changed date/time (track with `userChangedDate` flag)
- **Edit This and Future**: new series starts from `occurrenceDate`

**Critical: "Edit All" date shift for non-first occurrences**

When editing from a later occurrence with "Edit All", the form's dates are the occurrence's shifted
dates (e.g., April 15), not the master's (e.g., March 15). The code MUST shift them back to the
master's dates before sending to the server and before the optimistic local update.

```kotlin
// Compute shift from occurrence date back to master date
val masterDateStr = event.seriesStartDate  // "2026-03-15" (set by toEventOccurrence)
val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.getDefault())
val masterDate = masterDateStr?.let { sdf.parse(it) }
val occDateStr = (if (event.is_all_day) event.start_date else event.start_at)?.postedDate
val occDate = occDateStr?.let { sdf.parse(it) }
val shiftMs = if (masterDate != null && occDate != null) masterDate.time - occDate.time else 0L
// Apply shiftMs to start_at, end_at, start_date, end_date
```

Three triggers set `userChangedDate = true`:
- Start date picker (`updateStartDateOnly`)
- Start/end time picker (`updateEndTimeOnly`, end time callback)
- End date picker callback

If ANY date/time field changes, `userChangedDate` must be true — otherwise the original dates
are preserved and the user's change is silently discarded.

**Server-side alignment (defense-in-depth)**: `options.py` also has alignment code that shifts
`(request_start - origin_start + master_start)` for change_type=ALL. This corrects occurrence
dates to master dates using `repeat_flag`. Both Pad and server should produce correct dates
independently.

---

## 3. Data Model

### Server: BaseRecurrableModel (`backend/pronext/base/models.py`)

```python
class BaseRecurrableModel(models.Model):
    rrule = models.CharField(max_length=512, blank=True, null=True)
    exdates = models.JSONField(default=list, blank=True, null=True)  # ["2026-03-01"]
    version = models.PositiveSmallIntegerField(default=1)
```

Inherited by Task (`due_date`, `due_time`, `completeds`) and Meal (`plan_date`).
Calendar Event uses `recurrence` (same concept, different field name).

### Pad: Entity fields

**Task/Meal pattern** (reference):
```kotlin
val rrule: String? = null,        // "FREQ=DAILY;INTERVAL=1;UNTIL=20260331"
val exdates: String? = null,      // comma-separated: "2026-03-01,2026-03-05"
val hasRepeat: Boolean = false,
val dueDate: String,              // yyyy-MM-dd (original series start date)
val syncStatus: SyncStatus,       // SYNCED, PENDING_CREATE, PENDING_UPDATE, PENDING_DELETE
```

**Calendar Event pattern** (equivalent):
```kotlin
val recurrence: String? = null,   // same rrule format
val exdates: String? = null,      // same comma-separated format
val startAt: Long? = null,        // epoch millis (timed events)
val startDate: String? = null,    // yyyy-MM-dd (all-day events)
val isAllDay: Boolean = false,
val syncStatus: SyncStatus,
val syncedCalendarId: Long? = null, // null = own event, non-null = read-only synced
```

Calendar has both timed (`startAt`/`endAt` millis) and all-day (`startDate`/`endDate` string) events.
The `hasRecurrence` property is derived: `get() = !recurrence.isNullOrBlank()`.

---

## 4. Local RRule Expansion (Pad)

### RRuleParser.getOccurrencesAsStrings()

Shared by all modules. File: `pad/.../utils/RRuleParser.kt`

```kotlin
val occurrences = RRuleParser.getOccurrencesAsStrings(
    startDateStr = entity.dueDate,     // original series start (yyyy-MM-dd)
    rruleString = entity.rrule,        // full RRULE string
    rangeStartStr = rangeStart,        // query window start
    rangeEndStr = rangeEnd,            // query window end
    exdates = entity.exdates?.split(",")?.filter { it.isNotBlank() }
)
// Returns: ["2026-03-10", "2026-03-12", "2026-03-14"]
```

**Critical implementation details:**
- Uses `dmfs/lib-recur` library (RFC 5545 compliant)
- `iterator.fastForward(rangeStart)` — MUST use to skip old occurrences (performance)
- Creates floating DateTime (no timezone) to match UNTIL values
- Strips `RRULE:` prefix if present
- Normalizes UNTIL: strips time portion (`20260602T235959Z` -> `20260602`)
- Safety limit: 365 occurrences max
- Filters out exdates after expansion

### Manager expansion pattern

```kotlin
// Task/Meal: entity.dueDate / entity.planDate
// Calendar:  entity.startDate (all-day) or date extracted from entity.startAt (timed)

for (entity in entities) {
    if (entity.hasRecurrence) {
        val exdateList = entity.exdates?.split(",")?.filter { it.isNotBlank() }
        val occurrences = RRuleParser.getOccurrencesAsStrings(
            startDateStr = getStartDate(entity),
            rruleString = entity.rrule,
            rangeStartStr = rangeStart,
            rangeEndStr = rangeEnd,
            exdates = exdateList
        )
        for (occDate in occurrences) {
            expanded.add(createExpandedItem(entity, occDate))
        }
    } else {
        expanded.add(createNonRecurringItem(entity))
    }
}
```

For Calendar timed events, `toEventOccurrence(occurrenceDate)` shifts startAt/endAt by the day offset
from the original start date, preserving the time-of-day.

### DAO query pattern (Room)

**Task/Meal:**
```sql
SELECT * FROM tasks
WHERE syncStatus != 'PENDING_DELETE'
  AND (
    dueDate BETWEEN :startDate AND :endDate
    OR (rrule IS NOT NULL AND rrule != '' AND dueDate <= :endDate)
  )
```

**Calendar:**
```sql
SELECT * FROM calendar_events
WHERE syncStatus != 'PENDING_DELETE'
  AND (
    (isAllDay = 1 AND startDate <= :endDate AND (endDate IS NULL OR endDate >= :startDate))
    OR (isAllDay = 0 AND startAt <= :endMillis AND (endAt IS NULL OR endAt >= :startMillis))
    OR (recurrence IS NOT NULL AND recurrence != '' AND (
        (isAllDay = 1 AND startDate <= :endDate)
        OR (isAllDay = 0 AND startAt <= :endMillis)
    ))
  )
```

**Key**: Recurring entities MUST have `startDate/dueDate <= endDate` constraint. Without it,
ALL recurring events are returned regardless of range, causing performance issues.

---

## 5. Pad Repository — Optimistic CRUD with Race Prevention

### Critical Pattern: Prevent syncPendingChanges Race Condition

When a CRUD method (addEvent, updateEvent) runs, it calls the API. Meanwhile, a Signal/heartbeat
can trigger `syncPendingChanges()` concurrently. If the entity is in PENDING_CREATE/PENDING_UPDATE
state, `syncPendingChanges` will try the same API call again, creating duplicates.

**Solution**: Insert/update with `syncStatus = SYNCED`. Only change to PENDING on API failure.

```kotlin
// CORRECT: prevents race
suspend fun addItem(request): Long {
    val localId = Entity.generateLocalId()  // -System.currentTimeMillis()
    val entity = Entity(..., syncStatus = SyncStatus.SYNCED)  // <-- SYNCED, not PENDING_CREATE
    dao.insert(entity)

    return try {
        val response = api.add(request)
        val serverId = response.data?.id ?: localId
        dao.replaceLocalWithServer(localId, entity.copy(id = serverId, syncStatus = SyncStatus.SYNCED))
        serverId
    } catch (e: Exception) {
        dao.updateSyncStatus(localId, SyncStatus.PENDING_CREATE)  // <-- only on failure
        localId
    }
}
```

### Update flow (change_type=ALL)

```kotlin
suspend fun updateItem(id, request, changeType = 1): Boolean {
    if (changeType == 1 && existing != null) {
        // Optimistic local update with SYNCED (prevents race)
        dao.update(existing.copy(...newFields..., syncStatus = SyncStatus.SYNCED))
    }
    // THIS(0) and AND_FUTURE(2): NO optimistic local update (server creates new entities)

    return try {
        api.update(id, request.copy(change_type = changeType, repeat_flag = repeatFlag))
        if (changeType != 1) syncFromServer()  // THIS/AND_FUTURE need re-sync
        true
    } catch (e: Exception) {
        if (changeType == 1) dao.updateSyncStatus(id, SyncStatus.PENDING_UPDATE)
        else syncFromServer()
        false
    }
}
```

### Delete flow (3 change types)

```kotlin
suspend fun deleteItem(id, changeType, repeatFlag): Boolean {
    when (changeType) {
        0 -> {  // THIS: add exdate optimistically (keep SYNCED)
            val newExdates = (currentExdates + repeatFlag).joinToString(",")
            dao.update(existing.copy(exdates = newExdates))  // stays SYNCED
        }
        1 -> dao.deleteById(id)      // ALL: delete immediately
        2 -> {}                       // AND_FUTURE: no optimistic update
    }

    return try {
        api.delete(id, DeleteRequest(change_type = changeType, repeat_flag = repeatFlag))
        when (changeType) {
            0 -> {}                   // THIS: exdate already correct
            1 -> {}                   // ALL: already deleted
            2 -> syncFromServer()     // AND_FUTURE: server split series, re-sync
        }
        true
    } catch (e: Exception) {
        when (changeType) {
            0 -> dao.update(existing)  // revert exdate
            1 -> dao.insert(existing.copy(syncStatus = SyncStatus.PENDING_DELETE))
            2 -> syncFromServer()
        }
        false
    }
}
```

### syncFromServer — preserves PENDING items

```kotlin
// DAO transaction: delete SYNCED + insert new (PENDING_* survive)
@Transaction
suspend fun replaceOwnItems(items: List<Entity>) {
    deleteOwnSyncedItems()  // WHERE syncStatus = 'SYNCED' AND ownerId IS NULL
    insertAll(items)
}
```

---

## 6. Server CRUD Operations (options.py pattern)

Reference: `backend/pronext/task/options.py` (Task), `backend/pronext/meal/options.py` (Meal),
`backend/pronext/calendar/options.py` (Calendar Event)

### CREATE
```python
obj = Model.objects.create(user_id=device_id, **kwargs)  # rrule already in kwargs
Beat(device_id, rel_user_id).should_refresh_xxx(True)
```

### UPDATE — 3 change types
```python
if change_type == ALL:
    Model.objects.filter(...).update(version=F('version') + 1, **kwargs)

elif change_type == THIS:
    with transaction.atomic():
        kwargs['rrule'] = None; kwargs['exdates'] = []
        Model.objects.create(user_id=device_id, **kwargs)         # standalone exception
        exdates.append(repeat_flag)
        Model.objects.filter(...).update(exdates=exdates)         # hide from parent

elif change_type == AND_FUTURE:
    with transaction.atomic():
        new_rrule = update_rrule_until(obj.rrule, repeat_flag - 1 day)
        Model.objects.filter(...).update(rrule=new_rrule)         # truncate parent
        Model.objects.create(user_id=device_id, **kwargs)         # new series
```

### DELETE — 3 change types
```python
if change_type == ALL:     Model.objects.filter(...).delete()
elif change_type == THIS:
    with transaction.atomic():   # <-- required
        exdates.append(repeat_flag); update(exdates=exdates)
elif change_type == AND_FUTURE:
    with transaction.atomic():   # <-- required
        update(rrule=update_rrule_until(rrule, flag - 1 day))
```

### Calendar-specific notes
- Calendar Event uses `repeat_exclude` (list of dicts) instead of `exdates` (list of strings)
- Calendar `options.py` also handles Google Calendar and Outlook two-way sync within the transaction
- Calendar Event model has `compatible_recurrence` property that generates rrule from legacy
  `repeat_every`/`repeat_type` fields when `recurrence` field is empty
- Calendar passes `recurrence` directly (rrule string), not `repeat` (RepeatData)

---

## 7. Viewset Serialization

### Sentinel pattern for nullable repeat field
```python
_missing = object()
repeat_data = data.pop('repeat', _missing)
if repeat_data is not _missing:
    data['rrule'] = repeat_to_rrule(repeat_data) if repeat_data else None
```
Three states: field absent = don't touch; field = null = clear rrule; field = data = set rrule.

### Pad sync vs App API
- **Pad sync** (`get_xxx_for_sync`): Returns raw entities, NO rrule expansion. Pad expands locally.
- **App API** (`get_xxx`): Returns expanded occurrences. Server expands.
- **NEVER mix** these two approaches.

---

## 8. Pad Form Integration

### RepeatCard (shared component)

File: `pad/.../components/RepeatCard.kt`

```kotlin
interface IRepeat {
    var repeat_every: Int          // interval
    var repeat_type: Int           // 0=daily, 1=weekly, 2=monthly, 3=yearly
    var repeat_until: Date?        // end date
    var repeat_byday: RepeatByDay? // {byweekday: [0-6], bynweekday: [[pos, day]]}
    var startAt: SDatetime         // start date (for defaults)
}
```

### Smart repeat_until defaults
```
daily   -> +8 days
weekly  -> +29 days
monthly -> +1 year
yearly  -> +5 years
```

### RRule <-> IRepeat conversion

Task/Meal: `entity.toRepeatData()` (on entity itself)
Calendar: `toEvent()` parses rrule into IRepeat fields via `RRuleParser.parseRrule()`

Weekday mapping: Always use two-letter codes (MO, TU, ...) in rrule strings.
Index conversion only in form adapter layer.

### Calendar Form — EventFormManager specifics

Calendar Event uses `Event` data class (implements `IRepeat`) as both the model and form params.
The `Event.repeat_flag` field carries the occurrence date through the form lifecycle.

**Form initialization** (`EventFormManager`):
```kotlin
class EventFormManager(event: Event?, eventType, initialDate) {
    val occurrenceDate: String? = event?.repeat_flag       // set by toEventOccurrence()
    val originalStartDate: String? = event?.startDate/startAt formatted as "yyyy-MM-dd"
    var userChangedDate = false                             // track explicit date changes
    val repeatChanged: Boolean get() = originalRepeatData != currentRepeatData
}
```

**Save flow** (EventForm.kt):
```kotlin
// Non-recurring: save directly
if (event.repeat_every == 0) { vm.update(); return }
// Recurring: compute available change types
val changeTypes = availableChangeTypes(
    occurrenceDate = vm.occurrenceDate,
    originalStartDate = vm.originalStartDate,
    repeatChanged = vm.repeatChanged
)
showChangeConfirm("Save", SaveConfirmType.EVENT, changeTypes) { vm.update(it) }
```

**Delete flow** (EventForm.kt):
```kotlin
if (event.repeat_every == 0) { vm.delete(event); return }
val deleteChangeTypes = availableChangeTypes(
    occurrenceDate = vm.occurrenceDate,
    originalStartDate = vm.originalStartDate
)
showChangeConfirm("Delete", SaveConfirmType.EVENT, deleteChangeTypes) { vm.delete(event, it) }
```

**"Edit All" date preservation**:
When `changeType == ALL && !userChangedDate`, the update request shifts the occurrence's
dates back to the master's original dates using `event.seriesStartDate`. The shift is computed
as `masterDate - occurrenceDate` and applied to all date/time fields. User must explicitly
change any date or time field (which sets `userChangedDate = true`) for the new value to
propagate. Without `seriesStartDate`, the occurrence's dates would incorrectly replace the
master's start date.

### Calendar vs Task serialization

Calendar sends `recurrence` (rrule string) directly to server, NOT `repeat` (RepeatData).
The server's `create_rrule(**kwargs)` reads `repeat_every`, `repeat_type`, etc. from the serializer
and generates the rrule. This means:
- No sentinel pattern needed for Calendar (unlike Task which sends `repeat: RepeatData?`)
- When Pad clears repeat: sends `repeat_every=0` -> `create_rrule()` returns `None` -> `recurrence=None`
- `recurrence: null` in Kotlin (with `encodeDefaults=true`) is sent as JSON `null`

---

## 9. Rules & Pitfalls

### DO NOT:
- Expand rrule on server for Pad sync (Pad expands locally)
- Use BYSETPOS as separate rrule parameter (embed in BYDAY prefix)
- Allow "Edit This" when repeat settings changed (makes no sense)
- Forget `repeat_flag` for THIS/AND_FUTURE operations
- Use PENDING_CREATE/PENDING_UPDATE during API call (causes race with syncPendingChanges)
- Query recurring entities without startDate constraint (returns ALL recurring items)
- Use timezone-aware DateTime for rrule expansion (use floating/all-day)
- Generate rrule strings without `RRULE:` prefix (Google Calendar API rejects them)
- Let Google/Outlook API failures crash AND_FUTURE operations (wrap in try/except)

### MUST:
- Use `fastForward()` when expanding rrule (performance critical)
- **Always include `RRULE:` prefix** when generating rrule strings — both Pad (`RRuleParser.generateRrule()`) and server (`create_rrule()`) must produce `RRULE:FREQ=...` format. Google Calendar API requires the prefix; dmfs lib-recur requires it stripped (`.removePrefix("RRULE:")`). Server's `GoogleCalendar._ensure_rrule_prefix()` is a defense-in-depth layer for existing DB data.
- Strip `RRULE:` prefix before parsing with dmfs lib-recur (server may include it)
- Normalize UNTIL time portions (`T235959Z` -> removed) for date-only expansion
- Use `transaction.atomic()` for THIS and AND_FUTURE edits (two DB ops)
- Send Beat notification after every mutation
- Re-sync from server after THIS/AND_FUTURE (server creates new entities)
- Use SYNCED status during CRUD to prevent `syncPendingChanges` race
- Wrap Google/Outlook API calls in try/except for AND_FUTURE operations so local DB changes are not rolled back by external API failures (matches the pattern already used in delete AND_FUTURE)

### Monthly on 31st:
Months with fewer days skip the occurrence (RFC 5545 behavior). Expected, not a bug.

---

## 10. File Reference

### Server
| Purpose | Path |
|---------|------|
| Base model | `backend/pronext/base/models.py` -> `BaseRecurrableModel` |
| RRule utils | `backend/pronext/base/rrule_utils.py` |
| Recurrence expansion | `backend/pronext/base/recurrence_utils.py` |
| Task CRUD | `backend/pronext/task/options.py` |
| Task viewset (Pad) | `backend/pronext/task/viewset_pad.py` |
| Meal CRUD | `backend/pronext/meal/options.py` |
| Meal viewset (Pad) | `backend/pronext/meal/viewset_pad.py` |
| Calendar CRUD orchestration | `backend/pronext/calendar/options.py` (CUD re-exported from providers/) |
| Calendar provider operations | `backend/pronext/calendar/providers/operations.py` |
| Calendar viewset (Pad) | `backend/pronext/calendar/viewset_pad.py` |

### Pad (Kotlin)
| Purpose | Path |
|---------|------|
| RRule parser | `pad/.../utils/RRuleParser.kt` |
| Task entity | `pad/.../database/entities/TaskEntity.kt` |
| Task DAO | `pad/.../database/dao/TaskDao.kt` |
| Task repository | `pad/.../database/repository/TaskRepository.kt` |
| Task manager | `pad/.../modules/task/TaskManager.kt` |
| Task form | `pad/.../modules/task/TaskForm.kt` |
| Meal entity | `pad/.../database/entities/MealEntity.kt` |
| Meal manager | `pad/.../modules/meal/MealManager.kt` |
| Calendar entity | `pad/.../database/entities/CalendarEventEntity.kt` |
| Calendar DAO | `pad/.../database/dao/CalendarEventDao.kt` |
| Calendar repository | `pad/.../database/repository/CalendarRepository.kt` |
| Event manager | `pad/.../modules/calendar/Managers.kt` -> EventManager |
| Event form | `pad/.../modules/calendar/Managers.kt` -> EventFormManager |
| Calendar models | `pad/.../modules/calendar/Models.kt` |
| RepeatCard UI | `pad/.../components/RepeatCard.kt` |
| Change confirm | `pad/.../components/ChangeConfirm.kt` |

(All Pad paths under `pad/app/src/main/java/it/expendables/pronext/`)
