#!/usr/bin/env bash
# Refactor equivalence check: snapshot every host's system + home-manager drvPaths,
# then diff two snapshots. Identical drvs = zero behavior change.
#   drv-equiv.sh snap <name> [host...]   evaluate the working tree, save as <name>
#   drv-equiv.sh diff <a> <b>            compare; on a mismatch, nix-diff the first one
# configurationRevision embeds HEAD/dirtyRev, so it is pinned via extendModules
# or every commit would differ.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
state="${XDG_STATE_HOME:-$HOME/.local/state}/drv-equiv"
mkdir -p "$state"

snap() {
  local name="$1"; shift
  local hosts=("$@")
  [ ${#hosts[@]} -gt 0 ] || hosts=(desktop surface retro pi)
  local out="$state/$name.json" tmp
  tmp="$(mktemp -d)"
  for h in "${hosts[@]}"; do
    echo "eval $h..." >&2
    nix eval --impure --json --expr "
      let f   = builtins.getFlake \"git+file://$root\";
          lib = f.inputs.nixpkgs.lib;
          c   = f.nixosConfigurations.$h.extendModules {
                  modules = [ { system.configurationRevision = lib.mkForce \"drv-equiv\"; } ];
                };
          hm  = if c.config ? home-manager then c.config.home-manager.users else { };
      in { \"$h\" = { system = c.config.system.build.toplevel.drvPath; }
                    // lib.mapAttrs (_: u: u.home.activationPackage.drvPath) hm; }
    " > "$tmp/$h.json"
  done
  jq -s 'add' "$tmp"/*.json > "$out"
  rm -rf "$tmp"
  echo "saved $out" >&2
}

diffsnap() {
  local a="$state/$1.json" b="$state/$2.json"
  local changed
  changed="$(jq -rn --slurpfile a "$a" --slurpfile b "$b" '
    $a[0] as $a | $b[0] as $b
    | $a | paths(strings) as $p
    | ($a | getpath($p)) as $x | ($b | getpath($p)) as $y
    | select($y != null and $x != $y)
    | "\($p | join("."))\t\($x)\t\($y)"')"
  if [ -z "$changed" ]; then echo "identical: every common drv matches"; return 0; fi
  printf '%s\n' "$changed" | cut -f1 | sed 's/^/differs: /'
  local first
  first="$(printf '%s\n' "$changed" | head -1)"
  echo "--- nix-diff ${first%%$'\t'*}"
  nix run nixpkgs#nix-diff -- --skip-already-compared \
    "$(cut -f2 <<<"$first")" "$(cut -f3 <<<"$first")" | head -80
  return 1
}

case "${1:-}" in
  snap) shift; snap "$@" ;;
  diff) shift; diffsnap "$@" ;;
  *) echo "usage: drv-equiv.sh snap <name> [host...] | diff <a> <b>" >&2; exit 2 ;;
esac
