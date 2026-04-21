---
description: Read-only Pronext prod server health snapshot (containers, pg18, heartbeat, redis, pg_bouncer)
argument-hint: [--verbose] [--tail <dur>]
allowed-tools: Bash(ssh *), Bash(grep *), Read
---

# Pronext Prod Status

Read-only health snapshot of the Pronext production server. Invoke when something looks wrong (timeouts, 5xx spikes, heartbeat silence, "too many clients" storms) to triage fast.

## Constitution (宪法) — NON-NEGOTIABLE

Every command this file issues MUST obey these rules. If a suggested step would violate any of them, skip it and note the skip in the report.

1. **Read-only only.** NEVER run any of these, under any circumstance:
   - `docker restart` / `docker stop` / `docker rm` / `docker kill` / `docker start`
   - `docker compose up` / `down` / `restart` / `build` / `pull` / any mutating compose verb
   - `kill` / `pkill` / `systemctl restart` / `systemctl stop` / `systemctl start`
   - `rm` / `mv` / `cp` (to server paths) / `chmod` / `chown` / `touch`
   - Any redirect that writes on the server: `>`, `>>`, `tee` without `-a /dev/null`
   - `pg_dump`, `pg_dumpall`, `vacuum`, `reindex`, `cluster`, `analyze` (as mutating command)
   - In any SQL: `SET`, `ALTER`, `UPDATE`, `INSERT`, `DELETE`, `TRUNCATE`, `CREATE`, `DROP`, `GRANT`, `REVOKE`, `COPY ... FROM`, `REFRESH MATERIALIZED VIEW`
   - Anything that sends signals to running processes
2. **No heavy load.** Budget total wall-clock well under 10 seconds.
   - No full table scans. Never `SELECT * FROM <bigtable>` or `SELECT count(*) FROM <bigtable>` on any application table.
   - No `EXPLAIN ANALYZE`.
   - No `docker logs` without `--tail N` or `--since N`.
   - No streaming: `docker stats` MUST use `--no-stream`; `docker logs -f` is forbidden.
   - No `redis-cli KEYS *`, no `SCAN` loops, no `MONITOR`, no `DEBUG SLEEP`.
   - No `strace`, `tcpdump`, `htop`, `iotop`, `top` in interactive mode.
3. **Batch SSH calls.** Group read commands into a single `ssh pronext 'bash -c "..."'` invocation so SSH handshake cost doesn't dominate. Total SSH calls: 1-3, not 20.
4. **Redact secrets.** Never emit `DJANGO_PG` password, `POSTGRESQL_PASSWORD`, API keys, or JWT signing keys. Substitute via `sed` BEFORE printing: `s/:[^:@]*@/:<redacted>@/g` for URLs, `s/(password|PASSWORD|PWD)=[^ ]*/\1=<redacted>/g` for env form.
5. **If any check hits a limit or errors, surface it in the report.** Do NOT retry, do NOT escalate to a heavier command, do NOT probe deeper. A truncated result is an acceptable result — an extra server load is not.

## Context hints for debugging

A few facts that make the next investigation 10x faster:

- **pg_bouncer is currently orphaned.** Django's `DJANGO_PG` points directly at `pg18:5432`, bypassing pg_bouncer. Any stats from `pg_bouncer` (`SHOW POOLS`) are historical / FYI only — the real connection pressure shows up on `pg18`.
- **Error log IPs map to containers.** The traefik docker network assigns IPs dynamically but `172.19.0.5` has historically been `pg18`. When Django tracebacks cite `172.19.0.x`, cross-reference section 6 (network IP mapping) before assuming.
- **Canonical storm signature.** `FATAL: sorry, too many clients already` in `pg18` logs is the fingerprint for connection-exhaustion incidents. Always check section 5 first when the API is flaking.

## Arguments

Parse `$ARGUMENTS`:

- `--tail <duration>` — window for log searches (e.g. `--tail 10m`, `--tail 24h`). Default: `1h`.
- `--verbose` — dump raw outputs of every section for deep dive. Default: concise summary only.
- no args → concise summary, default 1h window.

## Instructions

### Step 1: Parse arguments

Extract `TAIL` (default `1h`) and `VERBOSE` (default false) from `$ARGUMENTS`.

### Step 2: Execute the batched read-only probe

Issue ONE `ssh pronext` call that bundles sections 1-11 below. Use heredoc-style quoting so the remote bash sees a single script. All queries must be read-only per Constitution rule 1.

Template (substitute `${TAIL}` before sending):

```bash
ssh pronext 'bash -s' <<'REMOTE'
set +e  # keep going even if one section errors — we want partial data

echo "===== 1. HOST + CONTAINERS ====="
hostname
echo
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

echo
echo "===== 2. CONTAINER RESOURCE USAGE ====="
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

echo
echo "===== 3. DJANGO API DB ENDPOINT ====="
docker exec pronext env 2>/dev/null \
  | grep -iE "^DJANGO_PG=|^DJANGO_REDIS=" \
  | sed -E "s/:[^:@]*@/:<redacted>@/g; s/(password|PASSWORD|PWD)=[^ ]*/\1=<redacted>/g"

echo
echo "===== 4. PG18 HEALTH ====="
docker exec pg18 psql -U postgres -d pronext_prod -tA -c "SHOW max_connections;" 2>&1
echo "active_connections:"
docker exec pg18 psql -U postgres -d pronext_prod -tA -c "SELECT count(*) FROM pg_stat_activity WHERE datname=current_database();" 2>&1
echo "by application_name + state:"
docker exec pg18 psql -U postgres -d pronext_prod -c "SELECT application_name, state, count(*) FROM pg_stat_activity WHERE datname=current_database() GROUP BY 1,2 ORDER BY 3 DESC LIMIT 20;" 2>&1
echo "db_size:"
docker exec pg18 psql -U postgres -d pronext_prod -c "SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;" 2>&1

echo
echo "===== 5. PG18 RECENT FATAL / PANIC (since TAIL) ====="
docker logs pg18 --since TAIL_PLACEHOLDER 2>&1 | grep -iE "FATAL|PANIC" | tail -30

echo
echo "===== 6. NETWORK IP MAPPING (traefik) ====="
docker network inspect traefik 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(chr(10).join(f\"  {c[\x27Name\x27]:<25} {c[\x27IPv4Address\x27]}\" for c in d[0][\x27Containers\x27].values()))" 2>&1

echo
echo "===== 7. PG_BOUNCER (orphan — FYI only) ====="
docker exec pg_bouncer sh -c "echo SHOW LISTS\; | psql -h 127.0.0.1 -p 6432 -U postgres pgbouncer" 2>&1 | head -20

echo
echo "===== 8. REDIS ====="
# Extract password from Django's DJANGO_REDIS (format redis://:password@host:port/db)
# so we don't bake a secret into this file. Pass via REDISCLI_AUTH env so it
# doesn't leak into process args. --no-auth-warning silences the noisy notice.
REDIS_PWD=$(docker exec pronext sh -c 'echo "$DJANGO_REDIS"' 2>/dev/null | sed -nE 's|^redis://:([^@]+)@.*|\1|p')
if [ -n "$REDIS_PWD" ]; then
  docker exec -e REDISCLI_AUTH="$REDIS_PWD" bcps-redis-1 redis-cli --no-auth-warning INFO clients 2>/dev/null | head -10
  docker exec -e REDISCLI_AUTH="$REDIS_PWD" bcps-redis-1 redis-cli --no-auth-warning INFO memory 2>/dev/null | grep -E "used_memory_human|maxmemory_human"
else
  echo "could not extract redis password from DJANGO_REDIS (is pronext container up?)"
fi

echo
echo "===== 9. HEARTBEAT LOGS (errors in last TAIL, last log line since 5m) ====="
docker logs heartbeat --since TAIL_PLACEHOLDER 2>&1 | grep -iE "error|fatal|panic" | tail -10
echo "---last-line-since-5m---"
docker logs heartbeat --since 5m 2>&1 | tail -1

echo
echo "===== 10. CELERY WORKER + BEAT (tracebacks in last 10m) ====="
echo "--- celeryworker ---"
docker logs pronext-celeryworker --since 10m 2>&1 | grep -iE "error|exception|traceback" | tail -10
echo "--- celerybeat ---"
docker logs pronext-celerybeat --since 10m 2>&1 | grep -iE "error|exception|traceback" | tail -10

echo
echo "===== 11. HOST DISK + LOAD ====="
df -h /data/pg18 /var/lib/docker 2>/dev/null | grep -vE "^Filesystem"
uptime

REMOTE
```

**Important**: before sending, replace both `TAIL_PLACEHOLDER` tokens with the actual `${TAIL}` value (default `1h`). Do this via `sed` in the local shell, or build the heredoc body as a local variable first. The placeholder exists because bash heredocs with `'REMOTE'` don't expand locals on the remote side.

### Step 3: Parse the output and classify

Walk through each section and apply these flagging rules. A flag is one of 🟢 (ok), 🟡 (degraded — surface but not urgent), 🔴 (critical — lead with this).

**Section 1 — Containers**
- Expected set on the traefik network: `pronext`, `pronext-celeryworker`, `pronext-celerybeat`, `pg_bouncer`, `pg18`, `heartbeat`, `pronext-tools`, `traefik`, `bcps-redis-1`, `bcps-watchtower-1`.
- 🔴 any expected container MISSING from `docker ps`.
- 🟡 any container with uptime < 5 min (parse `Status` column: `Up 3 minutes`).
- 🟡 image tag other than `latest` or a recognizable `v...` release tag on a core app container.

**Section 2 — Resources**
- 🟡 CPU > 70% on any container. 🔴 CPU > 90%.
- 🟡 Mem > 80% of limit. 🔴 Mem > 95%.

**Section 3 — DB endpoint**
- 🟡 `DJANGO_PG` does NOT contain `pg18:5432` (surface it; could be intentional migration).
- Always confirm `DJANGO_REDIS` is present.

**Section 4 — pg18**
- Let `M = max_connections`, `A = active_connections`.
- 🟡 `A > 0.7 * M`. 🔴 `A > 0.9 * M`.
- 🟡 If the by-application breakdown shows a big `application_name=''` + `state=idle` bucket (stale connections not returned to pool).

**Section 5 — pg18 FATAL/PANIC**
- 🔴 any `FATAL: sorry, too many clients already` in the TAIL window.
- 🟡 any other FATAL.

**Section 6 — Network mapping**
- No flag. Reference data for reading tracebacks.

**Section 7 — pg_bouncer**
- No flag. Annotate: "pg_bouncer is not in the Django data path; historical only."

**Section 8 — Redis**
- 🟡 `connected_clients > 500`.
- 🟡 `used_memory_human` > 80% of `maxmemory_human`.

**Section 9 — Heartbeat**
- 🔴 any `panic` or `fatal` in last TAIL.
- 🟡 last-log-line-since-5m is empty (heartbeat should constantly receive pings).

**Section 10 — Celery**
- 🟡 any traceback on worker or beat in last 10m.

**Section 11 — Host**
- 🟡 any fs > 80%. 🔴 > 90%.
- Let `C = core count` (approximate from uptime context; assume 8 if unknown and note the assumption).
- 🟡 load1 > `C * 1.5`. 🔴 load1 > `C * 3`.

Overall verdict:
- Any 🔴 → `🔴 CRITICAL`
- Else any 🟡 → `🟡 DEGRADED`
- Else → `🟢 HEALTHY`

### Step 4: Emit the report

Print a single Markdown block the user can scan. If there are no anomalies, keep it tight (fits on one screen). If anomalies exist, LEAD WITH THE RED FLAGS.

Use this shape:

```
## Prod status @ <UTC timestamp>

Overall: <🟢 HEALTHY | 🟡 DEGRADED | 🔴 CRITICAL>

### Containers
<one line per container: name, uptime, any flag>
Expected but missing: <list or "none">

### Resources
<only flagged lines; "all within budget" if none>

### pg18
max_connections: <M>
active: <A> / <M>  <flag>
recent FATAL (<TAIL>): <count>  <flag>
top FATAL sample: <first line, or "none">

### DB endpoint
DJANGO_PG  → <host>:<port>/<db>  <flag>
DJANGO_REDIS → <host>:<port>/<db>  <flag>

### Heartbeat / Celery / Redis
heartbeat: <ok | last ping <age> | panic: <sample>>
celeryworker: <ok | traceback: <sample>>
celerybeat: <ok | traceback: <sample>>
redis: clients=<n>, mem=<used>/<max>  <flag>

### Disk / Load
<flagged lines only, or "all within budget">

### Anomalies
<bulleted list of every 🟡 and 🔴 finding with a one-line explanation; empty if all green>

### Hints
- pg_bouncer is orphan; real pressure is on pg18
- If you see 172.19.0.x in tracebacks, cross-ref section 6
- "too many clients already" → look at section 4 breakdown for the offending application_name
```

### Step 5: --verbose mode

If `$ARGUMENTS` contains `--verbose`, ALSO append the raw output of each section below the summary under a `## Raw output` header. Still redact secrets.

## Failure modes

- **SSH failure** (host unreachable, auth denied) → report "unable to SSH" with the exit code and stop. Do NOT retry, do NOT try an alternate host.
- **`docker exec` fails on a container** → record "container X unreachable" in the Anomalies section and continue. Do NOT restart the container.
- **Query times out** → surface the timeout verbatim; never re-run with a longer timeout or lower isolation.
- **Any accidental write detected in output** → STOP, do not emit the report, tell the user the command drafted a mutating operation and needs revision. This should be impossible if Constitution is followed, but guard anyway.
