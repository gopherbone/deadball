"""Build all DEADBALL audio into playdate/source/audio/.

  python3 tools/audio/build.py            # everything
  python3 tools/audio/build.py --no-ffmpeg  # only regenerate MIDI + manifest

Steps
 1. compose.py -> audio/midi/*.mid (our own arrangements)
 2. organ_wave.py -> audio/organ/tonewheel.wav (our synthesized organ voice, fallback)
 3. selection.json: real recordings/samples picked from tools/audio/.cache/ (see
    sources_music.json / sources_sfx.json written while sourcing) -> trimmed, mono,
    band-limited "AM radio / stadium PA" processing, normalized, IMA ADPCM WAV
    (organ notes stay 16-bit PCM: synths can't play ADPCM).
 4. audio/manifest.lua (Lua table the runtime reads) + audio/credits.json.
"""
import json, os, subprocess, sys, struct, wave

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "playdate", "source", "audio")
FFMPEG = "/opt/homebrew/bin/ffmpeg"
sys.path.insert(0, HERE)

import compose  # noqa: E402
import organ_wave  # noqa: E402
import organ_render  # noqa: E402

# Cue catalogue: what each cue is for and how it behaves. "midi" = our arrangement exists.
CUES = {
    # name            kind       loop   midi   description
    "take_me_out":   ("music",   True,  True,  "Take Me Out to the Ball Game (1908) - 7th-inning stretch"),
    # selection.json "aliases" picks which file plays as take_me_out (the organ arrangement, chosen by ear)
    "take_me_out_organ":    ("music", False, True,  "Take Me Out - full-chorus ballpark organ (ours, from the 1908 score)"),
    "charge":        ("stinger", False, True,  "Charge! (traditional bugle call) - ballpark organ sting"),
    "charge_band":   ("stinger", False, False, "Charge! (traditional bugle call) - full band"),
    "gladiators":    ("music",   False, False, "Entry of the Gladiators (Fucik 1897) - blowups, clowns, raccoons"),
    "stars_stripes": ("music",   False, False, "The Stars and Stripes Forever (Sousa 1896) - big wins"),
    "summertime":    ("music",   True,  False, "In the Good Old Summertime (1902) - idle/desktop"),
    "sweet_georgia": ("music",   True,  False, "Sweet Georgia Brown (1925) - showboating"),
    "turkey_straw":  ("music",   False, False, "Turkey in the Straw (traditional) - quick fills"),
    "funeral_march": ("music",   False, True,  "Funeral March (Chopin 1840) - blowout losses, busted bets"),
    "hat_dance":     ("music",   True,  False, "Jarabe Tapatio / Mexican Hat Dance (traditional) - rally"),
    "pop_weasel":    ("music",   False, True,  "Pop Goes the Weasel (traditional) - walk-up jingle"),
    "hail_chief":    ("music",   False, False, "Hail to the Chief (Sanderson c.1812) - officials, commissioner"),
    "wedding_march": ("music",   False, True,  "Wedding March (Mendelssohn 1842) - life events"),
    "bridal_chorus": ("music",   False, True,  "Bridal Chorus (Wagner 1850) - weddings"),
    "ragtime":       ("music",   True,  False, "Black Diamond Rag (1912 band recording) - idle/desktop"),
    "casey":         ("music",   False, False, "Casey at the Bat (1909 recitation, the strikeout) - star strikes out"),
    "stretch_vamp":  ("music",   True,  True,  "Original organ vamp (ours) - between innings"),
    "ejection":      ("stinger", False, True,  "Shave and a Haircut (trad. 1899) - you're outta here"),
    "home_run":      ("stinger", False, True,  "Original stinger - home run"),
    "strikeout":     ("stinger", False, True,  "Original stinger - strikeout"),
    "error":         ("stinger", False, True,  "Original stinger - error"),
    "bet_won":       ("stinger", False, True,  "Original stinger - bet won"),
    "bet_lost":      ("stinger", False, True,  "Original stinger - bet lost"),
    "pack_opened":   ("stinger", False, True,  "Original stinger - card pack opened"),
    "new_mail":      ("stinger", False, True,  "Original stinger - new mail"),
    "arrest":        ("stinger", False, True,  "Original stinger - arrest"),
}

# Rendered-organ cues that must sit level with the real recordings they can replace
# (loudness-normalized like music, no presence lift: the organ is bright already).
ORGAN_PROCESS = {
    "take_me_out_organ": ({"highpass": 280, "lowpass": 5500, "presence": 0},
                          "music"),
}

SFX = ["crowd_roar", "crowd_cheer", "crowd_boo", "crowd_ooh", "crowd_ambience", "applause",
       "bat_crack", "mitt_pop", "strike_call", "out_call", "whistle", "vendor_bell", "vendor_call",
       "telegraph", "typewriter", "modem", "cash_register", "pack_tear", "card_flip", "siren",
       "jail_door", "phone_ring", "focus", "select", "back", "error_blip"]


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(cmd)}\n{r.stderr[-2000:]}")
    return r


def peak_db(path, ss=None, to=None, af=None):
    cmd = [FFMPEG, "-hide_banner", "-nostats"]
    if ss is not None:
        cmd += ["-ss", str(ss)]
    if to is not None:
        cmd += ["-to", str(to)]
    cmd += ["-i", path]
    if af:
        cmd += ["-af", af + ",volumedetect"]
    else:
        cmd += ["-af", "volumedetect"]
    cmd += ["-f", "null", "-"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    for line in r.stderr.splitlines():
        if "max_volume" in line:
            return float(line.split(":")[1].split()[0])
    return 0.0


def concat_segments(src, segments):
    """Cut [[a,b],...] out of src and splice them (10 ms crossfades) into a temp WAV."""
    tmp = os.path.join(HERE, ".cache", "_seg_" + os.path.basename(src) + ".wav")
    parts, labels = [], []
    for i, (a, b) in enumerate(segments):
        parts.append(f"[0:a]atrim={a}:{b},asetpts=PTS-STARTPTS[s{i}]")
        labels.append(f"[s{i}]")
    chain = labels[0]
    for i in range(1, len(labels)):
        out = f"[x{i}]"
        parts.append(f"{chain}{labels[i]}acrossfade=d=0.01{out}")
        chain = out
    run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-filter_complex", ";".join(parts),
         "-map", chain, "-ac", "1", "-ar", "44100", tmp])
    return tmp


def process(src, dst, item, kind):
    """Trim + lo-fi + normalize -> IMA ADPCM WAV (or PCM16 for organ notes)."""
    if item.get("segments"):
        src = concat_segments(src, item["segments"])
        item = dict(item)
        item.pop("start", None)
        r = subprocess.run([FFMPEG.replace("ffmpeg", "ffprobe"), "-v", "error", "-show_entries", "format=duration",
                            "-of", "csv=p=0", src], capture_output=True, text=True)
        item["start"], item["end"] = 0, float(r.stdout.strip())
    ss, to = item.get("start"), item.get("end")
    sr = item.get("rate", 16000)  # everything is low-passed below 8 kHz; the speaker rolls off well before that
    # The Playdate's speaker can't reproduce much below ~400 Hz; low-end energy only turns
    # into boom and mud ("woofy"). Cut it hard and lift the presence band instead.
    hp = item.get("highpass", 350 if kind == "music" else 300)
    lp = item.get("lowpass", 6500 if kind == "music" else 7500)
    chain = [f"highpass=f={hp}:poles=2", f"highpass=f={hp}:poles=2", f"lowpass=f={lp}",
             f"equalizer=f={item.get('presence_hz', 2500)}:t=q:w=1.2:g={item.get('presence', 3)}"]
    if item.get("denoise"):
        chain.append(f"afftdn=nf={item.get('denoise_nf', -30)}")
    if kind == "music":
        chain.append("acompressor=threshold=-20dB:ratio=3:attack=10:release=200")
    if item.get("af"):
        chain.append(item["af"])
    dur = (to - ss) if (ss is not None and to is not None) else None
    fi, fo = item.get("fade_in", 0.02), item.get("fade_out", 0.25 if kind == "music" else 0.03)
    if dur:
        chain.append(f"afade=t=in:d={fi}")
        chain.append(f"afade=t=out:st={max(0, dur - fo)}:d={fo}")
    if kind == "music":
        # loudness-match the cues (band recordings vary wildly), then cap peaks
        chain.append("loudnorm=I=-16:TP=-1.5:LRA=9")
        chain.append("alimiter=limit=0.89")
        if item.get("post_gain_db"):  # single-pass loudnorm undershoots on some sources
            chain += [f"volume={item['post_gain_db']}dB", "alimiter=limit=0.89"]
        af = ",".join(chain)
    else:
        af = ",".join(chain)
        gain = -1.0 - peak_db(src, ss, to, af)
        af += f",volume={gain:.2f}dB"
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y"]
    if ss is not None:
        cmd += ["-ss", str(ss)]
    if to is not None:
        cmd += ["-to", str(to)]
    cmd += ["-i", src, "-ac", "1", "-ar", str(sr), "-af", af]
    cmd += ["-acodec", "pcm_s16le" if kind == "organ" else "adpcm_ima_wav", dst]
    run(cmd)


def process_organ(src, dst, item):
    """Real organ note -> pitch-corrected, looped 16-bit PCM that a synth plays as 'C4'.
    Data is 22.05 kHz; the WAV header rate is shifted by whole octaves so the note plays
    back as C4 at rate 1 (synth convention). Returns (loopStart, loopEnd) in frames."""
    import numpy as np
    m, cents = item["midi"], item.get("cents", 0)
    octs = (60 - m) / 12
    assert octs == int(octs), "organ notes must be C's (whole octaves from C4)"
    fix = 2 ** (-cents / 1200)
    af = f"asetrate={int(round(44100 * fix))},aresample=44100,highpass=f=40"
    raw = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-ss", str(item.get("start", 0)), "-to",
                          str(item.get("end", 2.2)), "-i", src, "-ac", "1", "-af", af, "-ar", "22050", "-f", "s16le",
                          "-"], capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float64)
    sr = 22050
    f0 = 440 * 2 ** ((m - 69) / 12)
    period = sr / f0
    # skip the leading silence/attack: start of note = first sample above 10 % of peak
    peak = np.max(np.abs(x)) or 1
    on = int(np.argmax(np.abs(x) > 0.1 * peak))
    x = x[max(0, on - 20):]
    # loop: ~0.6 s of whole cycles starting ~0.35 s in, end refined by correlation
    ls = int(0.35 * sr)
    while ls < len(x) - 1 and not (x[ls] <= 0 < x[ls + 1]):
        ls += 1
    cycles = max(1, int(round(0.6 * sr / period)))
    target = ls + cycles * period
    w = 256
    best, le = -2, int(round(target))
    span = int(period / 2) + 2
    for c in range(int(target) - span, int(target) + span + 1):
        a, b = x[ls:ls + w], x[c:c + w]
        if len(b) < w:
            continue
        r = np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)
        if r > best:
            best, le = r, c
    # crossfade the tail of the loop into the audio just before the loop start
    xf = min(512, ls)
    seg = x[:le].copy()
    ramp = np.linspace(0, 1, xf)
    seg[le - xf:le] = seg[le - xf:le] * (1 - ramp) + x[ls - xf:ls] * ramp
    seg = seg / (np.max(np.abs(seg)) or 1) * 0.89 * 32767
    with wave.open(dst, "wb") as wv:
        wv.setnchannels(1); wv.setsampwidth(2); wv.setframerate(int(sr * 2 ** octs))
        wv.writeframes(seg.astype(np.int16).tobytes())
    print(f"organ {os.path.basename(dst)}: loop {ls}..{le} xcorr={best:.4f}")
    return ls, le


def lua_val(v, ind=""):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{ " + ", ".join(lua_val(x, ind) for x in v) + " }"
    if isinstance(v, dict):
        inner = ind + "  "
        parts = [f"{inner}{k} = {lua_val(v[k], inner)}," if k.isidentifier() else
                 f"{inner}[{json.dumps(k)}] = {lua_val(v[k], inner)}," for k in sorted(v)]
        return "{\n" + "\n".join(parts) + "\n" + ind + "}"
    raise TypeError(v)


def main():
    use_ffmpeg = "--no-ffmpeg" not in sys.argv
    for d in ("midi", "music", "sfx", "organ"):
        os.makedirs(os.path.join(OUT, d), exist_ok=True)

    # 1. MIDI
    compose.OUT = os.path.join(OUT, "midi")
    steps, songs = {}, {}
    for name, fn in compose.CUES.items():
        song, total = compose.render(fn)
        steps[name] = song.write(os.path.join(OUT, "midi", name + ".mid"), total)
        songs[name] = (song, total if total is not None else -(-song.length_beats() // song.bpb) * song.bpb)

    # 2. synthesized organ
    data, ls, le, f0 = organ_wave.render()
    with wave.open(os.path.join(OUT, "organ", "tonewheel.wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(organ_wave.SR)
        w.writeframes(b"".join(struct.pack("<h", x) for x in data))
    organs = {"tonewheel": {"file": "audio/organ/tonewheel", "loopStart": ls, "loopEnd": le,
                            "gain": 1.0}}

    # 3. real recordings / samples
    sel_path = os.path.join(HERE, "selection.json")
    sel = json.load(open(sel_path)) if os.path.exists(sel_path) else {}
    credits = []
    music, sfx = {}, {}
    for name, (kind, loop, has_midi, desc) in CUES.items():
        e = {"kind": kind, "loop": loop, "desc": desc}
        if has_midi:
            e["midi"] = f"audio/midi/{name}.mid"
            e["steps"] = steps[name]
        music[name] = e

    def add_credit(file, it):
        if it.get("license"):
            credits.append({"file": file, "title": it.get("title"), "author": it.get("author"),
                            "url": it.get("page_url") or it.get("url"), "license": it["license"],
                            "year": it.get("year"), "notes": it.get("credit_notes")})

    for name, it in sel.get("music", {}).items():
        dst = f"audio/music/{name}"
        if use_ffmpeg:
            process(os.path.join(ROOT, it["src"]), os.path.join(ROOT, "playdate", "source", dst + ".wav"), it, "music")
        e = music.setdefault(name, {"kind": "music", "loop": it.get("loop", False), "desc": it.get("title", name)})
        e["file"] = dst
        e["gain"] = it.get("gain", 1.0)
        if "loop" in it:
            e["loop"] = it["loop"]
        add_credit(dst + ".wav", it)

    for name, its in sel.get("sfx", {}).items():
        files = []
        for i, it in enumerate(its if isinstance(its, list) else [its]):
            dst = f"audio/sfx/{name}" + (f"_{i + 1}" if i else "")
            if use_ffmpeg:
                process(os.path.join(ROOT, it["src"]), os.path.join(ROOT, "playdate", "source", dst + ".wav"), it,
                        "ambience" if name == "crowd_ambience" else "sfx")
            files.append(dst)
            add_credit(dst + ".wav", it)
            gain = it.get("gain", 1.0)
        sfx[name] = {"files": files, "gain": gain}

    # 3b. arrangements with no real recording: render the organ offline (organ_render.py)
    #     and ship a file; the runtime prefers files over live MIDI synthesis.
    aliases = sel.get("aliases", {})
    for name, e in music.items():
        if e.get("file") or name not in songs or name in aliases:
            continue
        dst = f"audio/music/{name}"
        if use_ffmpeg:
            tmp = os.path.join(HERE, ".cache", "organ_render", name + ".wav")
            os.makedirs(os.path.dirname(tmp), exist_ok=True)
            song, total = songs[name]
            organ_render.write_wav(tmp, organ_render.render(song, total, loop=e["loop"]))
            opts, kind = ORGAN_PROCESS.get(name, ({"highpass": 280, "lowpass": 7500}, "sfx"))
            process(tmp, os.path.join(ROOT, "playdate", "source", dst + ".wav"), opts, kind)
        e["file"] = dst
        e["gain"] = 1.0 if name in ORGAN_PROCESS else 0.9

    # 3b'. aliases: a cue that plays another cue's file, e.g. "take_me_out": "take_me_out_haydn".
    #      Switching which candidate plays is that one line in selection.json.
    for name, target in aliases.items():
        t = music[target]
        music[name]["file"], music[name]["gain"], music[name]["loop"] = t["file"], t.get("gain", 1.0), t["loop"]
        music[name]["alias_of"] = target

    # 3c. DBN broadcast stings for BallCast's TV package: synthesized offline (tv_stings.py),
    #     original, so no credit row beyond docs/CREDITS.md
    import tv_stings
    rendered = tv_stings.render_all() if use_ffmpeg else {}
    for name in tv_stings.CUES:
        dst = f"audio/sfx/{name}"
        if use_ffmpeg:
            process(rendered[name][0], os.path.join(ROOT, "playdate", "source", dst + ".wav"),
                    {"highpass": 260, "lowpass": 7500, "rate": 22050}, "sfx")
        sfx[name] = {"files": [dst], "gain": 1.0}

    loops_path = os.path.join(HERE, ".organ_loops.json")  # remembers loops for --no-ffmpeg runs
    loops = json.load(open(loops_path)) if os.path.exists(loops_path) else {}
    for name, it in sel.get("organ", {}).items():
        dst = f"audio/organ/{name}"
        if use_ffmpeg:
            loops[name] = process_organ(os.path.join(ROOT, it["src"]), os.path.join(ROOT, "playdate", "source", dst + ".wav"), it)
        ls, le = loops[name]
        organs[name] = {"file": dst, "loopStart": ls, "loopEnd": le, "gain": it.get("gain", 1.0)}
        add_credit(dst + ".wav", it)
    json.dump(loops, open(loops_path, "w"))

    roles = sel.get("organ_roles", {})
    roles = {r: roles.get(r, "tonewheel") for r in ("lead", "chords", "bass")}
    manifest = {"cues": music, "sfx": sfx, "organs": organs, "organ": roles}
    with open(os.path.join(OUT, "manifest.lua"), "w") as f:
        f.write("-- GENERATED by tools/audio/build.py - do not edit by hand.\n")
        f.write("AudioManifest = " + lua_val(manifest) + "\n")
    with open(os.path.join(OUT, "credits.json"), "w") as f:
        json.dump(credits, f, indent=1, ensure_ascii=False)
    total = 0
    for dp, _, fs in os.walk(OUT):
        total += sum(os.path.getsize(os.path.join(dp, x)) for x in fs if x.endswith((".wav", ".mid")))
    print(f"cues={len(music)} sfx={len(sfx)} organs={len(organs)} credits={len(credits)} audio bytes={total}")


if __name__ == "__main__":
    main()
