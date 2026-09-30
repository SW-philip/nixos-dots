"""Category collections — batch-generate a curated keyword set into one family.

Each category maps to its own theme family directory, so the pack stays sorted:
Custom/ and future per-category folders. Adding a category
is a one-line dict edit; `auto-theme.py` registers a `--<key>` flag for each.

`run_category` skips keywords that already exist anywhere on disk and generates the
missing ones. It takes an injectable `fetch` so tests can stub the network and so
Part 2's multi-source `gather → score → pick_best` can replace the single-source
default without touching this orchestration.
"""

from pathlib import Path

from theme_lib.paths import THEMES_ROOT
from theme_lib.naming import slugify
from theme_lib.registry import theme_exists, register_theme
from theme_lib.sources import fetch_api_palette


CATEGORIES = {
    "animals": {
        "family": "Custom",
        "keywords": [
            "octopus", "squid", "fox", "axolotl", "peacock", "flamingo",
            "chameleon", "raven", "koi", "jellyfish", "monarch", "scarab",
        ],
    },
    # future: further categories, each with its own family folder
}


def run_category(name, *, force=False, register_only=False, fetch=None, api_cache=None):
    """Generate every missing theme in category `name` into its family.

    `fetch(keyword) -> {"query","palette",...} | None` defaults to the live
    single-source Color Magic adapter; pass a stub in tests.
    Returns (generated, skipped, failed) slug lists.
    """
    cat = CATEGORIES[name]
    family = cat["family"]
    if fetch is None:
        cache = api_cache if api_cache is not None else {}
        fetch = lambda kw: fetch_api_palette(kw, cache)

    generated, skipped, failed = [], [], []
    print(f"\n── category: {name} → themes/{family}/ ──")
    for kw in cat["keywords"]:
        slug = slugify(kw)
        if theme_exists(slug) and not force:
            print(f"  {kw:<14} ✓ skip (exists)")
            skipped.append(slug)
            continue
        result = fetch(kw)
        if not result or not result.get("palette"):
            print(f"  {kw:<14} ✗ no palette found")
            failed.append(slug)
            continue
        dest = THEMES_ROOT / family / slug
        register_theme(result.get("query", kw), result["palette"], "category",
                       force=force, output_dir=dest)
        src = result.get("source", "colormagic")
        print(f"  {kw:<14} ✗ → {src} → generated")
        generated.append(slug)

    print(f"\n{name}: {len(generated)} generated, {len(skipped)} skipped, "
          f"{len(failed)} failed")
    if generated and not register_only:
        print("  → run `nrs` then `drmis set <slug>` to apply new themes")
    return generated, skipped, failed
