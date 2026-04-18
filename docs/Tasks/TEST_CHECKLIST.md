# Pad Task Feature - Test Checklist

Task 模块是 Chore 的 rrule 迁移版本，采用 Meal 模块架构（Room DB + 本地 rrule 展开 + SyncStatus 离线优先）。本清单基于原 Flutter Chores 测试清单适配而来，反映了以下关键架构差异：

**Cross-device testing:** Flutter (iOS) 的 Chores 页面现已调用 Task 后端 API (`/app-api/task/`)，因此数据同步类测试需要在 Pad 和 Flutter 双端验证。标记为 **[Flutter]** 的测试项表示需要在 Flutter 端确认数据同步正确。UI 行为类测试仅在 Pad 端执行。

**Key differences from Chore module:**

| Feature | Chore (old) | Task (new) |
| --- | --- | --- |
| Category | Multi-select `category_ids` (1 record, N categories) | Multi-select on create (duplicates N tasks, 1 category each), single-select on edit |
| Time field | `expired_at` (Date) | `due_date` (String) + `due_time` (String?) |
| "Any Day" concept | `expired_at = null` | Not applicable — Task requires `due_date` |
| Repeat expansion | Server-side | Local RRuleParser (`dmfs/lib-recur`) |
| "Late" logic | `showLateChores` filter | Not applicable |
| Data layer | API-only, no local cache | Room DB + offline + SyncStatus |
| `byday` support | Not supported | Supported (`hasByDay = true`) |
| Delete category | API delete | Hide only (toggle visibility) |
| Completions | Server boolean | Local `completeds` comma-separated dates |

> **Convention:** Each test item should be verified against Room DB state and backend API response. "Refresh" means navigating away and back, or killing and restarting the app, to confirm data persistence.

---

## Testing resources

For the /pad-api/ you can use curl with the following headers (replace token and host as needed):

```
Timestamp: 1771382262
Signature: QrUeTCAasexZUG5fU4x9jXY5sdtN3RMZAK+A/bypM7GZTv/la0ZTiDV4JDLrlPe4
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ0b2tlbl90eXBlIjoiYWNjZXNzIiwiZXhwIjoxNzc2NTY1MDY2LCJpYXQiOjE3NzEzODEwNjYsImp0aSI6IjNmZWE4NDI1YjU3MzQ1YmE5NTI1ZjQ5MWI2YmU3ZjgwIiwidXNlcl9pZCI6Ijc3NyIsImFjY291bnQiOiJja2RldmljZTFAcHJvbmV4dHVzYS5jb20iLCJyZWxfdXNlcl9pZCI6Nzc2LCJob3N0IjoiMTAuMC4yLjI6ODAwMCJ9.MMgsmr1bM-ffIkTxrF4DquvbJCyfmMDYnCc1-M5gkUU
```


## 1. Task Category (Profile) CRUD

### 1.1 Create Category ✅ PASS (2026-02-17)

- [x] Create a category with name + color, verify it appears in list
- [x] Create a category and verify the default color is applied if none selected
- [x] Verify at least a name is required (empty name shows error)
- [x] Create multiple categories, verify ordering in list
- [x] Verify duplicate name is rejected by backend (same user)
- [x] After create, verify category syncs to server and appears on other devices
- [x] **[Flutter]** 在 Pad 创建 category 后，Flutter 端刷新确认新 category 出现

> **Fix applied:** Added name labels below category profile circles (Pad + Flutter) — same-letter categories were indistinguishable.

### 1.2 Toggle Category Visibility ✅ PASS (2026-02-17)

- [x] Toggle `hidden` on, verify category disappears from tasks list
- [x] Toggle `hidden` off, verify category reappears in tasks list
- [x] Hidden category is not shown in the category selector when creating/editing tasks
- [x] Visibility toggle persists after app restart (stored via Room + API)
- [x] **[Flutter]** 在 Pad 隐藏/显示 category 后，Flutter 端确认同步更新

### 1.3 Category in Calendar Preview ✅ PASS (2026-02-17)

- [x] Visible categories appear in Calendar page's TasksRow preview
- [x] Hidden categories do NOT appear in Calendar preview
- [x] Tapping a preview card navigates to TasksPage
- [x] **[Flutter]** Flutter 端 Today's Tasks 卡片正确显示对应 category 数据

---

## 2. Non-Recurring Task CRUD

### 2.1 Create Task (No Repeat) ✅ PASS (2026-02-17)

- [x] Create task with content + 1 category + specific date + time
- [x] Create task with content + 1 category + specific date + All Day (no `due_time`)
- [x] Create task with **multiple categories** selected → verify one task per category is created (duplicate tasks, each with single `categoryId`)
- [x] Verify content is required (empty content → Save button disabled)
- [x] Verify at least one category must be selected (no category → Save button disabled)
- [x] Verify default date is current list date when creating
- [x] Verify task appears immediately after save (optimistic insert into Room)
- [x] Verify task syncs to server (check via API or other device)
- [x] **[Flutter]** Flutter 端刷新后确认新 task 出现在对应 category 下

> **Fix applied:** `dueTime` was null when toggling time switch on for new tasks — added default time (current hour + 1, matching Flutter).

### 2.2 Edit Task (No Repeat) ✅ PASS (2026-02-17)

- [x] Change content, verify update
- [x] Change date, verify update
- [x] Switch from specific time to All Day (toggle time off), verify `due_time` becomes null
- [x] Switch from All Day to specific time, verify time picker appears
- [x] Change category (single-select), verify update
- [x] Edit does NOT show change type dialog (no repeat)
- [x] Verify edit syncs to server
- [x] **[Flutter]** Pad 端编辑 task 后，Flutter 端确认内容/日期/分类同步更新

> **Fix applied:** `categoryId` was missing from local Room update in `updateTask()` — category change wasn't reflected until server sync.

### 2.3 Delete Task (No Repeat) ✅ PASS (2026-02-17)

- [x] Delete non-recurring task, verify removal from Room and UI
- [x] Delete does NOT show change type dialog (no repeat)
- [x] Verify delete syncs to server (PENDING_DELETE → sync → hard delete)
- [x] **[Flutter]** Pad 端删除 task 后，Flutter 端确认该 task 消失

### 2.4 Complete Task (No Repeat) ✅ PASS (2026-02-17)

- [x] Tap checkbox to complete, verify UI updates immediately (optimistic)
- [x] Verify completed state persists after app restart (stored in Room `completeds` field)
- [x] Tap checkbox again to uncomplete, verify state toggles back
- [x] Complete via "Mark As Complete" button in edit form
- [x] Verify completion syncs to server
- [x] **[Flutter]** Pad 端完成/取消完成 task 后，Flutter 端确认完成状态同步

---

## 3. Recurring Task — Creation (All Repeat Types)

> Task uses rrule format via RepeatData. Local RRuleParser expands occurrences on the Pad.

### 3.1 Daily Repeat ✅ PASS (2026-02-17)

- [x] Create task: repeat every **1 day**, verify it appears on consecutive days
- [x] Create task: repeat every **3 days**, verify it appears every 3rd day (check days 1–4)
- [x] Create task: repeat every 1 day **with repeat_until**, verify it stops appearing after end date
- [x] Create task: repeat every 1 day **without repeat_until**, verify it continues indefinitely
- [x] Verify rrule is stored correctly in Room (`FREQ=DAILY` — INTERVAL=1 omitted per RFC 5545 default)

> **Fixes applied:** (1) `toResponse()` wasn't populating `repeat` field from rrule — edit form showed no repeat options. (2) Smart `repeat_until` defaults by type (daily +8d, weekly +29d, monthly +1y, yearly +5y). (3) Remember last selected category via MMKV. (4) Consolidated `toRepeatData()` into `TaskEntity`.

### 3.2 Weekly Repeat ✅ PASS (2026-02-17)

- [x] Create task: repeat every **1 week**, verify it appears on the same weekday each week
- [x] Create task: repeat every **2 weeks**, verify it appears biweekly
- [x] Create task: repeat every 1 week **with repeat_until**, verify it stops after end date
- [x] Create task: repeat every 1 week **with byday** (e.g., MO,WE,FR), verify it appears on selected days only

### 3.3 Monthly Repeat ✅ PASS (2026-02-17)

- [x] Create task: repeat every **1 month**, verify it appears on the same date each month
- [x] Create task: repeat every **2 months**, verify correct interval
- [x] Create task on Jan 31 with monthly repeat — months without 31 days correctly skip (RFC 5545 behavior)
- [x] Create task: repeat every 1 month **with repeat_until**, verify it stops after end date

> **Fix applied:** Monthly repeat option switches used wrong font/control style — replaced Checkbox with Switch + RowField.

### 3.4 Yearly Repeat ✅ PASS (2026-02-17)

- [x] Create task: repeat every **1 year**, verify it appears on the same date next year
- [x] Create task on Feb 29 (leap year) with yearly repeat — non-leap years correctly skip (RFC 5545)
- [x] Create task: repeat every 1 year **with repeat_until**, verify it stops after end date

> **Fix applied:** Date nav picker: (1) always opens to today instead of remembering last date; (2) shows year when cross-year.

### 3.5 Repeat Interval Stepper ✅ PASS (2026-02-18)

- [x] Verify stepper increments correctly (1 → 2 → 3...)
- [x] Verify stepper decrements correctly (3 → 2 → 1)
- [x] Verify minimum value is 1 (cannot go below)

### 3.6 Repeat Until ✅ PASS (2026-02-18)

- [x] Toggle repeat_until on, verify date picker appears
- [x] Set repeat_until date, save, verify task does not appear after that date (tested with "All" save type)
- [x] Toggle repeat_until off, verify UNTIL is removed from rrule

### 3.7 Cross-device Sync (Recurring Creation) ✅ PASS (2026-02-18)

- [x] **[Flutter]** Pad 创建每日重复 task 后，Flutter 端确认该 task 出现
- [x] **[Flutter]** Pad 创建带 repeat_until 的 task 后，Flutter 端确认 rrule 数据正确（在截止日期后不显示）
- [x] **[Flutter]** Pad 创建带 byday 的周重复 task 后，Flutter 端确认仅在指定日期显示

---

## 4. Recurring Task — Edit (Change Types)

> All edit tests below should show the change type action sheet with up to 3 options:
> "This task" / "This and future tasks" / "All task"

### 4.1 Edit "This" (change_type: 0) ✅ PASS (2026-02-18)

**Daily repeat:**

- [x] Edit content of one occurrence → verify only that day's instance changes
- [x] Edit time of one occurrence → verify only that day's instance changes
- [x] Verify other days still show the original content/time
- [x] Verify original task's `exdates` now contains this date
- [x] Verify a new non-recurring task is created for this date

**Weekly repeat:**

- [x] Edit content of one weekly occurrence → verify only that instance changes
- [x] Verify next week's occurrence still shows original

**Monthly repeat:**

- [x] Edit content of one monthly occurrence → verify only that month's instance changes
- [x] Verify next month's occurrence still shows original

**Yearly repeat:**

- [x] Edit content of one yearly occurrence → verify only that year's instance changes

> **Fixes applied:** (1) `dueDate` form init used `entity.dueDate` (series start) instead of `occurrenceDate` — new standalone task got wrong `due_date`. (2) RRuleParser removed verbose per-occurrence logging + added `fastForward()` for performance. (3) XDatePicker syncs `selectedDateMillis` and `displayedMonthMillis` when external date prop changes.

### 4.2 Edit "All" (change_type: 1) ✅ PASS (2026-02-18)

**Daily repeat:**

- [x] Edit content → verify all past and future occurrences show new content
- [x] Edit time → verify all occurrences shift to new time
- [x] Add repeat_until → verify series now has an end date
- [x] Remove repeat_until → verify series becomes indefinite again
- [x] Change repeat interval (e.g., every 1 day → every 2 days) → verify new interval applies

**Weekly repeat:**

- [x] Edit content → verify all weekly occurrences update
- [x] Change interval (every 1 week → every 2 weeks) → verify

**Monthly repeat:**

- [x] Edit content → verify all monthly occurrences update

**Yearly repeat:**

- [x] Edit content → verify all yearly occurrences update

**Cross-type changes:**

- [x] Change repeat type (daily → weekly), verify series now follows weekly pattern
- [x] Change repeat type (weekly → monthly), verify series now follows monthly pattern
- [x] Disable repeat entirely (set repeat_every to 0) when editing "All" — verify task becomes non-recurring

> **Fixes applied:** (1) "Edit All" was sending occurrence date as `due_date`, shifting series start — added `userChangedDate` tracking to preserve original unless user explicitly changes. (2) Server `viewset_pad.py` didn't distinguish missing `repeat` from explicit `null` — used sentinel to allow clearing rrule via `repeat: null`.

### 4.3 Edit "This and Future" (change_type: 2)

**Daily repeat:** ✅ PASS (2026-02-19)

- [x] Edit content on day N → verify days before N still have old content
- [x] Verify days from N onward have new content
- [x] Verify a new recurring task is created starting from day N
- [x] Verify original task's `repeat_until` is set to day N-1

> **Fixes applied:** (1) Weekly byday not including start date's day-of-week on save — `buildRepeatData()` now syncs computed byweekday back. (2) Extracted `availableChangeTypes()` as shared change type logic for Task/Meal (replaces manual isOriginalEvent/hideThisOnly booleans). (3) Task save now correctly shows "This and future" option for non-first occurrences.

**Weekly repeat:** ✅ PASS (2026-02-19)

- [x] Edit content on week N → verify previous weeks unchanged, this and future weeks updated
- [x] Verify new series starts from this occurrence

**Monthly repeat:** ✅ PASS (2026-02-19)

- [x] Edit content on month N → verify previous months unchanged
- [x] Verify new series starts from this month's occurrence

**Yearly repeat:** ✅ PASS (2026-02-19)

- [x] Edit content on year N → verify previous years unchanged

**Mixed edits:** ✅ PASS (2026-02-19)

- [x] Edit "this and future" and change repeat interval → verify old series ends, new series uses new interval
- [x] Edit "this and future" and change time → verify old series keeps old time, new series uses new time

### 4.4 Cross-device Sync (Recurring Edit)

- [ ] **[Flutter]** Pad 编辑 "This" 后，Flutter 端确认仅该日实例被修改
- [ ] **[Flutter]** Pad 编辑 "All" 后，Flutter 端确认所有实例内容更新
- [ ] **[Flutter]** Pad 编辑 "This and Future" 后，Flutter 端确认旧系列不变、新系列生效

---

## 5. Recurring Task — Delete (Change Types)

> Delete of recurring task should show the same 3-option action sheet.

### 5.1 Delete "This" (change_type: 0) ✅ PASS (2026-02-19)

**Daily repeat:**

- [x] Delete one day's occurrence → verify that day no longer shows the task
- [x] Verify previous and subsequent days still show the task
- [x] Verify backend adds `repeat_flag` date to `exdates`
- [x] Delete the **original/first** occurrence → verify it's excluded but series continues

**Weekly repeat:**

- [x] Delete one week's occurrence → verify other weeks unaffected

**Monthly repeat:**

- [x] Delete one month's occurrence → verify other months unaffected

**Yearly repeat:**

- [x] Delete one year's occurrence → verify other years unaffected

### 5.2 Delete "All" (change_type: 1) ✅ PASS (2026-02-19)

- [x] Delete all → verify task disappears from all days
- [x] Verify task record is marked PENDING_DELETE in Room, then removed after sync
- [x] Verify deletion reflected on server

> **Fix applied:** Non-recurring task delete was using `TaskChangeType.THIS` (0) instead of `TaskChangeType.ALL` (1), which could cause server to misinterpret as "add exdate". Fixed to use `ALL`.

### 5.3 Delete "This and Future" (change_type: 2) ✅ PASS (2026-02-19)

**Daily repeat:**

- [x] Delete "this and future" on day N → verify days before N still show task
- [x] Verify day N and all future days no longer show the task
- [x] Verify backend sets `repeat_until` to day N-1

**Weekly repeat:**

- [x] Delete "this and future" on week N → verify previous weeks preserved

**Monthly repeat:**

- [x] Delete "this and future" on month N → verify previous months preserved

**Yearly repeat:**

- [x] Delete "this and future" on year N → verify previous years preserved

**Edge case:**

- [x] Delete "this and future" on the **first occurrence** → should behave like "Delete All" (nothing remains)

### 5.4 Cross-device Sync (Recurring Delete)

- [ ] **[Flutter]** Pad 删除 "This" 后，Flutter 端确认仅该日实例消失，其余不变
- [ ] **[Flutter]** Pad 删除 "All" 后，Flutter 端确认所有实例消失
- [ ] **[Flutter]** Pad 删除 "This and Future" 后，Flutter 端确认仅未来实例消失

---

## 6. Recurring Task — Complete/Uncomplete

### 6.1 Complete Individual Occurrences ✅ PASS (2026-02-19)

- [x] Complete day 1 of daily task → verify day 1 is checked, day 2 is not
- [x] Complete day 2 of daily task → verify day 1 AND day 2 are checked independently
- [x] Uncomplete day 1 → verify day 1 unchecked, day 2 still checked
- [x] Verify `completeds` field in Room contains correct comma-separated date strings
- [x] Complete a weekly occurrence → verify other weeks unaffected
- [x] Complete a monthly occurrence → verify other months unaffected
- [x] Complete a yearly occurrence → verify other years unaffected

### 6.2 Complete via Edit Page ✅ PASS (2026-02-19)

- [x] Open recurring task in edit → tap "Mark As Complete" → verify direct complete (no change type dialog)
- [x] Verify completion via edit page matches checkbox behavior
- [x] "Mark As Not Complete" for already completed occurrence

### 6.3 Complete Original Occurrence ✅ PASS (2026-02-19)

- [x] Complete the **first/original** occurrence → verify it's marked done
- [x] Verify subsequent occurrences are still incomplete

### 6.4 Cross-device Sync (Recurring Complete)

- [ ] **[Flutter]** Pad 完成某日实例后，Flutter 端确认该日完成状态同步
- [ ] **[Flutter]** Pad 取消完成后，Flutter 端确认状态回退

---

## 7. List View & Navigation

### 7.1 Date Navigation ✅ PASS (2026-02-19)

- [x] Tap "Next" → verify date advances by 1 day and tasks reload
- [x] Tap "Previous" → verify date goes back by 1 day and tasks reload
- [x] Tap "Today" → verify returns to today's date
- [x] "Today" button visual indicator when already on today
- [x] Date header shows correct format (EEE, MMM dd)
- [x] Date picker opens and allows jumping to any date

### 7.2 Category Grouping ✅ PASS (2026-02-19)

**Landscape mode (LazyRow):**

- [x] Tasks grouped by category in horizontal scrollable cards
- [x] Each category card shows: color avatar, name, progress (X/Y), progress bar
- [x] Progress bar fills based on completed count
- [x] Tapping a task item opens edit form

**Portrait mode (HorizontalPager):**

- [x] Tasks grouped by category in swipeable pages (2 per page)
- [x] Swipe left/right to navigate between pages
- [x] Each card shows correct category data

### 7.3 Time & Repeat Display on Task Item ✅ PASS (2026-02-19)

**Non-recurring task:**

- [x] All day (no `due_time`) → no time badge shown
- [x] Specific time → formatted time e.g. "1:10 PM" (12-hour format)

**Recurring task:**

- [x] Repeat description shown from rrule parsing (e.g., "Daily", "Every 2 weeks", "Weekly")
- [x] Time shown alongside repeat description if `due_time` is set

### 7.4 Empty States ✅ PASS (2026-02-19)

- [x] Category with no tasks for today → shows "Nothing to do today."
- [x] All tasks completed and hideCompleted on → shows "All done!"
- [x] No categories at all → tasks page shows nothing (no crash)

> **Fix applied:** Updated empty state text and added emoji icons (☕/🎉) for friendlier UX.

---

## 8. Filtering

### 8.1 Hide Completed ✅ PASS (2026-02-19)

- [x] Toggle "Hide Completed" on → completed tasks disappear from list
- [x] Toggle "Hide Completed" off → completed tasks reappear
- [x] Filter persists after navigating away and returning
- [x] Filter persists across app restart (stored via MMKV per-user key)
- [x] Progress bar still shows total count (including hidden completed tasks)

### 8.2 Filter Dropdown ✅ PASS (2026-02-19)

- [x] Filter dropdown accessible from header
- [x] Filter state reflected in UI indicator

---

## 9. Offline & Sync (New — Room DB Architecture)

> This entire section is new, testing the Room DB + SyncStatus offline-first architecture.

### 9.1 Optimistic Create ✅ PASS (2026-02-19)

- [x] Create a task while online → verify task appears immediately in UI with negative local ID
- [x] Verify task syncs to server and local ID is replaced with server ID
- [ ] **[Flutter]** Pad 创建 task 同步后，Flutter 端确认该 task 出现
- [x] Create a task while offline → verify task appears immediately (PENDING_CREATE)
- [x] Restore network → verify task syncs on next heartbeat and ID updates
- [ ] **[Flutter]** Pad 离线创建 task 恢复网络后，Flutter 端确认数据同步

### 9.2 Optimistic Complete ✅ PASS (2026-02-19)

- [x] Toggle complete while online → verify UI updates immediately, server call follows
- [x] Toggle complete while offline → verify UI updates immediately
- [x] Restore network → verify completion syncs
- [x] Rapidly toggle complete/uncomplete → verify final state is consistent after sync

> **Fix applied:** Offline complete was reverting because API failure caused both Room DB and UI to revert. Fixed by keeping local `completeds` change and queuing a `PendingComplete` action for retry on next sync, instead of marking as PENDING_UPDATE (which would send wrong API).

### 9.3 Optimistic Delete ✅ PASS (2026-02-19)

- [x] Delete while online → task disappears immediately, PENDING_DELETE in Room, then hard-deleted after sync
- [x] Delete while offline → task disappears from UI immediately
- [x] Restore network → verify deletion syncs

> **Fix applied:** Offline delete was blocking on API timeout, keeping dialog open. Fixed by optimistically removing from Room immediately and returning success. On API failure, re-inserts as PENDING_DELETE for sync later.

### 9.4 Version Conflict (409) ⏭️ SKIPPED

- [ ] Edit task on Pad → simultaneously edit same task on another device → verify 409 triggers re-sync from server
- [ ] After conflict resolution, verify local Room data matches server truth

> **Skipped:** `TaskUpdateRequest` does not send `version` field, so server never triggers 409. Needs future work to add version tracking.

### 9.5 DEVICE_MISMATCH (403) ⏭️ SKIPPED

- [ ] Simulate DEVICE_MISMATCH error (e.g., re-auth on different device) → verify database is destroyed and re-synced
- [ ] Verify "Syncing task data..." HUD appears during re-sync
- [ ] After re-sync, verify all data is correct

> **Skipped:** Requires special device setup to simulate.

### 9.6 Initial Sync ✅ PASS (2026-02-19)

- [x] Fresh login → verify all tasks and categories sync from server to Room
- [x] Logout → verify Room database is destroyed
- [x] Re-login → verify fresh sync occurs

> **Verified:** Device reset confirmed both Meal and Task Room databases are closed/destroyed.

### 9.7 Beat System Sync ⏭️ SKIPPED

- [ ] Modify task on another device → verify Beat flag triggers sync on Pad
- [ ] **[Flutter]** 在 Flutter 端修改 task → 验证 Pad 端 Beat 触发同步并更新
- [ ] Modify category on another device → verify category sync triggered
- [ ] **[Flutter]** 在 Flutter 端修改 category → 验证 Pad 端同步更新
- [ ] Verify heartbeat polling interval triggers refresh correctly

> **Skipped:** Requires multi-device setup.

### 9.8 Pending Sync Queue ⏭️ SKIPPED

- [ ] Create task offline → delete it offline before sync → verify no orphan server record
- [ ] Create task offline → edit it offline → verify only final state syncs
- [ ] Multiple offline operations → restore network → verify all sync in correct order

> **Skipped:** Requires reliable offline simulation on real device.

---

## 10. Navigation & Settings Integration

### 10.1 Sidebar / Bottom Navigation ✅ PASS (2026-02-19)

- [x] "Tasks" tab in sidebar (landscape) navigates to TasksPage
- [x] "Tasks" tab in bottom nav (portrait) navigates to TasksPage
- [x] Active state indicator shows when on TasksPage
- [x] Icon displays correctly (icon_chores drawable)

> **Also verified:** Migration propagation fix — after device reset and re-activate, Tasks menu appears correctly (sibling device migration check).

### 10.2 Calendar Page Integration ✅ PASS (2026-02-19)

- [x] Task preview row appears on Calendar page (when setting enabled)
- [x] TaskPreviewCards show correct category names and progress
- [x] Tapping a preview card navigates to TasksPage
- [x] "Task" option in Calendar AddButton opens TaskForm
- [x] Setting "Preview tasks in Calendar view" toggles the preview row

### 10.3 Settings Page ✅ PASS (2026-02-19)

- [x] "Tasks" tab appears in Settings
- [x] "Preview tasks in Calendar view" toggle works and persists

### 10.4 Page Lifecycle ✅ PASS (2026-02-19)

- [x] Navigate to Tasks → edit → save → return to Tasks → verify refresh
- [x] Navigate to Tasks → manage categories → hide/unhide → return → verify refresh
- [x] App backgrounded and resumed → verify data refreshes via Signal/Beat
- [x] Day changes while app is open → verify date auto-updates

---

## 11. Edge Cases & Special Scenarios

### 11.1 Recurring + Edit Combinations ✅ PASS (2026-02-19)

- [x] Create daily task → edit "this" on day 3 → then edit "all" the original → verify day 3's standalone task is unaffected
- [x] Create daily task → delete "this" on day 5 → edit "all" to change content → verify day 5 is still excluded
- [x] Create daily task → edit "this and future" from day 4 → delete "all" the **new** series → verify days 1–3 of old series remain
- [x] Create daily task → complete day 2 → edit "all" to change time → verify day 2 completion is preserved

### 11.2 Boundary Dates ✅ PASS (2026-02-19)

- [x] Task on Dec 31 with daily repeat → verify Jan 1 shows correctly (year rollover)
- [x] Monthly task starting Jan 31 → Feb (28/29), Mar 31, Apr 30 — verify correct handling
- [x] Yearly task on Feb 29 → verify non-leap year behavior
- [x] repeat_until set to today → verify today shows but tomorrow doesn't

### 11.3 Large Data ✅ PASS (2026-02-19)

- [x] 10+ categories → verify LazyRow/Pager scrolls correctly
- [x] 50+ tasks in one day → verify list performance
- [x] Category with very long name (100 chars) → verify truncation/layout

### 11.4 Rapid Operations ✅ PASS (2026-02-19)

- [x] Rapidly tap complete/uncomplete checkbox → verify final state is consistent
- [x] Create task, immediately navigate back → verify task was saved
- [x] Delete task, immediately navigate back → verify task is gone

### 11.5 Concurrent Access ⏭️ SKIPPED

- [ ] Modify task on Pad while another device also has tasks open → verify Beat system triggers sync
- [ ] Hide category on one device → verify other device updates on next sync
- [ ] **[Flutter]** Pad 端修改 task → Flutter 端确认 Beat 触发后数据更新
- [ ] **[Flutter]** Flutter 端修改 task → Pad 端确认 Beat 触发后数据更新
- [ ] **[Flutter]** 双端同时编辑同一 task → 确认 409 冲突正确处理，最终数据一致

> **Skipped:** Requires multi-device setup on test server.

---

## Test Execution Notes

- **Backend required**: All tests require a running Django backend at the configured API endpoint
- **Flutter cross-device**: Flutter (iOS) Chores 页面已调用 Task 后端 API，标记 **[Flutter]** 的测试项需在 Flutter 端验证同步
- **Device context**: Tests run in the context of a specific device_id (from Pad auth)
- **Offline testing**: To test offline scenarios, toggle airplane mode on the Pad device
- **Data cleanup**: Consider resetting task data between test runs (Settings → destroy database, or logout/login)
- **Date sensitivity**: Some tests are date-sensitive ("today" logic) — note the test execution date
- **Repeat validation**: For recurring task tests, navigate to multiple dates to verify the pattern — don't just check one day
- **Room DB inspection**: Use Android Studio's Database Inspector to verify Room state during debugging
