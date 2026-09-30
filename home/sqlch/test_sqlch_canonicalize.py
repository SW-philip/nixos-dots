import importlib.util
import json
from pathlib import Path

import pytest

_HERE = Path(__file__).parent
_SPEC = importlib.util.spec_from_file_location(
    "sqlch_canonicalize", _HERE.parent.parent / "scripts" / "sqlch-canonicalize.py"
)
cz = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(cz)

BASELINE = json.loads((_HERE / "testdata" / "library-baseline.json").read_text())


def _canon():
    return cz.canonicalize(json.loads(json.dumps(BASELINE)))  # deep copy


def test_drops_the_three_duplicate_ids():
    ids = {s["id"] for s in _canon()["stations"]}
    assert "wioq-q102-philly" not in ids
    assert "wwip-sports-radio-94-wip" not in ids
    assert "90s90s-hiphop-rap" not in ids
    assert len(_canon()["stations"]) == 60


def test_every_station_has_a_real_group_and_numeric_frequency():
    for s in _canon()["stations"]:
        assert isinstance(s["group"], str) and s["group"], s["id"]
        assert isinstance(s["frequency"], (int, float)), s["id"]


def test_known_corrections_applied():
    by = {s["id"]: s for s in _canon()["stations"]}
    assert by["wprb-princeton-radio"]["frequency"] == 103.3
    assert by["wppm_-_phillycam"]["frequency"] == 106.5
    assert by["wrnb-rnb-and-hip-hop"]["frequency"] == 100.3
    assert by["wrnb-rnb-and-hip-hop"]["group"] == "RnB/Hip-Hop"
    assert by["wrff-alt-1045"]["group"] == "Alternative"
    assert by["wstw-delaware-valley"]["group"] == "Top 40"


def test_am_stations_keep_am_numbers():
    by = {s["id"]: s for s in _canon()["stations"]}
    assert by["wurd-talk-900"]["frequency"] == 900.0
    assert by["kyw-news-radio-1060"]["frequency"] == 1060.0
    assert by["wpht-talk-1210"]["frequency"] == 1210.0
    assert by["wdas-sports-1480"]["frequency"] == 1480.0


def test_no_unintended_fm_collision():
    fm = {}
    for s in _canon()["stations"]:
        f = s["frequency"]
        if f < 200:
            fm.setdefault(f, []).append(s["id"])
    dupes = {f: ids for f, ids in fm.items() if len(ids) > 1}
    assert dupes == {90.1: ["wrti-classical", "wrti-jazz"]} or dupes == {
        90.1: ["wrti-jazz", "wrti-classical"]
    }


def test_other_fields_preserved():
    src = {s["id"]: s for s in BASELINE["stations"]}
    out = {s["id"]: s for s in _canon()["stations"]}
    s = out["wmmr-mmr-rocks"]
    assert s["url"] == src["wmmr-mmr-rocks"]["url"]
    assert s["added_at"] == src["wmmr-mmr-rocks"]["added_at"]
    assert s["play_count"] == src["wmmr-mmr-rocks"]["play_count"]


def test_stations_sorted_by_frequency_then_id():
    st = _canon()["stations"]
    keys = [(s["frequency"], s["id"]) for s in st]
    assert keys == sorted(keys)


def test_top_level_keys_kept():
    out = _canon()
    assert out["version"] == BASELINE["version"]
    assert set(out.keys()) == set(BASELINE.keys())


def test_90s90s_hiphop_inherits_the_dropped_twins_url():
    src = {s["id"]: s for s in BASELINE["stations"]}
    dropped_url = src["90s90s-hiphop-rap"]["url"]
    assert dropped_url != src["90s90s-hip-hop"]["url"]  # they really differ
    out = {s["id"]: s for s in _canon()["stations"]}
    assert "90s90s-hiphop-rap" not in out               # still dropped
    assert out["90s90s-hip-hop"]["url"] == dropped_url   # 192k MP3 URL carried over
    assert "mp3-192" in out["90s90s-hip-hop"]["url"]


def test_raises_when_station_absent_from_map():
    bad = json.loads(json.dumps(BASELINE))
    bad["stations"].append(
        {"id": "totally-bogus-not-in-map", "name": "x", "url": "http://x",
         "frequency": 100.0, "group": "Pop"}
    )
    with pytest.raises(AssertionError):
        cz.canonicalize(bad)


def test_raises_on_disallowed_fm_collision(monkeypatch):
    # 93.7 is already wstw-delaware-valley; forcing wmmr onto it too is a
    # collision that is not in _ALLOWED_SHARED.
    monkeypatch.setitem(cz.MAP, "wmmr-mmr-rocks", ("Rock", 93.7))
    with pytest.raises(AssertionError):
        _canon()
