#!/usr/bin/env bash
# Fixture tests for scripts/git-hooks/pre-push: a throwaway repo with a stub check-hosts.sh.
set -uo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/git-hooks/pre-push"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1; mkdir -p "$HOME"
git config --global user.name t; git config --global user.email t@t
fail=0
assert_rc() { if [[ "$2" == "$3" ]]; then echo "PASS: $1"; else echo "FAIL: $1 — expected rc $2, got $3"; fail=1; fi; }

mkdir -p "$T/repo/scripts"; git -C "$T/repo" init -q -b main
stub() { printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$T/repo/scripts/check-hosts.sh"; chmod +x "$T/repo/scripts/check-hosts.sh"; }
run() { # <remote> <remote-ref> [env...]
  local remote=$1 ref=$2; shift 2
  (cd "$T/repo" && echo "refs/heads/main abc123 $ref def456" | env "$@" "$HOOK" "$remote" origin-url >/dev/null 2>&1)
  echo $?
}
Z=0000000000000000000000000000000000000000
stub 1
assert_rc "failing check blocks main to origin" 1 "$(run origin refs/heads/main)"
assert_rc "pi remote is never checked" 0 "$(run pi refs/heads/main)"
assert_rc "wip to origin is not checked" 0 "$(run origin refs/heads/wip)"
assert_rc "SHIP_CHECKED skips the check" 0 "$(run origin refs/heads/main SHIP_CHECKED=1)"
stub 0
assert_rc "passing check lets main through" 0 "$(run origin refs/heads/main)"
stub 3
assert_rc "skipped check (surface) blocks" 1 "$(run origin refs/heads/main)"
assert_rc "SHIP_UNCHECKED overrides a skipped check" 0 "$(run origin refs/heads/main SHIP_UNCHECKED=1)"
stub 1
rc=0; (cd "$T/repo" && echo "(delete) $Z refs/heads/main def456" | "$HOOK" origin x >/dev/null 2>&1) || rc=$?
assert_rc "deleting main is not checked" 0 "$rc"
exit "$fail"
