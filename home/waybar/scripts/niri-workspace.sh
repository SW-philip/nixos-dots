#!/usr/bin/env bash
# Custom waybar module: show only the active niri workspace (icon + name) for
# one output, and cycle workspaces on click/scroll. Replaces niri/workspaces,
# which reserved full width for every hidden per-workspace button.
set -uo pipefail

# Icon map as JSON, e.g. {"code":"","fallback":""}. Injected by the nix
# wrapper; falls back to name-only text when unset or malformed.
ICONS_JSON=${NIRI_WS_ICONS:-}
if [ -z "$ICONS_JSON" ] || ! jq -e . >/dev/null 2>&1 <<<"$ICONS_JSON"; then
  ICONS_JSON='{}'
fi

# Snark line pools as JSON (persona + time categories). Path injected by the
# nix wrapper as NIRI_WS_SNARK_FILE and seeded once into ~/.local/share; user
# edits there are picked up on the next waybar/niri restart. Unset, unreadable,
# or invalid JSON => no snark line (same graceful degrade as ICONS_JSON).
SNARK_JSON='{}'
if [ -n "${NIRI_WS_SNARK_FILE:-}" ] && [ -r "${NIRI_WS_SNARK_FILE}" ] \
   && jq -e . "${NIRI_WS_SNARK_FILE}" >/dev/null 2>&1; then
  SNARK_JSON=$(cat "${NIRI_WS_SNARK_FILE}")
fi

# Pure. $1 = `niri msg --json workspaces` payload, $2 = output name.
# Prints one waybar JSON line for that output's active workspace.
_render_line() {
  local ws=$1 out=$2
  local now=${NIRI_WS_NOW_EPOCH:-$(date +%s)}
  local hour=${NIRI_WS_NOW_HOUR:-$(date +%-H)}
  printf '%s' "$ws" | jq -c \
    --arg out "$out" \
    --argjson icons "$ICONS_JSON" \
    --argjson snark "$SNARK_JSON" \
    --argjson now "$now" \
    --argjson hour "$hour" '
    def csum(s): (s | explode | add) // 0;
    # Snark line for workspace name $n, or null. Kept in a def so the whole
    # chain can be `try`d — the file is hand-edited and `jq -e .` only checks
    # syntax, so a valid-JSON wrong-shape file (e.g. "lines" as a string) would
    # otherwise abort mid-program and blank the module for that output forever.
    def snarkpick($n):
      (($snark.rotateSeconds | numbers) // 60 | if . < 1 then 1 else . end) as $rot
      | ($snark.persona // {}) as $pmap
      | (($pmap[($n // "")]) // $pmap["_default"] // []) as $ppool
      | (([ $snark.time // [] | .[]
            | select((.from <= $hour) and ($hour < .to)) ][0]).lines // []) as $tpool
      | ([ (if ($ppool | length) > 0 then {cat: "persona", pool: $ppool} else empty end),
           (if ($tpool | length) > 0 then {cat: "time",    pool: $tpool} else empty end)
         ]) as $cats
      | if ($cats | length) == 0 then null
        else ($cats[ (($now / $rot) | floor) % ($cats | length) ]) as $c
           | $c.pool[ csum(($n // "") + ($hour | tostring) + $c.cat) % ($c.pool | length) ]
        end;
    ([.[] | select(.output == $out)]) as $mine
    | ($mine | map(select(.name != null)) | sort_by(.idx)) as $named
    | ($mine | map(select(.is_active)) | first) as $act
    | if $act == null then { text: "", class: "empty" }
      else
        ($act.name) as $n
        | ($n // ($act.idx | tostring)) as $base
        | ($icons[($n // "")] // $icons.fallback // "") as $ic
        # The runtime Nerd Font (HackNerdFont, proportional) has ~1 cell of ink
        # overhang past the glyph advance, so a plain space cannot clear the
        # name. Span-force the zero-overhang Mono variant; one space then works.
        | (if $ic == "" then $base
           else "<span font_family=\"Hack Nerd Font Mono\">" + $ic + "</span> " + $base
           end) as $label
        | (($named | map(.id) | index($act.id))) as $pos
        # snark: two categories, alternating on a wall-clock step. persona is
        # keyed by workspace name (_default fallback); time by the first
        # half-open hour bucket. Line within a pool is a deterministic
        # codepoint-sum hash so redraws in the same context do not flicker.
        # try/catch: any malformed shape degrades to no snark line. `| strings`
        # drops a non-string (e.g. numeric) pool entry before the concat below;
        # trailing `// null` turns that `empty` back into a bindable value.
        | (((try snarkpick($n) catch null) | strings) // null) as $snarkline
        | {
            text: $label,
            tooltip: (($n // ("workspace " + ($act.idx | tostring)))
                      + (if $pos != null
                         then " — \($pos + 1)/\($named | length)"
                         else "" end)
                      # Bare <i>, not a themed <span foreground=…> like sibling
                      # modules: sourcing palette.sh here would break the purity
                      # of _render_line and the test harness. Deliberate.
                      + (if $snarkline != null
                         then "\n<i>" + $snarkline + "</i>"
                         else "" end)),
            class: ($n // "unnamed")
          }
      end
  '
}

# Pure. $1 = workspaces payload, $2 = output, $3 = next|prev.
# Prints the name of the workspace to focus, or nothing when the output has
# fewer than two named workspaces.
_pick_target() {
  local ws=$1 out=$2 dir=$3
  printf '%s' "$ws" | jq -r --arg out "$out" --arg dir "$dir" '
    ([.[] | select(.output == $out and .name != null)] | sort_by(.idx)) as $n
    | ($n | length) as $len
    | if $len < 2 then empty
      else
        ($n | map(.is_active) | index(true)) as $i
        | if $i == null then $n[0].name
          elif $dir == "next" then $n[($i + 1) % $len].name
          else $n[($i - 1 + $len) % $len].name
          end
      end
  '
}

_workspaces() { niri msg --json workspaces 2>/dev/null; }

feed() {
  local out=$1 last="" ws line
  if ws=$(_workspaces) && line=$(_render_line "$ws" "$out"); then
    printf '%s\n' "$line"
    last=$line
  fi
  # event-stream ends when niri restarts; waybar's restart-interval respawns us.
  niri msg --json event-stream 2>/dev/null \
    | jq --unbuffered -c 'select(has("WorkspacesChanged") or has("WorkspaceActivated"))' \
    | while read -r _; do
        ws=$(_workspaces) || continue
        line=$(_render_line "$ws" "$out") || continue
        [ "$line" = "$last" ] && continue
        last=$line
        printf '%s\n' "$line"
      done
  # The pipeline exits 143 when niri restarts kills event-stream; pipefail
  # would propagate that and make waybar log a spurious "stopped unexpectedly".
  return 0
}

cycle() {
  local out=$1 dir=$2 ws target
  ws=$(_workspaces) || exit 0
  target=$(_pick_target "$ws" "$out" "$dir")
  [ -n "$target" ] || exit 0
  # focus-monitor first so the pointer's monitor follows on multi-output; a
  # single-output host treats it as a no-op.
  niri msg action focus-monitor "$out" >/dev/null 2>&1 || true
  niri msg action focus-workspace "$target" >/dev/null 2>&1 || true
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd=${1:-}
  shift || true
  case "$cmd" in
    feed)  feed "${1:?output required}" ;;
    cycle) cycle "${1:?output required}" "${2:?direction (next|prev) required}" ;;
    *)
      echo "usage: niri-workspace.sh {feed <output> | cycle <output> next|prev}" >&2
      exit 2
      ;;
  esac
fi
