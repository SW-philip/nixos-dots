import os

from greeter import snark


def test_load_snark_lines_reads_file(tmp_path):
    p = tmp_path / "lines.txt"
    p.write_text("one\ntwo\nthree\n")
    assert snark.load_snark_lines(str(p)) == ["one", "two", "three"]


def test_load_snark_lines_strips_blank_lines(tmp_path):
    p = tmp_path / "lines.txt"
    p.write_text("one\n\n  \ntwo\n")
    assert snark.load_snark_lines(str(p)) == ["one", "two"]


def test_load_snark_lines_missing_path_returns_default():
    assert snark.load_snark_lines(None) == [snark.DEFAULT_LINE]


def test_load_snark_lines_nonexistent_file_returns_default(tmp_path):
    missing = tmp_path / "does-not-exist.txt"
    assert snark.load_snark_lines(str(missing)) == [snark.DEFAULT_LINE]


def test_load_snark_lines_empty_file_returns_default(tmp_path):
    p = tmp_path / "lines.txt"
    p.write_text("")
    assert snark.load_snark_lines(str(p)) == [snark.DEFAULT_LINE]


def test_pick_snark_line_returns_one_of_the_lines(tmp_path):
    p = tmp_path / "lines.txt"
    p.write_text("one\ntwo\nthree\n")
    for _ in range(20):
        assert snark.pick_snark_line(str(p)) in ("one", "two", "three")


def test_pick_snark_line_reads_env_var_when_no_path_given(tmp_path, monkeypatch):
    p = tmp_path / "lines.txt"
    p.write_text("only-line\n")
    monkeypatch.setenv(snark.ENV_VAR, str(p))
    assert snark.pick_snark_line() == "only-line"
