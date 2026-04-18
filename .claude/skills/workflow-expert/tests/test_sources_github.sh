#!/bin/bash
# Tests sources/github.sh by placing a mock `gh` on PATH.
set -eu

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SKILL_DIR/sources/github.sh"

pass=0; fail=0

# Create a temp dir with a fake `gh` that prints a canned JSON.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/gh" <<'EOF'
#!/bin/bash
# Mock: `gh issue view 143 --json title,body,labels,url`
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  ID="$3"
  case "$ID" in
    143)
      cat <<JSON
{
  "title": "All-day events not show on device dashboard page",
  "body":  "Repro: open dashboard with an all-day event today.",
  "labels": [{"name": "bug"}],
  "url":   "https://github.com/ck-tech-nz/pronext-vue/issues/143"
}
JSON
      ;;
    404)
      echo 'gh: issue not found' >&2
      exit 1
      ;;
    *)
      echo 'gh mock: unexpected id' >&2
      exit 1
      ;;
  esac
fi
EOF
chmod +x "$TMP/gh"
export PATH="$TMP:$PATH"

assert_contains() {
  local desc="$1" output="$2" needle="$3"
  if echo "$output" | grep -q "$needle"; then
    echo "  PASS: $desc"
    pass=$((pass+1))
  else
    echo "  FAIL: $desc — missing '$needle'"
    echo "  output: $output"
    fail=$((fail+1))
  fi
}

echo "test_sources_github.sh"

# Success case: id=143 → common JSON with title, body, url, labels
out=$("$SCRIPT" 143)
assert_contains "has title"  "$out" '"title":'
assert_contains "has body"   "$out" '"body":'
assert_contains "has url"    "$out" '"url":'
assert_contains "has labels" "$out" '"labels":'
assert_contains "title value" "$out" "All-day events"

# Failure case: id=404 → non-zero, non-2 exit
set +e
"$SCRIPT" 404 >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
  echo "  PASS: missing issue exits non-zero non-2 (got $rc)"
  pass=$((pass+1))
else
  echo "  FAIL: missing issue should exit non-zero non-2 (got $rc)"
  fail=$((fail+1))
fi

echo "test_sources_github.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
