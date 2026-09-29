--[[
Panels+
File: src/_pagerender.lua
Name: PageRender
Description: Renders page crops with KOReader's active contrast and saturation.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
-- Try the newer module path first; fall back to the path shipped by
-- KOReader ≤ v2025.04 ("document/canvascontext") for backward compat.
local ok, CanvasContext = pcall(require, "ui/canvascontext")
if not ok then
    CanvasContext = require("document/canvascontext")
end
local Geom = require("ui/geometry")

--- Page-crop rendering shared by panel images, transitions, and pre-rendering.
---
--- KOReader's `Document:drawPagePart()` intentionally renders image-viewer
--- crops with gamma and saturation fixed at 1.0. Panels+ is part of the active
--- document reader, however, so its crops should use the same adjustments as
--- the page underneath it.
---
--- @class PPPageRenderModule
local PageRender = {}

--- Return the active fixed-layout render adjustments.
---
--- ReaderView.state is the value KOReader actually passes to `drawPage()`. The
--- configurable values are retained as a fallback for tests, older KOReader
--- versions, and calls made before ReaderView has finished initializing.
---
--- @param ui table|nil KOReader reader UI.
--- @return number gamma
--- @return number saturation
function PageRender.getAdjustments(ui)
    local document = ui and ui.document
    local state = ui and ui.view and ui.view.state
    local configurable = document and document.configurable
    local gamma = state and state.gamma
    local saturation = state and state.saturation

    if type(gamma) ~= "number" then
        gamma = configurable and configurable.contrast
    end
    if type(saturation) ~= "number" then
        saturation = configurable and configurable.saturation
    end

    return type(gamma) == "number" and gamma or (document and document.GAMMA_NO_GAMMA or 1.0),
        type(saturation) == "number" and saturation or 1.0
end

--- Render a native-page crop at canvas-fit or caller-supplied zoom.
---
--- This mirrors KOReader's `Document:drawPagePart()` geometry and cache path,
--- changing only the gamma and saturation passed to `renderPage()`. Documents
--- without that fixed-layout API keep using their own implementation.
---
--- @param ui table KOReader reader UI.
--- @param pageno integer Page number.
--- @param native_rect PPRect Native page rectangle.
--- @param rotation number|nil Document rotation.
--- @param zoom number|nil Explicit zoom; nil uses the canvas-fit zoom.
--- @return table|nil bb Rendered blitbuffer.
--- @return boolean rotate Whether ImageViewer should rotate the bitmap.
function PageRender.drawPagePart(ui, pageno, native_rect, rotation, zoom)
    local document = ui and ui.document
    rotation = rotation or 0
    if not document or type(document.transformRect) ~= "function" or type(document.renderPage) ~= "function" then
        if document and type(document.drawPagePart) == "function" then
            return document:drawPagePart(pageno, native_rect, rotation)
        end
        return nil, false
    end

    local rect = Geom:new({
        x = native_rect.x,
        y = native_rect.y,
        w = native_rect.w,
        h = native_rect.h,
    })
    local rotate = false
    if not zoom then
        local canvas_size = CanvasContext:getSize()
        if
            G_reader_settings
            and type(G_reader_settings.isTrue) == "function"
            and G_reader_settings:isTrue("imageviewer_rotate_auto_for_best_fit")
        then
            rotate = (canvas_size.w > canvas_size.h) ~= (rect.w > rect.h)
        end
        zoom = rotate and math.min(canvas_size.w / rect.h, canvas_size.h / rect.w)
            or math.min(canvas_size.w / rect.w, canvas_size.h / rect.h)
    end

    rect.scaled_rect = document:transformRect(rect, zoom, rotation)
    local gamma, saturation = PageRender.getAdjustments(ui)
    local tile = document:renderPage(pageno, rect, zoom, rotation, gamma, saturation, true)
    return tile and tile.bb, rotate
end

return PageRender
