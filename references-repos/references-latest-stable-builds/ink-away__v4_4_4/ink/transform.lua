--[[
Moving, resizing, turning and mirroring ops, for a selection of any mix of pen
strokes, shapes, fills, pictures and text boxes. Plain Lua, so the headless
tests drive it. Every function changes the op it is given: callers pass a copy
(Canvas:cloneOp) so undo keeps the original.

  * Transform.scale(op, ax, ay, s)      grow or shrink by s about (ax, ay)
  * Transform.rotate(op, cx, cy, a)     turn by a radians about (cx, cy), clockwise
                                        on the y-down page
  * Transform.flip(op, axis, mid)       mirror across x = mid ("h") or y = mid ("v")

How each kind takes it:
  * a pen stroke: its points move; resizing scales its thickness too, so it looks
    the same, only bigger or smaller
  * a shape: its defining points move and its angle turns, so a rectangle or an
    ellipse stays exact at any angle; its line width and arrowheads scale
  * a picture: its box moves and scales about its centre, its angle (degrees)
    turns, and a mirror flips it and reverses its angle
  * a text box: it moves and its letters scale, and a turn turns it (its
    angle, about its top-left corner, see ink/text.lua); a mirror moves it to
    where its centre goes and mirrors its angle, so it stays readable
  * a link's area (see ink/links.lua): it moves and scales, and stays upright
  * a fill (a paint bucket area, stored as pixel runs): mirrored run by run;
    resized or turned by resampling its pixels
]]

local Text = require("ink/text")

local Transform = {}

local cos, sin, floor, ceil, max, min = math.cos, math.sin, math.floor, math.ceil, math.max, math.min

local function rotPoint(x, y, cx, cy, ca, sa)
    local dx, dy = x - cx, y - cy
    return cx + dx * ca - dy * sa, cy + dx * sa + dy * ca
end

-- The point a shape turns about (as Shapes draws it): the middle of its first
-- two points, or of all its points' box for a point path.
local function shapeCentre(op)
    local p = op.pts
    if op.shape == "poly" then
        local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
        for i = 1, #p - 1, 2 do
            x0, x1 = min(x0, p[i]), max(x1, p[i])
            y0, y1 = min(y0, p[i + 1]), max(y1, p[i + 1])
        end
        return (x0 + x1) / 2, (y0 + y1) / 2
    end
    return (p[1] + p[3]) / 2, (p[2] + p[4]) / 2
end

local function eachPoint(op, fn)
    local p = op.pts
    if not p then return end
    for i = 1, #p - 1, 2 do p[i], p[i + 1] = fn(p[i], p[i + 1]) end
end

local function shiftBox(op, dx, dy) op.x, op.y = op.x + dx, op.y + dy end

-- The centre of a picture's, a text box's or a link's box (a text box's turned
-- with it).
local function boxCentre(op)
    if op.kind == "text" then return Text.centre(op) end
    return op.x + (op.w or 0) / 2, op.y + (op.h or 0) / 2
end

------------------------------------------------------------------------------
-- Fills: pixel runs { x, y, len, ... }
------------------------------------------------------------------------------

-- Rows of a fill as sorted lists of [x0, x1) spans, and its box.
local function fillRows(runs)
    local rows = {}
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #runs - 2, 3 do
        local x, y, n = runs[i], runs[i + 1], runs[i + 2]
        local row = rows[y]
        if not row then row = {}; rows[y] = row end
        row[#row + 1] = { x, x + n }
        x0, x1 = min(x0, x), max(x1, x + n)
        y0, y1 = min(y0, y), max(y1, y + 1)
    end
    for _, row in pairs(rows) do table.sort(row, function(a, b) return a[1] < b[1] end) end
    return rows, x0, y0, x1, y1
end

local function inRow(row, x)
    if not row then return false end
    local lo, hi = 1, #row
    while lo <= hi do
        local m = floor((lo + hi) / 2)
        local s = row[m]
        if x < s[1] then hi = m - 1 elseif x >= s[2] then lo = m + 1 else return true end
    end
    return false
end

-- New runs for a fill under the point map `fwd` (page point -> new point),
-- found by sending each pixel of the new box back through `inv`.
local function resampleFill(op, fwd, inv)
    local rows, x0, y0, x1, y1 = fillRows(op.runs)
    if x0 > x1 then return end
    local bx0, by0, bx1, by1 = math.huge, math.huge, -math.huge, -math.huge
    for _, c in ipairs({ { x0, y0 }, { x1, y0 }, { x0, y1 }, { x1, y1 } }) do
        local x, y = fwd(c[1], c[2])
        bx0, bx1 = min(bx0, x), max(bx1, x)
        by0, by1 = min(by0, y), max(by1, y)
    end
    local out = {}
    for y = floor(by0), ceil(by1) - 1 do
        local start
        for x = floor(bx0), ceil(bx1) do
            local sx, sy = inv(x + 0.5, y + 0.5)
            local on = x < ceil(bx1) and inRow(rows[floor(sy)], floor(sx))
            if on and not start then start = x
            elseif not on and start then
                out[#out + 1] = start; out[#out + 1] = y; out[#out + 1] = x - start
                start = nil
            end
        end
    end
    op.runs = out
end

------------------------------------------------------------------------------
-- The three changes
------------------------------------------------------------------------------

function Transform.scale(op, ax, ay, s)
    local function sc(x, y) return ax + (x - ax) * s, ay + (y - ay) * s end
    local k = op.kind
    if k == "image" then
        local cx, cy = sc(boxCentre(op))
        op.w, op.h = op.w * s, op.h * s
        op.x, op.y = cx - op.w / 2, cy - op.h / 2
    elseif k == "text" or k == "link" then
        op.x, op.y = sc(op.x, op.y)
        op.w = (op.w or 0) * s
        if op.h then op.h = op.h * s end
        if k == "text" then op.size = (op.size or 20) * s end
    elseif k == "fill" then
        resampleFill(op, sc, function(x, y) return ax + (x - ax) / s, ay + (y - ay) / s end)
    else
        eachPoint(op, sc)
        if op.width then op.width = max(0.5, op.width * s) end
        if op.head then op.head = op.head * s end
    end
    return op
end

function Transform.rotate(op, cx, cy, a)
    local ca, sa = cos(a), sin(a)
    local k = op.kind
    if k == "image" then
        local ox, oy = boxCentre(op)
        local nx, ny = rotPoint(ox, oy, cx, cy, ca, sa)
        shiftBox(op, nx - ox, ny - oy)
        op.angle = ((op.angle or 0) + math.deg(a)) % 360
    elseif k == "text" then
        -- its corner goes round the pivot and the box turns about it
        op.x, op.y = rotPoint(op.x, op.y, cx, cy, ca, sa)
        local deg = ((op.angle or 0) + math.deg(a)) % 360
        if math.abs(deg - floor(deg + 0.5)) < 1e-6 then deg = floor(deg + 0.5) % 360 end
        op.angle = deg ~= 0 and deg or nil
    elseif k == "link" then
        local ox, oy = boxCentre(op)
        local nx, ny = rotPoint(ox, oy, cx, cy, ca, sa)
        shiftBox(op, nx - ox, ny - oy)   -- it stays upright
    elseif k == "shape" then
        local ox, oy = shapeCentre(op)
        local nx, ny = rotPoint(ox, oy, cx, cy, ca, sa)
        local dx, dy = nx - ox, ny - oy
        eachPoint(op, function(x, y) return x + dx, y + dy end)
        op.angle = (op.angle or 0) + a
    elseif k == "fill" then
        resampleFill(op, function(x, y) return rotPoint(x, y, cx, cy, ca, sa) end,
            function(x, y) return rotPoint(x, y, cx, cy, ca, -sa) end)
    else
        eachPoint(op, function(x, y) return rotPoint(x, y, cx, cy, ca, sa) end)
    end
    return op
end

function Transform.flip(op, axis, mid)
    local h = axis == "h"
    local function fl(x, y) if h then return 2 * mid - x, y end return x, 2 * mid - y end
    local k = op.kind
    if k == "image" or k == "text" or k == "link" then
        local ox, oy = boxCentre(op)
        local nx, ny = fl(ox, oy)
        shiftBox(op, nx - ox, ny - oy)
        if k == "image" then
            if h then op.flip_h = not op.flip_h else op.flip_v = not op.flip_v end
            op.angle = (-(op.angle or 0)) % 360
        elseif k == "text" and Text.turned(op) then
            -- its letters stay readable: the angle mirrors, about the new centre
            Text.turnTo(op, -(op.angle or 0))
        end
    elseif k == "fill" then
        local r = op.runs
        for i = 1, #r - 2, 3 do
            if h then r[i] = floor(2 * mid - (r[i] + r[i + 2]) + 0.5)
            else r[i + 1] = floor(2 * mid - r[i + 1] - 1 + 0.5) end
        end
    else
        eachPoint(op, fl)
        if k == "shape" then op.angle = -(op.angle or 0) end
    end
    return op
end

return Transform
