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

There is no detector selector or detector cycle in the current UI.

## Diagnosing detection

Enable **Panels+ → Enable debugging logs**, reopen the page, and inspect
KOReader's `crash.log`. Panels+ messages begin with `[Panels+]`. They report
bitmap construction, native fallback, render timings, and memory checks.

There is no alternate detector mode to switch to when a page is misread. See
[DETECTION.md](DETECTION.md) for the relevant heuristics, settings, and known
limitations.
