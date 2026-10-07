"""quivr detail view: frame parsing, rendering, key handling. Design: docs/superpowers/specs/2026-10-06-quivr-detail-design.md"""
from quivr_view import bar, fmt_rate, norm

CORE_CELL_WIDTH = 20
FOOTER = "esc back  [ ] host  t top  q quit"
# Run in this order: ship lands wip on main, deploy-all rolls main out, release cuts the tag.
ACTIONS = {"1": "ship", "2": "deploy", "3": "release"}
TABLE_OVERHEAD = 3  # blank line, title, column header


class FrameReader:
    """Assembles @frame ... @end blocks; a block cut short by a new @frame is dropped."""

    def __init__(self):
        self.frame = None

    def feed(self, line):
        line = line.rstrip("\n")
        if line.startswith("@frame"):
            parts = line.split()
            try:
                at = int(parts[1])
            except (IndexError, ValueError):
                at = 0
            self.frame = {"at": at, "cores": [], "net": [], "mounts": [], "io": [], "pcpu": [], "pmem": []}
            return None
        if self.frame is None:
            return None
        if line == "@end":
            done, self.frame = self.frame, None
            return done
        parse_line(self.frame, line)
        return None


def parse_line(frame, line):
    kind, _, rest = line.partition(" ")
    try:
        if kind == "core":
            n, pct = rest.split()
            frame["cores"].append((int(n), int(pct)))
        elif kind == "net":
            iface, rx, tx = rest.split()
            frame["net"].append((iface, int(rx), int(tx)))
        elif kind == "mount":
            pct, used, total, mp = rest.split(" ", 3)
            frame["mounts"].append((mp, int(pct), int(used), int(total)))
        elif kind == "io":
            dev, r, w = rest.split()
            frame["io"].append((dev, int(r), int(w)))
        elif kind in ("pcpu", "pmem"):
            pid, user, cpu, rss, cmd = rest.split(" ", 4)
            frame[kind].append((int(pid), user, float(cpu), int(rss), cmd))
    except ValueError:
        return


def heat_text(text, pos, c):
    return f"{c.heat(pos)}{text}{c.rs}"


def section(title, c):
    return f"{c.accent}{title}{c.rs}"


def core_lines(cores, width, c):
    cells = [f"{n:>2} {bar(p, 10, c)} {heat_text(f'{p:>3}%', p / 100, c)}" for n, p in cores]
    per_row = max(1, width // CORE_CELL_WIDTH)
    return [" ".join(cells[i:i + per_row]) for i in range(0, len(cells), per_row)]


def net_lines(net, c):
    busiest = sorted(net, key=lambda n: n[1] + n[2], reverse=True)[:6]
    return [f"  {iface:<14} ↓{fmt_rate(rx):>6}  ↑{fmt_rate(tx):>6}" for iface, rx, tx in busiest]


def disk_lines(mounts, io, c):
    out = []
    for mp, pct, used, total in mounts:
        size = f"{used / 1048576:.1f}G/{total / 1048576:.1f}G"
        out.append(f"  {mp[:16]:<16} {bar(pct, 10, c)} {heat_text(f'{pct:>3}%', pct / 100, c)} {size}")
    for dev, r, w in io:
        out.append(f"  io {dev:<13} r {fmt_rate(r):>6}/s  w {fmt_rate(w):>6}/s")
    return out


def proc_table(title, rows, limit, mem_total_kb, c):
    out = ["", section(title, c), f"{c.dim}{'PID':>7} {'USER':<8} {'CPU%':>6} {'RSS':>7}  COMMAND{c.rs}"]
    for pid, user, cpu, rss, cmd in rows[:limit]:
        cpu_t = heat_text(f"{cpu:>6.1f}", norm(cpu, 0, 100), c)
        rss_t = heat_text(f"{fmt_rate(rss * 1024):>7}", norm(rss / max(1, mem_total_kb), 0, 0.25), c)
        out.append(f"{pid:>7} {user[:8]:<8} {cpu_t} {rss_t}  {cmd}")
    return out


def render_detail(host, frame, age_s, mem_total_kb, c, width, height):
    age = "connecting…" if frame is None else f"{age_s}s old"
    lines = [f"{c.accent}quivr{c.rs} › {c.bold}{host}{c.rs}  {c.dim}{age}{c.rs}"]
    footer = ["", f"{c.dim}{FOOTER}{c.rs}"]
    if frame is None:
        return "\n".join(lines + ["", f"{c.dim}connecting…{c.rs}"] + footer)
    lines += ["", section("CPU", c)] + core_lines(frame["cores"], width, c)
    if frame["net"]:
        lines += ["", section("NETWORK", c)] + net_lines(frame["net"], c)
    if frame["mounts"] or frame["io"]:
        lines += ["", section("DISKS", c)] + disk_lines(frame["mounts"], frame["io"], c)
    avail = height - len(lines) - len(footer)
    each = (avail - 2 * TABLE_OVERHEAD) // 2
    if each >= 3:
        rows = min(10, each)
        lines += proc_table("PROCESSES by CPU", frame["pcpu"], rows, mem_total_kb, c)
        lines += proc_table("PROCESSES by MEMORY", frame["pmem"], rows, mem_total_kb, c)
    elif avail - TABLE_OVERHEAD >= 3:
        lines += proc_table("PROCESSES by CPU", frame["pcpu"], min(10, avail - TABLE_OVERHEAD), mem_total_kb, c)
    return "\n".join((lines + footer)[:height])


ARROWS = {"A": "up", "B": "down", "C": "right", "D": "left"}


def parse_key(data):
    """First key in data and the remainder. A lone ESC is a bare Esc press."""
    if data[0] == "\x1b":
        if len(data) == 1:
            return "esc", ""
        if data[1] in "[O" and len(data) >= 3:
            if data[2] in ARROWS:
                return ARROWS[data[2]], data[3:]
            i = 2
            while i < len(data) and not data[i].isalpha() and data[i] != "~":
                i += 1
            return "?", data[i + 1:]
        return "esc", data[1:]
    if data[0] in "\r\n":
        return "enter", data[1:]
    return data[0], data[1:]


def handle_key(state, key, nhosts):
    s = dict(state, top=False, action=None)
    if key == "q":
        s["quit"] = True
    elif s["mode"] == "overview":
        if key in ("up", "k"):
            s["sel"] = (s["sel"] - 1) % nhosts
        elif key in ("down", "j"):
            s["sel"] = (s["sel"] + 1) % nhosts
        elif key in ("enter", "right", "l"):
            s["mode"] = "detail"
        elif key in ACTIONS:
            s["action"] = ACTIONS[key]
    else:
        if key in ("esc", "left", "h"):
            s["mode"] = "overview"
        elif key == "]":
            s["sel"] = (s["sel"] + 1) % nhosts
        elif key == "[":
            s["sel"] = (s["sel"] - 1) % nhosts
        elif key == "t":
            s["top"] = True
    return s
