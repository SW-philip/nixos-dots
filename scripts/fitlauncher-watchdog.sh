#!/usr/bin/env bash
# Kills fit-launcher/aria2c if they peg the CPU while doing zero KB/s of
# actual download throughput -- the state fit-launcher's aria2 pause/resume
# reconciliation can get stuck in (RPC "cannot be paused/unpaused now" loop).
# Invoked every 20s by the fitlauncher-watchdog systemd user timer
# (home/fitlauncher-watchdog.nix).
set -uo pipefail

CPU_THRESHOLD=50          # %CPU (either process) above this counts as "busy"
POLL_INTERVAL=20          # seconds, must match the .timer's OnUnitActiveSec
CHECKS_TO_WARN=3          # ~60s of stuck state before a heads-up notification
CHECKS_TO_KILL=9          # ~180s of stuck state before killing

STATE_DIR="$HOME/.cache/fitlauncher-watchdog"
STATE_FILE="$STATE_DIR/count"
WARNED_FILE="$STATE_DIR/warned"
mkdir -p "$STATE_DIR"

notify() {
    notify-send -a "fit-launcher watchdog" -u "$1" "$2" "$3" 2>/dev/null || true
}

# Instantaneous-ish %CPU for a pid, sampled over ~1s (ps reports a lifetime
# average, which stays "hot" for hours after a spike ends -- useless here).
cpu_pct() {
    local pid="$1"
    top -bn2 -d 1 -p "$pid" 2>/dev/null | tail -1 | awk '{print $9}' | cut -d. -f1
}

ARIA2_PID=$(pgrep -f 'aria2c.*com\.fitlauncher\.carrotrub' | head -1)
FITLAUNCHER_PID=$(pgrep -x fit-launcher | head -1)

if [[ -z "$ARIA2_PID" && -z "$FITLAUNCHER_PID" ]]; then
    rm -f "$STATE_FILE" "$WARNED_FILE"
    exit 0
fi

# Ask aria2's own RPC for aggregate download speed -- the ground truth,
# independent of whatever state fit-launcher's manager.json thinks it's in.
SPEED=0
if [[ -n "$ARIA2_PID" ]]; then
    SPEED=$(curl -s -m 3 -X POST http://127.0.0.1:6899/jsonrpc \
        -d '{"jsonrpc":"2.0","id":"watchdog","method":"aria2.getGlobalStat"}' \
        2>/dev/null | jq -r '.result.downloadSpeed // "0"' 2>/dev/null)
    [[ "$SPEED" =~ ^[0-9]+$ ]] || SPEED=0
fi

CPU=0
for pid in "$ARIA2_PID" "$FITLAUNCHER_PID"; do
    [[ -z "$pid" ]] && continue
    c=$(cpu_pct "$pid")
    [[ "$c" =~ ^[0-9]+$ ]] || c=0
    (( c > CPU )) && CPU=$c
done

if (( CPU >= CPU_THRESHOLD && SPEED == 0 )); then
    COUNT=$(( $(cat "$STATE_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$COUNT" > "$STATE_FILE"

    if (( COUNT >= CHECKS_TO_WARN )) && [[ ! -f "$WARNED_FILE" ]]; then
        touch "$WARNED_FILE"
        SECS_LEFT=$(( (CHECKS_TO_KILL - COUNT) * POLL_INTERVAL ))
        notify critical "fit-launcher looks stuck" \
            "${CPU}% CPU with 0 KB/s for ~$((COUNT * POLL_INTERVAL))s. Will kill it in ${SECS_LEFT}s unless it recovers."
    fi

    if (( COUNT >= CHECKS_TO_KILL )); then
        [[ -n "$ARIA2_PID" ]] && kill -TERM "$ARIA2_PID" 2>/dev/null
        [[ -n "$FITLAUNCHER_PID" ]] && kill -TERM "$FITLAUNCHER_PID" 2>/dev/null
        sleep 2
        [[ -n "$ARIA2_PID" ]] && kill -0 "$ARIA2_PID" 2>/dev/null && kill -KILL "$ARIA2_PID" 2>/dev/null
        [[ -n "$FITLAUNCHER_PID" ]] && kill -0 "$FITLAUNCHER_PID" 2>/dev/null && kill -KILL "$FITLAUNCHER_PID" 2>/dev/null
        notify normal "fit-launcher killed" \
            "Stopped fit-launcher/aria2c after $((COUNT * POLL_INTERVAL))s stuck at ${CPU}% CPU / 0 KB/s."
        rm -f "$STATE_FILE" "$WARNED_FILE"
    fi
else
    rm -f "$STATE_FILE" "$WARNED_FILE"
fi
