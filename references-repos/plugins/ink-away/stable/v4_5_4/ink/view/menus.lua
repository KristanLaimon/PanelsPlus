--[[
The tool sheets: pen, eraser, shapes and line variants, fill colour and text,
and the colour picker and brush maker they open.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Brushes = require("ink/brushes")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Penset = require("ink/penset")
local EraserRing = require("ink/ui/eraserring")
local PenSample = require("ink/ui/pensample")
local SliderRow = require("ink/ui/controls").SliderRow
local Strip = require("ink/ui/strip")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
local HAIRLINE = Paint.HAIRLINE
local TILE_BG = Paint.TILE_BG
local CARET_BG = Paint.CARET_BG
local SHADES = Palette.SHADES
local COLORS = Palette.COLORS
local sameColor = Palette.sameColor

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
local function pxfmt(v) return v .. _(" px") end

local InkAwayView = {}

-- The reader's saved custom colours, a list of {r,g,b} kept in the settings.
function InkAwayView:getCustomColors()
    local list = self:getSetting("inkaway_custom_colors")
    return type(list) == "table" and list or {}
end

function InkAwayView:addCustomColor(rgb)
    local list = self:getCustomColors()
    for _, c in ipairs(list) do
        if sameColor(c, rgb) then return end  -- already saved
    end
    list[#list + 1] = { rgb[1], rgb[2], rgb[3] }
    while #list > 18 do table.remove(list, 1) end   -- 3 rows of 6, oldest drops out
    self:setSetting("inkaway_custom_colors", list)
end

function InkAwayView:removeCustomColor(rgb)
    local list = self:getCustomColors()
    for i, c in ipairs(list) do
        if sameColor(c, rgb) then table.remove(list, i); break end
    end
    self:setSetting("inkaway_custom_colors", list)
end

-- Open the colour wheel to pick (and optionally save) an exact pen colour.
function InkAwayView:openColorPicker()
    local ok, ColorPicker = pcall(require, "ink/ui/colorpicker")
    if not ok then return end
    local function apply(rgb)
        self.pen_color = { rgb[1], rgb[2], rgb[3] }
        self:penChanged("color", self.pen_color)
    end
    UIManager:show(ColorPicker:new{
        color = self.pen_color,
        on_pick = function(rgb) apply(rgb); self:openPenSettings() end,
        on_save = function(rgb) apply(rgb); self:addCustomColor(rgb); self:openPenSettings() end,
    })
end

-- Open the brush maker. A saved brush becomes the current pen and stays in the
-- pen menu (it is kept in KOReader's settings, so it survives plugin updates).
function InkAwayView:openBrushMaker()
    local ok, BrushMaker = pcall(require, "ink/ui/brushmaker")
    if not ok then return end
    local maker = BrushMaker:new{
        params = Brushes.defaults(),
        prompt = function(o) self:promptText(o) end,   -- (the name, asked in Ink Away's own sheet)
        on_save = function(name, params)
            local key = Brushes.save(
                function(k) return self:getSetting(k) end,
                function(k, val) self:setSetting(k, val) end,
                name, params)
            self:choosePenType(key)
            self:openPenSettings()
        end,
    }
    UIManager:show(maker)
end

function InkAwayView:confirmDeleteBrush(key, label)
    self:ask{
        title = string.format(_("Delete the brush \u{201C}%s\u{201D}?"), label),
        ok_text = _("Delete"), ok_icon = "trash",
        on_ok = function()
            local name = key:gsub("^user:", "")
            Brushes.remove(function(k) return self:getSetting(k) end,
                           function(k, v) self:setSetting(k, v) end, name)
            if self.pen_style == key then self:choosePenType("solid") end
            local case = self:penset()
            case.types[key] = nil
            for i = #case.favs, 1, -1 do
                if case.favs[i].style == key then Penset.removeFav(case, i) end
            end
            self:savePens()
            self:openPenSettings()
        end,
    }
end

-- A w x h picture of the eraser, `d` screen pixels across, clearing a line of
-- ink, with the outline it shows while erasing: its true shape and size.
function InkAwayView:eraserSample(w, h, d)
    local bb = PenSample.render({ width = 1 }, w, h, math.max(2, Screen:scaleBySize(5)))
    EraserRing.paint(bb, w / 2, h / 2, d / 2, true)
    return bb
end

-- The eraser sheet: the eraser at its real size, a size slider, the Erase
-- pictures and Erase whole strokes toggles, and Protect text from eraser.
function InkAwayView:openEraserSettings()
    if self:rebuildSheet("_eraser_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_eraser_dialog") end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Eraser"), content_w, _("Done"), closeSelf))
        add(vspan(12))
        -- the eraser at its real size on screen (at this zoom), as its outline
        -- shows while erasing; one too big for the strip is shown smaller
        local strip = Strip:new{ w = content_w - 2 * Screen:scaleBySize(3), h = Screen:scaleBySize(96) }
        local function preview()
            local zoom = (self.view and self.view.zoom) or 1
            local real = math.max(1, self.eraser_width * zoom)
            local shown = math.min(real, strip.h - Screen:scaleBySize(8))
            strip.note = shown < real and string.format(_("shown at %d%%"), math.floor(shown / real * 100 + 0.5)) or nil
            strip:setImage(self:eraserSample(strip.w, strip.h, shown))
        end
        preview()
        add(FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = HAIRLINE, radius = Screen:scaleBySize(10),
            padding = Screen:scaleBySize(2), margin = 0, background = WHITE, strip })
        add(vspan(10))
        add(SliderRow:new{ label = _("Size"), value = self.eraser_width, min = 4, max = 120,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v)
                self.eraser_width = math.max(1, v)
                preview()
                if strip.dimen then UIManager:setDirty(menu, "fast", strip.dimen) end
            end })
        add(vspan(14))
        local pictures = ToggleRow:new{ label = _("Erase pictures"), is_on = self.erase_bg,
            compact = true, parent = menu,
            callback = function(on) self.erase_bg = on; self:setSetting("inkaway_erase_bg", on) end }
        local whole = ToggleRow:new{ label = _("Erase whole strokes"), is_on = self.erase_whole,
            compact = true, parent = menu,
            callback = function(on) self.erase_whole = on; self:setSetting("inkaway_erase_whole", on) end }
        add(HorizontalGroup:new{ align = "center", pictures,
            HorizontalSpan:new{ width = math.max(Screen:scaleBySize(16), content_w - pictures.width - whole.width) },
            whole })
        add(vspan(10))
        add(ToggleRow:new{ label = _("Show the eraser while erasing"), is_on = self.eraser_outline,
            width = content_w, parent = menu,
            callback = function(on)
                self.eraser_outline = on; self:setSetting("inkaway_eraser_outline", on)
                if not on then self:eraserCursorOff() end
            end })
        add(vspan(10))
        -- the same setting as in the Text sheet, here too since it is the eraser's
        add(ToggleRow:new{ label = _("Protect text from eraser"), is_on = self.text_erase_protect,
            width = content_w, parent = menu,
            callback = function(on)
                self.text_erase_protect = on; self:setSetting("inkaway_text_erase_protect", on)
            end })
        return content
    end
    self:showSheet("_eraser_dialog", build)
end

-- Arrowhead size, in canvas pixels (used by the arrow shapes).
function InkAwayView:openArrowSize()
    self:askNumber{
        title = _("Arrowhead size"),
        note = _("How big the arrowheads are, in canvas pixels."),
        label = _("Size"), value = self.arrow_head, min = 6, max = 120, step = 2,
        format = function(v) return string.format("%d %s", v, _("px")) end,
        on_done = function(v)
            self.arrow_head = math.max(4, math.floor(v))
            self:setSetting("inkaway_arrow_head", self.arrow_head)
            self:openShapeLineMenu()
        end,
    }
end

-- The Shapes sheet: large shape tiles (a caret in the Line tile's corner opens
-- the line variants), smaller paint bucket and lasso tiles, and the fill and snap
-- toggles. Icons keep their transparency so the tile colour shows through; the
-- selected tile is black with the icon inverted to white.
function InkAwayView:openShapePicker()
    self:flushShape()
    if self:rebuildSheet("_shape_dialog") then return end
    self:ensureUserIcons()

    -- four square tiles fill a row with equal gaps; the content width comes from
    -- the tile size so everything lines up with the panel padding
    local content_w, gap, tileW = self:sheetWidth()
    local isz = math.floor(tileW * 0.60)   -- big icon inside the tile
    local closeSelf = function() self:closeSheet("_shape_dialog") end

    -- the Line tile: a select button (a plain line) with a small caret button in
    -- its bottom right corner that opens the variants
    local function lineTile(sel)
        local select_btn = self:makeTile("sh_line", tileW, tileW, isz, sel, function()
            self:flushShape(); self.shape, self.shape_arrow = "line", nil
            self:refreshToolLabels(); self:openShapePicker()
        end)
        local caretW = Screen:scaleBySize(30)
        local inset = Screen:scaleBySize(5)
        local caretIsz = caretW - Screen:scaleBySize(8)
        local caret_btn = Button:new{ icon = "inkaway.caret", icon_width = caretIsz, icon_height = caretIsz,
            width = caretW, height = caretW,
            bordersize = 0, radius = Screen:scaleBySize(8), background = CARET_BG,
            margin = 0, padding = 0, show_parent = self,
            callback = function() self:openShapeLineMenu() end,
            overlap_offset = { tileW - caretW - inset, tileW - caretW - inset } }
        local cw = self:tileIcon("caret", caretIsz, false)
        if cw then self:setButtonLabel(caret_btn, cw) end
        -- the caret is child 1, so events reach its corner first and anything
        -- else falls through to the select button; paintTo draws in reverse so
        -- the caret stays on top
        local og = OverlapGroup:new{ dimen = { w = tileW, h = tileW },
            allow_mirroring = false, caret_btn, select_btn }
        function og:paintTo(bb, x, y)   -- luacheck: ignore 432
            for i = #self, 1, -1 do
                local w = self[i]
                if w.overlap_offset then
                    w:paintTo(bb, x + w.overlap_offset[1], y + w.overlap_offset[2])
                else
                    w:paintTo(bb, x, y)
                end
            end
        end
        return og
    end

    local function shapeTile(name, shape)
        return self:makeTile(name, tileW, tileW, isz, self.shape == shape, function()
            self:flushShape(); self.shape, self.shape_arrow = shape, nil
            self:refreshToolLabels(); self:openShapePicker()
        end)
    end

    -- built inside the build callback so the toggles can use the menu as their
    -- repaint parent
    local build = function(menu)
        -- the tiles show the current selection, so they are rebuilt on every
        -- rebuild
        local lineSel = (self.shape == "line" or self.shape == "curve")
        local shapeRow = HorizontalGroup:new{ align = "center",
            lineTile(lineSel), HorizontalSpan:new{ width = gap },
            shapeTile("sh_rect", "rect"), HorizontalSpan:new{ width = gap },
            shapeTile("sh_ellipse", "ellipse"), HorizontalSpan:new{ width = gap },
            shapeTile("sh_triangle", "triangle"),
        }
        -- the paint bucket, a wide tile with a label (the lasso has its own
        -- toolbar button)
        local toolH = Screen:scaleBySize(80)
        local toolIsz = Screen:scaleBySize(36)
        local toolRow = self:makeTile("bucket", content_w, toolH, toolIsz, self.tool == "fill", function()
                self:flushShape(); self.tool = "fill"; self:refreshToolLabels()
                closeSelf()
            end, _("Paint bucket"), _("hold to pick colour"), function() self:openFillColor() end)
        -- three compact toggles (switch right after its label) spread across one row
        local function toggle(label, on, cb)
            return ToggleRow:new{ label = label, is_on = on, compact = true, parent = menu, callback = cb }
        end
        local fillRow = toggle(_("Fill"), self.shape_fill, function(on)
            self.shape_fill = on end)
        local gridRow = toggle(_("Snap to grid"), self.snap_grid, function(on)
            self.snap_grid = on; self:setSetting("inkaway_snap_grid", on) end)
        local snap45Row = toggle(_("Snap to 45\u{00B0}"), self.snap_angle, function(on)
            self.snap_angle = on; self:setSetting("inkaway_snap_angle", on) end)
        if self.reader_mode then
            -- over a book: no grid to snap to, nothing to pour paint into, and the
            -- lasso has its own button
            local slack = math.max(Screen:scaleBySize(16), content_w - fillRow.width - snap45Row.width)
            return VerticalGroup:new{ align = "left",
                self:sheetTitle(_("Shapes"), content_w, _("Done"), closeSelf), vspan(16),
                shapeRow, vspan(16),
                HorizontalGroup:new{ align = "center", fillRow, HorizontalSpan:new{ width = slack }, snap45Row },
            }
        end
        local totalW = fillRow.width + gridRow.width + snap45Row.width
        local slack = math.max(Screen:scaleBySize(16), math.floor((content_w - totalW) / 2))
        local togglesRow = HorizontalGroup:new{ align = "center",
            fillRow, HorizontalSpan:new{ width = slack },
            gridRow, HorizontalSpan:new{ width = slack },
            snap45Row }
        return VerticalGroup:new{ align = "left",
            self:sheetTitle(_("Shapes"), content_w, _("Done"), closeSelf), vspan(16),
            shapeRow, vspan(16),
            togglesRow, vspan(16),
            toolRow,
        }
    end
    self:showSheet("_shape_dialog", build)
end

-- The line, arrow and curve variants, opened from the Line tile: two rows of
-- three smaller tiles (straight and curved), the arrowhead size and a Back pill.
function InkAwayView:openShapeLineMenu()
    -- no rebuild in place: every button here closes the sheet
    self:closeSheet("_shape_dialog")
    self:closeSheet("_shape_line_dialog")
    self:ensureUserIcons()

    local gap, parentTileW = select(2, self:sheetWidth())
    local tileW = math.floor(parentTileW * 0.78)   -- smaller than the parent's tiles
    local isz = math.floor(tileW * 0.60)
    local content_w = 3 * tileW + 2 * gap
    local closeSelf = function() self:closeSheet("_shape_line_dialog") end

    local function isSel(shape, arrow)
        return self.shape == shape and (self.shape_arrow or false) == (arrow or false)
    end
    local function pick(shape, arrow)
        return function()
            self:flushShape(); self.shape, self.shape_arrow = shape, arrow
            self:refreshToolLabels()
            closeSelf()
            self:openShapePicker()
        end
    end
    local function tile(name, shape, arrow)
        return self:makeTile(name, tileW, tileW, isz, isSel(shape, arrow), pick(shape, arrow))
    end

    local row1 = HorizontalGroup:new{ align = "center",
        tile("sh_line", "line", nil), HorizontalSpan:new{ width = gap },
        tile("sh_arrow", "line", "end"), HorizontalSpan:new{ width = gap },
        tile("sh_darrow", "line", "both") }
    local row2 = HorizontalGroup:new{ align = "center",
        tile("sh_curve", "curve", nil), HorizontalSpan:new{ width = gap },
        tile("sh_carrow", "curve", "end"), HorizontalSpan:new{ width = gap },
        tile("sh_cdarrow", "curve", "both") }

    -- arrowhead size: a full-width text button
    local ahRow = Button:new{ text = string.format(_("Arrowhead size: %d px"), self.arrow_head),
        width = content_w, height = Screen:scaleBySize(48), bordersize = 0,
        radius = Screen:scaleBySize(14), background = TILE_BG, margin = 0, padding = 0,
        text_font_size = 17, show_parent = self,
        callback = function() closeSelf(); self:openArrowSize() end }

    local build = function()
        return VerticalGroup:new{ align = "left",
            self:sheetTitle(_("Line / arrow / curve"), content_w, _("Back"),
                function() closeSelf(); self:openShapePicker() end, 20), vspan(16),
            row1, vspan(gap),
            row2, vspan(16),
            ahRow,
        }
    end
    self:showSheet("_shape_line_dialog", build)
end

-- The paint bucket's colour sheet (hold the Paint bucket tile): swatch rows (the
-- shades, plus colours on a colour screen) and an opacity slider.
function InkAwayView:openFillColor()
    if self:rebuildSheet("_fill_dialog") then return end
    self:closeSheet("_shape_dialog")
    self:ensureUserIcons()

    local content_w, gap, sw = self:sheetWidth(6)   -- 6 swatches per row (colours)

    -- one swatch: a rounded colour tile; the current colour gets a black ring,
    -- the others a hairline
    local function swatch(e)
        local selected = sameColor(self.fill_color, e.rgb)
        local inner = sw - Screen:scaleBySize(8)
        local btn = self:colourTileButton(e.rgb, inner, inner, Screen:scaleBySize(12),
            function() self.fill_color = { e.rgb[1], e.rgb[2], e.rgb[3] }; self:openFillColor() end)
        return FrameContainer:new{
            bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
            color = selected and BLACK or HAIRLINE,
            radius = Screen:scaleBySize(15),
            padding = selected and Screen:scaleBySize(1) or Screen:scaleBySize(3),
            margin = 0, btn }
    end
    local function swatchRow(entries)
        local row = HorizontalGroup:new{ align = "center" }
        for i, e in ipairs(entries) do
            if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, swatch(e))
        end
        return row
    end

    -- opacity, built inside build() so the shown menu is its repaint parent
    local build = function(menu)
        local pct = math.floor(self.fill_alpha / 255 * 100 + 0.5)
        local opacity = SliderRow:new{ label = _("Opacity"), value = pct, width = content_w, parent = menu,
            on_set = function(v) self.fill_alpha = math.floor(v / 100 * 255 + 0.5) end }
        local content = VerticalGroup:new{ align = "center" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Fill colour"), content_w, _("Done"), function() self:closeSheet("_fill_dialog") end))
        add(vspan(16))
        add(swatchRow(SHADES))
        if self:colorScreen() then
            add(vspan(gap))
            add(swatchRow(COLORS))
        end
        add(vspan(18))
        add(opacity)
        return content
    end
    self:showSheet("_fill_dialog", build)
end

-- The text sheet: font chooser, a size slider, the snap and eraser-protect
-- toggles, and Convert to text's online service (ink/view/ocrapi.lua).
function InkAwayView:openTextSettings()
    if self:rebuildSheet("_text_settings") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_text_settings") end
    local build = function(menu)
        local size = self.text_size or math.max(16, math.floor(self.view.canvas_w / 32))
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Text"), content_w, _("Done"), closeSelf))
        add(vspan(16))
        add(self:actionButton(string.format(_("Font: %s"), self:textFontDisplay()), content_w,
            function() closeSelf(); self:openTextFont() end))
        add(vspan(12))
        add(SliderRow:new{ label = _("Font size"), value = size, min = 10, max = 96,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.text_size = v; self:setSetting("inkaway_text_size", v) end })
        add(vspan(14))
        if not self.reader_mode then   -- a book's page has no ruling
            add(ToggleRow:new{ label = _("Snap lines to ruling"), is_on = self.text_grid_snap,
                width = content_w, parent = menu,
                callback = function(on)
                    self.text_grid_snap = on; self:setSetting("inkaway_text_grid_snap", on)
                    if self.editing_text then
                        self.editing_text.grid_snap = on
                        if on then self:snapTextBoxToGrid(self.editing_text) end
                        self:invalidateLayout(); self:refreshTextBox("flashui")
                    end
                end })
            add(vspan(10))
        end
        add(ToggleRow:new{ label = _("Protect text from eraser"), is_on = self.text_erase_protect,
            width = content_w, parent = menu,
            callback = function(on)
                self.text_erase_protect = on; self:setSetting("inkaway_text_erase_protect", on)
            end })
        add(vspan(10))
        self:addOcrApiRows(add, menu, content_w)
        return content
    end
    self:showSheet("_text_settings", build)
end

return InkAwayView
