#!/usr/bin/env bash
# ff-session {from|others}: values for the SESSION block ff shows inside an ssh login.
set -euo pipefail

case "${1:-}" in
  from)
    conn=${SSH_CONNECTION:-}
    if [[ -z "$conn" ]]; then echo "local session"; exit 0; fi
    ip=${conn%% *}
    name=$(tailscale status --json 2>/dev/null | jq -r --arg ip "$ip" '([.Self] + [.Peer[]?]) | map(select((.TailscaleIPs // []) | index($ip))) | (.[0].HostName // empty)' 2>/dev/null || true)
    if [[ -z "$name" ]]; then
      name=$(tailscale whois --json "$ip" 2>/dev/null | jq -r '.Node.ComputedName // .Node.Name // empty' 2>/dev/null || true)
    fi
    if [[ -n "$name" ]]; then echo "$name ($ip)"; else echo "$ip"; fi
    ;;
  others)
    # `who` lines: user tty date time (host); the caller's own tty is excluded
    me=${FF_SELF_TTY:-$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ' || true)}
    out=$(who | awk -v me="$me" '
      $2 == me { next }
      {
        h = $NF
        if (h ~ /^\(.*\)$/) { gsub(/[()]/, "", h) } else { h = "" }
        if (h == "" || h == $2 || h ~ /^:/) { what = $1 " (local)" } else { what = $1 " ← " h }
        printf "%s%s", sep, what; sep = ", "
      }')
    echo "${out:-just you}"
    ;;
  *)
    echo "usage: ff-session {from|others}" >&2
    exit 64
    ;;
esac
