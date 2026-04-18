#!/bin/bash
set -eu

SCRIPT="$(dirname "$0")/../scripts/parse_source.sh"

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

echo "test_parse_source.sh"
# github forms
assert_eq "i prefix"            "i99"                    "github 99"
assert_eq "issue# form"         "issue#99"               "github 99"
assert_eq "issue space form"    "issue 99"               "github 99"
assert_eq "bare digits"         "42"                     "github 42"
# sentry forms
assert_eq "s prefix"            "s501"                   "sentry 501"
assert_eq "sentry# form"        "sentry#501"             "sentry 501"
assert_eq "sentry space form"   "sentry 501"             "sentry 501"
# devtrakr forms
assert_eq "d prefix"            "d7"                     "devtrakr 7"
assert_eq "devtrakr# form"      "devtrakr#7"             "devtrakr 7"
# free text → new
assert_eq "free text"           "add dark mode"          "new add dark mode"
assert_eq "free with colon"     "Fix: login crash"       "new Fix: login crash"

echo "test_parse_source.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
