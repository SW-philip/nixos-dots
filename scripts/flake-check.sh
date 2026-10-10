#!/usr/bin/env bash
# Preview `nix flake update` without touching the tree: what moved, what changed upstream, what it costs.
# Report -> ~/.local/state/flake-check/<stamp>.md (+ latest.md). Never edits flake.lock or deploys.
#   flake-check            eval every host on the new lock + download/rebuild size (dry-run)
#   flake-check --build    also build old+new toplevels: closure size delta and nvd package diff
set -euo pipefail

BUILD=0
[[ "${1:-}" == --build ]] && BUILD=1
HOSTS=${FLAKE_CHECK_HOSTS:-"desktop surface retro pi"}

# Surface is 8 GB: evaluating several full configs there risks oomd reaping the shell.
if hostname | grep -qi surface; then
  echo "flake-check: SKIPPED on surface (8 GB) — run it on desktop" >&2
  exit 3
fi

root=$(git rev-parse --show-toplevel)
out=${XDG_STATE_HOME:-$HOME/.local/state}/flake-check
mkdir -p "$out"
exec 9>"$out/lock"
flock -n 9 || { echo "flake-check: already running" >&2; exit 0; }

work=$(mktemp -d)
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  git -C "$root" worktree remove --force "$work/old" 2>/dev/null || true
  git -C "$root" worktree remove --force "$work/new" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# Committed state only: uncommitted edits would muddy "what did the update change".
git -C "$root" worktree add -q --detach "$work/old" HEAD
git -C "$root" worktree add -q --detach "$work/new" HEAD
(cd "$work/new" && nix flake update 2>/dev/null)

stamp=$(date +%Y-%m-%d_%H%M)
report="$out/$stamp.md"
toplevel() { echo "$1#nixosConfigurations.$2.config.system.build.toplevel"; }

gh_api() {
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh api "$1"
  else
    curl -fsS "https://api.github.com/$1"
  fi
}

describe() { # type owner repo old new
  local json n
  if [[ $1 != github ]]; then echo "- no changelog source for a \`$1\` input"; return; fi
  if ! json=$(gh_api "repos/$2/$3/compare/$4...$5?per_page=100" 2>/dev/null); then
    echo "- compare unavailable (rate-limited, or rev no longer upstream)"; return
  fi
  n=$(jq -r .ahead_by <<<"$json")
  echo "- $n commits · <https://github.com/$2/$3/compare/${4:0:12}...${5:0:12}>"
  if (( n <= 15 )); then
    jq -r '.commits[] | "  - " + (.commit.message | split("\n")[0])' <<<"$json"
  fi
}

# Root inputs only; transitive churn is just counted.
moved=$(jq -rn --slurpfile o "$work/old/flake.lock" --slurpfile n "$work/new/flake.lock" '
  def pick(l): l.nodes as $nd | [l.nodes.root.inputs | to_entries[]
    | select(.value | type == "string") | {key: .key, value: $nd[.value].locked}] | from_entries;
  pick($o[0]) as $a | pick($n[0]) as $b
  | $b | to_entries[]
  | select(.value.narHash != $a[.key].narHash)
  | [.key, .value.type, (.value.owner // ""), (.value.repo // ""),
     ($a[.key].rev // ""), (.value.rev // ""),
     (($a[.key].lastModified // 0) | todate[:10]), ((.value.lastModified // 0) | todate[:10]),
     (((.value.lastModified // 0) - ($a[.key].lastModified // 0)) / 86400 | floor)]
  | @tsv')

total_nodes=$(jq -rn --slurpfile o "$work/old/flake.lock" --slurpfile n "$work/new/flake.lock" '
  [$n[0].nodes | to_entries[] | select(.value.locked != null)
    | select(.value.locked.narHash != ($o[0].nodes[.key].locked.narHash // ""))] | length')

{
  echo "# flake-check $stamp"
  echo

  if [[ -z "$moved" ]]; then
    echo "Nothing to update: flake.lock is current."
  else
    echo "$(wc -l <<<"$moved") root inputs would move ($total_nodes locked nodes changed in all)."
    echo
    echo "## Inputs"
    echo
    while IFS=$'\t' read -r name type owner repo old new oldd newd gap; do
      echo "### $name  \`$oldd → $newd\` (+${gap}d)"
      describe "$type" "$owner" "$repo" "$old" "$new"
      echo
    done <<<"$moved"
  fi

  echo "## Hosts on the new lock"
  echo
  echo "| host | eval | download | unpacked | local builds |"
  echo "|---|---|---|---|---|"
  fail=0
  for h in $HOSTS; do
    log=$(mktemp -p "$work")
    if nix build --dry-run "$(toplevel "$work/new" "$h")" >"$log" 2>&1; then
      sz=$(sed -nE 's/.*\(([0-9.]+ [KMG]iB) download, ([0-9.]+ [KMG]iB) unpacked.*/\1|\2/p' "$log" | head -1 || true)
      nb=$(grep -oE 'these [0-9]+ derivations' "$log" | grep -oE '[0-9]+' || true)
      echo "| $h | ok | ${sz%%|*} | ${sz##*|} | ${nb:-0} |"
    else
      fail=1
      echo "| $h | **FAIL** | | | |"
      { echo; echo "<details><summary>$h eval error</summary>"; echo; echo '```'; grep -E 'error|undefined|infinite' "$log" | head -8; echo '```'; echo "</details>"; } >>"$work/errors"
    fi
  done
  [[ -f "$work/errors" ]] && cat "$work/errors"

  if (( BUILD )) && (( ! fail )); then
    echo
    echo "## Closure size and package changes"
    echo
    echo "| host | old | new | delta |"
    echo "|---|---|---|---|"
    for h in $HOSTS; do
      o=$(nix build --no-link --print-out-paths "$(toplevel "$work/old" "$h")")
      n=$(nix build --no-link --print-out-paths "$(toplevel "$work/new" "$h")")
      os=$(nix path-info -S "$o" | awk '{print $NF}')
      ns=$(nix path-info -S "$n" | awk '{print $NF}')
      d=$((ns - os))
      echo "| $h | $(numfmt --to=iec "$os") | $(numfmt --to=iec "$ns") | $(numfmt --to=iec --format='%+.1f' "$d") |"
      nvd diff "$o" "$n" >"$out/$stamp-$h.nvd" 2>&1 || true
    done
    echo
    echo "Per-host package diffs: \`$out/$stamp-<host>.nvd\`"
  fi
} >"$report"

ln -sf "$report" "$out/latest.md"
# Keep a month of history.
find "$out" -name '20*' -mtime +30 -delete

n_moved=0; [[ -n "$moved" ]] && n_moved=$(wc -l <<<"$moved")
summary="$n_moved inputs would move"
(( fail )) && summary="$summary — a host FAILS to eval on the new lock"
echo "$summary"
echo "report: $report"
notify-send -a flake-check "flake-check" "$summary" 2>/dev/null || true
exit "$fail"
