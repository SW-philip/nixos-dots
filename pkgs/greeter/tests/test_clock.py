import time

from greeter import clock

NOON_ISH = time.struct_time((2026, 9, 3, 14, 7, 0, 3, 246, -1))  # Thu 2026-09-03 14:07


def test_clock_text_24h():
    assert clock.clock_text(now=NOON_ISH, twenty_four=True) == "14:07"


def test_clock_text_12h():
    assert clock.clock_text(now=NOON_ISH, twenty_four=False) == "2:07 PM"


def test_date_text():
    assert clock.date_text(now=NOON_ISH) == "Thursday, 03 September"


def test_is_24h_true(tmp_path):
    f = tmp_path / "24h"; f.write_text("1\n")
    assert clock.is_24h(f) is True


def test_is_24h_false_on_zero(tmp_path):
    f = tmp_path / "24h"; f.write_text("0")
    assert clock.is_24h(f) is False


def test_is_24h_false_on_missing(tmp_path):
    assert clock.is_24h(tmp_path / "nope") is False
