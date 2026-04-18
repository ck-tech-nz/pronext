#!/bin/bash
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

pass=0; fail=0

check_stub() {
  local source="$1"
  local script="$SKILL_DIR/sources/$source.sh"

  set +e
  out=$("$script" 123 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 2 ]; then
    echo "  PASS: $source stub exits 2"
    pass=$((pass+1))
  else
    echo "  FAIL: $source stub should exit 2, got $rc"
    fail=$((fail+1))
  fi

  if echo "$out" | grep -qi "not configured"; then
    echo "  PASS: $source stub message mentions 'not configured'"
    pass=$((pass+1))
  else
    echo "  FAIL: $source stub message missing 'not configured'"
    fail=$((fail+1))
  fi
}

echo "test_sources_stubs.sh"
check_stub sentry
check_stub devtrakr

echo "test_sources_stubs.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
