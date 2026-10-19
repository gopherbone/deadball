"""Hand-keyed puppet poses + table definitions (the puppet contract lives here).

Vectors are V(left, forward, up) in metres in the figure's root frame (it faces 'forward');
rotations (bend, side, twist) in degrees.  See posing.py for the keys.  Reference joints of the
stylised rig: shoulders (+-0.165, 0, 1.40), hips (+-0.095, 0, 0.89), ankles ~0.08 m up,
thigh 0.40, shin 0.42, upper arm 0.27, forearm 0.27.

Views are (azimuth, elevation) of the camera around the figure: 0 = in front (figure faces the
camera), 180 = behind, -90 = on the figure's right (figure faces screen right), +90 = on its left.
"""
import json, os
from hlib import V, MOCAP

BACK, FRONT, SIDE = (180, 6), (0, 6), (-90, 4)
BATTER_VIEW = (62, 6)      # CF camera on a right-handed batter: his left side / front, he faces screen left
HOME_AWAY = [("", "home"), ("_away", "away")]


def P(*parts, **kw):
    d = {}
    for p in parts:
        d.update(p)
    d.update(kw)
    return d


def legs(l, r, pelvis=None, pole_l=None, pole_r=None):
    d = {"leg.L": {"ik": l}, "leg.R": {"ik": r}}
    if pole_l:
        d["leg.L"]["pole"] = pole_l
    if pole_r:
        d["leg.R"]["pole"] = pole_r
    if pelvis:
        d["pelvis"] = pelvis
    return d


STAND = P(legs(V(0.12, 0.0, 0.08), V(-0.12, 0.0, 0.08)),
          {"upper_arm.L": V(0.22, 0.02, -1), "forearm.L": V(0.12, 0.2, -1),
           "upper_arm.R": V(-0.22, 0.02, -1), "forearm.R": V(-0.12, 0.2, -1)})
HANDS_CHEST = {"arm.R": {"ik": V(-0.02, 0.24, 1.14), "pole": V(-1, -0.2, -0.6)},
               "arm.L": {"ik": V(0.05, 0.27, 1.16), "pole": V(1, -0.2, -0.6)},
               "hand.L": V(-0.6, 0.3, 0.6)}


def run(phase, lean=14, arms=True, glove=False):
    """running stride; phase 0 = left leg forward, 1 = right leg forward"""
    s = 1 if phase == 0 else -1     # +1: left leg forward
    fwd, back = ("L", "R") if phase == 0 else ("R", "L")
    sg = {"L": 1, "R": -1}
    d = {"pelvis": V(0, 0.05, 0.86), "hips": (lean, 0, 6 * s), "spine": (6, 0, -10 * s), "neck": (-lean, 0, 0),
         "thigh." + fwd: V(sg[fwd] * 0.06, 0.75, -0.65), "shin." + fwd: V(0, 0.15, -1),
         "foot." + fwd: {"abs": (-5, 0, 0)},
         "thigh." + back: V(sg[back] * 0.04, -0.40, -0.92), "shin." + back: V(0, -0.85, 0.35),
         "foot." + back: {"abs": (95, 0, 0)}}
    if arms:
        # arms swing opposite to the legs, elbows bent ~90 degrees
        d.update({"upper_arm." + back: V(sg[back] * 0.12, 0.55, -0.8), "forearm." + back: V(sg[back] * 0.05, 0.85, 0.55),
                  "upper_arm." + fwd: V(sg[fwd] * 0.12, -0.6, -0.75), "forearm." + fwd: V(sg[fwd] * 0.05, 0.25, -0.95)})
    return d


# ---------------------------------------------------------------- pitcher (right-handed)
P_SET = P(STAND, HANDS_CHEST, legs(V(0.13, 0.0, 0.08), V(-0.13, 0.0, 0.08)), {"head": (5, 0, 0)})
P_KICK_BACK = P(HANDS_CHEST, {"root": (0, 0, -78), "pelvis": V(0, 0.0, 0.90), "spine": (-6, 0, 0),
                              "leg.R": {"ik": V(-0.04, 0.0, 0.08)},
                              "thigh.L": V(0.08, 0.92, 0.35), "shin.L": V(0, -0.15, -1),
                              "foot.L": {"abs": (50, 0, 0)}, "head": (0, 0, 40)})
P_KICK_SIDE = P(HANDS_CHEST, {"root": (0, 0, -18), "pelvis": V(0, -0.02, 0.90), "spine": (-8, 0, 0),
                              "leg.R": {"ik": V(-0.06, 0.0, 0.08)},
                              "thigh.L": V(0.1, 0.95, 0.35), "shin.L": V(0, -0.2, -1),
                              "foot.L": {"abs": (50, 0, 0)}, "head": (0, 0, 15),
                              "arm.R": {"ik": V(-0.04, 0.22, 1.24), "pole": V(-1, -0.4, -0.4)},
                              "arm.L": {"ik": V(0.04, 0.26, 1.26), "pole": V(1, -0.2, -0.6)}})
P_RELEASE = {"root": (0, 0, -8), "pelvis": V(0, 0.28, 0.72), "hips": (12, 0, 18), "spine": (16, 0, 16),
             "chest": (12, 0, 10), "head": (-18, 0, -12),
             "leg.L": {"ik": V(0.16, 0.78, 0.08), "pole": V(0.2, 1, 0)},
             "leg.R": {"ik": V(-0.20, -0.42, 0.20), "pole": V(0, 1, -0.4)},
             "foot.R": {"abs": (55, 0, -20)},
             "upper_arm.R": V(-0.25, 0.45, 0.85), "forearm.R": V(-0.05, 0.85, 0.5),
             "upper_arm.L": V(0.55, -0.05, -0.8), "forearm.L": V(-0.25, 0.65, 0.4)}

# ---------------------------------------------------------------- batter (right-handed)
B_STANCE = {"pelvis": V(0, -0.02, 0.82), "hips": (8, 0, 0), "spine": (10, 0, -5), "neck": (-10, 0, 35), "head": (0, 0, 40),
            "leg.L": {"ik": V(0.27, 0.02, 0.08), "pole": V(0.3, 1, 0)},
            "leg.R": {"ik": V(-0.27, 0.0, 0.08), "pole": V(-0.3, 1, 0)},
            "arm.R": {"ik": V(-0.16, 0.20, 1.30), "pole": V(-1, -0.6, -0.5)},
            "arm.L": {"ik": V(-0.12, 0.22, 1.22), "pole": V(0.3, 1, -1)},
            "hand.R": V(0.1, 0.3, 1), "bat": V(-0.30, -0.30, 1)}
B_SWING = {"pelvis": V(0.03, 0.0, 0.80), "hips": (6, 0, 45), "spine": (8, 0, 20), "neck": (-10, 0, -20), "head": (0, 0, 0),
           "leg.L": {"ik": V(0.36, 0.06, 0.08), "pole": V(0.4, 1, 0)},
           "leg.R": {"ik": V(-0.24, 0.0, 0.16), "pole": V(0.2, 1, 0)},
           "foot.R": {"abs": (40, 0, 50)},
           "arm.R": {"ik": V(0.10, 0.44, 1.02), "pole": V(-0.5, 0, -1)},
           "arm.L": {"ik": V(0.16, 0.40, 1.04), "pole": V(1, 0, -0.5)},
           "bat": V(0.25, 1, 0.08)}
B_FOLLOW = {"pelvis": V(0.04, 0.0, 0.82), "hips": (4, 0, 70), "spine": (2, 0, 25), "neck": (-5, 0, -40), "head": (0, 0, -10),
            "leg.L": {"ik": V(0.34, 0.06, 0.08), "pole": V(0.4, 1, 0)},
            "leg.R": {"ik": V(-0.16, 0.10, 0.18), "pole": V(0.5, 1, 0)},
            "foot.R": {"abs": (60, 0, 80)},
            "arm.R": {"ik": V(0.30, 0.12, 1.42), "pole": V(-0.2, 1, -0.3)},
            "arm.L": {"ik": V(0.36, 0.06, 1.36), "pole": V(1, 0, -1)},
            "bat": V(-0.45, -0.75, 0.45)}

# ---------------------------------------------------------------- catcher (facing camera)
C_CROUCH = {"pelvis": V(0, -0.06, 0.46), "hips": (25, 0, 0), "spine": (-5, 0, 0), "neck": (-15, 0, 0),
            "leg.L": {"ik": V(0.30, 0.10, 0.08), "pole": V(0.8, 1, 0)},
            "leg.R": {"ik": V(-0.30, 0.10, 0.08), "pole": V(-0.8, 1, 0)},
            "arm.L": {"ik": V(0.20, 0.42, 0.78), "pole": V(1, 0, -1)},
            "arm.R": {"ik": V(-0.30, 0.30, 0.55), "pole": V(-1, 0, -0.2)},
            "hand.L": V(0, 0.4, 1)}
C_RECEIVE = P(C_CROUCH, {"arm.L": {"ik": V(0.16, 0.42, 1.10), "pole": V(1, 0, -1)},
                         "arm.R": {"ik": V(-0.02, 0.38, 0.92), "pole": V(-1, 0, -1)}, "hand.L": V(0, 0.2, 1)})
C_THROW = {"pelvis": V(0, 0.0, 0.86), "hips": (0, 0, -25), "spine": (-5, 0, -10), "neck": (0, 0, 30),
           "leg.L": {"ik": V(0.20, 0.28, 0.08)}, "leg.R": {"ik": V(-0.20, -0.12, 0.08)},
           "upper_arm.R": V(-0.95, -0.3, 0.25), "forearm.R": V(-0.1, -0.25, 1),
           "upper_arm.L": V(0.4, 0.8, 0.2), "forearm.L": V(0.1, 1, 0.15)}

# ---------------------------------------------------------------- catcher reach grid (IK)
# The glove (left wrist) is placed with the two-bone IK on a grid of targets in the catcher's
# frame; the body follows: leans/twists toward the glove, rises for high balls, lunges for wide
# ones, the throwing hand tucks behind the right knee. Targets are in metres (l = glove side).
REACH_X = [("glove", 0.37), ("mid", -0.07), ("back", -0.36)]
# mitt-centre heights wanted (ft): high 3.2, mid 2.4, low 1.6 (glove turned over); the mitt sits
# ~0.48 ft above the wrist when up, ~0.38 ft below when turned down (measured from the anchors)
FT_M = 3.23
REACH_Z = [("high", (3.2 - 0.48) / FT_M, False), ("mid", (2.4 - 0.48) / FT_M, False), ("low", (1.6 + 0.38) / FT_M, True)]


def reach(l, u, down=False, f=0.40):
    d = dict(C_CROUCH)
    side = max(-16, min(16, l * 40))
    twist = max(-28, min(28, l * 50))
    rise = max(0.0, u - 0.80) * 0.9
    lean = 22 if down else 0
    d["pelvis"] = V(l * 0.22, -0.06, 0.46 + rise - (0.03 if down else 0))
    d["hips"] = (25 - rise * 45 + lean * 0.4, side * 0.5, twist * 0.4)
    d["spine"] = (-5 - max(0.0, u - 0.75) * 25 + lean, side * 0.5, twist * 0.6)
    d["neck"] = (-15 + lean * 0.6, 0, -twist * 0.5)
    back = l < -0.1
    d["arm.L"] = {"ik": V(l + 0.04, f, u), "pole": V(0.3, 0.1, 1) if back else V(1, -0.2, -0.6)}
    d["hand.L"] = V(-0.25 if back else 0.08, 0.45, -0.8 if down else 1)
    d["arm.R"] = {"ik": V(-0.30 + l * 0.15, 0.02, 0.40 + rise * 0.5), "pole": V(-1, -0.3, -0.2)}
    if abs(l) > 0.5:     # way outside: step out with the near foot
        sg = 1 if l > 0 else -1
        k = "leg.L" if sg > 0 else "leg.R"
        d[k] = {"ik": V(sg * 0.48, 0.18, 0.08), "pole": V(sg * 0.8, 1, 0)}
    return d


C_BLOCK = {"pelvis": V(0, 0.05, 0.40), "hips": (40, 0, 0), "spine": (18, 0, 0), "neck": (-38, 0, 0),
           "thigh.L": V(0.22, 0.3, -1), "shin.L": V(0.05, -1, -0.12), "foot.L": V(0, -0.6, 0.6),
           "thigh.R": V(-0.22, 0.3, -1), "shin.R": V(-0.05, -1, -0.12), "foot.R": V(0, -0.6, 0.6),
           "arm.L": {"ik": V(0.03, 0.44, 0.14), "pole": V(1, 0, 0.2)}, "hand.L": V(0, 0.3, -1),
           "arm.R": {"ik": V(-0.06, 0.40, 0.22), "pole": V(-1, 0, 0.2)}}
C_REACH = [("set", C_CROUCH)] + [(f"{zn}_{xn}", reach(xl, zu, dn)) for zn, zu, dn in REACH_Z for xn, xl in REACH_X] + \
          [("way_high", reach(-0.05, (4.3 - 0.48) / FT_M)), ("way_glove", reach(0.68, (2.4 - 0.48) / FT_M)),
           ("way_back", reach(-0.65, (2.4 - 0.48) / FT_M)), ("block", C_BLOCK)]

# ---------------------------------------------------------------- umpire (facing camera)
U_CROUCH = {"pelvis": V(0, -0.14, 0.66), "hips": (38, 0, 0), "spine": (8, 0, 0), "neck": (-38, 0, 0),
            "leg.L": {"ik": V(0.26, 0.02, 0.08), "pole": V(0.6, 1, 0)},
            "leg.R": {"ik": V(-0.26, 0.02, 0.08), "pole": V(-0.6, 1, 0)},
            "arm.L": {"ik": V(0.20, 0.24, 0.52), "pole": V(1, -0.5, 0)},
            "arm.R": {"ik": V(-0.20, 0.24, 0.52), "pole": V(-1, -0.5, 0)}}
U_STRIKE = P(STAND, legs(V(0.16, 0.0, 0.08), V(-0.16, 0.0, 0.08)),
             {"hips": (0, 3, 0), "upper_arm.R": V(-0.75, 0.15, 0.65), "forearm.R": V(-0.05, 0.1, 1),
              "upper_arm.L": V(0.3, 0.1, -1), "forearm.L": V(0.15, 0.3, -1)})
U_SAFE = P(STAND, legs(V(0.20, 0.0, 0.08), V(-0.20, 0.0, 0.08)),
           {"upper_arm.L": V(1, 0.1, 0.08), "forearm.L": V(1, 0.05, 0.02),
            "upper_arm.R": V(-1, 0.1, 0.08), "forearm.R": V(-1, 0.05, 0.02), "head": (8, 0, 0)})

# ---------------------------------------------------------------- fielder
F_READY = {"pelvis": V(0, -0.08, 0.70), "hips": (32, 0, 0), "spine": (12, 0, 0), "neck": (-40, 0, 0),
           "leg.L": {"ik": V(0.26, 0.02, 0.08), "pole": V(0.5, 1, 0)},
           "leg.R": {"ik": V(-0.26, 0.02, 0.08), "pole": V(-0.5, 1, 0)},
           "arm.L": {"ik": V(0.20, 0.40, 0.48), "pole": V(1, 0, 0)},
           "arm.R": {"ik": V(-0.20, 0.40, 0.48), "pole": V(-1, 0, 0)},
           "hand.L": V(0.1, 0.8, -0.4)}
F_REACH = {"pelvis": V(0, 0.04, 0.92), "hips": (-6, 0, 0), "spine": (-8, 0, 0), "neck": (-25, 0, 0),
           "leg.R": {"ik": V(-0.08, -0.02, 0.12)}, "foot.R": {"abs": (35, 0, 0)},
           "thigh.L": V(0.05, 0.6, -0.8), "shin.L": V(0, -0.45, -0.9), "foot.L": {"abs": (40, 0, 0)},
           "upper_arm.L": V(0.12, 0.25, 1), "forearm.L": V(0.05, 0.3, 1),
           "upper_arm.R": V(-0.3, -0.6, -0.4), "forearm.R": V(-0.1, -0.5, 0.3)}
F_DIVE = {"root": (66, 0, 0), "pelvis": V(0, 0.0, 0.90), "neck": (-50, 0, 0), "_lift": 0.30,
          "upper_arm.L": V(0.12, 0.25, 1), "forearm.L": V(0.05, 0.1, 1),
          "upper_arm.R": V(-0.2, 0.0, 1), "forearm.R": V(-0.1, 0.3, 1),
          "thigh.L": V(0.08, -0.2, -1), "shin.L": V(0, -0.85, -0.5),
          "thigh.R": V(-0.08, 0.1, -1), "shin.R": V(0, -0.5, -0.85),
          "foot.L": V(0, -0.4, -1), "foot.R": V(0, -0.3, -1)}
F_THROW = {"root": (0, 0, -35), "pelvis": V(0, 0.12, 0.80), "hips": (0, -4, 0), "spine": (-6, -8, 0), "neck": (0, 8, 30),
           "leg.L": {"ik": V(0.12, 0.55, 0.08), "pole": V(0.2, 1, 0)},
           "leg.R": {"ik": V(-0.14, -0.30, 0.08), "pole": V(-0.2, 1, 0)},
           "foot.L": {"abs": (0, 0, 20)}, "foot.R": {"abs": (0, 0, 60)},
           "upper_arm.R": V(-0.45, -0.8, 0.35), "forearm.R": V(-0.1, -0.35, 1),
           "upper_arm.L": V(0.25, 0.95, 0.25), "forearm.L": V(0.05, 1, 0.1)}

# ---------------------------------------------------------------- runner
R_SLIDE = {"pelvis": V(0, 0.0, 0.25), "hips": (-38, 0, 0), "spine": (-10, 0, 0), "neck": (25, 0, 0),
           "thigh.L": V(0.05, 1, 0.12), "shin.L": V(0, 1, -0.05), "foot.L": V(0, 0.3, 1),
           "thigh.R": V(-0.12, 0.75, 0.05), "shin.R": V(-0.05, -0.8, -0.35), "foot.R": V(0, -0.2, -1),
           "upper_arm.R": V(-0.3, 0.1, 1), "forearm.R": V(-0.1, 0.4, 1),
           "upper_arm.L": V(0.35, -0.75, -0.55), "forearm.L": V(0.05, -0.2, -1)}

# slide sequence (runner frames 4-7; 1-3 unchanged): drop into the slide, head-first dive slide,
# pop-up (safe sign), slump (out)
R_DROP = {"pelvis": V(0, 0.05, 0.42), "hips": (-34, 0, 0), "spine": (-4, 0, 0), "neck": (18, 0, 0),
          "thigh.L": V(0.06, 0.9, -0.45), "shin.L": V(0, 0.95, -0.3), "foot.L": V(0, 0.4, 0.9),
          "thigh.R": V(-0.1, 0.35, -0.95), "shin.R": V(-0.05, -0.9, -0.45), "foot.R": V(0, -0.3, -1),
          "upper_arm.L": V(0.45, -0.35, 0.8), "forearm.L": V(0.2, 0.1, 1),
          "upper_arm.R": V(-0.45, -0.35, 0.8), "forearm.R": V(-0.2, 0.1, 1)}
R_HEADFIRST = {"root": (70, 0, 0), "pelvis": V(0, 0.0, 0.90), "neck": (-52, 0, 0), "_lift": 0.05,
               "upper_arm.L": V(0.14, 0.15, 1), "forearm.L": V(0.06, 0.05, 1),
               "upper_arm.R": V(-0.14, 0.15, 1), "forearm.R": V(-0.06, 0.05, 1),
               "thigh.L": V(0.1, -0.05, -1), "shin.L": V(0.04, -0.3, -0.95), "foot.L": V(0, -0.2, -1),
               "thigh.R": V(-0.1, 0.05, -1), "shin.R": V(-0.04, -0.2, -1), "foot.R": V(0, -0.2, -1)}
R_POPUP = P(STAND, legs(V(0.18, 0.05, 0.08), V(-0.16, -0.08, 0.08)),
            {"hips": (-4, 0, 0), "upper_arm.L": V(0.35, 0.55, 0.75), "forearm.L": V(0.1, 0.45, 1),
             "upper_arm.R": V(-0.35, -0.45, 0.8), "forearm.R": V(-0.1, -0.25, 1), "head": (-12, 0, 0)})
R_SLUMP = {"pelvis": V(0, 0.0, 0.18), "hips": (-20, 0, 0), "spine": (38, 0, 0), "chest": (12, 0, 0),
           "neck": (25, 0, 0), "head": (15, 0, 0),
           "thigh.L": V(0.16, 0.9, 0.3), "shin.L": V(0.05, 0.35, -0.95), "foot.L": {"abs": (0, 0, 0)},
           "thigh.R": V(-0.16, 0.9, 0.25), "shin.R": V(-0.05, 0.3, -0.95), "foot.R": {"abs": (0, 0, 0)},
           "upper_arm.L": V(0.3, 0.6, -0.7), "forearm.L": V(0.05, 0.85, 0.1),
           "upper_arm.R": V(-0.3, 0.6, -0.7), "forearm.R": V(-0.05, 0.85, 0.1)}

# ---------------------------------------------------------------- crowd & co
FAN_DOWN = P(STAND, {"head": (0, 0, 0)})
FAN_UP = P(STAND, {"upper_arm.L": V(0.45, 0.15, 0.9), "forearm.L": V(0.15, 0.1, 1),
                   "upper_arm.R": V(-0.45, 0.15, 0.9), "forearm.R": V(-0.15, 0.1, 1), "head": (-10, 0, 0)})


def streak(phase):
    d = run(phase, lean=6, arms=False)
    fwd, back = ("R", "L") if phase == 0 else ("L", "R")
    sg = {"L": 1, "R": -1}
    d.update({"upper_arm." + fwd: V(sg[fwd] * 0.3, 0.55, 0.8), "forearm." + fwd: V(sg[fwd] * 0.1, 0.35, 1),
              "upper_arm." + back: V(sg[back] * 0.3, -0.45, 0.85), "forearm." + back: V(sg[back] * 0.1, -0.1, 1),
              "neck": (-10, 0, 0)})
    return d


M_IDLE = P(STAND, {"upper_arm.L": V(0.5, 0.05, -1), "forearm.L": V(0.3, 0.3, -1),
                   "upper_arm.R": V(-0.5, 0.05, -1), "forearm.R": V(-0.3, 0.3, -1)})
M_WAVE = P(M_IDLE, {"upper_arm.R": V(-0.85, 0.15, 0.5), "forearm.R": V(-0.35, 0.05, 1), "hips": (0, 4, 0)})

# ---------------------------------------------------------------- mocap key poses (CMU, see mocap.py)
def _tup(x):
    if isinstance(x, list):
        return tuple(_tup(v) for v in x)
    if isinstance(x, dict):
        return {k: _tup(v) for k, v in x.items()}
    return x


_KP = os.path.join(MOCAP, "keyposes.json")
MC = {k: _tup(v) for k, v in json.load(open(_KP)).items()} if os.path.exists(_KP) else {}


def mc(key, fallback=None, **over):
    """mocap key pose `key` with hand-tuned overrides; the hand-keyed fallback when no mocap"""
    if key not in MC:
        return fallback
    d = {k: v for k, v in MC[key].items() if not k.startswith("_")}
    d.update(over)
    return d


# bat directions for the mocap swing frames (the markers don't carry the bat)
BAT = {"stance": V(0.1, -0.6, 1), "load": V(0.0, -0.85, 0.75), "launch": V(-0.75, 0.1, 0.35),
       "contact": V(-0.1, 1, -0.05), "extend": V(0.55, 0.75, 0.2), "follow": V(-0.25, -0.75, 0.55)}
PITCH = {k: mc("pitch_" + k) for k in ("set", "break", "kick", "stride", "cock", "release", "follow")}
SWING = {k: mc("swing_" + k, bat=BAT[k]) for k in BAT}
RUN = {k: mc("run_" + k) for k in ("a", "b", "pass_a", "pass_b")}
if MC:
    P_SET, P_KICK_BACK, P_KICK_SIDE, P_RELEASE = PITCH["set"], PITCH["kick"], PITCH["kick"], PITCH["release"]
    B_STANCE, B_SWING, B_FOLLOW = SWING["stance"], SWING["contact"], SWING["follow"]
    RUN1, RUN2 = RUN["a"], RUN["b"]
    F_THROW = PITCH["cock"]
else:
    RUN1, RUN2 = run(0, lean=18), run(1, lean=18)

PLAYER = ("cap",)
TABLES = [
    {"name": "pitcher_back", "outfit": "player", "props": PLAYER + ("glove",), "view": BACK, "variants": HOME_AWAY,
     "desc": "Pitcher from behind (CF/pitch cam): set, kick, release",
     "frames": [("set", P_SET), ("kick", P_KICK_BACK), ("release", P_RELEASE)]},
    {"name": "pitcher_side", "outfit": "player", "props": PLAYER + ("glove",), "view": SIDE, "variants": HOME_AWAY,
     "desc": "Pitcher side-on facing right (toward the plate): set, kick, release. Flip for facing left",
     "frames": [("set", P_SET), ("kick", P_KICK_SIDE), ("release", P_RELEASE)]},
    {"name": "batter", "outfit": "player", "props": PLAYER + ("bat",), "view": BATTER_VIEW, "variants": HOME_AWAY,
     "desc": "Right-handed batter as seen from the CF cam (stands right of plate, faces left): stance, swing, follow. "
             "Left-handed = flip horizontally",
     "frames": [("stance", B_STANCE), ("swing", B_SWING), ("follow", B_FOLLOW)]},
    {"name": "catcher", "outfit": "player", "props": PLAYER + ("mitt", "mask", "chestpro"), "view": FRONT,
     "variants": HOME_AWAY, "desc": "Catcher facing camera: crouch, receive (mitt up), throw",
     "frames": [("crouch", C_CROUCH), ("receive", C_RECEIVE), ("throw", C_THROW)]},
    {"name": "catcher_reach", "outfit": "player", "props": PLAYER + ("mitt", "mask", "chestpro"), "view": FRONT,
     "variants": HOME_AWAY, "glove": True,
     "desc": "EXTRA catcher receive grid (IK): 1 set; 2-10 glove at high/mid/low x glove-side/middle/backhand; "
             "11 way high, 12 way glove side, 13 way backhand, 14 block (dirt). Glove anchors in anim_tracks.json",
     "frames": C_REACH},
    {"name": "umpire", "outfit": "umpire", "props": ("cap", "mask"), "view": FRONT, "variants": [("", "home")],
     "desc": "Umpire (dark suit) facing camera: crouch, strike/out call, safe",
     "frames": [("crouch", U_CROUCH), ("strike", U_STRIKE), ("safe", P(U_SAFE, _hide=("mask",)))]},
    {"name": "fielder", "outfit": "player", "props": PLAYER + ("glove",), "view": SIDE, "variants": HOME_AWAY,
     "desc": "Fielder: ready (front), run1, run2, reach, dive, throw (side, facing right)",
     "frames": [("ready", P(F_READY, _view=FRONT)), ("run1", RUN1), ("run2", RUN2), ("reach", F_REACH),
                ("dive", F_DIVE), ("throw", F_THROW)]},
    {"name": "runner", "outfit": "player", "props": PLAYER, "view": SIDE, "variants": HOME_AWAY,
     "desc": "Runner facing right: run1, run2, slide (feet first); 4 drop, 5 head-first, 6 pop-up (safe), 7 slump (out)",
     "frames": [("run1", RUN1), ("run2", RUN2), ("slide", R_SLIDE), ("drop", R_DROP), ("headfirst", R_HEADFIRST),
                ("popup", R_POPUP), ("slump", R_SLUMP)]},
    {"name": "streaker", "outfit": "streaker", "props": ("hair", "censor"), "view": SIDE, "variants": [("", "home")],
     "desc": "Streaker (censor bar), running right: 2 frames",
     "frames": [("streak1", streak(0)), ("streak2", streak(1))]},
    {"name": "mascot", "outfit": "mascot", "props": ("ballhead", "ballface"), "view": FRONT, "variants": [("", "home")],
     "desc": "Mascot (baseball head): idle, wave",
     "frames": [("mascot1", M_IDLE), ("mascot2", M_WAVE)]},
    {"name": "fan", "outfit": "fan", "props": ("boater",), "view": FRONT, "variants": [("", ["home", "gray"])],
     "desc": "1 arms down, 2 arms up (white shirt); 3 arms down, 4 arms up (gray shirt)",
     "frames": [("down", FAN_DOWN), ("up", FAN_UP)]},
]
# ---------------------------------------------------------------- extra in-between tables (mocap)
SEQ = []
if MC:
    SEQ = [
        {"name": "pitcher_back_seq", "outfit": "player", "props": PLAYER + ("glove",), "view": BACK, "variants": HOME_AWAY,
         "desc": "EXTRA pitch cycle from behind: 1 set, 2 kick, 3 stride, 4 cock, 5 release, 6 follow",
         "frames": [(k, PITCH[k]) for k in ("set", "kick", "stride", "cock", "release", "follow")]},
        {"name": "pitcher_side_seq", "outfit": "player", "props": PLAYER + ("glove",), "view": SIDE, "variants": HOME_AWAY,
         "desc": "EXTRA pitch cycle side-on facing right: 1 set, 2 kick, 3 stride, 4 cock, 5 release, 6 follow",
         "frames": [(k, PITCH[k]) for k in ("set", "kick", "stride", "cock", "release", "follow")]},
        {"name": "batter_seq", "outfit": "player", "props": PLAYER + ("bat",), "view": BATTER_VIEW, "variants": HOME_AWAY,
         "desc": "EXTRA swing cycle (CF cam, right-handed): 1 stance, 2 load, 3 launch, 4 contact, 5 extend, 6 follow",
         "frames": [(k, SWING[k]) for k in ("stance", "load", "launch", "contact", "extend", "follow")]},
        {"name": "runner_seq", "outfit": "player", "props": PLAYER, "view": SIDE, "variants": HOME_AWAY,
         "desc": "EXTRA 4-frame run cycle facing right: 1 pass, 2 stride, 3 pass (other leg), 4 stride (other leg)",
         "frames": [("pass_b", RUN["pass_b"]), ("a", RUN["a"]), ("pass_a", RUN["pass_a"]), ("b", RUN["b"])]},
    ]
# ---------------------------------------------------------------- accent poses for silly incidents / celebrations
A_CARTWHEEL = {"root": (0, 180, 0), "pelvis": V(0, 0, 0.89),
               "upper_arm.L": V(0.45, 0.05, 1), "forearm.L": V(0.35, 0.05, 1),
               "upper_arm.R": V(-0.45, 0.05, 1), "forearm.R": V(-0.35, 0.05, 1),
               "thigh.L": V(0.75, 0.0, -0.65), "shin.L": V(0.8, 0.0, -0.6), "foot.L": V(0.6, 0.0, -0.8),
               "thigh.R": V(-0.75, 0.0, -0.65), "shin.R": V(-0.8, 0.0, -0.6), "foot.R": V(-0.6, 0.0, -0.8)}
A_TUCK = {"root": (-35, 0, 0), "_ground": False, "_lift": 0.75, "pelvis": V(0, 0, 0.6), "neck": (30, 0, 0),
          "thigh.L": V(0.12, 0.85, 0.45), "shin.L": V(0.05, -0.3, -1), "foot.L": V(0, 0.6, -0.6),
          "thigh.R": V(-0.12, 0.85, 0.45), "shin.R": V(-0.05, -0.3, -1), "foot.R": V(0, 0.6, -0.6),
          "upper_arm.L": V(0.3, 0.8, -0.2), "forearm.L": V(0.0, 0.2, -1),
          "upper_arm.R": V(-0.3, 0.8, -0.2), "forearm.R": V(0.0, 0.2, -1)}
A_PRATFALL = {"pelvis": V(0, 0, 0.14), "hips": (-40, 0, 0), "spine": (-8, 0, 0), "neck": (25, 0, 0),
              "thigh.L": V(0.12, 0.8, 0.6), "shin.L": V(0.05, 0.6, 0.8), "foot.L": V(0, 0.2, 1),
              "thigh.R": V(-0.12, 0.85, 0.45), "shin.R": V(-0.05, 0.9, 0.2), "foot.R": V(0, 0.6, 0.8),
              "upper_arm.L": V(0.55, -0.4, 0.75), "forearm.L": V(0.3, 0.1, 1),
              "upper_arm.R": V(-0.55, -0.3, 0.75), "forearm.R": V(-0.3, 0.2, 1)}
A_JUMP = {"_lift": 0.22, "pelvis": V(0, 0, 0.89), "hips": (-6, 0, 0), "neck": (-12, 0, 0),
          "thigh.L": V(0.12, 0.35, -0.95), "shin.L": V(0.05, -0.75, -0.65), "foot.L": {"abs": (55, 0, 0)},
          "thigh.R": V(-0.12, 0.2, -1), "shin.R": V(-0.05, -0.85, -0.55), "foot.R": {"abs": (60, 0, 0)},
          "upper_arm.L": V(0.55, 0.1, 0.85), "forearm.L": V(0.25, 0.05, 1),
          "upper_arm.R": V(-0.55, 0.1, 0.85), "forearm.R": V(-0.25, 0.05, 1)}
SEQ.append({"name": "accent", "outfit": "player", "props": PLAYER, "view": FRONT, "variants": HOME_AWAY,
            "desc": "EXTRA accent poses for silly incidents / celebrations: 1 cartwheel (inverted, front), "
                    "2 backflip tuck (airborne, side), 3 pratfall (side), 4 celebrate jump (front)",
            "frames": [("cartwheel", P(A_CARTWHEEL, _hide=("cap",))), ("tuck", P(A_TUCK, _view=SIDE)),
                       ("pratfall", P(A_PRATFALL, _view=SIDE)), ("jump", A_JUMP)]})
TABLES += SEQ
TABLE_BY_NAME = {t["name"]: t for t in TABLES}

DEBUG_POSES = {
    "armsup": FAN_UP,
    "squat": C_CROUCH,
    "kick": P_KICK_SIDE,
    "release": P_RELEASE,
}

# ---------------------------------------------------------------- multi-view pose sets
# Every billboard pose set is rendered from several camera directions so the runtime can pick
# the view matching the camera vs. the puppet's facing (playdate/source/ballcast/puppets.lua).
# Table name: <set>_<view> (+ _away). Views: v0..v7 = camera azimuth k*45 deg around the figure
# (0 = in front, 90 = on its left, 180 = behind, 270 = on its right), elevation 6 deg;
# h0..h3 = azimuth k*90 deg at 65 deg down (blimp / steep shots).
VIEWS = [(f"v{k}", ((k * 45 + 180) % 360) - 180, 6) for k in range(8)]
# pose sets drawn with a facing at runtime, in PACK ORDER (puppets.lua VIEW_SETS mirrors this:
# name, frames per view, has _away). pitcher/batter 3-frame tables are frame remaps of the _seq sets;
# accent/streaker/mascot stay single-view (legacy art).
VIEW_SETS = [("pitcher_seq", "pitcher_back_seq"), ("batter_seq", "batter_seq"), ("catcher", "catcher"),
             ("umpire", "umpire"), ("fielder", "fielder"), ("runner", "runner"), ("runner_seq", "runner_seq"),
             ("catcher_reach", "catcher_reach")]
# sets drawn only from a few directions (index into VIEWS): the catcher is seen from the pitch cam
# (front), behind the plate (back) and the side cams
VIEW_SUBSET = {"catcher_reach": [0, 2, 4, 6]}
TABLE_POSESET = {src: ps for ps, src in VIEW_SETS}


def _strip_view(frames):
    return [(lab, {k: v for k, v in p.items() if k != "_view"}) for lab, p in frames]


POSESETS = []
for _ps, _tn in VIEW_SETS:
    _t = TABLE_BY_NAME[_tn]
    POSESETS.append({"name": _ps, "outfit": _t["outfit"], "props": _t["props"], "variants": _t["variants"],
                     "frames": _strip_view(_t["frames"]), "glove": _t.get("glove", False)})
VIEW_TABLES = []
for _p in POSESETS:
    for _vi, (_vid, _az, _el) in enumerate(VIEWS):
        if _p["name"] in VIEW_SUBSET and _vi not in VIEW_SUBSET[_p["name"]]:
            continue
        VIEW_TABLES.append(dict(_p, name=f"{_p['name']}_{_vid}", view=(_az, _el), multiview=True,
                                desc=f"{_p['name']} seen from azimuth {_az}, elevation {_el}"))
ALL_TABLES = TABLES + VIEW_TABLES
TABLE_BY_NAME.update({t["name"]: t for t in VIEW_TABLES})
