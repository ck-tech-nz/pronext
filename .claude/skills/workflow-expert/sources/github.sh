#!/bin/bash
# sources/github.sh — fetch a GitHub issue and emit the common adapter JSON.
# Input:  $1 = issue number
# Output (stdout): {"title": "...", "body": "...", "url": "...", "labels": [...]}
# Exit codes:
#   0 = success
#   2 = not configured (n/a for github — `gh` either works or it does not)
#   other = runtime failure (issue not found, network, no auth, etc.)

set -eu

id="${1:-}"
if [ -z "$id" ]; then
  echo "Usage: sources/github.sh <issue_number>" >&2
  exit 1
fi

# Fetch; pass through gh's exit code on failure.
gh issue view "$id" --json title,body,labels,url
