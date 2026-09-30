#!/usr/bin/env bash
# extract-to-backup <archive> [dest-dir]
#
# Extracts an archive (zip/rar/7z/tar.*, whatever `ouch` supports) into
# dest-dir (default /mnt/backup/srv/Games) and deletes the source archive
# once extraction succeeds. Runs detached so you can close the terminal;
# progress and result come via notify-send plus a per-file log.
#
# Downloads live on the small SSD (/home), games live on the big HDD
# (/mnt/backup) — extracting across those two disks avoids the read+write
# contention that once made an in-place extraction crawl at ~1.8 MB/s.
set -euo pipefail

DEST_DIR="${2:-/mnt/backup/srv/Games}"
LOG_DIR="$HOME/.cache/extract-to-backup"
mkdir -p "$LOG_DIR"

notify() { notify-send -a "extract-to-backup" -u "$1" "$2" "$3" 2>/dev/null || true; }

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $(basename "$0") <archive> [dest-dir]" >&2
    exit 1
fi

ARCHIVE="$1"
if [[ ! -f "$ARCHIVE" ]]; then
    echo "no such file: $ARCHIVE" >&2
    exit 1
fi
ARCHIVE="$(realpath "$ARCHIVE")"

# Re-exec ourselves detached on first call so the caller gets their
# shell back immediately; the worker does the actual extraction.
if [[ "${EXTRACT_TO_BACKUP_WORKER:-0}" != "1" ]]; then
    LOG="$LOG_DIR/$(basename "$ARCHIVE").log"
    EXTRACT_TO_BACKUP_WORKER=1 nohup "$0" "$ARCHIVE" "$DEST_DIR" > "$LOG" 2>&1 < /dev/null &
    disown
    echo "started in background (pid $!), log: $LOG"
    exit 0
fi

BASENAME="$(basename "$ARCHIVE")"
mkdir -p "$DEST_DIR"

# Same failure mode that bit us before: don't even start if there's
# obviously not enough room, so we don't burn time before hitting ENOSPC.
ARCHIVE_SIZE=$(stat -c '%s' "$ARCHIVE")
AVAIL=$(df --output=avail -B1 "$DEST_DIR" | tail -1 | tr -d ' ')
NEEDED=$(( ARCHIVE_SIZE + ARCHIVE_SIZE / 20 ))  # archive size + 5% margin
if (( AVAIL < NEEDED )); then
    echo "[$(date -Is)] not enough space on $DEST_DIR: need ~$NEEDED bytes, have $AVAIL"
    notify critical "Extraction skipped: low disk space" \
        "$BASENAME needs ~$((NEEDED / 1024 / 1024 / 1024))GB on $DEST_DIR, only $((AVAIL / 1024 / 1024 / 1024))GB free."
    exit 1
fi

echo "[$(date -Is)] starting extraction of $BASENAME -> $DEST_DIR"
notify normal "Extraction started" "$BASENAME -> $DEST_DIR"

if (cd "$DEST_DIR" && ouch decompress "$ARCHIVE" -y); then
    echo "[$(date -Is)] extraction succeeded, deleting source archive"
    rm -f "$ARCHIVE"
    notify normal "Extraction complete" "$BASENAME extracted to $DEST_DIR and source archive deleted."
else
    echo "[$(date -Is)] extraction FAILED, keeping source archive"
    notify critical "Extraction FAILED" "$BASENAME failed to extract -- source archive kept. See $LOG_DIR"
    exit 1
fi
