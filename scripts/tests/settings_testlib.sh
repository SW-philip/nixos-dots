# shellcheck shell=bash
# Shared fixtures for the settings hub tests. Sourced, never run.
# shellcheck disable=SC2034 # fail is read by the test file that sources this
SETTINGS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../settings" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim" "$T/run"

export FAKE_LOG="$T/log" PICKS="$T/picks" XDG_RUNTIME_DIR="$T/run"
export SETTINGS_PICKER="$T/shim/picker" SETTINGS_LIB="$SETTINGS_DIR/lib.sh"
export SETTINGS_SECTIONS="$SETTINGS_DIR/sections.json"
export PATH="$T/shim:$PATH"
: > "$FAKE_LOG"
: > "$PICKS"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}
assert_has() {
  if grep -qF -- "$2" <<<"$3"; then echo "PASS: $1"; else echo "FAIL: $1 — '$2' not in: $3"; fail=1; fi
}
assert_lacks() {
  if grep -qF -- "$2" <<<"$3"; then echo "FAIL: $1 — '$2' unexpectedly in: $3"; fail=1; else echo "PASS: $1"; fi
}

# shim <name> [body]: a fake command that logs "name args" to $FAKE_LOG, then runs body.
shim() {
  local name=$1 body=${2:-}
  cat > "$T/shim/$name" <<SHIM
#!/usr/bin/env bash
echo "$name \$*" >> "\$FAKE_LOG"
${body}
SHIM
  chmod +x "$T/shim/$name"
}

# picker: takes the next line of $PICKS and answers with the row containing it.
# An empty/missing line is Escape (exit 1).
cat > "$T/shim/picker" <<'SHIM'
#!/usr/bin/env bash
rows=$(cat)
want=$(head -n1 "$PICKS")
sed -i 1d "$PICKS"
[[ -n "$want" ]] || exit 1
grep -F -m1 -- "$want" <<<"$rows" || exit 1
SHIM
chmod +x "$T/shim/picker"
