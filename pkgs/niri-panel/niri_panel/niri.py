import json
import subprocess
from dataclasses import dataclass


@dataclass
class Mode:
    width: int
    height: int
    refresh_mhz: int
    is_preferred: bool


@dataclass
class Output:
    name: str
    make: str
    model: str
    serial: str
    modes: list
    current_mode_idx: "int | None"
    enabled: bool
    scale: float
    transform: str
    vrr_supported: bool
    vrr_enabled: bool
    pos: "tuple[int, int] | None"
    logical_size: "tuple[int, int] | None"

    @property
    def description(self) -> str:
        return f"{self.make} {self.model} {self.serial}"


def mode_str(m: Mode) -> str:
    return f"{m.width}x{m.height}@{m.refresh_mhz / 1000:.3f}"


def parse_outputs(raw: dict) -> dict:
    out = {}
    for name, o in raw.items():
        logical = o.get("logical")
        modes = [
            Mode(m["width"], m["height"], m["refresh_rate"], m.get("is_preferred", False))
            for m in o.get("modes", [])
        ]
        out[name] = Output(
            name=name,
            make=o.get("make", ""),
            model=o.get("model", ""),
            serial=o.get("serial", ""),
            modes=modes,
            current_mode_idx=o.get("current_mode"),
            enabled=logical is not None,
            scale=(logical or {}).get("scale", 1.0),
            transform=(logical or {}).get("transform", "Normal"),
            vrr_supported=o.get("vrr_supported", False),
            vrr_enabled=o.get("vrr_enabled", False),
            pos=((logical["x"], logical["y"]) if logical else None),
            logical_size=((logical["width"], logical["height"]) if logical else None),
        )
    return out


def list_outputs() -> dict:
    raw = json.loads(subprocess.run(
        ["niri", "msg", "--json", "outputs"],
        capture_output=True, text=True, check=True,
    ).stdout)
    return parse_outputs(raw)


TRANSFORMS = ["normal", "90", "180", "270",
              "flipped", "flipped-90", "flipped-180", "flipped-270"]
SCALES = [0.5, 0.75, 1.0, 1.125, 1.25, 1.5, 2.0]


def output_argv(name: str, action: str, *args: str) -> list:
    return ["niri", "msg", "output", name, action, *args]


def apply(name: str, action: str, *args: str) -> None:
    subprocess.run(output_argv(name, action, *args),
                   capture_output=True, text=True, check=True)


def relative_position(anchor_pos, anchor_size, moving_size, placement) -> tuple:
    ax, ay = anchor_pos
    aw, ah = anchor_size
    mw, mh = moving_size
    return {
        "right": (ax + aw, ay),
        "left":  (ax - mw, ay),
        "above": (ax, ay - mh),
        "below": (ax, ay + ah),
    }[placement]
