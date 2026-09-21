# PanelsPlus Test Suite & Panel Detection Benchmark

This directory contains the unit tests, integration specs, real-world datasets, and benchmarking tools for PanelsPlus.

## Architecture Overview

```
tests/
├── PanelsPlusTestFramework.lua    # Dependency-free Lua test framework (describe, it, assert)
├── dataset-mangas/                # Manga evaluation suite & OpenMantra dataset
│   ├── dataset/                   # OpenMantra Dataset (214 pages, 1,069 annotated frames)
│   │   ├── annotation.json        # Ground-truth frames and text annotations
│   │   └── images/                # 5 series: tojime_no_siora, balloon_dream, tencho_isoro, etc.
│   ├── dataset_loader.lua         # Converts image files into PPPageMap using ImageMagick streaming
│   ├── dataset_manifest.lua       # Indexes books, pages, and ground truth from datasets
│   ├── panel_evaluator.lua        # Calculates IoU, Precision, Recall, F1, and Reading Order
│   └── report/                    # Architectural benchmarks & detection improvement reports
├── helpers/
│   └── json.lua                   # Pure-Lua JSON decoder for manifests and annotations
├── run_tests.lua                  # Primary test runner (executes all spec files)
└── spec/                          # Unit and integration specifications
    ├── dataset_benchmark_spec.lua # Golden manga regression spec (<1.5s)
    └── ...
```

---

## Running the Tests

### 1. Test Suite
```bash
./run-tests.sh --quick          # Parallel tests, skipping Lua lint/format checks
./run-tests.sh --quicker        # Skip Lua lint/format checks and dataset/benchmark specs
./run-tests.sh --quick -j 2     # Limit to two workers
./run-tests.sh --quick -j 1     # Run jobs sequentially
./run-tests.sh --quick tests/spec/geometry_spec.lua
```

The shell runner requires Python 3.9+ and defaults to at most four Lua workers.
Each full-volume production benchmark runs in its own process. Golden-page and
per-manga specs run as separate jobs; ordinary unit tests stay together. All
pages and accuracy gates are retained. Output is grouped by completed job, with
elapsed times and a failing exit status if any worker fails. More workers use
more memory. ImageMagick defaults to one thread per worker; an explicit
`MAGICK_THREAD_LIMIT` is respected.

`lua tests/run_tests.lua` still runs the complete suite sequentially without the
Python scheduler. It also accepts one or more spec paths for targeted runs.
Full local volumes can take minutes; public clones skip unavailable volumes.

### 2. Code Quality and Linter
Formats with StyLua and validates with Luacheck:
```bash
./check.sh
```

---

## Panel Segmentation Benchmark Tool

A dedicated CLI tool (`tools/benchmark_panels.lua`) evaluates panel detection across real manga and comic pages.

The reader's connected-component detector can be evaluated with
`./run-benchmark.sh --detector components --all`. The default benchmark remains
the original Lua segmenter so its historical `bestbenchmark.json` records stay
comparable.

Every local volume has a separate `components_full_volume` production baseline.
Tests guard precision, recall, F1, and mean IoU to the four-decimal record
precision, without rewriting records. A passing regression test means scores
were preserved; it does **not** mean every metric reached 95%. The existing
Komi/Scott F1, recall, and IoU gates remain in place, but Scott's precision is
currently below 95%, and Bloom/Kobayashi's recall and F1 are below 95%.

Run `PANELSPLUS_REQUIRE_DATASETS=1 lua tests/run_tests.lua` to require all private
page images. Otherwise unavailable full-volume production checks are reported
as skipped. The loader keeps one page map in memory; under LuaJIT it uses the
same byte-array storage as the reader. Preload real FFI for a native-array run:
`luajit -l ffi tests/run_tests.lua`.

To compare component detection speed and exact output against the revision
before the neighbor-scan optimization:

```bash
git show c2a2e29:src/_componentdetector.lua > /tmp/component-reference.lua
MAGICK_THREAD_LIMIT=1 luajit tools/benchmark_component_scan.lua /tmp/component-reference.lua
```

An optional final argument limits the run to the first N pages of each book.
The tool alternates old/new execution order over four runs per page, reports
mean detector CPU time per book, and fails if panel coordinates, ordering, or
fallback decisions differ. Image decoding is outside the timed region. It
retains one page map and separate scratch arrays for the two detectors; it
does not modify benchmark records. These are host detection measurements,
not end-to-end page-turn measurements on an e-reader.

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
lua tools/benchmark_panels.lua
```

### Evaluate Every Discovered Dataset
```bash
lua tools/benchmark_panels.lua --all
```

### Evaluate a Specific Book or Page
```bash
lua tools/benchmark_panels.lua --book tojime_no_siora
lua tools/benchmark_panels.lua --book rasetugari --page 1
```

### Strict Matching & Failures Only
```bash
lua tools/benchmark_panels.lua --threshold 0.75 --failures-only
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
python3 tests/dataset-mangas/annotator.py

# Or launch directly with a comic file
python3 tests/dataset-mangas/annotator.py path/to/manga.cbz
```

### Supported Formats
- Comic archives: `.cbz`, `.cbr` (via `unrar` / `bsdtar`)
- Documents: `.pdf`, `.epub`, `.kepub.epub`, `.mobi` (via `PyMuPDF`)
- Image collections: folders of `.jpg`, `.jpeg`, `.png`, `.webp`

---

## Licensing & Compliance

- MIT License. Found in `LICENSE` file here.
