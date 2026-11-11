#!/usr/bin/env python3
"""Render the system sound effects to WAV (stdlib only).

  sfx.py [-o DIR] [name ...]     names: see SOUNDS below (default: all)
"""
import argparse
import itertools
import math
import random
import struct
import wave
from pathlib import Path

SR = 44100
NOTE = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def hz(name):
    n = NOTE[name[0]] + (1 if name[1] == "#" else 0)
    octave = int(name[-1])
    return 440.0 * 2 ** ((12 * (octave + 1) + n - 69) / 12)


def tone(freq, dur, kind="bell", vol=0.5):
    """One note. bell = decaying inharmonic partials; pulse = buzzy square-ish."""
    n = int(SR * dur)
    out = []
    for i in range(n):
        t = i / SR
        if kind == "bell":
            env = math.exp(-5.5 * t) * min(1.0, t * 800)
            s = (math.sin(2 * math.pi * freq * t)
                 + 0.35 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-9 * t)
                 + 0.2 * math.sin(2 * math.pi * freq * 5.4 * t) * math.exp(-14 * t))
        elif kind == "warm":  # mellow, sustained; no bright upper partials
            env = min(1.0, t * 70, (dur - t) * 25) * math.exp(-1.3 * t)
            s = (math.sin(2 * math.pi * freq * t)
                 + 0.28 * math.sin(2 * math.pi * freq * 2 * t) * math.exp(-2 * t)
                 + 0.06 * math.sin(2 * math.pi * freq * 3 * t) * math.exp(-4 * t))
        elif kind == "pluck":
            env = math.exp(-4.0 * t) * min(1.0, t * 600, (dur - t) * 200)
            s = (math.sin(2 * math.pi * freq * t)
                 + 0.5 * math.sin(2 * math.pi * freq * 2 * t) * math.exp(-6 * t)
                 + 0.25 * math.sin(2 * math.pi * freq * 3 * t) * math.exp(-9 * t))
        else:
            env = min(1.0, t * 400, (dur - t) * 400)
            s = sum(math.sin(2 * math.pi * freq * k * t) / k for k in (1, 3, 5, 7))
        out.append(s * env * vol)
    return out


def mix(parts, total):
    """parts: [(start_seconds, samples)] summed into a buffer of `total` seconds."""
    buf = [0.0] * int(SR * total)
    for start, samples in parts:
        o = int(SR * start)
        for i, v in enumerate(samples):
            if o + i < len(buf):
                buf[o + i] += v
    return buf


def echo(buf, delay=0.18, gain=0.28, taps=3):
    out = buf[:] + [0.0] * int(SR * delay * taps)
    for k in range(1, taps + 1):
        off = int(SR * delay * k)
        for i, v in enumerate(buf):
            out[i + off] += v * gain ** k
    return out


def notify():
    return echo(mix([(0.0, tone(hz("E6"), 0.6)), (0.11, tone(hz("B6"), 0.6, vol=0.4))], 0.8))


def alert():
    """'awhooOOOOaaa there': a voice-like swoop up, a held wobbling peak, a drop."""
    # (time, hz) breakpoints for the pitch contour
    pts = [(0.0, 260), (0.12, 330), (0.5, 900), (0.62, 880), (1.25, 880), (1.6, 430), (1.8, 400)]
    dur = pts[-1][0]
    n = int(SR * dur)
    phase, out = 0.0, []
    for i in range(n):
        t = i / SR
        for (t0, f0), (t1, f1) in itertools.pairwise(pts):
            if t0 <= t <= t1:
                f = f0 + (f1 - f0) * (t - t0) / (t1 - t0)
                break
        if 0.62 < t < 1.25:  # vibrato grows in while it is held
            f *= 1 + 0.025 * math.sin(2 * math.pi * 6.5 * t) * min(1.0, (t - 0.62) / 0.3)
        phase += 2 * math.pi * f / SR
        env = min(1.0, t * 40, (dur - t) * 6) * (0.55 + 0.45 * min(1.0, t / 0.5))
        s = math.sin(phase) + 0.45 * math.sin(2 * phase) + 0.25 * math.sin(3 * phase)
        out.append(s * env * 0.35)
    return echo(out, 0.14, 0.22, 2)


def reed(freq, dur, vol=0.3):
    """Earnest harmonica/accordion-ish lead: soft attack, few rolled-off partials, late vibrato."""
    n = int(SR * dur)
    phase, out = 0.0, []
    for i in range(n):
        t = i / SR
        f = freq * (1 + 0.006 * math.sin(2 * math.pi * 5.0 * t) * min(1.0, max(0.0, (t - 0.2) / 0.25)))
        phase += 2 * math.pi * f / SR
        env = min(1.0, t * 40, (dur - t) * 25) * (0.8 + 0.2 * math.exp(-3 * t))
        s = sum(math.sin(k * phase) / k ** 2 for k in range(1, 5))
        out.append(s * env * vol * 1.4)
    return out


def _sweep(f0, f1, dur, decay, vol):
    phase, out = 0.0, []
    for i in range(int(SR * dur)):
        t = i / SR
        phase += 2 * math.pi * (f1 + (f0 - f1) * math.exp(-t * 30)) / SR
        out.append(math.sin(phase) * math.exp(-t / decay) * vol)
    return out


def kick(vol=0.8):
    return _sweep(130, 48, 0.3, 0.09, vol)


def snare(vol=0.5):
    rng = random.Random(7)
    body = _sweep(220, 170, 0.2, 0.04, vol * 0.6)
    return [b + rng.uniform(-1, 1) * math.exp(-i / (SR * 0.06)) * vol * 0.7
            for i, b in enumerate(body)]


def tom(vol=0.6):
    return _sweep(190, 95, 0.4, 0.14, vol)


def ring():
    """Eight bars in D at 150 bpm: strummed open chords, root-fifth bass, 50s-rock drums,
    a kazoo-ish singalong lead. Ends on the tonic with a tail of silence so it loops."""
    beat = 60 / 150
    # (strum voicing, bass root, bass fifth) per bar: D A Bm G D A G D
    D = (["D3", "A3", "D4", "F#4"], "D2", "A2")
    A = (["A2", "E3", "A3", "C#4"], "A2", "E2")
    Bm = (["B2", "F#3", "B3", "D4"], "B2", "F#2")
    G = (["G2", "D3", "G3", "B3"], "G2", "D2")
    bars = [D, A, Bm, G, D, A, G, D]
    melody = [
        ("F#4", .5), ("F#4", .5), ("A4", 1), ("F#4", .5), ("E4", .5), ("D4", 1),
        ("E4", .5), ("E4", .5), ("C#5", 1.5), ("B4", .5), ("A4", 1),
        ("D5", 1), ("B4", .5), ("B4", .5), ("A4", 1), ("F#4", 1),
        ("G4", .5), ("A4", .5), ("B4", 1), ("A4", 1), (None, 1),
        ("A4", .5), ("A4", .5), ("D5", 1.5), ("C#5", .5), ("A4", 1),
        ("B4", .5), ("B4", .5), ("E5", 1.5), ("D5", .5), ("C#5", 1),
        ("D5", .5), ("B4", .5), ("G4", 1), ("B4", 1), ("A4", 1),
        ("A4", 1), ("F#4", 1), ("D4", 2),
    ]
    parts = []
    for bar, (chord, root, fifth) in enumerate(bars):
        b0 = bar * 4
        for step in range(8):  # eighth-note downstrokes, accented on the backbeat
            t = (b0 + step * 0.5) * beat
            vol = 0.17 if step % 2 == 0 else 0.1
            if step in (2, 6):
                vol = 0.2
            for k, nm in enumerate(chord):
                parts.append((t + k * 0.008, tone(hz(nm), beat * 0.9, "pluck", vol)))
        for off, nm in ((0, root), (1, fifth), (2, root), (3, fifth)):
            parts.append(((b0 + off) * beat, tone(hz(nm), beat * 0.9, "pluck", 0.34)))
        # eighth-note count, one bar: "BASS 2 3 BASS BASS 6 SNARE 8"
        for e in (0, 3, 4):
            parts.append(((b0 + e * 0.5) * beat, kick()))
        parts.append(((b0 + 3) * beat, snare()))
        parts.append(((b0 + 3) * beat, tom()))
    t = 0.0
    for nm, b in melody:
        if nm:
            parts.append((t, reed(hz(nm), b * beat * 0.95)))
        t += b * beat
    return echo(mix(parts, t + 1.0), 0.16, 0.12, 1)


def success():
    notes = ["C5", "E5", "G5"]
    return echo(mix([(0.07 * i, tone(hz(n), 0.5, vol=0.4)) for i, n in enumerate(notes)], 0.8), 0.15, 0.2, 2)


def complete():
    chord = [tone(hz(n), 0.9, vol=0.28) for n in ("C5", "E5", "G5")]
    parts = [(0.0, c) for c in chord] + [(0.18, tone(hz("C6"), 0.9, vol=0.4))]
    return echo(mix(parts, 1.1), 0.2, 0.25, 2)


def warning():
    parts = [(0.0, tone(hz("E5"), 0.28, "warm", 0.5)), (0.24, tone(hz("C5"), 0.4, "warm", 0.5)),
             (0.8, tone(hz("E5"), 0.28, "warm", 0.5)), (1.04, tone(hz("C5"), 0.5, "warm", 0.5))]
    return echo(mix(parts, 1.6), 0.16, 0.18, 1)


def error():
    parts = [(0.0, tone(hz("A3"), 0.22, "pulse", 0.2)), (0.26, tone(hz("E3"), 0.4, "pulse", 0.22))]
    return mix(parts, 0.75)


def connect():
    return echo(mix([(0.0, tone(hz("G5"), 0.4, vol=0.4)), (0.09, tone(hz("C6"), 0.5, vol=0.4))], 0.7), 0.12, 0.2, 1)


def disconnect():
    return echo(mix([(0.0, tone(hz("C6"), 0.4, vol=0.4)), (0.09, tone(hz("G5"), 0.5, vol=0.4))], 0.7), 0.12, 0.2, 1)


def low_battery():
    parts = [(0.0, tone(hz("G5"), 0.5, "warm", 0.5)), (0.3, tone(hz("E5"), 0.5, "warm", 0.5)),
             (0.6, tone(hz("C5"), 0.9, "warm", 0.55))]
    return echo(mix(parts, 1.6), 0.22, 0.2, 1)


def shutter():
    rng = random.Random(3)
    click = [rng.uniform(-1, 1) * math.exp(-i / (SR * 0.012)) * 0.6 for i in range(int(SR * 0.05))]
    return mix([(0.0, click), (0.05, tone(hz("A6"), 0.08, "pulse", 0.05))], 0.2)


SOUNDS = {
    "notify": notify, "alert": alert, "ring": ring,
    "success": success, "complete": complete, "warning": warning, "error": error,
    "connect": connect, "disconnect": disconnect, "low-battery": low_battery, "shutter": shutter,
    "kick": kick, "snare": snare, "tom": tom,  # building blocks, handy in a sequencer
}


def write(path, buf):
    peak = max(1e-9, max(abs(v) for v in buf))
    scale = min(1.0, 0.9 / peak) * 32767
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(v * scale)) for v in buf))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*")
    ap.add_argument("-o", "--out", default=str(Path(__file__).resolve().parent.parent / "assets" / "sounds"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for name in a.names or SOUNDS:
        if name not in SOUNDS:
            ap.error(f"unknown sound {name!r} (have: {', '.join(SOUNDS)})")
        write(out / f"{name}.wav", SOUNDS[name]())
        print(f"wrote {out / name}.wav")


if __name__ == "__main__":
    main()
