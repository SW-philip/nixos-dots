"""quivr front page: one card per host with sparklines, in a one- or two-column grid.
Design: docs/superpowers/specs/2026-11-01-quivr-host-health-design.md"""
import re
import threading
import time
from collections import deque

from quivr_view import bar, fmt_mem, fmt_rate, fmt_uptime, heat_text, norm

SPARK = "▁▂▃▄▅▆▇█"
SPARK_WIDTH = 16
HISTORY_LEN = 180  # ~3 minutes at the sampler's 1 s interval
NET_FLOOR = 10 * 1024  # bytes/s: idle chatter shouldn't fill the sparkline
CARD_WIDTH = 48
GRID_MIN_WIDTH = 100
GAP = "  "
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def mean(xs):
    return sum(xs) / len(xs)


def bucket(values, width, agg=max):
    """Shrink a series to `width` points by aggregating equal slices; shorter series pass through."""
    n = len(values)
    if n <= width:
        return list(values)
    out = []
    for i in range(width):
        part = [v for v in values[i * n // width:(i + 1) * n // width] if v is not None]
        out.append(agg(part) if part else None)
    return out


def sparkline(values, hi, c, width=SPARK_WIDTH, agg=max):
    vals = bucket(values, width, agg)
    cells = []
    for v in vals:
        if v is None:
            cells.append(f"{c.dim}·{c.rs}")
            continue
        pos = norm(v, 0, hi)
        cells.append(f"{c.heat(pos, attrs=False)}{SPARK[round(pos * (len(SPARK) - 1))]}")
    return " " * (width - len(vals)) + "".join(cells) + c.rs


class History:
    """Newest-last cpu and rx+tx series for one host; written by its feed thread, read by the UI.
    A None entry marks a break in the stream (reconnect)."""

    def __init__(self, maxlen=HISTORY_LEN):
        self.lock = threading.Lock()
        self.cpu = deque(maxlen=maxlen)
        self.net = deque(maxlen=maxlen)

    def push(self, s):
        with self.lock:
            self.cpu.append(s["cpu"])
            self.net.append(s["rx"] + s["tx"])

    def mark_gap(self):
        with self.lock:
            if self.cpu and self.cpu[-1] is not None:
                self.cpu.append(None)
                self.net.append(None)

    def snapshot(self):
        with self.lock:
            return {"cpu": list(self.cpu), "net": list(self.net)}


def vlen(s):
    return len(ANSI.sub("", s))


def pad(s, width):
    return s + " " * max(0, width - vlen(s))


def clip(text, width):
    return text if len(text) <= width else text[:width - 1] + "…"


def render_card(name, state, s, hist, c, selected=False):
    """Four lines, at most CARD_WIDTH visible characters each."""
    marker = f"{c.accent}▸{c.rs} " if selected else "  "
    if state != "up" or s is None:
        return [f"{marker}{c.dim}○ {clip(name, CARD_WIDTH - 4)}{c.rs}", f"  {c.dim}reconnecting…{c.rs}", "", ""]
    right = f"{c.dim}up {fmt_uptime(s['up'])}{c.rs}"
    shown = clip(name, CARD_WIDTH - 5 - vlen(right))
    label = f"{c.bold}{shown}{c.rs}" if selected else shown
    left = f"{marker}{c.accent}●{c.rs} {label}"
    head = left + " " * max(1, CARD_WIDTH - vlen(left) - vlen(right)) + right

    cpu_pct = heat_text(f"{s['cpu']:>3}%", s["cpu"] / 100, c)
    load = heat_text(f"{s['load']:>5.2f}", norm(s["load"] / s["cpus"], 0, 1), c)
    if s["temp"] is None:
        temp = f"{c.dim}{'—':>4}{c.rs}"
    else:
        temp = heat_text(f"{s['temp']:>3}°", norm(s["temp"], 30, 90), c)
    cpu_line = f"  cpu {sparkline(hist['cpu'], 100, c, agg=mean)} {cpu_pct}  load {load} {temp}"

    net_hi = max(NET_FLOOR, max((v for v in hist["net"] if v is not None), default=0))
    disk = heat_text(f"{s['disk']:>3}%", s["disk"] / 100, c)
    net_line = (f"  net {sparkline(hist['net'], net_hi, c)} "
                f"↓{fmt_rate(s['rx']):>5} ↑{fmt_rate(s['tx']):>5}  disk {disk}")

    mem_pct = 100 * s["mem_used"] // max(1, s["mem_total"])
    mem_used = heat_text(f"{mem_pct:>3}%", mem_pct / 100, c)
    mem_text = heat_text(fmt_mem(s["mem_used"], s["mem_total"]), mem_pct / 100, c)
    mem_line = f"  mem {bar(mem_pct, SPARK_WIDTH, c)} {mem_used} {mem_text}"
    return [head, cpu_line, net_line, mem_line]


def render_frame(rows, now, c, width, selected=None):
    cards = [render_card(name, state, s, hist, c, selected == i)
             for i, (name, state, s, hist) in enumerate(rows)]
    per_row = 2 if width >= GRID_MIN_WIDTH else 1
    lines = [f"{c.accent}quivr{c.rs}  {c.dim}{time.strftime('%H:%M:%S', time.localtime(now))}{c.rs}", ""]
    for i in range(0, len(cards), per_row):
        for parts in zip(*cards[i:i + per_row]):
            lines.append(GAP.join(pad(p, CARD_WIDTH) for p in parts).rstrip())
        lines.append("")
    lines += [f"{c.dim}↑↓ select  ⏎ detail  q quit{c.rs}",
              f"{c.accent}1{c.rs} ship  {c.dim}→{c.rs}  {c.accent}2{c.rs} deploy  {c.dim}→{c.rs}  {c.accent}3{c.rs} release"]
    return "\n".join(lines)
