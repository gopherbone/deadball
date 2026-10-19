"""Edit faces_overrides.json by current face number (resolved through images/faces/faces.json).

  python3 tools/assets/faces_ov.py skip 12 40 77          # drop these people from the bank
  python3 tools/assets/faces_ov.py skipphoto 12b 40c       # drop one photo variant
  python3 tools/assets/faces_ov.py sex F 31 94
  python3 tools/assets/faces_ov.py age old 22 26 27
  python3 tools/assets/faces_ov.py crop 16 zoom=1.2 dy=-0.05 dx=0.03   # main photo (or 16b)
"""
import os, sys, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import IMAGES, HERE

OV = os.path.join(HERE, "faces_overrides.json")


def main(argv):
    man = {m["n"]: m for m in json.load(open(os.path.join(IMAGES, "faces", "faces.json")))["faces"]}
    ov = json.load(open(OV)) if os.path.exists(OV) else {}
    ov.setdefault("photos", {}); ov.setdefault("people", {})
    cmd, rest = argv[0], argv[1:]

    def ref(tok):
        n = int(tok.rstrip("bc")); suf = tok[len(str(n)):]
        m = man[n]
        v = next(v for v in m["variants"] if v["suffix"] == suf)
        return m, v

    if cmd in ("sex", "age"):
        val, nums = rest[0], rest[1:]
        for t in nums:
            m, _ = ref(t)
            ov["people"].setdefault(m["key"], {})[cmd] = val
    elif cmd == "skip":
        for t in rest:
            m, v = ref(t)
            ov["people"].setdefault(m["key"], {})["skip"] = True
            ov["people"][m["key"]]["why"] = v["caption"][:60]
    elif cmd == "skipphoto":
        for t in rest:
            _, v = ref(t)
            ov["photos"].setdefault(v["pk"], {})["skip"] = True
    elif cmd == "crop":
        _, v = ref(rest[0])
        d = ov["photos"].setdefault(v["pk"], {})
        for kv in rest[1:]:
            k, x = kv.split("=")
            d[k] = float(x)
    with open(OV, "w") as fh:
        json.dump(ov, fh, indent=1, ensure_ascii=False)
        fh.write("\n")


if __name__ == "__main__":
    main(sys.argv[1:])
