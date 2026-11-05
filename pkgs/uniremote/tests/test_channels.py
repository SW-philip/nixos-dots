from uniremote.channels import RECENT_SHOWN, filter_apps, sections

APPS = [("12", "Netflix"), ("2285", "Hulu"), ("837", "YouTube"), ("13535", "Plex"), ("551012", "Apple TV")]


def test_filter_is_case_insensitive_substring_and_keeps_order():
    assert filter_apps(APPS, "U") == [("2285", "Hulu"), ("837", "YouTube")]
    assert filter_apps(APPS, "  tv ") == [("551012", "Apple TV")]


def test_empty_query_returns_everything():
    assert filter_apps(APPS, "") == APPS
    assert filter_apps(APPS, "   ") == APPS


def test_sections_favorites_keep_user_order_and_drop_unknown_ids():
    s = sections(APPS, favorites=["837", "999", "12"], recent=[])
    assert s["favorites"] == [("837", "YouTube"), ("12", "Netflix")]


def test_recent_excludes_favorites_drops_unknown_and_caps():
    apps = [(str(n), f"App{n}") for n in range(20)]
    recent = [str(n) for n in range(20)] + ["999"]
    s = sections(apps, favorites=["0", "1"], recent=recent)
    ids = [i for i, _ in s["recent"]]
    assert "0" not in ids and "1" not in ids and "999" not in ids
    assert len(ids) == RECENT_SHOWN
    assert ids[0] == "2"


def test_all_is_every_channel_in_roku_order():
    assert sections(APPS, favorites=["12"], recent=["12"])["all"] == APPS


def test_query_filters_every_section():
    s = sections(APPS, favorites=["12", "837"], recent=["2285", "13535"], query="u")
    assert s["favorites"] == [("837", "YouTube")]
    assert s["recent"] == [("2285", "Hulu")]
    assert s["all"] == [("2285", "Hulu"), ("837", "YouTube")]
