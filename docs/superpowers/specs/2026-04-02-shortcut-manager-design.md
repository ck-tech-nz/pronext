# Shortcut Manager Design

**Date:** 2026-04-02
**Scope:** Flutter app (`app/`) + H5 URL fix (`h5/`)

## Overview

Replace the hardcoded shortcut grid on the Flutter app home screen with a configurable system. Users can reorder, hide, and re-add shortcuts via an inline edit mode. Also adds a new "Manual" shortcut and fixes the User Manual URL in the H5 Support/Feedback pages.

## Shortcut Registry

A developer-defined list of all available shortcuts. Each entry:

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | Unique key (e.g. `'scan'`, `'manual'`) |
| `label` | `String` | Display name |
| `icon` | `IconData` | Material icon |
| `iconColor` | `Color` | Icon foreground color |
| `bgColor` | `Color` | Circular background color |
| `routeKey` | `String?` | Key into `_featureRoutes` map (for WebView-based shortcuts) |
| `action` | `Function(String deviceId)?` | Custom action receiving deviceId (for Scan, Manual — non-route shortcuts) |
| `devOnly` | `bool` | If true, only shown in dev mode (Dashboard) |

Default registry order: Scan, Meal, Photos, Lists, Sync, Manual. Dashboard is devOnly.

The Manual URL (`https://www.pronextusa.com/manual/`) is defined as a constant in the shortcut manager, shared with the action callback.

## User Preferences

Stored in `SimpleStorage` (SharedPreferences), per-account (not per-device).

```json
{
  "shortcut_order": ["scan", "meal", "photos", "lists", "sync", "manual"],
  "hidden_shortcuts": []
}
```

**Default state:** When no preferences exist (fresh install), all non-devOnly shortcuts are visible in registry order.

**New shortcut merge:** When a developer adds a new shortcut to the registry, if its id is not in `shortcut_order` and not in `hidden_shortcuts`, it is appended to the end of the visible list automatically.

## Edit Mode

### Entering

- Long-press anywhere on the shortcut grid (`GestureDetector.onLongPress`)
- Or tap "Edit Shortcuts" in the "..." overflow menu on the home screen
- Haptic feedback on enter

### In Edit Mode

- All visible tiles jiggle (subtle rotation animation, ~1.5 degree oscillation)
- Red circle badge with "✕" appears on each tile's top-left corner
- A dashed "+" tile appears at the end of the grid (only if there are hidden shortcuts available to re-add)
- A "Done" button appears below the grid
- Normal tile tap actions are disabled

### Actions

- **Reorder:** Drag tiles to new positions within the grid
- **Hide:** Tap a tile's ✕ badge — tile is removed with animation, grid collapses
- **Re-add:** Tap the "+" tile — bottom sheet appears listing all hidden shortcuts, tap one to add it at the end of the visible list
- **No minimum:** All shortcuts can be hidden. When all are hidden, the grid area disappears entirely from the home screen. The "..." menu retains "Edit Shortcuts" so the user can re-add later.

### Exiting

- Tap "Done" button — saves preferences to `SimpleStorage`, exits edit mode
- Tap outside the grid or press back — also saves and exits

## Manual Shortcut

- **id:** `'manual'`
- **label:** "Manual"
- **icon:** `Icons.menu_book` (or similar book icon matching Support page)
- **Action:** Calls `openURL('https://www.pronextusa.com/manual/')` — opens in external browser, same behavior as the Support page "User Manual" button

## H5 URL Fix

Fix the User Manual URL in two H5 files (currently pointing to test env):

- `h5/src/pages/support/Support.vue` line 90: change `env-test.pronext-websize.pages.dev/manual/` to `www.pronextusa.com/manual/`
- `h5/src/pages/support/Feedback.vue` line 23: same fix

## File Changes

### New Files

- `app/lib/src/model/shortcut.dart` — `ShortcutItem` class and the shortcut registry constant list
- `app/lib/src/manager/shortcut_manager.dart` — `ShortcutManager` (GetX controller or similar): loads/saves preferences, exposes reactive visible shortcut list, handles reorder/hide/show operations

### Modified Files

- `app/lib/src/page/home.dart` — Replace hardcoded `_QuickAction` list and `_quickActionBar()` with the new shortcut system. Add long-press handler, edit mode state, jiggle animation, drag-and-drop reorder, ✕ badges, "+" tile, Done button.
- `app/lib/main.dart` or wherever the "..." menu is defined — Add "Edit Shortcuts" menu item
- `h5/src/pages/support/Support.vue` — Fix manual URL
- `h5/src/pages/support/Feedback.vue` — Fix manual URL

## Edge Cases

- **Empty grid:** When all shortcuts hidden, grid area disappears. "Edit Shortcuts" in menu remains accessible.
- **Dev mode:** Dashboard shortcut only appears in registry (and thus in edit mode's "+" picker) when `isDevMode` is true.
- **New shortcuts after update:** Automatically appended to visible list if not already in user preferences.
- **Badge counts:** Shortcuts that show badges (e.g. Lists with `listUncompletedCount`) continue to work — badge data comes from `DeviceHome` model, unaffected by reordering.
