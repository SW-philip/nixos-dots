#!/usr/bin/env python3
"""photo-merge: find the same photo across every library and build one master library.

  photo-merge index [--jobs N] [--source NAME ...]
                                    record metadata and fingerprints of every source file
  photo-merge group                 find copies of one photo/video across sources, pick the
                                    best of each, write <state>/groups.json

Sources (SOURCES below) are read only. State lives in <pictures>/.photo-merge/index.sqlite,
keyed by path and re-read only when a file's size or mtime changes, so re-running after a
new pull or import costs only the new files. Images get a perceptual hash (phash) and a
gradient hash (dhash) of a 512px decode: a re-compressed or resized copy of a photo lands
within a few bits of the original, a different photo 30+ bits away. Capture time comes
from the file's own metadata (exiftool), the same field takeout-photos restores from
Google's sidecars, so a Google copy and an iCloud original of one shot agree on it.

Group links two images when their fingerprints are within a few bits and their capture
times agree (same second, or whole hours apart: one copy shifted by a timezone), so burst
shots a second apart stay separate. Undated images link only on near-identical prints.
Videos link on capture time plus duration. The best copy of a group is the one with the
most pixels, then the original format (raw, HEIC), then GPS, a capture date, bytes, and
iCloud over Google over the rest.
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime

PICTURES = "/srv/prepko/Pictures"
STATE = os.path.join(PICTURES, ".photo-merge")
# name -> (path, recursive). Dot-directories (staging, quarantine) are always skipped.
SOURCES = {
    "google": (os.path.join(PICTURES, "Google Photos"), True),
    "icloud": (os.path.join(PICTURES, "icloud"), True),
    "drive": ("/srv/prepko/Drive", True),
    "takeout-partial": (os.path.join(PICTURES, "takeout-partial-2026-05-21"), True),
    "drost-wedding": (os.path.join(PICTURES, "Drost Wedding"), True),
    "gmail-saves": (os.path.join(PICTURES, "gmail saves"), True),
    "screenshots": (os.path.join(PICTURES, "Screenshots"), True),
    "loose": (PICTURES, False),
}
IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".avif", ".bmp", ".tif", ".tiff",
             ".dng", ".cr2", ".nef", ".arw"}
VIDEO_EXT = {".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".mpg", ".wmv"}
# Raw formats PIL can't decode get metadata only; they still win "best copy" on format.
NO_DECODE = {".dng", ".cr2", ".nef", ".arw"}
EXIF_BATCH = 400
# Fingerprint bits two copies of one dated photo may differ by; unrelated photos sit at 30+.
PHASH_MAX, DHASH_MAX = 6, 10
# With no capture times to agree on, only near-identical prints count as one photo.
UNDATED_PHASH_MAX, UNDATED_DHASH_MAX = 2, 4
# Seconds two copies' capture times may drift (Google sidecar vs camera EXIF rounding).
CLOCK_SLACK = 2
# A fingerprint chunk shared by this many images is a flat frame (black, white), not a photo.
BUCKET_CAP = 200
VIDEO_DURATION_SLACK = 1.0
FORMAT_RANK = {".dng": 3, ".cr2": 3, ".nef": 3, ".arw": 3, ".heic": 2, ".heif": 2}
SOURCE_RANK = {"icloud": 0, "google": 1}
# Copy markers a file picks up on its way through Takeout, Drive and photo editors.
COPY_MARKS = re.compile(r"(\(\d+\)|-edited|-bearbeitet|-modifié|-editado| \([A-Za-z0-9_-]{8}\)|-original)+$", re.IGNORECASE)
CAMERA_COUNTER = re.compile(r"\d{3,}$")
SCHEMA = """
create table if not exists files (
  path text primary key, source text, size int, mtime real,
  taken text, width int, height int, model text, gps int, duration real, mime text,
  phash text, dhash text, error text
)"""


def walk(name, root, recursive):
    if not recursive:
        for f in sorted(os.listdir(root)):
            full = os.path.join(root, f)
            if not f.startswith(".") and os.path.isfile(full):
                yield full
        return
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if not x.startswith("."))
        for f in sorted(files):
            if not f.startswith("."):
                yield os.path.join(d, f)


def media_kind(path):
    ext = os.path.splitext(path)[1].lower()
    return "image" if ext in IMAGE_EXT else "video" if ext in VIDEO_EXT else None


def exif_batch(paths):
    """path -> exiftool record, numeric values (-n), QuickTime dates converted to local time."""
    out = subprocess.run(
        ["exiftool", "-j", "-n", "-q", "-q", "-api", "QuickTimeUTC=1",
         "-DateTimeOriginal", "-CreateDate", "-ImageWidth", "-ImageHeight", "-Model",
         "-GPSLatitude", "-Duration", "-MIMEType", "-@", "-"],
        input="\n".join(paths), capture_output=True, text=True, check=False,
    ).stdout
    try:
        return {r["SourceFile"]: r for r in json.loads(out or "[]")}
    except json.JSONDecodeError:
        return {}


def taken(rec):
    for k in ("DateTimeOriginal", "CreateDate"):
        v = rec.get(k)
        # exiftool's placeholder for an unset QuickTime date
        if isinstance(v, str) and len(v) >= 19 and not v.startswith("0000"):
            return v[:19]
    return None


def fingerprint(path):
    """(phash, dhash, error) of an image, decoded at most 512px on its long side."""
    import imagehash
    import pillow_heif
    from PIL import Image

    pillow_heif.register_heif_opener()
    try:
        with Image.open(path) as im:
            im.draft("RGB", (512, 512))
            im = im.convert("RGB")
            im.thumbnail((512, 512))
            return str(imagehash.phash(im)), str(imagehash.dhash(im)), None
    except ImportError:
        # A broken environment, not a broken file: recording it per file would quietly
        # leave the whole index without fingerprints.
        raise
    except Exception as e:  # noqa: BLE001 - one unreadable file must not stop the index
        return None, None, f"{type(e).__name__}: {e}"[:200]


def index(jobs, only):
    os.makedirs(STATE, exist_ok=True)
    db = sqlite3.connect(os.path.join(STATE, "index.sqlite"))
    db.execute(SCHEMA)
    known = {p: (s, m) for p, s, m in db.execute("select path, size, mtime from files")}
    seen, todo = set(), []
    for name, (root, recursive) in SOURCES.items():
        if only and name not in only:
            continue
        if not os.path.isdir(root):
            print(f"skipping {name}: no {root}", file=sys.stderr)
            continue
        n = 0
        for path in walk(name, root, recursive):
            if not media_kind(path):
                continue
            st = os.stat(path)
            seen.add(path)
            n += 1
            if known.get(path) != (st.st_size, st.st_mtime):
                todo.append((path, name, st.st_size, st.st_mtime))
        print(f"{name:<16} {n:>6} media files", flush=True)
    names = only or set(SOURCES)
    marks = ",".join("?" * len(names))
    indexed = {p for p, in db.execute(f"select path from files where source in ({marks})", sorted(names))}
    gone = [p for p in indexed if p not in seen]
    db.executemany("delete from files where path = ?", [(p,) for p in gone])
    print(f"{len(todo)} new or changed, {len(gone)} gone", flush=True)

    with ProcessPoolExecutor(max_workers=jobs) as pool:
        for i in range(0, len(todo), EXIF_BATCH):
            batch = todo[i:i + EXIF_BATCH]
            exif = exif_batch([p for p, *_ in batch])
            images = [p for p, *_ in batch
                      if media_kind(p) == "image" and os.path.splitext(p)[1].lower() not in NO_DECODE]
            prints = dict(zip(images, pool.map(fingerprint, images, chunksize=8), strict=True))
            rows = []
            for path, name, size, mtime in batch:
                rec = exif.get(path, {})
                ph, dh, err = prints.get(path, (None, None, None))
                rows.append((path, name, size, mtime, taken(rec), rec.get("ImageWidth"), rec.get("ImageHeight"),
                             rec.get("Model"), int("GPSLatitude" in rec), rec.get("Duration"), rec.get("MIMEType"),
                             ph, dh, err))
            db.executemany("insert or replace into files values (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
            # Committed per batch, so an interrupted index resumes where it stopped.
            db.commit()
            print(f"  {min(i + EXIF_BATCH, len(todo))}/{len(todo)}", flush=True)
    db.commit()
    total, errors = db.execute("select count(*), count(error) from files").fetchone()
    print(f"index: {total} files, {errors} unreadable")


def bits(a, b):
    return (int(a, 16) ^ int(b, 16)).bit_count()


def epoch(taken):
    try:
        return datetime.strptime(taken, "%Y:%m:%d %H:%M:%S").timestamp()
    except (TypeError, ValueError):
        return None


def stem(path):
    return COPY_MARKS.sub("", os.path.splitext(os.path.basename(path))[0]).lower()


def names_allow(a, b):
    """Burst shots share a second and nearly a frame, but never a name: IMG_0046 and
    IMG_0047 are two photos, while a copy keeps its name (IMG_0047.JPG in Google is
    IMG_0047.HEIC in iCloud). Different names in one source, or different camera
    counters anywhere, are different shots; otherwise the fingerprints decide."""
    sa, sb = stem(a["path"]), stem(b["path"])
    if sa == sb:
        return True
    if a["source"] == b["source"]:
        return False
    return not (CAMERA_COUNTER.search(sa) and CAMERA_COUNTER.search(sb))


def times_agree(a, b):
    """True/False when both copies are dated, None when either isn't."""
    if a is None or b is None:
        return None
    d = abs(a - b)
    return d <= CLOCK_SLACK or (d <= 14 * 3600 and min(d % 3600, 3600 - d % 3600) <= CLOCK_SLACK)


class Union:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, i):
        while self.p[i] != i:
            self.p[i] = self.p[self.p[i]]
            i = self.p[i]
        return i

    def join(self, i, j):
        self.p[self.find(i)] = self.find(j)


def by_clock(files):
    """Pairs of indices whose capture times could agree, via buckets of time mod one hour
    so timezone-shifted copies share a bucket; each pair is still checked by the caller."""
    buckets = {}
    for i, f in enumerate(files):
        if f["t"] is not None:
            buckets.setdefault(int(f["t"]) % 3600, []).append(i)
    for k, members in buckets.items():
        for off in range(CLOCK_SLACK + 1):
            other = members if off == 0 else buckets.get((k + off) % 3600, [])
            for x, i in enumerate(members):
                for j in other[x + 1:] if off == 0 else other:
                    yield i, j


def by_print(files):
    """Pairs of indices sharing a 16-bit chunk of phash: every pair within UNDATED_PHASH_MAX
    bits shares at least two of the four chunks, so none is missed."""
    buckets = {}
    for i, f in enumerate(files):
        for b in range(4):
            buckets.setdefault((b, f["phash"][b * 4:b * 4 + 4]), []).append(i)
    seen = set()
    for members in buckets.values():
        if len(members) > BUCKET_CAP:
            continue
        for x, i in enumerate(members):
            for j in members[x + 1:]:
                if (i, j) not in seen:
                    seen.add((i, j))
                    yield i, j


def link_images(files):
    u = Union(len(files))
    for i, j in by_clock(files):
        a, b = files[i], files[j]
        if names_allow(a, b) and times_agree(a["t"], b["t"]) and bits(a["phash"], b["phash"]) <= PHASH_MAX \
                and bits(a["dhash"], b["dhash"]) <= DHASH_MAX:
            u.join(i, j)
    for i, j in by_print(files):
        a, b = files[i], files[j]
        if names_allow(a, b) and times_agree(a["t"], b["t"]) is not False \
                and bits(a["phash"], b["phash"]) <= UNDATED_PHASH_MAX \
                and bits(a["dhash"], b["dhash"]) <= UNDATED_DHASH_MAX:
            u.join(i, j)
    return u


def link_videos(files):
    u = Union(len(files))
    for i, j in by_clock(files):
        a, b = files[i], files[j]
        if names_allow(a, b) and times_agree(a["t"], b["t"]) and a["duration"] and b["duration"] \
                and abs(a["duration"] - b["duration"]) <= VIDEO_DURATION_SLACK:
            u.join(i, j)
    return u


def quality(f):
    ext = os.path.splitext(f["path"])[1].lower()
    return ((f["width"] or 0) * (f["height"] or 0), FORMAT_RANK.get(ext, 1), f["gps"], f["t"] is not None,
            f["size"], -SOURCE_RANK.get(f["source"], 2))


def groups_of(files, u):
    sets = {}
    for i in range(len(files)):
        sets.setdefault(u.find(i), []).append(files[i])
    out = []
    for g in sets.values():
        if len(g) > 1:
            g = sorted(g, key=quality, reverse=True)
            # An edit is a choice, not a copy: review decides between it and the original.
            edited = any(re.search(r"-edited", os.path.basename(f["path"]), re.IGNORECASE) for f in g)
            out.append([dict(f, best=k == 0, edited=edited) for k, f in enumerate(g)])
    return out


def load(db):
    cols = ("path", "source", "size", "taken", "width", "height", "gps", "duration", "phash", "dhash")
    rows = [dict(zip(cols, r, strict=True)) for r in db.execute(f"select {', '.join(cols)} from files")]
    for r in rows:
        r["t"] = epoch(r["taken"])
    images = [r for r in rows if r["phash"] and r["dhash"]]
    videos = [r for r in rows if media_kind(r["path"]) == "video"]
    return rows, images, videos


def human(n):
    for unit in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def group():
    db = sqlite3.connect(os.path.join(STATE, "index.sqlite"))
    rows, images, videos = load(db)
    groups = groups_of(images, link_images(images)) + groups_of(videos, link_videos(videos))
    for g in groups:
        for f in g:
            f.pop("t")
    with open(os.path.join(STATE, "groups.json"), "w") as fh:
        json.dump(groups, fh, indent=1)
    extra = [f for g in groups for f in g if not f["best"]]
    combos = {}
    for g in groups:
        k = "+".join(sorted({f["source"] for f in g}))
        combos[k] = combos.get(k, 0) + 1
    in_groups = sum(len(g) for g in groups)
    print(f"{len(rows)} files indexed; {len(groups)} groups hold {in_groups} files")
    print(f"library: {len(rows) - len(extra)} files ({human(sum(r['size'] for r in rows) - sum(f['size'] for f in extra))}),"
          f" {len(extra)} redundant copies ({human(sum(f['size'] for f in extra))})")
    for k, n in sorted(combos.items(), key=lambda kv: -kv[1])[:12]:
        print(f"  {n:>6} groups  {k}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ix = sub.add_parser("index")
    ix.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    ix.add_argument("--source", action="append", choices=sorted(SOURCES), help="only these (repeatable)")
    sub.add_parser("group")
    args = ap.parse_args()
    if args.cmd == "index":
        index(args.jobs, set(args.source or ()))
    elif args.cmd == "group":
        group()


if __name__ == "__main__":
    main()
