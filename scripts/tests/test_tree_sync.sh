#!/usr/bin/env bash
# Fixture tests for scripts/tree-sync.sh: a throwaway bare "hub" plus two clones (hostA, hostB).
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tree-sync.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export TREE_SYNC_TIMEOUT=10 TREE_SYNC_LOCK="$T/lock"
HUB="$T/pi.git"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_ok()   { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "PASS: $d"; else echo "FAIL: $d"; fail=1; fi; }
assert_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $d"; fail=1; else echo "PASS: $d"; fi; }

ts() { local h=$1 r=$2; shift 2; TREE_SYNC_HOST=$h TREE_SYNC_ROOT=$r "$SCRIPT" "$@"; }

fresh() {
  rm -rf "${T:?}"/* ; mkdir -p "$HOME"
  git config --global user.name test; git config --global user.email t@t
  git init -q --bare -b main "$HUB"
  git clone -q "$HUB" "$T/seed" 2>/dev/null
  git -C "$T/seed" checkout -q -b wip
  echo base > "$T/seed/flake.nix"; echo '.claude-shared/' > "$T/seed/.gitignore"
  git -C "$T/seed" add -A; git -C "$T/seed" commit -qm base
  git -C "$T/seed" push -q origin wip wip:main
  for h in A B; do
    git clone -q "$HUB" "$T/$h" 2>/dev/null
    git -C "$T/$h" remote rename origin pi 2>/dev/null
    git -C "$T/$h" checkout -q wip
  done
}

echo "== save: dirty tree =="
fresh
echo changed > "$T/A/flake.nix"; echo new > "$T/A/new.txt"
before=$(git -C "$T/A" rev-parse HEAD)
ts hostA "$T/A" save >/dev/null
assert_ok "autosave on hub holds the untracked file" git -C "$HUB" cat-file -e refs/autosave/hostA:new.txt
assert_eq "autosave holds the edited content" "changed" "$(git -C "$HUB" show refs/autosave/hostA:flake.nix)"
assert_eq "HEAD untouched" "$before" "$(git -C "$T/A" rev-parse HEAD)"
assert_eq "worktree still dirty (2 paths)" "2" "$(git -C "$T/A" status --porcelain | wc -l)"
assert_eq "hub wip untouched" "$before" "$(git -C "$HUB" rev-parse wip)"

echo "== save: large and sensitive untracked files =="
fresh
head -c 6000000 /dev/zero > "$T/A/big.bin"; echo k > "$T/A/keys.txt"; echo ok > "$T/A/ok.txt"
ts hostA "$T/A" save >/dev/null 2>&1
assert_ok "small untracked file is autosaved" git -C "$HUB" cat-file -e refs/autosave/hostA:ok.txt
assert_fail "big file is not autosaved" git -C "$HUB" cat-file -e refs/autosave/hostA:big.bin
assert_fail "keys.txt is not autosaved" git -C "$HUB" cat-file -e refs/autosave/hostA:keys.txt
assert_eq "worktree keeps all three" "3" "$(ls "$T/A/big.bin" "$T/A/keys.txt" "$T/A/ok.txt" | wc -l)"

echo "== save: clean tree after commit =="
git -C "$T/A" add -A; git -C "$T/A" commit -qm work
ts hostA "$T/A" save >/dev/null
assert_fail "stale autosave removed" git -C "$HUB" rev-parse -q --verify refs/autosave/hostA
assert_eq "wip pushed" "$(git -C "$T/A" rev-parse HEAD)" "$(git -C "$HUB" rev-parse wip)"

echo "== pull: fast-forward =="
fresh
echo a > "$T/A/a.txt"; git -C "$T/A" add -A; git -C "$T/A" commit -qm a
ts hostA "$T/A" save >/dev/null
rc=0; out=$(ts hostB "$T/B" pull 2>&1) || rc=$?
assert_eq "clean tree fast-forwards" "$(git -C "$T/A" rev-parse HEAD)" "$(git -C "$T/B" rev-parse HEAD)"
assert_eq "pull exits 0" "0" "$rc"

echo "== pull: diverged =="
fresh
echo a > "$T/A/a.txt"; git -C "$T/A" add -A; git -C "$T/A" commit -qm a
echo b > "$T/B/b.txt"; git -C "$T/B" add -A; git -C "$T/B" commit -qm b
ts hostA "$T/A" save >/dev/null
bhead=$(git -C "$T/B" rev-parse HEAD)
rc=0; out=$(ts hostB "$T/B" pull 2>&1) || rc=$?
assert_eq "diverged exits 2" "2" "$rc"
assert_eq "diverged leaves HEAD alone" "$bhead" "$(git -C "$T/B" rev-parse HEAD)"
assert_eq "diverged says so" "1" "$(grep -c DIVERGED <<<"$out")"

echo "== auto: diverged is loud =="
fresh
echo a > "$T/A/a.txt"; git -C "$T/A" add -A; git -C "$T/A" commit -qm a
echo b > "$T/B/b.txt"; git -C "$T/B" add -A; git -C "$T/B" commit -qm b
ts hostA "$T/A" save >/dev/null
mkdir -p "$T/shim"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/notify.log"\n' "$T" > "$T/shim/notify-send"
chmod +x "$T/shim/notify-send"
rc=0; PATH="$T/shim:$PATH" ts hostB "$T/B" auto >/dev/null 2>&1 || rc=$?
assert_eq "auto still exits 0" "0" "$rc"
assert_eq "auto notifies once" "1" "$(wc -l < "$T/notify.log" 2>/dev/null || echo 0)"
assert_eq "notification says DIVERGED" "1" "$(grep -c DIVERGED "$T/notify.log" 2>/dev/null)"
out=$(ts hostB "$T/B" status 2>&1)
assert_eq "status prints the DIVERGED line" "1" "$(grep -c '^tree-sync: DIVERGED: wip here and on pi both have new commits' <<<"$out")"

echo "== pull: dirty and behind =="
fresh
echo a > "$T/A/a.txt"; git -C "$T/A" add -A; git -C "$T/A" commit -qm a
ts hostA "$T/A" save >/dev/null
echo wip > "$T/B/flake.nix"
bhead=$(git -C "$T/B" rev-parse HEAD)
rc=0; out=$(ts hostB "$T/B" pull 2>&1) || rc=$?
assert_eq "dirty tree not moved" "$bhead" "$(git -C "$T/B" rev-parse HEAD)"
assert_eq "dirty tree keeps its edit" "wip" "$(cat "$T/B/flake.nix")"
assert_eq "dirty tree warns" "1" "$(grep -c 'uncommitted work' <<<"$out")"

echo "== restore =="
fresh
echo unsaved > "$T/A/note.txt"
ts hostA "$T/A" save >/dev/null
out=$(ts hostB "$T/B" pull 2>&1)
assert_eq "pull announces the other host's unsaved work" "1" "$(grep -c 'hostA has unsaved work' <<<"$out")"
bhead=$(git -C "$T/B" rev-parse HEAD)
ts hostB "$T/B" restore hostA >/dev/null
assert_eq "restored file is staged" "note.txt" "$(git -C "$T/B" diff --cached --name-only)"
assert_eq "restore leaves HEAD alone" "$bhead" "$(git -C "$T/B" rev-parse HEAD)"
git -C "$T/B" reset -q --hard
echo own > "$T/B/own.txt"; git -C "$T/B" add -A; git -C "$T/B" commit -qm own
rc=0; ts hostB "$T/B" restore hostA >/dev/null 2>&1 || rc=$?
assert_eq "restore refuses when this tree has commits the autosave lacks" "1" "$rc"

echo "== restore: autosave made on another branch =="
fresh
git -C "$T/A" checkout -q -b feature
echo f > "$T/A/f.txt"; git -C "$T/A" add -A; git -C "$T/A" commit -qm f
echo unsaved > "$T/A/note.txt"
ts hostA "$T/A" save >/dev/null 2>&1
ts hostB "$T/B" pull >/dev/null 2>&1
bhead=$(git -C "$T/B" rev-parse HEAD)
rc=0; out=$(ts hostB "$T/B" restore hostA 2>&1) || rc=$?
assert_eq "restore refuses a non-wip autosave" "1" "$rc"
assert_eq "restore names the branch" "1" "$(grep -c feature <<<"$out")"
assert_eq "B HEAD unchanged" "$bhead" "$(git -C "$T/B" rev-parse HEAD)"
assert_eq "B tree unchanged" "0" "$(git -C "$T/B" status --porcelain | wc -l)"

echo "== status =="
out=$(ts hostB "$T/B" status 2>&1)
assert_eq "status names the branch" "1" "$(grep -c 'on wip' <<<"$out")"

cs_fresh() {
  fresh
  git init -q --bare -b main "$T/cs.git"
  git clone -q "$T/cs.git" "$T/csseed" 2>/dev/null
  mkdir -p "$T/csseed/memory"; echo one > "$T/csseed/memory/MEMORY.md"
  git -C "$T/csseed" add -A; git -C "$T/csseed" commit -qm init; git -C "$T/csseed" push -q origin main
  for h in A B; do git clone -q "$T/cs.git" "$T/$h/.claude-shared" 2>/dev/null; done
}

echo "== claude-shared: edit on A reaches B =="
cs_fresh
echo "fact" > "$T/A/.claude-shared/memory/new.md"
ts hostA "$T/A" save >/dev/null
ts hostB "$T/B" pull >/dev/null
assert_eq "memory file arrives on B" "fact" "$(cat "$T/B/.claude-shared/memory/new.md" 2>/dev/null)"
assert_eq "main tree is not affected by the nested repo" "0" "$(git -C "$T/A" status --porcelain | wc -l)"

echo "== claude-shared: same file edited on both =="
cs_fresh
echo A > "$T/A/.claude-shared/memory/MEMORY.md"; ts hostA "$T/A" save >/dev/null
echo B > "$T/B/.claude-shared/memory/MEMORY.md"
rc=0; out=$(ts hostB "$T/B" pull 2>&1) || rc=$?
assert_eq "conflict exits 2" "2" "$rc"
assert_eq "no rebase left in progress" "0" "$(ls -d "$T/B/.claude-shared/.git/rebase-"* 2>/dev/null | wc -l)"
assert_eq "B's edit is kept as a commit" "B" "$(cat "$T/B/.claude-shared/memory/MEMORY.md")"

echo "== unreachable hub =="
fresh
rc=0; out=$(TREE_SYNC_REMOTE=nowhere ts hostA "$T/A" auto 2>&1) || rc=$?
assert_eq "unreachable hub exits 0" "0" "$rc"
assert_eq "unreachable hub says so" "1" "$(grep -c unreachable <<<"$out")"

echo "== lock =="
fresh
( flock 9; sleep 3 ) 9>"$TREE_SYNC_LOCK" &
sleep 0.5
start=$SECONDS; out=$(ts hostA "$T/A" save 2>&1); rc=$?
assert_eq "second run exits 0" "0" "$rc"
assert_eq "second run does not wait" "1" "$(( SECONDS - start < 2 ))"
assert_eq "second run says already running" "1" "$(grep -c 'already running' <<<"$out")"
wait

echo "== assets =="
fresh
mkdir -p "$T/shim" "$T/deskhome/nixos/themes/x" "$T/deskhome/nixos/.claude-shared" "$T/deskhome/nixos/.cache/__pycache__"
git -C "$T/deskhome/nixos" init -q
echo '*.png' > "$T/deskhome/nixos/.gitignore"; echo '.claude-shared/' >> "$T/deskhome/nixos/.gitignore"; echo '__pycache__/' >> "$T/deskhome/nixos/.gitignore"
printf '%s\n' '*.pem' '*.qcow2' '.env' 'secrets/' 'claude-archive/' >> "$T/deskhome/nixos/.gitignore"
mkdir -p "$T/deskhome/nixos/secrets" "$T/deskhome/nixos/claude-archive"
echo k > "$T/deskhome/nixos/secrets/key.pem"; echo d > "$T/deskhome/nixos/big.qcow2"; echo e > "$T/deskhome/nixos/.env"
echo note > "$T/deskhome/nixos/claude-archive/note.md"
echo wall > "$T/deskhome/nixos/themes/x/wallpaper-a.png"
touch -d "1 minute ago" "$T/deskhome/nixos/themes/x/wallpaper-a.png"
echo secret > "$T/deskhome/nixos/.claude-shared/skip.png"
echo junk > "$T/deskhome/nixos/.cache/__pycache__/m.png"
cat > "$T/shim/ssh" <<'SHIM'
#!/usr/bin/env bash
# fake `ssh <opts> host cmd`: run cmd locally from the fake desktop home (real ssh starts in $HOME)
while [[ "$1" == -* ]]; do shift 2; done; shift
cd "$FAKE_DESK" && HOME=$FAKE_DESK bash -c "$*"
SHIM
cat > "$T/shim/rsync" <<'SHIM'
#!/usr/bin/env bash
# fake remote: rewrite the `desktop:nixos/` source to the local fixture, drop `-e <ssh>`
args=(); skip=0
for a in "$@"; do
  if (( skip )); then skip=0; continue; fi
  [[ "$a" == -e ]] && { skip=1; continue; }
  args+=("${a/#desktop:nixos\//$FAKE_DESK/nixos/}")
done
exec env PATH="$REAL_PATH" rsync "${args[@]}"
SHIM
chmod +x "$T/shim/ssh" "$T/shim/rsync"
REAL_PATH=$PATH FAKE_DESK="$T/deskhome" PATH="$T/shim:$PATH" TREE_SYNC_ASSETS_FROM=desktop ts hostA "$T/A" assets >/dev/null 2>&1
assert_eq "wallpaper copied" "wall" "$(cat "$T/A/themes/x/wallpaper-a.png" 2>/dev/null)"
assert_fail ".claude-shared files are not copied" test -e "$T/A/.claude-shared/skip.png"
assert_fail "pycache is not copied" test -e "$T/A/.cache/__pycache__/m.png"
assert_eq "claude-archive is copied" "note" "$(cat "$T/A/claude-archive/note.md" 2>/dev/null)"
assert_fail "pem key is not copied" test -e "$T/A/secrets/key.pem"
assert_fail "qcow2 is not copied" test -e "$T/A/big.qcow2"
assert_fail ".env is not copied" test -e "$T/A/.env"
echo newer > "$T/A/themes/x/wallpaper-a.png"
REAL_PATH=$PATH FAKE_DESK="$T/deskhome" PATH="$T/shim:$PATH" TREE_SYNC_ASSETS_FROM=desktop ts hostA "$T/A" assets >/dev/null 2>&1
assert_eq "--update keeps a newer local file" "newer" "$(cat "$T/A/themes/x/wallpaper-a.png")"

echo "== ship.sh =="
SHIP="$(dirname "$SCRIPT")/ship.sh"
lock_expr='${XDG_RUNTIME_DIR:-/tmp}/tree-sync.lock'
assert_eq "tree-sync's default lock path" "1" "$(grep -cF "LOCK=\${TREE_SYNC_LOCK:-$lock_expr}" "$SCRIPT")"
assert_eq "ship.sh takes the same lock" "1" "$(grep -cF "exec 9>\"$lock_expr\"" "$SHIP")"
assert_eq "ship.sh flocks it" "1" "$(grep -c 'flock -w 60 9' "$SHIP")"
assert_eq "both ship pushes use --force-if-includes" "2" "$(grep -E 'push .*--force-with-lease=wip' "$SHIP" | grep -c -- '--force-if-includes')"

echo "== dirty save/auto exit status =="
fresh
echo unsaved > "$T/A/dirty.txt"
rc=0; out=$(ts hostA "$T/A" save 2>&1) || rc=$?
assert_eq "dirty save exits 0" "0" "$rc"
assert_eq "dirty save stderr has no unbound variable" "0" "$(grep -c 'unbound variable' <<<"$out")"
echo unsaved2 > "$T/A/dirty2.txt"
rc=0; out=$(ts hostA "$T/A" auto 2>&1) || rc=$?
assert_eq "dirty auto exits 0" "0" "$rc"
assert_eq "dirty auto stderr has no unbound variable" "0" "$(grep -c 'unbound variable' <<<"$out")"

exit "$fail"
