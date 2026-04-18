# Chores Module — Product Requirements Document

## Overview

Chores (家务) module allows users to create, manage, and track recurring household tasks. Each chore belongs to one or more **Profiles** (categories), and supports flexible repeat patterns (daily, weekly, monthly, yearly).

The Flutter version is a full replacement of the H5 (Vue) version, which will be retained only for legacy app compatibility.

---

## Category (Profile)

### Basic Rules

- A category has: **name** (max 80 chars), **color** (hex, default `#5584FF`), **hidden** flag.
- Category names must be unique per user; duplicates are rejected by backend.
- Deleting a category also deletes chores that **only** belong to that category. Chores belonging to multiple categories survive (only the deleted category_id is removed).

### Hidden Category Behavior

- A hidden category is **completely invisible**:
  - Its chores do not appear on the main chores list page.
  - It does not appear in the category selector when creating or editing chores.
- To access chores under a hidden category, the user must first unhide it.

---

## Chore

### Multi-Category Creation

- When creating a new chore with **multiple categories selected**, the backend creates **one independent chore per category**.
- Each copy is a separate record with its own `id`, linked to a single `category_id`.
- Completing, editing, or deleting one copy does **not** affect the others.

### Default Date

- When creating a new chore, the default date is the **current date shown on the chores list page** (end-of-day 23:59:59), not a fixed "tomorrow".

---

## Time Badge Display

The time badge is shown next to each chore item to indicate its time/schedule. The display logic follows a priority order — the **first matching rule wins**.

### Decision Logic (priority order)

| # | Condition | Badge Text | Example |
|---|-----------|------------|---------|
| 1 | `expired_at == null` (Any Day chore) | `"Any day"` | Any day |
| 2 | Active repeat, `repeat_every == 1` | `"{Type}"` or `"{Type} at {time}"` | Daily, Weekly at 9:00 AM |
| 3 | Active repeat, `repeat_every > 1` | `"Every {N} {units}"` or `"Every {N} {units} at {time}"` | Every 2 days, Every 3 weeks at 1:10 PM |
| 4 | Same day + all day (`expired_at` time == 23:59:59) | `"All day"` | All day |
| 5 | Same day + specific time | `"{h:mm a}"` | 1:10 PM |
| 6 | Past day + expired + showLateChores on | Late description (see below) | 2 days late |
| 7 | Past day + expired + showLateChores off | `""` (hidden) | — |

**"Active repeat"** means `repeat_every > 0` AND (`repeat_until == null` OR `repeat_until >= current viewing date`).

### Repeat Type Mapping

| `repeat_type` | `repeat_every == 1` | `repeat_every > 1` |
|---------------|---------------------|---------------------|
| 0 (daily) | Daily | Every {N} days |
| 1 (weekly) | Weekly | Every {N} weeks |
| 2 (monthly) | Monthly | Every {N} months |
| 3 (yearly) | Yearly | Every {N} years |

If the chore has a specific time (not all-day), append `" at {h:mm a}"` (e.g., "Daily at 9:00 AM").

### Late Description Format

For **all-day** chores (only count whole days):

| Duration | Text |
|----------|------|
| 1 day | 1 day late |
| N days | {N} days late |

For **timed** chores (use exact time difference):

| Duration | Text |
|----------|------|
| < 1 minute | Just overdue |
| 1 minute | 1 minute late |
| 2–59 minutes | {N} minutes late |
| 1 hour | 1 hour late |
| 2–23 hours | {N} hours late |
| 1+ days | {N} days late |

### All Day Detection

All-day is determined by checking if `expired_at`'s time portion is `23:59:59`. No separate `is_all_day` field is needed — this is a shared convention across backend, Pad, and Flutter.

### "Any Day" Chore Behavior

- `expired_at = null`, non-recurring.
- Appears on **every day** in the chore list.
- Completion is global: completing it on any day marks it as complete everywhere.
- Badge always shows `"Any day"`.

---

## Navigation Flow

### List → Detail → Edit

```text
Chore List → tap item → /choreDetail (read-only)
                            ├── "..." → Edit → /choreEdit → Save → back to detail
                            ├── "..." → Delete → confirm → back to list
                            └── Mark Complete → toggle → back to list

FAB → /choreEdit (add mode) → Save → back to list
```

### Detail Page — Reactive State

- The detail page reads chore data **reactively from the manager's `RxList`** (single source of truth).
- It does **not** make a separate API call to fetch detail.
- After edit/save, the manager calls `refresh()` which updates the `RxList`; the detail page auto-rebuilds via `Obx`.

### Auto-Pop on Chore Not Found

- If the chore is no longer in the current list (e.g., its date was changed to a different day), the detail page **automatically pops back** to the chore list.
- This is detected by: `_chore == null` (not found in `RxList`) AND `isLoading == false` (list has finished loading).

### Mark Complete Behavior

- Uses optimistic update: mutates the chore object in the `RxList` immediately, then sends the API call.
- On API failure, rolls back the mutation.
- After toggling, navigates back to the chore list.

---

## Notes

_This document is being built incrementally during testing. Additional sections will be added as features are verified._
