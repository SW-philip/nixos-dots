#!/usr/bin/env bash
# pass-through-migrate: one-time move of ~/Pictures and ~/Downloads onto desktop's 3 TB drive.
# Run on desktop first, then on surface, each BEFORE the nrs that adds the home-manager symlinks
# (home-manager refuses to overwrite a real directory). Nothing is deleted: the old directory is
# renamed <name>.migrated-<date> for you to remove by hand. The script does NOT create ~/<name>:
# home-manager treats a symlink it did not make as foreign, so the following nrs creates the links.
#   desktop: moves into /srv/prepko (refuses unless /srv is a mounted drive)
#   surface: mounts desktop's /srv/prepko at ~/.desktop (ad hoc, unmounted again on exit; nrs
#            makes it permanent), merges into it (a name clash keeps both: the shared copy
#            wins, surface's goes to *.from-surface)
set -euo pipefail

HOME_DIR=${PT_HOME:-$HOME}
SELF=${PT_SELF:-$( [[ $(uname -n) == SWphil ]] && echo desktop || echo surface )}
SUDO=${PT_SUDO-sudo}
DATE=${PT_DATE:-$(date +%Y%m%d)}
NAMES=(Pictures Downloads)
if [[ $SELF == desktop ]]; then ROOT=${PT_ROOT:-/srv/prepko}; else ROOT=${PT_ROOT:-$HOME_DIR/.desktop}; fi

# validate everything before changing anything
if [[ $SELF == desktop && -n ${PT_REQUIRE_MOUNT-/srv} ]] && ! mountpoint -q "${PT_REQUIRE_MOUNT-/srv}"; then
  echo "${PT_REQUIRE_MOUNT-/srv} is not a mount point: the 3 TB drive is not mounted, refusing" >&2; exit 1
fi
for n in "${NAMES[@]}"; do
  home=$HOME_DIR/$n
  if [[ -L $home && $(readlink "$home") != "$ROOT/$n" ]]; then
    echo "$n: $home is a symlink to $(readlink "$home"), not $ROOT/$n — refusing" >&2; exit 1
  fi
done

mounted_here=0
cleanup() { [[ $mounted_here == 1 ]] && $SUDO umount "$ROOT" || true; }
trap cleanup EXIT
if [[ $SELF == surface && ${PT_SKIP_MOUNT:-} != 1 ]] && ! mountpoint -q "$ROOT"; then
  mkdir -p "$ROOT"
  # shellcheck disable=SC2086
  $SUDO mount -t nfs4 -o nfsvers=4.2,soft,timeo=30,retrans=2 100.64.0.1:/srv/prepko "$ROOT"
  mounted_here=1
fi

# copy via a temp name so an interrupted copy never leaves a truncated file at the real name
safe_cp() { cp -a "$1" "$2.pt-tmp.$$" && mv "$2.pt-tmp.$$" "$2"; }

for n in "${NAMES[@]}"; do
  home=$HOME_DIR/$n target=$ROOT/$n
  if [[ -L $home ]]; then echo "$n: already linked"; continue; fi
  if [[ $SELF == desktop ]]; then
    # shellcheck disable=SC2086
    $SUDO install -d -o "$(id -un)" -g "$(id -gn)" -m 0700 "$ROOT"
    # shellcheck disable=SC2086
    $SUDO install -d -o "$(id -un)" -g "$(id -gn)" -m 0755 "$target"
  else
    [[ -d $target ]] || { echo "$n: $target missing — is desktop's export live (nrs on desktop first)?" >&2; exit 1; }
  fi
  if [[ ! -d $home ]]; then echo "$n: nothing to migrate"; continue; fi
  if [[ $SELF == surface ]]; then
    # the shared copy wins a name clash; surface's differing file is kept beside it
    while IFS= read -r -d '' f; do
      rel=${f#"$home"/}
      dest=$target/$rel
      if [[ -d $f && ! -L $f ]]; then
        mkdir -p "$dest"
      elif [[ ! -e $dest && ! -L $dest ]]; then
        mkdir -p "$(dirname "$dest")"; safe_cp "$f" "$dest"
      elif [[ -L $f ]]; then
        :
      elif ! cmp -s "$f" "$dest"; then
        safe_cp "$f" "$dest.from-surface"
      fi
    done < <(find "$home" -mindepth 1 \( -type f -o -type l -o -type d \) -print0)
  else
    rsync -a "$home/" "$target/"
    # a dry run that still wants to transfer something means the copy is incomplete: stop before the rename
    if [[ -n $(rsync -an --itemize-changes "$home/" "$target/") ]]; then
      echo "$n: copy incomplete, leaving $home in place" >&2; exit 1
    fi
  fi
  mv "$home" "$home.migrated-$DATE"
  echo "$n: data now in $target; old copy kept as $home.migrated-$DATE; run nrs to create the link"
done
