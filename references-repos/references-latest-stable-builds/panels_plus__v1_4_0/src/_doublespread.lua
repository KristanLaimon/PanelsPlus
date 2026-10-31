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

--- Return the spread rotation choice the two settings add up to.
---
--- `auto_rotate_double_pages` rotates the image in the panel viewer and
--- `rotate_screen_for_double_pages` rotates the screen while reading. The menus
--- show them as one choice.
--- @param settings PPSettings Plugin settings.
--- @return string mode `"off"`, `"viewer"`, `"reading"` or `"both"`.
function DoubleSpread.rotationMode(settings)
    local in_viewer = settings.auto_rotate_double_pages ~= false
    if settings.rotate_screen_for_double_pages == true then
        return in_viewer and "both" or "reading"
    end
    return in_viewer and "viewer" or "off"
end

--- Return whether a rectangle has the shape of a double-page spread.
--- @param rect PPRect|nil Native page or image rectangle.
--- @return boolean
function DoubleSpread.isSpreadRect(rect)
    return rect ~= nil and (rect.w or 0) > 0 and (rect.h or 0) > 0 and rect.w / rect.h >= MIN_SPREAD_ASPECT
end

--- Return the angle a spread image is rotated by in a portrait viewer.
---
--- `ImageWidget.rotation_angle` turns the bitmap counter-clockwise, so clockwise is 270.
--- @param direction string|nil `"cw"` or `"ccw"`. Anything else follows KOReader's image viewer
---   ("Invert default rotation in portrait mode").
--- @return integer angle 90 or 270.
function DoubleSpread.imageAngle(direction)
    if direction == "cw" then
        return 270
    elseif direction == "ccw" then
        return 90
    end
    local inverted = G_reader_settings and G_reader_settings:isTrue("imageviewer_rotation_portrait_invert")
    return inverted and 270 or 90
end

--- Return the screen rotation mode for reading a double-page spread, or nil.
---
--- The direction matches `imageAngle`, so the device is held the same way for the viewer and
--- the reading page. In rotation mode 1 the page's top is on the device's left edge, like an
--- image at 90. Mode 3 matches 270.
--- @param base_mode integer Rotation mode the reader uses for normal pages.
--- @param page_w number|nil Native page width.
--- @param page_h number|nil Native page height.
--- @param direction string|nil See `imageAngle`.
--- @return integer|nil rotation_mode Nil for a normal page or a landscape base.
function DoubleSpread.screenRotationFor(base_mode, page_w, page_h, direction)
    if type(page_w) ~= "number" or type(page_h) ~= "number" or page_w <= 0 or page_h <= 0 then
        return nil
    end
    if base_mode % 2 == 1 or page_w / page_h < MIN_SPREAD_ASPECT then
        return nil
    end
    return (base_mode + (DoubleSpread.imageAngle(direction) == 270 and 3 or 1)) % 4
end

return DoubleSpread
