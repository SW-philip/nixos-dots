#!/usr/bin/env bash
# shellcheck disable=SC2029  # remote paths are meant to expand client-side
# key-escrow: passphrase-encrypt this host's unrecoverable keys (sops age key, SSH host key,
# sbctl Secure Boot keys) and park the bundle on the pi.
# The pi's microSD is unencrypted and `.sops.yaml` lists it as a recipient, so the bundle is
# encrypted with a passphrase that exists nowhere on the pi. Never lands on disk in plaintext.
#   key-escrow.sh [backup]   encrypt and upload (prompts for a passphrase twice)
#   key-escrow.sh verify     download the newest bundle for this host and list its contents
set -euo pipefail

HOST=$(hostname)
PI=${KEY_ESCROW_PI:-prepko@pi}
REMOTE_DIR=${KEY_ESCROW_DIR:-key-escrow}

# /persist paths first: on impermanence hosts /etc and /var/lib are bind mounts of them.
CANDIDATES=(
  /persist/var/lib/sops-nix
  /persist/etc/ssh/ssh_host_ed25519_key
  /persist/etc/ssh/ssh_host_ed25519_key.pub
  /var/lib/sbctl
  /etc/ssh/ssh_host_ed25519_key
)

backup() {
  local present=() p
  for p in "${CANDIDATES[@]}"; do
    sudo test -e "$p" && present+=("$p")
  done
  if ((${#present[@]} == 0)); then
    echo "key-escrow: no known key paths on $HOST" >&2
    exit 1
  fi
  printf 'key-escrow: bundling on %s:\n' "$HOST"
  printf '  %s\n' "${present[@]}"

  local name
  name="$HOST-$(date +%Y%m%d-%H%M%S).tar.age"
  ssh "$PI" "umask 077 && mkdir -p '$REMOTE_DIR'"
  # pipefail makes any failed stage fail the `if`; a truncated .part must never be renamed into place.
  if ! sudo tar -C / --absolute-names -cf - "${present[@]}" | age -p | ssh "$PI" "cat > '$REMOTE_DIR/$name.part'"; then
    ssh "$PI" "rm -f '$REMOTE_DIR/$name.part'"
    echo "key-escrow: failed, nothing kept" >&2
    exit 1
  fi
  ssh "$PI" "mv '$REMOTE_DIR/$name.part' '$REMOTE_DIR/$name'"
  echo "key-escrow: stored $PI:$REMOTE_DIR/$name"
  echo "key-escrow: now run '$0 verify' to prove the passphrase decrypts it"
}

verify() {
  local latest
  latest=$(ssh "$PI" "ls -1t '$REMOTE_DIR'/$HOST-*.tar.age 2>/dev/null | head -n1")
  if [[ -z $latest ]]; then
    echo "key-escrow: no bundle for $HOST on $PI" >&2
    exit 1
  fi
  echo "key-escrow: verifying $latest"
  ssh "$PI" "cat '$latest'" | age -d | tar -tvf -
}

case ${1:-backup} in
  backup) backup ;;
  verify) verify ;;
  *) echo "usage: ${0##*/} [backup|verify]" >&2; exit 2 ;;
esac
