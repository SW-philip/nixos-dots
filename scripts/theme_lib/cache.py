"""Persistence for the API palette cache."""
import json

from theme_lib.paths import API_CACHE_FILE


def save_cache(cache: dict):
    """Saves the current API palette cache to a JSON file."""
    with open(API_CACHE_FILE, 'w') as f:
        json.dump(cache, f, indent=2)

def load_cache() -> dict:
    """Loads the API palette cache if it exists."""
    if API_CACHE_FILE.exists():
        try:
            with open(API_CACHE_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            return {}
    return {}
