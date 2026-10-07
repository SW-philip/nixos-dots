#!/usr/bin/env bash
# tree-sync: keep ~/nixos and its nested ~/nixos/.claude-shared repo in step across
# hosts through the pi git hub. It never merges: it autosaves, fast-forwards, and
# stops loudly on divergence.
#   save              autosave unsaved work to refs/autosave/<host>, push wip
#   pull              fast-forward wip (clean tree only), list other hosts' unsaved work
#   restore <host>    stage <host>'s autosaved work into this tree
#   assets            pull gitignored files (wallpapers...) from $TREE_SYNC_ASSETS_FROM
#   auto              pull, save, assets (what the timer runs)
#   status            local view only, no network
set -euo pipefail

ROOT=${TREE_SYNC_ROOT:-$HOME/nixos}
HOST=${TREE_SYNC_HOST:-$(uname -n)}
REMOTE=${TREE_SYNC_REMOTE:-pi}
CS_REMOTE=${TREE_SYNC_CS_REMOTE:-origin}
ASSETS_FROM=${TREE_SYNC_ASSETS_FROM:-}
NET_TIMEOUT=${TREE_SYNC_TIMEOUT:-20}
LOCK=${TREE_SYNC_LOCK:-${XDG_RUNTIME_DIR:-/tmp}/tree-sync.lock}
BRANCH=wip
CS=$ROOT/.claude-shared
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=5"
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-"ssh $SSH_OPTS"}
export GIT_OPTIONAL_LOCKS=0

say()  { echo "tree-sync: $*"; }
warn() { echo "tree-sync: WARNING: $*" >&2; }
net()  { local repo=$1; shift; timeout "$NET_TIMEOUT" git -C "$repo" "$@"; }
is_clean() { [[ -z "$(git -C "$1" status --porcelain)" ]]; }

hub_up() {
  net "$ROOT" ls-remote "$REMOTE" >/dev/null 2>&1 && return 0
  say "$REMOTE unreachable, skipping"
  return 1
}

push_branch() {
  [[ "$(git -C "$ROOT" branch --show-current)" == "$BRANCH" ]] || return 0
  net "$ROOT" push -q "$REMOTE" "$BRANCH" 2>/dev/null \
    || warn "$BRANCH was not pushed: $REMOTE has commits this tree lacks (run: tree-sync pull)"
}

save_tree() {
  local idx tree sha f br
  if is_clean "$ROOT"; then
    # nothing unsaved: drop our stale autosave if the hub still has one
    if [[ -n "$(net "$ROOT" ls-remote "$REMOTE" "refs/autosave/$HOST")" ]]; then
      net "$ROOT" push -q "$REMOTE" ":refs/autosave/$HOST"
    fi
  else
    # temporary index: the real index, worktree and branch stay exactly as they are
    idx=$(git -C "$ROOT" rev-parse --absolute-git-dir)/tree-sync-index
    rm -f "$idx"
    GIT_INDEX_FILE=$idx git -C "$ROOT" read-tree HEAD
    GIT_INDEX_FILE=$idx git -C "$ROOT" add -A
    # untracked files only: big or secret-looking ones must not reach the hub
    while IFS= read -r -d '' f; do
      if [[ "$f" == *keys.txt || "$f" == *.age || "$f" == *.img || "$f" == *.iso || "$f" == *.qcow2 \
            || "$f" == *.pem || "$f" == *.key || "$(basename "$f")" == .env \
            || "$(stat -c %s "$ROOT/$f" 2>/dev/null || echo 0)" -gt 5242880 ]]; then
        GIT_INDEX_FILE=$idx git -C "$ROOT" rm -q --cached --ignore-unmatch -- "$f"
        warn "autosave skipped $f (large or sensitive)"
      fi
    done < <(git -C "$ROOT" ls-files -z --others --exclude-standard)
    tree=$(GIT_INDEX_FILE=$idx git -C "$ROOT" write-tree)
    rm -f "$idx"
    br=$(git -C "$ROOT" branch --show-current)
    sha=$(git -C "$ROOT" -c user.name="tree-sync ($HOST)" -c user.email="tree-sync@$HOST" \
      commit-tree "$tree" -p HEAD -m "autosave $HOST on ${br:-detached} $(date -u +%FT%TZ)")
    net "$ROOT" push -q "$REMOTE" "+$sha:refs/autosave/$HOST"
    say "autosaved unsaved work to $REMOTE (refs/autosave/$HOST)"
  fi
  push_branch
}

fetch_hub() {
  net "$ROOT" fetch -q --prune "$REMOTE" \
    "+refs/heads/*:refs/remotes/$REMOTE/*" "+refs/autosave/*:refs/pi-autosave/*"
}

pull_tree() {
  local theirs="refs/remotes/$REMOTE/$BRANCH" ref h rc=0
  fetch_hub
  if [[ "$(git -C "$ROOT" branch --show-current)" != "$BRANCH" ]]; then
    say "not on $BRANCH, leaving the branch alone"
  elif git -C "$ROOT" rev-parse -q --verify "$theirs" >/dev/null; then
    if git -C "$ROOT" merge-base --is-ancestor "$theirs" HEAD; then
      :   # up to date, or ahead (save pushes)
    elif git -C "$ROOT" merge-base --is-ancestor HEAD "$theirs"; then
      if is_clean "$ROOT"; then
        git -C "$ROOT" merge -q --ff-only "$theirs"
        say "fast-forwarded $BRANCH to $(git -C "$ROOT" rev-parse --short HEAD)"
      else
        warn "$BRANCH is behind $REMOTE but this tree has uncommitted work: commit or stash, then run tree-sync pull"
      fi
    else
      warn "DIVERGED: $BRANCH here and on $REMOTE both have new commits; nothing was changed. Inspect: git log --oneline --left-right HEAD...$theirs"
      rc=2
    fi
  fi
  while read -r ref; do
    h=${ref#refs/pi-autosave/}
    [[ "$h" == "$HOST" ]] && continue
    say "$h has unsaved work from $(git -C "$ROOT" log -1 --format=%cr "$ref"): tree-sync restore $h"
  done < <(git -C "$ROOT" for-each-ref --format='%(refname)' refs/pi-autosave/)
  return "$rc"
}

restore_tree() {
  local h=$1 ref="refs/pi-autosave/$1" base msg br
  git -C "$ROOT" rev-parse -q --verify "$ref" >/dev/null \
    || { warn "no autosave from $h (run: tree-sync pull)"; return 1; }
  is_clean "$ROOT" || { warn "tree has uncommitted work: commit or stash first"; return 1; }
  base=$(git -C "$ROOT" rev-parse "$ref^")
  git -C "$ROOT" merge-base --is-ancestor HEAD "$base" \
    || { warn "this tree has commits $h's autosave lacks; compare by hand: git diff $base $ref"; return 1; }
  if ! git -C "$ROOT" merge-base --is-ancestor "$base" "refs/remotes/$REMOTE/$BRANCH"; then
    msg=$(git -C "$ROOT" log -1 --format=%s "$ref")
    br=${msg#autosave "$h" on }; br=${br%% *}
    warn "$h's autosave was made on a line that is not $BRANCH (branch: ${br:-unknown}); not restoring"
    return 1
  fi
  git -C "$ROOT" merge -q --ff-only "$base"
  git -C "$ROOT" read-tree -u --reset "$ref"   # HEAD unchanged, so the work shows as staged changes
  say "restored $h's unsaved work, staged: review with git diff --cached"
}

cmd_status() {
  local ahead behind ref
  say "tree: $ROOT on $(git -C "$ROOT" branch --show-current), $(git -C "$ROOT" status --porcelain | wc -l) changed path(s)"
  if git -C "$ROOT" rev-parse -q --verify "refs/remotes/$REMOTE/$BRANCH" >/dev/null; then
    read -r ahead behind < <(git -C "$ROOT" rev-list --left-right --count "HEAD...refs/remotes/$REMOTE/$BRANCH")
    say "vs $REMOTE/$BRANCH as of the last fetch: $ahead ahead, $behind behind"
    if [[ "$ahead" -gt 0 && "$behind" -gt 0 ]]; then
      say "DIVERGED: $BRANCH here and on $REMOTE both have new commits"
    fi
  fi
  while read -r ref; do
    say "autosave from ${ref#refs/pi-autosave/}: $(git -C "$ROOT" log -1 --format=%cr "$ref")"
  done < <(git -C "$ROOT" for-each-ref --format='%(refname)' refs/pi-autosave/)
}

# .claude-shared is its own repo: edits are auto-committed on main and replayed over
# whatever the hub has. A conflict aborts the replay and leaves everything as it was.
sync_cs() {
  [[ -d "$CS/.git" ]] || return 0
  if ! is_clean "$CS"; then
    git -C "$CS" add -A
    git -C "$CS" -c user.name="tree-sync ($HOST)" -c user.email="tree-sync@$HOST" \
      commit -q -m "autosave $HOST $(date -u +%FT%TZ)"
  fi
  net "$CS" fetch -q "$CS_REMOTE" main 2>/dev/null || return 0
  if ! git -C "$CS" merge-base --is-ancestor "$CS_REMOTE/main" HEAD; then
    if ! git -C "$CS" rebase -q "$CS_REMOTE/main" >/dev/null 2>&1; then
      git -C "$CS" rebase --abort
      warn "claude-shared: same file edited on two hosts, nothing replayed; resolve in $CS (git pull --rebase)"
      return 2
    fi
  fi
  net "$CS" push -q "$CS_REMOTE" main 2>/dev/null || warn "claude-shared: push to $CS_REMOTE failed"
}

cmd_assets() {
  local list
  [[ -n "$ASSETS_FROM" ]] || return 0
  list=$(mktemp)
  # gitignored files on the source host, but only wallpapers and the claude archive are assets
  # shellcheck disable=SC2086
  if ! timeout "$NET_TIMEOUT" ssh $SSH_OPTS "$ASSETS_FROM" \
      'cd nixos && git ls-files --others --ignored --exclude-standard' \
      | { grep -E '^themes/.*/wallpaper-[^/]*\.png$|^claude-archive/' || true; } > "$list"; then
    say "$ASSETS_FROM unreachable, skipping assets"; rm -f "$list"; return 0
  fi
  timeout 300 rsync -a --update --files-from="$list" -e "ssh $SSH_OPTS" "$ASSETS_FROM:nixos/" "$ROOT/" \
    || warn "assets: rsync from $ASSETS_FROM failed"
  rm -f "$list"
}

# One notification per divergence: the stamp holds the two tips it was raised for, and
# goes away when the tree stops being diverged, so a new divergence notifies again.
notify_diverged() {
  local rc=$1 stamp=${XDG_STATE_HOME:-$HOME/.local/state}/tree-sync-diverged tips
  if [[ "$rc" -ne 2 ]]; then rm -f "$stamp"; return 0; fi
  tips=$(git -C "$ROOT" rev-parse HEAD "$REMOTE/$BRANCH")
  [[ "$(cat "$stamp" 2>/dev/null)" == "$tips" ]] && return 0
  mkdir -p "$(dirname "$stamp")"
  printf '%s\n' "$tips" > "$stamp"
  notify-send -u critical "tree-sync" "wip DIVERGED from the pi: run tree-sync status" || true
}

main() {
  local cmd=${1:-} rc=0
  [[ $# -gt 0 ]] && shift
  [[ "$cmd" == status ]] && { cmd_status; return 0; }
  exec 9>"$LOCK"
  flock -n 9 || { say "already running"; return 0; }
  case "$cmd" in
    save)    hub_up || return 0; save_tree; sync_cs ;;
    pull)    hub_up || return 0; pull_tree || rc=$?; sync_cs || rc=$?; return "$rc" ;;
    restore) if hub_up; then fetch_hub; fi; restore_tree "${1:?usage: tree-sync restore <host>}" ;;
    assets)  cmd_assets ;;
    auto)    hub_up || return 0
             pull_tree || rc=$?
             notify_diverged "$rc"
             save_tree || warn "autosave failed (hub dropped mid-run?)"
             sync_cs || true
             cmd_assets ;;
    *) echo "usage: tree-sync {save|pull|restore <host>|assets|auto|status}" >&2; return 64 ;;
  esac
}
main "$@"
