"""BallCast dev fixture with Pennant bunts (sac, squeeze, drag, fakes): a pdsim tactics-bot game.

  playdate/c/pdsim_test/run.sh 1              # (once) builds the host + the calibration world
  $T/host tacticslog $T/w bunts.json 300      # the game with the most bunt variety
  python3 tools/make_bunts_fixture.py bunts.json

Names, faces and the park are borrowed from the dev fixture (fixtures_dev/ballcast/game-logc.json).
Writes fixtures_dev/ballcast/game-log-bunts.json and game-logc-bunts.json (BallCast game id "bunts")."""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.join(HERE, "..", "playdate", "source", "fixtures_dev", "ballcast")
src = json.load(open(sys.argv[1]))
logc = open(sys.argv[1] + ".logc").read()
dev = json.load(open(os.path.join(DEV, "game-logc.json")))
donors = list(dev["people"].values())
people = {}
for i, (pid, p) in enumerate(sorted(src["people"].items())):
    d = donors[i % len(donors)]
    q = dict(p)
    q["name"], q["face"] = d["name"], d.get("face")
    people[pid] = q
for name, doc in (("game-log-bunts.json", {"id": "bunts", "people": people, "park": dev["park"], "log": src["log"]}),
                  ("game-logc-bunts.json", {"id": "bunts", "people": people, "park": dev["park"], "logc": logc,
                                            "n": len(src["log"])})):
    with open(os.path.join(DEV, name), "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    print("wrote", name)
