--[[
The accent: the colour of everything that is black by default to stand out
(Done and Close, filled action buttons, the selected tile, the active tool, the
switches and slider fills). On a colour screen it can be a colour the reader
chose in the settings; otherwise it is black.

It is worked out once, when Ink Away opens or the setting changes: the fill,
whether text on it should be black or white (whichever contrasts more), and a
softer shade for notes. KOReader fills a rounded colour shape slowly in Lua (and
wrongly on some older builds), so colour shapes and icons are drawn once into
images with clear corners and reused until Ink Away closes.
]]

local Blitbuffer = require("ffi/blitbuffer")

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local NOTE = Blitbuffer.ColorRGB32(0xC8, 0xC8, 0xC8, 0xFF)   -- a note on black

local Accent = {}

local state
local images = {}   -- key -> BlitBuffer, freed by Accent.free

-- sRGB channel (0..255) to linear light.
local function linear(c)
    c = c / 255
    return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
end

-- Relative luminance of {r,g,b}, 0 (black) to 1 (white).
function Accent.luminance(rgb)
    return 0.2126 * linear(rgb[1]) + 0.7152 * linear(rgb[2]) + 0.0722 * linear(rgb[3])
end

-- Does black text read better than white on {r,g,b}?
function Accent.darkText(rgb)
    local l = Accent.luminance(rgb)
    return (l + 0.05) / 0.05 > 1.05 / (l + 0.05)
end

-- Ink Away's own green: the theme on a colour screen until the reader picks
-- another, always first in the row and never removed.
Accent.SIGNATURE = { 0x9F, 0xD6, 0x65 }

-- Ready-made theme colours, deep enough for white text to read on them on a
-- colour e-ink screen: blue, teal, red, purple, orange.
Accent.PRESETS = {
    { 0x24, 0x57, 0xD6 }, { 0x0F, 0x80, 0x76 }, { 0xC6, 0x28, 0x28 }, { 0x7B, 0x3F, 0xB0 }, { 0xD0, 0x60, 0x00 },
}

-- Are two {r,g,b} the same colour?
function Accent.same(a, b)
    return a ~= nil and b ~= nil and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- Is {r,g,b} black, Ink Away green or one of the presets (already in the row)?
function Accent.builtin(rgb)
    if rgb[1] == 0 and rgb[2] == 0 and rgb[3] == 0 then return true end
    if Accent.same(Accent.SIGNATURE, rgb) then return true end
    for _, p in ipairs(Accent.PRESETS) do if Accent.same(p, rgb) then return true end end
    return false
end

-- The colours last picked on the wheel, newest first and at most `max`: `list`
-- with `rgb` added at the front (moved there if it is already in it), leaving
-- out black, Ink Away green and the presets, which the row always shows (also
-- when kept before they were built in). Returns a new list.
function Accent.remember(list, rgb, max)
    local out = {}
    if rgb and not Accent.builtin(rgb) then out[1] = { rgb[1], rgb[2], rgb[3] } end
    for _, c in ipairs(list or {}) do
        if #out >= (max or 2) then break end
        if type(c) == "table" and not Accent.same(c, rgb) and not Accent.builtin(c) then
            out[#out + 1] = { c[1], c[2], c[3] }
        end
    end
    return out
end

-- Is {r,g,b} a usable colour value?
local function valid(rgb)
    if type(rgb) ~= "table" then return false end
    for i = 1, 3 do
        local c = rgb[i]
        if type(c) ~= "number" or c < 0 or c > 255 then return false end
    end
    return true
end

-- Use colour {r,g,b} as the accent, or black when nil. Drops the images drawn
-- in the previous one.
function Accent.set(rgb)
    Accent.free()
    if not valid(rgb) or (rgb[1] == 0 and rgb[2] == 0 and rgb[3] == 0) then
        state = { fill = BLACK, text = WHITE, note = NOTE, custom = false, chromatic = false, key = "black" }
        return
    end
    local r, g, b = math.floor(rgb[1]), math.floor(rgb[2]), math.floor(rgb[3])
    local grey = (r == g and g == b)
    local dark = Accent.darkText({ r, g, b })
    local t = dark and 0 or 255
    -- a note is the text colour taken a third of the way towards the fill
    local function mix(c) return math.floor(t + (c - t) / 3 + 0.5) end
    state = {
        rgb = { r, g, b },
        fill = grey and Blitbuffer.Color8(r) or Blitbuffer.ColorRGB32(r, g, b, 0xFF),
        text = dark and BLACK or WHITE,
        note = Blitbuffer.ColorRGB32(mix(r), mix(g), mix(b), 0xFF),
        dark_text = dark,
        custom = true,
        chromatic = not grey,
        key = r .. "," .. g .. "," .. b,
    }
end

-- Use the theme saved in the settings (nil when none was ever chosen): on a
-- colour screen that colour, or Ink Away green; on a grey screen always black.
function Accent.apply(saved, colour_screen)
    Accent.set(colour_screen and (saved or Accent.SIGNATURE) or nil)
end

-- The accent in use: { fill, text, note, custom, chromatic, rgb, key }.
function Accent.get()
    if not state then Accent.set(nil) end
    return state
end

-- The accent's rounded shape, w x h with corner radius r, as an image with
-- clear corners (drawn once). Only for a colour accent.
function Accent.shape(w, h, r)
    local a = Accent.get()
    local key = table.concat({ "shape", a.key, w, h, r }, "|")
    local bb = images[key]
    if bb then return bb end
    bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)   -- starts fully clear
    bb:paintRoundedRectRGB32(0, 0, w, h, Blitbuffer.ColorRGB32(a.rgb[1], a.rgb[2], a.rgb[3], 0xFF), r)
    images[key] = bb
    return bb
end

-- Fill a rounded rectangle on bb with the accent.
function Accent.paintRounded(bb, x, y, w, h, r)
    local a = Accent.get()
    if not a.chromatic then
        bb:paintRoundedRect(x, y, w, h, a.fill, r)
        return
    end
    bb:alphablitFrom(Accent.shape(w, h, r), x, y, 0, 0, w, h)
end

-- Fill a bar (a slider's fill) with the accent: a rounded left end, square on
-- the right, where the knob covers it. Any width is quick, so a slider can be
-- dragged without a new image per step.
function Accent.paintBar(bb, x, y, w, h)
    local a = Accent.get()
    local r = math.floor(h / 2)
    if not a.chromatic then
        bb:paintRoundedRect(x, y, w, h, a.fill, r)
        return
    end
    local cap = math.min(w, h)
    bb:alphablitFrom(Accent.shape(h, h, r), x, y, 0, 0, cap, h)
    if w > r then
        local rest_x = x + r
        if bb.paintRectRGB32 then
            bb:paintRectRGB32(rest_x, y, w - r, h, a.fill)
        else
            bb:paintRect(rest_x, y, w - r, h, a.fill)
        end
    end
end

-- The icon in the SVG `file` at size x size: its lines in the text colour on a
-- square of the accent, to sit on an accent button (drawn once). Nil when the
-- accent is black or the icon cannot be drawn; callers then use the plain one.
function Accent.icon(file, size)
    local a = Accent.get()
    if not a.custom then return nil end
    local key = table.concat({ "icon", a.key, file, size }, "|")
    if images[key] ~= nil then return images[key] or nil end
    local ok, bb = pcall(function()
        local RenderImage = require("ui/renderimage")
        local raw, straight = RenderImage:renderSVGImageFile(file, size, size)
        if not raw then return nil end
        local w, h = raw:getWidth(), raw:getHeight()
        -- the icon flattened on white, then inverted: its lines become the mask
        local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        mask:fill(WHITE)
        if straight then mask:alphablitFrom(raw, 0, 0, 0, 0, w, h)
        else mask:pmulalphablitFrom(raw, 0, 0, 0, 0, w, h) end
        raw:free()
        mask:invert()
        local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        local fill = Blitbuffer.ColorRGB32(a.rgb[1], a.rgb[2], a.rgb[3], 0xFF)
        if out.paintRectRGB32 then out:paintRectRGB32(0, 0, w, h, fill) else out:paintRect(0, 0, w, h, fill) end
        local ink = a.dark_text and Blitbuffer.ColorRGB32(0, 0, 0, 0xFF) or Blitbuffer.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF)
        out:colorblitFromRGB32(mask, 0, 0, 0, 0, w, h, ink)
        mask:free()
        return out
    end)
    images[key] = (ok and bb) or false
    return images[key] or nil
end

-- Free the images drawn in the accent (when Ink Away closes).
function Accent.free()
    for k, bb in pairs(images) do
        if bb and bb.free then bb:free() end
        images[k] = nil
    end
end

return Accent
