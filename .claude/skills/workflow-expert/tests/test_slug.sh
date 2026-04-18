#!/bin/bash
set -eu

SCRIPT="$(dirname "$0")/../scripts/slug.sh"

pass=0; fail=0

assert_eq() {
  local desc="$1" input="$2" expected="$3"
  local actual
  actual="$("$SCRIPT" "$input")"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $desc"
    pass=$((pass+1))
  else
    echo "  FAIL: $desc"
    echo "    input:    '$input'"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
    fail=$((fail+1))
  fi
}

echo "test_slug.sh"
assert_eq "basic lowercase"     "Hello World"                               "hello-world"
assert_eq "punctuation"         "Fix: login crash!"                         "fix-login-crash"
assert_eq "all caps"            "SECURITY FIX"                              "security-fix"
assert_eq "multiple spaces"     "a   b   c"                                 "a-b-c"
assert_eq "leading/trailing"    "  --foo--  "                               "foo"
assert_eq "long title"          "All-day events not show on device dashboard page" \
                                "all-day-events-not-show-on-device-dashboard-page"
assert_eq "digits preserved"    "Issue 143 repro"                           "issue-143-repro"
assert_eq "unicode dropped"     "test-bug-fix"                              "test-bug-fix"

echo "test_slug.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
