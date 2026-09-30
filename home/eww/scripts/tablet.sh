#!/usr/bin/env bash
# true while the Type Cover is detached; surface-kbd-monitor writes the state file.
f="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/surface-cover"
if [ "$(cat "$f" 2>/dev/null)" = detached ]; then echo true; else echo false; fi
