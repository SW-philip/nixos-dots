from greeter import colors


def test_hex_rgb_roundtrip():
    assert colors.hex_to_rgb("#ca2541") == (202, 37, 65)
    assert colors.rgb_to_hex((202, 37, 65)) == "#ca2541"


def test_short_hex_expands():
    assert colors.hex_to_rgb("#fff") == (255, 255, 255)


def test_lightness_ordering():
    light_neutral = "#b8b9b1"  # earl-grey base
    dark_wine = "#3c1021"      # squid base
    assert colors.lightness(light_neutral) > colors.lightness(dark_wine)


def test_mix_endpoints_and_midpoint():
    assert colors.mix("#000000", "#ffffff", 0.0) == "#000000"
    assert colors.mix("#000000", "#ffffff", 1.0) == "#ffffff"
    assert colors.mix("#000000", "#ffffff", 0.5) == "#808080"


def test_css_rgba():
    assert colors.css_rgba("#ca2541", 0.55) == "rgba(202,37,65,0.55)"
    assert colors.css_rgba("#fff", 1) == "rgba(255,255,255,1)"


def test_set_lightness_keeping_hue():
    out = colors.set_lightness_keeping_hue("#b8b9b1", 0.12)
    # lightness is pinned near the target, not just "somewhere dark"
    assert abs(colors.lightness(out) - 0.12) < 0.03
    # hue/saturation preserved -> not collapsed to pure black
    assert out != "#000000"
