--[[
What the whole-stroke eraser touches. A stroke or a shape's outline is a line,
taken as soon as the eraser meets it; a fill or a filled shape's inside is an
area, and so is a text box (unless text is protected) or a picture (with Erase
pictures on). Plain Lua.
]]

local Canvas = require("ink/canvas")
local Geom = require("ink/geom")
local Shapes = require("ink/shapes")
local Symmetry = require("ink/symmetry")
local Text = require("ink/text")

local Wipe = {}

-- Does the stroke along `pts` come within `reach` of the segment s?
local function nearStroke(pts, s, reach, breaks)
    if breaks and #breaks > 0 then   -- a cut stroke: its parts, not the gaps between them
        for _, run in ipairs(Geom.runs(pts, nil, breaks)) do
            if nearStroke(run.pts, s, reach) then return true end
        end
        return false
    end
    local r2 = reach * reach
    if #pts < 4 then
        return #pts >= 2 and Geom.segDist2(pts[1], pts[2], s[1], s[2], s[3], s[4]) <= r2
    end
    for i = 1, #pts - 3, 2 do
        if Geom.segSegDist2(pts[i], pts[i + 1], pts[i + 2], pts[i + 3], s[1], s[2], s[3], s[4]) <= r2 then
            return true
        end
    end
    return false
end

-- Is (x, y) inside a fill op? Its runs are indexed by row in `rows` once.
local function inFill(op, x, y, rows)
    local idx = rows[op]
    if not idx then
        idx = {}
        local r = op.runs
        for i = 1, #r - 2, 3 do
            local row = idx[r[i + 1]] or {}
            row[#row + 1] = r[i]; row[#row + 1] = r[i] + r[i + 2]
            idx[r[i + 1]] = row
        end
        rows[op] = idx
    end
    local row = idx[math.floor(y)]
    if not row then return false end
    for i = 1, #row, 2 do
        if x >= row[i] and x < row[i + 1] then return true end
    end
    return false
end

-- The ops the eraser can take (strokes, shapes and fills, and with opts.text
-- text boxes, with opts.pictures pictures), each with its box {x0, y0, x1, y1}.
-- A symmetric op's copies can be anywhere: it gets the page.
function Wipe.boxes(ops, W, H, opts)
    opts = opts or {}
    local out = {}
    for _, op in ipairs(ops) do
        local k = op.kind
        if (k == "ink" or k == "shape" or k == "fill" or k == "smudge"
                or (k == "text" and opts.text) or (k == "image" and opts.pictures)) and not op.hidden then
            local x0, y0, x1, y1 = Canvas.opBox(op)
            if x0 then
                if op.sym and op.sym ~= "off" then x0, y0, x1, y1 = 0, 0, W, H end
                out[op] = { x0, y0, x1, y1 }
            end
        end
    end
    return out
end

-- Is (x, y) within r of a picture, turned by its angle about its centre?
local function onPicture(op, x, y, r)
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    local a = math.rad(op.angle or 0)
    local ca, sa = math.cos(a), math.sin(a)
    local dx, dy = x - cx, y - cy
    local lx, ly = dx * ca + dy * sa, -dx * sa + dy * ca
    return math.abs(lx) <= op.w / 2 + r and math.abs(ly) <= op.h / 2 + r
end

-- Does the eraser segment s ({x0, y0, x1, y1}) of radius r touch op, on any
-- mirror copy, as a line or an area? Returns line, area. `rows` caches fills.
-- A text box or a picture is an area, so rubbing out writing over it keeps it.
function Wipe.hits(op, s, r, W, H, rows)
    local k = op.kind
    if k == "text" then
        if not (op.h and op.h > 0) then return false, false end
        return false, Text.contains(op, s[3], s[4], r)   -- in its own frame, turned or not
    elseif k == "image" then
        return false, onPicture(op, s[3], s[4], r)
    end
    local area = false
    for _, f in ipairs(Symmetry.flips(op.sym)) do
        local p = Symmetry.flipPoints(s, f, W, H)
        if k == "ink" or k == "smudge" then
            if nearStroke(op.pts, p, r + (op.width or 1) / 2, op.breaks) then return true, false end
        elseif k == "shape" and op.fill then
            if Shapes.reachedBy(op, p, r) then return false, true end
        elseif k == "shape" then
            if Shapes.reachedBy(op, p, r, true) then return true, false end
            if op.fill_color and Shapes.contains(op, p[3], p[4]) then area = true end
        elseif k == "fill" then
            if inFill(op, p[3], p[4], rows) then area = true end
        end
    end
    return false, area
end

return Wipe
