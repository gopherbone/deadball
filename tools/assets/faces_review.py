"""Review sheets for hand-checking the face bank: preview/review/r-<k>.png, 40 faces per sheet
at 96x120 with "n sex age" labels (and the 24px thumb in the corner). Use findings to edit
faces_overrides.json (photos: skip / zoom / dx / dy / face; people: sex / age / skip)."""
import os, sys, json
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import IMAGES, PREVIEW, contact_sheet


def main(start=0, per=40):
    man = json.load(open(os.path.join(IMAGES, "faces", "faces.json")))["faces"]
    out = os.path.join(PREVIEW, "review")
    os.makedirs(out, exist_ok=True)
    for f in os.listdir(out):
        os.remove(os.path.join(out, f))
    for s in range(start, len(man), per):
        items = []
        for m in man[s:s + per]:
            n = m["n"]
            im = Image.open(os.path.join(IMAGES, "faces", f"{n}-96.png")).convert("L")
            th = Image.open(os.path.join(IMAGES, "faces", f"{n}-24.png")).convert("L")
            im.paste(0, (70, 0, 96, 26)); im.paste(th, (71, 1))
            items.append((im, f"{n} {m['sex']}{m['age'][0]} {m['photos']}"))
        contact_sheet(items, os.path.join(out, f"r-{s // per:02d}.png"), cols=10, cell=(96, 120), label_font="tiny")


if __name__ == "__main__":
    main()
