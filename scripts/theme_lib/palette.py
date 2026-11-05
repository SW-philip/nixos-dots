"""Palette derivation: Rose Pine blending and depth/accent expansion from seed colors."""
import math
from itertools import combinations

from theme_lib.colormath import (
    _adjust,
    _clamp,
    _hex_to_hsl,
    _hsl_to_hex,
    _theme_mode,
    delta_e_cie76,
    lab_to_hex,
    srgb_to_lab,
)
from theme_lib.ink import derive_ink
from theme_lib.legibility import (
    MIN_ACCENT_DELTA_E,
    MIN_TEXT_CONTRAST,
    contrast_problems,
    distinctness_problems,
    surfaces,
    worst_contrast,
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


# Elevation scales tried in order: full depth first, then WING/MUTE/STAGE pulled
# proportionally toward HALL until every text slot clears its floor on every
# surface. A dark teal/cyan ground's full-depth WING is too light for any accent
# lightness to reach 4.5:1 while staying ΔE-distinct.
_DEPTH_SCALES = (1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2)


def _lch(hex_color: str) -> tuple[float, float, float]:
    L, a, b = srgb_to_lab(hex_color)
    return L, math.hypot(a, b), math.atan2(b, a)


def _lch_hex(L: float, C: float, h: float) -> str:
    """Nearest sRGB colour at this L*/hue: chroma is cut back to the gamut
    edge, then the HSL round trip applies the neon-green saturation ceiling."""
    L = _clamp(L, 0.0, 100.0)
    hex_color = lab_to_hex(L, C * math.cos(h), C * math.sin(h))
    if hex_color is None:
        lo, hi = 0.0, C
        hex_color = lab_to_hex(L, 0.0, 0.0) or ("#ffffff" if L > 50 else "#000000")
        for _ in range(14):
            mid = (lo + hi) / 2
            cand = lab_to_hex(L, mid * math.cos(h), mid * math.sin(h))
            if cand is None:
                hi = mid
            else:
                lo, hex_color = mid, cand
    return _hsl_to_hex(*_hex_to_hsl(hex_color))


def _to_floor(color: str, grounds: list[str], floor: float) -> str:
    """Move `color`'s L* (CIELAB hue and chroma kept, gamut allowing) toward
    whichever pole reads better on `grounds`, just far enough to clear `floor`
    everywhere. Lifting in HSL instead washes accents out to pastel."""
    if worst_contrast(color, grounds) >= floor:
        return color
    pole = max(("#ffffff", "#000000"), key=lambda c: worst_contrast(c, grounds))
    # A mid-tone ground can leave the floor out of reach even at white/black:
    # stop short of the pole so the accents keep their hues (the check still
    # reports the shortfall) instead of all collapsing onto it.
    floor = min(floor, worst_contrast(pole, grounds) - 0.5)
    if worst_contrast(color, grounds) >= floor:
        return color
    L, C, h = _lch(color)
    step = 1.0 if pole == "#ffffff" else -1.0
    cand = color
    while 0.0 < L < 100.0:
        L += step
        cand = _lch_hex(L, C, h)
        if worst_contrast(cand, grounds) >= floor:
            return cand
    return cand


# Dark accents keep their natural lightness range (~16 L* wide) because they
# start above the floor. Lifting light ones only to the floor stacks all six at
# the same L*, so spread them down from the lightest the surfaces allow.
_LIGHT_ACCENT_SPREAD = 16.0


def _grade_light(accents: dict, grounds: list[str]) -> dict:
    """Re-space light-theme accents over a graded L* band, hue and chroma kept.
    Order follows the floor-lifted lightness (so seed character survives); the
    lightest sits at its floor, the rest step darker, which only adds contrast."""
    order = sorted(accents, key=lambda k: -_lch(accents[k])[0])
    top = _lch(accents[order[0]])[0]
    step = _LIGHT_ACCENT_SPREAD / (len(order) - 1)
    graded = {}
    for rank, k in enumerate(order):
        L, C, h = _lch(accents[k])
        target = min(L, top - rank * step)
        graded[k] = _lch_hex(target, C, h) if target < L else accents[k]
    return graded


_SEPARATE_MOVES = ((2.0, 0.0), (-2.0, 0.0), (0.0, 4.0), (0.0, -4.0))


def _shortfall(colors: dict) -> float:
    return sum(max(0.0, MIN_ACCENT_DELTA_E - delta_e_cie76(colors[a], colors[b]))
               for a, b in combinations(colors, 2))


def _separate(colors: dict, grounds: list[str], floor: float, max_steps: int = 150) -> dict:
    """Hill-climb accents apart until every pair clears the ΔE bar. Each step
    nudges one accent's L* or chroma (hue fixed, contrast floor kept), taking
    whichever move cuts the total ΔE shortfall most. Lifting every accent to
    a light WING's floor squeezes them into a narrow L* band; this spreads
    them back out inside it."""
    colors = dict(colors)
    state = {k: list(_lch(v)) for k, v in colors.items()}
    c_bounds = {k: (C * 0.6, C + 20.0) for k, (_, C, _) in state.items()}
    current = _shortfall(colors)
    for _ in range(max_steps):
        if current == 0.0:
            break
        best = None
        for k in colors:
            L, C, h = state[k]
            for dL, dC in _SEPARATE_MOVES:
                nC = _clamp(C + dC, *c_bounds[k])
                if dC and nC == C:
                    continue
                cand = _lch_hex(L + dL, nC, h)
                if cand == colors[k] or worst_contrast(cand, grounds) < floor:
                    continue
                score = _shortfall({**colors, k: cand})
                if best is None or score < best[0]:
                    best = (score, k, cand, L + dL, nC)
        if best is None or best[0] >= current:
            break
        current, k, colors[k], state[k][0], state[k][1] = best
    return colors


def _with_depth(mapped: dict, is_dark: bool, scale: float) -> dict:
    """Surfaces at `scale` x the full elevation ladder, then ink and every text
    slot fitted to them."""
    def _to_rgb(h_str):
        h = h_str.lstrip('#')
        return f"{int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)}"

    # --- 1. STRUCTURAL DEPTH ---
    # Larger L gaps (9%/17% vs 5%/10%) and wider hue shift (9°/16° vs 3.6°/7.2°) so each
    # elevation is visually distinct even at low saturation.
    # Light steps are wider in HSL L: near white the same ΔL buys far fewer L*.
    surface_l = (0.09 if is_dark else -0.10) * scale
    overlay_l = (0.17 if is_dark else -0.21) * scale

    mapped["STAGE"] = _adjust(mapped["HALL"], l=surface_l, s=0.03 * scale,
                              h=(-0.025 if is_dark else 0.025) * scale)
    mapped["WING"] = _adjust(mapped["HALL"], l=overlay_l, s=0.06 * scale,
                             h=(-0.044 if is_dark else 0.044) * scale)

    # --- 2. HIGHLIGHTS ---
    mapped["MUTE"] = _adjust(mapped["HALL"], l=(0.12 if is_dark else -0.15) * scale)

    # --- 3. WAYBAR SHELL & GRADIENT STOPS ---
    mapped["PIT"] = _adjust(mapped["HALL"], l=surface_l * 0.5)
    mapped["PIT_SURFACE"] = mapped["STAGE"]
    mapped["PIT_OVERLAY"] = mapped["WING"]
    for t in ["HALL", "STAGE", "WING"]:
        target = mapped[t]
        mapped[f"GRAD_{t}_HI"] = _adjust(target, l=0.04, s=0.02)
        mapped[f"GRAD_{t}_LO"] = _adjust(target, l=-0.04, s=-0.02)
    grounds = surfaces(mapped)

    # --- 4. TEXT HIERARCHY (Contrast-Guaranteed Ink) ---
    mapped.update(derive_ink(mapped["HALL"], grounds))

    # --- 5. ACCENT READABILITY ---
    # Checked against every surface, not HALL alone: WING (bar fill, swaync,
    # firefox chrome) sits ~0.17 L off HALL, and an accent that clears HALL can
    # read at 2:1 there. Runs after harmonize_accents_by_rank (which reassigns
    # hues, and hue alone shifts luminance) so it has the final say.
    lifted = {k: _to_floor(mapped[k], grounds, MIN_TEXT_CONTRAST) for k in _UNIVERSAL_ACCENT_KEYS}
    if not is_dark:
        lifted = _grade_light(lifted, grounds)
    mapped.update(_separate(lifted, grounds, MIN_TEXT_CONTRAST))

    # --- 6. SHADOWS, EDGES & SIGNALS ---
    mapped["SHADOW"] = _adjust(mapped["HALL"], l=-0.25 if is_dark else -0.4, s=0.15, h=-0.05)
    mapped["STAFF"] = _to_rgb(mapped["SHADOW"])
    mapped["FORTE_RGB"] = _to_rgb(mapped["TONIC"])
    mapped["LEDGER"] = _to_floor(_adjust(mapped["TONIC"], l=-0.05), grounds, MIN_TEXT_CONTRAST)
    mapped["FERMATA"] = _to_floor(_adjust(mapped["TONIC"], h=0.05), grounds, MIN_TEXT_CONTRAST)
    mapped["FORTE"] = mapped["TONIC"]
    mapped["PIANO"] = mapped["SUBMEDIANT"]

    # --- 7. ROLE MAPPINGS ---
    mapped.update({
        "CHG_MORENDO": mapped["TONIC"], "CHG_PP": mapped["SUBMEDIANT"],
        "CHG_MP": mapped["MEDIANT"], "CHG_MF": mapped["SUBDOMINANT"],
        "CHG_FF": mapped["DOMINANT"],
    })
    return mapped


def derive_full_palette(mapped: dict, rp_strength: float = 0.0, family: str | None = None,
                        harmonize: bool = True) -> dict:
    """Takes a dict with HALL, TONIC, MEDIANT, DOMINANT, SUBDOMINANT and derives the full depth."""
    mode = _theme_mode(mapped["HALL"])
    is_dark = mode == "dark"
    if rp_strength > 0.0:
        mapped = rosepineify(mapped, is_dark, rp_strength)

    # --- HARMONIC ACCENTS ---
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

    # Deepest clean ladder wins. If none is clean (e.g. seeds whose accents are
    # ΔE-close at any depth), contrast failures outrank distinctness ones, and
    # ties keep the deeper ladder.
    best, best_rank = None, None
    for scale in _DEPTH_SCALES:
        p = _with_depth(dict(mapped), is_dark, scale)
        rank = (len(contrast_problems(p)), len(distinctness_problems(p)))
        if best_rank is None or rank < best_rank:
            best, best_rank = p, rank
        if rank == (0, 0):
            break
    return best
