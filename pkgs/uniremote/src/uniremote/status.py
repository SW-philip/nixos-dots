from __future__ import annotations
import xml.etree.ElementTree as ET
from dataclasses import dataclass

import requests

from uniremote.api import RokuAPI, SmartThingsAPI

NOT_SET_UP = "not set up · ⋯ → Preferences"

SNARK = (
    "Nobody home. Try the wall.",
    "The couch is waiting.",
    "Silence, and not the good kind.",
    "Off the grid, or just off.",
    "Have you tried being closer?",
)

_ROKU_POWER = {
    "PowerOn": "on",
    "Ready": "ready",
    "DisplayOff": "screen off",
    "Headless": "headless",
}


@dataclass(frozen=True)
class DeviceStatus:
    name: str
    line: str
    online: bool


def samsung_status(api: SmartThingsAPI, label: str) -> DeviceStatus:
    name = label or "Samsung TV"
    try:
        main = api.status()
    except requests.HTTPError as e:
        if e.response is not None and e.response.status_code in (401, 403):
            return DeviceStatus(name, "token rejected · ⋯ → Preferences", False)
        return DeviceStatus(name, "", False)
    except (requests.RequestException, ValueError):
        return DeviceStatus(name, "", False)
    power = main.get("switch", {}).get("switch", {}).get("value")
    volume = main.get("audioVolume", {}).get("volume", {}).get("value")
    source = main.get("mediaInputSource", {}).get("inputSource", {}).get("value")
    parts = [power or "unknown"]
    if volume is not None:
        parts.append(f"vol {volume}")
    if source:
        parts.append(str(source))
    return DeviceStatus(name, " · ".join(parts), True)


def roku_status(api: RokuAPI) -> DeviceStatus:
    try:
        info = api.device_info()
    except requests.HTTPError:
        return DeviceStatus("Roku", "status unavailable", True)
    except (requests.RequestException, ET.ParseError):
        return DeviceStatus("Roku", "", False)
    raw = info.get("power-mode", "")
    parts = [_ROKU_POWER.get(raw, raw.lower() or "unknown")]
    if info.get("model-name"):
        parts.append(info["model-name"])
    return DeviceStatus(info.get("user-device-name") or "Roku", " · ".join(parts), True)
