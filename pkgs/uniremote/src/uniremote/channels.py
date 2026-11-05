"""Sectioning and filtering for the Roku channels window. Pure: no GTK."""
from __future__ import annotations

RECENT_SHOWN = 8


def filter_apps(apps, query):
    """Case-insensitive substring match on the channel name; Roku order is kept."""
    q = query.strip().lower()
    if not q:
        return list(apps)
    return [(app_id, name) for app_id, name in apps if q in name.lower()]


def sections(apps, favorites, recent, query=""):
    """Favorites (the user's order), Recent (newest first, not already a favorite,
    capped at RECENT_SHOWN) and All (Roku order), each filtered by `query`.
    Ids the Roku does not list (uninstalled channels) are dropped."""
    names = dict(apps)
    fav_ids = [i for i in favorites if i in names]
    recent_ids = [i for i in recent if i in names and i not in fav_ids][:RECENT_SHOWN]
    return {
        "favorites": filter_apps([(i, names[i]) for i in fav_ids], query),
        "recent": filter_apps([(i, names[i]) for i in recent_ids], query),
        "all": filter_apps(apps, query),
    }
