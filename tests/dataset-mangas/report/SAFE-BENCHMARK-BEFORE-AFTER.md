# Safe review for Komi, Chainsmoker and Kobayashi

The version 1 export matched reviewer report
`99418fd2da929026971df18dd479cf14abb7fc6ba2da1ea932e4eb4df669139c`.
The 120 exported Safe choices for these three volumes matched the saved
reviews, their report basis, image paths and dimensions. The 22
Nagatoro entries were outside scope. Chainsmoker also had 50 older
persisted choices. All 94 choices agreed with the committed mapping
before the chapter-label clarification.

Komi had 23 confirmed choices that had not been saved to the mapping.
The other 15 Komi choices and all exported Chainsmoker and Kobayashi
choices already agreed with their mappings. Mapping writes used the
reviewer's hash check and original-file backups.

The user clarified that detached chapter labels count as separate reading
steps, including short end labels. Original image inspection confirmed
missing separate captions on Komi pages 11, 27, 54, 125, 149, 158, 160,
167 and 185. Page 158 had absorbed the caption into its last panel.
Chainsmoker omitted the labels on pages 59, 78, 110, 116, 135, 148, 168,
173, 177, 188, 205 and 213. These annotations were updated from the
source images. Komi 79 and 140 contain page numbers or scan marks where
the old detector returned an extra crop. Those pages do not have the
kind of detached chapter caption shown on pages 35 and 48.

Safe now recovers stacks of complete frames joined by gray shading,
handles modest bounding-box overlap between aligned frames, and recognizes
detached chapter labels below the artwork. It keeps the dark bridge,
coverage and panel count checks. Centered end labels and adjacent pieces
of the same label are handled together. Small fragments at the top of
a full-page title illustration no longer create extra reading steps.

An earlier overlap experiment split intentional groupings on Chainsmoker
74 and 146 and Bloom 76. Requiring supporting frame and gutter geometry
preserved those cases. An early footer experiment included separated
page numbers and a Scott Pilgrim print credit. The final implementation
separates wide gaps in the text band and limits caption recovery to manga.

Both detector versions were evaluated against the final reviewed mappings,
using IoU 0.50 / 35 px edge tolerance. Mean IoU is averaged by matched page.

| Safe volume | Panels expected | Detected before → after | Matched before → after | F1 before → after | Mean IoU before → after | Complete pages in order | Exported reviews matched |
|---|---:|---:|---:|---:|---:|---:|---:|
| Komi 1 | 771 | 736 → 764 | 725 → 763 | 96.22% → 99.41% | .9854 → .9833 | 151 → 184 / 190 | 7 → 32 / 38 |
| Chainsmoker Cat 1 | 900 | 872 → 895 | 823 → 847 | 92.89% → 94.37% | .9683 → .9713 | 161 → 178 / 214 | 12 → 18 / 44 |
| Kobayashi 2 | 574 | 567 → 563 | 548 → 550 | 96.06% → 96.75% | .9682 → .9724 | 115 → 120 / 143 | 14 → 19 / 38 |

Relative order of matched pairs was 100.00% for Komi, 99.85% for Chainsmoker
and 98.92% for Kobayashi. Chainsmoker matched 58 of the 94 persisted
reviews, including decisions from the earlier round. No previously
correct page or matched panel was lost relative to the pre-change detector
on the mappings in place after reconciling the original export. Bloom 8
and Scott Pilgrim 5 returned identical Safe results across 431 pages.

Still unresolved in the export:

- Komi 3, 22, 28, 33, 50 and 90. These include a contents page, a nested
  inset, and title or artwork crops with different reading roles.
- Chainsmoker 7, 8, 27, 50, 72, 99, 105, 108, 109, 112, 127, 131, 140,
  142, 161, 167, 170, 180, 192, 194, 195, 200, 201, 204, 209 and 212.
  Pages 201 and 209 have identical images and equivalent grouping. Pages
  204 and 212 are also duplicates, and Safe falls back on both.
- Kobayashi 20, 21, 28, 52, 53, 58, 60, 61, 67, 72, 78, 80, 93, 104, 113,
  117, 123, 138 and 142. Page 61 is a detached time caption between tiers.
  Page 142 maps the colophon and reading guide as one crop. Pages 93,
  103 and 127 map bottom artwork as a single reading step where the
  detector finds separate regions. Splitting each visibly distinct region
  would conflict with those choices.

The synthetic frame and label tests and the Chainsmoker and Kobayashi
image regressions fail with the original detector and pass with this one.
The targeted detector, collector, geometry and book checks passed all
63 tests. The scoped Safe and Smart production benchmarks and lint passed.
Only Safe baselines were established. Komi and Kobayashi's previous Safe
records were archived and Chainsmoker received its first Safe full-volume
record. Other baseline records were checked for equality.

The reviewer refreshed only the three Safe groups and was restarted on
localhost port 3210. Older choices can appear stale when the detector
result or the mapping changes. Device behavior has not been tested.
