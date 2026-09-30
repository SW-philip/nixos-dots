from greeter.sessions import list_sessions


def _write(p, name, exec_):
    p.write_text(f"[Desktop Entry]\nName={name}\nExec={exec_}\nType=Application\n")


def test_lists_and_defaults_niri_first(tmp_path):
    _write(tmp_path / "gnome.desktop", "GNOME", "gnome-session")
    _write(tmp_path / "niri.desktop", "Niri", "niri-session")
    sessions = list_sessions([str(tmp_path)], default="niri")
    assert sessions[0]["id"] == "niri"
    assert sessions[0]["name"] == "Niri"
    assert sessions[0]["exec"] == "niri-session"
    assert {s["id"] for s in sessions} == {"niri", "gnome"}


def test_missing_dir_is_skipped(tmp_path):
    _write(tmp_path / "niri.desktop", "Niri", "niri-session")
    sessions = list_sessions([str(tmp_path), "/nonexistent/dir"], default="niri")
    assert len(sessions) == 1


def test_empty_when_no_sessions(tmp_path):
    assert list_sessions([str(tmp_path)], default="niri") == []
