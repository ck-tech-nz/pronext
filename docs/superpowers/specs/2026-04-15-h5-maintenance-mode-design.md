# H5 Maintenance Mode — Design

**Date:** 2026-04-15
**Scope:** h5 global route-level gate + backend `AppConfig` fields
**Motivation:** Provide an emergency "kill switch" so operators can block every H5 page behind an "Upgrading…" screen without releasing a new mobile-app build.

---

## Goal

When a server-side flag is flipped on, every H5 page — Calendar, Tasks, Meal, Settings, anything under `<router-view>` — is replaced by a full-screen "Upgrading…" message. The screen has a "Check Again" button and auto-polls every 30 seconds, so when the operator flips the flag back off the user recovers without restarting the app. Operators control the flag and the displayed message from the Django admin.

## Non-Goals

- No per-module / per-page toggle. A single global boolean.
- No maintenance gating of native Flutter-app screens (this design only covers H5 routes; the native onboarding screen that appears on `/device/list` failures is a separate concern).
- No ETA / countdown display.
- No multi-language support for the copy.
- No changes to Pad, the Flutter app, or the heartbeat service.

## Architecture

```
Django Admin (AppConfig)                 H5 App (WebView)
    |                                        |
    | sets h5_maintenance_enabled            |
    | sets h5_maintenance_message            |
    v                                        |
AppConfig JSON row                           |
    |                                        |
    | read on each request                   |
    v                                        |
GET /app-api/common/config/                  |
  (existing unauthenticated endpoint,        |
   returns full AppConfig JSON)              |
    ---------------------------------------->|
                                             |
                                             v
                              App.vue : useMaintenance()
                                             |
                                             v
                              maintenance.enabled ?
                                  true  -> <MaintenanceScreen message=... />
                                  false -> <router-view />
                                             |
                                             v
                          MaintenanceScreen (while mounted):
                            - dismisses stray loading toast on mount
                            - polls refetch() every 30s
                            - "Check Again" button for immediate refetch
                            - support email link
```

## Why a top-level `App.vue` gate

The initial instinct was to gate just the H5 Dashboard, reasoning that it's the sole entry into H5 feature pages. That turned out to be wrong in practice — the current Flutter app bypasses the H5 Dashboard entirely and opens Calendar (or other pages) directly. A page-level gate on any single page would miss the actual entry route.

A top-level `App.vue` `v-if/v-else` on `<router-view>` catches every H5 route with one edit and is immune to future Flutter navigation changes. The performance cost is one extra call to `/common/config/` on app load (shared with any other future consumer via a module-level singleton ref).

## Backend Changes

### `backend/pronext/config/models.py` — `AppConfig`

Two new fields, shipped in commit `f299601`:

```python
h5_maintenance_enabled = models.BooleanField(
    default=False,
    help_text='H5 maintenance mode switch (replaces every H5 page with a full-screen notice)',
)
h5_maintenance_message = models.CharField(
    default='We are upgrading the service. Please check back soon.',
    max_length=255,
    help_text='Message shown on the H5 maintenance screen',
)
```

`AppConfig` is a cache-backed JSON singleton (see `backend/pronext/config/options.py`). `AppConfig.shared()` reads; `AppConfig.update(cfg)` writes. The admin form is auto-generated from `_meta.fields`, so new fields appear in `/admin/config/AppConfig/` without extra code.

### No new backend endpoint

The existing unauthenticated endpoint `GET /app-api/common/config/` (at `backend/pronext/common/viewset_app.py:58-62`) already returns the full `AppConfig` via `AppConfigSerializer(fields='__all__')`. Our two new fields are surfaced automatically.

### No migration

`AppConfig` is `abstract=True`; its data lives in a JSONField on the concrete `Config` model. No schema change is needed.

### Caveat: serializer exposure

`AppConfigSerializer` uses `fields='__all__'`. Every future `AppConfig` field is automatically served to unauthenticated clients on every page load. Our two new fields are low-sensitivity (a boolean and a short public message), so this is fine today, but future maintainers adding an `AppConfig` field should verify their field is intended for public exposure. Tightening the serializer to an explicit allow-list is an unrelated follow-up worth doing.

## Frontend Changes

### `h5/src/composables/useMaintenance.js` (new)

Module-level singleton: all consumers share one `ref({ enabled, message })`. Fetches once per page load via a `hasFetched` guard. Exposes `refetch()` for the Check Again button and the 30-second poll.

Fail-open at two layers: non-200 responses leave `enabled: false`, and a `try/catch` around the HTTP call handles network errors the same way.

### `h5/src/components/MaintenanceScreen.vue` (new)

Full-screen component:

- Gear icon + "Upgrading…" title + server-provided message (centered)
- "Check Again" button (primary, round, shows loading state during refetch, prevents double-tap)
- `mailto:info@pronextusa.com` support link pinned to the bottom
- `onMounted` calls `closeToast()` to dismiss any loading toast the just-swapped-out page left behind
- `setInterval(refetch, 30_000)` on mount, `clearInterval` on `onBeforeUnmount`

When `refetch()` returns `enabled=false`, App.vue's `v-if` unmounts the component, `onBeforeUnmount` clears the interval, and `<router-view>` takes over — the user is back to their original route.

### `h5/src/App.vue` (modified)

Two-line change inside `<script setup>` (import + call `useMaintenance`) and one-line template swap:

```vue
<MaintenanceScreen v-if="maintenance.enabled" :message="maintenance.message" />
<router-view v-else />
```

## Behavior Matrix

| Scenario | User sees |
| --- | --- |
| Flag off (default) | Normal app, plus one extra `/common/config/` call on launch. |
| Flag on, fresh app launch | 50–200ms of the real app (router-view renders while fetch is in-flight) then MaintenanceScreen swaps in. |
| Flag on, user already in app | Next page load or manual refresh triggers the gate. No active push from the server. |
| Flag flipped off while user is on MaintenanceScreen | Within ≤30 seconds the poll catches it and the user is returned to their route. Pressing Check Again makes this immediate. |
| `/common/config/` fails or returns malformed data | Fail-open: `enabled` stays false, normal app renders. |
| Backend deployment missing the new fields | Serializer still runs; `res.data.h5_maintenance_enabled` is `undefined` → falsy → normal app renders. |

## Recovery Paths (for reference)

1. **Active** — user taps Check Again → immediate refetch → if flag off, return to app
2. **Passive** — MaintenanceScreen polls every 30s while mounted → auto-recovers hands-free
3. **Cold restart** — user kills and reopens WebView → fresh `/common/config/` call on launch

## YAGNI — Explicitly Excluded

- Polling while the flag is OFF (no reason to check if no problem exists)
- Tri-state loading (would avoid the 50–200ms flash-of-real-app on launch but adds a blank screen on every normal launch — not worth the trade-off for an emergency tool)
- Per-module toggles
- Countdown / ETA
- i18n of the maintenance copy
- Pad, Flutter app, or heartbeat changes

## Risks & Mitigations

| Risk | Mitigation |
| --- | --- |
| Operator forgets to flip the flag back. | Admin toggle is prominent; help_text is explicit about what it does. |
| Operator saves an empty message string. | Backend default is non-empty; if wiped to `None`, `__getattribute__` on `AbstractConfig` falls back to the field default. |
| Older backend deployments without the fields. | Response omits keys harmlessly; frontend treats missing/undefined as falsy (fail-open). |
| Older H5 bundles (cached) without the gate. | Acceptable — maintenance only works after H5 update propagates. The backend change alone does not break anything for older bundles. |
| Stale `h5_maintenance_message` in production admin after a code-level default change. | Document that operators must clear/resave in admin to pick up new defaults. |
| Backend outage drops users to the native onboarding screen before any H5 page loads. | **Out of scope.** This design only covers H5 routes. The native onboarding screen is rendered by Flutter before the WebView opens, so H5 cannot intercept it. Addressing this requires a Flutter-side fix. |
| `AppConfigSerializer(fields='__all__')` may expose future `AppConfig` fields to unauthenticated clients. | Pre-existing. Worth tightening as a follow-up. Not a blocker for this feature. |

## Files Touched

| File | Change |
| --- | --- |
| `backend/pronext/config/models.py` | +2 fields on `AppConfig` |
| `h5/src/App.vue` | import composable + component; wrap `<router-view>` in `v-if/v-else` |
| `h5/src/composables/useMaintenance.js` | new — singleton state + fetch + refetch |
| `h5/src/components/MaintenanceScreen.vue` | new — full-screen UI + poll + retry + support link |

No schema migrations, no new endpoints, no tests (the H5 repo has no test harness; backend change is too small to warrant a dedicated test, covered implicitly by existing serializer roundtrips).

## Testing Plan

**Automated:** none (see above).

**Manual:**

1. `npm run dev` in h5, `python3 manage.py runserver` in backend.
2. Default flag off — open the app, confirm normal render.
3. Toggle `H5 maintenance enabled` on in `/admin/config/AppConfig/`, edit the message.
4. Hard-refresh or reopen the WebView — maintenance screen renders with custom message.
5. Tap Check Again — should re-fetch (verify in network tab).
6. Leave the app on maintenance screen for ≥30s — poll should fire automatically.
7. Toggle the flag off in admin — within 30s (or immediately after Check Again), the user returns to their original route.
8. Kill the backend — reload the WebView — normal route renders (fail-open).
