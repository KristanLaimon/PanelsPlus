# Bundled OCR language data

Panels+ bundles the unmodified English, Spanish, and Italian models from
[Tesseract's `tessdata_fast`](https://github.com/tesseract-ocr/tessdata_fast)
at revision [`87416418657359cb625c412a48b6e1d6d41c29bd`](https://github.com/tesseract-ocr/tessdata_fast/tree/87416418657359cb625c412a48b6e1d6d41c29bd).
They are compatible with Tesseract 4 and 5 and use KOReader's existing OCR
runtime. The accompanying [LICENSE](LICENSE) is Apache-2.0. The exact file
hashes are in [SHA256SUMS](SHA256SUMS); both build scripts verify them.

| Plugin file | Upstream file | Size |
| --- | --- | ---: |
| `eng_fast.traineddata` | `eng.traineddata` | 4,113,088 bytes |
| `spa_fast.traineddata` | `spa.traineddata` | 2,294,433 bytes |
| `ita_fast.traineddata` | `ita.traineddata` | 2,701,314 bytes |

The language names have a `_fast` suffix because KOReader's k2pdfopt OCR
engine caches models by language name without checking the data directory.
The data inside each file is unchanged. This keeps the bundled models separate
from KOReader's installed models when switching between them.

The `panelsplus_with_ocrmodels.koplugin` build includes these three models and always
uses them for zoomed-panel word lookup. English is selected by default; the
panel viewer's **More Config… → OCR language** entries select Spanish or
Italian persistently. The separate `panelsplus.koplugin` build
excludes this directory and uses KOReader's configured OCR language and
`data/tessdata` files. Install only one build. If a bundled model is missing
or cannot be read, Panels+ falls back to KOReader's configured OCR data. An
OCR engine error or empty result falls back to KOReader's document OCR path.

These are general language models, not manga-trained models. See
[OCR_REPORT.md](../../OCR_REPORT.md) for the English accuracy measurements.
