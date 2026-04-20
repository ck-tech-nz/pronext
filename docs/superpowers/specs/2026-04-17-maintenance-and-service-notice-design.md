# Maintenance Mode & Service Notice — Design

**Date:** 2026-04-17
**Status:** Spec — awaiting implementation plan
**Scope:** `backend/`, `h5/`, `app/`
**Supersedes:** [2026-04-15-h5-maintenance-mode-design.md](./2026-04-15-h5-maintenance-mode-design.md) (H5-only flags are replaced by unified flags described here)

## 1. Background

Two operational scenarios need a user-facing safety net:

1. **Partial outage** — App still logs in, but some modules fail (e.g. stale migrations, broken data). Admin can still reach Django admin. Fix may take hours.
2. **Full outage** — Backend is unreachable. Even previously logged-in devices can't open most pages. Admin can't flip any flag because Django itself is down.

An existing `h5_maintenance_enabled` / `h5_maintenance_message` pair on `AppConfig` covers scenario 1 for the H5 site, but only takes effect because `App.vue` gates every H5 route on it. The Flutter mobile app currently has no equivalent.

This spec replaces the H5-only flags with a unified, cross-platform maintenance system and adds a non-blocking "service notice" banner that the Flutter App renders at the top of every **native** screen. H5 (and therefore WebView-hosted routes) deliberately does **not** render the banner — see §7 for the rationale.

## 2. Goals

- A single admin-controlled switch blocks both H5 and the Flutter App with a full-screen maintenance page.
- A separate admin-controlled switch displays a non-blocking marquee banner across every Flutter-native screen. WebView-hosted H5 routes (tasks, calendar, chores, etc.) intentionally skip the banner to keep the code path simple and avoid clashing with H5's sticky headers.
- The Flutter App also falls back to the maintenance page when the backend is unreachable, without any admin intervention (handles scenario 2).
- All admin controls live in `/admin/config/AppConfig/`.

## 3. Non-Goals

- Native Android Pad app (`pad/`) is **not** in scope for this spec.
- Scheduled / time-windowed maintenance (auto-on, auto-off) is not required. Admin toggles manually.
- Per-user or per-device targeting is not required.
- Localized content is out of scope — a single string/JSON payload applies to all users. Admin writes in English.

## 4. Config Schema

Four new fields on `AppConfig` (in [backend/pronext/config/models.py](../../../backend/pronext/config/models.py)). The existing `h5_maintenance_enabled` and `h5_maintenance_message` are **removed** — no backwards-compat shim, both H5 and App are upgraded together.

| Field | Type | Default | Purpose |
|---|---|---|---|
| `maintenance_enabled` | BooleanField | `False` | Full-screen maintenance mode for both H5 and Mobile App |
| `maintenance_content` | JSONField | `dict` (`{}`) | Structured content for the maintenance page |
| `service_notice_enabled` | BooleanField | `False` | Show the top-of-screen service notice banner |
| `notice_content` | CharField(500) | `""` | Service notice banner text (single line, marquee scroll) |

### 4.1 `maintenance_content` JSON shape

```json
{
  "title": "We're upgrading",
  "body": "Some services are temporarily unavailable. We'll be back shortly.",
  "footer": "Need help? info@pronextusa.com"
}
```

- All three keys are optional strings. `\n` is allowed for line breaks in `body`.
- Renderers (H5 & App) MUST fall back to a sensible English default for any missing / empty key.
- Future fields (icon, CTA button, ETA) can be added without breaking clients.

### 4.2 Migration

One migration file: `0xxx_maintenance_refactor.py` that:

1. Adds the four new fields with the defaults above.
2. Removes `h5_maintenance_enabled` and `h5_maintenance_message`.

No data preservation — these two fields control operator-facing toggles, not user data.

## 5. API

### 5.1 `GET /common/config/` (existing)

No code change. `AppConfigSerializer` uses `fields = '__all__'`, so the four new fields appear automatically. Permission stays open (`permission_classes=[]`) so unauthenticated clients can fetch the config.

### 5.2 `GET /common/health/` (new)

```python
@action(["get"], detail=False, permission_classes=[])
def health(self, request):
    return Response({"status": "ok"})
```

- No auth required.
- Does **not** read the database or Redis. Purpose is to detect "Django process alive" only.
- If Django is down the endpoint is unreachable (connection refused / timeout), which is exactly the signal the App needs.

## 6. State Machine (per client)

Both H5 and App share the same high-level states:

```
                 ┌──────────────────────────┐
                 │      Normal              │
                 │ (router-view / Navigator │
                 │  renders app content)    │
                 └────────────┬─────────────┘
                              │
                     service_notice_enabled
                     AND notice_content != ""
                              │
                              ▼
                 ┌──────────────────────────┐
                 │   Normal + top banner    │
                 │  (content still usable)  │
                 └────────────┬─────────────┘
                              │
                 maintenance_enabled = true
                 OR (App only) backend unreachable
                              │
                              ▼
                 ┌──────────────────────────┐
                 │   Full-screen            │
                 │   Maintenance            │
                 │ (everything else hidden) │
                 └──────────────────────────┘
```

Priority: **maintenance > notice**. When maintenance is on, the notice banner is not shown (the maintenance page is already the whole screen).

## 7. H5 Implementation

### 7.1 `useMaintenance.js` → `useAppConfig.js` (rename + extend)

File: [h5/src/composables/useMaintenance.js](../../../h5/src/composables/useMaintenance.js) → `h5/src/composables/useAppConfig.js`.

Expose a single reactive object:

```js
const state = ref({
  maintenanceEnabled: false,
  maintenanceContent: { title: '', body: '', footer: '' },
  serviceNoticeEnabled: false,
  noticeContent: '',
})
```

Keep the existing fetch-once + manual-refetch pattern, plus the existing fail-open policy (any error leaves all flags `false` so users aren't locked out by a transient glitch).

### 7.2 `MaintenanceScreen.vue` (rewrite)

File: [h5/src/components/MaintenanceScreen.vue](../../../h5/src/components/MaintenanceScreen.vue).

- Drop the `message: String` prop.
- Add `content: { type: Object, default: () => ({}) }`.
- Render `content.title` / `content.body` / `content.footer` with fallbacks:
  - `title` → `"We're upgrading"`
  - `body` → `"Some services are temporarily unavailable. We'll be back shortly."`
  - `footer` → `"Need help? info@pronextusa.com"` (keeps the mailto link)
- Keep the "Check Again" button and 30s background polling.

### 7.3 `ServiceNoticeBar.vue` — **not implemented**

Originally this section specced an H5 marquee banner. During implementation we decided **H5 does not render the banner** at all:

- H5 is only reached inside the Flutter WebView; adding another banner inside H5 would either duplicate or clash with H5 sticky headers (e.g. calendar).
- The Flutter WebView host (`MixWebView`) also intentionally skips the banner, so WebView-backed routes show no banner by design.
- The banner is therefore a **Flutter-native-only** feature (home, profile, login, settings, etc. — anything wrapped by `XPage`).

No component file exists; `App.vue` must not import or render one.

### 7.4 `App.vue` composition

File: [h5/src/App.vue](../../../h5/src/App.vue).

```vue
<template>
  <div id="app">
    <div class="bg-[url('@/assets/bg.png')] ..."></div>
    <MaintenanceScreen v-if="config.maintenanceEnabled" :content="config.maintenanceContent" />
    <template v-else>
      <router-view />
    </template>
  </div>
</template>
```

H5 only renders the full-screen MaintenanceScreen (belt-and-suspenders for older Flutter builds without `maintenance_enabled` support). Normal content is handled by `router-view` directly — no banner wrapper.

## 8. Flutter App Implementation

### 8.1 `RemoteConfig` extension

File: [app/lib/src/manager/remote_config.dart](../../../app/lib/src/manager/remote_config.dart).

Add four fields to `RemoteConfig`:

```dart
@JsonKey(name: 'maintenance_enabled', defaultValue: false)
final bool maintenanceEnabled;

@JsonKey(name: 'maintenance_content', defaultValue: <String, dynamic>{})
final Map<String, dynamic> maintenanceContent;

@JsonKey(name: 'service_notice_enabled', defaultValue: false)
final bool serviceNoticeEnabled;

@JsonKey(name: 'notice_content', defaultValue: '')
final String noticeContent;
```

Re-run `build_runner` to regenerate `remote_config.g.dart`. The existing `MRemoteConfig().config` is already `Rx<RemoteConfig>`; UI subscribes via `Obx`.

The existing refresh cadence (5 min via `MRemoteConfig` internal timer) stays — admin toggles take at most 5 min to reach already-running App sessions, plus any manual "Check Again" tap.

### 8.2 `HealthMonitor` (new)

File: `app/lib/src/manager/health_monitor.dart`.

```dart
class HealthMonitor {
  static final _instance = HealthMonitor._();
  factory HealthMonitor() => _instance;
  HealthMonitor._();

  final reachable = true.obs;              // Optimistic at start
  int _consecutiveHealthFails = 0;
  final List<DateTime> _recentRequestFailures = [];
  Timer? _timer;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => pingHealth());
    pingHealth();                          // Immediate first ping
  }

  Future<void> pingHealth() async {
    try {
      final res = await Cnnt().httpClient
          .get('/common/health/', /* 5s timeout */);
      if (res.statusCode == 200) {
        _consecutiveHealthFails = 0;
        _recentRequestFailures.clear();
        reachable.value = true;
        return;
      }
    } catch (_) {
      // fall through
    }
    _consecutiveHealthFails++;
    _evaluate();
  }

  void reportRequestFailure() {
    final now = DateTime.now();
    _recentRequestFailures.add(now);
    _recentRequestFailures.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 15),
    );
    _evaluate();
  }

  void _evaluate() {
    if (_consecutiveHealthFails >= 3 || _recentRequestFailures.length >= 2) {
      reachable.value = false;
    }
  }
}
```

Decision thresholds:
- **3 consecutive** `/health/` failures (minute-scale) OR **2 request failures within 15 seconds** (second-scale) → `reachable = false`.
- Any single `/health/` success → `reachable = true` and counters reset.

### 8.3 `Cnnt` hook

File: [app/lib/src/base/cnnt.dart](../../../app/lib/src/base/cnnt.dart).

In `_request`'s catch block and on 5xx responses, call:

```dart
HealthMonitor().reportRequestFailure();
```

This lets an in-flight user request surface a backend outage in seconds rather than waiting up to 60s for the next health poll.

### 8.4 `MaintenanceScreen` widget (new)

File: `app/lib/src/widget/maintenance_screen.dart`.

- Full-screen `CupertinoPageScaffold` / white background.
- Centered column: wrench icon → `title` → `body` → "Check Again" button → `footer` (mailto link).
- Reads `content: Map<String, dynamic>` prop; applies the same string fallbacks defined for H5 (§7.2).
- "Check Again" button awaits `MRemoteConfig().refresh()` and `HealthMonitor().pingHealth()` in parallel, shows a `CupertinoActivityIndicator` until both return.

### 8.5 `ServiceNoticeBar` widget (new)

File: `app/lib/src/widget/service_notice_bar.dart`.

- `Container` height ~36pt, background `Color(0xFFFEF3C7)`, text `Color(0xFF92400E)`.
- Leading: `📣` + `🔧` emojis (match the mockup exactly — no asset files needed).
- Text:
  - If it fits: center it, static.
  - If it overflows: wrap in a `SingleChildScrollView(scrollDirection: Axis.horizontal)` driven by a `ScrollController` that loops left-to-right with a pause between cycles.
- Props: `text: String`. No close button.

### 8.6 `main.dart` composition

File: [app/lib/main.dart](../../../app/lib/main.dart).

In `main()`, after `await MRemoteConfig().initialize();`, add:

```dart
HealthMonitor().start();
```

Wrap the `GetCupertinoApp` with a `builder`:

```dart
GetCupertinoApp(
  // ... existing params ...
  builder: (context, child) {
    return Obx(() {
      final cfg = MRemoteConfig().config.value;
      final reachable = HealthMonitor().reachable.value;
      final showFullScreen = cfg.maintenanceEnabled || !reachable;
      final showNotice =
          cfg.serviceNoticeEnabled && cfg.noticeContent.isNotEmpty;

      if (showFullScreen) {
        return MaintenanceScreen(content: cfg.maintenanceContent);
      }
      return Column(
        children: [
          if (showNotice) ServiceNoticeBar(text: cfg.noticeContent),
          Expanded(child: child!),
        ],
      );
    });
  },
)
```

Because this wraps the Navigator, the maintenance full-screen view replaces the entire Navigator subtree — there is no route the user can swipe back to. The **banner**, however, is rendered inside `XPage` (the shared page scaffold for native screens), not in the top-level `builder` — so only Flutter-native routes (login, home, profile, settings, etc.) inherit it. `MixWebView` (the `/web` host) intentionally does not use `XPage` and therefore shows no banner, which is consistent with H5 deliberately not rendering one either (§7.3).

## 9. Failure Modes

| Scenario | Behavior |
|---|---|
| `/common/config/` returns 4xx/5xx | Clients fall back to the last cached config (App) or `enabled: false` (H5). Fail-open. |
| `/common/config/` times out | Same as above. |
| Backend fully down | App: `HealthMonitor` flips `reachable = false` within ~15 s if any user request hits the outage, or within ~3 minutes on a fully idle app (three consecutive health polls at 60 s intervals). Result: MaintenanceScreen. H5: fetchMaintenance fails-open so notices don't show, but H5 is typically unreachable anyway if backend is down. |
| Admin flips `maintenance_enabled` during active session | App sees it on next `MRemoteConfig.refresh()` (≤ 5 min) or on a "Check Again" tap. H5 sees it on next page reload or 30s poll from inside MaintenanceScreen. |
| Banner text contains malicious HTML | Both renderers display as plain text; no `v-html` / `Html.fromHtml` usage. |
| JSON content has unexpected keys | Ignored. Missing keys fall back to hardcoded English defaults. |

## 10. Testing

### 10.1 Backend (automated)

- `test_config_api.py::test_includes_new_fields` — `GET /common/config/` returns the four new keys with correct defaults.
- `test_health_api.py::test_returns_ok_unauthenticated` — `GET /common/health/` returns `200 {"status":"ok"}` without any auth header.
- `test_config_model.py::test_defaults` — a freshly-created `AppConfig.shared()` has `maintenance_content == {}` and `notice_content == ""`.

### 10.2 H5 (manual)

Run the H5 dev server, flip admin flags, verify:
1. `maintenance_enabled=true` → every H5 route shows MaintenanceScreen.
2. `service_notice_enabled=true` + non-empty `notice_content` → H5 shows **no** banner by design (banner is Flutter-native-only).
3. Both off → normal.

### 10.3 Flutter App (manual)

On a dev build:
1. `maintenance_enabled=true` → App (including login page) shows MaintenanceScreen.
2. `service_notice_enabled=true` + text → every **native** Flutter page (login, home, profile, settings, etc.) shows banner. WebView-hosted routes (tasks, calendar, chores) deliberately show no banner.
3. Stop Django (`docker compose stop api`) → trigger any user action that fires an API request and App flips to MaintenanceScreen within ~15 s (two request failures in the 15 s window). If the app is left idle, it flips after ~3 min (three consecutive health pings fail at 60 s intervals).
4. Start Django again → next `/health/` poll flips back to normal automatically.
5. Both flags on → MaintenanceScreen.
6. "Check Again" in MaintenanceScreen triggers a config refresh + health ping.

## 11. Rollout

1. Merge backend PR first — old clients just get extra fields they ignore; removal of `h5_maintenance_*` temporarily disables the H5 maintenance page for any H5 client on the old bundle.
2. Merge H5 PR — restores H5 maintenance page on the new schema.
3. Merge App PR (gated by version ≥ next release) — brings mobile support.
4. Admin can start using the new toggles once all three are deployed.

Between step 1 and step 2, if a true emergency forces maintenance mode before the H5 PR ships, the H5 site won't show the full-screen page (fail-open). Service-notice banner (the new, non-blocking mechanism) can be used instead.

## 12. Open Questions

None. All design decisions are resolved in sections 4–9.
