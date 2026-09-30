#!/usr/bin/env bash
# ==========================================================
# Quantum Clock — v3
# Modes: moon (default) · hex · progress · natural
# Modes latch until cycled back to moon.
# Hourly surprise fires from default mode only.
# Lunar phase: synodic reference-epoch method (accurate).
# ==========================================================
set -euo pipefail

# shellcheck source=/dev/null
source "$HOME/.config/waybar/palette.sh"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/quantum_clock"
MODE_FILE="$CACHE_DIR/mode"
H24_FILE="$CACHE_DIR/24h"
HOURLY_FILE="$CACHE_DIR/hourly_show"

CLOCK_DEFAULT="moon"
CLOCK_MODES=(moon hex progress natural caliper binary)

: "${CLOCK_TZ:=}"
CLOCK_24H=$(cat "$H24_FILE" 2>/dev/null || echo "0")

mkdir -p "$CACHE_DIR"
[[ -f "$MODE_FILE" ]] || echo "$CLOCK_DEFAULT" > "$MODE_FILE"

# ── Time helpers ──────────────────────────────────────────

_now() {
  [[ -n "$CLOCK_TZ" ]] && TZ="$CLOCK_TZ" date +%s || date +%s
}

_date() {   # wrapper: runs date with optional TZ
  if [[ -n "$CLOCK_TZ" ]]; then
    TZ="$CLOCK_TZ" date "$@"
  else
    date "$@"
  fi
}

_fmt() {    # HH:MM (no seconds) for bar display
  local ep="$1"
  if [[ "$CLOCK_24H" == "1" ]]; then
    _date -d "@$ep" "+%H:%M"
  else
    _date -d "@$ep" "+%-I:%M %p"
  fi
}

_fmt_sec() {  # HH:MM:SS for tooltip
  local ep="$1"
  if [[ "$CLOCK_24H" == "1" ]]; then
    _date -d "@$ep" "+%H:%M:%S"
  else
    _date -d "@$ep" "+%-I:%M:%S %p"
  fi
}

_wrap_json() {
  # Only escape double-quotes; leave \n sequences intact (waybar renders them).
  printf '{"text":"%s","tooltip":"%s","class":"%s"}\n' \
    "$(sed 's/"/\\"/g' <<<"$1")" \
    "$(sed 's/"/\\"/g' <<<"$2")" \
    "$(sed 's/"/\\"/g' <<<"$3")"
}

# ── Mode cycling ──────────────────────────────────────────

_current_mode() { cat "$MODE_FILE" 2>/dev/null || echo "$CLOCK_DEFAULT"; }

_next_mode() {
  local cur; cur=$(_current_mode)
  local n=${#CLOCK_MODES[@]}
  for i in "${!CLOCK_MODES[@]}"; do
    if [[ "${CLOCK_MODES[$i]}" == "$cur" ]]; then
      echo "${CLOCK_MODES[$(( (i+1) % n ))]}" > "$MODE_FILE"
      return
    fi
  done
  echo "${CLOCK_MODES[0]}" > "$MODE_FILE"
}

# ── Tooltip base (same regardless of mode) ────────────────

_tooltip_base() {
  local ep="$1"
  local weekday datestr weeknum dayofyear year dow total_days

  weekday=$( _date -d "@$ep" "+%A")
  datestr=$(  _date -d "@$ep" "+%-d %B %Y")
  weeknum=$(  _date -d "@$ep" "+%-V")
  dayofyear=$(date -d "@$ep" "+%-j")
  year=$(     date -d "@$ep" "+%Y")
  dow=$(      date -d "@$ep" "+%u")   # 1=Mon … 7=Sun

  if (( year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) )); then
    total_days=366
  else
    total_days=365
  fi

  local weekend_line=""
  case "$dow" in
    1) weekend_line="\n<span foreground='${PIANO}'>4 days until the weekend</span>" ;;
    2) weekend_line="\n<span foreground='${PIANO}'>3 days until the weekend</span>" ;;
    3) weekend_line="\n<span foreground='${PIANO}'>2 days until the weekend</span>" ;;
    4) weekend_line="\n<span foreground='${PIANO}'>1 day until the weekend</span>" ;;
    5) weekend_line="\n<span foreground='${ROOT}'>weekend starts tomorrow</span>" ;;
    6|7) weekend_line="" ;;
  esac

  echo "<span foreground='${REST}'>${weekday}</span>, <span foreground='${SCORE}'>${datestr}</span>\n<span foreground='${REST}'>Week ${weeknum} · Day ${dayofyear} of ${total_days}</span>${weekend_line}\n<span foreground='${FIFTH}'>$(_fmt_sec "$ep")</span>"
}

# ── Lunar phase ───────────────────────────────────────────
# Reference new moon: 2000-01-06 18:14 UTC = JD 2451550.259
# Synodic period: 29.530588853 days
# Returns pipe-separated: glyph|name|illum%|days_to_full|days_to_new

_lunar() {
  local ep; ep="$(_now)"

  read -r phase_days illum phase_idx <<< "$(awk -v t="$ep" 'BEGIN {
    pi      = 3.141592653589793
    synodic = 29.530588853
    jd      = t / 86400.0 + 2440587.5
    ref_new = 2451550.259

    frac = (jd - ref_new) / synodic
    frac = frac - int(frac)
    if (frac < 0) frac += 1

    phase_days = frac * synodic
    illum      = int((1 - cos(frac * 2 * pi)) / 2 * 100 + 0.5)
    phase_idx  = int(frac * 8 + 0.5) % 8

    printf "%.2f %d %d\n", phase_days, illum, phase_idx
  }')"

  local -a names=(
    "New Moon"       "Waxing Crescent" "First Quarter"  "Waxing Gibbous"
    "Full Moon"      "Waning Gibbous"  "Last Quarter"   "Waning Crescent"
  )
  local -a glyphs=( "󰽤" "󰽧" "󰽡" "󰽨" "󰽢" "󰽦" "󰽣" "󰽥" )

  local days_to_full days_to_new
  days_to_full=$(awk -v pd="$phase_days" -v syn=29.530588853 'BEGIN {
    half = syn / 2
    d    = half - pd
    if (d < 0) d += syn
    printf "%.0f\n", d
  }')
  days_to_new=$(awk -v pd="$phase_days" -v syn=29.530588853 'BEGIN {
    printf "%.0f\n", syn - pd
  }')

  printf '%s|%s|%d|%s|%s' \
    "${glyphs[$phase_idx]}" "${names[$phase_idx]}" "$illum" "$days_to_full" "$days_to_new"
}

# ── Hex time ──────────────────────────────────────────────
# Day = 16^3 = 4096 hex-ticks (~21.09s each): 16 hexhours (90m each),
# each split into 16 hexminutes (5m37.5s each), each into 16 hexseconds.

_hex_digit() {   # 0-15 -> single uppercase hex digit
  printf '%X' "$1"
}

_hex_fields() {   # decimal h m s -> "hexhour hexminute hexsecond" (each 0-15)
  local h=$1 m=$2 s=$3
  local secs=$(( h * 3600 + m * 60 + s ))
  local tick=$(( secs * 4096 / 86400 ))
  local hexhour=$(( tick / 256 ))
  local hexminute=$(( (tick / 16) % 16 ))
  local hexsecond=$(( tick % 16 ))
  echo "$hexhour $hexminute $hexsecond"
}

_hexhour_progress() {   # decimal h m s -> progress through current hexhour, 0-1000
  local h=$1 m=$2 s=$3
  local secs=$(( h * 3600 + m * 60 + s ))
  local rem=$(( secs % 5400 ))
  echo $(( rem * 1000 / 5400 ))
}

_hex_gradient_block() {   # block index 0-7, progress 0-1000 -> blend toward next color, 0-1000
  local i=$1 progress_x1000=$2
  # coefficient = 1 + (blocks-1)/blocks = 15/8, so the last-lagging block (i=0)
  # exactly reaches 1000 at progress=1000 instead of needing the clamp
  local term_a=$(( progress_x1000 * 15 / 8 ))
  local term_b=$(( (7 - i) * 1000 / 8 ))
  local blend=$(( term_a - term_b ))
  (( blend < 0 )) && blend=0
  (( blend > 1000 )) && blend=1000
  echo "$blend"
}

# 16 colors, one per hexhour, resampled from the 24-color palette used by
# the previous hourly hex swatch (every 1.5 decimal hours) so the
# night->dawn->day->dusk->night arc is preserved at hexhour granularity.
declare -a HOUR_COLORS_HEX=(
  "0d1b2a" "1b2838" "2d1b69" "1d4ed8"
  "ea580c" "f59e0b" "22c55e" "14b8a6"
  "e0f2fe" "fde68a" "f97316" "ef4444"
  "ec4899" "f43f5e" "4f46e5" "1d4ed8"
)

_lerp_rgb() {   # col_a(hex6) col_b(hex6) blend(0-1000) -> blended hex6
  local col_a=$1 col_b=$2 blend=$3
  local ra=$(( 16#${col_a:0:2} )) ga=$(( 16#${col_a:2:2} )) ba=$(( 16#${col_a:4:2} ))
  local rb=$(( 16#${col_b:0:2} )) gb=$(( 16#${col_b:2:2} )) bb=$(( 16#${col_b:4:2} ))
  local r=$(( (ra * (1000 - blend) + rb * blend) / 1000 ))
  local g=$(( (ga * (1000 - blend) + gb * blend) / 1000 ))
  local b=$(( (ba * (1000 - blend) + bb * blend) / 1000 ))
  printf '%02x%02x%02x' "$r" "$g" "$b"
}

_hex_gradient_bar() {   # hexhour_idx(0-15) progress(0-1000) -> 8-block colored span string
  local hexhour_idx=$1 progress_x1000=$2
  local next_idx=$(( (hexhour_idx + 1) % 16 ))
  local col_a="${HOUR_COLORS_HEX[$hexhour_idx]}"
  local col_b="${HOUR_COLORS_HEX[$next_idx]}"

  local bar="" i blend color
  for (( i = 0; i < 8; i++ )); do
    blend=$(_hex_gradient_block "$i" "$progress_x1000")
    color=$(_lerp_rgb "$col_a" "$col_b" "$blend")
    bar+="<span foreground=\"#${color}\">█</span>"
  done
  echo "$bar"
}

_hex() {
  local ep; ep="$(_now)"
  local h m s
  h=$(_date -d "@$ep" +%-H); m=$(_date -d "@$ep" +%-M); s=$(_date -d "@$ep" +%-S)

  local hexhour hexminute hexsecond
  read -r hexhour hexminute hexsecond <<< "$(_hex_fields "$h" "$m" "$s")"

  local hh_digit mm_digit ss_digit
  hh_digit=$(_hex_digit "$hexhour")
  mm_digit=$(_hex_digit "$hexminute")
  ss_digit=$(_hex_digit "$hexsecond")

  local progress_x1000; progress_x1000=$(_hexhour_progress "$h" "$m" "$s")
  local swatch; swatch="$(_hex_gradient_bar "$hexhour" "$progress_x1000")"

  local brk="$REST" c1="$ROOT" c2="$FIFTH" c3="$PIANO"

  echo "<span foreground=\"${brk}\">{</span>${swatch}<span foreground=\"${brk}\">}</span> <span foreground=\"${brk}\">{</span><span foreground=\"${c1}\">${hh_digit}</span><span foreground=\"${brk}\">}{</span><span foreground=\"${c2}\">${mm_digit}</span><span foreground=\"${brk}\">}{</span><span foreground=\"${c3}\">${ss_digit}</span><span foreground=\"${brk}\">}</span>"
}

# ── Day progress ──────────────────────────────────────────

_progress() {
  local ep; ep="$(_now)"
  local h m s
  h=$(date -d "@$ep" +%-H)
  m=$(date -d "@$ep" +%-M)
  s=$(date -d "@$ep" +%-S)

  local secs=$(( h * 3600 + m * 60 + s ))
  local pct=$(( secs * 100 / 86400 ))
  local filled=$(( secs * 10 / 86400 ))

  local c_fill="$FIFTH" c_empty="$BAR" c_pct="$PIANO"
  local bar="" i
  for (( i = 0;      i < filled; i++ )); do bar+="<span foreground=\"${c_fill}\">█</span>"; done
  for (( i = filled; i < 10;     i++ )); do bar+="<span foreground=\"${c_empty}\">░</span>"; done

  printf "%s <span foreground=\"${c_pct}\">%d%%</span>  %s" "$bar" "$pct" "$(_fmt "$ep")"
}

# ── Caliper clock ────────────────────────────────────────

_caliper() {
  local ep; ep="$(_now)"
  local h m s
  h=$(_date -d "@$ep" +%-H)
  m=$(_date -d "@$ep" +%-M)
  s=$(_date -d "@$ep" +%-S)

  local is_pm=$(( h >= 12 ? 1 : 0 ))
  local h12=$(( h % 12 ))
  local h12_secs=$(( h12 * 3600 + m * 60 + s ))

  # Continuous arm: 80 positions across 12h.
  # One full ━ unit appears every ~9 min; the fractional tip shifts every ~67 sec.
  local arm_x8
  if [[ $is_pm -eq 0 ]]; then
    arm_x8=$(( h12_secs * 80 / 43200 ))
  else
    arm_x8=$(( (43200 - h12_secs) * 80 / 43200 ))
  fi
  local arm_len=$(( arm_x8 / 8 ))
  local tip_idx=$(( arm_x8 % 8 ))   # 0 = flush, 1–7 = fractional block

  # Object level: hourly granularity (0 = midnight-tiny, 12 = noon-large)
  local level
  if [[ $is_pm -eq 0 ]]; then
    level=$h12
  else
    level=$(( 12 - h12 ))
  fi

  # AM: botanical scale, midnight→noon (0→11 used; 12 completes array)
  local -a am_objects=(
    "A mote of dust"
    "A grain of pollen"
    "A poppy seed"
    "A sesame seed"
    "A lentil"
    "A green pea"
    "A blueberry"
    "A cherry"
    "A walnut"
    "A lime"
    "An orange"
    "A grapefruit"
    "A pomelo"
  )
  # PM: sporting goods scale, noon→midnight (12→1 used; 0 completes array)
  local -a pm_objects=(
    "A shadow"
    "A BB pellet"
    "A marble"
    "A film canister"
    "A golf ball"
    "A billiard ball"
    "A tennis ball"
    "A baseball"
    "A softball"
    "A bocce ball"
    "A grapefruit"
    "A cantaloupe"
    "A basketball"
  )

  local obj
  if [[ $is_pm -eq 1 ]]; then
    obj="${pm_objects[$level]}"
  else
    obj="${am_objects[$level]}"
  fi

  # Tip brightens toward the top of each hour: FIFTH(dim) → SOTTO → SEVENTH → SCORE(bright)
  # This makes the tip "glow" as each hour boundary approaches.
  local tip_color
  if   [[ $m -lt 15 ]]; then tip_color="$FIFTH"
  elif [[ $m -lt 30 ]]; then tip_color="$SOTTO"
  elif [[ $m -lt 45 ]]; then tip_color="$SEVENTH"
  else                        tip_color="$SCORE"
  fi

  # Build colored arm
  local a="" i
  for (( i = 0; i < arm_len; i++ )); do
    a+="<span foreground=\"${FIFTH}\">━</span>"
  done

  # Fractional tip (▏▎▍▌▋▊▉ for tip_idx 1–7)
  local tip_str=""
  if [[ $tip_idx -gt 0 ]]; then
    local -a tip_chars=("▏" "▎" "▍" "▌" "▋" "▊" "▉")
    tip_str="<span foreground=\"${tip_color}\">${tip_chars[$(( tip_idx - 1 ))]}</span>"
  fi

  # Object colored slightly brighter than the arm so it reads as the "label"
  local jaw
  if [[ $arm_len -gt 0 || $tip_idx -gt 0 ]]; then
    jaw="${a}${tip_str}<span foreground=\"${REST}\">┤</span> <span foreground=\"${SOTTO}\">${obj}</span> <span foreground=\"${REST}\">├</span>${tip_str}${a}"
  else
    jaw="<span foreground=\"${REST}\">┤</span><span foreground=\"${SOTTO}\">${obj}</span><span foreground=\"${REST}\">├</span>"
  fi

  printf "%s  %s" "$jaw" "$(_fmt "$ep")"
}

# ── Natural language time ─────────────────────────────────

_natural() {
  local ep; ep="$(_now)"
  local h m
  h=$(_date -d "@$ep" +%-H)
  m=$(_date -d "@$ep" +%-M)

  # Round to nearest 5 minutes
  local r=$(( (m + 2) / 5 * 5 ))
  if [[ $r -eq 60 ]]; then r=0; h=$(( (h + 1) % 24 )); fi

  # Index 0–23 maps cleanly: midnight=0, noon=12
  local -a hour_names=(
    "midnight" "one"   "two"   "three" "four"  "five"
    "six"      "seven" "eight" "nine"  "ten"   "eleven"
    "noon"     "one"   "two"   "three" "four"  "five"
    "six"      "seven" "eight" "nine"  "ten"   "eleven"
  )
  local next_h=$(( (h + 1) % 24 ))

  if [[ $r -eq 0 ]]; then
    if [[ $h -eq 0 || $h -eq 12 ]]; then
      echo "${hour_names[$h]}"
    else
      echo "${hour_names[$h]} o'clock"
    fi
  elif [[ $r -le 30 ]]; then
    local -a past_words=( "" "five past" "ten past" "quarter past"
                             "twenty past" "twenty-five past" "half past" )
    echo "${past_words[$(( r / 5 ))]} ${hour_names[$h]}"
  else
    local -a to_words=( "" "five to" "ten to" "quarter to" "twenty to" "twenty-five to" )
    echo "${to_words[$(( (60 - r) / 5 ))]} ${hour_names[$next_h]}"
  fi
}

# ── Binary (BCD) clock ────────────────────────────────────
# Each of HH MM SS's 6 digits shown as 4 bits (weights 8 4 2 1, MSB→LSB).

_binary() {   # flat panel: digit-major, 4 glyphs per digit
  local ep; ep="$(_now)"
  local digits; digits="$(_date -d "@$ep" +%H%M%S)"

  local c_on="$FIFTH" c_off="$BAR" c_sep="$REST"
  local panel="" i d val bit
  for (( i = 0; i < 6; i++ )); do
    d="${digits:$i:1}"; val=$(( 10#$d ))
    for bit in 8 4 2 1; do
      if (( (val & bit) != 0 )); then
        panel+="<span foreground=\"${c_on}\">█</span>"
      else
        panel+="<span foreground=\"${c_off}\">░</span>"
      fi
    done
    if   [[ $i -eq 1 || $i -eq 3 ]]; then panel+=" <span foreground=\"${c_sep}\">:</span> "
    elif [[ $i -lt 5 ]]; then panel+=" "
    fi
  done

  printf "%s" "$panel"
}

_binary_grid() {   # tooltip: 4 rows (bit 8,4,2,1) x 6 columns (H1 H2 M1 M2 S1 S2)
  local ep; ep="$(_now)"
  local digits; digits="$(_date -d "@$ep" +%H%M%S)"

  local c_on="$FIFTH" c_off="$BAR"
  local -a bits=(8 4 2 1)
  local -a rows=()
  local row bit i d val
  for bit in "${bits[@]}"; do
    row=""
    for (( i = 0; i < 6; i++ )); do
      d="${digits:$i:1}"; val=$(( 10#$d ))
      if (( (val & bit) != 0 )); then
        row+="<span foreground=\"${c_on}\">█</span>"
      else
        row+="<span foreground=\"${c_off}\">░</span>"
      fi
      if   [[ $i -eq 1 || $i -eq 3 ]]; then row+="  "
      elif [[ $i -lt 5 ]]; then row+=" "
      fi
    done
    rows+=("$row")
  done

  local grid="${rows[0]}"
  for (( i = 1; i < ${#rows[@]}; i++ )); do
    grid+="\n${rows[$i]}"
  done
  printf "%s" "$grid"
}

# ── Commands ──────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-show}"
  case "$cmd" in
    next)
      _next_mode
      exit 0 ;;
    toggle)
      [[ "$CLOCK_24H" == "1" ]] && echo "0" > "$H24_FILE" || echo "1" > "$H24_FILE"
      exit 0 ;;
    help|-h|--help)
      echo "Quantum Clock v3  modes: ${CLOCK_MODES[*]}"
      exit 0 ;;
    lock)
      _natural
      exit 0 ;;
  esac

  # ── Mode selection ────────────────────────────────────────

  mode=$(_current_mode)

  # Hourly surprise: only fires when idling in the default mode,
  # shows a random non-default mode for a ~5-second window.
  if [[ "$mode" == "$CLOCK_DEFAULT" ]]; then
    _min=$(date +%-M); _sec=$(date +%-S)
    if [[ $_min -eq 0 && $_sec -lt 5 ]]; then
      stamp=$(date +%Y%m%d%H)
      if [[ ! -f "$HOURLY_FILE" || "$(cat "$HOURLY_FILE")" != "$stamp" ]]; then
        echo "$stamp" > "$HOURLY_FILE"
        surprise_pool=()
        for _m in "${CLOCK_MODES[@]}"; do
          [[ "$_m" != "$CLOCK_DEFAULT" ]] && surprise_pool+=("$_m")
        done
        [[ ${#surprise_pool[@]} -gt 0 ]] && mode="${surprise_pool[$((RANDOM % ${#surprise_pool[@]}))]}"
      fi
    fi
  fi

  # ── Render ────────────────────────────────────────────────

  ep="$(_now)"
  base_tip="$(_tooltip_base "$ep")"
  class="$mode"

  case "$mode" in
    moon)
      IFS='|' read -r glyph name illum days_to_full days_to_new <<< "$(_lunar)"
      if   (( illum < 25 )); then illum_color="$BAR"
      elif (( illum < 50 )); then illum_color="$REST"
      elif (( illum < 75 )); then illum_color="$FIFTH"
      else                        illum_color="$PIANO"
      fi
      text="<span foreground=\"${ROOT}\">${glyph}</span> $(_fmt "$ep")"
      tip="<span foreground='${ROOT}'>${name}</span> · <span foreground='${illum_color}'>${illum}%</span> illuminated\n<span foreground='${FIFTH}'>${days_to_full}d</span> <span foreground='${REST}'>to full moon</span>  ·  <span foreground='${REST}'>${days_to_new}d to new moon</span>\n\n${base_tip}"
      ;;
    hex)
      text="󰅩 $(_hex)"
      tip="<span foreground='${ROOT}'>Hex time</span> · day = 16 hexhours (90m each) → 16 hexminutes (5m37s each) → 16 hexseconds (~21s each)\n\n${base_tip}"
      ;;
    progress)
      text="$(_progress)"
      tip="<span foreground='${FIFTH}'>Day progress</span>\n\n${base_tip}"
      ;;
    natural)
      text="<span foreground=\"${REST}\">$(_natural)</span>"
      tip="<span foreground='${REST}'>Natural time</span>\n\n${base_tip}"
      ;;
    caliper)
      text="$(_caliper)"
      tip="<span foreground='${SOTTO}'>Caliper clock</span>\n\n${base_tip}"
      ;;
    binary)
      text="$(_binary)"
      tip="<span foreground='${FIFTH}'>Binary clock (BCD)</span> · <span foreground='${REST}'>bit weights 8 4 2 1</span>\n$(_binary_grid)\n\n${base_tip}"
      ;;
    *)
      text="$(_fmt "$ep")"
      tip="$base_tip"
      ;;
  esac

  _wrap_json "$text" "$tip" "$class"
fi
