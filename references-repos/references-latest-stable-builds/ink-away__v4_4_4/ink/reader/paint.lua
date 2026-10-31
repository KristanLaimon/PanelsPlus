--[[
Paint a page's ink over the book, in the order it was drawn: strokes, shapes and
fills through the shared span writer, see-through pens through their blend
(a highlighter multiplies, so the book's text stays black under it), text boxes
and pictures through the canvas's own painters. The canvas module is loaded
only for a page that has text or pictures on it.
]]

local Paint = require("ink/paint")
local Symmetry = require("ink/symmetry")
local Wash = require("ink/wash")
local Export = require("ink/export")

local PaintInk = {}

-- A stand-in for the canvas, enough for its text and picture painters.
local function painter(book, W, H)
    if book._painter and book._painter.view.canvas_w == W and book._painter.view.canvas_h == H then
        return book._painter
    end
    local InkAwayView = require("ink/view")
    local p = setmetatable({ view = { canvas_w = W, canvas_h = H, zoom = 1, pan_x = 0, pan_y = 0 } },
        { __index = InkAwayView })
    book._painter = p
    return p
end

function PaintInk.ops(bb, ops, _x, _y, book)
    local W, H = bb:getWidth(), bb:getHeight()
    local refx, refy = Symmetry.canvasRefs(W, H)
    for _i, op in ipairs(ops) do
        local k = op.kind
        if k == "text" then
            painter(book, W, H):stampTextInto(bb, op)
        elseif k == "image" then
            painter(book, W, H):blitImageInto(bb, op)
        elseif k == "link" or k == "erase" or k == "smudge" then   -- luacheck: ignore 542
            -- nothing to paint over a book (see ink/reader/inkview.lua)
        else
            local wash, st = Wash.isWash(op)
            if wash then
                local m = Wash.cachedMask(op, st, W, H)
                if m then Wash.blendBB(bb, m, op, st) end
            else
                local put = Paint.spanWriter(bb, W, H, Paint.displayColor(op.color, op.alpha or 255), nil)
                local fill_put
                if k == "shape" and op.fill_color and not op.fill then
                    fill_put = Symmetry.wrap(Paint.spanWriter(bb, W, H,
                        Paint.displayColor(op.fill_color, op.fill_alpha or 255), nil), op.sym, refx, refy)
                end
                Export.paintGeom(op, Symmetry.wrap(put, op.sym, refx, refy), fill_put)
            end
        end
    end
end

return PaintInk
