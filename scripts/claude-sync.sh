#!/usr/bin/env bash
# Point ~/.claude settings + project memory at this host's ~/nixos/.claude-shared
# (a gitignored nested repo synced via the pi remote). Idempotent; run on each host.
# Flags a real file where a link should be: Claude Code rewrites settings.json
# by replace, which turns the link back into a plain file on that host.
# CLAUDE_SYNC_COPY_SETTINGS=1 (surface, via home activation): settings.json is a
# real local copy refreshed from .claude-shared, since Claude Code replaces a
# settings.json symlink with a plain file. Skips quietly if it is unreadable.
set -euo pipefail
SH="$HOME/nixos/.claude-shared"
rc=0
link() {
  local src=$1 dst=$2
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then return; fi
  if [[ -e "$dst" || -L "$dst" ]]; then
    echo "DIVERGED: $dst is not the link to $src (diff it, merge into the shared copy, rm it, rerun)" >&2; rc=1; return
  fi
  mkdir -p "$(dirname "$dst")"; ln -s "$src" "$dst"; echo "linked $dst"
}
copy() {
  local src=$1 dst=$2
  if ! [[ -r "$src" ]]; then echo "claude-sync: $src unreadable, keeping existing $dst" >&2; return; fi
  [[ -L "$dst" ]] && rm "$dst"   # cp through the link would overwrite the shared file
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then return; fi
  mkdir -p "$(dirname "$dst")"
  [[ -f "$dst" ]] && cp "$dst" "$dst.bak"
  cp "$src" "$dst"; chmod 644 "$dst"; echo "copied $src -> $dst"
}
if [[ -n "${CLAUDE_SYNC_COPY_SETTINGS:-}" ]]; then
  copy "$SH/settings.json" "$HOME/.claude/settings.json"
else
  link "$SH/settings.json" "$HOME/.claude/settings.json"
fi
link "$SH/memory" "$HOME/.claude/projects/-home-prepko-nixos/memory"
exit $rc
