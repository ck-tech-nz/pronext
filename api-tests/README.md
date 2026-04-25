# api-tests

Plain-text HTTP request collections for manual / Claude-assisted API testing.
No app, no cloud, no account. Just `.http` files in git.

## Layout

```
api-tests/
├── .env.example       # template of required env vars (commit)
├── .env               # real tokens / URLs (gitignored, auto-loaded by httpyac)
├── backend/           # Django REST API (port 8000)
├── heartbeat/         # Go heartbeat service (port 8080)
└── external/          # Third-party APIs (Google, Microsoft Graph, iCloud, ...)
```

## Setup

```bash
cp api-tests/.env.example api-tests/.env
# then fill in real values in .env
```

## How to run a request

Three ways:

1. **In VS Code** — install the [httpyac extension](https://marketplace.visualstudio.com/items?itemName=anweber.vscode-httpyac). It auto-loads `.env` from a parent directory of the open `.http` file. Click "Send" above any request.
2. **CLI** — `npx httpyac send api-tests/external/google-calendar.http --line 32` runs request #32 and prints the response.
3. **Ask Claude** — "跑一下 backend/calendar.http 里 list synced calendars 那个请求". Claude reads the file, substitutes env vars from `.env`, runs `curl`, shows the response.

## File format

```http
### A short title for this request
# Optional comment explaining what it does
POST {{BACKEND_URL}}/api/some/endpoint
Authorization: Bearer {{AUTH_TOKEN}}
Content-Type: application/json

{
  "field": "value"
}

### Next request
GET {{BACKEND_URL}}/api/other
```

- `###` separates requests
- `{{VAR}}` references a variable from `.env`
- Lines starting with `#` are comments

## Conventions

- One file per logical module (auth, calendar, device, ...).
- Keep payloads small and realistic; trim noise.
- Never commit real tokens. Use `{{VAR}}` and put the value in `.env`.
- If a request depends on a previous response (e.g. login → token), note it in a comment above the dependent request.
