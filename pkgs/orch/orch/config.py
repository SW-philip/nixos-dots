"""Optional ~/.config/orch/config.toml merged over built-in defaults."""

import ipaddress
import tomllib
from pathlib import Path

KNOWN_AGENTS = ("claude", "codex")
DEFAULTS = {
    "implementer": "claude",
    "reviewer": "codex",
    "max_rounds": 3,
    "timeout_s": 1800,
    "agents": {},
    "dns": None,
}


def default_path() -> Path:
    return Path.home() / ".config" / "orch" / "config.toml"


def load(path: Path | None = None) -> dict:
    cfg = {**DEFAULTS, "agents": {}}
    p = Path(path) if path else default_path()
    if p.exists():
        try:
            cfg.update(tomllib.loads(p.read_text()))
        except tomllib.TOMLDecodeError as e:
            raise ValueError(f"{p}: {e}") from e
    for role in ("implementer", "reviewer"):
        if cfg[role] not in KNOWN_AGENTS:
            raise ValueError(f"{role} must be one of {KNOWN_AGENTS}, got {cfg[role]!r}")
    for key, lo, hi in (("max_rounds", 1, 10), ("timeout_s", 10, 86400)):
        v = cfg[key]
        if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
            raise ValueError(f"{key} must be an integer in {lo}..{hi}, got {v!r}")
    dns = cfg.get("dns")
    if dns is not None:
        try:
            ok = isinstance(dns, str) and str(ipaddress.IPv4Address(dns)) == dns
        except ValueError:
            ok = False
        if not ok:
            raise ValueError(f"dns must be an IPv4 address, got {dns!r}")
    return cfg


def agent_model(cfg: dict, name: str) -> str | None:
    return (cfg.get("agents", {}).get(name) or {}).get("model")
