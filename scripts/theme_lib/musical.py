"""Translate a derived palette dict into the lean 44-key musical schema."""
from theme_lib.colormath import _hex_to_hsl

ACCENTS = ["TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT", "SUPERTONIC", "SUBMEDIANT"]


def vividness(hex_color: str) -> float:
    """Chroma proxy: peaks at saturated, mid-lightness colors (HSL)."""
    _, s, l = _hex_to_hsl(hex_color)
    return s * (1 - abs(2 * l - 1))


def rank_accents(p: dict) -> list[str]:
    """The six accent hexes ordered by vividness desc.
    Ties broken by saturation, then the canonical ACCENTS order (determinism)."""
    order = {k: i for i, k in enumerate(ACCENTS)}
    def sort_key(k):
        _, s, _l = _hex_to_hsl(p[k])
        return (-vividness(p[k]), -s, order[k])
    return [p[k] for k in sorted(ACCENTS, key=sort_key)]


def _rgb(hex_color: str) -> str:
    h = hex_color.lstrip("#")
    return f"{int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)}"


def to_musical(p: dict) -> dict:
    """Derived palette dict -> the 44-key musical schema dict."""
    r = rank_accents(p)
    m = {
        # Ground
        "HALL": p["HALL"], "STAGE": p["STAGE"], "WING": p["WING"],
        "MUTE": p["MUTE"], "DIM": p["GRAD_STAGE_LO"],
        # Ink
        "SCORE": p["SCORE"], "LYRIC": p["LYRIC"], "REST": p["REST"],
        # Accent (ranked)
        "ROOT": r[0], "FIFTH": r[1], "SEVENTH": r[2], "SOTTO": r[3],
        # Signal (theme-tinted; TACET reuses SEVENTH)
        "FORTE": p["FORTE"], "FERMATA": p["FERMATA"], "PIANO": p["PIANO"], "TACET": r[2],
        # Edge
        "BAR": p["BAR"], "LEDGER": p["LEDGER"], "SHADOW": p["SHADOW"],
        # Shell
        "PIT": p["PIT"], "PIT_SURFACE": p["PIT_SURFACE"], "PIT_OVERLAY": p["PIT_OVERLAY"],
        # Charge
        "CHG_FF": p["CHG_FF"], "CHG_MF": p["CHG_MF"], "CHG_MP": p["CHG_MP"],
        "CHG_PP": p["CHG_PP"], "CHG_MORENDO": p["CHG_MORENDO"],
        # Meta (FONT_SIZE_BAR/ICON_SHADOW/alphas are not in the derive dict — supply here)
        "TEMPO": p.get("FONT_SIZE_BAR", "12px"),
        "MEASURE": p.get("ICON_SHADOW", "0 1px 2px rgba(0,0,0,0.80)"),
        "STAFF": p["STAFF"],
        "STAFF_A_OUTER": "0.50", "STAFF_A_DROP": "0.55", "STAFF_A_HOVER": "0.65",
        "STAFF_A_INSET_TOP": "0.08", "STAFF_A_INSET_BOT": "0.30", "STAFF_A_BORDER": "0.07",
        # Derived
        "FORTE_RGB": p["FORTE_RGB"],
        "GRAD_STAGE_HI": p["GRAD_STAGE_HI"], "GRAD_STAGE_LO": p["GRAD_STAGE_LO"],
        "GRAD_WING_HI": p["GRAD_WING_HI"], "GRAD_WING_LO": p["GRAD_WING_LO"],
        "GRAD_HALL_HI": p["GRAD_HALL_HI"], "GRAD_HALL_LO": p["GRAD_HALL_LO"],
    }
    m["ROOT_RGB"] = _rgb(m["ROOT"])
    return m
