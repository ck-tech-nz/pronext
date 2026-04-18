#!/bin/bash
# parse_source.sh — classify /wf-start input.
# Usage: parse_source.sh "<input>"
# Output (stdout, one line): "<source> <id_or_text>"
#   source ∈ {github, sentry, devtrakr, new}

set -eu

input="${1:-}"
if [ -z "$input" ]; then
  echo "Usage: parse_source.sh <input>" >&2
  exit 1
fi

case "$input" in
  i[0-9]*)                            echo "github ${input#i}" ;;
  issue#[0-9]*)                       echo "github ${input#issue#}" ;;
  "issue "[0-9]*)                     echo "github ${input#issue }" ;;
  s[0-9]*)                            echo "sentry ${input#s}" ;;
  sentry#[0-9]*)                      echo "sentry ${input#sentry#}" ;;
  "sentry "[0-9]*)                    echo "sentry ${input#sentry }" ;;
  d[0-9]*)                            echo "devtrakr ${input#d}" ;;
  devtrakr#[0-9]*)                    echo "devtrakr ${input#devtrakr#}" ;;
  "devtrakr "[0-9]*)                  echo "devtrakr ${input#devtrakr }" ;;
  *)
    if [[ "$input" =~ ^[0-9]+$ ]]; then
      echo "github $input"
    else
      echo "new $input"
    fi
    ;;
esac
