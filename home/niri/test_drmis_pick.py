#!/usr/bin/env python3
"""Standalone tests for drmis pick pure helpers. Run: python3 home/niri/test_drmis_pick.py"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent))
import drmis_tui as drmis


def _themes():
    # (slug, family, dir, sh, colors) — same shape as get_all_themes()
    return [
        ("citrus",     "Dark",  None, None, {"HALL": "#111111"}),
        ("octopus",    "Dark",  None, None, {"HALL": "#222222"}),
        ("eagles",     "Dark",  None, None, {"HALL": "#004c54"}),
        ("rose-pine",  "Light", None, None, {"HALL": "#f4ede8"}),
    ]


def test_build_pick_rows_sections_and_order():
    rows = drmis.build_pick_rows(_themes())
    kinds_labels = [(r["kind"], r["label"]) for r in rows]
    assert kinds_labels == [
        ("header", "🌙 Dark"),
        ("theme",  "citrus"),
        ("theme",  "octopus"),
        ("theme",  "eagles"),
        ("header", "☀️ Light"),
        ("theme",  "rose-pine"),
        ("header", "◐ Mode"),
        ("action", "Toggle light / dark"),
        ("header", "🎲 Shuffle"),
        ("action", "Random (any)"),
    ], kinds_labels
    assert rows[-1]["action"] == "random"


def test_unknown_family_is_not_hidden():
    themes = _themes() + [("custom-x", "Weird", None, None, {})]
    labels = [r["label"] for r in drmis.build_pick_rows(themes)]
    assert "Weird" in labels  # appears as its own header
    assert "custom-x" in labels


def test_selectable_indices_skip_headers():
    rows = drmis.build_pick_rows(_themes())
    sel = drmis.selectable_indices(rows)
    assert all(rows[i]["kind"] in ("theme", "action") for i in sel)
    assert sel[0] == 1  # first theme, not the header at 0


def test_move_cursor_skips_headers_and_wraps():
    rows = drmis.build_pick_rows(_themes())
    sel = drmis.selectable_indices(rows)
    first, last = sel[0], sel[-1]
    # down from octopus (idx 2) lands on eagles (idx 3); down from eagles skips the Light header at 4
    assert drmis.move_cursor(rows, 2, +1) == 3
    assert drmis.move_cursor(rows, 3, +1) == 5
    # wrap: down from last selectable -> first selectable
    assert drmis.move_cursor(rows, last, +1) == first
    # wrap: up from first selectable -> last selectable
    assert drmis.move_cursor(rows, first, -1) == last


def test_move_cursor_from_header_index():
    rows = drmis.build_pick_rows(_themes())
    sel = drmis.selectable_indices(rows)
    # idx 0 is the first header ("🌙 Dark"); going down should land on the first selectable, not skip it
    assert drmis.move_cursor(rows, 0, +1) == sel[0]
    # going up from the first header should wrap to the last selectable
    assert drmis.move_cursor(rows, 0, -1) == sel[-1]
    # from a mid-list header (the "☀️ Light" header), down -> next selectable after it, up -> previous selectable before it
    rp_hdr = next(i for i, r in enumerate(rows) if r["label"] == "☀️ Light")
    nxt = next(i for i in sel if i > rp_hdr)
    prv = next(i for i in reversed(sel) if i < rp_hdr)
    assert drmis.move_cursor(rows, rp_hdr, +1) == nxt
    assert drmis.move_cursor(rows, rp_hdr, -1) == prv


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} passed")
    sys.exit(0)
