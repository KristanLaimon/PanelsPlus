# Stable Safe restoration and detector resource optimization — 2026-10-16

Safe restores the grouping, padding, acceptance, and reading order of `6a82bc8`
(three commits before `6086013`). It no longer invokes Smart. Smart preserves
its behavior at `6086013`. Both use an optimized shared traversal workspace.

Production panel gates now require **strictly above 90%** precision, recall,
F1, mean matched IoU, and matched-panel pair order. When there are no comparable
pairs, the existing exact-page ordering fallback applies. OCR gates are unchanged.
Horimiya Safe remains draft and excluded; SHY has no Safe mapping.

## CPU and allocations

Host LuaJIT, five evenly spaced pages from each of eight volumes (40 pages),
four warmups and four timed detections per page. Each implementation ran in a
separate process. Decoding, collection, scratch cleanup, and allocation sampling
were outside timed detections. GC ran normally during CPU timing.

| Detector | CPU before | CPU after | Reduction | Temporary allocation before | After |
| --- | ---: | ---: | ---: | ---: | ---: |
| Safe | 53.739 ms/page | 5.466 ms/page | 89.8% | 122.7 KiB/page | 4.5 KiB/page |
| Smart | 34.624 ms/page | 17.393 ms/page | 49.8% | 116.1 KiB/page | 22.9 KiB/page |

Safe's comparison includes the requested behavior restoration; it is not a
comparison of identical algorithms. Against the historical Safe reference,
paired full-volume timings were 27–61% lower while outputs matched exactly.

Temporary allocation is heap growth over one warmed call with GC temporarily
stopped. It is allocation pressure, not process RSS. Maximum detector FFI buffer
allocation in the sample fell from **3,771.3 to 1,748.3 KiB for Safe**. Smart's
maximum remained **2,056.0 KiB**. These figures exclude input maps and decoded
images. Retained warm heap, including LuaJIT bookkeeping, was 3,665.6 → 1,621.3
KiB for Safe and 1,996.0 → 2,073.6 KiB for Smart. Smart retains projection tables
to avoid repeatedly allocating them; its retained heap rose by about 78 KiB.

These are host measurements, not Kindle/Kobo page-turn timings or whole-reader
memory measurements. LuaJIT trace state and page content affect timings.

The changes are:

- Traverse complete horizontal ink runs with the same eight-neighbor connectivity.
- Share visited, queue, and boundary arrays across Safe and Smart.
- Skip unused frame fitting for balloon visitors; stop once a non-merging check
  has its answer.
- Reject Smart's impossible compact candidates before fitting their boundaries.
- Reuse four split-projection tables and move compact eligibility out of a
  per-component closure.

Scratch cleanup remains available through the existing lifecycle methods.
Production code does not force per-page full collections or change KOReader's
application-wide GC settings.

Reproduce with `tools/benchmarking/benchmark_component_resources.lua`; the
commands and saved reference dependencies are documented in `tests/README.md`.

## Output preservation

All **1,503 pages across eight volumes** were compared against both references:
3,006 page/algorithm comparisons. Ordered coordinates, frame metadata,
acceptance, and fallback reasons matched exactly. Safe was compared against
`6a82bc8`; Smart against `6086013`. This includes pages without reviewed Safe
annotations as behavior comparisons, not accuracy measurements. An additional
128 comparisons with optional hole detection and both crop-padding modes
also matched their references exactly.

## Accuracy and regression checks

The new 90% accuracy gate passes **12 of 14** mapped algorithm/volume evaluations.

| Volume | Safe precision | Safe recall | Safe F1 | Smart F1 |
| --- | ---: | ---: | ---: | ---: |
| Bloom | 96.75% | 91.48% | 94.04% | 95.78% |
| Chainsmoker | 91.04% | 77.83% | **83.92%** | 93.78% |
| Nagatoro | 98.83% | 93.80% | 96.25% | 95.88% |
| Horimiya | Draft | Draft | Draft | 92.44% |
| Komi | 97.41% | 93.34% | 95.33% | 95.58% |
| Kobayashi | 95.54% | 90.69% | 93.06% | 96.85% |
| SHY | Unmapped | Unmapped | Unmapped | **72.31%** |
| Scott Pilgrim | 94.80% | 97.74% | 96.25% | 97.04% |

The two remaining accuracy failures are Chainsmoker Safe and SHY Smart.
Seven additional assertions fail against saved baselines: five restored Safe
results differ from the newer records; Chainsmoker Smart has a pre-existing
coverage mismatch; Horimiya Smart has a pre-existing recall regression.
Saved benchmark records and annotations were not rewritten to hide these failures.

Validation:

- Ordinary suite: **435 passed**, zero failures.
- Focused native FFI suite: **66 passed**, zero failures.
- Production benchmark suite: **13 passed, 9 failed, 2 skipped**, as explained above.
- Randomized traversal checks compare every component pixel with an independent
  eight-neighbor flood fill; allocation checks cover sharing, reuse, and cleanup.
- Modified Lua files pass StyLua and Luacheck; `git diff --check` passes.
