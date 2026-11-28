--[[
A pen drawn as a short sample stroke, through the same code that draws it on the
page (ink/pens.lua, ink/wash.lua, ink/smudge.lua): the pen case's tiles and its
true-size preview. A pen that changes width with pressure is drawn pressed
lightly, then firmly, then lightly; the smudge is shown dragging three bars of
colour.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Paint = require("ink/paint")
local Pens = require("ink/pens")
local Raster = require("ink/raster")
local Smudge = require("ink/smudge")
local Wash = require("ink/wash")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE

local PenSample = {}

-- An S-curve across w x h, inset by `pad`, as a flat point list.
local function wave(w, h, pad, n)
    local pts = {}
    local amp = math.max(0, h / 2 - pad) * 0.6
    for i = 0, n do
        local u = i / n
        pts[#pts + 1] = pad + u * (w - 2 * pad)
        pts[#pts + 1] = h / 2 + math.sin(u * math.pi * 2) * amp
    end
    return pts
end

-- A new w x h bitmap with `pen` drawn on white at `width` px (its own width
-- times the zoom for a true-size sample). `colour` says whether the screen
-- shows colour (the smudge's sample colours), by default whether its buffer
-- holds colour.
function PenSample.render(pen, w, h, width, colour)
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(WHITE)
    width = math.max(1, width or pen.width or 4)
    local pad = math.ceil(width / 2) + 4
    local n = 40
    local op = { kind = "ink", style = pen.style, width = width, alpha = pen.alpha or 255,
                 color = pen.color, seed = 12345, nib = pen.nib, pts = wave(w, h, math.min(pad, w / 3), n) }
    if Pens.usesPressure(pen.style) then
        op.pr = {}
        for i = 0, n do op.pr[i + 1] = math.floor(70 + 185 * math.sin(i / n * math.pi)) end
    end
    if pen.style == "smudge" then
        -- three bars of colour, dragged across by the smudge
        if colour == nil then colour = Screen.bb:getType() == Blitbuffer.TYPE_BBRGB32 end
        local colours = colour
            and { { 220, 30, 40 }, { 245, 200, 30 }, { 30, 80, 220 } }
            or { { 40, 40, 40 }, { 140, 140, 140 }, { 80, 80, 80 } }
        local bw = math.max(4, math.floor(w / 10))
        local base = Blitbuffer.new(w, h, bb:getType())
        base:fill(WHITE)
        for i, c in ipairs(colours) do
            local x = math.floor(w * (0.25 + (i - 1) * 0.17))
            Paint.fillRect(bb, x, 2, bw, h - 4, Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF),
                Paint.isChromatic(Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF)))
        end
        op.kind = "smudge"
        local s, b = Smudge.surfaceOf(bb), Smudge.surfaceOf(base)
        if s and b then Smudge.apply(s, b, op, w, h) end
        base:free()
        return bb
    end
    local wash, st = Wash.isWash(op)
    if wash then
        local m = Wash.buildMask(op, st, w, h)
        if m then Wash.blendBB(bb, m, op, st) end
        return bb
    end
    if not Raster.STYLES[pen.style] then op.style = "solid" end
    Pens.paint(op, Paint.spanWriter(bb, w, h, Paint.displayColor(pen.color, pen.alpha or 255)))
    return bb
end

return PenSample
