#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["requests"]
# ///
"""
auto-theme — Unified theme generator and activator.

Modes:
2. API Mode: Fetches palettes from Color Magic API for keywords (e.g., "neapolitan", "halloween")

Usage:
    python3 scripts/auto-theme.py "Philadelphia 76ers"       # Team mode
    python3 scripts/auto-theme.py "neapolitan"               # API mode (Ice cream)
    python3 scripts/auto-theme.py "halloween"                # API mode (Holiday)
    python3 scripts/auto-theme.py --list                     # List available teams
    python3 scripts/auto-theme.py --list-api "tropical"      # Preview API results
"""

import argparse
import json
import sys
from pathlib import Path

# External dependency for API; theme_lib.sources imports it — guard here for a friendly message.
try:
    import requests  # noqa: F401
except ImportError:
    print("❌ Error: 'requests' library not found. Install with: pip install requests")
    sys.exit(1)

from theme_lib.paths import THEMES_ROOT, DARK_DIR, PALETTE_SOURCES, ROSE_PINE_SLUGS
from theme_lib.colormath import parse_colorhunt_url, map_colorhunt_to_slots
from theme_lib.palette import derive_full_palette
from theme_lib.cache import load_cache
from theme_lib.sources import fetch_api_palette, fetch_rose_pine_palette
from theme_lib.scoring import print_source_comparison
from theme_lib.registry import register_theme, theme_exists, _read_sh_palette
from theme_lib.locking import is_locked
from theme_lib.naming import slugify
from theme_lib.categories import CATEGORIES, run_category


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Auto-generate and activate themes from teams or keywords.")
    parser.add_argument("query", nargs="?", help="Team name or keyword (e.g., 'lakers', 'neapolitan')")
    parser.add_argument("--rose-pine", action="store_true", help="Use official Rosé Pine palette (fetched live)")
    parser.add_argument("--manual", metavar="HEX_LIST", help="Manual 5 colors: #base,#love,#rose,#pine,#foam")
    parser.add_argument("--colorhunt", metavar="URL", help="Generate from a colorhunt.co palette URL")
    parser.add_argument("--list", action="store_true", help="List available teams")
    parser.add_argument("--list-api", metavar="KEYWORD", help="Preview API results for a keyword")
    parser.add_argument("--register-only", action="store_true", help="Generate files but don't activate")
    parser.add_argument("--force", action="store_true", help="Overwrite existing hand-crafted palette files")
    parser.add_argument("--output-dir", metavar="PATH", help="Write theme files here instead of themes/Dark/<slug>")
    parser.add_argument("--rp-strength", type=float, default=0.0, metavar="0-1",
                        help="Blend accent hues toward Rose Pine semantics (0=off, 1=full)")
    parser.add_argument("--batch", action="store_true",
                        help="Regenerate derived files for all existing themes (preserves palette unless --force)")
    parser.add_argument("--family", metavar="NAME",
                        help="Limit --batch to one family (Dark, Light)")
    parser.add_argument("--sources", action="store_true", help="List available palette sources")
    parser.add_argument("--source", metavar="NAME",
                        help="Palette source to use for keyword queries (default: colormagic)")
    parser.add_argument("--compare", action="store_true",
                        help="Fetch query from all keyword sources and show a side-by-side comparison")
    # One --<category> flag per CATEGORIES key (e.g. --animals); adding a category is a dict edit.
    for cat, meta in CATEGORIES.items():
        parser.add_argument(f"--{cat}", action="store_true",
                            help=f"Batch-generate the '{cat}' collection into themes/{meta['family']}/")
    args = parser.parse_args()
    output_dir = Path(args.output_dir) if args.output_dir else None
    active_category = next((c for c in CATEGORIES if getattr(args, c.replace("-", "_"))), None)

    # 1. PRE-FLIGHT DATA LOADING
    teams = []
    api_cache = load_cache()

    # 2. GLOBAL HELP CHECK
    if not args.query and not (args.rose_pine or args.manual or args.list or args.list_api
                               or args.batch or args.sources or args.compare or args.colorhunt
                               or active_category):
        parser.print_help()
        sys.exit(1)

    # 2-cat. FLAG: --<category> (e.g. --animals)
    if active_category:
        run_category(active_category, force=args.force,
                     register_only=args.register_only, api_cache=api_cache)
        return

    # 2a. FLAG: --sources
    if args.sources:
        print("\n  Available palette sources:\n")
        for sname, desc in PALETTE_SOURCES.items():
            print(f"  \033[1m{sname:<14}\033[0m {desc}")
        print()
        return

    # 3. FLAG: --list
    if args.list:
        print("No team data is bundled.")
        return

    # 4. FLAG: --batch
    if args.batch:
        strength = args.rp_strength
        if args.family:
            family_dirs = [THEMES_ROOT / args.family]
            if not family_dirs[0].is_dir():
                print(f"❌ Family '{args.family}' not found in {THEMES_ROOT}", file=sys.stderr)
                sys.exit(1)
        else:
            family_dirs = [d for d in sorted(THEMES_ROOT.iterdir()) if d.is_dir()]
        seeds_keys = ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT")
        ok = fail = skip = 0
        for fam_dir in family_dirs:
            print(f"\n── {fam_dir.name} ──")
            for theme_dir in sorted(fam_dir.iterdir()):
                if not theme_dir.is_dir():
                    continue
                slug = theme_dir.name
                sh_path = theme_dir / f"palette-{slug}.sh"
                if not sh_path.exists():
                    print(f"  ⏭  {slug}: no palette-{slug}.sh, skipping")
                    skip += 1
                    continue
                if is_locked(theme_dir):
                    print(f"  🔒 {slug}: locked, skipping")
                    skip += 1
                    continue
                try:
                    if args.force:
                        # --force: re-derive the palette from seed colors (requires seeds).
                        # Musical .sh stores them as SEED_*; legacy files used bare names.
                        raw = _read_sh_palette(sh_path)
                        initial = {k: raw[f"SEED_{k}"] if f"SEED_{k}" in raw else raw.get(k)
                                   for k in seeds_keys}
                        missing = [k for k in seeds_keys if not initial.get(k)]
                        if missing:
                            print(f"  ⏭  {slug}: no seeds to re-derive {missing}, skipping")
                            skip += 1
                            continue
                        fam = "Rose-Pine" if slug in ROSE_PINE_SLUGS else fam_dir.name
                        p = derive_full_palette(initial, rp_strength=strength, family=fam)
                        register_theme(slug, p, "batch", force=True, output_dir=theme_dir, raw_seeds=initial)
                    else:
                        # Default: regenerate derived files (wallpaper) from the existing
                        # palette — preserves palette-*.sh, needs no seeds. This is what makes
                        # `drmis regen` work on musical themes, which carry no BASE/LOVE seeds.
                        register_theme(slug, {}, "batch", force=False, output_dir=theme_dir)
                    print(f"  ✅ {slug}")
                    ok += 1
                except Exception as e:
                    print(f"  ❌ {slug}: {e}")
                    fail += 1
        print(f"\nBatch complete: {ok} updated, {skip} skipped, {fail} failed")
        return

    # 5. FLAG: --rose-pine — fetch live from official palette, override structural keys
    if args.rose_pine:
        q = (args.query or "").lower()
        variant = "dawn" if "dawn" in q else "moon" if "moon" in q else "main"
        variant_display = {"main": "Rosé Pine", "moon": "Rosé Pine Moon", "dawn": "Rosé Pine Dawn"}
        name = variant_display[variant]

        official = fetch_rose_pine_palette(variant)
        seeds = {k: official[k] for k in ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT") if k in official}
        p = derive_full_palette(seeds, rp_strength=args.rp_strength, family="Rose-Pine")
        for k in ("STAGE", "WING", "BAR", "REST", "SCORE", "SUBMEDIANT", "SUPERTONIC", "MUTE"):
            if k in official:
                p[k] = official[k]

        slug, _ = register_theme(name, p, "rosepine", force=args.force, output_dir=output_dir, raw_seeds=seeds)
        if not args.register_only:
            print(f"  → run `drmis set {slug}` to apply (after `nrs` if it is a new theme)")
        return

    # 6. FLAG: --manual
    if args.manual:
        codes = args.manual.split(',')
        if len(codes) != 5:
            print("❌ Error: --manual requires exactly 5 hex codes (base,love,rose,pine,foam)")
            return
        initial = {"HALL": codes[0], "TONIC": codes[1], "MEDIANT": codes[2], "DOMINANT": codes[3], "SUBDOMINANT": codes[4]}
        p = derive_full_palette(initial, rp_strength=args.rp_strength)
        slug, _ = register_theme("Manual Theme", p, "manual", force=args.force, output_dir=output_dir, raw_seeds=initial)
        if not args.register_only:
            print(f"  → run `drmis set {slug}` to apply (after `nrs` if it is a new theme)")
        return

    # 7. FLAG: --list-api
    if args.list_api:
        res = fetch_api_palette(args.list_api, api_cache)
        if res:
            p = res["palette"]
            print(f"Query: {res['query']} -> {res['palette_name']}")
            print(f"Colors: {', '.join([p['HALL'], p['TONIC'], p['SUPERTONIC'], p['SUBMEDIANT']])}")
        else:
            print("No results found.")
        return

    # 7a. FLAG: --compare
    if args.compare:
        query = args.query
        if not query:
            print("❌ --compare requires a query  (e.g. auto-theme.py 'forest' --compare)",
                  file=sys.stderr)
            sys.exit(1)
        results: dict[str, dict] = {}
        cm = fetch_api_palette(query, api_cache)
        if cm:
            results["colormagic"] = cm["palette"]
        if results:
            print_source_comparison(query, results)
        else:
            print("No results from any source.")
        return

    # 7b. FLAG: --colorhunt
    if args.colorhunt:
        mapped = map_colorhunt_to_slots(parse_colorhunt_url(args.colorhunt))
        raw_seeds = dict(mapped)
        p = derive_full_palette(mapped, rp_strength=args.rp_strength)
        name = args.query or "ColorHunt Theme"
        slug, _ = register_theme(name, p, "colorhunt", force=args.force, output_dir=output_dir, raw_seeds=raw_seeds)
        if not args.register_only:
            print(f"  → run `drmis set {slug}` to apply (after `nrs` if it is a new theme)")
        return

    # 8. SEARCH EXECUTION (API)
    # At this point, we know args.query exists because of the check in step 2.

    # PARKED 2026-06-26: Team lookup removed; keyword path handles all queries.

    # Try API Match
    print(f"🔍 No team found. Trying API for '{args.query}'...")
    api_result = fetch_api_palette(args.query, api_cache)

    if not api_result:
        print(f"❌ No theme found for '{args.query}'.")
        sys.exit(1)

    p = api_result["palette"]
    print(f"  🎨 Palette: {api_result['palette_name']}")
    theme_name = api_result['query']
    slug, _ = register_theme(theme_name, p, "api", force=args.force, output_dir=output_dir)

    print(f"  ✅ Generated: {slug}")
    if not args.register_only:
        print(f"  → run `drmis set {slug}` to apply (after `nrs` if it is a new theme)")

if __name__ == "__main__":
    main()
