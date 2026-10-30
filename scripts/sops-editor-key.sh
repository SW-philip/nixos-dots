#!/usr/bin/env bash
# sops-editor-key: one age identity that can edit every secrets file, kept only
# passphrase-encrypted, so no host's deploy key has to live in ~ (design:
# docs/superpowers/specs/2026-10-27-secrets-hardening-design.md).
#   sops-editor-key.sh init     generate the key (prompts for a passphrase) and add it
#                               as the &editor recipient on every .sops.yaml rule
#   sops-editor-key.sh rotate   re-encrypt every file this host can decrypt with the
#                               editor key added (also lifts it to the current sops format)
#   sops-editor-key.sh verify   decrypt every file with the editor key alone
#   sops-editor-key.sh sync     after editing .sops.yaml recipients, re-key every file to match
#                               (editor key only, so it works from any host)
# Run init + rotate on desktop, commit, then rotate + verify on surface for surface.yaml.
set -euo pipefail

REPO=${SOPS_EDITOR_REPO:-$(git rev-parse --show-toplevel)}
KEY=${SOPS_EDITOR_KEY:-$HOME/.config/sops/age/editor.age}
HOST_KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
# Tests swap these out: age reads passphrases only from a terminal.
DECRYPT=${SOPS_EDITOR_DECRYPT:-age -d}
ENCRYPT=${SOPS_EDITOR_ENCRYPT:-age -p -o}
LINT=${SOPS_EDITOR_LINT:-$REPO/scripts/secrets-lint.sh}
cd "$REPO"

die() { echo "sops-editor-key: $*" >&2; exit 1; }

anchor() {
  sed -nE "s/^[[:space:]]*-[[:space:]]*&$1[[:space:]]+(age1[a-z0-9]+).*/\1/p" .sops.yaml
}

has_recipient() {
  grep -qE "^[[:space:]]*(-[[:space:]]+)?recipient:[[:space:]]*$2\$" "$1"
}

init() {
  [[ -n $(anchor editor) ]] && die ".sops.yaml already has an &editor key; copy $KEY from the host that made it"
  [[ -e $KEY ]] && die "$KEY already exists"
  mkdir -p "$(dirname "$KEY")"
  local identity pub
  identity=$(age-keygen 2>/dev/null)
  pub=$(printf '%s\n' "$identity" | age-keygen -y)
  echo "Choose the editor passphrase (age asks twice). Save it in your password manager."
  (umask 077 && printf '%s\n' "$identity" | $ENCRYPT "$KEY" >/dev/null)
  unset identity
  echo "Now type it once more to prove it decrypts."
  [[ $($DECRYPT "$KEY" | age-keygen -y) == "$pub" ]] || { rm -f "$KEY"; die "round-trip failed, nothing kept"; }

  python3 - "$pub" <<'EOF'
import re, sys
pub = sys.argv[1]
lines = open(".sops.yaml").read().splitlines(keepends=True)
last_key = max(i for i, l in enumerate(lines) if re.match(r"\s*-\s*&\w+\s+age1", l))
indent = re.match(r"(\s*)", lines[last_key]).group(1)
lines.insert(last_key + 1, f"{indent}- &editor {pub}\n")
out = [re.sub(r"(-\s*age:\s*\[[^\]]*)\]", r"\1, *editor]", l) for l in lines]
open(".sops.yaml", "w").write("".join(out))
EOF
  echo "editor key: $pub"
  echo "next: $0 rotate"
}

rotate() {
  local pub host_pub f done=0
  pub=$(anchor editor)
  [[ -n $pub ]] || die "no &editor in .sops.yaml; run init first"
  host_pub=$(age-keygen -y "$HOST_KEY")
  for f in secrets/*.yaml; do
    if has_recipient "$f" "$pub"; then
      echo "skip  $f (editor already a recipient)"
    elif ! has_recipient "$f" "$host_pub"; then
      echo "skip  $f (this host can't decrypt it)"
    else
      sops rotate -i --add-age "$pub" "$f"
      sops decrypt "$f" >/dev/null || die "$f no longer decrypts with this host's key"
      echo "done  $f"
      done=1
    fi
  done
  ((done)) || { echo "nothing to rotate here"; return; }
  $LINT
  echo "next: $0 verify, then commit"
}

# Prompts once; the identity stays in this shell's memory, handed to sops only through its env.
editor_identity() {
  local pub
  pub=$(anchor editor)
  [[ -n $pub ]] || die "no &editor in .sops.yaml"
  [[ -e $KEY ]] || die "$KEY missing; copy it from desktop (it's passphrase-encrypted)"
  identity=$($DECRYPT "$KEY")
  [[ $(printf '%s\n' "$identity" | age-keygen -y) == "$pub" ]] || die "$KEY is not the &editor key"
}

# An empty HOME keeps sops from finding keys.txt or ~/.ssh/id_ed25519: only the editor key counts.
editor_sops() {
  env -i PATH="$PATH" HOME="$sandbox" SOPS_AGE_KEY="$identity" sops "$@"
}

verify() {
  local pub identity f fail=0 sandbox
  pub=$(anchor editor)
  editor_identity
  sandbox=$(mktemp -d)
  trap 'rm -rf "$sandbox"' RETURN
  for f in secrets/*.yaml; do
    if ! has_recipient "$f" "$pub"; then
      echo "todo  $f (not rotated yet)"; fail=1
    elif editor_sops decrypt "$f" >/dev/null 2>&1; then
      echo "ok    $f"
    else
      echo "FAIL  $f"; fail=1
    fi
  done
  unset identity
  ((fail)) && die "the editor key can't open everything yet; keep the host keys in ~"
  echo "editor key opens every file"
}

# Make every file's recipients match .sops.yaml. A file whose list changed also gets a
# fresh data key, so a dropped recipient can't open anything written from now on.
sync() {
  local identity f before changed=0 sandbox
  editor_identity
  sandbox=$(mktemp -d)
  trap 'rm -rf "$sandbox"' RETURN
  for f in secrets/*.yaml; do
    before=$(grep -E 'recipient:' "$f" | sort)
    editor_sops updatekeys -y "$f" >/dev/null 2>&1 || die "updatekeys failed on $f"
    if [[ $(grep -E 'recipient:' "$f" | sort) == "$before" ]]; then
      echo "same  $f"
    else
      editor_sops rotate -i "$f" || die "rotate failed on $f"
      echo "done  $f"
      changed=1
    fi
  done
  unset identity
  ((changed)) || { echo "every file already matches .sops.yaml"; return; }
  $LINT
  echo "next: commit, then deploy the hosts whose recipients changed"
}

case ${1:-} in
  init) init ;;
  rotate) rotate ;;
  verify) verify ;;
  sync) sync ;;
  *) echo "usage: ${0##*/} init|rotate|verify|sync" >&2; exit 2 ;;
esac
