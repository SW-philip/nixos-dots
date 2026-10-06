#!/usr/bin/env bash
# Eval test for home/fastfetch/config.nix (both variants). Imports nixpkgs: run on desktop.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
assert_eq() { if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi; }

# t is built like home/niri/default.nix's loadTheme, for one theme directory
render() {
  nix eval --impure --raw --expr "
    let
      flake = builtins.getFlake (toString $ROOT);
      pkgs  = flake.inputs.nixpkgs.legacyPackages.x86_64-linux;
      lib   = pkgs.lib;
      dir   = $ROOT + \"/themes/Custom/charcoal-cyan\";
      files = builtins.readDir dir;
      nixName = builtins.head (builtins.attrNames (
        lib.filterAttrs (n: _: lib.hasPrefix \"palette-\" n && lib.hasSuffix \".nix\" n) files));
      slug = lib.removeSuffix \".nix\" (lib.removePrefix \"palette-\" nixName);
      t = { family = \"Custom\"; inherit slug dir; palette = import \"\${dir}/\${nixName}\"; };
    in import $ROOT/home/fastfetch/config.nix {
      inherit t pkgs;
      config = { myConfig.isDesktop = true; home.homeDirectory = \"/home/prepko\"; };
      ssh = $1;
    }"
}

normal=$(render false) || { echo "FAIL: eval normal"; exit 1; }
sshv=$(render true)    || { echo "FAIL: eval ssh"; exit 1; }

count() { jq "[.modules[] | select(type==\"object\") | $2] | length" <<<"$1"; }

for v in normal ssh; do
  [[ $v == ssh ]] && j=$sshv || j=$normal
  assert_eq "$v: parses as JSON" "ok" "$(jq -e . <<<"$j" >/dev/null 2>&1 && echo ok || echo bad)"
  for h in desktop surface retro pi; do
    assert_eq "$v: fleet row $h" "1" "$(count "$j" "select(.type==\"command\" and ((.text // \"\") | endswith(\"/bin/ff-fleet $h\")))")"
  done
  assert_eq "$v: exactly four fleet rows" "4" "$(count "$j" 'select((.text // "") | test("/bin/ff-fleet "))')"
  assert_eq "$v: FLEET header" "1" "$(count "$j" 'select(.type=="custom" and ((.format // "") | contains("FLEET")))')"
  assert_eq "$v: closing box rule" "1" "$(count "$j" 'select(.type=="custom" and ((.format // "") | contains("╚")))')"
  assert_eq "$v: no raw # hex colour in script text" "0" "$(jq -r '.modules[] | select(type=="object") | (.text // "")' <<<"$j" | grep -c '#[0-9a-fA-F]\{6\}')"
done

assert_eq "normal: wm module" "1" "$(count "$normal" 'select(.type=="wm")')"
assert_eq "normal: terminal module" "1" "$(count "$normal" 'select(.type=="terminal")')"
assert_eq "normal: DESKTOP header" "1" "$(count "$normal" 'select(.type=="custom" and ((.format // "") | contains("DESKTOP")))')"
assert_eq "normal: no SESSION header" "0" "$(count "$normal" 'select((.format // "") | contains("SESSION"))')"

assert_eq "ssh: SESSION header" "1" "$(count "$sshv" 'select(.type=="custom" and ((.format // "") | contains("SESSION")))')"
assert_eq "ssh: session-from row" "1" "$(count "$sshv" 'select(.type=="command" and ((.text // "") | endswith("/bin/ff-session-from")))')"
assert_eq "ssh: session-others row" "1" "$(count "$sshv" 'select(.type=="command" and ((.text // "") | endswith("/bin/ff-session-others")))')"
for ty in wm terminal icons cursor; do
  assert_eq "ssh: no $ty module" "0" "$(count "$sshv" "select(.type==\"$ty\")")"
done
assert_eq "ssh: no DESKTOP header" "0" "$(count "$sshv" 'select((.format // "") | contains("DESKTOP"))')"

exit "$fail"
