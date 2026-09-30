import importlib.util
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location(
    "sqlch_sync", Path(__file__).parent / "sqlch-sync.py"
)
ss = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(ss)


def lib(*stations):
    return {"version": 1, "stations": [dict(s) for s in stations]}


def st(id, freq=100.0, group="Pop", **extra):
    return {"id": id, "name": id, "url": f"http://x/{id}", "frequency": freq, "group": group, **extra}


def test_new_station_on_remote_is_appended_locally():
    local = lib(st("a"))
    remote = lib(st("a"), st("b"))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    assert {s["id"] for s in nl["stations"]} == {"a", "b"}
    assert lc is True and rc is False


def test_new_station_on_local_is_pushed_to_remote():
    local = lib(st("a"), st("b"))
    remote = lib(st("a"))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    assert {s["id"] for s in nr["stations"]} == {"a", "b"}
    assert lc is False and rc is True


def test_identical_libraries_report_no_change():
    local = lib(st("a"), st("b"))
    remote = lib(st("a"), st("b"))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    assert lc is False and rc is False


def test_conflict_authority_is_local_remote_adopts_local_entry():
    local = lib(st("a", freq=98.9, group="RnB/Hip-Hop"))
    remote = lib(st("a", freq=101.1, group="Unsorted"))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    got = nr["stations"][0]
    assert got["frequency"] == 98.9 and got["group"] == "RnB/Hip-Hop"
    assert lc is False and rc is True


def test_conflict_authority_is_remote_local_adopts_remote_entry():
    local = lib(st("a", freq=101.1, group="Unsorted"))
    remote = lib(st("a", freq=98.9, group="RnB/Hip-Hop"))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=False)
    got = nl["stations"][0]
    assert got["frequency"] == 98.9 and got["group"] == "RnB/Hip-Hop"
    assert lc is True and rc is False


def test_play_count_difference_alone_is_not_a_conflict():
    local = lib(st("a", play_count=5, last_played=100))
    remote = lib(st("a", play_count=9, last_played=200))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    assert lc is False and rc is False


def test_real_conflict_merges_volatile_counts():
    local = lib(st("a", group="Rock", play_count=5, last_played=100))
    remote = lib(st("a", group="Unsorted", play_count=9, last_played=200))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    got = nr["stations"][0]
    assert got["group"] == "Rock"
    assert got["play_count"] == 9
    assert got["last_played"] == 200


def test_never_deletes_station_absent_from_authority():
    local = lib(st("a"))                       # authority, no "b"
    remote = lib(st("a"), st("b"))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    assert {s["id"] for s in nl["stations"]} == {"a", "b"}
    assert {s["id"] for s in nr["stations"]} == {"a", "b"}


def test_conflict_winner_and_merged_volatile_land_on_both_sides():
    # local is authority: group "Rock" wins over remote "Unsorted"; play_count
    # from the losing (remote) side is carried onto BOTH sides.
    local = lib(st("a", group="Rock", play_count=5, last_played=100))
    remote = lib(st("a", group="Unsorted", play_count=9, last_played=50))
    nl, nr, lc, rc = ss.merge(local, remote, is_authority=True)
    gl, gr = nl["stations"][0], nr["stations"][0]
    assert gl["group"] == "Rock" and gr["group"] == "Rock"
    assert gl["play_count"] == 9 and gr["play_count"] == 9
    assert gl["last_played"] == 100 and gr["last_played"] == 100
    assert lc is True and rc is True


def test_argv_parsing_authority_flag():
    assert ss.parse_authority(["prog", "desktop", "1"]) is True
    assert ss.parse_authority(["prog", "desktop", "0"]) is False
    assert ss.parse_authority(["prog", "desktop"]) is False
