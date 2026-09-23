# SPDX-License-Identifier: MIT
# Generate synthetic OCR training data, independent of the evaluation dataset.
import concurrent.futures
import os
import random
import string
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

root = Path(sys.argv[1]).resolve()
(root / "samples").mkdir(parents=True, exist_ok=True)
rng = random.Random(271835)
fonts = sorted((root / "fonts").glob("*.ttf"))
files = []
for i in range(360):
    f = fonts[i % 3]
    font = ImageFont.truetype(str(f), rng.choice([20, 24, 28, 32]))
    text = (
        string.ascii_uppercase[i % 26]
        if i < 260
        else "".join(rng.choices(string.ascii_uppercase, k=rng.randint(2, 5)))
    )
    if rng.random() < 0.3:
        text = '"' + text
    if rng.random() < 0.3:
        text += rng.choice([".", "...", "!", "?"])
    bounds = font.getbbox(text)
    w = bounds[2] - bounds[0] + 16
    h = bounds[3] - bounds[1] + 12
    im = Image.new("L", (w, h), 255)
    ImageDraw.Draw(im).text((8 - bounds[0], 6 - bounds[1]), text, font=font, fill=0)
    slope = rng.choice([0, 0.15, 0.3])
    pad = int(h * slope) + 2
    im = im.transform(
        (w + pad, h),
        Image.Transform.AFFINE,
        (1, slope, -pad, 0, 1, 0),
        Image.Resampling.BICUBIC,
        fillcolor=255,
    )
    base = root / "samples" / f"char-{i:04d}"
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
train = (root / "train.list").read_text().splitlines() + files[:320]
rng.shuffle(train)
(root / "train-short.list").write_text("\n".join(train) + "\n")
(root / "eval-short.list").write_text(
    (root / "eval.list").read_text() + "\n".join(files[320:]) + "\n"
)
