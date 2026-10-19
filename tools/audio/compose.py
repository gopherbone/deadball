"""Our own MIDI arrangements, played on the Playdate through a sampled/synthesized organ.

Run: python3 tools/audio/compose.py   -> playdate/source/audio/midi/*.mid

Channel roles (audio.lua assigns instruments by channel):
  1 = lead (melody, 2 voices)   2 = chords (organ, 3 voices)   3 = bass (1 voice)
  4 = lead double (auto-copied from 1; played slightly detuned for a chorus effect)

Only melodies we are sure of are transcribed. Where a tune's full chorus wasn't certain,
the arrangement uses the passage we are sure of (see notes in each function); the real
vintage recordings (tools/audio/build.py) carry the full tunes.
"""
import os
from midi import Song

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "playdate", "source", "audio", "midi")


def waltz(song, ch_chord, ch_bass, bars, at=0):
    """Oom-pah-pah: bars = list of (bass_note, chord) per 3/4 bar."""
    t = at
    for bass, chord in bars:
        song.add(ch_bass, f"{bass}:1 r:2", at=t, vel=100)
        song.add(ch_chord, f"r:1 {chord}:1? {chord}:1?", at=t, vel=80, legato=0.6)
        t += 3
    return t


def march(song, ch_chord, ch_bass, bars, at=0, beats=4):
    """Bass on 1 and 3 (root/fifth), chord stabs on 2 and 4. bars = (root, fifth, chord)."""
    t = at
    for root, fifth, chord in bars:
        if beats == 4:
            song.add(ch_bass, f"{root}:1 r:1 {fifth}:1 r:1", at=t, vel=100, legato=0.7)
            song.add(ch_chord, f"r:1 {chord}:1? r:1 {chord}:1?", at=t, vel=78, legato=0.5)
        else:
            song.add(ch_bass, f"{root}:1 {fifth}:1", at=t, vel=100, legato=0.7)
            song.add(ch_chord, f"r:.5 {chord}:.5? r:.5 {chord}:.5?", at=t, vel=78, legato=0.5)
        t += beats
    return t


# --- Take Me Out to the Ball Game (Albert Von Tilzer / Jack Norworth, 1908) -------------
# Transcribed from the original 1908 York Music Co. piano-vocal score (public domain):
# Connecticut College Greer Music Library, Historic Sheet Music Collection, Paper 1482
# (digitalcommons.conncoll.edu/sheetmusic/1482, mirrored at archive.org/details/
# sm_takemeouttotheballgame), pp. 4-5. Key of D, 3/4, "Tempo di Valse". Melody: the vocal
# line of the CHORUS, bars 1-32, note for note (2nd ending). Harmony: the bass note and chord
# of the printed piano part, bar by bar, simplified to organ oom-pah-pah voicings.
TMO_CHORUS = [
    # (melody, bass, chords) per bar; chords sound on beats 2 and 3 unless spelled out.
    ("D4:2 D5:1", "D3", "D4+F#4+A4"),          # 1  Take me
    ("B4:1 A4:1 F#4:1", "A2", "D4+F#4+A4"),    # 2  out to the
    ("A4:3", "E3", "C#4+E4+G4"),               # 3  ball
    ("E4:3", "A2", "C#4+E4+G4"),               # 4  game,
    ("D4:2 D5:1", "D3", "D4+F#4+A4"),          # 5  Take me
    ("B4:1 A4:1 F#4:1", "A2", "D4+F#4+A4"),    # 6  out with the
    ("A4:5", "E3", "C#4+E4+A4"),               # 7  crowd___ (tied into bar 8)
    ("r:3", ("A2:1 r:1 C3:1", "r:1 C#4+E4+G4:1? E4+G4+A#4:1?")),  # 8  (C natural, A# in score)
    ("B4:1 A#4:1 B4:1", "B2", "A3+D#4+F#4"),   # 9  Buy me some
    ("F#4:1 G4:1 A4:1", "B2", "A3+D#4+F#4"),   # 10 pea-nuts and
    ("B4:2 G4:1", "E3", "E4+G4+B4"),           # 11 crack-er
    ("E4:3", "B2", "E4+G4+B4"),                # 12 jack,
    ("B4:2 B4:1", "G#2", "D4+E4+G#4"),         # 13 I don't
    ("B4:1 C#5:1 D5:1", "A2", "C#4+E4+G4"),    # 14 care if I
    ("E5:1 C#5:1 B4:1", "A2", "C#4+E4+G4"),    # 15 nev-er get
    ("A4:1 F#4:1 E4:1", ("A2:1 F#2:1! E2:1!", "C#4+E4+G4:1 r:2")),  # 16 back, Let me
    ("D4:2 D5:1", "D3", "D4+F#4+A4"),          # 17 root, root,
    ("B4:1 A4:1 F#4:1", "A2", "D4+F#4+A4"),    # 18 root for the
    ("A4:3", "E3", "C#4+E4+G4"),               # 19 home
    ("E4:2 E4:1", "A2", "C#4+E4+G4"),          # 20 team, If
    ("D4:2 E4:1", "D3", "D4+F#4+A4"),          # 21 they don't
    ("F#4:1 G4:1 A4:1", ("D3:1 E3:1 F#3:1", "D4+F#4:1? C#4+E4+G4:1? C4+D4+F#4:1?")),  # 22 win it's a
    ("B4:4", "G2", "B3+D4+G4"),                # 23 shame___ (tied into bar 24)
    ("r:1 B4:1 C#5:1", "G2", "B3+D4+G4"),      # 24 - For it's
    ("D5:3", "B2", "G4+B4"),                   # 25 one,
    ("D5:3", "Bb2", "D4+G#4"),                 # 26 two,  (B-flat bass, G# = A-flat: B-flat 7)
    ("D5:1 C#5:1 B4:1", ("A2:1 r:1 G2:1", "D4+F#4:1 C#4+E4+A4:1 B3+D4+G4:1")),  # 27 three strikes, you're
    ("A4:1 G#4:1 A4:1", ("F#2:1 E#2:1 F#2:1", "A3+D4+F#4:1 G#3+B3+D4:1 A3+D4+F#4:1")),  # 28 out, at the
    ("B4:3", "E3", "D4+E4+G#4"),               # 29 old
    ("C#5:3", "A2", "C#4+E4+G4"),              # 30 ball
    ("D5:3", "D3", "D4+F#4+A4"),               # 31 game.
]


def _bar(s, at, melody, bass, chords, lead_vel=104):
    """One 3/4 bar: lead (an octave up, bright over the oom-pah), bass and chords. Plain note
    names get the oom-pah-pah (bass on 1, chord on 2 and 3); DSL strings are played as written."""
    s.add(1, melody, at=at, transpose=12, vel=lead_vel)
    if ":" in bass:
        s.add(3, bass, at=at, vel=100, legato=0.7)
        s.add(2, chords, at=at, vel=80, legato=0.6)
    else:
        s.add(3, f"{bass}:1 r:2", at=at, vel=100)
        s.add(2, f"r:1 {chords}:1? {chords}:1?", at=at, vel=80, legato=0.6)
    return at + 3


def _harm(h):
    return h[0] if len(h) == 1 else tuple(h)


def take_me_out():
    """The whole chorus as a ballpark-organ waltz, from the 1908 score (see TMO_CHORUS).

    Intro: the score's own 4-bar-style lead-in idea, built from chorus bars 24-30
    ("For it's one, two, three strikes, you're out, at the old ball") and the piano's
    first-ending turnaround (D C# B | A F# E). Then chorus bars 1-31, then our own tag:
    an arpeggio run up and a final accented D chord (the score's 2nd ending also closes on
    an accented D chord with D6 on top)."""
    s = Song(bpm=186, beats_per_bar=3)
    t = 0
    # intro: pickup (bar 24, beats 2-3) + bars 25-30
    t = _bar(s, t, "r:1 B4:1 C#5:1", "G2", "B3+D4+G4", lead_vel=96)
    for mel, *h in TMO_CHORUS[24:30]:
        t = _bar(s, t, mel, *_harm(h), lead_vel=96)
    # first-ending turnaround (score: octave unison D C# B | A F# E back to "Take")
    t = _bar(s, t, "D5:1 C#5:1 B4:1", "D3:1 C#3:1 B2:1", "D4+F#4+A4:1 r:2", lead_vel=100)
    t = _bar(s, t, "A4:1 F#4:1 E4:1", "A2:1! F#2:1! E2:1!", "r:3", lead_vel=100)
    for mel, *h in TMO_CHORUS:
        t = _bar(s, t, mel, *_harm(h))
    # tag (ours): a chromatic climb to A over A7, then the final D chord with D6 on top
    t = _bar(s, t, "D4:.5 E4:.5 F#4:.5 G4:.5 G#4:.5 A4:.5",
             "A2:1 E2:1 A2:1", "r:1 C#4+E4+G4:1? C#4+E4+G4:1?", lead_vel=108)
    s.add(1, "F#5+A5+D6:2! r:1", at=t, vel=110)
    s.add(2, "D4+F#4+A4:2! r:1", at=t, vel=96)
    s.add(3, "D2+D3:2! r:1", at=t, vel=110)
    return s, None


# --- "Charge!" (traditional bugle-call fanfare as played at ballparks) -------------------
def charge():
    s = Song(bpm=132)
    s.add(1, "G4:.5 C5:.5 E5:.5 G5:1! E5:.5 G5:3!", vel=112)
    s.add(2, "r:1.5 E4+G4:1 r:.5 E4+G4+C5:3", vel=96)
    s.add(3, "r:1.5 C3:1 r:.5 C3:3", vel=100)
    return s, None


# --- Funeral March (Chopin, Sonata No. 2, Op. 35, 1840) -----------------------------------
def funeral_march():
    """Main theme, bars 1-4 of the march proper (B-flat minor), with the left-hand
    alternation of B-flat minor and G-flat chords."""
    s = Song(bpm=54)
    m1 = "Bb3:1 Bb3:.75 Bb3:.25 Bb3:2 |"
    m2 = "Db4:.75 C4:.25 C4:.75 Bb3:.25 Bb3:.75 A3:.25 Bb3:2 |"
    s.add(1, m1 + m2 + m1 + m2, vel=96)
    lh = "Bb2+F3:1 Gb2+Db3:1 Bb2+F3:1 Gb2+Db3:1 |"
    s.add(2, lh * 4, vel=70, legato=0.85)
    s.add(3, "Bb1:4 | Bb1:4 | Bb1:4 | Bb1:4 |", vel=84)
    return s, None


# --- Pop Goes the Weasel (traditional, 1850s) ---------------------------------------------
def pop_weasel():
    s = Song(bpm=200, beats_per_bar=3)  # 6/8: one bar = 3 quarter beats
    a = "C5:1 C5:.5 D5:1 D5:.5 | E5:.5 G5:.5 E5:.5 C5:1.5 |"
    b = "C5:1 C5:.5 D5:1 D5:.5 | E5:1.5 C5:1.5 |"
    pop = "A5:1.5! D5:1 F5:.5 | E5:1.5 C5:1.5 |"
    s.add(1, a + b + a + pop, vel=104)
    bars = [("C3", "E4+G4"), ("C3", "E4+G4"), ("C3", "E4+G4"), ("G2", "F4+B4"),
            ("C3", "E4+G4"), ("C3", "E4+G4"), ("F2", "F4+A4"), ("C3", "E4+G4")]
    t = 0
    for bass, ch in bars:  # 6/8 bounce: bass on 1, chord on 4
        s.add(3, f"{bass}:1.5 r:1.5", at=t, vel=100, legato=0.6)
        s.add(2, f"r:1.5 {ch}:1?", at=t, vel=78, legato=0.6)
        t += 3
    return s, None


# --- Wedding March (Mendelssohn, A Midsummer Night's Dream, 1842) -------------------------
def wedding_march():
    """The opening trumpet fanfare only (repeated triplet call on C), then a full chord."""
    s = Song(bpm=96)
    call = "C5:1/3 C5:1/3 C5:1/3 C5:1 "
    s.add(1, call * 3 + "C5:1/3 C5:1/3 C5:1/3 C5:1/3 C5:1/3 C5:1/3 | C5:4!", vel=108)
    s.add(2, "r:8 E4+G4+C5:4", vel=92)
    s.add(3, "C3:4 | G2:4 | C2:4", vel=96)
    return s, None


# --- Bridal Chorus (Wagner, Lohengrin, 1850) — "Here comes the bride" ----------------------
def bridal_chorus():
    s = Song(bpm=72)
    s.add(1, "C4:1 F4:.75 F4:.25 F4:2 | C4:1 G4:.75 E4:.25 F4:2 |", transpose=12, vel=100)
    s.add(2, "A3+C4:4 | Bb3+C4:2 A3+C4:2 |", transpose=12, vel=76)
    s.add(3, "F2:4 | C2:2 F2:2 |", vel=90)
    return s, None


# --- "Shave and a Haircut" (traditional, from Charles Hale's 1899 "At a Darktown
#     Cakewalk") — our "you're outta here" ejection button ---------------------------------
def ejection():
    s = Song(bpm=150)
    s.add(1, "C5:1 G4:.5 G4:.5 A4:1 G4:1 | r:1 B4:1! C5:1! r:1", vel=110)
    s.add(2, "E4+G4:1 r:3 | r:1 D4+F4:1 E4+G4:1 r:1", vel=90)
    s.add(3, "C3:1 r:3 | r:1 G2:1 C3:1 r:1", vel=100)
    return s, None


# --- Original stingers (ours) --------------------------------------------------------------
def home_run():
    s = Song(bpm=150)
    s.add(1, "C5:1/4 E5:1/4 G5:1/4 C6:1/4 E6:1/2 r:1/2 C6:1/3 D6:1/3 E6:1/3 G6:2!", vel=112)
    s.add(2, "r:1 C4+E4+G4:.5 r:.5 E4+G4+C5:1/3 F4+A4+D5:1/3 G4+C5+E5:1/3 G4+C5+E5:2", vel=96)
    s.add(3, "C3:1 C3:.5 r:.5 r:1 C2:2", vel=104)
    return s, None


def strikeout():
    s = Song(bpm=100)
    s.add(1, "G4:.75 F#4:.75 F4:.75 E4:2.25", vel=100)
    s.add(2, "C4+E4:.75 C4+Eb4:.75 B3+D4:.75 Bb3+Db4:2.25", vel=74)
    s.add(3, "C3:.75 B2:.75 Bb2:.75 A2:2.25", vel=90)
    return s, None


def error():
    s = Song(bpm=160)
    s.add(1, "B5:.25 C6:.25 B5:.25 C6:.25 r:.5 F4+B4:2", vel=104)
    s.add(3, "r:1 F2:2", vel=96)
    return s, None


def bet_won():
    s = Song(bpm=160)
    s.add(1, "G5:.5 C6:.5 E6:.5 G6:.5 r:.5 E6:.5 G6:2!", vel=110)
    s.add(2, "r:2.5 G4+C5+E5:2.5", vel=92)
    s.add(3, "C3:.5 r:1.5 G2:.5 C3:2.5", vel=96)
    return s, None


def bet_lost():
    s = Song(bpm=84)
    s.add(1, "Eb4:1 D4:1 Db4:1 C4:3", vel=100)
    s.add(2, "C4+Gb4:3 C3+Eb3+Gb3:3", vel=70)
    s.add(3, "r:3 C2:3", vel=90)
    return s, None


def pack_opened():
    s = Song(bpm=180)
    s.add(1, "C5:1/4 D5:1/4 E5:1/4 F5:1/4 G5:1/4 A5:1/4 B5:1/4 C6:1/4 E6:2!", vel=104)
    s.add(2, "r:2 E5+G5+C6:2", vel=88)
    s.add(3, "r:2 C3:2", vel=96)
    return s, None


def new_mail():
    s = Song(bpm=120)
    s.add(1, "E6:.5 C6:1.5", vel=96)
    s.add(2, "G5:.5 E5:1.5", vel=70)
    return s, None


def arrest():
    s = Song(bpm=132)
    s.add(1, "C5+Gb5:.5 r:.25 C5+Gb5:.25 r:.5 Eb5+A5:1.5? | C4:2!", vel=108)
    s.add(3, "C2:.5 r:.25 C2:.25 r:.5 Gb2:1.5 | C2:2", vel=104)
    return s, None


def seventh_stretch_vamp():
    """Original 'get up and stretch' warm-up vamp (ours), 4 bars, loops."""
    s = Song(bpm=128)
    s.add(1, "G4:.5 A4:.5 C5:1 A4:.5 C5:.5 D5:1 | E5:.5 D5:.5 C5:.5 A4:.5 G4:2 |"
             " G4:.5 A4:.5 C5:1 A4:.5 C5:.5 E5:1 | D5:2 C5:2 |", vel=100)
    march(s, 2, 3, [("C3", "G2", "E4+G4"), ("F2", "C3", "F4+A4"), ("C3", "G2", "E4+G4"), ("G2", "D3", "F4+B4")])
    return s, None


CUES = {
    "take_me_out": take_me_out,
    "take_me_out_organ": take_me_out,
    "charge": charge,
    "funeral_march": funeral_march,
    "pop_weasel": pop_weasel,
    "wedding_march": wedding_march,
    "bridal_chorus": bridal_chorus,
    "ejection": ejection,
    "home_run": home_run,
    "strikeout": strikeout,
    "error": error,
    "bet_won": bet_won,
    "bet_lost": bet_lost,
    "pack_opened": pack_opened,
    "new_mail": new_mail,
    "arrest": arrest,
    "stretch_vamp": seventh_stretch_vamp,
}


def render(fn):
    """Build a cue; channel 4 doubles the lead (detuned chorus voice, muted in low-CPU mode)."""
    song, total = fn()
    if 1 in song.parts:
        song.parts[4] = list(song.parts[1])
    return song, total


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in CUES.items():
        song, total = render(fn)
        ticks = song.write(os.path.join(OUT, name + ".mid"), total)
        print(f"{name:16s} {ticks:6d} ticks  {float(song.length_beats()) * 60 / song.bpm:5.1f}s")


if __name__ == "__main__":
    main()
