from __future__ import annotations
import html
import xml.etree.ElementTree as ET
from dataclasses import dataclass

import requests

from uniremote.api import RokuAPI, SamsungAPI

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


def samsung_status(api: SamsungAPI) -> DeviceStatus:
    try:
        info = api.device_info()
    except (requests.RequestException, ValueError):
        return DeviceStatus("Samsung TV", "", False)
    name = html.unescape(info.get("name", "")).removeprefix("[TV] ") or "Samsung TV"
    if not api.paired:
        return DeviceStatus(name, "not paired · ⋯ → Preferences", True)
    parts = [info.get("PowerState", "on")]
    if info.get("modelName"):
        parts.append(info["modelName"])
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
