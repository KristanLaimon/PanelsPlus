# Bundled English OCR training

The bundled `eng_fast.traineddata` is an integer model fine-tuned from
[Tesseract's English `tessdata_best`](https://github.com/tesseract-ocr/tessdata_best/blob/main/eng.traineddata).
The historical filename preserves the separate language name used by KOReader's
model cache. This recipe creates a candidate in a separate working directory;
it does not install it or change benchmark records.

Training used Tesseract 5.5.3, Leptonica 1.87.0, Python 3 and Pillow 12.3.0.
Install Tesseract's training programs, Pillow, and curl before running:

```sh
bash tools/ocr-training/train.sh /tmp/panelsplus-ocr-training
```

## Inputs and separation from evaluation

The first stage creates 600 synthetic text lines from the upstream English
model's dictionary, with Bangers Regular, Kalam Bold, and Comic Neue Bold Italic
fonts. It varies case, punctuation, size, slant, and resampling. The second stage
adds 360 synthetic isolated letters and random short uppercase strings.
Random seeds are fixed in the two generators. Training uses 860 images; a
separate 100-image validation set is never in the training lists.

Neither generator reads manga pages, annotations, benchmark output, or expected
evaluation words. Model/crop choices were selected using the Bloom evaluation
set, so its score is a development benchmark, not an unseen-book estimate.

The final floating checkpoint measured **3.947% character error** and **8.000%
word error** with `lstmeval` on those 100 synthetic validation images. This is
distinct from the manga word-match metric. The deployed integer model is
validated by the OCR dataset tests. Integer conversion, platform differences,
and training nondeterminism can affect results; rerun the full OCR tests before
installing a reproduced model.

## Source integrity and licensing

The script verifies every downloaded binary against these SHA-256 values;
if an upstream URL changes, it fails rather than silently training new inputs.

| Input | SHA-256 |
| --- | --- |
| `tessdata_best/eng.traineddata` | `8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba` |
| `Bangers-Regular.ttf` | `4160a7311de9342674cce9160cde9fcbb30f48190397d86ff1b70b455af65824` |
| `Kalam-Bold.ttf` | `2f6576601db015d4f6c08678120277fc8510b98c06e932ce7a6a9cbff4cbdded` |
| `ComicNeue-BoldItalic.ttf` | `5c312c2a2fa64eee82f3b87fcfab8f3b12a5e59b043124401d322eb323cfbf16` |

The base model and resulting model use the Apache-2.0 license in
[`data/ocr/LICENSE`](../../data/ocr/LICENSE). Fonts come from
[Google Fonts](https://github.com/google/fonts/tree/main/ofl), under the SIL
Open Font License; copies are in [`licenses/`](licenses/). Fonts and generated
training images are not shipped in the plugin.
