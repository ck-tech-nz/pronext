---
name: pad-update
description: >
  Pad device OTA update system — check, download, install, and rollout logic.
  Covers staggered rollout (anti-thundering-herd), failure handling with skip_devices,
  caching, timeout protection, and result reporting. Use when modifying any update-related
  logic to avoid reintroducing the DB overload and stuck-update bugs that were previously fixed.
---

# Pad OTA Update System (Pronext Standard)

This skill documents the complete Pad update pipeline. **Historical context**: early versions
caused DB overload (all devices hitting check_update simultaneously) and devices stuck in
"Checking update" / "Downloading update" states. The current design solves both problems.

## Architecture Overview

```
Pad Device                          Django Server                    CDN/S3
┌──────────────┐                   ┌────────────────────┐           ┌─────────┐
│ LaunchPage   │  POST             │ check_update       │           │ APK file│
│  ↓ 500ms     │── check_update──→ │  ├ cache lookup    │           │ hosted  │
│ UpdateManager│                   │  ├ skip_devices?   │           │ externally
│  ├ check()   │   ← {url,build}   │  ├ stagger slot?   │           └────┬────┘
│  ├ download()│────────────────────────────────────────────────────────→│
│  ├ install() │   ← APK bytes     │                     │               │
│  └ report()  │───report_result──→│ report_update_result│               │
│              │                   │  └ skip on failure  │               │
│ Background:  │                   └─────────────────────┘               │
│ queue 8min   │                                                         │
└──────────────┘
```

**Key design decisions:**
1. Server returns APK URL → device downloads from CDN directly (no server bandwidth)
2. Staggered rollout via hash-based time slots (20-min window)
3. Failed devices auto-added to skip list (never retry broken APK on that device)
4. 7-day APK info cache (invalidated on admin changes via signals)

---

## 1. Server: PadApk Model

File: `backend/pronext/common/models.py`

```python
class PadApk(models.Model):
    version = models.CharField(max_length=20)        # "2.2.0"
    build_num = models.PositiveSmallIntegerField()    # 1399 (unique, auto-increment)
    url = models.URLField(max_length=2048)            # Full CDN URL to APK
    whats_new = models.TextField(null=True, blank=True)
    skip_devices = models.JSONField(default=list)     # ["SN001", "SN002"] — devices to exclude
    window_seconds = models.PositiveIntegerField(default=7200)  # Stagger window (seconds)
    is_paused = models.BooleanField(default=False)              # Pause rollout for non-testing devices
    status = models.SmallIntegerField(choices=[
        (0, 'UNPUBLISHED'),  # Draft
        (1, 'TESTING'),      # Only testing devices see it
        (2, 'PUBLISHED'),    # All devices see it
    ])
    published_at = models.DateTimeField(null=True)    # Auto-set when status → PUBLISHED
    comment = models.TextField(null=True, blank=True) # Internal notes
```

### Status workflow
```
UNPUBLISHED (0) → TESTING (1) → PUBLISHED (2)
```
- **TESTING**: only devices in `testing_devices` config list receive the update
- **PUBLISHED**: all devices receive (subject to stagger)
- `published_at` auto-set on first transition to PUBLISHED

### skip_devices list
- JSON array of device SNs: `["SN001", "SN002"]`
- Devices in this list will NEVER receive this APK version
- Auto-populated when a device reports failed/timeout update
- Admin can manually clear entries if the issue is resolved

---

## 2. Server: check_update Endpoint

File: `backend/pronext/common/viewset_pad.py`

**Endpoint**: `POST /pad-api/common/check_update/`

### Flow

```python
def check_update(request):
    device_build = request.pad.app_build_num
    device_sn = request.pad.sn
    is_testing = device_sn in testing_devices

    # 1. Get latest APK info (cached 7 days)
    apk_info = get_latest_apk_info(is_testing)  # TESTING+PUBLISHED or PUBLISHED only
    if not apk_info:
        return {}

    latest_build = apk_info['build_num']

    # 2. Skip if device already up-to-date
    if device_build >= latest_build:
        # If was pending, mark as updated (async)
        return {}

    # 3. Skip if device is in skip_devices list
    if device_sn in apk_info.get('skip_devices', []):
        return {}

    # 4. Stagger check (CRITICAL for preventing DB overload)
    if not is_testing and not _should_notify_update(device_sn, apk_info['version']):
        return {}  # Not this device's turn yet

    # 5. Return update info
    mark_device_pending_update(device_sn)
    return {'build': latest_build, 'apk_url': apk_info['url'], 'version': apk_info['version']}
```

### Staggered Rollout Algorithm (anti-thundering-herd)

```python
def _should_notify_update(device_sn, version, window_seconds=7200):
    """Spread update notifications across a configurable window (default 2h)."""
    hash_input = f"{device_sn}:{version}"
    hash_value = int(hashlib.md5(hash_input.encode()).hexdigest(), 16)
    device_slot = hash_value % window_seconds     # 0-1199
    current_slot = int(time.time()) % window_seconds
    return current_slot >= device_slot
```

**How it prevents overload:**
- `window_seconds` is configurable per PadApk (default 7200 = 2 hours)
- Each device gets deterministic slot based on `MD5(sn:version)`
- Devices check every 8 min; each cycle, `480/window_seconds` fraction of devices are released
- Example with 5000 devices: window=7200 → ~333 devices per 8-min cycle, 2h to full rollout
- Example with 5000 devices: window=1200 → ~2000 devices per cycle, 20min to full rollout
- New APK version → new hash → new distribution (prevents stale slots)
- `is_paused=True` → all non-testing devices get empty response (emergency brake)

**NEVER remove or bypass the stagger logic.** This was the primary fix for the DB overload problem.

### Caching

File: `backend/pronext/common/cache_utils.py`

```python
# Two separate cache keys (7-day TTL):
"latest_apk:testing"   # status IN (TESTING, PUBLISHED) — for test devices
"latest_apk:published" # status = PUBLISHED only — for production devices

# Invalidated via Django signals on PadApk save/delete
# Admin action: "Invalidate APK cache" also available
```

**IMPORTANT**: Every `check_update` call hits cache, NOT the database. Without this cache,
thousands of devices polling every 8 minutes would overload PostgreSQL.

---

## 3. Pad: UpdateManager

File: `pad/.../modules/common/Managers.kt`

### Check lifecycle

```
App Launch
    ↓ 500ms delay (LaunchPage LaunchedEffect)
    ↓
UpdateManager.check(inCheckPage=true)
    ↓
    ├─ Success + update available → download → install → report → navigate away
    ├─ Success + no update → navigate away + startQueue(background)
    └─ Failure → retry (max 3, 5s interval) → navigate away + startQueue(background)

Background Queue (every 480 seconds = 8 minutes)
    ↓
UpdateManager.check(inCheckPage=false)
    ↓
    ├─ Update available → download → install → report
    └─ No update / failure → wait 480s → retry
```

### Timeout protection (fixed the "stuck in checking" bug)

```kotlin
// LaunchPage: randomized timeout 2-5 minutes
val timeout = Random.nextInt(120_000, 300_000)  // ms

// After timeout: force-navigate away regardless of update state
// Prevents devices getting stuck on launch screen forever
```

**Why randomized**: if all devices have the same timeout and all launch simultaneously
(e.g., after power outage), they'd all retry at the same moment. Randomization spreads retries.

### Download

```kotlin
// OkHttp client with generous timeouts
val client = OkHttpClient.Builder()
    .readTimeout(10, TimeUnit.MINUTES)
    .writeTimeout(10, TimeUnit.MINUTES)
    .build()

// Download to cache directory
val file = File(context.cacheDir, apkFileName)
// Stream response body to file
```

- No progress callback to UI (just `downloading = true/false` state)
- Direct download from CDN URL (not through Django server)
- APK file written to `context.cacheDir` (auto-cleaned by system)

### Installation

```kotlin
// Root install (system app)
val result = Runtime.getRuntime().exec("pm install -r ${file.absolutePath}")
```

- Requires root/system privileges
- Synchronous on IO thread
- No user prompt or confirmation dialog
- App restarts automatically after successful install

---

## 4. Result Reporting

File: `backend/pronext/common/viewset_pad.py`

**Endpoint**: `POST /pad-api/common/report_update_result/`

### Request

```json
{
    "build_num": 1400,
    "version": "2.2.1",
    "status": "success",          // "success" | "failed" | "timeout"
    "error_message": null,        // populated on failure
    "download_duration": 45,      // seconds
    "install_duration": 12,       // seconds
    "total_duration": 60          // seconds
}
```

### Server behavior on failure

```python
if status in ("failed", "timeout"):
    # Auto-add device to APK's skip_devices list
    apk = PadApk.objects.get(build_num=build_num)
    skip = apk.skip_devices or []
    if device_sn not in skip:
        skip.append(device_sn)
        apk.skip_devices = skip
        apk.save()
```

**This prevents retry loops**: a device that fails to install an APK will never be offered
that same APK again. Admin must manually remove from `skip_devices` if the issue is fixed.

### UpdateResult model

```python
class UpdateResult(models.Model):
    device_sn = models.CharField(max_length=50, db_index=True)
    apk_build_num = models.PositiveSmallIntegerField()
    apk_version = models.CharField(max_length=20)
    status = models.CharField(max_length=20)           # success/failed/timeout
    error_message = models.TextField(null=True)
    download_duration = models.PositiveIntegerField(null=True)  # seconds
    install_duration = models.PositiveIntegerField(null=True)
    total_duration = models.PositiveIntegerField(null=True)
    created_at = models.DateTimeField(auto_now_add=True)
```

Read-only in admin, searchable by `device_sn` and `error_message`.

---

## 5. Admin Workflow

File: `backend/pronext/common/admin.py`, `forms.py`

### Publishing a new APK

1. Upload APK to CDN (S3/Cloudflare R2)
2. In admin: create PadApk with URL
   - URL auto-parsed: `pronext-v{version}-{build}_release_*.apk` → auto-fills version + build_num
   - URL validated via HTTP HEAD request
3. Set status = TESTING → only test devices get it
4. Monitor UpdateResult for test devices
5. Set status = PUBLISHED → staggered rollout to all devices begins
6. Monitor skip_devices count (red badge in admin if > 0)

### Handling failures

- Check `UpdateResult` admin for error patterns
- If APK is fundamentally broken: set status back to UNPUBLISHED
- If only specific devices fail: leave in skip_devices, investigate hardware
- If issue is fixed: clear skip_devices list manually, devices will get update on next check

---

## 6. Protection Mechanisms Summary

| Problem | Solution | Location |
|---------|----------|----------|
| **All devices check simultaneously** | Hash-based stagger (configurable window, default 2h) | `viewset_pad.py: _should_notify_update()` |
| **Rollout too fast** | Configurable `window_seconds` per APK (1200-14400) | `PadApk.window_seconds` |
| **Need emergency stop** | `is_paused` flag + admin Pause/Resume actions | `PadApk.is_paused` |
| **DB overload from check_update** | 7-day APK info cache | `cache_utils.py: get_latest_apk_info()` |
| **Device stuck on launch screen** | Randomized timeout (2-5 min) | `LaunchPage.kt` |
| **Failed device retries forever** | Auto skip_devices on failure | `viewset_pad.py: report_update_result` |
| **Download overloads server** | Direct CDN download (not Django) | APK URL points to S3/R2 |
| **Background polling too frequent** | 8-minute interval with 3-retry cap | `Managers.kt: startQueue()` |
| **Cache invalidation** | Django signals on PadApk save/delete | `signals.py` |
| **Power outage → all launch at once** | Randomized timeout + stagger hash | Both client + server |

---

## 7. Rules — DO NOT Break These

### NEVER:
- Remove or weaken the stagger algorithm (caused DB meltdown before)
- Serve APK files through Django (use CDN URLs only)
- Remove the launch page timeout (causes stuck devices)
- Allow failed devices to retry the same APK without admin intervention
- Make check_update hit the database directly (must use cache)
- Set background check interval below 5 minutes
- Use a fixed timeout value (must be randomized to prevent synchronized retries)

### WHEN ADDING NEW FEATURES:
- Any new field on PadApk must handle cache invalidation (add to signal)
- New check_update conditions must go AFTER the cache lookup (never before)
- Test with testing_devices first (status=TESTING) before PUBLISHED
- Monitor UpdateResult after rollout for failure patterns
- Consider: "what happens if 1000 devices hit this at the same second?"

---

## 8. File Reference

### Server
| Purpose | Path |
|---------|------|
| PadApk & UpdateResult models | `backend/pronext/common/models.py` |
| check_update & report endpoint | `backend/pronext/common/viewset_pad.py` |
| APK cache utilities | `backend/pronext/common/cache_utils.py` |
| Cache invalidation signals | `backend/pronext/common/signals.py` |
| Admin (PadApk, UpdateResult) | `backend/pronext/common/admin.py` |
| Admin forms (URL parsing) | `backend/pronext/common/forms.py` |
| Services (async helpers) | `backend/pronext/common/services.py` |

### Pad (Kotlin)
| Purpose | Path |
|---------|------|
| UpdateManager | `pad/.../modules/common/Managers.kt` |
| Launch page (check trigger) | `pad/.../modules/launch/LaunchPage.kt` |
| Config (version info) | `pad/.../base/Config.kt` |
| Build config | `pad/app/build.gradle.kts` |

(All Pad paths under `pad/app/src/main/java/it/expendables/pronext/`)
