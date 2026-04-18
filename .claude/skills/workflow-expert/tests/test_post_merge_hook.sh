#!/bin/bash
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SKILL_DIR/hooks/post-merge-notify.sh"

pass=0; fail=0

# Helper: pipe the JSON payload Claude Code sends on PostToolUse, capture stderr.
run_hook() {
  local cmd="$1"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_input: {command: $c}}')
  echo "$payload" | "$HOOK" 2>&1 >/dev/null
}

assert_event() {
  local desc="$1" cmd="$2" expected_event="$3"
  local out
  out=$(run_hook "$cmd")
  if [ -z "$expected_event" ]; then
    if [ -z "$out" ]; then
      echo "  PASS: $desc → no-op"
      pass=$((pass+1))
    else
      echo "  FAIL: $desc → expected no output, got: $out"
      fail=$((fail+1))
    fi
  else
    if echo "$out" | grep -q "$expected_event"; then
      echo "  PASS: $desc → $expected_event"
      pass=$((pass+1))
    else
      echo "  FAIL: $desc → expected '$expected_event', got: $out"
      fail=$((fail+1))
    fi
  fi
}

echo "test_post_merge_hook.sh"
assert_event "gh pr merge"          "gh pr merge 42 --squash"                         "pr-merged"
assert_event "git merge --squash"   "git merge --squash feat/foo"                     "pr-merged"
assert_event "deploy to prod"       "git push origin main:env/prod --force"           "deployed-prod"
assert_event "deploy to test (skip)" "git push origin main:env/test --force"          ""
assert_event "unrelated command"    "npm run build"                                    ""

echo "test_post_merge_hook.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
