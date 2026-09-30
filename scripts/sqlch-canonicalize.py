#!/usr/bin/env python3
"""One-shot canonicaliser for sqlch's library.json.

Reads a library, drops known duplicate-station IDs, and rewrites every
remaining station's `group` and `frequency` from a reviewed map (see
docs/superpowers/specs/2026-09-05-sqlch-library-single-source-design.md).
All other fields pass through untouched. Real Philadelphia FM stations get
their real dial position; the four AM stations keep their true AM number;
internet/genre streams get an assigned free Philly slot.

Usage:  sqlch-canonicalize.py [INPUT] [OUTPUT]
        INPUT  defaults to stdin, OUTPUT to stdout.
"""
import json
import sys

# Duplicate stations (same real station twice) — the curated twin is kept.
DROP = {"wioq-q102-philly", "wwip-sports-radio-94-wip", "90s90s-hiphop-rap"}

# Before dropping a duplicate, salvage its stream URL onto the kept twin.
# The kept 90s90s hip-hop entry points at a 64k AAC stream; its dropped twin
# carried the 192k MP3 URL, which is the one Phil wants to keep playing.
URL_FROM_DROPPED = {"90s90s-hip-hop": "90s90s-hiphop-rap"}

# WRTI runs classical on 90.1 analog and jazz on its HD2 subchannel — both 90.1.
_ALLOWED_SHARED = {90.1: {"wrti-classical", "wrti-jazz"}}

# id -> (group, frequency)
MAP = {
    # --- real stations ---
    "wxpn-hd2-xponential": ("Public", 88.1),
    "wxpn-885-philadelphia-pa": ("Public", 88.5),
    "wxvu-villanova-radio": ("College", 89.1),
    "wrti-classical": ("Classical", 90.1),
    "wrti-jazz": ("Jazz", 90.1),
    "whyy-npr": ("News", 90.9),
    "wmmr-mmr-rocks": ("Rock", 93.3),
    "wstw-delaware-valley": ("Top 40", 93.7),
    "wip-sportsradio-philadelphia": ("Sports", 94.1),
    "wpst-top-40-945": ("Top 40", 94.5),
    "wzzo-rock-951": ("Classic Rock", 95.1),
    "wben-ben-fm": ("Easy Listening", 95.7),
    "wtdy-hot-ac-965": ("Top 40", 96.5),
    "wpen-the-fanatic": ("Sports", 97.5),
    "wogl-big-981": ("Oldies", 98.1),
    "wusl-power-99": ("RnB/Hip-Hop", 98.9),
    "wrnb-rnb-and-hip-hop": ("RnB/Hip-Hop", 100.3),
    "wlev-ac-1007": ("News", 100.7),
    "wbeb-b101": ("Easy Listening", 101.1),
    "wkxw-nj-1015": ("Talk", 101.5),
    "wioq-q102": ("Top 40", 102.1),
    "wmgk-classic-rock-1029": ("Classic Rock", 102.9),
    "wprb-princeton-radio": ("College", 103.3),
    "wrff-alt-1045": ("Alternative", 104.5),
    "wdas-urban-1053": ("RnB/Hip-Hop", 105.3),
    "wppm_-_phillycam": ("Philadelphia", 106.5),
    "wurd-talk-900": ("Talk", 900.0),
    "kyw-news-radio-1060": ("News", 1060.0),
    "wpht-talk-1210": ("Talk", 1210.0),
    "wdas-sports-1480": ("Sports", 1480.0),
    # --- internet / genre streams ---
    "ambient_modern": ("Ambient", 88.7),
    "0r_-_lo-fi__lofi_chill_study_hip_hop_relax_background_calm_instrumental_smooth_beats_coffee_work_focus_soft_chillhop": ("Lo-Fi", 88.9),
    "0r_-_music_for_sleep__sleep_relax_calm_meditation_nature_ambient_soft_music_piano_deep_sleep_peaceful_chill_background_slow_gentle_instrumental": ("Sleep", 89.3),
    "jazz_radio_blues": ("Blues", 89.5),
    "radioart-just-blues": ("Blues", 89.7),
    "calm_n_chill_radio": ("Chill", 89.9),
    "bbc_world_service": ("News", 90.5),
    "npr_24_hour_program_stream": ("News", 90.7),
    "jjj-triple-j-unearthed": ("Alternative", 91.3),
    "radio_caprice_-_post-punk": ("Post-Punk", 91.5),
    "radio_caprice_-_post-rock": ("Post-Rock", 91.7),
    "real-punk-radio": ("Punk", 91.9),
    "indie-experience": ("Indie", 92.1),
    "indie-x-fm": ("Indie", 92.3),
    "somafm-indie-pop-rocks-128k-aac": ("Indie", 92.7),
    "ynot-radio-philly": ("Alternative", 92.9),
    "static__90s__2000s_alt_rock": ("Alternative", 95.3),
    "1fm_90s_alternative_radio": ("90s", 95.5),
    "977_90s": ("90s", 95.9),
    "90s90s-hits": ("90s", 96.1),
    "megarock-radio-320k": ("Rock", 96.3),
    "radio_tsop_-_the_sound_of_philadelphia": ("Philadelphia", 96.7),
    "dance-wave-retro": ("Dance", 99.3),
    "90s90s-hip-hop": ("Hip-Hop/Rap", 99.5),
    "triple-m-2000s": ("Alternative", 99.9),
    "neon-radio-80s-90s-pop-dance": ("Pop", 103.7),
    "iheart2000s-radio": ("Pop", 103.9),
    "big-r-radio-80s-and-90s-pop-mix": ("Pop", 106.1),
    "somafm-poptron-128k-mp3": ("Pop", 106.3),
    "101-smooth-jazz": ("Jazz", 107.1),
}


def canonicalize(lib: dict) -> dict:
    by_id = {s["id"]: s for s in lib["stations"]}
    for kept, dropped in URL_FROM_DROPPED.items():
        if kept in by_id and dropped in by_id:
            by_id[kept]["url"] = by_id[dropped]["url"]

    stations = [s for s in lib["stations"] if s["id"] not in DROP]

    unmapped = sorted(s["id"] for s in stations if s["id"] not in MAP)
    if unmapped:
        raise AssertionError(f"stations missing from MAP: {unmapped}")

    fm_used: dict[float, list[str]] = {}
    for s in stations:
        group, freq = MAP[s["id"]]
        s["group"] = group
        s["frequency"] = freq
        if freq < 200:
            fm_used.setdefault(freq, []).append(s["id"])

    for freq, ids in fm_used.items():
        if len(ids) > 1 and set(ids) != _ALLOWED_SHARED.get(freq):
            raise AssertionError(f"FM collision at {freq}: {ids}")

    out = dict(lib)
    out["stations"] = sorted(stations, key=lambda s: (s["frequency"], s["id"]))
    return out


def main() -> None:
    src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
    lib = json.load(src)
    out = canonicalize(lib)
    text = json.dumps(out, indent=2, sort_keys=True)
    if len(sys.argv) > 2:
        with open(sys.argv[2], "w") as f:
            f.write(text + "\n")
    else:
        print(text)


if __name__ == "__main__":
    main()
