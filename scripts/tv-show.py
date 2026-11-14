#!/usr/bin/env python3
"""tv-show — download a YouTube show as a real TV show, so it can be a main
show on an ErsatzTV channel (tv-add's folders only ever become break pools).

    tv-show "Finding Stuff Out (2014)" 'https://youtube.com/playlist?list=…'
    tv-show "Finding Stuff Out (2014)"            # recheck saved URLs for new episodes
    tv-show "Finding Stuff Out (2014)" URL --season 2 --dry-run

Episodes land in $TV_ROOT/<Show (Year)>/Season NN/<Show> - SxxEyy - <topic>.mkv.
The season and episode come from the video title ("S2E5", "Season 3 Episode 1",
"Season 1, Episode 2"). A playlist whose titles carry no numbers is numbered
by playlist position under --season (default 1). Anything left unnumbered
(specials, trailers) is listed and skipped, never guessed.

URLs are saved to assets/yt-curate/show-<slug>.txt (one per line, an optional
season after the URL), so a bare `tv-show "<Show (Year)>"` refetches them all.
<show>/.archive tracks downloaded video ids. A video whose SxxEyy slot is
already on disk is skipped but not archived, since it may be a different video. Finishes by printing the `runtime` line for
modules/ersatztv.nix.
"""
import argparse
import os
import re
import string
import subprocess
import sys
import unicodedata
from pathlib import Path

TV_ROOT = Path(os.environ.get("TV_ROOT", "/srv/Videos/kid_and_henry/television"))
LIST_DIR = Path(os.environ.get("LIST_DIR", Path.home() / "nixos/assets/yt-curate"))
YT_DLP = os.environ.get("YT_DLP", "yt-dlp")

# same pacing and format as yt-curate.sh: unpaced runs trip YouTube's bot check
COMMON = [
    "-f", "bv*[height<=1080]+ba/b[height<=1080]",
    "--merge-output-format", "mkv",
    "--embed-metadata", "--embed-thumbnail",
    "--no-overwrites",
    "--sleep-requests", "1", "--sleep-interval", "5", "--max-sleep-interval", "15",
]

EPISODE = [
    re.compile(r"\bS(\d{1,2})\s*E(\d{1,3})\b", re.IGNORECASE),
    re.compile(r"\bSeason\s*(\d{1,2})\s*[,:-]?\s*(?:Episode|Ep\.?)\s*(\d{1,3})\b", re.IGNORECASE),
]
QUOTED = re.compile(r'["＂“”]([^"＂“”]+)["＂“”]')
CLUTTER = re.compile(r"#?\s*full\s*episodes?|\(\s*\)|\[\s*\]|\bHD\b|\bEp(?:isode)?\.?\s*\d+\b", re.IGNORECASE)


def slug(show: str) -> str:
    base = re.sub(r"\s*\(\d{4}\)$", "", show)
    return re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")


def bare(show: str) -> str:
    return re.sub(r"\s*\(\d{4}\)$", "", show)


def episode_number(title: str):
    for pat in EPISODE:
        if m := pat.search(title):
            return int(m.group(1)), int(m.group(2))
    return None


def strip_emoji(s: str) -> str:
    return "".join(c for c in s if unicodedata.category(c) != "So"
                   and not 0xFE00 <= ord(c) <= 0xFE0F and c != "‍")


def topic(title: str, show: str) -> str:
    """The episode's own name: quoted text if any, else the title with the
    show name, SxEy marker and "Full Episode" boilerplate cut."""
    if m := QUOTED.search(title):
        name = m.group(1)
    else:
        name = title
        for pat in EPISODE:
            name = pat.sub("", name)
        name = name.replace("®", "")
        show_pat = r"[\s:]*".join(map(re.escape, bare(show).split()))
        name = re.sub(show_pat, "", name, flags=re.IGNORECASE)
        parts = [p for p in (CLUTTER.sub("", p).strip(" -–—:|,") for p in re.split(r"\|| - ", name)) if p]
        # "Show - Gets Eaten - Ep. 2": the episode is whatever's left once the show is cut
        parts = [" - ".join(parts)] if parts else []
        name = parts[0] if parts else ""
    name = strip_emoji(name)
    name = re.sub(r"[/\\]", "-", name)
    name = re.sub(r"\s+", " ", name).strip(" -–—:,.")
    if name.isupper():
        name = string.capwords(name)
    return name


def clean_url(url: str) -> str:
    url = re.sub(r"([?&])si=[^&]*&?", r"\1", url)
    return re.sub(r"[?&]$", "", url)


def read_list(path: Path):
    """[(url, season-or-None)] from a show list."""
    out = []
    if path.exists():
        for line in path.read_text().splitlines():
            fields = line.split("#", 1)[0].split()
            if fields:
                season = int(fields[1]) if len(fields) > 1 and fields[1].isdigit() else None
                out.append((clean_url(fields[0]), season))
    return out


def add_to_list(path: Path, show: str, urls, season):
    have = {u for u, _ in read_list(path)}
    new = [u for u in map(clean_url, urls) if u not in have]
    if not path.exists():
        path.write_text(f"# show: {show}\n# fetched by scripts/tv-show.py; an optional season follows a URL\n")
        print(f"new list: {path}")
    with path.open("a") as f:
        for u in new:
            f.write(f"{u} {season}\n" if season else f"{u}\n")
    return new


def listing(url: str):
    """[(id, playlist_index-or-None, title, seconds-or-None)] without downloading."""
    res = subprocess.run(
        [YT_DLP, "--flat-playlist", "--print",
         "%(id)s\t%(playlist_index)s\t%(title)s\t%(duration)s", url],
        check=False, capture_output=True, text=True)
    if res.returncode:
        sys.stderr.write(res.stderr)
        raise RuntimeError(f"couldn't list {url}")
    rows = []
    for line in res.stdout.splitlines():
        vid, idx, title, dur = (line.split("\t") + ["NA"] * 4)[:4]
        rows.append((vid, int(idx) if idx.isdigit() else None, title,
                     float(dur) if dur not in ("NA", "None", "") else None))
    return rows


def plan(rows, show, season_hint):
    """Each row → (id, season, episode, filename) or (id, None, None, title) if unnumbered.
    Position numbering only applies when no title in the playlist carries a number."""
    numbered = any(episode_number(t) for _, _, t, _ in rows)
    out = []
    for vid, idx, title, _ in rows:
        se = episode_number(title)
        if not se and not numbered and idx is not None:
            se = (season_hint or 1, idx)
        if not se:
            out.append((vid, None, None, title))
            continue
        s, e = se
        name = f"{bare(show)} - S{s:02d}E{e:02d}"
        if t := topic(title, show):
            name += f" - {t}"
        out.append((vid, s, e, name))
    return out


def is_episode(p: Path) -> bool:
    # yt-dlp's per-stream pieces (Name.f399.mp4) linger after an interrupted merge
    return p.suffix in {".mkv", ".mp4", ".webm"} and not re.search(r"\.f\d+$", p.stem)


def existing(show_dir: Path, s: int, e: int):
    season = show_dir / f"Season {s:02d}"
    tag = re.compile(rf"\bS{s:02d}E{e:02d}\b", re.IGNORECASE)
    return season.is_dir() and any(
        tag.search(p.name) and is_episode(p) for p in season.iterdir())


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("show", help='folder name, "Title (Year)"')
    ap.add_argument("urls", nargs="*", help="videos or playlists; none = every saved URL")
    ap.add_argument("--season", type=int, help="season for a playlist with unnumbered titles")
    ap.add_argument("--dry-run", action="store_true", help="show what would download")
    a = ap.parse_args(argv)

    if not re.search(r"\(\d{4}\)$", a.show):
        ap.error('show must end in its year, e.g. "Finding Stuff Out (2014)", so Jellyfin matches it')
    show_dir = TV_ROOT / a.show
    archive = show_dir / ".archive"
    lst = LIST_DIR / f"show-{slug(a.show)}.txt"

    if a.urls and not a.dry_run:
        add_to_list(lst, a.show, a.urls, a.season)
        todo = [(clean_url(u), a.season) for u in a.urls]
    elif a.urls:
        todo = [(clean_url(u), a.season) for u in a.urls]
    else:
        todo = read_list(lst)
        if not todo:
            ap.error(f"no URLs given and nothing saved in {lst}")

    done = set(archive.read_text().split("\n")) if archive.exists() else set()
    claimed = {}   # (season, episode) -> title, so two playlists can't share a slot
    fail = skipped = 0
    for url, season in todo:
        try:
            rows = listing(url)
        except RuntimeError as err:
            print(err, file=sys.stderr)
            fail += 1
            continue
        for vid, s, e, name in plan(rows, a.show, season):
            if f"youtube {vid}" in done:
                continue
            if s is None:
                print(f"no episode number, skipped: {name}")
                skipped += 1
                continue
            if (s, e) in claimed:
                print(f"S{s:02d}E{e:02d} is already {claimed[s, e]!r}; skipped: {name}"
                      f" (give this playlist its own season after the URL)", file=sys.stderr)
                fail += 1
                continue
            claimed[s, e] = name
            if existing(show_dir, s, e):
                # not archived: a taken slot may hold a different video (another
                # playlist, a wrong --season), and archiving would hide this one
                print(f"S{s:02d}E{e:02d} already on disk, skipped: {name}")
                continue
            if a.dry_run:
                print(f"would fetch: Season {s:02d}/{name}.mkv")
                continue
            (show_dir / f"Season {s:02d}").mkdir(parents=True, exist_ok=True)
            out = show_dir / f"Season {s:02d}" / f"{name}.%(ext)s"
            res = subprocess.run([YT_DLP, *COMMON, "--no-playlist", "--download-archive", str(archive),
                                  "-o", str(out), f"https://www.youtube.com/watch?v={vid}"], check=False)
            if res.returncode:
                print(f"failed: {name}", file=sys.stderr)
                fail += 1

    eps = [p for p in show_dir.glob("Season */*") if is_episode(p)]
    if eps and not a.dry_run:
        mins = [m for m in map(minutes, eps) if m]
        avg = f"{sum(mins) / len(mins):.1f}" if mins else "?"
        print(f'\nmodules/ersatztv.nix runtime: "{bare(a.show)}" = {{ eps = {len(eps)}; mins = {avg}; }};')
    if skipped:
        print(f"{skipped} unnumbered video(s) skipped; file any you want by hand as SxxEyy")
    return 1 if fail else 0


def minutes(path: Path):
    res = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", str(path)], check=False, capture_output=True, text=True)
    try:
        return float(res.stdout.strip()) / 60
    except ValueError:
        return None


if __name__ == "__main__":
    sys.exit(main())
