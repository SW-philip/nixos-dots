#!/usr/bin/env python3
"""make-variant.py — derive a light or dark counterpart of an existing theme.

Reads <slug>'s SEED_* colours, rewrites them for the target mode's ground, runs
the usual derive_full_palette + register_theme (palettes + wallpaper), and
writes the result to themes/<Light|Dark>/<slug>-<mode>. The source theme is
never touched.

Usage:
  make-variant.py <slug> [--mode light|dark] [--dry-run] [--force]
                  [--ground-l F] [--ground-sat F] [--accent-sat-max F]
                  [--seed KEY=#rrggbb ...] [--accent KEY=#rrggbb ...] [--no-harmonize]
  make-variant.py --all [--mode light] [--dry-run]
      every Dark theme that has no counterpart yet (skips variants, Rose Pine
      themes, and themes whose counterpart already exists)
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from theme_lib.colormath import _theme_mode
from theme_lib.paths import ROSE_PINE_SLUGS, THEMES_ROOT
from theme_lib.palette import derive_full_palette
from theme_lib.registry import register_theme
from theme_lib.variant import (DERIVED_ACCENTS, apply_overrides, check_palette, hexline,
                               palette_seeds, read_seeds, set_pair, swatch, variant_seeds)

FAMILY = {"dark": "Dark", "light": "Light"}


def find_theme_dir(slug: str) -> Path:
    for family in sorted(THEMES_ROOT.iterdir()):
        d = family / slug
        if (d / f"palette-{slug}.sh").exists():
            return d
    sys.exit(f"make-variant: no theme '{slug}' under {THEMES_ROOT}")


def make_one(slug: str, args, quiet: bool = False) -> list[str]:
    """Derive (and unless --dry-run, write) <slug>'s counterpart; return problems."""
    src = find_theme_dir(slug)
    sh = src / f"palette-{slug}.sh"
    try:
        src_seeds, from_palette = read_seeds(sh), False
    except ValueError:
        src_seeds, from_palette = palette_seeds(sh), True
    if _theme_mode(src_seeds["HALL"]) == args.mode:
        sys.exit(f"make-variant: {slug} is already {args.mode}; use --mode "
                 f"{'dark' if args.mode == 'light' else 'light'}")
    knobs = {"ground_l": args.ground_l, "ground_sat": args.ground_sat,
             "accent_sat_max": args.accent_sat_max}
    knobs = {k: v for k, v in knobs.items() if v is not None}
    seeds = apply_overrides(variant_seeds(src_seeds, args.mode, **knobs), args.seed)
    # A seedless source already carries its final, harmonized accents: re-harmonizing
    # would move them.
    no_harmonize = args.no_harmonize or from_palette
    derived = derive_full_palette(dict(seeds), harmonize=not no_harmonize)
    derived = apply_overrides(derived, args.accent, allowed=DERIVED_ACCENTS)

    name = f"{slug}-{args.mode}"
    problems = check_palette(derived)
    print(name)
    print("  " + swatch(derived))
    if from_palette:
        print("  (no recorded seeds: built from the palette's final accents)")
    if not quiet:
        print("  " + hexline(derived))
    for msg in problems:
        print(f"  ! {msg}")
    if not problems and not quiet:
        print("  checks clean")
    if args.dry_run:
        return problems

    out = THEMES_ROOT / FAMILY[args.mode] / name
    register_theme(name, derived, source=f"variant of {slug}", force=args.force,
                   output_dir=out, raw_seeds=seeds)
    if no_harmonize or args.accent:
        # Not reproducible from the five SEED_* values, so `drmis regen --force`
        # must never re-derive it.
        (out / "LOCKED").touch()
    set_pair(out, slug)
    set_pair(src, name)
    return problems


def pending_themes(mode: str) -> list[str]:
    """Themes of the opposite mode that still need a <mode> counterpart."""
    todo = []
    src_dir = THEMES_ROOT / FAMILY["dark" if mode == "light" else "light"]
    if not src_dir.is_dir():
        return todo
    for d in sorted(src_dir.iterdir()):
        slug = d.name
        if not (d / f"palette-{slug}.sh").exists():
            continue
        if slug.endswith(("-light", "-dark")) or slug in ROSE_PINE_SLUGS:
            continue
        # skip themes that already have any pair (e.g. kid, moss-violet)
        if any((THEMES_ROOT / fam / f"{slug}-{m}").exists()
               for fam in FAMILY.values() for m in ("dark", "light")):
            continue
        todo.append(slug)
    return todo


def main():
    ap = argparse.ArgumentParser(description="Derive a light or dark counterpart of a theme.")
    ap.add_argument("slug", nargs="?")
    ap.add_argument("--all", action="store_true", help="every theme still missing a counterpart")
    ap.add_argument("--mode", choices=("dark", "light"), default="dark")
    ap.add_argument("--ground-l", type=float, default=None)
    ap.add_argument("--ground-sat", type=float, default=None)
    ap.add_argument("--accent-sat-max", type=float, default=None)
    ap.add_argument("--seed", action="append", default=[], metavar="KEY=#hex",
                    help="override one seed after the mode remap (repeatable)")
    ap.add_argument("--accent", action="append", default=[], metavar="KEY=#hex",
                    help="set SUPERTONIC or SUBMEDIANT after derivation (they are otherwise "
                         "near-siblings of SUBDOMINANT and the warm seed); repeatable")
    ap.add_argument("--no-harmonize", action="store_true",
                    help="keep accent hues where the seeds put them (no rainbow spreading)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if args.all == bool(args.slug):
        ap.error("give either a theme slug or --all")

    if not args.all:
        make_one(args.slug, args)
        return

    if args.seed or args.accent or args.no_harmonize:
        ap.error("--seed/--accent/--no-harmonize apply to one theme, not --all")
    todo = pending_themes(args.mode)
    flagged = {}
    for slug in todo:
        problems = make_one(slug, args, quiet=True)
        if problems:
            flagged[slug] = problems
    print(f"\n{len(todo)} themes, {len(todo) - len(flagged)} clean, {len(flagged)} with warnings")
    for slug, problems in flagged.items():
        print(f"  {slug}: {len(problems)}")


if __name__ == "__main__":
    main()
