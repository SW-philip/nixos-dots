from uniremote.icons import IconCache


def test_store_then_get_round_trip(tmp_path):
    cache = IconCache(tmp_path)
    assert cache.get("12") is None
    path = cache.store("12", b"png-bytes")
    assert path == tmp_path / "12.png"
    assert path.read_bytes() == b"png-bytes"
    assert cache.get("12") == path


def test_non_digit_ids_are_refused(tmp_path):
    cache = IconCache(tmp_path)
    assert cache.store("../evil", b"x") is None
    assert cache.get("../evil") is None
    assert cache.store("", b"x") is None
    assert list(tmp_path.iterdir()) == []


def test_store_creates_the_cache_directory(tmp_path):
    cache = IconCache(tmp_path / "nested" / "icons")
    assert cache.store("5", b"x") == tmp_path / "nested" / "icons" / "5.png"
