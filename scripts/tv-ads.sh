#!/usr/bin/env bash
# tv-ads <pool> <url|file>... — add commercial compilations to an ad pool:
# tv-add files them under commercials/<pool>, then split-commercials.sh cuts
# every unsplit source there into commercials-split/spots-<pool>. No break in
# modules/ersatztv.nix airs those pools right now; add one back to air it.
#
#   tv-ads halloween https://youtu.be/pMy58wP8e7Y
#   tv-ads kids ~/Downloads/nick-2003.mp4
set -euo pipefail

DEST_ROOT="${DEST_ROOT:-/srv/Videos/kid_and_henry}"
export DEST_ROOT
here="$(dirname "$(readlink -f "$0")")"

pool="${1:?usage: tv-ads <pool> <url|file>...}"; shift
(($#)) || { echo "usage: tv-ads <pool> <url|file>..." >&2; exit 1; }

rc=0
NOTE_TAG="spots-$pool" "$here/tv-add.sh" "commercials/$pool" "$@" || rc=$?
# split whatever did download, even if a fetch failed
"$here/split-commercials.sh" "$DEST_ROOT/commercials-split/spots-$pool" "$DEST_ROOT/commercials/$pool"
echo "spots-$pool: $(find "$DEST_ROOT/commercials-split/spots-$pool" -name '*.mkv' | wc -l) spots"
exit "$rc"
