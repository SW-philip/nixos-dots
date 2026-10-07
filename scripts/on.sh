#!/usr/bin/env bash
# on <host> <cmd...> — run a Wayland app on another fleet host, shown as a native window here.
set -euo pipefail

# keep in sync with `fleet` in roles/ssh-known-hosts.nix
HOSTS="desktop surface retro pi"

usage() { echo "usage: on <host> <cmd> [args...]   (hosts: $HOSTS)" >&2; exit 2; }

[[ $# -ge 2 ]] || usage
host=$1; shift

case " $HOSTS " in
  *" $host "*) ;;
  *) echo "on: unknown host '$host' (hosts: $HOSTS)" >&2; exit 2 ;;
esac

# non-interactive ssh lacks the per-user profile on PATH; a login shell has it.
# ssh space-joins its args and the remote user's shell (zsh) re-parses that string,
# so the script is %q-quoted a second time to reach bash -lc as ONE word
cmd=$(printf '%q ' "$@")
# --no-gpu: with dmabuf on, waypipe-server probes desktop's NVIDIA Vulkan device and dies mid-handshake
# (GTK4 clients then report "Failed to open display"); windows are shm-copied anyway
exec waypipe --no-gpu --title-prefix "[$host] " ssh -o BatchMode=yes "$host" -- bash -lc "$(printf '%q' "exec $cmd")"
