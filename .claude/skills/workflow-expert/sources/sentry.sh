#!/bin/bash
# sources/sentry.sh — stub. Will fetch a Sentry issue once configured.
# Input:  $1 = Sentry issue id
# Output (stdout on success): common adapter JSON (see spec section 7)
# Exit codes: 0 success, 2 not configured, other runtime.

# shellcheck disable=SC1091
source "$(dirname "$0")/../config.env" 2>/dev/null || true

set -eu

if [ -z "${SENTRY_TOKEN:-}" ]; then
  echo "sentry source not configured: set SENTRY_TOKEN in .claude/skills/workflow-expert/config.env" >&2
  exit 2
fi

echo "sentry source: fetch not yet implemented" >&2
exit 2
