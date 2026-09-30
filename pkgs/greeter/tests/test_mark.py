from greeter.mark import tint_svg

_SRC = (
    '<svg><path fill="#7EBAE4" stroke="#000000" stroke-width="2"/>'
    '<path fill="#5277C3" stroke="#000000" stroke-width="2"/></svg>'
)


def test_both_fills_become_ink():
    out = tint_svg(_SRC, "#abcdef")
    assert "#7EBAE4" not in out
    assert "#5277C3" not in out
    assert out.count("#abcdef") == 2


def test_black_stroke_dropped():
    out = tint_svg(_SRC, "#abcdef")
    assert 'stroke="#000000"' not in out
    assert 'stroke="none"' in out


def test_no_matching_tokens_returns_unchanged():
    assert tint_svg("<svg><rect/></svg>", "#abcdef") == "<svg><rect/></svg>"
