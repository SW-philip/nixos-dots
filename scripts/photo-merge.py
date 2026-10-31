#!/usr/bin/env python3
"""photo-merge: find the same photo across every library and build one master library.

  photo-merge index [--jobs N] [--source NAME ...]
                                    record metadata and fingerprints of every source file
  photo-merge group                 find copies of one photo/video across sources, pick the
                                    best of each, write <state>/groups.json
  photo-merge review                decide in fzf which copies to keep where the best one
                                    isn't obvious: a group holding an edit, or a burst
  photo-merge build [--dry-run]     reflink every kept file into <pictures>/Library

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

Review asks only about groups where keeping the best copy alone could lose something: an
edit (the edit and the original are both choices) or a burst (one source holding several
different prints in one group). Decisions live in <state>/review.json, keyed by the group's
paths, so a group whose membership changes is asked again.

Build reflinks (btrfs FICLONE: no extra space, independent files) the best copy of each
group, the reviewed choices, and every ungrouped file outside LIBRARY_SKIP into
Library/YYYY/YYYY-MM-DD/, undated ones into Library/undated/<source>/. <state>/library.tsv
maps each library file to its source; a source already in it is skipped, so build resumes
and re-runs add only what's new. Build never deletes: a library file whose source is no
longer chosen is listed in <state>/library-stale.tsv.
"""
import argparse
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime

PICTURES = "/srv/prepko/Pictures"
STATE = os.path.join(PICTURES, ".photo-merge")
LIBRARY = os.path.join(PICTURES, "Library")
# Ungrouped files from these sources stay out of the library.
LIBRARY_SKIP = {"screenshots"}
FICLONE = 0x40049409
# name -> (path, recursive). Dot-directories (staging, quarantine) are always skipped.
SOURCES = {
    "google": (os.path.join(PICTURES, "Google Photos"), True),
    "icloud": (os.path.join(PICTURES, "icloud"), True),
    "drive": ("/srv/prepko/Drive", True),
    "takeout-partial": (os.path.join(PICTURES, "takeout-partial-2026-05-21"), True),
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
# A phash with this few bits set (or unset) is a blank frame, not a fingerprint.
FLAT_BITS = 4
VIDEO_DURATION_SLACK = 1.0
FORMAT_RANK = {".dng": 3, ".cr2": 3, ".nef": 3, ".arw": 3, ".heic": 2, ".heif": 2}
SOURCE_RANK = {"icloud": 0, "google": 1}
# Copy markers a file picks up on its way through Takeout, Drive, iCloud export (_HEVC on
# a Live Photo's motion clip) and photo editors.
COPY_MARKS = re.compile(r"(\(\d+\)|-edited|-bearbeitet|-modifié|-editado| \([A-Za-z0-9_-]{8}\)|[-_]original|_hevc)+$",
                        re.IGNORECASE)
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


def conflict(a, b):
    return not names_allow(a, b) or times_agree(a["t"], b["t"]) is False


class Union:
    """Union-find that refuses a join putting two conflicting files in one group: an undated
    or counterless copy can match two burst shots that don't match each other, and plain
    transitivity would merge the burst through it."""

    def __init__(self, files):
        self.files = files
        self.p = list(range(len(files)))
        self.members = {i: [i] for i in range(len(files))}

    def find(self, i):
        while self.p[i] != i:
            self.p[i] = self.p[self.p[i]]
            i = self.p[i]
        return i

    def join(self, i, j):
        ri, rj = self.find(i), self.find(j)
        if ri == rj or any(conflict(self.files[x], self.files[y]) for x in self.members[ri] for y in self.members[rj]):
            return
        self.p[ri] = rj
        self.members[rj] += self.members.pop(ri)


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
    bits shares at least two of the four chunks, so none is missed. Flat frames are left
    out: every black screenshot prints the same, and one undated one would chain them all."""
    buckets = {}
    for i, f in enumerate(files):
        if not FLAT_BITS < int(f["phash"], 16).bit_count() < 64 - FLAT_BITS:
            continue
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
    u = Union(files)
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
    u = Union(files)
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


def load_groups():
    try:
        with open(os.path.join(STATE, "groups.json")) as fh:
            return json.load(fh)
    except OSError:
        sys.exit("photo-merge: no groups; run `photo-merge group` first")


def gkey(g):
    return hashlib.sha1("\n".join(sorted(f["path"] for f in g)).encode()).hexdigest()[:16]


def is_edit(f):
    return re.search(r"-edited", os.path.basename(f["path"]), re.IGNORECASE) is not None


def burst(g):
    """One source holding two different prints of one format. A screenshot's PNG and the
    JPG Google re-encoded from it also differ by a bit or two, but never share a format."""
    prints = {}
    for f in g:
        prints.setdefault((f["source"], os.path.splitext(f["path"])[1].lower()), set()).add(f["phash"])
    return all(f["phash"] for f in g) and any(len(p) > 1 for p in prints.values())


def needs_review(g):
    return g[0]["edited"] or burst(g)


def suggest(g):
    """Paths review pre-selects: the best original and best edit, and with a burst the best
    copy of each distinct print. g is sorted best first, so the first of each kind wins."""
    keep = {f["path"] for f in (next((f for f in g if is_edit(f) == e), None) for e in (False, True)) if f}
    if burst(g):
        seen = set()
        for f in g:
            if f["phash"] not in seen:
                seen.add(f["phash"])
                keep.add(f["path"])
    return keep


def load_review():
    try:
        with open(os.path.join(STATE, "review.json")) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}


def save_review(decided):
    tmp = os.path.join(STATE, "review.json.part")
    with open(tmp, "w") as fh:
        json.dump(decided, fh, indent=1)
    os.replace(tmp, os.path.join(STATE, "review.json"))


def fzf_args(g, n, total, why, pre, preview):
    start = "+".join(["toggle+down"] * pre + ["first"])
    return [
        "fzf", "--multi", "--layout=reverse", "--delimiter=\t", "--with-nth=2", "--expect=ctrl-s",
        (f"--header=[{n}/{total}] {why}, {len(g)} files\n"
         "tab: toggle keep   enter: keep selected (none: the highlighted one)   ctrl-s: skip   esc: stop"),
        # Full screen, whatever FZF_DEFAULT_OPTS says: an inline (--height) fzf sits at the
        # terminal's bottom, where an image one row too tall scrolls the whole screen.
        "--no-height", "--header-first", f"--preview={preview} {{1}}", "--preview-window=right,55%,nowrap",
        f"--bind=load:{start}",
    ]


def review():
    groups = [g for g in load_groups() if needs_review(g)]
    decided = load_review()
    todo = [g for g in groups if gkey(g) not in decided]
    preview = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))} preview"
    for n, g in enumerate(todo, 1):
        keep = suggest(g)
        # Suggested keeps first: the load binding pre-selects that many rows from the top.
        files = sorted(g, key=lambda f: f["path"] not in keep)
        lines = [f"{f['path']}\t{f['source']:<15} {f['taken'] or 'undated':<19} {f['width']}x{f['height']:<5}"
                 f" {human(f['size']):>5}  {os.path.basename(f['path'])}" for f in files]
        why = " + ".join(w for w, on in (("edit", g[0]["edited"]), ("burst", burst(g))) if on)
        r = subprocess.run(fzf_args(g, n, len(todo), why, len(keep), preview), input="\n".join(lines),
                           stdout=subprocess.PIPE, text=True, check=False)
        if r.returncode == 130:
            print(f"stopped at {n}/{len(todo)}; run review again to continue")
            return
        out = r.stdout.splitlines()
        if out and out[0] == "ctrl-s":
            continue
        kept = sorted(ln.split("\t", 1)[0] for ln in out[1:] if ln)
        if kept:
            decided[gkey(g)] = kept
            save_review(decided)
    left = sum(gkey(g) not in decided for g in groups)
    print(f"{len(groups) - left}/{len(groups)} groups decided" + (f", {left} skipped" if left else ""))


def preview(path):
    import pillow_heif
    from PIL import Image

    cols = int(os.environ.get("FZF_PREVIEW_COLUMNS", "80"))
    rows = int(os.environ.get("FZF_PREVIEW_LINES", "40"))
    # One line, never wrapped, so the image sized below it fits the pane exactly. Flushed:
    # chafa writes straight to the terminal, ahead of anything buffered.
    print(os.path.basename(path)[:cols], flush=True)
    if media_kind(path) != "image":
        print("(no preview for video)")
        return
    # chafa can't read HEIC; a small PNG decoded once serves every redraw.
    thumb = os.path.join(STATE, "thumbs", hashlib.sha1(path.encode()).hexdigest() + ".png")
    if not os.path.exists(thumb):
        pillow_heif.register_heif_opener()
        os.makedirs(os.path.dirname(thumb), exist_ok=True)
        try:
            with Image.open(path) as im:
                im.draft("RGB", (1024, 1024))
                im = im.convert("RGB")
                im.thumbnail((1024, 1024))
                im.save(thumb)
        except Exception as e:  # noqa: BLE001 - a preview that fails is just a missing picture
            print(f"(no preview: {type(e).__name__}: {e})")
            return
    subprocess.run(["chafa", f"--size={cols}x{rows - 1}", thumb], check=False)


def library_path(f):
    if f["taken"]:
        day = f["taken"][:10].replace(":", "-")
        return os.path.join(day[:4], day, os.path.basename(f["path"]))
    return os.path.join("undated", f["source"], os.path.basename(f["path"]))


def free_name(rel, taken):
    stem, ext = os.path.splitext(rel)
    k = 1
    while rel in taken or os.path.lexists(os.path.join(LIBRARY, rel)):
        k += 1
        rel = f"{stem}-{k}{ext}"
    return rel


def reflink(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = os.path.join(os.path.dirname(dst), "." + os.path.basename(dst) + ".part")
    with open(src, "rb") as s, open(tmp, "wb") as d:
        fcntl.ioctl(d.fileno(), FICLONE, s.fileno())
    shutil.copystat(src, tmp)
    os.replace(tmp, dst)


def chosen():
    """Every file the library should hold, and the number of unreviewed groups."""
    db = sqlite3.connect(os.path.join(STATE, "index.sqlite"))
    rows, _, _ = load(db)
    groups, decided = load_groups(), load_review()
    grouped, keep, unreviewed = set(), set(), 0
    for g in groups:
        grouped |= {f["path"] for f in g}
        if not needs_review(g):
            keep.add(g[0]["path"])
        elif gkey(g) in decided:
            keep |= set(decided[gkey(g)])
        else:
            unreviewed += 1
    out = [r for r in rows if r["path"] in keep or (r["path"] not in grouped and r["source"] not in LIBRARY_SKIP)]
    return out, unreviewed


def build(dry_run):
    files, unreviewed = chosen()
    if unreviewed:
        sys.exit(f"photo-merge: {unreviewed} groups unreviewed; run `photo-merge review` first")
    manifest = os.path.join(STATE, "library.tsv")
    placed = {}
    if os.path.exists(manifest):
        with open(manifest) as fh:
            placed = dict(reversed(ln.rstrip("\n").split("\t", 1)) for ln in fh if ln.strip())
    want = {f["path"] for f in files}
    todo = [f for f in files if f["path"] not in placed]
    missing = [f for f in todo if not os.path.exists(f["path"])]
    todo = [f for f in todo if os.path.exists(f["path"])]
    print(f"library: {len(files)} files ({human(sum(f['size'] for f in files))}), {len(placed)} placed,"
          f" {len(todo)} to place" + (f", {len(missing)} gone from their source" if missing else ""))
    if dry_run:
        claimed = set(placed.values())
        for f in todo[:10]:
            rel = free_name(library_path(f), claimed)
            claimed.add(rel)
            print(f"  {rel}  <-  {f['path']}")
        return
    claimed = set(placed.values())
    with open(manifest, "a") as fh:
        for i, f in enumerate(todo, 1):
            rel = free_name(library_path(f), claimed)
            claimed.add(rel)
            reflink(f["path"], os.path.join(LIBRARY, rel))
            # Written per file, so an interrupted build resumes where it stopped.
            fh.write(f"{rel}\t{f['path']}\n")
            fh.flush()
            if i % 2000 == 0:
                print(f"  {i}/{len(todo)}", flush=True)
    stale = sorted((rel, src) for src, rel in placed.items() if src not in want)
    with open(os.path.join(STATE, "library-stale.tsv"), "w") as fh:
        fh.writelines(f"{rel}\t{src}\n" for rel, src in stale)
    print(f"placed {len(todo)}" + (f"; {len(stale)} library files no longer chosen, listed in library-stale.tsv"
                                   if stale else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ix = sub.add_parser("index")
    ix.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1))
    ix.add_argument("--source", action="append", choices=sorted(SOURCES), help="only these (repeatable)")
    sub.add_parser("group")
    sub.add_parser("review")
    sub.add_parser("preview").add_argument("path")
    sub.add_parser("build").add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.cmd == "index":
        index(args.jobs, set(args.source or ()))
    elif args.cmd == "group":
        group()
    elif args.cmd == "review":
        review()
    elif args.cmd == "preview":
        preview(args.path)
    elif args.cmd == "build":
        build(args.dry_run)


if __name__ == "__main__":
    main()
