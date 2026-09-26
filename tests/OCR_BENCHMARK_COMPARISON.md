# Panels+ English OCR benchmark: before and now

Measured on 2026-09-26. This compares the word recognition code from commit
`1bf5d32` (2026-09-22, before the bundled OCR model and subsequent OCR work)
with current commit `aa71068` (11 commits later). Both versions were run against
the **same current annotations and page images** from *Bloom Into You, Vol. 8*.
The historical run loaded that commit's `src/_wordfinder.lua` into the current
benchmark harness. It did not reconstruct an entire old KOReader installation.

## Results

The score is exact annotated-word agreement after the benchmark's case and
punctuation normalization. A word counts as incorrect if Panels+ cannot find a
box or OCR returns the wrong text. “KOReader English” means the installed
`eng.traineddata`; “fine-tuned English” means Panels+'s `eng_fast.traineddata`.

| OCR path | Full development set (668 words) | Pages held out from model training (123 annotations) |
| --- | ---: | ---: |
| Before (`1bf5d32`), KOReader English | 263/668 **39.37%** | 42/123 **34.15%** |
| Now (`aa71068`), KOReader English | 580/668 **86.83%** | 106/123 **86.18%** |
| Now (`aa71068`), fine-tuned English | 639/668 **95.66%** | 117/123 **95.12%** |

Holding the English model fixed, the newer Panels+ word-finding and OCR path
adds **317 matches (+47.46 percentage points)** on the full set and **64
matches (+52.03 points)** on the held-out pages. Holding the current code fixed,
switching from KOReader English to fine-tuned English adds **59 matches (+8.83
points)** and **11 matches (+8.94 points)**, respectively. The combined change
from the historical path to the current fine-tuned path is **+376/668 words**
on the full set and **+75/123** on the held-out pages.

The separate word-box check improved from **368/668 (55.09%)** to **637/668
(95.36%)** on the full set, and from **68/123 (55.28%)** to **116/123 (94.31%)**
on the held-out pages. This check measures finding the annotated word region,
before model choice can affect recognition. The held-out-page geometry result is
below the current 95% acceptance threshold even though the full-set result
passes it.

## Models and benchmark conditions

| Model | File | Size | SHA-256 |
| --- | --- | ---: | --- |
| KOReader installed English | `~/.config/koreader/data/tessdata/eng.traineddata` | 15,400,601 bytes | `8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba` |
| Panels+ fine-tuned English | `data/ocr/eng_fast.traineddata` | 5,199,098 bytes | `6e7142edd0954fb1b3a2aad0a26eb6dcfb8801f17c1996d6fc4269f7478c8063` |

The installed KOReader file matches the pinned `tessdata_best` English base
model used to train the Panels+ model; it is not the smaller upstream
`tessdata_fast` English model. Both choices use KOReader's native
k2pdfopt/Tesseract OCR library. The harness uses ImageMagick for page and crop
rendering and a fake document for word selection. It does not run the full
reader UI or measure physical e-reader latency. OCR CPU timing excludes crop
rendering and therefore is not a user-visible speed comparison.

The full 668-word set spans 35 annotated pages. It includes 545 word crops
used to fine-tune the model, so **95.66% is a development score**. Pages 5, 10,
15, 20, 25, 30, 35, and 45 supplied 121 crops excluded from training; the
benchmark has 123 annotations on those pages because two punctuation-only
labels were not training crops. Those pages are a better comparison for the
model, although all pages informed word-box and crop tuning. Results from one
English manga do not establish accuracy on unseen books, other languages, or
reader hardware.

## Reproduction

Run from `/usr/lib/koreader` with `PANELSPLUS_OCR_NATIVE=1`,
`PANELSPLUS_OCR_TESSDATA=~/.config/koreader/data/tessdata`, and
`OMP_THREAD_LIMIT=1`. The current benchmark entry point is
`tools/benchmark_ocr_native.lua`. For the held-out-page check, also set
`PANELSPLUS_OCR_PAGES=5,10,15,20,25,30,35,45`; omit it for the full set.
`PANELSPLUS_OCR_CANDIDATE` was set to this plugin's `data/ocr` directory during
these runs so the benchmark did not update `bestbenchmark.json`.

For the before run, extract `src/_wordfinder.lua` from `1bf5d32` and preload it
as `src._wordfinder` after `tests.spec.helper` but before loading the current
`bloom_ocr_spec.lua`. Skip that spec's bundled-model case, since the historical
code had no bundled model. This keeps the dataset, fake document, normalization,
and OCR library identical across runs. The old word-box check fails today's
95% gate as expected; its count and text score are still recorded above.

The raw run logs from this measurement are
`/tmp/panels_ocr_before_full.log`, `/tmp/panels_ocr_now_full.log`,
`/tmp/panels_ocr_before_holdout.log`, and `/tmp/panels_ocr_now_holdout.log`.
See [OCR_REPORT.md](OCR_REPORT.md) and
[tools/ocr-training/README.md](tools/ocr-training/README.md) for the earlier
milestones and training recipe.
