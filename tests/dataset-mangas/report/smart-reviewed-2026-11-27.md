# Smart review feedback, 2026-11-27

The Smart scope covers the 252 decisions in `REVIEW-OUTPUT.json`. The report ID, saved review bases, source paths and native image sizes matched the export. The reviewer service applied 147 pending decisions with stale-file protection and exact backups. All 252 selections match the resulting Smart annotations, including panel sequence. The review did not include Scott Pilgrim, which was evaluated only as a comic control.

## Detector changes

- **Bloom Into You Vol. 8, page 36.** Retain an edge-to-edge full-bleed tier beside a separate framed tier when both fill the crop and meet the existing coverage threshold. The regression protects inset artwork.
- **Chainsmoker Cat Vol. 1, page 34.** Skip dark divider inference inside nearly solid dark crops so black gaps between lines of light text do not split a caption. The regression still splits a real shared border.
- **Don’t Bully Me, Nagatoro Vol. 1, pages 53 and 160.** Keep a detached footer with its sole unframed illustration when the high-contrast plane contains no strongly framed panel. The regression preserves a standalone footer next to real framed artwork.
- **Horimiya Vol. 1, page 158.** Trim an overlapping open crop to the neighboring frame only where a continuous border and gutter support the correction. Filling the gutter restores overlap suppression in the regression.
- **Komi Can’t Communicate Vol. 1, pages 123 and 125.** Recover a set of enclosed rows from the high-contrast plane when gray screening causes a dominant merged crop. Scan the detached footer on that plane as well. The regression preserves a real one-pixel ink bridge.
- **Miss Kobayashi’s Dragon Maid Vol. 2, pages 65 and 117.** Recognize partly gray horizontal separators when a continuous dark core and pale neighboring bands support a border. A discontinuous line still fails the separator check. Page 60 gained a match but still has a panel discrepancy.

## Rejected approaches

- Recovering the enclosed grid on Chainsmoker page 95 produced all five boxes but worsened pair order against the approved sequence. The chosen mapping and the general manga reading direction were preserved. Coalescing dark text fragments more broadly also degraded order.
- Accepting overlapping neighbors without border and gutter evidence regressed two Horimiya pages. The narrower trim keeps that evidence mandatory.
- Treating every detached footer as part of an illustration removed an approved standalone caption on Nagatoro page 88. Lowering the dark-rule threshold for weak parent crops recovered page 113 in isolation, but that candidate lacked full control and regression coverage.
- Relaxing the two-tier rule for Bloom beyond a real page-edge bleed could retain inset artwork as its own tier. The remaining slanted or interrupted examples also lack enough panel evidence for that rule.

## Full-volume validation

The before and after columns use the same approved annotations. The saved F1 column uses the pre-review annotations and includes the effect of changing the mapping. Exact requires every panel to match in reading order. Pair order compares all matched panel pairs. Evaluation uses IoU 0.50 and edge tolerance 35 px.

| Volume | Saved F1 | Detector F1 before → after | Mean IoU before → after | Exact pages before → after | Correct pairs before → after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bloom Into You Vol. 8 | 95.78% | 97.69% → 97.76% | 0.9647 → 0.9662 | 196/213 → 197/213 | 1085/1085 → 1086/1086 |
| Chainsmoker Cat Vol. 1 | 93.78% | 98.01% → 98.05% | 0.9670 → 0.9673 | 189/214 → 190/214 | 2463/2467 → 2463/2467 |
| Don’t Bully Me, Nagatoro Vol. 1 | 95.88% | 97.33% → 97.48% | 0.9722 → 0.9739 | 147/161 → 149/161 | 1161/1161 → 1161/1161 |
| Horimiya Vol. 1 | 92.44% | 94.89% → 94.96% | 0.9634 → 0.9634 | 152/181 → 153/181 | 1307/1307 → 1312/1312 |
| Komi Can’t Communicate Vol. 1 | 95.58% | 98.25% → 99.03% | 0.9813 → 0.9811 | 178/190 → 180/190 | 1378/1378 → 1398/1398 |
| Miss Kobayashi’s Dragon Maid Vol. 2 | 96.85% | 98.63% → 98.89% | 0.9799 → 0.9811 | 135/143 → 137/143 | 1218/1218 → 1226/1226 |

The reviewed set went from 147 to 156 exact pages out of 252. Across 1,508 pages, no previously exact page failed after integration. Komi’s mean IoU decreased by 0.0002 as previously unmatched crops entered the mean. Its panel matches rose from 756 to 766 and no other Komi page changed.

SHY was a manga control. Its F1 rose from 72.31% to 72.40% and its exact pages increased from 59 to 61 of 179. Scott Pilgrim was a comic control. Its detections and metrics stayed identical. Bloom EPUB, KEPUB and MOBI each retained three exact pages. The Safe detector, annotations and report partition were untouched. The shared tests still exercise independence between the detectors.

## Remaining reviewed discrepancies

Page numbers are 1-based. A page can match under the evaluator tolerances even if the coordinates differ.

- **Bloom Into You Vol. 8.** 6, 50, 67, 74, 90, 97, 98, 119, 122, 153, 164, 165, 208, 209, 212, 213.
- **Chainsmoker Cat Vol. 1.** 8, 9, 28, 35, 38, 42, 48, 50, 63, 71, 85, 95, 96, 109, 122, 127, 131, 135, 148, 181, 194, 195, 200, 208.
- **Don’t Bully Me, Nagatoro Vol. 1.** 28, 50, 70, 88, 113, 120, 128, 129, 144, 148, 151, 159.
- **Horimiya Vol. 1.** 7, 12, 26, 34, 51, 53, 55, 56, 63, 65, 79, 87, 107, 108, 117, 141, 142, 150, 152, 157, 161, 166, 171, 172, 173, 178, 179, 180.
- **Komi Can’t Communicate Vol. 1.** 7, 19, 42, 50, 57, 58, 62, 131, 143, 159.
- **Miss Kobayashi’s Dragon Maid Vol. 2.** 60, 61, 64, 80, 85, 93.

## Verification

Each new detector fixture failed with the original implementation and passed with its candidate. The six fixtures also passed together in the final 36-case component suite. The component, segmenter, collector and benchmark unit suites totaled 70 passes. StyLua and Luacheck passed for both modified Lua files.

The six initial production benchmark failures were coverage mismatches after applying the reviewed annotation counts. After full-volume comparison, `Benchmark.establishBaseline` archived the previous Smart records and established new records for the six reviewed volumes. Benchmark thresholds, non-Smart records and control baselines remained unchanged.

The final production checks passed for the six reviewed volumes and both fixed-page controls. The EPUB, KEPUB and MOBI suite also passed. Together those checks added 24 passes, with zero failures or skips.

The six Smart groups were regenerated individually. Their saved diagnostics match the validated page results and retain the previous different detector outputs. Reviews, session settings and unrelated report groups were preserved.

The live reviewer exposed a baseline display issue for Nagatoro, whose mapping has 161 annotated pages and four empty records. The Smart baseline check now counts only annotated pages. Its HTTP regression reproduced the omission before the fix and passed afterward with the other ten reviewer tests. The Bun build passed and the restarted reviewer returned all six Smart baselines. Standalone strict TypeScript checking reported missing Bun, Node and HTML declarations in this environment.

The validation used local page images and the standalone Lua runner. Device behavior was outside the review scope.
