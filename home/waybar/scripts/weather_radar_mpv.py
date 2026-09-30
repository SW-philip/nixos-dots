#!/usr/bin/env python3
"""Pre-cache and display RainViewer radar as an mpv animation.

Modes:
  (no args)  — open cached frames in mpv, toggle if already running
  --cache    — download any new frames and composite them into the cache
"""

import json, math, os, subprocess, sys, tempfile, time, urllib.request
from pathlib import Path

LOCATION_JSON = Path.home() / ".config/waybar/weather_location.json"
CACHE_DIR     = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "waybar" / "radar"

ZOOM       = 7
COLS       = 2
ROWS       = 2
X_OFF      = -1     # shift west: location sits right-of-center so PA fills the frame
Y_OFF      = -1     # shift north: show northern PA
FRAMES_API = 12     # pull all available frames from the API each run
KEEP_AGE   = 8 * 3600  # prune composites older than 8 h
FRAME_S    = 0.25   # seconds per frame in mpv

# ── Geo ───────────────────────────────────────────────────────────────────────

def lat_lon_to_tile(lat, lon, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    lr = math.radians(lat)
    y = int((1 - math.log(math.tan(lr) + 1 / math.cos(lr)) / math.pi) / 2 * n)
    return x, y

def get_location():
    try:
        cfg = json.loads(LOCATION_JSON.read_text())
        use = cfg.get("USE_LOCATION")
        for loc in cfg.get("SAVED_LOCATIONS", []):
            if loc["name"] == use:
                return loc["lat"], loc["lon"]
        if cfg.get("SAVED_LOCATIONS"):
            return cfg["SAVED_LOCATIONS"][0]["lat"], cfg["SAVED_LOCATIONS"][0]["lon"]
    except Exception:
        pass
    return 40.13, -75.37

# ── Network ───────────────────────────────────────────────────────────────────

def fetch(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "waybar-weather/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r, open(dest, "wb") as f:
        f.write(r.read())

def fetch_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "waybar-weather/1.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())

# ── Image ops ─────────────────────────────────────────────────────────────────

def stitch(tile_paths, dest):
    """Combine a COLS×ROWS grid of tiles into one image."""
    inputs = [arg for p in tile_paths for arg in ("-i", str(p))]
    filter_parts = [
        f"{''.join(f'[{row*COLS+col}:v]' for col in range(COLS))}hstack=inputs={COLS}[row{row}]"
        for row in range(ROWS)
    ]
    filter_parts.append(f"{''.join(f'[row{r}]' for r in range(ROWS))}vstack=inputs={ROWS}[out]")
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", *inputs,
         "-filter_complex", ";".join(filter_parts), "-map", "[out]", str(dest)],
        check=True,
    )

def composite(base, radar, dest):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error",
         "-i", str(base), "-i", str(radar),
         "-filter_complex", "[0:v][1:v]overlay=format=auto", str(dest)],
        check=True,
    )

def get_base(ox, oy):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"base_{ZOOM}_{ox}_{oy}_{COLS}x{ROWS}.png"
    if not path.exists() or (time.time() - path.stat().st_mtime) > 86400:
        with tempfile.TemporaryDirectory(prefix="radar_base_") as tmp:
            tiles = []
            for row in range(ROWS):
                for col in range(COLS):
                    dest = Path(tmp) / f"b_{col}_{row}.png"
                    fetch(f"https://basemaps.cartocdn.com/dark_all/{ZOOM}/{ox+col}/{oy+row}.png", dest)
                    tiles.append(dest)
            stitch(tiles, path)
    return path

# ── Cache mode ────────────────────────────────────────────────────────────────

def do_cache():
    lat, lon = get_location()
    cx, cy   = lat_lon_to_tile(lat, lon, ZOOM)
    ox, oy   = cx + X_OFF, cy + Y_OFF

    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    base = get_base(ox, oy)

    api    = fetch_json("https://api.rainviewer.com/public/weather-maps.json")
    host   = api["host"]
    frames = api["radar"]["past"][-FRAMES_API:]

    # Prune frames older than KEEP_AGE
    now = time.time()
    for f in CACHE_DIR.glob("frame_*.png"):
        try:
            if now - int(f.stem.split("_")[1]) > KEEP_AGE:
                f.unlink()
        except (ValueError, IndexError):
            pass

    for frame in frames:
        ts   = frame["time"]
        dest = CACHE_DIR / f"frame_{ts}.png"
        if dest.exists():
            continue
        with tempfile.TemporaryDirectory(prefix="radar_dl_") as tmp:
            tmp = Path(tmp)
            try:
                tiles = []
                for row in range(ROWS):
                    for col in range(COLS):
                        tile = tmp / f"r_{col}_{row}.png"
                        fetch(f"{host}{frame['path']}/256/{ZOOM}/{ox+col}/{oy+row}/4/1_1.png", tile)
                        tiles.append(tile)
                stitched = tmp / "stitched.png"
                stitch(tiles, stitched)
                composite(base, stitched, dest)
            except Exception as e:
                print(f"frame ts={ts} failed: {e}", file=sys.stderr)
                dest.unlink(missing_ok=True)

# ── Play mode ─────────────────────────────────────────────────────────────────

def do_play():
    if subprocess.run(["pgrep", "-f", "wayland-app-id=weather-radar"],
                      capture_output=True).returncode == 0:
        subprocess.run(["pkill", "-f", "wayland-app-id=weather-radar"])
        sys.exit(0)

    frames = sorted(CACHE_DIR.glob("frame_*.png"))
    if not frames:
        print("Cache empty — fetching now (first run only)…", file=sys.stderr)
        do_cache()
        frames = sorted(CACHE_DIR.glob("frame_*.png"))
    if not frames:
        print("No frames available", file=sys.stderr)
        sys.exit(1)

    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt",
                                     prefix="radar_pl_", delete=False) as pl:
        pl.write("\n".join(str(f) for f in frames) + "\n")
        playlist = pl.name

    os.execvp("mpv", [
        "mpv",
        "--wayland-app-id=weather-radar",
        "--title=Weather Radar",
        "--loop-playlist=inf",
        f"--image-display-duration={FRAME_S}",
        "--no-terminal",
        "--force-window",
        "--no-resume-playback",
        "--autofit=35%",
        f"--playlist={playlist}",
    ])

if __name__ == "__main__":
    if "--cache" in sys.argv:
        do_cache()
    else:
        do_play()
