#!/usr/bin/env bash
# nixfetch-collect: copy each host's /var/lib/nixfetch/host.json into ~/.cache/nixfetch/<host>.json.
# A host that is down or returns junk keeps its previous cache; nixfetch shows it as stale.
set -euo pipefail

CACHE=${NIXFETCH_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nixfetch}
HOSTS=${NIXFETCH_HOSTS:-"desktop surface retro pi"}
SELF=${NIXFETCH_SELF:-$(uname -n)}
SRC=${NIXFETCH_SRC:-/var/lib/nixfetch/host.json}
SSH_TIMEOUT=${NIXFETCH_SSH_TIMEOUT:-5}

nix_name() { case $1 in desktop) echo swphil ;; surface) echo swsurface ;; retro) echo swretro ;; pi) echo swpi ;; *) echo "$1" ;; esac; }

mkdir -p "$CACHE"
for host in $HOSTS; do
  if [[ "${SELF,,}" == "$(nix_name "$host")" ]]; then
    raw=$(cat "$SRC" 2>/dev/null) || continue
  else
    raw=$(timeout "$((SSH_TIMEOUT + 3))" ssh -n -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$host" cat "$SRC" 2>/dev/null) || continue
  fi
  jq -e '.generated_at' <<<"$raw" >/dev/null 2>&1 || continue
  tmp=$(mktemp "$CACHE/.$host.XXXXXX")
  printf '%s\n' "$raw" > "$tmp"
  chmod 644 "$tmp"
  mv "$tmp" "$CACHE/$host.json"
done
