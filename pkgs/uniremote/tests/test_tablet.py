from uniremote.tablet import cover_detached


def test_detached(tmp_path):
    f = tmp_path / "surface-cover"
    f.write_text("detached\n")
    assert cover_detached(f) is True


def test_attached(tmp_path):
    f = tmp_path / "surface-cover"
    f.write_text("attached")
    assert cover_detached(f) is False


def test_missing_file_is_not_tablet(tmp_path):
    assert cover_detached(tmp_path / "nope") is False
