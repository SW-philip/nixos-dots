from __future__ import annotations
import tomllib
from pathlib import Path

DEFAULT_CONFIG_PATH = Path.home() / ".config" / "uniremote" / "config.toml"


# NOTE: values are written unescaped — safe for tokens/IDs/IPs and Roku app-id
# strings (digits only), but would produce invalid TOML for a value containing
# " or \.
def _fmt(val) -> str:
    if isinstance(val, list):
        return "[" + ", ".join(f'"{v}"' for v in val) + "]"
    return f'"{val}"'


def _write_toml(data: dict) -> str:
    lines = []
    for section, values in data.items():
        lines.append(f"[{section}]")
        for key, val in values.items():
            lines.append(f"{key} = {_fmt(val)}")
        lines.append("")
    return "\n".join(lines)


class Config:
    def __init__(self, path: Path = DEFAULT_CONFIG_PATH):
        self.path = Path(path)
        self.samsung_token = ""
        self.samsung_device_id = ""
        self.roku_ip = ""
        self.recent_roku_apps: list[str] = []
        self._load()

    def _load(self):
        if not self.path.exists():
            return
        with open(self.path, "rb") as f:
            data = tomllib.load(f)
        samsung = data.get("samsung", {})
        roku = data.get("roku", {})
        self.samsung_token = samsung.get("token", "")
        self.samsung_device_id = samsung.get("device_id", "")
        self.roku_ip = roku.get("ip", "")
        self.recent_roku_apps = [str(a) for a in roku.get("recent", [])]

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "samsung": {"token": self.samsung_token, "device_id": self.samsung_device_id},
            "roku": {"ip": self.roku_ip, "recent": self.recent_roku_apps},
        }
        self.path.write_text(_write_toml(data))
