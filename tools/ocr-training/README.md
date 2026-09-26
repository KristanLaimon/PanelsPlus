# Bundled English OCR training

The bundled `eng_fast.traineddata` is an integer model fine-tuned from
[Tesseract's English `tessdata_best`](https://github.com/tesseract-ocr/tessdata_best/blob/main/eng.traineddata)
on annotated Bloom word crops. The historical filename preserves the separate
language name used by KOReader's model cache. The recipe creates a candidate in
a separate directory; it does not install it or change benchmark records.

Training used Tesseract 5.5.3, Leptonica 1.87.0, Python 3 and Pillow 12.3.0.
Install Tesseract's training programs and Pillow. Supply the local dataset
images and the upstream floating-point English model:

```sh
bash tools/ocr-training/train-annotated.sh \
  tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8 \
  /path/to/tessdata_best/eng.traineddata \
  /tmp/panelsplus-ocr-training-new
```

## Training and validation

`generate_annotated.py` creates 666 crops from the 668 annotations, excluding
the two punctuation-only labels. It pads each annotation by 10% of its height
(at least three pixels), inverts predominantly dark crops, resizes to 40 pixels
high, and adds an eight-pixel white border. The input pages and labels are not
modified. Missing page images fail the generation step.

Every fifth page is held out: pages 5, 10, 15, 20, 25, 30, 35, and 45 contribute
**121 validation crops**. The other pages contribute **545 training crops**.
The shuffle seed is `9262026`. Training runs for 1,000 iterations at learning
rate `0.0001`, then converts the selected checkpoint to an integer model.
`input_manifest.json` in the output directory records annotation/image hashes,
the split, and the exact training and validation sample order.

The floating checkpoint measured **0.826% character error and 0.826% word error**
with `lstmeval` on the 121 held-out crops. The previous bundled synthetic model
measured 12.887% character error and 17.355% word error on these same crops.
The deployed integer model measured **3.030% character error and 3.306% word error**
after quantization.
This validates recognition of supplied crops, separately from finding a word
under a tap on a complete page.

The full 668-word benchmark includes training samples. Its results are therefore
development scores. The held-out crops were excluded from model training, but
all pages have informed crop/segmentation tuning; neither metric establishes
accuracy on unseen books. Private page images and generated crops are not shipped.

Test a candidate through the complete pipeline without replacing the bundled
model or updating saved scores:

```sh
OMP_THREAD_LIMIT=1 PANELSPLUS_REQUIRE_DATASETS=1 \
  PANELSPLUS_OCR_CANDIDATE=/tmp/panelsplus-ocr-training-new/candidate \
  ./run-tests.sh --ocr -j 1
```

The same candidate variable works with `tools/benchmark_ocr_native.lua`.
Integer conversion, platform differences, and training nondeterminism can
affect results; run both CLI and native checks before installing a reproduction.

## Source integrity and licensing

The annotated recipe verifies the supplied base model against its pinned
SHA-256. This model was built with the following inputs:

| Input | SHA-256 |
| --- | --- |
| `tessdata_best/eng.traineddata` | `8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba` |
| Bloom `annotation.json` | `b127c21a0e988eee5fc39ac3c091b0c3bef88ba6b006201fdcb0c83acd3bad5d` |
| Output `eng_fast.traineddata` | `6e7142edd0954fb1b3a2aad0a26eb6dcfb8801f17c1996d6fc4269f7478c8063` |

The base model and resulting model use the Apache-2.0 license in
[`data/ocr/LICENSE`](../../data/ocr/LICENSE).

## Historical synthetic recipe

`train.sh`, `generate_words.py`, and `generate_characters.py` retain the previous
recipe: 600 synthetic dictionary lines and 360 isolated letters/random strings
rendered with Bangers Regular, Kalam Bold, and Comic Neue Bold Italic. It used
860 training images and 100 held-out synthetic images, without reading manga
pages or labels. Its floating checkpoint measured 3.947% character error and
8.000% word error on that synthetic validation set.

That script pins the downloaded model and font hashes. Its OFL font licenses
remain in [`licenses/`](licenses/). It reproduces a historical candidate rather
than the model currently bundled with the plugin.
