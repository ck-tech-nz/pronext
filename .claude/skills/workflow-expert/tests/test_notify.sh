#!/bin/bash
set -eu

SCRIPT="$(dirname "$0")/../scripts/notify.sh"

pass=0; fail=0

# Stub must exit 0 so it never blocks a PostToolUse hook chain.
# Stub must echo a line containing the event name to stderr, so it is grep-able by operators.

for event in pr-merged deployed-prod; do
  set +e
  out=$("$SCRIPT" "$event" "some command" 2>&1 1>/dev/null)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    echo "  PASS: exit 0 for $event"
    pass=$((pass+1))
  else
    echo "  FAIL: non-zero exit $rc for $event"
    fail=$((fail+1))
  fi

  if echo "$out" | grep -q "$event"; then
    echo "  PASS: stderr contains $event"
    pass=$((pass+1))
  else
    echo "  FAIL: stderr missing $event (got: $out)"
    fail=$((fail+1))
  fi
done

echo "test_notify.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
