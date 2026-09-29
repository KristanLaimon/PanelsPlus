# SPDX-License-Identifier: MIT
# Generate synthetic OCR training data, independent of the evaluation dataset.
import concurrent.futures
import os
import random
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(sys.argv[1]).resolve()
(root / "samples").mkdir(parents=True, exist_ok=True)
rng = random.Random(628914)
words = [
    w.strip()
    for w in (root / "words.txt").read_text().splitlines()
    if re.fullmatch("[A-Za-z]{2,12}", w.strip())
]
fonts = sorted((root / "fonts").glob("*.ttf"))
files = []
for i in range(600):
    fontpath = fonts[i % len(fonts)]
    font = ImageFont.truetype(str(fontpath), rng.choice([28, 32, 38, 44]))
    items = rng.choices(words, k=rng.choice([1, 2, 3, 4]))
    if rng.random() < 0.3:
        items.insert(rng.randrange(len(items) + 1), rng.choice(["I", "A"]))
    text = " ".join(items)
    if "Bangers" in fontpath.name or rng.random() < 0.8:
        text = text.upper()
    if rng.random() < 0.4:
        text += rng.choice([".", ",", "!", "?", "..."])
    bounds = font.getbbox(text)
    w = bounds[2] - bounds[0] + 20
    h = bounds[3] - bounds[1] + 16
    im = Image.new("L", (w, h), 255)
    ImageDraw.Draw(im).text((10 - bounds[0], 8 - bounds[1]), text, font=font, fill=0)
    slope = rng.choice([0, 0, 0.15, 0.3, 0.45])
    pad = int(h * slope) + 2
    im = im.transform(
        (w + pad, h),
        Image.Transform.AFFINE,
        (1, slope, -pad, 0, 1, 0),
        Image.Resampling.BICUBIC,
        fillcolor=255,
    )
    if rng.random() < 0.3:
        im = im.resize(
            (max(1, im.width * 2 // 3), max(1, im.height * 2 // 3)),
            Image.Resampling.LANCZOS,
        )
        im = im.resize((w + pad, h), Image.Resampling.LANCZOS)
    base = root / "samples" / f"{i:04d}"
    im.save(str(base) + ".tif")
    base.with_suffix(".gt.txt").write_text(text + "\n")
    base.with_suffix(".box").write_text(
        "".join(f"{ch} 0 0 {im.width} {im.height} 0\n" for ch in text + "\t")
    )
    files.append(base)


def convert(base):
    p = subprocess.run(
        ["tesseract", str(base) + ".tif", str(base), "--psm", "13", "lstm.train"],
        capture_output=True,
        check=False,
        env={**os.environ, "OMP_THREAD_LIMIT": "1"},
    )
    if p.returncode:
        raise RuntimeError(p.stderr.decode())
    return str(base) + ".lstmf"


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    files = list(pool.map(convert, files))
rng.shuffle(files)
(root / "train.list").write_text("\n".join(files[:540]) + "\n")
(root / "eval.list").write_text("\n".join(files[540:]) + "\n")
print(
    "600 synthetic samples from independent dictionary text and three OFL fonts; 540 train / 60 validation"
)
