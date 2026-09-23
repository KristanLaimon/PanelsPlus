--[[
Panels+
File: src/types.lua
Name: Types
Description: Declares side-effect-free LuaLS annotations for shared Panels+ record shapes.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Shared LuaLS annotations for Panels+.
---
--- This module is intentionally side-effect free. It exists so Sumneko/LuaLS can
--- index the plugin's record shapes even when values originate from KOReader.

--- KOReader WidgetContainer base class stub for LuaLS.
--- @class WidgetContainer

--- KOReader ImageViewer widget base class stub for LuaLS.
--- @class ImageViewer

--- KOReader InputContainer widget base class stub for LuaLS.
--- @class InputContainer

--- KOReader plugin that replaces native panel zoom with ordered panel reading.
---
--- @class PanelsPlus : WidgetContainer
--- @field name string KOReader plugin id.
--- @field is_doc_only boolean Whether the plugin requires an opened document.
--- @field ui table KOReader reader UI object injected by WidgetContainer.
--- @field settings PPSettings Runtime plugin settings.
--- @field panel_cache table<string, PPPanel[]> Per-page panel cache.
--- @field panel_cache_order string[] LRU cache key order.
--- @field panel_prefetch_actions table<string, function> Scheduled prefetch jobs, by cache key.
--- @field panel_prerender_action function|nil Scheduled next-panel warm-up, if any.

--- Reading order used to sort panels and interpret horizontal swipes.
--- @alias PPReadingMode '"manga"'|'"comic"'

--- Crop behavior for drawing panel image parts.
--- @alias PPCropMode '"strict"'|'"loose"'|'"margin"'|'"none"'

--- Direction reported when the viewer crosses the first or last panel.
--- @alias PPBoundaryDirection '"next"'|'"previous"'

--- Document page-space rectangle.
--- @class PPRect
--- @field x number Left coordinate.
--- @field y number Top coordinate.
--- @field w number Width.
--- @field h number Height.

--- Native panel rectangle returned by KOReader's document detector.
--- @class PPPanel : PPRect

--- Document page dimensions.
--- @class PPPageSize
--- @field w number Page width.
--- @field h number Page height.

--- Position in page coordinates.
--- @class PPPagePosition
--- @field page number Document page number.
--- @field x number X coordinate on the page.
--- @field y number Y coordinate on the page.

--- Which detector `PanelCollector.collect` should use.
--- @alias PPDetector '"components"'|'"exact"'

--- Panel-to-panel navigation transition style.
--- @alias PPNavTransitionMode '"classic"'|'"smooth"'|'"animated"'

--- Persisted plugin settings.
--- @class PPSettings
--- @field enabled boolean
--- @field mode PPReadingMode
--- @field crop_mode PPCropMode
--- @field panel_margin_ratio number Zoom-out fraction the "margin" crop mode applies to non-full-page panels.
--- @field invert_swipe boolean
--- @field invert_taps boolean
--- @field kobo_vertical_gesture boolean Whether vertical swipes on the left edge zoom in/out (Kobo-style).
--- @field panel_gesture string Gesture that opens panels on a page: "hold" (long press, the default) or "two_finger_tap".
--- @field remember_doc_settings boolean Whether per-document settings (mode, nav mode, progress bar, crop mode) are saved & restored.
--- @field doc_settings table<string, table>|nil Per-document settings map fallback.
--- @field progress_bar_visible boolean
--- @field ocr_bundled_language string Three-letter bundled OCR language code: eng, spa, or ita.
--- @field nav_transition_mode PPNavTransitionMode Classic, Smooth camera-pan, or framebuffer Animated navigation.
--- @field nav_animated_panels boolean Whether Animated mode animates panel-to-panel switches.
--- @field nav_animated_pages boolean Whether Animated mode animates page-boundary switches.
--- @field nav_transition_duration number Seconds the smooth camera pan takes.
--- @field nav_transition_cross_page boolean Whether smooth navigation also animates across page boundaries.
--- @field nav_transition_frames integer Number of discrete steps a smooth camera pan is split into.
--- @field detector PPDetector
--- @field embedded_detector PPDetector Bitmap-only detector for embedded EPUB/KEPUB/MOBI images.
--- @field embedded_nav_transition_mode PPNavTransitionMode Navigation mode for embedded EPUB/KEPUB/MOBI images.
--- @field panel_grid_cols integer
--- @field panel_grid_rows integer
--- @field panel_bleed_ratio number Fraction of extra page area "loose" crop mode reveals around each panel.
--- @field panel_bleed_min number
--- @field panel_prefetch_delay number
--- @field panel_cache_pages integer
--- @field panel_prerender boolean Warm the next panel's tile while idle.
--- @field panel_prerender_delay number Idle seconds before warming the next panel.
--- @field prerender_min_free_bytes integer Free bytes below which prerendering is skipped.
--- @field native_detect_min_free_bytes integer Free bytes below which native K2PDFOpt detection is skipped entirely.
--- @field full_page_panel_ratio number
--- @field segment_target_width integer Ink-map render width in pixels.
--- @field segment_ink_delta integer Luminance distance from background counted as ink.
--- @field segment_border_split boolean Comic mode only: split panels on the drawn border stroke between edge-to-edge panels. Experimental and off by default; also splits panels containing a drawn black line.
--- @field segment_border_luminance_max integer Comic mode only: absolute luminance at/below which a cell is a candidate drawn panel-border stroke, regardless of the page background.
--- @field segment_border_line_ratio number Comic mode only: fraction of a line's span that must be border cells for it to count as a drawn separator.
--- @field segment_border_width_ratio number Comic mode only: widest run, as a fraction of the map's smaller side, still accepted as a border stroke rather than a filled panel interior.
--- @field segment_gutter_ratio number Shortest gutter, as a fraction of the map's smaller side.
--- @field segment_gutter_ink_ratio number Ink fraction of a line still treated as empty.
--- @field segment_min_panel_area number Smallest panel, as a fraction of page area.
--- @field segment_min_panel_side number Smallest panel side, as a fraction of the map's smaller side.
--- @field segment_sliver_aspect number Long-to-short side ratio at or above which a panel is elongated enough to be checked against `segment_sliver_ink`.
--- @field segment_sliver_ink number Least share of the page's total ink an elongated panel must contain, rejecting page furniture that clears the size floors.
--- @field segment_max_depth integer Deepest recursion allowed in the X-Y cut.
--- @field segment_max_panels integer Hard cap on panels produced per page.
--- @field segment_coverage_min number Least share of the covered region the panels must retain.
--- @field segment_page_coverage_min number Least share of the page the panels must span.
--- @field segment_single_panel_ratio number Least share of the page a lone panel must cover.
--- @field segment_shear boolean Look for slanted gutters when no straight one exists.
--- @field segment_shear_max_depth integer Deepest recursion level allowed to search for slanted gutters.
--- @field segment_shear_trigger number Emptiest line, as a fraction of span, that triggers a slanted search.
--- @field segment_shear_step integer Sample every Nth line while searching for slanted gutters.
--- @field debug_mode boolean Write panel pipeline timings and memory usage to the KOReader log.
--- @field performance_profile_version integer
--- @field image_rotation number|boolean|nil Plugin-only zoomed-view rotation set from the rotation picker; `nil` until the reader picks one. `false` (or 0) is an explicit "no rotation" choice, distinct from `nil`'s "let the document's own auto-rotation decide".

--- Options accepted by `showPanelViewerForPage`.
--- @class PPShowViewerOptions
--- @field buttons_visible boolean|nil Show viewer controls immediately.
--- @field defer_preload boolean|nil Skip next-page prefetch when true.
--- @field return_viewer boolean|nil Return the viewer instance instead of `true`.
--- @field replace_viewer PanelViewer|nil Existing viewer to replace after the destination viewer has been constructed.
--- @field boundary_direction PPBoundaryDirection|nil Page-turn direction used to arm a native animation during replacement.

--- KOReader ImageViewer lazy image list.
--- @class PPImageList : table
--- @field image_disposable boolean Whether ImageViewer owns decoded panel images.
--- @field rotated boolean|nil Last rotation flag returned by `drawPagePart`.

--- Result of a side-effect-free adjacent-page lookup for boundary crossings.
--- @class PPBoundaryResolution
--- @field next_page number Adjacent document page number.
--- @field panels PPPanel[] Adjacent page's ordered panel rectangles.
--- @field start_idx integer 1-based panel index the crossing should land on.
--- @field target_rect PPPanel Crop rectangle (post crop-mode expansion) for the landing panel.
--- @field target_is_full_page boolean Whether the landing panel spans nearly the whole page.

--- ImageViewer subclass for navigating one page's ordered panel sequence.
---
--- @class PanelViewer : ImageViewer
--- @field reading_mode PPReadingMode Current left/right panel order.
--- @field crop_mode PPCropMode Current crop rendering mode.
--- @field margin_ratio number Zoom-out fraction "margin" crop mode applies to non-full-page panels.
--- @field bleed_ratio number Fraction of extra page area "loose" crop mode reveals around each panel.
--- @field panel_is_full_page boolean[]|nil Per-panel flag matching `_images_list`, true when a panel spans nearly the whole page.
--- @field detector PPDetector Detector the displayed panels came from.
--- @field detector_cycle_callback fun(viewer:PanelViewer):boolean|nil
--- @field invert_swipe boolean Whether horizontal swipe direction is inverted.
--- @field invert_taps boolean Whether side tap direction is inverted.
--- @field tap_navigation boolean Whether tapping the left/right screen edges navigates between panels.
--- @field swipe_navigation boolean Whether horizontal swipes navigate between panels.
--- @field kobo_vertical_gesture boolean Whether vertical swipes on the left edge zoom in/out (Kobo-style).
--- @field panel_gesture string Gesture that opens panels on a page: "hold" (long press, the default) or "two_finger_tap".
--- @field more_config_callback fun(viewer:PanelViewer):boolean|nil
--- @field progress_bar_visible boolean Whether the bottom progress bar is shown.
--- @field nav_transition_mode PPNavTransitionMode Classic, Smooth camera-pan, or framebuffer Animated navigation.
--- @field nav_animated_panels boolean Whether Animated mode animates panel-to-panel switches.
--- @field nav_animated_pages boolean Whether Animated mode animates page-boundary switches.
--- @field nav_transition_duration number Seconds the smooth camera pan takes.
--- @field panel_animation_callback fun(direction:PPBoundaryDirection, viewer:PanelViewer):boolean|nil

--- A tappable wrapper around one child widget.
---
--- @class TapTarget : InputContainer

--- Dialog for picking image or device rotation.
---
--- @class RotationPickerDialog : InputContainer
--- @field on_device_rotate fun(direction: "up"|"down"|"left"|"right")|nil
--- @field on_image_rotate fun(direction: "up"|"down"|"left"|"right")|nil

--- Panel viewer orchestration methods mixed into `PanelsPlus`.
--- @class PPViewerControllerMethods

--- Native panel-zoom integration methods mixed into `PanelsPlus`.
--- @class PPNativePanelZoomMethods

--- Main-menu methods mixed into `PanelsPlus`.
--- @class PPMenuMethods

--- Panel cache and prefetch methods mixed into `PanelsPlus`.
--- @class PPCacheMethods

--- Dispatcher action and event-handler methods mixed into `PanelsPlus`.
--- @class PPActionMethods

--- Ink-map segmenter module.
--- @class PPSegmenterModule

--- Document page bitmap helper module.
--- @class PPPageBitmapModule

--- Document page grayscale/color ink map.
--- @class PPPageMap

--- Geometry helper functions module.
--- @class PPGeometryModule

--- Memory stats helper module.
--- @class PPMemoryModule

--- Panel collector module.
--- @class PPPanelCollectorModule

--- Word finder / OCR helper module.
--- @class PPWordFinder

--- Settings storage and migration module.
--- @class PPSettingsModule

--- Timing and profiling helper module.
--- @class PPTimingModule

--- Native panel detector module.
--- @class PPNativeDetectorModule

return {}
