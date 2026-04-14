---
description: Start all three Go calendar syncers (Google, ICS, Outlook) locally. Requires Django running on port 8000.
---

Start all three Go calendar syncers in the background by running their run.sh scripts:

1. `scripts/go/google_syncer/run.sh`
2. `scripts/go/ics_syncer/run.sh`
3. `scripts/go/outlook_syncer/run.sh`

Run all three in parallel using background Bash commands. Each syncer should run from the backend directory.

Before starting, verify Django is reachable on localhost:8000 with a quick curl check. If not, warn the user but still start the syncers.

Show the user a summary of what's running and how to check logs.
