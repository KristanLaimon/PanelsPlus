# Safe reading order after the second review

The 28 choices in the export at 14:35 UTC matched the persisted Safe
reviews and report `ebbc8c226d82af4b36a43964ef9689d44a7541f3cfcc6a8958cdd04dbcfffb8d`.
All 23 Chainsmoker choices and all five Nagatoro choices were already in
the dataset, including Chainsmoker pages 2 and 161. No additional
mapping edits were needed.

Safe now finishes a right-hand stack before a tall left panel that
starts above it when at least two later tiers support the stack.
It also finishes each column within a manga band where vertical gutters
separate staggered stacks. Shared horizontal gutters retain row order.
Chainsmoker page 57 illustrates why the distinction matters. Its lower
stacks share a horizontal gutter and were correctly read as rows.
Applying column order there in the first trial caused a regression.
The final sorter retains its row order.

| Scope | Complete pages, same mappings | F1 before and after | Pair order before → after |
|---|---:|---:|---:|
| Chainsmoker 1 | 180 → 180 / 214 | 94.12% | 1941/1947 → 1944/1947 |
| Nagatoro 1 | 140 → 141 / 161 | 96.73% | 1031/1037 → 1037/1037 |

Nagatoro page 37 now matches in full. Page 152 now visits all seven
matched panels in order, with one additional detached bonus label.
Chainsmoker pages 8 and 140 now visit their matched panels in order,
with remaining differences in panel detection. Page 42 still matches
all five rectangles under the evaluator's tolerance, but Safe's first
crop reaches across the preceding scene. The resulting sequence is
2, 1, 3, 4, 5. Pages 33 and 48 retain inversions together with missing
or extra crops. The duplicate images on Chainsmoker pages 204 and 212
have the same seven reading steps with slightly different crop edges.

Komi and Bloom have no inversions among matched panels. Kobayashi
pages 20, 58, 78 and 104 have mixed detection and order differences.
Scott Pilgrim was evaluated as a left-to-right comic. Pages 13, 15,
101 and 129 match all mapped panels but still disagree on sequence.
Their diagnostic results were identical before and after this manga
change.

The 1,139 mapped pages across the six volumes kept the same detected
rectangles and had no newly failing pages. The two new geometry
regressions fail with the original sorter and pass with the revised one.
The 73 targeted tests and lint passed. Device reading was not tested.
