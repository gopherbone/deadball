"""Download candidate portrait photos from the Library of Congress Bain News Service
collection (ggbain) into tools/assets/.cache/loc/.

  python3 tools/assets/faces_fetch.py            # search + download (skips cached files)
  python3 tools/assets/faces_fetch.py --offline  # just report what's cached

Search results: .cache/loc/search/<slug>-<page>.json
Images:        .cache/loc/img/<pk>.jpg   (the ~1024px "v.jpg" derivative)
Index:         .cache/loc/index.json     (pk -> metadata, merged from all searches)
"""
import os, sys, json, time, re, urllib.request, urllib.parse, urllib.error
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import CACHE, ensure_dir

LOC = os.path.join(CACHE, "loc")
RATE_SLEEP = 300
SEARCH_PAUSE = 8.0   # seconds between loc.gov search requests (their burst limit is low)
UA = "deadball-asset-pipeline/1.0 (public-domain face bank; python urllib)"

# (query, max pages of 100). Varied so the bank isn't all ballplayers.
QUERIES = [
    ("baseball", 12), ("baseball players", 4), ("baseball manager", 2), ("umpire", 2),
    ("head-and-shoulders portrait", 6), ("portrait", 6), ("Mrs.", 6), ("Miss", 6),
    ("woman", 3), ("women", 2), ("old man", 2), ("elderly", 2), ("aged", 2),
    ("policeman", 2), ("police", 2), ("fireman", 2), ("priest", 2), ("Rev.", 3), ("minister", 1),
    ("nun", 1), ("sister", 1), ("vendor", 2), ("peddler", 1), ("worker", 2), ("workers", 1),
    ("strikers", 1), ("sailor", 1), ("jockey", 2), ("boxer", 2), ("wrestler", 1), ("golfer", 1),
    ("tennis", 2), ("aviator", 2), ("chauffeur", 1), ("detective", 1), ("judge", 1),
    ("lawyer", 1), ("doctor", 1), ("Dr.", 2), ("actress", 2), ("singer", 1), ("dancer", 1),
    ("bride", 1), ("widow", 1), ("suffragist", 2),
    ("captain", 1), ("coach", 1), ("trainer", 1), ("athlete", 2), ("runner", 1), ("swimmer", 1),
    ("rower", 1), ("cyclist", 1), ("football", 2), ("polo", 1), ("hockey", 1),
    ("prisoner", 1), ("murder", 1), ("trial", 1), ("gangster", 1), ("heiress", 1),
    ("count", 1), ("mayor", 1), ("alderman", 1), ("explorer", 1), ("inventor", 1),
]


def slug(q):
    return re.sub(r"[^a-z0-9]+", "_", q.lower()).strip("_")


def get(url, path=None, tries=4):
    for k in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            if path:
                tmp = path + ".part"
                with open(tmp, "wb") as fh:
                    fh.write(data)
                os.replace(tmp, path)
            return data
        except urllib.error.HTTPError as e:
            if e.code == 429:
                # loc.gov rate limit / Cloudflare challenge: back off for a while
                print(f"  429 from loc.gov, sleeping {RATE_SLEEP}s"); sys.stdout.flush()
                time.sleep(RATE_SLEEP)
                continue
            if k == tries - 1 or e.code == 404:
                return None
            time.sleep(2 + 3 * k)
        except Exception as e:  # noqa
            if k == tries - 1:
                print("  fail", url, e)
                return None
            time.sleep(2 + 3 * k)


def search_all(offline=False):
    sd = ensure_dir(os.path.join(LOC, "search"))
    index = {}
    for q, pages in QUERIES:
        for p in range(1, pages + 1):
            path = os.path.join(sd, f"{slug(q)}-{p}.json")
            if not os.path.exists(path):
                if offline:
                    break
                url = ("https://www.loc.gov/pictures/search/?" +
                       urllib.parse.urlencode({"q": q, "co": "ggbain", "fo": "json", "c": 100, "sp": p}))
                data = get(url, path, tries=8)
                time.sleep(SEARCH_PAUSE)
                if data is None:
                    break
            try:
                d = json.load(open(path))
            except Exception:
                os.remove(path)
                break
            res = d.get("results") or []
            for r in res:
                pk = r.get("pk")
                img = (r.get("image") or {}).get("full")
                if not pk or not img:
                    continue
                e = index.setdefault(pk, {
                    "pk": pk, "title": r.get("title", ""), "subjects": r.get("subjects") or [],
                    "date": r.get("created_published_date", ""), "item": (r.get("links") or {}).get("item", ""),
                    "img": img, "queries": []})
                if q not in e["queries"]:
                    e["queries"].append(q)
            if len(res) < 100:
                break
        print(f"query {q!r}: index now {len(index)}")
    json.dump(index, open(os.path.join(LOC, "index.json"), "w"), indent=0)
    return index


def big_url(img):
    # tile.loc.gov derivatives: ...r.jpg (640px) -> ...v.jpg (1024px)
    return re.sub(r"r\.jpg$", "v.jpg", img)


IMG_PAUSE = 1.5  # seconds between image requests (tile.loc.gov shares the loc.gov rate limit)


def download(index, pks=None, workers=1):
    idir = ensure_dir(os.path.join(LOC, "img"))
    order = list(pks) if isinstance(pks, list) else [pk for pk in index if pks is None or pk in pks]
    todo = [index[pk] for pk in order if index[pk].get("img")
            and not os.path.exists(os.path.join(idir, f"{pk}.jpg"))]
    print(f"downloading {len(todo)} images")

    def one(e):
        path = os.path.join(idir, f"{e['pk']}.jpg")
        if get(big_url(e["img"]), path) is None:
            time.sleep(IMG_PAUSE)
            get(e["img"], path)  # fall back to the 640px derivative
        time.sleep(IMG_PAUSE)
    done = 0
    with ThreadPoolExecutor(workers) as ex:
        for _ in ex.map(one, todo):
            done += 1
            if done % 100 == 0:
                print("  ", done)


if __name__ == "__main__":
    offline = "--offline" in sys.argv
    idx = search_all(True if "--images-first" in sys.argv else offline)
    if not offline and "--search-only" not in sys.argv:
        import faces_select
        # first fetch images for what is already indexed (cheap), then search more
        cands = faces_select.prefilter(idx)
        download(idx, set(cands))
        idx = search_all(False)
        cands = faces_select.prefilter(idx)
        print(f"{len(cands)} candidates after caption prefilter")
        download(idx, set(cands))
