#!/usr/bin/env bash
# Shared helpers for the waybar shell scripts; source, don't execute.
#   source "$(dirname "${BASH_SOURCE[0]}")/waybar-lib.sh"

SNARK_FILE="${SNARK_FILE:-$HOME/.config/waybar/snark.json}"

# `snark off` creates this file; every snark consumer checks it per pick.
snark_quiet() { [[ -e "${XDG_STATE_HOME:-$HOME/.local/state}/snark-off" ]]; }

# waybar_unsnark <tooltip> — in quiet mode, drop the trailing rule + snark line.
waybar_unsnark() {
  local t="$1"
  if snark_quiet; then t=${t%$'\n'*}; t=${t%$'\n'*}; fi
  printf '%s' "$t"
}

# waybar_snark <category> <bucket> [fallback] — random line from
# snark.json[category][bucket], else the fallback. Empty when quiet.
waybar_snark() {
  local category="$1" bucket="$2" fallback="${3:-}" s
  snark_quiet && return 0
  if [[ -f "$SNARK_FILE" ]] && command -v jq >/dev/null; then
    s=$(jq -r ".${category}.${bucket}[]?" "$SNARK_FILE" 2>/dev/null | shuf -n1 || true)
    if [[ -n "$s" && "$s" != "null" ]]; then
      echo "$s"
      return
    fi
  fi
  echo "$fallback"
}

# Escape device-controlled strings before they land in Pango markup. `&`
# first, or it double-escapes the entities from the later substitutions.
pango_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<<"$1"
}
