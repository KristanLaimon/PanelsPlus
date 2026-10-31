# Manhwa mode: initial Safe implementation

Cycle the existing mode button **Manga → Comic → Manhwa → Manga**. The reader
keeps the **Safe** and **Smart** names. Manhwa currently enables Safe only;
requesting Smart explains that it is not enabled. Manga/Comic retain their
existing detectors and their previous finding-mode preference when leaving
Manhwa.

Manhwa reads downward. Swipe up for the next reading section, down for the
previous one; swipe inversion still applies. Existing left-edge Kobo zoom gestures
remain available when enabled. Physical page-turn controls keep
working. Optional tap navigation uses the top/bottom thirds; the center toggles
controls. Existing viewer A/D behavior remains panel navigation, rather than
the annotator's half-screen drag panning.

Select **Nav. Smooth** for vertical camera transitions, including source-page
crossings. Manhwa uses Classic/Smooth navigation rather than horizontal
hardware page-turn animations. An existing Animated preference is displayed
as Smooth in the manhwa viewer without changing the fixed-layout preference.

## Independent forks

- `src/_manhwasafe.lua` starts from the existing Safe detector, with its own
  geometry fork in `_manhwasafegeometry.lua`.
- `src/_manhwasmart.lua` and `_manhwasmartgeometry.lua` are copies of the current
  Smart implementation, reserved for later manhwa development.
- `src/_manhwabitmap.lua` forks the bitmap builder. Its additional paper channel
  distinguishes black and white separators within the same source image.
- `src/manhwa.lua` handles continuity, complete panels, source-page layout,
  navigation between groups, and multi-page crop compositing.

`ENABLE_MANHWA_SMART = false` is near the top of `src/manhwa.lua`. Enabling the
fork is a development switch, not a claim that manhwa Smart has been tuned or
validated. Its dataset is not used by the current manhwa benchmark.

The original Manga/Comic detector, geometry, and bitmap files are unchanged.
Low-level component traversal remains shared; manhwa grouping and tuning are
independent. Manhwa results have separate panel-cache keys and benchmarks.

## Complete illustrations

Safe retains floating narration and borderless artwork alongside ordinary
framed panels. Content reaching a source image's edge can join compatible
content on the adjacent image. Neither white nor black pacing gaps count as
illustrations. Source-page coordinates are converted to a continuous native
coordinate system, preserving actual begins/ends across file seams.

Each detected illustration reaches the viewer as one complete panel, regardless
of its height or how many source images it spans. There is no screen-height
subdivision or source-page-count cutoff. Legacy section-height and join-limit
settings do not shorten panels.

The implementation stores native dimensions and detected rectangles, not an
entire chapter bitmap. Detection maps are processed one source page at a time.
Finding the true extent of uninterrupted artwork can require scanning many
source images; summaries are cached for subsequent navigation. Only source
crops intersecting the requested panel are composited at screen-fit size.
Render allocations remain bounded independently of the panel's native height,
and transition allocations are guarded by memory checks. Source crops share
rounded pixel boundaries to avoid visible rendering seams.

For EPUB/KEPUB/MOBI, an extracted image also uses the manhwa Safe fork and keeps
each tall illustration intact. This initial path operates within one extracted
image; it does not yet stitch separate embedded images into a continuous illustration.
Fixed-layout image pages (including the current CBZ dataset) use cross-page
joining.

Strict, Loose, Margin, and No crop use the same virtual strip geometry.
Automatic spread rotation and fold removal do not run on the strip. Text
selection transforms positions back to their actual source page.

## Initial evaluation

The evaluation reads **only `panels_safe.json`**, converts its overflow rectangles
to continuous coordinates, and matches complete panels from the actual viewer
collection path. It does not rewrite annotations or Manga/Comic benchmark records.

On the complete 62-image `Overgeared_Vol_1` chapter, at IoU ≥ 0.5:

| Metric | Initial result |
|---|---:|
| Annotated Safe rectangles | 50 |
| Detected regions | 49 |
| Matched rectangles | 40 |
| Precision | 81.63% |
| Recall | 80.00% |
| F1 | 80.81% |
| Mean IoU of matched rectangles | 91.45% |

This is an initial regression baseline, not the existing Manga/Comic production
quality target. Most unmatched annotations concern grouping: continuous scenes
around source pages 7–12, 15–18, and 49–52 are joined differently from the manual
reading stops. A credits/logo region is also split differently. An unmatched
rectangle does not necessarily mean its artwork is missing. The remaining
classification differences need further review/tuning; this chapter alone does
not establish general accuracy across all manhwa.

The Safe mapping mixes illustration boundaries with some source-page-sized
reading chunks, as discussed in `feelings.md`. The one-to-one score above should
therefore be read alongside the separate synthetic checks for preserving tall panels,
continuity, navigation, ownership/cleanup, and bounds. There is no manhwa Smart
accuracy claim.

Run from the plugin directory:

```sh
luajit tools/benchmarking/benchmark_manhwa.lua
luajit tests/run_tests.lua tests/manhwa_spec.lua tests/manhwa_dataset_spec.lua
python3 tests/run_parallel.py --panels -j 2
```

Complete local source images are required for the real-chapter regression.
Public preview-only checkouts skip it, unless `PANELSPLUS_REQUIRE_DATASETS=1`
requests strict completeness. The original Manga/Comic volume registry excludes
manhwa because its separate evaluator must account for source-page overflow.

## Existing regression checks

The broad panel run also exposed three legacy failures unrelated to this fork:

- Bloom's legacy F1 check reports 79.59% against its saved 79.85% record.
- Bloom Safe's reading-order check reports 83.10% against its saved 83.57% record;
  its panel F1 remains 94.04%, and Smart's remains 95.78%.
- Kobayashi's preview check requires extracted images `04.png`–`07.png`, which
  are absent from the current local extraction (139/143 images are present).

Both Bloom failures, including their exact scores, were reproduced with an
isolated copy of the original `HEAD` code and the same book annotations/images.
No legacy thresholds were lowered or records replaced. The manhwa baseline
above is separate from those existing records.

Automated crop-rendering and gesture checks use the repository's KOReader API
mocks. The real-image accuracy result uses its standard standalone image loader
at 480-pixel detection width. Live device rendering and responsiveness still
need manual confirmation after restarting KOReader.
