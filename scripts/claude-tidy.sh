#!/usr/bin/env bash
# Prune old Claude Code state and redact leaked tokens. Run daily by the
# claude-tidy user timer (home/claude-tidy.nix); `claude-tidy --dry-run` to preview.
# Memory (a symlink into .claude-shared) and settings are never touched.
set -euo pipefail
RETAIN_DAYS="${CLAUDE_TIDY_DAYS:-14}"
C="$HOME/.claude"
dry=0; [[ "${1:-}" == --dry-run ]] && dry=1
say() { echo "claude-tidy: $*"; }

# Files touched in the last 10 min may be a live session mid-write: skip them.
idle() { find "$@" -mmin +10; }

# 1. Redact tokens that landed in transcripts/history (never print the match).
pat='github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|sk-ant-[A-Za-z0-9_-]{20,}'
mapfile -t leaky < <(grep -rlE "$pat" --include='*.jsonl' "$C/projects" "$C/history.jsonl" 2>/dev/null || true)
for f in "${leaky[@]}"; do
  [[ -n "$f" && -n "$(idle "$f")" ]] || continue
  if ((dry)); then say "would redact $f"; else sed -i -E "s/$pat/[REDACTED]/g" "$f"; say "redacted $f"; fi
done

# 2. Age out transcripts and per-session scratch.
for spec in "$C/projects:*.jsonl" "$C/file-history:*" "$C/shell-snapshots:*" "$C/paste-cache:*" "$C/telemetry:*"; do
  dir="${spec%%:*}"; glob="${spec#*:}"
  [[ -d "$dir" ]] || continue
  n=$(find "$dir" -type f -name "$glob" -mtime +"$RETAIN_DAYS" | wc -l)
  say "$dir: $n files older than ${RETAIN_DAYS}d"
  ((dry)) || find "$dir" -type f -name "$glob" -mtime +"$RETAIN_DAYS" -delete
  ((dry)) || find "$dir" -mindepth 2 -type d -empty -delete
done
