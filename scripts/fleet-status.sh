#!/usr/bin/env bash
# fleet-status: probe every fleet host and write one JSON snapshot for ff and waybar.
# Reachability from tailscale, what each host runs from `nixos-version --configuration-revision`
# over ssh, how far behind that is from this host's git history. An unreachable host is data,
# not an error.
set -euo pipefail

ROOT=${FLEET_ROOT:-$HOME/nixos}
OUT=${FLEET_OUT:-${XDG_CACHE_HOME:-$HOME/.cache}/fleet-status.json}
HOSTS=${FLEET_HOSTS:-"desktop surface retro pi"}
SELF=${FLEET_SELF:-$(uname -n)}
SSH_TIMEOUT=${FLEET_SSH_TIMEOUT:-5}
NOW=${FLEET_NOW:-$(date +%s)}
# two labeled lines, so an empty value (unstamped host prints nothing) cannot shift the other:
# rev=<deployed flake rev>, built=<when the current system generation was installed: mtime of the /nix/var/nix/profiles/system link, which survives reboots, unlike /run/current-system>
# absolute nixos-version path: a systemd user unit has no /run/current-system/sw/bin on PATH
# shellcheck disable=SC2016  # expanded on the probed host, not here
PROBE_CMD=${FLEET_PROBE_CMD:-'printf "rev=%s\n" "$(/run/current-system/sw/bin/nixos-version --configuration-revision 2>/dev/null)"; printf "built=%s\n" "$(stat -c %Y /nix/var/nix/profiles/system 2>/dev/null)"'}

nix_name() { case $1 in desktop) echo swphil ;; surface) echo swsurface ;; retro) echo swretro ;; pi) echo swpi ;; *) echo "$1" ;; esac; }
ts_name()  { case $1 in desktop) echo swphil ;; surface) echo swsurface ;; *) echo "$1" ;; esac; }

ts_json=$(timeout 10 tailscale status --json 2>/dev/null) || ts_json='{}'
ts_ok=0; jq -e '.Self and .BackendState == "Running"' <<<"$ts_json" >/dev/null 2>&1 && ts_ok=1

if git -C "$ROOT" rev-parse -q --verify refs/heads/wip >/dev/null 2>&1; then HEAD_REF=wip; else HEAD_REF=main; fi
HEAD_SHA=$(git -C "$ROOT" rev-parse "$HEAD_REF" 2>/dev/null || true)

# drift counts only commits that can change what a host runs: docs, notes and tests never do.
# desktop/surface build from nearly the whole tree; retro and pi are plain nixosSystems that only
# reach a few paths (their hosts/ dir plus what it imports), so a commit elsewhere is not pending
# for them. Keep these lists in step with the imports in hosts/retro and hosts/pi.
drift_paths() {
  case $1 in
    pi)    DRIFT_PATHS=(-- flake.nix flake.lock hosts/pi identities roles/ssh-known-hosts.nix) ;;
    retro) DRIFT_PATHS=(-- flake.nix flake.lock hosts/retro identities roles pkgs/josefin-sans.nix themes/Custom/slate-lavender) ;;
    *)     DRIFT_PATHS=(-- . ':(exclude)docs' ':(exclude)*.md' ':(exclude).superpowers' ':(exclude)scripts/tests' ':(exclude).claude-shared') ;;
  esac
}

# match either Tailscale name: retro/pi are registered under their short names today and may be
# renamed to SWretro/SWpi (their nixos hostnames) at any time
is_online() {
  jq -e --arg a "$(ts_name "$1")" --arg b "$(nix_name "$1")" \
    '([.Self] + [.Peer[]?]) | map(select((((.HostName // "") | ascii_downcase) as $h | $h == $a or $h == $b) and (.Online // false))) | length > 0' \
    <<<"$ts_json" >/dev/null 2>&1
}

probe_host() {
  local host=$1 raw="" rev="" built="" base age=null drift=null ahead=null
  local up=false ssh_ok=false dirty=false

  if [[ "${SELF,,}" == "$(nix_name "$host")" ]]; then
    up=true
    if raw=$(bash -c "$PROBE_CMD" 2>/dev/null); then ssh_ok=true; fi
  else
    is_online "$host" && up=true
    # skip the ssh attempt only when tailscale answered and says the host is offline
    if (( ts_ok == 0 )) || [[ $up == true ]]; then
      if raw=$(timeout "$((SSH_TIMEOUT + 3))" ssh -n -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" "$PROBE_CMD" 2>/dev/null); then
        ssh_ok=true; up=true
      fi
    fi
  fi

  if [[ $ssh_ok == true ]]; then
    rev=$(sed -n '/^rev=/{s///p;q}' <<<"$raw")
    built=$(sed -n '/^built=/{s///p;q}' <<<"$raw")
    [[ "$rev" == unknown || "$rev" == null ]] && rev=""
    if [[ "$built" =~ ^[0-9]+$ ]]; then age=$((NOW - 10#$built)); else built=""; fi
    base=$rev
    drift_paths "$host"
    if [[ "$rev" == *-dirty ]]; then dirty=true; base=${rev%-dirty}; fi
    if [[ -n "$base" && -n "$HEAD_SHA" ]] && git -C "$ROOT" cat-file -e "$base^{commit}" 2>/dev/null; then
      drift=$(git -C "$ROOT" rev-list --count "$base..$HEAD_SHA" "${DRIFT_PATHS[@]}")
      ahead=$(git -C "$ROOT" rev-list --count "$HEAD_SHA..$base" "${DRIFT_PATHS[@]}")
    fi
  fi

  jq -n --arg host "$host" --argjson up "$up" --argjson ssh_ok "$ssh_ok" --arg rev "$rev" \
    --argjson dirty "$dirty" --argjson built_at "${built:-null}" --argjson age "$age" \
    --argjson drift "$drift" --argjson ahead "$ahead" \
    '{host:$host, up:$up, ssh_ok:$ssh_ok, rev:(if $rev == "" then null else $rev end), dirty:$dirty,
      built_at:$built_at, built_age_s:$age, drift:$drift, ahead:$ahead}'
}

# global on purpose: an EXIT trap runs after main() returns, when a local would be unset (set -u)
TMP=""
cleanup() { [[ -z "$TMP" ]] || rm -f "$TMP"; }
trap cleanup EXIT

main() {
  local hosts h
  read -ra hosts <<<"$HOSTS"
  mkdir -p "$(dirname "$OUT")"
  TMP=$(mktemp "$OUT.XXXXXX")
  { for h in "${hosts[@]}"; do probe_host "$h"; done; } \
    | jq -s --argjson now "$NOW" --arg head "$HEAD_SHA" --arg ref "$HEAD_REF" \
        '{generated_at:$now, head:(if $head == "" then null else $head end), head_ref:$ref, hosts:.}' > "$TMP"
  chmod 644 "$TMP"
  mv "$TMP" "$OUT"
}
main
