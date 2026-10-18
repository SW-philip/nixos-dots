import ipaddress
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

ALLOWED_ENV = ("PATH", "HOME", "TERM", "LANG", "CLAUDE_CONFIG_DIR", "CODEX_HOME")

_RO_TRY = ("/etc/ssl", "/etc/static", "/etc/passwd",
           "/etc/group", "/etc/nsswitch.conf",
           "/bin", "/usr/bin", "/etc/hosts", "/etc/localtime", "/etc/zoneinfo")


def clean_env(extra: dict[str, str], base: dict[str, str] | None = None) -> dict[str, str]:
    bad = sorted(set(extra) - set(ALLOWED_ENV))
    if bad:
        raise ValueError(f"env keys not allowed: {', '.join(bad)}")
    if base is None:
        base = os.environ
    env = {k: base[k] for k in ("TERM", "LANG") if k in base}
    env.update(extra)
    return env


def store_path(base: dict[str, str] | None = None) -> str:
    if base is None:
        base = os.environ
    parts = base.get("PATH", "").split(":")
    return ":".join(p for p in parts if p.startswith("/nix/store/"))


def _norm(p: Path) -> Path:
    # normpath keeps a leading "//", which is the same directory as "/" on Linux.
    return Path("/" + os.path.normpath(p).lstrip("/"))


def _nested(a: Path, b: Path) -> bool:
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


# Inside pasta's namespace this address is mapped onto the host's resolver(s); the
# host's own /etc/resolv.conf (often a 127.0.0.53 stub) would be unreachable there.
DNS_ADDR = "192.0.2.53"
RESOLV_CONF = f"nameserver {DNS_ADDR}\n"


_IFACE = re.compile(r"^[A-Za-z0-9._:-]{1,15}$")
_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_ROUTE_TARGET = "1.1.1.1"


class NoRoute(RuntimeError):
    pass


class NoDns(RuntimeError):
    pass


@dataclass(frozen=True)
class Route:
    dev: str
    via: str | None
    src: str | None


def _ipv4(text: str) -> str | None:
    try:
        return str(ipaddress.IPv4Address(text))
    except ValueError:
        return None


def parse_route_get(text: str) -> Route:
    """Parse `ip -4 -o route get 1.1.1.1`; the kernel's answer honours policy routing."""
    line = next((ln for ln in text.splitlines() if ln.strip()), "")
    tok = line.replace("\\", " ").split()
    if not tok or tok[0] in ("unreachable", "blackhole", "prohibit", "throw"):
        raise NoRoute(f"unusable answer {line.strip()!r}")
    fields = {}
    for i, t in enumerate(tok[:-1]):
        if t in ("dev", "via", "src") and t not in fields:
            fields[t] = tok[i + 1]
    dev = fields.get("dev")
    if dev is None or not _IFACE.fullmatch(dev):
        raise NoRoute(f"no usable device in {line.strip()!r}")
    return Route(dev, _ipv4(fields.get("via", "")), _ipv4(fields.get("src", "")))


def _device_addrs(addr_text: str) -> list[ipaddress.IPv4Address]:
    out = []
    for m in re.finditer(r"\binet\s+(\d+\.\d+\.\d+\.\d+)", addr_text):
        out.append(ipaddress.IPv4Address(m.group(1)))
    return out


def check_device(route: Route, addr_text: str) -> None:
    """Binding pasta to lo or a tailscale device re-opens the host-address hole
    (connects to the host's own addresses would be delivered locally again)."""
    if route.dev == "lo" or route.dev.startswith("tailscale") \
            or any(a in _CGNAT for a in _device_addrs(addr_text)):
        raise NoRoute(
            f"the route to the internet leaves through {route.dev!r}, which is lo or a "
            "tailscale device; binding the agent network to it would expose host services. "
            "Disable the tailscale exit node and retry.")


def _ip(ip: str, *args: str, run) -> str:
    try:
        res = run([ip, *args], capture_output=True, text=True, timeout=5,
                  env={"LC_ALL": "C"})
    except (OSError, subprocess.SubprocessError) as e:
        raise NoRoute(f"no route to the internet (ip {' '.join(args)} failed: {e})") from e
    if res.returncode != 0:
        raise NoRoute("no route to the internet (ip route get "
                      f"{_ROUTE_TARGET} failed: {(res.stderr or res.stdout).strip()})")
    return res.stdout


def egress_route(ip: str, run=subprocess.run) -> Route:
    out = _ip(ip, "-4", "-o", "route", "get", _ROUTE_TARGET, run=run)
    try:
        route = parse_route_get(out)
    except NoRoute as e:
        raise NoRoute(f"no route to the internet (ip route get {_ROUTE_TARGET} failed: {e})") from e
    check_device(route, _ip(ip, "-4", "-o", "addr", "show", "dev", route.dev, run=run))
    return route


def pick_dns(resolv_text: str, via: str | None, config_dns: str | None) -> tuple[str, str]:
    """(resolver, source) pasta forwards to (IPv4 only: the sandbox is -4). An explicit
    config value wins; then resolv.conf order, so a VPN's resolver written by
    wg-quick/resolvconf is used; then the route gateway. Never a built-in public resolver."""
    if config_dns:
        return config_dns, "config"
    for line in resolv_text.splitlines():
        f = line.split()
        if len(f) >= 2 and f[0] == "nameserver":
            try:
                a = ipaddress.IPv4Address(f[1])
            except ValueError:
                continue
            if not (a.is_loopback or a.is_unspecified or a.is_link_local or a in _CGNAT):
                return str(a), "resolv.conf"
    if via:
        return via, "gateway"
    raise NoDns("no usable DNS server: resolv.conf has only loopback/link-local/"
                "tailscale/IPv6 entries and the route has no gateway. Set "
                '`dns = "<ipv4>"` in ~/.config/orch/config.toml')


def host_resolv() -> str:
    try:
        return Path("/etc/resolv.conf").read_text()
    except OSError:
        return ""


@dataclass(frozen=True)
class NetPlan:
    dev: str
    via: str | None
    dns_host: str
    dns_source: str = "resolv.conf"

    def describe(self) -> str:
        return (f"orch: network dev={self.dev} gateway={self.via or '-'} "
                f"dns-host={self.dns_host} ({self.dns_source})")


def network_plan(ip: str, config_dns: str | None = None, run=subprocess.run) -> NetPlan:
    route = egress_route(ip, run=run)
    dns, source = pick_dns(host_resolv(), route.via, config_dns)
    return NetPlan(route.dev, route.via, dns, source)


def net_wrap(argv: list[str], *, iface: str, dns_host: str,
             pasta: str = "pasta") -> list[str]:
    """Run argv in a fresh network namespace with outbound-only networking.
    -t/-T/-u/-U none: without them pasta forwards host loopback ports in.
    --outbound-if4: pasta connect()s from the host namespace, so without binding the
    device a connect to the host's own tailscale address is delivered over lo, which
    the firewall trusts. -4: IPv6 off, which removes the same hole for fd7a:: and
    global addresses. There is deliberately no way to share the host network."""
    if not _IFACE.fullmatch(iface):
        raise ValueError(f"invalid interface name {iface!r}")
    dns_host = str(ipaddress.IPv4Address(dns_host))
    return [pasta, "--config-net", "--no-map-gw", "-4", "--outbound-if4", iface,
            "--dns-forward", DNS_ADDR, "--dns-host", dns_host,
            "-t", "none", "-T", "none", "-u", "none", "-U", "none", "--", *argv]


def bwrap_argv(*, cmd: list[str], workdir: Path, writable: bool, home: Path,
               env: dict[str, str], extra_ro: tuple[Path, ...] = (),
               resolv_conf: Path | None = None, uid: int | None = None,
               gid: int | None = None) -> list[str]:
    # pasta's user namespace makes us uid 0; claude refuses to run as root, so map
    # the real ids back in.
    uid = os.getuid() if uid is None else uid
    gid = os.getgid() if gid is None else gid
    extra_ro = tuple(Path(p) for p in extra_ro)
    if not workdir.is_absolute() or not home.is_absolute():
        raise ValueError("workdir and home must be absolute paths")
    if not all(p.is_absolute() for p in extra_ro):
        raise ValueError("extra_ro paths must be absolute")
    # Nested binds silently shadow each other; normpath (not resolve) keeps this pure.
    workdir, home = _norm(workdir), _norm(home)
    extra_ro = tuple(_norm(p) for p in extra_ro)
    if _nested(workdir, home):
        raise ValueError("workdir and home must not be equal or nested")
    mounts = [workdir, home, *extra_ro]
    if any(_nested(a, b) for i, a in enumerate(mounts) for b in mounts[:i]):
        raise ValueError("extra_ro, workdir and home must not be equal or nested")
    argv = ["bwrap", "--unshare-user", "--uid", str(uid), "--gid", str(gid),
            "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try",
            "--die-with-parent", "--new-session", "--ro-bind", "/nix/store", "/nix/store"]
    for p in _RO_TRY:
        argv += ["--ro-bind-try", p, p]
    argv += ["--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp"]
    if resolv_conf is not None:
        argv += ["--ro-bind", str(resolv_conf), "/etc/resolv.conf"]
    argv += ["--bind", str(home), str(home)]
    argv += ["--bind" if writable else "--ro-bind", str(workdir), str(workdir)]
    for p in extra_ro:
        argv += ["--ro-bind", str(p), str(p)]
    argv += ["--chdir", str(workdir), "--clearenv"]
    for k, v in sorted(env.items()):
        argv += ["--setenv", k, v]
    return argv + ["--"] + cmd
