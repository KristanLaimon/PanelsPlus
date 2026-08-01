# Changelog

All notable changes to the **Panels+** KOReader plugin are documented in this file. From version v1.2.0

## [Unreleased]

### Added

- **Left-Edge Vertical Swipe Gestures (One-Handed Zoom & Exit)**
  - **Swipe UP on the left edge** (left 25% of screen): Zooms in on the current panel image to easily inspect small text or fine details without needing multi-finger pinch gestures.
  - **Swipe DOWN on the left edge**:
    - *When zoomed in*: Steps back out towards standard panel zoom level.
    - *When at standard panel zoom*: Closes the panel viewer and returns directly to full-page reader view (matching native KOReader panel-zoom behavior).
  - General image panning across the rest of the screen remains fully preserved when zoomed in.

- **Physical Buttons & Bluetooth Page Turner Integration**
  - **Boundary Page Crossing**: Advancing past the last panel of a page via physical side buttons (e.g., Kobo Libra Colour) or Bluetooth remotes now automatically turns the document page and opens panel 1 of the next page. Swiping/pressing back from panel 1 similarly crosses into the previous page.
  - **Standard Reader Action Handlers**: Added explicit event handlers for `GotoNextPage`, `GotoPrevPage`, `PageForward`, `PageBackward`, `ShowNextPage`, `ShowPrevPage`, `PhysicalPageForward`, and `PhysicalPageBackward`.
  - **Full Compatibility with `kobo.koplugin`**: Any Bluetooth controller or page-turner plugin sending KOReader dispatcher actions is now supported out-of-the-box with zero extra configuration.

---

## [v1.1.0]

### Added
- **Smooth Panel-to-Panel Navigation**: Switch panels with camera panning transitions instead of instant cuts.
- **Cross-Page Camera Panning**: Camera pan animation across page boundaries when adjacent page panels are cached.
- **"No Crop" Render Mode**: Render panels centered in screen window without clipping nearby page area.
- **Expanded Loose Crop Bleed**: Bleed ratio slider up to 100%.

### Fixed
- Fixed memory leaks in transition canvas and detection passes on low-memory devices (Kindle).
