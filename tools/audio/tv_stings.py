"""DBN broadcast stings: offline-synthesized 90s sports-TV sounds for BallCast's TV package.

Original sounds (ours, no samples): the network ident, whooshes for wipes, the INSTANT
REPLAY stinger, a VHS rewind chirp, the SPECIAL REPORT bulletin, the telestrator pen squeak,
a data tick, the freeze-frame thunk and the big-moment impact.

    python3 tools/audio/tv_stings.py            # write raw WAVs to tools/audio/.cache/tv/
    (tools/audio/build.py calls render_all() and runs them through the usual lo-fi chain
     into playdate/source/audio/sfx/tv_*.wav)

Everything is numpy: additive/subtractive synthesis, RBJ biquads (time-varying cutoffs are
recomputed every 32 samples), and a short room. Rendered at 44.1 kHz; build.py downsamples.
"""
import os
import wave

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, ".cache", "tv")
RNG = np.random.default_rng(1996)


# --- building blocks ---------------------------------------------------------------------

def secs(d):
    return np.arange(int(d * SR)) / SR


def phase(freq, n):
    f = np.broadcast_to(np.asarray(freq, dtype=float), (n,))
    return 2 * np.pi * np.cumsum(f) / SR


def sine(freq, n):
    return np.sin(phase(freq, n))


def saw(freq, n):
    p = phase(freq, n) / (2 * np.pi)
    return 2 * (p - np.floor(p + 0.5))


def square(freq, n, duty=0.5):
    p = (phase(freq, n) / (2 * np.pi)) % 1.0
    return np.where(p < duty, 1.0, -1.0)


def noise(n):
    return RNG.uniform(-1, 1, n)


def env(n, a=0.005, d=0.1, s=0.0, r=0.05, hold=None):
    """ADSR over n samples: attack a, decay d to level s, hold until n - r, release r."""
    e = np.zeros(n)
    ia, idd, ir = int(a * SR), int(d * SR), int(r * SR)
    ia = max(1, min(ia, n))
    e[:ia] = np.linspace(0, 1, ia)
    i = ia
    k = max(1, min(idd, n - i))
    e[i:i + k] = np.linspace(1, s, k)
    i += k
    rel0 = max(i, n - ir)
    e[i:rel0] = s
    if rel0 < n:
        e[rel0:] = np.linspace(s, 0, n - rel0)
    return e


def expdecay(n, tau):
    return np.exp(-np.arange(n) / SR / tau)


def biquad(x, kind, f, q=0.7):
    """RBJ biquad; f may be an array (time-varying cutoff)."""
    n = len(x)
    f = np.broadcast_to(np.asarray(f, dtype=float), (n,))
    y = np.zeros(n)
    x1 = x2 = y1 = y2 = 0.0
    for s0 in range(0, n, 32):
        w = 2 * np.pi * min(max(f[s0], 20), SR * 0.45) / SR
        cw, sw = np.cos(w), np.sin(w)
        al = sw / (2 * q)
        if kind == "lp":
            b0, b1, b2 = (1 - cw) / 2, 1 - cw, (1 - cw) / 2
        elif kind == "hp":
            b0, b1, b2 = (1 + cw) / 2, -(1 + cw), (1 + cw) / 2
        else:  # band-pass (constant peak gain)
            b0, b1, b2 = al, 0.0, -al
        a0, a1, a2 = 1 + al, -2 * cw, 1 - al
        b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
        for i in range(s0, min(n, s0 + 32)):
            xi = x[i]
            yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, xi, y1, yi
            y[i] = yi
    return y


def room(x, mix=0.18):
    """A small, bright TV-studio room: a few early reflections and a short tail."""
    y = x.copy()
    for d, g in ((0.023, 0.5), (0.037, 0.4), (0.051, 0.32), (0.071, 0.25), (0.097, 0.18), (0.131, 0.12)):
        k = int(d * SR)
        y[k:] += x[:-k] * g * mix * 2
    return y


def place(buf, x, at):
    i = int(at * SR)
    j = min(len(buf), i + len(x))
    buf[i:j] += x[:j - i]


def hz(note):
    names = {"C": 0, "C#": 1, "D": 2, "D#": 3, "E": 4, "F": 5, "F#": 6, "G": 7, "G#": 8, "A": 9, "A#": 10, "B": 11}
    n, o = note[:-1], int(note[-1])
    return 440.0 * 2 ** ((names[n] + 12 * (o + 1) - 69) / 12)


def brass(freq, d, bright=3200, vib=True):
    """A 90s synth-brass voice: three detuned saws through a swelling low-pass."""
    n = int(d * SR)
    t = secs(d)
    v = 1 + (0.004 * np.sin(2 * np.pi * 5.5 * t) * np.clip(t * 3 - 0.3, 0, 1) if vib else 0)
    x = saw(freq * v, n) + saw(freq * 1.006 * v, n) * 0.8 + saw(freq * 0.994 * v, n) * 0.8
    cut = 600 + bright * np.clip(t / 0.05, 0, 1) * np.exp(-t / 0.6) + bright * 0.25
    x = biquad(x, "lp", cut, 0.9)
    return x * env(n, 0.012, 0.25, 0.65, 0.12) * 0.33


def bell(freq, d, decay=0.6):
    """FM bell (2-operator), the 'data' sparkle of a network logo."""
    n = int(d * SR)
    t = secs(d)
    mod = np.sin(2 * np.pi * freq * 3.5 * t) * 2.2 * np.exp(-t / (decay * 0.4))
    return np.sin(2 * np.pi * freq * t + mod) * np.exp(-t / decay)


def whoosh(d, f0, f1, q=1.4, peak=0.5):
    n = int(d * SR)
    t = np.linspace(0, 1, n)
    f = f0 * (f1 / f0) ** t
    x = biquad(noise(n), "bp", f, q)
    e = np.sin(np.pi * np.clip(t / peak, 0, 1) * 0.5) ** 2 * np.where(t > peak, np.cos(np.pi * 0.5 * (t - peak) / (1 - peak)) ** 2, 1)
    return x * e * 2.2


def timpani(freq, d):
    n = int(d * SR)
    t = secs(d)
    f = freq * (1 + 0.06 * np.exp(-t / 0.05))
    x = sine(f, n) + 0.5 * sine(f * 1.5, n) * np.exp(-t / 0.2) + 0.3 * biquad(noise(n), "bp", freq * 4, 2) * np.exp(-t / 0.04)
    return x * np.exp(-t / 0.5)


def norm(x, peak=0.89):
    m = np.max(np.abs(x)) or 1
    return x / m * peak


# --- the cues ----------------------------------------------------------------------------

def ident():
    """Network ident (~2.4 s): timpani + riser into a brass stab, D-B-N bells, sparkle."""
    buf = np.zeros(int(2.6 * SR))
    place(buf, whoosh(0.55, 300, 5000, q=1.0, peak=0.95) * 0.5, 0.0)
    place(buf, timpani(hz("D3"), 0.9) * 0.9, 0.5)
    for k, note in enumerate(("D4", "F#4", "A4", "D5")):
        place(buf, brass(hz(note), 1.3, bright=3600), 0.52 + k * 0.004)
    # the motif: D - B - N, on bells, then a held fifth
    for k, (note, at) in enumerate((("A5", 1.05), ("F#5", 1.2), ("D6", 1.35))):
        place(buf, bell(hz(note), 1.0, 0.7) * 0.32, at)
    place(buf, brass(hz("A4"), 0.9, bright=2400) * 0.6, 1.5)
    place(buf, brass(hz("D5"), 0.9, bright=2400) * 0.6, 1.5)
    # sparkle: tiny high bells
    for k in range(10):
        place(buf, bell(2600 + RNG.uniform(0, 1800), 0.25, 0.12) * 0.12, 1.4 + k * 0.07)
    return norm(room(buf, 0.25))


def tv_whoosh():
    x = whoosh(0.45, 700, 4200, q=1.6, peak=0.55) + whoosh(0.45, 400, 1800, q=2.5, peak=0.5) * 0.5
    return norm(room(x, 0.1))


def replay():
    """INSTANT REPLAY (~1.1 s): reverse-cymbal swell, a two-chord stab, a laser 'zap'."""
    buf = np.zeros(int(1.2 * SR))
    n = int(0.42 * SR)
    t = np.linspace(0, 1, n)
    sw = biquad(noise(n), "hp", 3000 + 5000 * t, 0.7) * t ** 3
    place(buf, sw * 0.6, 0.0)
    for note in ("E4", "G#4", "B4"):
        place(buf, brass(hz(note), 0.16, bright=4000) * 1.1, 0.42)
    for note in ("A4", "C#5", "E5"):
        place(buf, brass(hz(note), 0.55, bright=4000), 0.6)
    nz = int(0.35 * SR)
    tz = secs(0.35)
    zap = square(2400 * np.exp(-tz / 0.08) + 300, nz, 0.3) * np.exp(-tz / 0.12) * 0.25
    place(buf, biquad(zap, "lp", 5000), 0.42)
    return norm(room(buf, 0.2))


def rewind():
    """VHS rewind: a squealing, warbling chirp over tape hiss (~0.8 s)."""
    d = 0.8
    n = int(d * SR)
    t = secs(d)
    f = 700 + 2200 * (t / d) ** 0.7 + 120 * np.sin(2 * np.pi * 23 * t)
    x = 0.5 * square(f, n, 0.4) + 0.3 * sine(f * 2, n)
    x = biquad(x, "bp", f * 1.5, 1.2)
    hiss = biquad(noise(n), "hp", 4000, 0.7) * 0.3
    e = env(n, 0.02, 0.1, 0.9, 0.12)
    return norm((x + hiss) * e)


def bulletin():
    """SPECIAL REPORT (~1.9 s): an urgent four-note news motif over teletype clicks."""
    buf = np.zeros(int(2.0 * SR))
    motif = (("A4", 0.0, 0.12), ("A4", 0.16, 0.12), ("A4", 0.32, 0.12), ("F5", 0.48, 0.9))
    for note, at, d in motif:
        for mult, g in ((1, 1.0), (1.5, 0.45), (2, 0.25)):
            place(buf, brass(hz(note) * mult, d, bright=3000) * g, at)
    place(buf, timpani(hz("A2"), 0.8) * 0.7, 0.48)
    for k in range(18):
        nc = int(0.012 * SR)
        click = biquad(noise(nc), "bp", 3200, 3) * np.exp(-np.arange(nc) / SR / 0.003)
        place(buf, click * 0.7, 0.05 + k * 0.095 + RNG.uniform(0, 0.02))
    return norm(room(buf, 0.2))


def pen():
    """Telestrator: felt marker on a monitor (~0.35 s), squeaky."""
    d = 0.35
    n = int(d * SR)
    t = secs(d)
    f = 2400 + 500 * np.sin(2 * np.pi * 9 * t) + 300 * np.sin(2 * np.pi * 31 * t)
    x = biquad(noise(n), "bp", f, 6) * 2.5 + 0.15 * sine(f, n)
    return norm(x * env(n, 0.01, 0.05, 0.8, 0.08))


def tick():
    """Graphic data blip (~0.14 s): two quick sine pips."""
    buf = np.zeros(int(0.16 * SR))
    for at, f in ((0.0, 1600), (0.06, 2400)):
        n = int(0.06 * SR)
        place(buf, sine(f, n) * env(n, 0.002, 0.05, 0, 0.005), at)
    return norm(buf)


def freeze():
    """Freeze-frame: a shutter click, a low thunk and a brief ring (~0.45 s)."""
    buf = np.zeros(int(0.5 * SR))
    nc = int(0.02 * SR)
    place(buf, biquad(noise(nc), "hp", 2000) * np.exp(-np.arange(nc) / SR / 0.004), 0.0)
    n = int(0.3 * SR)
    t = secs(0.3)
    place(buf, sine(380 * np.exp(-t / 0.1) + 120, n) * np.exp(-t / 0.08) * 0.8, 0.0)
    place(buf, bell(1760, 0.4, 0.15) * 0.25, 0.02)
    return norm(room(buf, 0.15))


def impact():
    """Big moment: a boom, a crash and a stab (~1.3 s)."""
    buf = np.zeros(int(1.4 * SR))
    n = int(0.6 * SR)
    t = secs(0.6)
    place(buf, sine(110 * np.exp(-t / 0.15) + 50, n) * np.exp(-t / 0.25) * 0.9, 0.0)
    nc = int(1.2 * SR)
    tc = secs(1.2)
    crash = biquad(noise(nc), "hp", 2500, 0.6) * np.exp(-tc / 0.35)
    place(buf, crash * 0.35, 0.0)
    for note in ("C4", "E4", "G4", "C5"):
        place(buf, brass(hz(note), 0.7, bright=4200) * 0.8, 0.0)
    return norm(room(buf, 0.25))


CUES = {
    "tv_ident": (ident, "DBN network ident (original)"),
    "tv_whoosh": (tv_whoosh, "DBN graphic whoosh (original)"),
    "tv_replay": (replay, "DBN INSTANT REPLAY stinger (original)"),
    "tv_rewind": (rewind, "DBN VHS rewind chirp (original)"),
    "tv_bulletin": (bulletin, "DBN SPECIAL REPORT bulletin (original)"),
    "tv_pen": (pen, "DBN telestrator pen squeak (original)"),
    "tv_tick": (tick, "DBN graphic data tick (original)"),
    "tv_freeze": (freeze, "DBN freeze-frame thunk (original)"),
    "tv_impact": (impact, "DBN big-moment impact (original)"),
}


def write_wav(path, x):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def render_all():
    """Render every cue to .cache/tv/<name>.wav; returns {name: (path, description)}."""
    out = {}
    for name, (fn, desc) in CUES.items():
        p = os.path.join(OUT, name + ".wav")
        write_wav(p, fn())
        out[name] = (p, desc)
    return out


if __name__ == "__main__":
    for name, (p, _) in render_all().items():
        print(name, os.path.getsize(p))
