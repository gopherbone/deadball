"""Crowd photos from the LoC Bain collection (downloaded via the Wikimedia Commons mirror).

  python3 tools/assets/crowd.py discover   # search Commons, download candidates, write a review sheet
  python3 tools/assets/crowd.py            # build from tools/assets/crowd_sources.json (fetches only missing curated photos)

Outputs (playdate/source/images/crowd/):
  bd-<n>.png        400x240 1-bit backdrops for BallCast crowd / incident shots
  tex-<style>-64x32.png, tex-<style>-128x64.png   horizontally seamless 1-bit crowd tiles
  crowd.json        manifest (source pk, URL, caption, banner clear rect)
Also: tools/assets/.cache/crowd/gray/<name>.png  grayscale tiles for the park renderers (parks.py samples them).
Deterministic: crop boxes + tuning live in tools/assets/crowd_sources.json (checked in).
"""
import os, sys, json, re, time
import numpy as np
from PIL import Image, ImageOps, ImageFilter, ImageEnhance, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

HERE = os.path.dirname(os.path.abspath(__file__))
CDIR = os.path.join(common.CACHE, "crowd")
SOURCES = os.path.join(HERE, "crowd_sources.json")
OUT = os.path.join(common.IMAGES, "crowd")
GRAY = os.path.join(CDIR, "gray")

QUERIES = ["crowd", "bleachers", "fans", "Polo Grounds", "World Series", "scoreboard", "grandstand",
           "rooftops", "baseball crowd", "spectators", "Ebbets", "Fenway", "Hilltop", "stands", "cheering", "audience"]
KNOWN = ["ggbain.02266", "ggbain.02322", "ggbain.14444", "ggbain.20092", "cph.3b43945", "cph.3a24381",
         "cph.3a29625", "ppmsca.18452"]
LCCN_RE = re.compile(r"LCCN\s?(\d{8,10})", re.I)


# ------------------------------------------------------------------ discovery (network; cached)

def discover(width=1024):
    import faces_commons as fc
    common.ensure_dir(CDIR)
    cand_path = os.path.join(CDIR, "candidates.json")
    cands = json.load(open(cand_path)) if os.path.exists(cand_path) else {}
    titles = set()
    for q in QUERIES:
        for t in fc.search(q, limit=500):
            titles.add(t)
        print("search", q, len(titles)); sys.stdout.flush()
    for lid in KNOWN:
        d = fc.api({"action": "query", "list": "search", "srnamespace": 6, "srlimit": 10, "srsearch": f'insource:"{lid}"'})
        for r in (d.get("query") or {}).get("search") or []:
            if r["title"].lower().endswith((".jpg", ".jpeg")):
                titles.add(r["title"]); cands.setdefault(r["title"], {})["locid"] = lid
                break
    # keep jpgs whose caption suggests a crowd
    kw = re.compile(r"crowd|bleacher|fans|grandstand|stands|spectator|rooftop|scoreboard|world series|polo grounds|"
                    r"opening day|audience|cheer|throng|game", re.I)
    for t in sorted(titles):
        if not t.lower().endswith((".jpg", ".jpeg")) or "(cropped)" in t:
            continue
        if not kw.search(t) and t not in cands:
            continue
        e = cands.setdefault(t, {})
        m = LCCN_RE.search(t)
        e["pk"] = m.group(1) if m else e.get("pk", "")
        e["caption"] = re.sub(r"^File:|\s*LCCN\s?\d+\.jpe?g$|\.jpe?g$", "", t).strip()
    # resolve LoC links for items without an LCCN in the title (cph/ppmsca)
    for t, e in cands.items():
        if not e.get("pk"):
            d = fc.api({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main", "titles": t})
            for p in ((d.get("query") or {}).get("pages") or {}).values():
                txt = (p.get("revisions") or [{}])[0].get("slots", {}).get("main", {}).get("*", "")
                m = re.search(r"loc\.gov/pictures/item/(\d+)", txt) or LCCN_RE.search(txt)
                if m:
                    e["pk"] = m.group(1)
    keys = [t for t in cands if not os.path.exists(_img(cands[t], t))]
    urls = fc.thumb_urls(keys, width) if keys else {}
    for t in keys:
        if t in urls:
            fc.download_url(urls[t], _img(cands[t], t))
            time.sleep(0.5)
    json.dump(cands, open(cand_path, "w"), indent=1)
    review_sheet(cands)
    print("candidates:", len(cands))
    return cands


def _key(e, t):
    return e.get("pk") or e.get("locid") or re.sub(r"[^A-Za-z0-9]+", "_", t)[-40:]


def _img(e, t):
    return os.path.join(CDIR, _key(e, t) + ".jpg")


def review_sheet(cands):
    items = []
    for t, e in sorted(cands.items()):
        p = _img(e, t)
        if os.path.exists(p):
            im = Image.open(p).convert("L")
            im.thumbnail((200, 150))
            cell = Image.new("L", (200, 150), 255); cell.paste(im, (0, 0))
            items.append((cell, _key(e, t)))
    for i in range(0, len(items), 40):
        common.contact_sheet(items[i:i + 40], os.path.join(CDIR, f"review-{i // 40}.png"), cols=8, label_font="tiny")


# ------------------------------------------------------------------ processing

def load_src(src):
    p = os.path.join(CDIR, src["key"] + ".jpg")
    im = Image.open(p).convert("L")
    if src.get("crop"):
        w, h = im.size
        c = src["crop"]  # fractional (x0, y0, x1, y1)
        im = im.crop((int(c[0] * w), int(c[1] * h), int(c[2] * w), int(c[3] * h)))
    return im


def tone(im, contrast=1.35, gamma=1.0, sharpen=1.6, clahe=True):
    """Push away from flat mid-grey: local contrast (big-radius unsharp), autocontrast, gamma, sharpen."""
    im = ImageOps.autocontrast(im, cutoff=1)
    if clahe:
        im = im.filter(ImageFilter.UnsharpMask(radius=max(4, im.width // 40), percent=70, threshold=0))
    if gamma != 1.0:
        im = im.point(lambda v: int(255 * ((v / 255) ** gamma)))
    im = ImageEnhance.Contrast(im).enhance(contrast)
    im = im.filter(ImageFilter.UnsharpMask(radius=1.2, percent=int(sharpen * 100), threshold=2))
    return im


def dither_mix(im, mix=0.0):
    """Atkinson; with mix>0 blend in an ordered-dither bias for a steadier texture on big flat areas."""
    if mix:
        a = np.asarray(im, np.float32) / 255.0
        h, w = a.shape
        thr = np.tile(common.BAYER8, (h // 8 + 1, w // 8 + 1))[:h, :w]
        a = np.clip(a + (thr - 0.5) * mix, 0, 1)
        im = Image.fromarray((a * 255).astype(np.uint8), "L")
    return common.atkinson(im)


def seamless(gray, w, h):
    """Horizontally seamless tile: resize to (w + blend) width, cross-fade the overlap."""
    blend = max(4, w // 4)
    big = gray.resize((w + blend, h), Image.LANCZOS)
    a = np.asarray(big, np.float32)
    out = a[:, :w].copy()
    t = np.linspace(0, 1, blend)[None, :]
    # left edge cross-fades with the extra columns past the right edge
    out[:, :blend] = a[:, :blend] * t + a[:, w:w + blend] * (1 - t)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "L")


def fetch_sources(spec, width=1280):
    """Download only the curated photos (by LoC pk via the Commons mirror) if they aren't cached."""
    keys = sorted({e["key"] for e in spec["backdrops"] + spec["textures"]})
    todo = [k for k in keys if not os.path.exists(os.path.join(CDIR, k + ".jpg"))]
    if not todo:
        return
    import faces_commons as fc
    common.ensure_dir(CDIR)
    for k in todo:
        t = fc.lookup_pk(k)
        u = fc.thumb_urls([t], width).get(t) if t else None
        if u and fc.download_url(u, os.path.join(CDIR, k + ".jpg")):
            print("crowd: fetched", k)
        time.sleep(0.5)


def build(verbose=True):
    if not os.path.exists(SOURCES):
        print("crowd: no crowd_sources.json; run `crowd.py discover` and curate"); return None
    spec = json.load(open(SOURCES))
    try:
        fetch_sources(spec)
    except Exception as e:  # offline: build from whatever is cached
        print("crowd: fetch skipped:", e)
    common.ensure_dir(OUT); common.ensure_dir(GRAY)
    man = {"version": 1, "backdrops": [], "textures": [], "credit": "Library of Congress, Bain News Service collection (no known restrictions on publication)"}
    prev = []
    missing = []
    for i, bd in enumerate(spec["backdrops"]):
        if not os.path.exists(os.path.join(CDIR, bd["key"] + ".jpg")):
            missing.append(bd["key"]); continue
        im = load_src(bd)
        im = ImageOps.fit(im, (400, 240), Image.LANCZOS, centering=bd.get("focus", (0.5, 0.5)))
        im = tone(im, bd.get("contrast", 1.35), bd.get("gamma", 1.0), bd.get("sharpen", 1.6))
        if bd.get("banner"):
            x0, y0, x1, y1 = bd["banner"]
            # soften the clear rect toward white so an overlaid banner reads
            a = np.asarray(im, np.float32)
            a[y0:y1, x0:x1] = 255 - (255 - a[y0:y1, x0:x1]) * bd.get("banner_fade", 0.35)
            im = Image.fromarray(a.astype(np.uint8), "L")
        out = dither_mix(im, bd.get("mix", 0.0))
        name = f"bd-{i + 1}"
        common.save_1bit(out, os.path.join(OUT, name + ".png"))
        man["backdrops"].append({"name": name, "file": f"images/crowd/{name}", "kind": bd.get("kind", "crowd"),
                                 "pk": bd["pk"], "url": f"https://www.loc.gov/pictures/item/{bd['pk']}/",
                                 "caption": bd["caption"], "banner": bd.get("banner")})
        prev.append((out, name + " " + bd.get("kind", "")))
    texprev = []
    for tx in spec["textures"]:
        if not os.path.exists(os.path.join(CDIR, tx["key"] + ".jpg")):
            missing.append(tx["key"]); continue
        src = load_src(tx)
        src = tone(src, tx.get("contrast", 1.3), tx.get("gamma", 1.0), 1.0, clahe=True)
        entry = {"style": tx["style"], "pk": tx["pk"], "url": f"https://www.loc.gov/pictures/item/{tx['pk']}/",
                 "caption": tx["caption"], "files": {}}
        big = ImageEnhance.Contrast(seamless(src, 512, 256)).enhance(1.1)
        big.save(os.path.join(GRAY, f"{tx['style']}-512x256.png"))   # for parks.py static renders
        for (w, h) in ((64, 32), (128, 64)):
            g = seamless(src, w, h)
            g = ImageEnhance.Contrast(g).enhance(1.15)
            g.save(os.path.join(GRAY, f"{tx['style']}-{w}x{h}.png"))
            # dither 3 tiles side by side and keep the middle one so error diffusion wraps seamlessly
            wide = Image.new("L", (w * 3, h)); [wide.paste(g, (k * w, 0)) for k in range(3)]
            d = dither_mix(wide, tx.get("mix", 0.25)).crop((w, 0, 2 * w, h))
            nm = f"tex-{tx['style']}-{w}x{h}"
            common.save_1bit(d, os.path.join(OUT, nm + ".png"))
            entry["files"][f"{w}x{h}"] = f"images/crowd/{nm}"
            if w == 128:
                tiled = Image.new("L", (128 * 3, 64)); [tiled.paste(d, (k * 128, 0)) for k in range(3)]
                texprev.append((tiled, nm + " x3"))
        man["textures"].append(entry)
    common.write_json(os.path.join(OUT, "crowd.json"), man)
    if missing and verbose:
        print("crowd: missing cached photos (run `crowd.py discover`):", missing)
    if prev:
        sheet_items = []
        for im, lab in prev:
            sheet_items.append((im, lab))
        common.contact_sheet(sheet_items, os.path.join(common.PREVIEW, "crowd.png"), cols=2)
        common.contact_sheet(texprev, os.path.join(common.PREVIEW, "crowd_tex.png"), cols=2)
    readme(man)
    credits(man)
    credits_json(man)
    if verbose:
        print(f"crowd: {len(man['backdrops'])} backdrops, {len(man['textures'])} texture styles")
    return man


def gray_texture(style, size="128x64"):
    """Grayscale seamless tile (float 0..1 array) for the park renderers, or None."""
    p = os.path.join(GRAY, f"{style}-{size}.png")
    if not os.path.exists(p):
        return None
    return np.asarray(Image.open(p).convert("L"), np.float32) / 255.0


def readme(man):
    lines = ["## Crowd photos (`images/crowd/`)", "",
             "Real crowd photographs (LoC Bain collection, via the Wikimedia Commons mirror), 1-bit for the reflective screen.",
             "Manifest: `images/crowd/crowd.json` = `{version, credit, backdrops:[{name, file, kind, pk, url, caption, banner}],",
             "textures:[{style, pk, url, caption, files:{\"64x32\": path, \"128x64\": path}}]}`.", "",
             "**Backdrops** (400x240 opaque, `gfx.image.new(file)`): full-screen BallCast crowd / incident shots.",
             "`banner` = `[x0, y0, x1, y1]` (exclusive) clear-ish rect lightened for an overlaid banner/caption, or null.", "",
             "| name | kind | banner | source |", "|---|---|---|---|"]
    for b in man["backdrops"]:
        lines.append(f"| `{b['name']}` | {b['kind']} | {b['banner']} | [{b['pk']}]({b['url']}) {b['caption'][:60]} |")
    lines += ["", "**Textures** (`tex-<style>-64x32`, `tex-<style>-128x64`): seamless horizontally (tile in x;",
              "vertical tiling is not seamless — stack rows with a 1 px dark step line or use one tile per stands band).",
              "Styles: " + ", ".join(f"`{t['style']}`" for t in man["textures"]) + ".",
              "The park pipeline uses them: parks-geo.json `crowd_<style>` textures and the crowd fill in the static",
              "park backgrounds (including the bleachers camera) come from these photos."]
    common.write_readme_part("37-crowd.md", "\n".join(lines))


def credits_json(man):
    """Merge our entries into playdate/source/images/credits.json (only paths under images/crowd/)."""
    path = os.path.join(common.IMAGES, "credits.json")
    cur = json.load(open(path)) if os.path.exists(path) else []
    cur = [e for e in cur if not str(e.get("path", "")).startswith("images/crowd/")]
    for b in man["backdrops"]:
        cur.append({"path": b["file"], "title": b["caption"], "author": "Bain News Service",
                    "url": b["url"], "license": "Public domain (LoC Bain, no known restrictions)"})
    for t in man["textures"]:
        for f in t["files"].values():
            cur.append({"path": f, "title": t["caption"], "author": "Bain News Service",
                        "url": t["url"], "license": "Public domain (LoC Bain, no known restrictions)"})
    common.write_json(path, cur)


def credits(man):
    """Rewrite only the '## Crowd photos' subsection of docs/CREDITS.md (append if missing)."""
    path = os.path.join(common.ROOT, "docs", "CREDITS.md")
    txt = open(path, encoding="utf-8").read() if os.path.exists(path) else "# Credits\n"
    seen, rows = set(), []
    for e in man["backdrops"] + man["textures"]:
        if e["pk"] in seen:
            continue
        seen.add(e["pk"])
        rows.append(f"- {e['caption']} — {e['url']}")
    sec = ("## Crowd photos\n\nBallCast crowd backdrops and stands textures (`playdate/source/images/crowd/`) are made from\n"
           "Library of Congress, Prints & Photographs Division, George Grantham Bain Collection photographs —\n"
           "\"no known restrictions on publication\". Downloaded via the Wikimedia Commons mirror; heavily cropped,\n"
           "tone-adjusted and dithered to 1 bit.\n\n" + "\n".join(rows) + "\n")
    pat = re.compile(r"## Crowd photos\n.*?(?=\n## |\Z)", re.S)
    if pat.search(txt):
        txt = pat.sub(sec.rstrip("\n") + "\n", txt)
    else:
        txt = txt.rstrip("\n") + "\n\n" + sec
    open(path, "w", encoding="utf-8").write(txt)


if __name__ == "__main__":
    if sys.argv[1:] == ["discover"]:
        discover()
    else:
        build()
