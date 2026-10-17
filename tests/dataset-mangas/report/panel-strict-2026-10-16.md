**Strict panel detection evaluation — 2026-10-16**

Historical snapshot of `6086013`. The user subsequently requested stable Safe
from `6a82bc8` and a 90% gate; see the [restoration and resource report](panel-resources-2026-10-16.md).

The requested result is **not achieved**. 10 of 14 mapped algorithm/volume evaluations exceed 95% in every strict accuracy metric. The remaining four evaluations still fail. Horimiya Safe is excluded as requested; its existing rectangles are retained with `"status": "draft"`. SHY has no Safe mapping.

The order column measures relative ordering of matched panel pairs, as enforced by the existing evaluator. Exact page order also requires perfect detection and is a separate diagnostic. Values below are percentages; gates use unrounded values.

| Volume | Algorithm | Pages | Precision | Recall | F1 | IoU | Pair order | Strict accuracy |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Bloom | Safe | 213 | 95.05 | 96.51 | 95.77 | 95.63 | 99.32 | Pass |
| Bloom | Smart | 213 | 95.26 | 96.30 | 95.78 | 95.35 | 99.71 | Pass |
| Chainsmoker | Safe | 214 | 93.64 | 94.79 | 94.21 | 95.48 | 99.14 | Fail |
| Chainsmoker | Smart | 214 | 92.80 | 94.79 | 93.78 | 95.33 | 99.73 | Fail |
| Nagatoro | Safe | 161 | 95.02 | 96.98 | 95.99 | 97.88 | 99.26 | Pass |
| Nagatoro | Smart | 161 | 96.62 | 95.16 | 95.88 | 96.10 | 99.91 | Pass |
| Horimiya | Smart | 181 | 92.26 | 92.63 | 92.44 | 94.76 | 100.00 | Fail |
| Komi | Safe | 190 | 96.07 | 95.69 | 95.88 | 97.62 | 100.00 | Pass |
| Komi | Smart | 190 | 96.08 | 95.09 | 95.58 | 97.27 | 100.00 | Pass |
| Kobayashi | Safe | 143 | 98.08 | 95.26 | 96.65 | 96.67 | 99.57 | Pass |
| Kobayashi | Smart | 143 | 97.93 | 95.79 | 96.85 | 96.82 | 99.83 | Pass |
| SHY | Smart | 179 | 80.90 | 65.37 | 72.31 | 87.57 | 100.00 | Fail |
| Scott Pilgrim | Safe | 218 | 96.70 | 97.62 | 97.16 | 96.60 | 99.46 | Pass |
| Scott Pilgrim | Smart | 218 | 96.47 | 97.62 | 97.04 | 96.63 | 99.88 | Pass |

Changes include shared extraction with conservative Safe grouping, deterministic overlap selection, selective grouping of shared balloons, recovery of detached manga footnotes and compact closed-frame strips, and fixed-page bounds at the detected ink rather than additional detector padding. Viewer margins remain separate. Embedded image maps retain their original one-cell crop padding; EPUB, KEPUB and MOBI regression checks preserve their original records.

All mapped volumes, including challenging and experimental ones, now have the same strict gates. Regression tests are read-only. `--establish-baseline` permits complete passing evaluations to establish records for reviewed annotation changes; previous records are retained under `annotation_baseline_history`, and existing OCR records are preserved. Failed evaluations do not replace their records. Unchanged coverage still enforces regression protection.

Reproduce the accuracy evaluation without changing records:

```sh
MAGICK_THREAD_LIMIT=1 luajit -l ffi tools/benchmarking/benchmark_panels.lua --detector components --all --summary-only
```

For faster validation, the production test scheduler can run one native LuaJIT process per volume. A single long process was substantially slower in this session; per-volume isolation was used for the final baseline review.

The ordinary quick suite passed **433 tests, 0 failed**. Native fixed-layout production checks produced **18 passed, 4 failed, 2 mapping skips**. The four failed accuracy checks correspond to the table above. Two legacy segmenter checks also fail against historical annotation records. The native full-panel run exposed embedded crop-padding regressions, which were fixed and rerun: **58 focused native tests passed, 0 failed, 3 pending Safe mapping skips**. StyLua, Luacheck (14 changed Lua files), shell syntax checks and `git diff --check` passed. The complete suite is not passing.

The unchanged legacy segmenter checks use historical records for 725 Bloom panels and 586 Kobayashi panels; the current annotations contain 730 and 594 respectively. Those historical records were retained rather than lowered to make these checks pass.

Host CPU sample (40 pages, native FFI; detection only, excluding image loading): Safe increased from 10.85 to 51.69 ms/page; Smart increased from 24.38 to 39.95 ms/page. This is a small host sample, not an e-reader page-turn measurement. Device latency and memory measurements remain outstanding.

The remaining detection failures include merged or split dialogue-linked groups in Chainsmoker, incomplete or fragmented crops in Horimiya, and dark/angled gutter layouts in SHY. A prototype based on enclosed white regions did not reach the requested target and was not included in the production detector.
