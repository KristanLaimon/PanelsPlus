# Conservative panel recognition — 2026-10-03

## Behavior

When a proposed split is uncertain, retain the containing panel or panel group.
When the final candidates fail coverage checks, retain the full page.

The reader was missing the `dark` and `structural` maps supplied by the dataset
loader. The detector substituted all ink for dark strokes. Gray shading could
therefore qualify as a drawn separator in the reader even when the benchmark
rejected it. Both production sampling paths now construct the same two layers:
luminance at most 100 for dark strokes, and background contrast greater than 100
for structural ink. Without a dark map, dark-border splitting is disabled.
The additional two byte arrays use at most about 0.9 MiB at a 480 × 960 raster.

Further safeguards:

- Preserve components with at least three supported frame sides during projection splitting.
- Require every structural child to have at least three supported frame sides.
- Require children to cover at least 85% of the parent, with at most 2% pairwise overlap relative to the smaller child.
- Preserve groups crossed by a shared speech balloon and respect the configured panel limit.
- Remove nested crops deterministically without letting two similar boxes remove each other.
- Preserve caller settings and global defaults; coverage checks use a local copy.

## All mapped pages

Matching is unchanged: IoU ≥ 0.50, with the existing 35-native-pixel coordinate
tolerance. Precision and recall count individual annotated panels; keeping a
larger group can lower recall while providing a safer reading crop.
Nagatoro contributes only its 108 mapped pages. SHY remains experimental.

“Previous benchmark” is measured from the files present when this change began.
“Previous reader layers” runs that same detector on the same dataset rasters with
`dark` and `structural` absent, reproducing the old reader's map interface.
It isolates the interface mismatch; it is not a measurement on physical hardware.
The current Scott result already differed from the table supplied in the request.

| Dataset | Mapped pages | Previous benchmark FP | Previous reader layers FP | New FP | Precision | Recall | F1 | Mean IoU |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Bloom_Into_You_Vol_8 | 213 | 31 | 85 | 23 | 96.72% | 93.66% | 95.16% | 0.9409 |
| Chainsmoker_Cat_Vol_1 | 214 | 72 | 152 | 69 | 92.58% | 88.31% | 90.39% | 0.9392 |
| Don't_Bully_Me_Nagatoro_Vol_1 | 108 | 6 | 21 | 6 | 98.61% | 98.39% | 98.50% | 0.9744 |
| Horimiya_Vol1 | 181 | 41 | 119 | 41 | 93.84% | 83.78% | 88.53% | 0.9244 |
| Komi_Can't_Communicate_Vol_1 | 190 | 22 | 58 | 17 | 97.72% | 97.59% | 97.66% | 0.9701 |
| Miss_Kobayashi's_Dragon_Maid_Vol_2 | 143 | 13 | 34 | 12 | 97.86% | 93.52% | 95.64% | 0.9616 |
| SHY_Vol_01 | 179 | 99 | 235 | 98 | 80.93% | 53.96% | 64.75% | 0.8741 |
| Scott_Pilgrim_Vol_5 | 218 | 15 | 15 | 15 | 98.21% | 98.33% | 98.27% | 0.9564 |

Across 1446 mapped pages, false positives fall from
299 in the previous benchmark to 281.
The previous reader-layer simulation produces 719 false positives.
No volume gains false positives relative to the measured previous benchmark.

This is an intentional tradeoff, not an improvement in every metric. Yani Neko's
recall changes from 90.77% to 88.31% while F1 stays above 90%.
Some close decisions retain a wider group. Horimiya remains below 90% F1.
F1 alone does not establish that every returned crop is suitable for reading.

## Regression records and validation

Historical `components_full_volume` records remain intact. The new policy uses
`components_conservative_full_volume` so the deliberate preference for retaining
groups is visible rather than silently replacing historical accuracy records.
Production tests and the component benchmark CLI use the new records, retaining
precision, recall, F1, mean-IoU and false-positive regression checks.

New synthetic tests cover straight lines inside an intact frame, incomplete
structural fragments, clear frames connected by shading, caller-settings
immutability, and production grayscale/RGB layer generation with and without the
optional border plane. The runtime map tests exercise the same production builder
used by the reader.

Commands:

```sh
python3 tests/run_parallel.py --skip-datasets
PANELSPLUS_REQUIRE_DATASETS=1 python3 tests/run_parallel.py --panels
luajit -l ffi tests/run_tests.lua tests/spec/componentdetector_spec.lua tests/spec/pagebitmap_spec.lua
```

Validation completed:

- Ordinary unit suite: 369 passed, zero failures.
- Panel suite with datasets required: 12 jobs passed, zero failures or skips; all 1,446 mapped pages evaluated, plus existing golden and text-format checks.
- Focused native-FFI tests: 29 passed, zero failures.
- Component CLI: Nagatoro's 108 mapped pages passed the new regression record and reported all six false positives.
- StyLua and Luacheck passed for the changed Lua files.

Physical e-reader rendering and memory behavior still require device validation.
