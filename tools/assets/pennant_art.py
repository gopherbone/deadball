"""Period photo art for Pennant '96 trade calls, the trade deadline and telegram / newspaper moments (1-bit).

  python3 -I tools/assets/pennant_art.py            # build everything (downloads pinned photos once, cached)
  python3 -I tools/assets/pennant_art.py --search   # search Commons for candidates + write review sheets
  python3 -I tools/assets/pennant_art.py phone_candlestick newsboy   # rebuild only these keys

Every image is a real public-domain (US government work, LoC "no known restrictions", published before 1931)
or CC0 photograph found on Wikimedia Commons; the license is re-checked from imageinfo extmetadata on download.
Sibling of landmarks.py, same crop / tone / dither pipeline.

Outputs: playdate/source/images/pennant/<key>.png      card art, 400x160, opaque 1-bit
         playdate/source/images/pennant/<key>-96.png   dialog thumbnail, 96x96
         playdate/source/images/pennant/<key>-48.png   small dialog thumbnail, 48x48
         playdate/source/images/credits.json (entries under images/pennant/ are rewritten)
         docs/CREDITS.md "## Pennant art" section
         tools/assets/preview/pennant_art.png (contact sheet, 1:1)
Cache:   tools/assets/.cache/pennant/{search,info,img,review}/   (downloaded files are untrusted data)
"""
import os, sys, re, json, time, hashlib, urllib.parse
import numpy as np
from PIL import Image, ImageOps, ImageFilter, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "archive"))
import common  # noqa: E402
from common import CACHE, ensure_dir, atkinson, save_1bit  # noqa: E402
from fetch import http, strip_html, rights, API  # noqa: E402

CW, CH = 400, 160
THUMBS = (96, 48)
PDIR = os.path.join(CACHE, "pennant")
OUT = os.path.join(common.IMAGES, "pennant")
PREVIEW = os.path.join(common.PREVIEW, "pennant_art.png")

SEARCHES = {
    "phone_candlestick": ["candlestick telephone", "candlestick telephone Harris Ewing", "telephone 1915 desk set"],
    "phone_wall": ["wall telephone crank", "magneto wall telephone", "wall telephone 1900"],
    "switchboard": ["switchboard operators Harris Ewing", "telephone switchboard operators 1910s",
                    "telephone exchange operators women"],
    "office_phone": ["man talking on telephone Harris Ewing", "telephoning National Photo Company",
                     "at desk with telephone 1920s", "man on telephone Bain"],
    "telegram": ["Western Union telegram 1920s", "telegram form Western Union", "telegram 1918"],
    "telegraph_key": ["telegraph key", "telegraph operator Harris Ewing", "telegraph operator 1900s"],
    "messenger_boy": ["Western Union messenger boy Hine", "messenger boy bicycle Hine", "telegraph messenger boy"],
    "handshake": ["shaking hands Harris Ewing", "shake hands National Photo Company", "handshake 1920s photograph"],
    "signing": ["signing contract Harris Ewing", "signing papers at desk National Photo Company",
                "signs contract baseball", "baseball player signing contract"],
    "magnates": ["baseball magnates", "baseball club owners meeting", "Ban Johnson Bain", "baseball owners Bain"],
    "station": ["railroad station platform Bain", "Union Station Washington Harris Ewing train shed",
                "railroad station 1910s passengers"],
    "luggage": ["baseball team leaving train Bain", "baseball players train station", "man with suitcase train 1920s",
                "baseball suitcase Bain"],
    "train": ["steam locomotive departing station", "train leaving station Bain", "locomotive Detroit Publishing"],
    "newsboy": ["newsboy Lewis Hine", "newsboys selling papers Hine", "newsie Hine"],
    "newspaper": ["reading newspaper Bain", "newspaper headline 1910s", "extra newspaper baseball"],
    "press": ["printing press newspaper Harris Ewing", "newspaper press room 1910s", "linotype operators"],
    "clock": ["clock face Harris Ewing", "station clock", "big clock 1920s photograph", "clock tower dial Bain",
              "alarm clock", "wall clock antique", "pocket watch dial", "clock dial Roman numerals", "stopwatch"],
    "calendar": ["calendar 1910 page", "wall calendar 1920s", "calendar 1896", "tear-off calendar",
                 "calendar July 1914", "desk calendar", "calendar 1912"],
}


LOC = "Public domain (Library of Congress, no known restrictions)"
HE = "Public domain (Harris & Ewing Collection, Library of Congress; no known restrictions)"
BAIN = "Public domain (Bain News Service, Library of Congress; no known restrictions)"
NCLC = "Public domain (National Child Labor Committee Collection, Library of Congress; no known restrictions)"
# file: pinned Commons file. trim: fractional inner area kept first (drops scan borders / captions).
# box: fractional (x0, y0, x1, y1) that must be on the 400x160 card (grown to the aspect around its centre).
# sq: same for the square 96/48 thumbnails. tone / ttone (thumb overrides): autocontrast cutoff, gamma (>1 darker),
# contrast, local-contrast %, sharpen %. mix: ordered-dither bias. pad: fill past the photo edge (edge/white/black).
PHOTOS = {
    # ---- the phone call
    "phone_candlestick": dict(
        year="2008 photo",
        file="File:Candlestick phone.JPG", box=(0.0, 0.0, 1.0, 0.72), sq=(0.0, 0.0, 1.0, 0.98), pad="white",
        title="Western Electric candlestick telephone", author="Nuberger13 (Wikimedia Commons)",
        lic="Public domain (released by the photographer)", tone=dict(gamma=1.0, contrast=1.15, local=40)),
    "phone_wall": dict(
        year="2014",
        file="File:Vintage crank telephone at the Buffalo Gap Historic Village in the unincorporated Taylor County, "
             "Texas, town of the same name, near Abilene LCCN2014631337.tif",
        box=(0.05, 0.22, 0.95, 0.52), sq=(0.08, 0.18, 0.66, 0.76), url="https://www.loc.gov/pictures/item/2014631337/",
        title="Vintage crank telephone, Buffalo Gap Historic Village, Texas", author="Carol M. Highsmith",
        lic="Public domain (Carol M. Highsmith Archive, Library of Congress; no known restrictions)",
        tone=dict(gamma=0.9, contrast=1.2, local=70)),
    "switchboard": dict(
        year="1937",
        file="File:First Capitol telephone operator still on job. Washington, D.C., July 30. When Miss Harriot Daley "
             "was appointed telephone operator at the United States Capitol in 1898 there were only 51 LCCN2016872097.jpg",
        trim=(0.03, 0.03, 0.98, 0.96), box=(0.0, 0.18, 1.0, 0.62), sq=(0.42, 0.14, 0.98, 0.70),
        url="https://www.loc.gov/pictures/item/2016872097/",
        title="Capitol telephone switchboard and operators, Washington, D.C. (1937)", author="Harris & Ewing", lic=HE,
        tone=dict(gamma=1.0, contrast=1.2, local=60)),
    "office_phone": dict(
        year="1908",
        file="File:William Howard Taft, three-quarter-length portrait, seated, facing left, talking on a telephone as he "
             "receives news about his nomination as the 1908 Republican presidential candidate from LCCN2015647021.jpg",
        trim=(0.02, 0.02, 0.98, 0.95), box=(0.0, 0.20, 1.0, 0.48), sq=(0.10, 0.18, 0.72, 0.64),
        url="https://www.loc.gov/pictures/item/2015647021/",
        title="William Howard Taft on the telephone, receiving news of his nomination (1908)",
        author="Harris & Ewing", lic=HE, tone=dict(gamma=0.75, contrast=1.25, local=80, cutoff=0.5)),
    "desk_phone": dict(
        year="1913",
        file="File:MARTIN, FRANKLIN H., DR. OF CHICAGO. REGENT AND SECRETARY GENERAL, AMERICAN COLLEGE OF SURGEONS "
             "LCCN2016864744.jpg",
        trim=(0.03, 0.04, 0.97, 0.94), box=(0.0, 0.22, 1.0, 0.76), sq=(0.22, 0.08, 0.84, 0.80),
        url="https://www.loc.gov/pictures/item/2016864744/",
        title="Dr. Franklin H. Martin at his desk with a candlestick telephone (1913)", author="Harris & Ewing", lic=HE,
        tone=dict(gamma=1.0, contrast=1.15, local=60)),
    "phone_call": dict(
        year="1913",
        file="File:Businessman on candlestick telephone.jpg", box=(0.02, 0.02, 0.98, 0.98), sq=(0.30, 0.04, 0.86, 0.96),
        pad="white", title="Businessman on a candlestick telephone (magazine advertisement, 1913)",
        author="Unknown illustrator (The All-Story Magazine)", lic="Public domain (published 1913)",
        tone=dict(gamma=1.0, contrast=1.05, local=20, sharpen=60)),
    # ---- the wire
    "telegram": dict(
        year="1920",
        file="File:Western Union telegram to Jane Judge of Georgia from Annie G. Wright on passage of Nineteenth "
             "Amendment, August 26, 1920.jpg", box=(0.0, 0.02, 1.0, 0.68), sq=(0.22, 0.0, 0.88, 0.62),
        title="Western Union telegram, Augusta to Savannah, August 26, 1920",
        author="Annie G. Wright, via Western Union (unknown author)", lic="Public domain (1920 document)", tone=dict(gamma=1.1, contrast=1.3, local=40, cutoff=2)),
    "telegraph_key": dict(
        year="c. 1876 (photo 2013)",
        file="File:Telegraph key and sounder, Western Electric Manufacturing Co, Chicago, c. 1876 - Wisconsin "
             "Historical Museum - DSC02817.JPG", box=(0.0, 0.10, 1.0, 0.62), sq=(0.50, 0.18, 0.90, 0.74),
        title="Telegraph key and sounder, Western Electric Manufacturing Co., c. 1876 (Wisconsin Historical Museum)",
        author="Daderot", lic="CC0 1.0 (public domain)", tone=dict(gamma=1.0, contrast=1.2, local=60)),
    "messenger_boy": dict(
        year="1913",
        file="File:Percy Neville Shreveport 1913.jpg", box=(0.0, 0.12, 1.0, 0.72), sq=(0.18, 0.08, 0.78, 0.96),
        title="Messenger boy on his bicycle, Shreveport, Louisiana (1913)",
        author="Lewis Wickes Hine (National Child Labor Committee, Library of Congress)", lic=NCLC,
        tone=dict(gamma=1.1, contrast=1.2, local=60)),
    # ---- the deal
    "handshake": dict(
        year="1938",
        file="File:J.F.T. O'Connor, Comptroller of the Treasury, former Pres. of the California State Society, shaking "
             "hands with congressman Frank Buck, new President of the Society LCCN2016873033.tif",
        trim=(0.02, 0.02, 0.98, 0.97), box=(0.12, 0.24, 0.90, 0.60), sq=(0.24, 0.20, 0.80, 0.76),
        url="https://www.loc.gov/pictures/item/2016873033/",
        title="Two men in suits shaking hands, Washington, D.C. (1938)", author="Harris & Ewing", lic=HE,
        tone=dict(gamma=0.9, contrast=1.2, local=70)),
    "handshake_managers": dict(
        year="1938",
        file="File:Just another handshaking. Washington, D.C., April 18. The traditional handshaking was repeated today "
             "as Bucky Harris and Connie Mack gripped each other just before their teams went into LCCN2016873413.jpg",
        trim=(0.01, 0.02, 0.99, 0.98), box=(0.04, 0.06, 1.0, 0.58), sq=(0.26, 0.04, 0.96, 0.74),
        url="https://www.loc.gov/pictures/item/2016873413/",
        title="Bucky Harris and Connie Mack shake hands before the opener, Washington, D.C. (1938)",
        author="Harris & Ewing", lic=HE, tone=dict(gamma=1.3, contrast=1.1, local=60, cutoff=0.3)),
    "signing": dict(
        year="1908",
        file="File:Ty Cobb and Frank Navin.jpeg", box=(0.0, 0.24, 1.0, 0.80), sq=(0.0, 0.16, 0.62, 0.92),
        title="Ty Cobb signs with Detroit owner Frank Navin (1908)", author="Unknown photographer (The Sporting News)",
        lic="Public domain (published 1908)", tone=dict(gamma=0.75, contrast=1.15, local=60)),
    "magnates": dict(
        year="1913",
        file="File:National League magnates (baseball) LCCN2014681792.jpg", trim=(0.02, 0.02, 0.98, 0.97),
        box=(0.04, 0.44, 0.96, 0.78), sq=(0.26, 0.38, 0.74, 0.80), url="https://www.loc.gov/pictures/item/2014681792/",
        title="National League magnates (1913)", author="Bain News Service", lic=BAIN,
        tone=dict(gamma=1.0, contrast=1.2, local=70)),
    # ---- the trip out of town
    "station": dict(
        year="c. 1911",
        file="File:Passengers walking through hallway at Pennsylvania Station, New York, New York LCCN2004670837.jpg",
        trim=(0.02, 0.05, 0.98, 0.97), box=(0.0, 0.40, 1.0, 0.92), sq=(0.22, 0.24, 0.82, 0.96),
        url="https://www.loc.gov/pictures/item/2004670837/",
        title="Passengers in the hallway of Pennsylvania Station, New York (c. 1911)",
        author="Library of Congress Prints and Photographs Division", lic=LOC,
        tone=dict(gamma=1.25, contrast=1.3, local=80, cutoff=1)),
    "luggage": dict(
        year="1911",
        file="File:Boston Red Sox in Chicago - DPLA - d738a8e296af0a1803d50c97daf72b6f.jpg",
        box=(0.0, 0.10, 1.0, 0.74), sq=(0.08, 0.06, 0.58, 0.92),
        title="Boston Red Sox arrive in Chicago by train, bags in hand (1911)",
        author="Unknown photographer (Boston Public Library)", lic="Public domain (photograph 1911)",
        tone=dict(gamma=0.85, contrast=1.15, local=60)),
    "train": dict(
        year="c. 1910-1920",
        file="File:A Deluxe overland limited train.jpg", box=(0.0, 0.22, 1.0, 0.74), sq=(0.0, 0.18, 0.46, 0.78),
        title="A deluxe overland limited train, Atchison, Topeka & Santa Fe (c. 1910-1920)",
        author="Detroit Publishing Co. (Library of Congress det.4a24374)",
        lic="Public domain (Detroit Publishing Co. collection, Library of Congress; no known restrictions)",
        tone=dict(gamma=1.0, contrast=1.2, local=60)),
    # ---- the papers
    "newsboys": dict(
        year="1909",
        file="File:Lewis Hine, Hartford Newsboys, 1909, NGA 115839.jpg", box=(0.0, 0.08, 1.0, 0.70),
        sq=(0.24, 0.08, 0.76, 0.86), title="Hartford newsboys (1909)",
        author="Lewis Wickes Hine (National Gallery of Art 1985.64.1)", lic="CC0 1.0 (public domain)",
        tone=dict(gamma=0.8, contrast=1.15, local=60)),
    "newsboy": dict(
        year="1910",
        file="File:Michael Mc Nelis, 8 years old, a newsboy. This boy has just recovered from his second attack of "
             "pneumonia. Was found... - NARA - 523323.jpg", trim=(0.01, 0.02, 0.955, 0.98),
        box=(0.14, 0.10, 0.96, 0.62), sq=(0.30, 0.10, 0.78, 0.84),
        title="A newsboy sells a paper, Philadelphia (1910)", author="Lewis Wickes Hine (NARA 523323)",
        lic="Public domain (US National Archives)", tone=dict(gamma=0.75, contrast=1.15, local=70)),
    "reading_paper": dict(
        year="c. 1900",
        file="File:J.C. Smith (reading newspaper) LCCN2014713608.tif", trim=(0.03, 0.02, 0.98, 0.98),
        box=(0.0, 0.24, 1.0, 0.52), sq=(0.08, 0.24, 0.92, 0.86), url="https://www.loc.gov/pictures/item/2014713608/",
        title="J.C. Smith reading the newspaper (c. 1900)", author="Bain News Service", lic=BAIN,
        tone=dict(gamma=1.45, contrast=1.1, local=50, cutoff=0.3)),
    "press": dict(
        year="1937",
        file="File:Feeding one of the presses LCCN2016872427.jpg", trim=(0.02, 0.03, 0.98, 0.96),
        box=(0.0, 0.24, 1.0, 0.78), sq=(0.14, 0.08, 0.76, 0.74), url="https://www.loc.gov/pictures/item/2016872427/",
        title="Feeding one of the presses (1937)", author="Harris & Ewing", lic=HE,
        tone=dict(gamma=1.1, contrast=1.15, local=60)),
    "linotype": dict(
        year="1941",
        file="File:Russell Lee, Linotype operators of the Chicago Defender, 1941.jpg", box=(0.0, 0.32, 1.0, 0.82),
        sq=(0.30, 0.30, 0.80, 0.96),
        title="Linotype operators of the Chicago Defender (1941)",
        author="Russell Lee, Farm Security Administration (Library of Congress ppmsca.01614)", lic="Public domain (US government work, FSA/OWI)",
        tone=dict(gamma=0.8, contrast=1.2, local=70)),
    # ---- the deadline
    "clock": dict(
        year="2024 photo",
        file="File:Antique wall clock.jpg", box=(0.0, 0.10, 1.0, 0.39), sq=(0.06, 0.04, 0.96, 0.70),
        title="Antique wall clock", author="Amitbalani (Wikimedia Commons)", lic="CC0 1.0 (public domain)",
        tone=dict(gamma=1.0, contrast=1.2, local=50)),
    "calendar": dict(
        year="1918",
        file="File:The Lincoln calendar (1918) (14591014560).jpg", box=(0.0, 0.72, 1.0, 0.98),
        sq=(0.04, 0.72, 0.52, 0.98), pad="white", url="https://www.flickr.com/photos/internetarchivebookimages/14591014560",
        title="The Lincoln Calendar, July 1918 page",
        author="R. S. Bartlett (compiler), Sully and Kleinteich, New York (Internet Archive Book Images)",
        lic="Public domain (published 1918; no known copyright restrictions)",
        tone=dict(gamma=1.0, contrast=1.3, local=30, cutoff=2)),
    "calendar_1897": dict(
        year="1896",
        file="File:January, February, March, 1897 MET DP823995.jpg", box=(0.0, 0.03, 1.0, 0.30),
        sq=(0.58, 0.02, 0.99, 0.50), title="Calendar page: January, February, March, 1897",
        author="Edward Penfield (The Metropolitan Museum of Art)", lic="CC0 1.0 (public domain)",
        tone=dict(gamma=1.2, contrast=1.3, local=40, cutoff=2)),
}
ORDER = list(PHOTOS)


# ------------------------------------------------------------------ commons

def _slug(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")[:80]


def _meta(ii):
    m = ii.get("extmetadata") or {}
    return {k: strip_html(v.get("value", "")) if isinstance(v, dict) else "" for k, v in m.items()}


def _query(params, path, width):
    if os.path.exists(path):
        return json.load(open(path))
    base = {"action": "query", "format": "json", "prop": "imageinfo", "iiprop": "url|extmetadata|size|mime",
            "iiurlwidth": width,
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
                  os.path.join(PDIR, "search", _slug(q) + ".json"), 320)


def info(title):
    r = _query({"titles": title}, os.path.join(PDIR, "info", hashlib.sha1(title.encode()).hexdigest()[:12] + ".json"),
               1600)
    return r[0] if r else None


def download(e, sub="img"):
    p = os.path.join(PDIR, sub, hashlib.sha1(e["title"].encode()).hexdigest()[:12] + ".jpg")
    if not os.path.exists(p):
        ensure_dir(os.path.dirname(p))
        http(e["thumb"], p)
        time.sleep(0.5)
    return p if os.path.exists(p) else None


def run_search(only=None):
    rev = ensure_dir(os.path.join(PDIR, "review"))
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
                if cls not in ("pd", "cc0"):
                    continue
                lst.append((cls, e, lic))
        lines = []
        for i, (cls, e, lic) in enumerate(lst[:48]):
            p = download(e, "rthumb")
            lines.append(f"{i:2d} {cls:3s} {e['w']}x{e['h']} {e['title']} | {lic} | {e['meta'].get('Artist', '')[:60]}"
                         f" | {e['meta'].get('DateTimeOriginal', '')[:20]}")
            if p:
                try:
                    im = Image.open(p).convert("L")
                    im.thumbnail((200, 130))
                    items.append((im, f"{i}"))
                except Exception:
                    pass
        open(os.path.join(rev, key + ".txt"), "w").write("\n".join(lines) + "\n")
        common.contact_sheet(items, os.path.join(rev, key + ".png"), cols=8, cell=(200, 130))
        print(f"{key:18s} {len(lst)} candidates"); sys.stdout.flush()


# ------------------------------------------------------------------ build

def photo_entry(key):
    """Resolve the pinned Commons file (cached imageinfo), re-check the license, download the 1600px thumb."""
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


def crop_to(im, box, size, pad="edge"):
    """Grow fractional `box` to the aspect of `size` around its centre (padding past the edge), resize."""
    W, H = size
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
        if pad in ("white", "black"):
            a = np.pad(a, ((pt, pb), (pl, pr)), mode="constant", constant_values=255 if pad == "white" else 0)
        else:
            a = np.pad(a, ((pt, pb), (pl, pr)), mode=pad)
            if pad == "edge":  # soften the replicated streaks into smooth bands
                blur = np.asarray(Image.fromarray(a).filter(ImageFilter.GaussianBlur(max(3, a.shape[1] // 120))))
                m = np.ones(a.shape, bool)
                m[pt:pt + h, pl:pl + w] = False
                a = np.where(m, blur, a).astype(np.uint8)
        X0, X1, Y0, Y1 = X0 + pl, X1 + pl, Y0 + pt, Y1 + pt
    return Image.fromarray(a[Y0:Y1, X0:X1]).resize((W, H), Image.LANCZOS)


def tone(im, cutoff=1, gamma=1.0, contrast=1.1, local=50, sharpen=100, blur=0.0, radius=12):
    if blur:
        im = im.filter(ImageFilter.GaussianBlur(blur))
    im = ImageOps.autocontrast(im, cutoff=cutoff)
    if local:
        im = im.filter(ImageFilter.UnsharpMask(radius=radius, percent=local, threshold=0))
    if gamma != 1.0:
        im = im.point(lambda v: int(255 * ((v / 255) ** gamma)))
    im = ImageEnhance.Contrast(im).enhance(contrast)
    return im.filter(ImageFilter.UnsharpMask(radius=1.0, percent=sharpen, threshold=2))


def dither(im, mix=0.0):
    if mix:
        W, H = im.size
        a = np.asarray(im, np.float32) / 255.0
        thr = np.tile(common.BAYER8, (H // 8 + 1, W // 8 + 1))[:H, :W]
        im = Image.fromarray((np.clip(a + (thr - 0.5) * mix, 0, 1) * 255).astype(np.uint8), "L")
    return atkinson(im)


def frame(im):
    """1 px black border so thumbnails sit cleanly on a white dialog."""
    a = np.asarray(im).copy()
    a[0, :] = a[-1, :] = 0
    a[:, 0] = a[:, -1] = 0
    return Image.fromarray(a, "L")


def build(key):
    spec = PHOTOS[key]
    e, p = photo_entry(key)
    im = Image.open(p).convert("L")
    if spec.get("trim"):
        w, h = im.size
        t = spec["trim"]
        im = im.crop((int(t[0] * w), int(t[1] * h), int(t[2] * w), int(t[3] * h)))
    pad = spec.get("pad", "edge")
    out = {}
    card = crop_to(im, spec["box"], (CW, CH), pad)
    out[key] = dither(tone(card, **spec.get("tone", {})), spec.get("mix", 0.0))
    for n in THUMBS:
        th = crop_to(im, spec.get("sq", spec["box"]), (n * 2, n * 2), pad)
        tt = dict(spec.get("tone", {}))
        tt.update(spec.get("ttone", {}))
        tt["radius"] = max(3, n // 8)
        if n <= 48:  # small: punchier, less fine texture
            tt["contrast"] = tt.get("contrast", 1.1) * 1.15
            tt["blur"] = max(tt.get("blur", 0), 0.6)
        th = tone(th, **tt).resize((n, n), Image.LANCZOS)
        out[f"{key}-{n}"] = frame(dither(th, spec.get("mix", 0.0)))
    credit = {"path": f"images/pennant/{key}", "title": spec["title"], "author": spec["author"],
              "year": spec["year"], "url": spec.get("url") or e["page"], "license": spec["lic"]}
    return out, credit


# ------------------------------------------------------------------ outputs

def write_credits(credits):
    path = os.path.join(common.IMAGES, "credits.json")
    cur = json.load(open(path)) if os.path.exists(path) else []
    keep = [e for e in cur if not str(e.get("path", "")).startswith("images/pennant/")]
    old = {e["path"]: e for e in cur if str(e.get("path", "")).startswith("images/pennant/")}
    old.update({c["path"]: c for c in credits})
    old = {k: v for k, v in old.items() if k.split("/")[-1] in PHOTOS}
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(keep + [old[k] for k in sorted(old)], fh, indent=1, ensure_ascii=False)
        fh.write("\n")
    return [old[k] for k in sorted(old)]


def write_credits_md(entries):
    path = os.path.join(common.ROOT, "docs", "CREDITS.md")
    txt = open(path, encoding="utf-8").read()
    rows = [f"- {e['path'].split('/')[-1]}.png (+ -96, -48): {e['title']} ({e['author']}; {e['year']}) — {e['url']} — {e['license']}"
            for e in entries]
    sec = ("## Pennant art\n\nPennant-mode trade-call, trade-deadline, telegram and newspaper art "
           "(`playdate/source/images/pennant/`: `<key>.png` 400x160 cards plus `<key>-96.png` and `<key>-48.png` "
           "square dialog thumbnails, 1-bit). Every image is a real public-domain or CC0 picture, found via Wikimedia "
           "Commons: period photographs (Library of Congress Harris & Ewing, Bain News Service, National Child Labor "
           "Committee / Lewis Hine, Detroit Publishing, FSA and Highsmith collections with no known restrictions; US "
           "National Archives; National Gallery of Art CC0), period print (a 1913 magazine advertisement, a 1920 "
           "telegram, 1897 and 1918 calendars), and CC0 / public-domain-released photographs of antique telephones, "
           "a telegraph key and a wall clock. Cropped, tone-adjusted and dithered to 1 bit (changes made) "
           "by `tools/assets/pennant_art.py`.\n\n" + "\n".join(rows) + "\n")
    pat = re.compile(r"## Pennant art\n.*?(?=\n## |\Z)", re.S)
    if pat.search(txt):
        txt = pat.sub(sec.rstrip("\n") + "\n", txt)
    else:
        txt = txt.rstrip("\n") + "\n\n" + sec
    open(path, "w", encoding="utf-8").write(txt)


def contact(keys):
    """One row per key: card, 96, 48 (each with its name)."""
    rows = []
    for k in keys:
        ims = [Image.open(os.path.join(OUT, n + ".png")).convert("L") for n in (k, f"{k}-96", f"{k}-48")]
        row = Image.new("L", (CW + 96 + 48 + 16, CH), 255)
        row.paste(ims[0], (0, 0)); row.paste(ims[1], (CW + 8, 0)); row.paste(ims[2], (CW + 96 + 16, 0))
        rows.append((row, k))
    common.contact_sheet(rows, PREVIEW, cols=2, cell=(CW + 160, CH))


def main(keys):
    ensure_dir(OUT)
    credits = []
    for key in keys:
        imgs, credit = build(key)
        credits.append(credit)
        for name, im in imgs.items():
            save_1bit(im, os.path.join(OUT, name + ".png"))
        print(f"{key:18s} {os.path.getsize(os.path.join(OUT, key + '.png'))}B"); sys.stdout.flush()
    entries = write_credits(credits)
    write_credits_md(entries)
    contact([k for k in ORDER if os.path.exists(os.path.join(OUT, k + ".png"))])
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
