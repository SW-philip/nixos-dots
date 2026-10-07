#!/usr/bin/env bash
# app-launch <desktop-id> [args...] — open a registry app here or on another fleet host.
set -euo pipefail

REGISTRY=${APP_LAUNCH_REGISTRY:-$HOME/.config/app-launch/registry.json}
FLEET=${APP_LAUNCH_FLEET:-$HOME/.cache/fleet-status.json}
STATE=${APP_LAUNCH_STATE:-$HOME/.local/state/app-launch}
PICKER=${APP_LAUNCH_PICKER:-fuzzel --dmenu --prompt "Open on › " --width 300}

[[ $# -ge 1 ]] || { echo "usage: app-launch <desktop-id> [args...]" >&2; exit 2; }
id=$1; shift

app=$(jq -c --arg id "$id" '.apps[$id] // empty' "$REGISTRY")
[[ -n $app ]] || { echo "app-launch: '$id' is not in the registry" >&2; exit 2; }
self=$(jq -r .self "$REGISTRY")
mapfile -t local_cmd < <(jq -r '.exec[]' <<<"$app")
mapfile -t remote_cmd < <(jq -r '.remoteExec[]' <<<"$app")
here=$(jq -r --arg self "$self" '(.hosts | index($self)) != null' <<<"$app")

fail() {
  echo "app-launch: $1" >&2
  notify-send -u critical "app-launch" "$1"
  exit 1
}

# files and URLs handed to us (xdg-open, a file manager) live on this host: never offer another
if [[ $# -gt 0 ]]; then
  [[ $here == true ]] || fail "$id is not installed on $self, so it can't open local files or links"
  exec "${local_cmd[@]}" "$@"
fi

# no snapshot: offer every host and let ssh report, rather than hiding them all
choices=()
while IFS= read -r h; do
  if [[ -r $FLEET ]] && ! jq -e --arg h "$h" '.hosts[] | select(.host == $h and .up and .ssh_ok)' "$FLEET" >/dev/null; then
    continue
  fi
  choices+=("$h")
done < <(jq -r --arg self "$self" '.hosts[] | select(. != $self)' <<<"$app")

menu=("${choices[@]}")
if [[ $here == true ]]; then menu=(here "${menu[@]}"); fi
[[ ${#menu[@]} -gt 0 ]] || fail "$id is not installed on $self and no host that has it is reachable"

if [[ ${#menu[@]} -eq 1 ]]; then
  pick=${menu[0]}
else
  last=$(cat "$STATE/$id" 2>/dev/null || true)
  ordered=()
  for m in "${menu[@]}"; do [[ $m == "$last" ]] && ordered+=("$m"); done
  for m in "${menu[@]}"; do [[ $m == "$last" ]] || ordered+=("$m"); done

  # shellcheck disable=SC2086  # PICKER is a command line, split on purpose
  pick=$(printf '%s\n' "${ordered[@]}" | $PICKER) || exit 0
  [[ -n $pick ]] || exit 0

  mkdir -p "$STATE"
  printf '%s\n' "$pick" > "$STATE/$id"
fi

if [[ $pick == here ]]; then exec "${local_cmd[@]}"; fi

start=$SECONDS
on "$pick" "${remote_cmd[@]}" && exit 0
rc=$?
# a quick non-zero exit is a failed launch; a long-lived app closing is not worth a notification
if (( SECONDS - start < 10 )); then
  notify-send -u critical "app-launch" "$id on $pick failed (exit $rc)"
fi
exit "$rc"
