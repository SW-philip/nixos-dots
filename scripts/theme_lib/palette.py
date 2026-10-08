"""Palette derivation: Rose Pine blending and depth/accent expansion from seed colors."""
from theme_lib.colormath import (
    _hex_to_hsl, _hsl_to_hex, _clamp, _adjust, _get_text_color, _theme_mode,
    contrast_ratio,
)

# Rose Pine semantic hue targets: (hue/360, l_min, l_max, s_min) for dark themes.
# Light-theme L bounds are mirrored automatically in rosepineify().
_RP_ROLES: dict[str, tuple[float, float, float, float]] = {
    "TONIC":       (346/360, 0.58, 0.75, 0.45),  # red-pink — critical/error
    "MEDIANT":     (  3/360, 0.65, 0.80, 0.38),  # salmon-pink — softer accent
    "DOMINANT":    (200/360, 0.36, 0.57, 0.30),  # teal — cool primary
    "SUBDOMINANT": (189/360, 0.62, 0.78, 0.30),  # light teal — cool secondary
}

def rosepineify(initial: dict, is_dark: bool, strength: float = 0.7) -> dict:
    """Blend each accent seed toward its Rose Pine hue target.

    strength=0.0 → no change.  strength=1.0 → exact RP hues.
    Hue is blended via the shortest circular arc; L is nudged toward the
    per-role midpoint when it falls outside [l_min, l_max]; S is lifted to
    s_min when below it.
    """
    if strength <= 0.0:
        return dict(initial)
    result = dict(initial)
    for key, (target_h, l_min, l_max, s_min) in _RP_ROLES.items():
        if key not in result:
            continue
        h, s, l = _hex_to_hsl(result[key])
        # Mirror L bounds for light themes
        if not is_dark:
            l_min, l_max = 1.0 - l_max, 1.0 - l_min
        # Blend hue via shortest circular path
        diff = (target_h - h + 0.5) % 1.0 - 0.5
        new_h = (h + diff * strength) % 1.0
        # Nudge L into range
        l_mid = (l_min + l_max) / 2
        if l < l_min:
            new_l = l + (l_mid - l) * strength
        elif l > l_max:
            new_l = l + (l_mid - l) * strength
        else:
            new_l = l
        # Lift S to minimum
        new_s = s if s >= s_min else s + (s_min - s) * strength
        result[key] = _hsl_to_hex(new_h, _clamp(new_s), _clamp(new_l))
    return result


def harmonize_accents_by_rank(mapped: dict, keys: tuple, anchor_hues: list,
                               strength: float, min_sat: float = 0.0) -> dict:
    """Blend accents toward a fixed hue-anchor set without crossing.

    A fixed key->anchor mapping (e.g. "TONIC always blends toward red") can drag
    two accents past each other mid-blend if the source palette didn't hand them
    out in that order, making things muddier rather than better separated.
    Instead: sort `keys` by their current hue, sort `anchor_hues`, and match them
    in the same circular order (picking whichever rotation of the anchor set
    minimizes total angular movement) — each accent blends toward its nearest
    anchor and none of them cross.
    """
    if strength <= 0.0:
        return dict(mapped)

    def _circ_dist(a, b):
        d = abs(a - b) % 1.0
        return min(d, 1.0 - d)

    result = dict(mapped)
    present = [k for k in keys if k in mapped]
    if not present:
        return result
    order = sorted(present, key=lambda k: _hex_to_hsl(mapped[k])[0])
    anchors_sorted = sorted(anchor_hues)

    best_cost, best_rot = None, anchors_sorted
    for rot in range(len(anchors_sorted)):
        rotated = anchors_sorted[rot:] + anchors_sorted[:rot]
        cost = sum(_circ_dist(_hex_to_hsl(mapped[k])[0], a) for k, a in zip(order, rotated))
        if best_cost is None or cost < best_cost:
            best_cost, best_rot = cost, rotated
    assignment = dict(zip(order, best_rot))

    for k in present:
        h, s, l = _hex_to_hsl(mapped[k])
        target_h = assignment[k]
        diff = (target_h - h + 0.5) % 1.0 - 0.5
        new_h = (h + diff * strength) % 1.0
        new_s = s if s >= min_sat else s + (min_sat - s) * strength
        result[k] = _hsl_to_hex(new_h, _clamp(new_s), l)
    return result


_UNIVERSAL_ANCHOR_HUES = [0 / 360, 40 / 360, 130 / 360, 185 / 360, 230 / 360, 300 / 360]
_UNIVERSAL_ACCENT_KEYS = ("TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT")
_UNIVERSAL_STRENGTH = 0.6
_UNIVERSAL_MIN_SAT = 0.35


def derive_full_palette(mapped: dict, rp_strength: float = 0.0, family: str | None = None,
                        harmonize: bool = True) -> dict:
    """Takes a dict with HALL, TONIC, MEDIANT, DOMINANT, SUBDOMINANT and derives the full depth."""
    mode = _theme_mode(mapped["HALL"])
    is_dark = mode == "dark"
    if rp_strength > 0.0:
        mapped = rosepineify(mapped, is_dark, rp_strength)

    def _to_rgb(h_str):
        h = h_str.lstrip('#')
        return f"{int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)}"

    # --- 1. STRUCTURAL DEPTH ---
    # Larger L gaps (9%/17% vs 5%/10%) and wider hue shift (9°/16° vs 3.6°/7.2°) so each
    # elevation is visually distinct even at low saturation.
    surface_l = 0.09 if is_dark else -0.08
    overlay_l = 0.17 if is_dark else -0.18

    mapped["STAGE"] = _adjust(mapped["HALL"], l=surface_l, s=0.03, h=-0.025 if is_dark else 0.025)
    mapped["WING"] = _adjust(mapped["HALL"], l=overlay_l, s=0.06, h=-0.044 if is_dark else 0.044)
    # PARKED 2026-06-26: dead intermediate — never read by to_musical. Retained for reference.
    # mapped["OVERLAY_RGB"] = _to_rgb(mapped["WING"])

    # --- 2. HIGHLIGHTS ---
    h_step = 0.12 if is_dark else -0.12
    mapped["MUTE"]           = _adjust(mapped["HALL"], l=h_step)
    # PARKED 2026-06-26: dead intermediates — never read by to_musical. Retained for reference.
    # mapped["HIGHLIGHT_MED"]  = _adjust(mapped["HALL"], l=h_step * 1.6, s=0.05)
    # mapped["HIGHLIGHT_HIGH"] = _adjust(mapped["HALL"], l=h_step * 2.2, s=0.10)

    # --- 3. TEXT HIERARCHY (Contrast-Guaranteed Ink) ---
    from theme_lib.ink import derive_ink
    mapped.update(derive_ink(mapped["HALL"]))

    # --- 4. HARMONIC ACCENTS ---
    # Tint + small hue shift from the input team colors — no large hue jumps.
    # SUPERTONIC: cool-accent slot; nudge SUBDOMINANT slightly toward violet.
    # SUBMEDIANT: warm-amber slot; pick whichever of TONIC/MEDIANT/DOMINANT is closest to
    #       orange (H≈0.08) and nudge it further toward amber.
    mapped["SUPERTONIC"] = _adjust(mapped["SUBDOMINANT"], h=0.06, s=0.05)

    def _circ_dist(a, b):
        d = abs(a - b) % 1.0
        return min(d, 1.0 - d)

    warm_key = min(["TONIC", "MEDIANT", "DOMINANT"],
                   key=lambda k: _circ_dist(_hex_to_hsl(mapped[k])[0], 0.08))
    wh, ws, wl = _hex_to_hsl(mapped[warm_key])
    # Nudge 25% toward orange (H=0.08) using the correct circular direction
    gold_diff = (0.08 - wh + 0.5) % 1.0 - 0.5
    mapped["SUBMEDIANT"] = _hsl_to_hex(
        (wh + gold_diff * 0.25) % 1.0,
        max(0.0, min(1.0, ws - 0.05)),
        max(0.0, min(1.0, wl + (0.08 if is_dark else -0.08))),
    )

    # Every family except Rose-Pine (which already gets its own dedicated,
    # fixed-role treatment above) gets its 6 accents pulled toward well-separated
    # hue anchors by default — no flag needed.
    # harmonize=False keeps a deliberately restrained palette (e.g. an autumn
    # one) from being spread back across the whole hue wheel.
    if harmonize and family != "Rose-Pine":
        mapped = harmonize_accents_by_rank(
            mapped, _UNIVERSAL_ACCENT_KEYS, _UNIVERSAL_ANCHOR_HUES,
            _UNIVERSAL_STRENGTH, min_sat=_UNIVERSAL_MIN_SAT)

    # Ensure readability against the actual background, not a fixed lightness
    # cutoff. A flat "L < 0.4" / "L > 0.7" check assumes HALL is near-black or
    # near-white; it silently under-corrects whenever HALL itself sits at a
    # medium lightness (e.g. a tan/khaki "light" ground), where an accent can
    # clear the absolute threshold while still reading as near-invisible
    # against that particular background. Runs after harmonize_accents_by_rank
    # (which reassigns hues, and hue alone shifts luminance) so it has the
    # final say on every accent that actually ships.
    MIN_ACCENT_CONTRAST = 3.5
    for acc in ["TONIC", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT", "MEDIANT"]:
        step = 0.03 if is_dark else -0.03
        tries = 0
        while contrast_ratio(mapped[acc], mapped["HALL"]) < MIN_ACCENT_CONTRAST and tries < 20:
            mapped[acc] = _adjust(mapped[acc], l=step, s=0.02)
            tries += 1

    # --- 5. UNIFIED HOVERS ---
    # PARKED 2026-06-26: dead block — no HOVER_* key is read by to_musical. Retained for reference.
    # h_lift = 0.15 if is_dark else -0.15
    # mapped["HOVER_BG"] = _adjust(mapped["HALL"], l=h_lift, s=0.05)
    # for key in ["BAR", "SUBDOMINANT", "DOMINANT", "SUBMEDIANT", "TONIC", "MEDIANT", "SUPERTONIC"]:
    #     mapped[f"HOVER_{key}_BG"] = _adjust(mapped[key], l=h_lift, s=0.1)
    #
    # # Legacy hover aliases
    # mapped["HOVER_TEAL_BG"]   = mapped["HOVER_SUBDOMINANT_BG"]
    # mapped["HOVER_GREEN_BG"]  = mapped["HOVER_DOMINANT_BG"]
    # mapped["HOVER_SUBMEDIANT_BG"] = mapped["HOVER_SUBMEDIANT_BG"]
    # mapped["HOVER_ORANGE_BG"] = _adjust(mapped["TONIC"], h=0.05, l=h_lift)

    # --- 6. GHOSTTY BACKGROUND ---
    # PARKED 2026-06-26: dead block — GHOSTTY_* never read by to_musical. Retained for reference.
    # Grey gradient hued with the theme's main color: use HALL hue when it's chromatic,
    # else fall back to TONIC hue.  Keeps saturation very low to avoid neon backgrounds.
    # _gh_base_h, _gh_base_s, _ = _hex_to_hsl(mapped["HALL"])
    # _gh_hue = _gh_base_h if _gh_base_s >= 0.15 else _hex_to_hsl(mapped["TONIC"])[0]
    # if is_dark:
    #     mapped["GHOSTTY_BG"] = _hsl_to_hex(_gh_hue, 0.12, 0.20)
    #     mapped["GHOSTTY_FG"] = _adjust(mapped["HALL"], l=-0.1)
    # else:
    #     mapped["GHOSTTY_BG"] = _hsl_to_hex(_gh_hue, 0.06, 0.93)
    #     mapped["GHOSTTY_FG"] = _adjust(mapped["HALL"], l=0.4)

    # --- 7. WAYBAR & SHADOWS ---
    mapped["PIT"] = _adjust(mapped["HALL"], l=surface_l * 0.5)
    mapped["PIT_SURFACE"] = mapped["STAGE"]
    mapped["PIT_OVERLAY"] = mapped["WING"]

    for t in ["HALL", "STAGE", "WING"]:
        target = mapped[t]
        mapped[f"GRAD_{t}_HI"] = _adjust(target, l=0.04, s=0.02)
        mapped[f"GRAD_{t}_LO"] = _adjust(target, l=-0.04, s=-0.02)

    mapped["SHADOW"] = _adjust(mapped["HALL"], l=-0.25 if is_dark else -0.4, s=0.15, h=-0.05)
    mapped["STAFF"] = _to_rgb(mapped["SHADOW"])
    mapped["FORTE_RGB"] = _to_rgb(mapped["TONIC"])
    # PARKED 2026-06-26: dead intermediate — never read by to_musical. Retained for reference.
    # mapped["BORDER_IRIS_RGB"] = _to_rgb(mapped["SUPERTONIC"])
    mapped["LEDGER"] = _adjust(mapped["TONIC"], l=-0.05)

    # --- 8. TINTS & STATES ---
    # PARKED 2026-06-26: dead intermediates — never read by to_musical. Retained for reference.
    # mapped["TINT_PINE_DARK"] = _adjust(mapped["DOMINANT"], l=-0.2)
    # mapped["TINT_PINE_MID"] = _adjust(mapped["DOMINANT"], l=-0.1)
    # mapped["TINT_CRITICAL_BG"] = _adjust(mapped["TONIC"], l=0.2 if is_dark else -0.2, s=-0.2)
    mapped["FERMATA"] = _adjust(mapped["TONIC"], h=0.05)
    mapped["FORTE"] = mapped["TONIC"]
    mapped["PIANO"] = mapped["SUBMEDIANT"]

    # --- 9. ROLE MAPPINGS ---
    mapped.update({
        "CHG_MORENDO": mapped["TONIC"], "CHG_PP": mapped["SUBMEDIANT"],
        "CHG_MP": mapped["MEDIANT"], "CHG_MF": mapped["SUBDOMINANT"],
        "CHG_FF": mapped["DOMINANT"],
        # PARKED 2026-06-26: dead intermediates — never read by to_musical. Retained for reference.
        # "ACCENT_PRIMARY": mapped["SUPERTONIC"], "ACCENT_SECONDARY": mapped["SUBDOMINANT"],
    })

    return mapped
