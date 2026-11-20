"""Who is asking: process chains and units from /proc. Reads comm only, never cmdlines (tokens)."""
import os
import subprocess


def log(msg):
    print(msg, flush=True)


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def comm(pid):
    return (_read(f"/proc/{pid}/comm") or "?").strip()


def ppid(pid):
    stat = _read(f"/proc/{pid}/stat")
    if not stat:
        return None
    # comm may hold spaces or parens: the fields after the last ')' are fixed
    return int(stat.rsplit(")", 1)[1].split()[1])


def chain(pid, depth=4):
    """'systemctl ← goodnight ← bash', stopping at systemd (pid 1 or a user manager)."""
    names, cur = [], pid
    while cur and cur > 1 and len(names) < depth:
        name = comm(cur)
        if name == "systemd":
            break
        names.append(name)
        cur = ppid(cur)
    return " ← ".join(names) or "?"


def unit_of(pid):
    """The systemd unit a pid runs in, e.g. 'goodnight.service (user)'."""
    cg = _read(f"/proc/{pid}/cgroup")
    if not cg:
        return None
    path = cg.strip().splitlines()[-1].split(":", 2)[-1]
    parts = [p for p in path.split("/") if p]
    user = any(p.startswith("user@") for p in parts)
    for p in reversed(parts):
        if p.endswith((".service", ".scope")):
            return f"{p} ({'user' if user else 'system'})"
    return None


def ssh_agent_clients(sock=None):
    """Pids of the processes connected to the gcr ssh-agent socket, newest first."""
    sock = sock or os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "gcr/ssh")
    try:
        out = subprocess.run(["ss", "-xpH"], capture_output=True, text=True, timeout=3, check=False).stdout
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows = [line.split(None, 8) for line in out.splitlines()]
    rows = [r for r in rows if len(r) >= 8]
    # the agent's end carries the socket path; the client's end is the row whose inode is its peer
    peers = {r[7] for r in rows if r[4] == sock}
    pids = []
    for r in rows:
        if r[5] in peers and len(r) == 9 and "pid=" in r[8]:
            pids.append(int(r[8].split("pid=", 1)[1].split(",", 1)[0]))
    return sorted(set(pids), key=start_time, reverse=True)


def start_time(pid):
    stat = _read(f"/proc/{pid}/stat")
    return int(stat.rsplit(")", 1)[1].split()[19]) if stat else 0
