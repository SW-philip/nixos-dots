# shellcheck shell=bash
# Shared helpers for the settings hub. Sourced by settings.sh and every handler.

# Same path home/niri/scripts.nix's set-default-sink checks; keep in sync.
# shellcheck disable=SC2034 # read by the handlers that source this file
PIN_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/audio-output-pinned"

# SETTINGS_PICKER swaps fuzzel for a shim in tests.
pick() {
  if [[ -n "${SETTINGS_PICKER:-}" ]]; then
    "$SETTINGS_PICKER" "$1"
  else
    fuzzel --dmenu --lines 12 --prompt "$1 "
  fi
}

toast() { notify-send -a Settings "$1" "${2:-}"; }

has_cap() { [[ " ${SETTINGS_CAPS:-} " == *" $1 "* ]]; }

# Conventions: run_menu <prompt> [cancel_rc] reads rows ("label<TAB>command")
# on stdin and returns the command's status. Special statuses:
#   10   Escape: "back to the hub" (cancel_rc)
#   11   a failure was already toasted; enclosing levels pass it up without
#        toasting again, and the hub exits 1 so callers still see a failure
#   >=128 fuzzel was killed (a second Mod+S press); passed straight through
run_menu() {
  local prompt=$1 cancel_rc=${2:-10}
  local -a labels=() cmds=() argv=()
  local label cmd choice rc=0 i
  while IFS=$'\t' read -r label cmd; do
    [[ -n "$label" ]] || continue
    labels+=("$label")
    cmds+=("$cmd")
  done
  if [[ "${SETTINGS_LIST:-0}" == 1 ]]; then
    printf '%s\n' "${labels[@]}"
    return 0
  fi
  choice=$(printf '%s\n' "${labels[@]}" | pick "$prompt") || rc=$?
  if (( rc >= 128 )); then return "$rc"; fi
  [[ -n "$choice" ]] || return "$cancel_rc"
  for i in "${!labels[@]}"; do
    [[ "${labels[$i]}" == "$choice" ]] || continue
    read -ra argv <<<"${cmds[$i]}"
    rc=0
    "${argv[@]}" || rc=$?
    if (( rc != 0 && rc != 10 && rc != 11 && rc < 128 )); then
      toast "Settings" "${labels[$i]} failed"
      rc=11
    fi
    return "$rc"
  done
  return "$cancel_rc"
}
