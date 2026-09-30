#!/usr/bin/env python3
"""Emit home/eww/colors.scss for one theme.

A fixed REST/FIFTH bar pair goes invisible on the palettes where
harmonize_accents_by_rank collapses the accents (moss-violet, onyx-mauve,
slate-lavender, ...). Pick both bar ends per theme by CIE76 ΔE instead:
the normal bar must stand off the .section card fill it actually renders
on ($module-bg/STAGE), the alert bar must stand off that fill AND the
normal bar.

$crit doubles as the ≥85 °C readout *text* on the .section card fill
($module-bg), sitting beside .readout ($fg = SCORE) and .readout.warn
($warn = PIANO). The bar-fill pick alone never checks it against
SCORE/PIANO, so $crit gets its own pick — restricted to hot_pool members
already visible as a bar — that maximises distance from both
neighbouring readout colours.

$bg is WING passed straight through, unprocessed — the shell/container
tone (.panel, .ledger-bar). $module-bg is STAGE passed
straight through — the recessed chip/card tone (.chip, .section). This
mirrors waybar's own .module fill (home/waybar/style.nix): container in
WING, chip cut into it in STAGE, tolerating STAGE/WING closeness via
hairline/hover rather than picking for guaranteed distinctness.
"""
import sys

from colormath import delta_e_cie76

DE_MIN = 25.0  # this repo's CIE76 distinctness bar (CLAUDE.md)


def pick(bg, rest, norm_pool, hot_pool, score_ink, piano):
    norm = rest if delta_e_cie76(rest, bg) >= DE_MIN else max(
        norm_pool, key=lambda t: delta_e_cie76(t, bg)
    )
    hot = max(hot_pool, key=lambda t: min(delta_e_cie76(t, bg), delta_e_cie76(t, norm)))
    score = min(delta_e_cie76(hot, bg), delta_e_cie76(hot, norm))

    # $crit as readout text: pick among hot_pool members that already clear the
    # bar objective, then maximise distance from BOTH normal ($fg/SCORE) and
    # warn ($warn/PIANO) readout text. Fall back to the bar fill on a palette so
    # monochrome that nothing clears.
    bar_visible = [
        t for t in hot_pool
        if min(delta_e_cie76(t, bg), delta_e_cie76(t, norm)) >= DE_MIN
    ]
    if bar_visible:
        crit = max(
            bar_visible,
            key=lambda t: min(delta_e_cie76(t, score_ink), delta_e_cie76(t, piano)),
        )
    else:
        crit = hot
    return norm, hot, score, crit


def main(argv):
    if len(argv) != 16:
        sys.exit("emit_colors: expected 15 args, got %d" % (len(argv) - 1))
    (stage, score_ink, rest, lyric, mute, sotto,
     fifth, fermata, piano, seventh, forte, root, staff, wing, staff_a_drop) = argv[1:16]

    bar_norm, bar_hot, de, crit = pick(
        stage, rest,
        norm_pool=[lyric, mute, sotto, score_ink],
        hot_pool=[fifth, fermata, piano, seventh, forte, root],
        score_ink=score_ink, piano=piano,
    )

    checks = [
        ("bar-hot vs bg/bar-norm", de),
        ("bar-norm vs bg", delta_e_cie76(bar_norm, stage)),
        ("crit vs fg/SCORE", delta_e_cie76(crit, score_ink)),
        ("crit vs warn/PIANO", delta_e_cie76(crit, piano)),
    ]
    warn = ""
    for label, d in checks:
        if d < DE_MIN:
            warn += f"// WARNING: {label} ΔE is {d:.1f} (< {DE_MIN}) on this palette\n"
            sys.stderr.write(f"emit_colors: {label} ΔE {d:.1f} < {DE_MIN} (bg {stage})\n")

    sys.stdout.write(
        warn
        + f"$bg:       {wing};\n"
        + f"$bg-edge:  {fifth};\n"
        + f"$fg:       {score_ink};\n"
        + f"$dim:      {rest};\n"
        + f"$accent:   {fifth};\n"
        + f"$warn:     {piano};\n"
        + f"$crit:     {crit};\n"
        + f"$hairline: rgba({score_ink}, 0.15);\n"
        + f"$thread:   rgba({score_ink}, 0.55);\n"
        + f"$shadow:   rgba({staff}, {staff_a_drop});\n"
        + f"$bar-norm: {bar_norm};\n"
        + f"$bar-hot:  {bar_hot};\n"
        + f"$module-bg: {stage};\n"
    )


if __name__ == "__main__":
    main(sys.argv)
