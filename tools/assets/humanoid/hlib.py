"""Shared constants for the humanoid puppet pipeline (plain Python; imported by both the
Blender-side scripts and the Pillow/numpy post-processing)."""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SOURCE_BLEND = os.path.join(HERE, "source", "Humanoid.blend")
SOURCE_TEX = os.path.join(HERE, "source", "NonOverlapping.png")
CACHE = os.path.join(HERE, "cache")
RENDERS = os.path.join(CACHE, "renders")
TEXTURES = os.path.join(HERE, "textures")
PREVIEW = os.path.join(HERE, "preview")
LEGACY = os.path.join(HERE, "legacy")
RIG_BLEND = os.path.join(CACHE, "rig.blend")
FACES_JSON = os.path.join(CACHE, "mesh_faces.json")
RIG_JSON = os.path.join(CACHE, "rig.json")
MOCAP = os.path.join(HERE, "mocap")
PUPPETS_OUT = os.path.join(REPO, "playdate", "source", "images", "puppets")

# Colour regions of NonOverlapping.png -> body part
REGIONS = {
    (255, 210, 172): "head", (254, 209, 171): "head", (253, 208, 171): "head",
    (68, 255, 243): "torso",
    (0, 255, 14): "arm.R", (198, 255, 0): "arm.L",
    (128, 72, 216): "hand.R", (0, 26, 216): "hand.L",
    (255, 0, 107): "leg.R", (255, 141, 247): "leg.L",
    (255, 105, 0): "foot", (246, 242, 255): "foot",
}

# Material classes written into the R channel of the class textures / prop materials
# (value = code * 16 / 255) and decoded by sprites.py.
BG, WHITE, JERSEY, BLACK, SKIN, SHIRT, MID, LIGHT = 0, 1, 2, 3, 4, 5, 6, 7
CLASS_NAMES = {WHITE: "white", JERSEY: "jersey", BLACK: "black", SKIN: "skin", SHIRT: "shirt",
               MID: "mid", LIGHT: "light"}
# preview colours for the human-readable uniform textures
CLASS_RGB = {BG: (40, 40, 40), WHITE: (245, 245, 240), JERSEY: (225, 230, 255), BLACK: (25, 25, 30),
             SKIN: (240, 200, 170), SHIRT: (200, 230, 200), MID: (128, 128, 128), LIGHT: (190, 190, 190)}

# Render geometry. Everything is rendered at SS hi-res pixels per 1x output pixel on a canvas of
# CANVAS (1x px), with the field origin (feet) projected to ORIGIN_PX (1x px, continuous coords).
SS = 8
CANVAS = (88, 64)
ORIGIN_PX = (44.0, 54.0)
# The standing rest figure (cap top to sole) spans MASK_H_1X px of fill at 1x; ink adds 1 px
# above/below -> head-top ink at y=2, feet ink at y=42 in the 28x44 cell.
MASK_H_1X = 39.0
CAM_DIST = 12.0
DEPTH_NEAR, DEPTH_RANGE = CAM_DIST - 2.0, 4.0


def V(l, f, u):
    """pose vector in the figure's root frame: (left, forward, up) metres"""
    return ("V", float(l), float(f), float(u))
