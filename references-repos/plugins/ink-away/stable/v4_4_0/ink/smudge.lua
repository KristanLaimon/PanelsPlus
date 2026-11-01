--[[
The smudge: drag ink as a finger drags wet paint or graphite. Only ink moves.
The paper, its ruling or grid, a background picture, placed pictures and text
are never picked up, though smudged ink can be laid over them.

The brush carries a small patch of colour, the size of the brush. At each step
along the path it first picks up some of what lies under it (only ink: a pixel
that differs from the page without ink), then lays the patch back down, so what
it picked up a step earlier lands a little further on. Colours mix as paint
does, not as light: each channel is mixed as an amount of pigment (its
absorbance, -log of the light it lets through), so yellow pushed into blue
turns green, not grey.

A smudge is an op ({ kind = "smudge", pts, width, alpha = strength }) replayed in
order like every other, by this one function on every surface: the screen's
master and the export buffers, so files match the screen. Its points are kept
as drawn (not simplified), so the replay retraces the live stroke exactly.

A surface is { ptr = uint8_t*, stride = bytes per row, bpp = 1 (grey), 3 (RGB)
or 4 (RGB32, or RGBA with `alpha`), w, h }.
]]

local ffi = require("ffi")
local Symmetry = require("ink/symmetry")

local Smudge = {}

local floor, ceil, sqrt, max, min = math.floor, math.ceil, math.sqrt, math.max, math.min

local PICKUP = 0.45      -- how much of what lies under the brush it takes each step

-- Paint-like mixing: a channel value as absorbance, and back, through tables.
local ABS = ffi.new("float[256]")
for c = 0, 255 do ABS[c] = -math.log((c + 0.5) / 256) end
local INV_K = 1024                                  -- table steps per unit of absorbance
local INV_N = ceil(ABS[0] * INV_K) + 2
local INV = ffi.new("uint8_t[?]", INV_N)
for i = 0, INV_N - 1 do
    local c = floor(256 * math.exp(-i / INV_K))
    INV[i] = c > 255 and 255 or c
end
local function toValue(a)
    local i = floor(a * INV_K + 0.5)
    if i < 0 then i = 0 elseif i >= INV_N then i = INV_N - 1 end
    return INV[i]
end
Smudge.absorbance, Smudge.fromAbsorbance = function(c) return ABS[c] end, toValue

-- A surface over a KOReader Blitbuffer: 8-bit grey or RGB32 (as the canvas
-- always is), not rotated. nil for anything else.
function Smudge.surfaceOf(bb)
    if not bb then return nil end
    local ok, t = pcall(function() return bb:getType() end)
    if not ok then return nil end
    if (bb.getRotation and bb:getRotation() ~= 0) or (bb.getInverse and bb:getInverse() ~= 0) then return nil end
    local BB = require("ffi/blitbuffer")
    local bpp = (t == BB.TYPE_BB8 and 1) or (t == BB.TYPE_BBRGB32 and 4) or nil
    if not bpp then return nil end
    return { ptr = ffi.cast("uint8_t*", bb.data), stride = tonumber(bb.stride), bpp = bpp,
             w = bb:getWidth(), h = bb:getHeight(), keep = bb }
end

-- A surface over a packed export buffer (RGB or RGBA). It keeps the buffer
-- alive for as long as the surface is used (`keep`).
function Smudge.surfaceOfBuffer(buf, w, h, bpp, alpha)
    return { ptr = ffi.cast("uint8_t*", buf), stride = w * bpp, bpp = bpp, w = w, h = h, alpha = alpha,
             keep = buf }
end

-- A fresh brush for a stroke of radius r: its patch and how far it has come.
function Smudge.newState(r)
    local R = max(1, ceil(r))
    local side = 2 * R + 1
    return { r = r, R = R, side = side, acc = ffi.new("double[?]", side * side * 4),
             started = false, left = 0 }
end

-- One step of the brush at (cx, cy) on surface s, with base b (the page without
-- ink, the same layout). k is the strength, 0-255.
-- (The step is compiled once per kind of surface: see stepFor.)
local STEP_SRC = [==[
local floor, ABS, PICKUP, toValue = ...
return function(st, s, b, cx, cy, k)
    local R, side, acc, r = st.R, st.side, st.acc, st.r
    local ptr, stride, bpp, w, h = s.ptr, s.stride, s.bpp, s.w, s.h
    local bptr = b.ptr
    local alpha_ch = s.alpha
    local icx, icy = floor(cx + 0.5), floor(cy + 0.5)
    local first = not st.started
    st.started = true
    local inv_r2 = 1 / (r * r)
    local strength = k / 255
    for dy = -R, R do
        local y = icy + dy
        if y >= 0 and y < h then
            local row = y * stride
            for dx = -R, R do
                local d2 = (dx * dx + dy * dy) * inv_r2
                local x = icx + dx
                if d2 <= 1 and x >= 0 and x < w then
                    local o = row + x * bpp
                    local ai = ((dy + R) * side + (dx + R)) * 4
                    -- is this pixel ink? (it differs from the page without ink)
                    local ink
                    if bpp == 1 then
                        ink = ptr[o] ~= bptr[o]
                    elseif alpha_ch then
                        ink = ptr[o + 3] > 0 and (ptr[o] ~= bptr[o] or ptr[o + 1] ~= bptr[o + 1]
                            or ptr[o + 2] ~= bptr[o + 2] or ptr[o + 3] ~= bptr[o + 3])
                    else
                        ink = ptr[o] ~= bptr[o] or ptr[o + 1] ~= bptr[o + 1] or ptr[o + 2] ~= bptr[o + 2]
                    end
                    -- Paper under a brush that carries next to nothing: it only
                    -- thins the load further, and too little is left to lay
                    -- down (the test below, t <= 0.002), so nothing else is
                    -- read or written. Most of a smudge's area is that, and
                    -- this keeps a page with smudges quick to draw again.
                    local skip = false
                    if not first and not ink then
                        local l = acc[ai + 3] * (1 - PICKUP)
                        if l / 255 * strength * (1 - d2) <= 0.002 then
                            acc[ai + 3] = l
                            skip = true
                        end
                    end
                    if not skip then
                        local c1 = ptr[o]
                        local c2 = bpp > 1 and ptr[o + 1] or c1
                        local c3 = bpp > 1 and ptr[o + 2] or c1
                        -- how much ink the pixel holds: all of it on an opaque page, its
                        -- alpha in a transparent PNG
                        local load = ink and (alpha_ch and ptr[o + 3] or 255) or 0
                        -- the brush holds pigment: each channel as absorbance
                        local a1, a2, a3 = ABS[c1], ABS[c2], ABS[c3]
                        if first then
                            acc[ai], acc[ai + 1], acc[ai + 2] = a1, a2, a3
                            acc[ai + 3] = load
                        else
                            -- pick up: ink brings its pigment; paper only thins the load
                            if ink then
                                acc[ai] = acc[ai] + (a1 - acc[ai]) * PICKUP
                                acc[ai + 1] = acc[ai + 1] + (a2 - acc[ai + 1]) * PICKUP
                                acc[ai + 2] = acc[ai + 2] + (a3 - acc[ai + 2]) * PICKUP
                                acc[ai + 3] = acc[ai + 3] + (load - acc[ai + 3]) * PICKUP
                            else
                                acc[ai + 3] = acc[ai + 3] * (1 - PICKUP)
                            end
                            -- lay down, strongest at the centre, mixing pigments
                            local t = acc[ai + 3] / 255 * strength * (1 - d2)
                            if t > 0.002 then
                                if alpha_ch and ptr[o + 3] == 0 then
                                    ptr[o], ptr[o + 1], ptr[o + 2] = toValue(acc[ai]),
                                        toValue(acc[ai + 1]), toValue(acc[ai + 2])
                                    ptr[o + 3] = floor(255 * t + 0.5)
                                else
                                    ptr[o] = toValue(a1 + (acc[ai] - a1) * t)
                                    if bpp > 1 then
                                        ptr[o + 1] = toValue(a2 + (acc[ai + 1] - a2) * t)
                                        ptr[o + 2] = toValue(a3 + (acc[ai + 2] - a3) * t)
                                        if alpha_ch then
                                            ptr[o + 3] = floor(ptr[o + 3] + (255 - ptr[o + 3]) * t + 0.5)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
]==]

-- The step for surfaces like `s`. Each kind (grey, RGB, RGB32, RGBA) gets a
-- copy of its own: LuaJIT compiles a loop for the first kind it meets, and a
-- page drawn on another kind afterwards (the screen's grey page after an RGBA
-- export, say) fell back to the interpreter and took thirty times as long.
local stepFor = {}
local function stepOf(s)
    local key = s.bpp .. (s.alpha and "a" or "")
    local f = stepFor[key]
    if not f then
        f = load(STEP_SRC, "=ink/smudge.lua step " .. key)(floor, ABS, PICKUP, toValue)
        stepFor[key] = f
    end
    return f
end

-- Move the brush from (x0, y0) to (x1, y1), stepping every quarter radius;
-- leftover distance carries over to the next segment. A nil x0 places it.
function Smudge.segment(st, s, b, x0, y0, x1, y1, k)
    local step = st.step
    if not step then step = stepOf(s); st.step = step end
    if not x0 then return step(st, s, b, x1, y1, k) end
    local spacing = max(1, st.r * 0.25)
    local dx, dy = x1 - x0, y1 - y0
    local dist = sqrt(dx * dx + dy * dy)
    if dist <= 0 then return end
    local d = spacing - st.left
    while d <= dist do
        local f = d / dist
        step(st, s, b, x0 + dx * f, y0 + dy * f, k)
        d = d + spacing
    end
    st.left = dist - (d - spacing)
end

-- Replay a whole smudge op on surface s with base b, with its symmetry copies
-- (each its own brush) on a W x H page. A cropped export's surface starts at
-- canvas (offx, offy).
function Smudge.apply(s, b, op, W, H, offx, offy)
    local pts = op.pts
    local n = floor(#pts / 2)
    if n == 0 or not (s and b) then return end
    local r = max(1, (op.width or 1) / 2)
    local k = op.alpha or 255
    offx, offy = offx or 0, offy or 0
    for _i, f in ipairs(Symmetry.flips(op.sym)) do
        local p = Symmetry.flipPoints(pts, f, W or s.w, H or s.h)
        if offx ~= 0 or offy ~= 0 then
            local q = {}
            for i = 1, #p - 1, 2 do q[i], q[i + 1] = p[i] - offx, p[i + 1] - offy end
            p = q
        end
        local st = Smudge.newState(r)
        Smudge.segment(st, s, b, nil, nil, p[1], p[2], k)
        for i = 2, n do
            Smudge.segment(st, s, b, p[2 * i - 3], p[2 * i - 2], p[2 * i - 1], p[2 * i], k)
        end
    end
end

-- The canvas rect a segment from (x0, y0) to (x1, y1) of radius r touches.
function Smudge.rect(x0, y0, x1, y1, r)
    local R = ceil(r) + 1
    return { x0 = floor(min(x0 or x1, x1)) - R, y0 = floor(min(y0 or y1, y1)) - R,
             x1 = ceil(max(x0 or x1, x1)) + R + 1, y1 = ceil(max(y0 or y1, y1)) + R + 1 }
end

return Smudge
