# Reading-order fix — 2026-10-03

## Cause and change

The nested-stack rule treated even a few pixels of vertical crop overlap as a
reason to defer a panel. This sent upper-row panels after lower-row panels,
especially in Horimiya. It also missed Nagatoro stacks when the tall trailing
panel started above its neighbours or crop padding crossed the column boundary.

The shared geometry sorter now requires at least half of the shorter panel to
overlap vertically before deferring a panel, and tolerates horizontal border
padding up to 5% of the narrower panel. A panel with no earlier neighbour in its
top-aligned row needs at least two later leading panels to establish a stack.
Subsequent members of a row cannot overtake a deferred predecessor.
The same rules apply to manga and mirrored comic layouts.

## Dataset measurements

Before and after use the same annotations and detected rectangles. All 1,446
mapped pages were compared individually; no page lost matched-pair ordering
accuracy, and sorting a second time preserved the result on every page. Fresh
component-detector CLI runs also passed for all eight datasets. Existing
detection scores and historical detector records remain unchanged.

Perfect-page accuracy requires complete one-to-one detection in the expected
order. Pair accuracy measures relative order among matched panels, excluding
unmatched panels. The expected sequence is the saved annotation frame array.

| Dataset | Perfect pages before → after | Pair order before → after |
| --- | ---: | ---: |
| Bloom_Into_You_Vol_8 | 169/213 → 171/213 | 99.61% → 100.00% |
| Chainsmoker_Cat_Vol_1 | 142/214 → 149/214 | 99.12% → 99.72% |
| Don't_Bully_Me_Nagatoro_Vol_1 | 94/108 → 96/108 | 98.96% → 100.00% |
| Horimiya_Vol1 | 105/181 → 124/181 | 95.50% → 99.92% |
| Komi_Can't_Communicate_Vol_1 | 162/190 → 164/190 | 99.84% → 100.00% |
| Miss_Kobayashi's_Dragon_Maid_Vol_2 | 118/143 → 120/143 | 99.47% → 99.82% |
| SHY_Vol_01 | 61/179 → 64/179 | 98.32% → 100.00% |
| Scott_Pilgrim_Vol_5 | 195/218 → 198/218 | 99.45% → 99.88% |

Nagatoro now has zero measured inversions. Horimiya falls from 55 inverted pairs
to one. Its remaining mismatch is page 180: the annotation puts the left top
panel before the right top panel. Visual inspection supports normal right-to-left
manga order (the right panel discusses future character appearances; the left
closes with “please keep on cheering me on”). The annotation was not changed.
Other datasets retain a few ambiguous/mismatched layouts; this is not a claim
that every page is now perfectly recognized or ordered.

## Validation

- 18 geometry tests pass, including ten new cases spanning both reading directions,
  multiple scales, permuted input, and repeated sorting.
- 379 ordinary unit tests pass.
- All eight fresh component CLI benchmarks pass and update the ordering records.
- Lua formatting and lint checks pass for the sorter and geometry tests.
- The required-dataset panel suite passes 11 of 12 jobs. The only failure is
  Horimiya's pre-existing plain-Lua mean-IoU discrepancy (0.9351 versus the
  recorded 0.9354), reproduced with the original evaluator/tracker/spec before
  changing the sorter. Its ordering guards pass. The complete Horimiya
  production test passes under LuaJIT.
