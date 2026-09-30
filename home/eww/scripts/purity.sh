#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

clients=0
if windows=$(niri msg --json windows 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$windows"; then
  # niri attributes rootless XWayland windows to xwayland-satellite's own pid,
  # not the real client's — matching window pid against the satellite pid set
  # is how this collector counts them.
  sat_pids=$(pgrep -f '^xwayland-satellite' 2>/dev/null | sort -u || true)
  if [[ -n "$sat_pids" ]]; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      grep -qx "$pid" <<<"$sat_pids" && clients=$((clients + 1))
    done < <(jq -r '.[].pid // empty' <<<"$windows")
  fi
fi

pure=true
(( clients > 0 )) && pure=false

out=$(jq -nc --argjson clients "$clients" --argjson pure "$pure" \
  '{clients:$clients, pure:$pure}')
printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-purity.json"
