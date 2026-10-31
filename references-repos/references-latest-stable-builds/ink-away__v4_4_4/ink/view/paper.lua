--[[
The paper colour: the page under the ink, white unless another is picked in
Settings, beside the paper (a notebook) or the grid (a drawing). Each document
keeps its own (a notebook in its template, a drawing in its file), and a new
one starts on the last picked. A grey screen offers white and black, a colour
one twelve papers (ink/palette.lua).

The ruling and the grid are drawn in the paper's own shade (Paint.rulingRGB),
so they show on any paper, and on a dark paper black ink, the text and the
marks over the page (the lasso, a selection's frame) show white, so what was
written in black reads on any paper.
A drawing on a coloured paper gets a paper buffer, as a notebook has, so the
eraser and the smudge reveal the paper, not white. Exports lay the page on the
same paper (view/export.lua). Dark mode never touches it.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Theme = require("ink/ui/theme")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE_RGB = { 255, 255, 255 }

local function S(px) return Screen:scaleBySize(px) end

-- An image as a button's label (fgcolor is set for the tap highlight, which
-- inverts a text button's label).
local function imageLabel(bb, w, h)
    return ImageWidget:new{ image = bb, width = w, height = h, image_disposable = false, fgcolor = BLACK }
end

local InkAwayView = {}

-- The open document's paper colour, {r,g,b}, or nil for white. Over a book
-- there is no paper: the page is the book's.
function InkAwayView:paperRGB()
    if self.reader_mode then return nil end
    if self.notebook then return Palette.paperRGB(self.notebook.template and self.notebook.template.paper) end
    return Palette.paperRGB(self.paper)
end

-- The paper a new document starts on: the last one picked (nil for white).
function InkAwayView:defaultPaper()
    return Palette.paperRGB(self:getSetting("inkaway_paper"))
end

-- The colour of text and of the marks over the page: black, white on a dark paper.
function InkAwayView:textInk()
    return Paint.inkOn(self:paperRGB())
end

-- A drawing's paper as a canvas-sized buffer: the base its ink is composed on
-- and what the eraser and the smudge reveal, as a notebook's paper is. nil on
-- white paper (and in a notebook, which has its own), which needs none.
function InkAwayView:plainPaperBB()
    local p = not self.notebook and self:paperRGB()
    if not (p and self.canvas_bb) then
        self:freePlainPaper()
        return nil
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local key = table.concat({ p[1], p[2], p[3], W, H, self.canvas_bb:getType() }, ",")
    if self._plain_paper_bb and self._plain_paper_key ~= key then self:freePlainPaper() end
    if not self._plain_paper_bb then
        local bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
        Paint.paintPaper(bb, W, H, { style = "blank", paper = p }, nil)
        self._plain_paper_bb, self._plain_paper_key = bb, key
    end
    return self._plain_paper_bb
end

function InkAwayView:freePlainPaper()
    if self._plain_paper_bb then self._plain_paper_bb:free() end
    self._plain_paper_bb, self._plain_paper_key = nil, nil
end

-- Put the open document on paper `rgb` (nil or white for white), remember it
-- for the next new document, and draw the page again (black ink and text show
-- white on a dark paper, see Paint.inkOnPaper).
function InkAwayView:setPaper(rgb)
    rgb = Palette.paperRGB(rgb)
    local before = self:paperRGB()
    self:setSetting("inkaway_paper", rgb or WHITE_RGB)
    if Palette.sameColor(before or WHITE_RGB, rgb or WHITE_RGB) then return end
    if self.notebook then self.notebook.template.paper = rgb else self.paper = rgb end
    self:markDirty()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

-- A small page of paper `rgb`, ruled, w x h, outlined so white shows on white
-- (drawn once).
function InkAwayView:cachedPaperSwatch(rgb, w, h)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local id = table.concat({ "papercol", rgb[1], rgb[2], rgb[3], w, h, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e then return e.bb end
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    Paint.paintPaper(bb, w, h, { style = "lines", size = math.max(6, math.floor(h / 7)), strength = 45,
        paper = Palette.paperRGB(rgb) }, nil)
    Paint.outline(bb, 0, 0, w, h, Paint.HAIRLINE, 1)
    cache[id] = { bb = bb }
    return bb
end

-- A round dot of paper `rgb`, d across, on the grey of a button (drawn once).
function InkAwayView:cachedPaperDot(rgb, d)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local id = table.concat({ "paperdot", rgb[1], rgb[2], rgb[3], d, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e then return e.bb end
    local bb = Blitbuffer.new(d, d, Screen.bb:getType())
    bb:paintRect(0, 0, d, d, Paint.TILE_BG)
    local r = math.floor(d / 2)
    local fill = Paint.uiFill(rgb)
    if Paint.isChromatic(fill) then bb:paintRoundedRectRGB32(0, 0, d, d, fill, r)
    else bb:paintRoundedRect(0, 0, d, d, fill, r) end
    bb:paintBorder(0, 0, d, d, 1, Paint.KNOB_EDGE, r)
    cache[id] = { bb = bb }
    return bb
end

-- The Settings button for the paper colour: a dot of it and `label`, w wide.
function InkAwayView:paperColourButton(label, w, cb)
    local rgb = self:paperRGB() or WHITE_RGB
    local h = S(48)
    local d = S(20)
    local text = TextWidget:new{ text = label, face = Font:getFace("cfont", 17), bold = true, fgcolor = BLACK,
        max_width = w - d - S(24) }
    local row = HorizontalGroup:new{ align = "center", fgcolor = BLACK }
    local ok, dot = pcall(function() return self:cachedPaperDot(rgb, d) end)
    if ok and dot then
        row[#row + 1] = Theme.keep(imageLabel(dot, d, d), math.floor(d / 2))   -- the paper, in dark too
        row[#row + 1] = HorizontalSpan:new{ width = S(8) }
    end
    row[#row + 1] = text
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0, radius = S(14),
        background = Paint.TILE_BG, margin = 0, padding = 0, callback = cb, show_parent = self }
    self:setButtonLabel(b, row)
    return b
end

-- A paper colour tile: a small ruled page of it and its name; the selected one
-- in the theme colour.
function InkAwayView:paperColourTile(entry, w, h, sel, cb)
    local a = Accent.get()
    local ph = h - S(24) - S(16)
    local pw = math.min(w - S(16), math.floor(ph * 0.78))
    local ok, page = pcall(function() return self:cachedPaperSwatch(entry.rgb, pw, ph) end)
    local vg = VerticalGroup:new{ align = "center", fgcolor = sel and a.text or BLACK }
    if ok and page then vg[#vg + 1] = Theme.keep(imageLabel(page, pw, ph)) end   -- the paper itself
    vg[#vg + 1] = VerticalSpan:new{ width = S(4) }
    vg[#vg + 1] = TextWidget:new{ text = entry.name, face = Font:getFace("cfont", 14), bold = true,
        fgcolor = sel and a.text or BLACK, max_width = w - S(6) }
    if sel and a.chromatic then return self:accentButton(w, h, S(14), vg, cb) end
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0, radius = S(14),
        background = sel and a.fill or Paint.TILE_BG, margin = 0, padding = 0, callback = cb, show_parent = self }
    self:setButtonLabel(b, vg)
    return b
end

-- The paper colour sheet: the papers this screen offers, the open document's
-- marked. A tap puts the page on it at once; the sheet stays to try another.
function InkAwayView:openPaperColour()
    self:closeSheet("_settings_dialog")
    self:closeSheet("_paper_colour")
    local list = Palette.papers(self:colorScreen())
    local cols = math.min(4, #list)
    local content_w, gap, col = self:sheetWidth(4)
    if cols < 4 then col = math.floor((content_w - (cols - 1) * gap) / cols) end
    local rows = math.ceil(#list / cols)
    -- tiles a little taller than wide, shorter when the screen has no room
    local fixed = S(34) + S(16) + (rows - 1) * gap + S(12) + S(56) + 2 * S(18) + S(40)
    local room = math.floor((Screen:getHeight() - (self:sheetTopY() or 0) - fixed) / rows)
    local tileH = math.max(S(84), math.min(math.floor(math.min(col, S(130)) * 1.3), room))
    local done = function() self:closeSheet("_paper_colour") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Paper colour"), content_w, _("Done"), done))
        add(VerticalSpan:new{ width = S(16) })
        local cur = self:paperRGB() or WHITE_RGB
        for r = 0, rows - 1 do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 1, cols do
                local e = list[r * cols + c]
                if e then
                    if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                    row[#row + 1] = self:paperColourTile(e, col, tileH, Palette.sameColor(e.rgb, cur), function()
                        self:setPaper(e.rgb)
                        self:rebuildSheet("_paper_colour")
                    end)
                end
            end
            if r > 0 then add(VerticalSpan:new{ width = gap }) end
            add(row)
        end
        add(VerticalSpan:new{ width = S(12) })
        add(self:sheetHint(_("Each document keeps its paper; a new one starts on the last you picked. On a dark paper black ink and text show white. Dark mode never changes the paper."), content_w))
        return content
    end
    self:showSheet("_paper_colour", build)
end

return InkAwayView
