--- Shared LuaLS annotations for Panels+.
---
--- This module is intentionally side-effect free. It exists so Sumneko/LuaLS can
--- index the plugin's record shapes even when values originate from KOReader.

--- Reading order used to sort panels and interpret horizontal swipes.
--- @alias PPReadingMode '"manga"'|'"comic"'

--- Crop behavior for drawing panel image parts.
--- @alias PPCropMode '"strict"'|'"loose"'

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

--- Persisted plugin settings.
--- @class PPSettings
--- @field enabled boolean
--- @field mode PPReadingMode
--- @field crop_mode PPCropMode
--- @field invert_swipe boolean
--- @field panel_grid_cols integer
--- @field panel_grid_rows integer
--- @field panel_bleed_ratio number
--- @field panel_bleed_min number
--- @field panel_prefetch_delay number
--- @field panel_cache_pages integer
--- @field full_page_panel_ratio number
--- @field performance_profile_version integer

--- Options accepted by `showPanelViewerForPage`.
--- @class PPShowViewerOptions
--- @field buttons_visible boolean|nil Show viewer controls immediately.
--- @field defer_preload boolean|nil Skip next-page prefetch when true.
--- @field return_viewer boolean|nil Return the viewer instance instead of `true`.

--- KOReader ImageViewer lazy image list.
--- @class PPImageList : table
--- @field image_disposable boolean Whether ImageViewer owns decoded images.
--- @field rotated boolean|nil Last rotation flag returned by `drawPagePart`.

return {}
