# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pronext is a cross-platform calendar and task management system for Pad devices. This monorepo contains:

| Directory            | Description                             | Tech Stack                                          |
| -------------------- | --------------------------------------- | --------------------------------------------------- |
| `backend/`   | Django REST API backend                 | Python 3.12+, Django 5.2, PostgreSQL, Redis         |
| `heartbeat/` | High-performance heartbeat microservice | Go 1.25+                                            |
| `h5/`        | H5 site (WebView in Flutter app)        | Vue 3, Vite, Tailwind CSS                           |
| `app/`       | Mobile app (iOS/Android)                | Flutter/Dart                                        |
| `pad/`       | Native Android tablet app               | Kotlin                                              |
| `docs/`      | API documentation                       | MkDocs                                              |

## Terminology

When the user says **admin** or **in admin** (or similar), they mean the **Django Admin site**: `backend/` `admin.py` / `ModelAdmin`, URLs under `/admin/`, and staff login there—not Pad or app “admin” screens, not the H5 site, and not generic “superuser” concepts unless they say otherwise.

## Architecture

```
┌─────────────┐   Heartbeat    ┌─────────────┐       ┌───────────────────────┐
│  Pad Device │───────────────>│ Go Service  │       │    Flutter/Mobile     │
│             │                │ (Port 8080) │       │  ┌─────────────────┐  │
└─────────────┘                └──────┬──────┘       │  │  Vue H5 Site    │  │
       │                              │              │  │  (WebView)      │  │
       │ All other API calls          │              │  └────────┬────────┘  │
       └──────────────────────────────┼──────────────┼───────────┘           │
                                      │              └───────────┬───────────┘
                                      │                          │
                                      v                          v
                               ┌──────────────────────────────────────┐
                               │          Django Backend              │
                               │          (Port 8888)                 │
                               └──────────────────┬───────────────────┘
                                                  │
                         ┌────────────────────────┼────────────────────────┐
                         v                        v                        v
                  ┌────────────┐          ┌──────────────┐         ┌──────────────┐
                  │ PostgreSQL │          │    Redis     │         │ Go ICS Syncer│
                  │            │          │   (DB 8)     │         │ (Linux)      │
                  └────────────┘          └──────────────┘         └──────┬───────┘
                                                                         │
                                                                         v
                                                                   ┌──────────────┐
                                                                   │  ICS URLs    │
                                                                   └──────────────┘
```

**Key architectural points:**

- Vue H5 site is not standalone; it is accessed only via WebView inside the Flutter mobile app
- Go heartbeat service handles high-frequency device pings (~10x faster than Django)
- Both Django and Go share Redis database 8 with `:1:` key prefix
- Devices authenticate via AES-CBC encrypted signatures + JWT tokens
- Beat flags system notifies devices of data changes via Redis (15s TTL)
- **Calendar sync**: Go ICS Syncer (Linux) polls ICS URLs, Cloudflare Workers handles Google Calendar
- **Celery is NOT enabled** - sync tasks run via standalone Go process and Cloudflare Workers

## Development Setup

### Writing Diagrams

Markdown files support Mermaid diagrams. or plain text diagrams, use English for all labels and comments to keep their indentation correct.

### Django Backend (backend/)

```bash
source ./.venv/bin/activate              # Always activate first
python3 manage.py runserver 0.0.0.0:8000
python3 manage.py test pronext.calendar # Run specific app tests
python3 manage.py test pronext.calendar.tests.test_models.EventModelTest.test_create_event
```

### Go Heartbeat (heartbeat/)

最初只有Django 提供了 heartbeat 功能，后来为了提升性能，单独抽离出了一个用Go 实现的微服务。
两个接口应该完全兼容，且共用同一套认证和 Redis 数据。
Django 端的 heartbeat 功能会暂时作为开发和备用，预计未来会被移除。
目前升级和新功能都会优先在 Django 端实现，然后再同步到 Go 端。

```bash
go run *.go                             # Run locally
go test -v                              # Run tests
go test -v -run TestSyncCalendarFlag    # Specific test
```

### Vue Frontend (h5/)

```bash
npm run dev                             # Development server
npm run build                           # Production build
npm run lint                            # ESLint
```

### Android Pad (pad/)

```bash
./gradlew build                         # Build APK
./gradlew assembleRelease               # Release build
```

### Docker (from backend/)

```bash
docker compose up -d                    # Start all services
docker compose logs -f heartbeat        # Go service logs
docker compose logs -f api              # Django logs
```

## Development Workflow

- **Before starting work:**
  - If the repo has uncommitted changes, commit them first to keep the working tree clean.
  - If previous changes look problematic, pause and ask the user to handle them (stash/discard).
- Tasks may span multiple steps — plan the order globally, reorder or split if needed.
- After each step, run automated tests yourself where possible; list anything that requires manual testing.
- If repeated fixes fail, double-check you are editing the right repo (pad/ and app/ share similar code).
- **PRs:** When reviewing, consider whether existing behavior is intentional. If changes require re-testing, say so.
- Do not blindly agree with the user — verify claims against the actual code before confirming.

## Git Workflow

### Commit Rules

- Commit freely as work progresses — no need to wait for explicit confirmation on each commit.
- After completing a change, run any automated tests yourself and tell the user what changed, how to test it, and expected results.
- Check if release notes need updating (see release-notes skill).
- Still confirm with the user before **pushing** to `env/prod` (see global CLAUDE.md).

This applies to all repos (backend, pad, app, h5, heartbeat, etc.).

### End of Conversation

Every fix or feature conversation should end with:

- All changes committed.
- All automated tests passing.
- A clear list of anything that still needs manual testing, with steps and expected results.

### Pre-commit Hooks

Hooks are configured in `backend/` — black (120 char), isort, flake8, djhtml. First commit may fail due to auto-formatting:

```bash
source ./.venv/bin/activate
git add . && git commit -m "message"    # May fail, hooks auto-fix
git add . && git commit -m "message"    # Second attempt passes
```

## Component Documentation

Each component has its own detailed documentation:

- **[backend/CLAUDE.md](backend/CLAUDE.md)** - Comprehensive Django backend guide (Beat system, Pad auth, testing)
- **[heartbeat/README.md](heartbeat/README.md)** - Go service documentation
- **[pad/CLAUDE.md](pad/CLAUDE.md)** - Android/Kotlin UI patterns

## Key Concepts

### Beat System

Cache-only sync notification system. When data changes in Django:

```python
from pronext.common.models import Beat
beat = Beat(device_id, rel_user_id)
beat.should_refresh_event(True)  # Device syncs on next heartbeat
```

### Device Authentication

- `Signature` header: AES-CBC encrypted `app_build|mac|sn|system_version|timestamp`
- `Authorization` header: Bearer JWT token
- Both Django and Go validate using same keys

### Shared Redis Keys

- Beat flags: `:1:beat1:{device_id}` (15s TTL)
- Sync calendar: `:1:beat:synced_calendar:{device_id}__{rel_user_id}` (15s TTL)
- Online status: `device:online_status:{device_sn}` (1h TTL)

### Data Sync Strategies (Pad)

Pad 端不同模块采用不同的数据同步策略：

| 模块 | 本地存储 | rrule 拆分位置 | 数据流 |
| --- | --- | --- | --- |
| **Meal** (新架构) | Room DB | Pad 本地 | 后端原始数据 → Room → 本地 rrule 拆分 → 渲染 |
| **Calendar / Chores** (旧架构) | 无 | 后端 | 每次请求后端 → 后端 rrule 拆分 → 返回展开数据 → 渲染 |

**新架构优势 (Meal):**

- 离线可用，减少网络请求
- rrule 拆分在本地执行，后端压力更小
- Room 数据库提供本地缓存

**旧架构特点 (Calendar / Chores):**

- 无本地持久化，每次展示需请求后端
- 后端负责 rrule 拆分和数据展开
- 实现简单，但依赖网络

## Environment Variables

Key variables (set in `backend/.env`):

- `SIGNING_KEY` - JWT signing key (must match between Django and Go)
- `DJANGO_REDIS` - Redis URL (e.g., `redis://localhost:6379/8`)
- `DJANGO_PG` - PostgreSQL connection string
