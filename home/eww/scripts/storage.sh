#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C   # awk float formatting must stay dot-decimal regardless of locale

state_dir="${XDG_RUNTIME_DIR:-/tmp}"
[[ "${1:-}" == "--selftest" ]] && state_dir="$(mktemp -d)"

# One row per distinct btrfs filesystem, not per mount: this impermanence layout
# mounts every subvolume separately but df reports whole-fs stats for all of them.
# Strip the [/subvol] suffix so all subvols of one device collapse to one entry.
mapfile -t devices < <(findmnt --real -rno SOURCE -t btrfs 2>/dev/null | sed 's/\[.*//' | sort -u)
[[ ${#devices[@]} -gt 0 ]] || devices=(/)

mounts_json="[]"
for dev in "${devices[@]}"; do
  if ! read -r t used size pct < <(df -B1 --output=target,used,size,pcent "$dev" 2>/dev/null \
    | awk 'NR==2{gsub(/%/,"",$4); print $1, $2, $3, $4}'); then
    continue
  fi
  [[ -n "${t:-}" ]] || continue
  [[ "${used:-}" =~ ^[0-9]+$ && "${size:-}" =~ ^[0-9]+$ ]] || continue
  [[ "${pct:-}" =~ ^[0-9]+$ ]] || pct=0
  ug=$(awk -v u="$used" 'BEGIN{printf "%.0f", u/1073741824}')
  sg=$(awk -v s="$size" 'BEGIN{printf "%.0f", s/1073741824}')
  [[ "$ug" =~ ^[0-9]+$ ]] || ug=0
  [[ "$sg" =~ ^[0-9]+$ ]] || sg=0
  mounts_json=$(jq -c --arg t "$t" --argjson u "$ug" --argjson s "$sg" --argjson p "$pct" \
    '. + [{target:$t, used_gib:$u, size_gib:$s, pct:$p}]' <<<"$mounts_json")
done

data_used_gib=0.0; data_total_gib=0.0
uuid=""
for d in /sys/fs/btrfs/*/allocation; do
  [[ -d "$d" ]] || continue
  uuid=$(basename "$(dirname "$d")")
  break
done
if [[ -n "$uuid" ]]; then
  base="/sys/fs/btrfs/$uuid/allocation"
  du_raw=$(cat "$base/data/disk_used" 2>/dev/null || echo 0)
  dt_raw=$(cat "$base/data/disk_total" 2>/dev/null || echo 0)
  [[ "$du_raw" =~ ^[0-9]+$ ]] || du_raw=0
  [[ "$dt_raw" =~ ^[0-9]+$ ]] || dt_raw=0
  data_used_gib=$(awk -v x="$du_raw" 'BEGIN{printf "%.1f", x/1073741824}')
  data_total_gib=$(awk -v x="$dt_raw" 'BEGIN{printf "%.1f", x/1073741824}')
fi
[[ "$data_used_gib" =~ ^[0-9]+(\.[0-9]+)?$ ]] || data_used_gib=0.0
[[ "$data_total_gib" =~ ^[0-9]+(\.[0-9]+)?$ ]] || data_total_gib=0.0

generation=$(readlink /nix/var/nix/profiles/system 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)
[[ "$generation" =~ ^[0-9]+$ ]] || generation=0
generation_total=$({ ls -d /nix/var/nix/profiles/system-*-link 2>/dev/null || true; } | wc -l)
[[ "$generation_total" =~ ^[0-9]+$ ]] || generation_total=0

out=$(jq -nc --argjson mounts "$mounts_json" \
  --argjson du "$data_used_gib" --argjson dt "$data_total_gib" \
  --argjson gen "$generation" --argjson gent "$generation_total" \
  '{mounts:$mounts, data_used_gib:$du, data_total_gib:$dt, generation:$gen, generation_total:$gent}')

printf '%s\n' "$out"
[[ "${1:-}" == "--selftest" ]] || printf '%s\n' "$out" > "$state_dir/eww-storage.json"
