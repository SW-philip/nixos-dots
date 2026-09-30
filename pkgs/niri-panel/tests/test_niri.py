import json
from niri_panel import niri

SAMPLE = {
    "eDP-1": {
        "name": "eDP-1", "make": "LG Display", "model": "0x0555", "serial": "0x000492A0",
        "modes": [{"width": 2736, "height": 1824, "refresh_rate": 59959, "is_preferred": True}],
        "current_mode": 0, "is_custom_mode": False,
        "vrr_supported": True, "vrr_enabled": False,
        "logical": {"x": 0, "y": 0, "width": 1368, "height": 912, "scale": 2.0, "transform": "Normal"},
    },
    "DP-2": {
        "name": "DP-2", "make": "Dell", "model": "U2412M", "serial": "ABC123",
        "modes": [
            {"width": 1920, "height": 1080, "refresh_rate": 60000, "is_preferred": True},
            {"width": 1280, "height": 1024, "refresh_rate": 75000, "is_preferred": False},
        ],
        "current_mode": None, "is_custom_mode": False,
        "vrr_supported": False, "vrr_enabled": False,
        "logical": None,
    },
}

def test_parse_basic_fields():
    outs = niri.parse_outputs(SAMPLE)
    e = outs["eDP-1"]
    assert e.description == "LG Display 0x0555 0x000492A0"
    assert e.enabled is True
    assert e.scale == 2.0
    assert e.transform == "Normal"
    assert e.vrr_supported is True and e.vrr_enabled is False
    assert e.pos == (0, 0)
    assert e.current_mode_idx == 0

def test_parse_disabled_output():
    outs = niri.parse_outputs(SAMPLE)
    d = outs["DP-2"]
    assert d.enabled is False
    assert d.pos is None
    assert d.current_mode_idx is None
    assert len(d.modes) == 2

def test_mode_str():
    outs = niri.parse_outputs(SAMPLE)
    assert niri.mode_str(outs["eDP-1"].modes[0]) == "2736x1824@59.959"
    assert niri.mode_str(outs["DP-2"].modes[0]) == "1920x1080@60.000"

def test_output_argv():
    assert niri.output_argv("DP-2", "mode", "1920x1080@60.000") == \
        ["niri", "msg", "output", "DP-2", "mode", "1920x1080@60.000"]
    assert niri.output_argv("DP-2", "off") == ["niri", "msg", "output", "DP-2", "off"]
    assert niri.output_argv("DP-2", "position", "x=1920", "y=0") == \
        ["niri", "msg", "output", "DP-2", "position", "x=1920", "y=0"]

def test_relative_position():
    # anchor at origin, 1920x1080; moving output 1280x1024
    assert niri.relative_position((0, 0), (1920, 1080), (1280, 1024), "right") == (1920, 0)
    assert niri.relative_position((0, 0), (1920, 1080), (1280, 1024), "left") == (-1280, 0)
    assert niri.relative_position((0, 0), (1920, 1080), (1280, 1024), "above") == (0, -1024)
    assert niri.relative_position((0, 0), (1920, 1080), (1280, 1024), "below") == (0, 1080)
