# Permanent Delete for Device (Calendar Account)

**Status:** Draft
**Date:** 2026-04-19
**Owner:** ck

## Problem

Today the only "delete" option on a calendar is soft-delete: `UserDeviceRel.removed = True`. The `Device`, its `device_user` (a `User` row), and all associated data (Events, Photos, Todos, Meals, Categories, SyncedCalendars) stay in the database. Because `User.username` carries the calendar name and is unique, the name is never released even after the user "deletes" the calendar. This surfaces as issue #10 — `IntegrityError` on `register` when a user tries to reuse a name — and forces users to pick new names rather than reclaim old ones.

Sharees have a second papercut: "Remove" soft-deletes their rel, but `find-existing` is gated on `is_owner=True`, so they can't self-restore. The soft step buys them nothing and leaves dead rows.

## Goals

- Let owners permanently delete a calendar: cascade the `device_user` and all its data, freeing the username.
- Let sharees cleanly leave (hard-delete their own rel) and force re-invite for re-access.
- Keep soft-delete (`Remove`) as the safe default for owners.
- Keep the request latency bounded — photo cascade is the slow part and must not block the web worker.

## Non-goals

- Changing the existing soft-delete / `find-existing` restore flow (already fixed for issue #10).
- Hard-deleting the physical `PadDevice` record — that's hardware, SN survives via `SET_NULL`.
- A trash/undo window for permanent delete. User is told it's irreversible; we respect that.

## Design

### Dialog states (app — `manage_calendars.dart`)

**Owner, no active sharees** — 3-action `CupertinoAlertDialog`:
- Title: `Delete "<name>"?`
- Body: `Remove hides this calendar and lets you restore it later. Permanently Delete erases all events, photos, todos, and meals, and frees the name.`
- Actions: Cancel / **Remove** / **Permanently Delete** (destructive)

**Owner, has active sharees** — same dialog, Permanently Delete disabled:
- Body adds: `Stop sharing with <N> user(s) before you can permanently delete.`

**Owner taps Permanently Delete** — second `CupertinoAlertDialog`:
- Title: `Really delete "<name>"?`
- Body: `This will erase all calendar data for this account. This cannot be undone.`
- Actions: Cancel / **Delete Everything** (destructive)

**Sharee** — 2-action `CupertinoAlertDialog`:
- Title: `Stop sharing "<name>"?`
- Body: `You'll need the owner to invite you again to regain access.`
- Actions: Cancel / **Stop Sharing** (destructive)

Client branches on `Device.isOwner` (already in `/device/list` payload). `Device.sharedWith.length > 0` drives the disabled state. Backend 403/409 responses act as a safety net for races.

### Backend endpoints

| Endpoint | Actor | Behavior |
|---|---|---|
| `POST /device/{pk}/remove` | owner or sharee | (unchanged) Soft-delete caller's `UserDeviceRel`. Reversible via `find-existing` (owner only). |
| `POST /device/{pk}/destroy` (new) | owner only | Hard-delete `device_user` → cascade `Device`, `UserDeviceRel`s (including soft-removed), `Event`, `Todo`, `Meal`, `Category`, `SyncedCalendar`, `Photo.Media` DB rows. `PadDevice.device` goes `NULL`. S3 cleanup handed off to Celery. |
| `POST /device/{pk}/leave` (new) | sharee only | Hard-delete caller's own `UserDeviceRel` row. |

**Guards:**
- `destroy`: 403 if caller's rel has `is_owner=False`; 409 if `UserDeviceRel.filter(device=pk, removed=False).exclude(user=me).exists()` (active sharees present). Soft-removed sharees (`removed=True`) do not block — they cascade away silently.
- `leave`: 403 if caller's rel has `is_owner=True`; 404 if no rel exists.

### Photo cascade strategy

Cascade via `device_user.delete()` normally fires `Media.post_delete` per row, which synchronously calls `storage.delete(path)` on S3. For a heavy user (hundreds of photos) this will exceed request timeouts and leave partial state.

Approach:

```python
# destroy view
paths = []
for m in Media.objects.filter(user=device_user).only('url', 'media_type'):
    paths.extend(m.get_all_storage_paths())

with _suppress_media_s3_signal(), transaction.atomic():
    device_user.delete()  # pure-DB cascade

if paths:
    delete_s3_media_task.delay(paths)

return Response(status=204)
```

- `_suppress_media_s3_signal()` — context manager that disconnects `delete_media_from_s3` from `post_delete` for the duration, then reconnects. The disconnect is process-wide — concurrent Media deletes from other threads will also skip the S3 signal while destroy() runs. Acceptable because destroy() is rare and any resulting orphans are handled by the reconciliation safety net.
- `delete_s3_media_task` — new Celery task, `bind=True, max_retries=3, default_retry_delay=30`. Iterates paths, calls `S3Storage().delete`, collects failures, retries if any. Matches the existing `cleanup_unused_categories_task` pattern.

**Why Celery over `threading.Thread(daemon=True)`:** durability across web-worker restarts, built-in retries, visibility, decoupling. The legacy `bulk_delete_with_files` daemon-thread pattern is kept unchanged but not copied for new code.

**Side-effect cleanup that is automatic:**
- Redis beat flags (`:1:beat1:*`, `:1:beat:synced_calendar:*`) expire in 15 s.
- Activation code cache keys (`code:*:device:{id}:user:{id}`) expire with configured TTL.
- `BindRecord` has `CASCADE` on `device`, so audit rows go away with the device (acceptable; the trail is tied to the device).

### Client-side details

- **Manage Calendars page** (`app/lib/src/page/calendar/manage_calendars.dart`): swipe-to-delete entry point stays the same; `_confirmDeleteDevice` becomes a branch on `device.isOwner` and `device.sharedWith.length`.
- **`DeviceManager`**: add `destroyDevice(id)` → `POST /device/{id}/destroy`; `leaveDevice(id)` → `POST /device/{id}/leave`. Existing `deleteDevice` (soft `remove`) stays.
- On 409 from `destroy`: show toast `Someone else was added to this calendar — refresh and try again.` then trigger the existing `_onRefresh` (see pull-to-refresh spec already in place).

### Error model

- `destroy` 403: caller not owner. Body `{msg: {default: "Only the owner can permanently delete."}}`.
- `destroy` 409: active sharees. Body `{msg: {default: "Stop sharing first.", active_sharee_count: N}}`.
- `leave` 403: caller is owner. Body `{msg: {default: "Owners cannot leave; use Delete instead."}}`.
- `leave` 404: no rel. Body `{msg: {default: "Device not found."}}`.

## Testing

**Backend — `pronext.device.tests`:**

`DeviceDestroyAPITest`
- `test_destroy_owner_no_sharees_cascades_all`: 204; `User`, `Device`, `UserDeviceRel`, `Event`, `Todo`, `Photo.Media`, `Meal`, `Category`, `SyncedCalendar` for that `device_user` all gone; `PadDevice` row survives with `device=NULL`; registering a new device with the same name succeeds.
- `test_destroy_blocked_by_active_sharee`: 409, no rows deleted.
- `test_destroy_ignores_soft_removed_sharees`: 204, soft-removed rel cascades away.
- `test_destroy_as_sharee_returns_403`: 403, no rows deleted.
- `test_destroy_bypasses_s3_signal_and_enqueues_task`: mock `storage.delete` and `delete_s3_media_task.delay`; assert `storage.delete` not called during the request, `delete_s3_media_task.delay` called once with expected paths.

`DeviceLeaveAPITest`
- `test_leave_sharee_hard_deletes_rel`: sharee 204; their rel row gone; owner's rel and Device intact.
- `test_leave_as_owner_returns_403`.
- `test_leave_when_no_rel_returns_404`.

`DeleteS3MediaTaskTest`
- `test_task_deletes_all_paths_on_success`: mock `storage.delete`, assert called per path, task returns clean.
- `test_task_retries_on_failure`: first two calls raise, third succeeds; assert `self.retry` called up to `max_retries`.
- `test_task_gives_up_after_max_retries`: all calls raise; assert final failure logged, no infinite loop.

**App — manual:**
- Owner, no sharees: 3-button dialog → Permanently Delete → second confirm → row disappears → create same name succeeds.
- Owner with sharees: Permanently Delete disabled; Remove still works.
- Sharee: 2-button dialog (Cancel / Stop Sharing) → row disappears.
- Regression: Owner Remove + `find-existing` restore path still works.

## Rollout

1. Land backend: endpoints + task + signal-suppress helper + tests.
2. Land app: dialog branching + new API calls. Feature works end-to-end once deployed to any env.
3. No migration required (schema unchanged).
4. No feature flag — behavior change is opt-in (user explicitly chooses Permanently Delete or Stop Sharing).

## Risks

- **Orphan S3 files** if Celery queue is down when `destroy` runs. Mitigation: task retries; operator-run reconciliation script (out of scope).
- **Shared cascade surprise** is blocked by guard (409). Race window between pre-check and POST is narrow; backend 409 handles it.
- **Accidental permanent delete** mitigated by the second confirm dialog (owner) and by Remove-as-default.
