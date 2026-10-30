#!/usr/bin/env bash
# secrets-lint: every sops secret a host declares must be decryptable by that host,
# checked statically (no keys, no decryption) so a bad recipient list fails check-hosts
# instead of activation. A host that can't decrypt passwords.yaml comes up with a locked
# account (mutableUsers = false), so this is the guard before any re-encryption.
# For each declared secret: its file is git-tracked (the flake never sees untracked
# files, and secrets/ is gitignored, so new files need `git add -f`), the host's
# .sops.yaml anchor is one of the file's recipients, and the key holds a real value.
# Every file's recipients must also all be .sops.yaml anchors.
#   secrets-lint.sh [repo]
#   SECRETS_LINT_DECLS=<file>   read "host<TAB>file<TAB>key" lines instead of evaluating
set -euo pipefail
cd "${1:-$(git rev-parse --show-toplevel)}"

HOSTS=(desktop surface retro pi)

declarations() {
  if [[ -n ${SECRETS_LINT_DECLS:-} ]]; then
    cat "$SECRETS_LINT_DECLS"
    return
  fi
  local h
  for h in "${HOSTS[@]}"; do
    # sopsFile stringifies to the flake's store copy; strip that back to a repo path.
    # shellcheck disable=SC2016  # ${…} is Nix interpolation
    nix eval --raw ".#nixosConfigurations.$h.config.sops.secrets" --apply '
      m: builtins.concatStringsSep "" (map (s: "${toString s.sopsFile}\t${s.key}\n")
        (builtins.attrValues m))' |
      sed -E "s#^/nix/store/[^/]+/#$h\t#"
  done
}

pubkey() {
  sed -nE "s/^[[:space:]]*-[[:space:]]*&$1[[:space:]]+(age1[a-z0-9]+).*/\1/p" .sops.yaml
}

fail=0
err() { echo "secrets-lint: $*" >&2; fail=1; }

decls=$(declarations)
[[ -n $decls ]] || { echo "secrets-lint: no sops secrets declared anywhere" >&2; exit 1; }

while IFS=$'\t' read -r host file key; do
  [[ -z $host ]] && continue
  if ! git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    err "$host: $file (for $key) is not git-tracked — git add -f it"
    continue
  fi
  pub=$(pubkey "$host")
  if [[ -z $pub ]]; then
    err "$host: no &$host age key in .sops.yaml"
  elif ! grep -qE "^[[:space:]]*(-[[:space:]]+)?recipient:[[:space:]]*$pub\$" "$file"; then
    err "$host: can't decrypt $file (not a recipient) but declares $key"
  fi
  # sops-nix addresses nested keys as a/b; only the top level is visible unencrypted.
  top=${key%%/*}
  if ! line=$(grep -m1 -E "^$top:" "$file"); then
    err "$host: $file has no $top"
  elif [[ $line == *'ENC[REDACTED]'* ]]; then
    err "$host: $file:$top is a scrubbed placeholder"
  fi
done <<<"$decls"

# A recipient no .sops.yaml anchor names is a retired (or leaked) key that still opens the file.
known=$(sed -nE 's/^[[:space:]]*-[[:space:]]*&[a-z_]+[[:space:]]+(age1[a-z0-9]+).*/\1/p' .sops.yaml)
for file in $(git ls-files -- 'secrets/*.yaml'); do
  while read -r r; do
    grep -qxF "$r" <<<"$known" || err "$file: recipient ${r:0:12}… is not in .sops.yaml — run sops-editor-key.sh sync"
  done < <(sed -nE 's/^[[:space:]]*(-[[:space:]]+)?recipient:[[:space:]]*(age1[a-z0-9]+).*/\2/p' "$file")
done

if ((fail)); then exit 1; fi
echo "secrets-lint: ok ($(grep -c . <<<"$decls") declarations)"
