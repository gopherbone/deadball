"""Build the face bank from cached LoC photos.

Inputs  (all under tools/assets/):
  .cache/loc/index.json, .cache/loc/img/<pk>.jpg   (faces_fetch.py)
  faces_detect.json                                 (faces_detect.py, checked in)
  faces_overrides.json                              (hand review: skips, crop nudges, sex/age)
  faces_ids.json                                    (frozen person -> face index map, checked in)
Outputs:
  playdate/source/images/faces/<n>-24.png  24x24   list thumb
  playdate/source/images/faces/<n>-48.png  48x60   inline / small card
  playdate/source/images/faces/<n>-96.png  96x120  fan page / event card
  ... and <n>b-*, <n>c-* for extra photos of the same person (photo bank)
  playdate/source/images/faces/thumbs-table-24-24.png  all 24px thumbs, frame n+1 = face n
  playdate/source/images/faces/faces.json  manifest
  packages/sim/src/faces.ts                FaceInfo catalogue
"""
import os, sys, json, re, math
import numpy as np
from PIL import Image, ImageOps, ImageFilter, ImageEnhance

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (CACHE, HERE, ROOT, IMAGES, PREVIEW, atkinson, save_1bit, save_table, contact_sheet,
                    write_readme_part, write_json, ensure_dir, font)
import faces_select as fs

LOC = os.path.join(CACHE, "loc")
OUT = os.path.join(IMAGES, "faces")
DETECT = os.path.join(HERE, "faces_detect.json")
OVERRIDES = os.path.join(HERE, "faces_overrides.json")
IDS = os.path.join(HERE, "faces_ids.json")
FACES_TS = os.path.join(ROOT, "packages", "sim", "src", "faces.ts")

TARGET = 600          # faces in the bank (worldgen draws face:0..FACES-1)
MAX_PHOTOS = 3
VARIANTS = ["", "b", "c"]
SIZES = {"24": (24, 24), "48": (48, 60), "96": (96, 120)}


def load_json(p, default):
    return json.load(open(p)) if os.path.exists(p) else default


# ---------------------------------------------------------------- photo scoring

def dominant_face(det, ov):
    faces = det.get("faces", [])
    if not faces:
        return None
    i = ov.get("face", 0)
    if i >= len(faces):
        return None
    f = faces[i]
    if "face" not in ov and len(faces) > 1:
        a0 = faces[0][2] * faces[0][3]
        a1 = faces[1][2] * faces[1][3]
        if a1 > 0.45 * a0 and faces[1][4] > 0.7:
            return None  # two similar-sized faces: a group shot
    return f


def photo_quality(det, ov):
    f = dominant_face(det, ov)
    if f is None:
        return 0.0, None
    x, y, w, h, score = f[:5]
    if score < 0.72 and "face" not in ov:
        return 0.0, None
    W, H = det["size"]
    if w < 34 and not ov.get("force"):
        return 0.0, None
    # frontalness: nose between the eyes, eyes level
    rex, rey, lex, ley, nx, ny = f[5:11]
    ed = abs(lex - rex) + 1e-3
    frontal = 1.0 - min(1.0, abs((nx - (rex + lex) / 2) / ed))
    tilt = abs(ley - rey) / ed
    size = min(w, 150) / 150
    # head must have room for a crop
    room = 1.0 if (x > -0.2 * w and x + w < W + 0.2 * w and y > 0.2 * h) else 0.6
    q = score * (0.35 + 0.65 * size) * (0.55 + 0.45 * frontal) * (1 - min(0.5, tilt)) * room
    return q, f


# ---------------------------------------------------------------- cropping + tone

def crop_box(f, size_key, imsize, ov):
    """Return (x0, y0, x1, y1) crop in source pixels for the given output size."""
    x, y, w, h = f[:4]
    rex, rey, lex, ley = f[5:9]
    ex, ey = (rex + lex) / 2, (rey + ley) / 2
    cx = 0.6 * ex + 0.4 * (x + w / 2)
    zoom = ov.get("zoom", 1.0)
    if size_key == "24":
        cw = 1.30 * max(w, h * 0.85) / zoom
        ch = cw
        top = ey - 0.40 * ch
    else:
        cw = 2.05 * max(w, h * 0.85) / zoom
        ch = cw * 1.25
        top = ey - 0.40 * ch
    cx += ov.get("dx", 0.0) * cw
    top += ov.get("dy", 0.0) * ch
    W, H = imsize
    # keep inside the photo: shrink if needed, then shift
    s = min(1.0, W / cw, H / ch)
    cw, ch = cw * s, ch * s
    x0 = min(max(0, cx - cw / 2), W - cw)
    y0 = min(max(0, top), H - ch)
    return (x0, y0, x0 + cw, y0 + ch)


def tone(img, out_size, face_rect, size_key, ov):
    """img: L crop already resized to out_size. face_rect in output coords."""
    a = np.asarray(img, np.float32) / 255.0
    fx0, fy0, fx1, fy1 = [int(round(v)) for v in face_rect]
    fx0, fy0 = max(0, fx0), max(0, fy0)
    fx1, fy1 = min(a.shape[1], max(fx0 + 2, fx1)), min(a.shape[0], max(fy0 + 2, fy1))
    region = a[fy0:fy1, fx0:fx1]
    lo, hi = np.percentile(region, 3), np.percentile(region, 97)
    glo, ghi = np.percentile(a, 1), np.percentile(a, 99)
    lo, hi = min(lo, 0.5 * lo + 0.5 * glo), max(hi, 0.7 * hi + 0.3 * ghi)
    if hi - lo < 0.15:
        hi = lo + 0.15
    a = np.clip((a - lo) / (hi - lo), 0, 1)
    # adaptive gamma: put the face's median tone at a fixed target so faces neither blow out
    # nor go muddy in 1-bit
    fm = float(np.median(np.clip((region - lo) / (hi - lo), 0.02, 0.98)))
    target = ov.get("target", {"24": 0.56, "48": 0.52, "96": 0.50}[size_key])
    gamma = math.log(target) / math.log(min(0.95, max(0.05, fm)))
    gamma = min(2.2, max(0.45, gamma)) * ov.get("gamma", 1.0)
    a = a ** gamma
    # S-curve for punch
    k = ov.get("contrast", {"24": 1.35, "48": 1.25, "96": 1.18}[size_key])
    a = np.clip(0.5 + (a - 0.5) * k, 0, 1)
    a = 0.03 + 0.97 * a
    im = Image.fromarray((a * 255).astype(np.uint8), "L")
    radius = {"24": 0.8, "48": 1.0, "96": 1.4}[size_key]
    im = im.filter(ImageFilter.UnsharpMask(radius=radius, percent=110, threshold=1))
    return atkinson(im)


def render(pk, f, imsize, ov):
    src = Image.open(os.path.join(LOC, "img", f"{pk}.jpg")).convert("L")
    out = {}
    for key, (tw, th) in SIZES.items():
        box = crop_box(f, key, imsize, ov)
        sc = tw / (box[2] - box[0])
        x, y, w, h = f[:4]
        frect = ((x - box[0]) * sc, (y - box[1]) * sc, (x + w - box[0]) * sc, (y + h - box[1]) * sc)
        # supersample: crop -> resize with Lanczos (reducing_gap for quality)
        c = src.crop(tuple(int(round(v)) for v in box)).resize((tw, th), Image.LANCZOS)
        out[key] = tone(c, (tw, th), frect, key, ov)
    return out


# ---------------------------------------------------------------- selection

def select(index, det, ovr):
    photos_ov = ovr.get("photos", {})
    people_ov = ovr.get("people", {})
    cands = set(fs.prefilter(index))
    people = {}
    for pk in cands:
        e = index[pk]
        if pk not in det:
            continue
        pov = photos_ov.get(pk, {})
        if pov.get("skip"):
            continue
        q, f = photo_quality(det[pk], pov)
        if q <= 0.25:
            continue
        key = pov.get("person") or fs.person_key(e)
        if people_ov.get(key, {}).get("skip"):
            continue
        people.setdefault(key, []).append((q, pk, f))
    # merge caption variants of the same person ("Jeff Tesreau" / 'Charles M. "Jeff" Tesreau')
    names = {}
    for k, ph in people.items():
        np_ = fs.name_parts(index[ph[0][1]])
        if np_:
            names[k] = np_
    frozen = load_json(IDS, {})
    keys = sorted(people, key=lambda k: (k not in frozen, -len(people[k]), k))
    for i, a in enumerate(keys):
        if a not in people or a not in names:
            continue
        for b in keys[i + 1:]:
            if b in people and b in names and names[a][0] == names[b][0] and fs.same_person_names(
                    names[a][1], names[b][1], index[people[a][0][1]], index[people[b][0][1]]):
                people[a] += people.pop(b)
    for k in people:
        people[k].sort(key=lambda t: -t[0])
        people[k] = people[k][:MAX_PHOTOS]
    return people


def assign_ids(people, ranked_keys):
    target = min(TARGET, len(ranked_keys))
    ids = load_json(IDS, {})
    ids = {k: v for k, v in ids.items() if k in people and v < target}
    used = set(ids.values())
    free = [i for i in range(target) if i not in used]
    for k in ranked_keys:
        if k in ids:
            continue
        if not free:
            break
        ids[k] = free.pop(0)
    with open(IDS, "w") as fh:
        json.dump(dict(sorted(ids.items(), key=lambda kv: kv[1])), fh, indent=0)
        fh.write("\n")
    return ids


def balance(people, index):
    """Rank people: best quality first, but make sure women / old faces are represented."""
    rows = []
    for k, ph in people.items():
        e = index[ph[0][1]]
        sex = fs.caption_sex(e)
        rows.append((k, ph[0][0] + 0.05 * (len(ph) - 1), sex))
    rows.sort(key=lambda r: -r[1])
    women = [r for r in rows if r[2] == "F"]
    men = [r for r in rows if r[2] != "F"]
    nf = min(len(women), int(TARGET * 0.22))
    picked = women[:nf] + men[:TARGET - nf]
    if len(picked) < TARGET:
        picked += women[nf:TARGET - len(picked) + nf]
    picked.sort(key=lambda r: -r[1])
    return [r[0] for r in picked]


def build(verbose=True):
    index = load_json(os.path.join(LOC, "index.json"), {})
    det = load_json(DETECT, {})
    ovr = load_json(OVERRIDES, {"photos": {}, "people": {}})
    if not index or not det:
        print("faces: no cached index/detections; run faces_fetch.py and faces_detect.py first")
        return
    people = select(index, det, ovr)
    ranked = balance(people, index)
    ids = assign_ids(people, ranked)
    by_n = sorted(((n, k) for k, n in ids.items()), key=lambda t: t[0])
    ensure_dir(OUT)
    for fn in os.listdir(OUT):
        if fn.endswith(".png"):
            os.remove(os.path.join(OUT, fn))
    manifest, infos, thumbs, sheet_items = [], [], [], []
    people_ov = ovr.get("people", {})
    photos_ov = ovr.get("photos", {})
    n_expected = 0
    for n, key in by_n:
        ph = people[key]
        e0 = index[ph[0][1]]
        pov = people_ov.get(key, {})
        sex = pov.get("sex") or fs.caption_sex(e0) or "M"
        age = pov.get("age") or fs.caption_age(e0)[0] or "adult"
        variants = []
        for vi, (q, pk, f) in enumerate(ph):
            suf = VARIANTS[vi]
            imgs = render(pk, f, det[pk]["size"], photos_ov.get(pk, {}))
            for sk, im in imgs.items():
                save_1bit(im, os.path.join(OUT, f"{n}{suf}-{sk}.png"))
            if vi == 0:
                thumbs.append(imgs["24"])
                sheet_items.append((imgs["48"], f"{n}{sex}{age[0]}"))
            variants.append({"suffix": suf, "pk": pk, "source": index[pk]["item"],
                             "caption": fs.clean_title(index[pk]["title"])})
        manifest.append({"n": n, "id": f"face:{n}", "sex": sex, "age": age, "photos": len(variants),
                         "key": key, "variants": variants})
        infos.append({"id": f"face:{n}", "sex": sex, "age": age, "title": variants[0]["caption"],
                      "source": variants[0]["source"], "photos": len(variants)})
    # contiguous check
    ns = [m["n"] for m in manifest]
    assert ns == list(range(len(ns))), "face ids must be contiguous 0..N-1"
    save_table(thumbs, OUT, "thumbs", cols=25)
    write_json(os.path.join(OUT, "faces.json"), {
        "count": len(manifest), "sizes": {"24": [24, 24], "48": [48, 60], "96": [96, 120]},
        "pattern": "images/faces/{n}{variant}-{size}", "faces": manifest}, indent=None)
    write_faces_ts(infos)
    write_credits(len(manifest), sum(m["photos"] for m in manifest))
    # previews
    for s in range(0, len(sheet_items), 100):
        contact_sheet(sheet_items[s:s + 100], os.path.join(PREVIEW, f"faces-{s // 100}.png"), cols=20, scale=1)
    bank = []
    for m in [m for m in manifest if m["photos"] > 1][:30]:
        for v in m["variants"]:
            bank.append((Image.open(os.path.join(OUT, f"{m['n']}{v['suffix']}-96.png")), f"{m['n']}{v['suffix']}"))
        bank += [(Image.new("L", (96, 120), 200), "")] * (3 - len(m["variants"]))
    contact_sheet(bank, os.path.join(PREVIEW, "faces-photobank.png"), cols=12, cell=(96, 120))
    write_readme(len(manifest), sum(m["photos"] for m in manifest))
    if verbose:
        sexes = {}
        for m in manifest:
            sexes[(m["sex"], m["age"])] = sexes.get((m["sex"], m["age"]), 0) + 1
        print(f"faces: {len(manifest)} faces, {sum(m['photos'] for m in manifest)} photos; {sexes}")
    return manifest


def write_credits(nfaces, nphotos):
    """Merge one entry for the face bank into images/credits.json (other paths are kept)."""
    path = os.path.join(IMAGES, "credits.json")
    cur = load_json(path, [])
    cur = [c for c in cur if not str(c.get("path", "")).startswith("images/faces/")]
    cur.append({"path": "images/faces/",
                "title": f"Face bank: {nfaces} people, {nphotos} photos (sources per face in faces.json)",
                "author": "Bain News Service", "url": "https://www.loc.gov/pictures/collection/ggbain/",
                "license": "Public domain (Library of Congress, George Grantham Bain Collection; no known restrictions on publication)"})
    cur.sort(key=lambda c: c.get("path", ""))
    write_json(path, cur)


def write_faces_ts(infos):
    lines = [
        "// Face bank catalogue. GENERATED by tools/assets/faces_build.py -- do not edit by hand.",
        "// One entry per real (non-famous) person photographed by the Bain News Service, 1900s-1920s",
        "// (Library of Congress, no known restrictions on publication). Images: playdate/source/images/faces/",
        "// <n>-24.png (24x24), <n>-48.png (48x60), <n>-96.png (96x120); extra photos of the same person",
        "// use suffixes b, c (e.g. <n>b-96.png) -- `photos` says how many exist.",
        "",
        "export interface FaceInfo {",
        "  id: string;",
        '  sex: "M" | "F";',
        '  age: "young" | "adult" | "old";',
        "  /** Original caption of the source photo. */",
        "  title: string;",
        "  /** Source URL (Library of Congress item). */",
        "  source: string;",
        "  /** Number of photos of this person in the bank (1-3): suffixes '', 'b', 'c'. */",
        "  photos?: number;",
        "}",
        "",
        "export const FACES: FaceInfo[] = [",
    ]
    for i in infos:
        lines.append("  " + json.dumps(i, ensure_ascii=False) + ",")
    lines += ["];", ""]
    with open(FACES_TS, "w") as fh:
        fh.write("\n".join(lines))


def write_readme(nfaces, nphotos):
    write_readme_part("10-faces.md", f"""
## Faces (`images/faces/`)

{nfaces} faces ({nphotos} photos) from the Library of Congress Bain News Service collection,
cropped to the head and Atkinson-dithered to 1-bit. Face `n` = sim id `face:<n>`
(`packages/sim/src/faces.ts`, contiguous `0..{nfaces - 1}`).

| file | size | use |
|---|---|---|
| `faces/<n>-24.png` | 24×24 | list thumbnails (tight head crop) |
| `faces/<n>-48.png` | 48×60 | inline / small card window |
| `faces/<n>-96.png` | 96×120 | fan page, event card, big card window |
| `faces/<n>b-<size>.png`, `faces/<n>c-<size>.png` | same | extra photos of the same person ("photo bank"); exist only if `photos` ≥ 2 / 3 |
| `faces/thumbs-table-24-24.png` | 24×24 cells, 25 per row | every face's 24px thumb in one imagetable: `getImage(n + 1)` = face n |
| `faces/faces.json` | | manifest (below) |

Lua: `gfx.image.new("images/faces/" .. n .. "-96")`, or `gfx.imagetable.new("images/faces/thumbs")`.
All face PNGs are opaque (black/white); draw a 1px frame around them yourself.

`faces.json`:
```json
{{"count": {nfaces}, "sizes": {{"24": [24,24], "48": [48,60], "96": [96,120]}},
 "pattern": "images/faces/{{n}}{{variant}}-{{size}}",
 "faces": [{{"n": 0, "id": "face:0", "sex": "M", "age": "adult", "photos": 2, "key": "s:dolan cozy",
            "variants": [{{"suffix": "", "pk": "2003689088", "source": "https://www.loc.gov/pictures/...", "caption": "..."}}, ...]}}]}}
```
`sex` is M/F, `age` young/adult/old (caption hints + hand review). Captions are the real LoC captions —
don't show them in-game next to fictional names (they name real people); they're for credits/debugging.
""")


if __name__ == "__main__":
    build()
