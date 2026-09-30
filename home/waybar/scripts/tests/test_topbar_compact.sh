#!/usr/bin/env bash
# quantum-bluetooth.sh and netstatus.sh feed one shared cache, read by the
# compact top-bar module through `jq '.text = (.text_compact // .text)'`.
# If any branch's jq object omits `text_compact`, that state silently falls back
# to the rich `text` field on the top bar and shoves the module cluster around.
# Static check — no Bluetooth/network hardware required.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

for f in quantum-bluetooth.sh netstatus.sh; do
  path="$DIR/$f"
  count=0
  while IFS= read -r filter; do
    count=$((count + 1))
    if [[ "$filter" == *text_compact* ]]; then
      echo "PASS: $f — $filter"
    else
      echo "FAIL: $f — waybar-JSON jq filter without text_compact: $filter"
      fail=1
    fi
  done < <(grep -oE "'\{text[^']*\}'" "$path")
  if (( count < 1 )); then
    echo "FAIL: $f — no waybar-JSON jq filter matched (pattern drift?)"
    fail=1
  fi
done

if (( fail == 0 )); then echo "All tests passed."; else echo "Some tests failed."; fi
exit $fail
