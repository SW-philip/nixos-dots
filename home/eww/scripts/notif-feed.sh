#!/usr/bin/env bash
# eww deflisten: print the notification history now and after every rewrite.
dir="${XDG_RUNTIME_DIR:?}"
state="$dir/notif-history.json"
emit() {
  if [ -r "$state" ]; then tr -d '\n' < "$state"; else printf '{"count":0,"items":[],"groups":[]}'; fi
  printf '\n'
}
emit
exec "${NOTIF_INOTIFYWAIT:-inotifywait}" -m -q -e moved_to --format %f "$dir" |
  while read -r name; do [ "$name" = notif-history.json ] && emit; done
