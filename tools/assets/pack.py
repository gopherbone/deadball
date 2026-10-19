"""Pack the Playdate build's many small assets into a few files (run by `make` in playdate/).

  python3 tools/assets/pack.py [OUT]     # default OUT: playdate/build/packed

The device copies a .pdx through its FAT data disk, which is very slow per file, so the
loose per-person / per-photo files in playdate/source stay the source of truth (the asset
pipeline, the sim's archive test and the dev harness read them) but the Makefile stages the
build without them and adds what this script writes instead:

  OUT/images/faces/f<size>-<k>-table-<w>-<h>.png     face bank, one size class per table run
  OUT/images/faces/pack.json                         {sizes: {"<size>": {w, h, per, tables, keys}}}
  OUT/images/archive/a<size>-<k>-table-<w>-<h>.png   photo archive, same scheme
  OUT/images/archive/pack.json
  OUT/<dir>/pack.json + pack-index.json              each fixtures dir as one JSON object
                                                     {"<file>.json": <original bytes>, ...};
                                                     pack-index.json = {"<file>.json": [offset, length]}

Image key k-th (1-based) of a size class lives in table (k-1)//per + 1, frame (k-1)%per + 1.
`per` is picked so one decoded table is ~120-220 KB (1-bit rows pad to 32 bits), since the
whole table loads at once. Lua side: playdate/source/ui/packs.lua.
Frames are copied pixel for pixel (verified) -- nothing is re-dithered.
"""
import os, sys, re, json, glob, shutil

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SRC = os.path.join(ROOT, "playdate", "source")
DEFAULT_OUT = os.path.join(ROOT, "playdate", "build", "packed")
MAX_SHEET_W = 2048

# size class -> (w, h, frames per table)
FACES = {24: (24, 24, 1024), 48: (48, 60, 64), 96: (96, 120, 32)}  # small tables: one decode ~46 KB (device loader slices)
ARCHIVE = {48: (48, 36, 512), 96: (96, 72, 256), 160: (160, 100, 96), 400: (400, 240, 16)}
JSON_DIRS = ["fixtures", "fixtures_dev", "fixtures_dev/ballcast"]


def _bit(path, w, h):
    im = Image.open(path)
    im.load()
    if im.size != (w, h):
        raise SystemExit(f"pack: {path} is {im.size}, expected {(w, h)}")
    if im.mode != "1":
        im = im.convert("L").point(lambda v: 255 if v >= 128 else 0).convert("1")
    return im


def pack_images(src_dir, out_dir, prefix, classes, keyfn, pattern):
    """pattern: regex with groups (key, size) matched against file names in src_dir."""
    rx = re.compile(pattern)
    by_size = {s: [] for s in classes}
    for fn in os.listdir(src_dir):
        m = rx.match(fn)
        if m and int(m.group(2)) in classes:
            by_size[int(m.group(2))].append(m.group(1))
    os.makedirs(out_dir, exist_ok=True)
    for old in glob.glob(os.path.join(out_dir, prefix + "*-table-*.png")):
        os.remove(old)
    index = {"version": 1, "sizes": {}}
    nfiles = 0
    for size, (w, h, per) in classes.items():
        keys = sorted(by_size[size], key=keyfn)
        tables = []
        for t0 in range(0, len(keys), per):
            chunk = keys[t0:t0 + per]
            cols = max(1, min(len(chunk), MAX_SHEET_W // w))
            rows = (len(chunk) + cols - 1) // cols
            sheet = Image.new("1", (cols * w, rows * h), 1)
            frames = []
            for i, k in enumerate(chunk):
                im = _bit(os.path.join(src_dir, f"{k}-{size}.png"), w, h)
                frames.append(im)
                sheet.paste(im, ((i % cols) * w, (i // cols) * h))
            name = f"{prefix}{size}-{len(tables) + 1}"
            sheet.save(os.path.join(out_dir, f"{name}-table-{w}-{h}.png"), optimize=True)
            # verify the round trip pixel for pixel
            back = Image.open(os.path.join(out_dir, f"{name}-table-{w}-{h}.png")).convert("1")
            for i, im in enumerate(frames):
                x, y = (i % cols) * w, (i // cols) * h
                assert back.crop((x, y, x + w, y + h)).tobytes() == im.tobytes(), (name, chunk[i])
            tables.append(name)
            nfiles += 1
        index["sizes"][str(size)] = {"w": w, "h": h, "per": per, "tables": tables, "keys": keys}
    with open(os.path.join(out_dir, "pack.json"), "w") as fh:
        json.dump(index, fh, separators=(",", ":"))
    return sum(len(v) for v in by_size.values()), nfiles + 1


def pack_json_dir(src_dir, out_dir):
    names = sorted(f for f in os.listdir(src_dir) if f.endswith(".json") and f not in ("pack.json", "pack-index.json"))
    os.makedirs(out_dir, exist_ok=True)
    blob = bytearray(b"{\n")
    idx = {}
    for i, n in enumerate(names):
        raw = open(os.path.join(src_dir, n), "rb").read().strip()
        json.loads(raw)  # must be valid on its own
        blob += json.dumps(n).encode() + b": "
        idx[n] = [len(blob), len(raw)]
        blob += raw + (b",\n" if i < len(names) - 1 else b"\n")
    blob += b"}\n"
    json.loads(bytes(blob))  # the blob stays one valid JSON object
    with open(os.path.join(out_dir, "pack.json"), "wb") as fh:
        fh.write(blob)
    with open(os.path.join(out_dir, "pack-index.json"), "w") as fh:
        json.dump(idx, fh, separators=(",", ":"))
    return len(names)


def face_key(k):
    m = re.match(r"(\d+)(\D*)$", k)
    return (int(m.group(1)), m.group(2))


def build(out=DEFAULT_OUT, verbose=True):
    if os.path.isdir(out):
        shutil.rmtree(out)
    n, f = pack_images(os.path.join(SRC, "images", "faces"), os.path.join(out, "images", "faces"),
                       "f", FACES, face_key, r"^(\d+[a-z]?)-(\d+)\.png$")
    if verbose:
        print(f"[pack] faces: {n} images -> {f} files")
    n, f = pack_images(os.path.join(SRC, "images", "archive"), os.path.join(out, "images", "archive"),
                       "a", ARCHIVE, lambda k: k, r"^(.+)-(\d+)\.png$")
    if verbose:
        print(f"[pack] archive: {n} images -> {f} files")
    for d in JSON_DIRS:
        src = os.path.join(SRC, d)
        if os.path.isdir(src):
            n = pack_json_dir(src, os.path.join(out, d))
            if verbose:
                print(f"[pack] {d}: {n} json -> 2 files")


if __name__ == "__main__":
    build(os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT)
