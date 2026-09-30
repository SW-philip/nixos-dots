from greeter import colors
from greeter.palette import Palette, load_dsa, load_theme, parse_sh

EARL_GREY = {
    "HALL": "#393b3e", "STAGE": "#4d5358", "SCORE": "#ffffff",
    "REST": "#888888", "FORTE": "#8f86a3", "PIANO": "#b3ada7",
}


def test_parse_sh_strips_export_and_quotes():
    d = parse_sh('export HALL="#393b3e"\nSTAGE="#4d5358"\n# c\n\n')
    assert d["HALL"] == "#393b3e"
    assert d["STAGE"] == "#4d5358"
    assert "#" not in d


def test_load_theme_maps_musical_keys(tmp_path):
    f = tmp_path / "palette.sh"
    f.write_text("\n".join(f'export {k}="{v}"' for k, v in EARL_GREY.items()))
    p = load_theme(f)
    assert p.ground == "#393b3e"
    assert p.ink == "#ffffff"
    assert p.field == "#4d5358"
    assert p.field_ink == "#ffffff"
    assert p.clock == "#8f86a3"
    assert p.date == "#888888"
    assert p.ok == "#b3ada7"
    assert p.fail == "#8f86a3"
    assert p.outline == colors.mix("#ffffff", "#393b3e", 0.45)


def test_load_theme_missing_file_uses_fallback():
    p = load_theme("/no/such/palette.sh")
    # fallback-palette.sh: SCORE=#f0f0f0
    assert p.ink == "#f0f0f0"
    assert isinstance(p, Palette)


def test_load_dsa_is_the_dark_preset():
    p = load_dsa()
    assert p.ground == "#211c1c"
    assert p.ink == "#f0e9d8"
    assert p.field_ink == "#f0e9d8"
    assert p.clock == "#a8451f"
    assert p.outline == "#a8451f"
    assert p.ok == "#8fb573"


def test_load_dsa_is_deterministic():
    assert load_dsa() == load_dsa()
