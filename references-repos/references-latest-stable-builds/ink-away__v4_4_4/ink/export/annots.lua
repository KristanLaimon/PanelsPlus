--[[
Ink as PDF annotations: what an editable export writes. A page's ops (strokes,
shapes) become lines a PDF viewer can show, move and delete; what a PDF
annotation cannot hold (text boxes, pictures, paint bucket fills, smudges) is
counted instead, so the export sheet can say so before it writes anything.
Plain Lua: the headless tests drive it.

An eraser stroke is applied first, cutting the strokes it crossed (see
ink/cut.lua), so what is written is what the page shows.

A map { s, ox, oy } takes the op's own coordinates (canvas px) into the page's
units: page = (px - o) / s.
]]

local Cut = require("ink/cut")
local Shapes = require("ink/shapes")
local Wash = require("ink/wash")

local Annots = {}

-- The kinds of item an editable PDF leaves out, in the order the sheet names them.
Annots.LEFT_OUT = { "text", "image", "fill", "smudge" }

-- A see-through pen (highlighter, marker, watercolor) is written this much
-- lighter than its opacity, as a PDF viewer lays it over the text.
local WASH_OPACITY = 0.45

-- The ops of a page as they look: hidden ones and links dropped, each eraser
-- stroke applied to what was drawn before it. Returns a new list.
function Annots.settle(ops)
    local out = {}
    for _i, op in ipairs(ops or {}) do
        if op.kind == "erase" then
            if op.pts and #op.pts >= 2 then out = Cut.ops(out, op.pts, (op.width or 1) / 2, {}) end
        elseif not op.hidden and op.kind ~= "link" then
            out[#out + 1] = op
        end
    end
    return out
end

-- What an op is, as far as a PDF annotation goes: "ink", or the name of what it
-- is that gets left out. A filled shape is written as its outline (see convert),
-- and counts as a fill left out.
local function leftOut(op)
    local k = op.kind
    if k == "text" or k == "image" or k == "fill" or k == "smudge" then return k end
    if k == "shape" and (op.fill or op.fill_color) then return "fill" end
    return nil
end

-- How many items of each kind an editable export leaves out of `lists` (page
-- op lists): { text = n, image = n, fill = n, smudge = n, total = n }.
function Annots.leftOut(lists)
    local n = { text = 0, image = 0, fill = 0, smudge = 0, total = 0 }
    for _i, ops in ipairs(lists) do
        for _j, op in ipairs(Annots.settle(ops)) do
            local k = leftOut(op)
            if k then n[k] = n[k] + 1; n.total = n.total + 1 end
        end
    end
    return n
end

-- A flat x, y list as { {x=, y=}, ... } in page units.
local function line(flat, m)
    local out = {}
    for i = 1, #flat - 1, 2 do
        out[#out + 1] = { x = (flat[i] - m.ox) / m.s, y = (flat[i + 1] - m.oy) / m.s }
    end
    return out
end

-- The ink of one page as annotations: a list of { strokes = { { {x=, y=} ... } },
-- color = { r, g, b }, width, opacity } in page units, one per op. `ops` are
-- the page's ops as stored (settled here).
function Annots.convert(ops, m)
    local groups = {}
    for _i, op in ipairs(Annots.settle(ops)) do
        local lines
        if op.kind == "ink" and op.pts and #op.pts >= 2 then
            lines = { op.pts }
            if #op.pts == 2 then lines = { { op.pts[1], op.pts[2], op.pts[1] + 0.01, op.pts[2] } } end   -- a dot
        elseif op.kind == "shape" and op.pts and #op.pts >= 4 then
            lines = Shapes.outlines(op)
        end
        if lines and #lines > 0 then
            local c = op.color or {}
            local opacity = (op.alpha or 255) / 255
            if Wash.isWash(op) then opacity = opacity * WASH_OPACITY end
            local strokes = {}
            for _j, l in ipairs(lines) do strokes[#strokes + 1] = line(l, m) end
            groups[#groups + 1] = { strokes = strokes, color = { r = c[1] or 0, g = c[2] or 0, b = c[3] or 0 },
                width = math.max(0.5, (op.width or 2) / m.s), opacity = opacity }
        end
    end
    return groups
end

return Annots
