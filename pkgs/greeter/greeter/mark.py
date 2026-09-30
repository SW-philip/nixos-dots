"""nix-flake mark recolour — deliberately gi-free (like colors.py / snark.py /
clock.py) so it unit-tests without a GTK / typelib environment. app.py's
_nix_mark_path does the file IO and calls tint_svg."""
from __future__ import annotations

# The source SVG (assets/nix/nix-flake.svg) has two lambda fills and a black
# outline stroke — see the file. Uppercase hex, matched literally.
_FILL_LIGHT = "#7EBAE4"
_FILL_DARK = "#5277C3"
_BLACK_STROKE = 'stroke="#000000"'


def tint_svg(svg: str, ink: str) -> str:
    """Both lambda fills -> `ink`; the black outline stroke -> none. Returns a
    flat single-ink silhouette. A string with none of those tokens is returned
    unchanged."""
    return (svg.replace(_FILL_LIGHT, ink)
               .replace(_FILL_DARK, ink)
               .replace(_BLACK_STROKE, 'stroke="none"'))
