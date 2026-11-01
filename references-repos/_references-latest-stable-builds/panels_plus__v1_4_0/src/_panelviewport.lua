--[[
Panels+
File: src/_panelviewport.lua
Name: PanelViewport
Description: Computes crop and no-crop viewport geometry for panel rendering.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
local Screen = require("device").screen

--- Shared panel-viewport geometry.
---
--- "No crop" does not mean that every panel should receive the whole source
--- page. It means that each panel gets a screen-aspect viewport centred on
--- that panel, retaining surrounding context where possible. Keeping this
--- geometry independent of the renderer lets document pages and extracted
--- EPUB/KEPUB/MOBI bitmaps navigate through the same panel positions.
local PanelViewport = {}

--- Build the screen-aspect viewport centred on a panel.
---
--- @param rect PPPanel Selected panel rectangle in source coordinates.
--- @param source_size PPPageSize Source-page or source-image dimensions.
--- @return table|nil viewport
function PanelViewport.noCrop(rect, source_size)
    local rx = rect and rect.x or 0
    local ry = rect and rect.y or 0
    local rw = math.max(1, rect and rect.w or 0)
    local rh = math.max(1, rect and rect.h or 0)
    local source_w = source_size and source_size.w or 0
    local source_h = source_size and source_size.h or 0
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()

    if screen_w <= 0 or screen_h <= 0 or source_w <= 0 or source_h <= 0 then
        return nil
    end

    local scale = math.min(screen_w / rw, screen_h / rh)
    local box_w, box_h = screen_w / scale, screen_h / scale
    local box_x = rx + rw / 2 - box_w / 2
    local box_y = ry + rh / 2 - box_h / 2
    local union_x = math.max(0, box_x)
    local union_y = math.max(0, box_y)
    local union_right = math.min(source_w, box_x + box_w)
    local union_bottom = math.min(source_h, box_y + box_h)

    return {
        scale = scale,
        box_x = box_x,
        box_y = box_y,
        union_x = union_x,
        union_y = union_y,
        union_w = math.max(0, union_right - union_x),
        union_h = math.max(0, union_bottom - union_y),
    }
end

return PanelViewport
