--[[
Panels+
File: src/_doublespread.lua
Name: DoubleSpread
Description: Identifies wide full-page images for local viewer rotation.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Screen = require("device").screen

local DoubleSpread = {}

-- Two portrait pages side by side are typically at least this wide relative
-- to their height. A lone wide detected panel can be an illustration spread
-- even when white margins keep it below the full-page area threshold.
local MIN_SPREAD_ASPECT = 1.3

--- Return whether a full-page image should turn within the portrait viewer.
--- @param rect PPRect|nil Native page or image rectangle.
--- @param is_full_page boolean Whether the rectangle covers nearly the whole source page.
--- @param is_single_panel boolean Whether this is the only detected panel on its source page.
--- @return boolean
function DoubleSpread.shouldRotate(rect, is_full_page, is_single_panel)
    return (is_full_page == true or is_single_panel == true)
        and rect ~= nil
        and (rect.w or 0) > 0
        and (rect.h or 0) > 0
        and Screen:getHeight() > Screen:getWidth()
        and rect.w / rect.h >= MIN_SPREAD_ASPECT
end

return DoubleSpread
