#!/usr/bin/env bash
# on-demand SMART health summary; use -s or -l to trigger a test

set -euo pipefail

[[ $EUID -ne 0 ]] && exec sudo "$0" "$@"

TRIGGER=
while getopts ":sl" opt; do
  case $opt in
    s) TRIGGER=short ;;
    l) TRIGGER=long ;;
    *) printf 'Usage: %s [-s|-l]\n  -s  trigger short self-test\n  -l  trigger long self-test\n' "$0" >&2; exit 1 ;;
  esac
done

div()  { printf '%.0s─' {1..56}; printf '\n'; }
igrep() { grep -E "$1" <<< "$2" | sed 's/^/  /' || true; }

while read -r dev; do
  div
  printf '  %s\n' "$dev"
  div

  data=$(smartctl -a "$dev" 2>&1 || true)

  igrep "^(Device Model|Model Number|Serial Number|Firmware Version):" "$data"
  echo

  igrep "^SMART (overall-health|Health Status)" "$data"
  igrep "(Temperature_Celsius|^Temperature:)" "$data"

  # HDD: reallocated / pending / uncorrectable sectors (attributes 5, 197, 198)
  grep -E "^[[:space:]]*(5|197|198)[[:space:]]" <<< "$data" | \
    grep -iE "(Reallocated|Pending|Uncorrectable)" | sed 's/^/  /' || true

  # NVMe: key health counters
  igrep "^(Media and Data Integrity|Available Spare|Percentage Used)" "$data"

  echo
  printf '  Recent self-tests:\n'
  tests=$(grep -A 40 "Self-test log" <<< "$data" | \
    grep -E "(# [0-9]|Short|Extended|Completed|Failed|Aborted)" | head -5 || true)
  if [[ -n "$tests" ]]; then
    while IFS= read -r t; do printf '    %s\n' "$t"; done <<< "$tests"
  else
    printf '    (no tests recorded — smartd schedules nightly short, Sunday long)\n'
  fi

  if [[ -n "$TRIGGER" ]]; then
    echo
    printf '  Triggering %s self-test on %s...\n' "$TRIGGER" "$dev"
    smartctl -t "$TRIGGER" "$dev" 2>&1 | \
      grep -iE "^(Testing|Please)" | sed 's/^/  /' || true
  fi

  echo
done < <(smartctl --scan | awk '{print $1}')
