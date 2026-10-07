"""quivr pure view code: sample parsing, formatting, heat colours, overview rendering."""
import re
import time

PALETTE_TOKENS = {"dim": "REST", "accent": "ROOT", "warm": "FERMATA", "loud": "FORTE"}
HEAT_STOPS = (("dim", 0.0), ("accent", 0.35), ("warm", 0.70), ("loud", 1.0))
INT_FIELDS = ("cpu", "mem_used", "mem_total", "rx", "tx", "disk", "up")


def parse_sample(line):
    kv = dict(p.split("=", 1) for p in line.split() if "=" in p)
    try:
        s = {k: int(kv[k]) for k in INT_FIELDS}
        s["load"] = float(kv["load"])
        s["temp"] = None if kv["temp"] == "-" else int(kv["temp"])
        s["cpus"] = max(1, int(kv.get("cpus", "1")))
    except (KeyError, ValueError):
        return None
    return s


def norm(value, lo, hi):
    return max(0.0, min(1.0, (value - lo) / (hi - lo)))


def fmt_rate(bps):
    if bps < 1024:
        return f"{bps}B"
    v = bps / 1024
    for unit in "KMG":
        if v < 1024 or unit == "G":
            return f"{v:.1f}{unit}" if v < 10 else f"{v:.0f}{unit}"
        v /= 1024


def fmt_mem(used_kb, total_kb):
    return f"{used_kb / 1048576:.1f}G/{total_kb / 1048576:.1f}G"


def fmt_uptime(s):
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


class Colours:
    def __init__(self, rgb=None):
        self.rgb = rgb or {}
        on = bool(self.rgb)
        self.rs = "\x1b[0m" if on else ""
        self.bold = "\x1b[1m" if on else ""
        self.dim = self.fg("dim")
        self.accent = self.fg("accent")

    def fg(self, name):
        if name not in self.rgb:
            return ""
        r, g, b = self.rgb[name]
        return f"\x1b[38;2;{r};{g};{b}m"

    def heat(self, pos, attrs=True):
        """Colour (and, with attrs, weight) for a heat value: 0 quiet and cool, 1 loud and bold."""
        if not self.rgb:
            return ""
        pos = max(0.0, min(1.0, pos))
        for lo, hi in zip(HEAT_STOPS, HEAT_STOPS[1:]):
            if pos <= hi[1]:
                break
        t = (pos - lo[1]) / (hi[1] - lo[1])
        r, g, b = (round(x + (y - x) * t) for x, y in zip(self.rgb[lo[0]], self.rgb[hi[0]]))
        attr = ""
        if attrs:
            if pos < 0.2:
                attr = "\x1b[2m"
            elif pos >= 0.9:
                attr = "\x1b[1;4m"
            elif pos >= 0.75:
                attr = "\x1b[1m"
        return f"{attr}\x1b[38;2;{r};{g};{b}m"


def make_colours(path):
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return Colours()
    hexes = dict(re.findall(r'^export (\w+)="(#[0-9a-fA-F]{6})"', text, re.M))
    rgb = {}
    for name, token in PALETTE_TOKENS.items():
        h = hexes.get(token)
        if not h:
            return Colours()
        rgb[name] = tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))
    return Colours(rgb)


def bar(pct, width=10, c=None):
    n = max(0, min(width, int(pct * width / 100 + 0.5)))
    if c is None or not c.rgb:
        return "█" * n + "░" * (width - n)
    filled = "".join(f"{c.heat((i + 0.5) / width, attrs=False)}█" for i in range(n))
    return f"{filled}{c.rs}{c.dim}{'░' * (width - n)}{c.rs}"


def heat_text(text, pos, c):
    return f"{c.heat(pos)}{text}{c.rs}"


def render_row(name, state, s, c, compact=False, selected=False):
    marker = f"{c.accent}▸{c.rs} " if selected else "  "
    label = f"{name:<8}"
    if state != "up" or s is None:
        text = "reconnecting…" if state == "wait" else "no data"
        return f"{marker}{c.dim}○ {label} {text}{c.rs}"
    mem_pct = 100 * s["mem_used"] // max(1, s["mem_total"])
    cpu = f"{bar(s['cpu'], 10, c)} {heat_text(f'{s['cpu']:>3}%', s['cpu'] / 100, c)}"
    mem = f"{bar(mem_pct, 10, c)} {heat_text(f'{fmt_mem(s['mem_used'], s['mem_total']):<9}', mem_pct / 100, c)}"
    load = heat_text(f"{s['load']:>5.2f}", norm(s["load"] / s["cpus"], 0, 1), c)
    if s["temp"] is None:
        temp = f"{c.dim} —{c.rs}"
    else:
        temp = heat_text(f"{s['temp']:>3}°", norm(s["temp"], 30, 90), c)
    name_col = f"{c.bold if selected else ''}{label}{c.rs if selected else ''}"
    parts = [f"{marker}{c.accent}●{c.rs} {name_col}", f"cpu {cpu}", f"mem {mem}", f"load {load}", temp]
    if not compact:
        parts += [f"↓{fmt_rate(s['rx']):>5} ↑{fmt_rate(s['tx']):>5}",
                  f"disk {heat_text(f'{s['disk']:>3}%', s['disk'] / 100, c)}"]
    parts.append(f"up {fmt_uptime(s['up']):>3}")
    return " ".join(parts)


def render_frame(rows, now, c, width, selected=None):
    compact = width < 105
    lines = [f"{c.accent}quivr{c.rs}  {c.dim}{time.strftime('%H:%M:%S', time.localtime(now))}{c.rs}", ""]
    lines += [render_row(name, state, s, c, compact, selected == i) for i, (name, state, s) in enumerate(rows)]
    lines += ["", f"{c.dim}↑↓ select  ⏎ detail  q quit{c.rs}",
              f"{c.accent}1{c.rs} ship  {c.dim}→{c.rs}  {c.accent}2{c.rs} deploy  {c.dim}→{c.rs}  {c.accent}3{c.rs} release"]
    return "\n".join(lines)
