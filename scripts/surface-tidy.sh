#!/usr/bin/env bash
# Safe-tier disk reclaim for surface (8G RAM, tight single-fs btrfs).
# Only touches regenerable caches. Bigger levers (Steam, nix-collect-garbage -d,
# Thunderbird/Proton Bridge mail duplication) are reported but never acted on here —
# those need a human decision. See memory/surface_disk_cleanup.md for background.
set -euo pipefail

echo "=== disk before ==="
df -h / 2>/dev/null

echo
echo "=== uv cache ==="
if uv cache clean 2>/dev/null; then
  echo "cleaned"
else
  echo "skipped (locked, likely by a running Claude Code session's nixos MCP server)"
fi

echo
echo "=== browser/app caches ==="
for d in mozilla spotify ms-playwright; do
  path="$HOME/.cache/$d"
  if [ -d "$path" ]; then
    size=$(du -sh "$path" 2>/dev/null | cut -f1)
    rm -rf "${path:?}"/*
    echo "cleared $path (was $size)"
  fi
done

if [ -d "$HOME/.npm/_cacache" ]; then
  size=$(du -sh "$HOME/.npm/_cacache" 2>/dev/null | cut -f1)
  rm -rf "$HOME/.npm/_cacache"
  echo "cleared ~/.npm/_cacache (was $size)"
fi

echo
echo "=== git gc: ~/nixos ==="
git -C ~/nixos gc --quiet

echo
echo "=== disk after ==="
df -h / 2>/dev/null

echo
echo "=== needs a human decision (not touched) ==="
du -sh ~/.local/share/Steam 2>/dev/null | sed 's/^/Steam: /'
du -sh ~/.local/share/protonmail/bridge-v3/gluon 2>/dev/null | sed 's/^/Proton Bridge gluon: /'
du -sh ~/.thunderbird/*/ImapMail/127.0.0.1 2>/dev/null | sed 's/^/Thunderbird IMAP copy: /'
echo "old nix generations: run 'nix-collect-garbage -d' (removes rollback ability)"
