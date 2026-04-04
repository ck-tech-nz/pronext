---
description: Run Pad UI tests — auto-creates test device, generates activation code, updates TestConfig, runs tests
argument-hint: [run|run <TestClass>]
allowed-tools: Bash(*), Read, Edit, Write, Grep, Glob
---

# Pad UI Testing

Fully automated UI test runner. Creates a fresh test device, generates activation code, patches TestConfig.kt, and runs tests.

## Default behavior (no args or `run`)

Execute these steps in order:

### Step 1: Create test device and get activation code

```bash
cd /Users/ck/Git/pronext/pronext/backend
source .venv/bin/activate
python3 manage.py shell -c "
from pronext.user.models import User
from pronext.device.models import Device, UserDeviceRel
from django.db import transaction
import datetime

user = User.objects.get(pk=1)  # Hustmck@hotmail.com
ts = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
device_name = f'uitest_{ts}'

with transaction.atomic():
    device_user = User.objects.create_user(username=device_name)
    device = Device.objects.create(device_user=device_user, name=device_name)
    rel = UserDeviceRel.objects.create(user=user, device=device, is_owner=True, removed=False)
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

### Step 3: Run tests

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

### Step 4: Report results

Show test results summary. If tests failed, show the failure details.

### Step 5: Revert TestConfig.kt

After tests complete (pass or fail), revert the activation code change:
```bash
cd /Users/ck/Git/pronext/pronext/pad
git checkout -- app/src/androidTest/java/it/expendables/pronext/base/TestConfig.kt
```

## Prerequisites

- Local Django backend running on port 8000
- Android emulator running (API 30+)
- On the pad project directory

## Test Structure

```
pad/app/src/androidTest/java/it/expendables/pronext/
├── base/
│   ├── BaseUiTest.kt      — Abstract base: app launch, auto-login, wait helpers
│   └── TestConfig.kt      — Activation code, timeout constants
├── auth/
│   └── ActivationTest.kt  — Login flow
└── calendar/
    ├── CalendarNavigationTest.kt  — View switching, date nav
    ├── EventCreateTest.kt         — Create single + repeat events
    ├── EventEditTest.kt           — Edit single + recurring events
    ├── EventDeleteTest.kt         — Delete single + recurring events
    └── CategoryFilterTest.kt      — Category filter toggle
```

## Troubleshooting

- **Tests timeout on login**: Check Django is running, emulator has network access to 10.0.2.2:8000
- **Events not appearing after create**: Increase `DEFAULT_TIMEOUT_MS` in TestConfig
- **"Already exists" errors**: Previous test run left data — events use unique timestamped titles to avoid this
