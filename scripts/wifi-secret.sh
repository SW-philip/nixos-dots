#!/usr/bin/env bash
# Creates secrets/wifi.yaml holding the home Wi-Fi PSK as an env-file line for
# NetworkManager's ensureProfiles. Encrypting needs only the public recipients
# in .sops.yaml. EnvironmentFile syntax: a PSK containing quotes or backslashes
# won't survive.
set -euo pipefail
cd "$(dirname "$0")/.."

out=secrets/wifi.yaml
if [ -e "$out" ]; then
  echo "$out exists; change it with: sops $out" >&2
  exit 1
fi

read -rsp "ARRIS-3545 password: " psk
echo
tmp=$(mktemp)
enc=$(mktemp)
trap 'rm -f "$tmp" "$enc"' EXIT
jq -n --arg v "ARRIS_PSK=$psk" '{wifi_env: $v}' > "$tmp"

sops_cmd=(sops)
command -v sops >/dev/null || sops_cmd=(nix run nixpkgs#sops --)
"${sops_cmd[@]}" --encrypt --filename-override "$out" \
  --input-type json --output-type yaml "$tmp" > "$enc"
mv "$enc" "$out"
git add -f "$out"
echo "wrote $out (staged)"
