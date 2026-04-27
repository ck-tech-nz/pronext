# Pad Manual Update Button — Design

**Date:** 2026-04-27
**Component:** backend (Django), pad (Kotlin)
**Status:** approved (pending implementation)

## 1. Goal

Add an "Update" button to the Pad **Settings → General → Other** section so a user can
explicitly check for OTA updates, instead of waiting for the 8-minute background poll.
On click:

- If a newer APK exists for this device → ask "Update now?" → run download/install.
- If the device is up to date → tell the user "You're up to date".
- On network/server failure → show a friendly error.

Also restyle the read-only info block (Calendar Name, Device Owner, Version, Mac
address, Serial Number) so non-debug users can clearly see those fields are static
information, not tappable cells.

## 2. Why

Today the Pad checks for updates only:
- Once on launch (LaunchPage), and
- Every 480 s in the background.

A user who plugs the Pad in or hears about a new release has no way to trigger a
check. They have to power-cycle or wait. A manual button closes that gap.

Additionally, the existing read-only rows (Version, Mac address, Serial Number, etc.)
share the same light-card styling as interactive rows like Wi-Fi or Time Zone, so a
user might tap them expecting something to happen. Making them visually static
removes that confusion.

## 3. Architecture

```
Pad — Settings/General                Django — pad-api
┌─────────────────────────────┐      ┌──────────────────────────────────┐
│ InfoRow "Version" v2.2.8    │      │  POST common/check_update        │
│   ├ static grey text         │      │   └ stagger + skip_devices       │  (existing,
│   └ [Update] inline button ──┼─────►│                                  │   unchanged)
│         │                    │      │                                   │
│  on tap:                     │      │  POST common/manual_check_update │
│   1. show spinner            │      │   ├ same cache lookup            │  (NEW)
│   2. POST manual_check       │      │   ├ honor is_paused              │
│   3. dispatch dialog         │      │   ├ honor TESTING/PUBLISHED tier │
│   4. on confirm: download    │      │   ├ BYPASS stagger window        │
│      and install             │      │   └ BYPASS skip_devices          │
└─────────────────────────────┘      └──────────────────────────────────┘
```

The auto-check pipeline (`check_update` → background queue, LaunchPage) is **not
touched**. Manual flow runs in parallel and reuses only the download/install/report
helpers inside `UpdateManager`.

## 4. Backend changes

### 4.1 New endpoint: `POST /pad-api/common/manual_check_update/`

Add as a new `@action` on the existing `CommonViewSet` in
`backend/pronext/common/viewset_pad.py`. Routing is automatic via
`@register_pad_route("common")`.

```python
@action(['post'], detail=False)
def manual_check_update(self, request):
    pad: Pad = request.pad
    is_testing = pad.sn in self._get_test_devices()

    apk_info = get_latest_apk_info(is_testing)   # cached, same as check_update
    if not apk_info:
        return Response({})

    # Honor is_paused (emergency brake): paused → up-to-date for non-testing.
    # Testing devices ignore is_paused (matches check_update behavior).
    if apk_info.get('is_paused') and not is_testing:
        return Response({})

    if pad.app_build_num >= apk_info['build_num']:
        return Response({})

    # Differences from check_update:
    #  • DO NOT call _should_notify_update() — manual click bypasses stagger.
    #  • DO NOT consult skip_devices — user explicitly asked to retry.

    # 5-second per-device cooldown (anti-hammer) — cheap cache check.
    cooldown_key = f"manual_check_cooldown:{pad.sn}"
    if cache.get(cooldown_key):
        return Response({})
    cache.set(cooldown_key, 1, timeout=5)

    mark_device_pending_update(pad.sn)
    return Response({
        'build': apk_info['build_num'],
        'apk_url': apk_info['url'],
        'version': apk_info['version'],
    })
```

**Cache:** `get_latest_apk_info()` already includes `is_paused`, `skip_devices`,
`window_seconds`, and `published_at` (verified in `cache_utils.py`). No cache
schema change needed.

**Auth:** standard pad-api authentication (Signature + JWT) — same as `check_update`,
inherited from `CommonViewSet`.

**Anti-hammer cooldown:** since this bypasses stagger, the per-device 5-second
cooldown above prevents pathological loops. The Pad client already disables the
button while a check is in flight, so legitimate use never trips it.

### 4.2 URL registration

Routing is handled by the `@register_pad_route("common")` decorator on
`CommonViewSet`, so the new `@action`-decorated method is auto-exposed at
`POST /pad-api/common/manual_check_update/`. No manual URL wiring needed.

### 4.3 Tests

Add to `backend/pronext/common/tests/` (mirror existing `test_check_update` tests):

- `test_manual_check_update_returns_apk_when_outdated`
- `test_manual_check_update_bypasses_stagger` — verify it returns the APK even when
  `_should_notify_update()` would return False
- `test_manual_check_update_bypasses_skip_devices` — device in `skip_devices` still
  receives the APK
- `test_manual_check_update_honors_is_paused` — paused → empty for non-testing
- `test_manual_check_update_paused_but_testing` — testing device still gets APK
- `test_manual_check_update_returns_empty_when_up_to_date`
- `test_manual_check_update_cooldown` — second call within 5 s returns empty

## 5. Pad changes

### 5.1 `UpdateManager.checkManually()`

Add to `pad/.../modules/common/Managers.kt`:

```kotlin
sealed class ManualCheckResult {
    data class UpToDate(val currentVersion: String) : ManualCheckResult()
    data class UpdateAvailable(val version: String, val build: Int) : ManualCheckResult()
    data class NetworkError(val message: String) : ManualCheckResult()
}

class UpdateManager : BaseManager() {
    // existing fields/companion …

    var manualChecking by mutableStateOf(false)

    fun checkManually(onResult: (ManualCheckResult) -> Unit) {
        if (manualChecking || downloading || installing) return  // re-entrancy guard
        manualChecking = true
        Net.shared.launch(Api::class.java, mute = true, onError = { _, error ->
            manualChecking = false
            onResult(ManualCheckResult.NetworkError(error?.message ?: "Network error"))
        }) { api ->
            val res = api.manualCheckUpdate()
            manualChecking = false
            val data = res.data
            if (data?.apk_url != null && data.build != null && data.version != null) {
                onResult(ManualCheckResult.UpdateAvailable(data.version, data.build))
                // caller decides whether to actually start the download (see UI)
                pendingManualUpdate = Triple(data.apk_url, data.build, data.version)
            } else {
                val current = "v${configManager.appVersion}(${configManager.appBuildNum})"
                onResult(ManualCheckResult.UpToDate(current))
            }
        }
    }

    private var pendingManualUpdate: Triple<String, Int, String>? = null

    fun startManualDownload(onComplete: (success: Boolean, errorMessage: String?) -> Unit) {
        val pending = pendingManualUpdate ?: return
        pendingManualUpdate = null
        downloadApkInternal(pending.first, pending.second, pending.third,
                            navigateOnComplete = false, onComplete = onComplete)
    }
}
```

**Refactor:** the current `downloadApk(url, buildNum, version, inCheckPage)` mixes
download/install with `Route.to(...)` navigation. Split it into:

- `downloadApkInternal(url, build, version, navigateOnComplete: Boolean, onComplete: ((Boolean, String?) -> Unit)? = null)` — does download/install/report only, optionally navigates.
- The existing `check(inCheckPage)` calls `downloadApkInternal(..., navigateOnComplete = inCheckPage)` to preserve current behavior.
- The new manual path calls `downloadApkInternal(..., navigateOnComplete = false, onComplete = ...)`.

This refactor is the only change to the existing auto-check flow; existing behavior
must be preserved exactly.

### 5.2 New API method

In the `Api` interface inside `Managers.kt`:

```kotlin
@POST("common/manual_check_update")
suspend fun manualCheckUpdate(): Res<UpdateInfo>
```

### 5.3 New `InfoRow` component (replace flat `TextCell` for static info)

Add a new private composable in `SettingPage.kt` (or co-locate with `TextCell`):

```kotlin
@Composable
private fun InfoRow(
    title: String,
    value: String,
    trailing: (@Composable () -> Unit)? = null,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 12.dp),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(4.dp),
            modifier = Modifier.weight(1f),
        ) {
            Text(
                text = title,
                color = Color(0xff8a8a92),         // muted label
                style = MaterialTheme.typography.headlineSmall,
            )
            Text(
                text = value,
                color = Color(0xff8a8a92),         // muted value, signals "static"
                fontSize = 22.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        if (trailing != null) {
            trailing()
        }
    }
}
```

**Visual difference vs. `TextCell`:** no rounded card background, lighter padding,
muted label+value color (`#8a8a92` grey instead of label `#56565b` + value `#28272f`).
The result reads as flat info text. Surrounding interactive rows (Wi-Fi, Time
Zone, ZIP Code, Device Name, Brightness, Volume) keep their card styling, so the
visual contrast does the communication work.

### 5.4 Replace existing rows

In `GeneralCard()` swap the five static `TextCell` calls in the **Other** section
(lines ~292–307) for `InfoRow`:

```kotlin
SectionTitle("Other")
InfoRow("Calendar Name", AuthManager.user?.account?.split("@")?.firstOrNull() ?: "")
InfoRow("Device Owner (Mobile App Login)",
        SettingManager.shared.ownerUsername.ifEmpty { "Not available" })
InfoRow("Version", "v${configManager.appVersion}(${configManager.appBuildNum})") {
    UpdateButton()
}
InfoRow("Mac address", configManager.mac)
// Serial Number keeps its 11-tap-to-reveal-Debug Box wrapper:
Box(modifier = Modifier.clickable(...) { /* tap counter, unchanged */ }) {
    InfoRow("Serial Number", configManager.sn)
}
```

The hidden 11-tap gesture on Serial Number continues to work unchanged.

### 5.5 The `UpdateButton` composable

```kotlin
@Composable
private fun UpdateButton() {
    val updateManager = UpdateManager.shared
    val checking = updateManager.manualChecking
    val busy = checking || updateManager.downloading || updateManager.installing

    Button(
        onClick = { onUpdateButtonTap() },
        enabled = !busy,
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xff5585ff)),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
        modifier = Modifier.requiredHeight(40.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(
                Modifier.size(20.dp),
                strokeWidth = 2.dp,
                color = Color.White,
            )
        } else {
            Text("Update", color = Color.White, fontSize = 18.sp,
                 fontWeight = FontWeight.Medium)
        }
    }
}
```

### 5.6 Tap handler — dialog flow

```kotlin
private fun onUpdateButtonTap() {
    UpdateManager.shared.checkManually { result ->
        when (result) {
            is ManualCheckResult.UpToDate -> showAlert(
                title = "You're up to date",
                content = "Version ${result.currentVersion} is the latest.",
                confirmTitle = "OK",
            ) { dismiss -> dismiss() }
            // Note: existing showAlert renders Cancel + confirm. For info-only
            // alerts both buttons just dismiss — accepted as-is. Single-button
            // variant of showAlert is out of scope for this spec.

            is ManualCheckResult.UpdateAvailable -> showAlert(
                title = "Update available",
                content = "Version ${result.version} (build ${result.build}) is available. Update now?",
                confirmTitle = "Update",
            ) { dismiss ->
                dismiss()
                UpdateManager.shared.startManualDownload { success, errorMessage ->
                    if (!success) {
                        showAlert(
                            title = "Update failed",
                            content = errorMessage ?: "Please try again later.",
                            confirmTitle = "OK",
                        ) { d -> d() }
                    }
                    // on success, pm install -r restarts the app — nothing to do here.
                }
            }

            is ManualCheckResult.NetworkError -> showAlert(
                title = "Couldn't check for updates",
                content = "Please check your connection and try again.",
                confirmTitle = "OK",
            ) { d -> d() }
        }
    }
}
```

While download/install runs, the `UpdateButton` shows a spinner because it's bound
to `updateManager.downloading`/`installing`. The user is free to navigate away from
Settings; the install will still complete and restart the app.

## 6. Edge cases & decisions

| Scenario | Behavior |
|---|---|
| Background auto-check is mid-download when user taps Update | Button is disabled (spinner), tap is no-op. |
| User taps Update twice rapidly | `manualChecking` flag blocks re-entry. |
| Server returns the same APK that previously failed (skip_devices bypass) | We try again. If install fails again, `report_update_result` re-adds device to `skip_devices`, and a `DownloadFailed`/`InstallFailed` alert is shown. |
| `is_paused = true` and device is testing | Endpoint still returns the APK (testing devices ignore `is_paused`, same as `check_update`). |
| Cooldown active (rapid retries) | Endpoint returns `{}`, user sees "You're up to date" — acceptable since this only fires under abnormal usage. |
| Device offline | `NetworkError` alert, button returns to idle. |
| User closes Settings during download | Download/install continues in `UpdateManager` background; app restarts on success. |

## 7. Out of scope

- No release notes (`whats_new`) shown in the dialog. (Add later if needed; field
  exists on `PadApk`.)
- No download progress percentage — just a spinner. (Existing flow doesn't track it
  either.)
- No change to the auto-check stagger / 8-minute queue / launch page flow.
- No change to existing `TextCell` styling for interactive rows.

## 8. Files touched

**Backend:**
- `backend/pronext/common/viewset_pad.py` — add `manual_check_update` action on `CommonViewSet` (routing automatic)
- `backend/pronext/common/tests/test_check_update.py` (or new file) — 7 new tests above

**Pad:**
- `pad/app/src/main/java/it/expendables/pronext/modules/common/Managers.kt` — new
  `ManualCheckResult`, `manualCheckUpdate` API method, `checkManually` /
  `startManualDownload`, refactor `downloadApk` → `downloadApkInternal`
- `pad/app/src/main/java/it/expendables/pronext/modules/settings/SettingPage.kt` —
  new `InfoRow` composable, `UpdateButton`, `onUpdateButtonTap`, swap five static
  rows in `GeneralCard()`

## 9. Test plan (manual)

After implementation:

1. **Up to date case:** ensure Pad on latest build → tap Update → see "You're up to date".
2. **Update available case:** publish a newer APK on test backend (status=TESTING,
   testing_devices includes the test SN) → tap Update → see "Update available" dialog
   → tap Update → button spinner, app restarts, version row shows new build.
3. **Stagger bypass:** confirm response arrives even when slot hasn't come up
   (verify by reading server logs / setting `window_seconds=14400` on the APK).
4. **skip_devices bypass:** add the test device's SN to the APK's `skip_devices`,
   tap Update — should still get the APK.
5. **is_paused honored:** set APK `is_paused=True` for a non-testing device → tap
   Update → "You're up to date".
6. **Network error:** disable Wi-Fi → tap Update → "Couldn't check for updates".
7. **Re-entrancy:** tap Update repeatedly during check / download — no duplicate
   requests, button stays in busy state.
8. **Static info styling:** verify Calendar Name, Device Owner, Version, Mac, SN
   rows visually distinct from Wi-Fi/Time Zone/ZIP Code rows; non-debug users do
   not perceive them as tappable.
9. **11-tap reveal still works:** tap Serial Number row 11× → Debug section appears.
