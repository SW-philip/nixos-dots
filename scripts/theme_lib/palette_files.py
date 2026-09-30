"""Palette serializers — the only theme files the live (Nix/drmis) pipeline consumes.

`palette-<slug>.nix` is imported by home/niri/default.nix to build every live app
config; `palette-<slug>.sh` feeds waybar and the wallpaper scripts.
"""
from pathlib import Path

from theme_lib.colormath import _hex_to_hsl, _hsl_to_hex


def write_nix(path: Path, p: dict, name: str):
    path.write_text(f"""\
{{
  # ── Ground ────────────────────────────────────────────────────
  HALL  = "{p['HALL']}";
  STAGE = "{p['STAGE']}";
  WING  = "{p['WING']}";
  MUTE  = "{p['MUTE']}";
  DIM   = "{p['DIM']}";

  # ── Ink ───────────────────────────────────────────────────────
  SCORE = "{p['SCORE']}";
  LYRIC = "{p['LYRIC']}";
  REST  = "{p['REST']}";

  # ── Accent ────────────────────────────────────────────────────
  ROOT    = "{p['ROOT']}";
  FIFTH   = "{p['FIFTH']}";
  SEVENTH = "{p['SEVENTH']}";
  SOTTO   = "{p['SOTTO']}";

  # ── Signal ────────────────────────────────────────────────────
  FORTE   = "{p['FORTE']}";
  FERMATA = "{p['FERMATA']}";
  PIANO   = "{p['PIANO']}";
  TACET   = "{p['TACET']}";

  # ── Edge ──────────────────────────────────────────────────────
  BAR    = "{p['BAR']}";
  LEDGER = "{p['LEDGER']}";
  SHADOW = "{p['SHADOW']}";

  # ── Shell ─────────────────────────────────────────────────────
  PIT         = "{p['PIT']}";
  PIT_SURFACE = "{p['PIT_SURFACE']}";
  PIT_OVERLAY = "{p['PIT_OVERLAY']}";

  # ── Charge ────────────────────────────────────────────────────
  CHG_FF      = "{p['CHG_FF']}";
  CHG_MF      = "{p['CHG_MF']}";
  CHG_MP      = "{p['CHG_MP']}";
  CHG_PP      = "{p['CHG_PP']}";
  CHG_MORENDO = "{p['CHG_MORENDO']}";

  # ── Meta ──────────────────────────────────────────────────────
  TEMPO   = "{p['TEMPO']}";
  MEASURE = "{p['MEASURE']}";
  STAFF   = "{p['STAFF']}";
  STAFF_A_OUTER     = "{p['STAFF_A_OUTER']}";
  STAFF_A_DROP      = "{p['STAFF_A_DROP']}";
  STAFF_A_HOVER     = "{p['STAFF_A_HOVER']}";
  STAFF_A_INSET_TOP = "{p['STAFF_A_INSET_TOP']}";
  STAFF_A_INSET_BOT = "{p['STAFF_A_INSET_BOT']}";
  STAFF_A_BORDER    = "{p['STAFF_A_BORDER']}";

  # ── Derived ───────────────────────────────────────────────────
  ROOT_RGB  = "{p['ROOT_RGB']}";
  FORTE_RGB = "{p['FORTE_RGB']}";
  GRAD_STAGE_HI = "{p['GRAD_STAGE_HI']}";
  GRAD_STAGE_LO = "{p['GRAD_STAGE_LO']}";
  GRAD_WING_HI  = "{p['GRAD_WING_HI']}";
  GRAD_WING_LO  = "{p['GRAD_WING_LO']}";
  GRAD_HALL_HI  = "{p['GRAD_HALL_HI']}";
  GRAD_HALL_LO  = "{p['GRAD_HALL_LO']}";
}}
""")

SEED_KEYS = ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT")


def write_sh(path: Path, p: dict, name: str, seeds: dict | None = None):
    """Writes a full shell-compatible palette for Waybar and wallpaper scripts.

    `seeds` are the 5 original input colors (HALL/TONIC/MEDIANT/DOMINANT/SUBDOMINANT), emitted as
    SEED_* exports so `auto-theme.py --batch --force` can re-derive the palette
    later — the musical schema itself no longer carries them.
    """
    lines = [
        "#!/usr/bin/env bash",
        f"# {name} — generated palette",
        "",
        "# --- All Theme Variables ---"
    ]

    # Export every key found in the palette dictionary
    for key, value in p.items():
        lines.append(f'export {key}="{value}"')

    # Ensure explicit wallpaper mapping is also present
    # BG_DARK/BG_LIGHT: grey gradient hued with the theme's dominant color.
    # Use BASE hue when chromatic, else fall back to LOVE.
    # Saturation is deliberately visible (not near-zero): below ~0.2, hex
    # rounding collapses unrelated dark/cool hues onto the same few RGB
    # triples (e.g. rose-pine, raven, and purple-rain all landed within a
    # couple hex digits of each other), so themes stopped reading as themed
    # at all and just looked like plain grey. 0.30/0.15 keeps the paper base
    # muted while still separating themes (visually verified 2026-07-05).
    _wsh, _wss, _wsl = _hex_to_hsl(p.get("HALL", "#1a1a1a"))
    _wh = _wsh if _wss >= 0.15 else _hex_to_hsl(p.get("FORTE", "#808080"))[0]
    if _wsl < 0.5:
        _bg_dark  = _hsl_to_hex(_wh, 0.30, 0.17)
        _bg_light = _hsl_to_hex(_wh, 0.32, 0.29)
    else:
        _bg_dark  = _hsl_to_hex(_wh, 0.15, 0.72)
        _bg_light = _hsl_to_hex(_wh, 0.14, 0.92)
    lines.extend([
        "",
        "# --- Wallpaper Mapping ---",
        f'export BG_DARK="{_bg_dark}"',
        f'export BG_LIGHT="{_bg_light}"',
        f'export ICE_SHADOW="{p.get("HALL", "#1a1a1a")}"',
        f'export ICE_MID="{p.get("FORTE", p.get("SOTTO", "#ff00ff"))}"',
        f'export ICE_HIGHLIGHT="{p.get("FIFTH", p.get("ROOT", "#ffffff"))}"',
        f'export CONE_SHADOW="{p.get("PIANO", "#965a28")}"',
        f'export CONE_MID="{p.get("SOTTO", "#d28e46")}"',
        'export STICKER_COLOR="#ffffff"'
    ])

    if seeds:
        lines.append("")
        lines.append("# --- Seeds (original input colors, for `--batch --force` re-derive) ---")
        lines.extend(f'export SEED_{k}="{seeds[k]}"' for k in SEED_KEYS if k in seeds)

    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o755)
