--[[
Cutting ink with an eraser path, for ink that has to stay separate strokes:
over a book each stroke is anchored to the word it marks (ink/reader/place.lua),
so a rubbed-out part cannot be a mask laid over it, which would stay put while
the stroke follows its word to a new layout. Instead each stroke the eraser
crosses is cut, and the parts outside the eraser become strokes of their own.

  * ink: walked in small steps; the runs outside the eraser (its radius plus the
    stroke's) are kept, simplified, with their pressures;
  * shapes: an outline-only shape is cut as its outline and arrowheads, which
    become plain strokes, each marked `cut_of` = the shape (so over a book they
    keep the shape's anchor and stay together); a filled one touched by the
    eraser goes whole;
  * a paint bucket fill: the eraser's disc taken out of each of its rows;
  * text boxes and pictures go whole when touched, if asked to (`text`,
    `pictures`).
A layered drawing erases this way too (ink/layers.lua), on its active layer only
(`only`), so the layers under it are never rubbed out with it.
Plain Lua, so the headless tests drive it.
]]

local Geom = require("ink/geom")
local Shapes = require("ink/shapes")
local Canvas = require("ink/canvas")
local Text = require("ink/text")
local Wash = require("ink/wash")

local Cut = {}

local floor, sqrt, min, max, ceil = math.floor, math.sqrt, math.min, math.max, math.ceil

-- The eraser: its points, radius, and box, for quick rejection.
local function eraser(epts, er)
    local x0, y0, x1, y1 = Geom.bounds(epts)
    return { pts = epts, r = er, x0 = x0, y0 = y0, x1 = x1, y1 = y1, n = floor(#epts / 2) }
end

-- Is (x, y) within `reach` (squared: r2) of the eraser's path?
local function under(e, x, y, reach, r2)
    if x < e.x0 - reach or x > e.x1 + reach or y < e.y0 - reach or y > e.y1 + reach then return false end
    local p = e.pts
    if e.n == 1 then
        local dx, dy = x - p[1], y - p[2]
        return dx * dx + dy * dy <= r2
    end
    for i = 1, e.n - 1 do
        local ax, ay, bx, by = p[2 * i - 1], p[2 * i], p[2 * i + 1], p[2 * i + 2]
        if not (x < min(ax, bx) - reach or x > max(ax, bx) + reach
                or y < min(ay, by) - reach or y > max(ay, by) + reach) then
            if Geom.segDist2(x, y, ax, ay, bx, by) <= r2 then return true end
        end
    end
    return false
end

-- A copy of `op` holding `pts` (and `pr`): one of its pieces.
local function piece(op, pts, pr)
    local c = Canvas.cloneOp(nil, op)
    c.pts, c.pr = pts, pr
    return c
end

-- Cut a polyline (flat pts, optional per-point pressures) of half-width hw with
-- eraser e. Returns nil when the eraser does not reach it, else a list of
-- { pts, pr } runs left outside it (empty when all of it is rubbed out).
local function cutLine(pts, pr, hw, e)
    local reach = e.r + hw
    local r2 = reach * reach
    local n = floor(#pts / 2)
    -- quick rejection: the boxes do not meet
    local sx0, sy0, sx1, sy1 = Geom.bounds(pts)
    if sx1 < e.x0 - reach or sx0 > e.x1 + reach or sy1 < e.y0 - reach or sy0 > e.y1 + reach then return nil end
    if n == 1 then
        if under(e, pts[1], pts[2], reach, r2) then return {} end
        return nil
    end
    -- the line in steps of at most `step`, each kept or rubbed out
    local step = max(1, min(hw, e.r) / 2)
    local runs, cur, touched = {}, nil, false
    local function keep(x, y, p)
        if not cur then cur = { pts = {}, pr = pr and {} or nil }; runs[#runs + 1] = cur end
        local q = cur.pts
        q[#q + 1] = x; q[#q + 1] = y
        if cur.pr then cur.pr[#cur.pr + 1] = p end
    end
    for i = 1, n - 1 do
        local ax, ay, bx, by = pts[2 * i - 1], pts[2 * i], pts[2 * i + 1], pts[2 * i + 2]
        local pa, pb = pr and pr[i] or nil, pr and pr[i + 1] or nil
        local len = sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        local k = max(1, ceil(len / step))
        for j = (i == 1) and 0 or 1, k do
            local t = j / k
            local x, y = ax + (bx - ax) * t, ay + (by - ay) * t
            local p = pa and floor(pa + (pb - pa) * t + 0.5) or nil
            if under(e, x, y, reach, r2) then
                touched = true
                cur = nil
            else
                keep(x, y, p)
            end
        end
    end
    if not touched then return nil end
    -- each run simplified back to a few points (and a lone point kept as a dot)
    local out = {}
    for _, r in ipairs(runs) do
        local q, rp = r.pts, r.pr
        if #q >= 4 then q, rp = Geom.rdp(q, 0.6, rp, (hw * 2) * 0.5 / 255) end
        if #q >= 2 then out[#out + 1] = { pts = q, pr = rp } end
    end
    return out
end

-- Does the eraser reach the box (x0, y0, x1, y1)?
local function reachesBox(e, x0, y0, x1, y1)
    if x1 < e.x0 - e.r or x0 > e.x1 + e.r or y1 < e.y0 - e.r or y0 > e.y1 + e.r then return false end
    local p, r2 = e.pts, e.r * e.r
    local function near(x, y)
        local dx = x < x0 and x0 - x or (x > x1 and x - x1 or 0)
        local dy = y < y0 and y0 - y or (y > y1 and y - y1 or 0)
        return dx * dx + dy * dy <= r2
    end
    if e.n == 1 then return near(p[1], p[2]) end
    -- along each piece of the path (it is simplified, so its points can be far apart)
    local step = max(1, e.r)
    for i = 1, e.n - 1 do
        local ax, ay, bx, by = p[2 * i - 1], p[2 * i], p[2 * i + 1], p[2 * i + 2]
        local k = max(1, ceil(sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / step))
        for j = 0, k do
            local t = j / k
            if near(ax + (bx - ax) * t, ay + (by - ay) * t) then return true end
        end
    end
    return false
end

-- The eraser's disc centres along its path, at most half a radius apart, so the
-- discs together cover it as the eraser's stamps do.
local function discs(e)
    if e.cs then return e.cs end
    local p, cs = e.pts, {}
    local step = max(0.5, e.r / 2)
    if e.n == 1 then cs[1], cs[2] = p[1], p[2] end
    for i = 1, e.n - 1 do
        local ax, ay, bx, by = p[2 * i - 1], p[2 * i], p[2 * i + 1], p[2 * i + 2]
        local k = max(1, ceil(sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / step))
        for j = (i == 1) and 0 or 1, k do
            local t = j / k
            cs[#cs + 1] = ax + (bx - ax) * t; cs[#cs + 1] = ay + (by - ay) * t
        end
    end
    e.cs = cs
    return cs
end

-- The x intervals the eraser covers on pixel row y, merged and sorted:
-- { a1, b1, a2, b2, ... } (cached per row for one cut).
local function rowCover(e, y)
    e.rows = e.rows or {}
    local got = e.rows[y]
    if got then return got end
    local cs, r = discs(e), e.r
    local cy, r2, iv = y + 0.5, r * r, {}
    for k = 1, #cs, 2 do
        local dy = cs[k + 1] - cy
        if dy * dy <= r2 then
            local h = sqrt(r2 - dy * dy)
            iv[#iv + 1] = { cs[k] - h, cs[k] + h }
        end
    end
    table.sort(iv, function(a, b) return a[1] < b[1] end)
    local out = {}
    for _, v in ipairs(iv) do
        local n = #out
        if n > 0 and v[1] <= out[n] then
            if v[2] > out[n] then out[n] = v[2] end
        else
            out[n + 1], out[n + 2] = v[1], v[2]
        end
    end
    e.rows[y] = out
    return out
end

-- A fill's runs ({ x, y, len, ... }) without the pixels the eraser covers (a
-- pixel goes when its centre is under the eraser). nil when it covers none.
local function cutRuns(runs, e)
    local r = e.r
    local out, changed = {}, false
    for i = 1, #runs - 2, 3 do
        local x, y, len = runs[i], runs[i + 1], runs[i + 2]
        local keep = true
        if y + 0.5 >= e.y0 - r and y + 0.5 <= e.y1 + r and x + len >= e.x0 - r and x <= e.x1 + r then
            local cov = rowCover(e, y)
            if #cov > 0 then
                keep = false
                local cx = x            -- the next pixel not yet decided
                local stop = x + len
                for k = 1, #cov, 2 do
                    -- pixels whose centres fall in [a, b]
                    local a = max(cx, ceil(cov[k] - 0.5))
                    local b = min(stop - 1, floor(cov[k + 1] - 0.5))
                    if b >= a then
                        if a > cx then out[#out + 1] = cx; out[#out + 1] = y; out[#out + 1] = a - cx end
                        cx = b + 1
                        changed = true
                    end
                end
                if cx < stop then out[#out + 1] = cx; out[#out + 1] = y; out[#out + 1] = stop - cx end
            end
        end
        if keep then out[#out + 1] = x; out[#out + 1] = y; out[#out + 1] = len end
    end
    if not changed then return nil end
    return out
end

-- Cut one op. Returns nil when the eraser leaves it as it is, else the list of
-- ops that take its place (empty when it goes).
function Cut.op(op, e, opts)
    local k = op.kind
    if k == "ink" and op.pts then
        -- (a stroke cut before keeps its parts apart: each is cut on its own)
        local runs, cut = {}, false
        for _, part in ipairs(Geom.runs(op.pts, op.pr, op.breaks)) do
            local left = cutLine(part.pts, part.pr, (op.width or 1) / 2, e)
            if left then cut = true else left = { part } end
            for _, r in ipairs(left) do runs[#runs + 1] = r end
        end
        if not cut then return nil end
        if #runs == 0 then return {} end
        if Wash.isWash(op) and #runs > 1 then
            -- a see-through pen: its parts stay one stroke, drawn as one wash,
            -- so where they overlap they do not glaze over each other
            local pts, pr, breaks = {}, op.pr and {} or nil, {}
            for _, r in ipairs(runs) do
                if #pts > 0 then breaks[#breaks + 1] = #pts / 2 + 1 end
                for i = 1, #r.pts do pts[#pts + 1] = r.pts[i] end
                if pr then for i = 1, #(r.pr or {}) do pr[#pr + 1] = r.pr[i] end end
            end
            local c = piece(op, pts, pr)
            c.breaks = breaks
            return { c }
        end
        local out = {}
        for _, r in ipairs(runs) do
            local c = piece(op, r.pts, r.pr)
            c.breaks = nil
            out[#out + 1] = c
        end
        return out
    elseif k == "shape" then
        if not Shapes.reachedBy(op, e.pts, e.r) then return nil end
        if op.fill or op.fill_color then return {} end   -- a filled shape goes whole
        local out = {}
        for _, line in ipairs(Shapes.outlines(op)) do
            local runs = cutLine(line, nil, (op.width or 2) / 2, e) or { { pts = line } }
            for _, r in ipairs(runs) do
                out[#out + 1] = { kind = "ink", style = "solid", width = op.width or 2, alpha = op.alpha or 255,
                    color = op.color and { op.color[1], op.color[2], op.color[3] } or { 0, 0, 0 },
                    sym = op.sym, pts = r.pts, cut_of = op, layer = op.layer }
            end
        end
        return out
    elseif k == "fill" and op.runs then
        local x0, y0, x1, y1 = Canvas.opBox(op)
        if not (x0 and reachesBox(e, x0, y0, x1, y1)) then return nil end
        local runs = cutRuns(op.runs, e)
        if not runs then return nil end
        if #runs == 0 then return {} end
        local c = Canvas.cloneOp(nil, op)
        c.runs = runs
        return { c }
    elseif k == "text" and opts.text and Text.turned(op) then
        -- in the box's own frame, where it is a plain box
        if not (op.h and op.h > 0) then return nil end
        local lp = {}
        for i = 1, #e.pts - 1, 2 do lp[i], lp[i + 1] = Text.toLocal(op, e.pts[i], e.pts[i + 1]) end
        if reachesBox(eraser(lp, e.r), 0, 0, op.w or 0, op.h) then return {} end
    elseif (k == "text" and opts.text) or (k == "image" and opts.pictures) then
        local x0, y0, x1, y1 = Canvas.opBox(op)
        if x0 and reachesBox(e, x0, y0, x1, y1) then return {} end
    end
    return nil
end

-- Cut `ops` with an eraser along `epts` of radius `er`. Returns the new list and
-- whether anything changed (the old list is left as it was).
function Cut.ops(ops, epts, er, opts)
    opts = opts or {}
    local e = eraser(epts, er)
    local out, changed = {}, false
    local only = opts.only
    for _, op in ipairs(ops) do
        local repl = (not only or only(op)) and Cut.op(op, e, opts) or nil
        if repl then
            changed = true
            for _, r in ipairs(repl) do out[#out + 1] = r end
        else
            out[#out + 1] = op
        end
    end
    return out, changed
end

return Cut
