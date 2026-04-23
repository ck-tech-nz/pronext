# Add Synced Calendar: Bind to Profile at Add Time (Replace Default-Category Flow)

**Date:** 2026-04-23
**Scope:** App (Flutter) — Sync Calendar flow and related screens. Backend — SyncedCalendar write paths only.

## Problem

Today, adding a synced calendar follows this flow:

```
Home → Sync → Add new synced calendar → [provider options]
  → (provider-specific OAuth / URL)
  → Success (creates SyncedCalendar + default Category)
  → User later navigates elsewhere to convert/assign that Category to a Profile
```

This produces two kinds of friction:

1. **Orphan state.** The SyncedCalendar and its default Category exist as an unbound blob until the user remembers to assign them to a Profile. If they abandon the app before doing that, the orphan stays around indefinitely and clutters every list view.
2. **Redundant step.** The common case — "I'm adding Dad's work calendar to Dad's profile" — requires two separate journeys. The Profile-to-Category model is an implementation detail leaking into UX.

The real-world family scenario makes this worse: a Google account commonly exposes 4–6 sub-calendars (Gmail, Google Calendar, Family, Kids' school, etc.), and they frequently belong to *different* family members. The current flow produces N orphan categories per OAuth session, each needing manual reassignment.

## Goal

Fold Profile binding into the add-synced-calendar flow so every SyncedCalendar is born with a Profile. No orphan state. No separate "convert category → profile" step.

## Approach

Split the add flow by source type, because the UX constraints differ:

- **OAuth providers (Google, Outlook, iCloud, Cozi, Yahoo)** — an OAuth session returns a list of sub-calendars. Users often want different sub-calendars bound to different Profiles (Dad's Gmail ≠ Kid's school calendar). So ask for Profile **per sub-calendar** at selection time.
- **ICS / Calendar URL** — a URL points to exactly one calendar. Ask for Profile **once, before URL input**.

Both paths defer all DB writes until the final confirmation step. Abandoning mid-flow writes nothing.

Public Calendars subscription (US Holidays) is untouched.

## Design

Pencil reference: `Pronext-mobile.pen` → y=21150 row (`Label: Sync-Optimized`). Frame IDs noted per screen below.

### User flow — OAuth branch

```
Sync list              (Sync-v2, 5I9bs)
 → [+ Add]
Provider list          (Sync-Providers-v2, Tv4zF)
 → tap Google/Outlook/iCloud/Cozi/Yahoo
OAuth authorization    (provider web flow, unchanged)
Select Calendars       (Sync-Google-Select-v2, hi8zM)
 ├── tap unselected row
 │    → AssignProfile popup  (Sync-AssignProfile-Popup, Xr5FX)
 │       ├── pick existing Profile → row becomes checked + Profile chip
 │       └── tap "+ Create new Profile"
 │            → CreateProfile popup  (Sync-CreateProfile-Popup, CuaMn)
 │               → name + color → Create & Assign → row checked + chip
 ├── tap chip on checked row → AssignProfile popup (change Profile)
 └── tap checkmark → deselect row
 → [Done]
Success               (Sync-Success-v2, o93OM)
```

### User flow — ICS branch

```
Sync list
 → [+ Add]
Provider list
 → tap "Calendar URL"
ChooseProfile popup    (Sync-ChooseProfile-Popup-ICS, uCDgE)
 ├── pick existing Profile
 └── tap "+ Create new Profile"
      → CreateProfile popup (same component as OAuth branch)
URL input              (Sync-Calendar-URL-v2, NNVif)
 → [Save]
Success                (shared with OAuth branch)
```

### Popup inventory

| Popup | Appears from | Purpose | Fields |
| --- | --- | --- | --- |
| AssignProfile | OAuth Select Calendars row tap | Pick/create Profile for one sub-calendar | List of Profiles + "Create new" + Cancel |
| ChooseProfile (ICS) | Provider list → Calendar URL | Pick/create Profile for the URL-based calendar | Same content as AssignProfile, different subtitle context |
| CreateProfile | "+ Create new Profile" link on either of the above | Minimal Profile creation | Name (text), Color (6-swatch picker), Create & Assign, Cancel |

### Persistence rules

**Nothing is written to the backend until the terminal action of each branch.**

- OAuth: `[Done]` on Select Calendars. At that moment, create N SyncedCalendar rows in a single transaction, each with its assigned `profile_id`. Any CreateProfile popups invoked along the way may have already created Profiles — those persist immediately on "Create & Assign" since Profiles are independent entities.
- ICS: `[Save]` on URL input. At that moment, create one SyncedCalendar with the pre-chosen `profile_id`.

Abandoning OAuth mid-flow (close app, back out) writes no SyncedCalendar rows. Any OAuth token obtained is held in app memory only until persist; if the user never hits Done, the token is discarded.

Abandoning ICS mid-flow likewise writes no SyncedCalendar. A Profile created via the CreateProfile popup *does* persist even if the user abandons — this is intentional, matching the "Profiles are independent entities" model (the user can reuse it next time).

### Data model

- `SyncedCalendar.profile_id` — becomes required (non-null) for all newly created rows in this flow. Existing rows are untouched (see Migration below).
- No "default Category" created as a side effect of sync. The current code that creates one on SyncedCalendar insertion is removed from this flow's write path.

### Migration (existing data)

Users with SyncedCalendars bound to the old default Category continue to work unchanged. The old Category-to-Profile conversion UI stays reachable from wherever it is today; it remains the path for legacy orphan categories. This spec does not force a bulk migration.

Once telemetry shows near-zero use of the legacy path, a follow-up spec can remove the old conversion UI and bulk-assign remaining orphans.

### Edge cases

- **Zero Profiles exist.** AssignProfile / ChooseProfile popup skips the list view and opens CreateProfile directly (since there is nothing to pick).
- **Exactly one Profile exists.** Popup still shows (per user decision — forced step helps users build the mental model of Profile binding).
- **Same OAuth account synced twice.** Re-running the OAuth flow for an already-synced account is allowed; the Select Calendars screen should (a) show previously synced sub-calendars pre-checked with their current Profile chip, and (b) allow changing Profile or unchecking. Out of scope for v1 if the current "Select" screen doesn't load existing bindings; treat as a future enhancement. For v1, adding the same sub-calendar twice creates a duplicate row and is not prevented.
- **User cancels OAuth.** Returns to Provider list. No state persisted.
- **User closes CreateProfile without saving.** Returns to the parent popup (Assign or Choose) with no Profile picked.
- **Network failure on `[Done]`.** Standard error toast. All-or-nothing: either every selected sub-calendar syncs or none. No partial state.

### Public Calendars (US Holidays)

No change. The Subscribe to Public Calendars section in the Provider list stays exactly as today, including its "Subscribed" badge and trash icon. Public calendars do not ask for a Profile and continue to use whatever hidden binding they use today.

## Non-goals

- **Per-sub-calendar Profile override after sync.** Editing a SyncedCalendar's Profile from the Sync list is a separate flow and out of scope.
- **Multi-Profile assignment during OAuth.** Each sub-calendar gets exactly one Profile. Splitting one sub-calendar across multiple Profiles is not supported.
- **Auto-skip of AssignProfile popup when only one Profile exists.** Intentional — keeps the binding explicit and consistent.
- **Renaming a calendar during the add flow.** Use the provider-returned name. Renaming lives on the edit screen.
- **Backend changes to Public Calendars.** Out of scope per user decision.
- **Bulk migration of existing orphan categories.** Deferred to a follow-up spec.

## Test plan (manual, iOS simulator + real device)

Set up: a test account with no existing synced calendars and no existing Profiles.

**OAuth branch — happy path**
1. Home → Sync → tap `+ Sync a New Calendar` → Provider list appears with 5 provider rows (each with its icon) + Calendar URL + Subscribe section.
2. Tap Google → OAuth web flow → return to Select Calendars with N sub-calendars listed, all unchecked (○).
3. Tap first sub-calendar → AssignProfile popup opens → since no Profiles exist, it auto-opens CreateProfile form.
4. Enter name "Dad", pick orange color, tap Create & Assign → popup closes, row shows checked + orange "Dad" chip.
5. Tap second sub-calendar → AssignProfile popup opens with "Dad" in list + "Create new" → tap "Create new" → create "Mom" with pink → row shows checked + pink "Mom" chip.
6. Tap chip on row 1 → AssignProfile popup opens → switch to "Mom" → chip updates.
7. Tap checkmark on row 1 → row deselects (back to ○).
8. Tap Done → transitions to Success screen, shows Sync list with both synced calendars + their Profile chips. Backend DB has exactly 2 SyncedCalendar rows, each with correct `profile_id`. No orphan categories created.

**ICS branch — happy path**
1. From fresh state, Sync → `+ Add` → Provider list → tap Calendar URL.
2. ChooseProfile popup appears immediately. No Profiles yet → auto-opens CreateProfile.
3. Create "Work" profile.
4. Transitions to URL input screen.
5. Enter a valid ICS URL → Save → Success.
6. Backend has 1 SyncedCalendar with `profile_id` = Work.

**Abandon paths**
1. OAuth flow, select 2 sub-calendars with Profile assignments, then close app before tapping Done → re-open → no SyncedCalendar rows exist. Profiles created during the flow still exist (by design).
2. ICS flow, pick Profile, enter URL, back button before Save → no SyncedCalendar row. Profile persists if created.

**Zero/one Profile edge cases**
1. Zero Profiles, any branch: popup skips list step.
2. One Profile, any branch: popup shows list with one entry + Create new (no auto-skip).

**Provider list visual check**
Google, Outlook, iCloud, Cozi, Yahoo all show their brand icons (matches `docs/design/assets/provider_icons/*.png`). Calendar URL and US Holidays keep their line icons. US Holidays row unchanged from current app (Subscribed badge, trash icon behavior).

**Regression check**
1. Existing SyncedCalendars (from legacy Category-based flow) still appear in Sync list and function normally.
2. Legacy "convert Category to Profile" path still reachable and still works for those legacy rows.

## Open questions

- Should the Provider list also show which providers are already partially synced (e.g. small badge "Google — 2 synced")? Not in v1 but noted.
- "Change Profile" from Sync list long-press: out of scope for this spec, will be a separate one.

## References

- Pencil design file: `/Users/ck/Documents/Pronext/UI/Pronext-mobile.pen`, row `Sync-Optimized` at y=21150.
- Current simulator screenshots: provided by user in chat thread, 2026-04-23.
- Provider icon assets: [docs/design/assets/provider_icons/](../../../docs/design/assets/provider_icons/) (extracted from `h5/src/assets/icon_calendar_*.svg`).
