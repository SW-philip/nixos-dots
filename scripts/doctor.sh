#!/usr/bin/env bash
# doctor: list the scrubbed placeholders a fresh checkout still needs replaced.
#   scripts/doctor.sh [dir]     defaults to the repo this script lives in
# Exit 0 when nothing is left to replace, 1 otherwise. Read-only.
set -euo pipefail

root=${1:-${DOCTOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
cd "$root"

# pattern@@what to do. The patterns are what scripts/make-public.sh writes in place of private values.
checks=(
  'age1REPLACE-WITH-YOUR-AGE-PUBKEY@@your age public key (age-keygen), in .sops.yaml; then re-encrypt secrets/*.yaml'
  'AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY@@your SSH public keys'
  'example\.ts\.net@@your tailnet name'
  '100\.64\.0\.[1-4]([^0-9]|$)@@your hosts'"'"' Tailscale IPs (hosts/inventory.json)'
  '00:00:00:00:00:0[0-9]@@your Bluetooth device addresses'
  'ENC\[REDACTED\]@@secret values: secrets/*.yaml only keep the key names'
)

if git rev-parse --show-toplevel >/dev/null 2>&1 && [[ "$(git rev-parse --show-toplevel)" == "$PWD" ]]; then
  mapfile -t files < <(git ls-files)
else
  mapfile -t files < <(find . -type f -not -path './.git/*' | sed 's|^\./||')
fi

# README documents the placeholders; these scripts hold the patterns as text.
scan=()
for f in "${files[@]}"; do
  case "$f" in
    README.md|scripts/doctor.sh|scripts/tests/test_doctor.sh|scripts/make-public.sh|scripts/nix-repo-audit.sh|claude-archive/*|docs/*) ;;
    *) [[ -f "$f" ]] && scan+=("$f") ;;
  esac
done

left=0
for entry in "${checks[@]}"; do
  pattern=${entry%%@@*}
  todo=${entry#*@@}
  hits=()
  if (( ${#scan[@]} )); then
    mapfile -t hits < <(grep -lIE -- "$pattern" "${scan[@]}" 2>/dev/null || true)
  fi
  if (( ${#hits[@]} )); then
    left=1
    echo "TODO  $todo"
    printf '        %s\n' "${hits[@]:0:5}"
    if (( ${#hits[@]} > 5 )); then echo "        (+$(( ${#hits[@]} - 5 )) more)"; fi
  else
    echo "ok    $todo"
  fi
done

# Not a placeholder, so it never fails the run.
users=0
if (( ${#scan[@]} )); then
  users=$({ grep -IlE -- '\bprepko\b' "${scan[@]}" 2>/dev/null || true; } | wc -l)
fi
echo
echo "note  the username 'prepko' is hardcoded in $users files; change it if yours differs"
echo "note  hosts/*/hardware.nix is for the author's disks; generate your own with nixos-generate-config"

if (( left )); then
  echo
  echo "Not ready: replace the TODO items above, then run this again."
  exit 1
fi
echo
echo "Nothing left to replace."
