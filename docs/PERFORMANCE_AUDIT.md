# Memory and performance audit — 2026-09-28

Target: low-memory e-readers, including roughly 300 MB Kindle devices.

## Changes

- Viewer teardown respects ImageViewer's disposal of the active bitmap, avoiding a second free call.
- Smooth transitions explicitly release canvases when filling or compositing fails.
- Cross-page transitions release owned source tiles when the next render, rotation check, or scaling fails. Borrowed tiles are not disposed of as private copies.
- Cross-page scaling and canvas creation reserve their estimated allocation plus 40 MiB of free memory. Oversized transitions fall back to ordinary navigation.
- Failed bitmap normalization, embedded-image crops, and fold joining release their temporary buffers before returning or raising an error.
- Fixed-page detection renders are bounded in both dimensions, as embedded-image detection already was. At the default setting the raster is at most 480 × 960; oversized returned rasters are sampled at a bounded size. Very tall pages may lose fine detection detail at this resolution.
- Delayed detection and prerender callbacks reject canceled work and changed documents. Detection rechecks memory when the callback executes. Prerendering also reserves eight bytes per screen pixel above its existing safety floor.
- OCR diagnostic PGM output writes one row at a time instead of constructing a full-image table of pixel strings.

## Ownership and GC findings

Panel rectangles have a bounded cache (12 pages by default). Panel image lists contain lazy render functions. Ordinary rendered tiles belong to KOReader's document cache; displayed private copies belong to the viewer. Component detection reuses FFI scratch arrays and clears them at document teardown. OCR sessions release their native context between lookups and retain at most one context within a lookup.

No new forced collections or global GC tuning were added. Existing low-memory collections remain, including the native detector's collection before its expensive fallback. Faster normal navigation should not require stopping the entire Lua heap on each panel change.

## Verification

- 361 non-dataset tests passed, including injected render failure, exact-once viewer disposal, canceled prefetch, memory changes during delayed work, and tall-page render bounds.
- Luacheck: zero warnings/errors across all 26 source modules and the changed test files. Formatting and diff checks passed.
- Native desktop KOReader OCR stress test: three rounds of the same 668 annotated words (2,004 lookups), using MuPDF and k2pdfopt with one OpenMP thread.
- 3,963 native contexts created; the harness asserts zero live contexts after each lookup and rejects duplicate frees. Peak live contexts: one.
- RSS after rounds: 46,900 / 47,088 / 47,224 KiB. After engine cleanup and collection: 36,856 KiB. Lua heap after cleanup: 2,175 KiB.
- Total measured CPU: 84.006 seconds (25.115 finding boxes, 58.791 recognizing words). These are desktop measurements, not Kindle latency or a before/after speed comparison.
- 1,968 lookups returned a plausible word. This is not an accuracy score; correctness against the annotation was not evaluated by this resource harness.

Reproduce the native resource test from `/usr/lib/koreader`:

```sh
OMP_THREAD_LIMIT=1 ./luajit /absolute/plugin/tools/benchmarking/benchmark_ocr_resources.lua /absolute/plugin/src/_wordfinder.lua 3
```

## Limits and device validation

The full panel/OCR accuracy datasets were not rerun in this audit. Native stress measurements exclude the full reader UI and document cache. Unit tests use mocked UI components. There is no physical Kindle measurement here, nor proof that all KOReader versions and native libraries are leak-free. Source review and these runs cannot establish a universal zero-leak guarantee.

On the Kindle, validate repeated panel/page navigation, repeated OCR, changing books, and closing/reopening the viewer while watching process RSS. Distinguish cache warm-up from continued growth across repeated identical cycles. Keep Classic navigation for the lowest transition overhead; it is already the default. OCR engine/model initialization and source-image decoding still consume native memory outside Lua's heap, so available system RAM alone is not a process memory budget.

The previously reported release-only flash is not confirmed fixed by this audit. The earlier assertion that 2025 KOReader needs a different hold return contract was not established: the inspected v2025.10 handler also returns booleans. That symptom still needs evidence from the active Kindle build, format, and gesture path.
