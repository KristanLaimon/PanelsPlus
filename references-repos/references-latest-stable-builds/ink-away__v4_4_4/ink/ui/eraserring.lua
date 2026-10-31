--[[
The eraser's footprint: the round area it clears, drawn as a ring whose outer
edge is exactly that edge, black with a white line inside so it shows on paper
and on ink alike. Drawn by the Eraser sheet's preview and under the pen while
erasing (see ink/view/erasecursor.lua). Plain rows of pixels, so it is quick
enough for every point of a stroke.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE

local EraserRing = {}

-- How thick the black line is, in screen pixels.
function EraserRing.line()
    return math.max(2, math.floor(Screen:scaleBySize(1.5) + 0.5))
end

-- Paint, row by row, the part of the disc at (cx, cy) between radii `inner` and
-- `outer` in `color` (the whole disc with no inner).
local function band(bb, cx, cy, outer, inner, color)
    if outer <= 0 then return end
    local y0, y1 = math.floor(cy - outer), math.ceil(cy + outer)
    for y = y0, y1 - 1 do
        local dy = y + 0.5 - cy
        local o2 = outer * outer - dy * dy
        if o2 > 0 then
            local xo = math.sqrt(o2)
            local l0, r1 = math.floor(cx - xo + 0.5), math.floor(cx + xo + 0.5)
            local i2 = inner and (inner * inner - dy * dy) or -1
            if i2 > 0 then
                local xi = math.sqrt(i2)
                local l1, r0 = math.floor(cx - xi + 0.5), math.floor(cx + xi + 0.5)
                if l1 > l0 then bb:paintRect(l0, y, l1 - l0, 1, color) end
                if r1 > r0 then bb:paintRect(r0, y, r1 - r0, 1, color) end
            elseif r1 > l0 then
                bb:paintRect(l0, y, r1 - l0, 1, color)
            end
        end
    end
end

-- Draw the footprint of an eraser `r` screen pixels in radius at (cx, cy) on
-- `bb`; with `clear` the inside is white first, as erased.
function EraserRing.paint(bb, cx, cy, r, clear)
    local line = EraserRing.line()
    if clear then band(bb, cx, cy, r, nil, WHITE) end
    band(bb, cx, cy, r, r - line, BLACK)
    band(bb, cx, cy, r - line, r - line - 1, WHITE)
end

-- The screen box the footprint covers: x, y, w, h.
function EraserRing.box(cx, cy, r)
    local x0, y0 = math.floor(cx - r) - 1, math.floor(cy - r) - 1
    return x0, y0, math.ceil(cx + r) + 1 - x0, math.ceil(cy + r) + 1 - y0
end

return EraserRing
