# Changelog

All notable changes to the **Panels+** KOReader plugin are documented in this file. From version v1.2.0

## [Unreleased]

### Added

- **Comic-Lettering-Aware Word Finder & OCR Segmentation**
  - **Local Line Height & Gap Thresholding**: Scoped vertical line extent detection (`row_ink`) to a local horizontal column band (~60px around tap point) in `src/_wordfinder.lua`. Prevents multi-word lines (e.g., "what's for dinner?") from merging into giant multi-line blocks that break Tesseract OCR.
  - **Tight Box Bounds**: Reduced internal padding (`PAD_RATIO` -> `0.02`) so KOReader's native `getNativeOCRWord` 30% expansion produces clean, tight crops without bleeding into neighboring words (fixing "uh?" -> "are" and "not" -> "o").
  - **Robust Background & Polarity Estimation**: Used 75th percentile crop luminance to accurately identify paper background vs text ink for both standard and inverted (white-on-dark) comic text.

- **Diagnostic Logging & On-Screen Visual Toasts**
  - **Programmatic Log File (`/tmp/panels_wordfinder.log`)**: Appends tap coordinates, background/polarity, line height, calibrated gap threshold, resulting box dimensions, final OCR text, and text-art column ink maps (e.g. `|###..#####..###|`) for easy copy/pasting and troubleshooting.
  - **KOReader Logger Integration**: Tagged entries with `[Panels+ WordFinder]` in KOReader `logger.info` output.
  - **On-Screen Notification Toast**: Displays transient `[WordFinder] 'recognized_word' (120x35)` toast on text selection for instant visual confirmation.

- **Tesseract OCR Memory Leak Prevention**
  - **Cleanup & Purging**: Added `WordFinder.cleanup()` and integrated it into `PanelViewer:onClose` and document teardown. Explicitly evicts cached `OCREngine` objects from `DocCache` and calls `freeOCR()`, releasing all Tesseract DAWGs (`eng.traineddatapunc-dawg`, `eng.traineddataword-dawg`, etc.) and eliminating C++ `ObjectCache` leak warnings on KOReader shutdown.

- **Comic-Mode Panel Border Detection (bleed layouts, dark/colored panels)**
  - **Problem**: the fast segmenter only ever looked for blank (background-coloured) gutters between panels. Western comics routinely bleed differently-coloured, dark, or grey panels edge to edge with no blank gutter at all -- only the artist's drawn black border stroke -- which the old search had nothing to find and either mis-split or gave up on, falling back to the native detector that explicitly can't handle dark backgrounds either. Verified against a dark, multi-colour CBR (Deadpool) with heavy bleed panels.
  - **Border-stroke ink map**: `src/_pagebitmap.lua` now builds a second, absolute-luminance flag array (`map.border`) alongside the existing background-relative ink map, marking near-black cells regardless of the page's own background colour. Built only when `mode == "comic"`; manga pages never pay for it.
  - **Border-line separator search**: `src/_segmenter.lua` adds `findBorderLine`/`projectWithBorder`, tried after the existing blank-gutter search and before the slanted-gutter ladder. It looks for a thin (bounded-width), densely dark run spanning a region's full cross-section -- a drawn panel border -- as opposed to a wide dark run, which is treated as a filled panel interior and left alone.
  - **New settings**: `segment_border_luminance_max` (60), `segment_border_line_ratio` (0.97), `segment_border_width_ratio` (0.01), all comic-mode only.
  - **Fixed false splits found in on-device testing**: a tall, roughly centered character silhouette on a grey background could mimic a drawn vertical rule closely enough to trigger a false split, and a thin page-footer rule near the page edge could get carved off as its own tiny "panel". Tightened `segment_border_line_ratio` (0.85 -> 0.97, a drawn rule is essentially 100% solid; an organic silhouette rarely is) and `segment_border_width_ratio` (0.02 -> 0.01), and `findBorderLine` now rejects any candidate line whose split would leave either side smaller than `min_side` -- the same floor `emitLeaf` already enforces on real panels, applied before the split happens instead of after.
  - **Deep mode ("exact" detector) no longer silently defeats comic mode**: it only recognizes white gutters and gives up on dark backgrounds, which comic pages routinely have. Switching to comic mode now forces the detector back to "auto" if Deep mode was active, and the "Deep mode" menu option is greyed out while comic mode is on.

- **Touch & Hold Text Selection & Dictionary Lookups in Zoom Mode**
  - **Screen-to-Page Coordinate Transformation**: Converted touch points on zoomed panel images (`_image_wg` blitbuffer viewport and pan offsets) to native document page coordinates `{x, y, page}`.
  - **Hold Gesture Delegation**: Added handlers for `onHold`, `onHoldPan`, `onHoldRelease`, and `onHoldPanRelease` in `PanelViewer` to delegate word selection and dictionary lookups to KOReader's `ReaderHighlight` module (`lookupDictWord`).
  - **Real-Time Text Selection Highlight Overlay**: Added `pageToScreenTransform(box)` and `paintHighlights(bb)` to render selection highlight boxes (`sboxes`/`pboxes`) directly on top of zoomed panel images in real-time.
  - **Settings & Menu Toggle**: Added `hold_text_selection` setting default and menu toggle under plugin settings (`"Touch & hold text selection in zoom"`).
  - **Works across CBZ, CBR, and PDF**: word/text boxes come from the document's own embedded OCR text layer on PDF, or from KOReader's on-the-fly OCR fallback on CBZ/CBR (which carry no text layer at all) -- the highlight/lookup path is shared, format-agnostic code.
  - **Fixed "big black square" highlight**: coarse or oversized word/line boxes (common with OCR on comic/manga art) no longer get filled solid with the "invert" drawer. `paintHighlights` now flags a box whose page-space area covers ≥60% of the current panel crop as anomalous and draws a thin outline instead of a full fill, so a bad box still gives visual feedback without obscuring the panel art.

- **Left-Edge Vertical Swipe Gestures (One-Handed Zoom & Exit)**
  - **Swipe UP on the left edge** (left 25% of screen): Zooms in on the current panel image to easily inspect small text or fine details without needing multi-finger pinch gestures.
  - **Swipe DOWN on the left edge**:
    - *When zoomed in*: Steps back out towards standard panel zoom level.
    - *When at standard panel zoom*: Closes the panel viewer and returns directly to full-page reader view (matching native KOReader panel-zoom behavior).
  - General image panning across the rest of the screen remains fully preserved when zoomed in.

- **Physical Buttons & Bluetooth Page Turner Integration**
  - **Boundary Page Crossing**: Advancing past the last panel of a page via physical side buttons (e.g., Kobo Libra Colour) or Bluetooth remotes now automatically turns the document page and opens panel 1 of the next page. Pressing back from panel 1 similarly crosses into the previous page.
  - **`GotoViewRel` Handler**: Added `PanelViewer:onGotoViewRel(diff)`, KOReader's standard relative page-turn event, so any input source that turns pages the normal KOReader way (hardware keys, the dispatcher's "Turn pages" action, `autoturn.koplugin`) drives panel-by-panel navigation instead of silently turning the underlying document page behind the panel viewer.
  - **Full Compatibility with `kobo.koplugin`**: Bluetooth controllers bound through `kobo.koplugin`'s essential actions (which fire `GotoViewRel`) are now supported out-of-the-box with zero extra configuration.

- **Developer & Testing Launcher Scripts**
  - Added `rungeneric.sh`: Easily launches KOReader Flatpak in standard desktop mode.
  - Added `runkobo.sh`: Launches KOReader Flatpak pre-configured with Kobo reader characteristics (632x840 resolution, 300 DPI, and e-ink grayscale rendering) for easy local testing.

### Fixed

- **Comic mode split single panels in two**
  - **Cause**: the drawn-border search keys on a thin, full-span, densely dark run. That is what a stroke shared between two edge-to-edge panels looks like -- and also exactly what a horizon, a caption rule, a letterbox band or a pole drawn *inside* one panel looks like. In the ink map the two are byte-identical, so no threshold separates them, and every page carrying such a line had a real panel cut in half.
  - **Fix**: the search is now opt-in via `segment_border_split` (default off) and a new **Panels+ → Panel detection → "Split on drawn panel borders (experimental)"** toggle, enabled only in comic mode. Off, those pages read correctly and genuinely bled layouts fall back to the already-documented "panels with no gutter" limitation -- one panel instead of two, which costs far less than half a panel. `src/_pagebitmap.lua` also skips building the border plane entirely when it is off, dropping a per-cell comparison and a full `w*h` allocation from every comic page.
  - The panel cache is keyed on the toggle, so flipping it re-detects rather than serving stale panels, and flipping back is instant.

- **Tiny "panels" containing no artwork** (both modes)
  - **Cause**: `emitLeaf` only had shape floors. A scanlation credit strip clears them comfortably -- at 182x20 on a 480x720 map it is 3640 cells against a 1728-cell area floor, and both sides beat the 14-cell side floor -- so it was emitted as a panel the reader then had to swipe through.
  - **Fix**: a leaf is now rejected when it is *both* elongated past `segment_sliver_aspect` (default `4`) **and** holds less than `segment_sliver_ink` (default `0.02`) of the page's total ink. The conjunction matters: measured on a typical page a credit strip is 0.96% of the page's ink at 9.1:1, but a legitimate 60x60 inset panel is only 1.51% and a 458x60 letterbox panel is 7.6:1 -- so an ink floor alone would drop the inset before the strip, and an aspect limit alone would drop both real panels. Only "stretched out **and** nearly empty" describes furniture and nothing else.
  - The ink floor is a share of the page rather than an absolute count, so a near-blank page with one small drawing still keeps it.

- **Test coverage**: added `tests/spec/segmenter_spec.lua`, driving the real `Segmenter.segment()` over synthetic maps built at the 480x720 size `_pagebitmap` actually produces, so the cut's fraction-of-map floors are exercised at the values real pages hit. Pins the grid and splash baselines, both fixes above, and the drawn-border ambiguity in both toggle states.

---

## [v1.1.0]

### Added
- **Smooth Panel-to-Panel Navigation**: Switch panels with camera panning transitions instead of instant cuts.
- **Cross-Page Camera Panning**: Camera pan animation across page boundaries when adjacent page panels are cached.
- **"No Crop" Render Mode**: Render panels centered in screen window without clipping nearby page area.
- **Expanded Loose Crop Bleed**: Bleed ratio slider up to 100%.

### Fixed
- Fixed memory leaks in transition canvas and detection passes on low-memory devices (Kindle).
