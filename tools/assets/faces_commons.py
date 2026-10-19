"""Wikimedia Commons mirror of the LoC Bain collection (Category:George Grantham Bain Collection,
uploaded from loc.gov with the LCCN in each file name). Used when loc.gov rate-limits us
(loc.gov + tile.loc.gov return HTTP 429 / Cloudflare challenges after a few hundred requests).

Every photo is still identified by its LoC LCCN (pk) and credited to the LoC item URL
https://www.loc.gov/pictures/item/<pk>/ ; Commons is only the download mirror.

  python3 tools/assets/faces_commons.py           # search Commons + download missing images
"""
import os, sys, json, re, time, urllib.request, urllib.parse, urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import CACHE, ensure_dir

API = "https://commons.wikimedia.org/w/api.php"
UA = "deadball-asset-pipeline/1.0 (public-domain face bank; python urllib)"
LOC = os.path.join(CACHE, "loc")
CDIR = os.path.join(CACHE, "commons")
PAUSE = 0.4
ORIGINALS = True   # fetch original scans and downscale locally to <= MAXPX
MAXPX = 1100

# intitle: terms searched inside the Bain category (Commons titles are the LoC captions)
QUERIES = ["Mrs.", "Miss", "Mme.", "Mlle.", "Lady", "Countess", "Rev.", "Dr.", "Capt.", "Judge", "Prof.",
           "Sister", "Mother", "Mayor", "Sheriff", "Policeman", "Detective", "Inspector", "Senator",
           "baseball", "umpire", "manager", "coach", "jockey", "boxer", "wrestler", "golfer", "tennis",
           "aviator", "chauffeur", "sailor", "Col.", "Major", "Lieut.", "Sgt.", "Count", "Baron",
           "Commissioner", "Warden", "Bishop", "Father", "Old", "aged", "veteran", "actress", "singer",
           "Mr.", "Jr.", "Sr.", "Hon.", "Gov."]


def api(params, tries=6):
    params = dict(params, format="json")
    url = API + "?" + urllib.parse.urlencode(params)
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                d = json.load(r)
            time.sleep(PAUSE)
            return d
        except Exception as e:  # noqa
            time.sleep(5 * (k + 1))
    return {}


TITLE_RE = re.compile(r"^File:(.*?)\s*LCCN\s?(\d{8,10})\.jpe?g$", re.I)


def search(q, limit=1500):
    sd = ensure_dir(os.path.join(CDIR, "search"))
    slug = re.sub(r"[^a-z0-9]+", "_", q.lower()).strip("_")
    path = os.path.join(sd, f"{slug}.json")
    if os.path.exists(path):
        return json.load(open(path))
    out, off = [], 0
    while off < limit:
        d = api({"action": "query", "list": "search", "srnamespace": 6, "srlimit": 500, "sroffset": off,
                 "srsearch": f'incategory:George_Grantham_Bain_Collection intitle:"{q}"'})
        res = (d.get("query") or {}).get("search") or []
        out += [r["title"] for r in res]
        if "continue" not in d or not res:
            break
        off = d["continue"]["sroffset"]
    json.dump(out, open(path, "w"))
    return out


def lookup_pk(pk):
    """Commons file title for a LoC pk (or None)."""
    d = api({"action": "query", "list": "search", "srnamespace": 6, "srlimit": 10,
             "srsearch": f"intitle:LCCN{pk}"})
    for r in (d.get("query") or {}).get("search") or []:
        m = TITLE_RE.match(r["title"])
        if m and m.group(2) == pk:
            return r["title"]
    return None


def thumb_urls(titles, width=1024):
    out = {}
    for i in range(0, len(titles), 50):
        chunk = titles[i:i + 50]
        d = api({"action": "query", "prop": "imageinfo", "iiprop": "url|size", "iiurlwidth": width,
                 "titles": "|".join(chunk)})
        norm = {n["to"]: n["from"] for n in (d.get("query") or {}).get("normalized", [])}
        for p in ((d.get("query") or {}).get("pages") or {}).values():
            ii = (p.get("imageinfo") or [{}])[0]
            t = norm.get(p.get("title"), p.get("title"))
            # originals: thumbnail renders are rate-limited hard (429, retry-after 600)
            u = ii.get("url") if ORIGINALS else (ii.get("thumburl") or ii.get("url"))
            if u:
                out[t] = u
    return out


def download_url(url, path, tries=5):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            from PIL import Image
            import io
            im = Image.open(io.BytesIO(data))
            im.draft("L", (MAXPX * 2, MAXPX * 2))
            im = im.convert("L")
            im.thumbnail((MAXPX, MAXPX), Image.LANCZOS)
            im.save(path + ".part", "JPEG", quality=90)
            os.replace(path + ".part", path)
            return True
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return False
            ra = e.headers.get("retry-after") if e.headers else None
            print("  http", e.code, "retry-after", ra); sys.stdout.flush()
            time.sleep(min(120, int(ra)) if ra and ra.isdigit() else 5 * (k + 1))
        except Exception:
            time.sleep(5 * (k + 1))
    return False


def merge_index():
    """Add Commons search hits to .cache/loc/index.json as LoC items (pk from LCCN)."""
    ipath = os.path.join(LOC, "index.json")
    index = json.load(open(ipath)) if os.path.exists(ipath) else {}
    added = 0
    for q in QUERIES:
        for t in search(q):
            m = TITLE_RE.match(t)
            if not m or "(cropped)" in t:
                continue
            caption, pk = m.group(1).strip(), m.group(2)
            e = index.get(pk)
            if e is None:
                index[pk] = e = {"pk": pk, "title": caption, "subjects": [], "date": "",
                                 "item": f"https://www.loc.gov/pictures/item/{pk}/", "img": "", "queries": []}
                added += 1
            e["commons"] = t
            if "commons:" + q not in e["queries"]:
                e["queries"].append("commons:" + q)
        print(f"commons {q!r}: index {len(index)} (+{added})"); sys.stdout.flush()
    json.dump(index, open(ipath, "w"), indent=0)
    return index


def fetch_images(index, pks, lookup=True):
    idir = ensure_dir(os.path.join(LOC, "img"))
    todo = [pk for pk in pks if not os.path.exists(os.path.join(idir, f"{pk}.jpg"))]
    print(f"commons: {len(todo)} images to fetch"); sys.stdout.flush()
    # titles we already know first, then resolve LoC-only items by LCCN search
    known = [pk for pk in todo if index[pk].get("commons")]
    unknown = [pk for pk in todo if "commons" not in index[pk]]
    n = 0

    def grab(pks):
        nonlocal n
        for i in range(0, len(pks), 50):
            chunk = pks[i:i + 50]
            urls = thumb_urls([index[pk]["commons"] for pk in chunk])
            from concurrent.futures import ThreadPoolExecutor

            def one(pk):
                u = urls.get(index[pk]["commons"])
                ok = bool(u) and download_url(u, os.path.join(idir, f"{pk}.jpg"))
                time.sleep(0.3)
                return ok
            with ThreadPoolExecutor(3) as ex:
                n += sum(ex.map(one, chunk))
            print("  downloaded", n); sys.stdout.flush()

    grab(known)
    if lookup:
        for j, pk in enumerate(unknown):
            index[pk]["commons"] = lookup_pk(pk) or ""
            if j % 50 == 0:
                print("  lookup", j, len(unknown)); sys.stdout.flush()
        json.dump(index, open(os.path.join(LOC, "index.json"), "w"), indent=0)
        grab([pk for pk in unknown if index[pk]["commons"]])
    print("commons: downloaded", n)


if __name__ == "__main__":
    import faces_select
    idx = merge_index()
    fetch_images(idx, faces_select.prefilter(idx))


def loc_image_urls(index, pks):
    """Read the LoC 'Image download' URL from each Commons file page (API, not the thumb servers)
    and store it as the entry's `img` so faces_fetch.download() can fetch from tile.loc.gov."""
    need = [pk for pk in pks if not index[pk].get("img") and index[pk].get("commons")]
    for i in range(0, len(need), 50):
        chunk = need[i:i + 50]
        d = api({"action": "query", "prop": "revisions", "rvprop": "content", "rvslots": "main",
                 "titles": "|".join(index[pk]["commons"] for pk in chunk)})
        q = d.get("query") or {}
        norm = {n["to"]: n["from"] for n in q.get("normalized", [])}
        by_title = {index[pk]["commons"]: pk for pk in chunk}
        for p in (q.get("pages") or {}).values():
            t = norm.get(p.get("title"), p.get("title"))
            pk = by_title.get(t)
            revs = p.get("revisions") or []
            if not pk or not revs:
                continue
            txt = revs[0].get("slots", {}).get("main", {}).get("*", "")
            m = re.search(r"Image download:''\s*(https?://\S+?\.jpg)", txt)
            if m:
                u = m.group(1).replace("https://cdn.loc.gov/service/", "https://tile.loc.gov/storage-services/service/")
                index[pk]["img"] = u.replace("v.jpg", "r.jpg") if u.endswith("v.jpg") else u
            dm = re.search(r"\|date=([^\n|]*)", txt)
            if dm and not index[pk].get("date"):
                index[pk]["date"] = dm.group(1).strip()
        if i % 500 == 0:
            print("  loc urls", i, len(need)); sys.stdout.flush()
    json.dump(index, open(os.path.join(LOC, "index.json"), "w"), indent=0)
