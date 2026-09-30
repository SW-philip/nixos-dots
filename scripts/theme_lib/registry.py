"""Theme registration and existence checks.

The live desktop is themed by the Nix pipeline (home/niri/default.nix + drmis),
which re-derives every app config from the palette. So registering a theme means
writing only its source-of-truth palette files (.nix/.sh) plus the wallpaper;
`drmis set <slug>` (after `nrs`) applies it.
"""
import subprocess
import sys
from pathlib import Path

from theme_lib.musical import to_musical
from theme_lib.naming import slugify
from theme_lib.paths import CUSTOM_DIR, THEMES_ROOT, MAKE_WALLPAPER, NIXOS_ROOT
from theme_lib.palette_files import write_nix, write_sh, SEED_KEYS


def _read_sh_palette(sh_path: Path) -> dict:
    """Parse a palette.sh file back into a dict of exported variables."""
    palette = {}
    for line in sh_path.read_text().splitlines():
        if line.startswith('export '):
            rest = line[7:]
            if '=' in rest:
                key, _, val = rest.partition('=')
                palette[key.strip()] = val.strip().strip('"')
    return palette


def register_theme(name: str, palette: dict, source: str, force: bool = False,
                    output_dir: Path | None = None, raw_seeds: dict | None = None) -> tuple[str, bool]:
    """Write a theme's palette files and wallpaper; return (slug, already_existed).

    If the theme directory already exists with a palette.sh and force is False,
    that palette is preserved (no overwrite).

    `raw_seeds`, when given, are the caller's pre-derivation input colors — pass
    these whenever `palette` went through `derive_full_palette`'s accent
    harmonizer, since the harmonizer can move TONIC/MEDIANT/DOMINANT/SUBDOMINANT
    to different hues and `palette` no longer reflects what was actually fed in.
    Without this, the recorded SEED_* values silently drift from the real seeds,
    making a later `--batch --force` re-derive non-idempotent.
    """
    slug = slugify(name)
    theme_dir = output_dir if output_dir is not None else CUSTOM_DIR / slug
    already = theme_dir.exists()
    theme_dir.mkdir(parents=True, exist_ok=True)

    existing_sh = theme_dir / f"palette-{slug}.sh"
    if already and existing_sh.exists() and not force:
        print(f"  ℹ️  Preserving existing palette for {slug} (use --force to regenerate)")
    else:
        musical = to_musical(palette)
        source_dict = raw_seeds if raw_seeds is not None else palette
        seeds = {k: source_dict[k] for k in SEED_KEYS if k in source_dict}
        write_nix(theme_dir / f"palette-{slug}.nix", musical, name)
        write_sh(theme_dir / f"palette-{slug}.sh", musical, name, seeds=seeds)

    # Wallpaper Generation — the wallpaper-<slug>.png is consumed live by drmis.
    if MAKE_WALLPAPER.exists():
        print(f"🖼️  Generating wallpaper for {slug}...")
        try:
            result = subprocess.run(
                [sys.executable, str(MAKE_WALLPAPER), str(theme_dir)],
                cwd=str(NIXOS_ROOT),
                timeout=60,
            )
            if result.returncode != 0:
                print(f"⚠️  Wallpaper generation failed (exit {result.returncode})")
        except subprocess.TimeoutExpired:
            print("⚠️  Wallpaper generation timed out after 60s, skipping")

    return slug, already


def theme_exists(slug: str) -> bool:
    """True if a theme directory named `slug` exists under any family folder.

    Families are discovered dynamically, so category families (Custom, and
    future Movies/Bands) are seen without editing a hardcoded list.
    """
    if not THEMES_ROOT.is_dir():
        return False
    for family in THEMES_ROOT.iterdir():
        if family.is_dir() and (family / slug).is_dir():
            return True
    return False
