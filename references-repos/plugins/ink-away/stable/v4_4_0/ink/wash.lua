--[[
See-through pens: Highlighter, Marker and Watercolor. Every other pen paints an
opaque colour; these blend with what is under them.

A wash stroke is drawn in two steps:
 1. Coverage: the stroke is stamped into an 8-bit mask, keeping the larger value
    where its own stamps overlap, so a stroke never darkens itself however often
    the pen goes back over it.
 2. Blend: the mask is laid on the page once.
      over      the pen's colour at the mask's strength (Marker, Watercolor):
                a second stroke over the first comes out darker
      multiply  the page times the pen's tint (Highlighter): white turns the
                tint, black text and ink stay black
On screen the blend is KOReader's C blitter (colorblitFrom, multiplyRectRGB);
exports blend with the same integer formula (DIV_255), so files match.

A mask is { buf = uint8_t[w*h], w, h, ox, oy }: (ox, oy) is its top-left in
canvas pixels.
]]

local ffi = require("ffi")
local Geom = require("ink/geom")
local Raster = require("ink/raster")
local Symmetry = require("ink/symmetry")

local Wash = {}

local floor, ceil, sqrt, max, min = math.floor, math.ceil, math.sqrt, math.max, math.min

-- The C blitter's rounding of v / 255, for the export to match the screen.
local function div255(v)
    v = v + 128
    return floor((floor(v / 256) + v) / 256)
end
Wash.div255 = div255

-- The pens. tip: "chisel" (a flat nib held upright, highlighter), "round" (a
-- hard round tip) or "soft" (a soft round tip, watercolour).
Wash.STYLES = {
    highlighter = { engine = "wash", solid = true, blend = "multiply", tip = "chisel" },
    felttip     = { engine = "wash", solid = true, blend = "over", tip = "round" },
    wash        = { engine = "wash", solid = true, blend = "over", tip = "soft",
                    soft = 0.35, wet = 0.7, pressure = true, minf = 0.6, sim = true },
}
for k, st in pairs(Wash.STYLES) do Raster.STYLES[k] = st end

function Wash.isWash(op)
    local st = op and op.kind == "ink" and op.style and Raster.STYLES[op.style]
    if not st then return false end
    return st.engine == "wash", st
end

------------------------------------------------------------------------------
-- Masks
------------------------------------------------------------------------------

function Wash.newMask(w, h, ox, oy)
    w, h = max(1, floor(w)), max(1, floor(h))
    return { buf = ffi.new("uint8_t[?]", w * h), w = w, h = h, ox = ox or 0, oy = oy or 0 }
end

-- What stamping changed in a mask: the box (canvas px, x1 and y1 included) of
-- the pixels it raised since Wash.unmark, or nil. Drawing live, only those
-- pixels are drawn and refreshed again (see washPoint).
function Wash.unmark(m)
    m.cx0, m.cy0, m.cx1, m.cy1 = math.huge, math.huge, -math.huge, -math.huge
end
function Wash.marked(m)
    if not m.cx0 or m.cx1 < m.cx0 then return nil end
    return m.cx0, m.cy0, m.cx1, m.cy1
end
local function mark(m, x0, x1, y)
    if not m.cx0 then Wash.unmark(m) end
    if x0 < m.cx0 then m.cx0 = x0 end
    if x1 > m.cx1 then m.cx1 = x1 end
    if y < m.cy0 then m.cy0 = y end
    if y > m.cy1 then m.cy1 = y end
end

-- Zero a rect (canvas coordinates) of a mask, or all of it.
function Wash.clearMask(m, x0, y0, x1, y1)
    if not x0 then ffi.fill(m.buf, m.w * m.h); return end
    x0, y0 = max(0, floor(x0) - m.ox), max(0, floor(y0) - m.oy)
    x1, y1 = min(m.w, ceil(x1) - m.ox), min(m.h, ceil(y1) - m.oy)
    if x1 <= x0 then return end
    for y = y0, y1 - 1 do ffi.fill(m.buf + y * m.w + x0, x1 - x0) end
end

-- A writer that raises a run of a mask (canvas coordinates) to at least v.
local function maskPut(m, v)
    local buf, w, h, ox, oy = m.buf, m.w, m.h, m.ox, m.oy
    return function(x, y, len)
        y = y - oy
        if y < 0 or y >= h then return end
        x = x - ox
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        local base = y * w + x
        local first, last
        for i = 0, len - 1 do
            if buf[base + i] < v then
                buf[base + i] = v
                first = first or i
                last = i
            end
        end
        if first then mark(m, x + first + ox, x + last + ox, y + oy) end
    end
end

-- The tip's radius at pressure p (0-255, nil for full).
local function radiusAt(st, r, p)
    if not p or not st.minf then return r end
    return r * (st.minf + (1 - st.minf) * p / 255)
end

-- One soft round stamp: strength falls off over the outer `soft` share of the
-- radius, and a wet rim pools a little darker just inside the edge, smooth
-- throughout. Raises the mask to `alpha` times that.
-- The soft tip's strength across its radius, sampled in 1024 steps of the
-- squared distance (t^2 = (distance / radius)^2 in [0, 1)), per style, so the
-- inner loop needs no square root.
local PROF_N = 1024
local profiles = {}
local function profile(st)
    local key = floor((st.soft or 0.6) * 100) * 10 + floor((st.wet or 0) * 9)
    local p = profiles[key]
    if p then return p end
    p = ffi.new("float[?]", PROF_N + 1)
    local soft, wet = st.soft or 0.6, st.wet or 0
    local inner = 1 - soft
    for i = 0, PROF_N do
        local t = sqrt(i / PROF_N)
        local s = 1
        if t > inner then s = (1 - t) / soft end
        if wet > 0 and t > 0.7 then
            local kk = (t - 0.7) / 0.3
            s = s * (1 + wet * 4 * kk * (1 - kk))
        end
        if s > 1 then s = 1 elseif s < 0 then s = 0 end
        p[i] = s
    end
    profiles[key] = p
    return p
end

-- One piece of a soft stroke, from (x0, y0) at radius r0 to (x1, y1) at r1:
-- every pixel within reach takes the strength for its distance from the
-- segment, once (the overlap with the next piece is settled by the max).
local function softSegment(m, x0, y0, r0, x1, y1, r1, st, alpha)
    local buf, w, h, ox, oy = m.buf, m.w, m.h, m.ox, m.oy
    local prof = profile(st)
    local same_r = r0 == r1
    local inv_r2 = 1 / (r0 * r0)
    local dx, dy = x1 - x0, y1 - y0
    local len2 = dx * dx + dy * dy
    local inv = len2 > 0 and 1 / len2 or 0
    local rmax = r0 > r1 and r0 or r1
    local bx0, by0 = floor(min(x0, x1) - rmax), floor(min(y0, y1) - rmax)
    local bx1, by1 = ceil(max(x0, x1) + rmax), ceil(max(y0, y1) + rmax)
    if bx0 < ox then bx0 = ox end
    if by0 < oy then by0 = oy end
    if bx1 > ox + w - 1 then bx1 = ox + w - 1 end
    if by1 > oy + h - 1 then by1 = oy + h - 1 end
    for y = by0, by1 do
        local py = y - y0
        local mrow = (y - oy) * w - ox
        local first, last
        for x = bx0, bx1 do
            local px = x - x0
            local u = (px * dx + py * dy) * inv
            if u < 0 then u = 0 elseif u > 1 then u = 1 end
            local ex, ey = px - dx * u, py - dy * u
            local t2 = ex * ex + ey * ey
            if same_r then
                t2 = t2 * inv_r2
            else
                local r = r0 + (r1 - r0) * u
                t2 = t2 / (r * r)
            end
            if t2 < 1 then
                local v = floor(alpha * prof[floor(t2 * PROF_N)] + 0.5)
                local o = mrow + x
                if buf[o] < v then
                    buf[o] = v
                    first = first or x
                    last = x
                end
            end
        end
        if first then mark(m, first, last, y) end
    end
end

-- Stamp the stroke (or one piece of it) into mask m. pts and pr are canvas
-- points and pressures; r the full radius; alpha the strength; sym the stroke's
-- symmetry on a W x H page; `breaks` where it was lifted (a stroke the eraser
-- cut keeps its parts as one stroke, so they never glaze over each other).
function Wash.stamp(m, st, pts, pr, r, alpha, sym, W, H, breaks)
    if breaks and #breaks > 0 then
        for _i, run in ipairs(Geom.runs(pts, pr, breaks)) do
            Wash.stamp(m, st, run.pts, run.pr, r, alpha, sym, W, H)
        end
        return
    end
    local n = floor(#pts / 2)
    if n == 0 then return end
    if st.tip == "soft" then
        local flips = Symmetry.flips(sym)
        for _i, f in ipairs(flips) do
            local p = Symmetry.flipPoints(pts, f, W or 0, H or 0)
            if n == 1 then
                local rr = radiusAt(st, r, pr and pr[1])
                softSegment(m, p[1], p[2], rr, p[1], p[2], rr, st, alpha)
            end
            for i = 2, n do
                softSegment(m, p[2 * i - 3], p[2 * i - 2], radiusAt(st, r, pr and pr[i - 1]),
                    p[2 * i - 1], p[2 * i], radiusAt(st, r, pr and pr[i]), st, alpha)
            end
        end
        return
    end
    local put = maskPut(m, alpha)
    if sym and sym ~= "off" then
        local rx, ry = Symmetry.canvasRefs(W, H)
        put = Symmetry.wrap(put, sym, rx, ry)
    end
    if st.tip == "chisel" then
        -- a flat nib held upright: a sideways stroke is as tall as the pen is wide
        local thick = max(1, r * 2 * 0.35)
        Raster.pathNib(pts, r * 2, thick, math.pi / 2, put)
    else
        Raster.path(pts, r, put)
    end
end

-- The box (canvas px) a stroke can cover, before symmetry: x0, y0, x1, y1.
function Wash.box(op)
    local pts = op.pts
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for i = 1, #pts - 1, 2 do
        local x, y = pts[i], pts[i + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    local pad = (op.width or 1) / 2 + 2
    return floor(x0 - pad), floor(y0 - pad), ceil(x1 + pad), ceil(y1 + pad)
end

-- The strength a stroke's mask is stamped at: its opacity for an "over" pen; a
-- multiply pen stamps full and takes its opacity into the tint.
local function strength(op, st)
    if st.blend == "multiply" then return 255 end
    return op.alpha or 255
end
Wash.strength = strength

-- The highlighter's tint: its colour taken toward white by its opacity.
function Wash.tint(op)
    local c = op.color or { 255, 235, 59 }
    local a = op.alpha or 255
    return 255 - div255((255 - c[1]) * a), 255 - div255((255 - c[2]) * a), 255 - div255((255 - c[3]) * a)
end

-- Build a stroke's mask over its whole box on a W x H page (with its symmetry
-- copies, the mask spans the page). `scratch`, if given and big enough, is
-- reused. Returns the mask and the box it covers.
function Wash.buildMask(op, st, W, H, scratch)
    local x0, y0, x1, y1
    if op.sym and op.sym ~= "off" then
        x0, y0, x1, y1 = 0, 0, W, H
    else
        x0, y0, x1, y1 = Wash.box(op)
        x0, y0, x1, y1 = max(0, x0), max(0, y0), min(W, x1), min(H, y1)
    end
    if x1 <= x0 or y1 <= y0 then return nil end
    local w, h = x1 - x0, y1 - y0
    local m
    if scratch and scratch.w * scratch.h >= w * h then
        m = scratch
        m.w, m.h, m.ox, m.oy = w, h, x0, y0
        ffi.fill(m.buf, w * h)
    else
        m = Wash.newMask(w, h, x0, y0)
    end
    Wash.stamp(m, st, op.pts, op.pr, (op.width or 1) / 2, strength(op, st), op.sym, W, H, op.breaks)
    return m, x0, y0, x1, y1
end

-- Masks kept for the screen: a page is composed again often (undo, a page turn
-- back, a selection lifted and dropped), and a saved stroke never changes (an
-- edit replaces it with a copy), so its mask is built once. Bounded by size;
-- the oldest go first.
local CACHE_MAX = 12 * 1024 * 1024
local cache, cache_order, cache_bytes = {}, {}, 0

local function signature(op, W, H)
    local pts = op.pts
    return table.concat({ #pts, pts[1] or 0, pts[2] or 0, pts[#pts] or 0, op.width or 0, op.alpha or 255,
        op.sym or "", op.style or "", op.pr and #op.pr or 0, op.breaks and #op.breaks or 0, W, H }, "|")
end

function Wash.cachedMask(op, st, W, H)
    local sig = signature(op, W, H)
    local e = cache[op]
    if e and e.sig == sig then return e.m end
    local m = Wash.buildMask(op, st, W, H)
    if not m then return nil end
    local bytes = m.w * m.h
    if bytes > CACHE_MAX / 4 then return m end   -- a page-wide symmetric stroke: not kept
    while cache_bytes + bytes > CACHE_MAX and #cache_order > 0 do
        local old = table.remove(cache_order, 1)
        local oe = cache[old]
        if oe then cache_bytes = cache_bytes - oe.bytes; cache[old] = nil end
    end
    if e then cache_bytes = cache_bytes - e.bytes end
    cache[op] = { m = m, sig = sig, bytes = bytes }
    cache_order[#cache_order + 1] = op
    cache_bytes = cache_bytes + bytes
    return m
end

-- The mask the screen already keeps for op, if any (an export reuses it rather
-- than building it again, without adding to the cache).
function Wash.peekMask(op, W, H)
    local e = cache[op]
    if e and e.sig == signature(op, W, H) then return e.m end
    return nil
end

function Wash.clearCache()
    cache, cache_order, cache_bytes = {}, {}, 0
end

------------------------------------------------------------------------------
-- Blending onto the screen's bitmaps, with KOReader's C blitter
------------------------------------------------------------------------------

-- Lay mask m on bitmap dst (a canvas-sized master or page), within the canvas
-- rect x0, y0, x1, y1 when given. "over" is colorblitFrom (the mask as alpha),
-- "multiply" a multiplyRectRGB per run of the mask.
function Wash.blendBB(dst, m, op, st, x0, y0, x1, y1)
    local Blitbuffer = require("ffi/blitbuffer")
    local cx0, cy0 = max(m.ox, x0 or m.ox), max(m.oy, y0 or m.oy)
    local cx1, cy1 = min(m.ox + m.w, x1 or (m.ox + m.w)), min(m.oy + m.h, y1 or (m.oy + m.h))
    cx1, cy1 = min(cx1, dst:getWidth()), min(cy1, dst:getHeight())
    if cx1 <= cx0 or cy1 <= cy0 then return end
    if st.blend == "multiply" then
        local tint = Blitbuffer.ColorRGB24(Wash.tint(op))
        local buf, mw = m.buf, m.w
        for y = cy0, cy1 - 1 do
            local row = (y - m.oy) * mw - m.ox
            local x = cx0
            while x < cx1 do
                if buf[row + x] > 0 then
                    local s = x
                    while x < cx1 and buf[row + x] > 0 do x = x + 1 end
                    dst:multiplyRectRGB(s, y, x - s, 1, tint)
                else
                    x = x + 1
                end
            end
        end
        return
    end
    local c = op.color or { 0, 0, 0 }
    local color = Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF)
    -- a view of the mask's bytes as an 8-bit bitmap (not owned: never freed)
    local mbb = Blitbuffer.new(m.w, m.h, Blitbuffer.TYPE_BB8, m.buf, m.w)
    local w, h = cx1 - cx0, cy1 - cy0
    if dst:getType() == Blitbuffer.TYPE_BBRGB32 then
        dst:colorblitFromRGB32(mbb, cx0, cy0, cx0 - m.ox, cy0 - m.oy, w, h, color)
    else
        dst:colorblitFrom(mbb, cx0, cy0, cx0 - m.ox, cy0 - m.oy, w, h, color)
    end
end

------------------------------------------------------------------------------
-- Blending into export buffers (the screen uses the C blitter, see compose)
------------------------------------------------------------------------------

-- Blend a mask into a packed buffer `buf` (ow x oh, bpp 3 = RGB or 4 = RGBA, the
-- canvas offset by offx, offy), the way the C blitter does on screen. On RGBA,
-- "over" also raises the alpha, so a transparent PNG gets the wash too. `flags`
-- (ow*oh bytes, optional) gets 1 where a multiplying pen drew on nothing, so an
-- export that lays the page under the ink can multiply it with the page there.
function Wash.blendBuffer(buf, ow, oh, bpp, offx, offy, m, op, st, flags)
    local mbuf, mw, mh = m.buf, m.w, m.h
    local x0, y0 = m.ox - offx, m.oy - offy
    local multiply = st.blend == "multiply"
    local r, g, b
    -- a highlighter over nothing in a transparent PNG is its colour at its
    -- opacity, which over white gives exactly the tint
    local hc = op.color or { 255, 235, 59 }
    local ha = op.alpha or 255
    if multiply then r, g, b = Wash.tint(op)
    else local c = op.color or { 0, 0, 0 }; r, g, b = c[1], c[2], c[3] end
    for my = 0, mh - 1 do
        local y = y0 + my
        if y >= 0 and y < oh then
            local row = my * mw
            for mx = 0, mw - 1 do
                local a = mbuf[row + mx]
                local x = x0 + mx
                if a > 0 and x >= 0 and x < ow then
                    local o = (y * ow + x) * bpp
                    if multiply then
                        if bpp == 4 and buf[o + 3] == 0 then
                            buf[o], buf[o + 1], buf[o + 2], buf[o + 3] = hc[1], hc[2], hc[3], ha
                            if flags then flags[y * ow + x] = 1 end
                        else
                            buf[o] = div255(buf[o] * r)
                            buf[o + 1] = div255(buf[o + 1] * g)
                            buf[o + 2] = div255(buf[o + 2] * b)
                        end
                    elseif a == 255 then
                        buf[o], buf[o + 1], buf[o + 2] = r, g, b
                        if bpp == 4 then buf[o + 3] = 255 end
                    else
                        local ai = 255 - a
                        if bpp == 4 then
                            local da = buf[o + 3]
                            if da == 0 then
                                buf[o], buf[o + 1], buf[o + 2], buf[o + 3] = r, g, b, a
                            else
                                buf[o] = div255(buf[o] * ai + r * a)
                                buf[o + 1] = div255(buf[o + 1] * ai + g * a)
                                buf[o + 2] = div255(buf[o + 2] * ai + b * a)
                                buf[o + 3] = da + div255((255 - da) * a)
                            end
                        else
                            buf[o] = div255(buf[o] * ai + r * a)
                            buf[o + 1] = div255(buf[o + 1] * ai + g * a)
                            buf[o + 2] = div255(buf[o + 2] * ai + b * a)
                        end
                    end
                end
            end
        end
    end
end

return Wash
