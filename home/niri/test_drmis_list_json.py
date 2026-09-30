import json
import drmis


def test_do_list_json(monkeypatch, capsys):
    fake = [
        ("midnight-rose", "Rose-Pine", None, None, {}),
        ("eagles",        "Teams",     None, None, {}),
    ]
    monkeypatch.setattr(drmis, "get_all_themes", lambda: fake)
    monkeypatch.setattr(drmis, "current_theme", lambda: "eagles")

    drmis.do_list(["--json"])

    out = json.loads(capsys.readouterr().out)
    assert out == [
        {"slug": "midnight-rose", "family": "Rose-Pine", "current": False},
        {"slug": "eagles", "family": "Teams", "current": True},
    ]


def test_do_list_human_unchanged(monkeypatch, capsys):
    fake = [("eagles", "Teams", None, None, {})]
    monkeypatch.setattr(drmis, "get_all_themes", lambda: fake)
    monkeypatch.setattr(drmis, "current_theme", lambda: "eagles")

    drmis.do_list()

    text = capsys.readouterr().out
    assert "eagles" in text and "Teams" in text and "●" in text
