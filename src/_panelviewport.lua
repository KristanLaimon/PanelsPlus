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

--- Disjoint rectangles covering only the two cropped transition endpoints.
--- Loose crops may overlap; splitting that overlap avoids painting translucent
--- ink twice when the annotation renderer visits each retained region.
function PanelViewport.transitionClips(a, b)
    local clips = { a }
    local x0, y0 = math.max(a.x, b.x), math.max(a.y, b.y)
    local x1, y1 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
    if x1 <= x0 or y1 <= y0 then
        clips[2] = b
        return clips
    end
    local function add(x, y, w, h)
        if w > 0 and h > 0 then
            clips[#clips + 1] = { x = x, y = y, w = w, h = h }
        end
    end
    add(b.x, b.y, b.w, y0 - b.y)
    add(b.x, y1, b.w, b.y + b.h - y1)
    add(b.x, y0, x0 - b.x, y1 - y0)
    add(x1, y0, b.x + b.w - x1, y1 - y0)
    return clips
end

--- Native bounds of a whole canvas containing a translated page bitmap.
--- Uses actual bitmap sizes so rounding, padding and rescaling share the
--- compositor's coordinates rather than a separately estimated camera zoom.
function PanelViewport.canvasRect(content_rect, content_w, content_h, canvas_w, canvas_h, paste_x, paste_y)
    if content_w <= 0 or content_h <= 0 then
        return nil
    end
    local units_x, units_y = content_rect.w / content_w, content_rect.h / content_h
    return {
        x = content_rect.x - paste_x * units_x,
        y = content_rect.y - paste_y * units_y,
        w = canvas_w * units_x,
        h = canvas_h * units_y,
    }
end

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
