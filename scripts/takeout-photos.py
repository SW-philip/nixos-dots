#!/usr/bin/env python3
"""takeout-photos: unpack Google Photos Takeout archives into <dest>/YYYY/YYYY-MM-DD/.

  takeout-photos [--dry-run] [--dest DIR] [ARCHIVE...]

Default archives: ~/Downloads/[Tt]akeout*.tgz. Default dest: ~/Pictures/Google Photos.
Archives are never modified. Every part is unpacked before any file is placed, because
Takeout splits a photo and its .json sidecar across parts at random. Each placed file
gets its date (and GPS/people when the file lacks them) written from the sidecar.
.takeout-import.tsv in dest maps every placed file back to its Takeout path (the only
record of album membership) and to the sha256 of the file as it came out of the archive.
A file whose sha256 is already listed is skipped, so the year-folder and album copies
Takeout emits collapse to one and re-running over the same archives is a no-op; the
hash has to be of the original, since writing metadata changes the placed file.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime

MEDIA_EXT = {
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".gif", ".webp", ".avif", ".bmp", ".tif", ".tiff",
    ".dng", ".cr2", ".nef", ".arw", ".raw",
    ".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".mpg", ".wmv",
}
EDITED = ("-edited", "-bearbeitet", "-modifié", "-editado")
SUPPL = ".supplemental-metadata"
# Takeout cuts sidecar names to 51 chars including ".json"; anything this long may be cut.
TRUNC_AT = 46
DUP_RE = re.compile(r"^(?P<stem>.*)\((?P<n>\d+)\)(?P<ext>\.[^.]+)$")
JSON_N_RE = re.compile(r"^(?P<key>.*)\((?P<n>\d+)\)$")
YEAR_DIR_RE = re.compile(r"^Photos from (\d{4})$")


def split_dup(name):
    """'IMG(1).jpg' -> ('IMG.jpg', '1'); 'IMG.jpg' -> ('IMG.jpg', None)."""
    m = DUP_RE.match(name)
    return (m["stem"] + m["ext"], m["n"]) if m else (name, None)


def sidecar_for(media, jsons):
    """Pick the Takeout sidecar for `media` from the .json names in its directory."""
    base, n = split_dup(media)
    stem, ext = os.path.splitext(base)
    cands = [base] + [stem[: -len(s)] + ext for s in EDITED if stem.endswith(s)]
    keyed = []
    for j in jsons:
        k = j[: -len(".json")]
        m = JSON_N_RE.match(k)
        keyed.append(((m["key"], m["n"]) if m else (k, None), j))
    for cand in cands:
        cstem = os.path.splitext(cand)[0]
        full = cand + SUPPL
        best = None
        for (k, jn), j in keyed:
            if jn != n or not k:
                continue
            exact = k in (full, cand, cstem)
            if (exact or (len(k) >= TRUNC_AT and full.startswith(k))) and (best is None or len(k) > len(best[0])):
                best = (k, j)
        if best:
            return best[1]
    # Live-photo videos (IMG_1234.MP4 beside IMG_1234.HEIC) usually have no sidecar of their own.
    for (k, jn), j in keyed:
        if jn == n and k.startswith(stem + ".") and not k.startswith(base):
            return j
    return None


def parse_exif_date(v):
    if not isinstance(v, str) or len(v) < 19:
        return None
    try:
        d = datetime.strptime(v[:19], "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None
    return d if 1990 <= d.year <= datetime.now().year + 1 else None


def read_exif(root):
    out = subprocess.run(
        ["exiftool", "-j", "-q", "-q", "-r", "-api", "QuickTimeUTC=1",
         "-DateTimeOriginal", "-CreateDate", "-GPSLatitude", "-FileTypeExtension", root],
        capture_output=True, text=True, check=False,
    ).stdout
    try:
        return {r["SourceFile"]: r for r in json.loads(out or "[]")}
    except json.JSONDecodeError:
        return {}


def true_name(name, actual):
    """Google re-encodes some HEIC/PNG uploads to JPEG but keeps the old extension, and
    exiftool refuses to write a file whose extension lies about its type."""
    stem, ext = os.path.splitext(name)
    if not actual:
        return name
    norm = {"jpeg": "jpg", "tif": "tiff"}
    if norm.get(ext[1:].lower(), ext[1:].lower()) == norm.get(actual.lower(), actual.lower()):
        return name
    return f"{stem}.{actual.upper() if ext[1:].isupper() else actual.lower()}"


def load_sidecar(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {}


def unpack(archives, staging):
    for a in archives:
        print(f"unpacking {os.path.basename(a)}", flush=True)
        r = subprocess.run(
            ["tar", "-xzf", a, "-C", staging, "--wildcards", "Takeout/Google Photos/*"],
            capture_output=True, text=True, check=False,
        )
        if r.returncode:
            print(f"  warning: {a}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'tar failed'}",
                  file=sys.stderr)


def walk_media(root):
    # Year folders first, so the canonical copy of an album photo comes from "Photos from YYYY".
    dirs = sorted(os.walk(root), key=lambda t: (not os.path.basename(t[0]).startswith("Photos from"), t[0]))
    for d, _, files in dirs:
        jsons = [f for f in files if f.endswith(".json")]
        for f in sorted(files):
            if os.path.splitext(f)[1].lower() in MEDIA_EXT:
                yield d, f, jsons


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_seen(manifest):
    try:
        with open(manifest) as fh:
            return {cols[3] for cols in (line.rstrip("\n").split("\t") for line in fh) if len(cols) > 3}
    except OSError:
        return set()


def place(src, dest_dir, name):
    os.makedirs(dest_dir, exist_ok=True)
    stem, ext = os.path.splitext(name)
    i = 0
    while True:
        target = os.path.join(dest_dir, name if i == 0 else f"{stem}_{i}{ext}")
        if not os.path.exists(target):
            os.replace(src, target)
            return target
        i += 1


def write_args(path, when, meta, exif):
    args = ["-overwrite_original", "-q", "-m", "-api", "QuickTimeUTC=1"]
    stamp = when.strftime("%Y:%m:%d %H:%M:%S")
    if not (parse_exif_date(exif.get("DateTimeOriginal")) or parse_exif_date(exif.get("CreateDate"))):
        args.append(f"-AllDates={stamp}")
    geo = meta.get("geoData") or {}
    lat, lon = geo.get("latitude") or 0, geo.get("longitude") or 0
    if (lat or lon) and "GPSLatitude" not in exif:
        args += [f"-GPSLatitude={abs(lat)}", f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
                 f"-GPSLongitude={abs(lon)}", f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}"]
    for p in meta.get("people") or []:
        if (p.get("name") or "").strip():
            args.append(f"-XMP-iptcExt:PersonInImage+={p['name'].strip()}")
    args.append(f"-FileModifyDate={stamp}")
    return args + [path, "-execute"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("archives", nargs="*")
    ap.add_argument("--dest", default=os.path.expanduser("~/Pictures/Google Photos"))
    ap.add_argument("--dry-run", action="store_true", help="unpack and report, place nothing")
    opt = ap.parse_args()

    archives = opt.archives or sorted(
        glob.glob(os.path.expanduser("~/Downloads/[Tt]akeout*.tgz")))
    if not archives:
        sys.exit("no archives (looked for ~/Downloads/[Tt]akeout*.tgz)")
    for tool in ("exiftool", "tar"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not on PATH")

    os.makedirs(opt.dest, exist_ok=True)
    # Staging lives under dest so placing a file is a rename on the same filesystem.
    staging = tempfile.mkdtemp(prefix=".staging-", dir=opt.dest)
    try:
        unpack(archives, staging)
        root = os.path.join(staging, "Takeout", "Google Photos")
        if not os.path.isdir(root):
            sys.exit("no Google Photos content in these archives")
        print("reading existing metadata", flush=True)
        exif = read_exif(root)

        manifest_path = os.path.join(opt.dest, ".takeout-import.tsv")
        seen = load_seen(manifest_path)
        counts = {"placed": 0, "duplicate": 0, "exif": 0, "sidecar": 0, "undated": 0}
        years = {}
        writes = []
        # Appended per file, so an interrupted run still knows what it already placed.
        manifest = open(manifest_path, "a")  # noqa: SIM115
        for d, f, jsons in walk_media(root):
            src = os.path.join(d, f)
            ex = exif.get(src, {})
            j = sidecar_for(f, jsons)
            meta = load_sidecar(os.path.join(d, j)) if j else {}
            when = parse_exif_date(ex.get("DateTimeOriginal")) or parse_exif_date(ex.get("CreateDate"))
            how = "exif"
            if not when:
                ts = (meta.get("photoTakenTime") or {}).get("timestamp")
                when = datetime.fromtimestamp(int(ts)) if ts and str(ts).isdigit() and int(ts) > 0 else None
                how = "sidecar" if when else "undated"
            counts[how] += 1
            folder_year = YEAR_DIR_RE.match(os.path.basename(d))
            if when:
                sub = os.path.join(f"{when:%Y}", f"{when:%Y-%m-%d}")
            elif folder_year:
                sub = os.path.join(folder_year[1], "unknown-day")
            else:
                sub = "undated"
            label = sub.split(os.sep)[0]
            rel = os.path.relpath(src, root)
            if opt.dry_run:
                years[label] = years.get(label, 0) + 1
                continue
            digest = sha256(src)
            if digest in seen:
                counts["duplicate"] += 1
                continue
            seen.add(digest)
            target = place(src, os.path.join(opt.dest, sub), true_name(f, ex.get("FileTypeExtension")))
            counts["placed"] += 1
            years[label] = years.get(label, 0) + 1
            manifest.write(f"{os.path.relpath(target, opt.dest)}\t{rel}\t{how}\t{digest}\n")
            manifest.flush()
            if when:
                writes += write_args(target, when, meta, ex)

        manifest.close()
        if writes:
            print(f"writing metadata to {counts['placed']} files", flush=True)
            with tempfile.NamedTemporaryFile("w", delete=False, dir=opt.dest, prefix=".exif-") as fh:
                fh.write("\n".join(writes) + "\n")
            try:
                subprocess.run(["exiftool", "-@", fh.name], check=False)
            finally:
                os.unlink(fh.name)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    print("\n" + "  ".join(f"{k}: {v}" for k, v in counts.items()))
    for y in sorted(years):
        print(f"  {y}: {years[y]}")


if __name__ == "__main__":
    main()
