"""Build the DEADBALL photo archive from fetched candidates.

  python3 tools/assets/archive/build.py review [group ...]   # gray+dithered review sheets of ALL candidates
                                                             #   -> tools/assets/.cache/archive/review/review-<group>.png
  python3 tools/assets/archive/build.py keep <group>=0,3,5   # curate: keep these review indexes (overrides.json _keep)
  python3 tools/assets/archive/build.py                      # select, process, write images + catalog

Selection: per group (queries.py), the first `take` candidates that overrides.json doesn't drop.
overrides.json (keyed by candidate key = sha1(title)[:12], shown on review sheets as group#n/key):
  {"<key>": {"drop": true}}
  {"<key>": {"crop": [x0, y0, x1, y1]}}        # fractions of the (trimmed) image to keep
  {"<key>": {"focus": [fx, fy]}}                # center for the aspect crops (default .5, .45)
  {"<key>": {"dither": "bayer"|"atkinson"|"threshold", "gamma": 0.8, "contrast": 1.2}}
  {"<key>": {"caption": "...", "tags": ["extra", ...], "group": "other-group"}}
  {"_pin": {"<group>": ["<key>", ...]}}          # force-include keys first

Outputs
  playdate/source/images/archive/<id>-<w>.png    w in 400 (400x240), 160 (160x100), 96 (96x72), 48 (48x36)
  playdate/source/images/archive/index.json      [{id, tags, caption}]
  playdate/source/images/archive/credits.json    [{id, title, author, url, license}]  (every item)
  packages/sim/src/archive-data.ts               ARCHIVE_DATA (generated)
  tools/assets/archive/ids.json                  stable id assignment (title -> id)
  tools/assets/archive/preview/archive-<n>.png   contact sheets of the built archive (160x100, 1:1)
  tools/assets/archive/preview/fullsize-sample.png  a dozen 400x240 cutaways
"""
import os, sys, json, re, html
import numpy as np
from PIL import Image, ImageOps, ImageFilter, ImageDraw, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
from common import CACHE, IMAGES, ROOT, ensure_dir, atkinson, bayer, BAYER4, save_1bit  # noqa: E402
from queries import G  # noqa: E402

IMG = os.path.join(CACHE, "archive", "img")
OUT = os.path.join(IMAGES, "archive")
PREVIEW = os.path.join(HERE, "preview")
SIZES = [(400, 240), (160, 100), (96, 72), (48, 36)]
FULL_SHARE = 0.36
GROUPS = {g["key"]: g for g in G}


def load_json(p, d):
    return json.load(open(p)) if os.path.exists(p) else d


CANDS = load_json(os.path.join(CACHE, "archive", "candidates.json"), {})
OVR = load_json(os.path.join(HERE, "overrides.json"), {})


# ------------------------------------------------------------------ image processing

def open_gray(key):
    p = os.path.join(IMG, key + ".jpg")
    if not os.path.exists(p) or os.path.getsize(p) < 2000:
        return None
    try:
        im = Image.open(p)
        im.load()
    except Exception:
        return None
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, im)
    return im.convert("RGB").convert("L")


def autotrim(im):
    """Cut scan borders / mounts: edge rows & columns that are flat or extreme."""
    a = np.asarray(im, np.float32)
    h, w = a.shape
    m = int(min(h, w) * 0.02)
    a = a[m:h - m, m:w - m]

    def edge(lines):
        n = 0
        for ln in lines:
            if ln.std() < 12 or ln.mean() < 22 or ln.mean() > 238:
                n += 1
            else:
                break
        return n
    rows = [a[i] for i in range(a.shape[0])]
    cols = [a[:, j] for j in range(a.shape[1])]
    t = edge(rows[: len(rows) // 4]); b = edge(rows[::-1][: len(rows) // 4])
    l = edge(cols[: len(cols) // 4]); r = edge(cols[::-1][: len(cols) // 4])
    pad = 2
    box = (m + l + pad, m + t + pad, w - m - r - pad, h - m - b - pad)
    return im.crop(box)


def aspect_crop(im, ar, focus=(0.5, 0.45), zoom=1.0):
    w, h = im.size
    if w / h > ar:
        ch, cw = h, h * ar
    else:
        cw, ch = w, w / ar
    cw, ch = cw / zoom, ch / zoom
    cx = min(max(focus[0] * w, cw / 2), w - cw / 2)
    cy = min(max(focus[1] * h, ch / 2), h - ch / 2)
    return im.crop((int(cx - cw / 2), int(cy - ch / 2), int(cx + cw / 2), int(cy + ch / 2)))


def tone(im, o, small):
    im = ImageOps.autocontrast(im, cutoff=(1, 1))
    eq = ImageOps.equalize(im)
    im = Image.blend(im, eq, 0.3)
    c = o.get("contrast", 1.15 if small else 1.08)
    im = ImageEnhance.Contrast(im).enhance(c)
    # the reflective Playdate screen reads dark: lift the midtones
    g = o.get("gamma", 0.82)
    lut = [int(255 * ((i / 255) ** g)) for i in range(256)]
    return im.point(lut)


def process(src, size, o):
    w, h = size
    ar = w / h
    small = w <= 96
    c = aspect_crop(src, ar, tuple(o.get("focus", (0.5, 0.45))), o.get("zoom", 1.0) * (o.get("zoom_small", 1.0) if small else 1.0))
    c = c.resize((w, h), Image.LANCZOS, reducing_gap=3.0)
    c = c.filter(ImageFilter.UnsharpMask(radius=1.2 if small else 1.6, percent=90 if small else 70, threshold=2))
    c = tone(c, o, small)
    d = o.get("dither", "atkinson")
    if d == "bayer":
        return Image.fromarray(bayer(np.asarray(c, np.float32) / 255.0, BAYER4), "L")
    if d == "threshold":
        return c.point(lambda v: 255 if v >= o.get("t", 140) else 0)
    return atkinson(c)


def prepared(key):
    im = open_gray(key)
    if im is None:
        return None
    o = OVR.get(key, {})
    im = autotrim(im)
    if "crop" in o:
        x0, y0, x1, y1 = o["crop"]
        W, H = im.size
        im = im.crop((int(x0 * W), int(y0 * H), int(x1 * W), int(y1 * H)))
    return im


# ------------------------------------------------------------------ review sheets

def label_cell(im, text, w, h):
    cell = Image.new("L", (w, h + 12), 255)
    cell.paste(im, (0, 0))
    ImageDraw.Draw(cell).text((1, h + 1), text[:30], fill=0)
    return cell


REVIEW = os.path.join(CACHE, "archive", "review")


def review(groups):
    ensure_dir(REVIEW)
    for gk in groups:
        lst = CANDS.get(gk, [])
        cells = []
        for i, c in enumerate(lst):
            src = prepared(c["key"])
            if src is None:
                continue
            o = OVR.get(c["key"], {})
            gray = tone(aspect_crop(src, 160 / 100).resize((160, 100), Image.LANCZOS), o, False)
            dith = process(src, (160, 100), o)
            pair = Image.new("L", (322, 100), 128)
            pair.paste(gray, (0, 0)); pair.paste(dith, (162, 0))
            tag = "X " if o.get("drop") else ""
            cells.append(label_cell(pair, f"{tag}{i} {c['key']} {c['rights']}", 322, 100))
        if not cells:
            continue
        cols = 3
        rows = (len(cells) + cols - 1) // cols
        sheet = Image.new("L", (cols * 326, rows * 116), 200)
        for i, cl in enumerate(cells):
            sheet.paste(cl, ((i % cols) * 326, (i // cols) * 116))
        sheet.save(os.path.join(REVIEW, f"review-{gk}.png"))
        print("review", gk, len(cells))


# ------------------------------------------------------------------ build

def clean(s):
    return re.sub(r"\s+", " ", html.unescape(s or "")).strip()


def year_of(c):
    for s in (c.get("date", ""), c["title"], c.get("desc", "")):
        m = re.search(r"\b(1[5-9]\d\d|20[0-2]\d)\b", s or "")
        if m:
            return m.group(1)
    return ""


def credit_of(c):
    t = c["title"]
    blob = " ".join([t, c.get("credit", ""), c.get("artist", ""), c.get("desc", "")]).lower()
    if c.get("lccn") or "library of congress" in blob:
        coll = ("Bain News Service" if "bain" in blob else "Detroit Publishing Co." if "detroit publishing" in blob else
                "FSA/OWI" if ("farm security" in blob or "office of war information" in blob or "fsa" in blob) else
                "National Photo Co." if "national photo" in blob else "Harris & Ewing" if "harris & ewing" in blob or "harris &amp; ewing" in blob else
                "Prints & Photographs Division")
        return f"Library of Congress, {coll}"
    junk = re.compile(r"^(unknown|anonymous|file url|this file was contributed|not provided|see below|"
                      r"internet archive book images$)|iiif|catalog record", re.I)

    def tidy(x):
        x = re.sub(r"\b(Unknown (author|artist|photographer))( \2)+", r"\1", clean(x), flags=re.I)
        x = re.sub(r"\s*(Life time|Description|Born|Died)\b.*$", "", x).strip(" ,;.")
        return "" if junk.search(x) else x[:80]
    author = tidy(c.get("artist", ""))
    cred = tidy(c.get("credit", ""))
    if c["rights"] == "by":
        return author or cred or "Wikimedia Commons contributor"
    if author:
        return author
    if "internet archive" in blob:
        return "Internet Archive Book Images (via Wikimedia Commons)"
    return cred or "Unknown author (via Wikimedia Commons)"


def source_of(c):
    if c.get("lccn"):
        return f"https://www.loc.gov/pictures/item/{c['lccn']}/"
    return c["page"] or "https://commons.wikimedia.org/wiki/" + c["title"].replace(" ", "_")


def license_of(c):
    if c["rights"] == "pd":
        l = c["license"]
        if c.get("lccn"):
            return "Public domain (LoC: no known restrictions on publication)"
        if l.lower() in ("public domain", "pd"):
            return "Public domain"
        if "no restrictions" in l.lower():
            return "Public domain (no known restrictions)"
        return f"Public domain ({l})"
    return c["license"]


def select():
    ids = load_json(os.path.join(HERE, "ids.json"), {})
    used_ids = set(ids.values())
    pin = OVR.get("_pin", {})
    picked = []
    seen = set()
    # group reassignment
    by_group = {k: [] for k in GROUPS}
    allc = {c["key"]: (gk, c) for gk, lst in CANDS.items() for c in lst}
    keep = OVR.get("_keep", {})
    for gk, lst in CANDS.items():
        if gk in keep:
            # reviewed group: exactly the kept keys, in order (take is ignored)
            by_group[gk].extend(allc[k][1] for k in keep[gk] if k in allc)
            continue
        for k in pin.get(gk, []):
            if k in allc:
                by_group[gk].append(allc[k][1])
        for c in lst:
            o = OVR.get(c["key"], {})
            tgt = o.get("group", gk)
            if tgt in by_group:
                by_group[tgt].append(c)
    for gk, g in GROUPS.items():
        n = 0
        for c in by_group[gk]:
            if n >= g["take"] and gk not in keep:
                break
            o = OVR.get(c["key"], {})
            if o.get("drop") or c["key"] in seen:
                continue
            if not os.path.exists(os.path.join(IMG, c["key"] + ".jpg")):
                continue
            seen.add(c["key"])
            iid = ids.get(c["title"])
            if not iid:
                j = 1
                while f"{gk}-{j:02d}" in used_ids:
                    j += 1
                iid = f"{gk}-{j:02d}"
                ids[c["title"]] = iid
                used_ids.add(iid)
            picked.append((iid, gk, c))
            n += 1
    json.dump(ids, open(os.path.join(HERE, "ids.json"), "w"), indent=1, sort_keys=True)
    return picked


def build():
    picked = select()
    ensure_dir(OUT)
    keep = set()
    index, credits, data = [], [], []
    sheet_cells = []
    # full-screen (400x240) versions only for the best FULL_SHARE of each group (review order), to
    # keep the archive near its ~6 MB budget; everything gets 160/96/48.
    gcount, grank = {}, {}
    for iid, gk, c in picked:
        grank[iid] = gcount.get(gk, 0)
        gcount[gk] = grank[iid] + 1
    for iid, gk, c in picked:
        src = prepared(c["key"])
        if src is None:
            continue
        o = OVR.get(c["key"], {})
        full = o.get("full", grank[iid] < max(1, -(-gcount[gk] * FULL_SHARE // 1)))
        outs = {}
        for (w, h) in SIZES:
            if w == 400 and not full:
                continue
            img = process(src, (w, h), o)
            p = os.path.join(OUT, f"{iid}-{w}.png")
            save_1bit(img, p)
            keep.add(os.path.basename(p))
            outs[w] = img
        g = GROUPS[gk]
        tags = list(dict.fromkeys(g["tags"] + o.get("tags", [])))
        if c["rights"] in ("pd", "cc0"):
            tags.append("pd")
        y = year_of(c)
        cap = o.get("caption") or (g["caption"] + (f", {y}" if y and int(y) < 1990 else ""))
        item = {"id": iid, "tags": tags, "caption": cap, "credit": credit_of(c), "source": source_of(c), "license": license_of(c)}
        if full:
            item["full"] = True
        data.append(item)
        index.append({"id": iid, "tags": tags, "caption": cap, "sizes": [w for w, _ in SIZES if w != 400 or full]})
        credits.append({"id": iid, "title": clean(c["title"]).removeprefix("File:"), "author": credit_of(c),
                        "url": source_of(c), "file": c["page"], "license": license_of(c),
                        "licenseUrl": c.get("licenseUrl", "") if c["rights"] != "pd" else ""})
        sheet_cells.append((outs[160], iid))
    # remove stale outputs
    for f in os.listdir(OUT):
        if f.endswith(".png") and f not in keep:
            os.remove(os.path.join(OUT, f))
    data.sort(key=lambda d: d["id"]); index.sort(key=lambda d: d["id"]); credits.sort(key=lambda d: d["id"])
    json.dump(index, open(os.path.join(OUT, "index.json"), "w"), indent=0)
    json.dump(credits, open(os.path.join(OUT, "credits.json"), "w"), indent=0)
    ts = os.path.join(ROOT, "packages", "sim", "src", "archive-data.ts")
    with open(ts, "w") as fh:
        fh.write("// GENERATED by tools/assets/archive/build.py — do not edit by hand.\n")
        fh.write("// Public-domain / CC0 / CC-BY photo & illustration archive. See archive.ts and docs/CREDITS.md.\n\n")
        fh.write('import type { ArchiveItem } from "./archive.ts";\n\n')
        fh.write("export const ARCHIVE_DATA: ArchiveItem[] = [\n")
        for d in data:
            fh.write("  " + json.dumps(d, ensure_ascii=False) + ",\n")
        fh.write("];\n")
    # final contact sheets (160x100 dithered, 1:1) split by ~60
    sheet_cells.sort(key=lambda t: t[1])
    for f in os.listdir(PREVIEW):
        if f.startswith("archive-"):
            os.remove(os.path.join(PREVIEW, f))
    per = 60
    for s in range(0, len(sheet_cells), per):
        part = sheet_cells[s:s + per]
        cols = 6
        rows = (len(part) + cols - 1) // cols
        sheet = Image.new("L", (cols * 164, rows * 114), 160)
        for i, (im, lab) in enumerate(part):
            sheet.paste(label_cell(im, lab, 160, 100), ((i % cols) * 164, (i // cols) * 114))
        sheet.save(os.path.join(PREVIEW, f"archive-{s // per + 1}.png"))
    # one full-size sample sheet
    fulls = [t for t in picked if os.path.exists(os.path.join(OUT, f"{t[0]}-400.png"))]
    big = fulls[:: max(1, len(fulls) // 12)][:12]
    bs = Image.new("L", (3 * 404, 4 * 244), 160)
    for i, (iid, gk, c) in enumerate(big):
        p = os.path.join(OUT, f"{iid}-400.png")
        if os.path.exists(p):
            bs.paste(Image.open(p).convert("L"), ((i % 3) * 404, (i // 3) * 244))
    bs.save(os.path.join(PREVIEW, "fullsize-sample.png"))
    write_credits(data, credits)
    total = sum(os.path.getsize(os.path.join(OUT, f)) for f in os.listdir(OUT))
    by = {}
    for d in data:
        by[d["id"].rsplit("-", 1)[0]] = by.get(d["id"].rsplit("-", 1)[0], 0) + 1
    print(f"{len(data)} items, {total / 1e6:.2f} MB in {OUT}")
    short = [f"{k}:{n}/{GROUPS[k]['take']}" for k, n in by.items() if n < GROUPS[k]["take"]]
    missing = [k for k in GROUPS if k not in by]
    print("short:", " ".join(short))
    print("missing:", " ".join(missing))


def write_credits(data, credits):
    """Append (or refresh) our own section at the end of docs/CREDITS.md; other sections untouched."""
    p = os.path.join(ROOT, "docs", "CREDITS.md")
    doc = open(p).read() if os.path.exists(p) else "# Credits\n"
    start, end = "<!-- archive:start (generated by tools/assets/archive/build.py) -->", "<!-- archive:end -->"
    n_pd = sum(1 for d in data if not d["license"].upper().startswith("CC BY"))
    by = [c for c in credits if c["license"].upper().startswith("CC BY")]
    esc = lambda s: str(s).replace("|", "\\|").replace("\n", " ")
    lines = [start, "## Archive (news, incident and world-event pictures)", "",
             f"`playdate/source/images/archive/` holds {len(data)} pictures (each at 160x100, 96x72 and 48x36; "
             f"{sum(1 for d in data if d.get('full'))} also at 400x240), "
             "cropped, resized and dithered to 1-bit from public-domain photographs, engravings, natural-history plates, "
             "period advertisements and cartoons, plus a few CC0 and CC-BY images where nothing public-domain fit. "
             f"{n_pd} are public domain / CC0; {len(by)} are CC-BY (attribution below).",
             "", "Main sources: Library of Congress Prints & Photographs Division (Bain News Service, Detroit Publishing Co., "
             "National Photo Co., Harris & Ewing, FSA/OWI; \"no known restrictions on publication\"), and public-domain "
             "scans hosted on Wikimedia Commons (used as the search index and download mirror; LoC items are credited to "
             "their LoC item page). The people shown are real, mostly anonymous, people of their time; DEADBALL uses the "
             "pictures as generic illustration, and nothing in the game is about them. Famous people are filtered out.",
             "", "Machine-readable: `playdate/source/images/archive/credits.json` (`{id, title, author, url, license}`; the "
             "in-game Credits page reads it) and `packages/sim/src/archive-data.ts` (`credit`, `source`, `license`).",
             ""]
    if by or any(c["license"].startswith("CC0") for c in credits):
        lines += ["### CC-BY and CC0 items (attribution)", "", "| id | title | author | source | license |", "|---|---|---|---|---|"]
        for c in credits:
            if c["license"].upper().startswith("CC"):
                lines.append(f"| {c['id']} | {esc(c['title'][:90])} | {esc(c['author'][:60])} | {c['url']} | {c['license']} ({c.get('licenseUrl', '')}) |")
        lines += ["", "Images were cropped, resized and dithered to 1-bit for the game (changes made).", ""]
    lines += ["### Public-domain items", "", "| id | title | credit | source | rights |", "|---|---|---|---|---|"]
    for c in credits:
        if c["license"].upper().startswith("CC"):
            continue
        lic = c["license"] + (f" ({c['licenseUrl']})" if c.get("licenseUrl") else "")
        lines.append(f"| {c['id']} | {esc(c['title'][:90])} | {esc(c['author'][:60])} | {c['url']} | {esc(lic)} |")
    lines.append(end)
    block = "\n".join(lines) + "\n"
    if start in doc and end in doc:
        doc = doc[:doc.index(start)] + block + doc[doc.index(end) + len(end) + 1:]
    else:
        doc = doc.rstrip("\n") + "\n\n" + block
    open(p, "w").write(doc)


def keep_cmd(group, idxs):
    """build.py keep <group> 0,3,5  -> overrides.json _keep[group] = keys of those review indexes."""
    lst = CANDS[group]
    o = load_json(os.path.join(HERE, "overrides.json"), {})
    o.setdefault("_keep", {})[group] = [lst[int(i)]["key"] for i in idxs.split(",") if i.strip()]
    json.dump(o, open(os.path.join(HERE, "overrides.json"), "w"), indent=1, sort_keys=True)
    print(group, len(o["_keep"][group]))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "keep":
        for arg in sys.argv[2:]:
            g_, ix = arg.split("=")
            keep_cmd(g_, ix)
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "review":
        review(sys.argv[2:] or list(CANDS))
    else:
        build()
