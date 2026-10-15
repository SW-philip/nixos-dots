#!/usr/bin/env bash
# nixfetch-sample: write this host's slow-to-compute flake facts as JSON for nixfetch-collect.
# Runs as a system unit (retro and pi have no home-manager); closure size is the expensive part.
set -euo pipefail

OUT=${NIXFETCH_OUT:-/var/lib/nixfetch/host.json}
LOCK=${NIXFETCH_LOCK:-}
PROFILE=${NIXFETCH_PROFILE:-/nix/var/nix/profiles/system}
BOOTED=${NIXFETCH_BOOTED:-/run/booted-system}
CURRENT=${NIXFETCH_CURRENT:-/run/current-system}
NOW=${NIXFETCH_NOW:-$(date +%s)}
HOST=${NIXFETCH_HOST:-$(uname -n)}
NIXOS_VERSION=${NIXFETCH_NIXOS_VERSION:-/run/current-system/sw/bin/nixos-version}

rev=$("$NIXOS_VERSION" --configuration-revision 2>/dev/null || true)
[[ "$rev" == unknown ]] && rev=""
version=$("$NIXOS_VERSION" 2>/dev/null || true)

generation=$(readlink "$PROFILE" 2>/dev/null | sed -n 's/^system-\([0-9]\+\)-link$/\1/p' || true)
built=$(stat -c %Y "$PROFILE" 2>/dev/null || true)

booted_same=false; [[ "$(readlink -f "$BOOTED")" == "$(readlink -f "$CURRENT")" ]] && booted_same=true
kernel_same=false; [[ "$(readlink -f "$BOOTED/kernel")" == "$(readlink -f "$CURRENT/kernel")" ]] && kernel_same=true

closure=$(nix --extra-experimental-features nix-command path-info -S "$CURRENT" 2>/dev/null | awk '{print $2}' || true)

inputs='[]'
if [[ -n "$LOCK" && -r "$LOCK" ]]; then
  inputs=$(jq -c '. as $d | [.nodes.root.inputs | to_entries[]
      | select(.value | type == "string")
      | {name: .key, last_modified: ($d.nodes[.value].locked.lastModified // null)}]' "$LOCK" 2>/dev/null || echo '[]')
fi

mkdir -p "$(dirname "$OUT")"
tmp=$(mktemp "$OUT.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq -n --arg host "$HOST" --argjson now "$NOW" --arg rev "$rev" --arg version "$version" \
  --arg gen "$generation" --arg built "$built" --argjson booted_same "$booted_same" \
  --argjson kernel_same "$kernel_same" --arg closure "$closure" --argjson inputs "$inputs" \
  '{host:$host, generated_at:$now, rev:(if $rev == "" then null else $rev end), version:$version,
    generation:(if $gen == "" then null else ($gen | tonumber) end),
    built_at:(if $built == "" then null else ($built | tonumber) end),
    booted_same:$booted_same, kernel_same:$kernel_same,
    closure_bytes:(if $closure == "" then null else ($closure | tonumber) end),
    inputs:$inputs}' > "$tmp"
chmod 644 "$tmp"
mv "$tmp" "$OUT"
