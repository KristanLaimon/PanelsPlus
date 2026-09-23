# Bundled OCR language data

Panels+ bundles an English model fine-tuned on synthetic comic lettering and
the unmodified Spanish and Italian models from
[Tesseract's `tessdata_fast`](https://github.com/tesseract-ocr/tessdata_fast)
at revision [`87416418657359cb625c412a48b6e1d6d41c29bd`](https://github.com/tesseract-ocr/tessdata_fast/tree/87416418657359cb625c412a48b6e1d6d41c29bd).
They are compatible with Tesseract 4 and 5 and use KOReader's existing OCR
runtime. The accompanying [LICENSE](LICENSE) is Apache-2.0. The exact file
hashes are in [SHA256SUMS](SHA256SUMS); both build scripts verify them.

| Plugin file | Upstream file | Size |
| --- | --- | ---: |
| `eng_fast.traineddata` | Fine-tuned `tessdata_best/eng.traineddata`, integer conversion | 5,199,098 bytes |
| `spa_fast.traineddata` | `spa.traineddata` | 2,294,433 bytes |
| `ita_fast.traineddata` | `ita.traineddata` | 2,701,314 bytes |

The language names have a `_fast` suffix because KOReader's k2pdfopt OCR
engine caches models by language name without checking the data directory.
This keeps the bundled models separate
from KOReader's installed models when switching between them.

The `panelsplus_with_ocrmodels.koplugin` build includes these three models and always
uses them for zoomed-panel word lookup. English is selected by default; the
panel viewer's **More Config… → OCR language** entries select Spanish or
Italian persistently. The separate `panelsplus.koplugin` build
excludes this directory and uses KOReader's configured OCR language and
`data/tessdata` files. Install only one build. If a bundled model is missing
or cannot be read, Panels+ falls back to KOReader's configured OCR data. An
OCR engine error or empty result falls back to KOReader's document OCR path.

## English model

English was fine-tuned from the Apache-2.0 `tessdata_best` model on synthetic
dictionary text and isolated characters rendered in three OFL fonts. No manga
pages or annotation labels were used as training inputs. The training recipe,
input checksums, validation details, and font licenses are in
[`tools/ocr-training`](../../tools/ocr-training/README.md).

Word lookup compares two render sizes, using a third OCR read on disagreement.
The expanded Bloom development dataset measures 240/266 normalized word matches
(90.2256%) with both the CLI evaluator and KOReader's native OCR library. This
is not a measurement on unseen books or
physical readers. Complete OCR runs save their best scores in the book's
`bestbenchmark.json` and reject lower results.
