--[[
Panels+
File: src/segmenter/init.lua
Name: Segmenter
Description: Composes segmentation, acceptance and full-page fallback.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Geometry = require("src._smartgeometry")
local Settings = require("src._settings")

--- Panel segmentation by recursive X-Y cut over a page ink map.
---
--- Comic and manga pages are laid out as nested bands: a page splits into tiers,
--- a tier splits into panels, and the separators are gutters of bare background.
--- Recursively slicing on the widest empty band reproduces that structure
--- directly, and because "empty" is defined against the page's own background
--- (see `src._pagebitmap`) it is indifferent to whether the page is printed dark
--- on light or light on dark.
---
--- The cut cannot separate interlocking or staircase layouts, where no straight
--- line runs cleanly between two panels. `Segmenter.accept()` detects
--- implausible page-level results and is also reused by the production
--- component detector; rejected current-reader results become a full-page
--- panel rather than selecting another detector mode.
---
--- Comic mode can add a second kind of separator search, off by default behind
--- `segment_border_split`. Western comics routinely bleed differently-coloured,
--- dark, or grey panels edge to edge with no blank gutter between them at all
--- -- only the artist's drawn black border stroke. That stroke is invisible to
--- the background-relative gutter search (there is no empty band to find) but
--- stands out as a thin, densely dark run against whatever fills the panels
--- either side of it, so it gets its own pass over `map.border` (see
--- `src._pagebitmap`). Manga mode never builds `map.border`, so neither the
--- pass nor its cost apply there.
---
--- It is opt-in because at ink-map resolution the pattern it keys on is not
--- unique to a panel border. A shared border between two bled panels and a
--- black line drawn *through* one panel -- a horizon, a caption rule, a pole,
--- a letterbox band -- produce byte-identical maps: a thin, full-width, densely
--- dark run flanked by artwork. Nothing left in the map distinguishes them, so
--- no amount of tuning separates the two and the pass splits real panels in
--- half on any page carrying such a line. Off, those pages read correctly and
--- genuinely bled layouts fall back to the documented "panels with no gutter"
--- limitation -- one panel instead of two, which costs the reader far less than
--- a panel cut in half. On, bled layouts split at the price of that
--- false-positive rate.
---
--- @class PPSegmenterModule
local Segmenter = {}

--- Slopes tried when no straight gutter exists, as dx per unit y.
---
--- Panels are rarely drawn perfectly square, and a gutter tilted by even two
--- degrees leaves no column empty from top to bottom, which is enough to stop
--- the straight cut entirely. The ladder covers 2 to 8 degrees either way; the
--- spacing matters, since a coarser ladder straddles 5 degrees and misses the
--- most common case.
Segmenter.SHEAR_SLOPES = {
    0.035,
    -0.035, -- 2.0 degrees
    0.061,
    -0.061, -- 3.5
    0.087,
    -0.087, -- 5.0
    0.115,
    -0.115, -- 6.5
    0.141,
    -0.141, -- 8.0
}

require("src.segmenter.cut")(Segmenter)
require("src.segmenter.acceptance")(Segmenter)

local frame_pipeline

--- Detect panels for a page map, applying acceptance validation and fallback.
---
--- If `Segmenter.accept` rejects the segmentation (e.g. splash page, title page,
--- or single partial panel), safely falls back to a full-page panel.
---
--- @param map PPPageMap Page ink map.
--- @param settings PPSettings|table Plugin settings.
--- @return PPPanel[] panels Ordered panel rectangles in native page coordinates.
--- @return boolean accepted True if segmented panels were accepted, false if fallen back.
--- @return string|nil reason Rejection reason if not accepted.
function Segmenter.detectPage(map, settings)
    settings = settings or Settings.defaults
    local raw_panels = Segmenter.segment(map, settings)
    -- A page without a continuous gutter can still contain independently
    -- framed panels. Try frame extraction before accepting a single crop or
    -- falling back to the whole page. The pipeline uses accept(), not this
    -- entry point, so it cannot recurse into the gutter detector.
    if #raw_panels <= 1 then
        frame_pipeline = frame_pipeline or require("src._componentpipeline")()
        local framed, framed_ok = frame_pipeline.detectPage(map, settings)
        if framed_ok and #framed > 1 then
            return framed, true, nil
        end
    end
    local accepted, reason = Segmenter.accept(raw_panels, map, settings)
    if not accepted then
        return {
            {
                x = 0,
                y = 0,
                w = map.native_w,
                h = map.native_h,
            },
        },
            false,
            reason
    end
    local mode = (settings and settings.mode) or "manga"
    return Geometry.sortReadingOrder(raw_panels, mode), true, nil
end

return Segmenter
