#!/usr/bin/env python3
# Reads the TITLE field out of a PS3 PARAM.SFO (the small Sony-authored
# key/value blob every disc/PKG ships at PS3_GAME/PARAM.SFO). Used by
# skyscraper-scrape.sh to get a real searchable game name for RPCS3 dumps,
# since every dump's actual rom file is identically named EBOOT.BIN --
# Skyscraper's filename-based search has nothing useful to go on otherwise.
#
# Format: 20-byte header (magic, version, key_table_start, data_table_start,
# entry count), then one 16-byte index entry per key (key_offset, data_fmt,
# data_len, data_max_len, data_offset), then a null-terminated-string key
# table, then a data table. See:
# https://www.psdevwiki.com/ps3/PARAM.SFO
import struct
import sys


def parse_sfo(path):
    with open(path, "rb") as f:
        data = f.read()

    magic, _version, key_table_start, data_table_start, entries = struct.unpack_from(
        "<4sIIII", data, 0
    )
    if magic != b"\x00PSF":
        raise ValueError(f"{path}: not a PARAM.SFO (bad magic {magic!r})")

    result = {}
    for i in range(entries):
        key_offset, data_fmt, data_len, _data_max_len, data_offset = struct.unpack_from(
            "<HHIII", data, 20 + i * 16
        )
        key_start = key_table_start + key_offset
        key_end = data.index(b"\x00", key_start)
        key = data[key_start:key_end].decode("ascii")

        val_start = data_table_start + data_offset
        raw = data[val_start:val_start + data_len]
        if data_fmt in (0x0204, 0x0004):  # UTF-8 string types
            value = raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
        elif data_fmt == 0x0404:  # int32
            value = struct.unpack_from("<i", raw)[0] if len(raw) >= 4 else None
        else:
            value = raw
        result[key] = value
    return result


def main():
    if len(sys.argv) < 2:
        print("usage: ps3-sfo-title.py <PARAM.SFO> [PARAM.SFO ...]", file=sys.stderr)
        return 1
    status = 0
    for path in sys.argv[1:]:
        try:
            sfo = parse_sfo(path)
        except (OSError, ValueError, struct.error) as e:
            print(f"error: {e}", file=sys.stderr)
            status = 1
            continue
        title = sfo.get("TITLE") or sfo.get("TITLE_01")
        if not title:
            print(f"error: {path}: no TITLE field found", file=sys.stderr)
            status = 1
            continue
        # Sony embeds trademark/copyright glyphs right in the title text,
        # sometimes with no surrounding space (e.g. "LittleBigPlanet™3") --
        # replace with a space rather than deleting, then collapse.
        for glyph in ("™", "®", "©"):
            title = title.replace(glyph, " ")
        print(" ".join(title.split()))
    return status


if __name__ == "__main__":
    sys.exit(main())
