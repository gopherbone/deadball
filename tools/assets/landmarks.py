"""Landmark card illustrations for Pennant mode's Road Map interludes (400x160, 1-bit).

  python3 tools/assets/landmarks.py            # build all cards (downloads pinned photos once, cached)
  python3 tools/assets/landmarks.py --search   # search Commons for candidates + write review sheets
  python3 tools/assets/landmarks.py rushmore alamo   # rebuild only these keys

Real places come from public-domain photos (US government works, LoC no-known-restrictions, pre-1929)
or CC0, found on Wikimedia Commons; the license is re-checked from imageinfo extmetadata on download.
Fictional roadside oddities (and real places without a usable free photo) are drawn here with PIL.

Outputs: playdate/source/images/landmarks/<key>.png (400x160, opaque 1-bit)
         playdate/source/images/credits.json (entries under images/landmarks/ are rewritten)
         docs/CREDITS.md "## Landmarks" section
         tools/assets/preview/landmarks.png (contact sheet, 1:1)
Cache:   tools/assets/.cache/landmarks/{search,img}/
"""
import os, sys, re, json, math, time, hashlib, random, urllib.parse
import numpy as np
from PIL import Image, ImageDraw, ImageOps, ImageFilter, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "archive"))
import common  # noqa: E402
from common import CACHE, ensure_dir, atkinson, bayer, save_1bit  # noqa: E402
from fetch import http, strip_html, rights, API  # noqa: E402

W, H = 400, 160
LDIR = os.path.join(CACHE, "landmarks")
OUT = os.path.join(common.IMAGES, "landmarks")
PREVIEW = os.path.join(common.PREVIEW, "landmarks.png")

SEARCHES = {
    "rushmore": ["Mount Rushmore National Memorial NPS", "Mount Rushmore public domain photograph"],
    "chimney_rock": ["Chimney Rock Nebraska", "Chimney Rock National Historic Site"],
    "independence_rock": ["Independence Rock Wyoming", "Independence Rock Sweetwater"],
    "grand_canyon": ["Grand Canyon National Park NPS photo", "Grand Canyon from rim panorama"],
    "niagara": ["Niagara Falls Detroit Publishing", "Niagara Falls American Falls 1900", "Horseshoe Falls Niagara"],
    "gateway_arch": ["Gateway Arch St. Louis", "Gateway Arch National Park NPS", "Gateway Arch Highsmith",
                     "St. Louis skyline Gateway Arch Mississippi", "Jefferson National Expansion Memorial arch"],
    "hoover_dam": ["Hoover Dam Bureau of Reclamation", "Boulder Dam aerial"],
    "old_faithful": ["Old Faithful geyser eruption", "Old Faithful Yellowstone NPS"],
    "liberty_bell": ["Liberty Bell Philadelphia", "Liberty Bell Independence National Historical Park"],
    "alamo": ["Alamo mission San Antonio facade", "Alamo San Antonio HABS", "The Alamo church San Antonio",
              "Alamo San Antonio Detroit Publishing", "Alamo Highsmith"],
    "devils_tower": ["Devils Tower Wyoming", "Devils Tower National Monument NPS"],
    "twine_ball": ["ball of twine Cawker City", "largest ball of twine Darwin Minnesota", "ball of twine"],
    "frying_pan": ["world's largest frying pan Long Beach Washington", "largest frying pan"],
    "eiffel_tower": ["Eiffel Tower Detroit Publishing", "Eiffel Tower photochrom", "Tour Eiffel 1900 photograph"],
    "stonehenge": ["Stonehenge photochrom", "Stonehenge Detroit Publishing", "Stonehenge 1900 photograph"],
    "sphinx": ["Great Sphinx Giza photochrom", "Sphinx Gizeh photograph 1890", "Pyramids of Giza photochrom",
               "Great Pyramid Giza 1900 photograph", "Pyramids Gizeh Detroit Publishing"],
    "pisa": ["Leaning Tower of Pisa photochrom", "Leaning Tower Pisa Detroit Publishing", "Torre di Pisa 1900"],
    "colosseum": ["Colosseum Rome photochrom", "Colosseum Rome Detroit Publishing", "Colosseo 1900 photograph"],
}

NPS = "Public domain (US National Park Service)"
HIGH = "Public domain (Carol M. Highsmith Archive, Library of Congress; no known restrictions)"
LOCPC = "Public domain (Photochrom Print Collection, Library of Congress; no known restrictions)"
# box: fractional (x0, y0, x1, y1) of the content that must be on the card; it is grown to 400:160 around its
# centre, reflect-padding past the photo edge if needed. trim: fractional inner area (drops scan borders) first.
# tone: autocontrast cutoff / gamma (>1 darker) / contrast / local-contrast % / sharpen %; mix: ordered-dither bias.
PHOTOS = {
    "rushmore": dict(
        file="File:Mount Rushmore National Memorial MORU2014.jpg", box=(0.14, 0.20, 0.86, 0.64),
        title="Mount Rushmore National Memorial", author="National Park Service Digital Image Archives", lic=NPS,
        tone=dict(gamma=1.0, contrast=1.1, local=40), mix=0.15),
    "chimney_rock": dict(
        file="File:Chimney Rock, Nebraska - NARA - 294354.jpg", box=(0.12, 0.11, 0.88, 0.80),
        title="Chimney Rock, Nebraska (1904)", author="US National Archives (NARA 294354)",
        lic="Public domain (US National Archives)", tone=dict(gamma=1.3, contrast=1.15, local=60)),
    "independence_rock": dict(
        file="File:Independence Rock, Wyoming. Noted landmark on the Oregon Trail, a granite dome rising out of the "
             "Sweetwater Plain... - NARA - 516895.jpg", box=(0.14, 0.40, 0.86, 0.70),
        title="Independence Rock, Wyoming (1870)", author="William Henry Jackson, US Geological Survey (NARA 516895)",
        lic="Public domain (US government work, 1870)", tone=dict(gamma=0.9, contrast=1.2, local=60)),
    "grand_canyon": dict(
        file="File:Grand Canyon National Park, North Rim, Vishnu Temple 0268 - Flickr - Grand Canyon NPS.jpg",
        box=(0.0, 0.12, 1.0, 0.88), title="Grand Canyon National Park, North Rim, Vishnu Temple",
        author="Grand Canyon National Park (NPS)", lic=NPS, tone=dict(gamma=0.8, contrast=1.5, local=90, blur=1.0)),
    "niagara": dict(
        file="File:Detroit Photographic Company (0536).jpg", trim=(0.0, 0.0, 0.99, 0.95), box=(0.0, 0.14, 1.0, 0.72),
        title="Niagara Falls from Steel Arch Bridge (c. 1900)", author="Detroit Photographic Company",
        lic="Public domain (published before 1929)", tone=dict(gamma=1.5, contrast=1.1, local=60)),
    "gateway_arch": dict(
        file="File:Gateway Arch, or Gateway to the West, the centerpiece of the Jefferson National Expansion Memorial, "
             "St. Louis, Missouri LCCN2011636061.tif", box=(0.06, 0.21, 0.94, 0.86),
        url="https://www.loc.gov/pictures/item/2011636061/",
        title="Gateway Arch, St. Louis, Missouri", author="Carol M. Highsmith", lic=HIGH,
        tone=dict(gamma=1.0, contrast=1.2, local=50)),
    "hoover_dam": dict(
        file="File:Hoover Dam with Bypass from Reclamation.tif", box=(0.05, 0.40, 0.95, 0.88),
        title="Hoover Dam with Bypass Bridge", author="Alexander Stephens, US Bureau of Reclamation",
        lic="Public domain (US Bureau of Reclamation)", tone=dict(gamma=1.2, contrast=1.0, local=70)),
    "old_faithful": dict(
        file="File:Old Faithful Geyser (48941845288).jpg", box=(0.0, 0.12, 1.0, 0.97), pad="edge", padblur=40,
        title="Old Faithful Geyser", author="Jim Peaco, Yellowstone National Park (NPS)", lic=NPS,
        tone=dict(gamma=2.4, contrast=1.1, local=80, cutoff=0.2), mix=0.25),
    "liberty_bell": dict(
        file="File:Liberty Bell (1904).jpg", trim=(0.0, 0.0, 0.865, 0.925), box=(0.0, 0.0, 1.0, 1.0), pad="white",
        title="Liberty Bell (1904)", author="R. Newell & Son, Philadelphia",
        lic="Public domain (published 1904)", tone=dict(gamma=1.0, contrast=1.15, local=60)),
    "alamo": dict(
        file="File:Gezicht op de Alamo in San Antonio The Alamo at San Antonio, Texas (titel op object), "
             "RP-F-2001-7-996-63.jpg", trim=(0.07, 0.19, 0.80, 0.79), box=(0.18, 0.22, 0.98, 0.72),
        title="The Alamo at San Antonio, Texas (c. 1890s)", author="Anonymous photographer (Rijksmuseum RP-F-2001-7-996-63)",
        lic="CC0 1.0 (public domain)", tone=dict(gamma=1.2, contrast=1.15, local=60)),
    "devils_tower": dict(
        file="File:Historic View of Devils Tower and The Entrance Station (cf4fdd95-1dd8-b71b-0b47-4b145cdb22eb).jpg",
        trim=(0.045, 0.07, 0.955, 0.92), box=(0.0, 0.18, 1.0, 0.75),
        title="Historic view of Devils Tower and the entrance station", author="National Park Service", lic=NPS,
        tone=dict(gamma=1.1, contrast=1.15, local=60)),
    "twine_ball": dict(
        file="File:TwineBallCawkerKs.jpg", box=(0.04, 0.13, 0.98, 0.88),
        title="Ball of Twine, Cawker City, Kansas", author="TigerPaw2154 (English Wikipedia)",
        lic="Public domain (released by the author)", tone=dict(gamma=0.85, contrast=1.1, local=50), mix=0.2, pad="edge"),
    "eiffel_tower": dict(
        file="File:Eiffel Tower, full-view looking toward the Trocadero, Exposition Universal, 1900, Paris, France.jpg",
        box=(0.0, 0.06, 1.0, 0.84), pad="edge",
        title="Eiffel Tower, full view looking toward the Trocadero, Exposition Universelle, 1900",
        author="Unknown photographer", lic="Public domain (published c. 1900)",
        tone=dict(gamma=1.1, contrast=1.2, local=60)),
    "pisa": dict(
        file="File:The Leaning Tower, Pisa, Italy LOC 4755214836.jpg", trim=(0.025, 0.02, 0.965, 0.9),
        box=(0.0, 0.0, 1.0, 0.95), pad="edge", url="https://www.flickr.com/photos/library_of_congress/4755214836",
        title="The Leaning Tower, Pisa, Italy (c. 1890-1900)", author="Detroit Publishing Co. (Library of Congress)",
        lic=LOCPC, tone=dict(gamma=1.1, contrast=1.2, local=60)),
    "stonehenge": dict(
        file="File:Stonehenge, near Salisbury, England-LCCN2002708089.tif", trim=(0.035, 0.0, 0.975, 1.0),
        box=(0.0, 0.26, 1.0, 0.80), url="https://www.loc.gov/pictures/item/2002708089/",
        title="Stonehenge, near Salisbury, England (c. 1890-1900)", author="Photochrom Print Collection (Library of Congress)",
        lic=LOCPC, tone=dict(gamma=1.0, contrast=1.2, local=60)),
    "sphinx": dict(
        file="File:Bild från familjen von Hallwyls resa genom Egypten och Sudan, 5 november 1900 – 29 mars 1901 - "
             "Hallwylska museet - 91717.tif", trim=(0.115, 0.03, 0.865, 0.9), box=(0.0, 0.10, 1.0, 0.66),
        title="Pyramide de Ghiseh: the Great Sphinx and the Great Pyramid (1900-1901)",
        author="von Hallwyl family travel album (Hallwylska museet 91717)", lic="Public domain (photograph 1900-1901)",
        tone=dict(gamma=1.2, contrast=1.2, local=70)),
    "colosseum": dict(
        file="File:Exterior of the Coliseum, Rome, Italy-LCCN2001700941.jpg", trim=(0.12, 0.11, 0.92, 0.84),
        box=(0.0, 0.13, 1.0, 0.75), url="https://www.loc.gov/pictures/item/2001700941/",
        title="Exterior of the Coliseum, Rome, Italy (c. 1890-1900)", author="Photochrom Print Collection (Library of Congress)",
        lic=LOCPC, tone=dict(gamma=1.1, contrast=1.2, local=60)),
}

TITLES = {
    "rushmore": "Mount Rushmore", "chimney_rock": "Chimney Rock", "independence_rock": "Independence Rock",
    "grand_canyon": "Grand Canyon", "niagara": "Niagara Falls", "gateway_arch": "Gateway Arch",
    "hoover_dam": "Hoover Dam", "old_faithful": "Old Faithful", "liberty_bell": "Liberty Bell",
    "alamo": "The Alamo", "devils_tower": "Devils Tower", "twine_ball": "Ball of Twine",
    "frying_pan": "World's Largest Frying Pan", "eiffel_tower": "Eiffel Tower", "pisa": "Leaning Tower of Pisa",
    "stonehenge": "Stonehenge", "sphinx": "Great Sphinx of Giza", "colosseum": "Colosseum",
}
ORDER = list(TITLES)


# ------------------------------------------------------------------ commons

def _slug(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")[:80]


def _meta(ii):
    m = ii.get("extmetadata") or {}
    return {k: strip_html(v.get("value", "")) if isinstance(v, dict) else "" for k, v in m.items()}


def _query(params, path):
    if os.path.exists(path):
        return json.load(open(path))
    base = {"action": "query", "format": "json", "prop": "imageinfo", "iiprop": "url|extmetadata|size|mime",
            "iiurlwidth": 1280,
            "iiextmetadatafilter": "LicenseShortName|LicenseUrl|UsageTerms|Artist|Credit|DateTimeOriginal|ImageDescription|ObjectName"}
    base.update(params)
    d = http(API + "?" + urllib.parse.urlencode(base))
    time.sleep(1.0)
    if d is None:
        return []
    d = json.loads(d)
    out = []
    for p in (d.get("query") or {}).get("pages", {}).values():
        ii = (p.get("imageinfo") or [{}])[0]
        out.append({"title": p["title"], "index": p.get("index", 99), "mime": ii.get("mime", ""),
                    "w": ii.get("width", 0), "h": ii.get("height", 0), "thumb": ii.get("thumburl") or ii.get("url"),
                    "page": ii.get("descriptionurl", ""), "meta": _meta(ii)})
    out.sort(key=lambda e: e["index"])
    ensure_dir(os.path.dirname(path))
    json.dump(out, open(path, "w"), indent=0)
    return out


def search(q):
    return _query({"generator": "search", "gsrnamespace": 6, "gsrlimit": 40, "gsrsearch": q + " filetype:bitmap"},
                  os.path.join(LDIR, "search", _slug(q) + ".json"))


def info(title):
    r = _query({"titles": title}, os.path.join(LDIR, "info", hashlib.sha1(title.encode()).hexdigest()[:12] + ".json"))
    return r[0] if r else None


def img_path(title):
    return os.path.join(LDIR, "img", hashlib.sha1(title.encode()).hexdigest()[:12] + ".jpg")


def download(e):
    p = img_path(e["title"])
    if not os.path.exists(p):
        ensure_dir(os.path.dirname(p))
        http(e["thumb"], p)
        time.sleep(0.5)
    return p if os.path.exists(p) else None


def run_search(only=None):
    rev = ensure_dir(os.path.join(LDIR, "review"))
    for key, qs in SEARCHES.items():
        if only and key not in only:
            continue
        seen, items, lst = set(), [], []
        for q in qs:
            for e in search(q):
                if e["title"] in seen or not e["mime"].startswith("image/") or "svg" in e["mime"] or "gif" in e["mime"]:
                    continue
                seen.add(e["title"])
                cls, lic = rights({"LicenseShortName": {"value": e["meta"].get("LicenseShortName", "")}})
                if cls not in ("pd", "cc0", "by"):
                    continue
                lst.append((cls, e, lic))
        lst.sort(key=lambda t: {"pd": 0, "cc0": 1, "by": 2}[t[0]])
        lines = []
        for i, (cls, e, lic) in enumerate(lst[:40]):
            p = download(e)
            lines.append(f"{i:2d} {cls:3s} {e['w']}x{e['h']} {e['title']} | {lic} | {e['meta'].get('Artist', '')[:60]}"
                         f" | {e['meta'].get('DateTimeOriginal', '')[:20]}")
            if p:
                try:
                    im = Image.open(p).convert("L")
                    im.thumbnail((200, 130))
                    items.append((im, f"{i} {cls}"))
                except Exception:
                    pass
        open(os.path.join(rev, key + ".txt"), "w").write("\n".join(lines) + "\n")
        common.contact_sheet(items, os.path.join(rev, key + ".png"), cols=6, cell=(200, 130))
        print(f"{key:18s} {len(lst)} candidates"); sys.stdout.flush()


# ------------------------------------------------------------------ photos

def photo_entry(key):
    """Resolve the pinned Commons file (cached imageinfo), re-check the license, download the 1280px thumb."""
    spec = PHOTOS[key]
    e = info(spec["file"])
    if not e or not e.get("thumb"):
        raise SystemExit(f"{key}: Commons file not found: {spec['file']}")
    cls, lic = rights({"LicenseShortName": {"value": e["meta"].get("LicenseShortName", "")}})
    if cls not in ("pd", "cc0"):
        raise SystemExit(f"{key}: license not public domain / CC0: {lic!r}")
    p = download(e)
    if not p:
        raise SystemExit(f"{key}: download failed")
    return e, p


def crop_card(im, box, trim=None, pad="symmetric", padblur=120):
    """Grow `box` to the card aspect around its centre; reflect-pad where it leaves the photo."""
    if trim:
        w, h = im.size
        im = im.crop((int(trim[0] * w), int(trim[1] * h), int(trim[2] * w), int(trim[3] * h)))
    w, h = im.size
    x0, y0, x1, y1 = box[0] * w, box[1] * h, box[2] * w, box[3] * h
    cx, cy, bw, bh = (x0 + x1) / 2, (y0 + y1) / 2, x1 - x0, y1 - y0
    if bw / bh < W / H:
        bw = bh * W / H
    else:
        bh = bw * H / W
    X0, Y0 = int(round(cx - bw / 2)), int(round(cy - bh / 2))
    X1, Y1 = X0 + int(round(bw)), Y0 + int(round(bh))
    a = np.asarray(im)
    pl, pt, pr, pb = max(0, -X0), max(0, -Y0), max(0, X1 - w), max(0, Y1 - h)
    if pl or pt or pr or pb:
        if pad == "white":
            a = np.pad(a, ((pt, pb), (pl, pr)), mode="constant", constant_values=255)
        else:
            a = np.pad(a, ((pt, pb), (pl, pr)), mode=pad)
            if pad == "edge":  # soften the replicated streaks into smooth bands
                blur = np.asarray(Image.fromarray(a).filter(ImageFilter.GaussianBlur(max(3, a.shape[1] // padblur))))
                m = np.ones(a.shape, bool)
                m[pt:pt + h, pl:pl + w] = False
                a = np.where(m, blur, a).astype(np.uint8)
        X0, X1, Y0, Y1 = X0 + pl, X1 + pl, Y0 + pt, Y1 + pt
    return Image.fromarray(a[Y0:Y1, X0:X1]).resize((W, H), Image.LANCZOS)


def tone(im, cutoff=1, gamma=1.0, contrast=1.1, local=50, sharpen=100, blur=0.0):
    if blur:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    im = ImageOps.autocontrast(im, cutoff=cutoff)
    if local:
        im = im.filter(ImageFilter.UnsharpMask(radius=12, percent=local, threshold=0))
    if gamma != 1.0:
        im = im.point(lambda v: int(255 * ((v / 255) ** gamma)))
    im = ImageEnhance.Contrast(im).enhance(contrast)
    return im.filter(ImageFilter.UnsharpMask(radius=1.0, percent=sharpen, threshold=2))


def dither(im, mix=0.0):
    if mix:
        a = np.asarray(im, np.float32) / 255.0
        thr = np.tile(common.BAYER8, (H // 8 + 1, W // 8 + 1))[:H, :W]
        im = Image.fromarray((np.clip(a + (thr - 0.5) * mix, 0, 1) * 255).astype(np.uint8), "L")
    return atkinson(im)


def build_photo(key):
    spec = PHOTOS[key]
    e, p = photo_entry(key)
    im = Image.open(p).convert("L")
    card = crop_card(im, spec["box"], spec.get("trim"), spec.get("pad", "symmetric"), spec.get("padblur", 120))
    card = dither(tone(card, **spec.get("tone", {})), spec.get("mix", 0.0))
    credit = {"path": f"images/landmarks/{key}", "title": spec["title"], "author": spec["author"],
              "url": spec.get("url") or e["page"], "license": spec["lic"]}
    return card, credit


# ------------------------------------------------------------------ drawing kit (original illustrations)

S = 2  # supersample


class Scene:
    """Painter's-algorithm scene: every shape is a mask with a flat grey `fill` (ordered-dithered at the end)
    and a black outline. Later shapes cover earlier ink. Coordinates are card pixels (400x160)."""

    def __init__(self):
        self.tone = Image.new("L", (W * S, H * S), 255)
        self.ink = Image.new("L", (W * S, H * S), 0)      # 255 = forced black
        self.wink = Image.new("L", (W * S, H * S), 0)     # 255 = forced white
        self.text = []

    @staticmethod
    def _xy(pts):
        return [(x * S, y * S) for x, y in pts]

    def mask(self):
        return Image.new("L", (W * S, H * S), 0)

    def shape(self, m, fill=None, outline=1.0):
        """m: L mask at S scale. fill: 0..255 grey or None (keep). outline: card-pixel width (0 = none)."""
        if fill is not None:
            self.tone.paste(fill, (0, 0), m)
            self.ink.paste(0, (0, 0), m)
            self.wink.paste(0, (0, 0), m)
        if outline:
            k = int(round(outline * S)) * 2 + 1
            edge = ImageChops_sub(m.filter(ImageFilter.MaxFilter(k)), m)
            self.ink.paste(255, (0, 0), edge)
            self.wink.paste(0, (0, 0), edge)

    def poly(self, pts, fill=None, outline=1.0):
        m = self.mask()
        ImageDraw.Draw(m).polygon(self._xy(pts), fill=255)
        self.shape(m, fill, outline)
        return m

    def ellipse(self, box, fill=None, outline=1.0):
        m = self.mask()
        ImageDraw.Draw(m).ellipse([v * S for v in box], fill=255)
        self.shape(m, fill, outline)
        return m

    def rect(self, box, fill=None, outline=1.0):
        return self.poly([(box[0], box[1]), (box[2], box[1]), (box[2], box[3]), (box[0], box[3])], fill, outline)

    def blob(self, ellipses, fill=255, outline=1.0):
        m = self.mask()
        d = ImageDraw.Draw(m)
        for b in ellipses:
            d.ellipse([v * S for v in b], fill=255)
        self.shape(m, fill, outline)
        return m

    def line(self, pts, w=1.0, white=False):
        layer = self.wink if white else self.ink
        other = self.ink if white else self.wink
        m = self.mask()
        ImageDraw.Draw(m).line(self._xy(pts), fill=255, width=max(1, int(round(w * S))), joint="curve")
        layer.paste(255, (0, 0), m)
        other.paste(0, (0, 0), m)

    def dots(self, pts, r=0.6, white=False):
        layer = self.wink if white else self.ink
        d = ImageDraw.Draw(layer)
        for x, y in pts:
            d.ellipse([(x - r) * S, (y - r) * S, (x + r) * S, (y + r) * S], fill=255)

    def sky(self, horizon, top=150, bottom=235):
        a = np.asarray(self.tone).copy()
        hz = int(horizon * S)
        g = np.linspace(top, bottom, hz)[:, None]
        a[:hz, :] = g.astype(np.uint8)
        self.tone = Image.fromarray(a)

    def label(self, xy, s, font="ui", color=0, center=False):
        self.text.append((xy, s, font, color, center))

    def render(self):
        tone = self.tone.resize((W, H), Image.BOX)
        out = Image.fromarray(bayer(np.asarray(tone, np.float32) / 255.0), "L")
        ink = self.ink.resize((W, H), Image.BOX)
        wink = self.wink.resize((W, H), Image.BOX)
        a = np.asarray(out).copy()
        a[np.asarray(wink) >= 100] = 255
        a[np.asarray(ink) >= 100] = 0
        out = Image.fromarray(a, "L").copy()
        for xy, s, f, c, center in self.text:
            fo = common.font(f)
            x = xy[0] - fo.width(s) // 2 if center else xy[0]
            fo.draw(out, (x, xy[1]), s, color=c)
        return out


def ImageChops_sub(a, b):
    from PIL import ImageChops
    return ImageChops.subtract(a, b)


def sun(sc, cx, cy, r, rays=True):
    sc.ellipse((cx - r, cy - r, cx + r, cy + r), fill=255, outline=1)
    if rays:
        for k in range(12):
            t = k * math.pi / 6
            sc.line([(cx + math.cos(t) * (r + 3), cy + math.sin(t) * (r + 3)),
                     (cx + math.cos(t) * (r + 7), cy + math.sin(t) * (r + 7))], w=1)


def cloud(sc, x, y, s=1.0):
    sc.blob([(x, y, x + 26 * s, y + 12 * s), (x + 10 * s, y - 7 * s, x + 32 * s, y + 9 * s),
             (x + 22 * s, y - 2 * s, x + 46 * s, y + 12 * s)], fill=255, outline=1)


def hills(sc, horizon, fill=170, seed=1, amp=10, outline=1):
    r = random.Random(seed)
    pts = [(0, horizon)]
    x = 0
    while x <= W:
        pts.append((x, horizon - amp * (0.4 + 0.6 * abs(math.sin(x / 47.0 + seed))) - r.random() * 3))
        x += 10
    pts += [(W, horizon), (W, horizon + 2), (0, horizon + 2)]
    sc.poly(pts, fill=fill, outline=outline)


def ground(sc, horizon, fill=200):
    sc.rect((-2, horizon, W + 2, H + 2), fill=fill, outline=1)


def grass(sc, y0, y1, n=60, seed=3):
    r = random.Random(seed)
    for _ in range(n):
        x, y = r.uniform(0, W), r.uniform(y0, y1)
        h = 1.5 + (y - y0) / max(1, y1 - y0) * 3
        sc.line([(x, y), (x - 1, y - h)], w=0.6)
        sc.line([(x + 1.5, y), (x + 2.5, y - h)], w=0.6)


def pole_line(sc, horizon, xs, top=None):
    """Telephone poles receding to the right along the road."""
    prev = None
    for i, x in enumerate(xs):
        s = 1.0 - i * 0.22
        base = horizon + 26 * s
        h = 60 * s
        sc.line([(x, base), (x, base - h)], w=max(0.6, 1.4 * s))
        sc.line([(x - 6 * s, base - h + 4 * s), (x + 6 * s, base - h + 4 * s)], w=max(0.6, 1.0 * s))
        if prev:
            px, ptop = prev
            sc.line([(px - 5, ptop + 4), ((px + x) / 2, (ptop + base - h) / 2 + 8), (x - 6 * s, base - h + 4 * s)], w=0.5)
        prev = (x, base - h)


def car(sc, x, y, s=1.0, fill=90):
    """Little 90s sedan, side view, wheels at y."""
    sc.poly([(x, y - 4 * s), (x + 2 * s, y - 9 * s), (x + 9 * s, y - 10 * s), (x + 13 * s, y - 15 * s),
             (x + 25 * s, y - 15 * s), (x + 30 * s, y - 10 * s), (x + 36 * s, y - 9 * s), (x + 37 * s, y - 4 * s),
             (x + 36 * s, y - 2 * s), (x + 1 * s, y - 2 * s)], fill=fill, outline=1)
    sc.poly([(x + 14 * s, y - 13.5 * s), (x + 19 * s, y - 13.5 * s), (x + 19 * s, y - 10 * s),
             (x + 11 * s, y - 10 * s)], fill=235, outline=0.5)
    sc.poly([(x + 21 * s, y - 13.5 * s), (x + 25 * s, y - 13.5 * s), (x + 28 * s, y - 10 * s),
             (x + 21 * s, y - 10 * s)], fill=235, outline=0.5)
    for wx in (x + 8 * s, x + 29 * s):
        sc.ellipse((wx - 3.5 * s, y - 5 * s, wx + 3.5 * s, y + 2 * s), fill=0, outline=0)
        sc.ellipse((wx - 1.3 * s, y - 2.8 * s, wx + 1.3 * s, y - 0.2 * s), fill=255, outline=0)


def road(sc, horizon, vx, near_l, near_r, fill=95, dash=True):
    """Two-lane road from the bottom edge to a vanishing point (vx, horizon)."""
    sc.poly([(near_l, H + 2), (vx - 1.5, horizon), (vx + 1.5, horizon), (near_r, H + 2)], fill=fill, outline=1)
    if dash:
        mid = (near_l + near_r) / 2
        for k in range(14):
            t0, t1 = (k / 14) ** 1.8, ((k + 0.45) / 14) ** 1.8
            p0 = (vx + (mid - vx) * t0, horizon + (H - horizon) * t0)
            p1 = (vx + (mid - vx) * t1, horizon + (H - horizon) * t1)
            sc.line([p0, p1], w=0.5 + 1.5 * t1, white=True)


def spline(pts, n=12, closed=False):
    """Catmull-Rom through pts -> dense polyline."""
    P = list(pts)
    if closed:
        P = [P[-1]] + P + [P[0], P[1]]
    else:
        P = [P[0]] + P + [P[-1]]
    out = []
    for i in range(1, len(P) - 2):
        p0, p1, p2, p3 = P[i - 1], P[i], P[i + 1], P[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t2
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t3) for j in (0, 1)))
    out.append(P[-2])
    return out


def stroke_mask(sc, pts, width):
    m = sc.mask()
    d = ImageDraw.Draw(m)
    xy = sc._xy(pts)
    wpx = int(round(width * S))
    d.line(xy, fill=255, width=wpx, joint="curve")
    r = wpx / 2
    for x, y in (xy[0], xy[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)
    return m


def stroke(sc, pts, width, fill, outline=1.0):
    m = stroke_mask(sc, pts, width)
    sc.shape(m, fill, outline)
    return m


def hatch(sc, m, spacing=4, w=0.5, angle=0.0, white=False, jitter=0.0, seed=0):
    """Parallel lines clipped to mask m."""
    r = random.Random(seed)
    L = Image.new("L", m.size, 0)
    d = ImageDraw.Draw(L)
    ca, sa = math.cos(angle), math.sin(angle)
    diag = (W + H) * S
    k = -diag
    while k < diag:
        o = k + r.uniform(-jitter, jitter) * S
        cx, cy = W * S / 2 - sa * o, H * S / 2 + ca * o
        d.line([(cx - ca * diag, cy - sa * diag), (cx + ca * diag, cy + sa * diag)], fill=255,
               width=max(1, int(round(w * S))))
        k += spacing * S
    from PIL import ImageChops
    L = ImageChops.multiply(L, m)
    (sc.wink if white else sc.ink).paste(255, (0, 0), L)
    (sc.ink if white else sc.wink).paste(0, (0, 0), L)


def stipple(sc, box, n, seed=0, r=0.5, white=False):
    rr = random.Random(seed)
    sc.dots([(rr.uniform(box[0], box[2]), rr.uniform(box[1], box[3])) for _ in range(n)], r=r, white=white)


def rot(pts, cx, cy, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    return [(cx + (x - cx) * ca - (y - cy) * sa, cy + (x - cx) * sa + (y - cy) * ca) for x, y in pts]


# ------------------------------------------------------------------ the drawn cards

def draw_frying_pan():
    HZ = 104
    sc = Scene()
    sc.sky(HZ, 196, 255)
    cloud(sc, 10, 30, 1.3)
    cloud(sc, 270, 18, 1.1)
    cloud(sc, 150, 6, 0.8)
    # sea strip + dunes
    sc.rect((-2, HZ - 6, W + 2, HZ + 2), fill=140, outline=1)
    for x in range(0, W, 14):
        sc.line([(x, HZ - 3), (x + 6, HZ - 3)], w=0.6, white=True)
    sc.poly([(-4, H), (-4, HZ + 2), (60, HZ - 2), (140, HZ + 3), (260, HZ - 1), (404, HZ + 4), (404, H)],
            fill=220, outline=1)
    grass(sc, HZ + 4, H - 20, n=90, seed=8)
    # conifers, left and right
    for x, h in ((22, 70), (50, 56), (346, 64), (374, 80), (396, 58)):
        top = HZ + 6 - h
        for k in range(4):
            y0 = top + k * h * 0.2
            wd = h * (0.16 + k * 0.08)
            sc.poly([(x, y0), (x + wd, y0 + h * 0.32), (x - wd, y0 + h * 0.32)], fill=70, outline=1)
        sc.rect((x - 2, HZ + 4, x + 2, HZ + 12), fill=60, outline=0.6)
    # concrete pad + frame
    sc.poly([(120, 148), (290, 148), (300, 156), (110, 156)], fill=180, outline=1.2)
    sc.line([(206, 120), (244, 150)], w=2.2)
    sc.line([(194, 120), (156, 150)], w=2.2)
    # the pan, standing on its rim, handle up and a little to the right
    cx, cy, r = 200, 98, 48
    hb = rot([(cx - 7, cy - r + 2), (cx + 7, cy - r + 2), (cx + 5, cy - r - 30), (cx + 9, cy - r - 44),
              (cx + 2, cy - r - 52), (cx - 5, cy - r - 44), (cx - 4, cy - r - 30)], cx, cy, 14)
    sc.poly(hb, fill=45, outline=1.4)
    hole = rot([(cx + 2, cy - r - 44)], cx, cy, 14)[0]
    sc.ellipse((hole[0] - 2.5, hole[1] - 2.5, hole[0] + 2.5, hole[1] + 2.5), fill=235, outline=0.8)
    sc.ellipse((cx - r, cy - r, cx + r, cy + r), fill=30, outline=1.6)          # rim
    sc.ellipse((cx - r + 6, cy - r + 6, cx + r - 6, cy + r - 6), fill=75, outline=1)  # cooking surface
    # sheen: arcs of white on the iron
    for k, rr in enumerate((r - 12, r - 17)):
        arc = [(cx + rr * math.cos(t), cy + rr * math.sin(t)) for t in np.linspace(math.pi * 1.05, math.pi * 1.45, 12)]
        sc.line(arc, w=1.6 - k * 0.6, white=True)
    arc = [(cx + (r - 3) * math.cos(t), cy + (r - 3) * math.sin(t)) for t in np.linspace(-0.6, 0.5, 14)]
    sc.line(arc, w=0.8, white=True)
    sc.ellipse((cx - r * 0.55, 150, cx + r * 0.55, 156), fill=90, outline=0)
    # picnic table, for scale
    sc.rect((292, 132, 336, 135), fill=150, outline=1)
    for x0, x1 in ((296, 290), (332, 338)):
        sc.line([(x0, 135), (x1, 148)], w=1)
    sc.rect((284, 140, 344, 142), fill=150, outline=0.8)
    return sc.render()


DRAWN = {"frying_pan": draw_frying_pan}


# ------------------------------------------------------------------ outputs

def write_credits(credits):
    path = os.path.join(common.IMAGES, "credits.json")
    cur = json.load(open(path)) if os.path.exists(path) else []
    keep = [e for e in cur if not str(e.get("path", "")).startswith("images/landmarks/")]
    old = {e["path"]: e for e in cur if str(e.get("path", "")).startswith("images/landmarks/")}
    old.update({c["path"]: c for c in credits})
    for k in DRAWN:
        old.pop(f"images/landmarks/{k}", None)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(keep + [old[k] for k in sorted(old)], fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    return [old[k] for k in sorted(old)]


def write_credits_md(entries):
    path = os.path.join(common.ROOT, "docs", "CREDITS.md")
    txt = open(path, encoding="utf-8").read()
    rows = [f"- {e['path'].split('/')[-1]}.png: {e['title']} ({e['author']}) — {e['url']} — {e['license']}"
            for e in entries]
    drawn = ", ".join(f"`{k}`" for k in ORDER if k in DRAWN)
    sec = ("## Landmarks\n\nPennant-mode Road Map landmark cards (`playdate/source/images/landmarks/`, 400x160, 1-bit). "
           "Every card is a real place. They are made from public-domain photographs (US National Park Service, US Bureau "
           "of Reclamation, US National Archives, the Library of Congress Photochrom and Carol M. Highsmith collections, "
           "pre-1929 publications) and "
           "one CC0 museum scan, found via Wikimedia Commons; cropped, tone-adjusted and dithered to 1 bit (changes made). "
           f"Drawn for this project by `tools/assets/landmarks.py`: {drawn} (an original drawing of the Long Beach, WA "
           "attraction).\n\n" + "\n".join(rows) + "\n")
    pat = re.compile(r"## Landmarks\n.*?(?=\n## |\Z)", re.S)
    if pat.search(txt):
        txt = pat.sub(sec.rstrip("\n") + "\n", txt)
    else:
        txt = txt.rstrip("\n") + "\n\n" + sec
    open(path, "w", encoding="utf-8").write(txt)


def main(keys):
    ensure_dir(OUT)
    credits = []
    for key in keys:
        if key in PHOTOS:
            card, credit = build_photo(key)
            credits.append(credit)
        else:
            card = DRAWN[key]()
        assert card.size == (W, H)
        save_1bit(card, os.path.join(OUT, key + ".png"))
        print(f"{key:18s} {'photo' if key in PHOTOS else 'drawn':5s} {os.path.getsize(os.path.join(OUT, key + '.png'))}B")
    entries = write_credits(credits)
    write_credits_md(entries)
    items = [(Image.open(os.path.join(OUT, k + ".png")).convert("L"), k) for k in ORDER
             if os.path.exists(os.path.join(OUT, k + ".png"))]
    common.contact_sheet(items, PREVIEW, cols=2, cell=(W, H))
    print("preview", PREVIEW)


if __name__ == "__main__":
    if "--search" in sys.argv:
        run_search([a for a in sys.argv[1:] if not a.startswith("-")])
    else:
        sel = [a for a in sys.argv[1:] if not a.startswith("-")]
        bad = [k for k in sel if k not in ORDER]
        if bad:
            raise SystemExit(f"unknown keys: {bad}")
        main(sel or ORDER)
