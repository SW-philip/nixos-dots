#!/usr/bin/env bash
# Ratchet for "colors always come from palette.sh/palette.nix": counts hex and
# rgb[a](<digit> literals per tracked file and fails if any file has more than
# scripts/palette-lint.baseline allows (new offenders count from zero).
# A line containing `palette-lint: ok` is exempt, and so is any file listed in
# scripts/palette-lint.exempt (`path  # reason`): brand art, fallbacks for when
# no palette loads, strings that must match upstream source, graded scales.
#   palette-lint.sh            check against the baseline
#   palette-lint.sh --update   rewrite the baseline (after removing literals, or
#                              deliberately accepting new ones)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

BASELINE=scripts/palette-lint.baseline
EXEMPT=scripts/palette-lint.exempt
PATTERN='#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?\b|rgba?\([0-9]'

# Tests, fixtures and the theme generator legitimately carry literal colors.
scan() {
  git ls-files -z -- '*.nix' '*.scss' '*.css' '*.sh' '*.py' '*.kdl' '*.conf' '*.script' 'home/waybar/scripts/*' |
    grep -zvE '^(themes|docs|claude-archive)/|/tests?/|(^|/)test_|^scripts/(theme_lib/|theme-sheet|regen-tuned|make-splotch|palette-lint)|^CLAUDE.md$' |
    while IFS= read -r -d '' f; do
      [ -f "$f" ] || continue
      if grep -qE "^$f([[:space:]]|\$)" "$EXEMPT"; then continue; fi
      n=$(grep -v 'palette-lint: ok' -- "$f" | grep -cE "$PATTERN" || true)
      if [ "$n" -gt 0 ]; then printf '%s %s\n' "$n" "$f"; fi
    done | sort -k2
}

if [ "${1:-}" = "--update" ]; then
  scan > "$BASELINE"
  echo "palette-lint: baseline rewritten ($(wc -l < "$BASELINE") files, $(awk '{s+=$1} END {print s+0}' "$BASELINE") literals)"
  exit 0
fi

fail=0
# An exempt entry for a file that is gone would silently exempt a future file of that name.
while read -r f _; do
  [[ -z $f || $f == \#* ]] && continue
  [[ -e $f ]] || { echo "palette-lint: $EXEMPT lists $f, which no longer exists" >&2; fail=1; }
done < "$EXEMPT"
while read -r n f; do
  allowed=$(awk -v f="$f" '$2 == f {print $1}' "$BASELINE")
  allowed=${allowed:-0}
  if [ "$n" -gt "$allowed" ]; then
    echo "palette-lint: $f has $n color literals (baseline $allowed) — use palette.sh/palette.nix, or tag the line 'palette-lint: ok'" >&2
    grep -nE "$PATTERN" -- "$f" | grep -v 'palette-lint: ok' | head -5 | sed 's/^/    /' >&2
    fail=1
  elif [ "$n" -lt "$allowed" ]; then
    echo "palette-lint: $f improved ($allowed -> $n); run scripts/palette-lint.sh --update to lock it in"
  fi
done < <(scan)
[ "$fail" -eq 0 ] && echo "palette-lint: ok"
exit "$fail"
