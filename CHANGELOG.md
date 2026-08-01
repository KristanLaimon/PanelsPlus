# Changelog

All notable changes to the **Panels+** KOReader plugin are documented in this file. From version v1.2.0

## [Unreleased]

### Added

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

---

## [v1.1.0]

### Added
- **Smooth Panel-to-Panel Navigation**: Switch panels with camera panning transitions instead of instant cuts.
- **Cross-Page Camera Panning**: Camera pan animation across page boundaries when adjacent page panels are cached.
- **"No Crop" Render Mode**: Render panels centered in screen window without clipping nearby page area.
- **Expanded Loose Crop Bleed**: Bleed ratio slider up to 100%.

### Fixed
- Fixed memory leaks in transition canvas and detection passes on low-memory devices (Kindle).
