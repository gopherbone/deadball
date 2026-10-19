"""Offline ballpark-organ renderer: compose.py arrangements -> WAV recordings.

The Playdate used to play these cues live through sample-based synth voices; pitched
far from their root, with a vibrato LFO and a detuned double on top, they came out
metallic. Rendering offline gives a clean tone we can check here, and the device only
has to play a file.

Tone: additive tonewheel organ (nine drawbars as sine partials, ~3 dB per drawbar
step), Hammond-style percussion on the lead, a slow "chorale" Leslie (gentle amplitude
swirl and a few cents of Doppler), and a short bleacher-and-roof room. build.py then
runs the result through the same lo-fi chain as the real recordings.
"""
import numpy as np

SR = 44100

# drawbar footages as multiples of the played pitch: 16' 5 1/3' 8' 4' 2 2/3' 2' 1 3/5' 1 1/3' 1'
RATIOS = (0.5, 1.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0)

# Registrations per role (channel): 1 lead, 2 chords, 3 bass. Channel 4 (the old
# detuned double) is ignored.
REG = {
    1: (6, 0, 8, 8, 0, 6, 0, 0, 4),   # bright ballpark lead
    2: (0, 0, 8, 6, 4, 2, 0, 0, 0),   # mellow chord pad
    3: (0, 0, 8, 8, 6, 4, 0, 0, 0),   # bass with upper partials so it reads on a small speaker
}
LEVEL = {1: 1.0, 2: 0.38, 3: 0.75}
PERC = {1: (3.0, 0.9, 0.18)}  # role -> (harmonic ratio, level, decay seconds): 2 2/3' "pop"


def midi_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def drawbar_amp(level):
    return 0.0 if level <= 0 else 10 ** ((level - 8) * 3 / 20)


def note(hz, dur, role, vel, rng):
    """One held organ key: dur seconds of sound plus a short release."""
    rel = 0.045
    n = int((dur + rel) * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for ratio, lvl in zip(RATIOS, REG[role]):
        a = drawbar_amp(lvl)
        f = hz * ratio
        if a == 0 or f > 9000:
            continue
        out += a * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))  # free-running wheels
    if role in PERC:
        ratio, lvl, tau = PERC[role]
        out += lvl * np.exp(-t / tau) * np.sin(2 * np.pi * hz * ratio * t)
    # keyed on/off like a real organ: 3 ms attack (a little click), short release
    env = np.ones(n)
    a = int(0.003 * SR)
    env[:a] = np.linspace(0, 1, a)
    r0 = int(dur * SR)
    env[r0:] = np.linspace(1, 0, n - r0)
    return out * env * (0.75 + 0.25 * vel / 127)


def leslie(x, rate=0.83, am=0.07, delay_ms=0.35):
    t = np.arange(len(x)) / SR
    ph = 2 * np.pi * rate * t
    d = (delay_ms / 1000) * SR * (1 + np.sin(ph))  # Doppler: a few cents, slow
    idx = np.arange(len(x)) - d
    i0 = np.clip(np.floor(idx).astype(int), 0, len(x) - 1)
    i1 = np.clip(i0 + 1, 0, len(x) - 1)
    fr = idx - np.floor(idx)
    y = x[i0] * (1 - fr) + x[i1] * fr
    return y * (1 + am * np.sin(ph + 0.6))


def room(x, rng, length=0.7, tau=0.16, mix=0.16, slap=0.11, slap_mix=0.12):
    n = int(length * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-t / tau)
    ir = np.convolve(ir, np.ones(6) / 6, mode="same")  # soften the tail
    ir[0] = 0
    ir /= np.sqrt((ir ** 2).sum())
    m = len(x) + n
    size = 1 << (m - 1).bit_length()
    wet = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[:m]
    out = np.zeros(m)
    out[:len(x)] += x
    out += mix * wet
    s = int(slap * SR)
    out[s:s + len(x)] += slap_mix * x  # bleacher slapback
    return out


def render(song, total_beats, loop=False, seed=7):
    """-> float array in [-1, 1]. Loops are rendered twice and the second pass kept, so
    the room tail wraps around the loop point."""
    rng = np.random.default_rng(seed)
    spb = 60.0 / song.bpm
    length = float(total_beats) * spb
    passes = 2 if loop else 1
    tail = 0 if loop else 0.9
    buf = np.zeros(int((length * passes + tail + 1) * SR))
    for role, events in song.parts.items():
        if role not in REG:
            continue
        for p in range(passes):
            for start, dur, n, vel in events:
                s = int((float(start) * spb + p * length) * SR)
                x = note(midi_hz(n), float(dur) * spb, role, vel, rng) * LEVEL[role]
                buf[s:s + len(x)] += x[:len(buf) - s]
    y = room(leslie(buf), rng)
    if loop:
        L = int(length * SR)
        y = y[L:2 * L]
    else:
        y = y[:int((length + tail) * SR)]
        # trim trailing silence
        nz = np.nonzero(np.abs(y) > 1e-3 * np.abs(y).max())[0]
        if len(nz):
            y = y[:nz[-1] + int(0.05 * SR)]
    return y / (np.abs(y).max() + 1e-9) * 0.9


def write_wav(path, y):
    import wave
    pcm = (np.clip(y, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
