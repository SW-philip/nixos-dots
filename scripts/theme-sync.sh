#!/usr/bin/env bash
# theme-sync: keep desktop and surface on the same drmis theme, newest change wins.
# Compares ~/.local/state/theme (slug + mtime) with the peer's; when the peer's is newer and
# differs, applies it with `drmis set`, then stamps the local file with the peer's mtime so the
# peer sees equal times and never echoes it back. Pull-only: each host runs it against the other.
set -uo pipefail

STATE=${THEME_SYNC_STATE:-$HOME/.local/state/theme}
PEER=${THEME_SYNC_PEER:?THEME_SYNC_PEER not set}
DRMIS=${THEME_SYNC_DRMIS:-drmis}
NET_TIMEOUT=${THEME_SYNC_TIMEOUT:-15}
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

local_slug=""; local_mtime=0
if [[ -f $STATE ]]; then
  local_slug=$(<"$STATE")
  local_mtime=$(stat -c %Y "$STATE")
fi

# One line: "<mtime> <slug>"; empty when the peer has no state yet.
# shellcheck disable=SC2016  # single quotes on purpose: the peer's shell expands $HOME and $f
peer_line=$(timeout "$NET_TIMEOUT" ssh "${SSH_OPTS[@]}" "$PEER" \
  'f=$HOME/.local/state/theme; [ -f "$f" ] && echo "$(stat -c %Y "$f") $(cat "$f")"' 2>/dev/null) || {
  echo "theme-sync: $PEER unreachable, skipping"; exit 0; }
[[ -n $peer_line ]] || exit 0

peer_mtime=${peer_line%% *}
peer_slug=${peer_line#* }
[[ $peer_mtime =~ ^[0-9]+$ && -n $peer_slug ]] || { echo "theme-sync: bad reply from $PEER: $peer_line" >&2; exit 0; }

(( peer_mtime > local_mtime )) || exit 0
[[ $peer_slug != "$local_slug" ]] || exit 0

# the wallpaper PNG is gitignored and arrives by tree-sync assets; fetch before switching
command -v tree-sync >/dev/null && tree-sync assets >/dev/null 2>&1

echo "theme-sync: $PEER switched to $peer_slug, following"
if "$DRMIS" set "$peer_slug"; then
  touch -d "@$peer_mtime" "$STATE"
else
  echo "theme-sync: drmis set $peer_slug failed (unknown theme here? rebuild first)" >&2
  exit 1
fi
