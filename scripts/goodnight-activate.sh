#!/usr/bin/env bash
# goodnight-activate <closure>: switch this host to a system closure, detached from the caller.
# The one privileged step of the nightly deploy (sudo -n, see roles/goodnight-activate.nix).
# Only this host's own `nixos-system-<hostname>-*` closure in /nix/store is accepted, so a wrong
# host's closure can never land here (that once dropped desktop to emergency mode).
# It runs as a transient unit because activation restarts sshd/network/session units, which would
# kill the ssh session that started it half-way; the caller polls `goodnight-switch` instead.
# Caveat: prepko is already a trusted nix user, so this is no new capability, just no password.
set -euo pipefail

die() { echo "goodnight-activate: $*" >&2; exit 2; }

p=${1:-}
[[ $p == /nix/store/* ]] || die "need a /nix/store path"
p=$(realpath -e -- "$p") || die "no such path: $1"
[[ $(dirname "$p") == /nix/store ]] || die "not a store root: $p"
host=$(hostname)
[[ $(basename "$p") =~ ^[a-z0-9]{32}-nixos-system-${host}- ]] || die "not a system closure for $host: $p"
[[ -x $p/bin/switch-to-configuration ]] || die "no switch-to-configuration in $p"

unit=goodnight-switch
systemctl stop "$unit" 2>/dev/null || true
systemctl reset-failed "$unit" 2>/dev/null || true
exec systemd-run --quiet --unit="$unit" --property=RemainAfterExit=yes \
  --setenv=HOME=/root --setenv=PATH=/run/current-system/sw/bin \
  --setenv=LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive \
  sh -c "nix-env -p /nix/var/nix/profiles/system --set '$p' && '$p/bin/switch-to-configuration' switch"
