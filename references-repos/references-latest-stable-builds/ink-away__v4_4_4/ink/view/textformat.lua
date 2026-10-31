--[[
Text rendering and formatting: fonts and the measuring context handed to the text
engine (ink/text.lua), styles and the format menu, and the clipboard.
Part of InkAwayView (see ink/view.lua).
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Text = require("ink/text")
local Turn = require("ink/turn")

local sameColor = Palette.sameColor

local Screen = Device.screen

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local CLIP_MAX = 5000   -- longest paste, in characters (a huge one would stall the layout)

local InkAwayView = {}

-- Line spacing: how far apart a box's lines are, as a share of the normal.
InkAwayView.TEXT_SPACING = { tight = 0.85, loose = 1.4 }

------------------------------------------------------------------------------
-- Fonts and the measuring and rendering context handed to the text engine.
-- They live here, not in ink/text.lua, so the engine stays pure Lua and testable.
------------------------------------------------------------------------------

function InkAwayView:textFontName()
    return self.text_font or "cfont"
end

-- Friendly display name for the current note font.
function InkAwayView:textFontDisplay()
    if not self.text_font then return _("Default") end
    return (self.text_font:gsub(".*/", ""):gsub("%.%w+$", ""))
end

-- Apply a font change: rebuild the face cache, update the box being edited (or
-- recompose so committed boxes on the default font pick it up), and persist.
function InkAwayView:afterFontChange()
    self._face_cache = nil
    self:invalidateLayout()
    self:setSetting("inkaway_text_font", self.text_font or "")
    if self.editing_text then
        self.editing_text.font = self.text_font
        self:refreshTextBox("flashui")
    else
        self:composeCanvas(); self:renderView(); self:refresh(self, "full")
    end
end

-- A scrollable chooser over the installed fonts, each shown in its own face.
-- on_done runs once one is chosen (the Format sheet shows the new name).
function InkAwayView:openTextFont(on_done)
    local FontList = require("fontlist")
    local function pick(path)
        self.text_font = path
        self:afterFontChange()
        if on_done then on_done() end
    end
    local items = {
        { text = (self.text_font == nil and "\u{2713} " or "") .. _("Default (content font)"),
          preview_font = "cfont",
          callback = function() pick(nil) end },
    }
    for _, path in ipairs(FontList:getFontList()) do
        local name = (path:gsub(".*/", ""):gsub("%.%w+$", ""))
        items[#items + 1] = { text = (self.text_font == path and "\u{2713} " or "") .. name,
            preview_font = path,
            callback = function() pick(path) end }
    end
    -- fit the popup inside the drawing area with a margin all round, clear of the
    -- toolbar and the notebook bar
    local v = self.view
    local m = Screen:scaleBySize(28)
    local area = { x = v.area_x, y = v.area_y, w = v.area_w, h = v.area_h }
    local FontMenu = require("ink/ui/fontmenu")
    local menu
    menu = FontMenu:new{
        title = _("Note font"),
        item_table = items,
        is_popout = true,
        width = math.max(200, area.w - 2 * m),
        height = math.max(200, area.h - 2 * m),
        center_rect = area,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- The ruling step (canvas px) that grid-snapped text lines up with, or nil when
-- there is nothing to snap to. A notebook uses its printed ruling; a drawing uses
-- the on-screen grid, in the styles that have rows (square, lines, dots).
function InkAwayView:textRulingStep()
    if self.notebook then
        local t = self.notebook:pageTemplate()
        if t and t.style and t.style ~= "blank" then return t.size or 40 end
        return nil
    end
    if self.grid_on and self.grid_size and self.grid_size > 0 then
        local s = self.grid_style or "square"
        if s == "square" or s == "lines" or s == "dots" then return self.grid_size end
    end
    return nil
end

-- Snap a text box's top edge onto the ruling, so its lines sit on the printed
-- lines (a no-op without one).
function InkAwayView:snapTextBoxToGrid(op)
    local step = self:textRulingStep()
    if op and step and step > 0 and not Text.turned(op) then op.y = math.floor(op.y / step + 0.5) * step end
end

-- The font size (canvas px) for grid-snapped text, so one line fills one ruling
-- row. The font's ascent is aimed at ~0.90 of the step, using the face's own
-- ascent ratio (it varies a lot between fonts), so every font fills a row alike.
function InkAwayView:gridBaseSize(name, rawStep)
    local probe = 100
    local face = self:faceAt(name, probe)
    local ratio = 1.0
    if face and face.ftsize then
        local _, asc = face.ftsize:getHeightAndAscender()
        if asc and asc > 0 then ratio = asc / probe end
    end
    return math.max(6, math.floor(0.90 * rawStep / ratio + 0.5))
end

-- A cached font face at a real pixel size. Font:getFace scales the size it is
-- given by the screen DPI, so the size is divided by that factor first.
function InkAwayView:faceAt(name, px)
    px = math.max(6, math.floor(px + 0.5))
    if not self._dpi_factor then
        local s = Screen.scaleBySize and (Screen:scaleBySize(1000) / 1000)
        self._dpi_factor = (s and s > 0) and s or 1
    end
    self._face_cache = self._face_cache or {}
    local key = name .. "@" .. px
    local f = self._face_cache[key]
    if not f then
        f = Font:getFace(name, math.max(6, math.floor(px / self._dpi_factor + 0.5)))
        self._face_cache[key] = f
    end
    return f
end

-- The context the text engine uses to measure and render one op. `scale` is 1
-- for the 1:1 master bitmap and the view zoom for the crisp editing overlay.
function InkAwayView:textCtx(op, scale)
    local RenderText = require("ui/rendertext")
    scale = scale or 1
    local name = op.font or self:textFontName()
    -- grid-line snap: when the box asks for it and the page has rows, the ruling
    -- step sets both the line spacing and the font size, so one line fills one
    -- row however fine the ruling
    -- (a turned box keeps the size but leaves the ruling, which it cannot follow)
    local rawStep = op.grid_snap and self:textRulingStep() or nil
    local gridStep = rawStep and not Text.turned(op) and rawStep * scale or nil
    local base = rawStep and self:gridBaseSize(name, rawStep) or (op.size or 32)
    local function pxOf(style) return base * ((style and style.sz) or 1) * scale end
    local spacing = InkAwayView.TEXT_SPACING[op.spacing] or 1
    local function faceOf(style) return self:faceAt(name, pxOf(style)) end
    local meta = {}
    local function metaOf(style)
        local px = math.max(6, math.floor(pxOf(style) + 0.5))
        local m = meta[px]
        if not m then
            local face = self:faceAt(name, px)
            local h, asc = face.ftsize:getHeightAndAscender()
            local lh = math.max(math.floor(h + 0.5), math.floor(px * 1.3 + 0.5))
            m = { lh = math.max(1, math.floor(lh * spacing + 0.5)), asc = math.floor(asc + 0.5) }
            meta[px] = m
        end
        return m
    end
    return {
        gridStep = gridStep,
        measure = function(text, style)
            if not text or text == "" then return 0 end
            return RenderText:sizeUtf8Text(0, nil, faceOf(style), text, true,
                (style and style.b) or false).x
        end,
        lineHeight = function(style) return metaOf(style).lh end,
        ascent = function(style) return metaOf(style).asc end,
        bulletLabel = function(para, pi)
            if para.bullet == "number" then
                local n = 1
                for k = pi - 1, 1, -1 do
                    if op.paras[k].bullet == "number" then n = n + 1 else break end
                end
                return n .. ".  "
            end
            return "\u{2022}  "
        end,
        face = faceOf,
        bold = function(style) return (style and style.b) or false end,
    }
end

-- Lay out a text op and, if its height is automatic, grow the box to fit.
function InkAwayView:layoutText(op, scale)
    local ctx = self:textCtx(op, scale or 1)
    local lay = Text.layout(op, ctx)
    return lay, ctx
end

-- Render a text op into a canvas-space bitmap at its own position; with
-- `region` (a canvas rect) only into that part of it. `ink` is the text's
-- colour, the open document's (see textInk) by default: white on a dark paper,
-- where a highlight under it is dark grey too.
function InkAwayView:stampTextInto(dst, op, region, ink)
    local lay, ctx = self:layoutText(op, 1)
    if op.auto_h then op.h = lay.height end
    local rctx = self:textPaints(ink or self:textInk(), self:colorScreen(), self:paperRGB())
    if Text.turned(op) then
        -- drawn upright, then put on the page turned (see ink/turn.lua)
        local c, s = Text.turn(op)
        Turn.paint(dst, op.x, op.y, c, s, op.w, op.h, self:textOverhang(op),
            function(bb, x, y) Text.render(op, lay, bb, x, y, ctx, rctx) end, region)
        return
    end
    local x, y = op.x, op.y
    if region then
        dst = dst:viewport(region.x0, region.y0, region.x1 - region.x0, region.y1 - region.y0)
        x, y = x - region.x0, y - region.y0
    end
    Text.render(op, lay, dst, x, y, ctx, rctx)
end

-- The colours a text box is drawn in (the rctx of Text.render): its letters in
-- `ink` (black, or white on a dark paper) unless a span has its own colour, and
-- its highlights. A colour screen (`colour`) shows the colours; a grey one shows
-- a coloured span in its grey and every highlight in the one grey. On a dark
-- paper a highlight is the colour toned down toward the paper, so the white
-- letters on it still read.
function InkAwayView:textPaints(ink, colour, paper)
    local dark = Paint.darkPaper(paper)
    local function rgbColor(rgb) return Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF) end
    local grey_mark = dark and Blitbuffer.Color8(0x55) or Blitbuffer.COLOR_LIGHT_GRAY
    return {
        color = ink,
        highlight = grey_mark,
        ink = function(c)
            local rgb = self:shownInk(Text.unpackRGB(c), paper)
            if not colour then return Blitbuffer.Color8(math.floor(Paint.lum(rgb) + 0.5)), false end
            return rgbColor(rgb), not (rgb[1] == rgb[2] and rgb[2] == rgb[3])
        end,
        mark = function(hl)
            if not colour then return grey_mark, false end
            local rgb = hl == true and Palette.HIGHLIGHTS[1].rgb or Text.unpackRGB(hl)
            if dark then
                local p = paper
                rgb = { math.floor(rgb[1] * 0.45 + p[1] * 0.55 + 0.5), math.floor(rgb[2] * 0.45 + p[2] * 0.55 + 0.5),
                        math.floor(rgb[3] * 0.45 + p[3] * 0.55 + 0.5) }
            end
            return rgbColor(rgb), true
        end,
    }
end

-- How far a box's letters can reach past its edges (a slanted italic, a glyph's
-- overhang), in canvas px: the margin a turned box is drawn with.
function InkAwayView:textOverhang(op)
    return 4 + math.floor((op.size or 32) * 0.3)
end

-- Rasterise a text op at 1:1 for the exporter: drawn as on the screen, on the
-- export's paper {r,g,b} (white by default) in its ink {r,g,b} (black by
-- default), into a packed RGB buffer; a pixel still the paper's colour is not
-- drawn on. Returns the buffer, w, h, the canvas point its top-left pixel goes
-- to (op.x, op.y for an upright box) and 3, its bytes per pixel.
function InkAwayView:exportTextRaster(op, paper, ink)
    local lay, ctx = self:layoutText(op, 1)
    if op.auto_h then op.h = lay.height end
    paper = paper or { 255, 255, 255 }
    ink = ink or { 0, 0, 0 }
    local inkc = Blitbuffer.ColorRGB32(ink[1], ink[2], ink[3], 0xFF)
    local rctx = self:textPaints(inkc, self:colorScreen(),
        not (paper[1] == 255 and paper[2] == 255 and paper[3] == 255) and paper or nil)
    local rx, ry, w, h
    local draw
    if Text.turned(op) then
        local x0, y0, x1, y1 = Text.bounds(op)
        local m = self:textOverhang(op)
        rx, ry = math.floor(x0) - m, math.floor(y0) - m
        w, h = math.ceil(x1) + m - rx, math.ceil(y1) + m - ry
        local c, s = Text.turn(op)
        draw = function(bb)
            Turn.paint(bb, op.x - rx, op.y - ry, c, s, op.w, op.h, m, function(b, x, y)
                Text.render(op, lay, b, x, y, ctx, rctx)
            end)
        end
    else
        rx, ry = op.x, op.y
        w = math.max(1, math.floor(op.w + 0.5))
        h = math.max(1, math.floor((op.auto_h and lay.height or op.h) + 0.5))
        draw = function(bb) Text.render(op, lay, bb, 0, 0, ctx, rctx) end
    end
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    bb:paintRectRGB32(0, 0, w, h, Blitbuffer.ColorRGB32(paper[1], paper[2], paper[3], 0xFF))
    draw(bb)
    local out = ffi.new("uint8_t[?]", w * h * 3)
    local data = ffi.cast("uint8_t*", bb.data)
    local stride = tonumber(bb.stride)
    for py = 0, h - 1 do
        local srow, drow = py * stride, py * w * 3
        for px = 0, w - 1 do
            local si, di = srow + px * 4, drow + px * 3
            out[di], out[di + 1], out[di + 2] = data[si], data[si + 1], data[si + 2]
        end
    end
    bb:free()
    return out, w, h, rx, ry, 3
end

------------------------------------------------------------------------------
-- Styling the selection, or the next typing when nothing is selected
------------------------------------------------------------------------------

function InkAwayView:textHasSel()
    return self.text_sel and not Text.selEmpty(self.text_sel)
end

-- The word around the cursor as a selection, or nil if the cursor is not on a
-- word, so a tap on a word is enough to format it.
function InkAwayView:wordSelAtCursor()
    local op, cur = self.editing_text, self.text_cur
    if not (op and cur) then return nil end
    local ch = Text.chars(Text.paraText(op.paras[cur.p]))
    local function isW(c) return c ~= nil and c:match("[%w'\u{2019}]") ~= nil end
    local lo, hi = cur.o, cur.o
    while lo > 0 and isW(ch[lo]) do lo = lo - 1 end          -- ch[lo] = char left of offset lo
    while hi < #ch and isW(ch[hi + 1]) do hi = hi + 1 end    -- ch[hi+1] = char right of offset hi
    if hi <= lo then return nil end
    return { a = { p = cur.p, o = lo }, b = { p = cur.p, o = hi } }
end

-- What a format action targets: the selection, else the word under the cursor.
-- nil means no target, and the style applies to the next typing instead.
function InkAwayView:textEffectiveSel()
    if self:textHasSel() then return self.text_sel end
    return self:wordSelAtCursor()
end

function InkAwayView:textStyleActive(key)
    local sel = self:textEffectiveSel()
    if sel then return Text.styleCovers(self.editing_text, sel, key) end
    local st = self._text_pending_style or Text.styleAt(self.editing_text, self.text_cur)
    return st[key] and true or false
end

function InkAwayView:textToggleStyle(key)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local sel = self:textEffectiveSel()
    if sel then
        local on = not Text.styleCovers(op, sel, key)
        Text.applyStyle(op, sel, key, on or nil)
    else
        self._text_pending_style = self._text_pending_style or Text.styleAt(op, self.text_cur)
        self._text_pending_style[key] = (not self._text_pending_style[key]) or nil
    end
    self:refreshTextBox("ui")
end

function InkAwayView:textStepSize(dir)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local function stepped(st)
        return math.max(0.5, math.min(4, (st.sz or 1) * (dir > 0 and 1.2 or 1 / 1.2)))
    end
    local sel = self:textEffectiveSel()
    if sel then
        local a = Text.orderSel(sel)
        local nz = stepped(Text.styleAt(op, a))
        Text.applyStyle(op, sel, "sz", (math.abs(nz - 1) < 1e-3) and nil or nz)
    else
        self._text_pending_style = self._text_pending_style or Text.styleAt(op, self.text_cur)
        local nz = stepped(self._text_pending_style)
        self._text_pending_style.sz = (math.abs(nz - 1) < 1e-3) and nil or nz
    end
    self:refreshTextBox("ui")
end

function InkAwayView:textToggleBullet(kind)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local sel = self.text_sel or { a = self.text_cur, b = self.text_cur }
    local a = Text.orderSel(sel)
    Text.setBullet(op, sel, op.paras[a.p].bullet == kind and nil or kind)
    self:refreshTextBox("ui")
end

-- The value of style `key` where a format action would apply (the start of the
-- selection or the word, else what typing next gets).
function InkAwayView:textStyleValue(key)
    local op = self.editing_text
    local sel = self:textEffectiveSel()
    if sel then
        local a = Text.orderSel(sel)
        return Text.styleAt(op, { p = a.p, o = math.min(a.o + 1, Text.paraLen(op.paras[a.p])) })[key]
    end
    local st = self._text_pending_style or Text.styleAt(op, self.text_cur)
    return st[key]
end

-- Set style `key` to `value` (nil clears it) on the selection or the word, or
-- for the next typing.
function InkAwayView:textSetStyle(key, value)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local sel = self:textEffectiveSel()
    if sel then
        Text.applyStyle(op, sel, key, value)
    else
        self._text_pending_style = self._text_pending_style or Text.styleAt(op, self.text_cur)
        self._text_pending_style[key] = value
    end
    self:refreshTextBox("ui")
end

-- Take every style off the selection or the word (or the next typing).
function InkAwayView:textPlain()
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local sel = self:textEffectiveSel()
    if sel then
        for _, k in ipairs({ "b", "i", "u", "s", "hl", "sz", "c" }) do Text.applyStyle(op, sel, k, nil) end
    else
        self._text_pending_style = {}
    end
    self:refreshTextBox("ui")
end

-- The box's alignment, line spacing ("tight", nil, "loose").
function InkAwayView:textSetAlign(align)
    self.editing_text.align = align
    self:invalidateLayout()
    self:refreshTextBox("ui")
end

function InkAwayView:textSetSpacing(spacing)
    local old = self:textOverlayRect()
    self.editing_text.spacing = spacing
    self:invalidateLayout(); self:editTextLayout()
    self:refreshRectUnion(old, self:textOverlayRect(), 2, "ui")
end

-- Turn the box across (0), reading down (90) or reading up (270). Its top-left
-- corner as it shows on the page stays put; a new box stood on end starts where
-- it was tapped instead (a box started in a book's margin is moved in from the
-- edge so it is not a sliver, and would otherwise stand on the text). A line too
-- long for the page there is shortened, and the box is kept on the page.
function InkAwayView:textSetTurn(deg)
    local op = self.editing_text
    if ((op.angle or 0) % 360) == deg then return end
    local old = self:textOverlayRect()
    local x0, y0 = Text.bounds(op)
    if not x0 then x0, y0 = op.x, op.y end
    local tap = self._text_tap_at
    if deg ~= 0 and tap and tap.op == op then x0, y0 = tap.x, tap.y end
    op.angle = deg ~= 0 and deg or nil
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    local margin = math.max(6, math.floor(math.min(W, H) * 0.02))
    local room = (deg == 0) and (W - margin - x0) or (H - margin - y0)
    local least = math.max(40, math.floor((op.size or 32) * 4))
    if op.w > room then op.w = math.max(least, room) end
    self:invalidateLayout(); self:editTextLayout()
    -- the corner it shows at goes there, then the box is kept on the page
    local nx0, ny0 = Text.bounds(op)
    local dx, dy = x0 - nx0, y0 - ny0
    local bx0, by0, bx1, by1 = nx0 + dx, ny0 + dy, select(3, Text.bounds(op))
    bx1, by1 = bx1 + dx, by1 + dy
    if bx1 > W then dx = dx - (bx1 - W) elseif bx0 < 0 then dx = dx - bx0 end
    if by1 > H then dy = dy - (by1 - H) elseif by0 < 0 then dy = dy - by0 end
    op.x, op.y = op.x + dx, op.y + dy
    if deg == 0 then self:snapTextBoxToGrid(op) end
    self:ensureCaretVisible()
    self:refreshRectUnion(old, self:textOverlayRect(), 2, "flashui")
end

-- Select everything in the box.
function InkAwayView:textSelectAll()
    local op = self.editing_text
    local last = #op.paras
    self.text_sel = { a = { p = 1, o = 0 }, b = { p = last, o = Text.paraLen(op.paras[last]) } }
    self.text_cur = self.text_sel.b
    self:textBreakCoalesce()
    self:refreshTextBox("ui")
end

-- Today's date as KOReader writes it (in the reader's language), typed at the
-- caret in place of any selection.
function InkAwayView:textInsertDate()
    local ok, datetime = pcall(require, "datetime")
    local s = ok and datetime.secondsToDate and datetime.secondsToDate(os.time(), true) or os.date("%Y-%m-%d")
    self:textBreakCoalesce()
    self:textMark("paste")
    self:textDeleteSelIfAny()
    self.text_cur = Text.insert(self.editing_text, self.text_cur, s, self._text_pending_style or nil)
    self._text_pending_style = nil
    self:textBreakCoalesce()
    self:afterTextEdit()
end

------------------------------------------------------------------------------
-- Text and highlight colours the reader saved (up to three of each), kept in
-- the settings as lists of {r,g,b}.
------------------------------------------------------------------------------

InkAwayView.TEXT_COLOUR_SLOTS = 3

function InkAwayView:textSavedColours(kind)
    local list = self:getSetting("inkaway_text_" .. kind .. "_colours")
    return type(list) == "table" and list or {}
end

function InkAwayView:textSaveColour(kind, rgb)
    local list = self:textSavedColours(kind)
    for _, c in ipairs(list) do
        if sameColor(c, rgb) then return end
    end
    list[#list + 1] = { rgb[1], rgb[2], rgb[3] }
    while #list > InkAwayView.TEXT_COLOUR_SLOTS do table.remove(list, 1) end   -- the oldest goes
    self:setSetting("inkaway_text_" .. kind .. "_colours", list)
end

function InkAwayView:textForgetColour(kind, rgb)
    local list = self:textSavedColours(kind)
    for i, c in ipairs(list) do
        if sameColor(c, rgb) then table.remove(list, i); break end
    end
    self:setSetting("inkaway_text_" .. kind .. "_colours", list)
end

-- The colour wheel for a text (kind "ink") or highlight ("mark") colour: a pick
-- applies it, a save keeps it among the three of that kind too.
function InkAwayView:openTextColourWheel(kind, current, apply)
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    UIManager:show(ColorPicker:new{
        color = current,
        on_pick = function(rgb) apply(rgb) end,
        on_save = function(rgb) self:textSaveColour(kind, rgb); apply(rgb) end,
    })
end

------------------------------------------------------------------------------
-- The Format sheet. It takes the keyboard's place at the bottom of the drawing
-- area, with the box being edited above it, and stays open while options are
-- picked one after another; Done, Format or a tap outside brings the keyboard
-- back. Three tabs: Text (styles, size, colour, highlight), Paragraph
-- (alignment, lists, line spacing, turning, font) and Edit (clipboard, select
-- all, the date).
------------------------------------------------------------------------------

function InkAwayView:openTextFormatMenu()
    if not self.editing_text then return end
    self:closeSheet("_text_fmt")
    self:hideClipBubble()
    self:hideTextKeyboard()
    local gap = Screen:scaleBySize(10)
    local content_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local colour = self:colorScreen()
    local function again() self:rebuildSheet("_text_fmt") end
    local function done()
        self:closeSheet("_text_fmt")
        if self.editing_text then self:showTextKeyboard() end
    end
    local build = function()
        if not self.editing_text then return VerticalGroup:new{} end
        local op = self.editing_text
        local tab = self._text_fmt_tab or "text"
        local sel = self:textEffectiveSel()
        -- a row of equal buttons filling content_w exactly
        local function row(items)
            local n = #items
            local bw = math.floor((content_w - (n - 1) * gap) / n)
            local g = HorizontalGroup:new{ align = "center" }
            for i, it in ipairs(items) do
                local w = (i == n) and (content_w - (n - 1) * (bw + gap)) or bw
                local enabled = it.enabled ~= false
                local b = self:actionButton(it.label, w, enabled and it.cb or function() end, it.active)
                if not enabled then
                    b.enabled = false                                   -- no tap flash either
                    if b.label_widget then b.label_widget.fgcolor = Blitbuffer.Color8(0xA0) end
                end
                g[#g + 1] = b
                if i < n then g[#g + 1] = HorizontalSpan:new{ width = gap } end
            end
            return g
        end
        local function act(label, fn, active, enabled)
            return { label = label, active = active, enabled = enabled,
                     cb = function() fn(); again() end }
        end
        local function style(label, key)
            return act(label, function() self:textToggleStyle(key) end, self:textStyleActive(key))
        end
        -- a row of colour tiles (wrapping onto more rows), each a swatch, the
        -- wheel or an empty slot
        local per_row = colour and 7 or 5
        local sw = math.floor((content_w - (per_row - 1) * gap) / per_row)
        local swh = math.min(sw, Screen:scaleBySize(36))
        local function tiles(list)
            local out = VerticalGroup:new{ align = "left" }
            local line
            for i, t in ipairs(list) do
                if (i - 1) % per_row == 0 then
                    if line then out[#out + 1] = VerticalSpan:new{ width = gap } end
                    line = HorizontalGroup:new{ align = "center" }
                    out[#out + 1] = line
                else
                    line[#line + 1] = HorizontalSpan:new{ width = gap }
                end
                line[#line + 1] = t
            end
            return out
        end
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Format"), content_w, _("Done"), done))
        add(vspan(6))
        add(self:segmentedRow({ { "text", _("Text") }, { "para", _("Paragraph") }, { "edit", _("Edit") } },
            tab, content_w, function(t) self._text_fmt_tab = t; again() end))
        add(vspan(8))
        if tab == "text" then
            add(TextWidget:new{ text = sel and _("Applies to the selected word or text")
                    or _("Applies to what you type next"),
                face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.Color8(0x66) })
            add(vspan(8))
            add(row({ style(_("Bold"), "b"), style(_("Italic"), "i"), style(_("Underline"), "u"),
                style(_("Strike"), "s") }))
            add(vspan(8))
            add(row({ act("A\u{2212}", function() self:textStepSize(-1) end),
                act("A+", function() self:textStepSize(1) end),
                act(_("Plain"), function() self:textPlain() end) }))
            add(vspan(10))
            -- the letters' colour: black (the page's ink) and the greys, and on a
            -- colour screen the pen's colours, the wheel and the reader's own
            add(self:sheetLabel(_("Colour")))
            add(vspan(4))
            local cur_c = self:textStyleValue("c")
            local list = {}
            local function inkTile(rgb, saved)
                local packed = rgb and Text.packRGB(rgb) or nil
                list[#list + 1] = self:swatchTile(rgb or { 0, 0, 0 }, cur_c == packed or (packed == 0 and cur_c == nil), sw,
                    function() self:textSetStyle("c", packed ~= 0 and packed or nil); again() end,
                    saved and function() self:textForgetColour("ink", rgb); again() end or nil, swh)
            end
            inkTile(nil)
            inkTile(Palette.SHADES[2].rgb); inkTile(Palette.SHADES[3].rgb)
            if colour then
                for i = 1, 6 do if Palette.COLORS[i].name ~= _("Yellow") then inkTile(Palette.COLORS[i].rgb) end end
                for _, c in ipairs(self:textSavedColours("ink")) do inkTile(c, true) end
                list[#list + 1] = self:wheelTile(sw, swh, function()
                    self:openTextColourWheel("ink", cur_c and Text.unpackRGB(cur_c) or nil, function(rgb)
                        local packed = Text.packRGB(rgb)
                        self:textSetStyle("c", packed ~= 0 and packed or nil); again()   -- (black is the page's ink)
                    end)
                end)
            end
            add(tiles(list))
            add(vspan(10))
            -- the highlight: none, or a colour (one grey on a grey screen)
            add(self:sheetLabel(_("Highlight")))
            add(vspan(4))
            local cur_hl = self:textStyleValue("hl")
            list = {}
            local function markTile(rgb, value, saved)
                local on = (value == nil and not cur_hl) or (value ~= nil and cur_hl == value)
                list[#list + 1] = self:swatchTile(rgb, on, sw,
                    function() self:textSetStyle("hl", value); again() end,
                    saved and function() self:textForgetColour("mark", rgb); again() end or nil, swh)
            end
            markTile({ 255, 255, 255 }, nil)   -- none
            if colour then
                markTile(Palette.HIGHLIGHTS[1].rgb, true)   -- the default: also how older highlights show
                for i = 2, #Palette.HIGHLIGHTS do
                    markTile(Palette.HIGHLIGHTS[i].rgb, Text.packRGB(Palette.HIGHLIGHTS[i].rgb))
                end
                for _, c in ipairs(self:textSavedColours("mark")) do markTile(c, Text.packRGB(c), true) end
                list[#list + 1] = self:wheelTile(sw, swh, function()
                    local cur = type(cur_hl) == "number" and Text.unpackRGB(cur_hl) or Palette.HIGHLIGHTS[1].rgb
                    self:openTextColourWheel("mark", cur, function(rgb)
                        self:textSetStyle("hl", Text.packRGB(rgb)); again()
                    end)
                end)
            else
                markTile({ 0xAA, 0xAA, 0xAA }, true)
            end
            add(tiles(list))
            if colour then
                add(vspan(4))
                add(self:sheetHint(_("Hold a colour you added to remove it."), content_w))
            end
        elseif tab == "para" then
            local cur = self.text_sel and Text.orderSel(self.text_sel) or self.text_cur
            local bullet = op.paras[cur.p] and op.paras[cur.p].bullet
            add(self:sheetLabel(_("Alignment")))
            add(vspan(4))
            add(self:segmentedRow({ { "left", _("Left") }, { "center", _("Centre") }, { "right", _("Right") } },
                op.align or "left", content_w, function(a) self:textSetAlign(a); again() end))
            add(vspan(10))
            add(self:sheetLabel(_("List")))
            add(vspan(4))
            add(row({ act("\u{2022} " .. _("List"), function() self:textToggleBullet("disc") end, bullet == "disc"),
                act("1. " .. _("List"), function() self:textToggleBullet("number") end, bullet == "number"),
                act("\u{2713} " .. _("Checklist"), function() self:textToggleBullet("check") end, bullet == "check") }))
            add(vspan(10))
            add(self:sheetLabel(_("Line spacing")))
            add(vspan(4))
            add(self:segmentedRow({ { "tight", _("Tight") }, { "normal", _("Normal") }, { "loose", _("Loose") } },
                op.spacing or "normal", content_w, function(sp)
                    self:textSetSpacing(sp ~= "normal" and sp or nil); again()
                end))
            add(vspan(10))
            add(self:sheetLabel(_("Direction")))
            add(vspan(4))
            local a = (op.angle or 0) % 360
            add(self:segmentedRow({ { 0, _("Across") }, { 90, _("Reads down") }, { 270, _("Reads up") } },
                a, content_w, function(deg) self:textSetTurn(deg); again() end))
            add(vspan(4))
            add(self:sheetHint(_("Or turn the box to any angle with the ring above it."), content_w))
            add(vspan(10))
            add(self:actionButton(string.format(_("Font: %s"), self:textFontDisplay()), content_w,
                function() self:openTextFont(again) end))
        else
            local has_clip = self:clipboardText() ~= nil
            add(row({ act(_("Copy"), function() self:textCopy(false) end, false, sel ~= nil),
                      act(_("Cut"), function() self:textCopy(true) end, false, sel ~= nil),
                      act(_("Paste"), function() self:textPaste() end, false, has_clip) }))
            add(vspan(8))
            add(row({ act(_("Select all"), function() self:textSelectAll() end, false, not Text.isEmpty(op)),
                      act(_("Date"), function() self:textInsertDate() end) }))
        end
        return content
    end
    -- the sheet takes the keyboard's place at the bottom of the drawing area,
    -- leaving the text box visible above it
    local v = self.view
    self:showSheet("_text_fmt", build, { bottom_y = v.area_y + v.area_h,
        on_close = function() if self.editing_text then self:showTextKeyboard() end end })
end

------------------------------------------------------------------------------
-- Clipboard. A long press inside the box being edited shows a small "Paste"
-- bubble above the finger; tapping it inserts KOReader's clipboard at the caret,
-- replacing any selection. The format menu also has Copy, Cut and Paste. The
-- canvas draws the bubble itself, so the keyboard keeps working while it shows.
------------------------------------------------------------------------------

-- KOReader's clipboard text cleaned up for a text box (line breaks unified, tabs
-- as spaces, other control characters dropped, capped at CLIP_MAX characters).
-- Returns the text and whether it was shortened, or nil when there is none.
function InkAwayView:clipboardText()
    local inp = Device.input
    if not (inp and inp.getClipboardText) then return nil end
    local ok, s = pcall(inp.getClipboardText)
    if not ok or type(s) ~= "string" or s == "" then return nil end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    "):gsub("[%z\1-\8\11-\31\127]", "")
    if s == "" then return nil end
    if Text.ulen(s) > CLIP_MAX then return Text.usub(s, 0, CLIP_MAX), true end
    return s, false
end

function InkAwayView:textPaste()
    self:hideClipBubble()
    if not self.editing_text then return end
    local s, shortened = self:clipboardText()
    if not s then self:showNotice(_("The clipboard is empty.")); return end
    self:textBreakCoalesce()
    self:textMark("paste")            -- the whole paste is one undo step
    self:textDeleteSelIfAny()
    local style = self._text_pending_style or nil
    self.text_cur = Text.insert(self.editing_text, self.text_cur, s, style)
    self._text_pending_style = nil
    self:textBreakCoalesce()          -- typing after it starts a new step
    self:afterTextEdit()
    if shortened then
        self:showNotice(string.format(_("Pasted the first %d characters."), CLIP_MAX))
    end
end

-- Copy (or cut) the selection, or the word under the caret, to the clipboard.
function InkAwayView:textCopy(cut)
    self:hideClipBubble()
    if not self.editing_text then return end
    local sel = self:textEffectiveSel()
    if not sel or Text.selEmpty(sel) then return end
    local s = Text.plainRange(self.editing_text, sel)
    if s == "" then return end
    local inp = Device.input
    if inp and inp.setClipboardText then pcall(inp.setClipboardText, s) end
    if cut then
        self:textBreakCoalesce()
        self:textMark("delete")
        self.text_cur = Text.deleteRange(self.editing_text, sel)
        self.text_sel = nil
        self:textBreakCoalesce()
        self:afterTextEdit()
    else
        self:showNotice(_("Copied"))
    end
end

-- The bubble widget: a pill in the accent (black by default) with the
-- clipboard icon and "Paste". Built once and kept; only its position changes.
function InkAwayView:clipBubbleWidget()
    if self._clip_widget then return self._clip_widget end
    local a = Accent.get()
    local isz = math.max(16, math.floor((self._icon_sz or Screen:scaleBySize(28)) * 0.8))
    local file = self:pluginDir() .. "ink/icons/clipboard.svg"
    local tinted = Accent.icon(file, isz)
    local icon
    if tinted then
        icon = ImageWidget:new{ image = tinted, width = isz, height = isz, image_disposable = false }
    else
        icon = IconWidget:new{ file = file, width = isz, height = isz }
        icon.invert = true   -- renders on white; inverted it reads white on the black pill
    end
    local label = TextWidget:new{ text = _("Paste"), face = self:faceAt("cfont", math.floor(isz * 0.85)),
        fgcolor = a.text, bold = true }
    local pad = Screen:scaleBySize(10)
    local h = math.max(isz, label:getSize().h) + 2 * pad
    local row = HorizontalGroup:new{ align = "center", icon, HorizontalSpan:new{ width = pad }, label }
    if a.chromatic then
        -- a colour fill is the accent's cached image under the row
        local w = row:getSize().w + math.floor(pad * 1.6) + math.floor(pad * 1.8)
        local dimen = GeomUI:new{ w = w, h = h }
        self._clip_widget = OverlapGroup:new{ dimen = dimen, allow_mirroring = false,
            ImageWidget:new{ image = Accent.shape(w, h, math.floor(h / 2)), width = w, height = h,
                alpha = true, image_disposable = false },
            CenterContainer:new{ dimen = dimen, row } }
        return self._clip_widget
    end
    self._clip_widget = FrameContainer:new{
        background = a.fill, bordersize = 0, radius = math.floor(h / 2),
        padding = pad, padding_left = math.floor(pad * 1.6), padding_right = math.floor(pad * 1.8),
        margin = 0, row,
    }
    return self._clip_widget
end

-- Show the bubble just above screen point (sx, sy), kept inside the drawing area
-- and above the keyboard; below the finger when there is no room above.
function InkAwayView:showClipBubble(sx, sy)
    if not self.editing_text then return end
    self:hideClipBubble()
    local sz = self:clipBubbleWidget():getSize()
    local w, h = sz.w, sz.h
    local v = self.view
    local gap, lift = Screen:scaleBySize(8), Screen:scaleBySize(40)
    local x = math.floor(sx - w / 2)
    x = math.max(v.area_x + gap, math.min(v.area_x + v.area_w - w - gap, x))
    local bottom = math.min(v.area_y + v.area_h, self:keyboardTop()) - gap
    local y = sy - lift - h
    if y < v.area_y + gap then y = sy + lift end
    y = math.max(v.area_y + gap, math.min(bottom - h, y))
    self._clip_bubble = { x = x, y = y, w = w, h = h }
    UIManager:setDirty(self, "ui", GeomUI:new{ x = x, y = y, w = w, h = h })
end

function InkAwayView:hideClipBubble()
    local b = self._clip_bubble
    if not b then return end
    self._clip_bubble, self._clip_press = nil, nil
    if not self.closing then
        UIManager:setDirty(self, "ui", GeomUI:new{ x = b.x, y = b.y, w = b.w, h = b.h })
    end
end

function InkAwayView:inClipBubble(pos)
    local b = self._clip_bubble
    return b and pos and InkGeom.inRect(pos.x, pos.y, b) or false
end

-- A long press at `pos` while a box is being edited: offer to paste there. The
-- touch that began it has already put the caret under the finger.
function InkAwayView:textHoldAt(pos)
    if not (self.editing_text and pos) then return false end
    if self:textZone(pos.x, pos.y) ~= "inside" then return false end
    if self:textHasSel() then return false end   -- a selection gets the format menu
    if not self:clipboardText() then
        self:showNotice(_("The clipboard is empty."))
        return true
    end
    self:showClipBubble(pos.x, pos.y)
    return true
end

return InkAwayView
