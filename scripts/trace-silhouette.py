#!/usr/bin/env python3
"""
One-time offline tool: trace an asset SVG's true outer silhouette (including
any holes) into a clean vector path, flattened into the asset's own native
viewBox coordinate system.

Usage:
    python3 scripts/trace-silhouette.py <asset.svg> <output-silhouette.svg> [resolution]

Only needs to be re-run if the source asset SVG is redrawn. Depends on
resvg, imagemagick (`magick`), and potrace (invoked via `nix-shell -p
potrace`) being available.
"""
import re
import subprocess
import sys

TOKEN_RE = re.compile(r'[MmLlHhVvCcSsQqTtZz]|-?\d*\.?\d+(?:[eE][-+]?\d+)?')
COORDS_PER_CMD = {'M': 2, 'L': 2, 'T': 2, 'S': 4, 'Q': 4, 'C': 6, 'H': 1, 'V': 1, 'Z': 0}


def transform_path_d(d, sx, sy, tx, ty):
    """Apply a pure scale+translate affine transform to an SVG path's `d`
    string, handling M/L/H/V/C/S/Q/T/Z (potrace never emits arcs, so A/a is
    not needed). Absolute commands get translated; relative commands only
    get scaled (deltas shouldn't be translated)."""
    tokens = TOKEN_RE.findall(d)
    out = []
    i = 0
    cmd = None
    while i < len(tokens):
        tok = tokens[i]
        if tok.isalpha():
            cmd = tok
            out.append(cmd)
            i += 1
            continue
        upper = cmd.upper()
        n = COORDS_PER_CMD[upper]
        if n == 0:
            i += 1
            continue
        nums = [float(tokens[i + k]) for k in range(n)]
        i += n
        is_rel = cmd.islower()
        transformed = []
        if upper == 'H':
            transformed = [nums[0] * sx + (0 if is_rel else tx)]
        elif upper == 'V':
            transformed = [nums[0] * sy + (0 if is_rel else ty)]
        else:
            for k in range(0, n, 2):
                x, y = nums[k], nums[k + 1]
                nx = x * sx + (0 if is_rel else tx)
                ny = y * sy + (0 if is_rel else ty)
                transformed += [nx, ny]
        out.append(' '.join(f'{v:.4f}' for v in transformed))
    return ' '.join(out)


def _update_bbox(bbox, x, y):
    minx, miny, maxx, maxy = bbox
    if minx is None:
        return (x, y, x, y)
    return (min(minx, x), min(miny, y), max(maxx, x), max(maxy, y))


def filter_noise_subpaths(d, threshold=0.03):
    """Split a potrace path `d` string into its constituent subpaths (each
    starting at an M/m), compute each subpath's bounding box in potrace's
    own raw (absolute) coordinate units, and drop any subpath whose
    bounding-box max dimension is under `threshold` of the overall traced
    shape's bounding-box max dimension.

    This filters out tiny decorative noise (e.g. a handful of stray
    sub-2-unit "sparkle" subpaths traced from tiny decorative source
    shapes) that would otherwise render as unwanted dots once a
    downstream renderer strokes the whole silhouette with a large
    border width. A regex split alone can't give correct absolute
    per-subpath bounding boxes for subpaths that use relative commands,
    so this walks the path commands tracking the current absolute
    (x, y) position, mirroring transform_path_d's tokenizer.

    Each kept subpath's leading M/m token is rewritten as an absolute
    `M x y` using the anchor point this walker computed for it (rather
    than preserved verbatim). A relative `m dx dy` is only correct
    relative to wherever the PREVIOUS subpath left the current point;
    if that previous subpath gets dropped (or, per spec, after a Z
    closepath — which resets the current point back to the subpath's
    own start, not wherever the last segment ended), the original
    relative delta would silently resolve to the wrong absolute
    position. Every other command in a kept subpath is left exactly as
    written, since only whole subpaths are ever dropped, never partial.

    Returns (filtered_d, dropped_count).
    """
    tokens = TOKEN_RE.findall(d)
    subpaths = []  # list of {'tokens': [...], 'bbox': (minx, miny, maxx, maxy)}
    cur_tokens = None
    cur_bbox = (None, None, None, None)
    curx = cury = 0.0
    subpath_start_x = subpath_start_y = 0.0
    anchor_pending = False  # True while the next chunk is this subpath's leading M
    cmd = None
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok.isalpha():
            cmd = tok
            if cmd.upper() == 'M':
                if cur_tokens is not None:
                    subpaths.append({'tokens': cur_tokens, 'bbox': cur_bbox})
                cur_tokens = [cmd]
                cur_bbox = (None, None, None, None)
                anchor_pending = True
            elif cmd.upper() == 'Z':
                cur_tokens.append(cmd)
                # Closepath returns the current point to this subpath's own
                # start, not wherever the last segment happened to end.
                curx, cury = subpath_start_x, subpath_start_y
            else:
                cur_tokens.append(cmd)
            i += 1
            continue
        upper = cmd.upper()
        n = COORDS_PER_CMD[upper]
        if n == 0:
            i += 1
            continue
        nums = [float(tokens[i + k]) for k in range(n)]
        raw_toks = tokens[i:i + n]
        i += n
        is_rel = cmd.islower()
        base_x, base_y = curx, cury
        if upper == 'H':
            nx, ny = (base_x + nums[0] if is_rel else nums[0]), cury
            cur_bbox = _update_bbox(cur_bbox, nx, ny)
            curx, cury = nx, ny
            cur_tokens.extend(raw_toks)
        elif upper == 'V':
            nx, ny = curx, (base_y + nums[0] if is_rel else nums[0])
            cur_bbox = _update_bbox(cur_bbox, nx, ny)
            curx, cury = nx, ny
            cur_tokens.extend(raw_toks)
        else:
            last = None
            for k in range(0, n, 2):
                x, y = nums[k], nums[k + 1]
                px = base_x + x if is_rel else x
                py = base_y + y if is_rel else y
                cur_bbox = _update_bbox(cur_bbox, px, py)
                last = (px, py)
            curx, cury = last
            if anchor_pending:
                # This is the subpath's leading M/m chunk: rewrite as an
                # absolute anchor rather than preserving the raw tokens, so
                # reconstruction is correct regardless of what precedes it.
                cur_tokens[-1] = 'M'
                cur_tokens.append(f'{curx:.6f}')
                cur_tokens.append(f'{cury:.6f}')
                subpath_start_x, subpath_start_y = curx, cury
                anchor_pending = False
                if i < len(tokens) and not tokens[i].isalpha():
                    # A moveto followed by another bare coordinate pair (no
                    # intervening command letter) is an implicit lineto that
                    # inherits its relative/absolute-ness from the ORIGINAL
                    # moveto letter. We've just forcibly rewritten that
                    # letter to absolute 'M', so a trailing bare pair would
                    # be silently re-interpreted under the wrong sense.
                    # potrace's actual output never emits this (verified
                    # against every asset this tool has traced), so fail
                    # loudly instead of risking silent wrong geometry.
                    sys.exit(
                        "❌ filter_noise_subpaths: unsupported "
                        "multi-vertex moveto in traced path — this "
                        "pattern isn't handled; if potrace's output changed "
                        "to produce this, the filter needs updating"
                    )
            else:
                cur_tokens.extend(raw_toks)
    if cur_tokens is not None:
        subpaths.append({'tokens': cur_tokens, 'bbox': cur_bbox})

    valid_bboxes = [sp['bbox'] for sp in subpaths if sp['bbox'][0] is not None]
    overall_minx = min(b[0] for b in valid_bboxes)
    overall_miny = min(b[1] for b in valid_bboxes)
    overall_maxx = max(b[2] for b in valid_bboxes)
    overall_maxy = max(b[3] for b in valid_bboxes)
    overall_max_dim = max(overall_maxx - overall_minx, overall_maxy - overall_miny)

    kept = []
    dropped = 0
    for sp in subpaths:
        minx, miny, maxx, maxy = sp['bbox']
        dim = max(maxx - minx, maxy - miny) if minx is not None else 0.0
        if overall_max_dim > 0 and dim < threshold * overall_max_dim:
            dropped += 1
            continue
        kept.append(sp)

    filtered_d = ' '.join(' '.join(sp['tokens']) for sp in kept)
    return filtered_d, dropped


def get_native_viewbox(svg):
    m = re.search(r'viewBox=["\']([^"\']+)["\']', svg)
    if m:
        vx, vy, vw, vh = map(float, m.group(1).split())
        return vx, vy, vw, vh
    wm = re.search(r'width=["\']([\d.]+)["\']', svg)
    hm = re.search(r'height=["\']([\d.]+)["\']', svg)
    return 0.0, 0.0, float(wm.group(1)), float(hm.group(1))


def trace_asset(svg_path, out_path, res=2048):
    svg = open(svg_path).read()
    vx, vy, vw, vh = get_native_viewbox(svg)

    inner = re.sub(r'^.*?<svg[^>]*>', '', svg, count=1, flags=re.S)
    inner = re.sub(r'</svg>\s*$', '', inner, flags=re.S).strip()
    # Flatten every fill to solid black so resvg renders a plain silhouette.
    inner_black = re.sub(r'fill:#[0-9A-Fa-f]{3,6}', 'fill:#000000', inner)
    inner_black = re.sub(r'fill="#[0-9A-Fa-f]{3,6}"', 'fill="#000000"', inner_black)
    inner_black = re.sub(r"fill='#[0-9A-Fa-f]{3,6}'", "fill='#000000'", inner_black)

    render_scale = res / max(vw, vh)
    canvas_w, canvas_h = vw * render_scale, vh * render_scale

    base = out_path.rsplit('.', 1)[0]
    src_svg = f'{base}-src.svg'
    src_png = f'{base}-src.png'
    pbm = f'{base}.pbm'
    trace_svg = f'{base}-trace.svg'

    open(src_svg, 'w').write(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas_w:.1f}" '
        f'height="{canvas_h:.1f}" viewBox="{vx} {vy} {vw} {vh}">{inner_black}</svg>'
    )
    subprocess.run(['resvg', '--width', str(int(canvas_w)), '--height', str(int(canvas_h)),
                     src_svg, src_png], check=True)
    subprocess.run(['magick', src_png, '-alpha', 'extract', '-threshold', '50%',
                     '-negate', pbm], check=True)
    subprocess.run(['nix-shell', '-p', 'potrace', '--run',
                     f'potrace -s -o {trace_svg} --flat {pbm}'], check=True)

    traced = open(trace_svg).read()
    gm = re.search(
        r'<g transform="translate\(([-\d.]+),([-\d.]+)\) scale\(([-\d.]+),([-\d.]+)\)"[^>]*>\s*<path d="([^"]+)"',
        traced, flags=re.S)
    if not gm:
        sys.exit(f"❌ Could not find traced path in {trace_svg} — potrace output format unexpected")
    ptx, pty, psx, psy, path_d = gm.groups()
    ptx, pty, psx, psy = float(ptx), float(pty), float(psx), float(psy)

    path_d, dropped = filter_noise_subpaths(path_d)
    if dropped:
        print(f"  (dropped {dropped} sub-3% noise subpath(s))")

    # Compose potrace's own (translate then scale) with pixel->native-viewBox
    # scale (1/render_scale) into ONE flattened transform, so the final path
    # 'd' lives directly in the asset's own native viewBox units with no
    # wrapper <g transform> needed at render time. This matters: leaving the
    # transforms as nested <g> wrappers instead compounds into a large hidden
    # scale factor that shrinks stroke-width to sub-pixel at render time.
    sx = psx / render_scale
    sy = psy / render_scale
    tx = ptx / render_scale
    ty = pty / render_scale
    flat_d = transform_path_d(path_d, sx, sy, tx, ty)

    open(out_path, 'w').write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vx} {vy} {vw} {vh}">'
        f'<path id="silhouette" d="{flat_d}" fill-rule="evenodd"/></svg>'
    )
    print(f"Wrote {out_path} (native viewBox {vx} {vy} {vw} {vh})")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        sys.exit(f"Usage: {sys.argv[0]} <asset.svg> <output-silhouette.svg> [resolution]")
    trace_asset(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2048)
