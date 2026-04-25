# Third-Party Synced Calendar Event Color — Design Spec

**Date**: 2026-04-26
**Status**: Approved, ready for implementation plan
**Scope**: backend + Pad (Kotlin); H5 / App / Flutter unchanged

---

## 1. Goal

Restore and extend per-event color synchronization for third-party calendars
(Google + Outlook) on Pad and H5/App, after the original behavior regressed in
2026-Q1 with the introduction of the `/upload_synced` Pad-direct sync path.

Concretely:

- Google event with explicit `colorId` (e.g. user picked "Basil" green) shows
  the same color in Pronext as in Google Calendar
- Outlook event with one or more `categories` shows the user's per-category
  preset color(s) in Pronext, including multi-category stripes
- Calendar-level color (e.g. user gives the whole calendar a default color)
  remains as today (out of scope changes)
- Write-back to upstream providers does **not** include color (Pad/App UI
  doesn't yet support setting event colors)

---

## 2. Background — current state

### 2.1 Storage and rendering pipeline (already in place)

```
Provider API event ──→ sync code ──→ Event.color (CharField)
                                         │
                          ┌──────────────┴──────────────┐
                          ↓                             ↓
                 Backend serializer              Pad Room (mirror)
                          │                             │
                          ↓                             ↓
                  H5 / App rendering              Pad rendering
```

Both H5 (`h5/src/managers/calendar.js:317`) and Pad (`drawMultiColorBackground`
in WeekView) consume `event.color` as a comma-separated hex string:

```js
e.color = (e.color !== undefined && e.color !== null && e.color !== '')
  ? e.color
  : e.categories.map(c => c.color).reverse().join(',')
```

Multi-color stripe support already exists; `Event.color` overrides
category-aggregated color when set.

### 2.2 The two write paths and their divergence

| Path | Triggered by | Translates colorId? |
|---|---|---|
| **Old**: `POST /sync_link_calendar/` → Celery → `options.sync_calendar` | Cloudflare Worker / Go google_syncer | ✅ Yes (`get_google_color`) |
| **New**: `POST /upload_synced/` → `Event.objects.create(**data)` | Pad Kotlin direct sync | ❌ No (Pad doesn't translate) |

The new path was introduced 2026-03 (commit `50efd02`) and accelerated event
creation but the Pad client never translated `colorId → hex`, leaving 86% of
April-2026 events with `color=NULL`.

### 2.3 Provider color models (verified)

| Provider | Event-level | Calendar-level | Notes |
|---|---|---|---|
| **Google** | `colorId: "1".."11"` (string) | `colorId: "1".."24"` + `backgroundColor` (per-user, can be custom hex) | `/colors` palette confirmed **global** — verified across 3 different accounts on 2026-04-26; `updated: 2012-02-14` (14 years stable) |
| **Outlook** | `categories: ["name", ...]` | `color: "lightBlue"` enum + `hexColor` | Event has only category names; preset color lives in **per-user** `/me/outlook/masterCategories` |
| **iCloud** | `COLOR:` (RFC 7986, near-zero usage) | `X-APPLE-CALENDAR-COLOR` (custom XML) | Event-level color effectively does not exist in practice |
| **ICS/url** | Same as iCloud | `X-APPLE-CALENDAR-COLOR` | Same |

Existing `enums.py:google_color_hex` was hand-transcribed from a "modern"
palette that does **not** match the `/colors` API response. We replace it with
the API-faithful palette.

---

## 3. Architectural decisions

The discussion converged on these, with the rationale beside each:

### 3.1 Store translated hex, not raw provider value

**Decision**: `Event.color` continues to store final hex strings
(`"#0078D4,#E81123"`), translated at sync time. We do **not** introduce a
`provider:value` self-describing format.

**Rationale**:

- Render path stays trivial: serializer passes through, Pad reads from Room.
  Zero translation cost on the hot path.
- The architectural "purity" benefit of raw storage (always re-translatable on
  palette change) is offset by the practical reality: Outlook category color
  changes propagate within one sync interval, which is acceptable to product.
- Existing 24k events already store hex; no migration needed for old data.
- Keeps three platforms simpler: backend, Pad Room, H5 renderer all unchanged
  in shape.

**Trade-off acknowledged**: when a user changes their Outlook `masterCategories`
color mapping, displayed colors are stale until the next sync (≤ ~1h on
backend with cache, ≤ Pad sync interval on device). Product accepts this.

### 3.2 Palette tables hardcoded in `enums.py`, not a DB model

**Decision**: `google_color_hex` and `outlook_preset_hex` are Python module
constants. No `ColorPalette` model.

**Rationale (YAGNI)**:

- Google palette has not changed since 2012-02-14
- Outlook preset hex is a fixed Microsoft client convention
- A DB model would buy us "edit at runtime" which is not a current requirement,
  and adding a provider still requires code (parser, sync integration) so the
  data-only flexibility is illusory
- If runtime edit becomes a real need, the current dict structure is trivially
  extractable to a model later (Rule of Three)

### 3.3 Use the palette returned by Google's `/colors` API, not Pronext's
historical "modern" hex

**Decision**: Replace existing `google_color_hex` values with what
`GET /calendar/v3/colors` returns.

**Rationale**:

- The current values in `enums.py` (e.g. `"10": "#0b8043"`) were transcribed
  manually in PR #222 (2025-08-26) and don't match Google's API
- The API values (e.g. `"10": "#51b749"`) are what Google itself considers
  authoritative
- We accept that Google's mobile/web UI may render slightly different shades
  via its modern Material palette; aligning to API is more defensible than
  guessing at UI-perceived colors

### 3.4 Drop the `"undefined"` sentinel in `google_color_hex`

`get_google_color()` looks up `google_color_hex.get(color_id, "")` where
`color_id` is `None` for events without the field. The string key `"undefined"`
is never queried — it's dead code. Removing it lets events without `colorId`
fall through to category-color fallback in the renderer, which is more correct
than forcing a default blue.

### 3.5 Outlook masterCategories: cache by `(user_id, email)`, not by sc_id

`masterCategories` is owned by a Microsoft account (an email), not by an
individual calendar. A user with multiple Outlook calendars under the same
account shares one mapping. Cache key:

```
outlook:master_categories:{user_id}:{email}
```

TTL 1h. Cache miss triggers MS Graph fetch; failure returns empty dict
gracefully (callers degrade to "no event color, fallback to category color").

---

## 4. Phase 1 — Restore Google (Commit 1)

Self-contained: ships a working fix for the regression without touching
Outlook.

### 4.1 Files changed

| File | Change |
|---|---|
| `backend/pronext/calendar/enums.py` | Replace `google_color_hex` values with `/colors` API hex; drop `"undefined"` key |
| `pad/.../modules/calendar/GoogleCalendarClient.kt` | Add `GOOGLE_EVENT_COLOR_HEX` const; in `toEntity()` set `color = colorId?.let { GOOGLE_EVENT_COLOR_HEX[it] }` |
| `backend/pronext/calendar/tests/test_options.py` | Test: synced Google event with colorId stores correct hex |
| `pad/.../modules/calendar/GoogleCalendarClientTest.kt` | Test: `toEntity` translates colorId; null → null |

### 4.2 New `enums.py` (Google portion)

```python
# Google event colorId → hex
# Source: GET /calendar/v3/colors response.event.<id>.background
# Last verified: 2026-04-26 across 3 accounts (palette is global per Google)
google_color_hex = {
    "1":  "#a4bdfc",
    "2":  "#7ae7bf",
    "3":  "#dbadff",
    "4":  "#ff887c",
    "5":  "#fbd75b",
    "6":  "#ffb878",
    "7":  "#46d6db",
    "8":  "#e1e1e1",
    "9":  "#5484ed",
    "10": "#51b749",
    "11": "#dc2127",
}
```

`get_google_color(color_id)` already returns `""` when `color_id is None` or
not in the dict. No code change needed in `utils.py`.

### 4.3 Pad Kotlin

In `GoogleCalendarClient.kt` (or new `GoogleColorPalette.kt` companion):

```kotlin
private val GOOGLE_EVENT_COLOR_HEX = mapOf(
    "1" to "#a4bdfc", "2" to "#7ae7bf", "3" to "#dbadff",
    "4" to "#ff887c", "5" to "#fbd75b", "6" to "#ffb878",
    "7" to "#46d6db", "8" to "#e1e1e1", "9" to "#5484ed",
    "10" to "#51b749", "11" to "#dc2127",
)
```

In `toEntity()` (currently `pad/.../GoogleCalendarClient.kt:163`):

```kotlin
return CalendarEventEntity(
    // ...existing fields...
    syncedEtag = event.etag,
    color = event.colorId?.let { GOOGLE_EVENT_COLOR_HEX[it] },  // ← new
    syncStatus = SyncStatus.SYNCED,
)
```

### 4.4 No schema migration

`Event.color` `CharField(10)` accommodates a single hex `#xxxxxx`. Multi-color
support comes with Phase 2.

### 4.5 Existing 24k legacy hex events

Existing events have hex from the (different) modern palette. Both old and new
are valid hex; H5/Pad render both correctly. **No backfill migration**. Users
will see a slight color shift on already-synced events that are eventually
re-synced via etag changes; new events use the API-faithful palette.

If product later requires "all events use the new palette immediately", a
one-shot script can map old hex → colorId → new hex by reverse lookup. Out of
scope here.

---

## 5. Phase 2 — Outlook event color (Commit 2)

Adds Outlook event-level color via the user's `masterCategories`. Depends on
Phase 1 only for shared infrastructure (`enums.py` shape).

### 5.1 Files changed

| File | Change |
|---|---|
| `backend/pronext/calendar/enums.py` | Add `outlook_preset_hex` (25 presets + "none") |
| `backend/pronext/calendar/models.py` | `Event.color` CharField(10) → CharField(64) |
| `backend/pronext/calendar/migrations/00xx_widen_event_color.py` | Schema migration |
| `backend/pronext/calendar/services.py` | New `get_outlook_master_categories(synced)` with Redis cache |
| `backend/pronext/calendar/utils.py` | New `get_outlook_color(categories, synced) -> str` |
| `backend/pronext/calendar/options.py` | `_sync_outlook_event`: stop dropping `color_id`; instead translate `categories` to hex |
| `backend/pronext/calendar/outlook_sync.py` | New `list_master_categories()` MS Graph helper |
| `pad/.../modules/calendar/OutlookCalendarClient.kt` | Fetch + cache masterCategories; translate categories → hex in `toEntity()` |
| `pad/.../database/entities/OutlookMasterCategoryEntity.kt` | New Room table per `(synced_calendar_id, displayName)` |
| `pad/.../modules/calendar/OutlookColorPalette.kt` | Kotlin preset → hex map |
| `pad/.../database/AppDatabase.kt` | Bump Room schema version + migration |
| Tests on both sides | Coverage |

### 5.2 New `enums.py` addition

```python
# Outlook category preset → hex
# Source: Microsoft Outlook desktop/web app convention
# (preset hex values are not exposed via MS Graph API)
# These values should be calibrated against a live Outlook Web on first deploy.
outlook_preset_hex = {
    "none":     "",
    "preset0":  "#E81123",   # Red
    "preset1":  "#FF8C00",   # Orange
    "preset2":  "#A4262C",   # Brown
    "preset3":  "#FFF100",   # Yellow
    "preset4":  "#107C10",   # Green
    "preset5":  "#008080",   # Teal
    "preset6":  "#808000",   # Olive
    "preset7":  "#0078D4",   # Blue
    "preset8":  "#5C2D91",   # Purple
    "preset9":  "#A6005A",   # Cranberry
    "preset10": "#69797E",   # Steel
    "preset11": "#373D41",   # DarkSteel
    "preset12": "#A19F9D",   # Gray
    "preset13": "#393939",   # DarkGray
    "preset14": "#000000",   # Black
    "preset15": "#750B1C",   # DarkRed
    "preset16": "#8E562E",   # DarkOrange
    "preset17": "#5D4037",   # DarkBrown
    "preset18": "#9C6C00",   # DarkYellow
    "preset19": "#054B16",   # DarkGreen
    "preset20": "#004B50",   # DarkTeal
    "preset21": "#3B3A1A",   # DarkOlive
    "preset22": "#002050",   # DarkBlue
    "preset23": "#32145A",   # DarkPurple
    "preset24": "#5C002E",   # DarkCranberry
}
```

Implementation note: open Outlook Web, screenshot a category of preset0 / 4 /
7 / 8, sample pixels, adjust hex values if they materially differ. Lock with
unit test.

### 5.3 Backend masterCategories cache

```python
# services.py
from django.core.cache import cache

def get_outlook_master_categories(synced: SyncedCalendar) -> dict[str, str]:
    """
    Returns {displayName: presetColor} for this user's Outlook account.
    Cached 1h per (user_id, email). Empty dict on failure (graceful degrade).
    """
    if not synced.email:
        return {}
    key = f"outlook:master_categories:{synced.user_id}:{synced.email}"
    cached = cache.get(key)
    if cached is not None:
        return cached

    try:
        outlook = _get_outlook(synced, need_two_way=False)
        if not outlook:
            return {}
        result = outlook.list_master_categories() or {}
        mapping = {
            c['displayName']: c.get('color', 'none')
            for c in result.get('value', [])
            if c.get('displayName')
        }
        cache.set(key, mapping, timeout=3600)
        return mapping
    except Exception as e:
        logger.warning(f"masterCategories fetch failed for sc={synced.id}: {e}")
        return {}
```

### 5.4 Backend translation helper

```python
# utils.py
def get_outlook_color(categories: list[str], synced: SyncedCalendar) -> str:
    """
    Translate Outlook event categories to comma-joined hex.
    Skips orphan / unmapped / "none"-colored categories silently.
    Returns "" if nothing translates.
    """
    if not categories:
        return ""
    master = get_outlook_master_categories(synced)
    hexes = []
    for name in categories:
        preset = master.get(name)
        if preset and preset != "none":
            hex_value = outlook_preset_hex.get(preset, "")
            if hex_value:
                hexes.append(hex_value)
    return ",".join(hexes)
```

### 5.5 Backend `_sync_outlook_event` change

Currently `pronext/calendar/options.py:108-109`:

```python
# Remove color_id as Event model doesn't have this field
event_data.pop('color_id', None)
```

Replace with:

```python
categories = outlook_event.get('categories') or []
event_data['color'] = get_outlook_color(categories, synced)
event_data.pop('color_id', None)  # legacy field, not used for Outlook
```

### 5.6 Pad Kotlin

`OutlookCalendarClient` extends:

```kotlin
suspend fun fetchMasterCategories(accessToken: String): Map<String, String> {
    val urlStr = "$BASE_URL/me/outlook/masterCategories"
    val (code, body) = httpGet(urlStr, accessToken)
    if (code != 200) return emptyMap()
    val response = json.decodeFromString<MasterCategoriesResponse>(body)
    return response.value.associate { it.displayName to (it.color ?: "none") }
}
```

Pattern: `fetchEvents()` calls `fetchMasterCategories` **once** at the start of
each sync, holds the result in a local `Map<String, String>`, and passes it
into each `toEntity(event, masterCategories)` call. The Room table
`OutlookMasterCategoryEntity` is a persisted **offline copy** so that local UI
operations between syncs can still resolve colors; it's refreshed each sync
from the live MS Graph fetch.

```kotlin
private fun toEntity(
    event: OutlookEvent,
    syncedCalendarId: Long,
    masterCategories: Map<String, String>,
): CalendarEventEntity {
    val hexes = event.categories.orEmpty()
        .mapNotNull { name ->
            val preset = masterCategories[name] ?: return@mapNotNull null
            if (preset == "none") return@mapNotNull null
            OUTLOOK_PRESET_HEX[preset]
        }
    return CalendarEventEntity(
        // ...other fields...
        color = hexes.joinToString(",").ifEmpty { null },
    )
}
```

### 5.7 Schema migration (backend)

```python
# 00xx_widen_event_color.py
class Migration(migrations.Migration):
    dependencies = [...]
    operations = [
        migrations.AlterField(
            model_name='event',
            name='color',
            field=models.CharField(max_length=64, blank=True, null=True),
        ),
    ]
```

PostgreSQL widens varchar in metadata only — fast on a 2.18M-row table.

### 5.8 Pad Room migration

Bump Room schema version. New table `outlook_master_category` and widened
`color` column on `calendar_event`. Migration replays without data loss
(existing color values fit in wider column).

### 5.9 Write-back must NOT include color

Outlook is bidirectional (`feat: Outlook bidirectional sync` #286). Both
write-back surfaces must omit color-related fields:

- Pad `OutlookCalendarClient` — `create_event` / `update_event` payload
  builders
- Backend `outlook_sync.py` — any server-side write functions invoked from
  admin or sync reconciliation paths

The request body **must not** include `categories` or any color-derived field
(if those fields are needed in the future for non-color reasons, add an
explicit allow-list rather than re-introducing implicit pass-through).

Lock with tests on both sides:

```kotlin
@Test
fun `outlook create-event payload omits categories`() {
    val payload = client.buildCreatePayload(event)
    assertFalse(payload.containsKey("categories"))
}
```

```python
def test_outlook_writeback_omits_categories():
    payload = build_outlook_event_payload(event)
    assert "categories" not in payload
```

---

## 6. Deployment order (critical)

The schema migration (`Event.color` CharField widening) MUST land before any
Pad app version that uploads multi-hex strings. Otherwise old backend rejects
new uploads with `value too long for type character varying(10)` and event
sync fails 500.

**Required sequence**:

1. Deploy backend with migration (Phase 2 backend work) → migration runs on prod
2. Verify column widened: `\d calendar_event` shows `color varchar(64)`
3. Release Pad apk with Outlook color translation
4. (Phase 1 Pad apk has no schema dependency and can ship anytime after Phase 1 backend deploy)

---

## 7. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Pad ships before backend migration → upload 500s | Medium | Hard sequencing in release process; CI check on PR |
| MS Graph `masterCategories` fetch fails mid-sync → kills sync | Low | `get_outlook_master_categories` returns `{}` on exception, never raises |
| Event has orphan category (deleted from masterCategories but still tagged on event) | Low | Skip silently in `get_outlook_color`, partial result OK |
| Old Pad version still on `color=null` upload | Certain (during rollout) | All paths allow null/empty; no regression vs today |
| Outlook 2-way sync writes back `categories` field, polluting user's tags | Medium if not tested | Explicit unit test asserting `categories` not in writeback payload |
| `outlook_preset_hex` values off from real Outlook UI | Medium | Calibrate against Outlook Web on first deploy; lock with snapshot test |
| User changes Outlook category color → 1h staleness | Low impact | Documented and accepted; cache TTL 1h gives bounded staleness |
| Existing 24k events show slightly different hex from new sync (modern vs API palette) | Low impact | Eventual re-sync via etag converges; one-shot backfill if product requests |

---

## 8. Out of scope

| Feature | Why deferred |
|---|---|
| Sync Google calendarList `backgroundColor` to `SyncedCalendar.color` | Existing UI-selected color works; not part of regression |
| Raw + provider-prefix storage format | Performance and migration cost not justified for the small staleness benefit |
| `ColorPalette` Django model with admin UI | YAGNI — palettes haven't changed in 14 years (Google) or are vendor-fixed (Outlook) |
| iCloud / ICS event-level `COLOR` parsing | Negligible upstream usage |
| Pad/App UI to set per-event color | Product not requesting |
| Event color write-back to upstream | Product explicit "do not write color" |

---

## 9. Acceptance criteria

- [ ] Google event in Web with colorId=10 (green) renders as `#51b749` in Pad/H5
- [ ] Google event with no colorId set renders the event's category color (fallback)
- [ ] Outlook event with `["Blue category"]` renders as `#0078D4` in Pad/H5
- [ ] Outlook event with `["Red", "Blue"]` renders as stripes `#E81123,#0078D4`
- [ ] After user changes "Blue category" preset in Outlook, Pad/H5 reflects new color within one sync interval (worst case 1h on backend cache)
- [ ] Pad on the previous version (without color translation) continues to sync events; events render with category-fallback color (no regression)
- [ ] Outlook 2-way sync write-back payload does not include `categories`
- [ ] Backend test suite green; Pad unit tests green
- [ ] Schema migration runs on local backup of prod DB without errors

---

## 10. Verification commands (smoke)

```bash
# Backend test
cd backend && python3 manage.py test pronext.calendar.tests.test_color_sync

# Pad unit test
cd pad && ./gradlew :app:test --tests "*GoogleCalendarClientTest*"
cd pad && ./gradlew :app:test --tests "*OutlookCalendarClientTest*"

# Live integration check (api-tests skill):
# 1. Tag an event in Google Web with colorId=10
# 2. Trigger Pad sync
# 3. Query DB:
#    SELECT id, title, color FROM calendar_event
#    WHERE synced_id='<the-event-id>';
#    Expect: color = '#51b749'
```

---

## Appendix A — verified facts (2026-04-26)

- Google `/calendar/v3/colors` returns identical palette across 3 different
  accounts (`willcute@gmail.com`, `ck.meng@theia.co.nz`, plus a third). No
  per-account variation.
- Google `/colors` `updated` field: `2012-02-14T00:00:00.000Z` (last palette
  change 14+ years ago).
- Outlook event JSON has only `categories: [string]` for color info; no
  event-level hex or colorIndex.
- Outlook `masterCategories` is per-user and varies between users for the same
  category name; standard categories (Red/Orange/Yellow/Green/Blue/Purple) map
  to fixed presets per Microsoft convention.
- Pad does its own direct sync for both Google (`GoogleCalendarClient.kt`) and
  Outlook (`OutlookCalendarClient.kt`); both upload via
  `/pad-api/calendar/event/upload_synced/`.
- Existing local `Event.color` distribution: 70% NULL, 29% empty string, 1%
  hex (≈24k), of which 99.996% from Google sync.
