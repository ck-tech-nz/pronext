---
name: api-tests
description: >
  Run live third-party calendar API checks (Google Calendar, Microsoft Graph, iCloud
  CalDAV) for a Pronext SyncedCalendar, across local / test / prod environments.
  Three core tasks: (1) fetch a usable access_token from a SyncedCalendar row,
  (2) list the account's upstream calendars via the live API, (3) list events /
  inspect a single event from the upstream provider. Reads connection config from
  db-backup.yml. Companion to the `api-tests/` request collection. Strict read-only
  on prod always; read-only on test unless the user explicitly opts in to a write.
---

# api-tests

Companion skill to the [api-tests/](../../../api-tests/) `.http` collection.

**Division of labor:**

- **`api-tests/external/*.http`** — every concrete request (URL, headers, body,
  param notes, jq hints). Plain text, editable by hand. The `.http` files own the
  request shapes.
- **This `SKILL.md`** — process: env routing, Constitution, data model, how to
  walk from a `sc_id` to a usable token, and the bash bridge that hands the token
  to those `.http` files.

If you find yourself wanting to write a curl example here, instead add it as a
`### …` block in the matching `.http` file.

## When to use

Trigger this skill when the user asks any of:

- "Give me the access_token for `<sc_id>` / `<email>`'s Google/Outlook synced calendar on `<env>`."
- "List `<account>`'s Google/Outlook calendars on `<env>`."
- "List events from `<account>`'s Google calendar on `<env>` for the next 30 days."
- "Show me event `<synced_id>` from upstream for `<account>`."
- "Compare what's in our DB vs what Google has for `<account>`."

Don't trigger for:

- Pure DB inspection without hitting the upstream API → use `data-analyst` or `calendar-probe`.
- Deep diagnostic across DB + Redis + API → use `calendar-probe`.

## Constitution

Project owner's rules — do not violate:

| Env | Reads | Writes |
|---|---|---|
| **local** | free | free |
| **test** | free | only after explicit "yes, write on test" from the user |
| **prod** | free | **never** — refuse and propose a non-mutating alternative |

What counts as a write here:

- `UPDATE / DELETE / INSERT` via psql or ORM `.save()` / `.update()` / `.delete()`.
- **Calling `pronext.calendar.services.get_access_token()` when the stored token
  is expired** — it triggers an OAuth refresh and persists the new token + new
  `credit_expired_at`. That's a write. See "Task 1" below for the read-only path.
- Mutating Google / MS Graph / iCloud state (creating, updating, or deleting
  upstream events). On test/prod require explicit confirmation; on prod, refuse.

Announce the env you're about to hit before connecting, so the user can intercept.

## Environment routing

What each env name means:

| Env | DB the Django shell reads | Where Django runs |
|---|---|---|
| **local** | whatever `backend/.env` → `DJANGO_PG` points at | local venv: `backend/.venv` |
| **test** | the `pronext` api container's configured DB on host `do` | `ssh do && docker exec pronext` |
| **prod** | the `pronext` api container's configured DB on host `pronext` | `ssh pronext && docker exec pronext` |

**"local" is not "any DB on my local Postgres".** It is specifically the DB the
local Django reads from `backend/.env`. If the user wants a different local DB
queried, they must (a) say so explicitly, or (b) have already changed
`DJANGO_PG`. Don't go fishing through other local DBs without being told to.

Connection metadata for the remote envs lives in [db-backup.yml](../../../db-backup.yml).
The `container` field there is the **Postgres** container — useful for psql/dump
ops via the `db-backup` skill. **Don't use it for Django shell.** For Django
shell we need the **api** container, which is `pronext` on both test and prod.

### How to run a Django shell snippet

**local** — venv at `backend/.venv`:

```bash
cd /Users/ck/Git/pronext/pronext/backend && source .venv/bin/activate && python3 manage.py shell <<'PY'
# ...
PY
```

**test** (ssh_host `do`):

```bash
ssh do "docker exec -i pronext python manage.py shell" <<'PY'
# ...
PY
```

**prod** (ssh_host `pronext`):

```bash
ssh pronext "docker exec -i pronext python manage.py shell" <<'PY'
# ...
PY
```

### When the user names a specific local backup DB

If the user explicitly names a restored backup (e.g. "in `pronext_prod_backup_20260424_100130`"),
treat as **local** with `DJANGO_PG` overridden — don't ssh anywhere. See the
`data-analyst` skill for the override pattern.

## Data model

A few Pronext-specific facts worth knowing before queries:

- `AUTH_USER_MODEL = user.User`. **All accounts live in one table** — both human
  users and per-Pad "Pronext Accounts" (called **device-users** in conversation).
- `SyncedCalendar.user` is a FK to `user.User`. The row it points at is usually
  a **device-user / Pronext Account**, not a human user. Each device-user owns
  several `SyncedCalendar` rows (Google / Outlook / iCloud / ICS).
- Human users own / share device-users. Django admin surfaces this at
  `/admin/user/user/<human_id>/stats/` under the "Pronext Accounts" panel.

Concretely:

```
user.User (id=1, username='hustmck@hotmail.com')   ← human admin (test account anchor)
   │  owns / shares
   ▼
user.User (id=777, "ckdevice")                     ← device-user / Pronext Account
   │  has many
   ▼
SyncedCalendar (sc_id=5313 google, 12490 google, 12305 outlook, 12284 icloud)
```

When the user says "device-user 777" or "Pronext Account 777", they mean a
`user.User` row with `id=777`. Query `SyncedCalendar.objects.filter(user_id=777)`
directly — don't walk through `Device` / `UserDeviceRel`.

### Test account anchors

| Anchor | Meaning | When to use |
|---|---|---|
| **`user_id=1`** | Human admin `hustmck@hotmail.com` (lowercase, unified across local/test/prod 2026-04-25). `is_staff=is_superuser=true`. Has few-or-no SyncedCalendars in its own row. | Default when user just says "the test account" or "the test user". Echo back before running. |
| **`user_id=777`** | "ckdevice" device-user. On **local** as of 2026-04-25 has 4 SyncedCalendars: sc 5313 (google `ck.meng@theia.co.nz`), 12490 (google `Gmail`), 12305 (outlook), 12284 (icloud). | When the user says "device 777", "device-user 777", "Pronext Account 777", or wants live-API tests against an account that actually has SyncedCalendars. |

When the user names a `user_id` directly, just use it — don't trace ownership.

### Resolving by email-like string

`user_user.email` is often **blank**; the email-like string lives in `username`.
Match both fields when looking up by email:

```python
from django.db.models import Q
from django.contrib.auth import get_user_model
User = get_user_model()
qs = User.objects.filter(Q(email__iexact=needle) | Q(username__iexact=needle))
```

## Task 1 — Get a usable access_token

Goal: hand back a valid token without surprise writes.

### Quick state check (no API call, no write)

```python
from pronext.calendar.models import SyncedCalendar
from django.utils import timezone

sc = SyncedCalendar.objects.get(id=<SC_ID>)
credit = sc.credit or {}
exp = sc.credit_expired_at
now = timezone.now()
expired = (exp is None) or (exp <= now)

print(f"sc_id={sc.id} type={sc.get_calendar_type_display()} email={sc.email or sc.calendar_id}")
print(f"has_access_token={bool(credit.get('access_token'))} has_refresh_token={bool(credit.get('refresh_token'))}")
print(f"credit_expired_at={exp} expired={expired}")
if credit.get('access_token') and not expired:
    tok = credit['access_token']
    print(f"token_preview={tok[:8]}...{tok[-4:]} (len={len(tok)})")
```

**Reality check on Pronext storage:** `access_token` is often **missing** from
`credit` even when the calendar is healthy. Pronext typically only persists
`refresh_token` long-term and refreshes the access_token on demand. So a refresh
step is usually required before any API call.

### Token policy by env

| Stored state | local | test | prod |
|---|---|---|---|
| `access_token` present, `expired=False` | use directly | use directly | use directly |
| `access_token` missing OR `expired=True` | refresh freely (write-back OK) | ask: "OK to refresh on test? (writes DB)" | use **off-DB refresh only**, never persist |

Never echo a full token to chat. Show `tok[:8]...tok[-4:]`. To use a full token
in a curl, capture it into a shell env var with `export TOKEN=$(...)`.

### Refresh — Google

```python
# Off-DB (read-only, prod-safe). Calls Google's token endpoint, returns new
# access_token in memory; does NOT write back.
from pronext.calendar.models import SyncedCalendar
from pronext.calendar.services import refresh_google_token
sc = SyncedCalendar.objects.get(id=<SC_ID>)
result = refresh_google_token(sc.credit['refresh_token'])
print(result['access_token'])    # send via os.write to stderr or capture, not chat
```

```python
# Write-back (writes DB — local-OK, test-with-OK, prod-NEVER).
from pronext.calendar.services import get_access_token
token, expires_in = get_access_token(sc)
```

### Refresh — Outlook (Microsoft Graph)

```python
# Off-DB (read-only, prod-safe). MS may rotate refresh_token in the response;
# off-DB path discards the new one — that's OK on prod, the next scheduled sync
# picks it up.
from pronext.calendar.services import refresh_outlook_token
result = refresh_outlook_token(sc.credit['refresh_token'])
print(result['access_token'])
```

```python
# Write-back (same env policy as Google).
from pronext.calendar.services import get_access_token
token, expires_in = get_access_token(sc)
```

### Refresh — iCloud

No OAuth refresh. iCloud uses HTTP Basic with an Apple ID + app-specific password.
Check the SyncedCalendar row's `credit` shape (likely `{username, password}`,
not `{access_token, refresh_token}`). Reuse the stored creds directly with curl.

## Bash bridge — sc_id → live curl

This is the recipe that turns a SyncedCalendar id into a working API call,
using the `.http` files in `api-tests/external/` for the request shapes.

```bash
cd /Users/ck/Git/pronext/pronext/backend && source .venv/bin/activate

# 1) Refresh off-DB and capture into env (no DB write, prod-safe).
export GOOGLE_OAUTH_TOKEN=$(python3 manage.py shell <<'PY'
from pronext.calendar.models import SyncedCalendar
from pronext.calendar.services import refresh_google_token
sc = SyncedCalendar.objects.get(id=5313)
print(refresh_google_token(sc.credit['refresh_token'])['access_token'])
PY
)

# 2) Run the request from api-tests/external/google-calendar.http manually
#    via curl (substitute {{...}} for $... here).
curl -s -H "Authorization: Bearer $GOOGLE_OAUTH_TOKEN" \
  "https://www.googleapis.com/calendar/v3/users/me/calendarList" | jq '.items[] | {id, summary, primary, accessRole}'
```

For Outlook substitute `refresh_outlook_token` and `MS_GRAPH_TOKEN`.

For repeat use, write the token into [api-tests/.env](../../../api-tests/.env)
(gitignored, auto-loaded by httpyac) under `GOOGLE_OAUTH_TOKEN` / `MS_GRAPH_TOKEN`,
then drive any request from the matching `.http` file via `{{GOOGLE_OAUTH_TOKEN}}` /
`{{MS_GRAPH_TOKEN}}`. Don't do this on prod — the local file would carry a
prod-account token.

## Task 2 — List the account's upstream calendars

Use the request from the matching `.http` file:

- Google: [api-tests/external/google-calendar.http](../../../api-tests/external/google-calendar.http) → `### List the user's calendars`
- Outlook: [api-tests/external/microsoft-graph.http](../../../api-tests/external/microsoft-graph.http) → `### List the user's calendars`
- iCloud: [api-tests/external/icloud-caldav.http](../../../api-tests/external/icloud-caldav.http) → step 3 `PROPFIND` on calendar-home

On test/prod prefer raw `curl` over the project's `_get_gc()` / `_get_outlook()`
wrappers — the wrappers may transparently refresh and write back.

## Task 3 — List events / inspect a single event

Use the request from the matching `.http` file:

- Google: [api-tests/external/google-calendar.http](../../../api-tests/external/google-calendar.http) → `### List events …` and `### Get a single event by id`
- Outlook: [api-tests/external/microsoft-graph.http](../../../api-tests/external/microsoft-graph.http) → `### List events …`, `### Calendar view …`, `### Get a single event by id`
- iCloud: [api-tests/external/icloud-caldav.http](../../../api-tests/external/icloud-caldav.http) → step 4 `REPORT calendar-query`

### Compare DB vs upstream (a common follow-up)

```python
# After collecting upstream synced_ids into a set `api_ids`:
from pronext.calendar.models import Event
db_ids = set(Event.objects.filter(synced_calendar_id=<SC_ID>).values_list('synced_id', flat=True))
print(f"DB only:       {len(db_ids - api_ids)}")
print(f"Upstream only: {len(api_ids - db_ids)}")
print(f"In both:       {len(db_ids & api_ids)}")
```

## See also

- [calendar-probe](../calendar-probe/SKILL.md) — deep diagnostic across DB + Redis + API.
- `data-analyst` — generic DB / Redis / ORM queries.
- [api-tests/README.md](../../../api-tests/README.md) — the request collection itself.
- `backend/pronext/calendar/services.py` — `get_access_token`, `refresh_google_token`, `refresh_outlook_token`.
- `backend/pronext/calendar/options.py` — `_get_gc`, `_get_outlook` (note: these may write).
