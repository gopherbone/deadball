#!/usr/bin/env python3
"""Writes playdate/source/fixtures_dev/ballcast/game-log-ultra.json: the BallCast dev replay
(fixtures_dev/ballcast/game-log.json) with Enhanced League `{k:"ultra", who, power, side}`
events spliced in where the sim would log them, so every power effect can be previewed.
Open it in BallCast with gameId "ultra" (kit.lua routes /games/ultra/* here).

  FIREBALL, STOPPER (swinging strike), WARP_PITCH (called strike), CLOUD_BALL: before a "p"
  HYPER_HIT: before the "p" that puts the first home run in play (carries over to the bip)
  LEAP_CATCH: before the second home run's "bip", which becomes a robbed fly out
  LASER_ARM, WARP_RUN: passive in the sim (never logged); injected here for preview only

Run: python3 playdate/tools/make_ultra_fixture.py
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "..", "source", "fixtures_dev", "ballcast")
src = json.load(open(os.path.join(DEV, "game-log.json")))
log = src["log"]

# who's batting/pitching at each index, and which side each team is
bat = pit = None
top = True
ctx = []
for e in log:
    if e["k"] == "half":
        top = e["top"]
    if e["k"] == "pa":
        bat, pit = e["bat"], e["pit"]
    ctx.append((bat, pit, "home" if top else "away", "away" if top else "home"))  # (bat, pit, defSide, offSide)

inserts = {}   # index → list of ultra events to insert before it
used = set()


def first(pred, start=30):
    for i in range(start, len(log)):
        if i not in used and pred(i, log[i]):
            used.add(i)
            return i
    raise SystemExit("no candidate")


def ultra(i, who, power, side):
    inserts.setdefault(i, []).append({"k": "ultra", "who": who, "power": power, "side": side})


def pitch_power(power, r, start):
    i = first(lambda i, e: e["k"] == "p" and e["r"] == r, start)
    b, p, d, o = ctx[i]
    ultra(i, p, power, d)
    return i


pitch_power("FIREBALL", "S", 30)
pitch_power("STOPPER", "S", 80)
pitch_power("WARP_PITCH", "C", 120)
pitch_power("CLOUD_BALL", "S", 160)

hrs = [i for i, e in enumerate(log) if e["k"] == "bip" and e["res"] == "HR"]
# HYPER_HIT: logged before the contact pitch
h = hrs[0]
b, p, d, o = ctx[h]
ultra(h - 1, b, "HYPER_HIT", o)
used.add(h)
# LEAP_CATCH: a solo shot becomes a robbed fly out (drop the batter's run)
solo = next(i for i in hrs[1:] if not (i + 2 < len(log) and log[i + 2]["k"] == "mv"))
sp = log[solo].get("sp", 0)
log[solo] = dict(log[solo], res="OUT", out="FO", f="LF" if sp < -14 else "RF" if sp > 14 else "CF")
if log[solo + 1]["k"] == "mv" and log[solo + 1]["to"] == 4:
    log[solo + 1] = None
b, p, d, o = ctx[solo]
people = src.get("people", {})
team = (people.get(p) or {}).get("teamAbbr")
of = [k for k, v in people.items() if v.get("teamAbbr") == team and v.get("pos") in ("LF", "CF", "RF")]
ultra(solo, of[0] if of else p, "LEAP_CATCH", d)
used.add(solo)

i = first(lambda i, e: e["k"] == "bip" and e.get("out") == "GO", 40)
b, p, d, o = ctx[i]
ultra(i, p, "LASER_ARM", d)
i = first(lambda i, e: e["k"] == "bip" and e["res"] in ("2B", "3B"), 40)
b, p, d, o = ctx[i]
ultra(i, b, "WARP_RUN", o)

out = []
for i, e in enumerate(log):
    out.extend(inserts.get(i, []))
    if e is not None:
        out.append(e)
doc = dict(src, id="ultra", log=out)
p = os.path.join(DEV, "game-log-ultra.json")
with open(p, "w") as f:
    json.dump(doc, f, separators=(",", ":"))
print("wrote", p, "with", sum(len(v) for v in inserts.values()), "ultra events")
