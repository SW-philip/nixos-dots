#!/usr/bin/env bash
# Fetch game metadata + art via Skyscraper for one console or all of them,
# or (with -d) deploy already-staged output into /srv/roms via
# skyscraper-deploy.sh. Wraps the platform sections in ~/.skyscraper/
# config.ini (see that file's header for why scrapes land in
# ~/skyscraper-staging instead of straight into /srv/roms).
#
# Usage:
#   scrape                    scrape every configured console
#   scrape -r <console>       scrape just one console
#   scrape --for <console>    same as -r (long form)
#   scrape -d [console]       deploy staged output (all consoles, or just one)
#   scrape --deploy [console] same as -d (long form)
#
# <console> accepts either the /srv/roms folder name (nes, genesis,
# gamecube-wii, ...) or the underlying Skyscraper platform token
# (megadrive, gc, wii, ...) where they differ. For folders scraped by more
# than one token (gamecube-wii: gc+wii), `-d <folder>` deploys both passes
# in one go — skyscraper-deploy.sh's <token> argument is handled internally.

set -uo pipefail

# PS3 dumps are directory trees (PS3_GAME/USRDIR/EBOOT.BIN) and every game
# ships that exact same filename, so Skyscraper's normal filename-based
# search has nothing to go on (bulk `-p ps3 -s screenscraper` "succeeds"
# but matches nothing, since it searches for the term "EBOOT" every time).
# `--query` gives Skyscraper an explicit search string, but only applies
# when exactly one romfile is passed alongside it, so this scrapes one
# title per Skyscraper invocation instead of a single bulk pass. The real
# title comes out of each game's own PS3_GAME/PARAM.SFO (ps3-sfo-title.py).
#
# Gamelist generation (`-f pegasus`) has the same filename problem one
# level further in: it names every exported cover/screenshot/wheel/etc.
# after the ROM's own basename, so a combined `-f pegasus <all 4 files>`
# run happily writes correct per-game text metadata but exports every
# single game's art to the same media/covers/EBOOT.png -- last game
# processed wins, and the other three silently show its art instead of
# their own. Verified live: 2026-09-27 run left all four `assets.boxFront`
# lines pointing at one identical path. Fix: export each title alone into
# an isolated temp dir (via `-g`/`-o`), then rename its art by a
# slugified-title before merging into the shared staging media/ folder.
scrape_ps3() {
  local input="/srv/roms/ps3"
  local staging="$HOME/skyscraper-staging/ps3"
  local staging_media="$staging/media"
  local combined="$staging/metadata.pegasus.txt"

  local ebootfiles=()
  while IFS= read -r -d '' f; do
    ebootfiles+=("$f")
  done < <(find "$input" -type f -iname 'EBOOT.BIN' -print0)

  if [[ ${#ebootfiles[@]} -eq 0 ]]; then
    echo "==> [ps3] no EBOOT.BIN found under $input" >&2
    return 1
  fi

  mkdir -p "$staging_media"
  : > "$combined"

  local title sfo eboot rc=0 processed=0
  local noart=()
  for eboot in "${ebootfiles[@]}"; do
    sfo="$(dirname "$(dirname "$eboot")")/PARAM.SFO"
    if ! title="$(python3 ~/nixos/scripts/ps3-sfo-title.py "$sfo" 2>&1)"; then
      echo "==> [ps3] $eboot: $title" >&2
      rc=1
      continue
    fi

    echo "==> [ps3] scraping '$title' ($eboot)..."
    if ! Skyscraper -p ps3 -s screenscraper --query "$title" "$eboot"; then
      echo "==> [ps3] scrape failed for '$title'" >&2
      rc=1
      continue
    fi

    local slug export_dir
    slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
    export_dir="$(mktemp -d)"

    echo "==> [ps3] exporting '$title' gamelist entry..."
    if ! Skyscraper -p ps3 -f pegasus -g "$export_dir" -o "$export_dir/media" "$eboot" >/dev/null; then
      echo "==> [ps3] gamelist export failed for '$title'" >&2
      rc=1
      rm -rf "$export_dir"
      continue
    fi

    # Rewrite this title's `assets.*` lines to the shared staging media/
    # dir under a slug-based filename, moving the actual file to match --
    # see comment above for why this can't just use Skyscraper's own path.
    local got_art=0
    while IFS= read -r line; do
      case "$line" in
        assets.*)
          got_art=1
          key="${line%%:*}"
          path="${line#*: }"
          cat="$(basename "$(dirname "$path")")"
          ext="${path##*.}"
          mkdir -p "$staging_media/$cat"
          mv -f "$path" "$staging_media/$cat/$slug.$ext"
          echo "$key: $staging_media/$cat/$slug.$ext" >> "$combined"
          ;;
        *)
          echo "$line" >> "$combined"
          ;;
      esac
    done < <(awk '/^game:/{f=1} f' "$export_dir/metadata.pegasus.txt")
    echo >> "$combined"

    # A matched title with zero assets.* lines means screenscraper's own
    # entry for this game has no cover/screenshot/wheel/etc uploaded --
    # Skyscraper still reports "success" for it (it found a title match),
    # so without this warning that data gap is completely silent.
    if [[ "$got_art" -eq 0 ]]; then
      echo "==> [ps3] warning: '$title' matched but screenscraper has no artwork for it" >&2
      noart+=("$title")
    fi

    rm -rf "$export_dir"
    processed=$((processed + 1))
  done

  if [[ "$processed" -eq 0 ]]; then
    echo "==> [ps3] nothing scraped successfully, skipping gamelist" >&2
    return 1
  fi

  echo "==> [ps3] wrote $processed entries to $combined"
  if [[ ${#noart[@]} -gt 0 ]]; then
    echo "==> [ps3] no artwork available for: ${noart[*]}" >&2
    echo "==> [ps3] (try another module, e.g. 'Skyscraper -p ps3 -s thegamesdb --flags interactive --query \"<title>\" <eboot>', or drop art in by hand)" >&2
  fi
  return $rc
}

# token|folder — one row per Skyscraper scrape pass. gc/wii share a folder
# because /srv/roms/gamecube-wii holds both systems (see config.ini).
JOBS=(
  "nes|nes"
  "snes|snes"
  "megadrive|genesis"
  "gba|gba"
  "psx|psx"
  "n64|n64"
  "saturn|saturn"
  "gc|gamecube-wii"
  "wii|gamecube-wii"
  "ps2|ps2"
  "psp|psp"
  "ps3|ps3"
  "wiiu|wiiu"
  "xbox|xbox"
  "3ds|3ds"
  "switch|switch"
  "dreamcast|dreamcast"
)

usage() {
  echo "Usage: scrape [-r|--for <console>]"
  echo "       scrape -d|--deploy [console]"
  echo
  echo "Consoles:"
  for job in "${JOBS[@]}"; do
    echo "  ${job%%|*} (${job#*|})"
  done
}

mode="scrape"
console=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  -r|--for)
    console="${2:-}"
    [[ -z "$console" ]] && { echo "scrape: -r/--for needs a console name" >&2; usage >&2; exit 1; }
    ;;
  -d|--deploy)
    mode="deploy"
    console="${2:-}"
    ;;
  "") ;;
  *)
    echo "scrape: unrecognized argument '$1'" >&2
    usage >&2
    exit 1
    ;;
esac

matched=()
if [[ -z "$console" ]]; then
  matched=("${JOBS[@]}")
else
  for job in "${JOBS[@]}"; do
    token="${job%%|*}"
    folder="${job#*|}"
    if [[ "$token" == "$console" || "$folder" == "$console" ]]; then
      matched+=("$job")
    fi
  done
  if [[ ${#matched[@]} -eq 0 ]]; then
    echo "scrape: unknown console '$console'" >&2
    usage >&2
    exit 1
  fi
fi

# Folders scraped by more than one platform token (gamecube-wii: gc+wii)
# need skyscraper-deploy.sh's <token> argument so each pass's staged
# gamelist deploys to (or is read from) its own sidecar/subdir instead of
# colliding with the other's. Count occurrences up front so both deploy
# mode and the "publish with" hint below know which folders need it.
declare -A folder_job_count
for job in "${JOBS[@]}"; do
  folder_job_count["${job#*|}"]=$(( ${folder_job_count["${job#*|}"]:-0} + 1 ))
done

if [[ "$mode" == "deploy" ]]; then
  failed=()
  for job in "${matched[@]}"; do
    token="${job%%|*}"
    folder="${job#*|}"
    if [[ ${folder_job_count["$folder"]} -gt 1 ]]; then
      echo "==> deploying [$folder $token]..."
      ~/nixos/scripts/skyscraper-deploy.sh "$folder" "$token" || failed+=("$folder/$token")
    else
      echo "==> deploying [$folder]..."
      ~/nixos/scripts/skyscraper-deploy.sh "$folder" || failed+=("$folder")
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed to deploy: ${failed[*]}" >&2
    exit 1
  fi
  exit 0
fi

failed=()
touched_pairs=()
for job in "${matched[@]}"; do
  token="${job%%|*}"
  folder="${job#*|}"
  if [[ "$token" == "ps3" ]]; then
    if ! scrape_ps3; then
      failed+=("$token")
      continue
    fi
    touched_pairs+=("$token|$folder")
    continue
  fi

  echo "==> [$token] scraping art+metadata from screenscraper..."
  if ! Skyscraper -p "$token" -s screenscraper; then
    echo "==> [$token] scrape pass failed, skipping gamelist" >&2
    failed+=("$token")
    continue
  fi
  echo "==> [$token] writing Pegasus gamelist..."
  if ! Skyscraper -p "$token" -f pegasus; then
    echo "==> [$token] gamelist generation failed" >&2
    failed+=("$token")
    continue
  fi
  touched_pairs+=("$token|$folder")
done

echo
if [[ ${#touched_pairs[@]} -gt 0 ]]; then
  echo "Staged. Publish into /srv/roms with:"
  declare -A hinted
  for pair in "${touched_pairs[@]}"; do
    folder="${pair#*|}"
    if [[ -z "${hinted[$folder]:-}" ]]; then
      echo "  scrape -d $folder"
      hinted["$folder"]=1
    fi
  done
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Failed: ${failed[*]}" >&2
  exit 1
fi
