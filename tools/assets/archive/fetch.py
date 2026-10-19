"""Search Wikimedia Commons for archive candidates (queries.py) and download them.

  python3 tools/assets/archive/fetch.py            # search + download (cached; safe to re-run)
  python3 tools/assets/archive/fetch.py --offline  # rebuild candidates.json from cached searches only

Accepted rights: Public domain / PD-* / "No restrictions" (LoC no-known-restrictions) / CC0, and
CC-BY (any version, attribution recorded). Rejected: CC-BY-SA, NC, ND, GFDL, fair use, unknown.
Public-domain items are ranked ahead of CC-BY ones.

Cache:  tools/assets/.cache/archive/search/<slug>.json   (search + imageinfo pages)
        tools/assets/.cache/archive/img/<sha1-of-title>.jpg  (960px thumbnails)
        tools/assets/.cache/archive/candidates.json  (group -> ordered candidate list)
"""
import os, sys, json, re, time, hashlib, html, urllib.request, urllib.parse, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
from common import CACHE, ensure_dir  # noqa: E402
from faces_select import FAMOUS_RE  # noqa: E402  (read-only reuse of the assets agent's famous-people list)
from queries import G  # noqa: E402

API = "https://commons.wikimedia.org/w/api.php"
UA = "DeadballArchive/1.0 (https://play.date; public-domain archive pipeline) python-urllib"
ADIR = os.path.join(CACHE, "archive")
PAUSE = 1.0

BAD_TITLE = re.compile(r"\b(map|coat of arms|logo|flag of|diagram|chart of|seal of|signature|svg|stamp|coin|banknote|"
                       r"page \d+|cover|title page|text)\b", re.I)
BAD_MIME = ("application/pdf", "image/vnd.djvu", "image/svg+xml", "image/gif", "video", "audio")


def http(url, path=None, tries=6, binary=False):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            if path:
                with open(path + ".part", "wb") as fh:
                    fh.write(data)
                os.replace(path + ".part", path)
            return data
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            wait = 30 * (k + 1) if e.code == 429 else 3 * (k + 1)
            print(f"  http {e.code}, retry in {wait}s"); sys.stdout.flush()
            time.sleep(wait)
        except Exception as e:  # noqa
            print("  err", e); time.sleep(3 * (k + 1))
    return None


def strip_html(s):
    s = re.sub(r"<[^>]+>", " ", s or "")
    return re.sub(r"\s+", " ", html.unescape(s)).strip()


def rights(meta):
    """-> (class, license string) with class in pd/cc0/by or None if rejected."""
    lic = strip_html(meta.get("LicenseShortName", {}).get("value", ""))
    l = lic.lower()
    if not l:
        return None, lic
    if any(x in l for x in ("-sa", " sa ", "share", "-nc", "-nd", "gfdl", "fair use", "non-free", "copyrighted")):
        return None, lic
    if l.startswith("cc0") or "cc-zero" in l:
        return "cc0", "CC0 1.0"
    if l.startswith("public domain") or l.startswith("pd") or "no restrictions" in l or "no known" in l:
        return "pd", lic
    if re.match(r"cc[- ]by( \d|-\d|$)", l):
        return "by", lic
    return None, lic


def search(group, q):
    sd = ensure_dir(os.path.join(ADIR, "search"))
    slug = re.sub(r"[^a-z0-9]+", "_", q.lower()).strip("_")[:80]
    path = os.path.join(sd, f"{slug}.json")
    if os.path.exists(path):
        return json.load(open(path))
    if OFFLINE:
        return []
    params = {"action": "query", "format": "json", "generator": "search", "gsrnamespace": 6, "gsrlimit": 30,
              "gsrsearch": q + " filetype:bitmap", "prop": "imageinfo", "iiprop": "url|extmetadata|size|mime",
              "iiurlwidth": 960,
              "iiextmetadatafilter": "LicenseShortName|LicenseUrl|UsageTerms|Artist|Credit|DateTimeOriginal|ImageDescription|ObjectName"}
    d = http(API + "?" + urllib.parse.urlencode(params))
    time.sleep(PAUSE)
    if d is None:
        return []
    d = json.loads(d)
    out = []
    for p in (d.get("query") or {}).get("pages", {}).values():
        ii = (p.get("imageinfo") or [{}])[0]
        m = ii.get("extmetadata") or {}
        out.append({"title": p["title"], "index": p.get("index", 99), "mime": ii.get("mime", ""),
                    "w": ii.get("width", 0), "h": ii.get("height", 0), "thumb": ii.get("thumburl") or ii.get("url"),
                    "page": ii.get("descriptionurl", ""),
                    "meta": {k: strip_html(v.get("value", "")) if isinstance(v, dict) else "" for k, v in m.items()}})
    out.sort(key=lambda e: e["index"])
    json.dump(out, open(path, "w"), indent=0)
    return out


def key_of(title):
    return hashlib.sha1(title.encode()).hexdigest()[:12]


def accept(e):
    if any(e["mime"].startswith(b) for b in BAD_MIME):
        return None
    if min(e["w"], e["h"]) < 300:
        return None
    t = e["title"]
    blob = (t + " " + e["meta"].get("ImageDescription", "")[:300]).lower()
    if FAMOUS_RE.search(blob) or BAD_TITLE.search(t):
        return None
    cls, lic = rights({"LicenseShortName": {"value": e["meta"].get("LicenseShortName", "")}})
    return (cls, lic) if cls else None


def main():
    cands = {}
    seen = set()
    for grp in G:
        lst = []
        for q in grp["searches"]:
            for e in search(grp["key"], q):
                ok = accept(e)
                if not ok or e["title"] in seen:
                    continue
                seen.add(e["title"])
                cls, lic = ok
                lcc = re.search(r"LCCN\s?(\d{8,10})", e["title"])
                lst.append({"title": e["title"], "key": key_of(e["title"]), "thumb": e["thumb"], "page": e["page"],
                            "rights": cls, "license": lic, "licenseUrl": e["meta"].get("LicenseUrl", ""),
                            "usage": e["meta"].get("UsageTerms", ""), "artist": e["meta"].get("Artist", "")[:200],
                            "credit": e["meta"].get("Credit", "")[:300], "date": e["meta"].get("DateTimeOriginal", "")[:40],
                            "desc": e["meta"].get("ImageDescription", "")[:300], "lccn": lcc.group(1) if lcc else "",
                            "q": q})
        # PD first, then CC0, then CC-BY; keep search order within each
        rank = {"pd": 0, "cc0": 1, "by": 2}
        lst.sort(key=lambda c: rank[c["rights"]])
        cands[grp["key"]] = lst[: max(grp["take"] * 3, 12)]
        print(f"{grp['key']:18s} {len(lst):3d} accepted -> {len(cands[grp['key']])}"); sys.stdout.flush()
    json.dump(cands, open(os.path.join(ADIR, "candidates.json"), "w"))
    if OFFLINE:
        return
    idir = ensure_dir(os.path.join(ADIR, "img"))
    todo = [c for lst in cands.values() for c in lst if not os.path.exists(os.path.join(idir, c["key"] + ".jpg"))]
    if "--reverse" in sys.argv:
        todo.reverse()
    for a in sys.argv:
        if a.startswith("--shuffle="):
            import random
            random.Random(a).shuffle(todo)
    print(f"downloading {len(todo)}")
    for i, c in enumerate(todo):
        if os.path.exists(os.path.join(idir, c["key"] + ".jpg")):
            continue
        http(c["thumb"], os.path.join(idir, c["key"] + ".jpg"))
        time.sleep(0.5)
        if i % 50 == 0:
            print("  ", i); sys.stdout.flush()


OFFLINE = "--offline" in sys.argv
if __name__ == "__main__":
    main()
