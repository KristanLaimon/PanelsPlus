--[[
Blitbuffer painting helpers shared by the screen code: the UI greys, colour
conversion, and span writers that paint, or restore a background, along runs.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Raster = require("ink/raster")
local Template = require("ink/template")

local WHITE = Blitbuffer.COLOR_WHITE

local Paint = {}

-- The UI greys. They are Color8 because KOReader draws a rounded corner in C only
-- for a Color8 and walks it pixel by pixel in Lua for an RGB32 colour, about 20x
-- slower on grey screens and 200x on colour ones.
local HAIRLINE  = Blitbuffer.Color8(0xCC)
local TILE_BG   = Blitbuffer.Color8(0xE6)   -- shape-menu tile fill
local CARET_BG  = Blitbuffer.Color8(0xB0)   -- line-tile corner caret chip
local TRACK_BG  = Blitbuffer.Color8(0xCF)   -- slider and switch track
local KNOB_EDGE = Blitbuffer.Color8(0x99)   -- slider and switch knob rim

-- Map a grid or ruling strength (1..100) to a grey level: faint at low values,
-- solid black at 100.
local function strengthToLevel(s)
    local lvl = math.floor(255 - (s or 45) / 100 * 255 + 0.5)
    if lvl < 0 then lvl = 0 elseif lvl > 255 then lvl = 255 end
    return lvl
end

-- How light {r,g,b} looks, 0 to 255.
local function lum(rgb)
    return 0.299 * rgb[1] + 0.587 * rgb[2] + 0.114 * rgb[3]
end

-- Is paper {r,g,b} dark (nil or false is white)? Black ink, text and the marks
-- drawn over the page are white on it.
local function darkPaper(rgb)
    return type(rgb) == "table" and lum(rgb) < 110
end

-- The colour ink {r,g,b} (nil is black) shows in on paper {r,g,b}: itself,
-- but black shows white on a dark paper, as text does, so what was written in
-- black reads on any paper (and turns black again on a light one).
local WHITE3 = { 255, 255, 255 }
local function inkOnPaper(rgb, paper)
    if darkPaper(paper) and (rgb == nil or (rgb[1] == 0 and rgb[2] == 0 and rgb[3] == 0)) then return WHITE3 end
    return rgb
end

-- The colour of a ruling or grid of strength 1..100 on paper {r,g,b} (nil is
-- white), as {r,g,b}: the paper taken toward black, or on a dark paper toward
-- white, by as much as the strength's grey is from white. On white that is the
-- grey itself, and the lines stand out as much on any paper.
local function rulingRGB(paper, strength)
    local lvl = strengthToLevel(strength)
    local p = paper or { 255, 255, 255 }
    local out = {}
    if darkPaper(p) then
        local k = (255 - lvl) / 255
        for i = 1, 3 do out[i] = math.floor(p[i] + (255 - p[i]) * k + 0.5) end
    else
        for i = 1, 3 do out[i] = math.floor(p[i] * lvl / 255 + 0.5) end
    end
    return out
end

-- The colour of text and of the marks over the page (the lasso, a selection's
-- frame) on paper {r,g,b}: black, or white on a dark paper.
local function inkOn(paper)
    return darkPaper(paper) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
end

-- The on-screen colour of ink {r,g,b} (black by default) at opacity `alpha`,
-- composited over white so the display matches the export. A grey panel's
-- blitter turns it into the right shade; a colour screen shows the colour.
local function displayColor(rgb, alpha)
    local a = alpha or 255
    local r = rgb and rgb[1] or 0
    local g = rgb and rgb[2] or 0
    local b = rgb and rgb[3] or 0
    local function over(c) return math.floor(255 - a * (255 - c) / 255 + 0.5) end
    return Blitbuffer.ColorRGB32(over(r), over(g), over(b), 0xFF)
end

-- A swatch or tile fill for {r,g,b}. A grey becomes a Color8, so its rounded
-- corners are drawn in C; a real colour has to stay RGB32 to keep its hue.
local function uiFill(rgb)
    local r, g, b = rgb[1], rgb[2], rgb[3]
    if r == g and g == b then return Blitbuffer.Color8(r) end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

-- An ink colour {r,g,b} drawn so that KOReader's night mode, which inverts the
-- whole screen, shows it in its own hue (#11): its hue turned half way round,
-- its lightness and saturation kept. The inverted screen then shows the same
-- hue with the lightness inverted, so dark blue ink is a light blue on the
-- dark page and a yellow highlight a deep one under the light text. A grey
-- (black, white) is left as it is and inverts as before.
local function nightInk(rgb)
    if not rgb then return rgb end
    local r, g, b = rgb[1] or 0, rgb[2] or 0, rgb[3] or 0
    local hi, lo = math.max(r, g, b), math.min(r, g, b)
    if hi == lo then return rgb end
    local s = hi + lo
    return { s - r, s - g, s - b }
end

-- Is this a real colour (not black, white or grey)?
local function isChromatic(color)
    if not (color and color.getColorRGB32) then return false end
    local c = color:getColorRGB32()
    return (c.r ~= c.g) or (c.g ~= c.b)
end

-- Fill a rectangle with `color`, keeping it a colour on a colour buffer.
-- KOReader's paintRect flattens any colour to grey (it takes getColor8() first),
-- so this uses paintRectRGB32, its C colour fill, or setPixel on builds without it.
local function fillRect(bb, x, y, w, h, color, chromatic)
    if not chromatic then
        bb:paintRect(x, y, w, h, color)
    elseif bb.paintRectRGB32 then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        for j = y, y + h - 1 do
            for i = x, x + w - 1 do bb:setPixel(i, j, color) end
        end
    end
end

-- A span writer that paints horizontal runs into `bb`, clipped to w x h, and
-- optionally grows `acc` over everything it touched. The master and the on-screen
-- buffer both use it, so they are stamped alike. Black and grey ink use
-- paintRect; a colour uses the C colour fill.
local function spanWriter(bb, w, h, color, acc)
    local chromatic = isChromatic(color)
    return function(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        fillRect(bb, x, y, len, 1, color, chromatic)
        if acc then
            if x < acc.x0 then acc.x0 = x end
            if x + len > acc.x1 then acc.x1 = x + len end
            if y < acc.y0 then acc.y0 = y end
            if y + 1 > acc.y1 then acc.y1 = y + 1 end
        end
    end
end

-- A span writer that copies the runs from a background buffer instead of
-- painting a colour: an eraser that reveals what lies under the ink. Optionally
-- grows `acc` like spanWriter.
local function bgSpanWriter(bb, bg, w, h, acc)
    return function(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        bb:blitFrom(bg, x, y, x, y, len, 1)
        if acc then
            if x < acc.x0 then acc.x0 = x end
            if x + len > acc.x1 then acc.x1 = x + len end
            if y < acc.y0 then acc.y0 = y end
            if y + 1 > acc.y1 then acc.y1 = y + 1 end
        end
    end
end

-- A rectangle outline `t` pixels thick (1 by default), inside x, y, w, h.
local function outline(bb, x, y, w, h, color, t)
    t = t or 1
    bb:paintRect(x, y, w, t, color)
    bb:paintRect(x, y + h - t, w, t, color)
    bb:paintRect(x, y, t, h, color)
    bb:paintRect(x + w - t, y, t, h, color)
end

-- Draw a sample stroke of brush style `st` across bb: one sine wave of `n`
-- segments with amplitude `amp` (a fraction of the height), inset `pad`, radius
-- `r`, in `ink`. The pen menu's brush tiles and the brush maker show these.
local function brushSample(bb, st, ink, pad, r, amp, n)
    local w, h = bb:getWidth(), bb:getHeight()
    local function put(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len > 0 then bb:paintRect(x, y, len, 1, ink) end
    end
    local pts = {}
    for i = 0, n do
        local u = i / n
        pts[#pts + 1] = pad + u * (w - pad * 2)
        pts[#pts + 1] = h / 2 + math.sin(u * math.pi * 2) * (h * amp)
    end
    if st.solid then Raster.path(pts, r, put) else Raster.pathTex(pts, r, put, st, 12345) end
end

-- Paint a notebook page's paper into `dst`: the picture or PDF page if there is
-- one (else the paper colour, tmpl.paper, white when nil), then the ruling on top.
local function paintPaper(dst, W, H, tmpl, bg)
    if bg then
        dst:blitFrom(bg, 0, 0, 0, 0, W, H)
    else
        local paper = tmpl and tmpl.paper
        local col = paper and Blitbuffer.ColorRGB32(paper[1], paper[2], paper[3], 0xFF) or WHITE
        fillRect(dst, 0, 0, W, H, col, isChromatic(col))
    end
    if tmpl and tmpl.style and tmpl.style ~= "blank" then
        -- the ruling in the paper's own shade (over a PDF page, grey as on white)
        local c = rulingRGB(not bg and tmpl.paper or nil, tmpl.strength)
        local put = spanWriter(dst, W, H, Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF), nil)
        Template.render(tmpl.style, W, H, tmpl.size or 40, put)
    end
end

Paint.HAIRLINE = HAIRLINE
Paint.TILE_BG = TILE_BG
Paint.CARET_BG = CARET_BG
Paint.TRACK_BG = TRACK_BG
Paint.KNOB_EDGE = KNOB_EDGE
Paint.strengthToLevel = strengthToLevel
Paint.displayColor = displayColor
Paint.uiFill = uiFill
Paint.isChromatic = isChromatic
Paint.nightInk = nightInk
Paint.fillRect = fillRect
Paint.outline = outline
Paint.brushSample = brushSample
Paint.spanWriter = spanWriter
Paint.bgSpanWriter = bgSpanWriter
Paint.paintPaper = paintPaper
Paint.lum = lum
Paint.darkPaper = darkPaper
Paint.rulingRGB = rulingRGB
Paint.inkOn = inkOn
Paint.inkOnPaper = inkOnPaper

return Paint
