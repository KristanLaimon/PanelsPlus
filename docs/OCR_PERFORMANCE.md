# OCR resource audit

Measured on the development Linux host using KOReader's installed LuaJIT,
MuPDF, Blitbuffer and k2pdfopt libraries. These are host measurements, not
Kindle timings or a measurement of the complete KOReader UI working set.

## Changes

- Keep at most one temporary OCR context per lookup. Reuse the 20px bitmap
  for the character-mode tie-breaker; release it before changing resolution,
  changing crop, falling back to reader OCR, or returning (including errors).
- Resolve the bundled model once per lookup, avoiding repeated filesystem
  probes without caching missing models across lookups.
- Stop column scanning at the first ink pixel. All consumers use presence,
  so gap thresholds, bounding boxes and recognition decisions are unchanged.
- Explicitly free an allocated grayscale buffer if conversion fails. Use
  pixel accessors for rotated/inverted source buffers after conversion failure;
  the raw FFI pointer fast path requires unrotated, non-inverted BB8 data.
- Closing the viewer cleans up already loaded OCR engines without loading
  native libraries just to release them.
- Before allocating a word-finding crop, reserve 40 MiB plus six bytes per
  rendered pixel for temporary color/grayscale buffers, using the existing
  memory helper. On insufficient headroom, retain the reader's selection.
  This estimates crop allocations; it cannot predict all renderer/model memory.

No full GC was added to taps, OCR passes or panel navigation. Native page and
bitmap memory is released explicitly; Lua's normal incremental GC handles
small temporary tables. Existing low-memory collection on viewer close and
native-detector fallback remains in place. Renderer-owned cache tiles remain
owned by the renderer; freeing them from WordFinder would risk use-after-free.

## Validation

- 256 unit tests passed, including crop reuse, cleanup on errors, missing models,
  grayscale conversion failure, transformed-buffer access and low-memory gating.
- All 668 annotated words evaluated: geometry 637/668 (95.36%), bundled native
  OCR 639/668 (95.66%). Configured installed model: 580/668 (86.83%).
- The final column-presence optimization also passed the complete geometry set.
- LuaCheck and formatting checks passed.

The OCR test fixture now defaults to 512 MiB available memory instead of zero;
low-memory tests override that explicitly. Otherwise adding an allocation guard
would turn every ordinary fixture into an artificial out-of-memory case.

## Host measurements

Sequential 668-word runs with identical bundled English models:

| Metric | Before this audit (`914c783`) | Optimized |
| --- | ---: | ---: |
| Total CPU | 30.360 s | 29.332 s |
| Word finding CPU, including rendering | 8.962 s | 8.710 s |
| OCR CPU, including rendering | 21.364 s | 20.588 s |
| OCR reads | 1,347 | 1,347 |
| OCR crop renders / contexts | 1,347 | 1,321 |
| Peak sampled RSS | 45.98 MiB | 45.48 MiB |
| Peak sampled Lua heap | 6.15 MiB | 5.79 MiB |

Exact output files matched for all 668 entries (boxes and returned strings).
This run saved 26 native renders/context allocations and about 3.4% CPU.
Timing differences this small are host-sensitive; allocation counts and exact
output equality are the stronger evidence.

A separate three-round optimized stress run completed 2,004 lookups with
RSS of 45.69, 46.09 and 46.31 MiB at the round boundaries, and at most one
live OCR context. After engine cleanup and a final benchmark-only GC,
RSS was 36.19 MiB and Lua heap 2.44 MiB. This bounds the observed run; it does
not prove zero growth for arbitrarily long reader sessions.

Historical code (`1bf5d32`) with the installed English model took 29.117 s
for one 668-word run and peaked at 62.94 MiB RSS. Its recognition behavior and
model differ: this is context for the requested historical comparison, not an
isolated code-speed comparison. The optimized bundled path's 29.332 s is close
on this host; equal speed on ARM/e-ink hardware is still unverified.

## Reproduction

From the KOReader installation directory:

```sh
OMP_THREAD_LIMIT=1 luajit /absolute/plugin/tools/benchmark_ocr_resources.lua
```

The default runs every annotated word three times (2,004 lookups), one page at
a time, using real MuPDF cropping and k2pdfopt recognition. It reports CPU time,
RSS, process high-water RSS, Lua heap, crop renders and live native contexts.
It asserts that no OCR context survives a lookup and detects double frees.
It excludes UI, DocCache retention, panel caches, fonts and other reader plugins.
PNG DPI is normalized to annotation coordinates. It makes no accuracy claim
for this rendering harness; the separate OCR dataset suite supplies that gate.

Optional arguments are a WordFinder source snapshot and repeat count. A
snapshot must retain the `src/_wordfinder.lua` layout and have access to the
same `data/ocr` directory. `PANELSPLUS_OCR_RESULTS=/tmp/results.txt` writes exact
boxes and returned strings for comparing implementations. The benchmark does
not modify bestbenchmark records.

To measure configured-model behavior, set `PANELSPLUS_BUNDLED_OCR=0`,
`PANELSPLUS_OCR_LANGUAGE=eng` and `PANELSPLUS_OCR_TESSDATA=/path/to/tessdata`.
Do not compare model configurations as though they isolated a code change.

## Device limits

The bundled English model remains opt-in. Its multiple recognition passes are
required by the measured accuracy policy. No accuracy thresholds were lowered.
A 250 MiB device also needs memory for its OS and reader caches: a small isolated
benchmark cannot certify that complete device configuration. Verify long-press
latency, repeated panel navigation and memory pressure on the target reader
before claiming identical pre-OCR speed or guaranteed 250 MiB compatibility.
