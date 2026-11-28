--[[
Pure geometry helpers: screen and canvas coordinates, the viewport, bounds and
rectangles, stroke thinning (Ramer-Douglas-Peucker and a minimum spacing) and the
input aids (stabilizer, grid and angle snap). Nothing here touches KOReader.
]]

local Geom = {}

-- Shallow copy of a flat point list.
local function copyList(pts)
    local out = {}
    for i = 1, #pts do out[i] = pts[i] end
    return out
end

------------------------------------------------------------------------------
-- Viewport
--
-- The canvas is a fixed W x H image. It shows inside a rectangular "area" of the
-- screen (below the toolbar) at some `zoom`, scrolled so that canvas point
-- (pan_x, pan_y) sits at the area's top left corner. A view table is:
--   { area_x, area_y, area_w, area_h,  -- area rect in screen coords
--     zoom, pan_x, pan_y,              -- canvas point shown at the area corner
--     canvas_w, canvas_h }
------------------------------------------------------------------------------

-- Convert screen coordinates to canvas coordinates.
function Geom.toCanvas(view, sx, sy)
    return view.pan_x + (sx - view.area_x) / view.zoom,
           view.pan_y + (sy - view.area_y) / view.zoom
end

-- Convert canvas coordinates to screen coordinates.
function Geom.toScreen(view, cx, cy)
    return view.area_x + (cx - view.pan_x) * view.zoom,
           view.area_y + (cy - view.pan_y) * view.zoom
end

-- The smallest zoom that fits the whole canvas inside the area: the pinch-out
-- floor. Below 1 when the canvas is larger than the area; a canvas of a different
-- shape is letterboxed at this zoom.
function Geom.fitZoom(view)
    return math.min(view.area_w / view.canvas_w, view.area_h / view.canvas_h)
end

-- The smallest zoom that covers the whole area (the canvas's longer side
-- overflows and is reached by panning). It is the default view, so the drawing
-- area is always fully paintable, even when the page's shape differs from the
-- screen. For a canvas the shape of the area, or narrower, it equals fill-width.
function Geom.coverZoom(view)
    return math.max(view.area_w / view.canvas_w, view.area_h / view.canvas_h)
end

-- Clamp the pan so the visible window stays over the canvas. A canvas smaller
-- than the area in a dimension is centred in it.
function Geom.clampPan(view)
    local vis_w = view.area_w / view.zoom
    local vis_h = view.area_h / view.zoom
    if vis_w >= view.canvas_w then
        view.pan_x = (view.canvas_w - vis_w) / 2
    else
        view.pan_x = math.max(0, math.min(view.canvas_w - vis_w, view.pan_x))
    end
    if vis_h >= view.canvas_h then
        view.pan_y = (view.canvas_h - vis_h) / 2
    else
        view.pan_y = math.max(0, math.min(view.canvas_h - vis_h, view.pan_y))
    end
end

------------------------------------------------------------------------------
-- Bounds and rectangles
------------------------------------------------------------------------------

-- Bounding box of a flat point list {x1,y1,x2,y2,...}, aligned to the axes.
-- Returns nil for an empty list.
-- A stroke's runs: the parts between its pen lifts. `breaks` lists the point
-- numbers (1-based) where a new run starts, as a see-through stroke the eraser
-- cut keeps them (ink/cut.lua). Returns { { pts, pr }, ... }: the stroke itself
-- when it has no breaks.
function Geom.runs(pts, pr, breaks)
    if not breaks or #breaks == 0 then return { { pts = pts, pr = pr } } end
    local out, start = {}, 1
    local n = math.floor(#pts / 2)
    for k = 1, #breaks + 1 do
        local stop = (breaks[k] or (n + 1)) - 1
        if stop >= start then
            local p, q = {}, pr and {} or nil
            for i = start, stop do
                p[#p + 1] = pts[2 * i - 1]; p[#p + 1] = pts[2 * i]
                if q then q[#q + 1] = pr[i] end
            end
            out[#out + 1] = { pts = p, pr = q }
        end
        start = math.max(start, stop + 1)
    end
    return out
end

function Geom.bounds(pts)
    local n = math.floor(#pts / 2)
    if n == 0 then return nil end
    local x0, y0 = pts[1], pts[2]
    local x1, y1 = x0, y0
    for i = 2, n do
        local x, y = pts[2 * i - 1], pts[2 * i]
        if x < x0 then x0 = x elseif x > x1 then x1 = x end
        if y < y0 then y0 = y elseif y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- Union of two rects given as {x,y,w,h}; either may be nil.
function Geom.mergeRect(a, b)
    if not a then return b end
    if not b then return a end
    local x0 = math.min(a.x, b.x)
    local y0 = math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Grow rect r ({x0, y0, x1, y1}) to cover x0..x1, y0..y1 as well. A nil r
-- starts a new rect. Returns r.
function Geom.growRect(r, x0, y0, x1, y1)
    if not r then return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
    if x0 < r.x0 then r.x0 = x0 end
    if y0 < r.y0 then r.y0 = y0 end
    if x1 > r.x1 then r.x1 = x1 end
    if y1 > r.y1 then r.y1 = y1 end
    return r
end

-- Is (px, py) inside the rect {x, y, w, h}, edges included?
function Geom.inRect(px, py, r)
    return px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h
end

-- Clip a rect to [0,w) x [0,h), rounding outward. Returns nil if empty.
function Geom.clipRect(x, y, w, h, width, height)
    local x0 = math.max(0, math.floor(x))
    local y0 = math.max(0, math.floor(y))
    local x1 = math.min(width, math.ceil(x + w))
    local y1 = math.min(height, math.ceil(y + h))
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1 - x0, y1 - y0
end

-- Even-odd test: is (px, py) inside the polygon `poly` (flat x,y list)?
function Geom.pointInPoly(px, py, poly)
    local n = math.floor(#poly / 2)
    if n < 3 then return false end
    local inside = false
    local jx, jy = poly[2 * n - 1], poly[2 * n]
    for i = 1, n do
        local ix, iy = poly[2 * i - 1], poly[2 * i]
        if ((iy > py) ~= (jy > py)) and (px < (jx - ix) * (py - iy) / (jy - iy) + ix) then
            inside = not inside
        end
        jx, jy = ix, iy
    end
    return inside
end

-- Nonzero-winding test: is (px, py) inside the loop `poly` (flat x,y list, closed
-- back to its start)? Unlike the even-odd rule, a part the loop wraps twice (a
-- hand that carries on past where it started) still counts as inside.
function Geom.windingInPoly(px, py, poly)
    local n = math.floor(#poly / 2)
    if n < 3 then return false end
    local wn = 0
    local jx, jy = poly[2 * n - 1], poly[2 * n]
    for i = 1, n do
        local ix, iy = poly[2 * i - 1], poly[2 * i]
        local left = (ix - jx) * (py - jy) - (px - jx) * (iy - jy)
        if jy <= py then
            if iy > py and left > 0 then wn = wn + 1 end
        elseif iy <= py and left < 0 then
            wn = wn - 1
        end
        jx, jy = ix, iy
    end
    return wn ~= 0
end

-- Is (px, py) within sqrt(d2) of the closed path `poly` (flat x,y list)?
function Geom.nearPath(px, py, poly, d2)
    local n = math.floor(#poly / 2)
    if n < 1 then return false end
    local jx, jy = poly[2 * n - 1], poly[2 * n]
    for i = 1, n do
        local ix, iy = poly[2 * i - 1], poly[2 * i]
        if Geom.segDist2(px, py, jx, jy, ix, iy) <= d2 then return true end
        jx, jy = ix, iy
    end
    return false
end

-- Squared distance from (px, py) to the segment (ax, ay)-(bx, by).
function Geom.segDist2(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and ((px - ax) * dx + (py - ay) * dy) / len2 or 0
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local ex, ey = ax + t * dx - px, ay + t * dy - py
    return ex * ex + ey * ey
end

-- Which side of the line p-q point r lies on (the sign of the cross product).
local function side(px, py, qx, qy, rx, ry)
    return (qx - px) * (ry - py) - (qy - py) * (rx - px)
end

-- Squared distance between segments (ax, ay)-(bx, by) and (cx, cy)-(dx, dy): 0
-- when they cross, otherwise the nearest endpoint-to-segment distance.
function Geom.segSegDist2(ax, ay, bx, by, cx, cy, dx, dy)
    local d1, d2 = side(cx, cy, dx, dy, ax, ay), side(cx, cy, dx, dy, bx, by)
    local d3, d4 = side(ax, ay, bx, by, cx, cy), side(ax, ay, bx, by, dx, dy)
    if d1 * d2 < 0 and d3 * d4 < 0 then return 0 end
    return math.min(Geom.segDist2(ax, ay, cx, cy, dx, dy), Geom.segDist2(bx, by, cx, cy, dx, dy),
        Geom.segDist2(cx, cy, ax, ay, bx, by), Geom.segDist2(dx, dy, ax, ay, bx, by))
end

------------------------------------------------------------------------------
-- Stroke simplification
------------------------------------------------------------------------------

-- Drop points closer than `min_spacing` to the previously kept point, keeping the
-- first and last. Takes and returns flat {x,y,...} lists. An optional `aux`, one
-- value per point (pen pressure), is thinned the same way and returned second.
function Geom.dropClose(pts, min_spacing, aux)
    local n = math.floor(#pts / 2)
    if n <= 2 then return copyList(pts), aux and copyList(aux) end
    local ms2 = min_spacing * min_spacing
    local out = { pts[1], pts[2] }
    local oaux = aux and { aux[1] }
    local lx, ly = pts[1], pts[2]
    for i = 2, n - 1 do
        local x, y = pts[2 * i - 1], pts[2 * i]
        local dx, dy = x - lx, y - ly
        if dx * dx + dy * dy >= ms2 then
            out[#out + 1] = x
            out[#out + 1] = y
            if oaux then oaux[#oaux + 1] = aux[i] end
            lx, ly = x, y
        end
    end
    out[#out + 1] = pts[2 * n - 1]
    out[#out + 1] = pts[2 * n]
    if oaux then oaux[#oaux + 1] = aux[n] end
    return out, oaux
end

-- Ramer-Douglas-Peucker simplification of a flat point list. Returns the points
-- it keeps; `tol` is how far a point may sit from the line before it is kept, in
-- the units of pts. With `aux` (one value per point, pen pressure) a point is
-- also kept where its value strays from the straight-line blend of the ends by
-- more than tol / aux_scale, so a stroke keeps its swell; the kept values are
-- returned second.
function Geom.rdp(pts, tol, aux, aux_scale)
    local n = math.floor(#pts / 2)
    if n <= 2 then return copyList(pts), aux and copyList(aux) end
    local keep = {}
    for i = 1, n do keep[i] = false end
    keep[1], keep[n] = true, true
    local stack = { { 1, n } }
    while #stack > 0 do
        local seg = table.remove(stack)
        local a, b = seg[1], seg[2]
        if b > a + 1 then
            local ax, ay = pts[2 * a - 1], pts[2 * a]
            local bx, by = pts[2 * b - 1], pts[2 * b]
            local vx, vy = bx - ax, by - ay
            local len = math.sqrt(vx * vx + vy * vy)
            local inv = len > 0 and (1 / len) or 0
            local split, maxd = -1, tol
            for j = a + 1, b - 1 do
                local px, py = pts[2 * j - 1], pts[2 * j]
                -- how far point j sits from the line through a and b; when a and b
                -- are the same point (a loop that closes on its start) there is no
                -- line, so use the distance from that point, or the whole loop
                -- collapses to a dot
                local d
                if len > 0 then
                    d = math.abs((py - ay) * vx - (px - ax) * vy) * inv
                else
                    d = math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay))
                end
                if aux then
                    -- the value's distance from its blend along a..b, in px
                    local t = (b > a) and (j - a) / (b - a) or 0
                    local da = math.abs(aux[j] - (aux[a] + (aux[b] - aux[a]) * t)) * (aux_scale or 1)
                    if da > d then d = da end
                end
                if d > maxd then maxd, split = d, j end
            end
            if split > 0 then
                keep[split] = true
                stack[#stack + 1] = { a, split }
                stack[#stack + 1] = { split, b }
            end
        end
    end
    local out, oaux = {}, aux and {}
    for i = 1, n do
        if keep[i] then
            out[#out + 1] = pts[2 * i - 1]
            out[#out + 1] = pts[2 * i]
            if oaux then oaux[#oaux + 1] = aux[i] end
        end
    end
    return out, oaux
end

------------------------------------------------------------------------------
-- Input aids: stabilizer, grid snap, angle snap
------------------------------------------------------------------------------

-- Exponential smoothing for the stabilizer: move the smoothed point a fraction
-- `alpha` of the way to the raw point (1 for none, small values for heavy).
function Geom.ema(px, py, x, y, alpha)
    return px + (x - px) * alpha, py + (y - py) * alpha
end

-- Map a 0..100 stabilizer strength to an EMA alpha: 0 gives 1 (off), 100 ~0.08.
function Geom.stabilizerAlpha(strength)
    local s = math.max(0, math.min(100, strength or 0)) / 100
    return 1 - s * 0.92
end

-- Snap a point to the nearest grid intersection of the given spacing.
function Geom.snapToGrid(x, y, spacing)
    if not spacing or spacing <= 0 then return x, y end
    return math.floor(x / spacing + 0.5) * spacing,
           math.floor(y / spacing + 0.5) * spacing
end

-- Snap the segment from (x0, y0) to (x1, y1) to the nearest 45-degree direction,
-- keeping its length. Returns the adjusted end point.
function Geom.snapAngle(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return x1, y1 end
    local step = math.pi / 4
    local a = math.floor(math.atan2(dy, dx) / step + 0.5) * step
    return x0 + math.cos(a) * len, y0 + math.sin(a) * len
end

return Geom
