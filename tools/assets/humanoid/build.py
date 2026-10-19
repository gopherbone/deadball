"""Humanoid puppet pipeline: python3 tools/assets/humanoid/build.py [steps...] [--preview]

Steps (default: all, in order):
  rig      blender: label UV regions, stylise, armature + auto weights (cleaned), props -> cache/rig.blend
  uniform  class textures per outfit from the UV regions        -> textures/*_class.png (+ previews)
  mocap    CMU key poses (downloads ASF/AMC into cache/ once)   -> mocap/keyposes.json (skipped offline;
           the committed keyposes.json is used, or hand-keyed poses if it is missing)
  render   blender/EEVEE data renders of every table frame       -> cache/renders/
  sprites  1-bit tables -> playdate/source/images/puppets/{1x,2x}/ (--preview: cache/out/ only) + contact sheets
  anim     animatic tracks -> images/puppets/anim_tracks.json + preview/anim_*.{png,gif}
  check    rig deformation turntable / extreme poses             -> preview/rig_check.png
Needs `blender` (5.x) on PATH, numpy and Pillow."""
import os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hlib

STEPS = ["rig", "uniform", "mocap", "render", "sprites", "anim"]


def blender(script, *args, blend=None):
    cmd = ["blender", "-b"] + ([blend] if blend else []) + ["-P", os.path.join(HERE, script)]
    if args:
        cmd += ["--"] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = [l for l in r.stdout.splitlines() if " OK" in l or l.startswith("weights")]
    if r.returncode or not ok or "Traceback" in r.stdout + r.stderr:
        sys.stderr.write(r.stdout[-4000:] + r.stderr[-4000:])
        raise SystemExit(f"blender step {script} failed")
    print("  " + "\n  ".join(ok))


def main(argv):
    preview = "--preview" in argv
    steps = [a for a in argv if not a.startswith("--")] or STEPS
    for s in steps:
        t = time.time()
        print(f"[{s}]")
        if s == "rig":
            blender("rig_build.py")
        elif s == "uniform":
            import uniform; uniform.build()
        elif s == "mocap":
            import mocap
            try:
                mocap.fetch(); mocap.export(); print("  key poses -> mocap/keyposes.json")
            except Exception as e:  # offline: keep the committed key poses
                print("  mocap skipped:", e)
        elif s == "render":
            blender("render_frames.py", blend=hlib.RIG_BLEND)
        elif s == "check":
            blender("render_frames.py", "--debug", blend=hlib.RIG_BLEND)
            import json
            from PIL import Image
            d = os.path.join(hlib.CACHE, "debug")
            ims = [Image.open(os.path.join(d, n + ".png")).convert("RGB") for n in json.load(open(os.path.join(d, "index.json")))]
            w, h = ims[0].size
            sheet = Image.new("RGB", (8 * w, ((len(ims) + 7) // 8) * h), "white")
            for i, im in enumerate(ims):
                sheet.paste(im, ((i % 8) * w, (i // 8) * h))
            sheet.save(os.path.join(hlib.PREVIEW, "rig_check.png"))
        elif s == "sprites":
            import sprites; sprites.build(install=not preview)
        elif s == "anim":
            import anim_tracks; anim_tracks.build()
        else:
            raise SystemExit("unknown step " + s)
        print(f"  ({time.time() - t:.1f}s)")


if __name__ == "__main__":
    main(sys.argv[1:])
