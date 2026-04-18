#!/bin/bash
# Runs every test_*.sh in this directory. Exits non-zero on first failure.
set -eu

cd "$(dirname "$0")"

ran=0; failed=0
for t in test_*.sh; do
  [ -e "$t" ] || continue
  ran=$((ran+1))
  echo "--- $t ---"
  if ! ./"$t"; then
    failed=$((failed+1))
  fi
done

echo "==="
echo "Ran $ran test file(s), $failed failed."
[ "$failed" -eq 0 ]
