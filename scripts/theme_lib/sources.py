"""Palette sources: keyword search (Color Magic) and the official Rosé Pine palette."""
import sys
from datetime import datetime

import requests

from theme_lib.paths import COLOR_MAGIC_API, ROSE_PINE_PALETTE_URL, RP_COLOR_MAP, RP_FALLBACK
from theme_lib.palette import derive_full_palette
from theme_lib.cache import save_cache


SEED_KEYS = ("HALL", "TONIC", "MEDIANT", "DOMINANT", "SUBDOMINANT")


def _result_from_colors(query: str, palette_name: str, tags: list,
                        colors: list, fetched_at: str) -> dict:
    """Derive a full palette from the raw seed colors. Deriving on read keeps the
    persisted cache independent of the palette key schema — a rename of the derive
    keys can never poison stored entries (only the 5 raw hexes are persisted)."""
    initial = dict(zip(SEED_KEYS, colors[:5]))
    return {
        "query": query,
        "palette_name": palette_name,
        "tags": tags,
        "colors": colors[:5],
        "palette": derive_full_palette(initial),
        "fetched_at": fetched_at,
    }


def fetch_api_palette(query: str, cache: dict) -> dict | None:
    cache_key = query.lower().strip()
    entry = cache.get(cache_key)
    # Only entries carrying the raw seed colors are trustworthy. Pre-rename entries
    # stored a derived palette (no "colors") whose accents were already adjusted in
    # place — not faithfully recoverable — so they are ignored and refetched.
    if entry and isinstance(entry.get("colors"), list) and len(entry["colors"]) >= 5:
        print(f"⏭️  Using cached palette for '{query}'")
        return _result_from_colors(query, entry.get("palette_name", query),
                                   entry.get("tags", []), entry["colors"],
                                   entry.get("fetched_at", ""))

    url = f"{COLOR_MAGIC_API}?q={query.replace(' ', '+')}"
    try:
        print(f"🔍 Fetching '{query}' from Color Magic API...")
        resp = requests.get(url, timeout=10)
        resp.raise_for_status()
        results = resp.json()

        if not results: return None

        best = max(results, key=lambda x: x.get('likesCount', 0))
        colors = best['colors']
        if len(colors) < 5: return None

        result = _result_from_colors(query, best['text'], best.get('tags', []),
                                     colors, datetime.now().isoformat())
        # Persist only the raw inputs — schema-independent and faithfully re-derivable.
        cache[cache_key] = {k: result[k] for k in
                            ("query", "palette_name", "tags", "colors", "fetched_at")}
        save_cache(cache)
        print(f"✅ Cached '{query}' -> {best['text']}")
        return result

    except Exception as e:
        print(f"❌ Error fetching API: {e}", file=sys.stderr)
        return None


def fetch_rose_pine_palette(variant: str) -> dict[str, str]:
    """Fetch official Rosé Pine colors for main/moon/dawn from the GitHub palette JSON.
    Falls back to built-in values if the network request fails.
    """
    variant = variant.lower().strip() or "main"
    if variant not in ("main", "moon", "dawn"):
        print(f"⚠️  Unknown Rosé Pine variant '{variant}', defaulting to 'main'")
        variant = "main"

    try:
        print(f"🌹 Fetching Rosé Pine '{variant}' from official palette...")
        resp = requests.get(ROSE_PINE_PALETTE_URL, timeout=10)
        resp.raise_for_status()
        data = resp.json()

        variant_colors = data.get("variants", {}).get(variant, {}).get("colors", {})
        if not variant_colors:
            raise ValueError("variant data missing or empty in palette JSON")

        official: dict[str, str] = {}
        for rp_key, internal_key in RP_COLOR_MAP.items():
            entry = variant_colors.get(rp_key)
            hex_val = entry.get("hex", "") if isinstance(entry, dict) else (entry or "")
            if isinstance(hex_val, str) and hex_val.startswith("#") and len(hex_val) == 7:
                official[internal_key] = hex_val

        if len(official) < 5:
            raise ValueError(f"only {len(official)} colors parsed — unexpected JSON shape")

        print(f"✅ Fetched {len(official)} official colors for '{variant}'")
        return official

    except Exception as e:
        print(f"⚠️  Falling back to built-in palette ({e})")
        return {RP_COLOR_MAP[k]: v for k, v in RP_FALLBACK[variant].items() if k in RP_COLOR_MAP}
