#!/bin/bash
# hooks/post-merge-notify.sh
# Registered as a PostToolUse hook for Bash. Receives the tool call payload on stdin
# and delegates to scripts/notify.sh for exactly two events:
#   pr-merged    → on `gh pr merge …` or `git merge --squash …`
#   deployed-prod → on `git push origin main:env/prod …`
# env/test pushes deliberately do NOT fire.

set -eu

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

case "$cmd" in
  *"gh pr merge"*|*"git merge --squash"*)  event="pr-merged" ;;
  *"git push origin main:env/prod"*)        event="deployed-prod" ;;
  *)                                         exit 0 ;;
esac

"$(dirname "$0")/../scripts/notify.sh" "$event" "$cmd"
