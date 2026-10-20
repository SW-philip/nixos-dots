#!/usr/bin/env bash
# persist-audit.sh — list what lives on the root subvolume, i.e. what a rollback
# wipe would lose. Read-only. Run on the host being audited: sudo persist-audit.sh

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "persist-audit: needs root (sudo $0)" >&2; exit 1; }

# Recreated by NixOS on every boot/activation; never state.
skip='^/(bin|usr|lib64|boot|dev|proc|sys|run|tmp|nix|etc/static)(/|$)'
# Listed one level deeper instead of as a single total.
expand='^/(var|var/lib|var/lib/systemd|var/cache|mnt|root)$'

rootdev=$(stat -c %d /)

walk() {
  local p
  for p in "$1"/* "$1"/.[!.]*; do
    [[ -e $p || -L $p ]] || continue
    [[ $p =~ $skip ]] && continue
    # Own subvolume, other disk, or bind mount from /persist: survives the wipe.
    [[ $(stat -c %d "$p") == "$rootdev" ]] || continue
    if [[ $p =~ $expand && -d $p && ! -L $p ]]; then
      walk "$p"
    elif [[ $p == /etc ]]; then
      walk_etc
    else
      printf '%8s  %s\n' "$(du -sxh "$p" 2>/dev/null | cut -f1)" "$p"
    fi
  done
}

# /etc is mostly symlinks into /etc/static; only real files/dirs can be state.
walk_etc() {
  local p
  for p in /etc/* /etc/.[!.]*; do
    [[ -L $p ]] && continue
    [[ $(stat -c %d "$p") == "$rootdev" ]] || continue
    printf '%8s  %s\n' "$(du -sxh "$p" 2>/dev/null | cut -f1)" "$p"
  done
}

walk ""
