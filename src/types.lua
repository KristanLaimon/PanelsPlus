--- Shared LuaLS annotations for Panels+.
---
--- This module is intentionally side-effect free. It exists so Sumneko/LuaLS can
--- index the plugin's record shapes even when values originate from KOReader.

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
--- @alias PPDetector '"auto"'|'"fast"'|'"exact"'

--- Panel-to-panel navigation transition style.
--- @alias PPNavTransitionMode '"classic"'|'"smooth"'

--- Persisted plugin settings.
--- @class PPSettings
--- @field enabled boolean
--- @field mode PPReadingMode
--- @field crop_mode PPCropMode
--- @field panel_margin_ratio number Zoom-out fraction the "margin" crop mode applies to non-full-page panels.
--- @field invert_swipe boolean
--- @field progress_bar_visible boolean
--- @field nav_transition_mode PPNavTransitionMode Instant swap vs. animated camera pan between panels.
--- @field nav_transition_duration number Seconds the smooth camera pan takes.
--- @field nav_transition_cross_page boolean Whether smooth navigation also animates across page boundaries.
--- @field nav_transition_frames integer Number of discrete steps a smooth camera pan is split into.
--- @field detector PPDetector
--- @field panel_grid_cols integer
--- @field panel_grid_rows integer
--- @field panel_bleed_ratio number Fraction of extra page area "loose" crop mode reveals around each panel.
--- @field panel_bleed_min number
--- @field panel_prefetch_delay number
--- @field panel_cache_pages integer
--- @field panel_prerender boolean Warm the next panel's tile while idle.
--- @field panel_prerender_delay number Idle seconds before warming the next panel.
--- @field prerender_min_free_bytes integer Free bytes below which prerendering is skipped.
--- @field native_detect_min_free_bytes integer Free bytes below which native (Outline) detection is skipped entirely.
--- @field full_page_panel_ratio number
--- @field segment_target_width integer Ink-map render width in pixels.
--- @field segment_ink_delta integer Luminance distance from background counted as ink.
--- @field segment_gutter_ratio number Shortest gutter, as a fraction of the map's smaller side.
--- @field segment_gutter_ink_ratio number Ink fraction of a line still treated as empty.
--- @field segment_min_panel_area number Smallest panel, as a fraction of page area.
--- @field segment_min_panel_side number Smallest panel side, as a fraction of the map's smaller side.
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

--- Options accepted by `showPanelViewerForPage`.
--- @class PPShowViewerOptions
--- @field buttons_visible boolean|nil Show viewer controls immediately.
--- @field defer_preload boolean|nil Skip next-page prefetch when true.
--- @field return_viewer boolean|nil Return the viewer instance instead of `true`.

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

return {}
