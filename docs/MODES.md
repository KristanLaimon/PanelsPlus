# Deep mode

Panels+ has one panel-detection mode: **Deep mode**. Stored detector preferences
from older versions are migrated to the single current implementation
(`components`) when settings are loaded.

See [DETECTION.md](DETECTION.md) for the full algorithm and
[ARCHITECTURE.md](ARCHITECTURE.md) for how detection fits into the viewer.

## What Deep mode does

Deep mode renders a reduced page bitmap, estimates the page background, and
turns the raster into a binary ink map. `ComponentDetector` then finds
8-connected ink components, checks their boundaries for straight panel-frame
support, removes contained or implausibly small regions, groups nearby artwork,
validates the result, and sorts it in the selected reading order.

Fixed-layout documents and images extracted from EPUB, KEPUB, and MOBI use the
same pipeline. Only the bitmap source and coordinate space differ.

If a source cannot provide the reduced bitmap, Panels+ may invoke KOReader's
K2PDFOpt/Leptonica detector as an internal compatibility fallback. It is not a
second mode and cannot be selected by the reader. If detection still cannot
produce a trustworthy panel list, the page is represented by one full-page
panel so the reading sequence can continue.

## What the other “modes” mean

These viewer controls are independent of panel detection:

- **Manga mode** sorts panels right to left.
- **Comic mode** sorts panels left to right.
- **Strict**, **Loose**, **With margin**, and **No crop** control the viewport
  around a detected rectangle.
- **Classic**, **Smooth**, and **Animated** control transitions between panels.
- **Invert panel swipe direction** changes the navigation gesture without
  changing either detection or reading order.

**Auto-rotate double-page spreads** turns a wide full-page or lone illustration image inside
the panel viewer when the screen is portrait. The device stays in its current
orientation, and ordinary panels return to their normal orientation. A manual
choice in the rotation picker takes priority; choose **Auto** in that picker to
resume automatic rotation. The option is enabled by default in the Panels+
menu.

**Rotate the screen for double-page spreads** does the same for the reading
page, where there is no image to rotate. When a page turn lands on a page at
least 1.3 times as wide as it is tall, the screen is rotated to landscape before
the page is painted, and the next normal page restores the rotation the reader
was using. While pages are turned in quick succession (less than 0.8 s apart)
nothing is rotated until the turning stops, so flipping past a spread does not
rotate the screen twice. It uses the same direction as the viewer, so the device is held the
same way for both. A screen already in landscape is left alone, a spread the
reader rotates back by hand is skipped, and the temporary rotation is not saved
with the book. When the panel viewer opens from a rotated spread, the screen is
restored first so panels are shown upright, unless the spread has nothing but
the whole page to show. The option is off by default.

**Remove the fold line from double-page spreads** applies in the panel viewer to
the whole-spread view and to any panel that crosses the fold. Some scans join the
two pages with a solid black strip. When the render has a strip at the page's
centre that is black over its full height, within 3% of the page width of the
centre and at most 4% of the page width, the two sides are joined without it.
Columns next to the strip that scaling has blurred are removed too. The joined
image keeps the size of the render, with the two sides centred on white, so it
is shown at the same scale and is not resampled. Dark artwork that runs across
the fold does not match and is left alone.
Touch positions and lookup highlights account for the removed strip. The option
is on by default.

The same is done on the reading page. KOReader draws a page from a cached tile,
so the plugin wraps the open document's `drawPage`. It keeps a joined copy of the
tile's bitmap and puts it in the tile's place while KOReader's own `drawPage` runs,
so night mode inversion and dithering work as usual. The cached tile's pixels are
not changed, and the copy has the same size, so zoom and panning are unchanged. At
most three joined copies are kept. Only a tile that covers the whole page is processed. When a page
is zoomed in so far that KOReader renders it in parts, the strip stays.

The reading-page parts (screen rotation and fold line removal) also work while
**Disable plugin panel focusing** is on. That setting only hands panel zoom back to
KOReader.

Spread rotation is one entry with four choices (off, in the panel viewer, while reading,
in the panel viewer and while reading). It and the fold line option are in the Panels+ menu and under `[Rotation]` in
`More Panel Viewer Settings`.

There is no detector selector or detector cycle in the current UI.

## Diagnosing detection

Enable **Panels+ → Enable debugging logs**, reopen the page, and inspect
KOReader's `crash.log`. Panels+ messages begin with `[Panels+]`. They report
bitmap construction, native fallback, render timings, and memory checks.

There is no alternate detector mode to switch to when a page is misread. See
[DETECTION.md](DETECTION.md) for the relevant heuristics, settings, and known
limitations.
