# Panels+ OCR investigation and handoff

## Follow-up: optional lightweight English model (2026-09-22)

Implemented an **off-by-default** `Panels+ → Lightweight English OCR` option.
It uses the official, unmodified `tessdata_fast` English model through KOReader's
existing Tesseract/k2pdfopt library. The model is **4,113,088 bytes (3.92 MiB)**,
bundled in `data/ocr/` with its Apache-2.0 license and source/checksum record.
There is no extra runtime, GPU requirement, or online recognition service.
This is a general English model, not one trained specifically on manga.

When enabled and the document OCR language is exactly `eng`, the OCR crop gets
an extra **5% of word height on each horizontal side** (usually about one native
pixel). Vertical extent and the 30px target height stay fixed. The located box
and painted highlight stay unchanged. Page edges clamp the added margin.
Widening the installed model's crop alone did not improve its score.

The model is loaded as `eng_fast`, because k2pdfopt caches its engine by language
name and ignores changes to the model directory. A distinct name lets it switch
back to normal `eng` correctly. Other languages, including `eng+spa`, retain the
configured model. A missing bundled file retains installed English; a failed or
empty native OCR call falls back to document OCR. Existing retry behavior remains:
one wider retry after an implausible result, with no annotation-based substitutions.

### Results with all 60 current annotations

| Evaluation | Installed/system English | Optional fast English |
| --- | ---: | ---: |
| Word-box geometry | 60/60 | 60/60 (same boxes) |
| KOReader native OCR library, current `readWord` flow | 43/60 (71.7%) | **47/60 (78.3%)** |
| Tesseract CLI stand-in, historical resize behavior | 42/60 (70%) | 42/60 (70%) |
| Desktop OCR CPU time, native run | 0.562s / 68 calls | 0.335s / 62 calls |

Scores ignore case and punctuation, as before. The native run now executes
`findWordBox` and the complete production `readWord`/fallback/retry flow, using
KOReader's actual OCR library with an ImageMagick stand-in for page rendering.
This differs from the earlier one-crop native probes and their 42/60 result.
The CLI and native renderer stand-ins have different resize rounding, model
configuration, and OCR implementations; their scores must remain separate.
**The CLI does not reproduce the native gain. Neither is an end-to-end device test.**

CPU times include model initialization but exclude image decoding/rendering and
reader UI work. They are one desktop measurement, not Kobo latency or RAM usage.
The actual reader may switch models between its initial word selection and the
Panels+ refinement, so model initialization costs can recur for each lookup.
No real-device peak-memory or architecture compatibility measurement was made.
The smaller data file does not by itself establish the amount of RAM saved.

The remaining native misses with the optional model are: page 6 `I` (three
instances), `EPISODE`, `FORTY`; page 7 `"I` (four instances), `NANAMI-`, `SENPAI`,
`I`, `WON'T`. Several are isolated glyphs that lack useful context. 60/60 text
recognition remains unmet, and the sample still covers only one English manga.

### Reproduce

The regular OCR suite evaluates both model choices:

```sh
OMP_THREAD_LIMIT=1 PANELSPLUS_REQUIRE_DATASETS=1 ./run-tests.sh --ocr -j 1
```

To choose the installed model for the CLI comparison, also set
`PANELSPLUS_OCR_TESSDATA=/path/to/koreader/data/tessdata`. Otherwise the first
comparison uses the system Tesseract model. The bundled-model test always uses
the model shipped with the plugin.

Run the native-library benchmark from the KOReader installation directory
(replace the absolute plugin/model paths for your installation):

```sh
cd /usr/lib/koreader
PANELSPLUS_OCR_NATIVE=1 \
PANELSPLUS_REQUIRE_DATASETS=1 \
PANELSPLUS_OCR_TESSDATA=/home/kristanlaimon/.config/koreader/data/tessdata \
luajit /home/kristanlaimon/.config/koreader/plugins/panels_plus_development.koplugin/tools/benchmark_ocr_native.lua
```

Without `PANELSPLUS_REQUIRE_DATASETS=1`, missing annotated pages now produce an
explicit `PARTIAL OCR DATASET` warning. The text tests enforce separate measured
baselines: CLI 42/60 for both choices; native 43/60 installed and 47/60 bundled.
Partial sets use proportional floors and cannot establish the full dataset score.
Images remain gitignored; no new manga images were added.

### Other probes and choice of margin

Direct one-crop native probes with the installed model gave 42/60 tight and
42/60 with 5% horizontal padding. The fast model gave 45/60 tight and 47/60 with
5% horizontal padding. More horizontal padding did not improve that total.
An artificial 3px white border gave 49/60 with fast English, but it was not
shipped: it needs additional bitmap handling and polarity validation beyond
these white speech bubbles. Increasing crop height to 40px did not help; reducing
to 20px gave different errors rather than a consistent improvement.

Official references: [model description](https://tesseract-ocr.github.io/tessdoc/Data-Files-in-tessdata_fast.html),
[Tesseract crop/border guidance](https://tesseract-ocr.github.io/tessdoc/ImproveQuality.html),
[KOReader OCR model caching](https://github.com/koreader/libk2pdfopt/blob/master/lib/koptocr.c).
The first two motivate the experiments; the measured dataset results determine
which change was included.

### Files changed in this follow-up

- `src/_wordfinder.lua`: optional model selection, distinct model language name,
  and bounded horizontal OCR margin.
- Settings/menu/viewer plumbing: persist the option and pass it to word lookup.
- `data/ocr/`: model, license, and source/checksum documentation.
- `build.sh` and `build.ps1`: include model data in plugin packages.
- OCR specs: model routing, page bounds, selection stability, language isolation,
  missing-file/error fallback and cleanup, both dataset model comparisons,
  stricter accuracy gates, and explicit dataset completeness.
- `tools/benchmark_ocr_native.lua`: reproducible native-library dataset runner.

### Validation of the follow-up

- Focused OCR suite: **67 unit checks + 3 dataset checks passed** with all 60 words.
- Native OCR runner: **3 dataset checks passed**, installed 43/60 and bundled 47/60.
- Targeted StyLua, Luacheck, and `git diff --check`: passed without warnings.
- Shell package build: passed; model and license in the built package match the
  source files byte for byte. The PowerShell build change was inspected but not
  executed on this Linux host.
- Python runner/data tests: 7 run, 1 skipped, no failures.
- Broader Lua unit run: 261 passed, 1 failed. The unchanged
  `native_panel_zoom_spec.lua` mock lacks `opensOnHold`; the same failure occurs
  when that spec runs alone. No OCR changes touch that code or spec.
- Annotator tests with a headless Qt theme: 37 passed, 1 failed because Bloom
  dataset metadata is not marked `finished`. Neither that test nor the annotation
  was changed. The first generic quick-suite attempt stopped earlier on a GTK
  display error; clearing the Qt platform theme allowed this check to run.
- Full panel datasets and physical KOReader devices were not tested in this pass.

## Earlier investigation (before the optional model)

The following records the earlier work and its original results. Statements
about no model being bundled describe that earlier state.

Updated: 2026-09-22. This report covers **word lookup OCR**, not panel detection. The goal discussed with the user is to move the 60 annotated Bloom Into You words from 38/60 toward 60/60 while retaining Kobo and other KOReader device support. The current result is **60/60 located word boxes and 42/60 recognized words** in the local test. The text goal has **not** been met.

## What Panels+ does

Panels+ does not ship or train a separate OCR engine. `src/_wordfinder.lua` finds the tapped word's rectangle in a raster page. KOReader's bundled k2pdfopt/Tesseract OCR then converts that image crop to text. `src/_panelviewer.lua` passes the result to the normal selection, dictionary, and highlight flow. An accurate rectangle cannot guarantee an accurate transcription: stylized comic glyphs can still be confused by the recognizer.

KOReader's installed `frontend/document/koptinterface.lua` has `getNativeOCRWord`, which expands a word rectangle by `floor(rect.h * 0.3)` on **all four sides**, renders it at `30 / rect.h` zoom, and calls `getTOCRWord` with `ocr_type = -1` by default (a uniform text block). On manga lettering, the extra margin can bring in adjacent words. The new `WordFinder.ocrWord` path uses KOReader's existing `createContext`, page renderer, and `getTOCRWord` directly, passing the **exact found rectangle** and OCR mode **8** (single word). It still uses KOReader's bundled language data, works offline, and falls back to `document:getOCRWord` if the direct path is unavailable or yields no text. `WordFinder.cleanup` also releases the direct OCR engine on viewer close.

`WordFinder.readWord` accepts a plausible first result. If that result is empty or implausible, it retries with 25% padding. It does **not** compare several plausible candidates or consult the annotation. A plausible but wrong result such as `Sove` for `Love` is returned unchanged. That distinction matters for future work.

## Dataset and reproducible checks

The annotated labels are in `tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/annotation.json`. The 60 word entries are on page indices **2 (3 words), 5 (3), 6 (29), and 7 (25)**. The pages are 1264 by 1680 pixels. The local PNGs are available but most are deliberately gitignored for copyright reasons. A clean checkout may not have the same images and therefore may evaluate fewer than 60 words. Do not add these images to the repository or claim a 60-word score from a partial checkout.

The new `bloom_ocr_spec.lua` has two independent checks:

1. Tap the center of each annotated word, run `WordFinder.findWordBox`, and check the resulting rectangle. A match needs at least **75% of the annotation area covered** and at most **80% extra area** relative to the annotation. This is a geometric tolerance, not an exact rectangle match.
2. Run `WordFinder.readWord` on that rectangle with a local `magick` + Tesseract CLI stand-in for the KOReader OCR call. Compare after uppercasing and removing nonalphanumeric characters. Thus the **42/60 text score ignores case and punctuation**; it is not an exact transcription score. The spec currently only requires at least 50% text matches to pass, so a green test does **not** mean the 60/60 target is achieved.

Run the focused suite with `./run-tests.sh --ocr -j 1`. It includes WordFinder, OCR debug, selection integration unit specs, and the annotated word dataset. `./run-tests.sh --panels` runs the remaining Lua specs and panel datasets. `./run-tests.sh` without a focus flag retains its complete test flow, including style, Python, and all Lua specs. This investigation intentionally ran **OCR only**, not the panel suite. The dataset spec needs the local `magick` and `tesseract` commands and the relevant PNGs. The CLI currently finds `/usr/share/tessdata/eng.traineddata`; KOReader's configured data path on this machine contains a **different** English model, so the CLI result is a proxy rather than an identical engine configuration.

## Results on this machine

The final `./run-tests.sh --ocr -j 1` run passed **61 OCR-related unit examples** and **2 Bloom dataset checks**. Geometry: **60/60**. Text: **42/60 (70%)** using the CLI stand-in. The initial local CLI baseline was **38/60**, so this is a four-word improvement under that proxy. No end-to-end Kobo measurement has been made. The direct kopt/Tesseract probe described below also read **42/60**, supporting the direction of the change but not establishing cross-device parity.

Reproduction environment: KOReader `v2026.07.1`, Tesseract CLI `5.5.3`, ImageMagick `7.1.2-31`, and Lua `5.5.1`. The configured KOReader English model SHA-256 was `8280aed0782fe27257a68ea10fe7ef324ca0f8d85bd2fd145d1c2b560bcb66ba`; the system English model used by the CLI was `daa0c97d651c19fba3b25e81317cd697e9908c8208090c94c3905381c23fc047`. Scores may change with a different image set, model, renderer, or Tesseract version.

The 18 text misses from the final local run are below. `nil` means WordFinder rejected or received no usable recognition result; other strings are plausible OCR results that were wrong. Page numbers are annotation page indices.

| Page | Expected | Read |
| --- | --- | --- |
| 6 | `I` | `nil` |
| 6 | `Love` | `Sove` |
| 6 | `EPISODE` | `EPrsope` |
| 6 | `FORTY` | `roB"‘` |
| 6 | `TO` | `nil` |
| 6 | `TO` | `nil` |
| 6 | `I` | `T` |
| 7 | `"I` | `v` |
| 7 | `TO` | `nil` |
| 7 | `NANAMI-` | `NANAM/-` |
| 7 | `SENPAI` | `SENFA/` |
| 7 | `I` | `z` |
| 7 | `"I` | `“r` |
| 7 | `WON'T` | `nil` |
| 7 | `FALL` | `nil` |
| 7 | `"I` | `r` |
| 7 | `TO` | `nil` |
| 7 | `"I` | `nil` |

Additional checks passed: `python3 -m unittest tests.test_parallel_runner` (4 tests), targeted `luacheck` (zero warnings/errors), `stylua --check` on changed Lua files, and `git diff --check`. Panel tests were not run in this OCR-only pass.

## Changes made

- `run-tests.sh`, `tests/run_parallel.py`, `tests/test_parallel_runner.py`, and `tests/README.md`: separate `--ocr` and `--panels` modes while preserving the no-argument full run.
- `tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/bloom_ocr_spec.lua`: exercise real annotated word geometry and local OCR text on available PNGs. The fake document emulates KOReader's tight native context; the CLI is a stand-in, not the actual app process.
- `src/_wordfinder.lua`: improve sparse gap calibration, split suspiciously tall text lines, retain small trailing punctuation runs, tighten the vertical runaway cap, and use a tight single-word native OCR path with fallback.
- `tests/spec/wordfinder_spec.lua`: cover the new native OCR crop and mode choice.

## OCR experiments and lessons

These were **local probes**, not product features or separate dependencies. They used the annotated words and recreated crops with the installed KOReader `ffi/koptcontext.lua` and `libk2pdfopt`, or with Tesseract CLI. The native probe scripts and temporary word-box TSV were kept under `/tmp`; they are not durable project artifacts. The report records their useful conclusions.

| Local configuration | Case/punctuation insensitive matches | Interpretation |
| --- | ---: | --- |
| KOReader-style 30% padded crop, OCR mode `-1`, installed 15 MB English data | 22/60 | A broad crop and block mode perform poorly for these isolated words. |
| Tight crop, OCR mode `8`, same English data, 30px target height | 42/60 | Best simple native configuration tried at KOReader's current target height. |
| 15% crop padding, OCR mode `8`, 30px | 42/60 | Padding did not improve the total. |
| 25% crop padding, OCR mode `8`, 30px | 39/60 | More neighboring ink tends to hurt. |
| Tight crop, OCR mode `8`, 20px target height | 44/60 | A small local improvement, but different errors; not shipped without broader regression evidence. |
| Tight crop, OCR mode `8`, local 23 MB `/usr/share/tessdata/eng.traineddata` | 40/60 | File size alone did not improve recognition. |

Simple thresholding and crop variants topped out around **44/60**. An oracle that could choose the correct answer among four tested OCR variants would still have reached only **48/60**. This is evidence that further tuning of gap thresholds, crop padding, or Tesseract page segmentation alone is unlikely to produce 60/60 on this sample. Longer phrase OCR sometimes helped but still confused short glyphs, such as `TO` with `70` and `I` with `T`.

The installed 15 MB language file at `~/.config/koreader/data/tessdata/eng.traineddata` appeared to contain a larger floating-point LSTM than the local 23 MB system file, which also contained legacy components. Do not equate `.traineddata` byte size with recognition quality. No model was added, downloaded, or packaged. A brief search for larger manga OCR models was exploratory after the user raised the possibility; it did not result in a dependency. A model with a desktop-only runtime or large memory demand cannot simply be assumed to work on Kobo. The existing approach keeps the KOReader OCR runtime and language data.

A headless attempt to load a complete `PdfDocument` outside KOReader's initialized app runtime crashed that probe process. Direct `KOPTContext:getTOCRWord` probes worked. That crash does **not** establish a crash in Panels+ or KOReader; the app path still needs a real device or full KOReader runtime check.

## Remaining work for a future session

1. **Validate on a real Kobo or supported KOReader device.** Confirm rendering the exact bbox, mode 8 support, OCR language selection, memory use, and the fallback path. The present dataset fakes the document renderer, and the kopt probe manually recreates crops.
2. **Instrument recognition errors before changing more heuristics.** Record found box, exact rendered crop, OCR raw text, retry text, and selection result. Separate segmentation mistakes from glyph recognition and from `isPlausibleWord` accepting a wrong candidate. Avoid storing copyrighted page images in Git.
3. **Expand the evaluation set.** Sixty annotated words from four pages of one English manga volume are too narrow to establish general accuracy. Include other fonts, page types, languages, and low-resolution images before changing the 30px target or introducing candidate selection. Preserve the distinction between rectangle score and text score.
4. **If 60/60 text remains a hard requirement, investigate a device-compatible recognition improvement.** Possibilities include a small comic-lettering-specific English model or on-device candidate scoring with surrounding text. Measure actual memory, latency, architecture support, and licenses before adopting one. Do not hardcode the annotated answers or apply book-specific substitutions merely to increase this test score.
5. **Make dataset completeness explicit if desired.** Since most PNGs are gitignored, the spec measures only available pages and requires at least one word. A future runner could print an explicit partial-dataset warning or require all four annotated page images and 60 labels in a local full-dataset mode. This prevents interpreting a partial checkout's result as 60-word coverage.

The present test can establish that the WordFinder box is consistently close to these annotations and that the local recognition proxy improved from 38 to 42 words. It cannot establish 60/60 recognition, broad manga accuracy, or identical Kobo behavior.
