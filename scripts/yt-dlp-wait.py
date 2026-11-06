#!/usr/bin/env python3
"""yt-dlp for mpv's ytdl hook, holding -J output until the streams open.

YouTube's TV client returns stream URLs that answer 403 until the skip time of
the ad attached to the session has passed (yt-dlp's `available_at`). yt-dlp's
own downloader sleeps through that; mpv connects at once and gives up, so the
hook has to be the one that waits. sqlch shows nothing meanwhile, so the video's
cached thumbnail stands in, as a window niri places like the real one.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

MARGIN = 1.0  # available_at is whole seconds; the gate can open just after it
POPUP_MAX_SECS = 30  # a backstop; the sitter normally closes it first
POPUP_LINGER = 2.0  # mpv still has to open the streams before its window appears
VIDEO_ID = re.compile(r"[?&]v=([\w-]{11})")


def ready_at(info: dict) -> float:
    selected = (info.get("format_id") or "").split("+")
    return max((f.get("available_at") or 0 for f in info.get("formats") or []
                if f.get("format_id") in selected), default=0)


def thumbnail(args: list[str]) -> Path | None:
    # mpv asks for this format only under --no-video; a listing has no watch URL
    if not args or "bestaudio/best" in args:
        return None
    match = VIDEO_ID.search(args[-1])
    if not match:
        return None
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    image = cache / "sqlch" / "youtube" / f"{match[1]}.jpg"
    return image if image.is_file() else None


def popup(image: Path | None) -> int | None:
    """Show image from a detached sitter; returns the pipe that dismisses it.

    A byte on the pipe means handed off: linger until mpv's window is up. EOF
    means this process died (sqlch stopped the load): close at once. Detached
    because mpv's hook waits for this process and its stdout before going on.
    """
    mpv = os.environ.get("POPUP_MPV")
    if not image or not mpv:
        return None
    read_end, write_end = os.pipe()
    if os.fork():
        os.close(read_end)
        return write_end
    os.close(write_end)
    os.setsid()
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    window = subprocess.Popen(
        [mpv, "--no-config", "--no-terminal", "--no-osc", "--wayland-app-id=sqlch-video",
         "--force-window=immediate", f"--image-display-duration={POPUP_MAX_SECS}",
         "--video-crop=480x270+0+45",  # hqdefault letterboxes 16:9 inside 4:3
         "--", str(image)])
    if os.read(read_end, 1):
        time.sleep(POPUP_LINGER)
    window.terminate()
    os._exit(0)


def main() -> int:
    dismiss = popup(thumbnail(sys.argv[1:]))
    proc = subprocess.run([os.environ["YT_DLP"], *sys.argv[1:]],
                          stdout=subprocess.PIPE, check=False)
    try:
        info = json.loads(proc.stdout)
    except ValueError:
        info = None
    if isinstance(info, dict):
        time.sleep(max(0.0, ready_at(info) + MARGIN - time.time()))
    if dismiss is not None:
        os.write(dismiss, b"1")
    sys.stdout.buffer.write(proc.stdout)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
