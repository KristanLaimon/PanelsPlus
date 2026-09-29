# SPDX-License-Identifier: MIT
"""Prepare annotated word crops, holding out every fifth page from training."""

import argparse
import hashlib
import json
import math
import os
import random
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from PIL import Image, ImageOps


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("book", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    book, root = args.book.resolve(), args.output.resolve()
    samples = root / "samples"
    samples.mkdir(parents=True, exist_ok=True)
    annotation = book / "annotation.json"
    pages = json.loads(annotation.read_text())[0]["pages"]
    records, image_hashes = [], {}
    for page in pages:
        if not page.get("word"):
            continue
        source = book / f"{page['page_index'] - 1:02}.png"
        # Missing pages must fail rather than silently change the training set.
        image_hashes[source.name] = checksum(source)
        with Image.open(source) as original:
            im = original.convert("L")
        for index, word in enumerate(page["word"]):
            label = word["text"]
            if (
                not label.isascii()
                or not any(c.isalnum() for c in label)
                or len(label) > 22
            ):
                continue
            x, y, w, h = (word[k] for k in ("x", "y", "w", "h"))
            pad = max(3, round(h * 0.10))
            crop = im.crop(
                (
                    max(0, math.floor(x - pad)),
                    max(0, math.floor(y - pad)),
                    min(im.width, math.ceil(x + w + pad)),
                    min(im.height, math.ceil(y + h + pad)),
                )
            )
            if crop.width < 3 or crop.height < 3:
                raise ValueError(
                    f"Invalid word crop on page {page['page_index']}, word {index}"
                )
            count, median = 0, 255
            for value, frequency in enumerate(crop.histogram()):
                count += frequency
                if count > crop.width * crop.height // 2:
                    median = value
                    break
            if median < 115:
                crop = ImageOps.invert(crop)
            height = 40
            width = max(1, round(crop.width * height / crop.height))
            crop = crop.resize((width, height), Image.Resampling.LANCZOS)
            bordered = Image.new("L", (width + 16, height + 16), 255)
            bordered.paste(crop, (8, 8))
            base = samples / f"p{page['page_index']:03d}-w{index:03d}"
            bordered.save(base.with_suffix(".tif"))
            base.with_suffix(".gt.txt").write_text(label + "\n")
            base.with_suffix(".box").write_text(
                "".join(
                    f"{char} 0 0 {bordered.width} {bordered.height} 0\n"
                    for char in label + "\t"
                )
            )
            records.append((page["page_index"], base))

    def convert(record):
        page, base = record
        subprocess.run(
            ["tesseract", str(base) + ".tif", str(base), "--psm", "13", "lstm.train"],
            env={**os.environ, "OMP_THREAD_LIMIT": "1"},
            capture_output=True,
            check=True,
        )
        return page, str(base) + ".lstmf"

    with ThreadPoolExecutor(max_workers=4) as pool:
        converted = list(pool.map(convert, records))
    random.Random(9262026).shuffle(converted)
    train = [path for page, path in converted if page % 5 != 0]
    held_out = [path for page, path in converted if page % 5 == 0]
    (root / "train.list").write_text("\n".join(train) + "\n")
    (root / "eval.list").write_text("\n".join(held_out) + "\n")
    manifest = {
        "annotation_sha256": checksum(annotation),
        "images_sha256": image_hashes,
        "train_samples": [Path(path).stem for path in train],
        "eval_samples": [Path(path).stem for path in held_out],
        "seed": 9262026,
        "holdout_rule": "page_index % 5 == 0",
    }
    (root / "input_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{len(converted)} crops: {len(train)} training, {len(held_out)} held out")


if __name__ == "__main__":
    main()
