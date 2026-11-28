--[[
The guide (its cards are in ink/guide.lua): Guide, beside Done in Settings and
in Book ink over a book, opens a grid of topics; a topic shows its cards a
screenful at a time, each under the glyph of its gesture or the icon of its
tool, with Show me where there is a sheet to open. Cards that don't apply on
this reader or here (over a book or not) are left out.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("ink/l10n")
local Actions = require("ink/actions")
local EinkDrive = require("ink/einkdrive")
local Guide = require("ink/guide")
local Paint = require("ink/paint")
local Welcome = require("ink/welcome")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local GREY = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF)

local function S(px) return Screen:scaleBySize(px) end
local function vspan(px) return VerticalSpan:new{ width = S(px) } end
local function hspan(px) return HorizontalSpan:new{ width = S(px) } end

local InkAwayView = {}

-- What the guide needs to know about here (see Guide.WHEN).
function InkAwayView:guideContext()
    local book = (self.reader_mode or self.floating) and true or false
    local ctx = {
        book = book, canvas = not book,
        pen_capable = self:penCapable() and true or false,
        pen = (self.palm_reject and self:penCapable()) and true or false,
        pressure = self:pressureReader() and true or false,
        colour = self:colorScreen() and true or false,
        android = self:onAndroid(),
        bindings = Actions.load(function(k) return self:getSetting(k) end),
        label = function(id) return _(Actions.label(id)) end,
        gesture = function(ges)
            local g = Welcome.GESTURES[ges]
            return g and { glyph = g.glyph, text = _(g.text) }
        end,
        placed = {},
    }
    ctx.boox = ctx.android and EinkDrive.detect() ~= nil
    local st = self:getSetting("inkaway_entry_gestures")
    if type(st) == "table" and type(st.placed) == "table" then
        for id, where in pairs(st.placed) do
            if type(where) == "table" then ctx.placed[id] = where.gesture_reader end
        end
    end
    return ctx
end

-- What a card's Show me opens here, or nil where there is nothing to open.
function InkAwayView:guideAction(id)
    local book = self.reader_mode or self.floating
    local actions = {
        pens = function() self:openPenSettings() end,
        pen_input = function() self:openPenInput() end,
        eraser = function() self:openEraserSettings() end,
        shapes = function() self:openShapePicker() end,
        gestures = function() self:openGestureSettings() end,
        device_tips = function() self:deviceTips(true) end,
        appearance = function() self:openAppearance() end,
        paper_colour = not book and function() self:openPaperColour() end or nil,
        updates = not book and function() self:openUpdates() end or nil,
        library = not book and function() self:openLibrary() end or nil,
        trash = not book and function() self:openTrash() end or nil,
        export = not book and function() self:openExport() end or nil,
        pen_test = not book and function() self:openPenTest() end or nil,
        layers = not book and not self.notebook and function() self:openDocumentSheet() end or nil,
        book_ink = self.reader_mode and function() self:openReaderSettings() end or nil,
    }
    return actions[id]
end

-- Open the guide, at its topics or at topic `id`.
function InkAwayView:openGuide(id)
    self:closeSheet("_settings_dialog")
    self:closeSheet("_guide")
    self._guide_topic, self._guide_page = id, 0
    self:showSheet("_guide", function() return self:buildGuide() end)
end

-- Go to topic `id` (nil: the topics) in the open guide.
function InkAwayView:guideGo(id)
    self._guide_topic, self._guide_page = id, 0
    if not self:rebuildSheet("_guide") then self:openGuide(id) end
end

-- An icon from ink/icons, or a blank of its size.
function InkAwayView:guideIcon(name, size)
    return (name and self:tileIcon(name, size)) or HorizontalSpan:new{ width = size }
end

-- A topic in the index: a grey tile with its icon, its title and a line.
function InkAwayView:guideTile(t, w, h, cb)
    local isz = S(28)
    local tw = w - isz - S(30)
    local texts = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = _(t.title), face = Font:getFace("cfont", 16), bold = true, max_width = tw },
        vspan(2),
        TextWidget:new{ text = _(t.line), face = Font:getFace("cfont", 12), fgcolor = GREY, max_width = tw } }
    -- fgcolor is set for the tap highlight, which inverts the label's colour
    local row = HorizontalGroup:new{ align = "center", fgcolor = BLACK,
        hspan(12), self:guideIcon(t.icon, isz), hspan(10), texts,
        HorizontalSpan:new{ width = math.max(0, w - S(22) - isz - texts:getSize().w) } }
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0, radius = S(14),
        background = Paint.TILE_BG, margin = 0, padding = 0, callback = cb, show_parent = self }
    self:setButtonLabel(b, row)
    return b
end

-- A card: the glyph or icon, a bold title, the gesture it got (for a book
-- feature), what it is, and Show me.
function InkAwayView:guideCard(card, w)
    local isz = S(32)
    local tw = w - isz - S(14)
    local col = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = card.title or "", width = tw, face = Font:getFace("cfont", 17), bold = true } }
    if card.how then
        col[#col + 1] = vspan(2)
        col[#col + 1] = TextBoxWidget:new{ text = card.how, width = tw, face = Font:getFace("cfont", 14), bold = true }
    end
    col[#col + 1] = vspan(2)
    col[#col + 1] = TextBoxWidget:new{ text = card.text or "", width = tw, face = Font:getFace("cfont", 15) }
    local act = card.show and self:guideAction(card.show)
    if act then
        col[#col + 1] = vspan(6)
        col[#col + 1] = self:actionButton(_("Show me"), S(130), function()
            self:closeSheet("_guide")
            act()
        end, false, "small")
    end
    return HorizontalGroup:new{ align = "top", self:guideIcon(card.glyph or card.icon, isz), hspan(14), col }
end

-- The guide's content: the topics, or the open topic's cards a page at a time.
function InkAwayView:buildGuide()
    local ctx = self:guideContext()
    local content_w, gap = self:sheetWidth()
    local content = VerticalGroup:new{ align = "left" }
    local function add(wd) content[#content + 1] = wd end
    local topic = self._guide_topic and Guide.topic(self._guide_topic)
    if not topic then
        add(self:sheetTitle(_("Guide"), content_w, _("Close"), function() self:closeSheet("_guide") end))
        add(vspan(4))
        add(self:sheetHint(_("What Ink Away can do that a glance doesn't show."), content_w))
        local topics = Guide.topics(ctx)
        local tile_w = math.floor((content_w - gap) / 2)
        local tile_h = S(62)
        for i = 1, #topics, 2 do
            add(vspan(i == 1 and 12 or 8))
            local row = HorizontalGroup:new{ align = "top" }
            for j = i, math.min(i + 1, #topics) do
                if j > i then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                local id = topics[j].id
                row[#row + 1] = self:guideTile(topics[j], tile_w, tile_h, function() self:guideGo(id) end)
            end
            add(row)
        end
        return content
    end
    add(self:sheetTitle(_(topic.title), content_w, _("Back"), function() self:guideGo(nil) end))
    -- the cards, a screenful a page: as many as fit under the sheet's top
    local cards = Guide.cards(topic, ctx)
    local widgets = {}
    for i, c in ipairs(cards) do
        c.title, c.text = _(c.title or ""), _(c.text or "")
        widgets[i] = self:guideCard(c, content_w)
    end
    local room = Screen:getHeight() - (self:sheetTopY() or 0) - S(190)
    local pages, cur, used = {}, {}, 0
    for _i, wd in ipairs(widgets) do
        local h = wd:getSize().h + S(16)
        if #cur > 0 and used + h > room then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = wd
        used = used + h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    local page = math.min(self._guide_page or 0, math.max(0, #pages - 1))
    self._guide_pages = #pages
    for _i, wd in ipairs(pages[page + 1] or {}) do
        add(vspan(16))
        add(wd)
    end
    if #pages > 1 then
        add(vspan(16))
        add(self:pagerRow(page, #pages, content_w, gap, function(d)
            self._guide_page = (page + d) % #pages
            self:rebuildSheet("_guide")
        end))
    end
    return content
end

return InkAwayView
