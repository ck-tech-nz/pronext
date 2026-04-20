# AI Tools: Primary/Backup Provider Failover

**Date:** 2026-04-21
**Scope:** [tools/](../../../tools/) — FastAPI service (`image-to-event`)

## Problem

`tools/` currently talks to a single AI provider (self-hosted at `webui.cktech.ai`) configured via `AI_URL` / `AI_KEY` / `AI_MODEL`. When that host goes down, every `/image-to-event` request fails and there is no fallback. We want Alibaba DashScope's `qwen-vl-ocr` (OpenAI-compatible endpoint at `https://dashscope.aliyuncs.com/compatible-mode/v1`) to serve as a backup so image-to-event keeps working through primary outages.

## Goals

- Primary stays the self-hosted model; Ali is only called when primary is unreachable.
- Caller API (`POST /image-to-event`) response body is unchanged. Failover is transparent.
- Backup must be optional — when its env vars are absent, service behavior is identical to today.
- Observability: the caller can tell which provider served the request; the service logs failover events.

## Non-goals

- No per-provider prompt files; both providers use the single existing `prompts/image_to_event.txt`. If Qwen-VL-OCR output quality proves divergent, a follow-up spec can split prompts.
- No request-level retry within a single provider. Each provider gets exactly one attempt.
- No weighted/canary traffic splitting. Primary is always tried first.
- No caching or deduplication.

## Design

### 1. Config

[app/config.py](../../../tools/app/config.py) adds three optional fields:

```python
backup_ai_url: str = ""
backup_ai_key: str = ""
backup_ai_model: str = ""
```

Backup is **enabled only when all three are non-empty**. Otherwise the service runs in single-provider mode (no behavior change).

`.env.example` documents the new variables with a reference to the Ali DashScope OpenAI-compatible endpoint.

### 2. Clients

[app/main.py](../../../tools/app/main.py) `lifespan` constructs up to two `httpx.AsyncClient` instances:

| Client | `base_url` | Timeout | Notes |
| --- | --- | --- | --- |
| `app.state.ai_client` (primary) | `settings.ai_url` | `Timeout(30.0, connect=5.0)` | Read timeout reduced from 60s → 30s so a hung primary fails over quickly. |
| `app.state.backup_ai_client` (backup) | `settings.backup_ai_url` | `Timeout(60.0, connect=5.0)` | Created only when backup is enabled; otherwise `None`. Ali is over public internet, so read is kept at 60s. |

Both clients share the existing `MAX_AI_CONNECTIONS` limit (one pool each of that size).

### 3. Exception classification

[app/services/image_to_event.py](../../../tools/app/services/image_to_event.py) currently collapses every outbound failure into `ConnectionError` / `TimeoutError` / `ValueError`, making failover decisions impossible at the call site. Split into two explicit exception types in the same module:

```python
class ProviderUnavailable(Exception):
    """Eligible for failover: connect error, pool timeout, read timeout, 5xx."""

class ProviderResponseError(ValueError):
    """Not eligible for failover: 4xx or non-parseable response."""
```

`extract_event_from_image` raises:

| httpx signal | Raised exception | Failover? |
| --- | --- | --- |
| `httpx.ConnectError` | `ProviderUnavailable("unreachable")` | yes |
| `httpx.PoolTimeout` | `ProviderUnavailable("busy")` | yes |
| `httpx.ReadTimeout` | `ProviderUnavailable("timeout")` | yes |
| `HTTPStatusError`, status ≥ 500 | `ProviderUnavailable(f"5xx {code}")` | yes |
| `HTTPStatusError`, status 4xx | `ProviderResponseError(f"4xx {code}: {body[:200]}")` | no |
| Empty / non-JSON / schema mismatch | `ProviderResponseError(...)` (existing path) | no |

Rationale: 4xx almost always means the request itself is malformed (e.g., image too large, bad payload) — calling Ali would produce the same 4xx and waste a billable request. `ValueError` path ("model returned garbage") is not failed over either, for the same cost reason.

### 4. Failover wrapper

Add to the same service module:

```python
@dataclass
class ProviderConfig:
    client: httpx.AsyncClient
    model: str
    key: str
    name: str  # "primary" | "backup" — used for logging and the response header

async def extract_with_failover(
    primary: ProviderConfig,
    backup: ProviderConfig | None,
    image_bytes: bytes,
    content_type: str,
    categories: list[dict] | None,
) -> tuple[EventDraft, str]:
    """Returns (draft, provider_name_that_succeeded)."""
    try:
        draft = await extract_event_from_image(
            primary.client, image_bytes, content_type,
            primary.model, primary.key, categories,
        )
        return draft, primary.name
    except ProviderUnavailable as e_primary:
        if backup is None:
            raise
        logger.warning("primary unavailable, failing over: %s", e_primary)
        try:
            draft = await extract_event_from_image(
                backup.client, image_bytes, content_type,
                backup.model, backup.key, categories,
            )
            return draft, backup.name
        except Exception as e_backup:
            logger.error(
                "both providers failed: primary=%s backup=%s",
                e_primary, e_backup,
            )
            raise  # backup's exception propagates
```

Maximum outbound cost per request: **2 AI calls** (primary then backup). No inner retries.

### 5. Handler wiring

In [app/main.py](../../../tools/app/main.py), the `/image-to-event` handler:

1. Builds `ProviderConfig` for primary (always) and backup (only when enabled).
2. Calls `extract_with_failover(...)`.
3. On success, returns `JSONResponse(content={"data": ...})` **and** sets response header `X-AI-Provider: primary|backup`.
4. Exception mapping (unchanged semantics for existing codes):
   - `ProviderUnavailable` with "busy" → 429
   - `ProviderUnavailable` other → 502
   - `ProviderResponseError` containing "No event content" → 400 (existing no-event behavior)
   - `ProviderResponseError` other → 500

### 6. `/health`

Return per-provider status:

```json
{
  "status": "ok",
  "version": "...",
  "providers": {
    "primary": {"reachable": true},
    "backup":  {"reachable": true, "configured": true}
  }
}
```

Rules:
- Both reachable → `status: "ok"`
- Primary unreachable, backup reachable → `status: "degraded"`
- Both unreachable → `status: "down"`
- Backup not configured → `providers.backup = {"configured": false}`, and `status` is derived from primary alone (`ok` or `down`).

Each provider is probed by `GET {base_url}/models` with its own key, as today. Probes run concurrently to keep `/health` fast.

### 7. Observability

- **Response header `X-AI-Provider: primary|backup`** on successful `/image-to-event` responses. Caller (Django / app) can monitor failover rate without body changes.
- **Structured logs** in the service at `warning` when failover fires and `error` when both fail, including the triggering exception's message.
- Response body schema is unchanged.

## Testing

Add `tools/tests/test_failover.py`. Mock each provider with its own `httpx.MockTransport` (following the pattern in existing `conftest.py`). Existing tests remain untouched — they default to backup-disabled and exercise the single-provider path.

| Scenario | Mock setup | Expected |
| --- | --- | --- |
| primary OK | primary 200 | 200, `X-AI-Provider: primary`, backup client not called |
| primary 5xx → backup OK | primary 503, backup 200 | 200, `X-AI-Provider: backup`, each client called once |
| primary read-timeout → backup OK | primary raises `ReadTimeout`, backup 200 | 200, `X-AI-Provider: backup` |
| primary connect-error → backup OK | primary raises `ConnectError`, backup 200 | 200, `X-AI-Provider: backup` |
| primary 4xx (no failover) | primary 400 | 500 (`ProviderResponseError`), backup not called |
| both fail | primary 503, backup `ConnectError` | 502, backup's exception surfaced |
| backup not configured + primary down | backup env unset, primary 503 | 502, single-provider behavior |
| `/health` both up | both 200 on `GET /models` | `{"status": "ok", ...}` |
| `/health` primary down, backup up | primary timeout, backup 200 | `{"status": "degraded", ...}` |
| `/health` backup not configured | backup env unset | `providers.backup.configured: false` |

## Rollout

1. Land code + tests with `BACKUP_AI_*` unset in all environments → zero behavior change, safe merge.
2. In the target deployment's `.env`, set `BACKUP_AI_URL=https://dashscope.aliyuncs.com/compatible-mode/v1/`, `BACKUP_AI_KEY=<DashScope API key>`, `BACKUP_AI_MODEL=qwen-vl-ocr-latest` (or pinned version).
3. Verify `/health` reports `providers.backup.configured: true` and `reachable: true`.
4. Simulate primary outage (stop the self-hosted container or block the URL) and confirm `/image-to-event` still succeeds with `X-AI-Provider: backup`.

## Open questions

None at spec time. If Qwen-VL-OCR's outputs diverge enough from the primary model to break `EventDraft` schema validation, a follow-up can split the prompt per provider: `prompts/image_to_event.txt` stays for primary, `prompts/image_to_event_qwen.txt` is added for backup, and the service picks based on `ProviderConfig.name`. Not done now (YAGNI) — wait for real failures in testing before investing.
