# deploy — gotchas and design notes

Things a future assistant (or ops engineer) needs to know that are **not** obvious from reading `docker-compose*.yml` or `custom-postgresql.conf`. README.md covers layout and operations; this file covers **why** the non-default choices exist and which footguns have already been stepped on.

---

## Postgres (pg18)

### pg_bouncer is orphan

`pg_bouncer` still runs on prod but is not in Django's data path. `DJANGO_PG` points directly at `pg18:5432`. Anything you read out of `pg_bouncer` (e.g. `SHOW POOLS`) is historical / FYI only. **Real connection pressure shows up on `pg18` — check `pg_stat_activity`, not pgbouncer stats.**

The psycopg3 in-process pool (see next section) made pgbouncer redundant; it remains deployed only so we can re-enable it quickly if the in-process pool disappoints.

### max_connections = 80 — derivation, not a guess

Chosen from memory arithmetic, not copy-pasted:

- `work_mem = 64 MB`, `max_connections = 80` → worst-case `80 × 64 MB = 5.12 GiB` for sort/hash workspaces.
- `mem_limit: 6g` on the container, `shared_buffers = 3 GB` already committed.
- 5.12 + 3 = 8.12 GiB exceeds RAM only under pathological simultaneous sorts; normal ops stay well under.

Django side uses psycopg3 in-process pool (`min_size=2`, `max_size=6`) × 6 gunicorn workers = **36 steady, plus celery ≈ 3, plus one-off scripts ≈ 5**. 80 gives comfortable headroom and leaves room for ad-hoc `psql` without eviction.

Config lives in [pronext/bcps/custom-postgresql.conf](pronext/bcps/custom-postgresql.conf).

### Superusers bypass `CONNECTION LIMIT` — a "rescue role" is not a real rescue

Tempting "Plan B": set `CONNECTION LIMIT 97` on the Django role so two slots are always reserved for `postgres` to log in and pause the rollout. **This does not work.** From the PostgreSQL docs:

> Superusers are not subject to this limit.

Django's `postgres` role on our deploy **is** a superuser, so `CONNECTION LIMIT` is silently ignored. Validated empirically on the test box: after saturating connections, logging in as `postgres` still failed with `too many clients already` because the superuser cap is `superuser_reserved_connections` (3), not a role-level limit.

Conclusion: **the rescue mechanism must live outside PG entirely.** That's why the watchdog in [apk_rollout.sh](apk_rollout.sh) flips a Redis key instead of running SQL.

### `/dev/shm = 1 GiB` (Docker default 64 MiB is too small)

With `max_parallel_workers=8` + `max_parallel_workers_per_gather=4`, PG's dynamic shared memory segments overflow the Docker default 64 MiB and surface as:

```
psycopg.errors.DiskFull: could not resize shared memory segment
    "/PostgreSQL.xxx" to N bytes: No space left on device
```

Fix baked into [pronext/bcps/docker-compose-pg18.yml](pronext/bcps/docker-compose-pg18.yml): `shm_size: 1g`. Manifested for the first time during the 2.2.4 rollout on `/calendar/event/list` (a parallel-friendly query). If you ever see `DiskFull` from psycopg, the shm knob is the first suspect.

### `track_wal_io_timing=on` / `io_method=worker` are PG18-specific

These live in the compose `command:` block, not in `custom-postgresql.conf`, because they only exist on PG18. `custom-postgresql.conf` is the shared-across-versions source of truth; the compose `command` layer pins PG18-only additions.

---

## Django ↔ PG

### psycopg3 in-process pool (no pgbouncer needed)

`backend/pronext_server/settings.py` uses psycopg3's native pool:

```python
'OPTIONS': {
    'pool': {
        'min_size': env.int('DJANGO_PG_POOL_MIN', 2),
        'max_size': env.int('DJANGO_PG_POOL_MAX', 6),
        'timeout': env.int('DJANGO_PG_POOL_TIMEOUT', 10),
    },
},
'CONN_HEALTH_CHECKS': True,
```

Requirements pin:
- `psycopg[binary]==3.3.2`
- `psycopg-pool==3.3.0`

Previously the code set `prepare_threshold=None` and `DISABLE_SERVER_SIDE_CURSORS=True` for pgbouncer compatibility. Both are **removed** — pg18 is connected directly, so those pgbouncer workarounds just cost performance.

### Verifying the pool under load

From `pg_stat_activity`:

```sql
SELECT application_name, state, count(*)
FROM pg_stat_activity
WHERE datname = current_database()
GROUP BY 1, 2
ORDER BY 3 DESC;
```

Steady state post-pool deploy: ~33 connections total, `application_name=''` with `state=idle` and `state=active` dominating. If you see a massive `application_name=''` + `state=idle` bucket it means connections are leaking / not being returned — check pool config first.

---

## OTA rollout tooling — [apk_rollout.sh](apk_rollout.sh)

### Redis cache-flip as a PG-independent brake

`check_update` (`backend/.../viewset_pad.py`) reads `:1:latest_apk:published` from Redis **before** touching PG. If `is_paused=true` in that cache entry, no PG query is issued. The watchdog weaponizes this:

1. Tail `pg18` logs for `sorry, too many clients already` in the last 60s.
2. If positive, GET the Redis key, flip `is_paused=true` in the JSON, `SETEX` back preserving TTL.
3. Best-effort DB `UPDATE` for persistence — if the UPDATE fails (PG saturated), operator is prompted to finish in Django admin before the Redis TTL (7d) expires.

The brake works **during** a storm, which is exactly when plain SQL can't reach PG. See `flip_published_cache_paused()` in [apk_rollout.sh](apk_rollout.sh).

### Watchdog must run **before** the STATS query

Inside the follow loop, the watchdog runs at the top of every tick — not after the STATS ORM query. Reason: under an actual storm, the `python manage.py shell` STATS call itself fails (can't get a PG connection), the loop `continue`s, and a watchdog placed after it would never fire. Keep the storm detector on the timer that definitely ticks.

### `redis-cli -x` puts stdin **last** — use `SETEX`, not `SET`

Initial watchdog used `redis-cli -x SET "$key" EX "$ttl"`. That produces on the wire: `SET key EX 60 <stdin>`. Redis parses `EX` as the value and `60` as the expiry name, silently refusing / erroring. `SETEX key ttl <stdin>` places stdin in the value slot naturally.

General rule when piping JSON through `redis-cli -x`: only use commands where the value is the final argument.

### Container overrides for test environment

Prod and test have different container names / DB names. The script reads them from env:

```bash
CONTAINER_NAME=pronext-test PG_CONTAINER=postgres REDIS_CONTAINER=pronext-redis \
    ./apk_rollout.sh -f --watchdog
```

`PG_DB` is **not** overridable by env — it's auto-extracted from the container's `DJANGO_PG` URL, so `pronext_prod` vs `pronext_backup_20260220_190204` Just Works without hardcoding.

### Redis password extraction

Watchdog reads `DJANGO_REDIS` out of the Django container and parses the `redis://:PASSWORD@...` URL. This keeps the secret out of the script and out of the shell's `ps` history. Same trick works for `/prod-status` — see `.claude/commands/prod-status.md`.

---

## Traefik network IP mapping

Django tracebacks that cite `172.19.0.x` are usually the traefik bridge. IPs are dynamic but `172.19.0.5` has historically landed on `pg18`. When triaging, cross-reference with `docker network inspect traefik` (section 6 of `/prod-status`) — don't assume from memory.

---

## See also

- [README.md](README.md) — deploy layout, sync-deploy, manual operations
- [../backend/CLAUDE.md](../backend/CLAUDE.md) — backend architecture, Beat system, Pad auth
- [../CLAUDE.md](../CLAUDE.md) — repo-wide conventions
- `.claude/commands/prod-status.md` — read-only health snapshot skill
