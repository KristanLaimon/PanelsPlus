# PanelsPlus Test Suite & Panel Detection Benchmark

This directory contains the unit tests, integration specs, real-world datasets, and benchmarking tools for PanelsPlus.

## Architecture Overview

```
tests/
├── *_spec.lua                    # All Lua unit, integration, and dataset specs
├── test_*.py                     # Python scheduler, dataset, and annotator tests
├── helper.lua                    # KOReader module stubs
├── PanelsPlusTestFramework.lua   # Dependency-free Lua assertions and spies
├── run_tests.lua                 # Discovers every *_spec.lua in filename order
├── run_parallel.py               # Schedules Lua jobs and full-volume benchmarks
├── helpers/json.lua              # JSON decoder for annotations and manifests
└── dataset-mangas/               # Dataset assets, evaluators, and reports
    ├── dataset/                  # Manga/comic images and annotations by book
    ├── dataset-textbasedformats/ # EPUB/KEPUB/MOBI fixtures
    ├── dataset_loader.lua        # Image decoding and page-map construction
    ├── dataset_manifest.lua      # Book, page, and annotation discovery
    ├── panel_evaluator.lua       # Detection and reading-order metrics
    └── report/                   # Benchmark reports
```

---

## Running the Tests

### 1. Test Suite
```bash
./run-tests.sh --quick          # Parallel tests, skipping Lua lint/format checks
./run-tests.sh --quicker        # Skip Lua lint/format checks and dataset/benchmark specs
./run-tests.sh --quick -j 2     # Limit to two workers
./run-tests.sh --quick -j 1     # Run jobs sequentially
./run-tests.sh --quick tests/geometry_spec.lua
./run-tests.sh --ocr            # OCR units and annotated Bloom word images
./run-tests.sh --panels         # Panel units and panel datasets
```

The OCR dataset evaluates both the configured English model and the bundled
English model. Set `PANELSPLUS_REQUIRE_DATASETS=1` to require every
annotated word (currently 668 across 35 pages); otherwise missing pages print a
partial-dataset warning. Bundled English text recognition requires at least 95%
matches. Configured models must retain their saved accuracy. Word-box geometry
also requires at least 95%.
Complete evaluations save improvements under `ocr` in the book's
`bestbenchmark.json`, even while the 95% target is still unmet. Subsequent runs
must match or exceed each saved result; exact correct/evaluated counts enforce
this without rounding tolerance. Configured and bundled models have separate
CLI and native records. Partial datasets neither compare nor update these full
dataset records, and explicitly report this limitation.
Text comparisons ignore case and punctuation, except that punctuation-only
annotations require an actual matching transcription and cannot match an empty
OCR result.
For a focused diagnostic run, `PANELSPLUS_OCR_PAGES=6,7` selects 1-indexed pages;
unselected annotations still count toward total coverage, so the run cannot
update full-dataset records or pass `PANELSPLUS_REQUIRE_DATASETS=1`.
`PANELSPLUS_OCR_CANDIDATE=/path/to/tessdata` tests an alternative
`eng_fast.traineddata` through the bundled English path without updating records.
The dataset runner caches decoded pages and found boxes across its three checks.
OCR dataset checks also build the Go worker in `tools/ocr_worker`. With cgo and
the Tesseract, Leptonica, and ImageMagick 7 development libraries available, it
uses their native APIs: each worker decodes one page at a time and retains at
most two OCR engine handles. Pages run concurrently, and crops from the same
page reuse that decode. ImageMagick's crop/resize/border operations are retained.
Hosts without those libraries use the existing subprocess backend. Go returns raw
recognized text; Lua still runs `WordFinder`, reports failures, and enforces or
updates every benchmark gate. Raw OCR results are content-addressed by the page,
model, tool versions, backend/library identity, helper executable, crop, and render size in
`tests/dataset-mangas/.cache/ocr-results-v1.json`, making unchanged follow-up
runs nearly instant without accepting stale results after an input changes.
Results stream back as they finish and are atomically checkpointed every 64
successful crops and at each stage boundary. Failed jobs are not cached;
completed work survives a later failed or truncated stream. A hard interruption
retains the last completed checkpoint; results still in flight or awaiting that
checkpoint can be recomputed on resume.
`PANELSPLUS_OCR_WORKERS` changes the default of four workers. Set
`PANELSPLUS_DISABLE_GO_OCR=1` to exercise the legacy sequential subprocess path.
`PANELSPLUS_OCR_BACKEND=cli` forces subprocesses, and `native` requires native
libraries instead of falling back. `PANELSPLUS_OCR_PROFILE=1` reports per-stage
wall time, summed worker phase times, decode/init counts, and subprocess counts
to stderr. KOReader native-library OCR checks remain sequential and unchanged.
For repeatable backend comparisons, run
`python3 tools/benchmarking/benchmark_ocr_worker.py --limit 40` after populating
the raw cache. Omit `--limit` to compare every recorded current-image request.
The bundled model was trained on part of this dataset; see
[training and held-out validation details](../tools/ocr_training/README.md).
Set `PANELSPLUS_OCR_TESSDATA=/path/to/tessdata` to compare a particular installed
model instead of the system Tesseract default. These CLI results are a stand-in
for the reader. [OCR_REPORT.md](../OCR_REPORT.md) also documents the native
KOReader OCR benchmark in `tools/benchmarking/benchmark_ocr_native.lua`, its separate accuracy
gates, and the limits of both measurements.

Python tests are discovered together with `python -m unittest discover -s tests -p "test_*.py"`.
Go worker tests remain beside their Go package in `tools/ocr_worker`.

The shell runner requires Python 3.9+ and defaults to at most four Lua workers.
Each full-volume production benchmark runs in its own process. Golden-page and
per-manga specs run as separate jobs; ordinary unit tests stay together. All
pages and accuracy gates are retained. Output is grouped by completed job, with
elapsed times and a failing exit status if any worker fails. More workers use
more memory. ImageMagick and Tesseract default to one thread per worker;
explicit `MAGICK_THREAD_LIMIT` and `OMP_THREAD_LIMIT` values are respected.

`lua tests/run_tests.lua` still runs the complete suite sequentially without the
Python scheduler. It also accepts one or more spec paths for targeted runs.
Full local volumes can take minutes; public clones skip unavailable volumes.
For the complete shell runner with LuaJIT and native FFI arrays, use
`PANELSPLUS_LUA="luajit -l ffi" ./run-tests.sh --strict`.

### 2. Code Quality and Linter
Formats with StyLua and validates with Luacheck:
```bash
./check.sh
```

---

## Panel Segmentation Benchmark Tool

A dedicated CLI tool (`tools/benchmarking/benchmark_panels.lua`) evaluates panel detection across real manga and comic pages.

Safe and Smart create independent instances of the shared frame pipeline. Safe
then retains enclosing frames and connected vertical stacks conservatively.
Fixed-page crops follow ink bounds; embedded rasters retain one-cell padding.
The legacy gutter detector tries frame extraction when a page remains one crop.

The reader's connected-component detector can be evaluated with
`./run-benchmark.sh --detector components --all`. The default benchmark remains
the original Lua segmenter so its historical `bestbenchmark.json` records stay
comparable.

Component runs evaluate both **Safe** and **Smart** by default. Use
`--algorithm safe`, `--algorithm smart`, or `--algorithm both` to select them.
Complete evaluations keep separate `safe_full_volume` and `smart_full_volume`
records per book, including embedded-image datasets. Each algorithm is compared
with its own annotations and saved baseline. Every mapped volume must exceed
90% precision, recall, F1, matched IoU, and matched-panel reading order, including
challenging and experimental books. Regression runs are read-only;
`--update-best` explicitly records improvements only after the accuracy gates pass.
After reviewing annotation changes, `--establish-baseline` archives records for
changed coverage and establishes new complete-volume records only after every
strict gate passes. It cannot reset a regression with unchanged coverage.
Panel files with `"status": "draft"` are excluded from evaluation. Horimiya's Safe
mapping is currently draft; removing that field enables it after review.

Every discovered annotated volume is evaluated on its mapped pages. Unmapped
pages in unfinished books are excluded. SHY retains its experimental label, but
is subject to the same requested accuracy gates.

The production detector now retains a wider crop when a proposed split lacks
sufficient evidence. Reader and dataset maps include the same dark-stroke and
structural-ink layers. See [the stability report](dataset-mangas/report/panel-stability-2026-10-03.md)
for all eight volumes, false-positive counts, and the recall tradeoff.
Current regression checks use `safe_full_volume` and `smart_full_volume`; historical
`components_conservative_full_volume`, `components_full_volume`, and OCR records remain intact. Tests guard precision, recall,
F1, mean IoU and false positives without rewriting records. Preserving a
historical record alone does not satisfy the separate strict accuracy gates.

Run `PANELSPLUS_REQUIRE_DATASETS=1 lua tests/run_tests.lua` to require all private
page images. Otherwise unavailable full-volume production checks are reported
as skipped. The loader keeps one page map in memory; under LuaJIT it uses the
same byte-array storage as the reader. Preload real FFI for a native-array run:
`luajit -l ffi tests/run_tests.lua`.

To compare detector outputs with the saved full-volume baseline implementation:

```bash
git show 6086013:src/_smartcomponentdetector.lua > /tmp/smart-reference.lua
git show 6086013:src/_safecomponentdetector.lua > /tmp/safe-reference.lua
MAGICK_THREAD_LIMIT=1 luajit tools/benchmarking/benchmark_component_scan.lua /tmp/smart-reference.lua
MAGICK_THREAD_LIMIT=1 luajit tools/benchmarking/benchmark_component_scan.lua /tmp/safe-reference.lua 10000 safe
```

The second argument optionally limits the run to the first N pages of each book;
the third selects `safe` or `smart` (default), and the fourth filters by book title.
The tool alternates old/new execution order over four runs per page, reports
mean detector CPU time per book, and fails if panel coordinates, ordering, or
fallback decisions differ. Image decoding is outside the timed region. It
retains one page map and separate scratch arrays for the two detectors; it
does not modify benchmark records. These are host detection measurements,
not end-to-end page-turn measurements on an e-reader.

For CPU and allocation measurements with each implementation in a separate
LuaJIT process, use the same saved references and also save the recent Safe:

```bash
git show 6086013:src/_safecomponentdetector.lua > /tmp/recent-safe.lua
MAGICK_THREAD_LIMIT=1 luajit tools/benchmarking/benchmark_component_resources.lua safe /tmp/recent-safe.lua /tmp/smart-reference.lua
MAGICK_THREAD_LIMIT=1 luajit tools/benchmarking/benchmark_component_resources.lua safe
MAGICK_THREAD_LIMIT=1 luajit tools/benchmarking/benchmark_component_resources.lua smart /tmp/smart-reference.lua
MAGICK_THREAD_LIMIT=1 luajit tools/benchmarking/benchmark_component_resources.lua smart
```

This samples five evenly spaced pages from every book, warms each detector,
and measures four calls per page. Temporary allocation is measured separately
with GC stopped for one call; the collector runs normally during CPU timing.
Maximum FFI buffer allocation excludes input maps and decoded images. See
[the restoration and optimization report](dataset-mangas/report/panel-resources-2026-10-16.md)
for results and the remaining accuracy failures.

Host LuaJIT comparison on 2026-09-12 against `c2a2e29` (four runs per
implementation per page; all 764 pages matched exactly):

| Dataset | Pages | Before (ms/page) | After (ms/page) | CPU time reduction |
| --- | ---: | ---: | ---: | ---: |
| Bloom Into You Vol. 8 | 213 | 51.959 | 38.940 | 25.1% |
| Miss Kobayashi's Dragon Maid Vol. 2 | 143 | 50.759 | 38.923 | 23.3% |
| Komi Can't Communicate Vol. 1 | 190 | 58.054 | 42.933 | 26.0% |
| Scott Pilgrim Vol. 5 | 218 | 65.895 | 51.164 | 22.4% |

The change adds no buffers and preserves traversal order and detector settings.
Validation also passed all 241 LuaJIT tests with native FFI and required datasets,
the plain-Lua suite, and 400 randomized old/new comparisons including hole
detection and changing map dimensions. No benchmark records were rewritten.
Total KOReader memory use and page-turn latency on a 300 MB device still need
hardware measurement.

### Evaluate the Curated Golden Set
```bash
lua tools/benchmarking/benchmark_panels.lua
```

### Evaluate Every Discovered Dataset
```bash
lua tools/benchmarking/benchmark_panels.lua --all
```

### Evaluate a Specific Book or Page
```bash
lua tools/benchmarking/benchmark_panels.lua --book tojime_no_siora
lua tools/benchmarking/benchmark_panels.lua --book rasetugari --page 1
```

### Strict Matching & Failures Only
```bash
lua tools/benchmarking/benchmark_panels.lua --threshold 0.75 --failures-only
```

---

## Evaluation Metrics Explained

The benchmark calculates standard computer vision evaluation metrics:
- **IoU (Intersection over Union)**: Overlap area divided by union area of detected vs ground-truth bounding box.
- **Precision**: Fraction of detected panels that matched a ground-truth panel ($\text{IoU} \ge 0.5$).
- **Recall**: Fraction of ground-truth panels successfully detected ($\text{IoU} \ge 0.5$).
- **F1 Score**: Harmonic mean of Precision and Recall ($2 \times \frac{P \times R}{P + R}$).
- **Reading Order**: Verifies top-to-bottom/right-to-left ordering for manga and top-to-bottom/left-to-right ordering for comics.

---

---

## Manga Panel Annotator & Private Dataset

A PyQt6 desktop annotator application is provided to build custom ground-truth manga/comic datasets by hand:

```bash
# Launch annotator app
./start-manga-annotator.sh

# Or launch directly with a comic file
./start-manga-annotator.sh path/to/manga.cbz
```

### Supported Formats
- Comic archives: `.cbz`, `.cbr` (via `unrar` / `bsdtar`)
- Documents: `.pdf`, `.epub`, `.kepub.epub`, `.mobi` (via `PyMuPDF`)
- Image collections: folders of `.jpg`, `.jpeg`, `.png`, `.webp`

---

## Licensing & Compliance

- MIT License. Found in `LICENSE` file here.
