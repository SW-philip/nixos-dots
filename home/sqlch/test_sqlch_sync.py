import pytest
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


NOW = 1_800_000_000.0


def fav(id, ts=None, source="youtube", removed=False, **extra):
    row = {"source": source, "id": id, "title": id, **extra}
    if ts is not None:
        row["updated_at"] = ts
    if removed:
        row["removed"] = True
    return row


def test_fav_union_copies_missing_rows_both_ways():
    nl, nr, lc, rc = ss.merge_favorites([fav("a", 1)], [fav("b", 2)], True, now=NOW)
    assert {r["id"] for r in nl} == {"a", "b"} and {r["id"] for r in nr} == {"a", "b"}
    assert lc and rc


def test_fav_identical_reports_no_change():
    nl, nr, lc, rc = ss.merge_favorites([fav("a", 1)], [fav("a", 1)], True, now=NOW)
    assert not lc and not rc


def test_fav_newer_updated_at_wins_regardless_of_authority():
    local = [fav("a", 5, removed=True)]
    remote = [fav("a", 9)]
    for auth in (True, False):
        nl, nr, lc, rc = ss.merge_favorites(local, remote, auth, now=NOW)
        assert nl == remote and nr == remote
        assert lc and not rc


def test_fav_tombstone_propagates():
    local = [fav("a", NOW, removed=True)]
    remote = [fav("a", NOW - 10)]
    nl, nr, lc, rc = ss.merge_favorites(local, remote, False, now=NOW)
    assert nr[0].get("removed") is True and not lc and rc


def test_fav_tie_goes_to_authority():
    local = [fav("a", 5, title="local")]
    remote = [fav("a", 5, title="remote")]
    nl, nr, _, _ = ss.merge_favorites(local, remote, True, now=NOW)
    assert nl[0]["title"] == "local" and nr[0]["title"] == "local"
    nl, nr, _, _ = ss.merge_favorites(local, remote, False, now=NOW)
    assert nl[0]["title"] == "remote" and nr[0]["title"] == "remote"


def test_fav_same_id_different_source_are_distinct():
    nl, nr, _, _ = ss.merge_favorites(
        [fav("a", 1, source="youtube")], [fav("a", 1, source="jellyfin")], True, now=NOW)
    assert len(nl) == 2 and len(nr) == 2


def test_fav_refavorite_after_tombstone_wins():
    nl, nr, _, _ = ss.merge_favorites(
        [fav("a", 5, removed=True)], [fav("a", 8)], True, now=NOW)
    assert not nl[0].get("removed") and not nr[0].get("removed")


def test_fav_legacy_rows_without_updated_at_union():
    nl, nr, lc, rc = ss.merge_favorites([fav("a")], [fav("a"), fav("b")], True, now=NOW)
    assert {r["id"] for r in nl} == {"a", "b"} and lc and not rc


def test_fav_old_tombstones_pruned_on_both_sides():
    old = NOW - ss.TOMBSTONE_TTL - 1
    nl, nr, lc, rc = ss.merge_favorites(
        [fav("a", old, removed=True), fav("k", NOW)], [fav("k", NOW)], True, now=NOW)
    assert [r["id"] for r in nl] == ["k"] and [r["id"] for r in nr] == ["k"]
    assert lc and not rc


def test_fav_recent_tombstone_kept():
    recent = NOW - ss.TOMBSTONE_TTL + 60
    nl, _, lc, _ = ss.merge_favorites([fav("a", recent, removed=True)], [], True, now=NOW)
    assert nl[0]["id"] == "a" and not lc


def test_fav_empty_sides():
    nl, nr, lc, rc = ss.merge_favorites([], [fav("a", 1)], True, now=NOW)
    assert nl == [fav("a", 1)] and lc and not rc


def test_fav_keeps_existing_order_then_appends_new():
    nl, _, _, _ = ss.merge_favorites(
        [fav("z", 1), fav("a", 1)], [fav("m", 1)], True, now=NOW)
    assert [r["id"] for r in nl] == ["z", "a", "m"]


def test_fav_unkeyed_rows_pass_through_untouched():
    junk = {"title": "no key"}
    nl, nr, _, _ = ss.merge_favorites([junk, fav("a", 1)], [fav("b", 1)], True, now=NOW)
    assert junk in nl and junk not in nr


def test_ssh_read_default_for_missing_file(monkeypatch):
    seen = {}

    def fake_run(cmd, **kw):
        seen["cmd"] = cmd

        class P:
            returncode = 0
            stdout = b"[]"
            stderr = b""
        return P()

    monkeypatch.setattr(ss.subprocess, "run", fake_run)
    assert ss.ssh_read("h", "~/x.json", default="[]") == []
    assert "[ -f ~/x.json ]" in seen["cmd"][-1]


def test_targets_cover_library_and_favorites():
    assert [t.label for t in ss.TARGETS] == ["library", "favorites"]
    assert ss.TARGETS[0].empty is None and ss.TARGETS[1].empty == []


def test_sync_target_favorites_pulls_when_local_missing(tmp_path, monkeypatch, capsys):
    t = ss.TARGETS[1]._replace(local_path=str(tmp_path / "favorites.json"))
    monkeypatch.setattr(ss, "ssh_read", lambda host, path, default=None: [fav("a", 1)])
    ss.sync_target("h", t, True)
    import json
    assert [r["id"] for r in json.load(open(t.local_path))] == ["a"]
    assert "favorites" in capsys.readouterr().out


def test_sync_target_library_skips_when_no_local(tmp_path, capsys):
    t = ss.TARGETS[0]._replace(local_path=str(tmp_path / "library.json"))
    ss.sync_target("h", t, True)
    assert "nothing to sync" in capsys.readouterr().out


def test_main_one_target_failing_does_not_block_the_other(tmp_path, monkeypatch, capsys):
    import json
    bad = tmp_path / "library.json"
    bad.write_text("{not json")
    good = tmp_path / "favorites.json"
    targets = [
        ss.TARGETS[0]._replace(local_path=str(bad)),
        ss.TARGETS[1]._replace(local_path=str(good)),
    ]
    monkeypatch.setattr(ss, "TARGETS", targets)
    monkeypatch.setattr(ss, "ssh_read", lambda host, path, default=None: [fav("a", 1)])
    monkeypatch.setattr(ss.sys, "argv", ["sqlch-sync", "h", "1"])
    with pytest.raises(SystemExit) as ex:
        ss.main()
    assert ex.value.code == 1
    assert [r["id"] for r in json.load(open(good))] == ["a"]
    assert "library failed" in capsys.readouterr().err
