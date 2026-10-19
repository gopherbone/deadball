"""Face detection for crop placement (OPTIONAL step: needs opencv-python-headless).

Results are written to tools/assets/faces_detect.json, which is checked in, so the normal
rebuild (`build.py`) needs only Pillow + numpy. Re-run this only after fetching new photos:

  python3 -m venv --system-site-packages /tmp/cvenv && /tmp/cvenv/bin/pip install opencv-python-headless
  /tmp/cvenv/bin/python tools/assets/faces_detect.py

Model: YuNet (OpenCV Zoo, MIT/Apache) downloaded to .cache/models/.
Per photo: {"size": [w, h], "faces": [[x, y, w, h, score, rex, rey, lex, ley, nx, ny, rmx, rmy, lmx, lmy], ...]}
(pixel coords in the cached image; sorted by area, largest first).
"""
import os, sys, json, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import CACHE, HERE, ensure_dir

MODEL_URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx"
OUT = os.path.join(HERE, "faces_detect.json")


def main():
    import cv2
    import numpy as np
    mdir = ensure_dir(os.path.join(CACHE, "models"))
    model = os.path.join(mdir, "yunet.onnx")
    if not os.path.exists(model):
        urllib.request.urlretrieve(MODEL_URL, model)
    det = cv2.FaceDetectorYN.create(model, "", (320, 320), 0.6, 0.3, 5000)
    idir = os.path.join(CACHE, "loc", "img")
    res = json.load(open(OUT)) if os.path.exists(OUT) else {}
    files = sorted(f for f in os.listdir(idir) if f.endswith(".jpg"))
    for i, f in enumerate(files):
        pk = f[:-4]
        if pk in res:
            continue
        img = cv2.imread(os.path.join(idir, f))
        if img is None:
            continue
        h, w = img.shape[:2]
        faces = []
        # run at native size and (for big images) at 0.6x to catch large faces
        for s in (1.0, 0.6):
            im = img if s == 1.0 else cv2.resize(img, (int(w * s), int(h * s)))
            det.setInputSize((im.shape[1], im.shape[0]))
            _, out = det.detect(im)
            if out is not None:
                for r in out:
                    v = [float(x) / s for x in r[:14]]
                    faces.append(v[:4] + [float(r[14])] + v[4:14])
        # merge duplicates (IoU > 0.4), keep best score
        faces.sort(key=lambda r: -r[4])
        kept = []
        for r in faces:
            ok = True
            for k in kept:
                ix = max(0, min(r[0] + r[2], k[0] + k[2]) - max(r[0], k[0]))
                iy = max(0, min(r[1] + r[3], k[1] + k[3]) - max(r[1], k[1]))
                inter = ix * iy
                if inter / (r[2] * r[3] + k[2] * k[3] - inter + 1e-6) > 0.4:
                    ok = False; break
            if ok:
                kept.append(r)
        kept.sort(key=lambda r: -(r[2] * r[3]))
        res[pk] = {"size": [w, h], "faces": [[round(x, 1) if j != 4 else round(x, 3) for j, x in enumerate(r)] for r in kept[:6]]}
        if i % 200 == 0:
            print(i, len(files))
            json.dump(res, open(OUT, "w"), separators=(",", ":"))
    json.dump(res, open(OUT, "w"), separators=(",", ":"))
    print("detections:", len(res))


if __name__ == "__main__":
    main()
