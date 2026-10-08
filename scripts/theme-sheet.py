#!/usr/bin/env python3
"""theme-sheet.py — render a contact sheet of dark/light theme pairs to a PNG.

One row per theme that has a counterpart: the dark theme on the left, its
<slug>-light on the right, each tile showing ground, surfaces, ink and the
accent chips. Needs resvg on PATH.

Usage:
  theme-sheet.py [--out PATH]          pairs, default ~/.cache/theme-sheets/pairs.png
  theme-sheet.py --only light          just the Light family
"""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from theme_lib.paths import THEMES_ROOT

TILE_W, TILE_H, GAP, PAD = 420, 96, 14, 18
ACCENTS = ("ROOT", "FIFTH", "SEVENTH", "SOTTO", "FORTE", "PIANO")


def read_palette(slug_dir: Path) -> dict:
    sh = slug_dir / f"palette-{slug_dir.name}.sh"
    out = {}
    for line in sh.read_text().splitlines():
        if line.startswith("export ") and "=" in line:
            key, _, val = line[len("export "):].partition("=")
            out[key.strip()] = val.strip().strip('"')
    return out


def tile(x: int, y: int, name: str, p: dict) -> str:
    chips = "".join(
        f'<rect x="{x + 150 + i * 42}" y="{y + 18}" width="34" height="34" rx="8" fill="{p[k]}"/>'
        for i, k in enumerate(ACCENTS))
    return (
        f'<rect x="{x}" y="{y}" width="{TILE_W}" height="{TILE_H}" rx="14" fill="{p["HALL"]}"/>'
        f'<rect x="{x + 14}" y="{y + 60}" width="60" height="22" rx="6" fill="{p["STAGE"]}"/>'
        f'<rect x="{x + 80}" y="{y + 60}" width="60" height="22" rx="6" fill="{p["WING"]}"/>'
        f'<text x="{x + 16}" y="{y + 38}" font-family="sans-serif" font-size="22" '
        f'font-weight="bold" fill="{p["SCORE"]}">Aa</text>'
        f'<text x="{x + 50}" y="{y + 38}" font-family="sans-serif" font-size="14" '
        f'fill="{p["SCORE"]}">{name}</text>'
        f'{chips}'
        f'<rect x="{x + 150}" y="{y + 62}" width="252" height="6" rx="3" fill="{p["LYRIC"]}"/>'
        f'<rect x="{x + 150}" y="{y + 74}" width="170" height="6" rx="3" fill="{p["REST"]}"/>'
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, default=Path.home() / ".cache/theme-sheets/pairs.png")
    ap.add_argument("--only", choices=("light", "dark"))
    args = ap.parse_args()

    dark_dir, light_dir = THEMES_ROOT / "Dark", THEMES_ROOT / "Light"
    rows = []
    if args.only:
        fam = light_dir if args.only == "light" else dark_dir
        rows = [(d, None) for d in sorted(fam.iterdir()) if (d / f"palette-{d.name}.sh").exists()]
    else:
        for d in sorted(dark_dir.iterdir()):
            twin = light_dir / f"{d.name}-light"
            if twin.is_dir() and (twin / f"palette-{twin.name}.sh").exists():
                rows.append((d, twin))
    if not rows:
        sys.exit("theme-sheet: nothing to draw")

    cols = 2
    body, y = [], PAD
    for a, b in rows:
        body.append(tile(PAD, y, a.name, read_palette(a)))
        if b is not None:
            body.append(tile(PAD + TILE_W + GAP, y, b.name, read_palette(b)))
        y += TILE_H + GAP
    width = PAD * 2 + TILE_W * cols + GAP * (cols - 1)
    height = y + PAD - GAP
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
           f'<rect width="100%" height="100%" fill="#7a7a7a"/>{"".join(body)}</svg>')

    args.out.parent.mkdir(parents=True, exist_ok=True)
    svg_path = args.out.with_suffix(".svg")
    svg_path.write_text(svg)
    subprocess.run(["resvg", str(svg_path), str(args.out)], check=True)
    print(args.out)


if __name__ == "__main__":
    main()
