#!/bin/bash
# slug.sh — english string → kebab-case.
# Usage: slug.sh "Some Title String"
# Output (stdout): lowercased, non-alphanumeric collapsed to hyphens, trimmed.

set -eu

input="${1:-}"
if [ -z "$input" ]; then
  echo "Usage: slug.sh <string>" >&2
  exit 1
fi

echo "$input" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g' \
  | sed -E 's/^-+|-+$//g'
