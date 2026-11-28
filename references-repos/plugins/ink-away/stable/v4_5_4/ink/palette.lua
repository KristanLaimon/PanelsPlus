--[[
The colour swatches: grey shades, the colours offered on colour screens and the
paper colours.
]]

local _ = require("ink/l10n")

local Palette = {}

-- Grey shades, the primary choice on e-ink. Ordered dark to light.
local SHADES = {
    { name = _("Black"),      rgb = { 0x00, 0x00, 0x00 } },
    { name = _("Dark grey"),  rgb = { 0x44, 0x44, 0x44 } },
    { name = _("Grey"),       rgb = { 0x88, 0x88, 0x88 } },
    { name = _("Light grey"), rgb = { 0xBB, 0xBB, 0xBB } },
    { name = _("White"),      rgb = { 0xFF, 0xFF, 0xFF } },
}

-- Colours, offered only on colour screens (colour e-ink, Android, desktop).
local COLORS = {
    { name = _("Red"),    rgb = { 0xD0, 0x00, 0x00 } },
    { name = _("Orange"), rgb = { 0xE0, 0x70, 0x00 } },
    { name = _("Yellow"), rgb = { 0xE8, 0xC0, 0x00 } },
    { name = _("Green"),  rgb = { 0x00, 0x90, 0x00 } },
    { name = _("Blue"),   rgb = { 0x00, 0x50, 0xD0 } },
    { name = _("Purple"), rgb = { 0x80, 0x00, 0xB0 } },
}

-- Highlights for text, offered on colour screens: the first is the default (and
-- what a highlight made before there were colours shows in). Light enough that
-- black letters read on each.
local HIGHLIGHTS = {
    { name = _("Yellow"), rgb = { 0xFF, 0xEB, 0x3B } },
    { name = _("Orange"), rgb = { 0xFF, 0xA7, 0x26 } },
    { name = _("Blue"),   rgb = { 0x64, 0xB5, 0xF6 } },
    { name = _("Green"),  rgb = { 0x81, 0xD4, 0x62 } },
    { name = _("Pink"),   rgb = { 0xF4, 0x8F, 0xB1 } },
}

-- Paper colours: the page under the ink, chosen in Settings beside the paper
-- (or the grid). A grey screen offers white and black (GREY_PAPERS); a colour
-- one all of them. Light to dark; the dark ones take white ink and text.
local PAPERS = {
    { key = "white",     name = _("White"),      rgb = { 255, 255, 255 } },
    { key = "cream",     name = _("Cream"),      rgb = { 250, 244, 226 } },
    { key = "sand",      name = _("Sandpaper"),  rgb = { 240, 230, 200 } },
    { key = "legal",     name = _("Legal pad"),  rgb = { 252, 240, 160 } },
    { key = "mint",      name = _("Mint"),       rgb = { 214, 240, 220 } },
    { key = "sky",       name = _("Sky"),        rgb = { 212, 230, 248 } },
    { key = "blush",     name = _("Blush"),      rgb = { 248, 220, 226 } },
    { key = "lavender",  name = _("Lavender"),   rgb = { 228, 220, 248 } },
    { key = "kraft",     name = _("Kraft"),      rgb = { 205, 170, 125 } },
    { key = "blueprint", name = _("Blueprint"),  rgb = { 28, 62, 120 } },
    { key = "chalk",     name = _("Chalkboard"), rgb = { 40, 68, 54 } },
    { key = "black",     name = _("Black"),      rgb = { 0, 0, 0 } },
}
local GREY_PAPERS = { white = true, black = true }

-- Is the pen currently set to this rgb?
local function sameColor(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

Palette.SHADES = SHADES
Palette.COLORS = COLORS
Palette.HIGHLIGHTS = HIGHLIGHTS
Palette.PAPERS = PAPERS
Palette.sameColor = sameColor

-- The papers this screen offers: all of them in colour, else white and black.
function Palette.papers(colour)
    if colour then return PAPERS end
    local out = {}
    for _i, p in ipairs(PAPERS) do if GREY_PAPERS[p.key] then out[#out + 1] = p end end
    return out
end

-- A document's paper colour as it is kept: {r,g,b}, or nil for white (and for
-- anything that is not a colour).
function Palette.paperRGB(v)
    if type(v) ~= "table" then return nil end
    local r, g, b = tonumber(v[1]), tonumber(v[2]), tonumber(v[3])
    if not (r and g and b) then return nil end
    r, g, b = math.floor(r), math.floor(g), math.floor(b)
    if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255 then return nil end
    if r == 255 and g == 255 and b == 255 then return nil end
    return { r, g, b }
end

-- The name of paper colour `rgb` (nil is white), or "Custom" for one not in
-- the list.
function Palette.paperName(rgb)
    rgb = Palette.paperRGB(rgb) or { 255, 255, 255 }
    for _i, p in ipairs(PAPERS) do if sameColor(p.rgb, rgb) then return p.name end end
    return _("Custom")
end

return Palette
