#!/usr/bin/env python3
"""pair-themes.py — write PAIR ("the next theme in my group") into palettes.

  pair-themes.py                 every <slug> / <slug>-light and <slug>-dark / <slug> pair
  pair-themes.py A B [C ...]     one group, in order: A -> B -> C -> A  (a pair is just two)

Idempotent. make-variant.py does the first form itself; the second is for hand-made
groups, such as the Rosé Pine variants that swap among themselves."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from theme_lib.paths import THEMES_ROOT
from theme_lib.variant import find_pairs, set_pair


def find_dir(slug: str) -> Path:
    for family in sorted(THEMES_ROOT.iterdir()):
        d = family / slug
        if (d / f"palette-{slug}.nix").exists():
            return d
    sys.exit(f"pair-themes: no theme '{slug}' under {THEMES_ROOT}")


def main():
    changed = 0
    if len(sys.argv) > 1:
        slugs = sys.argv[1:]
        if len(slugs) < 2:
            sys.exit("pair-themes: a group needs at least two themes")
        dirs = [find_dir(s) for s in slugs]
        for i, d in enumerate(dirs):
            changed += set_pair(d, slugs[(i + 1) % len(slugs)])
        print(f"group {' -> '.join(slugs + [slugs[0]])}, {changed} palette file(s) updated")
        return
    pairs = find_pairs(THEMES_ROOT)
    for a, b in pairs:
        changed += set_pair(a, b.name)
        changed += set_pair(b, a.name)
    print(f"{len(pairs)} pairs, {changed} palette file(s) updated")


if __name__ == "__main__":
    main()
