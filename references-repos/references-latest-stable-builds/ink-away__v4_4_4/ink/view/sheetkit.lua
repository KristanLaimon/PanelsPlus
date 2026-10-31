--[[
Building blocks shared by the sheets: opening and closing them, title row,
buttons, icon tiles, colour swatches and brush samples (cached while the canvas
is open). What is filled black by default takes the accent (see ink/accent.lua).
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Accent = require("ink/accent")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Raster = require("ink/raster")
local IconMenu = require("ink/ui/iconmenu")
local Theme = require("ink/ui/theme")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local BLACK = Blitbuffer.COLOR_BLACK
local LABEL = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF)   -- section headings
local HINT = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF)    -- explanations under a control
local TILE_BG = Paint.TILE_BG
local sameColor = Palette.sameColor
local uiFill = Paint.uiFill
local isChromatic = Paint.isChromatic

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

-- A cached image as a Button label. The cache owns the buffer, so the widget must
-- not free it, and fgcolor must be set: Button's tap highlight inverts
-- label_widget.fgcolor whenever `text` is set (ours is ""), and a nil one crashes.
local function imageLabel(bb, w, h)
    return ImageWidget:new{ image = bb, width = w, height = h,
        image_disposable = false, fgcolor = BLACK }
end

local InkAwayView = {}

-- One row of colour swatches. Each is a coloured button; the selected one gets
-- a thick border so it reads on any shade (a checkmark would vanish on a dark
-- swatch). `current` is the rgb to mark; `onpick(rgb)` is called on a tap.
function InkAwayView:swatchRowFor(entries, current, onpick)
    local sw = math.floor(math.min(self.screen_w, self.screen_h) * 0.9 / 6)
    local row = {}
    for _, e in ipairs(entries) do
        local selected = sameColor(current, e.rgb)
        row[#row + 1] = {
            text = "",
            background = uiFill(e.rgb),
            width = sw,
            bordersize = selected and Size.border.thick or Size.border.default,
            radius = 0,
            callback = function() onpick(e.rgb) end,
        }
    end
    return row
end

-- Where a tool sheet's top should sit: just under the toolbar, so its options
-- open right where the hand tapped (falls back to a small margin if unknown).
-- Where sheets may go across: nil centres them on the screen; a mode with a
-- toolbar down a side keeps them beside it.
function InkAwayView:sheetLeftX()
    if self._toolbar_hidden or self._vb_side ~= "left" then return nil end
    return self._vb_thick
end
function InkAwayView:sheetRightX()
    if self._toolbar_hidden or self._vb_side ~= "right" then return nil end
    return self.screen_w - (self._vb_thick or 0)
end
function InkAwayView:sheetBottomY() return nil end   -- (a toolbar along the bottom, over a book)

function InkAwayView:sheetTopY()
    return (self._bar_h or 0) + Screen:scaleBySize(6)
end

-- The width of a sheet's content: `cols` equal columns (four by default) and the
-- gaps between them, about 84% of the screen's short side. Returns the width, the
-- gap and the column width.
function InkAwayView:sheetWidth(cols)
    cols = cols or 4
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    -- beside a toolbar down the left side, narrow enough to fit next to it (the
    -- sheet's frame adds its padding and border on each side, see IconMenu)
    local left, right = self:sheetLeftX(), self:sheetRightX()
    if left or right then
        local frame = 2 * (Screen:scaleBySize(18) + Size.border.window) + 2 * Screen:scaleBySize(4)
        -- (and the arrow column a long sheet scrolls with, see ink/ui/arrowscroll.lua)
        frame = frame + require("ink/ui/arrowscroll").extraWidth()
        target = math.min(target, (right or Screen:getWidth()) - (left or 0) - frame - 2)
    end
    local col = math.floor((target - (cols - 1) * gap) / cols)
    return cols * col + (cols - 1) * gap, gap, col
end

-- Show a sheet (an IconMenu) and keep it in self[field] while it is open. It
-- hangs from the toolbar unless opts.bottom_y pins its bottom edge there, or
-- from the top always with opts.top (clear of the keyboard); opts.on_close runs
-- when a tap outside it or Back closes it, opts.on_closed however it closes;
-- with opts.keep_open a tap outside leaves it open.
function InkAwayView:showSheet(field, build, opts)
    opts = opts or {}
    -- every field a sheet was shown in, so closing the view closes them all
    self._sheet_fields = self._sheet_fields or {}
    self._sheet_fields[field] = true
    local bottom_y = not opts.top and (opts.bottom_y or self:sheetBottomY()) or nil
    self[field] = IconMenu:new{ build = build, flash = not self:colourPanel(),
        -- (at the top over a book whose toolbar is along the bottom: from the very top)
        top_y = not bottom_y and ((opts.top and self:sheetBottomY()) and Screen:scaleBySize(6) or self:sheetTopY())
            or nil, bottom_y = bottom_y,
        left_x = self:sheetLeftX(), right_x = self:sheetRightX(),
        on_uncover = function() self:uncovered() end,
        on_close = function()
            self[field] = nil
            if opts.on_close then opts.on_close() end
        end,
        on_closed = opts.on_closed, keep_open = opts.keep_open }
    UIManager:show(self[field])
end

-- Close the sheet kept in self[field], if one is open.
function InkAwayView:closeSheet(field)
    if self[field] then UIManager:close(self[field]); self[field] = nil end
end

-- Rebuild the sheet in self[field] in place. Returns false, after closing
-- whatever else the field holds, when there is no sheet to rebuild.
function InkAwayView:rebuildSheet(field)
    local sheet = self[field]
    if sheet and sheet.rebuild then sheet:rebuild(); return true end
    self:closeSheet(field)
    return false
end

-- Show `widget` in place of a Button's own label.
function InkAwayView:setButtonLabel(button, widget)
    if button.label_container then
        button.label_widget = widget; button.label_container[1] = widget
    end
end

-- A Button filled with a colour accent, `content` centred on it. The fill is the
-- accent's cached image (a rounded colour fill is slow to paint), so it is built
-- as an icon button: the tap highlight then inverts the whole button instead of
-- reading a label colour.
function InkAwayView:accentButton(w, h, radius, content, cb, hold_cb)
    local b = Button:new{ icon = "inkaway.pen", icon_width = 1, icon_height = 1,
        width = w, height = h, bordersize = 0, radius = radius, background = WHITE,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    local dimen = Geom:new{ w = w, h = h }
    self:setButtonLabel(b, OverlapGroup:new{ dimen = dimen, allow_mirroring = false,
        ImageWidget:new{ image = Accent.shape(w, h, radius), width = w, height = h, alpha = true,
            image_disposable = false },
        CenterContainer:new{ dimen = dimen, content } })
    return Theme.keep(b, radius)   -- the theme colour stays itself in dark
end

-- Path of a bundled icon.
function InkAwayView:iconPath(name)
    return self:pluginDir() .. "ink/icons/" .. name .. ".svg"
end

-- A tile's icon: transparent (the tile colour shows through), or when selected
-- in the colour that reads on the accent: drawn on it when the accent is a
-- chosen one, else flattened on white and inverted, so it reads white on black.
function InkAwayView:tileIcon(name, size, sel)
    if sel then
        local bb = Accent.icon(self:iconPath(name), size)
        if bb then return imageLabel(bb, bb:getWidth(), bb:getHeight()) end
    end
    local ok, w = pcall(function()
        if sel then
            return IconWidget:new{ file = self:iconPath(name), width = size, height = size,
                alpha = false, invert = true }
        end
        return IconWidget:new{ file = self:iconPath(name), width = size, height = size, alpha = true }
    end)
    return ok and w or nil
end

-- A rounded tile button with an icon, optionally above a label and a small grey
-- sublabel; `hold_cb` adds a long-press action. It is built as an icon Button
-- (`text` stays nil, so the tap highlight inverts rather than reading a fgcolor
-- the icon lacks), then the transparent icon is swapped in.
function InkAwayView:makeTile(name, w, h, size, sel, cb, label, sublabel, hold_cb)
    local a = Accent.get()
    local iw = self:tileIcon(name, size, sel)
    if iw and label then
        local vg = VerticalGroup:new{ align = "center", iw, vspan(6),
            TextWidget:new{ text = label, face = Font:getFace("cfont", 15),
                bold = true, fgcolor = sel and a.text or BLACK } }
        if sublabel then
            table.insert(vg, vspan(3))
            table.insert(vg, TextWidget:new{ text = sublabel, face = Font:getFace("cfont", 11),
                fgcolor = sel and a.note or HINT })
        end
        iw = vg
    end
    if sel and a.chromatic and iw then
        return self:accentButton(w, h, Screen:scaleBySize(16), iw, cb, hold_cb)
    end
    local b = Button:new{ icon = "inkaway." .. name, icon_width = size, icon_height = size,
        width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(16), background = sel and a.fill or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    if iw then self:setButtonLabel(b, iw) end
    return b
end

-- A wide action tile for a main choice: a black button with a white icon on the
-- left, a bold title and a small note under it; `hold_cb` adds a long-press
-- action (the note can say so).
function InkAwayView:actionTile(icon, title, note, w, cb, hold_cb)
    local a = Accent.get()
    local h = Screen:scaleBySize(76)
    local isz = Screen:scaleBySize(34)
    local pad = Screen:scaleBySize(20)
    local texts = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = title, face = Font:getFace("cfont", 20), bold = true, fgcolor = a.text,
            max_width = w - 3 * pad - isz },
        vspan(2),
        TextWidget:new{ text = note, face = Font:getFace("cfont", 13),
            fgcolor = a.note, max_width = w - 3 * pad - isz } }
    local iw = self:tileIcon(icon, isz, true) or HorizontalSpan:new{ width = isz }
    -- left aligned: the trailing span fills the rest of the tile
    local used = pad + isz + pad + texts:getSize().w
    local row = HorizontalGroup:new{ align = "center",
        HorizontalSpan:new{ width = pad }, iw, HorizontalSpan:new{ width = pad }, texts,
        HorizontalSpan:new{ width = math.max(0, w - used) } }
    if a.chromatic then return self:accentButton(w, h, Screen:scaleBySize(16), row, cb, hold_cb) end
    local b = Button:new{ icon = "inkaway." .. icon, icon_width = 1, icon_height = 1,
        width = w, height = h, bordersize = 0, radius = Screen:scaleBySize(16), background = a.fill,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    self:setButtonLabel(b, row)
    return b
end

-- A paper tile: a small page drawn with the paper's ruling and its name under
-- it; the selected one is black. Cached, as the papers never change.
function InkAwayView:paperTile(style, label, w, h, sel, cb)
    local a = Accent.get()
    local label_h = Screen:scaleBySize(26)
    local ph = h - label_h - Screen:scaleBySize(18)
    local pw = math.floor(ph * 0.75)
    if pw > w - Screen:scaleBySize(16) then
        pw = w - Screen:scaleBySize(16); ph = math.floor(pw / 0.75)
    end
    local ok, page = pcall(function() return self:cachedPaperPreview(style, pw, ph) end)
    -- fgcolor is set for the tap highlight, which inverts it on a text button
    -- (see imageLabel); the group itself draws nothing with it
    local vg = VerticalGroup:new{ align = "center", fgcolor = sel and a.text or BLACK }
    if ok and page then table.insert(vg, Theme.keep(imageLabel(page, pw, ph))) end   -- the paper itself
    table.insert(vg, vspan(4))
    table.insert(vg, TextWidget:new{ text = label, face = Font:getFace("cfont", 15), bold = true,
        fgcolor = sel and a.text or BLACK })
    if sel and a.chromatic then return self:accentButton(w, h, Screen:scaleBySize(14), vg, cb) end
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(14), background = sel and a.fill or TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = self }
    self:setButtonLabel(b, vg)
    return b
end

function InkAwayView:cachedPaperPreview(style, w, h)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    -- on the notebook's paper colour (a new one's when there is none open)
    local paper = (self.notebook and self:paperRGB() or self:defaultPaper()) or { 255, 255, 255 }
    local id = table.concat({ "paper", style, w, h, Screen.bb:getType(), paper[1], paper[2], paper[3] }, "|")
    local e = cache[id]
    if e then return e.bb end
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    Paint.paintPaper(bb, w, h, { style = style, size = math.max(6, math.floor(h / 9)), strength = 70,
        paper = Palette.paperRGB(paper) }, nil)
    Paint.outline(bb, 0, 0, w, h, HINT, 1)
    cache[id] = { bb = bb }
    return bb
end

-- Title row shared by every tool sheet: the sheet title on the left (cut short
-- with an ellipsis when long) and a filled black pill (Done / Back) on the
-- right, spanning content_w.
function InkAwayView:sheetTitle(title, content_w, pill_label, pill_cb, title_size, extra)
    local a = Accent.get()
    local pill_w = Screen:scaleBySize(84)
    local pill_h = Screen:scaleBySize(34)
    local gap = Screen:scaleBySize(8)
    -- `extra`: plain grey pills before the main one, each { label = , cb = } or
    -- { icon = , cb = } (a small square one): the guide, the appearance
    local extras, extras_w = {}, 0
    if extra then
        for _i, e in ipairs(extra[1] and extra or { extra }) do
            local w = e.icon and pill_h or pill_w
            local b = Button:new{ text = "", width = w, height = pill_h, bordersize = 0,
                radius = Screen:scaleBySize(11), background = TILE_BG, margin = 0, padding = 0,
                callback = e.cb, show_parent = self }
            local lbl = e.icon and self:tileIcon(e.icon, math.floor(pill_h * 0.62))
            if lbl then
                -- fgcolor is set for the tap highlight, which inverts a text button's label
                self:setButtonLabel(b, CenterContainer:new{ dimen = Geom:new{ w = w, h = pill_h }, fgcolor = BLACK, lbl })
            else
                self:setButtonLabel(b, TextWidget:new{ text = e.label or "", face = Font:getFace("cfont", 15),
                    bold = true, fgcolor = BLACK })
            end
            extras[#extras + 1] = b
            extras_w = extras_w + w + gap
        end
    end
    local titleW = TextWidget:new{ text = title, face = Font:getFace("cfont", title_size or 22), bold = true,
        max_width = content_w - pill_w - gap - extras_w }
    local text = TextWidget:new{ text = pill_label or _("Done"), face = Font:getFace("cfont", 15),
        bold = true, fgcolor = a.text }
    local pill
    if a.chromatic then
        pill = self:accentButton(pill_w, pill_h, Screen:scaleBySize(11), text, pill_cb)
    else
        pill = Button:new{ text = "", width = pill_w, height = pill_h,
            bordersize = 0, radius = Screen:scaleBySize(11), background = a.fill, margin = 0, padding = 0,
            callback = pill_cb, show_parent = self }
        self:setButtonLabel(pill, text)
    end
    local g = content_w - titleW:getSize().w - pill:getSize().w - extras_w
    local row = HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(gap, g) } }
    for _i, b in ipairs(extras) do
        row[#row + 1] = b
        row[#row + 1] = HorizontalSpan:new{ width = gap }
    end
    row[#row + 1] = pill
    return row
end

-- A small grey line of text in a sheet; a section heading when `bold`.
function InkAwayView:sheetLabel(text, bold)
    return TextWidget:new{ text = text, face = Font:getFace("cfont", 15), bold = bold, fgcolor = LABEL }
end

-- A grey explanation under a control, wrapped to `width`.
function InkAwayView:sheetHint(text, width, size)
    return TextBoxWidget:new{ text = text, width = width, face = Font:getFace("cfont", size or 13),
        fgcolor = HINT }
end

-- A rounded action button of any width, grey by default and in the accent
-- (black unless the reader chose a colour) when `dark`. `size` "small" makes a
-- compact one (the selection's menu); true a primary action (New drawing, New
-- notebook) with a larger face. `icon` (a name in ink/icons) goes before the
-- label, so a button reads at a glance.
function InkAwayView:actionButton(label, w, cb, dark, size, icon)
    local a = Accent.get()
    local small = size == "small"
    local h = Screen:scaleBySize(small and 40 or 48)
    local radius = Screen:scaleBySize(small and 12 or 14)
    local isz, igap = Screen:scaleBySize(small and 18 or 20), Screen:scaleBySize(10)
    local iw = icon and self:tileIcon(icon, isz, dark)
    local text = TextWidget:new{ text = label, face = Font:getFace("cfont", small and 15 or (size and 20 or 17)),
        bold = true, fgcolor = dark and a.text or BLACK,
        max_width = w - Screen:scaleBySize(8) - (iw and isz + igap or 0) }
    local content = text
    if iw then
        -- (fgcolor: a text Button's tap highlight inverts its label's colour)
        content = HorizontalGroup:new{ align = "center", fgcolor = text.fgcolor,
            iw, HorizontalSpan:new{ width = igap }, text }
    end
    if dark and a.chromatic then return self:accentButton(w, h, radius, content, cb) end
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0,
        radius = radius, background = dark and a.fill or TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = self }
    self:setButtonLabel(b, content)
    return b
end

-- A wide row to open something from a list (a search result, an entry of a
-- notebook's contents): a grey rounded button with an icon on the left, a bold
-- title and small grey lines under it (`notes`, each cut short to fit).
function InkAwayView:listRow(icon, title, notes, w, cb, hold_cb)
    local S = function(px) return Screen:scaleBySize(px) end
    local pad, isz = S(14), S(26)
    local tw = w - 3 * pad - isz
    local texts = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = title, face = Font:getFace("cfont", 17), bold = true, max_width = tw } }
    for _, note in ipairs(notes or {}) do
        table.insert(texts, VerticalSpan:new{ width = S(2) })
        table.insert(texts, TextWidget:new{ text = note, face = Font:getFace("cfont", 13), fgcolor = HINT,
            max_width = tw })
    end
    local iw = (icon and self:tileIcon(icon, isz, false)) or HorizontalSpan:new{ width = isz }
    local used = pad + isz + pad + texts:getSize().w
    -- fgcolor is set for the tap highlight (see imageLabel)
    local row = HorizontalGroup:new{ align = "center", fgcolor = BLACK,
        HorizontalSpan:new{ width = pad }, iw, HorizontalSpan:new{ width = pad }, texts,
        HorizontalSpan:new{ width = math.max(0, w - used) } }
    local b = Button:new{ text = "", width = w, height = math.max(S(56), texts:getSize().h + S(20)),
        bordersize = 0, radius = S(14), background = TILE_BG, margin = 0, padding = 0,
        callback = cb, hold_callback = hold_cb, show_parent = self }
    self:setButtonLabel(b, row)
    return b
end

-- How many list rows (listRow with two grey lines, `gap` apart) a sheet of
-- width `w` holds under the toolbar, besides a title, a line of text, the page
-- arrows and a row of buttons, inside the sheet's frame.
function InkAwayView:listRowsFit(w, gap)
    local S = function(px) return Screen:scaleBySize(px) end
    local function h(widget)
        local ok, sz = pcall(widget.getSize, widget)
        return ok and sz and sz.h or 0
    end
    local row_h = h(self:listRow("file", "M", { "M", "M" }, w, function() end)) + gap
    local fixed = h(self:sheetTitle("M", w, _("Close"), function() end)) + S(6)
        + h(self:sheetLabel("M")) + gap + S(48) + S(14) + S(48)
    local room = Screen:getHeight() - self:sheetTopY() - 2 * (S(18) + S(4)) - S(8)
    local per = row_h > gap and math.floor((room - fixed) / row_h) or 6
    return math.max(2, math.min(10, per))
end

-- Arrows either side of "2 / 3" across `w`, for a sheet whose content comes in
-- pages (0-based `page` of `pages`); a tap on an arrow calls on_turn(-1) or
-- on_turn(1).
function InkAwayView:pagerRow(page, pages, w, gap, on_turn)
    IconMenu.pager(on_turn)   -- (the page turn buttons turn it too)
    local aw = math.floor(w / 4)
    local label = TextWidget:new{ text = string.format("%d / %d", page + 1, pages),
        face = Font:getFace("cfont", 17), bold = true }
    local mid = w - 2 * aw - 2 * gap
    return HorizontalGroup:new{ align = "center",
        self:actionButton("\u{2039}", aw, function() on_turn(-1) end),
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{ dimen = Geom:new{ w = mid, h = Screen:scaleBySize(48) }, label },
        HorizontalSpan:new{ width = gap },
        self:actionButton("\u{203A}", aw, function() on_turn(1) end) }
end

-- A sheet of actions: a title with a Close pill, a note, then `rows`, each a
-- list of { label, callback[, dark], icon = name } laid out side by side.
-- Every action closes the sheet first.
function InkAwayView:openActionSheet(field, title, note, rows)
    self:closeSheet(field)
    local content_w, gap = self:sheetWidth()
    local closeSelf = function() self:closeSheet(field) end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(title, content_w, _("Close"), closeSelf))
        if note then
            add(VerticalSpan:new{ width = Screen:scaleBySize(6) })
            add(self:sheetLabel(note))
        end
        for _, row in ipairs(rows) do
            add(VerticalSpan:new{ width = Screen:scaleBySize(row.space or 8) })
            local w = math.floor((content_w - (#row - 1) * gap) / #row)
            local hg = HorizontalGroup:new{ align = "center" }
            for i, a in ipairs(row) do
                if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
                table.insert(hg, self:actionButton(a[1], w, function() closeSelf(); a[2]() end, a[3], nil, a.icon))
            end
            add(hg)
        end
        return content
    end
    self:showSheet(field, build)
end

-- A row of equal buttons across `width`, one per { value, label } option, with
-- the current one filled black. A tap calls onpick(value).
function InkAwayView:segmentedRow(options, current, width, onpick)
    local gap = Screen:scaleBySize(12)
    local w = math.floor((width - (#options - 1) * gap) / #options)
    local row = HorizontalGroup:new{ align = "center" }
    for i, o in ipairs(options) do
        if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        table.insert(row, self:actionButton(o[2], w, function() onpick(o[1]) end, current == o[1]))
    end
    return row
end

-- A tappable rounded tile filled with `rgb`. A grey uses a Color8 fill, rounded
-- in C. KOReader rounds an RGB32 fill pixel by pixel in Lua, which is slow, so a
-- colour tile is drawn once into an image (white corners, like the sheet) and
-- reused for every later paint.
function InkAwayView:colourTileButton(rgb, w, h, radius, cb, hold_cb)
    local fill = uiFill(rgb)
    -- a swatch is the colour it gives, in dark too
    if not isChromatic(fill) then
        return Theme.keep(Button:new{ text = "", width = w, height = h, background = fill,
            radius = radius, bordersize = 0, margin = 0, padding = 0,
            callback = cb, hold_callback = hold_cb, show_parent = self }, radius)
    end
    -- white Color8 frame behind the image: the tap highlight inverts it (a nil
    -- background would crash the highlight)
    local b = Button:new{ text = "", width = w, height = h, background = WHITE,
        radius = radius, bordersize = 0, margin = 0, padding = 0,
        callback = cb, hold_callback = hold_cb, show_parent = self }
    local ok, img_bb = pcall(function() return self:cachedColourTile(rgb, w, h, radius) end)
    if ok and img_bb and b.label_container then
        self:setButtonLabel(b, imageLabel(img_bb, w, h))
    else
        b.frame.background = fill   -- fall back to the plain (slow) colour fill
    end
    return Theme.keep(b, radius)
end

function InkAwayView:cachedColourTile(rgb, w, h, radius)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local id = table.concat({ "tile", rgb[1], rgb[2], rgb[3], w, h, radius, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e then return e.bb end
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:paintRect(0, 0, w, h, WHITE)
    bb:paintRoundedRectRGB32(0, 0, w, h, Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF), radius)
    cache[id] = { bb = bb }
    return bb
end

-- A colour swatch tile: a rounded colour square with a thin black border (thicker
-- when selected, so light swatches stay visible). The optional hold_cb deletes a
-- saved colour.
function InkAwayView:swatchTile(rgb, selected, w, cb, hold_cb, h)
    local inner = w - Screen:scaleBySize(8)
    local inner_h = (h or w) - Screen:scaleBySize(8)
    local btn = self:colourTileButton(rgb, inner, inner_h, Screen:scaleBySize(11), cb, hold_cb)
    return FrameContainer:new{
        bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
        color = BLACK, radius = Screen:scaleBySize(14),
        padding = selected and Screen:scaleBySize(1) or Screen:scaleBySize(3),
        margin = 0, btn }
end

-- A box the size of a swatch tile showing a small colour wheel, which opens the
-- colour wheel. The wheel is drawn once.
function InkAwayView:wheelTile(w, h, cb)
    local inner_w, inner_h = w - Screen:scaleBySize(8), h - Screen:scaleBySize(8)
    local radius = Screen:scaleBySize(11)
    local b = Button:new{ text = "", width = inner_w, height = inner_h, background = TILE_BG,
        radius = radius, bordersize = 0, margin = 0, padding = 0, callback = cb, show_parent = self }
    local d = math.min(inner_w, inner_h) - Screen:scaleBySize(8)
    local ok, wheel = pcall(function()
        local cache = self._wave_cache
        if not cache then cache = {}; self._wave_cache = cache end
        local id = table.concat({ "wheel", d, Screen.bb:getType() }, "|")
        if cache[id] then return cache[id].bb end
        local bb = Blitbuffer.new(d, d, Screen.bb:getType())
        require("ink/ui/colorpicker").paintWheel(bb, d, TILE_BG)
        cache[id] = { bb = bb }
        return bb
    end)
    if ok and wheel then self:setButtonLabel(b, imageLabel(wheel, d, d)) end
    Theme.keep(b, radius)
    return FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = BLACK, radius = Screen:scaleBySize(14),
        padding = Screen:scaleBySize(3), margin = 0, b }
end

-- An empty box the size of a swatch tile: a place a colour will go.
function InkAwayView:emptySlot(w, h)
    local inner_w, inner_h = w - Screen:scaleBySize(8), h - Screen:scaleBySize(8)
    return FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = Paint.HAIRLINE,
        radius = Screen:scaleBySize(14), padding = Screen:scaleBySize(3), margin = 0,
        background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = inner_w, h = inner_h }, HorizontalSpan:new{ width = 0 } } }
end

-- A brush-style tile: a small rounded rectangle showing a sample wave rendered
-- through the same rasterizer the pen uses, so it previews how the brush looks.
function InkAwayView:brushWaveTile(key, w, h, sel, cb, hold_cb)
    local a = Accent.get()
    -- render the sample wave into a bb sized to the inner tile
    local iw = w - Screen:scaleBySize(16)
    local ih = h - Screen:scaleBySize(16)
    local ok, wave = pcall(function() return self:cachedBrushWave(key, iw, ih, sel) end)
    if sel and a.chromatic and ok and wave then
        return self:accentButton(w, h, Screen:scaleBySize(12), imageLabel(wave, iw, ih), cb, hold_cb)
    end
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(12), background = sel and a.fill or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    if ok and wave then self:setButtonLabel(b, imageLabel(wave, iw, ih)) end
    return b
end

-- A brush sample from the cache: samples do not change while the canvas is open,
-- and a textured one takes a few ms to draw. Keyed by style table, so an edited
-- custom brush is drawn again.
function InkAwayView:cachedBrushWave(key, w, h, sel)
    local cache = self._wave_cache
    if not cache then cache = {}; self._wave_cache = cache end
    local st = Raster.STYLES[key] or Raster.STYLES.solid
    local id = table.concat({ key, w, h, sel and Accent.get().key or 0, Screen.bb:getType() }, "|")
    local e = cache[id]
    if e and e.st == st then return e.bb end
    if e then e.bb:free() end
    local bb = self:renderBrushWave(key, w, h, sel)
    cache[id] = { bb = bb, st = st }
    return bb
end

function InkAwayView:freeWaveCache()
    if self._wave_cache then
        for _, e in pairs(self._wave_cache) do e.bb:free() end
        self._wave_cache = nil
    end
end

-- Render a sample stroke for brush `key` into a new buffer: on the accent in its
-- text colour when selected, else black on grey.
function InkAwayView:renderBrushWave(key, w, h, sel)
    local a = Accent.get()
    local st = Raster.STYLES[key] or Raster.STYLES.solid
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    Paint.fillRect(bb, 0, 0, w, h, sel and a.fill or TILE_BG, sel and a.chromatic)
    Paint.brushSample(bb, st, sel and a.text or BLACK,
        Screen:scaleBySize(6), math.max(3, Screen:scaleBySize(5)), 0.26, 36)
    return bb
end

-- A short, non-blocking message at the top of the screen, gone after
-- `timeout` seconds (KOReader's own length by default).
function InkAwayView:showNotice(text, timeout)
    local ok, Notification = pcall(require, "ui/widget/notification")
    if ok and Notification then
        UIManager:show(Notification:new{ text = text, timeout = timeout })
    else
        self:tell(text, { timeout = timeout or 2 })
    end
end

return InkAwayView
