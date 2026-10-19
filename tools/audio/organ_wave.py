"""Synthesize our own tonewheel-style organ note (fallback organ voice; no samples of others).

Writes a 16-bit mono PCM WAV tuned to C4 with
  [0, loop_start)          attack: key click + decaying 2nd-harmonic percussion + drawbars
  [loop_start, loop_end)   steady drawbar tone, an exact whole number of cycles (seamless loop)
and prints the loop points (sample frames) for audio/manifest.lua.

  python3 tools/audio/organ_wave.py OUT.wav [registration]
registration = 9 drawbar digits (16' 5⅓' 8' 4' 2⅔' 2' 1⅗' 1⅓' 1'), default ballpark "868753034".
"""
import math, random, struct, sys, wave

SR = 22050
C4 = 261.6256
# drawbar footages -> harmonic ratio relative to 8' (the played pitch)
RATIOS = [0.5, 1.5, 1, 2, 3, 4, 5, 6, 8]


def find_loop(n_target=64):
    best = None
    for n in range(n_target - 16, n_target + 17):
        L = n * SR / C4
        err = abs(L - round(L))
        if best is None or err < best[0]:
            best = (err, n, round(L))
    _, n, L = best
    return n, L, SR * n / L  # cycles, frames, exact f0


def render(reg="868753034", seed=7):
    n, L, f0 = find_loop()
    # the 16' sub needs an even number of cycles in the loop
    if n % 2:
        n, L = n * 2, L * 2
    levels = [int(c) for c in reg]
    amps = [0 if lv == 0 else 10 ** ((lv - 8) * 3 / 20) for lv in levels]
    attack = L  # one loop length of attack (~0.25 s)
    total = attack + L
    rnd = random.Random(seed)
    out = []
    norm = sum(amps) + 0.6
    for i in range(total):
        t = i / SR
        s = 0.0
        for a, r in zip(amps, RATIOS):
            if a:
                # tonewheels are slightly "dirty" sines: add a whisper of 3rd harmonic
                ph = 2 * math.pi * f0 * r * t
                s += a * (math.sin(ph) + 0.04 * math.sin(3 * ph))
        if i < attack:
            # percussion: 2nd harmonic (4'), fast decay, gone by the loop start
            s += 0.55 * math.exp(-t / 0.055) * math.sin(2 * math.pi * f0 * 2 * t)
            # key click: a few ms of bright noise
            if t < 0.006:
                s += 0.5 * (1 - t / 0.006) * (rnd.random() * 2 - 1)
        out.append(s / norm)
    peak = max(abs(x) for x in out) or 1
    return [int(max(-32767, min(32767, x / peak * 0.9 * 32767))) for x in out], attack, total, f0


def main():
    path = sys.argv[1]
    reg = sys.argv[2] if len(sys.argv) > 2 else "868753034"
    data, ls, le, f0 = render(reg)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", x) for x in data))
    print(f"{path}: loop {ls}..{le} frames, f0={f0:.4f} Hz")


if __name__ == "__main__":
    main()
