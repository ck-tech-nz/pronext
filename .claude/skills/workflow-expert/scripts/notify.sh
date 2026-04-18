#!/bin/bash
# scripts/notify.sh — team notification stub.
# Invoked by hooks/post-merge-notify.sh with:
#   $1 = event name: "pr-merged" | "deployed-prod"
#   $2 = originating command string
#
# To wire a real channel (Slack, Feishu, etc.), edit ONLY this file.
# Load tokens from ../config.env (already gitignored).

set -eu

event="${1:-unknown}"
cmd="${2:-}"

# Source config.env if present (safe: won't fail when absent).
# shellcheck disable=SC1091
source "$(dirname "$0")/../config.env" 2>/dev/null || true

# TODO: wire up real channel. Example future body (commented):
# payload=$(jq -nc --arg text "event=$event" '{text: $text}')
# curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null

echo "[notify stub] event=$event cmd=$cmd" >&2
exit 0
