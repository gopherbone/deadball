#!/usr/bin/env python3
"""Compact BallCast replay logs ("?fmt=c") for the fixtures.

Mirrors encodeLogC in packages/server/src/routes/games.ts: the events become ONE string so the
Playdate's JSON decoder builds one string instead of ~600 tables (the client parses events
lazily, a few per frame: BallCast.Timeline.decodeC).

  python3 playdate/tools/compact_log.py            # every fixtures*/**/game-log*.json → game-logc*.json
"""
import glob, json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "source")


def val(v):
    if isinstance(v, bool):
        return "!1" if v else "!0"
    if isinstance(v, (int, float)):
        return json.dumps(v)
    if isinstance(v, str):
        s = re.sub(r"[\t\n\r]", " ", v)
        return "'" + s if s == "" or re.match(r"^[!#@'-.0-9]", s) else s
    if isinstance(v, list) and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v):
        return "#" + ",".join(json.dumps(x) for x in v)
    return "@" + re.sub(r"[\t\n]", " ", json.dumps(v, separators=(",", ":")))


def encode(events):
    lines = []
    for e in events:
        parts = [str(e["k"])]
        for k, v in e.items():
            if k != "k" and v is not None:
                parts.append(f"{k}={val(v)}")
        lines.append("\t".join(parts))
    return "\n".join(lines)


def main():
    for p in sorted(glob.glob(os.path.join(SRC, "fixtures*", "**", "game-log*.json"), recursive=True)):
        if "game-logc" in p or p.endswith("-page.json"):
            continue
        doc = json.load(open(p))
        if "log" not in doc:
            continue
        out = {k: v for k, v in doc.items() if k != "log"}
        out["logc"] = encode(doc["log"])
        out["n"] = len(doc["log"])
        q = p.replace("game-log", "game-logc")
        with open(q, "w") as f:
            json.dump(out, f, separators=(",", ":"))
        print(f"{os.path.relpath(q, SRC)}: {os.path.getsize(p)} -> {os.path.getsize(q)} bytes")


def lite():
    # ?lite=1 detail: what the replay needs, without the box score (routes/games.ts detail)
    for p in sorted(glob.glob(os.path.join(SRC, "fixtures", "game.json"))):
        d = json.load(open(p))
        out = {k: d[k] for k in ("id", "status", "home", "away", "myBet", "pool") if k in d}
        q = p.replace("game.json", "game-lite.json")
        with open(q, "w") as f:
            json.dump(out, f, separators=(",", ":"))
        print(f"{os.path.relpath(q, SRC)}: {os.path.getsize(p)} -> {os.path.getsize(q)} bytes")


if __name__ == "__main__":
    lite()
    main()
