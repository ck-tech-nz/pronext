# Calendar UI Test Suite — Design Spec

**Date:** 2026-04-04
**Scope:** Comprehensive Compose UI tests for Pad calendar Event CRUD with rrule expansion, covering all repeat frequencies and all three change types (THIS/ALL/THIS_AND_FUTURE). Plus JVM unit tests for RRuleParser.

**References:**
- Test checklist: `docs/calendar/CALENDAR_ROOM_TEST_CHECKLIST.md`
- RRule patterns: `.claude/skills/rrule-handling/skill.md`
- Existing tests: `pad/app/src/androidTest/java/it/expendables/pronext/`

---

## Architecture

```
src/androidTest/java/it/expendables/pronext/
├── base/
│   ├── BaseUiTest.kt              — existing: login, wait helpers
│   ├── CalendarTestHelper.kt      — NEW: navigation, event CRUD, assertions
│   └── TestConfig.kt              — existing: activation code, timeouts
├── auth/
│   └── ActivationTest.kt          — existing
├── calendar/
│   ├── CalendarNavigationTest.kt  — existing
│   ├── CategoryFilterTest.kt      — existing
│   ├── EventCreateTest.kt         — existing (basic create)
│   ├── EventEditTest.kt           — existing (basic edit)
│   ├── EventDeleteTest.kt         — existing (basic delete)
│   ├── create/
│   │   └── EventCreateRepeatTest.kt    — NEW: all freqs, UNTIL, BYDAY
│   ├── edit/
│   │   ├── EventEditThisTest.kt        — NEW: edit THIS for all freqs
│   │   ├── EventEditAllTest.kt         — NEW: edit ALL for all freqs
│   │   └── EventEditFutureTest.kt      — NEW: edit THIS_AND_FUTURE
│   ├── delete/
│   │   ├── EventDeleteThisTest.kt      — NEW: delete THIS for all freqs
│   │   ├── EventDeleteAllTest.kt       — NEW: delete ALL
│   │   └── EventDeleteFutureTest.kt    — NEW: delete THIS_AND_FUTURE
│   ├── combo/
│   │   └── EventComboTest.kt           — NEW: mixed ops, edge cases
│   └── view/
│       └── EventViewExpansionTest.kt   — NEW: rrule in day/week/month views
│
src/test/java/it/expendables/pronext/
└── utils/
    └── RRuleParserTest.kt              — NEW: JVM unit tests (no emulator)
```

**Existing tests are untouched.** New tests live in subdirectories to avoid conflicts.

---

## CalendarTestHelper — Shared Base

All new test classes extend `CalendarTestHelper` which extends `BaseUiTest`.

### Navigation

```kotlin
fun navigateForward(times: Int = 1)
fun navigateBack(times: Int = 1)
fun navigateToToday()
```

Uses testTags: `calendar_nav_next`, `calendar_nav_previous`, `calendar_nav_today`.
Each click includes a short stabilization wait (500ms) for the calendar to re-render.

### Event Creation

```kotlin
fun createEvent(
    titlePrefix: String,
    allDay: Boolean = false,
    repeat: RepeatConfig? = null
): String
```

1. Generates unique title via `"${titlePrefix}_${HHmmss}"`.
2. Clicks `calendar_addButton` → "Event" → fills `eventForm_title`.
3. If `repeat != null`: toggles `repeatCard_toggle`, sets freq via `repeatCard_type`, sets interval via NumStepper, optionally sets UNTIL and BYDAY.
4. Clicks `eventForm_save`.
5. Waits for title to appear (LOGIN_TIMEOUT_MS for network round-trip).
6. Returns the generated title.

### RepeatConfig

```kotlin
data class RepeatConfig(
    val freq: Freq,              // DAILY, WEEKLY, MONTHLY, YEARLY
    val interval: Int = 1,
    val withUntil: Boolean = false,
    val byday: List<String>? = null  // ["MO", "WE", "FR"] — weekly only
)

enum class Freq(val label: String) {
    DAILY("Day"), WEEKLY("Week"), MONTHLY("Month"), YEARLY("Year")
}
```

### Event Interaction

```kotlin
fun clickEvent(title: String)      // onNodeWithTag("eventCard_$title").performClick()
fun clickEventEdit()               // onNode(hasContentDescription("edit")).performClick()
fun clickEventDelete()             // onNode(hasContentDescription("delete")).performClick()
```

`clickEvent` opens the EventDetail popover. `clickEventEdit` then opens the EventForm inside a BasicAlert. `clickEventDelete` triggers the "Are you sure?" alert.

### Change Confirm Dialog

```kotlin
fun confirmThis()           // onNodeWithText("This event").performClick()
fun confirmAll()            // onNodeWithText("All event").performClick()
fun confirmThisAndFuture()  // onNodeWithText("This and future events").performClick()
fun confirmDelete()         // onNodeWithText("Delete").performClick() — the orange button in the alert
```

For recurring delete flow: `clickEventDelete()` → `confirmDelete()` → `confirmThis/All/Future()`.
For non-recurring delete: `clickEventDelete()` → `confirmDelete()` (no change type dialog).

### Form Helpers

```kotlin
fun editTitle(newTitle: String)    // clear eventForm_title + type new title
fun saveEvent()                    // click eventForm_save
fun setRepeat(config: RepeatConfig)
fun clearRepeat()                  // toggle repeatCard_toggle off
fun toggleAllDay()                 // click eventForm_allDay switch
```

### Assertions

```kotlin
fun assertEventVisible(title: String)
fun assertEventNotVisible(title: String)
fun assertEventVisibleOnDate(title: String, daysFromToday: Int)
fun assertEventNotVisibleOnDate(title: String, daysFromToday: Int)
```

`assertEventVisibleOnDate` and `assertEventNotVisibleOnDate` navigate to the target date, perform the assertion, then navigate back to today. Navigation is calculated as weeks forward/back since the calendar shows a full week at a time.

---

## Test Classes — Detailed Coverage

### create/EventCreateRepeatTest.kt

Maps to checklist sections 4.1–4.4 and 11.1–11.4.

| Test | Repeat Config | Assertion |
|---|---|---|
| `createDailyRepeat_interval1` | DAILY, 1 | Event visible today, +1d, +2d |
| `createDailyRepeat_interval3` | DAILY, 3 | Visible today, not +1d, not +2d, visible +3d |
| `createDailyRepeat_withUntil` | DAILY, 1, until=true | Visible today, not after UNTIL (~8 days) |
| `createDailyRepeat_noUntil` | DAILY, 1 | Visible 2+ weeks forward |
| `createWeeklyRepeat_interval1` | WEEKLY, 1 | Visible today, visible +7d, not +1d |
| `createWeeklyRepeat_interval2` | WEEKLY, 2 | Visible today, not +7d, visible +14d |
| `createWeeklyRepeat_withByday` | WEEKLY, 1, byday=[MO,WE,FR] | Visible on those days only |
| `createWeeklyRepeat_withUntil` | WEEKLY, 1, until=true | Stops after ~4 weeks |
| `createMonthlyRepeat_interval1` | MONTHLY, 1 | Visible today, visible +~30d |
| `createMonthlyRepeat_interval2` | MONTHLY, 2 | Visible today, not +~30d, visible +~60d |
| `createMonthlyRepeat_withUntil` | MONTHLY, 1, until=true | Stops after ~1 year |
| `createYearlyRepeat` | YEARLY, 1 | Visible today (can't easily verify +1y in UI) |
| `createYearlyRepeat_withUntil` | YEARLY, 1, until=true | Stops after UNTIL |

**View expansion tests** (same file or `view/EventViewExpansionTest.kt`):

| Test | What it checks |
|---|---|
| `verifyDailyRepeat_weekView` | Daily event appears 7 times in one week view |
| `verifyWeeklyRepeat_weekView` | Weekly event appears exactly 1 time in week |
| `verifyExdate_weekView` | After delete THIS, that day is skipped |

### edit/EventEditThisTest.kt

Maps to checklist section 5. Each test:
1. Creates a repeating event.
2. Navigates forward to a non-first occurrence.
3. Clicks event → edit → changes title → save → "This event".
4. Verifies: changed occurrence has new title, adjacent occurrences have old title.

| Test | Freq |
|---|---|
| `editThis_daily_changeTitle` | DAILY |
| `editThis_daily_changeTime` | DAILY — change time, verify only that day changed |
| `editThis_daily_otherUnchanged` | DAILY — explicit check adjacent days still original |
| `editThis_weekly_changeTitle` | WEEKLY |
| `editThis_monthly_changeTitle` | MONTHLY |
| `editThis_yearly_changeTitle` | YEARLY |

### edit/EventEditAllTest.kt

Maps to checklist section 6. Each test:
1. Creates a repeating event.
2. Clicks event → edit → makes change → save → "All event".
3. Verifies all occurrences reflect the change.

| Test | What changes |
|---|---|
| `editAll_daily_changeTitle` | Title — check multiple days |
| `editAll_daily_changeTime` | Time |
| `editAll_daily_addUntil` | Enable UNTIL — verify series ends |
| `editAll_daily_removeUntil` | Disable UNTIL — verify series continues |
| `editAll_daily_changeInterval` | Interval 1→2 — verify gaps |
| `editAll_weekly_changeTitle` | Title |
| `editAll_weekly_changeInterval` | Interval |
| `editAll_weekly_changeByday` | BYDAY — days shift |
| `editAll_monthly_changeTitle` | Title |
| `editAll_yearly_changeTitle` | Title |
| `editAll_changeType_dailyToWeekly` | Freq change — pattern changes |
| `editAll_changeType_weeklyToMonthly` | Freq change |
| `editAll_removeRepeat` | Turn off repeat — becomes single event |

### edit/EventEditFutureTest.kt

Maps to checklist section 7. Each test:
1. Creates repeating event.
2. Navigates to occurrence N (not first).
3. Edits → save → "This and future events".
4. Verifies: before N has old title, N+ has new title.

| Test | Freq |
|---|---|
| `editFuture_daily_changeTitle` | DAILY |
| `editFuture_daily_verifyNewSeries` | DAILY — new series exists from N |
| `editFuture_daily_verifyOldUntil` | DAILY — old series truncated at N-1 |
| `editFuture_weekly_changeTitle` | WEEKLY |
| `editFuture_monthly_changeTitle` | MONTHLY |
| `editFuture_yearly_changeTitle` | YEARLY |
| `editFuture_changeInterval` | Mixed — old interval stays, new changes |
| `editFuture_changeTime` | Mixed — old time stays, new changes |
| `editFuture_changeType` | Mixed — daily→weekly from N |

### delete/EventDeleteThisTest.kt

Maps to checklist section 8.

| Test | Freq |
|---|---|
| `deleteThis_daily` | DAILY — one day gone, rest visible |
| `deleteThis_daily_firstOccurrence` | DAILY — first excluded, series continues from day 2 |
| `deleteThis_weekly` | WEEKLY |
| `deleteThis_monthly` | MONTHLY |
| `deleteThis_yearly` | YEARLY |

### delete/EventDeleteAllTest.kt

Maps to checklist section 9.

| Test | Notes |
|---|---|
| `deleteAll_daily` | All occurrences gone |
| `deleteAll_weekly` | All gone |
| `deleteAll_withException` | Edit THIS day3 → delete ALL → both parent and exception gone |

### delete/EventDeleteFutureTest.kt

Maps to checklist section 10.

| Test | Freq |
|---|---|
| `deleteFuture_daily` | Before N visible, N+ gone |
| `deleteFuture_weekly` | Same pattern |
| `deleteFuture_monthly` | Same pattern |
| `deleteFuture_yearly` | Same pattern |
| `deleteFuture_firstOccurrence` | Equals delete all — everything gone |

### combo/EventComboTest.kt

Maps to checklist section 13.

| Test | Scenario |
|---|---|
| `editThis_thenEditAll` | Edit THIS day3 → edit ALL title → day3 exception survives with its own title |
| `deleteThis_thenEditAll` | Delete THIS day5 → edit ALL title → day5 still excluded |
| `editFuture_thenDeleteAllNew` | Edit FUTURE from day4 → delete ALL new series → days 1-3 old series preserved |
| `deleteThis_thenDeleteFuture` | Delete THIS day2 → delete FUTURE day5 → days 1,3,4 remain |
| `crossYear_dailyRepeat` | Create daily on Dec 31 → verify Jan 1 shows it |
| `month31_monthlyRepeat` | Create monthly on 31st → Feb skips, Mar 31 shows |
| `firstOccurrence_editThis` | Edit THIS on first occurrence → exdate added, standalone created |
| `firstOccurrence_deleteFuture` | Delete FUTURE on first → equals delete all |
| `exdateNormalization_timedEvent` | Create timed daily → delete THIS → wait for Beat sync → still hidden (server datetime exdate normalized) |

---

## JVM Unit Tests — RRuleParserTest.kt

Located at `src/test/java/it/expendables/pronext/utils/RRuleParserTest.kt`.

Tests `RRuleParser.getOccurrencesAsStrings()` directly, no emulator needed.

| Test Group | Cases |
|---|---|
| Daily | interval=1, interval=3, with UNTIL, without UNTIL |
| Weekly | interval=1, interval=2, BYDAY=MO,WE,FR, with UNTIL |
| Monthly | interval=1, BYMONTHDAY=31 (short month skip), interval=2 |
| Yearly | interval=1, Feb 29 leap year, with UNTIL |
| Exdates | Single exdate filtered, multiple exdates, exdate on first occurrence |
| UNTIL normalization | `20260602T235959Z` → treated as `20260602` |
| RRULE prefix | With `RRULE:` prefix stripped correctly |
| Edge cases | Empty rrule → empty list, null exdates handled |

---

## pad-testing Skill Updates

### Device cleanup (optional, after 100% pass)

Add an optional step at the end of `/pad-testing`:

```
### Step 7 (optional): Cleanup test device

If all tests passed, ask the user whether to delete the test device:

    python3 manage.py shell -c "
    from pronext.device.models import Device
    Device.objects.filter(pk=$DEVICE_ID).delete()
    "
```

### TestTag additions needed

The following testTags must be added to production code before tests can interact with these elements:

| Component | Proposed testTag | File |
|---|---|---|
| WeekView EventCard | `eventCard_${event.title}` | Already exists |
| NumStepper increment | `numStepper_increment` | `components/NumStepper.kt` |
| NumStepper decrement | `numStepper_decrement` | `components/NumStepper.kt` |
| Repeat "until" toggle | `repeatCard_until_toggle` | `components/RepeatCard.kt` |
| Repeat until date picker | `repeatCard_until_date` | `components/RepeatCard.kt` |
| Weekly day buttons | `repeatCard_day_{SU,MO,...}` | `components/RepeatCard.kt` |

These are non-breaking additions — testTags have no runtime cost.

---

## What's NOT in Scope

| Section | Reason |
|---|---|
| 1-3 (Category, non-repeat CRUD) | Already covered by existing tests |
| 12 (Offline/sync) | Requires airplane mode toggling — manual test |
| 14 (External calendars) | Deferred — needs browser automation for Google/Outlook |
| 15 (Error handling) | Requires network mocking — separate effort |
| `[App]` cross-platform items | Requires Flutter test harness |

---

## Estimated Test Count

| File | Tests |
|---|---|
| EventCreateRepeatTest | ~16 |
| EventEditThisTest | ~6 |
| EventEditAllTest | ~13 |
| EventEditFutureTest | ~9 |
| EventDeleteThisTest | ~5 |
| EventDeleteAllTest | ~3 |
| EventDeleteFutureTest | ~5 |
| EventComboTest | ~9 |
| EventViewExpansionTest | ~3 |
| RRuleParserTest (JVM) | ~20 |
| **Total** | **~89** |
