# Maintenance & Service Notice — Architecture

Technical reference for the maintenance/notice system. Operator-facing instructions live in [README.md](README.md).

## Source of truth

All state lives in `AppConfig` (Django, cached in Redis with 5-min TTL via `AbstractConfig.shared()`). No DB column — the whole config is stored as a single JSON blob on the `Config` table with key `"AppConfig"`. Admin edits go through `AppConfig.update(cfg)` which atomically writes the DB row and refreshes the Redis cache.

Fields used here:
- `maintenance_enabled` (bool)
- `maintenance_content` (JSON: `{title, body, footer}`)
- `service_notice_enabled` (bool)
- `notice_content` (string)

## Backend endpoints

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /app-api/common/config/` | None | Serves the whole `AppConfig` as JSON. Identical for every caller. |
| `GET /app-api/common/health/` | None | Liveness probe. Does not read DB or Redis — only confirms Django is up. Returns `{"status": "ok"}`. |

### Edge caching

`/common/config/` sets:

```
Cache-Control: public, max-age=30
```

Cloudflare (or any reverse proxy in front) absorbs the poll traffic. Consequences:

- Admin toggles propagate to the edge within 30s.
- Client polls mostly miss Django entirely.
- `AppConfig.shared()` itself has a 5-min Redis TTL, updated immediately on `AppConfig.update(cfg)` — so origin is always fresh the moment the CDN refreshes.

Combined worst-case lag from admin-save to visible-to-user: **30s edge TTL + client refresh cadence** (see below).

## Client state machine

Each client (Flutter, H5) is one of three states:

```
              ┌────────────────────┐
              │   Normal           │
              │ (regular routes,   │
              │  no banner)        │
              └───────┬────────────┘
                      │
       service_notice_enabled=true
       AND notice_content != ""
                      │
                      ▼
              ┌────────────────────┐
              │  Normal + banner   │
              │ (content usable)   │
              └───────┬────────────┘
                      │
       maintenance_enabled=true
       OR (Flutter only) HealthMonitor.reachable=false
                      │
                      ▼
              ┌────────────────────┐
              │ Full-screen        │
              │ MaintenanceScreen  │
              └────────────────────┘
```

Maintenance has priority. When both flags are on, maintenance takes over and the banner is hidden.

## Flutter App

### Config refresh triggers

The Flutter client hits `/common/config/` in these situations:

| Trigger | Frequency | Source |
|---|---|---|
| Cold start | once | `MRemoteConfig().initialize()` in `main()` |
| Idle poll | tick every 1 min, refresh only if >5 min stale | `MRemoteConfig.startQueue()` |
| App resumed from background | immediate | `AppLifecycleObserver.didChangeAppLifecycleState` |
| MaintenanceScreen visible | every 30 s | `_MaintenanceScreenState._pollTimer` |
| "Check Again" tap | on demand | `MaintenanceScreen._checkAgain()` |

All calls route through `MRemoteConfig.refresh()` which debounces with a 3 s floor: concurrent triggers collapse into a single request.

Typical daily traffic per idle user: ~5–10 requests. Edge-cached, so most don't reach Django.

### HealthMonitor

Flutter-only. Detects backend outages so the app can enter the maintenance screen without admin intervention.

- **Polling:** `GET /common/health/` every 60 s, 5 s request timeout.
- **Opportunistic signal:** `Cnnt._request` calls `HealthMonitor().reportRequestFailure()` whenever a normal API call returns `statusCode == null` (connection refused / timeout) or `>= 500`. This excludes `/common/health/` itself to avoid self-feedback.
- **Flip to `reachable = false`:** when **3 consecutive health pings fail** (~3 min on an idle client) **OR** **2 request failures within a 15 s window** (~seconds on an active client hitting the outage).
- **Flip back to `reachable = true`:** one successful health ping resets both counters.

The `reachable` state is an `Rx<bool>` watched by the root `Obx` in `main.dart`'s `GetCupertinoApp.builder`, so the transition to/from MaintenanceScreen happens immediately without manual wiring.

### Widget placement

```
GetCupertinoApp
 └─ builder: Obx (top-level gate)
    ├─ if maintenance_enabled || !reachable → MaintenanceScreen (replaces Navigator entirely)
    └─ else → child (Navigator)
         └─ XPage (wrapper used by every page)
            ├─ CupertinoNavigationBar
            └─ Container (top padding = safe_area + 44pt)
               └─ Obx
                  ├─ if service_notice_enabled && notice_content → ServiceNoticeBar
                  └─ Expanded(child: scrollChild)
```

Key point: the **banner lives inside `XPage`, below the nav bar**. An earlier version placed the banner above the Navigator; that produced a large visual gap because every page's `CupertinoPageScaffold` already pads content by `safe_area.top + 44pt` (nav bar height). The banner was being added on top of that without adjusting the nav bar's own layout, so the two padding regions stacked.

Consequence: routes that **don't** use `XPage` — notably `MixWebView` (the `/web` host) — show no banner. This is intentional. The WebView is left to render full-bleed so H5's own nav bar and sticky headers aren't pushed around by something the WebView's layout doesn't know about.

The MaintenanceScreen replacement happens at the top level (outside `XPage`) because it needs to take over the entire app, not just the current page.

### Important files

| File | Purpose |
|---|---|
| [app/lib/src/manager/remote_config.dart](../../app/lib/src/manager/remote_config.dart) | Config fetch + refresh timer + debounce |
| [app/lib/src/manager/health_monitor.dart](../../app/lib/src/manager/health_monitor.dart) | Outage detection |
| [app/lib/src/base/cnnt.dart](../../app/lib/src/base/cnnt.dart) | Hook that calls `HealthMonitor.reportRequestFailure()` on 5xx / null status |
| [app/lib/src/widget/maintenance_screen.dart](../../app/lib/src/widget/maintenance_screen.dart) | Full-screen widget with 30 s poll |
| [app/lib/src/widget/service_notice_bar.dart](../../app/lib/src/widget/service_notice_bar.dart) | Marquee widget |
| [app/lib/src/widget/common.dart](../../app/lib/src/widget/common.dart) | `XPage` — hosts the banner below the nav bar |
| [app/lib/main.dart](../../app/lib/main.dart) | Top-level gate + resume hook |

## H5 (Vue WebView)

Runs inside the Flutter mobile app's WebView only — never standalone.

### Config refresh
Fetch-once on mount via `useAppConfig` composable. Fail-open: any non-200 response leaves all flags at their safe defaults so a transient error doesn't lock users out.

### What's rendered

| Element | Rendered in H5? | Why |
|---|---|---|
| `MaintenanceScreen` | ✅ Yes | Fallback for older Flutter builds that don't yet support the top-level gate |
| `ServiceNoticeBar` | ❌ No | The Flutter shell only renders a banner on native `XPage` routes, not above the WebView. H5 is deliberately left banner-less to avoid clashing with its own sticky headers (calendar's Week/Month toggle). |

The MaintenanceScreen polls `/common/config/` every 30s while visible, matching Flutter's behavior.

### Important files

| File | Purpose |
|---|---|
| [h5/src/composables/useAppConfig.js](../../h5/src/composables/useAppConfig.js) | Config fetcher (fail-open) |
| [h5/src/components/MaintenanceScreen.vue](../../h5/src/components/MaintenanceScreen.vue) | Full-screen with 30 s poll |
| [h5/src/App.vue](../../h5/src/App.vue) | Mount MaintenanceScreen when `maintenanceEnabled` |

## Detection thresholds (Flutter HealthMonitor)

Constants in [health_monitor.dart](../../app/lib/src/manager/health_monitor.dart):

```dart
static const Duration _pollInterval = Duration(seconds: 60);
static const Duration _pingTimeout = Duration(seconds: 5);
static const Duration _failureWindow = Duration(seconds: 15);
static const int _healthFailThreshold = 3;
static const int _requestFailThreshold = 2;
```

Tweak these if outage detection feels too eager or too slow. Keep:
- `_healthFailThreshold × _pollInterval` ≥ 2 min so intermittent network blips don't trip it.
- `_requestFailThreshold` ≤ 3 so active users see the outage quickly.

## Propagation latency (admin → user)

Worst-case time from admin clicking "Save" to the user seeing the change:

| User state | Flutter | H5 |
|---|---|---|
| Idle, app foreground | 5 min (idle timer) + 30 s (edge cache) = **~5.5 min** | Same, relies on MaintenanceScreen poll only if on that screen; otherwise only sees on navigation |
| Backgrounded, comes back | 30 s (edge cache) on resume hook → **~30 s** | Page reload hits fresh fetch |
| Active, already on MaintenanceScreen | 30 s (poll) + 30 s (edge) = **~60 s** | Same |

Active, non-maintenance navigation in Flutter does **not** refresh config — we rely on the idle timer + resume hook to keep server load predictable.

## Testing

### Backend (automated)
Three test classes in [backend/pronext/common/tests.py](../../backend/pronext/common/tests.py):
- `HealthEndpointTest` — 200 response + DB/cache isolation regression guard
- `ConfigEndpointFieldsTest` — contract (new fields present, old `h5_*` gone, Cache-Control header set)

And [backend/pronext/config/tests.py](../../backend/pronext/config/tests.py):
- `AppConfigMaintenanceRefactorTest` — model fields present with correct defaults, old fields removed

Run: `python3 manage.py test`.

**Gotcha:** tests share Redis with dev. If you've toggled AppConfig in dev via shell/admin, the leftover cache can fail `test_exposes_maintenance_and_notice_fields`. Clear with:

```bash
python3 manage.py shell -c "from django.core.cache import cache; cache.delete('AppConfig')"
```

### Flutter (manual)
No automated widget tests. Exercise the 6-scenario matrix in [README.md § Testing](README.md#testing-manual-checklist) before merging to main.

### H5 (manual)
Run `npm run dev`, reload on admin toggle, check MaintenanceScreen full-screen takeover for `maintenance_enabled=true`.

## Rollout order

Because the schema is fully replaced (no `h5_maintenance_*` shim):

1. Deploy Django first — old clients get the new fields in config responses but may not read them. Old `h5_maintenance_*` is gone, so old H5 bundles temporarily lose their maintenance page (fail-open).
2. Deploy H5 — restores H5 maintenance page under the new schema.
3. Deploy Flutter — gains native MaintenanceScreen + HealthMonitor auto-outage detection + service notice banner.

Between steps 1 and 2, if a real emergency needs maintenance, use the service notice banner instead (it's the new mechanism and doesn't rely on the old schema).

## Non-goals (deferred / not supported)

- **Pad (Android Kotlin)** — not touched. Pads continue to operate normally regardless of the flags.
- **Per-user / per-device targeting** — not supported. Flags apply globally.
- **Time-windowed auto-toggle** — not supported. Admin toggles manually.
- **Localization** — English only. Admin writes in English.
