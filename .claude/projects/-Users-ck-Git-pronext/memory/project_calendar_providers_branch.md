---
name: calendar-providers-branch
description: Backend calendar development continues on feat/calendar-providers branch (provider refactor complete)
type: project
---

Backend calendar work continues on `feat/calendar-providers` branch (not `feat/calendar-room`).

**Why:** Provider refactor (Strategy Pattern) completed on this branch — `feat/calendar-room` kept as backup.

**How to apply:** All future calendar sync/CUD work should be on `feat/calendar-providers`. The providers/ package is the canonical location for CUD operations. `options.py` only has sync_calendar + token management + re-exports.

Key commits (8 total): test matrix (27 tests) → ABC + factory → OutlookProvider → GoogleProvider → operations.py → viewset switch → rename sync.py → trim options.py. All 119 tests pass.
