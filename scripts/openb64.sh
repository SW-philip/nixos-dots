#!/usr/bin/env bash
# Decode a base64 string and open the result with xdg-open.
# Usage: openb64 <base64-string>   (or pipe/clipboard if no arg given)
set -euo pipefail

if [ $# -gt 0 ]; then
  input="$1"
elif [ ! -t 0 ]; then
  input="$(cat)"
else
  input="$(wl-paste)"
fi

# strip whitespace/padding, convert base64url -> base64, restore padding
input="$(printf '%s' "$input" | tr -d '[:space:]=' | tr '_-' '/+')"
pad=$(( (4 - ${#input} % 4) % 4 ))
input+="$(printf '=%.0s' $(seq 1 "$pad") 2>/dev/null || true)"

decoded="$(printf '%s' "$input" | base64 -d 2>/dev/null)" || {
  echo "openb64: not valid base64" >&2
  exit 1
}

case "$decoded" in
  http://*|https://*)
    exec firefox "$decoded"
    ;;
  *)
    printf '%s\n' "$decoded"
    ;;
esac
