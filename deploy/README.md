# Deploy

Docker compose stacks for the two hosts that run pronext.

| Host | SSH alias | User | Path on host | Purpose |
|---|---|---|---|---|
| **prod** | `pronext` | `ubuntu` | `/home/ubuntu/{bcps,cps}/` | Production (api.pronextusa.com) |
| **test** | `do` | `root` | `/root/docker_compose/{bcps,cps}/` | Test (api-test.pronextusa.com); shared box with unrelated projects |

`bcps` = base / common platform services (postgres, redis, traefik, watchtower, TLS state).
`cps` = pronext app services (django, celery, pgbouncer, heartbeat, tools).

Bring `bcps` up first; `cps` services depend on it.

---

## Layout

```
deploy/
├── do/                          # test host
│   ├── bcps/
│   │   ├── docker-compose.yml   # one combined file: traefik + postgres + invoice + watchtower + nginx
│   │   ├── .env                 # POSTGRES_PASSWORD (gitignored)
│   │   ├── acme.json            # Let's Encrypt account state
│   │   └── certs/               # TLS certs (.key gitignored)
│   └── cps/
│       ├── docker-compose.yml   # pronext-test django stack (with embedded redis)
│       ├── .env                 # gitignored
│       ├── publish_apk.sh
│       ├── heartbeat/
│       │   ├── docker-compose.yml
│       │   └── .env
│       └── tools/
│           ├── docker-compose.yml
│           └── .env
└── pronext/                     # prod host
    ├── bcps/
    │   ├── docker-compose-pg17.yml         # postgres 17 (active)
    │   ├── docker-compose-redis.yml
    │   ├── docker-compose-traefik.yml
    │   ├── docker-compose-watchtower.yml
    │   ├── custom-postgresql.conf          # mounted into pg17
    │   ├── pg_hba.conf                     # mounted into pg17
    │   ├── .env                            # POSTGRES_PASSWORD + AWS/CF (gitignored)
    │   ├── acme.json
    │   └── certs/                          # .key gitignored
    └── cps/
        ├── docker-compose.yml              # api (django) + celeryworker + celerybeat + pgbouncer
        ├── .env                            # gitignored
        ├── flush_google_token.sh
        ├── release.sh
        ├── heartbeat/
        │   ├── docker-compose.yml          # go heartbeat service
        │   └── .env
        └── tools/
            ├── docker-compose.yml          # tools-api
            └── .env
```

---

## Sync between local and remote

The `sync-deploy` skill mirrors stacks via SSH+rsync. Config: `../server-sync.yml`.

```bash
# pull all four stacks from servers (server is authoritative; --delete syncs)
/sync-deploy download all

# push a single stack to its server (prod requires confirmation)
/sync-deploy upload do-bcps
/sync-deploy upload pronext-cps
```

`.env*` and `*.key` files are gitignored — they live on disk locally + on the server, never in git history.

---

## Manual operations on each host

### prod (`pronext`)

```bash
ssh pronext

# bcps stack — each yml is a separate compose project
cd /home/ubuntu/bcps
docker compose -f docker-compose-pg17.yml up -d
docker compose -f docker-compose-redis.yml up -d
docker compose -f docker-compose-traefik.yml up -d
docker compose -f docker-compose-watchtower.yml up -d

# cps stack — single combined file
cd /home/ubuntu/cps
docker compose up -d                              # api + celery + pgbouncer

cd /home/ubuntu/cps/heartbeat
docker compose up -d                              # go heartbeat

cd /home/ubuntu/cps/tools
docker compose up -d                              # tools-api
```

### test (`do`)

```bash
ssh do

# bcps stack — single combined file (also runs other unrelated services like invoice/nginx)
cd /root/docker_compose/bcps
docker compose up -d

# cps stack
cd /root/docker_compose/cps
docker compose up -d

cd /root/docker_compose/cps/heartbeat
docker compose up -d

cd /root/docker_compose/cps/tools
docker compose up -d
```

---

## Bootstrapping a fresh machine

To rebuild the prod box from scratch:

1. Provision a server, install docker.
2. Add the host as an SSH alias (`pronext` or `do`) in `~/.ssh/config`.
3. Clone this repo locally.
4. Run `/sync-deploy upload pronext-bcps` then `/sync-deploy upload pronext-cps` (and any sub-stacks).
5. SSH in and bring stacks up in order: bcps → cps.
6. Verify with `docker ps`, `pg_isready`, hitting the API endpoint.

---

## Gotchas

- **Each `.yml` in `pronext/bcps/` is its own compose project.** Don't run `docker compose up -d` from the dir without `-f` — it will only see the default `docker-compose.yml` (which doesn't exist there).
- **`do/bcps/docker-compose.yml` mixes pronext and unrelated projects** (invoice, nginx, watchtower also defined here). Be careful when editing — uploads affect those other services too.
- **Secrets are in `.env` files (gitignored).** Never inline them in `docker-compose*.yml`. After secret rotation, update `.env` then `docker compose up -d` to apply.
- **`env_file` content changes recreate the container.** Adding/removing one line in `.env` causes `docker compose up -d` to recreate every service that uses `env_file: .env`. Brief downtime (~5–10s per service). For zero-downtime tweaks, prefer `${VAR}` substitution at the YAML level (compose does NOT recreate when only `${VAR}` resolves to the same value).
- **prod uses manual TLS certs in `pronext/bcps/certs/`** — not Let's Encrypt. The `acme.json` and (legacy) `letsencrypt/` dir are inert.
- **prod's `pronext/cps/heartbeat/` go service is the heartbeat path; `cps/docker-compose.yml` Django no longer handles `/pad-api/common/heartbeat`** (traefik routes that path directly to the go container).

---

## See also

- [`../server-sync.yml`](../server-sync.yml) — sync-deploy environment definitions
- [`../backend/CLAUDE.md`](../backend/CLAUDE.md) — backend architecture
- [`../CLAUDE.md`](../CLAUDE.md) — repo-wide conventions
