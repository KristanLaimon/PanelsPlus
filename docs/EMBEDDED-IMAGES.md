# Embedded EPUB, KEPUB, and MOBI images

Panels+ supports images embedded in reflowable `.epub`, `.kepub`, and `.mobi`
books. Kobo sync normally names KEPUB books `.kepub.epub`, which Panels+
recognizes through its EPUB suffix; a directly named `.kepub` is also accepted
when KOReader opens it in its rolling reader.
Long-press an image: Panels+ extracts that bitmap, finds its panels, and opens
the usual panel reader. At the first or last panel it turns reader pages and
looks for the previous or next image with a usable panel layout.

This is deliberately different from CBZ/CBR/PDF. Those formats expose a
fixed document page, while EPUB/KEPUB/MOBI are laid out again whenever font,
margins, orientation, or line spacing change.

## Embedded-image detector

This is **Embedded detection**, one of Panels+' two source backends. Fixed-page
detection handles CBZ/CBR/PDF pages; Embedded detection handles a decoded image
extracted from a reflowable book. Both always use the same **Deep mode**
component pipeline; only the source image and coordinate space differ. See
[Detection](DETECTION.md#one-mode-two-source-backends).

There is no separate detector selector for embedded images. Stored detector
values from older versions are normalized to `components`, just like
fixed-page values.

Deep mode uses the same target-size raster, background-relative ink map, and
8-connected component analysis as CBZ/CBR/PDF.
The source differs necessarily: fixed-layout files supply a rendered document
page, while EPUB/KEPUB/MOBI supply a decoded image. Before detection, an
embedded image is resampled into the same target-size bounds (without
enlarging small images), so connected borders and gutters are classified at
the same scale in both backends.

On low-memory devices, that resize is guarded before allocating its temporary
copy. If the safety floor cannot be maintained, Panels+ uses the older bounded
sparse map for that one image instead of risking an out-of-memory kill. The
full-resolution image remains untouched in either case.

For an embedded image the component detector's coordinates are image-space,
not reflow-page-space, so its rectangles can be cropped directly from the
retained bitmap. This is the key adaptation: Panels+ analyzes the extracted
image itself instead of sending the surrounding text page to a fixed-document
renderer.

If the reduced ink map cannot be allocated or built, Panels+ may internally
copy the extracted bitmap into K2PDFOpt and run its native component collector.
That memory-guarded compatibility path is a fallback inside Deep mode, not a
reader-selectable detection mode.

On an image-to-image boundary, Panels+ keeps only the already-rendered current
crop on screen. It immediately releases the old full source bitmap, its lazy
crop closures, and any stale queued page search before scanning later reflow
pages. This prevents one large EPUB/KEPUB/MOBI image from staying resident throughout
an arbitrarily long search. Intermediate reader-page turns also cancel stale
one-shot hardware animation state. In **Nav. Animated**, once the destination
image and its first (or last) panel are ready, Panels+ arms one framebuffer
animation immediately before replacing the viewer. The same boundary effect is
available for fixed-layout PDF, CBZ, and CBR documents.

Long-pressing **Nav. Animated** opens two independent, default-on controls:
**Animate between panels** and **Animate between pages**. Classic remains an
instant switch, while Smooth retains its camera-pan settings.

## Smooth navigation

For fixed-layout documents, smooth navigation renders the union of the old and
new panel rectangles from the document page, places that result on a temporary
canvas, then pans the camera across it. The key operation is effectively:

```lua
document:drawPagePart(page, union_of_panel_rectangles, 0)
```

An embedded image has no `page`/`drawPagePart()` coordinate pair. Passing its
image-space rectangles to that API would crop unrelated text-page content, or
fail. Embedded images instead render the union directly from their retained
decoded bitmap, then use the same camera-pan logic as fixed-layout panels.

The **Nav. Smooth** and **Nav. Animated** controls are available for panels on
the same embedded image. The mode preference is separate from fixed-layout
documents, and Smooth's source-union cap falls back to an instant panel switch
before making a large temporary bitmap.

Smooth animation **between images** is a separate, more expensive problem:
the images may be on different reflow pages, have unrelated sizes, and require
a page turn plus an asynchronous search before the next image is known. The
camera-pan scope therefore remains limited to panels of the same image.
In Animated mode, image-to-image boundaries use the framebuffer effect when
**Animate between pages** is enabled; otherwise they use the classic instant
handoff.

## What remains available

- Manga/Comic reading order. The viewer re-detects and reorders the same image.
- Strict, loose, margin, and no-crop modes. The viewer rebuilds from the
  retained source bitmap when a crop needs new pixels.
- Tap/swipe configuration, progress bar, screenshots, zoom, and rotation.
- Forward/backward image flow: after a boundary, Panels+ moves through text
  pages until it finds another embedded image whose panel layout is accepted.

## Practical roadmap

1. Add image fixtures for manga, comics, dark pages, SVG/raster edge cases,
   and small inline images to tune Deep detection further.
2. Continue improving component grouping for layouts whose borders cannot be
   separated reliably from the reduced ink map.

These alternatives are intentionally scoped to extracted EPUB/KEPUB/MOBI images.
They do not change the fixed-page algorithms or add work to CBZ/CBR/PDF reads.
