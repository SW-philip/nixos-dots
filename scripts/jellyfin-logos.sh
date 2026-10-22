#!/usr/bin/env bash
# jellyfin-logos.sh [outdir] — save each series' clear logo from Jellyfin as
# <outdir>/<Series Name>.png, for uploading as ErsatzTV channel logos.
# Falls back to the series' thumb when it has no logo. Prompts for an API key
# (Dashboard → API Keys) so it never lands in shell history.
#
#   jellyfin-logos.sh ~/Pictures/channel-logos
set -euo pipefail

JF="${JF:-http://localhost:8096}"
out="${1:-$HOME/Pictures/channel-logos}"
mkdir -p "$out"

read -rsp "Jellyfin API key: " key; echo
auth=(-H "Authorization: MediaBrowser Token=\"$key\"")

curl -fsS "${auth[@]}" "$JF/Items?IncludeItemTypes=Series&Recursive=true&Fields=ImageTags" |
  jq -r '.Items[] | [.Id, .Name, (if .ImageTags.Logo then "Logo" elif .ImageTags.Thumb then "Thumb" else "" end)] | @tsv' |
  while IFS=$'\t' read -r id name kind; do
    if [[ -z "$kind" ]]; then
      echo "no logo: $name" >&2
      continue
    fi
    # format=png keeps the logo's transparency
    curl -fsS "${auth[@]}" -o "$out/${name//\//_}.png" "$JF/Items/$id/Images/$kind?format=png"
    printf '%-5s %s\n' "$kind" "$name"
  done
echo "→ $out"
