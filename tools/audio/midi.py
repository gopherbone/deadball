"""Minimal Standard MIDI File writer (no dependencies) plus a tiny melody DSL.

Playdate's playdate.sound.sequence.new("x.mid") maps MIDI *channels* to sequence tracks
(channel 1 -> track 1, ...), uses ticks as steps and the first tempo meta event for the
step rate. So: one tempo per file, one role per channel.

DSL: a whitespace-separated string of `NOTE:BEATS` tokens.
  NOTE  = C4, F#5, Bb3, or `r` for a rest; chords as `C4+E4+G4`.
  BEATS = quarter-note beats, e.g. 1, .5, 1.5, 2/3 (fractions allowed). `~` suffix ties
          into the next token of the same pitch (only used for readability; it just merges).
  `|` bar lines are ignored (they are for the reader).
  A trailing `!` raises velocity (accent), `?` lowers it (ghost).
"""
from fractions import Fraction
import struct

PPQ = 96
NAMES = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def note_num(s):
    s = s.strip()
    n = NAMES[s[0].upper()]
    i = 1
    while i < len(s) and s[i] in "#b":
        n += 1 if s[i] == "#" else -1
        i += 1
    octave = int(s[i:])
    return 12 * (octave + 1) + n  # C4 = 60


def parse(dsl, transpose=0, vel=96):
    """-> list of (start_beats: Fraction, beats: Fraction, [notes], velocity)."""
    out, t = [], Fraction(0)
    for tok in dsl.replace("|", " ").split():
        v = vel
        if tok.endswith("!"):
            v, tok = min(127, vel + 22), tok[:-1]
        elif tok.endswith("?"):
            v, tok = max(1, vel - 30), tok[:-1]
        name, dur = tok.split(":")
        d = Fraction(dur) if "/" in dur else Fraction(dur).limit_denominator(48)
        if name.lower() != "r":
            out.append((t, d, [note_num(x) + transpose for x in name.split("+")], v))
        t += d
    return out, t


class Song:
    def __init__(self, bpm, beats_per_bar=4):
        self.bpm = bpm
        self.bpb = beats_per_bar
        self.parts = {}  # channel (1-based) -> list of events

    def add(self, channel, dsl, at=0, transpose=0, vel=96, legato=0.92):
        evs, length = parse(dsl, transpose, vel)
        lst = self.parts.setdefault(channel, [])
        for start, d, notes, v in evs:
            for n in notes:
                lst.append((Fraction(at) + start, d * Fraction(legato).limit_denominator(100), n, v))
        return Fraction(at) + length

    def length_beats(self):
        end = 0
        for lst in self.parts.values():
            for s, d, n, v in lst:
                end = max(end, s + d)
        return end

    def write(self, path, total_beats=None):
        """Format 1: track 0 = tempo/time-sig; one MTrk per channel."""
        def vlq(x):
            b = [x & 0x7F]
            x >>= 7
            while x:
                b.append(0x80 | (x & 0x7F))
                x >>= 7
            return bytes(reversed(b))

        def trk(events):
            events.sort(key=lambda e: (e[0], e[1]))
            data, last = b"", 0
            for tick, _, payload in events:
                data += vlq(tick - last) + payload
                last = tick
            data += b"\x00\xff\x2f\x00"
            return b"MTrk" + struct.pack(">I", len(data)) + data

        if total_beats is None:  # round up to a whole bar so loops stay in time
            lb = self.length_beats()
            bars = -(-lb // self.bpb)
            total_beats = bars * self.bpb
        total = total_beats
        end_tick = int(round(total * PPQ))
        us = int(round(60_000_000 / self.bpm))
        meta = [
            (0, 0, b"\xff\x51\x03" + us.to_bytes(3, "big")),
            (0, 0, b"\xff\x58\x04" + bytes([self.bpb, 2, 24, 8])),
            (end_tick, 9, b"\xff\x01\x00"),  # empty text event pins the length
        ]
        tracks = [trk(meta)]
        for ch in sorted(self.parts):
            c = ch - 1
            evs = []
            for s, d, n, v in self.parts[ch]:
                on = int(round(s * PPQ))
                off = max(on + 1, int(round((s + d) * PPQ)))
                evs.append((on, 1, bytes([0x90 | c, n, v])))
                evs.append((off, 0, bytes([0x80 | c, n, 0])))  # offs before ons at same tick
            tracks.append(trk(evs))
        hdr = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), PPQ)
        with open(path, "wb") as f:
            f.write(hdr + b"".join(tracks))
        return end_tick
