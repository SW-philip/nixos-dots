#!/usr/bin/env python3
"""Quantum Clock v4 — waybar custom module, streaming.

Modes: moon (default) · progress · natural · caliper · binary.
Modes latch until cycled back to moon; the hourly surprise fires from the
default mode only. Lunar phase: synodic reference-epoch method.

  quantum_clock.py stream   one JSON line per second (waybar exec)
  quantum_clock.py [show]   print one JSON line
  quantum_clock.py next     cycle mode      quantum_clock.py toggle  flip 12/24h
  quantum_clock.py lock     natural-language time (hyprlock)

State lives in ~/.cache/quantum_clock/{mode,24h}; the 24h file is also read by
hyprlock and the greeter, so keep its format ("0"/"1").
"""
from __future__ import annotations

import json
import math
import os
import random
import signal
import sys
import time
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from waybar_palette import Palette

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "quantum_clock"
MODE_FILE = CACHE_DIR / "mode"
H24_FILE = CACHE_DIR / "24h"

CLOCK_DEFAULT = "moon"
CLOCK_MODES = ["moon", "progress", "natural", "caliper", "binary"]
SURPRISE_SECS = 5

SYNODIC = 29.530588853
REF_NEW_JD = 2451550.259  # 2000-01-06 18:14 UTC

MOON_NAMES = ["New Moon", "Waxing Crescent", "First Quarter", "Waxing Gibbous",
              "Full Moon", "Waning Gibbous", "Last Quarter", "Waning Crescent"]
MOON_GLYPHS = ["󰽤", "󰽧", "󰽡", "󰽨", "󰽢", "󰽦", "󰽣", "󰽥"]

# Time-of-day arc (16 stops, 90 min apart): night->dawn->day->dusk->night.
# progress and binary both tint themselves from it via day_color().
HOUR_COLORS_HEX = [
    "0d1b2a", "1b2838", "2d1b69", "1d4ed8",
    "ea580c", "f59e0b", "22c55e", "14b8a6",
    "e0f2fe", "fde68a", "f97316", "ef4444",
    "ec4899", "f43f5e", "4f46e5", "1d4ed8",
]

AM_OBJECTS = ["A mote of dust", "A grain of pollen", "A poppy seed", "A sesame seed",
              "A lentil", "A green pea", "A blueberry", "A cherry", "A walnut",
              "A lime", "An orange", "A grapefruit", "A pomelo"]
PM_OBJECTS = ["A shadow", "A BB pellet", "A marble", "A film canister", "A golf ball",
              "A billiard ball", "A tennis ball", "A baseball", "A softball",
              "A bocce ball", "A grapefruit", "A cantaloupe", "A basketball"]

HOUR_NAMES = ["midnight", "one", "two", "three", "four", "five",
              "six", "seven", "eight", "nine", "ten", "eleven",
              "noon", "one", "two", "three", "four", "five",
              "six", "seven", "eight", "nine", "ten", "eleven"]
PAST_WORDS = ["", "five past", "ten past", "quarter past",
              "twenty past", "twenty-five past", "half past"]
TO_WORDS = ["", "five to", "ten to", "quarter to", "twenty to", "twenty-five to"]


# ── State ─────────────────────────────────────────────────────

def read_text(path: Path, default: str) -> str:
    try:
        return path.read_text().strip() or default
    except OSError:
        return default


def write_text(path: Path, value: str) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(value + "\n")


def current_mode() -> str:
    return read_text(MODE_FILE, CLOCK_DEFAULT)


def next_mode() -> None:
    cur = current_mode()
    i = CLOCK_MODES.index(cur) if cur in CLOCK_MODES else -1
    write_text(MODE_FILE, CLOCK_MODES[(i + 1) % len(CLOCK_MODES)])


def toggle_24h() -> None:
    write_text(H24_FILE, "0" if read_text(H24_FILE, "0") == "1" else "1")


# ── Time ──────────────────────────────────────────────────────

def now_dt(ep: float | None = None) -> datetime:
    ep = time.time() if ep is None else ep
    tz = os.environ.get("CLOCK_TZ")
    return datetime.fromtimestamp(ep, ZoneInfo(tz) if tz else None)


def fmt(dt: datetime, h24: bool, seconds: bool = False) -> str:
    if h24:
        return dt.strftime("%H:%M:%S" if seconds else "%H:%M")
    return dt.strftime("%-I:%M:%S %p" if seconds else "%-I:%M %p")


def span(color: str, text: str, q: str = '"') -> str:
    return f"<span foreground={q}{color}{q}>{text}</span>"


# ── Lunar ─────────────────────────────────────────────────────

def lunar(ep: float):
    """-> (glyph, name, illum%, days_to_full, days_to_new)"""
    jd = ep / 86400.0 + 2440587.5
    frac = ((jd - REF_NEW_JD) / SYNODIC) % 1.0
    phase_days = frac * SYNODIC
    illum = int((1 - math.cos(frac * 2 * math.pi)) / 2 * 100 + 0.5)
    idx = int(frac * 8 + 0.5) % 8
    to_full = SYNODIC / 2 - phase_days
    if to_full < 0:
        to_full += SYNODIC
    return (MOON_GLYPHS[idx], MOON_NAMES[idx], illum,
            f"{to_full:.0f}", f"{SYNODIC - phase_days:.0f}")


# ── Time-of-day color ─────────────────────────────────────────

def hex_fields(h: int, m: int, s: int):
    """day = 4096 ticks (~21s): (hexhour, hexminute, hexsecond), shown in tooltips"""
    tick = (h * 3600 + m * 60 + s) * 4096 // 86400
    return tick // 256, (tick // 16) % 16, tick % 16


def lerp_rgb(a: str, b: str, blend: int) -> str:
    ca = [int(a[i:i + 2], 16) for i in (0, 2, 4)]
    cb = [int(b[i:i + 2], 16) for i in (0, 2, 4)]
    return "".join(f"{(x * (1000 - blend) + y * blend) // 1000:02x}" for x, y in zip(ca, cb))


def day_color(secs: int, p) -> str:
    """arc color at `secs` into the day, lifted 30% toward SCORE so the near-black
    night stops stay visible on a dark bar"""
    pos = secs * 16 * 1000 // 86400
    i, blend = pos // 1000, pos % 1000
    arc = lerp_rgb(HOUR_COLORS_HEX[i % 16], HOUR_COLORS_HEX[(i + 1) % 16], blend)
    return "#" + lerp_rgb(arc, p["SCORE"].lstrip("#"), 300)


# ── Other faces ───────────────────────────────────────────────

def render_progress(dt: datetime, h24: bool, p) -> str:
    secs = dt.hour * 3600 + dt.minute * 60 + dt.second
    filled = secs * 10 // 86400
    # each filled block carries the arc color of the time it stands for
    bar = "".join(span(day_color((i * 2 + 1) * 86400 // 20, p), "█") for i in range(filled))
    bar += span(p["BAR"], "░") * (10 - filled)
    return f'{bar} {span(day_color(secs, p), f"{secs * 100 // 86400}%")}  {fmt(dt, h24)}'


def render_caliper(dt: datetime, h24: bool, p) -> str:
    is_pm = dt.hour >= 12
    h12_secs = (dt.hour % 12) * 3600 + dt.minute * 60 + dt.second
    # 80 positions across 12h: a full ━ every ~9 min, fractional tip every ~67 s
    arm_x8 = (43200 - h12_secs if is_pm else h12_secs) * 80 // 43200
    arm_len, tip_idx = arm_x8 // 8, arm_x8 % 8
    level = 12 - dt.hour % 12 if is_pm else dt.hour % 12
    obj = (PM_OBJECTS if is_pm else AM_OBJECTS)[level]

    # the tip brightens toward the top of each hour
    tip_color = (p["FIFTH"], p["SOTTO"], p["SEVENTH"], p["SCORE"])[dt.minute // 15]
    arm = span(p["FIFTH"], "━") * arm_len
    tip = span(tip_color, "▏▎▍▌▋▊▉"[tip_idx - 1]) if tip_idx else ""
    left, right = span(p["REST"], "┤"), span(p["REST"], "├")
    if arm_len or tip_idx:
        jaw = f'{arm}{tip}{left} {span(p["SOTTO"], obj)} {right}{tip}{arm}'
    else:
        jaw = f'{left}{span(p["SOTTO"], obj)}{right}'
    return f"{jaw}  {fmt(dt, h24)}"


def natural(dt: datetime) -> str:
    h, r = dt.hour, (dt.minute + 2) // 5 * 5
    if r == 60:
        r, h = 0, (h + 1) % 24
    if r == 0:
        return HOUR_NAMES[h] if h in (0, 12) else f"{HOUR_NAMES[h]} o'clock"
    if r <= 30:
        return f"{PAST_WORDS[r // 5]} {HOUR_NAMES[h]}"
    return f"{TO_WORDS[(60 - r) // 5]} {HOUR_NAMES[(h + 1) % 24]}"


def bcd_bits(dt: datetime):
    """rows of bit weights 8,4,2,1 x 6 digits of HHMMSS"""
    digits = [int(c) for c in dt.strftime("%H%M%S")]
    return digits


def render_binary(dt: datetime, p) -> str:
    lit = day_color(dt.hour * 3600 + dt.minute * 60 + dt.second, p)
    panel = ""
    for i, d in enumerate(bcd_bits(dt)):
        panel += "".join(span(lit, "█") if d & bit else span(p["BAR"], "░")
                         for bit in (8, 4, 2, 1))
        if i in (1, 3):
            panel += f' {span(p["REST"], ":")} '
        elif i < 5:
            panel += " "
    return panel


def binary_grid(dt: datetime, p) -> str:
    lit = day_color(dt.hour * 3600 + dt.minute * 60 + dt.second, p)
    digits = bcd_bits(dt)
    rows = []
    for bit in (8, 4, 2, 1):
        row = ""
        for i, d in enumerate(digits):
            row += span(lit, "█") if d & bit else span(p["BAR"], "░")
            row += "  " if i in (1, 3) else " " if i < 5 else ""
        rows.append(row)
    return "\n".join(rows)


# ── Tooltip + frame ───────────────────────────────────────────

def tooltip_base(dt: datetime, h24: bool, p) -> str:
    year = dt.year
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    dow = dt.isoweekday()  # 1=Mon … 7=Sun
    q = lambda color, t: span(color, t, "'")  # noqa: E731
    weekend = ""
    if dow <= 4:
        n = 5 - dow
        weekend = "\n" + q(p["PIANO"], f"{n} day{'s' if n > 1 else ''} until the weekend")
    elif dow == 5:
        weekend = "\n" + q(p["ROOT"], "weekend starts tomorrow")
    return (f"{q(p['REST'], dt.strftime('%A'))}, {q(p['SCORE'], dt.strftime('%-d %B %Y'))}\n"
            f"{q(p['REST'], 'Week %d · Day %d of %d' % (dt.isocalendar()[1], dt.timetuple().tm_yday, 366 if leap else 365))}"
            f"{weekend}\n{q(p['FIFTH'], fmt(dt, h24, seconds=True))}")


def render(ep: float, mode: str, p) -> dict:
    dt = now_dt(ep)
    h24 = read_text(H24_FILE, "0") == "1"
    base = tooltip_base(dt, h24, p)
    q = lambda color, t: span(color, t, "'")  # noqa: E731

    if mode == "moon":
        glyph, name, illum, to_full, to_new = lunar(ep)
        illum_color = (p["BAR"] if illum < 25 else p["REST"] if illum < 50
                       else p["FIFTH"] if illum < 75 else p["PIANO"])
        text = f'{span(p["ROOT"], glyph)} {fmt(dt, h24)}'
        tip = (f"{q(p['ROOT'], name)} · {q(illum_color, f'{illum}%')} illuminated\n"
               f"{q(p['FIFTH'], f'{to_full}d')} {q(p['REST'], 'to full moon')}  ·  "
               f"{q(p['REST'], f'{to_new}d to new moon')}\n\n{base}")
    elif mode == "progress":
        hh, mm, ss = hex_fields(dt.hour, dt.minute, dt.second)
        text = render_progress(dt, h24, p)
        tip = (f"{q(p['FIFTH'], 'Day progress')} · {q(p['REST'], 'hex')} "
               f"{q(p['ROOT'], f'{hh:X}')}{q(p['REST'], '.')}{q(p['PIANO'], f'{mm:X}')}"
               f"{q(p['REST'], '.')}{q(p['SOTTO'], f'{ss:X}')}\n\n{base}")
    elif mode == "natural":
        text, tip = span(p["REST"], natural(dt)), f"{q(p['REST'], 'Natural time')}\n\n{base}"
    elif mode == "caliper":
        text, tip = render_caliper(dt, h24, p), f"{q(p['SOTTO'], 'Caliper clock')}\n\n{base}"
    elif mode == "binary":
        text = render_binary(dt, p)
        tip = (f"{q(p['FIFTH'], 'Binary clock (BCD)')} · {q(p['REST'], 'bit weights 8 4 2 1')}\n"
               f"{binary_grid(dt, p)}\n\n{base}")
    else:
        text, tip = fmt(dt, h24), base
    return {"text": text, "tooltip": tip, "class": mode}


# ── Commands ──────────────────────────────────────────────────

def emit(frame: dict) -> None:
    sys.stdout.write(json.dumps(frame, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def stream() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    palette = Palette()
    surprise_mode, surprise_until, last_stamp = None, 0.0, ""
    while True:
        ep = time.time()
        mode = current_mode()
        if mode == CLOCK_DEFAULT:
            dt = now_dt(ep)
            stamp = dt.strftime("%Y%m%d%H")
            # once per hour, flash a random non-default face for a few seconds
            if dt.minute == 0 and dt.second < SURPRISE_SECS and stamp != last_stamp:
                last_stamp = stamp
                surprise_mode = random.choice([m for m in CLOCK_MODES if m != CLOCK_DEFAULT])
                surprise_until = ep + SURPRISE_SECS
            if surprise_mode and ep < surprise_until:
                mode = surprise_mode
        try:
            emit(render(ep, mode, palette.get()))
        except OSError as e:
            print(f"quantum-clock: palette: {e}", file=sys.stderr)
        time.sleep(1.0 - time.time() % 1.0 + 0.005)


def main(argv: list[str]) -> int:
    cmd = argv[1] if len(argv) > 1 else "show"
    if cmd == "stream":
        try:
            return stream()
        except BrokenPipeError:
            return 0
    if cmd == "next":
        next_mode()
    elif cmd == "toggle":
        toggle_24h()
    elif cmd == "lock":
        print(natural(now_dt()))
    elif cmd in ("help", "-h", "--help"):
        print(__doc__)
    else:
        emit(render(time.time(), current_mode(), Palette().get()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
