--[[
A viewer plugin's document surface (see ink/integration.lua and
docs/INTEGRATION.md) as the placement adapter ink/reader/place.lua takes: an op
drawn on the viewer is kept as an op on its page, in page units, exactly as a
fixed-page book's ink drawn in KOReader's own view is (so it shows in both and
syncs as any other), and placed back through the surface's mapping. The zoom is
undone on the op, the page's turn undone too; a viewer whose page is folded
(a spread with the gutter removed) maps paths point by point across the fold,
and a shape crossing it is kept as a polygon.

From Kristan Laimon's PR #80.
]]
local Canvas = require("ink/canvas")
local Transform = require("ink/transform")

local Surface = {}

-- An affine part of a surface also describes how widths and non-path objects
-- turn. Path mapping can additionally cross discontinuities in a document view.
---@param op InkOperation
---@param surface InkSurface
---@param page integer?
---@param to_page boolean
---@return InkOperation? operation
---@return integer? page
local function mapped(op, surface, page, to_page)
    local c = Canvas.cloneOp(nil, op)
    local x0, y0 = Canvas.opBox(op)
    if not x0 then return nil end
    ---@cast y0 number Bounding-box coordinates are returned together.
    local x, y, scale, angle
    if to_page then
        local p, px, py, zoom, rotation = surface:toPage(x0, y0)
        if not p then return nil end
        ---@cast zoom number A successful mapping includes a positive scale.
        page, x, y, scale, angle = p, px, py, 1 / zoom, -(rotation or 0)
    else
        if not page then return nil end
        x, y, scale, angle = surface:toScreen(page, x0, y0)
        if not x then return nil end
    end
    Transform.scale(c, x0, y0, scale)
    Transform.rotate(c, x0, y0, angle or 0)
    Canvas.translateOp(c, x - x0, y - y0)
    ---@cast page integer Both successful branches identify the document page.
    if surface.mapPath then
        if op.kind == "ink" then
            c.pts = surface:mapPath(op.pts, to_page, page)
        elseif op.kind == "shape" and surface.isAffine and not surface:isAffine() then
            -- A primitive crossing a discontinuity is a polygon in the other
            -- coordinate system. Keep it in the existing shape format; no new
            -- persistent op types or viewer-specific metadata are needed.
            local outline = require("ink/shapes").outlines(op)[1]
            if outline then
                c.pts = surface:mapPath(outline, to_page, page)
                c.shape, c.angle = "poly", nil
                c.closed = op.shape ~= "line" and op.shape ~= "curve"
                    and (op.shape ~= "poly" or op.closed) or false
            end
        end
    end
    return c, page
end

--- Build internal ink placement from public transforms; consumers do not implement ink conversion.
---@param surface InkSurface
---@return InkPlacementDocument
function Surface.doc(surface)
    local doc = { kind = "paging" }
    function doc:toPage(x, y) return surface:toPage(x, y) end
    function doc:toScreen(page, x, y) return surface:toScreen(page, x, y) end
    ---@param op InkOperation
    ---@return InkAnchoredItem?
    function doc:anchorOp(op)
        local c, page = mapped(op, surface, nil, true)
        if not c then return nil end
        local x, y = Canvas.opBox(c)
        return { op = require("ink/reader/place").moved(c, -x, -y), a = { page = page, x = x, y = y } }
    end
    -- (only page anchors: the others belong to reflowing books, which a viewer
    -- surface never shows)
    ---@param item InkAnchoredItem
    ---@return InkOperation?
    function doc:placeOp(item)
        if not item.a.page then return nil end
        local op = require("ink/reader/place").moved(item.op, item.a.x, item.a.y)
        return mapped(op, surface, item.a.page, false)
    end
    -- (the screen, for an item pinned to it: none in a fixed-page book, but a
    -- piece of one re-anchored must not fail)
    function doc:size()
        local Screen = require("device").screen
        return Screen:getWidth(), Screen:getHeight()
    end
    return doc
end

return Surface
