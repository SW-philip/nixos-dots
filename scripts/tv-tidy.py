#!/usr/bin/env python3
"""Reorganise a TV library into Jellyfin's naming scheme.

    <Show (Year)>/Season NN/<Show (Year)> SxxEyy.ext
    <Show (Year)>/extras/<anything found under Featurettes/Extras>

Release-group clutter (scene .nfo, .txt, screenshots, partial downloads) moves
to <root>/.tv-tidy-junk/ (Jellyfin skips dot-dirs); nothing is deleted except
directories left empty. XML .nfo files are real metadata: an episode's follows
the episode, a show's tvshow.nfo and artwork stay with the show. Anything not
recognised is left in place and listed.

--titles: a video with no episode number is matched by its title against the
show's TVmaze episode list (cached in ~/.local/state/tv-tidy/tvmaze/), for rips
named "Show - Episode Title.mp4". Weak matches are listed, not moved.

Dry run by default. --apply moves files and writes an undo log to
~/.local/state/tv-tidy/; --undo LOG puts every file back.

Usage:  tv-tidy.py [ROOT] [--apply] [--show NAME] [--titles]
        tv-tidy.py --undo LOG
"""
import argparse
import functools
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from difflib import SequenceMatcher
from pathlib import Path

DEFAULT_ROOT = Path("/srv/Videos/mom_and_dad/television")
JUNK_DIR = ".tv-tidy-junk"
STATE = Path.home() / ".local/state/tv-tidy"

# top-level folder -> canonical "Title (Year)". Folders already shaped like
# "Title (Year)" need no entry.
SHOWS = {
    "Ashes to Ashes (2008) Season 1-3 S01-S03 (576p DVD x265 HEVC 10bit AAC 5.1 Panda)":
        "Ashes to Ashes (2008)",
    "Better Off Ted (1080p AV1.Opus muxed.encoded by VerbaL)": "Better Off Ted (2009)",
    "community": "Community (2009)",
    "Euphoria": "Euphoria (2019)",
    "game_of_thrones": "Game of Thrones (2011)",
    "House of the Dragon": "House of the Dragon (2022)",
    "Letterkenny": "Letterkenny (2016)",
    "Life on Mars UK 2006 S01-S02 720p WEB-DL HEVC x265 BONE": "Life on Mars (2006)",
    "rupauls_drag_race": "RuPaul's Drag Race (2009)",
    "Spaced 1999 S01-S02 720p WEB-DL HEVC x265 BONE": "Spaced (1999)",
    "The IT Crowd": "The IT Crowd (2006)",
    "untucked": "RuPaul's Drag Race Untucked (2010)",
    # kid_and_henry
    "AAAHH, REAL MONSTERS (1994-1997) - Complete ANIMATED TV Series, S01-S04 - 480p DVDRip x264":
        "Aaahh!!! Real Monsters (1994)",
    "Angry Beavers": "The Angry Beavers (1997)",
    "CatDog (1998-2005) - Complete ANIMATED TV Series, S01-S04 - 1080p Web-DL x264":
        "CatDog (1998)",
    "Gravity Falls 2012 Season 2 Complete + EXTRAS 720p BluRay x264": "Gravity Falls (2012)",
    "My Brother and Me - Complete TV Series - 480p DVDRip": "My Brother and Me (1994)",
    "Pokemon Complete Series (Season 01-25+Movies+Specials+Shorts+OST) [DVD+BD][1080p][HEVC 10bit x265][AAC]":
        "Pokémon (1997)",
    "Sago Mini Friends": "Sago Mini Friends (2022)",
    "sesame_street": "Sesame Street (1969)",
}

# shows whose files are bare "NN - Title" with no Season folder: the season they belong to
FLAT_SEASON = {"Toca Life Stories (2020)": 1}

VIDEO = {".mkv", ".mp4", ".avi", ".m4v", ".mov", ".ts", ".webm"}
SUBS = {".srt", ".ass", ".ssa", ".sub", ".idx", ".vtt", ".sup"}
JUNK = {".txt", ".nfo", ".jpg", ".jpeg", ".png", ".webp", ".website", ".url",
        ".part", ".sfv", ".md5", ".exe", ".nzb", ".torrent", ".db"}
SHOW_ART = {"poster", "fanart", "folder", "banner", "logo", "clearlogo", "clearart",
            "backdrop", "landscape", "thumb", "discart", "characterart"}
EXTRAS_DIRS = {"featurettes", "extras", "bonus", "behind the scenes", "deleted scenes"}

_SXE = re.compile(r"[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})(?:-?[Ee](\d{1,3}))?")
_WORDS = re.compile(r"Season[ ._-]?(\d{1,2})[ ._-]*Episode[ ._-]?(\d{1,3})", re.IGNORECASE)
_NXN = re.compile(r"(?<![\dx])(\d{1,2})x(\d{2,3})(?!\d)")
# absolute numbering inside a "Season NN" folder: "[grp] Pokemon - 024 - Title"
_SEASON_DIR = re.compile(r"^Season[ ._-]?(\d{1,2})\b", re.IGNORECASE)
_ABS = re.compile(r"(?:^|\s-\s)(?:Ep\.?\s*)?(\d{1,3})\s-\s", re.IGNORECASE)
_CANON = re.compile(r"^.+ \(\d{4}\)$")
_YEAR = re.compile(r"^(.+) \((\d{4})\)$")
_ROMAN = {"ii": "2", "iii": "3", "iv": "4", "v": "5"}
TVMAZE = "https://api.tvmaze.com/singlesearch/shows?embed=episodes&q="
# trailing ".en", ".eng", ".forced", ".en.sdh" … on a subtitle stem
_SUB_TAGS = re.compile(r"((?:\.(?:[a-z]{2,3}|forced|sdh|cc|default))+)$", re.IGNORECASE)


def episode(name):
    """'S01E02' / 'S01E02-E03' for a filename, or None."""
    m = _SXE.search(name)
    if m:
        s, e, e2 = m.groups()
    else:
        m = _WORDS.search(name) or _NXN.search(name)
        if not m:
            return None
        (s, e), e2 = m.groups(), None
    tag = f"S{int(s):02d}E{int(e):02d}"
    return tag + (f"-E{int(e2):02d}" if e2 else "")


def folder_episode(top, show, src):
    """'S01E24' from a Season-NN ancestor (or FLAT_SEASON) plus a bare episode number."""
    m = _ABS.search(src.name)
    if not m:
        return None
    season = FLAT_SEASON.get(show)
    for d in src.relative_to(top).parts[-2::-1]:
        s = _SEASON_DIR.match(d)
        if s:
            season = int(s.group(1))
            break
    return None if season is None else f"S{season:02d}E{int(m.group(1)):02d}"


def _norm(s):
    """'Muscular Beaver II' and 'Muscular-Beaver 2' both -> 'muscularbeaver2'."""
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return "".join(_ROMAN.get(w, w) for w in re.findall(r"[a-z0-9]+", s.replace("&", " and ")))


@functools.cache
def tvmaze_episodes(show):
    """[(tag, normalised title, title)] from TVmaze, or None if it has no such show."""
    cache = STATE / "tvmaze" / f"{show}.json"
    if cache.exists():
        data = json.loads(cache.read_text())
    else:
        title, year = _YEAR.match(show).groups()
        try:
            with urllib.request.urlopen(TVMAZE + urllib.parse.quote(title), timeout=20) as r:
                data = json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
            return None
        # singlesearch returns its best guess even for a different show of the same name
        if (data.get("premiered") or "")[:4] != year:
            return None
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(data))
    return [(f"S{e['season']:02d}E{e['number']:02d}", _norm(e["name"]), e["name"])
            for e in data["_embedded"]["episodes"] if e["number"] is not None]


def title_episode(show, src):
    """('S03E09', None) by matching src's title against TVmaze, or (None, why)."""
    eps = tvmaze_episodes(show)
    if not eps:
        return None, "no episode number, and TVmaze has no episode list for the show"
    name = _norm(src.stem)
    base = _YEAR.match(show).group(1)
    for prefix in (_norm(base), _norm(re.sub(r"^the ", "", base, flags=re.IGNORECASE))):
        if name.startswith(prefix):
            name = name[len(prefix):]
            break
    if not name:
        return None, "no episode number or title in the name"

    # rips often cut titles short ("Mission to the Big H"), so a prefix is a hit too
    def score(ep):
        title = ep[1]
        fuzzy = max(SequenceMatcher(None, name, title).ratio(),
                    SequenceMatcher(None, name, title[: len(name)]).ratio())
        return (name == title, title.startswith(name), len(name) >= 5 and name in title, fuzzy)

    best = max(eps, key=score)
    s = score(best)
    if any(s[:3]) or s[3] >= 0.8:
        return best[0], None
    return None, f"no confident TVmaze title match (closest: {best[0]} {best[2]})"


def is_xml(path):
    with path.open("rb") as fh:
        return b"<?xml" in fh.read(64)


def show_name(top):
    if top in SHOWS:
        return SHOWS[top]
    return top if _CANON.match(top) else None


def plan(root, only=None, titles=False):
    """Return (moves, problems). moves: [(src, dst)]; problems: [(path, why)]."""
    moves, problems = [], []
    for top in sorted(p for p in root.iterdir() if p.is_dir()):
        if top.name.startswith("."):
            continue
        show = show_name(top.name)
        if only and only.lower() not in (show or top.name).lower():
            continue
        if not show:
            problems.append((top, "no SHOWS entry — add one to tv-tidy.py"))
            continue
        for dirpath, dirnames, filenames in os.walk(top):
            dirnames.sort()
            for f in sorted(filenames):
                src = Path(dirpath) / f
                dst = target(root, top, show, src, titles)
                if isinstance(dst, str):
                    problems.append((src, dst))
                elif dst != src:
                    moves.append((src, dst))
    return resolve_collisions(moves, problems)


def target(root, top, show, src, titles=False):
    """Destination path, or a string saying why the file stays put."""
    ext = src.suffix.lower()
    parts = {p.lower() for p in src.relative_to(top).parts[:-1]}
    if ext in VIDEO and parts & EXTRAS_DIRS:
        return root / show / "extras" / src.name
    ep = episode(src.name) or (folder_episode(top, show, src) if ext in VIDEO else None)
    if not ep and titles and ext in VIDEO:
        ep, why = title_episode(show, src)
        if not ep:
            return why
    season = root / show / f"Season {ep[1:3]}" if ep else None
    if ep and ext in VIDEO:
        return season / f"{show} {ep}{ext}"
    if ep and ext in SUBS:
        # already renamed by an earlier run, with a suffix _SUB_TAGS can't parse ("2_English")
        if src.parent == season and src.name.startswith(f"{show} {ep}."):
            return src
        m = _SUB_TAGS.search(src.stem)
        tags = m.group(1) if m and episode(src.stem[: m.start()]) else ""
        return season / f"{show} {ep}{tags}{ext}"
    if ext in SUBS:
        # Subs/<episode release dir>/2_English.srt — the episode is in the folder
        ep = episode(src.parent.name)
        if ep:
            return root / show / f"Season {ep[1:3]}" / f"{show} {ep}.{src.stem}{ext}"
    if ext in VIDEO:
        return "video with no episode number, left alone"
    if src.parent == top and (src.name == "tvshow.nfo" or src.stem.lower() in SHOW_ART):
        return root / show / src.name
    if ext == ".nfo" and is_xml(src):
        return season / f"{show} {ep}.nfo" if ep else "XML metadata, left alone"
    if ext in JUNK:
        return root / JUNK_DIR / src.relative_to(root)
    return "unrecognised file type, left alone"


def resolve_collisions(moves, problems):
    by_dst = defaultdict(list)
    for src, dst in moves:
        by_dst[dst].append(src)
    sources = {src for src, _ in moves}
    keep = []
    for dst, srcs in by_dst.items():
        if len(srcs) > 1:
            for s in srcs:
                problems.append((s, f"same target as {len(srcs) - 1} other file(s): {dst.name}"))
        elif dst.exists() and dst not in sources:
            problems.append((srcs[0], f"target already exists: {dst}"))
        else:
            keep.append((srcs[0], dst))
    return sorted(keep), problems


def report(root, moves, problems):
    rel = lambda p: str(p.relative_to(root))
    shows = defaultdict(list)
    for src, dst in moves:
        shows[dst.relative_to(root).parts[0]].append((src, dst))
    for show, items in sorted(shows.items()):
        print(f"\n== {show}  ({len(items)})")
        for src, dst in items:
            print(f"  {rel(src)}\n    -> {rel(dst)}")
    if problems:
        print(f"\n== needs a look  ({len(problems)})")
        for path, why in problems:
            print(f"  {rel(path)}\n    !! {why}")
    junk = sum(1 for _, d in moves if d.relative_to(root).parts[0] == JUNK_DIR)
    print(f"\n{len(moves)} moves ({junk} to {JUNK_DIR}/), {len(problems)} to look at")


def prune(root, dirs):
    for d in sorted(dirs, key=lambda p: len(p.parts), reverse=True):
        while d != root and d.is_dir() and not any(d.iterdir()):
            d.rmdir()
            d = d.parent


def apply(root, moves):
    STATE.mkdir(parents=True, exist_ok=True)
    log = STATE / f"{time.strftime('%Y%m%d-%H%M%S')}.tsv"
    with log.open("w") as fh:
        fh.write(f"#root\t{root}\n")
        for src, dst in moves:
            dst.parent.mkdir(parents=True, exist_ok=True)
            # rename(2) would silently replace; plan() only rules out pre-existing targets
            if dst.exists():
                print(f"skip, appeared since planning: {dst}", file=sys.stderr)
                continue
            src.rename(dst)
            fh.write(f"{dst}\t{src}\n")
            fh.flush()
    prune(root, {src.parent for src, _ in moves})
    print(f"\nundo log: {log}\nundo with: tv-tidy.py --undo {log}")


def undo(log):
    lines = Path(log).read_text().splitlines()
    root = Path(lines[0].split("\t")[1])
    moved = []
    for line in reversed(lines[1:]):
        dst, src = map(Path, line.split("\t"))
        if src.exists():
            print(f"skip, original path occupied: {src}", file=sys.stderr)
            continue
        src.parent.mkdir(parents=True, exist_ok=True)
        dst.rename(src)
        moved.append(dst)
    prune(root, {p.parent for p in moved})
    print(f"restored {len(moved)} files")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", nargs="?", type=Path, default=DEFAULT_ROOT)
    ap.add_argument("--apply", action="store_true", help="actually move files")
    ap.add_argument("--show", help="only shows whose name contains this")
    ap.add_argument("--titles", action="store_true",
                    help="match unnumbered videos to TVmaze episode titles")
    ap.add_argument("--undo", metavar="LOG", help="reverse a previous --apply")
    a = ap.parse_args(argv)
    if a.undo:
        return undo(a.undo)
    root = a.root.resolve()
    moves, problems = plan(root, a.show, a.titles)
    report(root, moves, problems)
    if a.apply:
        apply(root, moves)
    elif moves:
        print("dry run — re-run with --apply to move")


if __name__ == "__main__":
    main()
