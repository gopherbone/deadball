"""Find where a known melody starts inside a recording (helps pick excerpts without ears).

  python3 tools/audio/melody_scan.py FILE "C5 A4 G4 E4 G4 D4" [--hop 0.05]

Decodes with ffmpeg to 8 kHz mono, tracks the dominant pitch per frame (harmonic-product
spectrum), collapses it into a note sequence (with times), and scores every position by how
well the *interval* pattern matches (key-independent). Prints the best few start times.
"""
import subprocess, sys
import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from midi import note_num  # noqa: E402

SR = 8000


def decode(path):
    raw = subprocess.run(["/opt/homebrew/bin/ffmpeg", "-loglevel", "error", "-i", path, "-ac", "1", "-ar", str(SR),
                          "-f", "s16le", "-"], capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768


def pitches(x, hop=0.05, win=2048):
    h = int(hop * SR)
    w = np.hanning(win)
    out = []
    for i in range(0, len(x) - win, h):
        seg = x[i:i + win] * w
        rms = np.sqrt(np.mean(seg ** 2))
        sp = np.abs(np.fft.rfft(seg))
        hps = sp.copy()
        for k in (2, 3):
            d = sp[::k]
            hps[:len(d)] *= d
        lo, hi = int(120 * win / SR), int(1100 * win / SR)
        b = lo + int(np.argmax(hps[lo:hi]))
        f = b * SR / win
        out.append((i / SR, 69 + 12 * np.log2(f / 440) if rms > 0.01 else None))
    return out


def notes(track, min_len=0.1):
    seq, cur, start, n = [], None, 0, 0
    for t, m in track:
        r = None if m is None else int(round(m))
        if r != cur:
            if cur is not None and n * 0.05 >= min_len:
                seq.append((start, cur))
            cur, start, n = r, t, 0
        n += 1
    return seq


def main():
    path, mel = sys.argv[1], [note_num(x) for x in sys.argv[2].split()]
    iv = np.diff(mel)
    seq = notes(pitches(decode(path)))
    pcs = np.array([p for _, p in seq])
    best = []
    for i in range(len(seq) - len(iv)):
        d = np.diff(pcs[i:i + len(mel)])
        # octave-folded interval error
        err = np.abs(((d - iv) + 6) % 12 - 6).sum()
        best.append((err, seq[i][0]))
    best.sort()
    for err, t in best[:8]:
        print(f"t={t:7.2f}s  err={err}")


if __name__ == "__main__":
    main()
