#!/usr/bin/env bash
# Snapshot what the installed `drmis let` deploys for every theme, into a
# throwaway HOME, as a sha256 manifest. Capture on the old build, compare on
# the new one: any difference is a behaviour change.
set -euo pipefail

mode=${1:?usage: drmis-golden.sh capture|compare [theme...]}
shift || true
store=${DRMIS_GOLDEN_DIR:-$HOME/.cache/drmis-golden}
# Fixed path: drmis writes absolute HOME paths into a few state files, so a
# random mktemp dir would make every run differ.
work=${XDG_RUNTIME_DIR:-/tmp}/drmis-golden-home

if [[ $# -gt 0 ]]; then
  themes=("$@")
else
  mapfile -t themes < <(drmis list | awk '{print $1}')
fi
mkdir -p "$store"

manifest() {
  (cd "$1" && find . \( -type f -o -type l \) -print0 | sort -z |
    while IFS= read -r -d '' f; do
      printf '%s  %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$f"
    done)
}

fail=0
for slug in "${themes[@]}"; do
  rm -rf "$work"
  mkdir -p "$work"
  HOME=$work drmis let "$slug" >/dev/null
  manifest "$work" >"$store/$slug.new"
  if [[ $mode == capture ]]; then
    mv "$store/$slug.new" "$store/$slug.manifest"
  elif diff -u "$store/$slug.manifest" "$store/$slug.new" >"$store/$slug.diff"; then
    rm -f "$store/$slug.new" "$store/$slug.diff"
  else
    echo "DIFF: $slug (see $store/$slug.diff)" >&2
    fail=1
  fi
done
rm -rf "$work"

# `let` also writes /run/tuigreet-theme and /run/greeter/palette.sh when
# writable; put them back to the real current theme.
drmis let >/dev/null

if [[ $mode == capture ]]; then
  echo "captured ${#themes[@]} themes in $store"
else
  [[ $fail -eq 0 ]] && echo "golden: ${#themes[@]} themes identical"
  exit "$fail"
fi
