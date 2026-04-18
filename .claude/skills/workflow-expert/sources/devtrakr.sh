#!/bin/bash
# sources/devtrakr.sh — stub. Will fetch a DevTrakr ticket once configured.
# Input:  $1 = ticket id
# Output (stdout on success): common adapter JSON (see spec section 7)
# Exit codes: 0 success, 2 not configured, other runtime.

# shellcheck disable=SC1091
source "$(dirname "$0")/../config.env" 2>/dev/null || true

set -eu

if [ -z "${DEVTRAKR_TOKEN:-}" ] || [ -z "${DEVTRAKR_BASE_URL:-}" ]; then
  echo "devtrakr source not configured: set DEVTRAKR_TOKEN and DEVTRAKR_BASE_URL in .claude/skills/workflow-expert/config.env" >&2
  exit 2
fi

echo "devtrakr source: fetch not yet implemented" >&2
exit 2
