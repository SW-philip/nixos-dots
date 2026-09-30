import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "emit_colors.py"
# emit_colors.py imports `colormath`; in the real build they're siblings.
# For the test, expose theme_lib's copy under that name.
ENV_PATH = str(HERE.parents[1] / "scripts" / "theme_lib")

# navy-teal: STAGE SCORE REST LYRIC MUTE SOTTO FIFTH FERMATA PIANO SEVENTH FORTE ROOT STAFF WING STAFF_A_DROP
NAVY_TEAL = ["#2a3d5b", "#eae9e9", "#ac93ad", "#cec6cb", "#313d63", "#c58c9a",
             "#6775b6", "#4683aa", "#c58c9a", "#b96fb9", "#46a1aa", "#46a1aa", "0,0,0",
             "#355779", "0.55"]

# Frightened-Rabbit/the-work: pre-fix its $crit (== $bar-hot == PIANO) sat 0.0 ΔE
# from $warn (also PIANO). The decoupled $crit pick must clear ΔE 25 vs both
# $fg (SCORE) and $warn (PIANO).
THE_WORK = ["#2c3b4c", "#eae9e9", "#a792a8", "#ccc5c9", "#333e54", "#e8cb91",
            "#637fc2", "#e2a887", "#e8cb91", "#e28d87", "#e28d87", "#c15190", "0,0,0",
            "#385569", "0.5"]

# Three palettes known to be colorimetrically tight (harmonize_accents_by_rank
# collapses their accent spread) — the chip-bg/chip-fg pick has to work here too.
MOSS_VIOLET = ["#5a9b69", "#f7f7f7", "#cdccc4", "#f7f7f7", "#65a07b", "#dce1f9",
               "#c8e7ce", "#c8e7d7", "#ebddd1", "#efdcfa", "#c8e7ce", "#c3e1e4", "22,50,24",
               "#6eb076", "0.6"]
ONYX_MAUVE = ["#181616", "#e6e6e6", "#8c8c8c", "#bfbfbf", "#1f1f1f", "#a8a8a8",
              "#978d8b", "#8a7870", "#978d8b", "#dbd8d7", "#8a7070", "#8a7070", "0,0,0",
              "#2e292a", "0.55"]
SLATE_LAVENDER = ["#4d5358", "#ffffff", "#888888", "#bfbfbf", "#56595e", "#d0c7d4",
                  "#a59a8c", "#9886a3", "#b3ada7", "#b7b2c0", "#8f86a3", "#8f86a3", "0,0,0",
                  "#5c6a71", "0.55"]


def run(args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True,
        env={"PYTHONPATH": ENV_PATH, "PATH": "/usr/bin:/bin"},
    )


def test_emits_all_vars():
    r = run(NAVY_TEAL)
    assert r.returncode == 0, r.stderr
    out = r.stdout
    for var in ("$bg:", "$bg-edge:", "$fg:", "$dim:", "$accent:", "$warn:",
                "$crit:", "$hairline:", "$thread:", "$shadow:", "$bar-norm:", "$bar-hot:",
                "$module-bg:"):
        assert var in out, f"missing {var}\n{out}"
    assert "$shadow:   rgba(0,0,0, 0.55);" in out
    assert "$hairline: rgba(#eae9e9, 0.15);" in out
    assert "$thread:   rgba(#eae9e9, 0.55);" in out


def test_bar_pick_is_distinct_on_navy_teal():
    import importlib
    import sys as _s
    _s.path.insert(0, ENV_PATH)
    de = importlib.import_module("colormath").delta_e_cie76
    out = dict(
        line.split(":", 1)[0].strip("$ ").strip()
        and (line.split(":", 1)[0].strip("$ ").strip(),
             line.split(":", 1)[1].strip().rstrip(";"))
        for line in run(NAVY_TEAL).stdout.splitlines() if ":" in line and line.startswith("$")
    )
    norm, hot, stage_bg = out["bar-norm"], out["bar-hot"], out["module-bg"]
    assert de(norm, stage_bg) >= 25
    assert de(hot, stage_bg) >= 25
    assert de(hot, norm) >= 25


def _emit_vars(tokens):
    return {
        line.split(":", 1)[0].strip("$ ").strip(): line.split(":", 1)[1].strip().rstrip(";")
        for line in run(tokens).stdout.splitlines()
        if line.startswith("$") and ":" in line
    }


def test_crit_is_decoupled_from_bar_hot_on_the_work():
    import importlib
    import sys as _s
    _s.path.insert(0, ENV_PATH)
    de = importlib.import_module("colormath").delta_e_cie76
    out = _emit_vars(THE_WORK)
    # $bar-hot stays the raw bar pick (PIANO); $crit is picked away from it.
    assert out["crit"] != out["bar-hot"]
    assert de(out["crit"], out["fg"]) >= 25, de(out["crit"], out["fg"])
    assert de(out["crit"], out["warn"]) >= 25, de(out["crit"], out["warn"])


def test_arg_count_guard():
    r = run(NAVY_TEAL + ["#000000"])  # 16 args (15 + 1 extra)
    assert r.returncode != 0
    assert "expected 15 args, got 16" in r.stderr


def test_monochrome_palette_warns_not_crashes():
    mono = ["#303030", "#e0e0e0", "#606060", "#707070", "#404040", "#505050",
            "#5a5a5a", "#5c5c5c", "#585858", "#565656", "#5a5a5a", "#5a5a5a", "0,0,0",
            "#5a5a5a", "0.55"]
    r = run(mono)
    assert r.returncode == 0
    assert "WARNING" in r.stdout or "WARNING" in r.stderr


def test_bg_and_module_bg_use_swapped_roles():
    out = _emit_vars(NAVY_TEAL)
    assert out["bg"] == "#355779"         # WING — shell/container tone
    assert out["module-bg"] == "#2a3d5b"  # STAGE — recessed chip/card tone


def test_shadow_threads_staff_a_drop_arg():
    out = _emit_vars(THE_WORK)
    assert out["shadow"] == "rgba(0,0,0, 0.5)"
