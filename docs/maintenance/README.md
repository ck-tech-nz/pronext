# Maintenance Mode & Service Notice

Two operator-controlled mechanisms for communicating service health to end users:

- **Maintenance mode** — full-screen takeover that blocks the entire app. Use for planned downtime or when a critical issue makes the product unusable.
- **Service notice** — non-blocking yellow marquee banner shown above page content. Use for partial issues where the product still works but the team wants to set expectations.

Both are toggled independently from Django admin. The two are orthogonal; maintenance mode has priority and hides the banner when both are on.

## Where it's deployed

| Platform | Maintenance screen | Service notice banner |
|---|---|---|
| Flutter App — native pages (home, profile, login, settings, etc.) | ✅ Blocks the entire app, including login | ✅ Rendered by `XPage` between nav bar and content |
| Flutter App — WebView host (`/web` routes: tasks, calendar, chores, etc.) | ✅ Maintenance view replaces the whole Navigator, so WebView is blocked too | ❌ Not rendered — WebView is left alone to avoid clashing with H5 sticky headers |
| H5 (inside WebView) | ✅ Full-screen takeover (fail-safe for older Flutter builds) | ❌ Not rendered — H5 has no banner component by design |
| Heartbeat microservice | — | — |
| Pad (Kotlin) | — | — |

## Admin configuration

Go to `/admin/config/AppConfig/` on Django admin.

| Field | Type | Default | Purpose |
|---|---|---|---|
| `maintenance_enabled` | bool | false | Full-screen maintenance mode toggle |
| `maintenance_content` | JSON | `{}` | Content for the maintenance page |
| `service_notice_enabled` | bool | false | Banner toggle |
| `notice_content` | string | `""` | Single-line banner text |

### `maintenance_content` shape

```json
{
  "title": "We'll be back shortly",
  "body": "We're rolling out a small upgrade.\nYou'll be back in a few minutes.",
  "footer": "Need help sooner? Reach us at info@pronextusa.com"
}
```

- All three keys are optional. Missing/empty keys fall back to hardcoded English defaults.
- `\n` in `body` renders as a line break.
- Keep content in English.

### `notice_content` guidance

Single-line text. Scrolls as a marquee if it overflows.

- **Don't promise timing** — you rarely know when it'll be fixed.
- **Describe impact** — e.g. "Sync may be delayed"
- **Reassure about data** — e.g. "Your data is safe"

## Operational playbook

### Show the notice banner

1. `/admin/config/AppConfig/` → set `service_notice_enabled = True`
2. Set `notice_content` to a short message (see [content templates](#content-templates))
3. Save. Banner appears on the next client refresh (up to 30s edge cache + client refresh delay; see [ARCHITECTURE.md](ARCHITECTURE.md)).

### Hide the banner

1. Uncheck `service_notice_enabled` and save. Content can stay for reuse.

### Enter maintenance mode

1. Set `maintenance_content` JSON first (so users see something meaningful immediately).
2. Tick `maintenance_enabled` → save.

### Exit maintenance mode

1. Untick `maintenance_enabled` → save.
2. Clients automatically leave the maintenance screen:
   - Flutter: MaintenanceScreen polls every 30s; users return to the app within 30s.
   - H5: MaintenanceScreen polls every 30s (same behavior).

## Content templates

### Maintenance content

**Planned upgrade:**
```json
{
  "title": "We'll be back shortly",
  "body": "We're rolling out a small upgrade to keep Pronext running smoothly. You'll be back in the app in a few minutes — no data is lost.",
  "footer": "Need help sooner? Reach us at info@pronextusa.com"
}
```

**Emergency fix:**
```json
{
  "title": "A quick fix in progress",
  "body": "We hit an unexpected hiccup and are working on it right now. Your calendar and tasks are safe — we'll have you back very soon.",
  "footer": "Questions? Drop us a line at info@pronextusa.com"
}
```

**Database migration:**
```json
{
  "title": "Giving Pronext an upgrade",
  "body": "We're migrating to a faster system so schedules and photos load quicker for your whole family.\nThis should take less than 15 minutes.",
  "footer": "Thanks for your patience — info@pronextusa.com"
}
```

### Service notice text (no timing, no promises)

- `We're aware of a service issue and working on a fix. Your data is safe — thanks for bearing with us.`
- `Sync may be delayed right now — we're working on a fix.`
- `Some features may be slow or unavailable. We're working to restore them.`
- `We're working on a known issue affecting sync and notifications. Thanks for your patience — your data is safe.`

## What users see

### Flutter App (normal)
Home screen with the bar sitting right below the "avatar | title | menu" nav bar, above the shortcuts grid. Yellow background, wrench + megaphone emojis, text scrolling right-to-left.

### Flutter App (maintenance)
Entire Navigator is replaced by the maintenance screen. Wrench icon, title, body (multi-line), "Check Again" button, footer at bottom. Tapping "Check Again" triggers an immediate config refresh + health ping.

### Flutter App (backend unreachable, no admin toggle)
Same maintenance screen, but content uses the hardcoded English defaults (admin hasn't written anything). Auto-exits when backend comes back.

### H5 (maintenance)
H5 pages inside the WebView also show a full-screen maintenance screen when `maintenance_enabled=true`. This is a fallback for older Flutter builds that don't yet support the new gate.

## Testing (manual checklist)

Quick smoke test after any change to the maintenance/notice code path:

| # | State | Admin flags | Expected |
|---|---|---|---|
| 1 | Normal | all off | Normal home screen, no banner |
| 2 | Notice only | `service_notice_enabled=true` + text | Yellow banner on every native Flutter page (including login); WebView-hosted routes (tasks, calendar, chores) deliberately show no banner |
| 3 | Maintenance only | `maintenance_enabled=true` + content | Full-screen maintenance; no banner |
| 4 | Both on | both true | Full-screen maintenance (banner hidden) |
| 5 | Outage | all off, stop Django | Flutter auto-enters maintenance in ≤ 15s if any request hits outage, ≤ 3 min idle |
| 6 | Recovery | all off, restart Django | Flutter auto-exits maintenance in ≤ 60s |

See [ARCHITECTURE.md](ARCHITECTURE.md) for details on how detection works.

## Related documents

- [ARCHITECTURE.md](ARCHITECTURE.md) — refresh cadence, edge caching, HealthMonitor thresholds
- Original spec: `docs/superpowers/specs/2026-04-17-maintenance-and-service-notice-design.md`
- Implementation plan: `docs/superpowers/plans/2026-04-17-maintenance-and-service-notice.md`
