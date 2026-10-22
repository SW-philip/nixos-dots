#!/usr/bin/env python3
"""Trim YouTube title clutter from video filenames, since ErsatzTV uses the
filename as the guide title.

    Spork! | Read Aloud Kids Book | Vooks Narrated Storybooks.mkv  ->  Spork!.mkv
    Bedtime Story for Kids: At the Stroke of Goodnight | Vooks…   ->  At the Stroke of Goodnight.mkv
    Kooki's Crafty Show | Hippo Bookmark.mkv                      ->  Kooki's Crafty Show - Hippo Bookmark.mkv

The title splits on "|" (or " --- " / " — "); segments after the first that are only channel or
genre boilerplate (BOILER) are dropped, and a boilerplate lead-in ending in
": " is cut from any segment. The first segment always stays, so a title
that is all boilerplate is never emptied. Emoji go too.

Dry run by default; --apply renames. A name that would collide is skipped.

Usage:  tidy-titles.py DIR... [--apply]
"""
import argparse
import re
import sys
import unicodedata
from pathlib import Path

VIDEO = {".mkv", ".mp4", ".webm"}

# whole segments that say nothing about this particular video
BOILER = re.compile(
    r"read aloud|kids?'? books?|kids story|story for kids|storybooks?|for kids|for children"
    r"|for preschoolers|for toddlers|for babies|^brain breaks?$|^science$|^read aloud$"
    r"|vooks|jack hartmann|pbs kids|danny go|zoomoo|hopscotch|telelingo"
    r"|spanish (immersion|learning)|aprende|learn about",
    re.IGNORECASE,
)


def strip_emoji(s: str) -> str:
    return "".join(
        c for c in s
        if unicodedata.category(c) != "So"
        and not 0xFE00 <= ord(c) <= 0xFE0F  # variation selectors
        and not 0x1F3FB <= ord(c) <= 0x1F3FF  # skin tones
        and ord(c) != 0x200D
    )


def clean(title: str) -> str:
    kept = []
    for i, seg in enumerate(re.split(r"\||\s-{2,}\s|\s—\s", strip_emoji(title))):
        seg = " ".join(seg.split())
        if len(seg) > 2 and seg[0] == seg[-1] == '"':
            seg = seg[1:-1]
        head, sep, rest = seg.partition(": ")
        if sep and rest and BOILER.search(head):
            seg = rest
        if seg and (i == 0 or not BOILER.search(seg)):
            kept.append(seg)
    return " - ".join(kept) or title.strip()


def tidy_dir(d: Path, apply: bool) -> int:
    """Rename every video in d; returns how many were skipped as collisions."""
    skipped = 0
    for f in sorted(d.iterdir()):
        if f.suffix.lower() not in VIDEO or not f.is_file():
            continue
        new = f.with_name(clean(f.stem) + f.suffix)
        if new == f:
            continue
        if new.exists():
            print(f"skip (exists): {f.name} -> {new.name}", file=sys.stderr)
            skipped += 1
            continue
        print(f"{f.name}\n  -> {new.name}")
        if apply:
            f.rename(new)
    return skipped


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dirs", nargs="+", type=Path)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    skipped = sum(tidy_dir(d, args.apply) for d in args.dirs)
    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main())
