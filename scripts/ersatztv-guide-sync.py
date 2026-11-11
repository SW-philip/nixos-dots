#!/usr/bin/env python3
"""Run Jellyfin's Refresh Guide when ErsatzTV rewrites listings it already published.

Jellyfin reloads XMLTV once a day, so after a playout reset (or a deploy
that ships new schedules) its guide shows the old times until then. Each run
compares the guide with the last run's: listings that changed, appeared or
vanished inside the window both runs cover mean a rewrite. ErsatzTV's hourly
build only appends past the old horizon, which doesn't count. A rewrite marks
a refresh pending; it fires on the first run that sees no further change, so a
burst of resets triggers one refresh, not one per reset.

Env: XMLTV_URL, JELLYFIN_URL, STATE_DIRECTORY (systemd), CREDENTIALS_DIRECTORY
(systemd, file `jellyfin-key`).
"""
import json
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

XMLTV_URL = os.environ.get("XMLTV_URL", "http://127.0.0.1:8409/iptv/xmltv.xml")
JELLYFIN_URL = os.environ.get("JELLYFIN_URL", "http://127.0.0.1:8096")
STATE = Path(os.environ.get("STATE_DIRECTORY", ".")) / "guide.json"


def parse_time(s):
    return int(datetime.strptime(s, "%Y%m%d%H%M%S %z").timestamp())


def fetch_guide(now):
    with urllib.request.urlopen(XMLTV_URL, timeout=30) as r:
        root = ET.parse(r).getroot()
    guide = {}
    for p in root.iter("programme"):
        stop = parse_time(p.get("stop"))
        if stop > now:
            guide.setdefault(p.get("channel"), []).append(
                [parse_time(p.get("start")), stop, p.findtext("title") or ""])
    return guide


def rewritten(old, new, now):
    if old.keys() != new.keys():
        return True
    for ch, items in old.items():
        # only the stretch both snapshots cover; the newer one extends past it
        horizon = min(items[-1][1], new[ch][-1][1]) if items and new[ch] else now
        if ([x for x in items if now < x[1] <= horizon]
                != [x for x in new[ch] if now < x[1] <= horizon]):
            return True
    return False


def jellyfin(path, method="GET"):
    key = (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "jellyfin-key").read_text().strip()
    req = urllib.request.Request(
        JELLYFIN_URL + path, method=method,
        # Jellyfin 10.11 rejects the legacy X-Emby-Token header
        headers={"Authorization": f'MediaBrowser Token="{key}"'})
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
    return json.loads(body) if body else None


def refresh_guide():
    task = next(t for t in jellyfin("/ScheduledTasks") if t["Key"] == "RefreshGuide")
    if task["State"] != "Running":
        jellyfin(f"/ScheduledTasks/Running/{task['Id']}", method="POST")


def main():
    now = int(datetime.now(UTC).timestamp())
    guide = fetch_guide(now)
    try:
        state = json.loads(STATE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        state = None

    pending = False
    if state is not None:
        pending = state["pending"]
        if rewritten(state["guide"], guide, now):
            print("guide rewritten; refresh once it settles")
            pending = True
        elif pending:
            refresh_guide()
            print("guide settled; started Jellyfin Refresh Guide")
            pending = False

    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"pending": pending, "guide": guide}))
    tmp.replace(STATE)


if __name__ == "__main__":
    sys.exit(main())
