--[[
The pen case: the Pen sheet. From the top: the reader's saved pens, drawn at
their real size and colour (a tap takes one up, a hold moves, copies or removes
it, + makes a new one of a chosen kind); the pen in hand drawn at its real size
on screen, which follows the size slider, with its kind; its size in mm and its
opacity; its colour; and, for pens that change width with pressure, how. The
saved pen in hand is edited directly. Palm rejection, the stabilizer and the
other input settings, which are set once and not per pen, are in "Pen and
input".
What is kept, and how each kind of pen remembers its settings: ink/penset.lua.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Brushes = require("ink/brushes")
local EinkDrive = require("ink/einkdrive")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local PenSample = require("ink/ui/pensample")
local Penset = require("ink/penset")
local Raster = require("ink/raster")
local SliderRow = require("ink/ui/controls").SliderRow
local Strip = require("ink/ui/strip")
local ToggleRow = require("ink/ui/controls").ToggleRow
local Theme = require("ink/ui/theme")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local HAIRLINE = Paint.HAIRLINE
local TILE_BG = Paint.TILE_BG
local LABEL = Blitbuffer.Color8(0x55)
local SHADES = Palette.SHADES
local COLORS = Palette.COLORS
local sameColor = Palette.sameColor

local PEN_CUSTOM_CAP = 12   -- how many made brushes a reader may keep

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

------------------------------------------------------------------------------
-- The pen in hand, and keeping it
------------------------------------------------------------------------------

-- Canvas pixels per mm on this screen.
function InkAwayView:pxPerMM()
    local dpi = Screen.getDPI and Screen:getDPI() or 300
    return (dpi or 300) / 25.4
end

-- The pen case, loaded from the settings the first time it is needed.
function InkAwayView:penset()
    if not self._penset then
        self._penset = Penset.load(function(k) return self:getSetting(k) end,
            { colour = self:colorScreen(), pxmm = self:pxPerMM() },
            function(style) return Raster.STYLES[style] ~= nil end)
    end
    return self._penset
end

-- Take up a pen: the drawing uses its style, width, opacity and colour.
function InkAwayView:applyPen(p)
    self.pen_style = (p.style and Raster.STYLES[p.style]) and p.style or "solid"
    self.pen_width = p.width or self.pen_width
    self.pen_alpha = p.alpha or 255
    self.pen_color = p.color and { p.color[1], p.color[2], p.color[3] } or { 0, 0, 0 }
    self.pen_nib = p.nib
end

-- Keep the pen case after a change, and show the pen in hand's colour on the
-- toolbar.
function InkAwayView:savePens()
    self._pens_rev = (self._pens_rev or 0) + 1
    Penset.save(self:penset(), function(k, v) self:setSetting(k, v) end)
    self:setSetting("inkaway_pen_style", self.pen_style)   -- for 4.0 and older, if ever opened again
    local r = self.toolbar and self.toolbar.dimen
    if r and r.w and not self._toolbar_hidden and not self.closing then
        self._paint_all = true
        UIManager:setDirty(self, "ui", r)
    end
    if not self.closing and not self._pens_hidden then self:refreshFabRegion(self:fabRect("pens")) end
end

-- The pen in hand's colour as a short bar under its toolbar button (x, y, w,
-- h: the button's cell on the screen).
function InkAwayView:paintPenMark(bb, x, y, w, h)
    local isz = self._icon_sz or math.floor(h * 0.6)
    local mw = math.max(6, math.floor(isz * 0.7))
    local mh = math.max(3, Screen:scaleBySize(3))
    local mx = x + math.floor((w - mw) / 2)
    local my = y + math.floor((h + isz) / 2) + math.max(1, Screen:scaleBySize(1))
    if my + mh > y + h - 1 then my = y + h - 1 - mh end
    bb:paintRect(mx, my, mw, mh, Paint.displayColor(self.pen_color, 255))
    self._pen_mark_rect = { x = mx, y = my, w = mw, h = mh }   -- kept in dark
    local c = self.pen_color or { 0, 0, 0 }
    if c[1] + c[2] + c[3] > 600 then   -- a light colour gets an edge, to show on white
        bb:paintBorder(mx, my, mw, mh, 1, HAIRLINE)
    end
end

-- The pen in hand changed one setting (field: width, alpha or color).
function InkAwayView:penChanged(field, value)
    Penset.set(self:penset(), field, value)
    self:savePens()
end

-- Take up saved pen i.
function InkAwayView:selectPen(i)
    local fav = self:penset().favs[i]
    if self.reader_mode and fav and fav.style == "smudge" then return false end   -- (no smudge over a book)
    local p = Penset.select(self:penset(), i)
    if not p then return false end
    self:applyPen(p)
    self:savePens()
    return true
end

-- Make the pen in hand another kind (the saved pen in hand changes with it).
function InkAwayView:setPenKind(style)
    self:applyPen(Penset.setKind(self:penset(), style))
    self:savePens()
end

-- A new saved pen of a kind, taken up.
function InkAwayView:addPen(style)
    local i = Penset.addNew(self:penset(), style)
    if i then self:applyPen(self:penset().cur); self:savePens() end
    return i
end

function InkAwayView:choosePenType(style)
    self:applyPen(Penset.choose(self:penset(), style))
    self:savePens()
end

-- Back to the pen before this one (a gesture or pen button can do this).
function InkAwayView:swapPen()
    local p = Penset.swap(self:penset())
    if not p then return false end
    self:applyPen(p)
    self:savePens()
    if self.tool ~= "pen" then self:setTool("pen") end
    return true
end

------------------------------------------------------------------------------
-- Tiles
------------------------------------------------------------------------------

-- A cached sample of a pen, w x h, drawn at `width` px.
function InkAwayView:cachedPenSample(p, w, h, width)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local c = p.color or { 0, 0, 0 }
    local colour = self:colorScreen()
    local id = table.concat({ "pen", p.style, width, p.alpha or 255, c[1], c[2], c[3], w, h,
        Screen.bb:getType(), tostring(colour) }, "|")
    local e = cache[id]
    if e then return e.bb end
    local ok, bb = pcall(PenSample.render, p, w, h, width, colour)
    if not ok then return nil end
    cache[id] = { bb = bb }
    return bb
end

-- A rounded frame around `inner`: thick and black when selected, as the colour
-- swatches are (a colour border would be drawn grey by KOReader's frame).
local function frame(inner, selected)
    return FrameContainer:new{
        bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
        color = selected and BLACK or HAIRLINE,
        radius = Screen:scaleBySize(12), padding = selected and 0 or Screen:scaleBySize(2),
        margin = 0, background = WHITE, inner }
end

-- A tile showing `bb` (owned by the cache), tappable.
function InkAwayView:imageTile(bb, w, h, cb, hold_cb)
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0, radius = Screen:scaleBySize(10),
        background = WHITE, margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    if bb then
        self:setButtonLabel(b, ImageWidget:new{ image = bb, width = w, height = h,
            image_disposable = false, fgcolor = BLACK })
    end
    return Theme.keep(b, Screen:scaleBySize(10))   -- a pen as it draws, in dark too
end

-- A small label under a tile.
local function caption(text, w)
    local t = TextWidget:new{ text = text, face = Font:getFace("cfont", 13), fgcolor = LABEL, max_width = w }
    return CenterContainer:new{ dimen = GeomUI:new{ w = w, h = t:getSize().h }, t }
end

-- Tiles laid out `per` to a row, `gap` apart.
local function rows(list, per, gap)
    local out = VerticalGroup:new{ align = "left" }
    for i = 1, #list, per do
        local row = HorizontalGroup:new{ align = "top" }
        for j = i, math.min(i + per - 1, #list) do
            if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, list[j])
        end
        if i > 1 then table.insert(out, VerticalSpan:new{ width = gap }) end
        table.insert(out, row)
    end
    return out
end

------------------------------------------------------------------------------
-- The sheet
------------------------------------------------------------------------------

-- The Pen sheet, kept small: your saved pens; the pen in hand drawn at its real
-- size with its name (a tap there chooses another kind of pen); its size and
-- opacity; one row of colours; and the pressure switch for pens that use it.
function InkAwayView:openPenSettings()
    if self:rebuildSheet("_pen_dialog") then return end
    self:ensureUserIcons()
    local content_w, gap = self:sheetWidth()
    local function closeSelf() self:closeSheet("_pen_dialog") end
    local function again() self:openPenSettings() end

    local build = function(menu)
        local case = self:penset()
        local cur = case.cur
        local zoom = (self.view and self.view.zoom) or 1
        local pxmm = self:pxPerMM()
        local smudge = cur.style == "smudge"
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end

        add(self:sheetTitle(_("Pen"), content_w, _("Done"), closeSelf))
        add(vspan(10))

        -- Your pens, at their real size and colour: a tap takes one up, a hold
        -- moves, copies or removes it, + makes a new one
        local per = (content_w >= Screen:scaleBySize(7 * 52)) and 7 or 6
        local fw = math.floor((content_w - (per - 1) * gap) / per)
        local fh = Screen:scaleBySize(34)
        local inner = fw - Screen:scaleBySize(6)
        local favs = {}
        for i, p in ipairs(case.favs) do
          -- the smudge needs the page under the ink, which a book's ink does not
          -- keep, so over a book its saved pens are left out
          if not (self.reader_mode and p.style == "smudge") then
            -- thin enough to read as a stroke: the strip below shows the real size
            local bb = self:cachedPenSample(p, inner, fh, math.min(p.width * zoom, math.floor(fh * 0.4)))
            favs[#favs + 1] = frame(self:imageTile(bb, inner, fh,
                function() self:selectPen(i); again() end,
                function() self:editSavedPen(i) end), case.sel == i)
          end
        end
        -- + is always there, after the last pen; with the case full it says how
        -- to make room rather than vanish
        favs[#favs + 1] = frame(Button:new{ text = "+", text_font_size = 20, text_font_bold = true,
            width = inner, height = fh, bordersize = 0, radius = Screen:scaleBySize(10),
            background = TILE_BG, margin = 0, padding = 0, show_parent = self,
            callback = function()
                if #case.favs >= Penset.FAV_CAP then
                    self:tell(string.format(
                        _("You have %d pens, as many as the menu holds. Hold one and Remove it to make room."), Penset.FAV_CAP))
                    return
                end
                closeSelf(); self:openPenTypes(true)
            end }, false)
        add(rows(favs, per, gap))
        if not case.sel then
            add(vspan(4))
            add(self:sheetHint(_("The pen in hand is not one of your pens: + keeps it as a new one."), content_w))
        end
        add(vspan(12))

        -- the pen in hand, its real size on screen, and its kind: tap to change
        local name_w = math.floor(content_w * 0.34)
        local strip_w = content_w - name_w - gap - 2 * Screen:scaleBySize(3)
        local strip_h = Screen:scaleBySize(46)
        local strip = Strip:new{ w = strip_w, h = strip_h,
            on_tap = function() closeSelf(); self:openPenTypes() end }
        local function preview()
            -- at its real size on screen; a pen too wide for the strip is shown
            -- smaller (with a note), so it never fills it edge to edge
            local real = math.max(1, case.cur.width * zoom)
            local fit = math.max(1, math.floor(strip.h * 0.55))
            local shown = math.min(real, fit)
            strip.note = shown < real and string.format(_("shown at %d%%"), math.floor(shown / real * 100 + 0.5)) or nil
            strip:setImage(PenSample.render(case.cur, strip.w, strip.h, shown, self:colorScreen()))
        end
        preview()
        self._pen_strip = strip
        local label = Penset.display(cur, _)
        add(HorizontalGroup:new{ align = "center",
            FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = HAIRLINE, radius = Screen:scaleBySize(10),
                padding = Screen:scaleBySize(2), margin = 0, background = WHITE, strip },
            HorizontalSpan:new{ width = gap },
            self:actionButton(label .. "  \u{203A}", name_w, function() closeSelf(); self:openPenTypes() end) })
        local function showPreview()
            preview()
            if strip.dimen then UIManager:setDirty(menu, "fast", strip.dimen) end
        end

        add(vspan(10))
        add(SliderRow:new{ label = _("Size"), value = cur.width, min = 1, max = Penset.maxWidth(cur.style),
            width = content_w, parent = menu, format = function(v) return Penset.mmText(v, pxmm) end,
            on_set = function(v)
                v = math.max(1, v)
                self.pen_width = v; self:penChanged("width", v); showPreview()
            end })
        add(vspan(6))
        add(SliderRow:new{ label = smudge and _("Strength") or _("Opacity"),
            value = math.floor((cur.alpha or 255) / 255 * 100 + 0.5),
            width = content_w, parent = menu,
            on_set = function(v)
                local a = math.max(1, math.floor(v / 100 * 255 + 0.5))
                self.pen_alpha = a; self:penChanged("alpha", a); showPreview()
            end })

        -- a calligraphy nib's angle
        if cur.style == "calligraphy" then
            add(vspan(6))
            add(SliderRow:new{ label = _("Nib angle"), value = cur.nib or 45, min = 0, max = 90,
                width = content_w, parent = menu, format = function(v) return string.format("%d\u{00B0}", v) end,
                on_set = function(v) self.pen_nib = v; self:penChanged("nib", v); showPreview() end })
        end

        -- one row of colours (the smudge has none: it moves the colours already there)
        if not smudge then
            add(vspan(10))
            add(self:penColourRow(content_w, gap, cur, closeSelf, again))
        end

        add(vspan(12))
        add(self:actionButton(_("Pen and input settings"), content_w, function() closeSelf(); self:openPenInput() end,
            nil, nil, "sliders"))
        return content
    end
    self:showSheet("_pen_dialog", build, { on_close = function() self._pen_strip = nil end })
end

-- The kinds of pen, each drawn as it is set, in groups; the reader's made
-- brushes (a hold deletes one), and making one. A tap makes the pen in hand
-- that kind and goes back to the Pen sheet; with `adding` (from +) it makes a
-- new saved pen of that kind instead.
function InkAwayView:openPenTypes(adding)
    self:closeSheet("_pentypes_dialog")
    self:ensureUserIcons()
    local content_w, gap = self:sheetWidth()
    local function closeSelf() self:closeSheet("_pentypes_dialog") end
    local build = function()
        local case = self:penset()
        local cur = case.cur
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(adding and _("New pen") or _("Kind of pen"), content_w, _("Back"),
            function() closeSelf(); self:openPenSettings() end))
        if adding then
            add(vspan(4))
            add(self:sheetHint(_("Choose its kind. You can then set its size and colour."), content_w))
        end
        local cols = 5
        local kw = math.floor((content_w - (cols - 1) * gap) / cols)
        local kh = Screen:scaleBySize(34)
        local function kindTile(style, label, hold_cb)
            local p = case.types[style] or Penset.default(style, case.opts)
            local shown = { style = style, width = p.width, alpha = p.alpha, color = p.color }
            local bb = self:cachedPenSample(shown, kw - Screen:scaleBySize(6), kh,
                math.min(p.width, math.floor(kh * 0.45)))
            local tile = frame(self:imageTile(bb, kw - Screen:scaleBySize(6), kh,
                function()
                    closeSelf()
                    if adding then self:addPen(style) else self:setPenKind(style) end
                    self:openPenSettings()
                end, hold_cb),
                not adding and cur.style == style)
            return VerticalGroup:new{ align = "center", tile, caption(label, kw) }
        end
        for _i, g in ipairs(Penset.GROUPS) do
            add(vspan(10))
            add(self:sheetLabel(_(g.label)))
            add(vspan(6))
            local tiles = {}
            for _j, style in ipairs(g.types) do
                -- the smudge needs the page under the ink, which a book's ink does not keep
                if not (self.reader_mode and style == "smudge") then
                    tiles[#tiles + 1] = kindTile(style, _(Penset.LABELS[style]))
                end
            end
            add(rows(tiles, cols, gap))
        end
        local mine = Brushes.userList(function(k) return self:getSetting(k) end)
        if #mine > 0 then
            add(vspan(10))
            add(self:sheetLabel(_("Your brushes")))
            add(vspan(6))
            local tiles = {}
            for _i, b in ipairs(mine) do
                if b.name then
                    local key = "user:" .. b.name
                    tiles[#tiles + 1] = kindTile(key, b.name, function() self:confirmDeleteBrush(key, b.name) end)
                end
            end
            add(rows(tiles, cols, gap))
        end
        if #mine < PEN_CUSTOM_CAP then
            add(vspan(14))
            add(self:actionButton(_("Make a brush"), content_w, function() closeSelf(); self:openBrushMaker() end,
                nil, nil, "brush"))
        end
        return content
    end
    self:showSheet("_pentypes_dialog", build)
end

-- One row of colours: on a colour screen black, grey, five colours and the
-- colour wheel (the saved colours are a row under it, if there are any); on a
-- greyscale one the five shades.
function InkAwayView:penColourRow(content_w, gap, cur, closeSelf, again)
    local out = VerticalGroup:new{ align = "left" }
    local colour = self:colorScreen()
    local n = colour and 8 or 5
    local sw = math.floor((content_w - (n - 1) * gap) / n)
    local swh = math.min(sw, Screen:scaleBySize(36))
    local function swatch(rgb, custom)
        return self:swatchTile(rgb, sameColor(cur.color, rgb), sw,
            function() self.pen_color = { rgb[1], rgb[2], rgb[3] }; self:penChanged("color", self.pen_color); again() end,
            custom and function() self:removeCustomColor(rgb); again() end or nil, swh)
    end
    local function line(list)
        local hg = HorizontalGroup:new{ align = "center" }
        for i, t in ipairs(list) do
            if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
            table.insert(hg, t)
        end
        return hg
    end
    local tiles = {}
    if colour then
        tiles[1] = swatch(SHADES[1].rgb)
        tiles[2] = swatch(SHADES[3].rgb)
        for i = 1, 5 do tiles[#tiles + 1] = swatch(COLORS[i].rgb) end
        tiles[#tiles + 1] = self:wheelTile(sw, swh, function() closeSelf(); self:openColorPicker() end)
    else
        for _i, e in ipairs(SHADES) do tiles[#tiles + 1] = swatch(e.rgb) end
    end
    table.insert(out, line(tiles))
    if colour then
        local customs = self:getCustomColors()
        if #customs > 0 then
            local chunk = {}
            for j = 1, math.min(#customs, n) do chunk[#chunk + 1] = swatch(customs[j], true) end
            table.insert(out, VerticalSpan:new{ width = gap })
            table.insert(out, line(chunk))
        end
    end
    return out
end

-- A saved pen's menu (from a hold): move it, copy it, or remove it. (The
-- saved pen in hand is changed by changing the pen itself.)
function InkAwayView:editSavedPen(i)
    local case = self:penset()
    local function done() self:applyPen(case.cur); self:savePens(); self:openPenSettings() end
    local rows_ = {
        { { _("Move left"), function() Penset.moveFav(case, i, -1); done() end },
          { _("Move right"), function() Penset.moveFav(case, i, 1); done() end } },
    }
    if #case.favs < Penset.FAV_CAP then
        rows_[#rows_ + 1] = { { _("Make a copy"), function() Penset.duplicateFav(case, i); done() end } }
    end
    rows_[#rows_ + 1] = { { _("Remove"), function() Penset.removeFav(case, i); done() end, true } }
    -- named for the pen held, with its size
    local p = case.favs[i]
    self:openActionSheet("_penfav_menu", p and Penset.display(p, _) or _("Saved pen"),
        p and Penset.mmText(p.width, self:pxPerMM()) or nil, rows_)
end

------------------------------------------------------------------------------
-- Pen and input: the settings that are set once, not per pen
------------------------------------------------------------------------------

function InkAwayView:openPenInput()
    if self:rebuildSheet("_peninput_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local function closeSelf() self:closeSheet("_peninput_dialog") end
    local function again() self:openPenInput() end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Pen and input"), content_w, _("Done"), closeSelf))
        add(vspan(12))
        add(ToggleRow:new{ label = _("Palm rejection"), is_on = self.palm_reject,
            width = content_w, parent = menu, callback = function(on)
                -- where KOReader can't hand over the pen it stays off (see penCapable)
                if on and not self:penCapable() then
                    again()
                    self:tell(self:onAndroid() and _(
                        "On Android, palm rejection needs a KOReader newer than 2026.07.1 (a nightly build from August 2026 or later). Earlier versions report the pen as a finger, so Ink Away can't tell it from your hand. Your pen draws as it is.")
                        or _("Palm rejection needs KOReader 2026.07 or newer (that release added the pen input support). Please update KOReader and it will start working. On a reader without a pen it does nothing."))
                    return
                end
                self.palm_reject = on; self:setSetting("inkaway_palm_reject", on); self:applyPalmReject()
                again()   -- show or hide the options that need it
            end })
        -- with palm rejection on, the pen writes and fingers can be kept for moving
        -- around: scrolling, turning pages, holding a picture or shape for its menu
        if self.palm_reject then
            add(vspan(10))
            add(self:sheetLabel(_("Finger on the page")))
            add(vspan(6))
            add(self:segmentedRow({ { "navigate", _("Navigate") }, { "nothing", _("Nothing") } },
                self.finger_mode, content_w,
                function(m) self.finger_mode = m; self:setSetting("inkaway_finger_mode", m); again() end))
        end
        if not (self.reader_mode or self.floating) then
            add(vspan(10))
            add(ToggleRow:new{ label = _("Your pens on the page"), is_on = self:penStripOn(),
                width = content_w, parent = menu, callback = function(on)
                    self.pen_strip = on; self:setSetting("inkaway_pen_strip", on)
                    self._paint_all = true
                    UIManager:setDirty(self, "ui")
                end })
            add(vspan(4))
            add(self:sheetHint(_("Your first four saved pens in a small strip at the bottom of the page, one tap away."), content_w))
        end
        add(vspan(10))
        add(ToggleRow:new{ label = _("Hold still to straighten"), is_on = self.hold_straighten,
            width = content_w, parent = menu,
            callback = function(on) self.hold_straighten = on; self:setSetting("inkaway_hold_straighten", on) end })
        add(vspan(10))
        add(ToggleRow:new{ label = _("Pen taps menus and buttons"), is_on = self.pen_ui,
            width = content_w, parent = menu,
            callback = function(on) self.pen_ui = on; self:setSetting("inkaway_pen_ui", on) end })
        -- the pen's own pressure, a Beta and off by default, offered only where
        -- a pen can give it (see pressureReader); with it on, how hard a press
        -- counts as firm is chosen below
        if self:pressureReader() then
            add(vspan(10))
            add(ToggleRow:new{ label = _("Pen pressure (Beta)"), is_on = self.pen_pressure == true,
                width = content_w, parent = menu, callback = function(on)
                    self.pen_pressure = on; self:setSetting("inkaway_pen_pressure_beta", on)
                    if on then self:installPressure() else self:removePressure() end
                    again()
                end })
            if self.pen_pressure == true then
                add(vspan(6))
                add(self:segmentedRow({ { "soft", _("Light touch") }, { "medium", _("Medium") }, { "firm", _("Firm") } },
                    self.pressure_curve or "medium", content_w,
                    function(c) self.pressure_curve = c; self:setSetting("inkaway_pressure_curve", c); again() end))
            end
            add(vspan(4))
            add(self:sheetHint(_("Still being tested. With Palm rejection on, Ballpoint, Fountain, Calligraphy and Pencil get wider the harder you press. If it misbehaves on your reader, I'd love to hear about it on GitHub."), content_w))
        end
        -- a Boox: Ink Away asks for the fast refresh itself (see ink/einkdrive.lua)
        if self:onAndroid() and EinkDrive.detect() then
            add(vspan(10))
            add(ToggleRow:new{ label = _("Fast refresh while drawing"), is_on = self:getSetting("inkaway_boox_fast", true) ~= false,
                width = content_w, parent = menu, callback = function(on)
                    self:setSetting("inkaway_boox_fast", on)
                    if on then self:startEinkDrive() else self:stopEinkDrive() end
                end })
            add(vspan(4))
            add(self:sheetHint(_("Ink shows with the Boox's fast black-and-white refresh as you write, and settles into grey and colour when the pen rests."), content_w))
        end
        add(vspan(12))
        add(SliderRow:new{ label = _("Stabilizer"), value = self.stabilizer, min = 0, max = 100,
            width = content_w, parent = menu, format = function(v) return tostring(v) end,
            on_set = function(v) self.stabilizer = v; self:setSetting("inkaway_stabilizer", v) end })
        add(vspan(4))
        add(self:sheetHint(
            _("Smooths shaky lines. Higher values steady the stroke but trail your finger slightly."), content_w))
        -- the pen test is the app's (over a book it would only take the book away)
        if not (self.reader_mode or self.floating) then
            add(vspan(14))
            add(self:actionButton(_("Test pen and touch"), content_w, function() closeSelf(); self:openPenTest() end,
                nil, nil, "target"))
        end
        return content
    end
    self:showSheet("_peninput_dialog", build)
end

return InkAwayView
