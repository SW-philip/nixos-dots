#!/usr/bin/env bash
# Clear a hung Pegasus app on the desktop's Sunshine, then restart the retro kiosk.
# Moonlight's store path changes every rebuild, so it is discovered on the box from cage-tty1's retro-stream.
# Usage: retro-recover.sh [ssh-target]   (default prepko@retro)
set -euo pipefail

die() { echo "retro-recover: $*" >&2; exit 1; }

target="${1:-prepko@retro}"

ssh "$target" bash -s <<'REMOTE' || die "recovery failed on $target"
set -euo pipefail
die() { echo "retro-recover: $*" >&2; exit 1; }

stream=$(systemctl cat cage-tty1 | grep -o '/nix/store/[^ "]*retro-stream[^ "]*' | head -n1) || true
[ -n "${stream:-}" ] || die "no retro-stream path in cage-tty1"
bindir=$(grep -o '/nix/store/[^: "]*moonlight-qt[^: "]*/bin' "$stream" | head -n1) || true
[ -n "${bindir:-}" ] && [ -x "$bindir/moonlight" ] || die "moonlight not found via retro-stream"
echo "1/3 moonlight: $bindir/moonlight"

uid=$(id -u retro)
if sudo -n systemd-run --quiet --wait --pipe --uid=retro \
  --setenv=QT_QPA_PLATFORM=offscreen --setenv=HOME=/home/retro --setenv=XDG_RUNTIME_DIR="/run/user/$uid" \
  /run/current-system/sw/bin/timeout 25 "$bindir/moonlight" quit 100.64.0.1 </dev/null >/dev/null 2>&1; then
  echo "2/3 Sunshine asked to quit the running app"
else
  echo "2/3 moonlight quit failed or timed out (continuing)"
fi

sudo -n systemctl restart cage-tty1
for _ in $(seq 1 30); do
  [ "$(systemctl is-active cage-tty1 || true)" = active ] && { echo "3/3 cage-tty1 active"; exit 0; }
  sleep 1
done
die "cage-tty1 not active after restart"
REMOTE
