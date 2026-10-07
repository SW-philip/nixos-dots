#!/usr/bin/env bash
# Fixture tests for scripts/on.sh with a fake waypipe.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/on.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/shim"

fail=0
assert_eq() {
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; else echo "PASS: $1"; fi
}

# one arg per line so quoting is visible
cat > "$T/shim/waypipe" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_OUT"
SHIM
chmod +x "$T/shim/waypipe"
export PATH="$T/shim:$PATH" FAKE_OUT="$T/args"

# basic invocation
bash "$SCRIPT" desktop firefox
assert_eq "waypipe argv" \
  $'--no-gpu\n--title-prefix\n[desktop] \nssh\n-o\nBatchMode=yes\ndesktop\n--\nbash\n-lc\nexec\\ firefox\\ ' \
  "$(cat "$T/args")"

# arguments with spaces survive the remote shell
bash "$SCRIPT" surface firefox --new-window 'a b'
assert_eq "quoted remote command" \
  'exec\ firefox\ --new-window\ a\\\ b\ ' \
  "$(sed -n '$p' "$T/args")"

# no args -> usage, exit 2
bash "$SCRIPT" >"$T/o" 2>&1; assert_eq "no args exit" 2 $?
grep -q '^usage: on <host>' "$T/o"; assert_eq "usage text" 0 $?

# host without a command -> usage, exit 2
bash "$SCRIPT" desktop >"$T/o" 2>&1; assert_eq "no command exit" 2 $?

# unknown host -> exit 2, names the valid hosts, waypipe never runs
rm -f "$T/args"
bash "$SCRIPT" nonesuch firefox >"$T/o" 2>&1; assert_eq "unknown host exit" 2 $?
grep -q 'desktop surface retro pi' "$T/o"; assert_eq "lists valid hosts" 0 $?
[[ ! -e "$T/args" ]]; assert_eq "waypipe not run for unknown host" 0 $?

# SEMANTIC TEST: verify spaces and literal $ survive through the quoting round-trip.
# Create a stub showargs that prints args one per line
cat > "$T/shim/showargs" <<'SHOWARGS'
#!/usr/bin/env bash
printf '%s\n' "$@"
SHOWARGS
chmod +x "$T/shim/showargs"

# Run on desktop showargs 'a b' 'x$y'; waypipe shim will record the bash -lc script.
# Extract the script and run it to verify args survive.
bash "$SCRIPT" desktop showargs 'a b' 'x$y' 2>/dev/null
script_to_run=$(sed -n '$p' "$T/args")

# Use zsh if available (what runs remotely), else bash, to interpret the script.
# ssh space-joins args, so we simulate that by joining the words after -- with spaces.
# The script_to_run is: exec\ showargs\ a\\ b\ x\$y\
# When evaluated by the shell, it becomes: exec showargs 'a b' 'x$y'
shell_to_use=$(command -v zsh || echo bash)
# Use eval to re-parse the escaped command string, simulating how the remote shell would handle it
# when ssh reconstructs the command line from the waypipe arguments
out=$(PATH="$T/shim:$PATH" "$shell_to_use" -c "eval $script_to_run" 2>&1)
assert_eq "semantic: args survive" $'a b\nx$y' "$out"

exit "$fail"
