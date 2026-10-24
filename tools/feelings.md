# My reading of your manhwa mappings

Review date: 2026-10-24. This is my interpretation for you to correct before implementation or detector testing resumes.

I inspected the saved geometry across all 62 source images in `Overgeared_Vol_1` and visually compared the mappings over the artwork, including every region where Smart and Safe differ. I have not run detector benchmarks, adjusted algorithms, or changed your annotations.

## What I think you prioritized

My strongest interpretation is that **Safe protects the continuity of a scene, while Smart sometimes divides the same scene into shorter reading chunks.** Both mappings recognize the same main content. Their difference is mostly where to stop a crop inside very tall artwork.

That is an inference from the rectangles and images, not a claim that I already know your intentions.

| Observation | Smart | Safe |
|---|---:|---:|
| Rectangles | 58 | 50 |
| Source pages containing a rectangle's starting point | 47 | 39 |
| Rectangles extending past their starting source page | 28 | 26 |
| Rectangles at least 90% of source width | 41 | 33 |
| Exact full-source-page rectangles | 5 | 4 |

There are **44 rectangles identical in both mappings**. The difference is six long Safe rectangles versus fourteen Smart rectangles covering approximately the same six regions. Those subdivisions explain all eight additional Smart rectangles.

Both mappings intersect all 62 source pages and follow increasing vertical starting positions. This does not establish complete artwork or text coverage; it establishes that no source page is entirely untouched by the saved rectangles. A source page with an empty `frame` list can be covered by a rectangle that began on an earlier page. It must not automatically become a missing-panel error or a duplicate full-page fallback.

## The six places that explain the difference

Page numbers below are the annotator's **1-based source-page numbers**. Source page 18 is `17.png`. The starting page identifies the rectangle; a rectangle can continue through later source images.

| Region, identified by its starting source page | Safe rectangle height | Smart crop heights in reading order | What the images suggest |
|---|---:|---|---|
| 18 | 4,198 px | 2,345 + 1,861 px | Safe preserves the long battle composition. Smart adds a stop around the beginning of source page 20. |
| 25 | 4,093 px | 2,268 + 1,823 px | Safe keeps the character, dialogue, and monsters in one continuous composition. Smart splits near source page 27. |
| 28 | 4,899 px | 1,808 + 1,772 + 1,319 px | Safe keeps the long sword/action image together. Smart divides it around source pages 29 and 30. |
| 31, the second crop on that page | 3,657 px | 1,336 + 2,307 px | Safe keeps the attack and its large sound effect together. Smart splits at the source-page-32 join. |
| 37 | 4,277 px | 1,041 + 1,896 + 1,340 px | Safe preserves the continuous attack and lettering. Smart adds stops at source pages 38 and 39. |
| 56 | 4,123 px | 2,088 + 2,052 px | Safe preserves the explosion and its extended sound effect. Smart splits at source page 58. |

The heights do not always add up exactly because the boundaries differ by a few pixels. For example, the region starting on page 18 differs by 8 px at its far end, the page-31 region by 14 px, and the page-56 region by 17 px. I would not treat those small edge differences as different artistic intentions.

Several Smart cuts pass through continuous art or sound-effect lettering, without a visible gutter at the cut. They appear useful as **reading stops**, but they are not all boundaries of distinct illustrated panels. If your intent was instead that Smart identify separate artistic panels, I need your explanation before treating these cuts as detector targets.

## My assessment of your pattern recognition

You consistently recognized that a manhwa source file is a slice of a longer composition. Both mappings already cross source-page joins rather than stopping every rectangle at a file boundary.

You also recognized content that a simple frame detector could miss:

- Detached narration gets its own reading unit. Page 12 has an 814 × 77 crop, page 33 has a 705 × 54 crop, and page 35 has a small 86 × 70 crop around “NO.” These are intentional-looking reading targets, not ordinary framed illustrations.
- Large sound effects belong to the surrounding composition. Safe's regions starting on pages 31, 37, and 56 make that especially clear.
- Wide blank or black spacing separates reading units. You often exclude much of that spacing instead of including it simply because it shares a source image with the artwork.
- Pages 60–62 retain the title, credits, and publishing information as separate units in both mappings. Safe therefore does not mean “ignore small content.”

Those choices form useful ground truth for **what should be readable as a unit**. They do not support reducing the goal to “find large connected shapes” or “keep rectangles with visible borders.”

The main uncertainty is the distinction between an artistic panel and a convenient reading chunk. Your maps contain both kinds of boundary. I cannot grade the extra Smart cuts as better or worse without knowing which behavior you intended.

There is also an important exception to my proposed Safe interpretation: around source pages 7–11, both mappings retain several source-page-sized chunks even though the background/artwork continues across joins. Safe does not consistently merge every continuous image in the chapter. That may be an intentional dialogue/pacing choice, an acceptable size limit, or an area you left unchanged. I should not silently decide which explanation is correct.

## A metadata issue separate from your judgment

The saved `illustration_type: "single_page"` currently does **not** reliably mean “this rectangle covers exactly one complete source page.”

Smart has 38 records with that label, but only 5 exact full-source-page rectangles. Safe has 30 such records, but only 4 exact full-source-page rectangles. Even the tiny narration crop on page 12 carries the label.

This follows the annotator's existing [one-frame fallback](tools/manga_annotator/dataset_manager.py): a page with one rectangle defaults to `single_page`, even if that rectangle is a partial crop or extends into subsequent images. It is not evidence that you manually declared every one of those crops a full-page illustration.

Before a reader or benchmark uses that metadata as an explicit full-page instruction, we should distinguish a deliberate full-source-page marker from this legacy classification. I have only documented the ambiguity here.

## Do we need separate manhwa algorithms?

**We need manhwa-specific handling. We do not yet have evidence that two entirely independent detector implementations are necessary.**

The current [collector](src/_panelcollector.lua) builds a bitmap and runs a detector for one source page at a time. The existing [Smart](src/_smartcomponentdetector.lua) and [Safe](src/_safecomponentdetector.lua) detectors apply fixed-layout panel heuristics and reading-order logic. Running that pipeline unchanged cannot fully reproduce a rectangle that begins on one image and ends several images later.

My tentative recommendation is:

1. Keep the Manga/Comic behavior and defaults intact.
2. Dispatch to a manhwa pipeline only when Manhwa mode is selected. Keep the visible names **Smart** and **Safe**.
3. Share low-level image analysis where it is useful, but isolate manhwa grouping, cross-page continuity, ordering, and any tuning values.
4. Let manhwa Safe and Smart have different grouping or subdivision policies if your explanation confirms that this is the intended distinction.

The rectangle maps suggest that shared detection followed by different subdivision policies could be enough. Your Safe mapping could describe continuous reading regions, and Smart could subdivide some of them. That is a design hypothesis, not an implementation decision.

The current component detectors are procedural algorithms, not models that learn when a dataset is read. Merely inspecting or later benchmarking these annotations will not retrain them. Your concern still matters: changing shared heuristics to improve this chapter could regress Manga/Comic behavior. Separate dispatch, settings, and regression expectations would protect against that.

One chapter also cannot establish a general policy for all manhwa. The current material supports vertical compositions, floating text, large sound effects, and black/white pacing gaps; it provides little evidence about more complicated side-by-side layouts.

## What I would evaluate later, after your review

Smart predictions should be compared with your Smart mapping, and Safe predictions with your Safe mapping, using continuous strip coordinates. Comparing a whole Safe scene to individual Smart pieces as though one must be wrong would misread your annotations.

The later checks should distinguish missing readable content, incorrect grouping, unwanted seam cuts, reading order, and crop-edge differences. Existing Manga/Comic regression expectations should remain separate. Long Safe rectangles also require a viewer policy that keeps them readable; shrinking a 4,899-pixel-tall crop to one screen could defeat the reason for preserving it.

No such detector evaluation has been started.

## Your corrections / intended rules

Please edit these directly; my interpretations above remain provisional.

YES: Is the distinction between an artistic panel and a convenient reading chunk!, thats the problem im facing.

Yes we need a separate both algorithms. Lets start with safe algorithm only manwa, not smart.
Ignore the smart algorithm of manhwa datasets for now(make it a easy boolean value at the start of file, so is easily changeable)

- **Safe's intended priority:**

 distinction between an artistic panel and a convenient reading chunk!, thats the problem im facing.

- **Smart's intended priority:**

  not yet, explained mbefore

- **The six Smart subdivisions:** Were these chosen for shorter viewing steps, actual panel boundaries, a size limit, or another reason?

                                                        I've found 3 cases that my visual human ey
                                                              prefer to organize the panels better

                  EARLY ILLUSTRATION                                 LATE ILUSTRATION                   multiple ilustration hard
                    CASE 1                                              CASE 2                              CASE 3
               ┌───────────────┐                                   ┌───────────────┐                  ┌───────────────┐
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
               │               │                                   │               │                  │               │
           │ ──┼───────────────┼─                                  │               │                  │               │ ─────────
           │   │               │                                   │               │                  │               │ Could be  CASE 1  start
           │   │               │                                   │               │                  │               │  OR case 2 start
           │   ┌───────────────┐                          ─────────┼───────────────┼                  ┌───────────────┐ ┌────────
           │   │               │                  Starts at        │               │                  │               │
This is    │   │               │                  perfect beginning│               │                  │               │
onepanel   │   │               │                  of page          │               │                  │               │
even if    │   │               │                                   │               │                  │               │
starts     │   │               │                                   │               │                  │               │
a little   │   │               │                                   │               │                  │               │
by the     │   │               │                                   │               │                  │               ├───────────────┐
emd pf     │   │               │                                   │               │                  │               │               │
previous   │   │               │                                   │               │                  │               │               │
page       │   │               │                                   │               │                  │               │               │
           │   │               │                                   │               │                  │               │               │
But ends   │   │               │                                   │               │                  │               │               │
in perfect ┴───┼───────────────┼────                               ┌───────────────┐                  ┌───────────────┐               │
end of page    │               │                    but ends a litt│               │                  │               │               │
               │               │               in the beginning    │               │                  │               │               │
               │               │              of next     ─────────┼───────────────┼                  │               │               │
               │               │                 page              │               │                  │               │               │      A very big
               │               │                                   │               │                  │               ├───────────────┼────  illustration
               │               │                                   │               │                  │               │               │      but divided evenly
               │               │                                   │               │                  │               │               │
               │               │                                   │               │                  │               │               │
               │               │                                   │               │                  │               │               │
               │               │                                   │               │                  │               │               │
               │               │                                   │               │                  │               │               │
               │               │                                   │               │                  │               │               │
               └───────────────┘                                   └───────────────┘                  ┌───────────────┐               │
                                                                                                      │               │               │
                                                                                                      │               │               │
                                                                                                      │               │               │
                                                                                                      │               │               │
                                                                                                      │               ├───────────────┘
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │ ─────────────
                                                                                                      │               │
                                                                                                      │               │ could be case 2  ending
                                                                                                      ┌───────────────┐        or case 1 ending
                                                                                                      │               │
                                                                                                      │               │ ──────────────
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      │               │
                                                                                                      └───────────────┘

Mainly this reasons.

- **The shared source-page cuts around pages 7–11:** Are these intentional exceptions or unfinished grouping?

???i dont understand

- **Detached text, credits, and very tall scenes:** Which should become separate navigation stops, and how should the reader present a scene taller than the screen?

  _Your notes:_
separate them if its very high in height
Implementation and detector testing are stopped here for your review.


Sinopsis:

- Separate manhwa algorithms, leaving Manga/Comic behavior untouched.
- Implement manhwa Safe first. Keep manhwa Smart disabled through an obvious top-of-file boolean.
- Case 1: include the illustration’s beginning near the bottom of the previous source page.
- Case 2: include its ending near the beginning of the next source page.
- Case 3: divide a very tall illustration into balanced, readable sections, while preserving its actual beginning and ending.
