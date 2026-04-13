---
description: Run Pad UI tests — auto-creates test device, generates activation code, updates TestConfig, runs tests
argument-hint: [run|run <TestClass>]
allowed-tools: Bash(*), Read, Edit, Write, Grep, Glob
---

# Pad UI Testing

Fully automated UI test runner. Creates a fresh test device, generates activation code, patches TestConfig.kt, and runs tests.

## Default behavior (no args or `run`)

Execute these steps in order:

### Step 0: Pre-flight checks (fail fast)

Before doing anything else, verify the environment. If any check fails, STOP and report to the user:

```bash
# Backend must be running — if this isn't 200, ALL calendar tests will fail with
# "event not visible" because the app can't sync events from the server.
curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/pad-api/
# Expect: 200
```

```bash
# Emulator must be connected
$HOME/Library/Android/sdk/platform-tools/adb devices | grep -v "^List" | grep "device$"
# Expect: one "emulator-XXXX device" line
```

If either fails, STOP and tell the user what's wrong (don't attempt to start backend yourself — the user wants to see its logs).

### Step 1: Create test device, category, and get activation code

```bash
cd /Users/ck/Git/pronext/pronext/backend
source .venv/bin/activate
python3 manage.py shell -c "
from pronext.user.models import User
from pronext.device.models import Device, UserDeviceRel
from pronext.calendar.models import Category
from django.db import transaction
import datetime

user = User.objects.get(pk=1)  # Hustmck@hotmail.com
ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
device_name = f'uitest_{ts}'

with transaction.atomic():
    device_user = User.objects.create_user(username=device_name)
    device = Device.objects.create(device_user=device_user, name=device_name)
    rel = UserDeviceRel.objects.create(user=user, device=device, is_owner=True, removed=False)
    # Create a default category so the calendar filter shows events
    Category.objects.create(user=device_user, name='Pad', color='#e040fb')
    code = rel.code
    print(f'DEVICE_ID={device.pk}')
    print(f'CODE={code}')
    print(f'NAME={device_name}')
"
```

Parse the output to extract `CODE`.

### Step 2: Update TestConfig.kt

Use the Edit tool to replace the `ACTIVATION_CODE` value in:
`/Users/ck/Git/pronext/pronext/pad/app/src/androidTest/java/it/expendables/pronext/base/TestConfig.kt`

Replace the old code with the new one. Do NOT commit this change — it's ephemeral.

### Step 3: Clear app data before running

Clear stale app data so the fresh activation code is actually used:
```bash
ADB=$HOME/Library/Android/sdk/platform-tools/adb
$ADB shell pm clear it.expendables.pronext 2>/dev/null || true
```

**IMPORTANT**: Each `./gradlew connectedDebugAndroidTest` invocation **reinstalls the app** (clearing data). So every gradle run needs a **fresh activation code** — activation codes are single-use after successful activation. If you run `./gradlew connectedDebugAndroidTest` a second time with the same code, the app reinstalls, fails to re-activate, and ALL tests will fail with "event not visible".

If you need to run multiple times in a session, repeat Step 1 (new device) and Step 2 (update TestConfig) before each run.

### Step 4: Run tests

If no argument or `run`:
```bash
cd /Users/ck/Git/pronext/pronext/pad
./gradlew connectedDebugAndroidTest 2>&1
```

If `run <TestClass>` (e.g., `run EventCreateTest`):
```bash
cd /Users/ck/Git/pronext/pronext/pad
./gradlew connectedDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=it.expendables.pronext.calendar.<TestClass>
```

### Step 5: Report results

Show test results summary. If tests failed, show the failure details.

### Step 6: Revert TestConfig.kt

After tests complete (pass or fail), revert the activation code change:
```bash
cd /Users/ck/Git/pronext/pronext/pad
git checkout -- app/src/androidTest/java/it/expendables/pronext/base/TestConfig.kt
```

## Prerequisites

- **Django backend on port 8000** — start it yourself so you can see the logs:
  ```bash
  cd /Users/ck/Git/pronext/pronext/backend
  source .venv/bin/activate
  python3 manage.py runserver 0.0.0.0:8000
  ```
  Run this in a **separate background terminal** (`run_in_background`). Keep it running throughout the test session. Watch its output for 401 errors — if heartbeat returns 401 repeatedly, events may disappear from Room due to syncEventsFromServer race condition.
- **Android emulator running** (API 30+)
- On the pad project directory

## Test Structure

```
pad/app/src/androidTest/java/it/expendables/pronext/
├── base/
│   ├── BaseUiTest.kt              — Abstract base: app launch, auto-login, wait helpers
│   ├── CalendarTestHelper.kt      — Shared helper: navigation, event CRUD, assertions
│   └── TestConfig.kt              — Activation code, timeout constants
├── auth/
│   └── ActivationTest.kt          — Login flow
└── calendar/
    ├── CalendarNavigationTest.kt  — View switching, date nav
    ├── EventCreateTest.kt         — Create single + repeat events (basic)
    ├── EventEditTest.kt           — Edit single + recurring events (basic)
    ├── EventDeleteTest.kt         — Delete single + recurring events (basic)
    ├── CategoryFilterTest.kt      — Category filter toggle
    ├── create/
    │   └── EventCreateRepeatTest.kt    — All frequencies with UNTIL and BYDAY
    ├── edit/
    │   ├── EventEditThisTest.kt        — Edit THIS occurrence
    │   ├── EventEditAllTest.kt         — Edit ALL occurrences
    │   └── EventEditFutureTest.kt      — Edit THIS_AND_FUTURE
    ├── delete/
    │   ├── EventDeleteThisTest.kt      — Delete THIS occurrence
    │   ├── EventDeleteAllTest.kt       — Delete ALL
    │   └── EventDeleteFutureTest.kt    — Delete THIS_AND_FUTURE
    ├── combo/
    │   └── EventComboTest.kt           — Mixed operations + edge cases
    └── view/
        └── EventViewExpansionTest.kt   — RRule expansion in week view
```

## Troubleshooting

- **Tests timeout on login**: Check Django is running, emulator has network access to 10.0.2.2:8000
- **Events not appearing after create**: The device likely has no category/profile — Step 1 creates one automatically. If still failing, check the calendar filter shows a profile (not "No Profile")
- **"Already exists" errors**: Previous test run left data — events use unique timestamped titles to avoid this
- **"New calendar is syncing" dialog blocks tests**: `BaseUiTest.dismissSyncDialog()` handles this automatically. If it fails, the dialog may have changed — check `WelcomePopover.kt`
- **ComposeTimeoutException not caught**: Use `catch (_: Throwable)` not `catch (_: Exception)` — Compose test exceptions extend Throwable directly
- **Wholesale test failures ("event not visible" or ComposeTimeoutException on every test)**: Likely one of:
  1. Backend down (Step 0 pre-flight should catch this now)
  2. Activation code consumed — run Step 1 + Step 2 again for a fresh code
  3. Emulator offline or DNS not resolving 10.0.2.2 — restart emulator
- **Test pass rate degrades as tests run sequentially**: Test events accumulate on the device across classes. Later tests may see dozens of old events in the same week view, causing LazyColumn to not render the new event. Options:
  - Run one test class at a time with fresh device (`run EventCreateTest`)
  - Split long runs into smaller batches of classes
  - (Future improvement: add `@After` cleanup to delete test events)
