#!/usr/bin/env python3
"""Write a MIDI file from a text melody.

  midi.py "C4 D4 E4:2 r F#4:0.5 Bb3 C4+E4+G4:2" -o tune.mid -t 100

Tokens: NOTE[:beats]. NOTE is a letter A-G, optional #/b, octave (C4 = middle C).
`r` is a rest, `+` joins notes into a chord. Beats default to 1.
"""
import argparse
import struct
import sys

SEMI = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
PPQ = 480


def vlq(n):
    out = [n & 0x7F]
    while n >> 7:
        n >>= 7
        out.append((n & 0x7F) | 0x80)
    return bytes(reversed(out))


def pitch(name):
    n = SEMI[name[0].upper()]
    rest = name[1:]
    while rest and rest[0] in "#b":
        n += 1 if rest[0] == "#" else -1
        rest = rest[1:]
    return 12 * (int(rest) + 1) + n


def build(text, tempo, program, velocity):
    trk = vlq(0) + b"\xFF\x51\x03" + (60_000_000 // tempo).to_bytes(3, "big")
    trk += vlq(0) + bytes([0xC0, program])
    gap = 0  # ticks of rest waiting to be added to the next delta
    for tok in text.split():
        name, _, beats = tok.partition(":")
        ticks = round(float(beats or 1) * PPQ)
        if name.lower() == "r":
            gap += ticks
            continue
        pitches = [pitch(p) for p in name.split("+")]
        for i, p in enumerate(pitches):
            trk += vlq(gap if i == 0 else 0) + bytes([0x90, p, velocity])
        for i, p in enumerate(pitches):
            trk += vlq(ticks if i == 0 else 0) + bytes([0x80, p, 0])
        gap = 0
    trk += vlq(gap) + b"\xFF\x2F\x00"
    hdr = b"MThd" + struct.pack(">IHHH", 6, 0, 1, PPQ)
    return hdr + b"MTrk" + struct.pack(">I", len(trk)) + trk


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("melody", nargs="?", help="melody text (default: read stdin)")
    ap.add_argument("-o", "--out", default="out.mid")
    ap.add_argument("-t", "--tempo", type=int, default=120, help="beats per minute")
    ap.add_argument("-p", "--program", type=int, default=0, help="GM instrument 0-127 (0 piano, 24 guitar, 80 square lead)")
    ap.add_argument("-v", "--velocity", type=int, default=96)
    a = ap.parse_args()
    text = a.melody if a.melody is not None else sys.stdin.read()
    try:
        data = build(text, a.tempo, a.program, a.velocity)
    except (KeyError, ValueError, IndexError) as e:
        sys.exit(f"midi.py: bad token ({e!r}) — see --help")
    with open(a.out, "wb") as f:
        f.write(data)
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
