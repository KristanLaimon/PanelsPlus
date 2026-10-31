--[[
Symmetry: mirror drawing across the vertical axis, the horizontal axis, or both.

It works on the span writer. Every stroke, shape, fill and erase already emits
horizontal spans through a `put(x, y, len)` callback; symmetry wraps it so each
span is also written at its mirrored positions. That costs a little arithmetic
per span, behaves the same for every kind of op, and keeps the screen, the
master and the export in step.

A span [x, x+len) reflected about the vertical centre of width W becomes
[W-len-x, W-x), an exact mirror; row y reflects to H-1-y. On screen the axis
goes through the zoom and pan, so it can be a pixel off until the view is
repainted from the master. Each op stores the mode it was drawn with, so a
replay reproduces its mirrors whatever the current setting.
]]

local Symmetry = {}

-- Does this mode mirror across the vertical axis (left and right)?
local function mirrorsX(mode) return mode == "vert" or mode == "quad" end
-- Does this mode mirror across the horizontal axis (top and bottom)?
local function mirrorsY(mode) return mode == "horiz" or mode == "quad" end

Symmetry.mirrorsX = mirrorsX
Symmetry.mirrorsY = mirrorsY

-- Exact pixel reflectors for canvas and export space (width W, height H).
function Symmetry.canvasRefs(W, H)
    return function(x, len) return W - len - x end,
           function(y) return H - 1 - y end
end

-- Reflectors for the on-screen area buffer, with the canvas centre lines mapped
-- through the zoom and pan; within a pixel, made exact by the repaint from the
-- master.
function Symmetry.areaRefs(view)
    local kx = (view.canvas_w - 2 * view.pan_x) * view.zoom
    local ky = (view.canvas_h - 2 * view.pan_y) * view.zoom
    return function(x, len) return kx - x - len end,
           function(y) return ky - y end
end

-- Wrap a span writer so it also emits the mirrored spans for `mode`.
-- `refx(x, len)` gives a span's reflected start across the vertical axis and
-- `refy(y)` the reflected row. Mirrored spans go to `mirror` when given, else to
-- `put`. With the mode off, `put` is returned unchanged.
function Symmetry.wrap(put, mode, refx, refy, mirror)
    if not mode or mode == "off" then return put end
    mirror = mirror or put
    local mx, my = mirrorsX(mode), mirrorsY(mode)
    if mx and my then
        return function(x, y, len)
            put(x, y, len)
            mirror(refx(x, len), y, len)
            mirror(x, refy(y), len)
            mirror(refx(x, len), refy(y), len)
        end
    elseif mx then
        return function(x, y, len)
            put(x, y, len)
            mirror(refx(x, len), y, len)
        end
    else
        return function(x, y, len)
            put(x, y, len)
            mirror(x, refy(y), len)
        end
    end
end

-- The copies a mode draws, as flip codes: 0 the original, 1 mirrored across the
-- vertical axis, 2 across the horizontal one, 3 both.
local FLIPS = { off = { 0 }, vert = { 0, 1 }, horiz = { 0, 2 }, quad = { 0, 1, 2, 3 } }
function Symmetry.flips(mode) return FLIPS[mode or "off"] or FLIPS.off end

-- A flat point list as it lands in copy `f` on a W x H page (a new list; the
-- same one for f = 0). Column x mirrors to W - 1 - x, as canvasRefs does.
function Symmetry.flipPoints(pts, f, W, H)
    if f == 0 then return pts end
    local out = {}
    for i = 1, #pts - 1, 2 do
        out[i] = (f % 2 == 1) and (W - 1 - pts[i]) or pts[i]
        out[i + 1] = (f >= 2) and (H - 1 - pts[i + 1]) or pts[i + 1]
    end
    return out
end

local function setRect(out, n, x0, y0, x1, y1)
    local r = out[n]
    if not r then r = {}; out[n] = r end
    r.x0, r.y0, r.x1, r.y1 = x0, y0, x1, y1
end

-- The rect r ({x0, y0, x1, y1}) and its mirror images under `mode`, reflected
-- across x = kx / 2 and y = ky / 2 (on the canvas, kx and ky are its size). They
-- are written into `out`, reused when given so a per-point caller allocates
-- nothing; returns out and the count.
function Symmetry.mirrorRects(r, mode, kx, ky, out)
    out = out or {}
    local x0, y0, x1, y1 = r.x0, r.y0, r.x1, r.y1
    setRect(out, 1, x0, y0, x1, y1)
    local n = 1
    local mx, my = mirrorsX(mode), mirrorsY(mode)
    if mx then n = n + 1; setRect(out, n, kx - x1, y0, kx - x0, y1) end
    if my then n = n + 1; setRect(out, n, x0, ky - y1, x1, ky - y0) end
    if mx and my then n = n + 1; setRect(out, n, kx - x1, ky - y1, kx - x0, ky - y0) end
    return out, n
end

return Symmetry
