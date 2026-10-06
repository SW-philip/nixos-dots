#!/usr/bin/env python3
"""quivr: live per-host stats over ssh. Design: docs/superpowers/specs/2026-10-06-quivr-design.md
and 2026-10-06-quivr-detail-design.md"""
import os
import select
import shutil
import subprocess
import sys
import termios
import threading
import time
import tty

from quivr_detail import FrameReader, handle_key, parse_key, render_detail
from quivr_view import make_colours, parse_sample, render_frame

HERE = os.path.dirname(os.path.abspath(__file__))
HOSTS = os.environ.get("QUIVR_HOSTS", "desktop surface retro pi").split()
SAMPLER = os.environ.get("QUIVR_SAMPLER", os.path.join(HERE, "quivr-sampler.sh"))
DETAIL = os.environ.get("QUIVR_DETAIL", os.path.join(HERE, "quivr-detail.sh"))
SSH = os.environ.get("QUIVR_SSH", "ssh")
PALETTE = os.environ.get("QUIVR_PALETTE", os.path.expanduser("~/.config/waybar/palette.sh"))
STALE_S = 4
LOCAL_NAMES = {"swphil": "desktop", "swsurface": "surface", "swretro": "retro", "swpi": "pi"}
# first of btop/htop/top the host has; no single quotes so it survives ssh's remote shell
TOP_SCRIPT = "for t in btop htop top; do command -v $t >/dev/null 2>&1 && exec $t; done; echo no top found; sleep 2"


def is_local(host):
    return LOCAL_NAMES.get(os.uname().nodename.lower()) == host


def top_command(host):
    if is_local(host):
        return ["sh", "-c", TOP_SCRIPT]
    return [SSH, "-t", host, TOP_SCRIPT]


class SampleReader:
    def feed(self, line):
        return parse_sample(line)


class StreamFeed(threading.Thread):
    """Keeps one sampler stream per host alive; `value` is the newest thing its reader produced."""

    def __init__(self, host, script, reader):
        super().__init__(daemon=True)
        self.host = host
        self.script = script
        self.reader = reader
        self.value = None
        self.at = 0.0
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.proc = None

    def command(self):
        if is_local(self.host):
            return ["sh", self.script], None
        cmd = [SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=2",
               "-o", "ServerAliveCountMax=2", self.host, "sh", "-s"]
        return cmd, open(self.script)

    def run(self):
        delay = 2
        while not self.stopping.is_set():
            cmd, stdin = self.command()
            try:
                self.proc = subprocess.Popen(cmd, stdin=stdin or subprocess.DEVNULL, stdout=subprocess.PIPE,
                                             stderr=subprocess.DEVNULL, text=True)
                for line in self.proc.stdout:
                    v = self.reader.feed(line)
                    if v is not None:
                        with self.lock:
                            self.value, self.at = v, time.time()
                        delay = 2
                self.proc.wait()
            except OSError:
                pass
            finally:
                if stdin:
                    stdin.close()
            self.stopping.wait(delay)
            delay = min(15, delay * 2)

    def latest(self):
        with self.lock:
            return self.value, self.at

    def close(self):
        self.stopping.set()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


class HostFeed(StreamFeed):
    def __init__(self, host):
        super().__init__(host, SAMPLER, SampleReader())

    def row(self, now):
        s, at = self.latest()
        if s is not None and now - at <= STALE_S:
            return (self.host, "up", s)
        return (self.host, "wait", None)


class DetailFeed(StreamFeed):
    def __init__(self, host):
        super().__init__(host, DETAIL, FrameReader())


def wait_for(feed, seconds=6):
    deadline = time.time() + seconds
    while time.time() < deadline and feed.latest()[0] is None:
        time.sleep(0.1)


def run_once(feeds, c):
    for f in feeds:
        wait_for(f)
    width = shutil.get_terminal_size((120, 24)).columns
    print(render_frame([f.row(time.time()) for f in feeds], time.time(), c, width))
    return 0


def run_once_detail(host, c):
    if host not in HOSTS:
        print(f"quivr: unknown host {host}", file=sys.stderr)
        return 2
    feed, overview = DetailFeed(host), HostFeed(host)
    feed.start()
    overview.start()
    try:
        wait_for(feed)
        wait_for(overview, 2)
        frame, at = feed.latest()
        sample, _ = overview.latest()
        mem_kb = sample["mem_total"] if sample else 1
        size = shutil.get_terminal_size((120, 40))
        print(render_detail(host, frame, int(time.time() - at) if frame else 0, mem_kb, c, size.columns, size.lines))
    finally:
        feed.close()
        overview.close()
    return 0


def leave_screen(fd, old):
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    sys.stdout.write("\x1b[?25h\x1b[?1049l")
    sys.stdout.flush()


def enter_screen(fd):
    tty.setcbreak(fd)
    sys.stdout.write("\x1b[?1049h\x1b[?25l")
    sys.stdout.flush()


def run_top(host, fd, old):
    leave_screen(fd, old)
    try:
        subprocess.run(top_command(host))
    except OSError as e:
        print(f"quivr: cannot run top on {host}: {e}")
        time.sleep(2)
    enter_screen(fd)


def read_keys(fd):
    data = os.read(fd, 64).decode(errors="ignore")
    if data == "\x1b" and select.select([fd], [], [], 0.05)[0]:
        data += os.read(fd, 64).decode(errors="ignore")
    return data


def draw(text):
    sys.stdout.write("\x1b[H" + text.replace("\n", "\x1b[K\n") + "\x1b[K\x1b[J")
    sys.stdout.flush()


def run_live(feeds, c):
    if not sys.stdin.isatty():
        print("quivr needs a terminal (use --once for a single frame)", file=sys.stderr)
        return 2
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    state = {"mode": "overview", "sel": 0, "quit": False, "top": False}
    detail = None
    try:
        enter_screen(fd)
        while True:
            now = time.time()
            size = shutil.get_terminal_size((120, 24))
            host = HOSTS[state["sel"]]
            if state["mode"] == "detail":
                if detail is None or detail.host != host:
                    if detail:
                        detail.close()
                    detail = DetailFeed(host)
                    detail.start()
                frame, at = detail.latest()
                mem_total = feeds[state["sel"]].row(now)[2]
                mem_kb = mem_total["mem_total"] if mem_total else 1
                draw(render_detail(host, frame, int(now - at) if frame else 0, mem_kb, c, size.columns, size.lines))
            else:
                if detail:
                    detail.close()
                    detail = None
                draw(render_frame([f.row(now) for f in feeds], now, c, size.columns, state["sel"]))
            if not select.select([fd], [], [], 1.0)[0]:
                continue
            pending = read_keys(fd)
            while pending:
                key, pending = parse_key(pending)
                state = handle_key(state, key, len(feeds))
                if state["quit"]:
                    return 0
                if state["top"]:
                    run_top(host, fd, old)
                    pending = ""
    except KeyboardInterrupt:
        return 0
    finally:
        if detail:
            detail.close()
        leave_screen(fd, old)


def main(argv):
    c = make_colours(PALETTE)
    if "--once" in argv and "--detail" in argv:
        i = argv.index("--detail")
        return run_once_detail(argv[i + 1] if i + 1 < len(argv) else "", c)
    feeds = [HostFeed(h) for h in HOSTS]
    for f in feeds:
        f.start()
    try:
        return run_once(feeds, c) if "--once" in argv else run_live(feeds, c)
    finally:
        for f in feeds:
            f.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
