--[[
Shape rasterization: line, curve, rectangle, ellipse, triangle and point-path
polygon, outlined or filled, optionally rotated about the centre.

Every shape is reduced to a boundary polyline with its rotation applied. Outlines
are stamped as discs along it by the freehand rasterizer, so an edge has the same
rounded, even thickness as a pen stroke; fills are a scanline fill of the same
polygon. Everything goes through a `put(x, y, len)` span callback, so the same
code paints the preview, the 1:1 master and the export.

A shape op looks like:
    { kind = "shape", shape = "line"|"curve"|"rect"|"ellipse"|"triangle"|"poly",
      fill = true|false, angle = <radians>, width = <px>, alpha = .., color = {r,g,b},
      pts = { x0,y0, x1,y1 [, cx,cy] } }   -- cx,cy is the curve control point
]]

local Geom = require("ink/geom")
local Raster = require("ink/raster")

local Shapes = {}

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local sin, cos = math.sin, math.cos

-- Build the boundary polyline of a shape (flat {x,y,...}), with any rotation
-- applied about the shape's centre. `closed` (second return) says whether the
-- last point should join the first for a fill.
local function boundary(op)
    local p = op.pts
    local x0, y0, x1, y1 = p[1], p[2], p[3], p[4]
    local s = op.shape
    local poly, closed = {}, true

    if s == "line" then
        poly = { x0, y0, x1, y1 }
        closed = false
    elseif s == "curve" then
        local cx = p[5] or (x0 + x1) / 2
        local cy = p[6] or (y0 + y1) / 2
        for i = 0, 28 do
            local t = i / 28
            local mt = 1 - t
            local a, b, c = mt * mt, 2 * mt * t, t * t
            poly[#poly + 1] = a * x0 + b * cx + c * x1
            poly[#poly + 1] = a * y0 + b * cy + c * y1
        end
        closed = false
    elseif s == "rect" then
        local ax0, ay0 = min(x0, x1), min(y0, y1)
        local ax1, ay1 = max(x0, x1), max(y0, y1)
        poly = { ax0, ay0, ax1, ay0, ax1, ay1, ax0, ay1 }
    elseif s == "triangle" then
        local ax0, ay0 = min(x0, x1), min(y0, y1)
        local ax1, ay1 = max(x0, x1), max(y0, y1)
        poly = { (ax0 + ax1) / 2, ay0, ax0, ay1, ax1, ay1 }
    elseif s == "ellipse" then
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        local rx, ry = math.abs(x1 - x0) / 2, math.abs(y1 - y0) / 2
        local steps = max(24, floor(rx + ry))
        for i = 0, steps - 1 do
            local a = (i / steps) * 2 * math.pi
            poly[#poly + 1] = cx + rx * cos(a)
            poly[#poly + 1] = cy + ry * sin(a)
        end
    elseif s == "poly" then
        -- an explicit point path (a snapped triangle or polygon from hold to
        -- straighten), drawn as its points and closed on demand
        for i = 1, #p do poly[i] = p[i] end
        closed = op.closed and true or false
    end

    -- rotate about the centre of the defining box or endpoints (for a poly, of
    -- the bounding box of all its points)
    local ang = op.angle
    if ang and ang ~= 0 then
        local cx, cy
        if s == "poly" then
            local minx, miny, maxx, maxy = Geom.bounds(poly)
            cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
        else
            cx = (x0 + x1) / 2
            cy = (y0 + y1) / 2
        end
        local ca, sa = cos(ang), sin(ang)
        for i = 1, #poly, 2 do
            local dx, dy = poly[i] - cx, poly[i + 1] - cy
            poly[i]     = cx + dx * ca - dy * sa
            poly[i + 1] = cy + dx * sa + dy * ca
        end
    end
    return poly, closed
end

-- Even-odd scanline fill of a closed polygon given as flat {x,y,...}.
local function fillPolygon(poly, put)
    local n = floor(#poly / 2)
    if n < 3 then return end
    local ymin, ymax = poly[2], poly[2]
    for i = 2, n do
        local y = poly[2 * i]
        if y < ymin then ymin = y elseif y > ymax then ymax = y end
    end
    for y = floor(ymin + 0.5), floor(ymax + 0.5) do
        local yc = y + 0.5
        local xs = {}
        local jx, jy = poly[2 * n - 1], poly[2 * n]   -- previous vertex
        for i = 1, n do
            local ix, iy = poly[2 * i - 1], poly[2 * i]
            if (iy <= yc and jy > yc) or (jy <= yc and iy > yc) then
                xs[#xs + 1] = ix + (yc - iy) / (jy - iy) * (jx - ix)
            end
            jx, jy = ix, iy
        end
        if #xs >= 2 then
            table.sort(xs)
            for k = 1, #xs - 1, 2 do
                local xl = floor(xs[k] + 0.5)
                local xr = floor(xs[k + 1] + 0.5)
                if xr >= xl then put(xl, y, xr - xl + 1) end
            end
        end
    end
end

-- Arrowhead barbs for a line or curve with op.arrow ("end" or "both"): a list of
-- {tx,ty, bx,by} segments from the tangent at each tip, so a head follows the
-- shape's direction and rotation (poly is already rotated). Empty without arrows.
local function arrowSegs(op, poly)
    local segs = {}
    if op.arrow ~= "end" and op.arrow ~= "both" then return segs end
    if op.shape ~= "line" and op.shape ~= "curve" then return segs end
    local n = floor(#poly / 2)
    if n < 2 then return segs end
    local head = op.head or max(12, (op.width or 2) * 3)
    local ca, sa = cos(0.4887), sin(0.4887)   -- barb half-angle ~28 degrees
    local function tip(txi, tyi, fxi, fyi)
        local tx, ty = poly[txi], poly[tyi]
        local dx, dy = tx - poly[fxi], ty - poly[fyi]
        local len = sqrt(dx * dx + dy * dy)
        if len < 1e-3 then return end
        dx, dy = dx / len, dy / len
        segs[#segs + 1] = { tx, ty, tx - head * (dx * ca - dy * sa), ty - head * (dx * sa + dy * ca) }
        segs[#segs + 1] = { tx, ty, tx - head * (dx * ca + dy * sa), ty + head * (dx * sa - dy * ca) }
    end
    tip(2 * n - 1, 2 * n, 2 * n - 3, 2 * n - 2)      -- head at the last point
    if op.arrow == "both" then tip(1, 2, 3, 4) end   -- and at the first
    return segs
end

-- The shape as drawn, as open polylines (flat {x,y,...}): its outline (a closed
-- one ends where it starts) and each arrowhead barb. The eraser that cuts
-- strokes cuts a shape's outline as these (see ink/cut.lua).
function Shapes.outlines(op)
    local poly, closed = boundary(op)
    local out = {}
    if #poly >= 2 then
        local line = {}
        for i = 1, #poly do line[i] = poly[i] end
        if closed and #poly >= 4 then line[#line + 1] = poly[1]; line[#line + 1] = poly[2] end
        out[1] = line
    end
    for _, sg in ipairs(arrowSegs(op, poly)) do out[#out + 1] = { sg[1], sg[2], sg[3], sg[4] } end
    return out
end

-- Render a shape op with the given span writer.
function Shapes.render(op, put)
    local poly, closed = boundary(op)
    local r = (op.width or 2) / 2
    if op.fill and closed then
        fillPolygon(poly, put)
    else
        -- outline: stamp discs along the polyline, closing area shapes
        local line = poly
        if closed then
            line = {}
            for i = 1, #poly do line[i] = poly[i] end
            line[#line + 1] = poly[1]
            line[#line + 1] = poly[2]
        end
        Raster.path(line, r, put)
        for _, s in ipairs(arrowSegs(op, poly)) do Raster.path(s, r, put) end
    end
end

-- Fill just the interior of a closed shape with the given span writer, whatever
-- op.fill says. A paint-bucket fill is painted this way under the outline, so the
-- interior can have its own colour.
function Shapes.fill(op, put)
    local poly, closed = boundary(op)
    if closed then fillPolygon(poly, put) end
end

-- Is point (px, py) strictly inside a closed shape's interior? Always false for
-- an open line or curve. Decides whether a paint-bucket tap fills the shape.
function Shapes.contains(op, px, py)
    local poly, closed = boundary(op)
    if not closed then return false end
    return Geom.pointInPoly(px, py, poly)
end

-- The shape's outline as drawn (rotation applied): a flat {x, y, ...} list, and
-- whether it is closed.
Shapes.outline = boundary

-- Bounding box {x0,y0,x1,y1} of the shape as actually drawn (rotation and any
-- arrowheads included).
function Shapes.bounds(op)
    local poly = boundary(op)
    local x0, y0, x1, y1 = Geom.bounds(poly)
    for _, s in ipairs(arrowSegs(op, poly)) do
        local x, y = s[3], s[4]
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- Does a stroke of radius r along `pts` (flat) reach the shape as drawn: its
-- outline, or its inside when filled (unless `edge_only`)? Tells whether an
-- eraser touched it.
function Shapes.reachedBy(op, pts, r, edge_only)
    local poly, closed = boundary(op)
    local filled = closed and (op.fill or op.fill_color) and not edge_only
    local reach = r + ((op.fill and closed) and 0 or (op.width or 2) / 2)
    local r2 = reach * reach
    local segs = arrowSegs(op, poly)
    local n = floor(#poly / 2)
    local last = closed and n or (n - 1)
    local bx0, by0, bx1, by1 = Shapes.bounds(op)
    local function near(x, y)
        if filled and Geom.pointInPoly(x, y, poly) then return true end
        for i = 1, last do
            local j = (i % n) + 1
            if Geom.segDist2(x, y, poly[2 * i - 1], poly[2 * i], poly[2 * j - 1], poly[2 * j]) <= r2 then
                return true
            end
        end
        for _, s in ipairs(segs) do
            if Geom.segDist2(x, y, s[1], s[2], s[3], s[4]) <= r2 then return true end
        end
        return false
    end
    if #pts < 4 then return #pts >= 2 and near(pts[1], pts[2]) end
    -- walk each stroke segment that comes near the shape in 2 px steps
    for i = 1, #pts - 3, 2 do
        local ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        if min(ax, bx) - reach <= bx1 and max(ax, bx) + reach >= bx0
                and min(ay, by) - reach <= by1 and max(ay, by) + reach >= by0 then
            local steps = math.max(1, math.ceil(sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / 2))
            for k = 0, steps do
                local t = k / steps
                if near(ax + (bx - ax) * t, ay + (by - ay) * t) then return true end
            end
        end
    end
    return false
end

-- Is point (px, py) on or inside the shape, for picking it by touch? A closed
-- shape can be grabbed anywhere inside, filled or not, as a bare outline is too
-- thin a target; an open line, curve or arrow is picked within `tol` of its
-- boundary.
function Shapes.hit(op, px, py, tol)
    local poly, closed = boundary(op)
    local n = floor(#poly / 2)
    if closed and Geom.pointInPoly(px, py, poly) then return true end
    local t2 = tol * tol
    local function nearSeg(ax, ay, bx, by)
        return Geom.segDist2(px, py, ax, ay, bx, by) <= t2
    end
    -- boundary segments
    local last = closed and n or (n - 1)
    for i = 1, last do
        local ni = (i % n) + 1
        if nearSeg(poly[2 * i - 1], poly[2 * i], poly[2 * ni - 1], poly[2 * ni]) then return true end
    end
    -- arrowhead barbs, so an arrow can be grabbed by its head too
    for _, s in ipairs(arrowSegs(op, poly)) do
        if nearSeg(s[1], s[2], s[3], s[4]) then return true end
    end
    return false
end

return Shapes
