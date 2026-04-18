# Task Module Release Plan

## Overview

Release the new Task module (replacing Chores) across the full stack without affecting existing users.
The migration uses a **silent auto-migration + post-notification** approach.

## Migration Strategy

```
User opens upgraded App
        │
        v
  ┌─────────────────────┐
  │ Check Device         │
  │ meta_data.migrations │
  │ .chore_to_task       │
  └──────────┬──────────┘
             │
     ┌───────┴───────┐
     │ exists?       │
     ▼               ▼
   [Yes]           [No]
   Skip        ┌──────────┐
               │ Call      │
               │ POST      │
               │ /migrate  │
               └─────┬─────┘
                     │
                     v
              ┌──────────────┐
              │ Server-side  │
              │ chore->task  │
              │ migration    │
              └──────┬───────┘
                     │
                     v
              ┌──────────────┐
              │ Set Beat:    │
              │ task_cate=T  │
              │ task=T       │
              └──────┬───────┘
                     │
                     v
              ┌──────────────┐
              │ Pad picks up │
              │ via heartbeat│
              │ → init Task  │
              │   Room DB    │
              └──────────────┘
```

**Key principle:** Old users on old App/Pad versions continue using Chore APIs normally. No breaking changes to existing endpoints.

---

## Device.meta_data JSONField Design

Add a `JSONField` to `Device` model for flexible metadata storage:

```python
# pronext/device/models.py
class Device(models.Model):
    ...
    meta_data = models.JSONField(default=dict, blank=True)
```

### Format

```json
{
    "migrations": {
        "chore_to_task": {
            "at": "2026-02-17T15:30:00Z",
            "categories": 5,
            "tasks": 42
        }
    }
}
```

### Design Decisions

| Aspect | Decision | Reason |
|---|---|---|
| Key exists = migrated | `"chore_to_task" in meta_data.get("migrations", {})` | No separate boolean needed |
| Store counts | `categories`, `tasks` | Debugging + admin visibility |
| ISO timestamp | `at` | Know when migration happened |
| Top-level `migrations` namespace | Keeps meta_data extensible | Future: device preferences, feature flags, etc. |

### Django ORM Queries

```python
# Check if migrated
Device.objects.filter(meta_data__migrations__chore_to_task__isnull=False)

# Not yet migrated
Device.objects.filter(
    Q(meta_data__migrations__chore_to_task__isnull=True) |
    Q(meta_data={})
)
```

---

## Implementation Steps

### Step 1: Backend — Device meta_data + Migration API

**1a. Add meta_data field to Device model**

```python
# pronext/device/models.py
meta_data = models.JSONField(default=dict, blank=True)
```

Create and run migration: `python manage.py makemigrations device`

**1b. Create migration API endpoint**

New endpoint in `pronext/task/viewset_app.py`:

```
POST /app-api/task/device/{device_id}/migrate
```

Logic:
1. Check `device.meta_data` — if `chore_to_task` key exists, return 200 with `{"already_migrated": true}`
2. Call existing `migrate_chores_to_tasks` management command logic (extract to a reusable function)
3. Write migration result to `device.meta_data`:
   ```python
   device.meta_data.setdefault("migrations", {})
   device.meta_data["migrations"]["chore_to_task"] = {
       "at": timezone.now().isoformat(),
       "categories": num_categories,
       "tasks": num_tasks,
   }
   device.save(update_fields=["meta_data"])
   ```
4. Set Beat flags: `beat.should_refresh_task_cate(True)`, `beat.should_refresh_task(True)`
5. Return 200 with migration stats

**1c. Migration status check API**

```
GET /app-api/task/device/{device_id}/migration-status
```

Returns:
```json
{
    "migrated": true,
    "migration_info": {
        "at": "2026-02-17T15:30:00Z",
        "categories": 5,
        "tasks": 42
    }
}
```

Or if not migrated:
```json
{
    "migrated": false,
    "has_chores": true,
    "chore_count": 42
}
```

---

### Step 2: Go Heartbeat — Add task/task_cate fields

**Files to modify:**

**a) `heartbeat/beat.go` — Beat struct**

```go
type Beat struct {
    ...
    MealRecipe   bool   `json:"meal_recipe"`
    Meal         bool   `json:"meal"`
    TaskCate     bool   `json:"task_cate"`     // NEW
    Task         bool   `json:"task"`          // NEW
}
```

**b) `heartbeat/handlers.go` — HeartbeatData struct**

```go
type HeartbeatData struct {
    ...
    MealRecipe  bool    `json:"meal_recipe"`
    Meal        bool    `json:"meal"`
    TaskCate    bool    `json:"task_cate"`     // NEW
    Task        bool    `json:"task"`          // NEW
    AccessToken *string `json:"access_token,omitempty"`
}
```

Update the `heartbeatHandler` function to map `beat.TaskCate` → `data.TaskCate` and `beat.Task` → `data.Task`.

**Note:** Since Beat is stored as JSON in Redis (shared between Django and Go), adding fields is backward-compatible. Old Beat entries without these fields will deserialize as `false` (Go zero value).

---

### Step 3: Flutter App — Auto-Migration Flow

**Migration trigger point:** When a user selects/enters a device in the App.

**Flow:**

```dart
// In device selection / task manager init
Future<void> checkAndMigrate(int deviceId) async {
  final status = await api.get('task/device/$deviceId/migration-status');
  if (status['migrated']) return;  // Already done

  if (status['has_chores'] && status['chore_count'] > 0) {
    // Silent migration
    await api.post('task/device/$deviceId/migrate');
    // Show "What's New" notification after migration completes
    showWhatsNewNotification();
  }
}
```

**What's New notification content:**
- "Chores has been upgraded to Tasks"
- Brief bullet points: rrule improvements, faster sync, offline support on Pad
- Dismissible, shown once

**Files to modify:**
- `mobile/lib/src/manager/task.dart` — Add migration check on init
- `mobile/lib/src/page/task/` — What's New dialog component

---

### Step 4: Pad — Auto-Detection + Switch

The Pad does NOT trigger migration itself. It detects migration has happened via:

1. **Beat signal**: When migration sets `task=true` + `task_cate=true`, Pad receives these in heartbeat
2. **On heartbeat with task flags**: Pad initializes TaskDatabase, syncs categories and tasks from server
3. **Navigation switch**: Once Task data is loaded, hide Chore sidebar entry, show Task entry

**Alternative detection** (if Pad restarts before Beat expires):
- On Pad startup, call `GET /pad-api/task/category/list`
- If response is non-empty, Task module is active → initialize TaskDatabase

**Files to modify:**
- `pad/.../modules/common/Managers.kt` — Add `task`/`task_cate` to Beat data class
- `pad/.../modules/task/TaskManager.kt` — Signal handling for Beat flags
- `pad/.../common/Page.kt` — Conditional navigation (Chore vs Task)

---

### Step 5: Admin Visibility

**Django Admin additions:**

```python
# pronext/device/admin.py — Update DeviceAdmin
class DeviceAdmin(admin.ModelAdmin):
    list_display = [..., 'is_task_migrated']
    readonly_fields = ['meta_data']

    def is_task_migrated(self, obj):
        return bool(obj.meta_data.get('migrations', {}).get('chore_to_task'))
    is_task_migrated.boolean = True
    is_task_migrated.short_description = 'Task Migrated'
```

---

## Deployment Order

```
 Phase A: Backend prep (no user impact)
 ─────────────────────────────────────────
 1. Deploy Django: Device.meta_data migration
 2. Deploy Django: Migration API + status API
 3. Deploy Go heartbeat: task/task_cate fields
 4. Verify: Beat flags flow end-to-end

 Phase B: Pad release (no user impact yet)
 ─────────────────────────────────────────
 5. Release Pad APK with Task module
    - Task module ready but inactive
    - Still shows Chores by default
    - Listens for task Beat flags

 Phase C: App release (triggers migration)
 ─────────────────────────────────────────
 6. Release Flutter App with auto-migration
    - On device select: check + migrate
    - What's New notification
    - Task UI replaces Chore UI in App

 Post-release
 ─────────────────────────────────────────
 7. Monitor: Admin dashboard shows migration progress
 8. After 100% migration: deprecate Chore APIs (future)
```

### Why This Order?

- **Backend first**: APIs must be ready before clients call them
- **Go heartbeat before Pad**: Pad needs task Beat flags to detect migration
- **Pad before App**: Pad must be ready to receive task data before App triggers migration
- **App last**: App triggers migration, so everything else must be in place

---

## Rollback Plan

| Scenario | Action |
|---|---|
| Migration API bug | Fix API, re-run migration for affected devices (idempotent check via meta_data) |
| Pad Task module crash | Pad falls back to Chore module (still functional, old API untouched) |
| Bad data migration | `meta_data` records exactly what was migrated; can write reverse migration script |

## Backward Compatibility

- Old Chore APIs (`/pad-api/chore/...`, `/app-api/chore/...`) remain functional
- Old App versions continue using Chore endpoints
- Old Pad versions continue using Chore endpoints
- No data is deleted during migration — Chore records remain in DB
- `chore_cate` / `chore` Beat flags continue working for old clients

## Testing Checklist

- [ ] Migration API: creates tasks from chores correctly
- [ ] Migration API: idempotent (second call returns already_migrated)
- [ ] Beat flags: task/task_cate flow through Go heartbeat
- [ ] Pad: receives task Beat flags, initializes Room DB
- [ ] Pad: shows Task module after migration, Chore module before
- [ ] Pad: live switch — Flutter migrates while Pad is running → Pad auto-switches to Tasks within ~10s
- [ ] Pad: cold start — migration already done → Pad shows Tasks immediately on boot
- [ ] App: auto-migration on device select
- [ ] App: What's New shown once after migration
- [ ] Old App version: continues using Chore API without errors
- [ ] Old Pad version: continues using Chore API without errors
- [ ] Admin: migration status visible in Device list

---

## Phase D: Full Chore Deprecation (Future)

Once all devices have migrated (admin dashboard shows 100%), the entire Chore module can be removed.
This section documents every file that needs to be deleted or simplified, grouped by repo.

### Prerequisites

Before starting deprecation:

1. Confirm 100% migration via Django admin:
   ```python
   # All devices migrated
   unmigrated = Device.objects.filter(
       Q(meta_data__migrations__chore_to_task__isnull=True) | Q(meta_data={})
   )
   assert unmigrated.count() == 0
   ```
2. Run final batch migration for any stragglers:
   ```bash
   python3 manage.py migrate_chores_to_tasks
   ```
3. Ensure minimum App version enforced (force-update) so no old clients call Chore APIs

### Deletion Order

```
1. Server: remove Chore app + simplify Beat/Home
2. Go Heartbeat: remove chore/chore_cate fields
3. Pad: delete Chore module + remove migration checks
4. Flutter: delete Chore pages/manager + remove migration logic
5. Docs: remove Chore API docs
6. Server: drop Chore DB tables (final migration)
```

---

### 1. server

#### DELETE entirely: `pronext/chore/` directory

All files in this app:

| File | Contents |
|------|----------|
| `models.py` | `Category`, `Chore` models |
| `admin.py` | `CategoryAdmin`, `ChoreAdmin` |
| `options.py` | `get_chores`, `add_chore`, `update_chore`, `delete_chore`, `complete_chore` |
| `viewset_app.py` | App-facing Chore CRUD endpoints |
| `viewset_pad.py` | Pad-facing Chore CRUD endpoints |
| `apps.py` | `ChoreConfig` |
| `migrations/0001..0008` | All 8 migration files |

#### DELETE: migration utilities (no longer needed)

| File | What to remove |
|------|----------------|
| `pronext/task/migration_utils.py` | Entire file (`migrate_chores_for_user`, `convert_rrule`, `convert_exdates`, `convert_completeds`) |
| `pronext/task/management/commands/migrate_chores_to_tasks.py` | Entire file |

#### MODIFY: `pronext_server/settings.py`

```python
# Remove from INSTALLED_APPS:
'pronext.chore',
```

#### MODIFY: `pronext/common/models.py` — Beat class

Remove 2 fields + 1 method:

```python
# Remove these fields:
chore_cate = models.BooleanField(default=False)
chore = models.BooleanField(default=False)

# Remove this method:
def should_refresh_chore(self, value): ...
```

#### MODIFY: `pronext/device/viewset_app.py` — Home API

Simplify `home()` action — remove the `is_migrated` branching and Chore fallback:

```python
# BEFORE (simplified):
is_migrated = bool(device.meta_data.get('migrations', {}).get('chore_to_task'))
if is_migrated:
    # Task-based summary
else:
    # Chore-based summary (fallback)

# AFTER:
# Always use Task-based summary, remove else branch entirely
```

Also remove imports:
```python
from ..chore.models import Category as ChoreCategory
from ..chore.options import get_chores
```

#### MODIFY: `pronext/task/viewset_app.py` and `viewset_pad.py`

Remove migration endpoints (no longer needed):

```python
# Remove these actions:
def migration_status(self, request, ...): ...
def migrate(self, request, ...): ...
```

Remove import:
```python
from pronext.chore.models import Chore   # used in migration_status for chore_count
from .migration_utils import migrate_chores_for_user
```

#### OPTIONAL: `pronext/device/models.py`

Remove legacy field (requires a Django migration):
```python
chores_shortcut_enabled = models.BooleanField(...)  # no longer used
```

#### DB cleanup (last step)

After all code is deployed:
```bash
python3 manage.py makemigrations  # generates migration to drop chore tables
python3 manage.py migrate
```

Or manual SQL if preferred:
```sql
DROP TABLE IF EXISTS chore_chore CASCADE;
DROP TABLE IF EXISTS chore_category CASCADE;
```

---

### 2. heartbeat (Go)

#### MODIFY: `beat.go` — Beat struct

```go
// Remove these fields:
ChoreCate    bool   `json:"chore_cate"`
Chore        bool   `json:"chore"`
```

Also remove from `GetBeat()` field copy and `SetBeat()` switch cases.

#### MODIFY: `handlers.go` — HeartbeatData struct

```go
// Remove these fields:
ChoreCate   bool    `json:"chore_cate"`
Chore       bool    `json:"chore"`
```

Remove from `heartbeatHandler()` data initialization.

---

### 3. pad (Android/Kotlin)

#### DELETE entirely: `modules/chore/` directory

| File | Contents |
|------|----------|
| `Managers.kt` | `ChoreManager`, `ChoreCategoryFormManager`, `ChoreFormManager`, signal keys |
| `Models.kt` | `Chore`, `Category` data classes |
| `ChoresPage.kt` | Full-page chore list UI |
| `ChoresCard.kt` | Calendar preview card |
| `ChoreItem.kt` | Single chore row component |
| `ChoreForm.kt` | Add/edit chore form |
| `ChoreCategories.kt` | Category management UI |

#### MODIFY: `modules/task/TaskManager.kt` — Remove migration state

```kotlin
// DELETE these properties:
var isTaskMigrated by mutableStateOf(false)
private var migrationChecked = false

// DELETE this method:
private fun checkMigrationStatus() { ... }

// SIMPLIFY initialize():
fun initialize(context: Context) {
    appContext = context.applicationContext
    repository = TaskRepository.getInstance(context)
    observeLocalData()
    observeTasksForDate()
    if (AuthManager.isAuth) {
        // Remove: checkMigrationStatus()
        performInitialSync()
    }
}

// SIMPLIFY HeartBeat signal handler — remove migration re-check:
if (beat.task_cate) {
    syncCategoriesFromServer()
    // Remove the isTaskMigrated / migrationChecked block
}
```

Also remove `migration-status` API call from `TaskRepository`.

#### MODIFY: `common/Page.kt` — Navigation

```kotlin
// BEFORE:
if (TaskManager.shared.isTaskMigrated) {
    SideTab(icon = R.drawable.icon_chores, label = "Tasks", ...) { ... }
    if (configManager.stored.showChores) {
        SideTab(icon = R.drawable.icon_chores, label = "Chores", ...) { ... }
    }
} else {
    SideTab(icon = R.drawable.icon_chores, label = "Chores", ...) { ... }
}

// AFTER:
SideTab(icon = R.drawable.icon_chores, label = "Tasks", ...) { ... }
// Remove all Chores tabs and isTaskMigrated conditionals
```

Same for BottomTab section.

#### MODIFY: `modules/calendar/CalendarPage.kt`

```kotlin
// BEFORE:
if (TaskManager.shared.isTaskMigrated) { TasksRow() } else { ChoresRow() }

// AFTER:
TasksRow()
// Remove ChoresRow() and all chore imports
```

Same for the Add menu — remove Chore option, keep only Task.

#### MODIFY: `modules/settings/SettingPage.kt`

- Remove `val isMigrated = TaskManager.shared.isTaskMigrated`
- Remove "Show Chores" switch
- Remove old `ChoresSettingCard` (backward compat)

#### MODIFY: `base/Config.kt`

```kotlin
// Remove:
var showChores: Boolean = false,
```

#### MODIFY: `modules/common/Managers.kt` — Beat data class

```kotlin
// Remove these fields:
val chore_cate: Boolean = false,
val chore: Boolean = false,
```

---

### 4. flutter (Flutter/Dart)

#### DELETE entirely: `lib/src/page/chore/` directory

| File | Contents |
|------|----------|
| `chores.dart` | Chore list page |
| `chore_edit.dart` | Chore add/edit form |
| `chore_detail.dart` | Chore detail view |
| `chore_categories.dart` | Category management |
| `chore_category_edit.dart` | Category add/edit |

#### DELETE: `lib/src/manager/chore.dart` + `chore.g.dart`

Entire ChoreListManager and generated file.

#### MODIFY: `lib/src/manager/device.dart`

Remove migration logic and chore models:

```dart
// DELETE these model classes:
class ChoreItem { ... }
class ChoreProfile { ... }
class ChoresSummary { ... }

// DELETE from DeviceHome:
final int? choresCount;
final ChoresSummary? choresSummary;

// DELETE from DeviceManager:
final _migratedDevices = <int>{};
Future<void> _checkAndMigrate(int deviceId) { ... }
void _showWhatsNew() { ... }
static String _migrationKey(int deviceId) => ...;

// SIMPLIFY refresh() — remove _checkAndMigrate call:
await Future.wait(list.map((device) async {
    // Remove: await _checkAndMigrate(device.id);
    await _fetchHomeData(device.id);
}));
```

Regenerate `device.g.dart` after model changes.

#### MODIFY: Route/navigation files

Remove chore page imports and route registrations. Update any `'chores': '/tasks'` route mapping — just keep `/tasks` directly.

---

### 5. docs

#### DELETE:

| File | Contents |
|------|----------|
| `apis/app_api/chore.md` | App chore API docs |
| `apis/pad_api/chore.md` | Pad chore API docs |

#### MODIFY:

| File | Change |
|------|--------|
| `apis/pad_api/common.md` | Remove `chore_cate`, `chore` from Beat response docs |
| `apis/app_api/device.md` | Remove chore fields from Home API response docs |
| `docs/Tasks/RELEASE_PLAN.md` | Mark Phase D as completed |

---

### Summary

| Repo | Delete (files) | Modify (files) |
|------|---------------|----------------|
| server | ~18 (chore app + migrations + utils) | 5 (settings, Beat, Home API, task viewsets) |
| heartbeat | 0 | 2 (beat.go, handlers.go) |
| pad | 7 (chore module) | 6 (TaskManager, Page, CalendarPage, SettingPage, Config, Beat) |
| flutter | 7 (chore pages + manager) | 2+ (device.dart, routes) |
| docs | 2 (API docs) | 3 (Beat docs, device docs, this file) |
| **Total** | **~34 files** | **~18 files** |

### Key Simplifications After Cleanup

- `isTaskMigrated` conditionals removed everywhere — Tasks is always on
- Beat model shrinks by 2 fields (chore, chore_cate)
- Home API loses branching logic — always serves Task data
- No more migration status checks on Pad startup or heartbeat
- Device.meta_data `migrations.chore_to_task` key remains as historical record (harmless)
